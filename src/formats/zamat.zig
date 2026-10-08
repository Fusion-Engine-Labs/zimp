const std = @import("std");

const constants = @import("../shared/constants.zig");
const cooked_material = @import("../assets/cooked/material.zig");
const raw_material = @import("../assets/raw/material.zig");
const wire = @import("../shared/wire.zig");

pub const MAGIC = constants.FORMAT_MAGIC.ZAMAT;
pub const ZAMAT_VERSION: u32 = 4;

pub const AlphaMode = cooked_material.AlphaMode;
pub const CullMode = cooked_material.CullMode;
pub const BlendMode = cooked_material.BlendMode;
pub const FilterMode = cooked_material.FilterMode;
pub const MipFilterMode = cooked_material.MipFilterMode;
pub const WrapMode = cooked_material.WrapMode;
pub const SamplerDesc = cooked_material.SamplerDesc;
pub const RenderState = cooked_material.RenderState;
pub const ParamType = cooked_material.ParamType;
pub const CookedMaterial = cooked_material.CookedMaterial;

const max_texture_slots = 32;
const max_params = 64;
const max_variants = 64;

const render_flag_double_sided: u8 = 0x1;
const render_flag_depth_test: u8 = 0x2;
const render_flag_depth_write: u8 = 0x4;

/// File layout: `Header`, then aligned sections: the `TextureSlot` table, the
/// `Param` table, required-variant refs, the param data block, and one string
/// blob (param names, variant names, then runtime paths).
pub const Header = extern struct {
    file: wire.FileHeader,
    shader_path_hash: u64,
    vertex_shader_path: wire.Span,
    fragment_shader_path: wire.Span,
    alpha_cutoff: f32,
    alpha_mode: u8,
    cull_mode: u8,
    blend_mode: u8,
    render_flags: u8,
    texture_slot_count: u16,
    param_count: u16,
    variant_count: u16,
    _reserved: u16 = 0,
    texture_slots: wire.Span,
    params: wire.Span,
    variants: wire.Span,
    param_data: wire.Span,
    strings: wire.Span,
};

pub const TextureSlot = extern struct {
    slot_name_hash: u64,
    texture_path_hash: u64,
    slot_index: u16,
    uv_set: u16,
    min_filter: u8,
    mag_filter: u8,
    mip_filter: u8,
    wrap_s: u8,
    wrap_t: u8,
    _reserved0: u8 = 0,
    _reserved1: u16 = 0,
    max_anisotropy: f32,
    sampler_name: wire.Span,
    cooked_path: wire.Span,
    uv_offset: [2]f32,
    uv_scale: [2]f32,
    uv_rotation: f32,
    normal_scale: f32,
    occlusion_strength: f32,
    _reserved2: u32 = 0,
};

pub const Param = extern struct {
    name: wire.Span,
    /// Range inside the param data block.
    data: wire.Span,
    param_type: u16,
    _reserved: u16 = 0,
};

comptime {
    wire.assertTightLayout(Header);
    wire.assertTightLayout(TextureSlot);
    wire.assertTightLayout(Param);
}

pub const HEADER_SIZE: u32 = @sizeOf(Header);

/// Decoded texture slot. Strings point into the material file bytes.
pub const TextureSlotView = struct {
    slot_name_hash: u64,
    texture_path_hash: u64,
    slot_index: u16,
    uv_set: u16,
    sampler: SamplerDesc,
    sampler_name: []const u8,
    cooked_path: []const u8,
    uv_offset: [2]f32,
    uv_scale: [2]f32,
    uv_rotation: f32,
    normal_scale: f32,
    occlusion_strength: f32,
};

pub const ParamView = struct {
    name: []const u8,
    param_type: ParamType,
    data: []const u8,
};

