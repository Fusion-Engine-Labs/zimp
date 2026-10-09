const std = @import("std");
const mesh = @import("../assets/cooked/mesh.zig");
const raw_mesh = @import("../assets/raw/mesh.zig");
const wire = @import("../shared/wire.zig");
const index_codec = @import("meshopt/index_codec.zig");
const vertex_codec = @import("meshopt/vertex_codec.zig");
pub const AssetId = @import("../id/id_types.zig").AssetId;
pub const IndexFormat = mesh.IndexFormat;
pub const FormatFlags = mesh.FormatFlags;

pub const MAGIC = @import("../shared/constants.zig").FORMAT_MAGIC.ZMESH;
pub const ZMESH_VERSION: u32 = 7;

pub const Transform = [16]f32;
pub const identity_transform: Transform = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

/// How vertex streams and indices are stored.
pub const Codec = enum(u8) {
    /// Raw arrays; `decodeStream` is a copy.
    none = 0,
    /// meshoptimizer vertex codec (v0) per stream, index codec (v1) for indices.
    meshopt = 1,
};

pub const JointFormat = enum(u8) { u8 = 0, u16 = 1 };

/// Vertex streams shared by every part. Decoded element types:
/// positions `[4]u16` unorm over the part AABB (w = 0), normals `[2]i16`
/// octahedral snorm, tangents `[4]i8` (octahedral snorm xy, handedness sign,
/// 0), uv0/uv1 `[2]u16` unorm, joints `[4]u8` or `[4]u16` (`JointFormat`),
/// weights `[4]u8` unorm summing to 255.
pub const Stream = enum(u8) {
    positions,
    normals,
    tangents,
    uv0,
    uv1,
    joints,
    weights,

    pub const count = @typeInfo(Stream).@"enum".fields.len;
};

/// File layout: `Header`, then aligned sections in this order: the
/// `PartEntry` table, the material slot table (one `AssetRef` per slot), the
/// `Submesh` table, each present vertex stream in `Stream` order, and the
/// index buffer.
///
/// Parts share the streams: part `p` owns vertices
/// `[base_vertex, base_vertex + vertex_count)` and indices
/// `[first_index, first_index + index_count)`, and its index values are
/// local to the part (draw with a base vertex). Parts tile all three
/// ranges in order.
pub const Header = extern struct {
    file: wire.FileHeader,
    part_count: u32,
    material_slot_count: u32,
    submesh_count: u32,
    vertex_count: u32,
    index_count: u32,
    format_flags: u8,
    index_format: u8,
    codec: u8,
    joint_format: u8,
    parts: wire.Span,
    material_slots: wire.Span,
    submeshes: wire.Span,
    streams: [Stream.count]wire.Span,
    indices: wire.Span,
};

pub const PartEntry = extern struct {
    transform: Transform,
    /// Position dequantization: `aabb_min + q * (aabb_max - aabb_min)`.
    aabb_min: [3]f32,
    aabb_max: [3]f32,
    uv0_min: [2]f32,
    uv0_scale: [2]f32,
    base_vertex: u32,
    vertex_count: u32,
    first_index: u32,
    index_count: u32,
    first_submesh: u32,
    submesh_count: u32,
};

/// `index_offset` is into the shared index buffer, inside its part's range.
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

/// Decoded size in bytes of one element of `stream`.
pub fn streamStride(stream: Stream, joint_format: JointFormat) u32 {
    return switch (stream) {
        .positions => 8,
        .joints => if (joint_format == .u16) 8 else 4,
        else => 4,
    };
}

fn streamPresent(stream: Stream, flags: FormatFlags) bool {
    return switch (stream) {
        .positions => true,
        .normals => flags.has_normals,
        .tangents => flags.has_tangents,
        .uv0 => flags.has_uv0,
        .uv1 => flags.has_uv1,
        .joints => flags.has_joints,
        .weights => flags.has_weights,
    };
}

pub fn indexSize(format: IndexFormat) u32 {
    return switch (format) {
        .u16 => 2,
        .u32 => 4,
    };
}

