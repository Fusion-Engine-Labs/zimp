const std = @import("std");
const mesh = @import("../assets/cooked/mesh.zig");
const raw_mesh = @import("../assets/raw/mesh.zig");
const wire = @import("../shared/wire.zig");

pub const MAGIC = @import("../shared/constants.zig").FORMAT_MAGIC.ZMESH;
pub const ZMESH_VERSION: u32 = 5;

pub const Transform = [16]f32;
pub const identity_transform: Transform = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

/// File layout: `Header`, then aligned sections in this order: the
/// `PartEntry` table, the material slot table (`Span`s into the string blob),
/// the string blob, and per part its vertex streams, indices, and submeshes.
pub const Header = extern struct {
    file: wire.FileHeader,
    part_count: u32,
    material_slot_count: u32,
    parts: wire.Span,
    material_slots: wire.Span,
    strings: wire.Span,
};

pub const PartEntry = extern struct {
    transform: Transform,
    aabb_min: [3]f32,
    aabb_max: [3]f32,
    uv0_min: [2]f32,
    uv0_scale: [2]f32,
    vertex_count: u32,
    index_count: u32,
    submesh_count: u32,
    index_format: u8,
    format_flags: u8,
    _reserved: u16 = 0,
    positions: wire.Span,
    normals: wire.Span,
    tangents: wire.Span,
    uv0: wire.Span,
    uv1: wire.Span,
    joint_indices: wire.Span,
    joint_weights: wire.Span,
    indices: wire.Span,
    submeshes: wire.Span,
};

pub const Submesh = extern struct {
    index_offset: u32,
    index_count: u32,
    material_index: u16,
    _reserved: u16 = 0,
};

comptime {
    wire.assertTightLayout(Header);
    wire.assertTightLayout(PartEntry);
    wire.assertTightLayout(Submesh);
}

pub const HEADER_SIZE: u32 = @sizeOf(Header);

/// Zero-copy view of one drawable mesh. Every slice points into the file bytes.
pub const MeshPart = struct {
    vertex_count: u32,
    index_count: u32,

    aabb_min: [3]f32,
    aabb_max: [3]f32,

    uv0_min: [2]f32,
    uv0_scale: [2]f32,

    submeshes: []const Submesh,

    positions: []const [3]f32,
    normals: ?[]const [2]i16,
    tangents: ?[]const [4]f16,
    uv0: ?[]const [2]u16,
    uv1: ?[]const [2]u16,
    joint_indices: ?[]const [4]u16,
    joint_weights: ?[]const [4]f16,

    indices_u16: ?[]const u16,
    indices_u32: ?[]const u32,

    fn view(bytes: wire.Bytes, entry: *const PartEntry, material_slot_count: u32) !MeshPart {
        const flags: mesh.FormatFlags = @bitCast(entry.format_flags);
        if (flags._padding != 0) return error.InvalidFormatFlags;
        const index_format = try wire.enumFromInt(mesh.IndexFormat, entry.index_format);
        if (entry._reserved != 0) return error.InvalidLayout;

        const n = entry.vertex_count;
        const submeshes = try wire.sectionSlice(Submesh, bytes, entry.submeshes, entry.submesh_count);
        for (submeshes) |s| {
            if (s.index_offset > entry.index_count or s.index_count > entry.index_count - s.index_offset)
                return error.InvalidSubmeshRange;
            if (s.material_index >= material_slot_count) return error.InvalidMaterialIndex;
        }

        return .{
            .vertex_count = n,
            .index_count = entry.index_count,
            .aabb_min = entry.aabb_min,
            .aabb_max = entry.aabb_max,
            .uv0_min = entry.uv0_min,
            .uv0_scale = entry.uv0_scale,
            .submeshes = submeshes,
            .positions = try wire.sectionSlice([3]f32, bytes, entry.positions, n),
            .normals = try optionalStream([2]i16, bytes, entry.normals, flags.has_normals, n),
            .tangents = try optionalStream([4]f16, bytes, entry.tangents, flags.has_tangents, n),
            .uv0 = try optionalStream([2]u16, bytes, entry.uv0, flags.has_uv0, n),
            .uv1 = try optionalStream([2]u16, bytes, entry.uv1, flags.has_uv1, n),
            .joint_indices = try optionalStream([4]u16, bytes, entry.joint_indices, flags.has_joints, n),
            .joint_weights = try optionalStream([4]f16, bytes, entry.joint_weights, flags.has_weights, n),
            .indices_u16 = if (index_format == .u16) try wire.sectionSlice(u16, bytes, entry.indices, entry.index_count) else null,
            .indices_u32 = if (index_format == .u32) try wire.sectionSlice(u32, bytes, entry.indices, entry.index_count) else null,
        };
    }
};

