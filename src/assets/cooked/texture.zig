const std = @import("std");

const raw_texture = @import("../raw/texture.zig");
const RawTexture = raw_texture.RawTexture;
const TextureClass = raw_texture.TextureClass;
const ColorSpace = raw_texture.ColorSpace;
const compression = @import("compression/compression.zig");
const rgb9e5 = @import("rgb9e5.zig");
pub const TargetProfile = @import("target_profile.zig").TargetProfile;

/// Target texel format for a cooked mip level. Values match the on-disk ZTex
/// format enum so they can be written directly.
pub const TexelFormat = enum(u16) {
    rgba8 = 0,
    rg8 = 1,
    r8 = 2,
    rgb16f = 3,
    /// GL_RGB9_E5: 9-bit RGB mantissas with a shared 5-bit exponent, one
    /// little-endian u32 per texel.
    rgb9e5 = 4,
    bc4 = 10,
    bc5 = 11,
    bc7 = 12,
    bc6h = 13,
    /// S3TC DXT1, always encoded in opaque 4-color mode.
    bc1 = 14,
    /// S3TC DXT5.
    bc3 = 15,

    pub fn isBlockCompressed(self: TexelFormat) bool {
        return switch (self) {
            .rgba8, .rg8, .r8, .rgb16f, .rgb9e5 => false,
            .bc1, .bc3, .bc4, .bc5, .bc7, .bc6h => true,
        };
    }

    /// Edge length of one block. Block-compressed formats work in 4x4 tiles;
    /// uncompressed formats treat a single texel as the block.
    pub fn blockSize(self: TexelFormat) u32 {
        return if (self.isBlockCompressed()) 4 else 1;
    }

    /// Bytes per block. For non-compressed formats, a "block" is a single texel.
    pub fn bytesPerBlock(self: TexelFormat) usize {
        return switch (self) {
            .rgba8 => 4,
            .rg8 => 2,
            .r8 => 1,
            .rgb16f => 6,
            .rgb9e5 => 4,
            .bc1, .bc4 => 8,
            .bc3, .bc5, .bc7, .bc6h => 16,
        };
    }

    /// Size in bytes of a mip of the given logical dimensions.
    /// For block-compressed formats, dimensions are rounded up to the block grid.
    pub fn imageSize(self: TexelFormat, width: u32, height: u32) usize {
        const block = self.blockSize();
        const blocks_x = (width + block - 1) / block;
        const blocks_y = (height + block - 1) / block;
        return @as(usize, blocks_x) * @as(usize, blocks_y) * self.bytesPerBlock();
    }
};

/// Shape of a cooked texture. Values match the on-disk ZTex enum.
pub const TextureType = enum(u8) {
    texture_2d = 0,
    /// Six faces stored as array layers, in GL order +X -X +Y -Y +Z -Z.
    texture_cube = 1,
    texture_array = 2,
    texture_3d = 3,
};

pub const CookedMip = struct {
    width: u32,
    height: u32,
    data: []u8,
};

pub const CookedTexture = struct {
    width: u32,
    height: u32,
    format: TexelFormat,
    color_space: ColorSpace,
    texture_type: TextureType = .texture_2d,
    /// Depth of mip 0. Only `texture_3d` has more than 1.
    depth: u32 = 1,
    /// Layers per mip: 6 for a cube, 1 for 2D and 3D.
    array_layers: u32 = 1,
    /// One entry per level, largest first. Each mip's `data` holds every layer
    /// (and depth slice) back to back.
    mips: []CookedMip,

    pub fn deinit(self: *CookedTexture, allocator: std.mem.Allocator) void {
        for (self.mips) |mip| allocator.free(mip.data);
        allocator.free(self.mips);
    }

    pub fn cook(allocator: std.mem.Allocator, raw: *const RawTexture, profile: TargetProfile) !CookedTexture {
        const format = selectFormat(raw.class, profile, hasAlpha(raw));
        const mip_count = std.math.log2(@max(raw.width, raw.height)) + 1;
        const mips = try allocator.alloc(CookedMip, mip_count);
        errdefer allocator.free(mips);

        var cooked_count: usize = 0;
        errdefer for (mips[0..cooked_count]) |mip| allocator.free(mip.data);

        if (raw.class == .normal_linear) raw.validateNormals();
        mips[cooked_count] = try cookMip(allocator, raw, format);
        cooked_count += 1;

        if (raw.width > 1 or raw.height > 1) {
            const scratch = try allocator.alloc(f32, raw.mipScratchLen());
            defer allocator.free(scratch);

            var previous: ?RawTexture = null;
            defer if (previous) |*mip| mip.deinit(allocator);

            while (true) {
                const source: *const RawTexture = if (previous) |*mip| mip else raw;
                const next = try source.downsample(allocator, scratch);
                if (previous) |*mip| {
                    mip.deinit(allocator);
                }
                previous = next;

                mips[cooked_count] = try cookMip(allocator, &previous.?, format);
                cooked_count += 1;
                if (previous.?.width == 1 and previous.?.height == 1) {
                    break;
                }
            }
        }
        std.debug.assert(cooked_count == mips.len);

        return .{
            .width = raw.width,
            .height = raw.height,
            .format = format,
            .color_space = raw.class.colorSpace(),
            .mips = mips,
        };
    }
};