/// A cooked model: one or more drawable parts with local-to-model
/// transforms over shared vertex streams. This is a view; it borrows the
/// bytes it was created from and owns no memory. Streams may be encoded, so
/// read them through `decodeStream` and `decodeIndices`.
pub const ZMesh = struct {
    bytes: wire.Bytes,
    header: *const Header,
    part_entries: []const PartEntry,
    material_slot_refs: []const wire.AssetRef,
    submesh_table: []const Submesh,

    pub const CookPart = struct {
        mesh: mesh.CookedMesh,
        transform: Transform,
    };

    pub const Part = struct {
        transform: Transform,
        aabb_min: [3]f32,
        aabb_max: [3]f32,
        uv0_min: [2]f32,
        uv0_scale: [2]f32,
        base_vertex: u32,
        vertex_count: u32,
        first_index: u32,
        index_count: u32,
        submeshes: []const Submesh,
    };

    pub const WriteOptions = struct {
        codec: Codec = .meshopt,
    };

    /// Validates the header and tables so `part`, `materialSlot`, and the
    /// stream accessors cannot fail. Encoded payloads are checked by the
    /// decode functions.
    pub fn view(bytes: wire.Bytes) !ZMesh {
        _ = try wire.FileHeader.validate(bytes, MAGIC, ZMESH_VERSION);
        const header = try wire.structAt(Header, bytes, 0);
        if (header.part_count == 0) return error.NoMeshes;
        if (header.material_slot_count == 0) return error.NoMaterialSlots;
        const flags: FormatFlags = @bitCast(header.format_flags);
        if (flags._padding != 0) return error.InvalidFormatFlags;
        const index_format = try wire.enumFromInt(IndexFormat, header.index_format);
        const payload_codec = try wire.enumFromInt(Codec, header.codec);
        const joint_format = try wire.enumFromInt(JointFormat, header.joint_format);
        if (header.index_count % 3 != 0) return error.InvalidIndexCount;

        var order = wire.SectionOrder.init(HEADER_SIZE);
        for ([_]wire.Span{ header.parts, header.material_slots, header.submeshes }) |span| try order.next(span);
        for (header.streams) |span| try order.next(span);
        try order.next(header.indices);
        try order.finish(bytes.len);
        if (header.vertex_count > std.math.maxInt(i32)) return error.AssetTooLarge; // GL base vertex is an i32

        const slot_refs = try wire.sectionSlice(wire.AssetRef, bytes, header.material_slots, header.material_slot_count);
        for (slot_refs) |ref| try ref.check();
        const entries = try wire.sectionSlice(PartEntry, bytes, header.parts, header.part_count);
        const submeshes = try wire.sectionSlice(Submesh, bytes, header.submeshes, header.submesh_count);

        for (std.enums.values(Stream)) |stream| {
            const span = header.streams[@intFromEnum(stream)];
            if (!streamPresent(stream, flags)) {
                if (span.len != 0) return error.InvalidLayout;
                continue;
            }
            const decoded_len = @as(u64, header.vertex_count) * streamStride(stream, joint_format);
            try checkPayload(bytes, span, payload_codec, decoded_len);
        }
        try checkPayload(bytes, header.indices, payload_codec, @as(u64, header.index_count) * indexSize(index_format));

        var next_vertex: u64 = 0;
        var next_index: u64 = 0;
        var next_submesh: u64 = 0;
        for (entries) |*entry| {
            if (entry.base_vertex != next_vertex or entry.first_index != next_index or entry.first_submesh != next_submesh)
                return error.InvalidPartRange;
            if (entry.index_count % 3 != 0) return error.InvalidIndexCount;
            if (index_format == .u16 and entry.vertex_count > std.math.maxInt(u16)) return error.InvalidPartRange;
            next_vertex += entry.vertex_count;
            next_index += entry.index_count;
            next_submesh += entry.submesh_count;
            if (next_submesh > submeshes.len) return error.InvalidPartRange;

            const index_end = @as(u64, entry.first_index) + entry.index_count;
            for (submeshes[entry.first_submesh..][0..entry.submesh_count]) |s| {
                if (s._reserved != 0) return error.InvalidLayout;
                // The index codec may rotate triangles, so ranges must not split them.
                if (s.index_offset % 3 != 0 or s.index_count % 3 != 0) return error.InvalidSubmeshRange;
                if (s.index_offset < entry.first_index or @as(u64, s.index_offset) + s.index_count > index_end)
                    return error.InvalidSubmeshRange;
                if (s.material_index >= header.material_slot_count) return error.InvalidMaterialIndex;
            }
        }
        if (next_vertex != header.vertex_count or next_index != header.index_count or next_submesh != header.submesh_count)
            return error.InvalidPartRange;

        return .{
            .bytes = bytes,
            .header = header,
            .part_entries = entries,
            .material_slot_refs = slot_refs,
            .submesh_table = submeshes,
        };
    }

    fn checkPayload(bytes: wire.Bytes, span: wire.Span, payload_codec: Codec, decoded_len: u64) !void {
        _ = try wire.sectionSlice(u8, bytes, span, span.len);
        switch (payload_codec) {
            .none => if (span.len != decoded_len) return error.InvalidLayout,
            // The smallest encoding is a header byte plus a 16-byte tail.
            .meshopt => if (span.len < 17) return error.InvalidLayout,
        }
    }

    pub fn partCount(self: *const ZMesh) usize {
        return self.part_entries.len;
    }

    pub fn part(self: *const ZMesh, index: usize) Part {
        const e = &self.part_entries[index];
        return .{
            .transform = e.transform,
            .aabb_min = e.aabb_min,
            .aabb_max = e.aabb_max,
            .uv0_min = e.uv0_min,
            .uv0_scale = e.uv0_scale,
            .base_vertex = e.base_vertex,
            .vertex_count = e.vertex_count,
            .first_index = e.first_index,
            .index_count = e.index_count,
            .submeshes = self.submesh_table[e.first_submesh..][0..e.submesh_count],
        };
    }

    pub fn materialSlotCount(self: *const ZMesh) usize {
        return self.material_slot_refs.len;
    }

    /// Id of the material asset bound to submeshes with this `material_index`.
    pub fn materialSlot(self: *const ZMesh, index: usize) AssetId {
        return self.material_slot_refs[index].toId();
    }

    pub fn vertexCount(self: *const ZMesh) u32 {
        return self.header.vertex_count;
    }

    pub fn indexCount(self: *const ZMesh) u32 {
        return self.header.index_count;
    }

    pub fn formatFlags(self: *const ZMesh) FormatFlags {
        return @bitCast(self.header.format_flags);
    }

    pub fn indexFormat(self: *const ZMesh) IndexFormat {
        return @enumFromInt(self.header.index_format);
    }

    pub fn codec(self: *const ZMesh) Codec {
        return @enumFromInt(self.header.codec);
    }

    pub fn jointFormat(self: *const ZMesh) JointFormat {
        return @enumFromInt(self.header.joint_format);
    }

    pub fn hasStream(self: *const ZMesh, stream: Stream) bool {
        return streamPresent(stream, self.formatFlags());
    }

    pub fn stride(self: *const ZMesh, stream: Stream) u32 {
        return streamStride(stream, self.jointFormat());
    }

    /// Stored (possibly encoded) bytes of a stream; empty when absent.
    pub fn streamBytes(self: *const ZMesh, stream: Stream) []const u8 {
        const span = self.header.streams[@intFromEnum(stream)];
        return self.bytes[span.offset..][0..span.len];
    }

    /// Stored (possibly encoded) bytes of the index buffer.
    pub fn indexBytes(self: *const ZMesh) []const u8 {
        const span = self.header.indices;
        return self.bytes[span.offset..][0..span.len];
    }

    pub fn decodedStreamSize(self: *const ZMesh, stream: Stream) usize {
        return @as(usize, self.vertexCount()) * self.stride(stream);
    }

    pub fn decodedIndexSize(self: *const ZMesh) usize {
        return @as(usize, self.indexCount()) * indexSize(self.indexFormat());
    }

    /// Decodes a present stream into `out` (`decodedStreamSize` bytes).
    pub fn decodeStream(self: *const ZMesh, stream: Stream, out: []u8) !void {
        if (!self.hasStream(stream)) return error.MissingStream;
        if (out.len != self.decodedStreamSize(stream)) return error.InvalidLayout;
        const data = self.streamBytes(stream);
        switch (self.codec()) {
            .none => @memcpy(out, data),
            .meshopt => try vertex_codec.decode(out, data, self.stride(stream)),
        }
    }

    /// Decodes the index buffer into `out` (`decodedIndexSize` bytes, as
    /// `indexFormat` values) and checks every index against its part's
    /// vertex count, so the result is safe to draw.
    pub fn decodeIndices(self: *const ZMesh, out: []align(4) u8) !void {
        if (out.len != self.decodedIndexSize()) return error.InvalidLayout;
        switch (self.indexFormat()) {
            .u16 => try self.decodeIndicesAs(u16, std.mem.bytesAsSlice(u16, out)),
            .u32 => try self.decodeIndicesAs(u32, std.mem.bytesAsSlice(u32, out)),
        }
    }

    fn decodeIndicesAs(self: *const ZMesh, comptime T: type, out: []align(4) T) !void {
        switch (self.codec()) {
            .none => @memcpy(std.mem.sliceAsBytes(out), self.indexBytes()),
            .meshopt => try index_codec.decode(T, out, self.indexBytes()),
        }
        for (self.part_entries) |e| {
            for (out[e.first_index..][0..e.index_count]) |index| {
                if (index >= e.vertex_count) return error.IndexOutOfRange;
            }
        }
    }

    pub fn write(allocator: std.mem.Allocator, writer: *std.Io.Writer, material_slots: []const AssetId, parts: []const CookPart, options: WriteOptions) !void {
        if (parts.len == 0) return error.NoMeshes;
        if (material_slots.len == 0) return error.NoMaterialSlots;
        if (material_slots.len > std.math.maxInt(u16)) return error.TooManyMaterialSlots;
        for (material_slots) |id| {
            if (id.isZero()) return error.ZeroAssetRef;
        }

        var flags: FormatFlags = .{};
        var vertex_total: u64 = 0;
        var index_total: u64 = 0;
        var submesh_total: u64 = 0;
        var max_part_vertices: usize = 0;
        var max_joint: u16 = 0;
        for (parts) |p| {
            const m = p.mesh;
            if (m.indices.len % 3 != 0) return error.InvalidIndexCount;
            for (m.indices) |i| if (i >= m.vertices.len) return error.IndexOutOfRange;
            for (m.submeshes) |s| {
                if (s.material_index >= material_slots.len) return error.InvalidMaterialIndex;
                if (@as(u64, s.index_offset) + s.index_count > m.indices.len) return error.InvalidSubmeshRange;
                if (s.index_offset % 3 != 0 or s.index_count % 3 != 0) return error.InvalidSubmeshRange;
            }
            flags = @bitCast(@as(u8, @bitCast(flags)) | @as(u8, @bitCast(m.format_flags)));
            vertex_total += m.vertices.len;
            index_total += m.indices.len;
            submesh_total += m.submeshes.len;
            max_part_vertices = @max(max_part_vertices, m.vertices.len);
            if (m.format_flags.has_joints) for (m.vertices) |v| {
                max_joint = @max(max_joint, std.mem.max(u16, &v.joints));
            };
        }
        if (vertex_total > std.math.maxInt(i32) or index_total > std.math.maxInt(u32)) return error.AssetTooLarge;
        const vertex_count: u32 = @intCast(vertex_total);
        const index_count: u32 = @intCast(index_total);
        const index_format: IndexFormat = if (max_part_vertices <= std.math.maxInt(u16)) .u16 else .u32;
        const joint_format: JointFormat = if (max_joint <= std.math.maxInt(u8)) .u8 else .u16;

        // Build every payload up front so the layout knows encoded sizes.
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var stream_payloads: [Stream.count][]const u8 = @splat(&.{});
        for (std.enums.values(Stream)) |stream| {
            if (!streamPresent(stream, flags)) continue;
            const s = streamStride(stream, joint_format);
            const raw = try arena.alloc(u8, @as(usize, vertex_count) * s);
            var pos: usize = 0;
            for (parts) |p| for (p.mesh.vertices) |*v| {
                writeElement(raw[pos..][0..s], stream, v, joint_format);
                pos += s;
            };
            stream_payloads[@intFromEnum(stream)] = switch (options.codec) {
                .none => raw,
                .meshopt => blk: {
                    const buf = try arena.alloc(u8, vertex_codec.encodeBound(vertex_count, s));
                    break :blk buf[0..try vertex_codec.encode(buf, raw, s)];
                },
            };
        }

        const all_indices = try arena.alloc(u32, index_count);
        {
            var pos: usize = 0;
            for (parts) |p| {
                @memcpy(all_indices[pos..][0..p.mesh.indices.len], p.mesh.indices);
                pos += p.mesh.indices.len;
            }
        }
        const index_payload: []const u8 = switch (options.codec) {
            .none => switch (index_format) {
                .u32 => std.mem.sliceAsBytes(all_indices),
                .u16 => blk: {
                    const narrow = try arena.alloc(u16, index_count);
                    for (all_indices, narrow) |src, *dst| dst.* = @intCast(src);
                    break :blk std.mem.sliceAsBytes(narrow);
                },
            },
            .meshopt => blk: {
                const buf = try arena.alloc(u8, index_codec.encodeBound(index_count, max_part_vertices));
                break :blk buf[0..try index_codec.encode(buf, all_indices)];
            },
        };

        var layout = wire.Layout.init(HEADER_SIZE);
        var header: Header = .{
            .file = undefined,
            .part_count = @intCast(parts.len),
            .material_slot_count = @intCast(material_slots.len),
            .submesh_count = @intCast(submesh_total),
            .vertex_count = vertex_count,
            .index_count = index_count,
            .format_flags = @bitCast(flags),
            .index_format = @intFromEnum(index_format),
            .codec = @intFromEnum(options.codec),
            .joint_format = @intFromEnum(joint_format),
            .parts = try layout.reserve(parts.len * @sizeOf(PartEntry)),
            .material_slots = try layout.reserve(material_slots.len * @sizeOf(wire.AssetRef)),
            .submeshes = try layout.reserve(submesh_total * @sizeOf(Submesh)),
            .streams = @splat(.{}),
            .indices = .{},
        };
        for (stream_payloads, &header.streams) |payload, *span| span.* = try layout.reserve(payload.len);
        header.indices = try layout.reserve(index_payload.len);
        const total_size = layout.totalSize();
        header.file = .init(MAGIC, ZMESH_VERSION, total_size);

        var out: wire.LayoutWriter = .{ .writer = writer };
        try out.value(header);

        try out.beginSection(header.parts);
        var base_vertex: u32 = 0;
        var first_index: u32 = 0;
        var first_submesh: u32 = 0;
        for (parts) |p| {
            const m = p.mesh;
            try out.value(PartEntry{
                .transform = p.transform,
                .aabb_min = m.bounds.min,
                .aabb_max = m.bounds.max,
                .uv0_min = m.uv0_bounds.min,
                .uv0_scale = m.uv0_bounds.scale,
                .base_vertex = base_vertex,
                .vertex_count = @intCast(m.vertices.len),
                .first_index = first_index,
                .index_count = @intCast(m.indices.len),
                .first_submesh = first_submesh,
                .submesh_count = @intCast(m.submeshes.len),
            });
            base_vertex += @intCast(m.vertices.len);
            first_index += @intCast(m.indices.len);
            first_submesh += @intCast(m.submeshes.len);
        }

        try out.beginSection(header.material_slots);
        for (material_slots) |id| try out.value(wire.AssetRef.fromId(id));

        try out.beginSection(header.submeshes);
        first_index = 0;
        for (parts) |p| {
            for (p.mesh.submeshes) |s| {
                try out.value(Submesh{ .index_offset = first_index + s.index_offset, .index_count = s.index_count, .material_index = s.material_index });
            }
            first_index += @intCast(p.mesh.indices.len);
        }

        for (stream_payloads, header.streams) |payload, span| try out.section(span, payload);
        try out.section(header.indices, index_payload);
        try out.finish(total_size);
    }

    fn writeElement(dst: []u8, stream: Stream, v: *const mesh.CookedVertex, joint_format: JointFormat) void {
        const src: []const u8 = switch (stream) {
            .positions => std.mem.asBytes(&v.position),
            .normals => std.mem.asBytes(&v.normal),
            .tangents => std.mem.asBytes(&v.tangent),
            .uv0 => std.mem.asBytes(&v.uv0),
            .uv1 => std.mem.asBytes(&v.uv1),
            .weights => std.mem.asBytes(&v.weights),
            .joints => switch (joint_format) {
                .u16 => std.mem.asBytes(&v.joints),
                .u8 => {
                    for (v.joints, dst[0..4]) |j, *d| d.* = @intCast(j);
                    return;
                },
            },
        };
        @memcpy(dst, src);
    }
};

