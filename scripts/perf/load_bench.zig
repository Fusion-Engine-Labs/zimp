//! Measures how fast cooked assets load, from loose files and from packs.
//!
//! Usage: zimp-load-bench <cooked_dir> [<pack.zpak>...]
//!
//! Prints one JSON object per (source, asset kind). Each pass loads and frees
//! every asset of that kind once; the page cache is warmed first, so results
//! measure deserialization rather than disk speed. Meshes with encoded
//! streams (zmesh v7+) are also decoded into a scratch buffer, since that is
//! the cost of getting them ready to upload.
//!
//! Loose files go through `runtime.loadFromFile` (source "loose"). Each pack
//! (source = its file stem) goes through `runtime.PackStore.load`, which views
//! raw entries in place and decodes zstd ones. Every pack pass maps the pack
//! afresh, untimed, so page faults count against the loads as they would in
//! a game; the open itself (mmap + table validation) is reported as kind
//! "open". Pack support is feature-detected with `@hasDecl`, and loose loads
//! only use `loadFromFile`, `detectKind`, and `Asset.deinit`, so the same
//! source builds against older zimp revisions for before/after comparisons.

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
    if (args.len < 2) {
        std.debug.print("usage: {s} <cooked_dir> [<pack.zpak>...]\n", .{args[0]});
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
        var timer: Passes = .{ .samples = &pass_ns };
        while (timer.more()) {
            const start = std.Io.Timestamp.now(io, .awake);
            try loadAll(gpa, io, dir, files.paths.items);
            try timer.record(arena, start.untilNow(io, .awake));
        }
        try timer.print(out, "loose", @tagName(kind), files.paths.items.len, files.bytes, files.bytes);
    }

    for (args[2..]) |pack_path| {
        if (comptime @hasDecl(runtime, "PackStore")) {
            try benchPack(gpa, arena, io, out, pack_path, &pass_ns);
        } else {
            return error.PacksUnsupported;
        }
    }
    try out.flush();
}

const Passes = struct {
    samples: *std.ArrayList(u64),
    total_ns: u64 = 0,
    started: bool = false,

    fn more(self: *Passes) bool {
        if (!self.started) {
            self.samples.clearRetainingCapacity();
            self.started = true;
        }
        const n = self.samples.items.len;
        return n < min_passes or (self.total_ns < min_measure_ns and n < max_passes);
    }

    fn record(self: *Passes, arena: std.mem.Allocator, elapsed: std.Io.Duration) !void {
        const ns: u64 = @intCast(elapsed.toNanoseconds());
        try self.samples.append(arena, ns);
        self.total_ns += ns;
    }

    fn print(self: *Passes, out: *std.Io.Writer, source: []const u8, kind: []const u8, files: usize, bytes: u64, stored_bytes: u64) !void {
        const items = self.samples.items;
        std.mem.sort(u64, items, {}, std.sort.asc(u64));
        try out.print(
            "{{\"source\":{f},\"kind\":{f},\"files\":{d},\"bytes\":{d},\"stored_bytes\":{d},\"passes\":{d},\"median_pass_ns\":{d},\"min_pass_ns\":{d}}}\n",
            .{ std.json.fmt(source, .{}), std.json.fmt(kind, .{}), files, bytes, stored_bytes, items.len, items[items.len / 2], items[0] },
        );
    }
};

fn benchPack(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, pack_path: []const u8, pass_ns: *std.ArrayList(u64)) !void {
    const source = std.fs.path.stem(pack_path);
    const cwd = std.Io.Dir.cwd();

    var open_timer: Passes = .{ .samples = pass_ns };
    var file_bytes: u64 = 0;
    var entry_count: usize = 0;
    while (open_timer.more()) {
        const start = std.Io.Timestamp.now(io, .awake);
        var store = try runtime.PackStore.open(io, cwd, pack_path);
        defer store.close(io);
        try open_timer.record(arena, start.untilNow(io, .awake));
        file_bytes = store.pak.bytes.len;
        entry_count = store.pak.count();
    }
    try open_timer.print(out, source, "open", entry_count, file_bytes, file_bytes);

    for (std.enums.values(AssetKind)) |kind| {
        var files: usize = 0;
        var bytes: u64 = 0;
        var stored: u64 = 0;
        {
            var probe = try runtime.PackStore.open(io, cwd, pack_path);
            defer probe.close(io);
            const range = probe.pak.kindRange(kind);
            files = range.end - range.start;
            for (probe.pak.entries[range.start..range.end]) |entry| {
                bytes += entry.size;
                stored += entry.stored_size;
            }
            try loadPackKind(gpa, io, &probe, kind); // warm the page cache
        }
        if (files == 0) continue;

        var timer: Passes = .{ .samples = pass_ns };
        while (timer.more()) {
            var store = try runtime.PackStore.open(io, cwd, pack_path);
            defer store.close(io);
            const start = std.Io.Timestamp.now(io, .awake);
            try loadPackKind(gpa, io, &store, kind);
            try timer.record(arena, start.untilNow(io, .awake));
        }
        try timer.print(out, source, @tagName(kind), files, bytes, stored);
    }
}

/// Loads every entry of `kind` in this mapping of the pack.
fn loadPackKind(gpa: std.mem.Allocator, io: std.Io, store: *runtime.PackStore, kind: AssetKind) !void {
    const range = store.pak.kindRange(kind);
    for (range.start..range.end) |index| {
        var asset = try store.load(gpa, io, @intCast(index));
        defer asset.deinit(gpa);
        std.mem.doNotOptimizeAway(&asset);
        if (asset.view == .mesh) try decodeMesh(gpa, &asset.view.mesh);
    }
}

fn loadAll(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, paths: []const []const u8) !void {
    for (paths) |path| {
        var asset = try runtime.loadFromFile(gpa, io, dir, path);
        defer asset.deinit(gpa);
        std.mem.doNotOptimizeAway(&asset);
        if (comptime @hasDecl(zimp.ZMesh, "decodeStream")) {
            if (asset.view == .mesh) try decodeMesh(gpa, &asset.view.mesh);
        }
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