fn selectFormat(class: TextureClass, profile: TargetProfile, has_alpha: bool) TexelFormat {
    return switch (profile) {
        // No BPTC on GL 4.1. BC1 is half the size of BC3 and BC7, so opaque
        // color takes it; anything with alpha needs BC3.
        .gl41 => switch (class) {
            .color_srgb, .packed_linear => if (has_alpha) .bc3 else .bc1,
            .normal_linear => .bc5,
            .single_linear => .bc4,
            .hdr_linear => .rgb9e5,
        },
        .desktop => switch (class) {
            .color_srgb => .bc7,
            .normal_linear => .bc5,
            .single_linear => .bc4,
            .packed_linear => .bc7,
            .hdr_linear => .bc6h,
        },
    };
}

/// True when any texel of the top mip has alpha below 255. Downsampling
/// averages alpha, so an opaque top mip gives an opaque chain.
fn hasAlpha(raw: *const RawTexture) bool {
    if (raw.channels != 4) return false;
    const ldr = switch (raw.pixels) {
        .ldr => |ldr| ldr,
        .hdr => return false,
    };
    var i: usize = 3;
    while (i < ldr.len) : (i += 4) {
        if (ldr[i] != 255) return true;
    }
    return false;
}

/// Extracts the channels the target format expects from a source mip.
/// LDR formats (rgba8/rg8/r8) read from `src.pixels.ldr`; rgb16f reads from `src.pixels.hdr`.
fn cookMip(allocator: std.mem.Allocator, src: *const RawTexture, format: TexelFormat) !CookedMip {
    const pixel_count = @as(usize, src.width) * @as(usize, src.height);
    const data = try allocator.alloc(u8, format.imageSize(src.width, src.height));
    errdefer allocator.free(data);

    switch (format) {
        .rgba8 => {
            const ldr = src.pixels.ldr;
            if (src.channels == 4) {
                @memcpy(data, ldr);
            } else {
                for (0..pixel_count) |i| {
                    const source_offset = i * src.channels;
                    data[i * 4 + 0] = ldr[source_offset + 0];
                    data[i * 4 + 1] = if (src.channels > 1) ldr[source_offset + 1] else ldr[source_offset + 0];
                    data[i * 4 + 2] = if (src.channels > 2) ldr[source_offset + 2] else ldr[source_offset + 0];
                    data[i * 4 + 3] = 255;
                }
            }
        },
        .rg8 => {
            const ldr = src.pixels.ldr;
            for (0..pixel_count) |i| {
                data[i * 2 + 0] = ldr[i * 4 + 0];
                data[i * 2 + 1] = ldr[i * 4 + 1];
            }
        },
        .r8 => {
            const ldr = src.pixels.ldr;
            for (0..pixel_count) |i| {
                data[i] = ldr[i * 4];
            }
        },
        .rgb16f => {
            const hdr = src.pixels.hdr;
            for (0..pixel_count) |i| {
                const r: f16 = @floatCast(hdr[i * 3 + 0]);
                const g: f16 = @floatCast(hdr[i * 3 + 1]);
                const b: f16 = @floatCast(hdr[i * 3 + 2]);
                std.mem.writeInt(u16, data[i * 6 + 0 ..][0..2], @bitCast(r), .little);
                std.mem.writeInt(u16, data[i * 6 + 2 ..][0..2], @bitCast(g), .little);
                std.mem.writeInt(u16, data[i * 6 + 4 ..][0..2], @bitCast(b), .little);
            }
        },
        .rgb9e5 => {
            const hdr = src.pixels.hdr;
            for (0..pixel_count) |i| {
                const packed_texel = rgb9e5.pack(hdr[i * 3 + 0], hdr[i * 3 + 1], hdr[i * 3 + 2]);
                std.mem.writeInt(u32, data[i * 4 ..][0..4], packed_texel, .little);
            }
        },
        .bc4 => {
            compression.encodeChannels(.bc4, .{
                .bytes = src.pixels.ldr,
                .width = src.width,
                .height = src.height,
                .row_stride = @as(usize, src.width) * src.channels,
                .pixel_stride = src.channels,
                .channels = .{ 0, 0 },
                .channel_count = 1,
            }, data);
        },
        .bc5 => {
            compression.encodeChannels(.bc5, .{
                .bytes = src.pixels.ldr,
                .width = src.width,
                .height = src.height,
                .row_stride = @as(usize, src.width) * src.channels,
                .pixel_stride = src.channels,
                .channels = .{ 0, 1 },
                .channel_count = 2,
            }, data);
        },
        .bc1, .bc3, .bc7 => {
            // Source is already the RGBA8 layout stb_image produced.
            std.debug.assert(src.channels == 4);
            compression.encode(format, src.pixels.ldr, src.width, src.height, data);
        },
        .bc6h => {
            compression.encodeF32(.bc6h, src.pixels.hdr, src.width, src.height, src.channels, data);
        },
    }

    return .{ .width = src.width, .height = src.height, .data = data };
}

