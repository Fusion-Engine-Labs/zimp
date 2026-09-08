const std = @import("std");

const resolveRelativeUri = @import("document.zig").resolveRelativeUri;
const GltfTextureInfo = @import("gltf_json_parser.zig").GltfTextureInfo;
const atomic_file = @import("../../shared/atomic_file.zig");
const SourceFile = @import("../../assets/source_file.zig").SourceFile;
const GltfMaterial = @import("gltf_json_parser.zig").GltfMaterial;
const GltfSampler = @import("gltf_json_parser.zig").GltfSampler;
const Extension = @import("../../assets/asset.zig").Extension;
const GltfDocument = @import("document.zig").GltfDocument;
const GltfJson = @import("gltf_json_parser.zig").GltfJson;
const GltfPbr = @import("gltf_json_parser.zig").GltfPbr;
const raw_material = @import("../../assets/raw/material.zig");
const file_read = @import("../../shared/file_read.zig");
const builtin = @import("../../builtin/registry.zig");
const GLBFile = @import("glb_parser.zig").GLBFile;
const Gltf = @import("gltf_json_parser.zig").Gltf;
const log = @import("../../logger.zig");

const DEFAULT_SHADER = builtin.PREFIX ++ "standard";
const GENERATED_MATERIAL_DIR = "generated/materials";
const GENERATED_TEXTURE_DIR = "generated/textures";

/// Files written while generating materials for a source.  Texture copies are
/// intentionally tracked separately: their containing material may be
/// byte-for-byte unchanged while the texture it references has been updated.
pub const GenerationResult = struct {
    materials: usize = 0,
    textures: usize = 0,

    pub fn changed(self: GenerationResult) bool {
        return self.materials != 0 or self.textures != 0;
    }

    fn merge(self: *GenerationResult, other: GenerationResult) void {
        self.materials += other.materials;
        self.textures += other.textures;
    }
};

const TextureRole = enum {
    albedo,
    normal,
    roughness_metallic,
    ao,
    emissive,

    fn suffix(self: TextureRole) []const u8 {
        return switch (self) {
            .albedo => "albedo",
            .normal => "normal",
            .roughness_metallic => "rm",
            .ao => "ao",
            .emissive => "emissive",
        };
    }

    fn slotName(self: TextureRole) []const u8 {
        return switch (self) {
            .albedo => "u_albedo",
            .normal => "u_normal_map",
            .roughness_metallic => "u_roughness_metallic_map",
            .ao => "u_ao_map",
            .emissive => "u_emissive_map",
        };
    }
};

pub fn generateForSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    sources: []const SourceFile,
) !GenerationResult {
    var result: GenerationResult = .{};
    for (sources) |source| {
        if (source.extension != .glb and source.extension != .gltf and source.extension != .obj) {
            continue;
        }

        result.merge(generateForSource(allocator, io, source_dir, source.path, source.extension) catch |err| {
            log.warn("Failed to auto-generate materials for '{s}': {s}", .{ source.path, @errorName(err) });
            continue;
        });
    }
    return result;
}

pub fn generateForSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    extension: Extension,
) !GenerationResult {
    switch (extension) {
        .glb => {
            const file_result = try file_read.readFileAllocChunked(allocator, io, source_dir, file_path);
            defer allocator.free(file_result);

            const glb_file = try GLBFile.parse(allocator, file_result);
            defer allocator.destroy(glb_file);

            var gltf = try Gltf.parse(glb_file.json, allocator);
            defer gltf.deinit();

            const buffers = [_][]const u8{glb_file.bin};
            return generateFromGltf(allocator, io, source_dir, file_path, &gltf.value, &buffers);
        },
        .gltf => {
            var document = try GltfDocument.loadGltf(allocator, io, source_dir, file_path);
            defer document.deinit();
            return generateFromGltf(allocator, io, source_dir, file_path, &document.gltf.value, document.buffers);
        },
        .obj => return generateDefaultMaterial(allocator, io, source_dir, file_path),
        else => return .{},
    }
}

