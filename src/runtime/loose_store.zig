const std = @import("std");

const runtime = @import("../runtime.zig");
const zpak = @import("../formats/zpak.zig");
const file_read = @import("../shared/file_read.zig");
const path = @import("../path.zig");
const manifest_model = @import("../manifest/model.zig");
const manifest_codec = @import("../manifest/codec.zig");
const AssetKind = @import("../assets/asset.zig").AssetKind;
const AssetId = @import("../id/id_types.zig").AssetId;

/// Loose cooked files indexed by `assets.zmanifest`: the editor and dev
/// path. Each load reads one file into a heap buffer. Entries are sorted by
/// (kind, id) like a pack's, so both stores index the same way.
pub const LooseStore = struct {
    arena: std.heap.ArenaAllocator,
    /// The cooked directory. Owned.
    dir: std.Io.Dir,
    entries: []const Entry,
    kind_start: [zpak.kind_count + 1]u32,

    pub const Entry = struct {
        id: AssetId,
        kind: AssetKind,
        /// Normalized cooked path, relative to `dir`.
        path: []const u8,
    };

    /// Loads the manifest at `root_dir/manifest_path` and opens `root_dir/cooked_dir`.
    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        root_dir: std.Io.Dir,
        manifest_path: []const u8,
        cooked_dir: []const u8,
    ) !LooseStore {
        var manifest = try manifest_codec.loadFromDir(gpa, io, root_dir, manifest_path);
        defer manifest.deinit();
        try path.validateVirtual(cooked_dir);
        const dir = try root_dir.openDir(io, cooked_dir, .{});
        errdefer dir.close(io);
        return init(gpa, dir, &manifest);
    }

    /// Indexes `manifest` over the cooked directory `dir`, taking ownership
    /// of `dir` on success.
    pub fn init(gpa: std.mem.Allocator, dir: std.Io.Dir, manifest: *const manifest_model.AssetManifest) !LooseStore {
        try manifest.validate();
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const entries = try a.alloc(Entry, manifest.entries.len);
        for (manifest.entries, entries) |src, *entry| {
            entry.* = .{ .id = src.id, .kind = src.kind, .path = try path.normalizeVirtual(a, src.cooked_path) };
        }
        std.mem.sort(Entry, entries, {}, entryLessThan);

        var kind_start: [zpak.kind_count + 1]u32 = undefined;
        var next_kind: usize = 0;
        for (entries, 0..) |entry, i| {
            while (next_kind <= @intFromEnum(entry.kind)) : (next_kind += 1) kind_start[next_kind] = @intCast(i);
        }
        while (next_kind <= zpak.kind_count) : (next_kind += 1) kind_start[next_kind] = @intCast(entries.len);

        return .{ .arena = arena, .dir = dir, .entries = entries, .kind_start = kind_start };
    }

    pub fn deinit(self: *LooseStore, io: std.Io) void {
        self.dir.close(io);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const LooseStore) u32 {
        return @intCast(self.entries.len);
    }

    pub fn kindRange(self: *const LooseStore, kind: AssetKind) zpak.Range {
        const k = @intFromEnum(kind);
        return .{ .start = self.kind_start[k], .end = self.kind_start[k + 1] };
    }

    pub fn findKind(self: *const LooseStore, kind: AssetKind, id: AssetId) ?u32 {
        const range = self.kindRange(kind);
        var lo = range.start;
        var hi = range.end;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, &self.entries[mid].id.uuid.bytes, &id.uuid.bytes)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    pub fn find(self: *const LooseStore, id: AssetId) ?u32 {
        for (std.enums.values(AssetKind)) |kind| {
            if (self.findKind(kind, id)) |index| return index;
        }
        return null;
    }

    /// Reads entry `index` into an owned buffer and validates it.
    pub fn load(self: *const LooseStore, gpa: std.mem.Allocator, io: std.Io, index: u32) !runtime.Asset {
        const entry = &self.entries[index];
        return .fromOwned(gpa, try file_read.readFileAligned(gpa, io, self.dir, entry.path), entry.kind);
    }

    fn entryLessThan(_: void, a: Entry, b: Entry) bool {
        if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
        return std.mem.order(u8, &a.id.uuid.bytes, &b.id.uuid.bytes) == .lt;
    }
};

const testing = std.testing;
const zmesh = @import("../formats/zmesh.zig");

const mesh_id = "3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01";
const texture_id = "8c1d6602-b3f4-4910-9c44-4b7e9b1a2f6c";

pub fn writeTestManifest(dir: std.Io.Dir, manifest_path: []const u8) !void {
    var manifest = try manifest_model.testManifest(testing.allocator, &.{
        .{ .id = mesh_id, .source_path = "meshes/monkey.glb", .cooked_path = "meshes/monkey.zmesh" },
        .{ .id = texture_id, .kind = .texture, .source_path = "tex/brick.png", .cooked_path = "tex\\brick.ztex" },
    });
    defer manifest.deinit();
    try manifest_codec.writeToDir(testing.allocator, testing.io, dir, manifest_path, &manifest);
}

test "LooseStore indexes the manifest by kind and id and loads cooked files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".fusion/cooked/meshes");
    try writeTestManifest(tmp.dir, ".fusion/assets.zmanifest");
    {
        const file = try tmp.dir.createFile(testing.io, ".fusion/cooked/meshes/monkey.zmesh", .{});
        defer file.close(testing.io);
        var buf: [4096]u8 = undefined;
        var writer = file.writer(testing.io, &buf);
        try zmesh.writeTestZmeshFile(&writer.interface);
        try writer.interface.flush();
    }

    var store = try LooseStore.open(testing.allocator, testing.io, tmp.dir, ".fusion/assets.zmanifest", ".fusion/cooked");
    defer store.deinit(testing.io);

    try testing.expectEqual(@as(u32, 2), store.count());
    const mesh = store.findKind(.mesh, try AssetId.parse(mesh_id)).?;
    try testing.expectEqual(zpak.Range{ .start = 0, .end = 1 }, store.kindRange(.mesh));
    try testing.expectEqualStrings("meshes/monkey.zmesh", store.entries[mesh].path);
    try testing.expect(store.findKind(.texture, try AssetId.parse(mesh_id)) == null);
    // Paths are normalized.
    try testing.expectEqualStrings("tex/brick.ztex", store.entries[store.find(try AssetId.parse(texture_id)).?].path);

    var asset = try store.load(testing.allocator, testing.io, mesh);
    defer asset.deinit(testing.allocator);
    try testing.expect(asset.view == .mesh);
    try testing.expect(asset.owned != null);

    const texture = store.find(try AssetId.parse(texture_id)).?;
    try testing.expectError(error.FileNotFound, store.load(testing.allocator, testing.io, texture));
}

test "LooseStore.open propagates missing manifests and directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.FileNotFound, LooseStore.open(testing.allocator, testing.io, tmp.dir, "assets.zmanifest", "cooked"));
    try writeTestManifest(tmp.dir, "assets.zmanifest");
    try testing.expectError(error.FileNotFound, LooseStore.open(testing.allocator, testing.io, tmp.dir, "assets.zmanifest", "cooked"));
    try testing.expectError(error.ParentTraversalNotAllowed, LooseStore.open(testing.allocator, testing.io, tmp.dir, "assets.zmanifest", "../cooked"));
}
