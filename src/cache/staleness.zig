const std = @import("std");
const builtin = @import("builtin");
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const Hash = @import("../assets/source_file.zig").Hash;
const CacheEntry = @import("entry.zig").CacheEntry;

pub const Staleness = enum {
    cached,
    hash_match,
    stale_size,
    stale_content,
    stale_host_os,
    stale_project_id,
    errored,
    not_cached,

    pub const Result = struct {
        verdict: Staleness,
        content_hash: ?Hash = null,
    };

    /// Compare an already captured stat snapshot.  Callers provide a hash only
    /// for the size-equal / mtime-changed path, avoiding a second open/stat.
    pub fn check(
        cache_entry: *const CacheEntry,
        source_file_info: SourceFile.FileInfo,
        source_content_hash: ?Hash,
        cached_host_os: []const u8,
        project_id_changed: bool,
    ) Result {
        if (cache_entry.isErrored()) {
            return .{ .verdict = .errored };
        }

        if (cache_entry.asset_kind != null and cache_entry.asset_kind.?.rebuildsOnHostOsChange() and !std.mem.eql(u8, cached_host_os, @tagName(builtin.os.tag))) {
            return .{ .verdict = .stale_host_os };
        }

        if (project_id_changed and cache_entry.asset_kind != null and cache_entry.asset_kind.?.embedsAssetIds()) {
            return .{ .verdict = .stale_project_id };
        }

        if (cache_entry.source_mtime == source_file_info.modified_ns) {
            return .{ .verdict = .cached };
        }

        if (cache_entry.source_size != source_file_info.size) {
            return .{ .verdict = .stale_size };
        }

        const content_hash = source_content_hash orelse {
            // Equal-size mtime changes must be supplied with their one retained
            // payload hash by the source-analysis owner.
            return .{ .verdict = .stale_content };
        };
        if (cache_entry.content_hash != content_hash) {
            return .{ .verdict = .stale_content, .content_hash = content_hash };
        }

        return .{ .verdict = .hash_match, .content_hash = content_hash };
    }
};

const testing = std.testing;

fn createTestFile(tmp: std.testing.TmpDir, name: []const u8, content: []const u8) !void {
    const file = try tmp.dir.createFile(testing.io, name, .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    file.close(testing.io);
}

fn makeSourceFile(path: []const u8) SourceFile {
    return .{ .path = path, .extension = .glb };
}

fn makeCacheEntryFromFile(tmp: std.testing.TmpDir, sf: *const SourceFile) !CacheEntry {
    const info = try sf.getFileInfo(tmp.dir, testing.io);
    const content_hash = try sf.hash(tmp.dir, testing.io);
    return .{
        .source_path = sf.path,
        .source_path_hash = sf.hashPath(),
        .content_hash = content_hash,
        .source_size = info.size,
        .source_mtime = info.modified_ns,
        .cooked_path = "out.zmesh",
        .cooked_path_hash = 0,
        .cooked_size = 0,
        .cooked_at = 0,
        .asset_kind = .mesh,
    };
}

fn currentHostOsName() []const u8 {
    return @tagName(builtin.os.tag);
}

test "check returns cached when mtime matches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.glb", "hello");
    const sf = makeSourceFile("a.glb");
    const entry = try makeCacheEntryFromFile(tmp, &sf);

    const result = Staleness.check(&entry, try sf.getFileInfo(tmp.dir, testing.io), null, currentHostOsName(), false);
    try testing.expectEqual(Staleness.cached, result.verdict);
}

test "check returns stale_size when size differs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.glb", "hello");
    const sf = makeSourceFile("a.glb");
    var entry = try makeCacheEntryFromFile(tmp, &sf);
    entry.source_mtime = 0;
    entry.source_size = 999;

    const result = Staleness.check(&entry, try sf.getFileInfo(tmp.dir, testing.io), null, currentHostOsName(), false);
    try testing.expectEqual(Staleness.stale_size, result.verdict);
}

test "check returns stale_content when size matches but hash differs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.glb", "hello");
    const sf = makeSourceFile("a.glb");
    var entry = try makeCacheEntryFromFile(tmp, &sf);
    entry.source_mtime = 0;
    entry.content_hash = 0xDEAD;

    const result = Staleness.check(&entry, try sf.getFileInfo(tmp.dir, testing.io), try sf.hash(tmp.dir, testing.io), currentHostOsName(), false);
    try testing.expectEqual(Staleness.stale_content, result.verdict);
}

test "check returns hash_match when size and hash match but mtime differs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.glb", "hello");
    const sf = makeSourceFile("a.glb");
    var entry = try makeCacheEntryFromFile(tmp, &sf);
    entry.source_mtime = 0;

    const result = Staleness.check(&entry, try sf.getFileInfo(tmp.dir, testing.io), try sf.hash(tmp.dir, testing.io), currentHostOsName(), false);
    try testing.expectEqual(Staleness.hash_match, result.verdict);
}

test "check returns stale_host_os for OS-sensitive cached asset from different host OS" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.zamat", "hello");
    const sf = SourceFile{ .path = "a.zamat", .extension = .zamat };
    var entry = try makeCacheEntryFromFile(tmp, &sf);
    entry.asset_kind = .material;

    const result = Staleness.check(&entry, try sf.getFileInfo(tmp.dir, testing.io), null, "not-current-os", false);
    try testing.expectEqual(Staleness.stale_host_os, result.verdict);
}

test "check ignores host OS changes for portable cached asset types" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.glb", "hello");
    const sf = makeSourceFile("a.glb");
    const entry = try makeCacheEntryFromFile(tmp, &sf);

    const result = Staleness.check(&entry, try sf.getFileInfo(tmp.dir, testing.io), null, "not-current-os", false);
    try testing.expectEqual(Staleness.cached, result.verdict);
}

test "check returns stale_project_id for id-embedding assets when the project id changed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.glb", "hello");
    const sf = makeSourceFile("a.glb");
    var entry = try makeCacheEntryFromFile(tmp, &sf);
    entry.asset_kind = .mesh;
    const info = try sf.getFileInfo(tmp.dir, testing.io);

    try testing.expectEqual(Staleness.stale_project_id, Staleness.check(&entry, info, null, currentHostOsName(), true).verdict);
    try testing.expectEqual(Staleness.cached, Staleness.check(&entry, info, null, currentHostOsName(), false).verdict);
    entry.asset_kind = .texture;
    try testing.expectEqual(Staleness.cached, Staleness.check(&entry, info, null, currentHostOsName(), true).verdict);
}