pub fn generateFromGltf(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
    gltf: *const GltfJson,
    buffers: []const []const u8,
) !GenerationResult {
    if (gltf.materials.len == 0) {
        return generateDefaultMaterial(allocator, io, source_dir, source_path);
    }

    try source_dir.createDirPath(io, GENERATED_MATERIAL_DIR);
    try source_dir.createDirPath(io, GENERATED_TEXTURE_DIR);

    var result: GenerationResult = .{};
    for (gltf.materials, 0..) |material, i| {
        const material_name = material.name orelse try std.fmt.allocPrint(allocator, "material_{d}", .{i});
        const allocated_name = material.name == null;
        defer if (allocated_name) allocator.free(material_name);

        const output_path = try generatedMaterialPath(allocator, source_path, material_name);
        defer allocator.free(output_path);

        const hand_path = try handwrittenMaterialPath(allocator, std.fs.path.basename(output_path));
        defer allocator.free(hand_path);

        if (file_read.fileExists(source_dir, io, hand_path)) {
            continue;
        }

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        result.textures += try writeMaterialText(
            &text,
            allocator,
            io,
            source_dir,
            source_path,
            gltf,
            buffers,
            material,
            material_name,
        );

        if (try fileMatches(source_dir, io, allocator, output_path, text.items)) {
            continue;
        }

        try atomic_file.writeFileAtomic(allocator, io, source_dir, output_path, text.items);

        result.materials += 1;
        log.debug("Generated material '{s}' from '{s}'", .{ output_path, source_path });
    }

    return result;
}

pub fn resolveMaterialPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
    gltf: *const GltfJson,
) ![][]u8 {
    const count = @max(gltf.materials.len, 1);
    const paths = try allocator.alloc([]u8, count);
    errdefer allocator.free(paths);
    var initialized: usize = 0;
    errdefer for (paths[0..initialized]) |path| allocator.free(path);

    for (0..count) |i| {
        const material_name = if (gltf.materials.len == 0)
            "DefaultMaterial"
        else
            gltf.materials[i].name orelse try std.fmt.allocPrint(allocator, "material_{d}", .{i});
        const allocated_name = gltf.materials.len != 0 and gltf.materials[i].name == null;
        defer if (allocated_name) allocator.free(material_name);

        const generated_path = try generatedMaterialPath(allocator, source_path, material_name);
        const handwritten_path = try handwrittenMaterialPath(allocator, std.fs.path.basename(generated_path));
        if (file_read.fileExists(source_dir, io, handwritten_path)) {
            allocator.free(generated_path);
            paths[i] = handwritten_path;
        } else {
            allocator.free(handwritten_path);
            paths[i] = generated_path;
        }
        initialized += 1;
    }
    return paths;
}

pub fn resolveDefaultMaterialPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
) ![]u8 {
    const empty: GltfJson = .{};
    const paths = try resolveMaterialPaths(allocator, io, source_dir, source_path, &empty);
    defer allocator.free(paths);
    return paths[0];
}

pub fn freeMaterialPaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn generateDefaultMaterial(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
) !GenerationResult {
    try source_dir.createDirPath(io, GENERATED_MATERIAL_DIR);

    const output_path = try generatedMaterialPath(allocator, source_path, "DefaultMaterial");
    defer allocator.free(output_path);
    const hand_path = try handwrittenMaterialPath(allocator, std.fs.path.basename(output_path));
    defer allocator.free(hand_path);
    if (file_read.fileExists(source_dir, io, hand_path)) return .{};

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const empty: GltfJson = .{};
    _ = try writeMaterialText(&text, allocator, io, source_dir, source_path, &empty, &.{}, .{
        .name = "DefaultMaterial",
        .pbrMetallicRoughness = .{},
    }, "DefaultMaterial");
    if (try fileMatches(source_dir, io, allocator, output_path, text.items)) return .{};

    try atomic_file.writeFileAtomic(allocator, io, source_dir, output_path, text.items);
    log.debug("Generated default material '{s}' from '{s}'", .{ output_path, source_path });
    return .{ .materials = 1 };
}