pub fn view(bytes: wire.Bytes) !ZMesh {
    return ZMesh.view(bytes);
}

pub fn write(allocator: std.mem.Allocator, writer: *std.Io.Writer, material_slots: []const AssetId, parts: []const ZMesh.CookPart, options: ZMesh.WriteOptions) !void {
    return ZMesh.write(allocator, writer, material_slots, parts, options);
}

/// Writes a small single-part mesh with normals and uv0. Used by inspector
/// and command tests.
pub fn writeTestZmeshFile(writer: *std.Io.Writer) !void {
    return writeTestZmeshFileWithMaterial(writer, test_material_id);
}

/// `writeTestZmeshFile` with `material` in its one material slot.
pub fn writeTestZmeshFileWithMaterial(writer: *std.Io.Writer, material: AssetId) !void {
    var vertices = [_]mesh.CookedVertex{
        testVertex(.{ 0, 0, 0, 0 }),
        testVertex(.{ 65535, 0, 0, 0 }),
        testVertex(.{ 0, 65535, 0, 0 }),
    };
    var indices = [_]u32{ 0, 1, 2 };
    var submeshes = [_]raw_mesh.RawSubmesh{.{ .index_offset = 0, .index_count = 3, .material_index = 0 }};
    const parts = [_]ZMesh.CookPart{.{
        .mesh = .{
            .vertices = &vertices,
            .indices = &indices,
            .submeshes = &submeshes,
            .format_flags = .{ .has_normals = true, .has_uv0 = true },
            .bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } },
            .name = null,
        },
        .transform = identity_transform,
    }};
    const material_slots = [_]AssetId{material};
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    try ZMesh.write(fba.allocator(), writer, &material_slots, &parts, .{});
}

