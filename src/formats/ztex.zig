const std = @import("std");

pub const MAGIC = @import("../shared/constants.zig").FORMAT_MAGIC.ZATEX;
pub const ZATEX_VERSION: u32 = 3;

const cooked_texture = @import("../assets/cooked/texture.zig");
const CookedTexture = cooked_texture.CookedTexture;
const TexelFormat = cooked_texture.TexelFormat;
const ColorSpace = @import("../assets/raw/texture.zig").ColorSpace;
const wire = @import("../shared/wire.zig");

const max_dimension: u32 = 32 * 1024;
/// GL's guaranteed minimum for both MAX_3D_TEXTURE_SIZE and MAX_ARRAY_TEXTURE_LAYERS.
const max_layers: u32 = 2048;
/// A full chain for `max_dimension`.
const max_mip_count: u16 = std.math.log2_int(u32, max_dimension) + 1;

pub const TextureType = cooked_texture.TextureType;

/// File layout: `Header`, then `wire.Span[mip_count]` indexed by level
/// (level 0 is the largest), then one 16-byte aligned data section per mip in
/// reverse level order. The smallest mip comes first, so a prefix read gets
/// the low mips. Each section holds every layer of that mip back to back.
pub const Header = extern struct {
    file: wire.FileHeader,
    width: u32,
    height: u32,
    /// 1 unless `texture_3d`. Halves per mip like width and height.
    depth: u32,
    /// 6 for a cube, 1 for 2D and 3D. Does not change per mip.
    array_layers: u32,
    mip_count: u16,
    format: u16,
    texture_type: u8,
    color_space: u8,
    _reserved: u16 = 0,
};

comptime {
    wire.assertTightLayout(Header);
}

pub const HEADER_SIZE: u32 = @sizeOf(Header);

pub const Extent = struct {
    width: u32,
    height: u32,
    depth: u32,
};

/// Checks dimensions, layers, and mip count against what the texture type
/// allows. Shared by `view` and `write` so the writer can't produce a file
/// the view rejects.
fn validateShape(texture_type: TextureType, extent: Extent, array_layers: u32, mip_count: usize) !void {
    if (extent.width == 0 or extent.height == 0 or extent.width > max_dimension or extent.height > max_dimension)
        return error.InvalidDimensions;
    if (extent.depth == 0 or extent.depth > max_layers or array_layers == 0 or array_layers > max_layers)
        return error.InvalidDimensions;
    const shape_ok = switch (texture_type) {
        .texture_2d => extent.depth == 1 and array_layers == 1,
        .texture_cube => extent.depth == 1 and array_layers == 6 and extent.width == extent.height,
        .texture_array => extent.depth == 1,
        .texture_3d => array_layers == 1,
    };
    if (!shape_ok) return error.InvalidTextureShape;
    const full_chain = std.math.log2_int(u32, @max(extent.width, extent.height, extent.depth)) + 1;
    if (mip_count == 0 or mip_count > full_chain) return error.InvalidMipCount;
}

fn levelExtent(base: Extent, level: usize) Extent {
    const shift: u5 = @intCast(level);
    return .{
        .width = @max(1, base.width >> shift),
        .height = @max(1, base.height >> shift),
        .depth = @max(1, base.depth >> shift),
    };
}

/// Bytes of one mip level, all layers and depth slices included. All math
/// is u64: `validateShape` caps every factor, so this can't overflow even on
/// a 32-bit target where `TexelFormat.imageSize`'s usize could.
fn levelSize(format: TexelFormat, extent: Extent, array_layers: u32) u64 {
    const block: u64 = format.blockSize();
    const blocks_x = (@as(u64, extent.width) + block - 1) / block;
    const blocks_y = (@as(u64, extent.height) + block - 1) / block;
    return blocks_x * blocks_y * format.bytesPerBlock() * extent.depth * array_layers;
}