fn fileMatches(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !bool {
    const result = file_read.readFileAllocChunked(allocator, io, dir, path) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer allocator.free(result);
    return std.mem.eql(u8, result, bytes);
}

fn renderStateText(allocator: std.mem.Allocator, state: raw_material.RenderState) ![]const u8 {
    const defaults = raw_material.RenderState{};
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    if (state.alpha_mode != defaults.alpha_mode) {
        try appendPrint(&text, allocator, "alpha_mode = \"{s}\"\n", .{
            @tagName(state.alpha_mode),
        });
    }

    if (state.alpha_mode == .alpha_test and state.alpha_cutoff != defaults.alpha_cutoff) {
        try appendPrint(&text, allocator, "alpha_cutoff = {d}\n", .{
            state.alpha_cutoff,
        });
    }

    if (state.double_sided != defaults.double_sided) {
        try appendPrint(&text, allocator, "double_sided = {s}\n", .{
            if (state.double_sided) "true" else "false",
        });
    }

    if (state.cull_mode != defaults.cull_mode) {
        try appendPrint(&text, allocator, "cull_mode = \"{s}\"\n", .{
            @tagName(state.cull_mode),
        });
    }

    if (state.depth_test != defaults.depth_test) {
        try appendPrint(&text, allocator, "depth_test = {s}\n", .{
            if (state.depth_test) "true" else "false",
        });
    }

    if (state.depth_write != defaults.depth_write) {
        try appendPrint(&text, allocator, "depth_write = {s}\n", .{
            if (state.depth_write) "true" else "false",
        });
    }

    if (state.blend_mode != defaults.blend_mode) {
        try appendPrint(&text, allocator, "blend_mode = \"{s}\"\n", .{
            @tagName(state.blend_mode),
        });
    }

    return text.toOwnedSlice(allocator);
}

fn writeMaterialText(
    text: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
    gltf: *const GltfJson,
    buffers: []const []const u8,
    material: GltfMaterial,
    material_name: []const u8,
) !usize {
    var textures_changed: usize = 0;
    try appendPrint(text, allocator,
        \\# Auto-generated from {s} - {s}
        \\[material]
        \\shader = "{s}"
    , .{
        source_path,
        material_name,
        DEFAULT_SHADER,
    });

    const render_state = material.renderState();
    const render_state_text = try renderStateText(allocator, render_state);
    defer allocator.free(render_state_text);

    if (render_state_text.len > 0) {
        try appendPrint(text, allocator,
            \\
            \\[render_state]
            \\{s}
            \\
        , .{render_state_text});
    }

    if (material.pbrMetallicRoughness) |pbr| {
        if (pbr.baseColorTexture) |info| {
            textures_changed += @intFromBool(try appendTexture(
                text,
                allocator,
                io,
                source_dir,
                source_path,
                gltf,
                buffers,
                .albedo,
                info,
                .{},
            ));
        }
        if (pbr.metallicRoughnessTexture) |info| {
            textures_changed += @intFromBool(try appendTexture(
                text,
                allocator,
                io,
                source_dir,
                source_path,
                gltf,
                buffers,
                .roughness_metallic,
                info,
                .{},
            ));
        }
    }
    if (material.normalTexture) |info| {
        textures_changed += @intFromBool(try appendTexture(
            text,
            allocator,
            io,
            source_dir,
            source_path,
            gltf,
            buffers,
            .normal,
            info,
            .{ .normal_scale = info.scale orelse 1.0 },
        ));
    }
    if (material.occlusionTexture) |info| {
        textures_changed += @intFromBool(try appendTexture(
            text,
            allocator,
            io,
            source_dir,
            source_path,
            gltf,
            buffers,
            .ao,
            info,
            .{ .occlusion_strength = info.strength orelse 1.0 },
        ));
    }
    if (material.emissiveTexture) |info| {
        textures_changed += @intFromBool(try appendTexture(
            text,
            allocator,
            io,
            source_dir,
            source_path,
            gltf,
            buffers,
            .emissive,
            info,
            .{},
        ));
    }

    const pbr = material.pbrMetallicRoughness orelse GltfPbr{};
    const emissive = material.emissiveFactor orelse .{ 0, 0, 0 };
    const has_emissive = !std.mem.eql(f32, &emissive, &[_]f32{ 0, 0, 0 });

    try text.appendSlice(allocator, "\n[params]\n");
    try appendParamVec4(text, allocator, "u_base_color", pbr.baseColorFactor);
    try appendParamFloat(text, allocator, "u_metallic", pbr.metallicFactor);
    try appendParamFloat(text, allocator, "u_roughness", pbr.roughnessFactor);
    if (has_emissive) {
        try appendParamVec3(text, allocator, "u_emissive", emissive);
    }

    return textures_changed;
}

const TextureOptions = struct {
    normal_scale: f32 = 1.0,
    occlusion_strength: f32 = 1.0,
};

const EffectiveTextureTransform = struct {
    uv_set: u32,
    offset: [2]f32,
    rotation: f32,
    scale: [2]f32,
};

fn effectiveTransform(info: GltfTextureInfo) EffectiveTextureTransform {
    const transform = if (info.extensions) |ext| ext.KHR_texture_transform else null;

    if (transform) |t| {
        return .{
            .uv_set = t.texCoord orelse info.texCoord,
            .offset = t.offset,
            .rotation = t.rotation,
            .scale = t.scale,
        };
    }

    return .{
        .uv_set = info.texCoord,
        .offset = .{ 0, 0 },
        .scale = .{ 1, 1 },
        .rotation = 0,
    };
}

fn textureSlotProperties(allocator: std.mem.Allocator, slot: *const raw_material.TextureSlot) ![]const u8 {
    const defaults = raw_material.TextureSlot{
        .slot_name = "",
        .texture_path = "",
    };
    const sampler_defaults: raw_material.SamplerDesc = .{};

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    if (slot.uv_set != defaults.uv_set) {
        try appendPrint(&text, allocator, "uv_set = {d}\n", .{
            slot.uv_set,
        });
    }

    if (!std.mem.eql(f32, &slot.uv_offset, &defaults.uv_offset)) {
        try appendPrint(&text, allocator, "uv_offset = [{d}, {d}]\n", .{
            slot.uv_offset[0],
            slot.uv_offset[1],
        });
    }

    if (!std.mem.eql(f32, &slot.uv_scale, &defaults.uv_scale)) {
        try appendPrint(&text, allocator, "uv_scale = [{d}, {d}]\n", .{
            slot.uv_scale[0],
            slot.uv_scale[1],
        });
    }

    if (slot.uv_rotation != defaults.uv_rotation) {
        try appendPrint(&text, allocator, "uv_rotation = {d}\n", .{
            slot.uv_rotation,
        });
    }

    if (slot.sampler.min_filter != sampler_defaults.min_filter) {
        try appendPrint(&text, allocator, "min_filter = \"{s}\"\n", .{
            @tagName(slot.sampler.min_filter),
        });
    }

    if (slot.sampler.mag_filter != sampler_defaults.mag_filter) {
        try appendPrint(&text, allocator, "mag_filter = \"{s}\"\n", .{
            @tagName(slot.sampler.mag_filter),
        });
    }

    if (slot.sampler.mip_filter != sampler_defaults.mip_filter) {
        try appendPrint(&text, allocator, "mip_filter = \"{s}\"\n", .{
            @tagName(slot.sampler.mip_filter),
        });
    }

    if (slot.sampler.wrap_s != sampler_defaults.wrap_s) {
        try appendPrint(&text, allocator, "wrap_s = \"{s}\"\n", .{
            @tagName(slot.sampler.wrap_s),
        });
    }

    if (slot.sampler.wrap_t != sampler_defaults.wrap_t) {
        try appendPrint(&text, allocator, "wrap_t = \"{s}\"\n", .{
            @tagName(slot.sampler.wrap_t),
        });
    }

    if (slot.sampler.max_anisotropy != sampler_defaults.max_anisotropy) {
        try appendPrint(&text, allocator, "max_anisotropy = {d}\n", .{
            slot.sampler.max_anisotropy,
        });
    }

    if (slot.normal_scale != defaults.normal_scale) {
        try appendPrint(&text, allocator, "normal_scale = {d}\n", .{
            slot.normal_scale,
        });
    }

    if (slot.occlusion_strength != defaults.occlusion_strength) {
        try appendPrint(&text, allocator, "occlusion_strength = {d}\n", .{
            slot.occlusion_strength,
        });
    }

    return text.toOwnedSlice(allocator);
}

fn toTextureSlot(
    slot_name: []const u8,
    texture_path: []const u8,
    sampler: *const GltfSampler,
    transform: *const EffectiveTextureTransform,
    options: *const TextureOptions,
) raw_material.TextureSlot {
    return .{
        .sampler = .{
            .min_filter = filterMode(sampler.minFilter),
            .mag_filter = filterMode(sampler.magFilter),
            .mip_filter = mipFilterMode(sampler.minFilter),
            .wrap_s = wrapMode(sampler.wrapS),
            .wrap_t = wrapMode(sampler.wrapT),
        },
        .slot_name = slot_name,
        .texture_path = texture_path,
        .uv_set = @intCast(transform.uv_set),
        .uv_offset = transform.offset,
        .uv_scale = transform.scale,
        .uv_rotation = transform.rotation,
        .normal_scale = options.normal_scale,
        .occlusion_strength = options.occlusion_strength,
    };
}

fn appendTexture(
    text: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
    gltf: *const GltfJson,
    buffers: []const []const u8,
    role: TextureRole,
    info: GltfTextureInfo,
    options: TextureOptions,
) !bool {
    const generated = try texturePath(
        allocator,
        io,
        role,
        source_dir,
        source_path,
        gltf,
        buffers,
        info.index,
    );
    defer allocator.free(generated.path);

    const sampler = samplerForTexture(gltf, info.index);
    const effective = effectiveTransform(info);
    const texture_slot = toTextureSlot(
        role.slotName(),
        generated.path,
        &sampler,
        &effective,
        &options,
    );
    const properties = try textureSlotProperties(allocator, &texture_slot);
    defer allocator.free(properties);

    try appendPrint(text, allocator,
        \\
        \\[texture.{s}]
        \\path = "{s}"
        \\{s}
        \\
    , .{
        role.slotName(),
        generated.path,
        properties,
    });

    return generated.changed;
}

const GeneratedTexture = struct {
    path: []const u8,
    changed: bool,
};

fn texturePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    role: TextureRole,
    source_dir: std.Io.Dir,
    source_path: []const u8,
    gltf: *const GltfJson,
    buffers: []const []const u8,
    texture_index: u32,
) !GeneratedTexture {
    if (texture_index >= gltf.textures.len) {
        return error.TextureIndexOutOfBounds;
    }

    const image_index = gltf.textures[texture_index].source orelse return error.TextureMissingSource;
    if (image_index >= gltf.images.len) {
        return error.ImageIndexOutOfBounds;
    }

    const image = gltf.images[image_index];
    if (image.uri) |uri| {
        const source_image_path =
            try resolveRelativeUri(allocator, source_path, uri);
        defer allocator.free(source_image_path);

        const image_result = try file_read.readFileAllocChunked(
            allocator,
            io,
            source_dir,
            source_image_path,
        );
        defer allocator.free(image_result);

        const extension = std.fs.path.extension(source_image_path);
        if (extension.len < 2) {
            return error.ImageExtensionMissing;
        }

        const generated_path = try generatedTexturePath(
            allocator,
            role,
            source_path,
            image.name,
            image_index,
            image.mimeType,
            extension[1..],
        );

        return .{
            .path = generated_path,
            .changed = try writeGeneratedTexture(
                allocator,
                io,
                source_dir,
                generated_path,
                image_result,
            ),
        };
    }

    const buffer_view_index = image.bufferView orelse return error.ImageMissingData;
    if (buffer_view_index >= gltf.bufferViews.len) {
        return error.BufferViewIndexOutOfBounds;
    }

    const view = gltf.bufferViews[buffer_view_index];
    if (view.buffer >= buffers.len) {
        return error.BufferIndexOutOfBounds;
    }

    const buffer = buffers[view.buffer];
    const start: usize = view.byteOffset;
    const end = start + view.byteLength;
    if (end > buffer.len) {
        return error.ImageOutOfBounds;
    }

    const path = try generatedTexturePath(
        allocator,
        role,
        source_path,
        image.name,
        image_index,
        image.mimeType,
        null,
    );
    errdefer allocator.free(path);

    return .{
        .path = path,
        .changed = try writeGeneratedTexture(
            allocator,
            io,
            source_dir,
            path,
            buffer[start..end],
        ),
    };
}

