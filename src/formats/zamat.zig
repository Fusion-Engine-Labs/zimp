const std = @import("std");

const constants = @import("../shared/constants.zig");
const cooked_material = @import("../assets/cooked/material.zig");
const raw_material = @import("../assets/raw/material.zig");
const wire = @import("../shared/wire.zig");
const ids = @import("../id/id_types.zig");

pub const MAGIC = constants.FORMAT_MAGIC.ZAMAT;
pub const ZAMAT_VERSION: u32 = 6;

pub const AlphaMode = cooked_material.AlphaMode;
pub const CullMode = cooked_material.CullMode;
pub const BlendMode = cooked_material.BlendMode;
pub const FilterMode = cooked_material.FilterMode;
pub const MipFilterMode = cooked_material.MipFilterMode;
pub const WrapMode = cooked_material.WrapMode;
pub const SamplerDesc = cooked_material.SamplerDesc;
pub const RenderState = cooked_material.RenderState;
pub const ParamType = cooked_material.ParamType;
pub const ParamValue = cooked_material.ParamValue;
pub const CookedMaterial = cooked_material.CookedMaterial;

pub const max_texture_slots = 32;
pub const max_params = 64;
pub const max_variants = 64;

/// Accepted `max_anisotropy` range. GL rejects values below 1; the runtime
/// clamps to the hardware limit.
pub const min_anisotropy: f32 = 1;
pub const max_anisotropy: f32 = 16;

const render_flag_double_sided: u8 = 0x1;
const render_flag_depth_test: u8 = 0x2;
const render_flag_depth_write: u8 = 0x4;

/// File layout: `Header`, then `[texture_slot_count]TextureSlot`,
/// `[param_count]Param`, and `[variant_count]u64` variant name hashes, back to
/// back. Header, slot, and param sizes are multiples of 16, so every table is
/// aligned and the file size follows from the counts alone. Names exist only
/// as `wire.nameHash`es, and each table is sorted by hash without duplicates.
pub const Header = extern struct {
    file: wire.FileHeader,
    vertex_shader: wire.AssetRef,
    fragment_shader: wire.AssetRef,
    alpha_cutoff: f32,
    alpha_mode: u8,
    cull_mode: u8,
    blend_mode: u8,
    render_flags: u8,
    texture_slot_count: u8,
    param_count: u8,
    variant_count: u8,
    _reserved0: u8 = 0,
    _reserved1: u32 = 0,
};

pub const TextureSlot = extern struct {
    texture: wire.AssetRef,
    /// `wire.nameHash` of the sampler uniform.
    name_hash: u64,
    /// `Sampler` bits.
    sampler: u32,
    uv_set: u16,
    _reserved0: u16 = 0,
    uv_offset: [2]f32,
    uv_scale: [2]f32,
    uv_rotation: f32,
    normal_scale: f32,
    occlusion_strength: f32,
    _reserved1: u32 = 0,
};

pub const Param = extern struct {
    /// `wire.nameHash` of the uniform.
    name_hash: u64,
    param_type: u32,
    _reserved: u32 = 0,
    /// f32 bits, an i32, or 0/1 for bool; lanes past the type's width are zero.
    value: [4]u32,
};

/// Sampler state packed into `TextureSlot.sampler`.
pub const Sampler = packed struct(u32) {
    min_filter: u1,
    mag_filter: u1,
    mip_filter: u2,
    wrap_s: u2,
    wrap_t: u2,
    _reserved: u8 = 0,
    max_anisotropy: f16,
};

comptime {
    wire.assertTightLayout(Header);
    wire.assertTightLayout(TextureSlot);
    wire.assertTightLayout(Param);
    std.debug.assert(@sizeOf(Header) % wire.section_alignment == 0);
    std.debug.assert(@sizeOf(TextureSlot) % wire.section_alignment == 0);
    std.debug.assert(@sizeOf(Param) % wire.section_alignment == 0);
}

