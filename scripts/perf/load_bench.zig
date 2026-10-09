//! Measures how fast cooked assets load through `zimp.runtime.loadFromFile`.
//!
//! Usage: zimp-load-bench <cooked_dir>
//!
//! Prints one JSON object per asset kind found under `cooked_dir`. Each pass
//! loads and frees every file of that kind once; the page cache is warmed
//! first, so results measure deserialization rather than disk speed. Meshes
//! with encoded streams (zmesh v7+) are also decoded into a scratch buffer,
//! since that is the cost of getting them ready to upload. Other than that
//! decode (feature-detected with `@hasDecl`), only `loadFromFile`,
//! `detectKind`, and `Asset.deinit` are used, so the same source builds
//! against older zimp revisions for before/after comparisons.

const std = @import("std");
const zimp = @import("zimp");

const runtime = zimp.runtime;
const AssetKind = runtime.AssetKind;

const min_passes = 5;
const max_passes = 2000;
const min_measure_ns = 300 * std.time.ns_per_ms;

const KindFiles = struct {
    paths: std.ArrayList([]const u8) = .empty,
    bytes: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const gpa = std.heap.smp_allocator;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: {s} <cooked_dir>\n", .{args[0]});
        return error.InvalidArguments;
    }

    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);

    var kinds = std.EnumArray(AssetKind, KindFiles).initFill(.{});
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const kind = runtime.detectKind(entry.path) orelse continue;
        const files = kinds.getPtr(kind);
        try files.paths.append(arena, try arena.dupe(u8, entry.path));
        files.bytes += (try dir.statFile(io, entry.path, .{})).size;
    }

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;

    var pass_ns: std.ArrayList(u64) = .empty;
    for (std.enums.values(AssetKind)) |kind| {
        const files = kinds.get(kind);
        if (files.paths.items.len == 0) continue;

        try loadAll(gpa, io, dir, files.paths.items); // warm the page cache

        pass_ns.clearRetainingCapacity();
        var total_ns: u64 = 0;
        while (pass_ns.items.len < min_passes or (total_ns < min_measure_ns and pass_ns.items.len < max_passes)) {
            const start = std.Io.Timestamp.now(io, .awake);
            try loadAll(gpa, io, dir, files.paths.items);
            const elapsed: u64 = @intCast(start.untilNow(io, .awake).toNanoseconds());
            try pass_ns.append(arena, elapsed);
            total_ns += elapsed;
        }
        std.mem.sort(u64, pass_ns.items, {}, std.sort.asc(u64));

        try out.print(
            "{{\"kind\":\"{s}\",\"files\":{d},\"bytes\":{d},\"passes\":{d},\"median_pass_ns\":{d},\"min_pass_ns\":{d}}}\n",
            .{ @tagName(kind), files.paths.items.len, files.bytes, pass_ns.items.len, pass_ns.items[pass_ns.items.len / 2], pass_ns.items[0] },
        );
    }
    try out.flush();
}

fn loadAll(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, paths: []const []const u8) !void {
    for (paths) |path| {
        var asset = try runtime.loadFromFile(gpa, io, dir, path);
        std.mem.doNotOptimizeAway(&asset);
        if (comptime @hasDecl(zimp.ZMesh, "decodeStream")) {
            if (asset.view == .mesh) try decodeMesh(gpa, &asset.view.mesh);
        }
        asset.deinit(gpa);
    }
}

fn decodeMesh(gpa: std.mem.Allocator, model: *const zimp.ZMesh) !void {
    var largest = model.decodedIndexSize();
    for (std.enums.values(zimp.MeshStream)) |stream| {
        if (model.hasStream(stream)) largest = @max(largest, model.decodedStreamSize(stream));
    }
    const scratch = try gpa.alignedAlloc(u8, .@"4", largest);
    defer gpa.free(scratch);
    for (std.enums.values(zimp.MeshStream)) |stream| {
        if (!model.hasStream(stream)) continue;
        try model.decodeStream(stream, scratch[0..model.decodedStreamSize(stream)]);
        std.mem.doNotOptimizeAway(scratch.ptr);
    }
    try model.decodeIndices(scratch[0..model.decodedIndexSize()]);
    std.mem.doNotOptimizeAway(scratch.ptr);
}