fn writeGeneratedTexture(allocator: std.mem.Allocator, io: std.Io, source_dir: std.Io.Dir, path: []const u8, bytes: []const u8) !bool {
    if (try fileMatches(source_dir, io, allocator, path, bytes)) {
        return false;
    }

    try atomic_file.writeFileAtomic(allocator, io, source_dir, path, bytes);

    return true;
}

fn appendParamFloat(text: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: f32) !void {
    try appendPrint(text, allocator, "{s} = {d:.6}\n", .{ name, value });
}

fn appendParamVec3(text: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: [3]f32) !void {
    try appendPrint(text, allocator, "{s} = [{d}, {d}, {d}]\n", .{ name, value[0], value[1], value[2] });
}

fn appendParamVec4(text: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: [4]f32) !void {
    try appendPrint(text, allocator, "{s} = [{d}, {d}, {d}, {d}]\n", .{ name, value[0], value[1], value[2], value[3] });
}

fn samplerForTexture(gltf: *const GltfJson, texture_index: u32) GltfSampler {
    if (texture_index >= gltf.textures.len) return .{};
    const sampler_index = gltf.textures[texture_index].sampler orelse return .{};
    if (sampler_index >= gltf.samplers.len) return .{};
    return gltf.samplers[sampler_index];
}