pub const HEADER_SIZE: u32 = @sizeOf(Header);

/// Exact size of a file with these table lengths.
pub fn fileSize(texture_slots: usize, params: usize, variants: usize) usize {
    return HEADER_SIZE + texture_slots * @sizeOf(TextureSlot) + params * @sizeOf(Param) + variants * @sizeOf(u64);
}

pub const TextureSlotView = struct {
    name_hash: u64,
    texture: ids.AssetId,
    uv_set: u16,
    sampler: SamplerDesc,
    uv_offset: [2]f32,
    uv_scale: [2]f32,
    uv_rotation: f32,
    normal_scale: f32,
    occlusion_strength: f32,
};

pub const ParamView = struct {
    name_hash: u64,
    value: ParamValue,
};

/// Zero-copy view of a cooked material. Borrows the bytes it was created from.
pub const Zamat = struct {
    vertex_shader: ids.AssetId,
    fragment_shader: ids.AssetId,
    render_state: RenderState,
    texture_slots: []const TextureSlot,
    params: []const Param,
    /// Sorted `wire.nameHash`es of the shader variants this material enables.
    variant_hashes: []const u64,

    pub fn view(bytes: wire.Bytes) !Zamat {
        _ = try wire.FileHeader.validate(bytes, MAGIC, ZAMAT_VERSION);
        const header = try wire.structAt(Header, bytes, 0);
        const render_state = try checkHeader(header);
        if (bytes.len != fileSize(header.texture_slot_count, header.param_count, header.variant_count))
            return error.InvalidLayout;

        const params_offset = fileSize(header.texture_slot_count, 0, 0);
        const variants_offset = fileSize(header.texture_slot_count, header.param_count, 0);
        const texture_slots = try wire.sliceAt(TextureSlot, bytes, HEADER_SIZE, header.texture_slot_count);
        const params = try wire.sliceAt(Param, bytes, params_offset, header.param_count);
        const variant_hashes = try wire.sliceAt(u64, bytes, variants_offset, header.variant_count);
        try checkTables(texture_slots, params, variant_hashes);

        return .{
            .vertex_shader = header.vertex_shader.toId(),
            .fragment_shader = header.fragment_shader.toId(),
            .render_state = render_state,
            .texture_slots = texture_slots,
            .params = params,
            .variant_hashes = variant_hashes,
        };
    }

    pub fn textureSlot(self: *const Zamat, index: usize) TextureSlotView {
        const slot = &self.texture_slots[index];
        return .{
            .name_hash = slot.name_hash,
            .texture = slot.texture.toId(),
            .uv_set = slot.uv_set,
            .sampler = decodeSampler(slot.sampler) catch unreachable, // validated in `view`
            .uv_offset = slot.uv_offset,
            .uv_scale = slot.uv_scale,
            .uv_rotation = slot.uv_rotation,
            .normal_scale = slot.normal_scale,
            .occlusion_strength = slot.occlusion_strength,
        };
    }

    pub fn param(self: *const Zamat, index: usize) ParamView {
        const p = &self.params[index];
        return .{
            .name_hash = p.name_hash,
            .value = decodeParam(p.*) catch unreachable, // validated in `view`
        };
    }
};

pub fn view(bytes: wire.Bytes) !Zamat {
    return Zamat.view(bytes);
}

// Shared by `view` and `write`, so the writer can't emit a file `view` rejects.

