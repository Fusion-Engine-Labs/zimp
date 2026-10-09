const std = @import("std");

const raw_mesh = @import("../raw/mesh.zig");
const MeshScratch = raw_mesh.MeshScratch;
const RawVertex = raw_mesh.RawVertex;
pub const UV0Bounds = raw_mesh.UV0Bounds;
const RawMesh = raw_mesh.RawMesh;

pub const FormatFlags = packed struct(u8) {
    has_normals: bool = false,
    has_tangents: bool = false,
    has_uv0: bool = false,
    has_uv1: bool = false,
    has_joints: bool = false,
    has_weights: bool = false,
    _padding: u2 = 0, // pad to u8
};

/// One vertex in its on-disk (quantized) encoding. Every field is filled;
/// attributes the source lacks hold `default_vertex` values and are only
/// written when the mesh's `FormatFlags` say the stream is present.
pub const CookedVertex = struct {
    /// u16 unorm relative to the mesh AABB, w = 0.
    position: [4]u16,
    /// Octahedral snorm16.
    normal: [2]i16,
    /// Octahedral snorm8 xy, handedness sign, 0.
    tangent: [4]i8,
    /// unorm16 relative to `UV0Bounds`.
    uv0: [2]u16,
    /// unorm16 over [0, 1].
    uv1: [2]u16,
    joints: [4]u16,
    /// unorm8, summing to 255.
    weights: [4]u8,

    pub const defaults: CookedVertex = .{
        .position = .{ 0, 0, 0, 0 },
        .normal = .{ 0, 0 }, // +Z
        .tangent = .{ 127, 0, 127, 0 }, // +X, right-handed
        .uv0 = .{ 0, 0 },
        .uv1 = .{ 0, 0 },
        .joints = .{ 0, 0, 0, 0 },
        .weights = .{ 255, 0, 0, 0 },
    };

    pub fn cook(vertex: *const RawVertex, bounds: *const AABB, uv0_bounds: *const UV0Bounds) CookedVertex {
        const d = defaults;
        return .{
            .position = raw_mesh.quantizePosition(vertex.position, bounds.min, bounds.max),
            .normal = vertex.encodeNormalOctahedral() orelse d.normal,
            .tangent = vertex.encodeTangentOctahedral() orelse d.tangent,
            .uv0 = vertex.quantizeUV0(uv0_bounds) orelse d.uv0,
            .uv1 = vertex.quantizeUV1() orelse d.uv1,
            .joints = vertex.joint_indices orelse d.joints,
            .weights = vertex.quantizeJointWeights() orelse d.weights,
        };
    }
};

pub const AABB = struct {
    min: [3]f32,
    max: [3]f32,

    pub fn of(vertices: []const RawVertex) AABB {
        if (vertices.len == 0) return .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } };
        var bounds = AABB{ .min = vertices[0].position, .max = vertices[0].position };
        for (vertices[1..]) |v| {
            for (0..3) |axis| {
                bounds.min[axis] = @min(bounds.min[axis], v.position[axis]);
                bounds.max[axis] = @max(bounds.max[axis], v.position[axis]);
            }
        }
        return bounds;
    }
};

pub const IndexFormat = enum {
    u16,
    u32,
};