/// Zero-copy view of a cooked material. Borrows the bytes it was created from.
pub const Zamat = struct {
    shader_path_hash: u64,
    vertex_shader_path: []const u8,
    fragment_shader_path: []const u8,
    render_state: RenderState,
    texture_slots: []const TextureSlot,
    params: []const Param,
    variant_refs: []const wire.Span,
    param_data: []const u8,
    strings: []const u8,

    pub fn view(bytes: wire.Bytes) !Zamat {
        _ = try wire.FileHeader.validate(bytes, MAGIC, ZAMAT_VERSION);
        const header = try wire.structAt(Header, bytes, 0);
        if (header.texture_slot_count > max_texture_slots) return error.TooManyTextureSlots;
        if (header.param_count > max_params) return error.TooManyParams;
        if (header.variant_count > max_variants) return error.TooManyVariants;
        if (header.render_flags & ~(render_flag_double_sided | render_flag_depth_test | render_flag_depth_write) != 0)
            return error.InvalidRenderFlags;

        var order = wire.SectionOrder.init(HEADER_SIZE);
        for ([_]wire.Span{ header.texture_slots, header.params, header.variants, header.param_data, header.strings }) |span| try order.next(span);

        const strings = try wire.sectionSlice(u8, bytes, header.strings, header.strings.len);
        const param_data = try wire.sectionSlice(u8, bytes, header.param_data, header.param_data.len);
        const texture_slots = try wire.sectionSlice(TextureSlot, bytes, header.texture_slots, header.texture_slot_count);
        const params = try wire.sectionSlice(Param, bytes, header.params, header.param_count);
        const variants = try wire.sectionSlice(wire.Span, bytes, header.variants, header.variant_count);

        try wire.checkString(strings, header.vertex_shader_path);
        try wire.checkString(strings, header.fragment_shader_path);
        for (texture_slots) |slot| {
            _ = try decodeSampler(slot);
            try wire.checkString(strings, slot.sampler_name);
            try wire.checkString(strings, slot.cooked_path);
        }
        for (params) |p| {
            _ = try wire.enumFromInt(ParamType, p.param_type);
            try wire.checkString(strings, p.name);
            try wire.checkString(param_data, p.data);
        }
        for (variants) |ref| try wire.checkString(strings, ref);

        return .{
            .shader_path_hash = header.shader_path_hash,
            .vertex_shader_path = wire.stringAt(strings, header.vertex_shader_path),
            .fragment_shader_path = wire.stringAt(strings, header.fragment_shader_path),
            .render_state = .{
                .alpha_mode = try wire.enumFromInt(AlphaMode, header.alpha_mode),
                .alpha_cutoff = header.alpha_cutoff,
                .double_sided = header.render_flags & render_flag_double_sided != 0,
                .depth_test = header.render_flags & render_flag_depth_test != 0,
                .depth_write = header.render_flags & render_flag_depth_write != 0,
                .cull_mode = try wire.enumFromInt(CullMode, header.cull_mode),
                .blend_mode = try wire.enumFromInt(BlendMode, header.blend_mode),
            },
            .texture_slots = texture_slots,
            .params = params,
            .variant_refs = variants,
            .param_data = param_data,
            .strings = strings,
        };
    }

    pub fn textureSlot(self: *const Zamat, index: usize) TextureSlotView {
        const slot = &self.texture_slots[index];
        return .{
            .slot_name_hash = slot.slot_name_hash,
            .texture_path_hash = slot.texture_path_hash,
            .slot_index = slot.slot_index,
            .uv_set = slot.uv_set,
            .sampler = decodeSampler(slot.*) catch unreachable, // validated in `view`
            .sampler_name = wire.stringAt(self.strings, slot.sampler_name),
            .cooked_path = wire.stringAt(self.strings, slot.cooked_path),
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
            .name = wire.stringAt(self.strings, p.name),
            .param_type = wire.enumFromInt(ParamType, p.param_type) catch unreachable, // validated in `view`
            .data = wire.stringAt(self.param_data, p.data),
        };
    }

    pub fn requiredVariantCount(self: *const Zamat) usize {
        return self.variant_refs.len;
    }

    pub fn requiredVariant(self: *const Zamat, index: usize) []const u8 {
        return wire.stringAt(self.strings, self.variant_refs[index]);
    }
};