fn checkHeader(header: *const Header) !RenderState {
    if (header._reserved0 != 0 or header._reserved1 != 0) return error.InvalidReserved;
    if (header.texture_slot_count > max_texture_slots) return error.TooManyTextureSlots;
    if (header.param_count > max_params) return error.TooManyParams;
    if (header.variant_count > max_variants) return error.TooManyVariants;
    if (header.render_flags & ~(render_flag_double_sided | render_flag_depth_test | render_flag_depth_write) != 0)
        return error.InvalidRenderFlags;
    try header.vertex_shader.check();
    try header.fragment_shader.check();
    return .{
        .alpha_mode = try wire.enumFromInt(AlphaMode, header.alpha_mode),
        .alpha_cutoff = header.alpha_cutoff,
        .double_sided = header.render_flags & render_flag_double_sided != 0,
        .depth_test = header.render_flags & render_flag_depth_test != 0,
        .depth_write = header.render_flags & render_flag_depth_write != 0,
        .cull_mode = try wire.enumFromInt(CullMode, header.cull_mode),
        .blend_mode = try wire.enumFromInt(BlendMode, header.blend_mode),
    };
}

fn checkTables(texture_slots: []const TextureSlot, params: []const Param, variant_hashes: []const u64) !void {
    for (texture_slots, 0..) |slot, i| {
        if (slot._reserved0 != 0 or slot._reserved1 != 0) return error.InvalidReserved;
        if (i > 0 and slot.name_hash <= texture_slots[i - 1].name_hash) return error.UnsortedNameHashes;
        try slot.texture.check();
        _ = try decodeSampler(slot.sampler);
    }
    for (params, 0..) |p, i| {
        if (i > 0 and p.name_hash <= params[i - 1].name_hash) return error.UnsortedNameHashes;
        _ = try decodeParam(p);
    }
    for (variant_hashes, 0..) |hash, i| {
        if (i > 0 and hash <= variant_hashes[i - 1]) return error.UnsortedNameHashes;
    }
}

fn encodeSampler(desc: SamplerDesc) !u32 {
    // Also rejects NaN.
    if (!(desc.max_anisotropy >= min_anisotropy and desc.max_anisotropy <= max_anisotropy))
        return error.InvalidMaxAnisotropy;
    return @bitCast(Sampler{
        .min_filter = @intCast(@intFromEnum(desc.min_filter)),
        .mag_filter = @intCast(@intFromEnum(desc.mag_filter)),
        .mip_filter = @intCast(@intFromEnum(desc.mip_filter)),
        .wrap_s = @intCast(@intFromEnum(desc.wrap_s)),
        .wrap_t = @intCast(@intFromEnum(desc.wrap_t)),
        .max_anisotropy = @floatCast(desc.max_anisotropy),
    });
}

fn decodeSampler(bits: u32) !SamplerDesc {
    const sampler: Sampler = @bitCast(bits);
    if (sampler._reserved != 0) return error.InvalidReserved;
    const anisotropy: f32 = sampler.max_anisotropy;
    if (!(anisotropy >= min_anisotropy and anisotropy <= max_anisotropy)) return error.InvalidMaxAnisotropy;
    return .{
        .min_filter = try wire.enumFromInt(FilterMode, sampler.min_filter),
        .mag_filter = try wire.enumFromInt(FilterMode, sampler.mag_filter),
        .mip_filter = try wire.enumFromInt(MipFilterMode, sampler.mip_filter),
        .wrap_s = try wire.enumFromInt(WrapMode, sampler.wrap_s),
        .wrap_t = try wire.enumFromInt(WrapMode, sampler.wrap_t),
        .max_anisotropy = anisotropy,
    };
}

fn encodeParam(entry: cooked_material.ParamEntry) Param {
    var lanes: [4]u32 = @splat(0);
    const param_type: ParamType = switch (entry.value) {
        .float => |v| blk: {
            lanes[0] = @bitCast(v);
            break :blk .float;
        },
        .vec2 => |v| blk: {
            for (v, 0..) |c, i| lanes[i] = @bitCast(c);
            break :blk .vec2;
        },
        .vec3 => |v| blk: {
            for (v, 0..) |c, i| lanes[i] = @bitCast(c);
            break :blk .vec3;
        },
        .vec4 => |v| blk: {
            for (v, 0..) |c, i| lanes[i] = @bitCast(c);
            break :blk .vec4;
        },
        .int => |v| blk: {
            lanes[0] = @bitCast(v);
            break :blk .int;
        },
        .bool => |v| blk: {
            lanes[0] = @intFromBool(v);
            break :blk .bool;
        },
    };
    return .{ .name_hash = entry.name_hash, .param_type = @intFromEnum(param_type), .value = lanes };
}