/// Zero-copy view of a cooked texture. Borrows the bytes it was created from.
pub const Zatex = struct {
    bytes: wire.Bytes,
    width: u32,
    height: u32,
    depth: u32,
    array_layers: u32,
    format: TexelFormat,
    texture_type: TextureType,
    color_space: ColorSpace,
    /// Data span per level, largest first.
    mips: []const wire.Span,

    pub fn view(bytes: wire.Bytes) !Zatex {
        _ = try wire.FileHeader.validate(bytes, MAGIC, ZATEX_VERSION);
        const header = try wire.structAt(Header, bytes, 0);

        const format = try wire.enumFromInt(TexelFormat, header.format);
        const texture_type = try wire.enumFromInt(TextureType, header.texture_type);
        const color_space = try wire.enumFromInt(ColorSpace, header.color_space);
        if (header._reserved != 0) return error.InvalidLayout;
        const base: Extent = .{ .width = header.width, .height = header.height, .depth = header.depth };
        try validateShape(texture_type, base, header.array_layers, header.mip_count);

        const mips = try wire.sliceAt(wire.Span, bytes, HEADER_SIZE, header.mip_count);
        var order = wire.SectionOrder.init(HEADER_SIZE + @as(usize, header.mip_count) * @sizeOf(wire.Span));
        var level = mips.len;
        while (level > 0) {
            level -= 1;
            const span = mips[level];
            if (span.len != levelSize(format, levelExtent(base, level), header.array_layers)) return error.InvalidLayout;
            try order.next(span);
            _ = try wire.sectionSlice(u8, bytes, span, span.len);
        }
        try order.finish(bytes.len);

        return .{
            .bytes = bytes,
            .width = header.width,
            .height = header.height,
            .depth = header.depth,
            .array_layers = header.array_layers,
            .format = format,
            .texture_type = texture_type,
            .color_space = color_space,
            .mips = mips,
        };
    }

    pub fn mipExtent(self: *const Zatex, level: usize) Extent {
        return levelExtent(.{ .width = self.width, .height = self.height, .depth = self.depth }, level);
    }

    /// All layers of one mip level.
    pub fn mipData(self: *const Zatex, level: usize) []const u8 {
        const span = self.mips[level];
        return self.bytes[span.offset..][0..span.len];
    }

    /// One array layer (or cube face) of one mip level.
    pub fn layerData(self: *const Zatex, level: usize, layer: usize) []const u8 {
        std.debug.assert(layer < self.array_layers);
        const data = self.mipData(level);
        const layer_size = data.len / self.array_layers;
        return data[layer * layer_size ..][0..layer_size];
    }

    pub fn write(writer: *std.Io.Writer, cooked_tex: CookedTexture) !void {
        const base: Extent = .{ .width = cooked_tex.width, .height = cooked_tex.height, .depth = cooked_tex.depth };
        try validateShape(cooked_tex.texture_type, base, cooked_tex.array_layers, cooked_tex.mips.len);
        const mip_count = cooked_tex.mips.len;

        var layout = wire.Layout.init(HEADER_SIZE + mip_count * @sizeOf(wire.Span));
        var spans: [max_mip_count]wire.Span = undefined;
        var level = mip_count;
        while (level > 0) {
            level -= 1;
            const mip = cooked_tex.mips[level];
            const extent = levelExtent(base, level);
            if (mip.width != extent.width or mip.height != extent.height) return error.InvalidMipDimensions;
            if (mip.data.len != levelSize(cooked_tex.format, extent, cooked_tex.array_layers)) return error.InvalidMipDimensions;
            spans[level] = try layout.reserve(mip.data.len);
        }
        const total_size = layout.totalSize();

        var out: wire.LayoutWriter = .{ .writer = writer };
        try out.value(Header{
            .file = .init(MAGIC, ZATEX_VERSION, total_size),
            .width = cooked_tex.width,
            .height = cooked_tex.height,
            .depth = cooked_tex.depth,
            .array_layers = cooked_tex.array_layers,
            .mip_count = @intCast(mip_count),
            .format = @intFromEnum(cooked_tex.format),
            .texture_type = @intFromEnum(cooked_tex.texture_type),
            .color_space = @intFromEnum(cooked_tex.color_space),
        });
        try out.slice(spans[0..mip_count]);
        level = mip_count;
        while (level > 0) {
            level -= 1;
            try out.section(spans[level], cooked_tex.mips[level].data);
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

const Shape = struct {
    texture_type: TextureType = .texture_2d,
    depth: u32 = 1,
    array_layers: u32 = 1,
};

fn makeCookedTexture(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    format: TexelFormat,
    color_space: ColorSpace,
    mip_count: usize,
) !CookedTexture {
    return makeShapedTexture(allocator, width, height, format, color_space, mip_count, .{});
}

fn makeShapedTexture(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    format: TexelFormat,
    color_space: ColorSpace,
    mip_count: usize,
    shape: Shape,
) !CookedTexture {
    const mips = try allocator.alloc(CookedMip, mip_count);
    errdefer allocator.free(mips);

    var allocated: usize = 0;
    errdefer for (mips[0..allocated]) |mip| allocator.free(mip.data);

    const base: Extent = .{ .width = width, .height = height, .depth = shape.depth };
    for (0..mip_count) |i| {
        const extent = levelExtent(base, i);
        const size: usize = @intCast(levelSize(format, extent, shape.array_layers));
        const data = try allocator.alloc(u8, size);
        for (data, 0..) |*b, j| b.* = @intCast((i * 37 + j * 13) & 0xff);
        mips[i] = .{ .width = extent.width, .height = extent.height, .data = data };
        allocated += 1;
    }

    return .{
        .width = width,
        .height = height,
        .format = format,
        .color_space = color_space,
        .texture_type = shape.texture_type,
        .depth = shape.depth,
        .array_layers = shape.array_layers,
        .mips = mips,
    };
}

fn writeToBuffer(buf: []align(wire.section_alignment) u8, cooked: CookedTexture) !wire.Bytes {
    var writer = std.Io.Writer.fixed(buf);
    try Zatex.write(&writer, cooked);
    return buf[0..writer.end];
}

fn spanOffsetPos(level: usize) usize {
    return HEADER_SIZE + level * @sizeOf(wire.Span) + @offsetOf(wire.Span, "offset");
}

fn spanLenPos(level: usize) usize {
    return HEADER_SIZE + level * @sizeOf(wire.Span) + @offsetOf(wire.Span, "len");
}

test "Header is 40 bytes" {
    try testing.expectEqual(@as(u32, 40), HEADER_SIZE);
    try testing.expectEqual(@as(u16, 16), max_mip_count);
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
    // header + one 8-byte span, data aligned to 48
    try testing.expectEqual(@as(usize, 48 + 4 * 2 * 4), bytes.len);
}

test "Zatex.view round-trips header fields and mip data in place" {
    var cooked = try makeCookedTexture(testing.allocator, 16, 8, .rg8, .linear, 4);
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeToBuffer(&buf, cooked);
    const texture = try Zatex.view(bytes);

    try testing.expectEqual(@as(u32, 16), texture.width);
    try testing.expectEqual(@as(u32, 8), texture.height);
    try testing.expectEqual(@as(u32, 1), texture.depth);
    try testing.expectEqual(@as(u32, 1), texture.array_layers);
    try testing.expectEqual(TexelFormat.rg8, texture.format);
    try testing.expectEqual(ColorSpace.linear, texture.color_space);
    try testing.expectEqual(TextureType.texture_2d, texture.texture_type);
    try testing.expectEqual(cooked.mips.len, texture.mips.len);
    for (cooked.mips, 0..) |src, level| {
        const extent = texture.mipExtent(level);
        try testing.expectEqual(src.width, extent.width);
        try testing.expectEqual(src.height, extent.height);
        try testing.expectEqual(@as(u32, 1), extent.depth);
        const data = texture.mipData(level);
        try testing.expectEqualSlices(u8, src.data, data);
        // Views point into the file buffer at aligned offsets.
        try testing.expect(@intFromPtr(data.ptr) >= @intFromPtr(bytes.ptr) and @intFromPtr(data.ptr) < @intFromPtr(bytes.ptr) + bytes.len);
        try testing.expectEqual(@as(usize, 0), (@intFromPtr(data.ptr) - @intFromPtr(bytes.ptr)) % wire.section_alignment);
    }
}

test "Zatex.write stores mips smallest first" {
    var cooked = try makeCookedTexture(testing.allocator, 64, 64, .bc1, .srgb, 7);
    defer cooked.deinit(testing.allocator);

    var buf: [4096]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeToBuffer(&buf, cooked);
    const texture = try Zatex.view(bytes);

    const table_end = HEADER_SIZE + texture.mips.len * @sizeOf(wire.Span);
    try testing.expectEqual(wire.alignSection(table_end), texture.mips[texture.mips.len - 1].offset);
    for (1..texture.mips.len) |level| {
        try testing.expect(texture.mips[level].offset < texture.mips[level - 1].offset);
    }
    try testing.expectEqual(bytes.len, texture.mips[0].end());
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

test "Zatex.view round-trips arrays, cubes, and 3D textures" {
    const cases = [_]struct { width: u32, height: u32, mips: usize, shape: Shape }{
        .{ .width = 8, .height = 4, .mips = 4, .shape = .{ .texture_type = .texture_array, .array_layers = 3 } },
        .{ .width = 8, .height = 8, .mips = 4, .shape = .{ .texture_type = .texture_cube, .array_layers = 6 } },
        .{ .width = 8, .height = 4, .mips = 4, .shape = .{ .texture_type = .texture_3d, .depth = 8 } },
    };
    for (cases) |case| {
        var cooked = try makeShapedTexture(testing.allocator, case.width, case.height, .bc4, .linear, case.mips, case.shape);
        defer cooked.deinit(testing.allocator);

        var buf: [4096]u8 align(wire.section_alignment) = undefined;
        const texture = try Zatex.view(try writeToBuffer(&buf, cooked));
        try testing.expectEqual(case.shape.texture_type, texture.texture_type);
        try testing.expectEqual(case.shape.depth, texture.depth);
        try testing.expectEqual(case.shape.array_layers, texture.array_layers);
        for (cooked.mips, 0..) |src, level| {
            try testing.expectEqualSlices(u8, src.data, texture.mipData(level));
            const layer_size = src.data.len / case.shape.array_layers;
            for (0..case.shape.array_layers) |layer| {
                try testing.expectEqualSlices(u8, src.data[layer * layer_size ..][0..layer_size], texture.layerData(level, layer));
            }
        }
    }
}

test "Zatex 3D depth halves per mip while array layers stay fixed" {
    var volume = try makeShapedTexture(testing.allocator, 4, 4, .r8, .linear, 3, .{ .texture_type = .texture_3d, .depth = 8 });
    defer volume.deinit(testing.allocator);
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const texture = try Zatex.view(try writeToBuffer(&buf, volume));
    try testing.expectEqual(Extent{ .width = 1, .height = 1, .depth = 2 }, texture.mipExtent(2));
    try testing.expectEqual(@as(usize, 2), texture.mipData(2).len);

    // An 8-deep 4x4 volume has a 4-level chain.
    var full = try makeShapedTexture(testing.allocator, 4, 4, .r8, .linear, 4, .{ .texture_type = .texture_3d, .depth = 8 });
    defer full.deinit(testing.allocator);
    _ = try Zatex.view(try writeToBuffer(&buf, full));

    var array = try makeShapedTexture(testing.allocator, 4, 4, .r8, .linear, 3, .{ .texture_type = .texture_array, .array_layers = 5 });
    defer array.deinit(testing.allocator);
    const array_view = try Zatex.view(try writeToBuffer(&buf, array));
    try testing.expectEqual(@as(usize, 5), array_view.mipData(2).len);
}

test "Zatex.write rejects shapes the texture type does not allow" {
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const bad = [_]struct { width: u32, height: u32, shape: Shape }{
        .{ .width = 4, .height = 4, .shape = .{ .array_layers = 2 } },
        .{ .width = 4, .height = 4, .shape = .{ .depth = 2 } },
        .{ .width = 4, .height = 2, .shape = .{ .texture_type = .texture_cube, .array_layers = 6 } },
        .{ .width = 4, .height = 4, .shape = .{ .texture_type = .texture_cube, .array_layers = 5 } },
        .{ .width = 4, .height = 4, .shape = .{ .texture_type = .texture_array, .depth = 2 } },
        .{ .width = 4, .height = 4, .shape = .{ .texture_type = .texture_3d, .depth = 2, .array_layers = 2 } },
    };
    for (bad) |case| {
        var cooked = try makeShapedTexture(testing.allocator, case.width, case.height, .r8, .linear, 1, case.shape);
        defer cooked.deinit(testing.allocator);
        try testing.expectError(error.InvalidTextureShape, writeToBuffer(&buf, cooked));
    }
}

test "Zatex.view rejects a texture type the dimensions don't fit" {
    var cooked = try makeShapedTexture(testing.allocator, 4, 4, .r8, .linear, 1, .{ .texture_type = .texture_array, .array_layers = 6 });
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const len = (try writeToBuffer(&buf, cooked)).len;
    _ = try Zatex.view(buf[0..len]);

    // Six layers but tagged 2D.
    buf[@offsetOf(Header, "texture_type")] = @intFromEnum(TextureType.texture_2d);
    try testing.expectError(error.InvalidTextureShape, Zatex.view(buf[0..len]));
    // Six layers tagged cube is fine (4x4 is square).
    buf[@offsetOf(Header, "texture_type")] = @intFromEnum(TextureType.texture_cube);
    _ = try Zatex.view(buf[0..len]);
    std.mem.writeInt(u32, buf[@offsetOf(Header, "array_layers")..][0..4], 0, .little);
    try testing.expectError(error.InvalidDimensions, Zatex.view(buf[0..len]));
    std.mem.writeInt(u32, buf[@offsetOf(Header, "array_layers")..][0..4], max_layers + 1, .little);
    try testing.expectError(error.InvalidDimensions, Zatex.view(buf[0..len]));
}

test "Zatex rejects mip counts past the full chain" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 2, .r8, .linear, 4);
    defer cooked.deinit(testing.allocator);
    var buf: [512]u8 align(wire.section_alignment) = undefined;
    try testing.expectError(error.InvalidMipCount, writeToBuffer(&buf, cooked));

    var full = try makeCookedTexture(testing.allocator, 4, 2, .r8, .linear, 3);
    defer full.deinit(testing.allocator);
    const len = (try writeToBuffer(&buf, full)).len;
    std.mem.writeInt(u16, buf[@offsetOf(Header, "mip_count")..][0..2], 4, .little);
    try testing.expectError(error.InvalidMipCount, Zatex.view(buf[0..len]));
    std.mem.writeInt(u16, buf[@offsetOf(Header, "mip_count")..][0..2], 0, .little);
    try testing.expectError(error.InvalidMipCount, Zatex.view(buf[0..len]));
}

test "Zatex.write rejects mips with the wrong dimensions or size" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .r8, .linear, 2);
    defer cooked.deinit(testing.allocator);
    var buf: [512]u8 align(wire.section_alignment) = undefined;

    cooked.mips[1].width = 3;
    try testing.expectError(error.InvalidMipDimensions, writeToBuffer(&buf, cooked));
    cooked.mips[1].width = 2;
    cooked.array_layers = 1;
    const data = cooked.mips[1].data;
    cooked.mips[1].data = data[0..3];
    try testing.expectError(error.InvalidMipDimensions, writeToBuffer(&buf, cooked));
    cooked.mips[1].data = data;
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

test "Zatex.view rejects truncated files, invalid enum values, and reserved bits" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .rgba8, .srgb, 1);
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const len = (try writeToBuffer(&buf, cooked)).len;

    try testing.expectError(error.InvalidFileSize, Zatex.view(buf[0 .. len - 1]));

    buf[@offsetOf(Header, "_reserved")] = 1;
    try testing.expectError(error.InvalidLayout, Zatex.view(buf[0..len]));
    buf[@offsetOf(Header, "_reserved")] = 0;

    buf[@offsetOf(Header, "texture_type")] = 4;
    try testing.expectError(error.InvalidEnumValue, Zatex.view(buf[0..len]));
    buf[@offsetOf(Header, "texture_type")] = 0;

    const format_offset = @offsetOf(Header, "format");
    std.mem.writeInt(u16, buf[format_offset..][0..2], std.math.maxInt(u16), .little);
    try testing.expectError(error.InvalidEnumValue, Zatex.view(buf[0..len]));
}