const testing = std.testing;

fn makeUniformRaw(allocator: std.mem.Allocator, width: u32, height: u32, class: TextureClass, fill: u8) !RawTexture {
    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
    @memset(pixels, fill);
    return .{
        .width = width,
        .height = height,
        .channels = 4,
        .pixels = .{ .ldr = pixels },
        .class = class,
        .owner = .allocator,
    };
}

fn makeUniformRawHdr(allocator: std.mem.Allocator, width: u32, height: u32, fill: [3]f32) !RawTexture {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const pixels = try allocator.alloc(f32, pixel_count * 3);
    for (0..pixel_count) |i| {
        pixels[i * 3 + 0] = fill[0];
        pixels[i * 3 + 1] = fill[1];
        pixels[i * 3 + 2] = fill[2];
    }
    return .{
        .width = width,
        .height = height,
        .channels = 3,
        .pixels = .{ .hdr = pixels },
        .class = .hdr_linear,
        .owner = .allocator,
    };
}

test "selectFormat: desktop uses BPTC for color and HDR" {
    try testing.expectEqual(TexelFormat.bc7, selectFormat(.color_srgb, .desktop, false));
    try testing.expectEqual(TexelFormat.bc7, selectFormat(.color_srgb, .desktop, true));
    try testing.expectEqual(TexelFormat.bc7, selectFormat(.packed_linear, .desktop, false));
    try testing.expectEqual(TexelFormat.bc5, selectFormat(.normal_linear, .desktop, false));
    try testing.expectEqual(TexelFormat.bc4, selectFormat(.single_linear, .desktop, false));
    try testing.expectEqual(TexelFormat.bc6h, selectFormat(.hdr_linear, .desktop, false));
}

test "selectFormat: gl41 uses S3TC for color, RGTC for normals and masks, RGB9_E5 for HDR" {
    try testing.expectEqual(TexelFormat.bc1, selectFormat(.color_srgb, .gl41, false));
    try testing.expectEqual(TexelFormat.bc3, selectFormat(.color_srgb, .gl41, true));
    try testing.expectEqual(TexelFormat.bc1, selectFormat(.packed_linear, .gl41, false));
    try testing.expectEqual(TexelFormat.bc3, selectFormat(.packed_linear, .gl41, true));
    try testing.expectEqual(TexelFormat.bc5, selectFormat(.normal_linear, .gl41, false));
    try testing.expectEqual(TexelFormat.bc4, selectFormat(.single_linear, .gl41, false));
    try testing.expectEqual(TexelFormat.rgb9e5, selectFormat(.hdr_linear, .gl41, false));
}