fn optionalStream(comptime T: type, bytes: wire.Bytes, span: wire.Span, present: bool, count: u32) !?[]const T {
    if (!present) {
        if (span.len != 0) return error.InvalidLayout;
        return null;
    }
    return try wire.sectionSlice(T, bytes, span, count);
}

/// Section spans for one part's data, reserved in write order.
const PartSpans = struct {
    positions: wire.Span = .{},
    normals: wire.Span = .{},
    tangents: wire.Span = .{},
    uv0: wire.Span = .{},
    uv1: wire.Span = .{},
    joint_indices: wire.Span = .{},
    joint_weights: wire.Span = .{},
    indices: wire.Span = .{},
    submeshes: wire.Span = .{},
};

/// Deterministic section planner. The writer replays it so the header,
/// entry tables, and data sections all agree without buffering the file.
const Plan = struct {
    layout: wire.Layout,
    parts: wire.Span,
    material_slots: wire.Span,
    strings: wire.Span,

    fn init(material_slots: []const []const u8, part_count: usize) !Plan {
        var layout = wire.Layout.init(HEADER_SIZE);
        const parts = try layout.reserve(part_count * @sizeOf(PartEntry));
        const slots = try layout.reserve(material_slots.len * @sizeOf(wire.Span));
        var string_bytes: usize = 0;
        for (material_slots) |path| string_bytes += path.len;
        const strings = try layout.reserve(string_bytes);
        return .{ .layout = layout, .parts = parts, .material_slots = slots, .strings = strings };
    }

    fn nextPart(self: *Plan, m: mesh.CookedMesh) !PartSpans {
        const n = m.vertices.len;
        const flags = m.format_flags;
        var spans: PartSpans = .{};
        spans.positions = try self.layout.reserve(n * @sizeOf([3]f32));
        if (flags.has_normals) spans.normals = try self.layout.reserve(n * @sizeOf([2]i16));
        if (flags.has_tangents) spans.tangents = try self.layout.reserve(n * @sizeOf([4]f16));
        if (flags.has_uv0) spans.uv0 = try self.layout.reserve(n * @sizeOf([2]u16));
        if (flags.has_uv1) spans.uv1 = try self.layout.reserve(n * @sizeOf([2]u16));
        if (flags.has_joints) spans.joint_indices = try self.layout.reserve(n * @sizeOf([4]u16));
        if (flags.has_weights) spans.joint_weights = try self.layout.reserve(n * @sizeOf([4]f16));
        const index_size: usize = switch (m.indices.format()) {
            .u16 => @sizeOf(u16),
            .u32 => @sizeOf(u32),
        };
        spans.indices = try self.layout.reserve(m.indices.len() * index_size);
        spans.submeshes = try self.layout.reserve(m.submeshes.len * @sizeOf(Submesh));
        return spans;
    }
};

