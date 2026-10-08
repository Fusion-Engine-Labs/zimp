const std = @import("std");
const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const cache = @import("../cache/cache.zig");
const AssetKind = @import("../assets/asset.zig").AssetKind;
const FLAG_ERRORED = @import("../cache/entry.zig").FLAG_ERRORED;
const wire = @import("../shared/wire.zig");

fn padRight(buf: []u8, s: []const u8, width: usize) []const u8 {
    @memcpy(buf[0..s.len], s);
    const pad = width - s.len;
    @memset(buf[s.len..][0..pad], ' ');
    return buf[0 .. s.len + pad];
}

fn inspectZCache(allocator: std.mem.Allocator, bytes: wire.Bytes) !void {
    var fixed_reader = std.Io.Reader.fixed(bytes);
    const reader = &fixed_reader;
    var magic: [cache.MAGIC.len]u8 = undefined;
    try reader.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, cache.MAGIC)) return error.InvalidMagic;

    var c = try cache.Cache.read(allocator, reader);
    defer c.deinit(allocator);

    log.info("zcache v{d}", .{c.header.version});
    log.info("  Output dir: {s}", .{if (c.output_dir_path.len > 0) c.output_dir_path else "(none)"});
    log.info("  Host OS: {s}", .{if (c.host_os.len > 0) c.host_os else "(unknown)"});
    log.info("  Entries: {d}", .{c.header.entry_count});

    var max_source_len: usize = "source".len;
    var max_cooked_len: usize = "cooked".len;
    for (c.entries.items) |entry| {
        if (entry.source_path.len > max_source_len) max_source_len = entry.source_path.len;
        if (entry.cooked_path.len > max_cooked_len) max_cooked_len = entry.cooked_path.len;
    }
    const source_col = max_source_len + 1;
    const cooked_col = max_cooked_len + 1;

    const source_buf = try allocator.alloc(u8, source_col);
    defer allocator.free(source_buf);
    const cooked_buf = try allocator.alloc(u8, cooked_col);
    defer allocator.free(cooked_buf);

    log.info("", .{});
    log.info("Entries:", .{});
    log.info("  {s} {s: <18} {s: <18} {s: <10} {s: <22} {s} {s: <18} {s: <10} {s: <22} {s: <8} {s: <8}", .{
        padRight(source_buf, "source", source_col),
        "source_hash",
        "content_hash",
        "src_size",
        "last_updated",
        padRight(cooked_buf, "cooked", cooked_col),
        "cooked_hash",
        "cook_size",
        "cooked_at",
        "type",
        "status",
    });

    const dash_len = source_col + cooked_col + 142;
    const dashes = try allocator.alloc(u8, dash_len);
    defer allocator.free(dashes);
    @memset(dashes, '-');
    log.info("  {s}", .{dashes});

    var total_source_size: u64 = 0;
    var total_cooked_size: u64 = 0;

    for (c.entries.items) |entry| {
        var hash1: [20]u8 = undefined;
        var hash2: [20]u8 = undefined;
        var hash3: [20]u8 = undefined;
        var size1: [16]u8 = undefined;
        var size2: [16]u8 = undefined;
        var ts: [24]u8 = undefined;
        var ts2: [24]u8 = undefined;

        const status: []const u8 = if (entry.flags & FLAG_ERRORED != 0) "ERRORED" else "COOKED";

        log.info("  {s} {s: >18} {s: >18} {s: <10} {s: <22} {s} {s: >18} {s: <10} {s: <22} {s: <8} {s: <8}", .{
            padRight(source_buf, entry.source_path, source_col),
            fmt.formatHash(&hash1, entry.source_path_hash),
            fmt.formatHash(&hash2, entry.content_hash),
            fmt.formatBytes(&size1, entry.source_size),
            fmt.formatTimestamp(&ts, entry.source_mtime),
            padRight(cooked_buf, entry.cooked_path, cooked_col),
            fmt.formatHash(&hash3, entry.cooked_path_hash),
            fmt.formatBytes(&size2, entry.cooked_size),
            fmt.formatTimestamp(&ts2, entry.cooked_at),
            if (entry.asset_kind) |kind| @tagName(kind) else "(none)",
            status,
        });

        total_source_size += entry.source_size;
        total_cooked_size += entry.cooked_size;
    }

    log.info("", .{});
    log.info("Dependency graph:", .{});
    log.info("  {d} source(s), {d} edge(s)", .{
        c.dependency_graph.rows.items.len,
        c.dependency_graph.totalEdgeCount(),
    });

    if (c.dependency_graph.rows.items.len > 0) {
        log.info("  .zcache", .{});
        for (c.dependency_graph.rows.items, 0..) |row, row_idx| {
            const row_is_last = row_idx + 1 == c.dependency_graph.rows.items.len;
            const row_connector = if (row_is_last) "└──" else "├──";
            const child_prefix = if (row_is_last) "    " else "│   ";

            log.info("  {s} {s}", .{ row_connector, row.source_path });

            for (row.dependencies.items, 0..) |dep, dep_idx| {
                const dep_connector = if (dep_idx + 1 == row.dependencies.items.len) "└──" else "├──";
                log.info("  {s}{s} {s}", .{ child_prefix, dep_connector, dep.path });
            }
        }
    }

    log.info("", .{});
    log.info("Summary:", .{});

    var buf1: [16]u8 = undefined;
    var buf2: [16]u8 = undefined;

    log.info("  Header:            {s: >10}", .{fmt.formatBytes(&buf1, cache.HEADER_SIZE)});
    log.info("  Total source size: {s: >10}", .{fmt.formatBytes(&buf2, total_source_size)});

    if (total_cooked_size > 0 and total_source_size > 0) {
        const ratio: f64 = @as(f64, @floatFromInt(total_cooked_size)) / @as(f64, @floatFromInt(total_source_size));
        log.info("  Total cooked size: {s: >10} ({d:.1}x)", .{ fmt.formatBytes(&buf1, total_cooked_size), ratio });
    } else {
        log.info("  Total cooked size: {s: >10}", .{fmt.formatBytes(&buf1, total_cooked_size)});
    }
}