fn decodeSampler(slot: TextureSlot) !SamplerDesc {
    return .{
        .min_filter = try wire.enumFromInt(FilterMode, slot.min_filter),
        .mag_filter = try wire.enumFromInt(FilterMode, slot.mag_filter),
        .mip_filter = try wire.enumFromInt(MipFilterMode, slot.mip_filter),
        .wrap_s = try wire.enumFromInt(WrapMode, slot.wrap_s),
        .wrap_t = try wire.enumFromInt(WrapMode, slot.wrap_t),
        .max_anisotropy = slot.max_anisotropy,
    };
}

pub fn view(bytes: wire.Bytes) !Zamat {
    return Zamat.view(bytes);
}

pub fn write(writer: *std.Io.Writer, material: CookedMaterial) !void {
    if (material.texture_slots.len > max_texture_slots) return error.TooManyTextureSlots;
    if (material.param_entries.len > max_params) return error.TooManyParams;
    if (material.required_variants.len > max_variants) return error.TooManyVariants;

    // String blob: param names, then variant names, then runtime paths.
    var variant_bytes: usize = 0;
    for (material.required_variants) |variant| variant_bytes += variant.len;
    const variant_base: u32 = @intCast(material.param_names.len);
    const runtime_base: u32 = @intCast(material.param_names.len + variant_bytes);

    var layout = wire.Layout.init(HEADER_SIZE);
    const texture_slots = try layout.reserve(material.texture_slots.len * @sizeOf(TextureSlot));
    const params = try layout.reserve(material.param_entries.len * @sizeOf(Param));
    const variants = try layout.reserve(material.required_variants.len * @sizeOf(wire.Span));
    const param_data = try layout.reserve(material.param_data.len);
    const strings = try layout.reserve(runtime_base + material.runtime_paths.len);
    const total_size = layout.totalSize();

    const state = material.render_state;
    var render_flags: u8 = 0;
    if (state.double_sided) render_flags |= render_flag_double_sided;
    if (state.depth_test) render_flags |= render_flag_depth_test;
    if (state.depth_write) render_flags |= render_flag_depth_write;

    var out: wire.LayoutWriter = .{ .writer = writer };
    try out.value(Header{
        .file = .init(MAGIC, ZAMAT_VERSION, total_size),
        .shader_path_hash = material.shader_path_hash,
        .vertex_shader_path = .{ .offset = runtime_base + material.vertex_shader_path_offset, .len = material.vertex_shader_path_len },
        .fragment_shader_path = .{ .offset = runtime_base + material.fragment_shader_path_offset, .len = material.fragment_shader_path_len },
        .alpha_cutoff = state.alpha_cutoff,
        .alpha_mode = @intCast(@intFromEnum(state.alpha_mode)),
        .cull_mode = @intCast(@intFromEnum(state.cull_mode)),
        .blend_mode = @intCast(@intFromEnum(state.blend_mode)),
        .render_flags = render_flags,
        .texture_slot_count = @intCast(material.texture_slots.len),
        .param_count = @intCast(material.param_entries.len),
        .variant_count = @intCast(material.required_variants.len),
        .texture_slots = texture_slots,
        .params = params,
        .variants = variants,
        .param_data = param_data,
        .strings = strings,
    });

    try out.beginSection(texture_slots);
    for (material.texture_slots) |entry| {
        try out.value(TextureSlot{
            .slot_name_hash = entry.slot_name_hash,
            .texture_path_hash = entry.texture_path_hash,
            .slot_index = entry.slot_index,
            .uv_set = entry.uv_set,
            .min_filter = @intFromEnum(entry.sampler.min_filter),
            .mag_filter = @intFromEnum(entry.sampler.mag_filter),
            .mip_filter = @intFromEnum(entry.sampler.mip_filter),
            .wrap_s = @intFromEnum(entry.sampler.wrap_s),
            .wrap_t = @intFromEnum(entry.sampler.wrap_t),
            .max_anisotropy = entry.sampler.max_anisotropy,
            .sampler_name = .{ .offset = runtime_base + entry.sampler_name_offset, .len = entry.sampler_name_len },
            .cooked_path = .{ .offset = runtime_base + entry.cooked_path_offset, .len = entry.cooked_path_len },
            .uv_offset = entry.uv_offset,
            .uv_scale = entry.uv_scale,
            .uv_rotation = entry.uv_rotation,
            .normal_scale = entry.normal_scale,
            .occlusion_strength = entry.occlusion_strength,
        });
    }

    try out.beginSection(params);
    for (material.param_entries) |entry| {
        try out.value(Param{
            .name = .{ .offset = entry.name_offset, .len = entry.name_len },
            .data = .{ .offset = entry.data_offset, .len = entry.data_size },
            .param_type = @intFromEnum(entry.param_type),
        });
    }

    try out.beginSection(variants);
    var variant_offset = variant_base;
    for (material.required_variants) |variant| {
        try out.value(wire.Span{ .offset = variant_offset, .len = @intCast(variant.len) });
        variant_offset += @intCast(variant.len);
    }

    try out.section(param_data, material.param_data);

    try out.beginSection(strings);
    try out.bytes(material.param_names);
    for (material.required_variants) |variant| try out.bytes(variant);
    try out.bytes(material.runtime_paths);
    try out.finish(total_size);
}