/// A cooked model is one or more independently drawable meshes with
/// local-to-model transforms. This is a zero-copy view; it borrows the bytes
/// it was created from and owns no memory.
pub const ZMesh = struct {
    bytes: wire.Bytes,
    part_entries: []const PartEntry,
    material_slot_refs: []const wire.Span,
    strings: []const u8,

    pub const CookPart = struct {
        mesh: mesh.CookedMesh,
        transform: Transform,
    };

    pub const Part = struct {
        mesh: MeshPart,
        transform: Transform,
    };

    /// Validates the whole file so `part` and `materialSlot` cannot fail.
    pub fn view(bytes: wire.Bytes) !ZMesh {
        _ = try wire.FileHeader.validate(bytes, MAGIC, ZMESH_VERSION);
        const header = try wire.structAt(Header, bytes, 0);
        if (header.part_count == 0) return error.NoMeshes;
        if (header.material_slot_count == 0) return error.NoMaterialSlots;

        var order = wire.SectionOrder.init(HEADER_SIZE);
        for ([_]wire.Span{ header.parts, header.material_slots, header.strings }) |span| try order.next(span);

        const strings = try wire.sectionSlice(u8, bytes, header.strings, header.strings.len);
        const slot_refs = try wire.sectionSlice(wire.Span, bytes, header.material_slots, header.material_slot_count);
        for (slot_refs) |ref| {
            if (ref.len == 0) return error.EmptyMaterialPath;
            try wire.checkString(strings, ref);
        }

        const entries = try wire.sectionSlice(PartEntry, bytes, header.parts, header.part_count);
        for (entries) |*entry| {
            const part_sections = [_]wire.Span{
                entry.positions,     entry.normals, entry.tangents,
                entry.uv0,           entry.uv1,     entry.joint_indices,
                entry.joint_weights, entry.indices, entry.submeshes,
            };
            for (part_sections) |span| try order.next(span);
            _ = try MeshPart.view(bytes, entry, header.material_slot_count);
        }

        return .{ .bytes = bytes, .part_entries = entries, .material_slot_refs = slot_refs, .strings = strings };
    }

    pub fn partCount(self: *const ZMesh) usize {
        return self.part_entries.len;
    }

    pub fn part(self: *const ZMesh, index: usize) Part {
        const entry = &self.part_entries[index];
        const part_view = MeshPart.view(self.bytes, entry, @intCast(self.material_slot_refs.len)) catch unreachable; // validated in `view`
        return .{ .mesh = part_view, .transform = entry.transform };
    }

    pub fn materialSlotCount(self: *const ZMesh) usize {
        return self.material_slot_refs.len;
    }

    pub fn materialSlot(self: *const ZMesh, index: usize) []const u8 {
        return wire.stringAt(self.strings, self.material_slot_refs[index]);
    }

    pub fn write(writer: *std.Io.Writer, material_slots: []const []const u8, parts: []const CookPart) !void {
        if (parts.len == 0) return error.NoMeshes;
        if (material_slots.len == 0) return error.NoMaterialSlots;
        if (material_slots.len > std.math.maxInt(u16)) return error.TooManyMaterialSlots;
        for (material_slots) |path| {
            if (path.len == 0) return error.EmptyMaterialPath;
        }
        for (parts) |p| {
            for (p.mesh.submeshes) |submesh| {
                if (submesh.material_index >= material_slots.len) return error.InvalidMaterialIndex;
            }
        }

        // Pass 1: total size.
        var sizing = try Plan.init(material_slots, parts.len);
        for (parts) |p| _ = try sizing.nextPart(p.mesh);
        const total_size = sizing.layout.totalSize();

        var out: wire.LayoutWriter = .{ .writer = writer };
        var plan = try Plan.init(material_slots, parts.len);
        try out.value(Header{
            .file = .init(MAGIC, ZMESH_VERSION, total_size),
            .part_count = @intCast(parts.len),
            .material_slot_count = @intCast(material_slots.len),
            .parts = plan.parts,
            .material_slots = plan.material_slots,
            .strings = plan.strings,
        });

        // Pass 2: part entry table.
        try out.beginSection(plan.parts);
        for (parts) |p| {
            const spans = try plan.nextPart(p.mesh);
            try out.value(partEntry(p, spans));
        }

        try out.beginSection(plan.material_slots);
        var string_offset: u32 = 0;
        for (material_slots) |path| {
            try out.value(wire.Span{ .offset = string_offset, .len = @intCast(path.len) });
            string_offset += @intCast(path.len);
        }
        try out.beginSection(plan.strings);
        for (material_slots) |path| try out.bytes(path);

        // Pass 3: part data sections.
        var data_plan = try Plan.init(material_slots, parts.len);
        for (parts) |p| {
            const spans = try data_plan.nextPart(p.mesh);
            try writePartData(&out, p.mesh, spans);
        }
        try out.finish(total_size);
    }

    fn partEntry(p: CookPart, spans: PartSpans) PartEntry {
        const m = p.mesh;
        return .{
            .transform = p.transform,
            .aabb_min = m.bounds.min,
            .aabb_max = m.bounds.max,
            .uv0_min = m.uv0_bounds.min,
            .uv0_scale = m.uv0_bounds.scale,
            .vertex_count = @intCast(m.vertices.len),
            .index_count = @intCast(m.indices.len()),
            .submesh_count = @intCast(m.submeshes.len),
            .index_format = @intFromEnum(m.indices.format()),
            .format_flags = @bitCast(m.format_flags),
            .positions = spans.positions,
            .normals = spans.normals,
            .tangents = spans.tangents,
            .uv0 = spans.uv0,
            .uv1 = spans.uv1,
            .joint_indices = spans.joint_indices,
            .joint_weights = spans.joint_weights,
            .indices = spans.indices,
            .submeshes = spans.submeshes,
        };
    }

    fn writePartData(out: *wire.LayoutWriter, m: mesh.CookedMesh, spans: PartSpans) !void {
        const flags = m.format_flags;
        try out.beginSection(spans.positions);
        for (m.vertices) |v| try out.value(v.position);
        if (flags.has_normals) {
            try out.beginSection(spans.normals);
            for (m.vertices) |v| try out.value(v.normal.?);
        }
        if (flags.has_tangents) {
            try out.beginSection(spans.tangents);
            for (m.vertices) |v| try out.value(v.tangent.?);
        }
        if (flags.has_uv0) {
            try out.beginSection(spans.uv0);
            for (m.vertices) |v| try out.value(v.uv0.?);
        }
        if (flags.has_uv1) {
            try out.beginSection(spans.uv1);
            for (m.vertices) |v| try out.value(v.uv1.?);
        }
        if (flags.has_joints) {
            try out.beginSection(spans.joint_indices);
            for (m.vertices) |v| try out.value(v.joint_indices.?);
        }
        if (flags.has_weights) {
            try out.beginSection(spans.joint_weights);
            for (m.vertices) |v| try out.value(v.joint_weights.?);
        }
        if (m.indices.u16) |indices| {
            try out.section(spans.indices, std.mem.sliceAsBytes(indices));
        } else if (m.indices.u32) |indices| {
            try out.section(spans.indices, std.mem.sliceAsBytes(indices));
        }
        try out.beginSection(spans.submeshes);
        for (m.submeshes) |s| {
            try out.value(Submesh{ .index_offset = s.index_offset, .index_count = s.index_count, .material_index = s.material_index });
        }
    }
};

