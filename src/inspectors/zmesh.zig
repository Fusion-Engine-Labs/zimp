const std = @import("std");
const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const zmesh = @import("../formats/zmesh.zig");
const wire = @import("../shared/wire.zig");

fn inspectZmesh(_: std.mem.Allocator, bytes: wire.Bytes) !void {
    const model = try zmesh.view(bytes);

    log.info("zmesh v{d}", .{zmesh.ZMESH_VERSION});
    log.info("Codec:       {s}", .{@tagName(model.codec())});
    log.info("Vertices:    {d}", .{model.vertexCount()});
    log.info("Indices:     {d}", .{model.indexCount()});
    log.info("Triangles:   {d}", .{model.indexCount() / 3});
    log.info("Index fmt:   {s}", .{@tagName(model.indexFormat())});
    log.info("Material slots: {d}", .{model.materialSlotCount()});
    for (0..model.materialSlotCount()) |i| {
        log.info("  [{d}] {f}", .{ i, model.materialSlot(i) });
    }

    log.info("", .{});
    log.info("Streams:", .{});
    log.info("  {s: <10}  {s: <8}  {s: >10}  {s: >10}", .{ "stream", "type", "stored", "decoded" });
    for (std.enums.values(zmesh.Stream)) |stream| {
        if (!model.hasStream(stream)) continue;
        logSection(@tagName(stream), streamType(stream, model.jointFormat()), model.streamBytes(stream).len, model.decodedStreamSize(stream));
    }
    logSection("indices", @tagName(model.indexFormat()), model.indexBytes().len, model.decodedIndexSize());

    log.info("", .{});
    log.info("Mesh parts: {d}", .{model.partCount()});
    for (0..model.partCount()) |i| inspectPart(i, model.part(i));

    log.info("", .{});
    var total_buf: [16]u8 = undefined;
    log.info("Model file size: {s}", .{fmt.formatBytes(&total_buf, bytes.len)});
}

fn streamType(stream: zmesh.Stream, joint_format: zmesh.JointFormat) []const u8 {
    return switch (stream) {
        .positions => "[4]u16",
        .normals => "[2]i16",
        .tangents => "[4]i8",
        .uv0, .uv1 => "[2]u16",
        .joints => if (joint_format == .u16) "[4]u16" else "[4]u8",
        .weights => "[4]u8",
    };
}

fn logSection(name: []const u8, type_name: []const u8, stored: usize, decoded: usize) void {
    var stored_buf: [16]u8 = undefined;
    var decoded_buf: [16]u8 = undefined;
    log.info("  {s: <10}  {s: <8}  {s: >10}  {s: >10}", .{ name, type_name, fmt.formatBytes(&stored_buf, stored), fmt.formatBytes(&decoded_buf, decoded) });
}

fn inspectPart(index: usize, part: zmesh.ZMesh.Part) void {
    log.info("", .{});
    log.info("Part {d}:", .{index});
    log.info("  Translation: [{d:.4}, {d:.4}, {d:.4}]", .{ part.transform[12], part.transform[13], part.transform[14] });
    log.info("  Vertices:    {d} (base {d})", .{ part.vertex_count, part.base_vertex });
    log.info("  Indices:     {d} (first {d})", .{ part.index_count, part.first_index });
    log.info("  AABB min:    [{d:.4}, {d:.4}, {d:.4}]", .{ part.aabb_min[0], part.aabb_min[1], part.aabb_min[2] });
    log.info("  AABB max:    [{d:.4}, {d:.4}, {d:.4}]", .{ part.aabb_max[0], part.aabb_max[1], part.aabb_max[2] });
    log.info("  UV0 min:     [{d:.4}, {d:.4}]  scale: [{d:.4}, {d:.4}]", .{ part.uv0_min[0], part.uv0_min[1], part.uv0_scale[0], part.uv0_scale[1] });

    log.info("  Submeshes ({d}):", .{part.submeshes.len});
    log.info("    {s: >5}  {s: >12}  {s: >12}  {s: >10}  {s: >8}", .{ "index", "index_offset", "index_count", "triangles", "material" });
    for (part.submeshes, 0..) |submesh, i| {
        log.info("    {d: >5}  {d: >12}  {d: >12}  {d: >10}  {d: >8}", .{
            i,
            submesh.index_offset,
            submesh.index_count,
            submesh.index_count / 3,
            submesh.material_index,
        });
    }
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