pub fn writeZamat(writer: *std.Io.Writer, material_source: raw_material.MaterialSource, allocator: std.mem.Allocator) !void {
    var cooked = try CookedMaterial.cook(allocator, &material_source);
    defer cooked.deinit(allocator);
    try write(writer, cooked);
}

const testing = std.testing;
const fnv1a = @import("../assets/source_file.zig").fnv1a;

fn cookedFromSource(source_text: []const u8) !CookedMaterial {
    var parsed = try raw_material.parseMaterialSource(source_text, testing.allocator);
    defer parsed.deinit(testing.allocator);
    return CookedMaterial.cook(testing.allocator, &parsed);
}

fn writeToBuffer(buf: []align(wire.section_alignment) u8, cooked: CookedMaterial) !wire.Bytes {
    var writer = std.Io.Writer.fixed(buf);
    try write(&writer, cooked);
    return buf[0..writer.end];
}

test "on-disk struct sizes" {
    try testing.expectEqual(@as(u32, 96), HEADER_SIZE);
    try testing.expectEqual(@as(usize, 80), @sizeOf(TextureSlot));
    try testing.expectEqual(@as(usize, 20), @sizeOf(Param));
}

test "Zamat write aligns every section and records total size" {
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

    var buf: [2048]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeToBuffer(&buf, cooked);

    try testing.expectEqualSlices(u8, MAGIC, bytes[0..4]);
    const header = try wire.structAt(Header, bytes, 0);
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), header.file.total_size);
    try testing.expectEqual(HEADER_SIZE, header.texture_slots.offset);
    try testing.expectEqual(@as(u32, 2 * @sizeOf(TextureSlot)), header.texture_slots.len);
    try testing.expectEqual(@as(u32, 3 * @sizeOf(Param)), header.params.len);
    for ([_]wire.Span{ header.texture_slots, header.params, header.param_data, header.strings }) |span| {
        try testing.expectEqual(@as(u32, 0), span.offset % wire.section_alignment);
    }
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
        \\u_mode = 2
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const loaded = try Zamat.view(try writeToBuffer(&buf, cooked));

    try testing.expectEqual(fnv1a("shaders/basic"), loaded.shader_path_hash);
    try testing.expectEqualStrings("shaders/basic.vert.zshdr", loaded.vertex_shader_path);
    try testing.expectEqualStrings("shaders/basic.frag.zshdr", loaded.fragment_shader_path);
    try testing.expectEqual(AlphaMode.alpha_test, loaded.render_state.alpha_mode);
    try testing.expectEqual(@as(usize, 1), loaded.texture_slots.len);
    const tex = loaded.textureSlot(0);
    try testing.expectEqual(fnv1a("u_albedo"), tex.slot_name_hash);
    try testing.expectEqual(fnv1a("textures/test_albedo.png"), tex.texture_path_hash);
    try testing.expectEqualStrings("u_albedo", tex.sampler_name);
    try testing.expectEqualStrings("textures/test_albedo.ztex", tex.cooked_path);
    try testing.expectEqual(@as(usize, 2), loaded.params.len);
    try testing.expectEqualStrings("u_enabled", loaded.param(0).name);
    try testing.expectEqual(ParamType.bool, loaded.param(0).param_type);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, loaded.param(0).data[0..4], .little));
    try testing.expectEqualStrings("u_mode", loaded.param(1).name);
    try testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, loaded.param(1).data[0..4], .little));
    try testing.expectEqual(@as(usize, 8), loaded.param_data.len);
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
        \\[params]
        \\u_roughness = 0.5
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [2048]u8 align(wire.section_alignment) = undefined;
    const loaded = try Zamat.view(try writeToBuffer(&buf, cooked));

    try testing.expectEqual(AlphaMode.alpha_blend, loaded.render_state.alpha_mode);
    try testing.expectEqual(@as(f32, 0.42), loaded.render_state.alpha_cutoff);
    try testing.expect(loaded.render_state.double_sided);
    try testing.expect(!loaded.render_state.depth_test);
    try testing.expect(!loaded.render_state.depth_write);
    try testing.expectEqual(BlendMode.alpha, loaded.render_state.blend_mode);

    const tex = loaded.textureSlot(0);
    try testing.expectEqualStrings("u_normal_map", tex.sampler_name);
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
}