pub fn view(bytes: wire.Bytes) !ZMesh {
    return ZMesh.view(bytes);
}

pub fn write(writer: *std.Io.Writer, material_slots: []const []const u8, parts: []const ZMesh.CookPart) !void {
    return ZMesh.write(writer, material_slots, parts);
}

/// Writes a small single-part mesh with normals and uv0. Used by inspector
/// and command tests.
pub fn writeTestZmeshFile(writer: *std.Io.Writer) !void {
    var vertices = [_]mesh.CookedVertex{
        .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 0 }, .tangent = null, .uv0 = .{ 0, 0 }, .uv1 = null, .joint_indices = null, .joint_weights = null },
        .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 0 }, .tangent = null, .uv0 = .{ 0, 0 }, .uv1 = null, .joint_indices = null, .joint_weights = null },
        .{ .position = .{ 0, 1, 0 }, .normal = .{ 0, 0 }, .tangent = null, .uv0 = .{ 0, 0 }, .uv1 = null, .joint_indices = null, .joint_weights = null },
    };
    var indices = [_]u16{ 0, 1, 2 };
    var submeshes = [_]raw_mesh.RawSubmesh{.{ .index_offset = 0, .index_count = 3, .material_index = 0 }};
    const parts = [_]ZMesh.CookPart{.{
        .mesh = .{
            .vertices = &vertices,
            .indices = .{ .u16 = &indices, .u32 = null },
            .submeshes = &submeshes,
            .format_flags = .{ .has_normals = true, .has_uv0 = true },
            .bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } },
            .name = null,
        },
        .transform = identity_transform,
    }};
    const material_slots = [_][]const u8{"materials/test.zamat"};
    try ZMesh.write(writer, &material_slots, &parts);
}

const testing = std.testing;

