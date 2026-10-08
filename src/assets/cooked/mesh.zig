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

pub const CookedVertex = struct {
    position: [3]f32,
    normal: ?[2]i16,
    tangent: ?[4]f16,
    uv0: ?[2]u16,
    uv1: ?[2]u16,
    joint_indices: ?[4]u16,
    joint_weights: ?[4]f16,

    pub fn cook(vertex: *const RawVertex, bounds: *const UV0Bounds) !CookedVertex {
        return .{
            .position = vertex.position,
            .normal = vertex.encodeNormalOctahedral(),
            .tangent = vertex.quantizeTangent(),
            .uv0 = vertex.quantizeUV0(bounds),
            .uv1 = vertex.quantizeUV1(),
            .joint_indices = vertex.joint_indices,
            .joint_weights = vertex.quantizeJointWeights(),
        };
    }
};

pub const AABB = struct {
    min: [3]f32,
    max: [3]f32,
};

pub const IndexFormat = enum {
    u16,
    u32,
};

pub const IndexBuffer = struct {
    u16: ?[]u16,
    u32: ?[]u32,

    pub fn format(self: *const IndexBuffer) IndexFormat {
        if (self.u16 != null) {
            return .u16;
        }
        return .u32;
    }

    pub fn len(self: *const IndexBuffer) usize {
        if (self.u16) |idx| return idx.len;
        if (self.u32) |idx| return idx.len;
        return 0;
    }

    pub fn compute(allocator: std.mem.Allocator, raw_indices: []const u32, vertex_count: usize) !IndexBuffer {
        if (vertex_count <= std.math.maxInt(u16)) {
            const idx = try allocator.alloc(u16, raw_indices.len);
            for (raw_indices, idx) |src, *dst| {
                dst.* = @intCast(src);
            }
            return .{ .u16 = idx, .u32 = null };
        }
        return .{ .u16 = null, .u32 = try allocator.dupe(u32, raw_indices) };
    }

    pub fn deinit(self: *IndexBuffer, allocator: std.mem.Allocator) void {
        if (self.u16) |idx| allocator.free(idx);
        if (self.u32) |idx| allocator.free(idx);
    }
};

pub const CookedMesh = struct {
    vertices: []CookedVertex,
    indices: IndexBuffer,
    submeshes: []raw_mesh.RawSubmesh,
    format_flags: FormatFlags,
    bounds: AABB,
    name: ?[]const u8,
    uv0_bounds: UV0Bounds = .{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } },

    pub fn deinit(self: *CookedMesh, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        self.indices.deinit(allocator);
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

        const flags: FormatFlags = if (mesh.vertices.len > 0) .{
            .has_normals = mesh.vertices[0].normal != null,
            .has_tangents = mesh.vertices[0].tangent != null,
            .has_uv0 = mesh.vertices[0].uv0 != null,
            .has_uv1 = mesh.vertices[0].uv1 != null,
            .has_joints = mesh.vertices[0].joint_indices != null,
            .has_weights = mesh.vertices[0].joint_weights != null,
        } else .{};

        const cooked_verts = try allocator.alloc(CookedVertex, mesh.vertices.len);
        errdefer allocator.free(cooked_verts);

        var bounds = AABB{
            .min = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) },
            .max = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) },
        };

        const uv0_bounds = UV0Bounds.compute(mesh.vertices);
        for (mesh.vertices, cooked_verts) |*raw_vert, *cooked| {
            cooked.* = try CookedVertex.cook(raw_vert, &uv0_bounds);

            for (0..3) |axis| {
                bounds.min[axis] = @min(bounds.min[axis], raw_vert.position[axis]);
                bounds.max[axis] = @max(bounds.max[axis], raw_vert.position[axis]);
            }
        }

        var indices = try IndexBuffer.compute(allocator, mesh.indices, mesh.vertices.len);
        errdefer indices.deinit(allocator);
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

test "IndexBuffer uses u16 for small vertex counts" {
    const allocator = std.testing.allocator;
    const raw_indices = [_]u32{ 0, 1, 2 };

    var buf = try IndexBuffer.compute(allocator, &raw_indices, 3);
    defer buf.deinit(allocator);

    try std.testing.expectEqual(IndexFormat.u16, buf.format());
    try std.testing.expect(buf.u16 != null);
    try std.testing.expect(buf.u32 == null);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, buf.u16.?);
}

