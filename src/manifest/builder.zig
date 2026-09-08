const std = @import("std");

const CacheEntry = @import("../cache/entry.zig").CacheEntry;
const ProjectId = @import("../id/id_types.zig").ProjectId;
const AssetId = @import("../id/id_types.zig").AssetId;
const Cache = @import("../cache/cache.zig").Cache;
const log = @import("../logger.zig");
const derive = @import("derive.zig");
const kind_mod = @import("../assets/asset.zig");
const model = @import("model.zig");

pub const generated_prefix = "generated/";

pub const BuildInputs = struct {
    project_id: ProjectId,
    cache: *const Cache,
    builtin_entries: []const model.AssetManifestEntry = &.{},
};

pub const BuildStats = struct {
    entries: usize = 0,
    builtin_entries: usize = 0,
    skipped_errored: usize = 0,
    skipped_dependency_only: usize = 0,
    skipped_unknown_kind: usize = 0,
};

pub fn build(gpa: std.mem.Allocator, inputs: BuildInputs, stats: *BuildStats) !model.AssetManifest {
    var m = model.AssetManifest{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .project_id = inputs.project_id,
        .entries = &.{},
    };
    errdefer m.deinit();
    const a = m.arena.allocator();

    var entries: std.ArrayList(model.AssetManifestEntry) =
        try .initCapacity(a, inputs.cache.entries.items.len + inputs.builtin_entries.len);

    for (inputs.cache.entries.items) |*cache_entry| {
        if (cache_entry.isErrored()) {
            stats.skipped_errored += 1;
            continue;
        }

        if (!cache_entry.hasCookedOutput()) {
            stats.skipped_dependency_only += 1;
            continue;
        }

        const kind = cache_entry.asset_kind orelse {
            stats.skipped_unknown_kind += 1; // dependency-only files
            continue;
        };

        try entries.append(a, .{
            .id = derive.assetIdForPath(inputs.project_id, cache_entry.source_path),
            .kind = kind,
            .source_path = try a.dupe(u8, cache_entry.source_path),
            .cooked_path = try a.dupe(u8, cache_entry.cooked_path),
            .content_hash = cache_entry.content_hash,
            .source_size = cache_entry.source_size,
            .cooked_size = cache_entry.cooked_size,
            .generated = std.mem.startsWith(u8, cache_entry.source_path, generated_prefix),
        });
    }

    for (inputs.builtin_entries) |entry| {
        try entries.append(a, try entry.clone(a));
        stats.builtin_entries += 1;
    }

    // Determinism: sort by source_path.
    std.mem.sort(model.AssetManifestEntry, entries.items, {}, entryLessThan);
    m.entries = try entries.toOwnedSlice(a);

    try m.validate();
    stats.entries = m.entries.len;
    return m;
}

fn entryLessThan(_: void, lhs: model.AssetManifestEntry, rhs: model.AssetManifestEntry) bool {
    return std.mem.order(u8, lhs.source_path, rhs.source_path) == .lt;
}

const testing = std.testing;
const codec = @import("codec.zig");

const TestFixture = struct {
    tmp: std.testing.TmpDir,
    cache: Cache,

    fn init() !TestFixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        return .{
            .tmp = tmp,
            .cache = try Cache.init(
                testing.allocator,
                tmp.dir,
                "cooked",
            ),
        };
    }

    fn deinit(self: *TestFixture) void {
        self.cache.deinit(testing.allocator);
        self.tmp.cleanup();
    }

    fn addCacheEntry(self: *TestFixture, source_path: []const u8, cooked_path: []const u8, asset_kind: ?kind_mod.AssetKind, flags: u16) !void {
        const fnv1a = @import("../assets/source_file.zig").fnv1a;
        try self.cache.pushCacheEntry(testing.allocator, .{
            .source_path = try testing.allocator.dupe(u8, source_path),
            .source_path_hash = fnv1a(source_path),
            .content_hash = fnv1a(source_path) ^ 0x1234,
            .source_size = 100,
            .source_mtime = 0,
            .cooked_path = try testing.allocator.dupe(u8, cooked_path),
            .cooked_path_hash = fnv1a(cooked_path),
            .cooked_size = 50,
            .cooked_at = 0,
            .flags = flags,
            .asset_kind = asset_kind,
        });
    }

    fn inputs(self: *TestFixture) BuildInputs {
        return .{
            .project_id = model.test_project_id,
            .cache = &self.cache,
        };
    }
};

test "build over an empty cache yields an empty valid manifest" {
    var fx = try TestFixture.init();
    defer fx.deinit();

    var stats = BuildStats{};
    var m = try build(testing.allocator, fx.inputs(), &stats);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.entries.len);
    try testing.expectEqual(@as(usize, 0), stats.entries);
}