fn makeVertex(x: f32, y: f32, z: f32) mesh.CookedVertex {
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

fn makeCookedMesh(vertices: []const mesh.CookedVertex, indices: mesh.IndexBuffer, submeshes: []const raw_mesh.RawSubmesh, flags: mesh.FormatFlags, bounds: mesh.AABB) mesh.CookedMesh {
    return .{
        .vertices = @constCast(vertices),
        .indices = indices,
        .submeshes = @constCast(submeshes),
        .format_flags = flags,
        .bounds = bounds,
        .name = null,
    };
}

const one_slot = [_][]const u8{"materials/test.zamat"};
const one_submesh = [_]raw_mesh.RawSubmesh{.{ .index_offset = 0, .index_count = 3, .material_index = 0 }};
const unit_bounds: mesh.AABB = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };

fn writeSingle(buf: []align(wire.section_alignment) u8, cooked: mesh.CookedMesh) !wire.Bytes {
    var writer = std.Io.Writer.fixed(buf);
    const parts = [_]ZMesh.CookPart{.{ .mesh = cooked, .transform = identity_transform }};
    try ZMesh.write(&writer, &one_slot, &parts);
    return buf[0..writer.end];
}

fn expectAligned(bytes: wire.Bytes, slice: anytype) !void {
    const offset = @intFromPtr(std.mem.sliceAsBytes(slice).ptr) - @intFromPtr(bytes.ptr);
    try testing.expectEqual(@as(usize, 0), offset % wire.section_alignment);
}

test "on-disk struct sizes" {
    try testing.expectEqual(@as(u32, 48), HEADER_SIZE);
    try testing.expectEqual(@as(usize, 192), @sizeOf(PartEntry));
    try testing.expectEqual(@as(usize, 12), @sizeOf(Submesh));
}

test "ZMesh.write records magic, version, and exact total size" {
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeSingle(&buf, makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{ 0, 1, 2 }), .u32 = null }, &one_submesh, .{}, unit_bounds));

    try testing.expectEqualSlices(u8, MAGIC, bytes[0..4]);
    const header = try wire.structAt(Header, bytes, 0);
    try testing.expectEqual(ZMESH_VERSION, header.file.version);
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), header.file.total_size);
}

test "ZMesh.view round-trips positions, u16 indices, AABB, and submeshes in place" {
    const verts = [_]mesh.CookedVertex{ makeVertex(1, 2, 3), makeVertex(4, 5, 6), makeVertex(7, 8, 9) };
    const submeshes = [_]raw_mesh.RawSubmesh{
        .{ .index_offset = 0, .index_count = 3, .material_index = 0 },
        .{ .index_offset = 3, .index_count = 3, .material_index = 0 },
    };
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeSingle(&buf, makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{ 0, 1, 2, 2, 1, 0 }), .u32 = null }, &submeshes, .{}, .{ .min = .{ -1, -2, -3 }, .max = .{ 4, 5, 6 } }));

    const model = try ZMesh.view(bytes);
    try testing.expectEqual(@as(usize, 1), model.partCount());
    const part = model.part(0).mesh;
    try testing.expectEqual(@as(u32, 3), part.vertex_count);
    try testing.expectEqual(@as(u32, 6), part.index_count);
    try testing.expectEqualSlices([3]f32, &.{ .{ 1, 2, 3 }, .{ 4, 5, 6 }, .{ 7, 8, 9 } }, part.positions);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 2, 1, 0 }, part.indices_u16.?);
    try testing.expect(part.indices_u32 == null);
    try testing.expect(part.normals == null);
    try testing.expectEqual([3]f32{ -1, -2, -3 }, part.aabb_min);
    try testing.expectEqual([3]f32{ 4, 5, 6 }, part.aabb_max);
    try testing.expectEqual(@as(usize, 2), part.submeshes.len);
    try testing.expectEqual(@as(u32, 3), part.submeshes[1].index_offset);
    try expectAligned(bytes, part.positions);
    try expectAligned(bytes, part.indices_u16.?);
    try expectAligned(bytes, part.submeshes);
}

test "ZMesh.view round-trips u32 indices" {
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeSingle(&buf, makeCookedMesh(&verts, .{ .u16 = null, .u32 = @constCast(&[_]u32{ 0, 1, 2 }) }, &one_submesh, .{}, unit_bounds));

    const part = (try ZMesh.view(bytes)).part(0).mesh;
    try testing.expect(part.indices_u16 == null);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, part.indices_u32.?);
}