test "IndexBuffer uses u32 when vertex count exceeds u16 max" {
    const allocator = std.testing.allocator;
    const raw_indices = [_]u32{ 0, 70000, 65536 };

    var buf = try IndexBuffer.compute(allocator, &raw_indices, 70001);
    defer buf.deinit(allocator);

    try std.testing.expectEqual(IndexFormat.u32, buf.format());
    try std.testing.expect(buf.u16 == null);
    try std.testing.expect(buf.u32 != null);
    try std.testing.expectEqualSlices(u32, &.{ 0, 70000, 65536 }, buf.u32.?);
}

test "IndexBuffer uses u16 at exactly u16 max vertex count" {
    const allocator = std.testing.allocator;
    const raw_indices = [_]u32{ 0, 65534 };

    var buf = try IndexBuffer.compute(allocator, &raw_indices, 65535);
    defer buf.deinit(allocator);

    try std.testing.expectEqual(IndexFormat.u16, buf.format());
    try std.testing.expectEqualSlices(u16, &.{ 0, 65534 }, buf.u16.?);
}

test "IndexBuffer uses u32 at u16 max + 1 vertex count" {
    const allocator = std.testing.allocator;
    const raw_indices = [_]u32{ 0, 65535 };

    var buf = try IndexBuffer.compute(allocator, &raw_indices, 65536);
    defer buf.deinit(allocator);

    try std.testing.expectEqual(IndexFormat.u32, buf.format());
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

test "CookedVertex.cook preserves position" {
    const raw = makeRawVertex(1.5, -2.0, 3.0);
    const bounds = UV0Bounds{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } };
    const cooked = try CookedVertex.cook(&raw, &bounds);
    try std.testing.expectEqual(raw.position, cooked.position);
}

test "CookedVertex.cook sets optional fields to null when absent" {
    const raw = makeRawVertex(0, 0, 0);
    const bounds = UV0Bounds{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } };
    const cooked = try CookedVertex.cook(&raw, &bounds);
    try std.testing.expectEqual(@as(?[2]i16, null), cooked.normal);
    try std.testing.expectEqual(@as(?[4]f16, null), cooked.tangent);
    try std.testing.expectEqual(@as(?[2]u16, null), cooked.uv0);
    try std.testing.expectEqual(@as(?[2]u16, null), cooked.uv1);
    try std.testing.expectEqual(@as(?[4]u16, null), cooked.joint_indices);
    try std.testing.expectEqual(@as(?[4]f16, null), cooked.joint_weights);
}

test "CookedVertex.cook quantizes all present fields" {
    var raw = makeRawVertex(1, 2, 3);
    raw.normal = .{ 0, 0, 1 };
    raw.tangent = .{ 1, 0, 0, 1 };
    raw.uv0 = .{ 0.5, 0.5 };
    raw.uv1 = .{ 0.0, 1.0 };
    raw.joint_indices = .{ 0, 1, 2, 3 };
    raw.joint_weights = .{ 0.5, 0.25, 0.125, 0.125 };

    const bounds = UV0Bounds{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } };
    const cooked = try CookedVertex.cook(&raw, &bounds);
    try std.testing.expect(cooked.normal != null);
    try std.testing.expect(cooked.tangent != null);
    try std.testing.expect(cooked.uv0 != null);
    try std.testing.expect(cooked.uv1 != null);
    try std.testing.expectEqual(raw.joint_indices, cooked.joint_indices);
    try std.testing.expect(cooked.joint_weights != null);
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

test "CookedMesh.cook sets format flags from first vertex" {
    const allocator = std.testing.allocator;

    var v0 = makeRawVertex(0, 0, 0);
    v0.normal = .{ 0, 0, 1 };
    v0.uv0 = .{ 0.5, 0.5 };

    var v1 = makeRawVertex(1, 0, 0);
    v1.normal = .{ 1, 0, 0 };
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

test "CookedMesh.cook uses u16 indices for small meshes" {
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

    try std.testing.expectEqual(IndexFormat.u16, cooked.indices.format());
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, cooked.indices.u16.?);
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
    for (cooked.indices.u16.?) |i| {
        try std.testing.expectEqual(@as(u16, 0), i);
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

    for (cooked.vertices) |v| {
        // All vertices should have octahedral-encoded normals (2 × i16)
        try std.testing.expect(v.normal != null);
        // All vertices should have quantized UV0 (2 × u16)
        try std.testing.expect(v.uv0 != null);
    }

    // Normal (0,0,1) encodes to oct (0,0) → both components should be 0
    const n = cooked.vertices[0].normal.?;
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