test "Zatex.view rejects a section length that disagrees with the derived mip size" {
    var cooked = try makeCookedTexture(testing.allocator, 8, 8, .r8, .linear, 2);
    defer cooked.deinit(testing.allocator);

    var buf: [512]u8 align(wire.section_alignment) = undefined;
    const len = (try writeToBuffer(&buf, cooked)).len;
    std.mem.writeInt(u32, buf[spanLenPos(1)..][0..4], 15, .little);
    try testing.expectError(error.InvalidLayout, Zatex.view(buf[0..len]));
}

test "Zatex.view rejects largest-first data order" {
    // Valid sizes and alignment, but level 0 is written first (the v2 order).
    const data_start = wire.alignSection(HEADER_SIZE + 2 * @sizeOf(wire.Span));
    const level0: wire.Span = .{ .offset = @intCast(data_start), .len = 4 };
    const level1: wire.Span = .{ .offset = @intCast(data_start + 16), .len = 1 };
    const total: u32 = @intCast(level1.end());

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var out: wire.LayoutWriter = .{ .writer = &writer };
    try out.value(Header{
        .file = .init(MAGIC, ZATEX_VERSION, total),
        .width = 2,
        .height = 2,
        .depth = 1,
        .array_layers = 1,
        .mip_count = 2,
        .format = @intFromEnum(TexelFormat.r8),
        .texture_type = @intFromEnum(TextureType.texture_2d),
        .color_space = @intFromEnum(ColorSpace.linear),
    });
    try out.slice(&[_]wire.Span{ level0, level1 });
    try out.section(level0, &.{ 1, 2, 3, 4 });
    try out.section(level1, &.{5});
    try out.finish(total);

    // The smallest level is checked first and isn't at the first data offset.
    try testing.expectError(error.InvalidLayout, Zatex.view(buf[0..writer.end]));
}

