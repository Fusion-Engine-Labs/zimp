const std = @import("std");

pub const MAGIC = @import("../shared/constants.zig").FORMAT_MAGIC.ZATEX;
pub const ZATEX_VERSION: u32 = 2;

const cooked_texture = @import("../assets/cooked/texture.zig");
const CookedTexture = cooked_texture.CookedTexture;
const TexelFormat = cooked_texture.TexelFormat;
const ColorSpace = @import("../assets/raw/texture.zig").ColorSpace;
const wire = @import("../shared/wire.zig");

const max_dimension: u32 = 32 * 1024;
const max_mip_count: u16 = 32;

pub const TextureType = enum(u8) {
    texture_2d = 0,
    texture_cube = 1,
    texture_array = 2,
};

/// File layout: `Header`, then `MipEntry[mip_count]`, then one 16-byte
/// aligned data section per mip, largest first.
pub const Header = extern struct {
    file: wire.FileHeader,
    width: u32,
    height: u32,
    mip_count: u16,
    format: u16,
    texture_type: u8,
    color_space: u8,
    _reserved: u16 = 0,
};

pub const MipEntry = extern struct {
    width: u32,
    height: u32,
    data: wire.Span,
};

comptime {
    wire.assertTightLayout(Header);
    wire.assertTightLayout(MipEntry);
}

pub const HEADER_SIZE: u32 = @sizeOf(Header);

/// Zero-copy view of a cooked texture. Borrows the bytes it was created from.
pub const Zatex = struct {
    bytes: wire.Bytes,
    width: u32,
    height: u32,
    format: TexelFormat,
    texture_type: TextureType,
    color_space: ColorSpace,
    mips: []const MipEntry,

    pub fn view(bytes: wire.Bytes) !Zatex {
        _ = try wire.FileHeader.validate(bytes, MAGIC, ZATEX_VERSION);
        const header = try wire.structAt(Header, bytes, 0);

        const format = try wire.enumFromInt(TexelFormat, header.format);
        const texture_type = try wire.enumFromInt(TextureType, header.texture_type);
        const color_space = try wire.enumFromInt(ColorSpace, header.color_space);
        if (header.width == 0 or header.height == 0 or header.width > max_dimension or header.height > max_dimension)
            return error.InvalidDimensions;
        if (header.mip_count == 0 or header.mip_count > max_mip_count) return error.InvalidMipCount;

        const mips = try wire.sliceAt(MipEntry, bytes, HEADER_SIZE, header.mip_count);
        var order = wire.SectionOrder.init(HEADER_SIZE + @as(usize, header.mip_count) * @sizeOf(MipEntry));
        var expected_width = header.width;
        var expected_height = header.height;
        for (mips) |mip| {
            if (mip.width != expected_width or mip.height != expected_height) return error.InvalidMipDimensions;
            try order.next(mip.data);
            _ = try wire.sectionSlice(u8, bytes, mip.data, format.imageSize(mip.width, mip.height));
            expected_width = @max(1, expected_width / 2);
            expected_height = @max(1, expected_height / 2);
        }

        return .{
            .bytes = bytes,
            .width = header.width,
            .height = header.height,
            .format = format,
            .texture_type = texture_type,
            .color_space = color_space,
            .mips = mips,
        };
    }

    pub fn mipData(self: *const Zatex, level: usize) []const u8 {
        const span = self.mips[level].data;
        return self.bytes[span.offset..][0..span.len];
    }

    pub fn write(writer: *std.Io.Writer, cooked_tex: CookedTexture) !void {
        if (cooked_tex.mips.len == 0 or cooked_tex.mips.len > max_mip_count) return error.InvalidMipCount;

        var layout = wire.Layout.init(HEADER_SIZE + cooked_tex.mips.len * @sizeOf(MipEntry));
        var spans: [max_mip_count]wire.Span = undefined;
        for (cooked_tex.mips, spans[0..cooked_tex.mips.len]) |mip, *span| {
            std.debug.assert(mip.data.len == cooked_tex.format.imageSize(mip.width, mip.height));
            span.* = try layout.reserve(mip.data.len);
        }
        const total_size = layout.totalSize();

        var out: wire.LayoutWriter = .{ .writer = writer };
        try out.value(Header{
            .file = .init(MAGIC, ZATEX_VERSION, total_size),
            .width = cooked_tex.width,
            .height = cooked_tex.height,
            .mip_count = @intCast(cooked_tex.mips.len),
            .format = @intFromEnum(cooked_tex.format),
            .texture_type = @intFromEnum(TextureType.texture_2d),
            .color_space = @intFromEnum(cooked_tex.color_space),
        });
        for (cooked_tex.mips, spans[0..cooked_tex.mips.len]) |mip, span| {
            try out.value(MipEntry{ .width = mip.width, .height = mip.height, .data = span });
        }
        for (cooked_tex.mips, spans[0..cooked_tex.mips.len]) |mip, span| {
            try out.section(span, mip.data);
        }
        try out.finish(total_size);
    }
};