test "ZMesh.view round-trips every optional vertex stream" {
    var verts: [3]mesh.CookedVertex = undefined;
    for (&verts, 0..) |*v, i| {
        const f: f16 = @floatFromInt(i);
        const u: u16 = @intCast(i);
        v.* = .{
            .position = .{ @floatFromInt(i), 0, 0 },
            .normal = .{ @intCast(i), -@as(i16, @intCast(i)) },
            .tangent = .{ f, f, f, 1 },
            .uv0 = .{ u, u + 1 },
            .uv1 = .{ u + 2, u + 3 },
            .joint_indices = .{ u, 0, 0, 0 },
            .joint_weights = .{ 1, 0, 0, 0 },
        };
    }
    const flags: mesh.FormatFlags = .{ .has_normals = true, .has_tangents = true, .has_uv0 = true, .has_uv1 = true, .has_joints = true, .has_weights = true };
    var cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{ 0, 1, 2 }), .u32 = null }, &one_submesh, flags, unit_bounds);
    cooked.uv0_bounds = .{ .min = .{ 0.25, 0.5 }, .scale = .{ 2, 4 } };

    var buf: [2048]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeSingle(&buf, cooked);
    const part = (try ZMesh.view(bytes)).part(0).mesh;

    try testing.expectEqual([2]f32{ 0.25, 0.5 }, part.uv0_min);
    try testing.expectEqual([2]f32{ 2, 4 }, part.uv0_scale);
    for (verts, 0..) |v, i| {
        try testing.expectEqual(v.normal.?, part.normals.?[i]);
        try testing.expectEqual(v.tangent.?, part.tangents.?[i]);
        try testing.expectEqual(v.uv0.?, part.uv0.?[i]);
        try testing.expectEqual(v.uv1.?, part.uv1.?[i]);
        try testing.expectEqual(v.joint_indices.?, part.joint_indices.?[i]);
        try testing.expectEqual(v.joint_weights.?, part.joint_weights.?[i]);
    }
    try expectAligned(bytes, part.normals.?);
    try expectAligned(bytes, part.tangents.?);
    try expectAligned(bytes, part.uv0.?);
    try expectAligned(bytes, part.uv1.?);
    try expectAligned(bytes, part.joint_indices.?);
    try expectAligned(bytes, part.joint_weights.?);
}

test "ZMesh round-trips multiple mesh parts and transforms" {
    const verts_a = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    const verts_b = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(0, 0, 1), makeVertex(0, 1, 0) };
    const indices = [_]u16{ 0, 1, 2 };
    const submeshes_b = [_]raw_mesh.RawSubmesh{.{ .index_offset = 0, .index_count = 3, .material_index = 1 }};
    const translated: Transform = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        2, 3, 4, 1,
    };
    const parts = [_]ZMesh.CookPart{
        .{ .mesh = makeCookedMesh(&verts_a, .{ .u16 = @constCast(&indices), .u32 = null }, &one_submesh, .{}, unit_bounds), .transform = identity_transform },
        .{ .mesh = makeCookedMesh(&verts_b, .{ .u16 = @constCast(&indices), .u32 = null }, &submeshes_b, .{}, unit_bounds), .transform = translated },
    };

    var buf: [4096]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const material_slots = [_][]const u8{ "materials/stone.zamat", "materials/metal.zamat" };
    try ZMesh.write(&writer, &material_slots, &parts);

    const model = try ZMesh.view(buf[0..writer.end]);
    try testing.expectEqual(@as(usize, 2), model.materialSlotCount());
    try testing.expectEqualStrings("materials/stone.zamat", model.materialSlot(0));
    try testing.expectEqualStrings("materials/metal.zamat", model.materialSlot(1));
    try testing.expectEqual(@as(usize, 2), model.partCount());
    try testing.expectEqual(@as(u32, 3), model.part(0).mesh.vertex_count);
    try testing.expectEqual(@as(u16, 1), model.part(1).mesh.submeshes[0].material_index);
    try testing.expectEqualSlices([3]f32, &.{ .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 0 } }, model.part(1).mesh.positions);
    try testing.expectEqual(@as(f32, 2), model.part(1).transform[12]);
    try testing.expectEqual(@as(f32, 3), model.part(1).transform[13]);
    try testing.expectEqual(@as(f32, 4), model.part(1).transform[14]);
}

