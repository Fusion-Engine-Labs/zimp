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
    log.info("  Alpha mode:  {s}", .{@tagName(material.render_state.alpha_mode)});
    log.info("  Alpha cut:   {d}", .{material.render_state.alpha_cutoff});
    log.info("  Cull mode:   {s}", .{@tagName(material.render_state.cull_mode)});
    log.info("  Blend mode:  {s}", .{@tagName(material.render_state.blend_mode)});
    log.info("  Textures:    {d}", .{material.texture_slots.len});
    log.info("  Params:      {d}", .{material.params.len});
    log.info("  Variants:    {d}", .{material.variant_hashes.len});
    log.info("  Names are stored as 64-bit FNV-1a hashes.", .{});

    log.info("", .{});
    log.info("Shaders:", .{});
    log.info("  Vertex:   {f}", .{material.vertex_shader});
    log.info("  Fragment: {f}", .{material.fragment_shader});

    log.info("", .{});
    log.info("Required Variants:", .{});
    for (material.variant_hashes) |hash| log.info("  0x{x:0>16}", .{hash});

    log.info("", .{});
    log.info("Texture Slots:", .{});
    log.info("  {s: >5}  {s: >18}  {s: >3}  {s: <36}  {s}", .{ "index", "name_hash", "uv", "texture", "sampler" });
    log.info("  {s}", .{"-" ** 100});
    for (0..material.texture_slots.len) |i| {
        const entry = material.textureSlot(i);
        const sampler = entry.sampler;
        log.info("  {d: >5}  0x{x:0>16}  {d: >3}  {f}  {s}/{s}/{s} {s}/{s} aniso {d}", .{
            i,
            entry.name_hash,
            entry.uv_set,
            entry.texture,
            @tagName(sampler.min_filter),
            @tagName(sampler.mag_filter),
            @tagName(sampler.mip_filter),
            @tagName(sampler.wrap_s),
            @tagName(sampler.wrap_t),
            sampler.max_anisotropy,
        });
    }

    log.info("", .{});
    log.info("Params:", .{});
    log.info("  {s: >5}  {s: >18}  {s: <6}  {s}", .{ "index", "name_hash", "type", "value" });
    log.info("  {s}", .{"-" ** 60});
    for (0..material.params.len) |i| {
        const entry = material.param(i);
        var value_buf: [96]u8 = undefined;
        log.info("  {d: >5}  0x{x:0>16}  {s: <6}  {s}", .{
            i,
            entry.name_hash,
            @tagName(entry.value),
            formatParamValue(&value_buf, entry.value),
        });
    }

    const texture_table_size: u64 = material.texture_slots.len * @sizeOf(zamat.TextureSlot);
    const param_table_size: u64 = material.params.len * @sizeOf(zamat.Param);
    const variant_table_size: u64 = material.variant_hashes.len * @sizeOf(u64);

    log.info("", .{});
    log.info("File Size Summary:", .{});
    var header_buf: [16]u8 = undefined;
    var texture_buf: [16]u8 = undefined;
    var param_buf: [16]u8 = undefined;
    var variant_buf: [16]u8 = undefined;
    var total_buf: [16]u8 = undefined;
    log.info("  Header:         {s: >10}", .{fmt.formatBytes(&header_buf, zamat.HEADER_SIZE)});
    log.info("  Texture table:  {s: >10}", .{fmt.formatBytes(&texture_buf, texture_table_size)});
    log.info("  Param table:    {s: >10}", .{fmt.formatBytes(&param_buf, param_table_size)});
    log.info("  Variant table:  {s: >10}", .{fmt.formatBytes(&variant_buf, variant_table_size)});
    log.info("  Total:          {s: >10}", .{fmt.formatBytes(&total_buf, bytes.len)});
}

fn formatParamValue(buf: []u8, value: zamat.ParamValue) []const u8 {
    return switch (value) {
        .float => |v| std.fmt.bufPrint(buf, "{d}", .{v}),
        .vec2 => |v| std.fmt.bufPrint(buf, "[{d}, {d}]", .{ v[0], v[1] }),
        .vec3 => |v| std.fmt.bufPrint(buf, "[{d}, {d}, {d}]", .{ v[0], v[1], v[2] }),
        .vec4 => |v| std.fmt.bufPrint(buf, "[{d}, {d}, {d}, {d}]", .{ v[0], v[1], v[2], v[3] }),
        .int => |v| std.fmt.bufPrint(buf, "{d}", .{v}),
        .bool => |v| std.fmt.bufPrint(buf, "{}", .{v}),
    } catch "(format error)";
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

    var cooked = try CookedMaterial.cook(std.testing.allocator, &parsed, .zero);
    defer cooked.deinit(std.testing.allocator);

    var file_buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try zamat.write(&writer, cooked);

    try inspectZamat(std.testing.allocator, file_buf[0..writer.end]);
}
