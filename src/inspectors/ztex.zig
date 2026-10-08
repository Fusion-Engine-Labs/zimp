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
    log.info("  Dimensions: {d} x {d}", .{ texture.width, texture.height });
    log.info("  Type:       {s}", .{@tagName(texture.texture_type)});
    log.info("  Format:     {s}", .{@tagName(texture.format)});
    log.info("  Color sp:   {s}", .{@tagName(texture.color_space)});
    log.info("  Mips:       {d}", .{texture.mips.len});

    log.info("", .{});
    log.info("Mip Levels:", .{});
    log.info("  {s: >5}  {s: >8}  {s: >8}  {s: >10}  {s: >10}", .{ "level", "width", "height", "offset", "size" });
    log.info("  {s}", .{"-" ** 52});

    var total_data_size: u64 = 0;
    for (texture.mips, 0..) |mip, i| {
        total_data_size += mip.data.len;
        var size_buf: [16]u8 = undefined;
        log.info("  {d: >5}  {d: >8}  {d: >8}  {d: >10}  {s: >10}", .{
            i,
            mip.width,
            mip.height,
            mip.data.offset,
            fmt.formatBytes(&size_buf, mip.data.len),
        });
    }

    const mip_meta_size: u64 = texture.mips.len * @sizeOf(ztex.MipEntry);

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
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const data_offset = ztex.HEADER_SIZE + 32 * @sizeOf(ztex.MipEntry);
    var writer = std.Io.Writer.fixed(&buf);
    var out: wire.LayoutWriter = .{ .writer = &writer };
    try out.value(ztex.Header{
        .file = .init(ztex.MAGIC, ztex.ZATEX_VERSION, data_offset + 1),
        .width = 1,
        .height = 1,
        .mip_count = 32,
        .format = @intFromEnum(cooked_texture.TexelFormat.r8),
        .texture_type = @intFromEnum(ztex.TextureType.texture_2d),
        .color_space = 1,
    });
    for (0..32) |_| try out.value(ztex.MipEntry{ .width = 1, .height = 1, .data = .{ .offset = data_offset, .len = 1 } });
    try out.bytes(&.{0});

    try std.testing.expectError(error.OverlappingSections, inspectZtex(std.testing.allocator, buf[0..writer.end]));
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