fn filterMode(value: ?u32) raw_material.FilterMode {
    return switch (value orelse 9987) {
        9728, 9984, 9986 => .nearest,
        else => .linear,
    };
}

fn mipFilterMode(value: ?u32) raw_material.MipFilterMode {
    return switch (value orelse 9987) {
        9728, 9729 => .none,
        9984, 9985 => .nearest,
        else => .linear,
    };
}

fn wrapMode(value: u32) raw_material.WrapMode {
    return switch (value) {
        33071 => .clamp_to_edge,
        33648 => .mirrored_repeat,
        else => .repeat,
    };
}

fn appendPrint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}

fn generatedMaterialPath(allocator: std.mem.Allocator, source_path: []const u8, material_name: []const u8) ![]u8 {
    const source_stem = std.fs.path.stem(source_path);
    const safe_name = try sanitizeName(allocator, material_name);
    defer allocator.free(safe_name);
    return std.fmt.allocPrint(allocator, GENERATED_MATERIAL_DIR ++ "/{s}_{s}.zamat", .{ source_stem, safe_name });
}

fn handwrittenMaterialPath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "materials/{s}", .{filename});
}

fn generatedTexturePath(
    allocator: std.mem.Allocator,
    role: TextureRole,
    source_path: []const u8,
    image_name: ?[]const u8,
    image_index: usize,
    mime_type: ?[]const u8,
    fallback_extension: ?[]const u8,
) ![]u8 {
    const source_stem = std.fs.path.stem(source_path);
    const source_hash = SourceFile.fromPath(source_path).hashPath();
    const raw_name = image_name orelse try std.fmt.allocPrint(allocator, "image_{d}", .{image_index});
    const allocated_name = image_name == null;
    defer if (allocated_name) allocator.free(raw_name);

    const safe_name = try sanitizeName(allocator, raw_name);
    defer allocator.free(safe_name);
    return std.fmt.allocPrint(allocator, GENERATED_TEXTURE_DIR ++ "/{s}_{x}_{s}_{s}.{s}", .{
        source_stem,
        source_hash,
        safe_name,
        role.suffix(),
        imageExtension(mime_type, fallback_extension),
    });
}

