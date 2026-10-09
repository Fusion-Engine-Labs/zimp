const std = @import("std");

const runtime = @import("../runtime.zig");
const zpak = @import("../formats/zpak.zig");
const LooseStore = @import("loose_store.zig").LooseStore;
const PackStore = @import("pack_store.zig").PackStore;
const ProjectManifest = @import("../project/manifest.zig").ProjectManifest;
const AssetKind = @import("../assets/asset.zig").AssetKind;
const AssetId = @import("../id/id_types.zig").AssetId;

/// A build's cooked assets, looked up and loaded by `AssetId`, from either a
/// loose cooked directory (editor and dev) or a `.zpak` (shipping). Both
/// sources index entries the same way: sorted by (kind, id), so `Index`
/// values of one kind form a contiguous range.
///
///     var store = try AssetStore.openProject(gpa, io, root_dir, &project, .pack);
///     defer store.deinit(io);
///     const index = store.findKind(.texture, id) orelse return error.AssetNotFound;
///     var asset = try store.load(gpa, io, index);
///     defer asset.deinit(gpa);
///
/// `load` is safe to call from several threads at once. Loaded assets may
/// borrow the store's memory, so free them before `deinit`.
pub const AssetStore = union(Source) {
    loose: LooseStore,
    pack: PackStore,

    pub const Source = enum { loose, pack };
    pub const Index = u32;
    pub const Range = zpak.Range;

    /// Opens the project's cooked directory through its `asset_manifest`
    /// (`.loose`), or its `asset_pack` (`.pack`).
    pub fn openProject(
        gpa: std.mem.Allocator,
        io: std.Io,
        root_dir: std.Io.Dir,
        project: *const ProjectManifest,
        source: Source,
    ) !AssetStore {
        return switch (source) {
            .loose => .{ .loose = try LooseStore.open(gpa, io, root_dir, project.asset_manifest, project.cooked_assets_dir) },
            .pack => .{ .pack = try PackStore.open(io, root_dir, project.asset_pack) },
        };
    }

    pub fn deinit(self: *AssetStore, io: std.Io) void {
        switch (self.*) {
            .loose => |*store| store.deinit(io),
            .pack => |*store| store.close(io),
        }
        self.* = undefined;
    }

    pub fn count(self: *const AssetStore) Index {
        return switch (self.*) {
            .loose => |*store| store.count(),
            .pack => |*store| store.pak.count(),
        };
    }

    /// Every entry of `kind`, sorted by id.
    pub fn kindRange(self: *const AssetStore, kind: AssetKind) Range {
        return switch (self.*) {
            .loose => |*store| store.kindRange(kind),
            .pack => |*store| store.pak.kindRange(kind),
        };
    }

    pub fn findKind(self: *const AssetStore, kind: AssetKind, id: AssetId) ?Index {
        return switch (self.*) {
            .loose => |*store| store.findKind(kind, id),
            .pack => |*store| store.pak.findKind(kind, id),
        };
    }

    pub fn find(self: *const AssetStore, id: AssetId) ?Index {
        return switch (self.*) {
            .loose => |*store| store.find(id),
            .pack => |*store| store.pak.find(id),
        };
    }

    pub fn idAt(self: *const AssetStore, index: Index) AssetId {
        return switch (self.*) {
            .loose => |*store| store.entries[index].id,
            .pack => |*store| store.pak.idAt(index),
        };
    }

    pub fn kindAt(self: *const AssetStore, index: Index) AssetKind {
        return switch (self.*) {
            .loose => |*store| store.entries[index].kind,
            .pack => |*store| store.pak.kindAt(index),
        };
    }

    /// The asset's cooked path, for display and diagnostics.
    pub fn nameAt(self: *const AssetStore, index: Index) []const u8 {
        return switch (self.*) {
            .loose => |*store| store.entries[index].path,
            .pack => |*store| store.pak.nameAt(index),
        };
    }

    pub fn load(self: *AssetStore, gpa: std.mem.Allocator, io: std.Io, index: Index) !runtime.Asset {
        return switch (self.*) {
            .loose => |*store| store.load(gpa, io, index),
            .pack => |*store| store.load(gpa, io, index),
        };
    }
};

const testing = std.testing;
const pack_store = @import("pack_store.zig");
const loose_store = @import("loose_store.zig");

test "openProject opens the loose directory or the pack the manifest names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project: ProjectManifest = .{
        .project_id = .parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
        .asset_pack = "build/game.zpak",
    };

    try testing.expectError(error.FileNotFound, AssetStore.openProject(testing.allocator, testing.io, tmp.dir, &project, .loose));
    try testing.expectError(error.FileNotFound, AssetStore.openProject(testing.allocator, testing.io, tmp.dir, &project, .pack));

    try tmp.dir.createDirPath(testing.io, ".fusion/cooked");
    try loose_store.writeTestManifest(tmp.dir, project.asset_manifest);
    var loose = try AssetStore.openProject(testing.allocator, testing.io, tmp.dir, &project, .loose);
    defer loose.deinit(testing.io);
    try testing.expectEqual(AssetStore.Source.loose, std.meta.activeTag(loose));
    try testing.expectEqual(@as(u32, 2), loose.count());

    var mesh_buf: [4096]u8 = undefined;
    try tmp.dir.createDirPath(testing.io, "build");
    try pack_store.writeTestPack(tmp.dir, project.asset_pack, &.{
        .{ .id = pack_store.test_mesh_id, .kind = .mesh, .name = "meshes/test.zmesh", .bytes = try pack_store.testMeshBytes(&mesh_buf) },
    });
    var pack = try AssetStore.openProject(testing.allocator, testing.io, tmp.dir, &project, .pack);
    defer pack.deinit(testing.io);

    const index = pack.findKind(.mesh, pack_store.test_mesh_id).?;
    try testing.expectEqual(index, pack.find(pack_store.test_mesh_id).?);
    try testing.expectEqual(AssetKind.mesh, pack.kindAt(index));
    try testing.expect(pack.idAt(index).eql(pack_store.test_mesh_id));
    try testing.expectEqualStrings("meshes/test.zmesh", pack.nameAt(index));
    try testing.expectEqual(AssetStore.Range{ .start = 0, .end = 1 }, pack.kindRange(.mesh));
    try testing.expect(pack.findKind(.texture, pack_store.test_mesh_id) == null);

    var asset = try pack.load(testing.allocator, testing.io, index);
    defer asset.deinit(testing.allocator);
    try testing.expect(asset.view == .mesh);
}
