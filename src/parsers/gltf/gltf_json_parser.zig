const std = @import("std");

pub const AccessorView = @import("accessor_view.zig").AccessorView;
const material = @import("../../assets/raw/material.zig");

const RenderState = material.RenderState;
const AlphaMode = material.AlphaMode;
const BlendMode = material.BlendMode;

pub const Gltf = struct {
    value: GltfJson,
    arena: *std.heap.ArenaAllocator,

    pub fn parse(json_bytes: []const u8, allocator: std.mem.Allocator) !Gltf {
        const parsed = try std.json.parseFromSlice(GltfJson, allocator, json_bytes, .{
            .ignore_unknown_fields = true,
        });

        return .{
            .value = parsed.value,
            .arena = parsed.arena,
        };
    }

    pub fn deinit(self: *Gltf) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const GltfJson = struct {
    scene: ?u32 = null,
    scenes: []GltfScene = &.{},
    nodes: []GltfNode = &.{},
    meshes: []GltfMesh = &.{},
    accessors: []GltfAccessor = &.{},
    bufferViews: []GltfBufferView = &.{},
    buffers: []GltfBuffer = &.{},
    materials: []GltfMaterial = &.{},
    textures: []GltfTexture = &.{},
    samplers: []GltfSampler = &.{},
    images: []GltfImage = &.{},
};

pub const GltfScene = struct {
    nodes: []u32 = &.{},
};

pub const GltfNode = struct {
    name: ?[]const u8 = null,
    mesh: ?u32 = null,
    skin: ?u32 = null,
    children: []u32 = &.{},
    translation: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },
    matrix: ?[16]f32 = null,
};

pub const GltfMesh = struct {
    name: ?[]const u8 = null,
    primitives: []GltfPrimitive = &.{},
};

pub const GltfPrimitive = struct {
    attributes: GltfAttributes = .{},
    indices: ?u32 = null,
    material: ?u32 = null,
    mode: u32 = 4,
};

pub const GltfAttributes = struct {
    POSITION: ?u32 = null,
    NORMAL: ?u32 = null,
    TANGENT: ?u32 = null,
    TEXCOORD_0: ?u32 = null,
    TEXCOORD_1: ?u32 = null,
    JOINTS_0: ?u32 = null,
    WEIGHTS_0: ?u32 = null,
};

pub const AccessorType = enum {
    SCALAR,
    VEC2,
    VEC3,
    VEC4,
    MAT4,

    pub fn componentCount(self: AccessorType) usize {
        return switch (self) {
            .SCALAR => 1,
            .VEC2 => 2,
            .VEC3 => 3,
            .VEC4 => 4,
            .MAT4 => 16,
        };
    }
};

pub const GltfAccessorError = error{
    OutOfBounds,
    OutOfMemory,
};

pub const GltfAccessor = struct {
    bufferView: ?u32 = null,
    byteOffset: u32 = 0,
    componentType: AccessorComponentType,
    count: u32,
    type: AccessorType,
    normalized: bool = false,
    min: ?[]f64 = null,
    max: ?[]f64 = null,

    pub fn accessorView(self: *const GltfAccessor, buffer_views: []const GltfBufferView, buffers: []const []const u8) GltfAccessorError!AccessorView {
        const buffer_view_value = self.bufferView orelse return GltfAccessorError.OutOfBounds;
        if (buffer_view_value >= buffer_views.len) {
            return GltfAccessorError.OutOfBounds;
        }
        const buffer_view = buffer_views[buffer_view_value];
        if (buffer_view.buffer >= buffers.len) {
            return GltfAccessorError.OutOfBounds;
        }
        const bin = buffers[buffer_view.buffer];

        const view_start: usize = buffer_view.byteOffset;
        const view_len: usize = buffer_view.byteLength;
        if (view_start > bin.len or view_len > bin.len - view_start) {
            return GltfAccessorError.OutOfBounds;
        }

        const accessor_offset: usize = self.byteOffset;
        if (accessor_offset > view_len) {
            return GltfAccessorError.OutOfBounds;
        }

        const start = std.math.add(usize, view_start, accessor_offset) catch return GltfAccessorError.OutOfBounds;
        const component_size = self.componentType.size();
        const num_components = self.type.componentCount();
        const element_size = std.math.mul(usize, component_size, num_components) catch return GltfAccessorError.OutOfBounds;
        const stride: usize = buffer_view.byteStride orelse @intCast(element_size);
        if (stride < element_size or stride % component_size != 0) {
            return GltfAccessorError.OutOfBounds;
        }

        const count: usize = self.count;
        if (count > 0) {
            const last_stride = std.math.mul(usize, stride, count - 1) catch return GltfAccessorError.OutOfBounds;
            const last_start = std.math.add(usize, accessor_offset, last_stride) catch return GltfAccessorError.OutOfBounds;
            const required = std.math.add(usize, last_start, element_size) catch return GltfAccessorError.OutOfBounds;
            if (required > view_len) {
                return GltfAccessorError.OutOfBounds;
            }
        }

        return .{
            .bytes = bin,
            .start = start,
            .stride = stride,
            .element_size = element_size,
            .count = count,
            .component_type = @backingInt(self.componentType),
            .component_count = num_components,
            .component_size = component_size,
            .normalized = self.normalized,
        };
    }
};