test "hasAlpha: only 4-channel LDR sources with a non-opaque texel" {
    var opaque_pixels = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    var translucent_pixels = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 254 };
    var rgb_pixels = [_]u8{ 1, 2, 3 };
    const opaque_raw = RawTexture{ .width = 2, .height = 1, .channels = 4, .pixels = .{ .ldr = &opaque_pixels }, .class = .color_srgb };
    const translucent_raw = RawTexture{ .width = 2, .height = 1, .channels = 4, .pixels = .{ .ldr = &translucent_pixels }, .class = .color_srgb };
    const rgb_raw = RawTexture{ .width = 1, .height = 1, .channels = 3, .pixels = .{ .ldr = &rgb_pixels }, .class = .normal_linear };
    try testing.expect(!hasAlpha(&opaque_raw));
    try testing.expect(hasAlpha(&translucent_raw));
    try testing.expect(!hasAlpha(&rgb_raw));
}

test "imageSize: rgba8 4x4 = 64" {
    try testing.expectEqual(@as(usize, 64), TexelFormat.rgba8.imageSize(4, 4));
}

test "imageSize: rg8 2x2 = 8" {
    try testing.expectEqual(@as(usize, 8), TexelFormat.rg8.imageSize(2, 2));
}

test "imageSize: r8 3x5 = 15" {
    try testing.expectEqual(@as(usize, 15), TexelFormat.r8.imageSize(3, 5));
}

test "imageSize: bc4 4x4 = 8 (one block)" {
    try testing.expectEqual(@as(usize, 8), TexelFormat.bc4.imageSize(4, 4));
}

test "imageSize: bc4 rounds sub-block dims up to a full block" {
    try testing.expectEqual(@as(usize, 8), TexelFormat.bc4.imageSize(1, 1));
    try testing.expectEqual(@as(usize, 8), TexelFormat.bc4.imageSize(3, 3));
    try testing.expectEqual(@as(usize, 16), TexelFormat.bc4.imageSize(5, 3));
}

test "imageSize: bc7 8x8 = 64 (four 16-byte blocks)" {
    try testing.expectEqual(@as(usize, 64), TexelFormat.bc7.imageSize(8, 8));
}

test "isBlockCompressed" {
    try testing.expect(!TexelFormat.rgba8.isBlockCompressed());
    try testing.expect(TexelFormat.bc4.isBlockCompressed());
    try testing.expect(TexelFormat.bc7.isBlockCompressed());
}

test "cookMip: rgba8 preserves all channels" {
    const alloc = testing.allocator;
    var pixels = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const src = RawTexture{ .width = 2, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .color_srgb };

    const mip = try cookMip(alloc, &src, .rgba8);
    defer alloc.free(mip.data);

    try testing.expectEqualSlices(u8, &pixels, mip.data);
}

test "cookMip: rgba8 expands compact LDR channels" {
    const alloc = testing.allocator;

    var single_pixels = [_]u8{ 10, 40 };
    const single = RawTexture{ .width = 2, .height = 1, .channels = 1, .pixels = .{ .ldr = &single_pixels }, .class = .single_linear };
    const single_mip = try cookMip(alloc, &single, .rgba8);
    defer alloc.free(single_mip.data);
    try testing.expectEqualSlices(u8, &.{ 10, 10, 10, 255, 40, 40, 40, 255 }, single_mip.data);

    var normal_pixels = [_]u8{ 128, 129, 255 };
    const normal = RawTexture{ .width = 1, .height = 1, .channels = 3, .pixels = .{ .ldr = &normal_pixels }, .class = .normal_linear };
    const normal_mip = try cookMip(alloc, &normal, .rgba8);
    defer alloc.free(normal_mip.data);
    try testing.expectEqualSlices(u8, &.{ 128, 129, 255, 255 }, normal_mip.data);
}

test "cookMip: rg8 extracts R and G" {
    const alloc = testing.allocator;
    var pixels = [_]u8{ 100, 200, 255, 255, 50, 150, 255, 255 };
    const src = RawTexture{ .width = 2, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .normal_linear };

    const mip = try cookMip(alloc, &src, .rg8);
    defer alloc.free(mip.data);

    try testing.expectEqualSlices(u8, &.{ 100, 200, 50, 150 }, mip.data);
}

test "cookMip: r8 extracts red only" {
    const alloc = testing.allocator;
    var pixels = [_]u8{ 77, 0, 0, 255, 88, 0, 0, 255 };
    const src = RawTexture{ .width = 2, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .single_linear };

    const mip = try cookMip(alloc, &src, .r8);
    defer alloc.free(mip.data);

    try testing.expectEqualSlices(u8, &.{ 77, 88 }, mip.data);
}