test "ZMesh.write validates inputs" {
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    const bad_submesh = [_]raw_mesh.RawSubmesh{.{ .index_offset = 0, .index_count = 3, .material_index = 1 }};
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{ 0, 1, 2 }), .u32 = null }, &bad_submesh, .{}, unit_bounds);
    const parts = [_]ZMesh.CookPart{.{ .mesh = cooked, .transform = identity_transform }};

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.NoMeshes, ZMesh.write(&writer, &one_slot, &.{}));
    try testing.expectError(error.NoMaterialSlots, ZMesh.write(&writer, &.{}, &parts));
    try testing.expectError(error.EmptyMaterialPath, ZMesh.write(&writer, &.{""}, &parts));
    try testing.expectError(error.InvalidMaterialIndex, ZMesh.write(&writer, &one_slot, &parts));
}

test "ZMesh.view rejects other versions, bad magic, and truncation" {
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZmeshFile(&writer);
    const len = writer.end;

    try testing.expectError(error.InvalidFileSize, ZMesh.view(buf[0 .. len - 4]));
    std.mem.writeInt(u32, buf[4..8], ZMESH_VERSION - 1, .little);
    try testing.expectError(error.UnsupportedVersion, ZMesh.view(buf[0..len]));
    std.mem.writeInt(u32, buf[4..8], ZMESH_VERSION, .little);
    buf[0] = 'X';
    try testing.expectError(error.InvalidMagic, ZMesh.view(buf[0..len]));
}

fn mutablePartEntry(buf: []align(wire.section_alignment) u8) *PartEntry {
    const header: *const Header = @ptrCast(buf.ptr);
    return @ptrCast(@alignCast(buf.ptr + header.parts.offset));
}

test "ZMesh.view rejects corrupted part entries" {
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZmeshFile(&writer);
    const len = writer.end;
    const entry = mutablePartEntry(&buf);
    const original = entry.*;

    entry.vertex_count = 4; // streams no longer match the declared count
    try testing.expectError(error.InvalidLayout, ZMesh.view(buf[0..len]));
    entry.* = original;

    entry.format_flags |= 0x80;
    try testing.expectError(error.InvalidFormatFlags, ZMesh.view(buf[0..len]));
    entry.* = original;

    entry.normals.offset += 4;
    try testing.expectError(error.MisalignedSection, ZMesh.view(buf[0..len]));
    entry.* = original;

    entry.submeshes.offset = 1 << 20; // last section, so ordering still holds
    try testing.expectError(error.Truncated, ZMesh.view(buf[0..len]));
    entry.* = original;

    entry.positions.offset = 1 << 20; // now precedes nothing it should follow
    try testing.expectError(error.OverlappingSections, ZMesh.view(buf[0..len]));
    entry.* = original;

    entry.format_flags &= ~@as(u8, 1); // drop has_normals while the normals section remains
    try testing.expectError(error.InvalidLayout, ZMesh.view(buf[0..len]));
    entry.* = original;

    entry.submeshes.offset = entry.indices.offset; // aliases the index buffer
    try testing.expectError(error.OverlappingSections, ZMesh.view(buf[0..len]));
    entry.* = original;

    _ = try ZMesh.view(buf[0..len]);
}

test "ZMesh.view rejects out-of-range submeshes and material indices" {
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZmeshFile(&writer);
    const len = writer.end;
    const entry = mutablePartEntry(&buf);
    const submesh: *Submesh = @ptrCast(@alignCast(buf[entry.submeshes.offset..].ptr));

    submesh.index_count = 4;
    try testing.expectError(error.InvalidSubmeshRange, ZMesh.view(buf[0..len]));
    submesh.index_count = 3;
    submesh.material_index = 1;
    try testing.expectError(error.InvalidMaterialIndex, ZMesh.view(buf[0..len]));
}

test "writeTestZmeshFile produces a viewable mesh" {
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZmeshFile(&writer);

    const model = try ZMesh.view(buf[0..writer.end]);
    try testing.expectEqualStrings("materials/test.zamat", model.materialSlot(0));
    const part = model.part(0).mesh;
    try testing.expect(part.normals != null);
    try testing.expect(part.uv0 != null);
    try testing.expectEqual(@as(u32, 3), part.index_count);
}
