const std = @import("std");
const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const zpak = @import("../formats/zpak.zig");
const PackStore = @import("../runtime.zig").PackStore;
const AssetKind = @import("../assets/asset.zig").AssetKind;

/// Prints a pack's table of contents, then loads every entry (decoding zstd
/// payloads and validating each asset), so inspecting a pack also checks it.
/// Packs can be far larger than any one asset, so this works on a mapping
/// rather than the read-everything buffer other inspectors get.
pub fn inspect(gpa: std.mem.Allocator, io: std.Io, store: *PackStore) !void {
    const pak = &store.pak;
    log.info("zpak v{d}", .{zpak.ZPAK_VERSION});
    var size_buf: [16]u8 = undefined;
    log.info("  Entries:    {d}", .{pak.count()});
    log.info("  Chunks:     {d}", .{pak.chunk_ends.len});
    log.info("  File size:  {s}", .{fmt.formatBytes(&size_buf, pak.bytes.len)});

    log.info("", .{});
    log.info("By kind:", .{});
    log.info("  {s: <13}  {s: >7}  {s: >5}  {s: >10}  {s: >10}  {s: >6}", .{ "kind", "assets", "zstd", "size", "stored", "ratio" });
    log.info("  {s}", .{"-" ** 60});
    for (std.enums.values(AssetKind)) |kind| {
        const range = pak.kindRange(kind);
        if (range.start == range.end) continue;
        var compressed: u32 = 0;
        var size: u64 = 0;
        var stored: u64 = 0;
        for (pak.entries[range.start..range.end]) |entry| {
            if (entry.codec == @intFromEnum(zpak.Codec.zstd)) compressed += 1;
            size += entry.size;
            stored += entry.stored_size;
        }
        var a: [16]u8 = undefined;
        var b: [16]u8 = undefined;
        log.info("  {s: <13}  {d: >7}  {d: >5}  {s: >10}  {s: >10}  {d: >5.1}%", .{
            @tagName(kind), range.end - range.start, compressed, fmt.formatBytes(&a, size), fmt.formatBytes(&b, stored), percent(stored, size),
        });
    }

    log.info("", .{});
    log.info("Entries:", .{});
    log.info("  {s: <13}  {s: <5}  {s: >10}  {s: >10}  {s: >6}  {s}", .{ "kind", "codec", "size", "stored", "ratio", "name" });
    log.info("  {s}", .{"-" ** 60});
    for (0..pak.count()) |i| {
        const index: u32 = @intCast(i);
        const entry = pak.entries[index];
        var a: [16]u8 = undefined;
        var b: [16]u8 = undefined;
        log.info("  {s: <13}  {s: <5}  {s: >10}  {s: >10}  {d: >5.1}%  {s}", .{
            @tagName(pak.kindAt(index)),            @tagName(pak.codecAt(index)),
            fmt.formatBytes(&a, entry.size),        fmt.formatBytes(&b, entry.stored_size),
            percent(entry.stored_size, entry.size), pak.nameAt(index),
        });
    }

    var failures: usize = 0;
    for (0..pak.count()) |i| {
        const index: u32 = @intCast(i);
        var asset = store.load(gpa, io, index) catch |err| {
            failures += 1;
            log.err("  {s} ({f}): {s}", .{ pak.nameAt(index), pak.idAt(index), @errorName(err) });
            continue;
        };
        asset.deinit(gpa);
    }
    log.info("", .{});
    if (failures > 0) {
        log.err("{d} of {d} entries failed to load", .{ failures, pak.count() });
        return error.InvalidPackEntry;
    }
    log.info("All {d} entries load and validate.", .{pak.count()});
}

fn percent(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole));
}

const testing = std.testing;
const pack_store = @import("../runtime/pack_store.zig");

test "inspect prints a pack and loads every entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var mesh_buf: [4096]u8 = undefined;
    const shader = try pack_store.testShaderBytes(zpak.chunk_size + 10);
    defer testing.allocator.free(shader);
    try pack_store.writeTestPack(tmp.dir, "a.zpak", &.{
        .{ .id = pack_store.test_mesh_id, .kind = .mesh, .name = "m.zmesh", .bytes = try pack_store.testMeshBytes(&mesh_buf) },
        .{ .id = pack_store.test_shader_id, .kind = .shader_stage, .name = "s.zshdr", .bytes = shader, .compress = true },
    });
    var store = try PackStore.open(testing.io, tmp.dir, "a.zpak");
    defer store.close(testing.io);
    try inspect(testing.allocator, testing.io, &store);
}