pub fn inspector() FormatInspector {
    return .{ .inspect_fn = inspectZCache };
}

const testing = std.testing;

test "inspector returns a valid FormatInspector" {
    const insp = inspector();
    try testing.expectEqual(@as(*const fn (std.mem.Allocator, wire.Bytes) anyerror!void, inspectZCache), insp.inspect_fn);
}

test "inspector can be called through FormatInspector trait" {
    const insp = inspector();

    var buf: [4096]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZcache(&writer, .{});

    try insp.inspect(testing.allocator, buf[0..writer.end]);
}

test "Cache.read parses a valid zcache" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZcache(&writer, .{});

    var reader = std.Io.Reader.fixed(buf[cache.MAGIC.len..writer.end]);
    var c = try cache.Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(cache.VERSION, c.header.version);
    try testing.expectEqual(@as(u32, 2), c.header.entry_count);
    try testing.expectEqual(@as(usize, 2), c.entries.items.len);
}

test "Cache.read returns StaleVersion for wrong version" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(cache.MAGIC);
    try writer.writeInt(u16, 999, .little);
    try writer.writeAll(&(.{0} ** 50));

    var reader = std.Io.Reader.fixed(buf[cache.MAGIC.len..writer.end]);
    try testing.expectError(error.StaleVersion, cache.Cache.read(testing.allocator, &reader));
}

test "Cache.read accepts zero entries" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(cache.MAGIC);
    try writer.writeInt(u16, cache.VERSION, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeInt(u16, 1, .little); // output_dir_path len
    try writer.writeAll("."); // output_dir_path
    try writer.writeInt(u16, @intCast(cache.currentHostOsName().len), .little); // host_os len
    try writer.writeAll(cache.currentHostOsName()); // host_os
    try writer.writeInt(u32, 0, .little); // dependency_row_count

    var reader = std.Io.Reader.fixed(buf[cache.MAGIC.len..writer.end]);
    var c = try cache.Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), c.header.entry_count);
    try testing.expectEqual(@as(usize, 0), c.entries.items.len);
}

