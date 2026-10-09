//! Thin wrapper over the vendored libzstd (external/zstd). Only one-shot
//! frame APIs are used: every pack chunk is an independent frame.

const std = @import("std");

const c = @cImport({
    @cInclude("zstd.h");
});

pub const max_level: i32 = 22;

/// Worst-case frame size for `len` input bytes.
pub fn compressBound(len: usize) usize {
    return c.ZSTD_compressBound(len);
}

pub const Encoder = struct {
    ctx: *c.ZSTD_CCtx,

    /// Frames carry their content size and no checksum or dictionary id, so
    /// output depends only on the input, the level, and the zstd version.
    pub fn init(level: i32) !Encoder {
        const ctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
        errdefer _ = c.ZSTD_freeCCtx(ctx);
        try setParameter(ctx, c.ZSTD_c_compressionLevel, level);
        try setParameter(ctx, c.ZSTD_c_checksumFlag, 0);
        try setParameter(ctx, c.ZSTD_c_contentSizeFlag, 1);
        try setParameter(ctx, c.ZSTD_c_dictIDFlag, 0);
        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *Encoder) void {
        _ = c.ZSTD_freeCCtx(self.ctx);
        self.* = undefined;
    }

    /// Compresses `src` into one frame in `dst`, which needs at least
    /// `compressBound(src.len)` bytes, and returns the frame.
    pub fn compress(self: *Encoder, dst: []u8, src: []const u8) ![]u8 {
        std.debug.assert(dst.len >= compressBound(src.len));
        const len = c.ZSTD_compress2(self.ctx, dst.ptr, dst.len, src.ptr, src.len);
        if (c.ZSTD_isError(len) != 0) return error.CompressionFailed;
        return dst[0..len];
    }

    fn setParameter(ctx: *c.ZSTD_CCtx, param: c.ZSTD_cParameter, value: i32) !void {
        if (c.ZSTD_isError(c.ZSTD_CCtx_setParameter(ctx, param, value)) != 0) return error.InvalidCompressionParameter;
    }
};

pub const Decoder = struct {
    ctx: *c.ZSTD_DCtx,

    pub fn init() !Decoder {
        return .{ .ctx = c.ZSTD_createDCtx() orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *Decoder) void {
        _ = c.ZSTD_freeDCtx(self.ctx);
        self.* = undefined;
    }

    /// Decodes `src` into exactly `dst.len` bytes. One-shot decoding writes
    /// only inside `dst` and allocates no window, so a hostile frame can at
    /// worst fail here.
    pub fn decompress(self: *Decoder, dst: []u8, src: []const u8) !void {
        const len = c.ZSTD_decompressDCtx(self.ctx, dst.ptr, dst.len, src.ptr, src.len);
        if (c.ZSTD_isError(len) != 0 or len != dst.len) return error.CorruptPayload;
    }
};

const testing = std.testing;
/// Comfortably above `compressBound` for the small test inputs.
const test_frame_capacity = 8192;

fn testInput(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate((i / 7) ^ (i % 13));
}

test "Encoder and Decoder round-trip a frame" {
    var src: [20000]u8 = undefined;
    testInput(&src);

    var encoder = try Encoder.init(19);
    defer encoder.deinit();
    const dst = try testing.allocator.alloc(u8, compressBound(src.len));
    defer testing.allocator.free(dst);
    const frame = try encoder.compress(dst, &src);
    try testing.expect(frame.len < src.len);

    var decoder = try Decoder.init();
    defer decoder.deinit();
    var out: [src.len]u8 = undefined;
    try decoder.decompress(&out, frame);
    try testing.expectEqualSlices(u8, &src, &out);
}

test "Encoder output is deterministic" {
    var src: [5000]u8 = undefined;
    testInput(&src);
    var a_buf: [test_frame_capacity]u8 = undefined;
    var b_buf: [test_frame_capacity]u8 = undefined;

    var a = try Encoder.init(19);
    defer a.deinit();
    var b = try Encoder.init(19);
    defer b.deinit();
    try testing.expectEqualSlices(u8, try a.compress(&a_buf, &src), try b.compress(&b_buf, &src));
}

test "Decoder rejects corrupt frames and wrong lengths" {
    var src: [4096]u8 = undefined;
    testInput(&src);
    var encoder = try Encoder.init(3);
    defer encoder.deinit();
    var dst: [test_frame_capacity]u8 = undefined;
    const frame = try encoder.compress(&dst, &src);

    var decoder = try Decoder.init();
    defer decoder.deinit();
    var out: [src.len + 1]u8 = undefined;
    // Too short and too long a destination both fail.
    try testing.expectError(error.CorruptPayload, decoder.decompress(out[0 .. src.len - 1], frame));
    try testing.expectError(error.CorruptPayload, decoder.decompress(&out, frame));
    // Truncated frames and garbage fail.
    try testing.expectError(error.CorruptPayload, decoder.decompress(out[0..src.len], frame[0 .. frame.len - 1]));
    try testing.expectError(error.CorruptPayload, decoder.decompress(out[0..src.len], "not a zstd frame"));
    try testing.expectError(error.CorruptPayload, decoder.decompress(out[0..src.len], ""));
    // The decoder is reusable after errors.
    try decoder.decompress(out[0..src.len], frame);
    try testing.expectEqualSlices(u8, &src, out[0..src.len]);
}
