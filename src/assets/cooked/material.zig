const std = @import("std");

const raw_material = @import("../raw/material.zig");
const derive = @import("../../manifest/derive.zig");
const ids = @import("../../id/id_types.zig");
const wire = @import("../../shared/wire.zig");
const log = @import("../../logger.zig");

pub const AlphaMode = raw_material.AlphaMode;
pub const CullMode = raw_material.CullMode;
pub const BlendMode = raw_material.BlendMode;
pub const FilterMode = raw_material.FilterMode;
pub const MipFilterMode = raw_material.MipFilterMode;
pub const WrapMode = raw_material.WrapMode;
pub const SamplerDesc = raw_material.SamplerDesc;
pub const RenderState = raw_material.RenderState;
pub const ParamValue = raw_material.ParamValue.Value;

pub const ParamType = enum(u16) {
    float = 0,
    vec2 = 1,
    vec3 = 2,
    vec4 = 3,
    int = 4,
    bool = 5,
};

pub const TextureSlotEntry = struct {
    /// `wire.nameHash` of the sampler uniform.
    name_hash: u64,
    texture: ids.AssetId,
    uv_set: u16 = 0,
    uv_offset: [2]f32 = .{ 0, 0 },
    uv_scale: [2]f32 = .{ 1, 1 },
    uv_rotation: f32 = 0,
    sampler: SamplerDesc = .{},
    normal_scale: f32 = 1.0,
    occlusion_strength: f32 = 1.0,
};

pub const ParamEntry = struct {
    /// `wire.nameHash` of the uniform.
    name_hash: u64,
    value: ParamValue,
};

/// A material ready for `zamat.write`. Names are reduced to `wire.nameHash`es
/// and every table is sorted by hash.
pub const CookedMaterial = struct {
    vertex_shader: ids.AssetId,
    fragment_shader: ids.AssetId,
    render_state: RenderState,
    texture_slots: []TextureSlotEntry,
    params: []ParamEntry,
    variant_hashes: []u64,

    /// Resolves shader and texture source paths to the `AssetId`s the
    /// manifest assigns them under `project_id`. Two texture slots, params, or
    /// variants with the same name hash are an error.
    pub fn cook(allocator: std.mem.Allocator, source: *const raw_material.MaterialSource, project_id: ids.ProjectId) !CookedMaterial {
        const vertex_source_path = try std.fmt.allocPrint(allocator, "{s}.vert", .{source.shader_path});
        defer allocator.free(vertex_source_path);
        const fragment_source_path = try std.fmt.allocPrint(allocator, "{s}.frag", .{source.shader_path});
        defer allocator.free(fragment_source_path);
        const vertex_shader = try derive.assetIdForReference(project_id, vertex_source_path);
        const fragment_shader = try derive.assetIdForReference(project_id, fragment_source_path);

        const texture_slots = try allocator.alloc(TextureSlotEntry, source.textures.len);
        errdefer allocator.free(texture_slots);
        for (source.textures, texture_slots) |slot, *entry| {
            entry.* = .{
                .name_hash = wire.nameHash(slot.slot_name),
                .texture = try derive.assetIdForReference(project_id, slot.texture_path),
                .uv_set = slot.uv_set,
                .uv_offset = slot.uv_offset,
                .uv_scale = slot.uv_scale,
                .uv_rotation = slot.uv_rotation,
                .sampler = slot.sampler,
                .normal_scale = slot.normal_scale,
                .occlusion_strength = slot.occlusion_strength,
            };
        }
        sortByHash(TextureSlotEntry, texture_slots);
        if (duplicateHash(TextureSlotEntry, texture_slots)) |hash| {
            for (source.textures) |slot| {
                if (wire.nameHash(slot.slot_name) != hash) continue;
                log.err("material: duplicate texture slot '{s}'", .{slot.slot_name});
                break;
            }
            return error.DuplicateTextureSlot;
        }

        const params = try allocator.alloc(ParamEntry, source.params.len);
        errdefer allocator.free(params);
        for (source.params, params) |param, *entry| {
            entry.* = .{ .name_hash = wire.nameHash(param.name), .value = param.value };
        }
        sortByHash(ParamEntry, params);
        if (duplicateHash(ParamEntry, params)) |hash| {
            for (source.params) |param| {
                if (wire.nameHash(param.name) != hash) continue;
                log.err("material: duplicate param '{s}'", .{param.name});
                break;
            }
            return error.DuplicateMaterialParam;
        }

        const variant_hashes = try allocator.alloc(u64, source.required_variants.len);
        errdefer allocator.free(variant_hashes);
        for (source.required_variants, variant_hashes) |variant, *hash| hash.* = wire.nameHash(variant);
        std.mem.sort(u64, variant_hashes, {}, std.sort.asc(u64));
        var i: usize = 1;
        while (i < variant_hashes.len) : (i += 1) {
            if (variant_hashes[i] == variant_hashes[i - 1]) return error.DuplicateVariant;
        }

        return .{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .render_state = source.render_state,
            .texture_slots = texture_slots,
            .params = params,
            .variant_hashes = variant_hashes,
        };
    }

    pub fn deinit(self: *CookedMaterial, allocator: std.mem.Allocator) void {
        allocator.free(self.texture_slots);
        allocator.free(self.params);
        allocator.free(self.variant_hashes);
    }
};