test "Cache.read parses entry fields correctly" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(cache.MAGIC);
    try writer.writeInt(u16, cache.VERSION, .little);
    try writer.writeInt(u32, 1, .little);
    try writer.writeInt(u16, 1, .little); // output_dir_path len
    try writer.writeAll("."); // output_dir_path
    try writer.writeInt(u16, @intCast(cache.currentHostOsName().len), .little); // host_os len
    try writer.writeAll(cache.currentHostOsName()); // host_os

    try writer.writeInt(u64, 0xAABBCCDD, .little);
    try writer.writeInt(u64, 0x11223344, .little);
    try writer.writeInt(u64, 1024, .little);
    try writer.writeInt(i96, 1775606400 * std.time.ns_per_s, .little);
    try writer.writeInt(u64, 0x55667788, .little);
    try writer.writeInt(u64, 512, .little);
    try writer.writeInt(i96, 1775606400 * std.time.ns_per_s, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, @intFromEnum(AssetKind.mesh), .little);
    const source_path = "meshes/triangle.glb";
    try writer.writeInt(u16, source_path.len, .little);
    try writer.writeAll(source_path);
    const cooked_path = "triangle.zmesh";
    try writer.writeInt(u16, cooked_path.len, .little);
    try writer.writeAll(cooked_path);
    try writer.writeInt(u32, 0, .little); // dependency_row_count

    var reader = std.Io.Reader.fixed(buf[cache.MAGIC.len..writer.end]);
    var c = try cache.Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    const entry = c.entries.items[0];
    try testing.expectEqual(@as(u64, 0xAABBCCDD), entry.source_path_hash);
    try testing.expectEqual(@as(u64, 0x11223344), entry.content_hash);
    try testing.expectEqual(@as(u64, 1024), entry.source_size);
    try testing.expectEqual(@as(u64, 0x55667788), entry.cooked_path_hash);
    try testing.expectEqual(@as(u64, 512), entry.cooked_size);
    try testing.expectEqual(AssetKind.mesh, entry.asset_kind);
    try testing.expectEqualStrings("meshes/triangle.glb", entry.source_path);
    try testing.expectEqualStrings("triangle.zmesh", entry.cooked_path);
}

test "inspectZCache runs without error on valid zcache" {
    var buf: [4096]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZcache(&writer, .{});

    try inspectZCache(testing.allocator, buf[0..writer.end]);
}

const TestZcacheOpts = struct {
    entry_count: u32 = 2,
};

fn writeTestZcache(writer: *std.Io.Writer, opts: TestZcacheOpts) !void {
    try writer.writeAll(cache.MAGIC);
    try writer.writeInt(u16, cache.VERSION, .little);
    try writer.writeInt(u32, opts.entry_count, .little);
    try writer.writeInt(u16, 1, .little); // output_dir_path len
    try writer.writeAll("."); // output_dir_path
    try writer.writeInt(u16, @intCast(cache.currentHostOsName().len), .little); // host_os len
    try writer.writeAll(cache.currentHostOsName()); // host_os

    for (0..opts.entry_count) |i| {
        try writer.writeInt(u64, 0x1000 + i, .little); // source_path_hash
        try writer.writeInt(u64, 0x2000 + i, .little); // content_hash
        try writer.writeInt(u64, 4096 * (i + 1), .little); // source_size
        try writer.writeInt(i96, 1775606400 * std.time.ns_per_s, .little); // source_mtime
        try writer.writeInt(u64, 0x3000 + i, .little); // cooked_path_hash
        try writer.writeInt(u64, 2048 * (i + 1), .little); // cooked_size
        try writer.writeInt(i96, 1775606400 * std.time.ns_per_s, .little); // cooked_at
        try writer.writeInt(u16, 0, .little); // flags
        try writer.writeInt(u16, @intFromEnum(AssetKind.mesh), .little); // asset_kind
        const source_path = "meshes/test.glb";
        try writer.writeInt(u16, source_path.len, .little);
        try writer.writeAll(source_path);
        const cooked_path = "test.zmesh";
        try writer.writeInt(u16, cooked_path.len, .little);
        try writer.writeAll(cooked_path);
    }

    try writer.writeInt(u32, 0, .little); // dependency_row_count
}