/// Material slot written by `writeTestZmeshFile`.
pub const test_material_id = AssetId.parseComptime("3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01");

fn testVertex(position: [4]u16) mesh.CookedVertex {
    var v = mesh.CookedVertex.defaults;
    v.position = position;
    return v;
}

const testing = std.testing;

fn makeCookedMesh(vertices: []const mesh.CookedVertex, indices: []const u32, submeshes: []const raw_mesh.RawSubmesh, flags: FormatFlags, bounds: mesh.AABB) mesh.CookedMesh {
    return .{
        .vertices = @constCast(vertices),
        .indices = @constCast(indices),
        .submeshes = @constCast(submeshes),
        .format_flags = flags,
        .bounds = bounds,
        .name = null,
    };
}

const one_slot = [_]AssetId{test_material_id};
const one_submesh = [_]raw_mesh.RawSubmesh{.{ .index_offset = 0, .index_count = 3, .material_index = 0 }};
const unit_bounds: mesh.AABB = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
const tri_verts = [_]mesh.CookedVertex{ testVertex(.{ 0, 0, 0, 0 }), testVertex(.{ 9, 0, 0, 0 }), testVertex(.{ 0, 9, 0, 0 }) };
const tri_indices = [_]u32{ 0, 1, 2 };

fn writeParts(buf: []align(wire.section_alignment) u8, slots: []const AssetId, parts: []const ZMesh.CookPart, codec: Codec) !wire.Bytes {
    var writer = std.Io.Writer.fixed(buf);
    try ZMesh.write(testing.allocator, &writer, slots, parts, .{ .codec = codec });
    return buf[0..writer.end];
}