/// One cooked mesh part: quantized vertices plus part-local triangle-list
/// indices.
pub const CookedMesh = struct {
    vertices: []CookedVertex,
    indices: []u32,
    submeshes: []raw_mesh.RawSubmesh,
    format_flags: FormatFlags,
    bounds: AABB,
    name: ?[]const u8,
    uv0_bounds: UV0Bounds = .{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } },

    pub fn deinit(self: *CookedMesh, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
        allocator.free(self.submeshes);
        if (self.name) |name| allocator.free(name);
    }

    pub fn cook(allocator: std.mem.Allocator, mesh: *RawMesh) !CookedMesh {
        var scratch = MeshScratch.init(allocator);
        defer scratch.deinit();
        return cookWithScratch(allocator, mesh, &scratch);
    }

    pub fn cookWithScratch(allocator: std.mem.Allocator, mesh: *RawMesh, scratch: *MeshScratch) !CookedMesh {
        try mesh.optimizeWithScratch(allocator, scratch);

        // A stream is present if any vertex has it; the rest get defaults.
        var flags: FormatFlags = .{};
        for (mesh.vertices) |v| {
            flags.has_normals = flags.has_normals or v.normal != null;
            flags.has_tangents = flags.has_tangents or v.tangent != null;
            flags.has_uv0 = flags.has_uv0 or v.uv0 != null;
            flags.has_uv1 = flags.has_uv1 or v.uv1 != null;
            flags.has_joints = flags.has_joints or v.joint_indices != null;
            flags.has_weights = flags.has_weights or v.joint_weights != null;
        }

        const bounds = AABB.of(mesh.vertices);
        const uv0_bounds = UV0Bounds.compute(mesh.vertices);
        const cooked_verts = try allocator.alloc(CookedVertex, mesh.vertices.len);
        errdefer allocator.free(cooked_verts);
        for (mesh.vertices, cooked_verts) |*raw_vert, *cooked| {
            cooked.* = CookedVertex.cook(raw_vert, &bounds, &uv0_bounds);
        }

        const indices = try allocator.dupe(u32, mesh.indices);
        errdefer allocator.free(indices);
        const submeshes = try allocator.dupe(raw_mesh.RawSubmesh, mesh.submeshes);
        errdefer allocator.free(submeshes);
        const name = if (mesh.name) |name| try allocator.dupe(u8, name) else null;
        errdefer if (name) |owned_name| allocator.free(owned_name);

        return .{
            .vertices = cooked_verts,
            .indices = indices,
            .submeshes = submeshes,
            .format_flags = flags,
            .bounds = bounds,
            .name = name,
            .uv0_bounds = uv0_bounds,
        };
    }
};

fn makeRawVertex(x: f32, y: f32, z: f32) RawVertex {
    return .{
        .position = .{ x, y, z },
        .normal = null,
        .tangent = null,
        .uv0 = null,
        .uv1 = null,
        .joint_indices = null,
        .joint_weights = null,
    };
}

fn makeRawMesh(allocator: std.mem.Allocator, vertices: []const RawVertex, indices: []const u32) !RawMesh {
    return .{
        .vertices = try allocator.dupe(RawVertex, vertices),
        .indices = try allocator.dupe(u32, indices),
        .submeshes = &.{},
        .name = null,
    };
}

test "FormatFlags defaults to all false" {
    const flags = FormatFlags{};
    try std.testing.expect(!flags.has_normals);
    try std.testing.expect(!flags.has_tangents);
    try std.testing.expect(!flags.has_uv0);
    try std.testing.expect(!flags.has_uv1);
    try std.testing.expect(!flags.has_joints);
    try std.testing.expect(!flags.has_weights);
}

test "FormatFlags fits in a u8" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(FormatFlags));
}

test "FormatFlags roundtrips through u8" {
    const flags = FormatFlags{ .has_normals = true, .has_uv0 = true, .has_weights = true };
    const as_int: u8 = @bitCast(flags);
    const back: FormatFlags = @bitCast(as_int);
    try std.testing.expectEqual(flags, back);
}

test "CookedVertex.cook quantizes position against the AABB" {
    const raw = makeRawVertex(1, -2, 3);
    const bounds = AABB{ .min = .{ -1, -2, 3 }, .max = .{ 1, 2, 3 } };
    const uv0_bounds = UV0Bounds{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } };
    const cooked = CookedVertex.cook(&raw, &bounds, &uv0_bounds);
    try std.testing.expectEqual([4]u16{ 65535, 0, 0, 0 }, cooked.position);
}

