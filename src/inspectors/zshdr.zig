const std = @import("std");
const string_list = @import("../shared/string_list.zig");

const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const zshdr = @import("../formats/zshdr.zig");
const wire = @import("../shared/wire.zig");

fn inspectZshdr(allocator: std.mem.Allocator, bytes: wire.Bytes) !void {
    _ = allocator;
    const shader = try zshdr.view(bytes);
    const variant_count = shader.variantCount();

    var size_buf: [16]u8 = undefined;
    log.info("zshdr", .{});
    log.info("  Magic:         {s}", .{zshdr.MAGIC});
    log.info("  Version:       {d}", .{zshdr.ZSHDR_VERSION});
    log.info("  Stage:         {s}", .{@tagName(shader.stage)});
    log.info("  Format:        glsl_source (minified)", .{});
    log.info("  Variants:      {d} ({d} permutations)", .{ variant_count, @as(u64, 1) << @intCast(variant_count) });
    log.info("  Prologue:      {s}", .{std.mem.trim(u8, shader.prologue, "\n")});
    log.info("  Body:          {s}, {d} lines", .{ fmt.formatBytes(&size_buf, shader.body.len), std.mem.count(u8, shader.body, "\n") });

    if (variant_count > 0) {
        log.info("", .{});
        log.info("Variant Dimensions:", .{});
        for (0..variant_count) |i| {
            log.info("  bit {d}: {s}", .{ i, shader.variantName(i) });
        }
    }

    log.info("", .{});
    var total_buf: [16]u8 = undefined;
    log.info("File Size Summary:", .{});
    log.info("  Total: {s: >10}", .{fmt.formatBytes(&total_buf, bytes.len)});
}

pub fn inspector() FormatInspector {
    return .{ .inspect_fn = inspectZshdr };
}

test "inspectZshdr uses the format view" {
    var cooked = zshdr.CookedShader{
        .stage = .vertex,
        .variant_names = try string_list.dupeStringList(std.testing.allocator, &.{"SKINNED"}),
        .prologue = try std.testing.allocator.dupe(u8, "#version 330 core\n"),
        .body = try std.testing.allocator.dupe(u8, "void main(){}\n"),
    };
    defer cooked.deinit(std.testing.allocator);

    var file_buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try zshdr.write(&writer, cooked);

    try inspectZshdr(std.testing.allocator, file_buf[0..writer.end]);
}