fn writeSingle(buf: []align(wire.section_alignment) u8, cooked: mesh.CookedMesh, codec: Codec) !wire.Bytes {
    return writeParts(buf, &one_slot, &.{.{ .mesh = cooked, .transform = identity_transform }}, codec);
}

fn decodeAll(allocator: std.mem.Allocator, model: *const ZMesh, stream: Stream) ![]u8 {
    const out = try allocator.alloc(u8, model.decodedStreamSize(stream));
    errdefer allocator.free(out);
    try model.decodeStream(stream, out);
    return out;
}

fn decodeIndicesU32(allocator: std.mem.Allocator, model: *const ZMesh) ![]u32 {
    const out = try allocator.alignedAlloc(u8, .@"4", model.decodedIndexSize());
    defer allocator.free(out);
    try model.decodeIndices(out);
    const result = try allocator.alloc(u32, model.indexCount());
    switch (model.indexFormat()) {
        .u16 => for (std.mem.bytesAsSlice(u16, out), result) |s, *d| {
            d.* = s;
        },
        .u32 => @memcpy(result, std.mem.bytesAsSlice(u32, out)),
    }
    return result;
}

/// Triangles must match up to rotation (the index codec may rotate them).
fn expectSameTriangles(expected: []const u32, actual: []const u32) !void {
    try testing.expectEqual(expected.len, actual.len);
    var i: usize = 0;
    while (i < expected.len) : (i += 3) {
        const e = expected[i..][0..3];
        const a = actual[i..][0..3];
        const ok = (a[0] == e[0] and a[1] == e[1] and a[2] == e[2]) or
            (a[0] == e[1] and a[1] == e[2] and a[2] == e[0]) or
            (a[0] == e[2] and a[1] == e[0] and a[2] == e[1]);
        try testing.expect(ok);
    }
}

test "on-disk struct sizes" {
    try testing.expectEqual(@as(u32, 128), HEADER_SIZE);
    try testing.expectEqual(@as(usize, 128), @sizeOf(PartEntry));
    try testing.expectEqual(@as(usize, 12), @sizeOf(Submesh));
}