test "CookedVertex.cook fills absent attributes with defaults" {
    const raw = makeRawVertex(0, 0, 0);
    const bounds = AABB{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } };
    const uv0_bounds = UV0Bounds{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } };
    const cooked = CookedVertex.cook(&raw, &bounds, &uv0_bounds);
    try std.testing.expectEqual(CookedVertex.defaults, cooked);
}

test "CookedVertex.cook quantizes all present fields" {
    var raw = makeRawVertex(1, 2, 3);
    raw.normal = .{ 1, 0, 0 };
    raw.tangent = .{ 0, 1, 0, -1 };
    raw.uv0 = .{ 0.5, 0.5 };
    raw.uv1 = .{ 0.0, 1.0 };
    raw.joint_indices = .{ 0, 1, 2, 3 };
    raw.joint_weights = .{ 0.5, 0.25, 0.125, 0.125 };

    const bounds = AABB{ .min = .{ 0, 0, 0 }, .max = .{ 2, 2, 2 } };
    const uv0_bounds = UV0Bounds{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } };
    const cooked = CookedVertex.cook(&raw, &bounds, &uv0_bounds);
    try std.testing.expectEqual([2]i16{ 32767, 0 }, cooked.normal);
    try std.testing.expectEqual([4]i8{ 0, 127, -127, 0 }, cooked.tangent);
    try std.testing.expectEqual([2]u16{ 32768, 32768 }, cooked.uv0);
    try std.testing.expectEqual([2]u16{ 0, 65535 }, cooked.uv1);
    try std.testing.expectEqual(raw.joint_indices.?, cooked.joints);
    try std.testing.expectEqual(@as(u32, 255), @as(u32, cooked.weights[0]) + cooked.weights[1] + cooked.weights[2] + cooked.weights[3]);
}

test "CookedMesh.cook produces correct vertex count" {
    const allocator = std.testing.allocator;
    var mesh = try makeRawMesh(allocator, &.{
        makeRawVertex(0, 0, 0),
        makeRawVertex(1, 0, 0),
        makeRawVertex(0, 1, 0),
    }, &.{ 0, 1, 2 });
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    var cooked = try CookedMesh.cook(allocator, &mesh);
    defer cooked.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), cooked.vertices.len);
}

test "CookedMesh.cook computes correct AABB" {
    const allocator = std.testing.allocator;
    var mesh = try makeRawMesh(allocator, &.{
        makeRawVertex(-1, -2, -3),
        makeRawVertex(4, 5, 6),
        makeRawVertex(0, 0, 0),
    }, &.{ 0, 1, 2 });
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    var cooked = try CookedMesh.cook(allocator, &mesh);
    defer cooked.deinit(allocator);

    try std.testing.expectEqual([3]f32{ -1, -2, -3 }, cooked.bounds.min);
    try std.testing.expectEqual([3]f32{ 4, 5, 6 }, cooked.bounds.max);
}

test "CookedMesh.cook sets format flags from the union of all vertices" {
    const allocator = std.testing.allocator;

    var v0 = makeRawVertex(0, 0, 0);
    v0.normal = .{ 0, 0, 1 };

    var v1 = makeRawVertex(1, 0, 0);
    v1.uv0 = .{ 0.0, 1.0 };

    var mesh = try makeRawMesh(allocator, &.{ v0, v1 }, &.{ 0, 1 });
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    var cooked = try CookedMesh.cook(allocator, &mesh);
    defer cooked.deinit(allocator);

    try std.testing.expect(cooked.format_flags.has_normals);
    try std.testing.expect(cooked.format_flags.has_uv0);
    try std.testing.expect(!cooked.format_flags.has_tangents);
    try std.testing.expect(!cooked.format_flags.has_uv1);
    try std.testing.expect(!cooked.format_flags.has_joints);
    try std.testing.expect(!cooked.format_flags.has_weights);
}