fn decodeParam(p: Param) !ParamValue {
    if (p._reserved != 0) return error.InvalidReserved;
    const lanes = p.value;
    const param_type = try wire.enumFromInt(ParamType, p.param_type);
    const width: usize = switch (param_type) {
        .float, .int, .bool => 1,
        .vec2 => 2,
        .vec3 => 3,
        .vec4 => 4,
    };
    for (lanes[width..]) |lane| if (lane != 0) return error.InvalidParamValue;
    return switch (param_type) {
        .float => .{ .float = @bitCast(lanes[0]) },
        .vec2 => .{ .vec2 = .{ @bitCast(lanes[0]), @bitCast(lanes[1]) } },
        .vec3 => .{ .vec3 = .{ @bitCast(lanes[0]), @bitCast(lanes[1]), @bitCast(lanes[2]) } },
        .vec4 => .{ .vec4 = @bitCast(lanes) },
        .int => .{ .int = @bitCast(lanes[0]) },
        .bool => .{ .bool = switch (lanes[0]) {
            0 => false,
            1 => true,
            else => return error.InvalidParamValue,
        } },
    };
}

pub fn write(writer: *std.Io.Writer, material: CookedMaterial) !void {
    if (material.texture_slots.len > max_texture_slots) return error.TooManyTextureSlots;
    if (material.params.len > max_params) return error.TooManyParams;
    if (material.variant_hashes.len > max_variants) return error.TooManyVariants;

    var slot_buf: [max_texture_slots]TextureSlot = undefined;
    const texture_slots = slot_buf[0..material.texture_slots.len];
    for (material.texture_slots, texture_slots) |entry, *slot| {
        slot.* = .{
            .texture = .fromId(entry.texture),
            .name_hash = entry.name_hash,
            .sampler = try encodeSampler(entry.sampler),
            .uv_set = entry.uv_set,
            .uv_offset = entry.uv_offset,
            .uv_scale = entry.uv_scale,
            .uv_rotation = entry.uv_rotation,
            .normal_scale = entry.normal_scale,
            .occlusion_strength = entry.occlusion_strength,
        };
    }
    var param_buf: [max_params]Param = undefined;
    const params = param_buf[0..material.params.len];
    for (material.params, params) |entry, *p| p.* = encodeParam(entry);

    const state = material.render_state;
    var render_flags: u8 = 0;
    if (state.double_sided) render_flags |= render_flag_double_sided;
    if (state.depth_test) render_flags |= render_flag_depth_test;
    if (state.depth_write) render_flags |= render_flag_depth_write;

    const header: Header = .{
        .file = .init(MAGIC, ZAMAT_VERSION, @intCast(fileSize(texture_slots.len, params.len, material.variant_hashes.len))),
        .vertex_shader = .fromId(material.vertex_shader),
        .fragment_shader = .fromId(material.fragment_shader),
        .alpha_cutoff = state.alpha_cutoff,
        .alpha_mode = @intCast(@intFromEnum(state.alpha_mode)),
        .cull_mode = @intCast(@intFromEnum(state.cull_mode)),
        .blend_mode = @intCast(@intFromEnum(state.blend_mode)),
        .render_flags = render_flags,
        .texture_slot_count = @intCast(texture_slots.len),
        .param_count = @intCast(params.len),
        .variant_count = @intCast(material.variant_hashes.len),
    };
    _ = try checkHeader(&header);
    try checkTables(texture_slots, params, material.variant_hashes);

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(std.mem.sliceAsBytes(texture_slots));
    try writer.writeAll(std.mem.sliceAsBytes(params));
    try writer.writeAll(std.mem.sliceAsBytes(material.variant_hashes));
}

