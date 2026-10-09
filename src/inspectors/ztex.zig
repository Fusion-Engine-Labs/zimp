const std = @import("std");
const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const ztex = @import("../formats/ztex.zig");
const cooked_texture = @import("../assets/cooked/texture.zig");
const wire = @import("../shared/wire.zig");

fn inspectZtex(_: std.mem.Allocator, bytes: wire.Bytes) !void {
    const texture = try ztex.view(bytes);

    log.info("zatex v{d}", .{ztex.ZATEX_VERSION});
    log.info("  Dimensions: {d} x {d} x {d}", .{ texture.width, texture.height, texture.depth });
    log.info("  Layers:     {d}", .{texture.array_layers});
    log.info("  Type:       {s}", .{@tagName(texture.texture_type)});
    log.info("  Format:     {s}", .{@tagName(texture.format)});
    log.info("  Color sp:   {s}", .{@tagName(texture.color_space)});
    log.info("  Mips:       {d}", .{texture.mips.len});

    log.info("", .{});
    log.info("Mip Levels:", .{});
    log.info("  {s: >5}  {s: >8}  {s: >8}  {s: >6}  {s: >10}  {s: >10}", .{ "level", "width", "height", "depth", "offset", "size" });
    log.info("  {s}", .{"-" ** 60});

    var total_data_size: u64 = 0;
    for (texture.mips, 0..) |span, i| {
        total_data_size += span.len;
        const extent = texture.mipExtent(i);
        var size_buf: [16]u8 = undefined;
        log.info("  {d: >5}  {d: >8}  {d: >8}  {d: >6}  {d: >10}  {s: >10}", .{
            i,
            extent.width,
            extent.height,
            extent.depth,
            span.offset,
            fmt.formatBytes(&size_buf, span.len),
        });
    }

    const mip_meta_size: u64 = texture.mips.len * @sizeOf(wire.Span);

    log.info("", .{});
    log.info("File Size Summary:", .{});
    var header_buf: [16]u8 = undefined;
    var metadata_buf: [16]u8 = undefined;
    var data_buf: [16]u8 = undefined;
    var padding_buf: [16]u8 = undefined;
    var total_buf: [16]u8 = undefined;
    log.info("  Header:        {s: >10}", .{fmt.formatBytes(&header_buf, ztex.HEADER_SIZE)});
    log.info("  Mip table:     {s: >10}", .{fmt.formatBytes(&metadata_buf, mip_meta_size)});
    log.info("  Mip data:      {s: >10}", .{fmt.formatBytes(&data_buf, total_data_size)});
    // `view` rejects overlapping sections, so the sections always fit in the file.
    log.info("  Padding:       {s: >10}", .{fmt.formatBytes(&padding_buf, bytes.len - ztex.HEADER_SIZE - mip_meta_size - total_data_size)});
    log.info("  Total:         {s: >10}", .{fmt.formatBytes(&total_buf, bytes.len)});
}

pub fn inspector() FormatInspector {
    return .{ .inspect_fn = inspectZtex };
}

test "inspectZtex reports a layout error for overlapping mips instead of crashing" {
    var buf: [256]u8 align(wire.section_alignment) = undefined;
    try std.testing.expectError(error.OverlappingSections, inspectZtex(std.testing.allocator, ztex.writeAliasedMipFile(&buf)));
}

test "inspectZtex uses the format view" {
    var data = [_]u8{ 0, 0, 0, 0 };
    var mips = [_]cooked_texture.CookedMip{.{
        .width = 1,
        .height = 1,
        .data = &data,
    }};
    const cooked = cooked_texture.CookedTexture{
        .width = 1,
        .height = 1,
        .format = .rgba8,
        .color_space = .srgb,
        .mips = &mips,
    };

    var file_buf: [128]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try ztex.write(&writer, cooked);

    try inspectZtex(std.testing.allocator, file_buf[0..writer.end]);
}