test "ZMesh.write records magic, version, and exact total size" {
    for ([_]Codec{ .none, .meshopt }) |codec| {
        var buf: [2048]u8 align(wire.section_alignment) = undefined;
        const bytes = try writeSingle(&buf, makeCookedMesh(&tri_verts, &tri_indices, &one_submesh, .{}, unit_bounds), codec);
        try testing.expectEqualSlices(u8, MAGIC, bytes[0..4]);
        const header = try wire.structAt(Header, bytes, 0);
        try testing.expectEqual(ZMESH_VERSION, header.file.version);
        try testing.expectEqual(@as(u32, @intCast(bytes.len)), header.file.total_size);
        try testing.expectEqual(@intFromEnum(codec), header.codec);
    }
}

test "ZMesh round-trips every stream with both codecs" {
    var verts: [40]mesh.CookedVertex = undefined;
    for (&verts, 0..) |*v, i| {
        const u: u16 = @intCast(i);
        const s: i16 = @intCast(i);
        const b: i8 = @intCast(i);
        v.* = .{
            .position = .{ u * 1000, u, 65535 - u, 0 },
            .normal = .{ s * 100, -s },
            .tangent = .{ b, -b, 127, 0 },
            .uv0 = .{ u, u + 1 },
            .uv1 = .{ u + 2, u + 3 },
            .joints = .{ u, 0, 1, 2 },
            .weights = .{ 200, 55, 0, 0 },
        };
    }
    var indices: [114]u32 = undefined;
    for (0..38) |t| indices[t * 3 ..][0..3].* = .{ @intCast(t), @intCast(t + 1), @intCast(t + 2) };
    const submeshes = [_]raw_mesh.RawSubmesh{
        .{ .index_offset = 0, .index_count = 57, .material_index = 0 },
        .{ .index_offset = 57, .index_count = 57, .material_index = 0 },
    };
    const flags: FormatFlags = .{ .has_normals = true, .has_tangents = true, .has_uv0 = true, .has_uv1 = true, .has_joints = true, .has_weights = true };
    var cooked = makeCookedMesh(&verts, &indices, &submeshes, flags, .{ .min = .{ -1, -2, -3 }, .max = .{ 4, 5, 6 } });
    cooked.uv0_bounds = .{ .min = .{ 0.25, 0.5 }, .scale = .{ 2, 4 } };

    for ([_]Codec{ .none, .meshopt }) |codec| {
        var buf: [8192]u8 align(wire.section_alignment) = undefined;
        const model = try ZMesh.view(try writeSingle(&buf, cooked, codec));
        try testing.expectEqual(JointFormat.u8, model.jointFormat());
        try testing.expectEqual(IndexFormat.u16, model.indexFormat());

        const p = model.part(0);
        try testing.expectEqual([3]f32{ -1, -2, -3 }, p.aabb_min);
        try testing.expectEqual([3]f32{ 4, 5, 6 }, p.aabb_max);
        try testing.expectEqual([2]f32{ 0.25, 0.5 }, p.uv0_min);
        try testing.expectEqual([2]f32{ 2, 4 }, p.uv0_scale);
        try testing.expectEqual(@as(usize, 2), p.submeshes.len);
        try testing.expectEqual(@as(u32, 57), p.submeshes[1].index_offset);

        const a = testing.allocator;
        const positions = try decodeAll(a, &model, .positions);
        defer a.free(positions);
        const normals = try decodeAll(a, &model, .normals);
        defer a.free(normals);
        const tangents = try decodeAll(a, &model, .tangents);
        defer a.free(tangents);
        const uv1 = try decodeAll(a, &model, .uv1);
        defer a.free(uv1);
        const joints = try decodeAll(a, &model, .joints);
        defer a.free(joints);
        const weights = try decodeAll(a, &model, .weights);
        defer a.free(weights);
        for (verts, 0..) |v, i| {
            try testing.expectEqualSlices(u8, std.mem.asBytes(&v.position), positions[i * 8 ..][0..8]);
            try testing.expectEqualSlices(u8, std.mem.asBytes(&v.normal), normals[i * 4 ..][0..4]);
            try testing.expectEqualSlices(u8, std.mem.asBytes(&v.tangent), tangents[i * 4 ..][0..4]);
            try testing.expectEqualSlices(u8, std.mem.asBytes(&v.uv1), uv1[i * 4 ..][0..4]);
            try testing.expectEqualSlices(u8, &.{ @intCast(i), 0, 1, 2 }, joints[i * 4 ..][0..4]);
            try testing.expectEqualSlices(u8, &v.weights, weights[i * 4 ..][0..4]);
        }
        const decoded = try decodeIndicesU32(a, &model);
        defer a.free(decoded);
        try expectSameTriangles(&indices, decoded);
    }
}

test "ZMesh widens joints to u16 when a joint exceeds 255" {
    var verts = tri_verts;
    verts[1].joints = .{ 300, 0, 0, 0 };
    var buf: [2048]u8 align(wire.section_alignment) = undefined;
    const model = try ZMesh.view(try writeSingle(&buf, makeCookedMesh(&verts, &tri_indices, &one_submesh, .{ .has_joints = true }, unit_bounds), .meshopt));
    try testing.expectEqual(JointFormat.u16, model.jointFormat());
    const joints = try decodeAll(testing.allocator, &model, .joints);
    defer testing.allocator.free(joints);
    try testing.expectEqual(@as(u16, 300), std.mem.bytesAsValue(u16, joints[8..10]).*);
}