pub fn writeZamat(writer: *std.Io.Writer, material_source: raw_material.MaterialSource, project_id: ids.ProjectId, allocator: std.mem.Allocator) !void {
    var cooked = try CookedMaterial.cook(allocator, &material_source, project_id);
    defer cooked.deinit(allocator);
    try write(writer, cooked);
}

const testing = std.testing;
const derive = @import("../manifest/derive.zig");
const test_project = ids.ProjectId.parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc");

fn cookedFromSource(source_text: []const u8) !CookedMaterial {
    var parsed = try raw_material.parseMaterialSource(source_text, testing.allocator);
    defer parsed.deinit(testing.allocator);
    return CookedMaterial.cook(testing.allocator, &parsed, test_project);
}

fn writeToBuffer(buf: []align(wire.section_alignment) u8, cooked: CookedMaterial) !wire.Bytes {
    var writer = std.Io.Writer.fixed(buf);
    try write(&writer, cooked);
    return buf[0..writer.end];
}

fn findParam(material: *const Zamat, name: []const u8) ?ParamValue {
    for (0..material.params.len) |i| {
        const p = material.param(i);
        if (p.name_hash == wire.nameHash(name)) return p.value;
    }
    return null;
}

test "on-disk struct sizes" {
    try testing.expectEqual(@as(u32, 64), HEADER_SIZE);
    try testing.expectEqual(@as(usize, 64), @sizeOf(TextureSlot));
    try testing.expectEqual(@as(usize, 32), @sizeOf(Param));
}

test "Zamat write lays out tables back to back" {
    var cooked = try cookedFromSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[texture.u_albedo]
        \\path = "textures/test_albedo.png"
        \\[texture.u_normal_map]
        \\path = "textures/test_normal.png"
        \\[params]
        \\u_roughness = 0.5
        \\u_light_dir = [0.5, 1.0, 0.3]
        \\u_light_color = [1.0, 0.95, 0.9]
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeToBuffer(&buf, cooked);

    try testing.expectEqualSlices(u8, MAGIC, bytes[0..4]);
    try testing.expectEqual(fileSize(2, 3, 0), bytes.len);
    const header = try wire.structAt(Header, bytes, 0);
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), header.file.total_size);
    try testing.expectEqual(@as(u8, 2), header.texture_slot_count);
    try testing.expectEqual(@as(u8, 3), header.param_count);
}

test "Zamat write and view round trips" {
    var cooked = try cookedFromSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[render_state]
        \\alpha_mode = "alpha_test"
        \\[texture.u_albedo]
        \\path = "textures/test_albedo.png"
        \\[params]
        \\u_enabled = true
        \\u_mode = -2
        \\u_roughness = 0.5
        \\u_uv = [2.0, 3.0]
        \\u_tint = [1.0, 0.5, 0.25]
        \\u_color = [0.1, 0.2, 0.3, 0.4]
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const loaded = try Zamat.view(try writeToBuffer(&buf, cooked));

    try testing.expect(loaded.vertex_shader.eql(derive.assetIdForPath(test_project, "shaders/basic.vert")));
    try testing.expect(loaded.fragment_shader.eql(derive.assetIdForPath(test_project, "shaders/basic.frag")));
    try testing.expectEqual(AlphaMode.alpha_test, loaded.render_state.alpha_mode);
    try testing.expectEqual(@as(usize, 1), loaded.texture_slots.len);
    const tex = loaded.textureSlot(0);
    try testing.expectEqual(wire.nameHash("u_albedo"), tex.name_hash);
    try testing.expect(tex.texture.eql(derive.assetIdForPath(test_project, "textures/test_albedo.png")));

    try testing.expectEqual(@as(usize, 6), loaded.params.len);
    try testing.expectEqual(true, findParam(&loaded, "u_enabled").?.bool);
    try testing.expectEqual(@as(i32, -2), findParam(&loaded, "u_mode").?.int);
    try testing.expectEqual(@as(f32, 0.5), findParam(&loaded, "u_roughness").?.float);
    try testing.expectEqual([2]f32{ 2.0, 3.0 }, findParam(&loaded, "u_uv").?.vec2);
    try testing.expectEqual([3]f32{ 1.0, 0.5, 0.25 }, findParam(&loaded, "u_tint").?.vec3);
    try testing.expectEqual([4]f32{ 0.1, 0.2, 0.3, 0.4 }, findParam(&loaded, "u_color").?.vec4);
    try testing.expectEqual(@as(?ParamValue, null), findParam(&loaded, "u_missing"));
}