test "builtin entries are cloned, sorted, with project entries" {
    var fx = try TestFixture.init();
    defer fx.deinit();

    try fx.tmp.dir.createDirPath(testing.io, "meshes");
    try fx.addCacheEntry("meshes/monkey.glb", "meshes/monkey.zmesh", .mesh, 0);

    const builtin_id = AssetId.parseComptime("3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01");
    const builtin_entries = [_]model.AssetManifestEntry{.{
        .id = builtin_id,
        .kind = .shader_stage,
        .source_path = "fusion/standard.vert",
        .cooked_path = "fusion/standard.vert.zshdr",
        .content_hash = 123,
        .source_size = 456,
        .cooked_size = 789,
    }};

    var inputs = fx.inputs();
    inputs.builtin_entries = &builtin_entries;
    var stats = BuildStats{};
    var m = try build(testing.allocator, inputs, &stats);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 2), m.entries.len);
    try testing.expectEqual(@as(usize, 1), stats.builtin_entries);
    const entry = m.findBySourcePath("fusion/standard.vert").?;
    try testing.expect(entry.id.eql(builtin_id));
    try testing.expectEqual(@as(u64, 123), entry.content_hash);
}

test "project assets get derived ids and non-assets are skipped" {
    var fx = try TestFixture.init();
    defer fx.deinit();

    try fx.addCacheEntry(
        "meshes/monkey.glb",
        "meshes/monkey.zmesh",
        .mesh,
        0,
    );
    try fx.addCacheEntry(
        "tex/broken.png",
        "tex/broken.ztex",
        .texture,
        @import("../cache/entry.zig").FLAG_ERRORED,
    );
    try fx.addCacheEntry(
        "includes/common.glsl",
        "",
        null,
        0,
    );
    try fx.addCacheEntry(
        "data/unknown.bin",
        "data/unknown.bin",
        null,
        0,
    );

    var stats = BuildStats{};
    var manifest = try build(
        testing.allocator,
        fx.inputs(),
        &stats,
    );
    defer manifest.deinit();

    try testing.expectEqual(
        @as(usize, 1),
        manifest.entries.len,
    );
    try testing.expectEqual(
        @as(usize, 1),
        stats.skipped_errored,
    );
    try testing.expectEqual(
        @as(usize, 1),
        stats.skipped_dependency_only,
    );
    try testing.expectEqual(
        @as(usize, 1),
        stats.skipped_unknown_kind,
    );

    const entry = manifest.findBySourcePath(
        "meshes/monkey.glb",
    ).?;
    const expected = derive.assetIdForPath(
        model.test_project_id,
        "meshes/monkey.glb",
    );

    try testing.expect(entry.id.eql(expected));
    try testing.expect(!entry.generated);
}

test "generated assets use the same project path identity rule" {
    var fx = try TestFixture.init();
    defer fx.deinit();

    try fx.addCacheEntry(
        "generated/materials/m.zamat",
        "generated/materials/m.zamat",
        .material,
        0,
    );

    var stats = BuildStats{};
    var manifest = try build(
        testing.allocator,
        fx.inputs(),
        &stats,
    );
    defer manifest.deinit();

    const expected = derive.assetIdForPath(
        model.test_project_id,
        "generated/materials/m.zamat",
    );

    try testing.expect(manifest.entries[0].id.eql(expected));
    try testing.expect(manifest.entries[0].generated);
}

test "builtin collision with a project id is rejected" {
    var fx = try TestFixture.init();
    defer fx.deinit();

    try fx.addCacheEntry("a.glb", "a.zmesh", .mesh, 0);

    const collision_id = derive.assetIdForPath(
        model.test_project_id,
        "a.glb",
    );
    const builtins = [_]model.AssetManifestEntry{.{
        .id = collision_id,
        .kind = .shader_stage,
        .source_path = "fusion/collision.vert",
        .cooked_path = "fusion/collision.vert.zshdr",
        .content_hash = 0,
        .source_size = 0,
        .cooked_size = 0,
    }};

    var inputs = fx.inputs();
    inputs.builtin_entries = &builtins;

    var stats = BuildStats{};
    try testing.expectError(
        error.DuplicateAssetId,
        build(testing.allocator, inputs, &stats),
    );
}

test "rebuild from identical inputs is byte-identical" {
    var fx = try TestFixture.init();
    defer fx.deinit();

    try fx.addCacheEntry(
        "meshes/monkey.glb",
        "meshes/monkey.zmesh",
        .mesh,
        0,
    );
    try fx.addCacheEntry(
        "generated/materials/m.zamat",
        "generated/materials/m.zamat",
        .material,
        0,
    );

    var stats1 = BuildStats{};
    var first = try build(
        testing.allocator,
        fx.inputs(),
        &stats1,
    );
    defer first.deinit();

    const bytes1 = try codec.encodeAlloc(
        testing.allocator,
        &first,
    );
    defer testing.allocator.free(bytes1);

    var stats2 = BuildStats{};
    var second = try build(
        testing.allocator,
        fx.inputs(),
        &stats2,
    );
    defer second.deinit();

    const bytes2 = try codec.encodeAlloc(
        testing.allocator,
        &second,
    );
    defer testing.allocator.free(bytes2);

    try testing.expectEqualStrings(bytes1, bytes2);
}