test "CookedMesh.cook keeps part-local u32 indices" {
    const allocator = std.testing.allocator;
    var mesh = try makeRawMesh(allocator, &.{
        makeRawVertex(0, 0, 0),
        makeRawVertex(1, 0, 0),
        makeRawVertex(0, 1, 0),
    }, &.{ 0, 1, 2 });
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    var cooked = try CookedMesh.cook(allocator, &mesh);
    defer cooked.deinit(allocator);

    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, cooked.indices);
}

test "CookedMesh.cook deduplicates before cooking" {
    const allocator = std.testing.allocator;
    const v = makeRawVertex(1, 2, 3);

    var mesh = try makeRawMesh(allocator, &.{ v, v, v, v }, &.{ 0, 1, 2, 3 });
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    var cooked = try CookedMesh.cook(allocator, &mesh);
    defer cooked.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cooked.vertices.len);
    for (cooked.indices) |i| {
        try std.testing.expectEqual(@as(u32, 0), i);
    }
}

test "CookedMesh.cook AABB is tight around single vertex" {
    const allocator = std.testing.allocator;
    var mesh = try makeRawMesh(allocator, &.{makeRawVertex(3, 7, -2)}, &.{0});
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    var cooked = try CookedMesh.cook(allocator, &mesh);
    defer cooked.deinit(allocator);

    try std.testing.expectEqual([3]f32{ 3, 7, -2 }, cooked.bounds.min);
    try std.testing.expectEqual([3]f32{ 3, 7, -2 }, cooked.bounds.max);
}

// ── Triangle GLB-style integration tests ──

fn makeTriangleMesh(allocator: std.mem.Allocator) !RawMesh {
    var v0 = makeRawVertex(0, 0, 0);
    v0.normal = .{ 0, 0, 1 };
    v0.uv0 = .{ 0, 0 };

    var v1 = makeRawVertex(1, 0, 0);
    v1.normal = .{ 0, 0, 1 };
    v1.uv0 = .{ 1, 0 };

    var v2 = makeRawVertex(0.5, 1, 0);
    v2.normal = .{ 0, 0, 1 };
    v2.uv0 = .{ 0.5, 1 };

    return .{
        .vertices = try allocator.dupe(RawVertex, &.{ v0, v1, v2 }),
        .indices = try allocator.dupe(u32, &.{ 0, 1, 2 }),
        .submeshes = &.{},
        .name = "triangle",
    };
}

test "triangle: cook produces 3 vertices with octahedral normals and quantized UVs" {
    const allocator = std.testing.allocator;
    var mesh = try makeTriangleMesh(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    var cooked = try CookedMesh.cook(allocator, &mesh);
    defer cooked.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), cooked.vertices.len);

    try std.testing.expect(cooked.format_flags.has_normals);
    try std.testing.expect(cooked.format_flags.has_uv0);

    // Normal (0,0,1) encodes to oct (0,0) → both components should be 0
    const n = cooked.vertices[0].normal;
    try std.testing.expectEqual(@as(i16, 0), n[0]);
    try std.testing.expectEqual(@as(i16, 0), n[1]);
}

test "triangle: AABB is min=[0,0,0] max=[1,1,0]" {
    const allocator = std.testing.allocator;
    var mesh = try makeTriangleMesh(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    var cooked = try CookedMesh.cook(allocator, &mesh);
    defer cooked.deinit(allocator);

    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, cooked.bounds.min);
    try std.testing.expectEqual([3]f32{ 1, 1, 0 }, cooked.bounds.max);
}

test "triangle: format flags show has_normals and has_uv0 true, rest false" {
    const allocator = std.testing.allocator;
    var mesh = try makeTriangleMesh(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    var cooked = try CookedMesh.cook(allocator, &mesh);
    defer cooked.deinit(allocator);

    try std.testing.expect(cooked.format_flags.has_normals);
    try std.testing.expect(cooked.format_flags.has_uv0);
    try std.testing.expect(!cooked.format_flags.has_tangents);
    try std.testing.expect(!cooked.format_flags.has_uv1);
    try std.testing.expect(!cooked.format_flags.has_joints);
    try std.testing.expect(!cooked.format_flags.has_weights);
}