fn imageExtension(mime_type: ?[]const u8, fallback: ?[]const u8) []const u8 {
    const mime = mime_type orelse return fallback orelse "bin";
    if (std.mem.eql(u8, mime, "image/png")) return "png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/jpg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/vnd-ms.dds")) return "dds";
    if (std.mem.eql(u8, mime, "image/ktx2")) return "ktx2";
    return "bin";
}

fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, @max(name.len, 1));
    if (name.len == 0) {
        out[0] = '_';
        return out;
    }

    for (name, 0..) |c, i| {
        out[i] = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => c,
            else => '_',
        };
    }
    return out;
}

const testing = std.testing;

fn writeTestFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dirname| {
        try dir.createDirPath(testing.io, dirname);
    }
    const file = try dir.createFile(testing.io, path, .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    file.close(testing.io);
}

fn readTestFile(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const result = try file_read.readFileAllocChunked(allocator, testing.io, dir, path);
    return result;
}

test "generateFromGltf writes material with external texture and params" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gltf = try Gltf.parse(
        \\{
        \\  "materials":[{"name":"WoodMaterial","alphaMode":"MASK","alphaCutoff":0.33,"doubleSided":true,"pbrMetallicRoughness":{"baseColorTexture":{"index":0,"texCoord":1},"baseColorFactor":[1,1,1,1],"metallicFactor":0.0,"roughnessFactor":1.0}}],
        \\  "textures":[{"source":0,"sampler":0}],
        \\  "samplers":[{"magFilter":9728,"minFilter":9984,"wrapS":33071,"wrapT":33648}],
        \\  "images":[{"uri":"cube_albedo.png"}]
        \\}
    , testing.allocator);
    defer gltf.deinit();
    try writeTestFile(tmp.dir, "meshes/cube_albedo.png", &.{ 1, 2, 3 });

    const result = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/cube_textured.glb", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 1), result.materials);
    try testing.expectEqual(@as(usize, 1), result.textures);

    const bytes = try readTestFile(testing.allocator, tmp.dir, "generated/materials/cube_textured_WoodMaterial.zamat");
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "alpha_mode = \"alpha_test\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "alpha_cutoff = 0.33") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "double_sided = true") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "cull_mode = \"none\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[texture.u_albedo]") != null);
    const texture_path = try generatedTexturePath(testing.allocator, .albedo, "meshes/cube_textured.glb", null, 0, null, "png");
    defer testing.allocator.free(texture_path);
    const texture_reference = try std.fmt.allocPrint(testing.allocator, "path = \"{s}\"", .{texture_path});
    defer testing.allocator.free(texture_reference);
    try testing.expect(std.mem.indexOf(u8, bytes, texture_reference) != null);
    const tex = try readTestFile(testing.allocator, tmp.dir, texture_path);
    defer testing.allocator.free(tex);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, tex);
    try testing.expect(std.mem.indexOf(u8, bytes, "uv_set = 1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "min_filter = \"nearest\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "mag_filter = \"nearest\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "mip_filter = \"nearest\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "wrap_s = \"clamp_to_edge\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "wrap_t = \"mirrored_repeat\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[params]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_base_color = [1, 1, 1, 1]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_roughness = 1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_metallic = 0") != null);

    var parsed = try raw_material.parseMaterialSource(bytes, testing.allocator);
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), parsed.params.len);

    try writeTestFile(tmp.dir, "meshes/cube_albedo.png", &.{ 4, 5, 6 });
    const refreshed = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/cube_textured.glb", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 0), refreshed.materials);
    try testing.expectEqual(@as(usize, 1), refreshed.textures);
    try testing.expect(refreshed.changed());

    const refreshed_tex = try readTestFile(testing.allocator, tmp.dir, texture_path);
    defer testing.allocator.free(refreshed_tex);
    try testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, refreshed_tex);
}