test "Zamat round trips required shader variants" {
    var parsed = try raw_material.parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\
    , testing.allocator);
    defer parsed.deinit(testing.allocator);
    const variants = try testing.allocator.alloc([]const u8, 2);
    variants[0] = try testing.allocator.dupe(u8, "HAS_NORMAL_MAP");
    variants[1] = try testing.allocator.dupe(u8, "ALPHA_TEST");
    parsed.required_variants = variants;

    var cooked = try CookedMaterial.cook(testing.allocator, &parsed);
    defer cooked.deinit(testing.allocator);

    var buf: [512]u8 align(wire.section_alignment) = undefined;
    const loaded = try Zamat.view(try writeToBuffer(&buf, cooked));

    try testing.expectEqual(@as(usize, 2), loaded.requiredVariantCount());
    try testing.expectEqualStrings("HAS_NORMAL_MAP", loaded.requiredVariant(0));
    try testing.expectEqualStrings("ALPHA_TEST", loaded.requiredVariant(1));
    try testing.expectEqualStrings("shaders/basic.vert.zshdr", loaded.vertex_shader_path);
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
    try testing.expectEqual(@as(usize, HEADER_SIZE + cooked.runtime_paths.len), bytes.len);

    const loaded = try Zamat.view(bytes);
    try testing.expectEqual(@as(usize, 0), loaded.texture_slots.len);
    try testing.expectEqual(@as(usize, 0), loaded.params.len);
}

test "Zamat.view rejects corrupted files" {
    var cooked = try cookedFromSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[texture.u_albedo]
        \\path = "textures/test_albedo.png"
        \\[params]
        \\u_roughness = 0.5
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const len = (try writeToBuffer(&buf, cooked)).len;
    const header: *Header = @ptrCast(&buf);
    const slot: *TextureSlot = @ptrCast(@alignCast(buf[header.texture_slots.offset..].ptr));
    const param: *Param = @ptrCast(@alignCast(buf[header.params.offset..].ptr));

    header.alpha_mode = 9;
    try testing.expectError(error.InvalidEnumValue, Zamat.view(buf[0..len]));
    header.alpha_mode = 0;
    header.render_flags = 0x80;
    try testing.expectError(error.InvalidRenderFlags, Zamat.view(buf[0..len]));
    header.render_flags = 0;
    slot.wrap_s = 9;
    try testing.expectError(error.InvalidEnumValue, Zamat.view(buf[0..len]));
    slot.wrap_s = 0;
    slot.cooked_path.len = 4096;
    try testing.expectError(error.InvalidStringRef, Zamat.view(buf[0..len]));
    slot.cooked_path.len = 1;
    param.data.offset = 64;
    try testing.expectError(error.InvalidStringRef, Zamat.view(buf[0..len]));
    param.data.offset = 0;
    const strings = header.strings;
    header.strings.offset = header.texture_slots.offset;
    try testing.expectError(error.OverlappingSections, Zamat.view(buf[0..len]));
    header.strings = strings;
    _ = try Zamat.view(buf[0..len]);
    try testing.expectError(error.InvalidFileSize, Zamat.view(buf[0 .. len - 1]));
}