test "cookMip: rgb16f converts f32 to little-endian f16" {
    const alloc = testing.allocator;
    var pixels = [_]f32{ 1.0, 2.0, 4.0, 0.5, 0.25, 0.125 };
    const src = RawTexture{ .width = 2, .height = 1, .channels = 3, .pixels = .{ .hdr = &pixels }, .class = .hdr_linear };

    const mip = try cookMip(alloc, &src, .rgb16f);
    defer alloc.free(mip.data);

    try testing.expectEqual(@as(usize, 2 * 6), mip.data.len);

    // Read back each f16 and confirm it matches the f32 input (within f16 precision).
    for (0..pixels.len) |i| {
        const bits = std.mem.readInt(u16, mip.data[i * 2 ..][0..2], .little);
        const half: f16 = @bitCast(bits);
        try testing.expectApproxEqAbs(pixels[i], @as(f32, half), 0.001);
    }
}

test "CookedTexture.cook: preserves dimensions and picks color_space" {
    const alloc = testing.allocator;
    var raw = try makeUniformRaw(alloc, 4, 4, .color_srgb, 128);
    defer raw.deinit(alloc);

    var cooked = try CookedTexture.cook(alloc, &raw, .desktop);
    defer cooked.deinit(alloc);

    try testing.expectEqual(@as(u32, 4), cooked.width);
    try testing.expectEqual(@as(u32, 4), cooked.height);
    try testing.expectEqual(ColorSpace.srgb, cooked.color_space);
    try testing.expectEqual(TexelFormat.bc7, cooked.format);
}

test "CookedTexture.cook: produces full mip chain" {
    const alloc = testing.allocator;
    var raw = try makeUniformRaw(alloc, 4, 4, .single_linear, 100);
    defer raw.deinit(alloc);

    var cooked = try CookedTexture.cook(alloc, &raw, .desktop);
    defer cooked.deinit(alloc);

    // log2(4) + 1 = 3 levels: 4x4, 2x2, 1x1
    try testing.expectEqual(@as(usize, 3), cooked.mips.len);
    try testing.expectEqual(@as(u32, 4), cooked.mips[0].width);
    try testing.expectEqual(@as(u32, 2), cooked.mips[1].width);
    try testing.expectEqual(@as(u32, 1), cooked.mips[2].width);
}

test "CookedTexture.cook: normal_linear produces BC5 mips" {
    const alloc = testing.allocator;
    // Pixel (128, 128, 255) → signed normal (0, 0, 1)
    const pixel_count: usize = 4 * 4;
    const pixels = try alloc.alloc(u8, pixel_count * 3);
    for (0..pixel_count) |i| {
        pixels[i * 3 + 0] = 128;
        pixels[i * 3 + 1] = 128;
        pixels[i * 3 + 2] = 255;
    }
    var raw = RawTexture{ .width = 4, .height = 4, .channels = 3, .pixels = .{ .ldr = pixels }, .class = .normal_linear, .owner = .allocator };
    defer raw.deinit(alloc);

    var cooked = try CookedTexture.cook(alloc, &raw, .desktop);
    defer cooked.deinit(alloc);

    try testing.expectEqual(TexelFormat.bc5, cooked.format);
    try testing.expectEqual(ColorSpace.linear, cooked.color_space);

    // Each mip is one BC5 block (2 × 8-byte BC4 halves = 16 bytes) since dims collapse to ≤4x4.
    for (cooked.mips) |mip| {
        try testing.expectEqual(@as(usize, 16), mip.data.len);
    }

    // On a uniform (128, 128) block, BC4 endpoints both equal 128 and selectors are all zero.
    const top = cooked.mips[0];
    try testing.expectEqual(@as(u8, 128), top.data[0]); // R red0
    try testing.expectEqual(@as(u8, 128), top.data[1]); // R red1
    try testing.expectEqual(@as(u8, 128), top.data[8]); // G red0
    try testing.expectEqual(@as(u8, 128), top.data[9]); // G red1
}

test "CookedTexture.cook: single_linear produces BC4 mips" {
    const alloc = testing.allocator;
    var raw = try makeUniformRaw(alloc, 4, 4, .single_linear, 77);
    defer raw.deinit(alloc);

    var cooked = try CookedTexture.cook(alloc, &raw, .desktop);
    defer cooked.deinit(alloc);

    try testing.expectEqual(TexelFormat.bc4, cooked.format);
    // Each mip is one 4x4 block = 8 bytes (sub-4 mips round up).
    for (cooked.mips) |mip| {
        try testing.expectEqual(@as(usize, 8), mip.data.len);
        // Uniform input → endpoints equal the source value, selectors all zero.
        try testing.expectEqual(@as(u8, 77), mip.data[0]);
        try testing.expectEqual(@as(u8, 77), mip.data[1]);
        for (mip.data[2..8]) |b| try testing.expectEqual(@as(u8, 0), b);
    }
}