test "generateFromGltf writes material with no textures" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gltf = try Gltf.parse(
        \\{"materials":[{"pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1],"metallicFactor":0.0,"roughnessFactor":1.0}}]}
    , testing.allocator);
    defer gltf.deinit();

    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/solid.gltf", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 1), count.materials);

    const bytes = try readTestFile(testing.allocator, tmp.dir, "generated/materials/solid_material_0.zamat");
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "[render_state]") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[texture.") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[params]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_base_color = [1, 0, 0, 1]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_metallic = 0") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_roughness = 1") != null);
}

test "generateFromGltf creates a default slot material when gltf has no materials" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gltf: GltfJson = .{};
    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/plain.gltf", &gltf, &.{});
    try testing.expectEqual(@as(usize, 1), count.materials);

    const bytes = try readTestFile(testing.allocator, tmp.dir, "generated/materials/plain_DefaultMaterial.zamat");
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "shader = \"fusion/standard\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[render_state]") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[params]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_base_color = [1, 1, 1, 1]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_metallic = 1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_roughness = 1") != null);
}

test "resolveMaterialPaths preserves gltf order and selects handwritten overrides" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "materials/model_Second.zamat", "[material]\n");

    const materials = [_]GltfMaterial{
        .{ .name = "First" },
        .{ .name = "Second" },
    };
    const gltf: GltfJson = .{ .materials = @constCast(&materials) };
    const paths = try resolveMaterialPaths(testing.allocator, testing.io, tmp.dir, "meshes/model.glb", &gltf);
    defer freeMaterialPaths(testing.allocator, paths);

    try testing.expectEqualStrings("generated/materials/model_First.zamat", paths[0]);
    try testing.expectEqualStrings("materials/model_Second.zamat", paths[1]);
}

test "generateForSource creates a default material for obj" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const count = try generateForSource(testing.allocator, testing.io, tmp.dir, "meshes/monkey.obj", .obj);
    try testing.expectEqual(@as(usize, 1), count.materials);
    try testing.expect(file_read.fileExists(tmp.dir, testing.io, "generated/materials/monkey_DefaultMaterial.zamat"));
}

test "generateFromGltf disables depth writes for blended materials" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gltf = try Gltf.parse(
        \\{"materials":[{"name":"Glass","alphaMode":"BLEND","pbrMetallicRoughness":{"baseColorFactor":[1,1,1,0.5]}}]}
    , testing.allocator);
    defer gltf.deinit();

    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/glass.gltf", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 1), count.materials);

    const bytes = try readTestFile(testing.allocator, tmp.dir, "generated/materials/glass_Glass.zamat");
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "alpha_mode = \"alpha_blend\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "depth_write = false") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "blend_mode = \"alpha\"") != null);
}

