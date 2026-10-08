const std = @import("std");
const string_list = @import("../../shared/string_list.zig");

const source_file = @import("../source_file.zig");
const raw_material = @import("../raw/material.zig");
const derive = @import("../../manifest/derive.zig");
const ids = @import("../../id/id_types.zig");

pub const AlphaMode = raw_material.AlphaMode;
pub const CullMode = raw_material.CullMode;
pub const BlendMode = raw_material.BlendMode;
pub const FilterMode = raw_material.FilterMode;
pub const MipFilterMode = raw_material.MipFilterMode;
pub const WrapMode = raw_material.WrapMode;
pub const SamplerDesc = raw_material.SamplerDesc;
pub const RenderState = raw_material.RenderState;
pub const Hash = source_file.Hash;

pub const TextureSlotIndex = enum(u16) {
    albedo = 0,
    normal = 1,
    roughness = 2,
    metallic = 3,
    ao = 4,
    emissive = 5,
    roughness_metallic = 6,
    orm = 7,
};

pub fn slotNameToIndex(name: []const u8) ?TextureSlotIndex {
    if (std.mem.eql(u8, name, "u_albedo")) return .albedo;
    if (std.mem.eql(u8, name, "u_normal_map")) return .normal;
    if (std.mem.eql(u8, name, "u_roughness_map")) return .roughness;
    if (std.mem.eql(u8, name, "u_metallic_map")) return .metallic;
    if (std.mem.eql(u8, name, "u_ao_map")) return .ao;
    if (std.mem.eql(u8, name, "u_emissive_map")) return .emissive;
    if (std.mem.eql(u8, name, "u_roughness_metallic_map")) return .roughness_metallic;
    if (std.mem.eql(u8, name, "u_orm_map")) return .orm;
    return null;
}

pub const ParamType = enum(u16) {
    float = 0,
    vec2 = 1,
    vec3 = 2,
    vec4 = 3,
    int = 4,
    bool = 5,
};

pub const TextureSlotEntry = struct {
    slot_name_hash: Hash,
    texture: ids.AssetId,
    slot_index: u16,
    uv_set: u16,
    uv_offset: [2]f32,
    uv_scale: [2]f32,
    uv_rotation: f32,
    sampler: SamplerDesc,
    normal_scale: f32,
    occlusion_strength: f32,
    sampler_name: []const u8,
    sampler_name_offset: u16,
    sampler_name_len: u16,
};

pub const ParamEntry = struct {
    name: []const u8,
    name_offset: u16,
    name_len: u16,
    param_type: ParamType,
    data_offset: u16,
    data_size: u16,
};

pub const ParamBuildResult = struct {
    entries: []ParamEntry,
    data: []u8,
    names: []u8,

    pub fn deinit(self: *ParamBuildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.data);
        allocator.free(self.names);
    }
};

pub const CookedMaterial = struct {
    vertex_shader: ids.AssetId,
    fragment_shader: ids.AssetId,
    render_state: RenderState,
    required_variants: []const []const u8,
    texture_slots: []TextureSlotEntry,
    param_entries: []ParamEntry,
    param_data: []u8,
    param_names: []u8,
    sampler_names: []u8,

    /// Resolves shader and texture source paths to the `AssetId`s the
    /// manifest assigns them under `project_id`.
    pub fn cook(allocator: std.mem.Allocator, source: *const raw_material.MaterialSource, project_id: ids.ProjectId) !CookedMaterial {
        const texture_slots = try allocator.alloc(TextureSlotEntry, source.textures.len);
        errdefer allocator.free(texture_slots);
        var sampler_names: std.ArrayList(u8) = .empty;
        errdefer sampler_names.deinit(allocator);

        const vertex_source_path = try std.fmt.allocPrint(allocator, "{s}.vert", .{source.shader_path});
        defer allocator.free(vertex_source_path);
        const fragment_source_path = try std.fmt.allocPrint(allocator, "{s}.frag", .{source.shader_path});
        defer allocator.free(fragment_source_path);
        const vertex_shader = try derive.assetIdForReference(project_id, vertex_source_path);
        const fragment_shader = try derive.assetIdForReference(project_id, fragment_source_path);

        for (source.textures, texture_slots) |slot, *entry| {
            const sampler_name_offset = try appendSamplerName(&sampler_names, allocator, slot.slot_name);
            entry.* = .{
                .slot_name_hash = source_file.fnv1a(slot.slot_name),
                .texture = try derive.assetIdForReference(project_id, slot.texture_path),
                .slot_index = if (slotNameToIndex(slot.slot_name)) |idx| @intFromEnum(idx) else std.math.maxInt(u16),
                .uv_set = slot.uv_set,
                .uv_offset = slot.uv_offset,
                .uv_scale = slot.uv_scale,
                .uv_rotation = slot.uv_rotation,
                .sampler = slot.sampler,
                .normal_scale = slot.normal_scale,
                .occlusion_strength = slot.occlusion_strength,
                .sampler_name = &.{},
                .sampler_name_offset = sampler_name_offset,
                .sampler_name_len = @intCast(slot.slot_name.len),
            };
        }

        var params = try buildParamDataBlock(source.params, allocator);
        errdefer params.deinit(allocator);

        const required_variants = try string_list.dupeStringList(allocator, source.required_variants);
        errdefer string_list.freeStringList(allocator, required_variants);

        const owned_sampler_names = try sampler_names.toOwnedSlice(allocator);
        for (texture_slots) |*entry| {
            const start: usize = entry.sampler_name_offset;
            entry.sampler_name = owned_sampler_names[start..][0..entry.sampler_name_len];
        }

        return .{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .render_state = source.render_state,
            .required_variants = required_variants,
            .texture_slots = texture_slots,
            .param_entries = params.entries,
            .param_data = params.data,
            .param_names = params.names,
            .sampler_names = owned_sampler_names,
        };
    }

    pub fn deinit(self: *CookedMaterial, allocator: std.mem.Allocator) void {
        allocator.free(self.texture_slots);
        string_list.freeStringList(allocator, self.required_variants);
        allocator.free(self.param_entries);
        allocator.free(self.param_data);
        allocator.free(self.param_names);
        allocator.free(self.sampler_names);
    }
};

