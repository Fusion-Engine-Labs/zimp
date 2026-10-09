const std = @import("std");

const TexelFormat = @import("../texture.zig").TexelFormat;

pub const bc1 = @import("bc1.zig");
pub const bc3 = @import("bc3.zig");
pub const bc4 = @import("bc4.zig");
pub const bc5 = @import("bc5.zig");
pub const bc7 = @import("bc7.zig");
pub const bc6h = @import("bc6h.zig");

pub const ChannelView = struct {
    bytes: []const u8,
    width: u32,
    height: u32,
    row_stride: usize,
    pixel_stride: u32,
    channels: [2]u32,
    channel_count: u8,
};

/// Encode a mip into its block-compressed on-disk representation.
///
/// `src` layout depends on `format`:
///   - .bc4:  width*height  bytes (single channel)
///   - .bc5:  width*height*2 bytes (RG interleaved)
///   - .bc1, .bc3, .bc7:  width*height*4 bytes (RGBA8)
///   - .bc6h: width*height*6 bytes (RGB f16 little-endian, same as rgb16f)
///
/// `dst.len` must equal `format.imageSize(width, height)`.
pub fn encode(
    format: TexelFormat,
    src: []const u8,
    width: u32,
    height: u32,
    dst: []u8,
) void {
    std.debug.assert(dst.len == format.imageSize(width, height));
    switch (format) {
        .bc1 => bc1.encode(src, width, height, dst),
        .bc3 => bc3.encode(src, width, height, dst),
        .bc4 => bc4.encode(src, width, height, dst),
        .bc5 => bc5.encode(src, width, height, dst),
        .bc7 => bc7.encode(src, width, height, dst),
        .bc6h => bc6h.encode(src, width, height, dst),
        else => unreachable,
    }
}

/// Encode one or two channels from an interleaved image without first copying
/// them into a full-image R or RG buffer.
pub fn encodeChannels(format: TexelFormat, source: ChannelView, dst: []u8) void {
    std.debug.assert(dst.len == format.imageSize(source.width, source.height));
    std.debug.assert(source.channel_count >= 1 and source.channel_count <= 2);
    std.debug.assert(source.row_stride >= @as(usize, source.width) * source.pixel_stride);
    switch (format) {
        .bc4 => bc4.encodeChannels(source, dst),
        .bc5 => bc5.encodeChannels(source, dst),
        else => unreachable,
    }
}

/// Encode an interleaved f32 RGB image directly to BC6H. Half conversion is
/// performed per 4x4 block by the encoder.
pub fn encodeF32(
    format: TexelFormat,
    source: []const f32,
    width: u32,
    height: u32,
    pixel_stride: u32,
    dst: []u8,
) void {
    std.debug.assert(format == .bc6h);
    std.debug.assert(source.len >= @as(usize, width) * @as(usize, height) * pixel_stride);
    std.debug.assert(dst.len == format.imageSize(width, height));
    bc6h.encodeF32(source, width, height, pixel_stride, dst);
}

/// Read a 4x4 block of `bytes_per_pixel`-sized texels into `dst`, replicating
/// edge pixels when the block straddles the image boundary. Required for mips
/// whose dimensions aren't a multiple of 4 — notably the 1x1, 2x2, 1x2 tail.
pub fn extractBlock4x4(
    src: []const u8,
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
    block_x: u32,
    block_y: u32,
    dst: []u8,
) void {
    std.debug.assert(dst.len == 16 * bytes_per_pixel);
    const row_stride = @as(usize, width) * bytes_per_pixel;

    // Interior blocks need no edge replication: each row is contiguous, so a
    // whole 4-texel row copies at once. Only the right/bottom edge of a mip
    // takes the clamped path.
    if (block_x + 4 <= width and block_y + 4 <= height) {
        const row_bytes = 4 * @as(usize, bytes_per_pixel);
        for (0..4) |ly| {
            const src_off = @as(usize, block_y + @as(u32, @intCast(ly))) * row_stride +
                @as(usize, block_x) * bytes_per_pixel;
            @memcpy(dst[ly * row_bytes ..][0..row_bytes], src[src_off..][0..row_bytes]);
        }
        return;
    }

    for (0..4) |ly| {
        const src_y = @min(block_y + @as(u32, @intCast(ly)), height - 1);
        for (0..4) |lx| {
            const src_x = @min(block_x + @as(u32, @intCast(lx)), width - 1);
            const src_off = @as(usize, src_y) * row_stride + @as(usize, src_x) * bytes_per_pixel;
            const dst_off = (ly * 4 + lx) * bytes_per_pixel;
            @memcpy(dst[dst_off..][0..bytes_per_pixel], src[src_off..][0..bytes_per_pixel]);
        }
    }
}

