const std = @import("std");
const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const zmesh = @import("../formats/zmesh.zig");
const wire = @import("../shared/wire.zig");

fn inspectZmesh(_: std.mem.Allocator, bytes: wire.Bytes) !void {
    const model = try zmesh.view(bytes);

    log.info("zmesh v{d}", .{zmesh.ZMESH_VERSION});
    log.info("Material slots: {d}", .{model.materialSlotCount()});
    for (0..model.materialSlotCount()) |i| {
        log.info("  [{d}] {f}", .{ i, model.materialSlot(i) });
    }
    log.info("Mesh parts: {d}", .{model.partCount()});

    for (0..model.partCount()) |i| {
        inspectPart(i, model.part(i), &model.part_entries[i]);
    }

    log.info("", .{});
    var total_buf: [16]u8 = undefined;
    log.info("Model file size: {s}", .{fmt.formatBytes(&total_buf, bytes.len)});
}

fn inspectPart(index: usize, part: zmesh.ZMesh.Part, entry: *const zmesh.PartEntry) void {
    const mesh = part.mesh;
    const index_format = if (mesh.indices_u16 != null) "u16" else "u32";

    log.info("", .{});
    log.info("Part {d}:", .{index});
    log.info("  Translation: [{d:.4}, {d:.4}, {d:.4}]", .{ part.transform[12], part.transform[13], part.transform[14] });
    log.info("  Vertices:    {d}", .{mesh.vertex_count});
    log.info("  Indices:     {d}", .{mesh.index_count});
    log.info("  Triangles:   {d}", .{mesh.index_count / 3});
    log.info("  Index fmt:   {s}", .{index_format});

    log.info("", .{});
    log.info("Vertex Streams:", .{});
    log.info("  positions    {d} x [3]f32", .{mesh.positions.len});
    if (mesh.normals) |values| log.info("  normals      {d} x [2]i16", .{values.len});
    if (mesh.tangents) |values| log.info("  tangents     {d} x [4]f16", .{values.len});
    if (mesh.uv0) |values| log.info("  uv0          {d} x [2]u16", .{values.len});
    if (mesh.uv1) |values| log.info("  uv1          {d} x [2]u16", .{values.len});
    if (mesh.joint_indices) |values| log.info("  joints       {d} x [4]u16", .{values.len});
    if (mesh.joint_weights) |values| log.info("  weights      {d} x [4]f16", .{values.len});

    log.info("", .{});
    log.info("AABB:", .{});
    log.info("  min: [{d:.4}, {d:.4}, {d:.4}]", .{ mesh.aabb_min[0], mesh.aabb_min[1], mesh.aabb_min[2] });
    log.info("  max: [{d:.4}, {d:.4}, {d:.4}]", .{ mesh.aabb_max[0], mesh.aabb_max[1], mesh.aabb_max[2] });

    if (mesh.uv0 != null) {
        log.info("", .{});
        log.info("UV0 Bounds:", .{});
        log.info("  min:   [{d:.4}, {d:.4}]", .{ mesh.uv0_min[0], mesh.uv0_min[1] });
        log.info("  scale: [{d:.4}, {d:.4}]", .{ mesh.uv0_scale[0], mesh.uv0_scale[1] });
    }

    log.info("", .{});
    log.info("Submeshes ({d}):", .{mesh.submeshes.len});
    log.info("  {s: >5}  {s: >12}  {s: >12}  {s: >10}  {s: >8}", .{ "index", "index_offset", "index_count", "triangles", "material" });
    log.info("  {s}", .{"-" ** 55});
    for (mesh.submeshes, 0..) |submesh, i| {
        log.info("  {d: >5}  {d: >12}  {d: >12}  {d: >10}  {d: >8}", .{
            i,
            submesh.index_offset,
            submesh.index_count,
            submesh.index_count / 3,
            submesh.material_index,
        });
    }

    var vertex_bytes: u64 = 0;
    for ([_]wire.Span{ entry.positions, entry.normals, entry.tangents, entry.uv0, entry.uv1, entry.joint_indices, entry.joint_weights }) |span| {
        vertex_bytes += span.len;
    }

    log.info("", .{});
    log.info("Section Sizes:", .{});
    var vertex_buf: [16]u8 = undefined;
    var index_buf: [16]u8 = undefined;
    var submesh_buf: [16]u8 = undefined;
    log.info("  Vertex streams: {s: >10}", .{fmt.formatBytes(&vertex_buf, vertex_bytes)});
    log.info("  Index buffer:   {s: >10}", .{fmt.formatBytes(&index_buf, entry.indices.len)});
    log.info("  Submesh table:  {s: >10}", .{fmt.formatBytes(&submesh_buf, entry.submeshes.len)});
}

pub fn inspector() FormatInspector {
    return .{ .inspect_fn = inspectZmesh };
}

test "inspectZmesh uses the format view" {
    var file_buf: [4096]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try zmesh.writeTestZmeshFile(&writer);

    try inspectZmesh(std.testing.allocator, file_buf[0..writer.end]);
}
