const std = @import("std");
const string_list = @import("../shared/string_list.zig");

const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const zshdr = @import("../formats/zshdr.zig");
const wire = @import("../shared/wire.zig");

fn firstLine(source: []const u8) []const u8 {
    const line = if (std.mem.indexOfScalar(u8, source, '\n')) |end| source[0..end] else source;
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn appendDecodedDefines(out: *std.ArrayList(u8), allocator: std.mem.Allocator, key: zshdr.VariantKey, shader: *const zshdr.ZShader) !void {
    if (key.bits == 0) {
        try out.appendSlice(allocator, "(base)");
        return;
    }

    var first = true;
    for (0..shader.variantCount()) |i| {
        if (!key.has(i)) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, shader.variantName(i));
        first = false;
    }
    if (first) try out.appendSlice(allocator, "(unknown bits)");
}

fn formatKeyBits(buf: []u8, key: zshdr.VariantKey, variant_count: usize) []const u8 {
    const width = @max(variant_count, 1);
    std.debug.assert(buf.len >= width + 2);
    buf[0] = '0';
    buf[1] = 'b';
    for (0..width) |i| {
        buf[2 + i] = if (key.has(width - 1 - i)) '1' else '0';
    }
    return buf[0 .. width + 2];
}

fn inspectZshdr(allocator: std.mem.Allocator, bytes: wire.Bytes) !void {
    const shader = try zshdr.view(bytes);

    log.info("zshdr", .{});
    log.info("  Magic:         {s}", .{zshdr.MAGIC});
    log.info("  Version:       {d}", .{zshdr.ZSHDR_VERSION});
    log.info("  Stage:         {s}", .{@tagName(shader.stage)});
    log.info("  Format:        glsl_source", .{});
    log.info("  Variant names: {d}", .{shader.variantCount()});
    log.info("  Variant count: {d}", .{shader.permutations.len});
    log.info("  Includes:      {d}", .{shader.includeCount()});

    if (shader.variantCount() > 0) {
        log.info("", .{});
        log.info("Variant Dimensions:", .{});
        for (0..shader.variantCount()) |i| {
            log.info("  bit {d}: {s}", .{ i, shader.variantName(i) });
        }
    }

    log.info("", .{});
    log.info("Variant Table:", .{});
    log.info("  {s: >5}  {s: <18}  {s: <28}  {s: >10}  {s}", .{ "index", "key", "defines", "payload", "first line" });
    log.info("  {s}", .{"-" ** 86});

    for (shader.permutations, 0..) |permutation, i| {
        const key = zshdr.VariantKey.fromBits(permutation.key);
        const source = shader.permutationSource(i);
        var key_buf: [66]u8 = undefined;
        var defines = std.ArrayList(u8).empty;
        defer defines.deinit(allocator);
        try appendDecodedDefines(&defines, allocator, key, &shader);

        var size_buf: [16]u8 = undefined;
        log.info("  {d: >5}  {s: <18}  {s: <28}  {s: >10}  {s}", .{
            i,
            formatKeyBits(&key_buf, key, shader.variantCount()),
            defines.items,
            fmt.formatBytes(&size_buf, source.len),
            firstLine(source),
        });
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
    const variant_names = try string_list.dupeStringList(std.testing.allocator, &.{"SKINNED"});
    const includes = try string_list.dupeStringList(std.testing.allocator, &.{"common.glsl"});
    const permutations = try std.testing.allocator.alloc(zshdr.CookedShader.Permutation, 1);
    permutations[0] = .{
        .key = .base,
        .source = try std.testing.allocator.dupe(u8, "#version 330 core\nvoid main() {}\n"),
    };

    var cooked = zshdr.CookedShader{
        .stage = .vertex,
        .variant_names = variant_names,
        .includes = includes,
        .permutations = permutations,
    };
    defer cooked.deinit(std.testing.allocator);

    var file_buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try zshdr.write(&writer, cooked);

    try inspectZshdr(std.testing.allocator, file_buf[0..writer.end]);
}