/// The file from the item 1 review report, in the v3 layout: a 4x4 BC4 chain
/// whose three levels are all one 8-byte block, with every span referencing
/// the same block. Sizes and alignment are valid; only the overlap is wrong.
pub fn writeAliasedMipFile(buf: []align(wire.section_alignment) u8) wire.Bytes {
    const mip_count = 3;
    const data_offset = wire.alignSection(HEADER_SIZE + mip_count * @sizeOf(wire.Span));
    const total: u32 = @intCast(data_offset + 8);
    var writer = std.Io.Writer.fixed(buf);
    var out: wire.LayoutWriter = .{ .writer = &writer };
    out.value(Header{
        .file = .init(MAGIC, ZATEX_VERSION, total),
        .width = 4,
        .height = 4,
        .depth = 1,
        .array_layers = 1,
        .mip_count = mip_count,
        .format = @intFromEnum(TexelFormat.bc4),
        .texture_type = @intFromEnum(TextureType.texture_2d),
        .color_space = @intFromEnum(ColorSpace.linear),
    }) catch unreachable;
    for (0..mip_count) |_| out.value(wire.Span{ .offset = @intCast(data_offset), .len = 8 }) catch unreachable;
    out.padTo(data_offset) catch unreachable;
    out.bytes(&(.{0x7f} ** 8)) catch unreachable;
    return buf[0..writer.end];
}