fn sortByHash(comptime T: type, items: []T) void {
    std.mem.sort(T, items, {}, struct {
        fn lessThan(_: void, a: T, b: T) bool {
            return a.name_hash < b.name_hash;
        }
    }.lessThan);
}

/// Returns a hash that appears twice in `items`, which must be sorted.
fn duplicateHash(comptime T: type, items: []const T) ?u64 {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        if (items[i].name_hash == items[i - 1].name_hash) return items[i].name_hash;
    }
    return null;
}

const testing = std.testing;

fn parseAndCook(source_text: []const u8) !CookedMaterial {
    var parsed = try raw_material.parseMaterialSource(source_text, testing.allocator);
    defer parsed.deinit(testing.allocator);
    return CookedMaterial.cook(testing.allocator, &parsed, .zero);
}

test "cook sorts slots and params by name hash" {
    var cooked = try parseAndCook(
        \\[material]
        \\shader = "shaders/basic"
        \\[texture.u_normal_map]
        \\path = "textures/n.png"
        \\[texture.u_albedo]
        \\path = "textures/a.png"
        \\[params]
        \\u_roughness = 0.5
        \\u_tint = [1.0, 0.5, 0.25]
        \\u_mode = 2
        \\
    );
    defer cooked.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), cooked.texture_slots.len);
    try testing.expect(cooked.texture_slots[0].name_hash < cooked.texture_slots[1].name_hash);
    try testing.expectEqual(@as(usize, 3), cooked.params.len);
    for (cooked.params[0..2], cooked.params[1..]) |a, b| try testing.expect(a.name_hash < b.name_hash);
    for (cooked.params) |param| {
        if (param.name_hash == wire.nameHash("u_tint")) {
            try testing.expectEqual([3]f32{ 1.0, 0.5, 0.25 }, param.value.vec3);
        }
    }
}

test "cook rejects duplicate slots, params, and variants" {
    var parsed = try raw_material.parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\
    , testing.allocator);
    defer parsed.deinit(testing.allocator);

    const slots = [_]raw_material.TextureSlot{
        .{ .slot_name = "u_albedo", .texture_path = "a.png" },
        .{ .slot_name = "u_albedo", .texture_path = "b.png" },
    };
    var with_slots = parsed;
    with_slots.textures = &slots;
    try testing.expectError(error.DuplicateTextureSlot, CookedMaterial.cook(testing.allocator, &with_slots, .zero));

    const params = [_]raw_material.ParamValue{
        .{ .name = "u_roughness", .value = .{ .float = 0.5 } },
        .{ .name = "u_roughness", .value = .{ .float = 0.25 } },
    };
    var with_params = parsed;
    with_params.params = &params;
    try testing.expectError(error.DuplicateMaterialParam, CookedMaterial.cook(testing.allocator, &with_params, .zero));

    const variants = [_][]const u8{ "ALPHA_TEST", "HAS_AO", "ALPHA_TEST" };
    var with_variants = parsed;
    with_variants.required_variants = &variants;
    try testing.expectError(error.DuplicateVariant, CookedMaterial.cook(testing.allocator, &with_variants, .zero));
}