pub fn view(bytes: wire.Bytes) !Zatex {
    return Zatex.view(bytes);
}

pub fn write(writer: *std.Io.Writer, cooked: CookedTexture) !void {
    return Zatex.write(writer, cooked);
}

const testing = std.testing;
const CookedMip = cooked_texture.CookedMip;

fn makeCookedTexture(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    format: TexelFormat,
    color_space: ColorSpace,
    mip_count: usize,
) !CookedTexture {
    const mips = try allocator.alloc(CookedMip, mip_count);
    errdefer allocator.free(mips);

    var allocated: usize = 0;
    errdefer for (mips[0..allocated]) |mip| allocator.free(mip.data);

    var w: u32 = width;
    var h: u32 = height;
    for (0..mip_count) |i| {
        const size = format.imageSize(w, h);
        const data = try allocator.alloc(u8, size);
        for (data, 0..) |*b, j| b.* = @intCast((i * 37 + j * 13) & 0xff);
        mips[i] = .{ .width = w, .height = h, .data = data };
        allocated += 1;
        w = @max(1, w / 2);
        h = @max(1, h / 2);
    }

    return .{
        .width = width,
        .height = height,
        .format = format,
        .color_space = color_space,
        .mips = mips,
    };
}

fn writeToBuffer(buf: []align(wire.section_alignment) u8, cooked: CookedTexture) !wire.Bytes {
    var writer = std.Io.Writer.fixed(buf);
    try Zatex.write(&writer, cooked);
    return buf[0..writer.end];
}

test "Header is 32 bytes and MipEntry is 16 bytes" {
    try testing.expectEqual(@as(u32, 32), HEADER_SIZE);
    try testing.expectEqual(@as(usize, 16), @sizeOf(MipEntry));
}

test "Zatex.write records magic, version, and exact total size" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 2, .rgba8, .srgb, 1);
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeToBuffer(&buf, cooked);

    try testing.expectEqualSlices(u8, MAGIC, bytes[0..4]);
    const header = try wire.structAt(Header, bytes, 0);
    try testing.expectEqual(ZATEX_VERSION, header.file.version);
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), header.file.total_size);
    // header + one mip entry, data section aligned right after
    try testing.expectEqual(@as(usize, HEADER_SIZE + 16 + 4 * 2 * 4), bytes.len);
}

test "Zatex.view round-trips header fields and mip data in place" {
    var cooked = try makeCookedTexture(testing.allocator, 16, 8, .rg8, .linear, 4);
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeToBuffer(&buf, cooked);
    const texture = try Zatex.view(bytes);

    try testing.expectEqual(@as(u32, 16), texture.width);
    try testing.expectEqual(@as(u32, 8), texture.height);
    try testing.expectEqual(TexelFormat.rg8, texture.format);
    try testing.expectEqual(ColorSpace.linear, texture.color_space);
    try testing.expectEqual(TextureType.texture_2d, texture.texture_type);
    try testing.expectEqual(cooked.mips.len, texture.mips.len);
    for (cooked.mips, texture.mips, 0..) |src, dst, level| {
        try testing.expectEqual(src.width, dst.width);
        try testing.expectEqual(src.height, dst.height);
        const data = texture.mipData(level);
        try testing.expectEqualSlices(u8, src.data, data);
        // Views point into the file buffer at aligned offsets.
        try testing.expect(@intFromPtr(data.ptr) >= @intFromPtr(bytes.ptr) and @intFromPtr(data.ptr) < @intFromPtr(bytes.ptr) + bytes.len);
        try testing.expectEqual(@as(usize, 0), (@intFromPtr(data.ptr) - @intFromPtr(bytes.ptr)) % wire.section_alignment);
    }
}