pub const AccessorComponentType = enum(u32) {
    BYTE = 5120,
    UNSIGNED_BYTE = 5121,
    SHORT = 5122,
    UNSIGNED_SHORT = 5123,
    UNSIGNED_INT = 5125,
    FLOAT = 5126,

    pub fn size(self: AccessorComponentType) usize {
        return switch (self) {
            .BYTE, .UNSIGNED_BYTE => 1,
            .SHORT, .UNSIGNED_SHORT => 2,
            .FLOAT, .UNSIGNED_INT => 4,
        };
    }
};

pub const GltfBufferView = struct {
    buffer: u32,
    byteOffset: u32 = 0,
    byteLength: u32,
    byteStride: ?u32 = null,
    target: ?u32 = null,
};

pub const GltfBuffer = struct {
    byteLength: u32,
    uri: ?[]const u8 = null,
};

fn mapAlphaMode(value: ?[]const u8) AlphaMode {
    const mode = value orelse return .solid;
    if (std.ascii.eqlIgnoreCase(mode, "MASK")) {
        return .alpha_test;
    }
    if (std.ascii.eqlIgnoreCase(mode, "BLEND")) {
        return .alpha_blend;
    }
    return .solid;
}

fn mapBlendMode(value: ?[]const u8) BlendMode {
    const mode = value orelse return .disabled;
    if (std.ascii.eqlIgnoreCase(mode, "BLEND")) {
        return .alpha;
    }
    return .disabled;
}

fn isAlphaBlend(value: ?[]const u8) bool {
    const mode = value orelse return false;
    return std.ascii.eqlIgnoreCase(mode, "BLEND");
}

pub const GltfMaterial = struct {
    name: ?[]const u8 = null,
    pbrMetallicRoughness: ?GltfPbr = null,
    normalTexture: ?GltfTextureInfo = null,
    occlusionTexture: ?GltfTextureInfo = null,
    emissiveTexture: ?GltfTextureInfo = null,
    emissiveFactor: ?[3]f32 = null,
    alphaMode: ?[]const u8 = null,
    alphaCutoff: f32 = 0.5,
    doubleSided: bool = false,

    pub fn renderState(self: *const GltfMaterial) RenderState {
        return .{
            .alpha_mode = mapAlphaMode(self.alphaMode),
            .alpha_cutoff = self.alphaCutoff,
            .double_sided = self.doubleSided,
            .cull_mode = if (self.doubleSided) .none else .back,
            .depth_test = true,
            .depth_write = if (isAlphaBlend(self.alphaMode)) false else true,
            .blend_mode = mapBlendMode(self.alphaMode),
        };
    }
};

pub const GltfPbr = struct {
    baseColorFactor: [4]f32 = .{ 1, 1, 1, 1 },
    metallicFactor: f32 = 1.0,
    roughnessFactor: f32 = 1.0,
    baseColorTexture: ?GltfTextureInfo = null,
    metallicRoughnessTexture: ?GltfTextureInfo = null,
};

pub const GlftTextureTransform = struct {
    offset: [2]f32 = .{ 0, 0 },
    rotation: f32 = 0,
    scale: [2]f32 = .{ 1, 1 },
    texCoord: ?u32 = null,
};