test "Zamat round trips render state and sampler metadata" {
    var cooked = try cookedFromSource(
        \\[material]
        \\shader = "shaders/pbr"
        \\[render_state]
        \\alpha_mode = "alpha_blend"
        \\alpha_cutoff = 0.42
        \\double_sided = true
        \\depth_test = false
        \\depth_write = false
        \\blend_mode = "alpha"
        \\[texture.u_normal_map]
        \\path = "textures/test_normal.png"
        \\uv_set = 1
        \\uv_offset = [0.1, 0.2]
        \\uv_scale = [3.0, 4.0]
        \\uv_rotation = 0.5
        \\min_filter = "nearest"
        \\mag_filter = "linear"
        \\mip_filter = "nearest"
        \\wrap_s = "clamp_to_edge"
        \\wrap_t = "mirrored_repeat"
        \\max_anisotropy = 4
        \\normal_scale = 0.8
        \\occlusion_strength = 0.6
        \\[params]
        \\u_roughness = 0.5
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const loaded = try Zamat.view(try writeToBuffer(&buf, cooked));

    try testing.expectEqual(AlphaMode.alpha_blend, loaded.render_state.alpha_mode);
    try testing.expectEqual(@as(f32, 0.42), loaded.render_state.alpha_cutoff);
    try testing.expect(loaded.render_state.double_sided);
    try testing.expect(!loaded.render_state.depth_test);
    try testing.expect(!loaded.render_state.depth_write);
    try testing.expectEqual(BlendMode.alpha, loaded.render_state.blend_mode);

    const tex = loaded.textureSlot(0);
    try testing.expectEqual(wire.nameHash("u_normal_map"), tex.name_hash);
    try testing.expectEqual(@as(u16, 1), tex.uv_set);
    try testing.expectEqual([2]f32{ 0.1, 0.2 }, tex.uv_offset);
    try testing.expectEqual([2]f32{ 3.0, 4.0 }, tex.uv_scale);
    try testing.expectEqual(@as(f32, 0.5), tex.uv_rotation);
    try testing.expectEqual(FilterMode.nearest, tex.sampler.min_filter);
    try testing.expectEqual(FilterMode.linear, tex.sampler.mag_filter);
    try testing.expectEqual(MipFilterMode.nearest, tex.sampler.mip_filter);
    try testing.expectEqual(WrapMode.clamp_to_edge, tex.sampler.wrap_s);
    try testing.expectEqual(WrapMode.mirrored_repeat, tex.sampler.wrap_t);
    try testing.expectEqual(@as(f32, 4), tex.sampler.max_anisotropy);
    try testing.expectEqual(@as(f32, 0.8), tex.normal_scale);
    try testing.expectEqual(@as(f32, 0.6), tex.occlusion_strength);
}

test "Zamat write rejects out-of-range anisotropy" {
    for ([_][]const u8{ "0.5", "17", "nan" }) |value| {
        var source_buf: [256]u8 = undefined;
        var cooked = try cookedFromSource(try std.fmt.bufPrint(&source_buf,
            \\[material]
            \\shader = "shaders/basic"
            \\[texture.u_albedo]
            \\path = "textures/a.png"
            \\max_anisotropy = {s}
            \\
        , .{value}));
        defer cooked.deinit(testing.allocator);
        var buf: [512]u8 align(wire.section_alignment) = undefined;
        try testing.expectError(error.InvalidMaxAnisotropy, writeToBuffer(&buf, cooked));
    }
}

test "Zamat round trips required shader variants as sorted hashes" {
    var parsed = try raw_material.parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\
    , testing.allocator);
    defer parsed.deinit(testing.allocator);
    const variants = [_][]const u8{ "HAS_NORMAL_MAP", "ALPHA_TEST" };
    parsed.required_variants = &variants;
    defer parsed.required_variants = &.{};

    var cooked = try CookedMaterial.cook(testing.allocator, &parsed, test_project);
    defer cooked.deinit(testing.allocator);

    var buf: [512]u8 align(wire.section_alignment) = undefined;
    const loaded = try Zamat.view(try writeToBuffer(&buf, cooked));

    var expected = [_]u64{ wire.nameHash("HAS_NORMAL_MAP"), wire.nameHash("ALPHA_TEST") };
    std.mem.sort(u64, &expected, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, &expected, loaded.variant_hashes);
}