/// BC 4-bit index interpolation weights, scaled by 64. Fixed by the DXGI block
/// formats; shared by the BC7 and BC6H mode-6/mode-3 encoders.
pub const weights4 = [16]u32{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };

/// Read one channel of a 4x4 block out of an interleaved `ChannelView`,
/// replicating edge pixels when the block straddles the image boundary.
pub fn extractChannelBlock(source: ChannelView, origin_x: u32, origin_y: u32, channel: u32, dst: *[16]u8) void {
    std.debug.assert(channel < source.pixel_stride);

    // Interior blocks need no edge replication; skip the per-texel clamps.
    if (origin_x + 4 <= source.width and origin_y + 4 <= source.height) {
        for (0..4) |ly| {
            const row = @as(usize, origin_y + @as(u32, @intCast(ly))) * source.row_stride +
                @as(usize, origin_x) * source.pixel_stride + channel;
            for (0..4) |lx| {
                dst[ly * 4 + lx] = source.bytes[row + lx * source.pixel_stride];
            }
        }
        return;
    }

    for (0..4) |ly| {
        const y = @min(origin_y + @as(u32, @intCast(ly)), source.height - 1);
        for (0..4) |lx| {
            const x = @min(origin_x + @as(u32, @intCast(lx)), source.width - 1);
            const offset = @as(usize, y) * source.row_stride + @as(usize, x) * source.pixel_stride + channel;
            dst[ly * 4 + lx] = source.bytes[offset];
        }
    }
}

/// Write `num_bits` of `value` into `buf` starting at bit `*bit`, LSB-first.
/// Advances `*bit` by `num_bits`.
pub fn writeBits(buf: []u8, bit: *u32, value: u32, num_bits: u32) void {
    std.debug.assert(num_bits <= 32);
    var v = value;
    var remaining = num_bits;
    while (remaining > 0) {
        const byte_idx: u32 = bit.* / 8;
        const bit_in_byte: u3 = @intCast(bit.* % 8);
        const space_in_byte: u32 = 8 - @as(u32, bit_in_byte);
        const take: u32 = @min(remaining, space_in_byte);
        const mask: u32 = (@as(u32, 1) << @intCast(take)) - 1;
        const chunk: u8 = @intCast(v & mask);
        buf[byte_idx] |= chunk << bit_in_byte;
        v >>= @intCast(take);
        bit.* += take;
        remaining -= take;
    }
}

const testing = std.testing;

test "extractBlock4x4: full in-bounds block copies unchanged" {
    // 4x4 single-channel: fill with column index so we can verify layout.
    var src: [16]u8 = undefined;
    for (0..4) |y| for (0..4) |x| {
        src[y * 4 + x] = @intCast(x);
    };

    var dst: [16]u8 = undefined;
    extractBlock4x4(&src, 4, 4, 1, 0, 0, &dst);

    try testing.expectEqualSlices(u8, &src, &dst);
}

test "extractBlock4x4: replicates edge when block overhangs" {
    // 2x2 image, single channel:  (0,0)=10 (1,0)=20 (0,1)=30 (1,1)=40
    const src = [_]u8{ 10, 20, 30, 40 };

    var dst: [16]u8 = undefined;
    extractBlock4x4(&src, 2, 2, 1, 0, 0, &dst);

    // Row 0: 10, 20, 20, 20   (x >= 1 clamps to x=1)
    // Row 1: 30, 40, 40, 40
    // Row 2: same as row 1 (y clamps to y=1)
    // Row 3: same as row 1
    const expected = [_]u8{
        10, 20, 20, 20,
        30, 40, 40, 40,
        30, 40, 40, 40,
        30, 40, 40, 40,
    };
    try testing.expectEqualSlices(u8, &expected, &dst);
}

test "extractBlock4x4: multi-byte pixels stay packed" {
    // 1x1 image, 2 bytes per pixel — every slot should be the same pair.
    const src = [_]u8{ 0xAA, 0xBB };
    var dst: [32]u8 = undefined;
    extractBlock4x4(&src, 1, 1, 2, 0, 0, &dst);

    for (0..16) |i| {
        try testing.expectEqual(@as(u8, 0xAA), dst[i * 2]);
        try testing.expectEqual(@as(u8, 0xBB), dst[i * 2 + 1]);
    }
}