fn appendSamplerName(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !u16 {
    if (list.items.len > std.math.maxInt(u16)) return error.SamplerNamesTooLarge;
    if (name.len > std.math.maxInt(u16)) return error.SamplerNameTooLarge;
    const offset: u16 = @intCast(list.items.len);
    try list.appendSlice(allocator, name);
    return offset;
}

pub fn buildParamDataBlock(params: []const raw_material.ParamValue, allocator: std.mem.Allocator) !ParamBuildResult {
    var entries = try std.ArrayList(ParamEntry).initCapacity(allocator, params.len);
    errdefer entries.deinit(allocator);

    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    var names: std.ArrayList(u8) = .empty;
    errdefer names.deinit(allocator);

    for (params) |param| {
        if (data.items.len > std.math.maxInt(u16)) return error.ParamDataTooLarge;
        if (names.items.len > std.math.maxInt(u16)) return error.ParamNamesTooLarge;
        if (param.name.len > std.math.maxInt(u16)) return error.ParamNameTooLarge;
        const data_offset: u16 = @intCast(data.items.len);
        const name_offset: u16 = @intCast(names.items.len);
        try names.appendSlice(allocator, param.name);
        const before = data.items.len;
        const param_type = try appendParamBytes(&data, allocator, param.value);
        const size = data.items.len - before;
        if (size > std.math.maxInt(u16)) return error.ParamDataTooLarge;

        entries.appendAssumeCapacity(.{
            .name = names.items[name_offset..][0..param.name.len],
            .name_offset = name_offset,
            .name_len = @intCast(param.name.len),
            .param_type = param_type,
            .data_offset = data_offset,
            .data_size = @intCast(size),
        });
    }

    const owned_entries = try entries.toOwnedSlice(allocator);
    errdefer allocator.free(owned_entries);
    const owned_data = try data.toOwnedSlice(allocator);
    errdefer allocator.free(owned_data);
    const owned_names = try names.toOwnedSlice(allocator);

    for (owned_entries) |*entry| {
        const start: usize = entry.name_offset;
        entry.name = owned_names[start..][0..entry.name_len];
    }

    return .{
        .entries = owned_entries,
        .data = owned_data,
        .names = owned_names,
    };
}

fn appendParamBytes(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: raw_material.ParamValue.Value) !ParamType {
    switch (value) {
        .float => |v| {
            try appendF32(list, allocator, v);
            return .float;
        },
        .vec2 => |v| {
            for (v) |component| try appendF32(list, allocator, component);
            return .vec2;
        },
        .vec3 => |v| {
            for (v) |component| try appendF32(list, allocator, component);
            return .vec3;
        },
        .vec4 => |v| {
            for (v) |component| try appendF32(list, allocator, component);
            return .vec4;
        },
        .int => |v| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(i32, &bytes, v, .little);
            try list.appendSlice(allocator, &bytes);
            return .int;
        },
        .bool => |v| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, if (v) 1 else 0, .little);
            try list.appendSlice(allocator, &bytes);
            return .bool;
        },
    }
}

fn appendF32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @bitCast(value), .little);
    try list.appendSlice(allocator, &bytes);
}

const testing = std.testing;

test "slotNameToIndex maps known slots" {
    try testing.expectEqual(TextureSlotIndex.albedo, slotNameToIndex("u_albedo").?);
    try testing.expectEqual(TextureSlotIndex.normal, slotNameToIndex("u_normal_map").?);
    try testing.expectEqual(@as(?TextureSlotIndex, null), slotNameToIndex("unknown_custom"));
}

test "buildParamDataBlock packs params and offsets" {
    const params = [_]raw_material.ParamValue{
        .{ .name = "u_roughness", .value = .{ .float = 0.5 } },
        .{ .name = "u_uv_scale", .value = .{ .vec2 = .{ 2.0, 2.0 } } },
    };

    var result = try buildParamDataBlock(&params, testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.entries.len);
    try testing.expectEqual(@as(usize, 12), result.data.len);
    try testing.expectEqual(@as(u16, 0), result.entries[0].data_offset);
    try testing.expectEqual(@as(u16, 4), result.entries[1].data_offset);
    try testing.expectEqual(ParamType.float, result.entries[0].param_type);
    try testing.expectEqual(ParamType.vec2, result.entries[1].param_type);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 0.5))), std.mem.readInt(u32, result.data[0..4], .little));
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 2.0))), std.mem.readInt(u32, result.data[4..8], .little));
}