test "CookedTexture.cook: compact single-channel source produces BC4 mips" {
    const alloc = testing.allocator;
    const pixels = try alloc.alloc(u8, 4 * 4);
    @memset(pixels, 91);
    var raw = RawTexture{ .width = 4, .height = 4, .channels = 1, .pixels = .{ .ldr = pixels }, .class = .single_linear, .owner = .allocator };
    defer raw.deinit(alloc);

    var cooked = try CookedTexture.cook(alloc, &raw, .desktop);
    defer cooked.deinit(alloc);

    try testing.expectEqual(TexelFormat.bc4, cooked.format);
    for (cooked.mips) |mip| {
        try testing.expectEqual(@as(u8, 91), mip.data[0]);
        try testing.expectEqual(@as(u8, 91), mip.data[1]);
    }
}

test "CookedTexture.cook: gl41 picks BC1 for opaque color and BC3 once any texel has alpha" {
    const alloc = testing.allocator;
    var raw = try makeUniformRaw(alloc, 8, 8, .color_srgb, 255);
    defer raw.deinit(alloc);

    var opaque_cooked = try CookedTexture.cook(alloc, &raw, .gl41);
    defer opaque_cooked.deinit(alloc);
    try testing.expectEqual(TexelFormat.bc1, opaque_cooked.format);
    try testing.expectEqual(@as(usize, 4 * 8), opaque_cooked.mips[0].data.len);

    raw.pixels.ldr[7] = 0; // alpha of texel 1
    var alpha_cooked = try CookedTexture.cook(alloc, &raw, .gl41);
    defer alpha_cooked.deinit(alloc);
    try testing.expectEqual(TexelFormat.bc3, alpha_cooked.format);
    try testing.expectEqual(@as(usize, 4 * 16), alpha_cooked.mips[0].data.len);
    // Alpha endpoints of the first block span the transparent texel.
    try testing.expectEqual(@as(u8, 255), alpha_cooked.mips[0].data[0]);
    try testing.expectEqual(@as(u8, 0), alpha_cooked.mips[0].data[1]);
}

test "CookedTexture.cook: gl41 packs HDR as RGB9_E5" {
    const alloc = testing.allocator;
    var raw = try makeUniformRawHdr(alloc, 2, 2, .{ 4.0, 1.0, 0.25 });
    defer raw.deinit(alloc);

    var cooked = try CookedTexture.cook(alloc, &raw, .gl41);
    defer cooked.deinit(alloc);

    try testing.expectEqual(TexelFormat.rgb9e5, cooked.format);
    try testing.expectEqual(@as(usize, 2 * 2 * 4), cooked.mips[0].data.len);
    const texel = std.mem.readInt(u32, cooked.mips[0].data[0..4], .little);
    try testing.expectEqual([3]f32{ 4.0, 1.0, 0.25 }, rgb9e5.unpack(texel));
}

test "cookMip: rgb9e5 packs each texel little-endian" {
    const alloc = testing.allocator;
    var pixels = [_]f32{ 1.0, 0.5, 0.0, 0.0, 0.0, 2.0 };
    const src = RawTexture{ .width = 2, .height = 1, .channels = 3, .pixels = .{ .hdr = &pixels }, .class = .hdr_linear };

    const mip = try cookMip(alloc, &src, .rgb9e5);
    defer alloc.free(mip.data);

    try testing.expectEqual(@as(usize, 8), mip.data.len);
    try testing.expectEqual([3]f32{ 1.0, 0.5, 0.0 }, rgb9e5.unpack(std.mem.readInt(u32, mip.data[0..4], .little)));
    try testing.expectEqual([3]f32{ 0.0, 0.0, 2.0 }, rgb9e5.unpack(std.mem.readInt(u32, mip.data[4..8], .little)));
}

test "imageSize: bc1 is 8 bytes and bc3 16 bytes per block; rgb9e5 is 4 bytes per texel" {
    try testing.expectEqual(@as(usize, 8), TexelFormat.bc1.imageSize(1, 1));
    try testing.expectEqual(@as(usize, 64), TexelFormat.bc3.imageSize(8, 8));
    try testing.expectEqual(@as(usize, 60), TexelFormat.rgb9e5.imageSize(3, 5));
}