test "Zamat resolves builtin shader references to builtin ids" {
    var cooked = try cookedFromSource(
        \\[material]
        \\shader = "fusion/standard"
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const loaded = try Zamat.view(try writeToBuffer(&buf, cooked));
    const builtin_registry = @import("../builtin/registry.zig");
    try testing.expect(loaded.vertex_shader.eql(builtin_registry.idFor("fusion/standard.vert")));
    try testing.expect(loaded.fragment_shader.eql(builtin_registry.idFor("fusion/standard.frag")));
}

test "Zamat supports empty texture and param tables" {
    var cooked = try cookedFromSource(
        \\[material]
        \\shader = "shaders/basic"
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeToBuffer(&buf, cooked);
    try testing.expectEqual(@as(usize, HEADER_SIZE), bytes.len);

    const loaded = try Zamat.view(bytes);
    try testing.expectEqual(@as(usize, 0), loaded.texture_slots.len);
    try testing.expectEqual(@as(usize, 0), loaded.params.len);
    try testing.expectEqual(@as(usize, 0), loaded.variant_hashes.len);
}

fn writeCorruptionFixture(buf: []align(wire.section_alignment) u8) !usize {
    var parsed = try raw_material.parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[render_state]
        \\alpha_mode = "alpha_test"
        \\[texture.u_albedo]
        \\path = "textures/test_albedo.png"
        \\max_anisotropy = 8
        \\[texture.u_normal_map]
        \\path = "textures/test_normal.png"
        \\[params]
        \\u_roughness = 0.5
        \\u_enabled = true
        \\u_tint = [1.0, 0.5, 0.25]
        \\
    , testing.allocator);
    defer parsed.deinit(testing.allocator);
    const variants = [_][]const u8{ "HAS_NORMAL_MAP", "ALPHA_TEST" };
    parsed.required_variants = &variants;
    defer parsed.required_variants = &.{};

    var cooked = try CookedMaterial.cook(testing.allocator, &parsed, test_project);
    defer cooked.deinit(testing.allocator);
    return (try writeToBuffer(buf, cooked)).len;
}

test "Zamat.view rejects corrupted files" {
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const len = try writeCorruptionFixture(&buf);
    const header: *Header = @ptrCast(&buf);
    const slots: [*]TextureSlot = @ptrCast(@alignCast(buf[HEADER_SIZE..].ptr));
    const params: [*]Param = @ptrCast(@alignCast(buf[fileSize(2, 0, 0)..].ptr));
    const variants: [*]u64 = @ptrCast(@alignCast(buf[fileSize(2, 3, 0)..].ptr));

    header.alpha_mode = 9;
    try testing.expectError(error.InvalidEnumValue, Zamat.view(buf[0..len]));
    header.alpha_mode = 1;
    header.render_flags = 0x80;
    try testing.expectError(error.InvalidRenderFlags, Zamat.view(buf[0..len]));
    header.render_flags = 0x6;
    header._reserved0 = 1;
    try testing.expectError(error.InvalidReserved, Zamat.view(buf[0..len]));
    header._reserved0 = 0;
    header.param_count = 2;
    try testing.expectError(error.InvalidLayout, Zamat.view(buf[0..len]));
    header.param_count = 3;

    const sampler = slots[0].sampler;
    var bits: Sampler = @bitCast(sampler);
    bits.wrap_s = 3;
    slots[0].sampler = @bitCast(bits);
    try testing.expectError(error.InvalidEnumValue, Zamat.view(buf[0..len]));
    bits = @bitCast(sampler);
    bits.max_anisotropy = 0.5;
    slots[0].sampler = @bitCast(bits);
    try testing.expectError(error.InvalidMaxAnisotropy, Zamat.view(buf[0..len]));
    bits = @bitCast(sampler);
    bits._reserved = 1;
    slots[0].sampler = @bitCast(bits);
    try testing.expectError(error.InvalidReserved, Zamat.view(buf[0..len]));
    slots[0].sampler = sampler;

    const texture = slots[0].texture;
    slots[0].texture = .{ .bytes = @splat(0) };
    try testing.expectError(error.ZeroAssetRef, Zamat.view(buf[0..len]));
    slots[0].texture = texture;
    const vertex_shader = header.vertex_shader;
    header.vertex_shader = .{ .bytes = @splat(0) };
    try testing.expectError(error.ZeroAssetRef, Zamat.view(buf[0..len]));
    header.vertex_shader = vertex_shader;

    std.mem.swap(TextureSlot, &slots[0], &slots[1]);
    try testing.expectError(error.UnsortedNameHashes, Zamat.view(buf[0..len]));
    std.mem.swap(TextureSlot, &slots[0], &slots[1]);
    const param_hash = params[1].name_hash;
    params[1].name_hash = params[0].name_hash;
    try testing.expectError(error.UnsortedNameHashes, Zamat.view(buf[0..len]));
    params[1].name_hash = param_hash;
    std.mem.swap(u64, &variants[0], &variants[1]);
    try testing.expectError(error.UnsortedNameHashes, Zamat.view(buf[0..len]));
    std.mem.swap(u64, &variants[0], &variants[1]);

    for (params[0..3]) |*p| {
        const saved = p.*;
        p.value[3] = 1; // unused by every fixture param type
        try testing.expectError(error.InvalidParamValue, Zamat.view(buf[0..len]));
        p.* = saved;
        p.param_type = 6;
        try testing.expectError(error.InvalidEnumValue, Zamat.view(buf[0..len]));
        p.* = saved;
        if (p.name_hash == wire.nameHash("u_enabled")) {
            p.value[0] = 2;
            try testing.expectError(error.InvalidParamValue, Zamat.view(buf[0..len]));
            p.* = saved;
        }
    }

    _ = try Zamat.view(buf[0..len]);
    try testing.expectError(error.InvalidFileSize, Zamat.view(buf[0 .. len - 1]));
}

test "Zamat.view rejects every truncation and survives every byte flip" {
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const len = try writeCorruptionFixture(&buf);
    for (0..len) |cut| try testing.expect(std.meta.isError(Zamat.view(buf[0..cut])));

    // Flipping a byte must either fail validation or leave a file whose
    // accessors all work (e.g. a changed float or AssetId byte).
    for (0..len) |offset| {
        for ([_]u8{ 0x01, 0x80, 0xff }) |mask| {
            buf[offset] ^= mask;
            defer buf[offset] ^= mask;
            const material = Zamat.view(buf[0..len]) catch continue;
            for (0..material.texture_slots.len) |i| _ = material.textureSlot(i);
            for (0..material.params.len) |i| _ = material.param(i);
        }
    }
    _ = try Zamat.view(buf[0..len]);
}