test "ZMesh merges parts into shared streams with part-local indices" {
    const verts_b = [_]mesh.CookedVertex{ testVertex(.{ 1, 1, 1, 0 }), testVertex(.{ 2, 2, 2, 0 }), testVertex(.{ 3, 3, 3, 0 }), testVertex(.{ 4, 4, 4, 0 }) };
    const indices_b = [_]u32{ 0, 1, 2, 2, 1, 3 };
    const submeshes_b = [_]raw_mesh.RawSubmesh{.{ .index_offset = 3, .index_count = 3, .material_index = 1 }};
    const translated: Transform = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        2, 3, 4, 1,
    };
    const parts = [_]ZMesh.CookPart{
        .{ .mesh = makeCookedMesh(&tri_verts, &tri_indices, &one_submesh, .{}, unit_bounds), .transform = identity_transform },
        .{ .mesh = makeCookedMesh(&verts_b, &indices_b, &submeshes_b, .{ .has_uv0 = true }, unit_bounds), .transform = translated },
    };
    const stone = AssetId.parseComptime("8c1d6602-b3f4-4910-9c44-4b7e9b1a2f6c");
    const material_slots = [_]AssetId{ stone, test_material_id };

    for ([_]Codec{ .none, .meshopt }) |codec| {
        var buf: [4096]u8 align(wire.section_alignment) = undefined;
        const model = try ZMesh.view(try writeParts(&buf, &material_slots, &parts, codec));
        try testing.expect(model.materialSlot(0).eql(stone));
        try testing.expect(model.materialSlot(1).eql(test_material_id));
        try testing.expectEqual(@as(usize, 2), model.partCount());
        try testing.expectEqual(@as(u32, 7), model.vertexCount());
        // The union of part flags is written; part 0 gets default uv0.
        try testing.expect(model.hasStream(.uv0));

        const b = model.part(1);
        try testing.expectEqual(@as(u32, 3), b.base_vertex);
        try testing.expectEqual(@as(u32, 4), b.vertex_count);
        try testing.expectEqual(@as(u32, 3), b.first_index);
        try testing.expectEqual(@as(u32, 6), b.submeshes[0].index_offset);
        try testing.expectEqual(@as(u16, 1), b.submeshes[0].material_index);
        try testing.expectEqual(@as(f32, 2), b.transform[12]);

        const positions = try decodeAll(testing.allocator, &model, .positions);
        defer testing.allocator.free(positions);
        try testing.expectEqualSlices(u8, std.mem.asBytes(&[4]u16{ 4, 4, 4, 0 }), positions[6 * 8 ..][0..8]);

        const decoded = try decodeIndicesU32(testing.allocator, &model);
        defer testing.allocator.free(decoded);
        try expectSameTriangles(&(tri_indices ++ indices_b), decoded);
    }
}

test "ZMesh.write validates inputs" {
    const bad_submesh = [_]raw_mesh.RawSubmesh{.{ .index_offset = 0, .index_count = 3, .material_index = 1 }};
    const parts = [_]ZMesh.CookPart{.{ .mesh = makeCookedMesh(&tri_verts, &tri_indices, &bad_submesh, .{}, unit_bounds), .transform = identity_transform }};
    const bad_index = [_]ZMesh.CookPart{.{ .mesh = makeCookedMesh(&tri_verts, &.{ 0, 1, 3 }, &one_submesh, .{}, unit_bounds), .transform = identity_transform }};
    const verts6 = [_]mesh.CookedVertex{ tri_verts[0], tri_verts[1], tri_verts[2], tri_verts[0], tri_verts[1], tri_verts[2] };
    const split_submesh = [_]raw_mesh.RawSubmesh{.{ .index_offset = 1, .index_count = 3, .material_index = 0 }};
    const split = [_]ZMesh.CookPart{.{ .mesh = makeCookedMesh(&verts6, &.{ 0, 1, 2, 2, 3, 4 }, &split_submesh, .{}, unit_bounds), .transform = identity_transform }};
    const partial = [_]ZMesh.CookPart{.{ .mesh = makeCookedMesh(&tri_verts, &.{ 0, 1 }, &.{}, .{}, unit_bounds), .transform = identity_transform }};

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const a = testing.allocator;
    try testing.expectError(error.NoMeshes, ZMesh.write(a, &writer, &one_slot, &.{}, .{}));
    try testing.expectError(error.NoMaterialSlots, ZMesh.write(a, &writer, &.{}, &parts, .{}));
    try testing.expectError(error.ZeroAssetRef, ZMesh.write(a, &writer, &.{AssetId.zero}, &parts, .{}));
    try testing.expectError(error.InvalidMaterialIndex, ZMesh.write(a, &writer, &one_slot, &parts, .{}));
    try testing.expectError(error.IndexOutOfRange, ZMesh.write(a, &writer, &one_slot, &bad_index, .{}));
    try testing.expectError(error.InvalidIndexCount, ZMesh.write(a, &writer, &one_slot, &partial, .{}));
    try testing.expectError(error.InvalidSubmeshRange, ZMesh.write(a, &writer, &one_slot, &split, .{}));
}