test "Zatex.view round-trips rgb16f and block-compressed formats" {
    inline for (.{ TexelFormat.rgb16f, TexelFormat.bc7, TexelFormat.bc4 }) |format| {
        var cooked = try makeCookedTexture(testing.allocator, 8, 4, format, .linear, 2);
        defer cooked.deinit(testing.allocator);

        var buf: [1024]u8 align(wire.section_alignment) = undefined;
        const texture = try Zatex.view(try writeToBuffer(&buf, cooked));
        try testing.expectEqual(format, texture.format);
        try testing.expectEqualSlices(u8, cooked.mips[1].data, texture.mipData(1));
    }
}

test "Zatex.view rejects wrong magic and version" {
    var cooked = try makeCookedTexture(testing.allocator, 1, 1, .r8, .linear, 1);
    defer cooked.deinit(testing.allocator);

    var buf: [128]u8 align(wire.section_alignment) = undefined;
    const len = (try writeToBuffer(&buf, cooked)).len;

    buf[0] = 'X';
    try testing.expectError(error.InvalidMagic, Zatex.view(buf[0..len]));
    buf[0] = MAGIC[0];
    std.mem.writeInt(u32, buf[4..8], ZATEX_VERSION + 1, .little);
    try testing.expectError(error.UnsupportedVersion, Zatex.view(buf[0..len]));
}

test "Zatex.view rejects truncated files and invalid enum values" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .rgba8, .srgb, 1);
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const len = (try writeToBuffer(&buf, cooked)).len;

    try testing.expectError(error.InvalidFileSize, Zatex.view(buf[0 .. len - 1]));

    const format_offset = @offsetOf(Header, "format");
    std.mem.writeInt(u16, buf[format_offset..][0..2], std.math.maxInt(u16), .little);
    try testing.expectError(error.InvalidEnumValue, Zatex.view(buf[0..len]));
}

test "Zatex.view rejects mip chains with wrong dimensions" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .r8, .linear, 2);
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const len = (try writeToBuffer(&buf, cooked)).len;

    const second_mip_width = HEADER_SIZE + @sizeOf(MipEntry);
    std.mem.writeInt(u32, buf[second_mip_width..][0..4], 3, .little);
    try testing.expectError(error.InvalidMipDimensions, Zatex.view(buf[0..len]));
}

/// The file from the review report: 32 1×1 r8 mips that all reference the
/// byte at offset 544. Each span is in bounds on its own.
fn writeAliasedMipFile(buf: []align(wire.section_alignment) u8) wire.Bytes {
    const data_offset = HEADER_SIZE + 32 * @sizeOf(MipEntry);
    const total = data_offset + 1;
    var writer = std.Io.Writer.fixed(buf);
    var out: wire.LayoutWriter = .{ .writer = &writer };
    out.value(Header{
        .file = .init(MAGIC, ZATEX_VERSION, total),
        .width = 1,
        .height = 1,
        .mip_count = 32,
        .format = @intFromEnum(TexelFormat.r8),
        .texture_type = @intFromEnum(TextureType.texture_2d),
        .color_space = @intFromEnum(ColorSpace.linear),
    }) catch unreachable;
    for (0..32) |_| out.value(MipEntry{ .width = 1, .height = 1, .data = .{ .offset = data_offset, .len = 1 } }) catch unreachable;
    out.bytes(&.{0x7f}) catch unreachable;
    return buf[0..writer.end];
}

test "Zatex.view rejects overlapping mip sections" {
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const bytes = writeAliasedMipFile(&buf);
    try testing.expectEqual(@as(usize, 545), bytes.len);
    try testing.expectError(error.OverlappingSections, Zatex.view(bytes));
}

test "Zatex.view rejects mip sections pointing outside the file" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .r8, .linear, 1);
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const len = (try writeToBuffer(&buf, cooked)).len;

    const data_offset = HEADER_SIZE + @offsetOf(MipEntry, "data");
    std.mem.writeInt(u32, buf[data_offset..][0..4], 4096, .little);
    try testing.expectError(error.Truncated, Zatex.view(buf[0..len]));
}