test "Zatex.view rejects overlapping mip sections" {
    var buf: [256]u8 align(wire.section_alignment) = undefined;
    try testing.expectError(error.OverlappingSections, Zatex.view(writeAliasedMipFile(&buf)));
}

test "levelSize matches imageSize and stays exact at the largest shapes" {
    inline for (.{ TexelFormat.rgba8, TexelFormat.rgb16f, TexelFormat.bc1, TexelFormat.bc7 }) |format| {
        try testing.expectEqual(@as(u64, format.imageSize(13, 7)), levelSize(format, .{ .width = 13, .height = 7, .depth = 1 }, 1));
    }
    const max_2d: Extent = .{ .width = max_dimension, .height = max_dimension, .depth = 1 };
    try testing.expectEqual(@as(u64, 1) << 32, levelSize(.rgba8, max_2d, 1));
    try testing.expectEqual(@as(u64, 6) << 41, levelSize(.rgb16f, max_2d, max_layers));
}

test "Zatex.view rejects files larger than the writer can produce" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .r8, .linear, 1);
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const len = (try writeToBuffer(&buf, cooked)).len;
    std.mem.writeInt(u32, buf[@offsetOf(wire.FileHeader, "total_size")..][0..4], wire.max_asset_bytes + 1, .little);
    try testing.expectError(error.AssetTooLarge, Zatex.view(buf[0..len]));
}

test "Zatex.view rejects mip sections moved outside the file" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .r8, .linear, 1);
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const len = (try writeToBuffer(&buf, cooked)).len;

    std.mem.writeInt(u32, buf[spanOffsetPos(0)..][0..4], 4096, .little);
    try testing.expectError(error.InvalidLayout, Zatex.view(buf[0..len])); // not at the canonical offset
}