test "ZMesh.view rejects other versions, bad magic, and truncation" {
    var buf: [2048]u8 align(wire.section_alignment) = undefined;
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

fn mutableHeader(buf: []align(wire.section_alignment) u8) *Header {
    return @ptrCast(buf.ptr);
}

fn mutablePartEntry(buf: []align(wire.section_alignment) u8) *PartEntry {
    return @ptrCast(@alignCast(buf.ptr + mutableHeader(buf).parts.offset));
}

test "ZMesh.view rejects corrupted headers and part entries" {
    var buf: [2048]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZmeshFile(&writer);
    const len = writer.end;
    const header = mutableHeader(&buf);
    const entry = mutablePartEntry(&buf);
    const original_header = header.*;
    const original_entry = entry.*;

    header.format_flags |= 0x80;
    try testing.expectError(error.InvalidFormatFlags, ZMesh.view(buf[0..len]));
    header.* = original_header;

    header.codec = 9;
    try testing.expectError(error.InvalidEnumValue, ZMesh.view(buf[0..len]));
    header.* = original_header;

    header.format_flags &= ~@as(u8, 1); // drop has_normals while the normals section remains
    try testing.expectError(error.InvalidLayout, ZMesh.view(buf[0..len]));
    header.* = original_header;

    header.streams[@intFromEnum(Stream.normals)].offset += 4;
    try testing.expectError(error.MisalignedSection, ZMesh.view(buf[0..len]));
    header.* = original_header;

    header.indices.len += 1 << 20; // last section now runs past the file
    try testing.expectError(error.Truncated, ZMesh.view(buf[0..len]));
    header.* = original_header;

    header.streams[@intFromEnum(Stream.tangents)].offset = 0xfffffff0; // absent stream with a stray offset
    try testing.expectError(error.InvalidLayout, ZMesh.view(buf[0..len]));
    header.* = original_header;

    header.vertex_count = 1 << 31;
    try testing.expectError(error.AssetTooLarge, ZMesh.view(buf[0..len]));
    header.* = original_header;

    header.submeshes.offset = header.parts.offset; // aliases the part table
    try testing.expectError(error.OverlappingSections, ZMesh.view(buf[0..len]));
    header.* = original_header;

    entry.vertex_count = 4; // parts no longer tile the vertex range
    try testing.expectError(error.InvalidPartRange, ZMesh.view(buf[0..len]));
    entry.* = original_entry;

    entry.first_index = 3;
    try testing.expectError(error.InvalidPartRange, ZMesh.view(buf[0..len]));
    entry.* = original_entry;

    _ = try ZMesh.view(buf[0..len]);
}

test "ZMesh.view rejects out-of-range submeshes and material indices" {
    var buf: [2048]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZmeshFile(&writer);
    const len = writer.end;
    const header = mutableHeader(&buf);
    const submesh: *Submesh = @ptrCast(@alignCast(buf[header.submeshes.offset..].ptr));

    submesh.index_count = 4;
    try testing.expectError(error.InvalidSubmeshRange, ZMesh.view(buf[0..len]));
    submesh.index_count = 3;
    submesh.material_index = 1;
    try testing.expectError(error.InvalidMaterialIndex, ZMesh.view(buf[0..len]));
    submesh.material_index = 0;

    const slot: *wire.AssetRef = @ptrCast(@alignCast(buf[header.material_slots.offset..].ptr));
    slot.* = .{ .bytes = @splat(0) };
    try testing.expectError(error.ZeroAssetRef, ZMesh.view(buf[0..len]));
}

test "ZMesh.decodeIndices rejects indices outside their part" {
    var buf: [2048]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeSingle(&buf, makeCookedMesh(&tri_verts, &tri_indices, &one_submesh, .{}, unit_bounds), .none);
    const header = mutableHeader(&buf);
    const indices: *[3]u16 = @ptrCast(@alignCast(buf[header.indices.offset..].ptr));
    indices[2] = 3;
    const model = try ZMesh.view(bytes);
    var out: [6]u8 align(4) = undefined;
    try testing.expectError(error.IndexOutOfRange, model.decodeIndices(&out));
}

test "ZMesh.decodeStream never panics on corrupted payloads" {
    var buf: [2048]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZmeshFile(&writer);
    const len = writer.end;
    const header = mutableHeader(&buf).*;
    const payload_start = header.streams[0].offset;

    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    var corrupt: [2048]u8 align(wire.section_alignment) = undefined;
    for (0..500) |_| {
        @memcpy(corrupt[0..len], buf[0..len]);
        corrupt[random.intRangeLessThan(usize, payload_start, len)] = random.int(u8);
        const model = ZMesh.view(corrupt[0..len]) catch continue;
        var stream_out: [3 * 8]u8 = undefined;
        model.decodeStream(.positions, &stream_out) catch {};
        var index_out: [6]u8 align(4) = undefined;
        model.decodeIndices(&index_out) catch {};
    }
}

test "writeTestZmeshFile produces a viewable mesh" {
    var buf: [2048]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZmeshFile(&writer);

    const model = try ZMesh.view(buf[0..writer.end]);
    try testing.expect(model.materialSlot(0).eql(test_material_id));
    try testing.expect(model.hasStream(.normals));
    try testing.expect(model.hasStream(.uv0));
    try testing.expectEqual(@as(u32, 3), model.part(0).index_count);
}