pub const GlftTextureExtensions = struct {
    KHR_texture_transform: ?GlftTextureTransform = null,
};

pub const GltfTextureInfo = struct {
    index: u32,
    texCoord: u32 = 0,
    scale: ?f32 = null,
    strength: ?f32 = null,
    extensions: ?GlftTextureExtensions = null,
};

pub const GltfTexture = struct {
    source: ?u32 = null,
    sampler: ?u32 = null,
};

pub const GltfSampler = struct {
    magFilter: ?u32 = null,
    minFilter: ?u32 = null,
    wrapS: u32 = 10497,
    wrapT: u32 = 10497,
};

pub const GltfImage = struct {
    bufferView: ?u32 = null,
    mimeType: ?[]const u8 = null,
    name: ?[]const u8 = null,
    uri: ?[]const u8 = null,
};

const testing = std.testing;

test "parse minimal gltf" {
    var gltf = try Gltf.parse("{}", testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(0, gltf.value.scenes.len);
    try testing.expectEqual(0, gltf.value.nodes.len);
    try testing.expectEqual(0, gltf.value.meshes.len);
    try testing.expectEqual(0, gltf.value.accessors.len);
    try testing.expectEqual(0, gltf.value.bufferViews.len);
    try testing.expectEqual(0, gltf.value.buffers.len);
    try testing.expectEqual(0, gltf.value.materials.len);
    try testing.expectEqual(0, gltf.value.textures.len);
    try testing.expectEqual(0, gltf.value.images.len);
}

test "parse ignores unknown fields" {
    var gltf = try Gltf.parse(
        \\{"asset":{"version":"2.0"},"scene":0,"samplers":[{}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(0, gltf.value.nodes.len);
}

test "parse scenes" {
    var gltf = try Gltf.parse(
        \\{"scenes":[{"nodes":[0,1]},{"nodes":[2]}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(2, gltf.value.scenes.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, gltf.value.scenes[0].nodes);
    try testing.expectEqualSlices(u32, &.{2}, gltf.value.scenes[1].nodes);
}

test "parse nodes with defaults" {
    var gltf = try Gltf.parse(
        \\{"nodes":[{"name":"Camera"},{}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(2, gltf.value.nodes.len);

    const cam = gltf.value.nodes[0];
    try testing.expectEqualStrings("Camera", cam.name.?);
    try testing.expectEqual(null, cam.mesh);
    try testing.expectEqual(null, cam.skin);
    try testing.expectEqual(0, cam.children.len);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, cam.translation);
    try testing.expectEqual([4]f32{ 0, 0, 0, 1 }, cam.rotation);
    try testing.expectEqual([3]f32{ 1, 1, 1 }, cam.scale);
    try testing.expectEqual(null, cam.matrix);

    const empty = gltf.value.nodes[1];
    try testing.expectEqual(null, empty.name);
}

test "parse node with all fields" {
    var gltf = try Gltf.parse(
        \\{"nodes":[{
        \\  "name":"Arm","mesh":2,"skin":1,
        \\  "children":[3,4],
        \\  "translation":[1.0,2.0,3.0],
        \\  "rotation":[0.0,0.707,0.0,0.707],
        \\  "scale":[2.0,2.0,2.0]
        \\}]}
    , testing.allocator);
    defer gltf.deinit();

    const node = gltf.value.nodes[0];
    try testing.expectEqualStrings("Arm", node.name.?);
    try testing.expectEqual(2, node.mesh.?);
    try testing.expectEqual(1, node.skin.?);
    try testing.expectEqualSlices(u32, &.{ 3, 4 }, node.children);
    try testing.expectEqual([3]f32{ 1.0, 2.0, 3.0 }, node.translation);
    try testing.expectEqual([3]f32{ 2.0, 2.0, 2.0 }, node.scale);
}

test "parse meshes and primitives" {
    var gltf = try Gltf.parse(
        \\{"meshes":[{
        \\  "name":"Cube",
        \\  "primitives":[{
        \\    "attributes":{"POSITION":1,"NORMAL":2,"TEXCOORD_0":3},
        \\    "indices":0,
        \\    "material":0
        \\  }]
        \\}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(1, gltf.value.meshes.len);
    try testing.expectEqualStrings("Cube", gltf.value.meshes[0].name.?);

    const prim = gltf.value.meshes[0].primitives[0];
    try testing.expectEqual(1, prim.attributes.POSITION.?);
    try testing.expectEqual(2, prim.attributes.NORMAL.?);
    try testing.expectEqual(3, prim.attributes.TEXCOORD_0.?);
    try testing.expectEqual(null, prim.attributes.TANGENT);
    try testing.expectEqual(null, prim.attributes.TEXCOORD_1);
    try testing.expectEqual(null, prim.attributes.JOINTS_0);
    try testing.expectEqual(null, prim.attributes.WEIGHTS_0);
    try testing.expectEqual(0, prim.indices.?);
    try testing.expectEqual(0, prim.material.?);
    try testing.expectEqual(4, prim.mode);
}

test "parse primitive with explicit mode" {
    var gltf = try Gltf.parse(
        \\{"meshes":[{"primitives":[{"attributes":{},"mode":1}]}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(1, gltf.value.meshes[0].primitives[0].mode);
}

test "parse accessors" {
    var gltf = try Gltf.parse(
        \\{"accessors":[
        \\  {"bufferView":0,"componentType":5123,"count":36,"type":"SCALAR","max":[23],"min":[0]},
        \\  {"componentType":5126,"count":24,"type":"VEC3"},
        \\  {"bufferView":3,"byteOffset":12,"componentType":5126,"count":24,"type":"VEC2"}
        \\]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(3, gltf.value.accessors.len);

    const a0 = gltf.value.accessors[0];
    try testing.expectEqual(0, a0.bufferView.?);
    try testing.expectEqual(0, a0.byteOffset);
    try testing.expectEqual(.UNSIGNED_SHORT, a0.componentType);
    try testing.expectEqual(36, a0.count);
    try testing.expectEqual(.SCALAR, a0.type);
    try testing.expectEqual(1, a0.max.?.len);
    try testing.expectEqual(1, a0.min.?.len);

    const a1 = gltf.value.accessors[1];
    try testing.expectEqual(null, a1.bufferView);
    try testing.expectEqual(.VEC3, a1.type);
    try testing.expectEqual(null, a1.max);
    try testing.expectEqual(null, a1.min);

    const a2 = gltf.value.accessors[2];
    try testing.expectEqual(12, a2.byteOffset);
    try testing.expectEqual(.VEC2, a2.type);
}

test "parse all accessor types" {
    var gltf = try Gltf.parse(
        \\{"accessors":[
        \\  {"componentType":5126,"count":1,"type":"SCALAR"},
        \\  {"componentType":5126,"count":1,"type":"VEC2"},
        \\  {"componentType":5126,"count":1,"type":"VEC3"},
        \\  {"componentType":5126,"count":1,"type":"VEC4"},
        \\  {"componentType":5126,"count":1,"type":"MAT4"}
        \\]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(.SCALAR, gltf.value.accessors[0].type);
    try testing.expectEqual(.VEC2, gltf.value.accessors[1].type);
    try testing.expectEqual(.VEC3, gltf.value.accessors[2].type);
    try testing.expectEqual(.VEC4, gltf.value.accessors[3].type);
    try testing.expectEqual(.MAT4, gltf.value.accessors[4].type);
}

test "parse buffer views" {
    var gltf = try Gltf.parse(
        \\{"bufferViews":[
        \\  {"buffer":0,"byteOffset":0,"byteLength":72,"target":34963},
        \\  {"buffer":0,"byteOffset":72,"byteLength":288,"byteStride":12,"target":34962},
        \\  {"buffer":0,"byteOffset":840,"byteLength":81}
        \\]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(3, gltf.value.bufferViews.len);

    const bv0 = gltf.value.bufferViews[0];
    try testing.expectEqual(0, bv0.buffer);
    try testing.expectEqual(0, bv0.byteOffset);
    try testing.expectEqual(72, bv0.byteLength);
    try testing.expectEqual(34963, bv0.target.?);
    try testing.expectEqual(null, bv0.byteStride);

    const bv1 = gltf.value.bufferViews[1];
    try testing.expectEqual(12, bv1.byteStride.?);

    const bv2 = gltf.value.bufferViews[2];
    try testing.expectEqual(null, bv2.target);
}

test "parse buffers" {
    var gltf = try Gltf.parse(
        \\{"buffers":[{"byteLength":1084},{"byteLength":256,"uri":"ext.bin"}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(2, gltf.value.buffers.len);
    try testing.expectEqual(1084, gltf.value.buffers[0].byteLength);
    try testing.expectEqual(null, gltf.value.buffers[0].uri);
    try testing.expectEqual(256, gltf.value.buffers[1].byteLength);
    try testing.expectEqualStrings("ext.bin", gltf.value.buffers[1].uri.?);
}

test "parse materials with pbr" {
    var gltf = try Gltf.parse(
        \\{"materials":[{
        \\  "name":"WoodMaterial",
        \\  "pbrMetallicRoughness":{
        \\    "baseColorFactor":[0.8,0.2,0.2,1.0],
        \\    "metallicFactor":0.0,
        \\    "roughnessFactor":0.8,
        \\    "baseColorTexture":{"index":0},
        \\    "metallicRoughnessTexture":{"index":2}
        \\  },
        \\  "normalTexture":{"index":1,"scale":1.0},
        \\  "occlusionTexture":{"index":3,"strength":0.4},
        \\  "emissiveTexture":{"index":4},
        \\  "emissiveFactor":[0.0,0.0,0.0],
        \\  "alphaMode":"MASK",
        \\  "alphaCutoff":0.33,
        \\  "doubleSided":true
        \\}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(1, gltf.value.materials.len);
    const mat = gltf.value.materials[0];
    try testing.expectEqualStrings("WoodMaterial", mat.name.?);
    try testing.expectEqualStrings("MASK", mat.alphaMode.?);
    try testing.expectEqual(@as(f32, 0.33), mat.alphaCutoff);
    try testing.expect(mat.doubleSided);
    try testing.expectEqual([3]f32{ 0.0, 0.0, 0.0 }, mat.emissiveFactor.?);

    const pbr = mat.pbrMetallicRoughness.?;
    try testing.expectEqual([4]f32{ 0.8, 0.2, 0.2, 1.0 }, pbr.baseColorFactor);
    try testing.expectEqual(@as(f32, 0.0), pbr.metallicFactor);
    try testing.expectEqual(@as(f32, 0.8), pbr.roughnessFactor);
    try testing.expectEqual(0, pbr.baseColorTexture.?.index);
    try testing.expectEqual(2, pbr.metallicRoughnessTexture.?.index);

    const normal = mat.normalTexture.?;
    try testing.expectEqual(1, normal.index);
    try testing.expectEqual(@as(f32, 1.0), normal.scale.?);
    try testing.expectEqual(0, normal.texCoord);
    try testing.expectEqual(3, mat.occlusionTexture.?.index);
    try testing.expectEqual(@as(f32, 0.4), mat.occlusionTexture.?.strength.?);
    try testing.expectEqual(4, mat.emissiveTexture.?.index);

    const state = mat.renderState();
    try testing.expectEqual(AlphaMode.alpha_test, state.alpha_mode);
    try testing.expectEqual(@as(f32, 0.33), state.alpha_cutoff);
    try testing.expect(state.double_sided);
    try testing.expectEqual(material.CullMode.none, state.cull_mode);
    try testing.expect(state.depth_write);
    try testing.expectEqual(BlendMode.disabled, state.blend_mode);
}

test "material render state maps blended glTF materials" {
    const material_source: GltfMaterial = .{ .alphaMode = "BLEND" };
    const state = material_source.renderState();
    try testing.expectEqual(AlphaMode.alpha_blend, state.alpha_mode);
    try testing.expect(!state.depth_write);
    try testing.expectEqual(BlendMode.alpha, state.blend_mode);
}

test "parse material with pbr defaults" {
    var gltf = try Gltf.parse(
        \\{"materials":[{"pbrMetallicRoughness":{}}]}
    , testing.allocator);
    defer gltf.deinit();

    const pbr = gltf.value.materials[0].pbrMetallicRoughness.?;
    try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, pbr.baseColorFactor);
    try testing.expectEqual(@as(f32, 1.0), pbr.metallicFactor);
    try testing.expectEqual(@as(f32, 1.0), pbr.roughnessFactor);
    try testing.expectEqual(null, pbr.baseColorTexture);
    try testing.expectEqual(null, pbr.metallicRoughnessTexture);
}

test "parse material with no pbr" {
    var gltf = try Gltf.parse(
        \\{"materials":[{"name":"Simple"}]}
    , testing.allocator);
    defer gltf.deinit();

    const mat = gltf.value.materials[0];
    try testing.expectEqualStrings("Simple", mat.name.?);
    try testing.expectEqual(null, mat.pbrMetallicRoughness);
    try testing.expectEqual(null, mat.normalTexture);
    try testing.expectEqual(null, mat.occlusionTexture);
    try testing.expectEqual(null, mat.emissiveTexture);
    try testing.expectEqual(null, mat.emissiveFactor);
    try testing.expectEqual(null, mat.alphaMode);
}

test "parse textures" {
    var gltf = try Gltf.parse(
        \\{"textures":[{"source":0,"sampler":0},{"source":1},{}],"samplers":[{"magFilter":9728,"minFilter":9984,"wrapS":33071,"wrapT":33648}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(3, gltf.value.textures.len);
    try testing.expectEqual(0, gltf.value.textures[0].source.?);
    try testing.expectEqual(0, gltf.value.textures[0].sampler.?);
    try testing.expectEqual(1, gltf.value.textures[1].source.?);
    try testing.expectEqual(null, gltf.value.textures[1].sampler);
    try testing.expectEqual(null, gltf.value.textures[2].source);
    try testing.expectEqual(@as(usize, 1), gltf.value.samplers.len);
    try testing.expectEqual(@as(u32, 9728), gltf.value.samplers[0].magFilter.?);
    try testing.expectEqual(@as(u32, 9984), gltf.value.samplers[0].minFilter.?);
    try testing.expectEqual(@as(u32, 33071), gltf.value.samplers[0].wrapS);
    try testing.expectEqual(@as(u32, 33648), gltf.value.samplers[0].wrapT);
}

test "parse images with buffer view" {
    var gltf = try Gltf.parse(
        \\{"images":[
        \\  {"bufferView":4,"mimeType":"image/png","name":"albedo"},
        \\  {"uri":"texture.png","name":"external"}
        \\]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(2, gltf.value.images.len);

    const img0 = gltf.value.images[0];
    try testing.expectEqual(4, img0.bufferView.?);
    try testing.expectEqualStrings("image/png", img0.mimeType.?);
    try testing.expectEqualStrings("albedo", img0.name.?);
    try testing.expectEqual(null, img0.uri);

    const img1 = gltf.value.images[1];
    try testing.expectEqual(null, img1.bufferView);
    try testing.expectEqual(null, img1.mimeType);
    try testing.expectEqualStrings("external", img1.name.?);
    try testing.expectEqualStrings("texture.png", img1.uri.?);
}

test "parse full triangle gltf" {
    const json_str =
        \\{
        \\  "scenes":[{"nodes":[0]}],
        \\  "nodes":[{"mesh":0,"name":"Triangle"}],
        \\  "meshes":[{"primitives":[{"attributes":{"POSITION":1,"NORMAL":2,"TEXCOORD_0":3},"indices":0,"material":0}],"name":"TriangleMesh"}],
        \\  "materials":[{"name":"DefaultMaterial","pbrMetallicRoughness":{"baseColorFactor":[0.8,0.2,0.2,1.0],"metallicFactor":0.0,"roughnessFactor":0.8}}],
        \\  "accessors":[
        \\    {"bufferView":0,"componentType":5123,"count":3,"type":"SCALAR","max":[2],"min":[0]},
        \\    {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
        \\    {"bufferView":2,"componentType":5126,"count":3,"type":"VEC3"},
        \\    {"bufferView":3,"componentType":5126,"count":3,"type":"VEC2"}
        \\  ],
        \\  "bufferViews":[
        \\    {"buffer":0,"byteOffset":0,"byteLength":6,"target":34963},
        \\    {"buffer":0,"byteOffset":8,"byteLength":36,"target":34962},
        \\    {"buffer":0,"byteOffset":44,"byteLength":36,"target":34962},
        \\    {"buffer":0,"byteOffset":80,"byteLength":24,"target":34962}
        \\  ],
        \\  "buffers":[{"byteLength":104}]
        \\}
    ;

    var gltf = try Gltf.parse(json_str, testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(1, gltf.value.scenes.len);
    try testing.expectEqual(1, gltf.value.nodes.len);
    try testing.expectEqual(1, gltf.value.meshes.len);
    try testing.expectEqual(1, gltf.value.materials.len);
    try testing.expectEqual(4, gltf.value.accessors.len);
    try testing.expectEqual(4, gltf.value.bufferViews.len);
    try testing.expectEqual(1, gltf.value.buffers.len);
    try testing.expectEqual(104, gltf.value.buffers[0].byteLength);
}

test "parse returns error on invalid json" {
    try testing.expectError(error.SyntaxError, Gltf.parse("{invalid", testing.allocator));
}

test "parse returns error on missing required field" {
    try testing.expectError(error.MissingField, Gltf.parse(
        \\{"accessors":[{"count":1,"type":"SCALAR"}]}
    , testing.allocator));
}

test "parse returns error on invalid accessor type" {
    try testing.expectError(error.InvalidEnumTag, Gltf.parse(
        \\{"accessors":[{"componentType":5126,"count":1,"type":"INVALID"}]}
    , testing.allocator));
}

test "accessor views decode interleaved data without a copy" {
    const bytes = [_]u8{
        0, 0, 128, 63, 0, 0, 0,   64, 0xaa, 0xbb, 0xcc, 0xdd,
        0, 0, 64,  64, 0, 0, 128, 64, 0xee, 0xff, 0x11, 0x22,
    };
    const views = [_]GltfBufferView{.{ .buffer = 0, .byteLength = bytes.len, .byteStride = 12 }};
    const buffers = [_][]const u8{&bytes};
    const accessor = GltfAccessor{
        .bufferView = 0,
        .componentType = .FLOAT,
        .count = 2,
        .type = .VEC2,
    };

    const view = try accessor.accessorView(&views, &buffers);
    try testing.expectEqual(@intFromPtr(bytes[0..].ptr), @intFromPtr(view.bytes.ptr));
    try testing.expectEqual([2]f32{ 1, 2 }, try view.readVec2(0));
    try testing.expectEqual([2]f32{ 3, 4 }, try view.readVec2(1));
}

test "accessor view validates zero count, stride, truncation, and overflow" {
    const bytes: [16]u8 = @splat(0);
    const buffers = [_][]const u8{&bytes};
    const views = [_]GltfBufferView{.{ .buffer = 0, .byteLength = bytes.len, .byteStride = 8 }};
    const packed_views = [_]GltfBufferView{.{ .buffer = 0, .byteLength = bytes.len }};
    const zero_count = GltfAccessor{ .bufferView = 0, .byteOffset = 16, .componentType = .FLOAT, .count = 0, .type = .VEC3 };
    try testing.expectEqual(@as(usize, 0), (try zero_count.accessorView(&packed_views, &buffers)).count);

    const undersized_stride = GltfAccessor{ .bufferView = 0, .componentType = .FLOAT, .count = 1, .type = .VEC3 };
    try testing.expectError(GltfAccessorError.OutOfBounds, undersized_stride.accessorView(&views, &buffers));

    const truncated = GltfAccessor{ .bufferView = 0, .byteOffset = 8, .componentType = .FLOAT, .count = 2, .type = .VEC2 };
    try testing.expectError(GltfAccessorError.OutOfBounds, truncated.accessorView(&views, &buffers));

    const overflow = GltfAccessor{ .bufferView = 0, .byteOffset = std.math.maxInt(u32), .componentType = .FLOAT, .count = 1, .type = .VEC2 };
    try testing.expectError(GltfAccessorError.OutOfBounds, overflow.accessorView(&views, &buffers));
}

test "deinit frees memory" {
    var gltf = try Gltf.parse(
        \\{"nodes":[{"name":"A"},{"name":"B"},{"name":"C"}],"buffers":[{"byteLength":100}]}
    , testing.allocator);
    gltf.deinit();
}