test "generateFromGltf preserves occlusion texture strength" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gltf = try Gltf.parse(
        \\{
        \\  "materials":[{"name":"Mat","occlusionTexture":{"index":0,"strength":0.25}}],
        \\  "textures":[{"source":0}],
        \\  "images":[{"uri":"ao.png"}]
        \\}
    , testing.allocator);
    defer gltf.deinit();
    try writeTestFile(tmp.dir, "meshes/ao.png", &.{ 1, 2, 3 });

    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/cube.glb", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 1), count.materials);

    const mat = try readTestFile(testing.allocator, tmp.dir, "generated/materials/cube_Mat.zamat");
    defer testing.allocator.free(mat);
    try testing.expect(std.mem.indexOf(u8, mat, "[texture.u_ao_map]") != null);
    try testing.expect(std.mem.indexOf(u8, mat, "occlusion_strength = 0.25") != null);
}

test "generateFromGltf does not overwrite handwritten material" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/cube_textured_WoodMaterial.zamat", "hand written\n");

    var gltf = try Gltf.parse(
        \\{"materials":[{"name":"WoodMaterial","pbrMetallicRoughness":{}}]}
    , testing.allocator);
    defer gltf.deinit();

    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/cube_textured.glb", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 0), count.materials);
    try testing.expect(!file_read.fileExists(tmp.dir, testing.io, "generated/materials/cube_textured_WoodMaterial.zamat"));
}

test "generateFromGltf extracts embedded image bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gltf = try Gltf.parse(
        \\{
        \\  "materials":[{"name":"Mat","pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],
        \\  "textures":[{"source":0}],
        \\  "images":[{"bufferView":0,"mimeType":"image/png","name":"albedo"}],
        \\  "bufferViews":[{"buffer":0,"byteOffset":1,"byteLength":3}]
        \\}
    , testing.allocator);
    defer gltf.deinit();

    const bin = [_]u8{ 0xaa, 1, 2, 3, 0xbb };
    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/cube.glb", &gltf.value, &.{&bin});
    try testing.expectEqual(@as(usize, 1), count.materials);

    const texture_path = try generatedTexturePath(testing.allocator, .albedo, "meshes/cube.glb", "albedo", 0, "image/png", null);
    defer testing.allocator.free(texture_path);
    const tex = try readTestFile(testing.allocator, tmp.dir, texture_path);
    defer testing.allocator.free(tex);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, tex);

    const mat = try readTestFile(testing.allocator, tmp.dir, "generated/materials/cube_Mat.zamat");
    defer testing.allocator.free(mat);
    try testing.expect(std.mem.indexOf(u8, mat, "[texture.u_albedo]") != null);
    const texture_reference = try std.fmt.allocPrint(testing.allocator, "path = \"{s}\"", .{texture_path});
    defer testing.allocator.free(texture_reference);
    try testing.expect(std.mem.indexOf(u8, mat, texture_reference) != null);
    try testing.expect(std.mem.indexOf(u8, mat, "uv_set =") == null);
    try testing.expect(std.mem.indexOf(u8, mat, "min_filter =") == null);
    try testing.expect(std.mem.indexOf(u8, mat, "max_anisotropy =") == null);
}

test "generateFromGltf namespaces textures by source path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try Gltf.parse(
        \\{
        \\  "materials":[{"name":"First","pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],
        \\  "textures":[{"source":0}],
        \\  "images":[{"uri":"image.png"}]
        \\}
    , testing.allocator);
    defer first.deinit();
    var second = try Gltf.parse(
        \\{
        \\  "materials":[{"name":"Second","pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],
        \\  "textures":[{"source":0}],
        \\  "images":[{"uri":"image.png"}]
        \\}
    , testing.allocator);
    defer second.deinit();
    try writeTestFile(tmp.dir, "a/image.png", &.{ 1, 2, 3 });
    try writeTestFile(tmp.dir, "b/image.png", &.{ 4, 5, 6 });

    _ = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "a/model.gltf", &first.value, &.{});
    _ = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "b/model.gltf", &second.value, &.{});

    const first_path = try generatedTexturePath(testing.allocator, .albedo, "a/model.gltf", null, 0, null, "png");
    defer testing.allocator.free(first_path);
    const second_path = try generatedTexturePath(testing.allocator, .albedo, "b/model.gltf", null, 0, null, "png");
    defer testing.allocator.free(second_path);
    try testing.expect(!std.mem.eql(u8, first_path, second_path));

    const first_texture = try readTestFile(testing.allocator, tmp.dir, first_path);
    defer testing.allocator.free(first_texture);
    const second_texture = try readTestFile(testing.allocator, tmp.dir, second_path);
    defer testing.allocator.free(second_texture);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, first_texture);
    try testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, second_texture);
}
