const std = @import("std");

const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const zamat = @import("../formats/zamat.zig");
const wire = @import("../shared/wire.zig");

fn inspectZamat(_: std.mem.Allocator, bytes: wire.Bytes) !void {
    const material = try zamat.view(bytes);

    log.info("zamat v{d}", .{zamat.ZAMAT_VERSION});
    log.info("  Magic:       {s}", .{zamat.MAGIC});
    log.info("  Version:     {d}", .{zamat.ZAMAT_VERSION});
    log.info("  Shader hash: 0x{x:0>16}", .{material.shader_path_hash});
    log.info("  Alpha mode:  {s}", .{@tagName(material.render_state.alpha_mode)});
    log.info("  Alpha cut:   {d}", .{material.render_state.alpha_cutoff});
    log.info("  Cull mode:   {s}", .{@tagName(material.render_state.cull_mode)});
    log.info("  Blend mode:  {s}", .{@tagName(material.render_state.blend_mode)});
    log.info("  Textures:    {d}", .{material.texture_slots.len});
    log.info("  Params:      {d}", .{material.params.len});
    log.info("  Variants:    {d}", .{material.requiredVariantCount()});

    log.info("", .{});
    log.info("Shader Paths:", .{});
    log.info("  Vertex:   {s}", .{material.vertex_shader_path});
    log.info("  Fragment: {s}", .{material.fragment_shader_path});

    log.info("", .{});
    log.info("Required Variants:", .{});
    for (0..material.requiredVariantCount()) |i| {
        log.info("  {s}", .{material.requiredVariant(i)});
    }

    log.info("", .{});
    log.info("Texture Slots:", .{});
    log.info("  {s: >5}  {s: >18}  {s: >18}  {s: <24}  {s}", .{ "index", "slot_hash", "texture_hash", "name", "cooked_path" });
    log.info("  {s}", .{"-" ** 88});
    for (0..material.texture_slots.len) |i| {
        const entry = material.textureSlot(i);
        log.info("  {d: >5}  0x{x:0>16}  0x{x:0>16}  {s: <24}  {s}", .{
            i,
            entry.slot_name_hash,
            entry.texture_path_hash,
            entry.sampler_name,
            entry.cooked_path,
        });
    }

    log.info("", .{});
    log.info("Params:", .{});
    log.info("  {s: >5}  {s: <24}  {s: <8}  {s: >8}  {s: >8}  {s}", .{ "index", "name", "type", "offset", "size", "value" });
    log.info("  {s}", .{"-" ** 78});
    for (material.params, 0..) |raw, i| {
        const entry = material.param(i);
        var value_buf: [96]u8 = undefined;
        log.info("  {d: >5}  {s: <24}  {s: <8}  {d: >8}  {d: >8}  {s}", .{
            i,
            entry.name,
            @tagName(entry.param_type),
            raw.data.offset,
            raw.data.len,
            formatParamValue(&value_buf, entry),
        });
    }

    const texture_table_size: u64 = material.texture_slots.len * @sizeOf(zamat.TextureSlot);
    const param_table_size: u64 = material.params.len * @sizeOf(zamat.Param);
    const variant_table_size: u64 = material.variant_refs.len * @sizeOf(wire.Span);

    log.info("", .{});
    log.info("File Size Summary:", .{});
    var header_buf: [16]u8 = undefined;
    var texture_buf: [16]u8 = undefined;
    var param_buf: [16]u8 = undefined;
    var variant_buf: [16]u8 = undefined;
    var data_buf: [16]u8 = undefined;
    var strings_buf: [16]u8 = undefined;
    var total_buf: [16]u8 = undefined;
    log.info("  Header:         {s: >10}", .{fmt.formatBytes(&header_buf, zamat.HEADER_SIZE)});
    log.info("  Texture table:  {s: >10}", .{fmt.formatBytes(&texture_buf, texture_table_size)});
    log.info("  Param table:    {s: >10}", .{fmt.formatBytes(&param_buf, param_table_size)});
    log.info("  Variant table:  {s: >10}", .{fmt.formatBytes(&variant_buf, variant_table_size)});
    log.info("  Param data:     {s: >10}", .{fmt.formatBytes(&data_buf, material.param_data.len)});
    log.info("  Strings:        {s: >10}", .{fmt.formatBytes(&strings_buf, material.strings.len)});
    log.info("  Total:          {s: >10}", .{fmt.formatBytes(&total_buf, bytes.len)});
}

fn formatParamValue(buf: []u8, entry: zamat.ParamView) []const u8 {
    const bytes = entry.data;
    const expected_size: usize = switch (entry.param_type) {
        .float, .int, .bool => 4,
        .vec2 => 8,
        .vec3 => 12,
        .vec4 => 16,
    };
    if (bytes.len < expected_size) return "(invalid size)";

    return switch (entry.param_type) {
        .float => std.fmt.bufPrint(buf, "{d}", .{readF32(bytes[0..4])}) catch "(format error)",
        .vec2 => std.fmt.bufPrint(buf, "[{d}, {d}]", .{ readF32(bytes[0..4]), readF32(bytes[4..8]) }) catch "(format error)",
        .vec3 => std.fmt.bufPrint(buf, "[{d}, {d}, {d}]", .{ readF32(bytes[0..4]), readF32(bytes[4..8]), readF32(bytes[8..12]) }) catch "(format error)",
        .vec4 => std.fmt.bufPrint(buf, "[{d}, {d}, {d}, {d}]", .{ readF32(bytes[0..4]), readF32(bytes[4..8]), readF32(bytes[8..12]), readF32(bytes[12..16]) }) catch "(format error)",
        .int => std.fmt.bufPrint(buf, "{d}", .{std.mem.readInt(i32, bytes[0..4], .little)}) catch "(format error)",
        .bool => std.fmt.bufPrint(buf, "{s}", .{if (std.mem.readInt(u32, bytes[0..4], .little) != 0) "true" else "false"}) catch "(format error)",
    };
}

fn readF32(bytes: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}

pub fn inspector() FormatInspector {
    return .{ .inspect_fn = inspectZamat };
}

test "inspectZamat uses the format view" {
    const raw_material = @import("../assets/raw/material.zig");
    const CookedMaterial = @import("../assets/cooked/material.zig").CookedMaterial;

    var parsed = try raw_material.parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[texture.u_albedo]
        \\path = "textures/test_albedo.png"
        \\[params]
        \\u_roughness = 0.5
        \\
    , std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);

    var cooked = try CookedMaterial.cook(std.testing.allocator, &parsed);
    defer cooked.deinit(std.testing.allocator);

    var file_buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try zamat.write(&writer, cooked);

    try inspectZamat(std.testing.allocator, file_buf[0..writer.end]);
}
