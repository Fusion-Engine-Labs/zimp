const std = @import("std");
const builtin = @import("builtin");

const source_file_mod = @import("../assets/source_file.zig");
const AssetKind = @import("../assets/asset.zig").AssetKind;
const CacheEntry = @import("entry.zig").CacheEntry;
const dep_graph_mod = @import("cache_dep_graph.zig");
const CacheDepGraph = dep_graph_mod.CacheDepGraph;
const DependencyRef = dep_graph_mod.DependencyRef;
const DependencyRow = dep_graph_mod.DependencyRow;
const sourceExists = dep_graph_mod.sourceExists;
const fnv1a = source_file_mod.fnv1a;
const Hash = source_file_mod.Hash;
const SourceFile = source_file_mod.SourceFile;
const log = @import("../logger.zig");
const AtomicFile = @import("../shared/atomic_file.zig").AtomicFile;
const wire = @import("../shared/wire.zig");
const constants = @import("../shared/constants.zig");
const ProjectId = @import("../id/id_types.zig").ProjectId;

pub const VERSION = 8;
pub const MAGIC = constants.FORMAT_MAGIC.ZACHE;

pub const HEADER_SIZE: u32 = MAGIC.len + @sizeOf(u16) + @sizeOf(u32) + @sizeOf(u16) + @sizeOf(u16) + 16; // magic + version + entry_count + output_dir_len + host_os_len + project_id

pub const CacheHeader = struct {
    version: u16 = VERSION,
    entry_count: u32,
};

/// source_path -> entry index. Keyed on the path itself rather than its hash so
/// a lookup is exact: there is no collision case to fall back on, and a miss
/// costs one probe instead of a scan of every entry. The map borrows each key
/// from the entry that owns it, so any code that frees an entry's `source_path`
/// must re-key or rebuild the map first.
const EntryMap = std.StringHashMap(u32);

pub fn currentHostOsName() []const u8 {
    return @tagName(builtin.os.tag);
}

pub const Cache = struct {
    header: CacheHeader,
    entries: std.ArrayList(CacheEntry),
    entry_map: EntryMap,
    dependency_graph: CacheDepGraph,
    source_dir: std.Io.Dir,
    output_dir_path: []const u8 = "",
    host_os: []const u8 = "",
    /// Namespace of the `AssetId`s embedded in cooked meshes and materials.
    project_id: ProjectId = .zero,
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator, source_dir: std.Io.Dir, output_dir_path: []const u8) !Cache {
        const owned_output_dir_path = try allocator.dupe(u8, output_dir_path);
        errdefer allocator.free(owned_output_dir_path);

        return .{
            .header = .{
                .entry_count = 0,
            },
            .entry_map = .init(allocator),
            .dependency_graph = CacheDepGraph.init(allocator),
            .entries = .empty,
            .source_dir = source_dir,
            .output_dir_path = owned_output_dir_path,
            .host_os = try allocator.dupe(u8, currentHostOsName()),
        };
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.source_path);
            allocator.free(entry.cooked_path);
        }
        self.entries.deinit(allocator);
        self.entry_map.deinit();
        self.dependency_graph.deinit(allocator);
        allocator.free(self.output_dir_path);
        allocator.free(self.host_os);
    }

    pub fn markDirty(self: *Cache) void {
        self.dirty = true;
    }

    pub fn setCurrentHostOs(self: *Cache, allocator: std.mem.Allocator) !void {
        if (std.mem.eql(u8, self.host_os, currentHostOsName())) {
            return;
        }

        const host_os = try allocator.dupe(u8, currentHostOsName());
        allocator.free(self.host_os);
        self.host_os = host_os;
        self.dirty = true;
    }

    pub fn setProjectId(self: *Cache, project_id: ProjectId) void {
        if (self.project_id.eql(project_id)) return;
        self.project_id = project_id;
        self.dirty = true;
    }

    pub fn pushCacheEntry(self: *Cache, allocator: std.mem.Allocator, entry: CacheEntry) !void {
        const idx = self.entries.items.len;
        try self.entries.append(allocator, entry);
        errdefer {
            const removed = self.entries.pop().?;
            allocator.free(removed.source_path);
            allocator.free(removed.cooked_path);
        }
        try self.entry_map.put(entry.source_path, @intCast(idx));
        self.header.entry_count += 1;
        self.dirty = true;
    }

    pub fn overwriteCacheEntry(self: *Cache, allocator: std.mem.Allocator, entry: CacheEntry, idx: u32) !void {
        const old = self.entries.items[idx];

        // The map borrows its key from the entry, and `old.source_path` is about
        // to be freed. `put` alone would keep the equal-comparing old key, so
        // overwrite the key pointer explicitly, and do it before any free so a
        // failure here leaves the cache untouched.
        const gop = try self.entry_map.getOrPut(entry.source_path);
        gop.key_ptr.* = entry.source_path;
        gop.value_ptr.* = idx;

        allocator.free(old.source_path);
        allocator.free(old.cooked_path);
        self.entries.items[idx] = entry;
        self.dirty = true;
    }

    pub fn lookupEntryMut(self: *Cache, source_file: SourceFile) ?*CacheEntry {
        const idx = self.getIdx(source_file) orelse return null;
        return &self.entries.items[idx];
    }

    pub fn pruneDeleted(self: *Cache, allocator: std.mem.Allocator, source_files: []const SourceFile) u32 {
        var source_paths = std.StringHashMap(void).init(allocator);
        defer source_paths.deinit();

        const has_source_paths = blk: {
            source_paths.ensureTotalCapacity(@intCast(source_files.len)) catch break :blk false;
            for (source_files) |sf| source_paths.putAssumeCapacity(sf.path, {});
            break :blk true;
        };

        var removed: u32 = 0;
        var write_index: usize = 0;
        for (self.entries.items) |entry| {
            const exists = if (has_source_paths)
                source_paths.contains(entry.source_path)
            else
                sourceExists(source_files, entry.source_path);

            if (!exists) {
                log.debug("Source file not found, removing cooked file {s}", .{entry.cooked_path});
                allocator.free(entry.source_path);
                allocator.free(entry.cooked_path);
                self.header.entry_count -= 1;
                removed += 1;
            } else {
                self.entries.items[write_index] = entry;
                write_index += 1;
            }
        }
        self.entries.items.len = write_index;

        // Rebuild entry_map indices after removals
        if (removed > 0) {
            self.rebuildEntryMap();
            self.dirty = true;
        }

        return removed;
    }

    pub fn pruneDeletedDependencyRows(self: *Cache, allocator: std.mem.Allocator, source_files: []const SourceFile) u32 {
        const removed = self.dependency_graph.pruneDeleted(allocator, source_files);
        if (removed > 0) {
            self.dirty = true;
        }

        return removed;
    }

    pub fn lookupDependencyRow(self: *const Cache, source_file: SourceFile) ?*const DependencyRow {
        return self.dependency_graph.get(source_file);
    }

    pub fn upsertDependencyRow(
        self: *Cache,
        allocator: std.mem.Allocator,
        source_file: SourceFile,
        info: SourceFile.FileInfo,
        dependencies: []const SourceFile,
    ) !void {
        var row = try DependencyRow.create(allocator, source_file, info, dependencies);
        errdefer row.deinit(allocator);

        try self.dependency_graph.upsert(allocator, row);
        self.dirty = true;
    }

    pub fn getIdx(self: *const Cache, source_file: SourceFile) ?u32 {
        return self.entry_map.get(source_file.path);
    }

    pub fn upsertEntry(self: *Cache, allocator: std.mem.Allocator, source_file: SourceFile, entry: CacheEntry) !void {
        if (self.getIdx(source_file)) |idx| {
            try self.overwriteCacheEntry(allocator, entry, idx);
        } else {
            try self.pushCacheEntry(allocator, entry);
        }
    }

    pub fn write(
        self: *Cache,
        allocator: std.mem.Allocator,
        io: std.Io,
        cache_dir: std.Io.Dir,
        cache_path: []const u8,
    ) !void {
        if (!self.dirty) return;

        var pending = try AtomicFile.create(allocator, io, cache_dir, cache_path);
        defer pending.deinit();
        var buf: [8192]u8 = undefined;
        var file_writer = pending.file.writer(io, &buf);
        const io_writer = &file_writer.interface;

        try io_writer.writeAll(MAGIC);
        try io_writer.writeInt(u16, self.header.version, .little);
        try io_writer.writeInt(u32, self.header.entry_count, .little);
        try io_writer.writeInt(u16, @intCast(self.output_dir_path.len), .little);
        try io_writer.writeAll(self.output_dir_path);
        try io_writer.writeInt(u16, @intCast(self.host_os.len), .little);
        try io_writer.writeAll(self.host_os);
        try io_writer.writeAll(&self.project_id.uuid.bytes);

        for (self.entries.items) |entry| {
            try io_writer.writeInt(u64, entry.source_path_hash, .little);
            try io_writer.writeInt(u64, entry.content_hash, .little);
            try io_writer.writeInt(u64, entry.source_size, .little);
            try io_writer.writeInt(i96, entry.source_mtime, .little);
            try io_writer.writeInt(u64, entry.cooked_path_hash, .little);
            try io_writer.writeInt(u64, entry.cooked_size, .little);
            try io_writer.writeInt(i96, entry.cooked_at, .little);
            try io_writer.writeInt(u16, entry.flags, .little);
            try io_writer.writeInt(u16, if (entry.asset_kind) |kind| @intFromEnum(kind) else std.math.maxInt(u16), .little);
            try io_writer.writeInt(u16, @intCast(entry.source_path.len), .little);
            try io_writer.writeAll(entry.source_path);
            try io_writer.writeInt(u16, @intCast(entry.cooked_path.len), .little);
            try io_writer.writeAll(entry.cooked_path);
        }

        try io_writer.writeInt(u32, @intCast(self.dependency_graph.rows.items.len), .little);
        for (self.dependency_graph.rows.items) |row| {
            try io_writer.writeInt(u64, row.source_path_hash, .little);
            try io_writer.writeInt(u64, row.source_size, .little);
            try io_writer.writeInt(i96, row.source_mtime, .little);
            try wire.writeString(io_writer, row.source_path);
            try io_writer.writeInt(u32, @intCast(row.dependencies.items.len), .little);
            for (row.dependencies.items) |dep| {
                try io_writer.writeInt(u64, dep.path_hash, .little);
                try wire.writeString(io_writer, dep.path);
            }
        }

        try file_writer.flush();
        try pending.commit();
        self.dirty = false;
    }

    pub fn readFromDir(
        allocator: std.mem.Allocator,
        io: std.Io,
        source_dir: std.Io.Dir,
        output_dir_path: []const u8,
        cache_dir: std.Io.Dir,
        cache_path: []const u8,
    ) !Cache {
        const file = try cache_dir.openFile(io, cache_path, .{});
        defer file.close(io);

        var buf: [8192]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        var reader = &file_reader.interface;

        var magic: [MAGIC.len]u8 = undefined;
        try reader.readSliceAll(&magic);
        if (!std.mem.eql(u8, &magic, MAGIC)) {
            return error.InvalidMagic;
        }

        const version = try reader.takeInt(u16, .little);
        if (version != VERSION) {
            return error.StaleVersion;
        }

        var cache = try readEntries(allocator, reader);
        cache.source_dir = source_dir;

        if (!std.mem.eql(u8, cache.output_dir_path, output_dir_path)) {
            const old_output_dir_path = cache.output_dir_path;
            defer {
                cache.deinit(allocator);
            }

            if (old_output_dir_path.len > 0)
                log.info("Output directory changed from '{s}' to '{s}', invalidating cache", .{ old_output_dir_path, output_dir_path });

            return error.OutputDirChanged;
        }

        return cache;
    }

    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Cache {
        const version = try reader.takeInt(u16, .little);
        if (version != VERSION) {
            return error.StaleVersion;
        }

        return readEntries(allocator, reader);
    }

    fn readEntries(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Cache {
        const entry_count = try reader.takeInt(u32, .little);
        if (entry_count > 1_000_000) {
            return error.TooManyCacheEntries;
        }

        const output_dir_path = try wire.readString(allocator, reader);
        errdefer allocator.free(output_dir_path);

        const host_os = try wire.readString(allocator, reader);
        errdefer allocator.free(host_os);

        var project_id_bytes: [16]u8 = undefined;
        try reader.readSliceAll(&project_id_bytes);

        var entries: std.ArrayList(CacheEntry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.source_path);
                allocator.free(entry.cooked_path);
            }
            entries.deinit(allocator);
        }
        var dependency_graph = CacheDepGraph.init(allocator);
        errdefer dependency_graph.deinit(allocator);

        try entries.ensureTotalCapacity(allocator, entry_count);

        for (0..entry_count) |_| {
            const source_path_hash = try reader.takeInt(u64, .little);
            const content_hash = try reader.takeInt(u64, .little);
            const source_size = try reader.takeInt(u64, .little);
            const source_mtime = try reader.takeInt(i96, .little);
            const cooked_path_hash = try reader.takeInt(u64, .little);
            const cooked_size = try reader.takeInt(u64, .little);
            const cooked_at = try reader.takeInt(i96, .little);
            const flags = try reader.takeInt(u16, .little);
            const asset_kind_raw = try reader.takeInt(u16, .little);
            const asset_kind: ?AssetKind = if (asset_kind_raw == std.math.maxInt(u16))
                null
            else
                AssetKind.fromInt(std.math.cast(u8, asset_kind_raw) orelse return error.InvalidAssetKind) orelse return error.InvalidAssetKind;

            const source_path = try wire.readString(allocator, reader);
            errdefer allocator.free(source_path);

            const cooked_path = try wire.readString(allocator, reader);
            errdefer allocator.free(cooked_path);

            entries.appendAssumeCapacity(.{
                .source_path = source_path,
                .source_path_hash = source_path_hash,
                .content_hash = content_hash,
                .source_size = source_size,
                .source_mtime = source_mtime,
                .cooked_path = cooked_path,
                .cooked_path_hash = cooked_path_hash,
                .cooked_size = cooked_size,
                .cooked_at = cooked_at,
                .flags = flags,
                .asset_kind = asset_kind,
            });
        }

        const dependency_row_count = try reader.takeInt(u32, .little);
        if (dependency_row_count > 1_000_000) {
            return error.TooManyDependencyRows;
        }

        try dependency_graph.rows.ensureTotalCapacity(allocator, dependency_row_count);
        try dependency_graph.row_map.ensureTotalCapacity(@intCast(dependency_row_count));

        var total_dependency_count: usize = 0;
        for (0..dependency_row_count) |_| {
            const source_path_hash = try reader.takeInt(u64, .little);
            const source_size = try reader.takeInt(u64, .little);
            const source_mtime = try reader.takeInt(i96, .little);
            const source_path = try wire.readString(allocator, reader);
            errdefer allocator.free(source_path);

            const dependency_count = try reader.takeInt(u32, .little);
            try wire.checkedAddWithinLimit(&total_dependency_count, dependency_count, 10_000_000);
            var dependencies: std.ArrayList(DependencyRef) = .empty;
            errdefer {
                for (dependencies.items) |dep| allocator.free(dep.path);
                dependencies.deinit(allocator);
            }
            try dependencies.ensureTotalCapacity(allocator, dependency_count);

            for (0..dependency_count) |_| {
                const path_hash = try reader.takeInt(u64, .little);
                const path = try wire.readString(allocator, reader);
                errdefer allocator.free(path);
                dependencies.appendAssumeCapacity(.{
                    .path = path,
                    .path_hash = path_hash,
                });
            }

            const idx = dependency_graph.rows.items.len;
            dependency_graph.rows.appendAssumeCapacity(.{
                .source_path = source_path,
                .source_path_hash = source_path_hash,
                .source_size = source_size,
                .source_mtime = source_mtime,
                .dependencies = dependencies,
            });
            dependency_graph.row_map.putAssumeCapacity(source_path, @intCast(idx));
        }

        var entry_map: EntryMap = .init(allocator);
        try entry_map.ensureTotalCapacity(@intCast(entry_count));
        for (entries.items, 0..) |entry, i| {
            entry_map.putAssumeCapacity(entry.source_path, @intCast(i));
        }

        return .{
            .header = .{
                .version = VERSION,
                .entry_count = entry_count,
            },
            .entry_map = entry_map,
            .dependency_graph = dependency_graph,
            .entries = entries,
            .source_dir = .cwd(),
            .output_dir_path = output_dir_path,
            .host_os = host_os,
            .project_id = .fromBytes(project_id_bytes),
            .dirty = false,
        };
    }

    fn rebuildEntryMap(self: *Cache) void {
        self.entry_map.clearRetainingCapacity();
        for (self.entries.items, 0..) |entry, idx| {
            self.entry_map.putAssumeCapacity(entry.source_path, @intCast(idx));
        }
    }
};

test "upsertEntry replaces existing entry without growing cache" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var cache = try Cache.init(testing.allocator, tmp.dir, "out");
    defer cache.deinit(testing.allocator);

    const source = SourceFile{ .path = "a.glsl", .extension = .glsl };
    const first = CacheEntry{
        .source_path = try testing.allocator.dupe(u8, "a.glsl"),
        .source_path_hash = source.hashPath(),
        .content_hash = 1,
        .source_size = 1,
        .source_mtime = 1,
        .cooked_path = try testing.allocator.dupe(u8, "old.zshdr"),
        .cooked_path_hash = fnv1a("old.zshdr"),
        .cooked_size = 1,
        .cooked_at = 1,
        .asset_kind = .shader_stage,
    };
    try cache.upsertEntry(testing.allocator, source, first);

    const second = CacheEntry{
        .source_path = try testing.allocator.dupe(u8, "a.glsl"),
        .source_path_hash = source.hashPath(),
        .content_hash = 2,
        .source_size = 2,
        .source_mtime = 2,
        .cooked_path = try testing.allocator.dupe(u8, ""),
        .cooked_path_hash = 0,
        .cooked_size = 0,
        .cooked_at = 2,
        .asset_kind = .shader_stage,
    };
    try cache.upsertEntry(testing.allocator, source, second);

    try testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    try testing.expectEqual(@as(u64, 2), cache.entries.items[0].content_hash);
    try testing.expectEqualStrings("", cache.entries.items[0].cooked_path);
}

test "path-hash collisions keep cache rows distinct" {
    var cache = try Cache.init(testing.allocator, .cwd(), ".");
    defer cache.deinit(testing.allocator);

    // Both entries carry the same stored path hash. The index is keyed on the
    // path itself, so a collision in that field cannot merge or hide a row.
    const hash: Hash = 1;
    var first = try makeTestEntry(testing.allocator, "first.glsl", "first.zshdr");
    first.source_path_hash = hash;
    var second = try makeTestEntry(testing.allocator, "second.glsl", "second.zshdr");
    second.source_path_hash = hash;
    try cache.pushCacheEntry(testing.allocator, first);
    try cache.pushCacheEntry(testing.allocator, second);

    try testing.expectEqual(@as(u32, 0), cache.getIdx(SourceFile.fromPath("first.glsl")).?);
    try testing.expectEqual(@as(u32, 1), cache.getIdx(SourceFile.fromPath("second.glsl")).?);
}

test "overwriting an entry re-keys the index off the freed path" {
    var cache = try Cache.init(testing.allocator, .cwd(), ".");
    defer cache.deinit(testing.allocator);

    const source = SourceFile.fromPath("shader.glsl");
    try cache.upsertEntry(testing.allocator, source, try makeTestEntry(testing.allocator, "shader.glsl", "a.zshdr"));

    // The replacement owns a different allocation for the same path text; the
    // index must follow it rather than keep borrowing the freed original.
    var replacement = try makeTestEntry(testing.allocator, "shader.glsl", "b.zshdr");
    replacement.content_hash = 99;
    try cache.upsertEntry(testing.allocator, source, replacement);

    try testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    const idx = cache.getIdx(source).?;
    try testing.expectEqual(@as(u64, 99), cache.entries.items[idx].content_hash);
    try testing.expectEqualStrings("shader.glsl", cache.entries.items[idx].source_path);
}

const testing = std.testing;

fn makeTestEntry(allocator: std.mem.Allocator, source_path: []const u8, cooked_path: []const u8) !CacheEntry {
    const owned_source = try allocator.dupe(u8, source_path);
    errdefer allocator.free(owned_source);
    const owned_cooked = try allocator.dupe(u8, cooked_path);
    return .{
        .source_path = owned_source,
        .source_path_hash = fnv1a(source_path),
        .content_hash = 0xDEADBEEF,
        .source_size = 1024,
        .source_mtime = 1775606400 * std.time.ns_per_s,
        .cooked_path = owned_cooked,
        .cooked_path_hash = fnv1a(cooked_path),
        .cooked_size = 512,
        .cooked_at = 1775606400 * std.time.ns_per_s,
        .asset_kind = .mesh,
    };
}

fn writeTestCache(writer: *std.Io.Writer, entries: []const CacheEntry) !void {
    try writeTestCacheWithOutputDirAndDependencies(writer, entries, ".", &.{});
}

fn writeTestCacheWithOutputDir(writer: *std.Io.Writer, entries: []const CacheEntry, output_dir_path: []const u8) !void {
    try writeTestCacheWithOutputDirAndDependencies(writer, entries, output_dir_path, &.{});
}

fn writeTestCacheWithOutputDirAndDependencies(
    writer: *std.Io.Writer,
    entries: []const CacheEntry,
    output_dir_path: []const u8,
    dependency_rows: []const DependencyRow,
) !void {
    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, VERSION, .little);
    try writer.writeInt(u32, @intCast(entries.len), .little);
    try writer.writeInt(u16, @intCast(output_dir_path.len), .little);
    try writer.writeAll(output_dir_path);
    try writer.writeInt(u16, @intCast(currentHostOsName().len), .little);
    try writer.writeAll(currentHostOsName());
    try writer.writeAll(&ProjectId.zero.uuid.bytes);

    for (entries) |entry| {
        try writer.writeInt(u64, entry.source_path_hash, .little);
        try writer.writeInt(u64, entry.content_hash, .little);
        try writer.writeInt(u64, entry.source_size, .little);
        try writer.writeInt(i96, entry.source_mtime, .little);
        try writer.writeInt(u64, entry.cooked_path_hash, .little);
        try writer.writeInt(u64, entry.cooked_size, .little);
        try writer.writeInt(i96, entry.cooked_at, .little);
        try writer.writeInt(u16, entry.flags, .little);
        try writer.writeInt(u16, if (entry.asset_kind) |kind| @intFromEnum(kind) else std.math.maxInt(u16), .little);
        try writer.writeInt(u16, @intCast(entry.source_path.len), .little);
        try writer.writeAll(entry.source_path);
        try writer.writeInt(u16, @intCast(entry.cooked_path.len), .little);
        try writer.writeAll(entry.cooked_path);
    }

    try writer.writeInt(u32, @intCast(dependency_rows.len), .little);
    for (dependency_rows) |row| {
        try writer.writeInt(u64, row.source_path_hash, .little);
        try writer.writeInt(u64, row.source_size, .little);
        try writer.writeInt(i96, row.source_mtime, .little);
        try writer.writeInt(u16, @intCast(row.source_path.len), .little);
        try writer.writeAll(row.source_path);
        try writer.writeInt(u32, @intCast(row.dependencies.items.len), .little);
        for (row.dependencies.items) |dep| {
            try writer.writeInt(u64, dep.path_hash, .little);
            try writer.writeInt(u16, @intCast(dep.path.len), .little);
            try writer.writeAll(dep.path);
        }
    }
}

test "init returns empty cache" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), c.header.entry_count);
    try testing.expectEqual(@as(usize, 0), c.entries.items.len);
    try testing.expectEqual(VERSION, c.header.version);
}

test "deinit frees allocated entry paths" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    const entry = try makeTestEntry(testing.allocator, "src/model.glb", "model.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);
    c.deinit(testing.allocator);
}

test "deinit on empty cache does not error" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    c.deinit(testing.allocator);
}

test "pushCacheEntry adds entry and increments count" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const entry = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);

    try testing.expectEqual(@as(u32, 1), c.header.entry_count);
    try testing.expectEqual(@as(usize, 1), c.entries.items.len);
    try testing.expectEqualStrings("a.glb", c.entries.items[0].source_path);
}

test "pushCacheEntry multiple entries" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    for (0..5) |_| {
        const entry = try makeTestEntry(testing.allocator, "mesh.glb", "mesh.zmesh");
        try c.pushCacheEntry(testing.allocator, entry);
    }

    try testing.expectEqual(@as(u32, 5), c.header.entry_count);
    try testing.expectEqual(@as(usize, 5), c.entries.items.len);
}

test "lookupEntryMut returns mutable entry" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const entry = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);
    try c.entry_map.put(entry.source_path, 0);

    const sf = SourceFile{ .path = "a.glb", .extension = .glb };
    const found = c.lookupEntryMut(sf);
    try testing.expect(found != null);
    found.?.source_mtime = 42;
    try testing.expectEqual(@as(i96, 42), c.entries.items[0].source_mtime);
}

test "lookupEntryMut returns null when not found" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const sf = SourceFile{ .path = "missing.glb", .extension = .glb };
    try testing.expect(c.lookupEntryMut(sf) == null);
}

test "getIdx returns index when entry exists" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const entry = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);
    try c.entry_map.put(entry.source_path, 0);

    const sf = SourceFile{ .path = "a.glb", .extension = .glb };
    try testing.expectEqual(@as(u32, 0), c.getIdx(sf).?);
}

test "getIdx returns null when entry does not exist" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const sf = SourceFile{ .path = "missing.glb", .extension = .glb };
    try testing.expect(c.getIdx(sf) == null);
}

test "pruneDeleted removes entries not in source list" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const e1 = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, e1);
    try c.entry_map.put(e1.source_path, 0);

    const e2 = try makeTestEntry(testing.allocator, "b.glb", "b.zmesh");
    try c.pushCacheEntry(testing.allocator, e2);
    try c.entry_map.put(e2.source_path, 1);

    const source_files = [_]SourceFile{
        .{ .path = "a.glb", .extension = .glb },
    };

    const removed = c.pruneDeleted(testing.allocator, &source_files);
    try testing.expectEqual(@as(u32, 1), removed);
    try testing.expectEqual(@as(u32, 1), c.header.entry_count);
    try testing.expectEqual(@as(usize, 1), c.entries.items.len);
    try testing.expectEqualStrings("a.glb", c.entries.items[0].source_path);
}

test "pruneDeleted returns zero when all entries present" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const e1 = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, e1);
    try c.entry_map.put(e1.source_path, 0);

    const source_files = [_]SourceFile{
        .{ .path = "a.glb", .extension = .glb },
    };

    const removed = c.pruneDeleted(testing.allocator, &source_files);
    try testing.expectEqual(@as(u32, 0), removed);
    try testing.expectEqual(@as(u32, 1), c.header.entry_count);
}

test "pruneDeleted removes all entries when source list is empty" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const e1 = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, e1);
    try c.entry_map.put(e1.source_path, 0);

    const e2 = try makeTestEntry(testing.allocator, "b.glb", "b.zmesh");
    try c.pushCacheEntry(testing.allocator, e2);
    try c.entry_map.put(e2.source_path, 1);

    const empty: []const SourceFile = &.{};
    const removed = c.pruneDeleted(testing.allocator, empty);
    try testing.expectEqual(@as(u32, 2), removed);
    try testing.expectEqual(@as(u32, 0), c.header.entry_count);
    try testing.expectEqual(@as(usize, 0), c.entries.items.len);
}

test "pruneDeleted rebuilds entry_map with correct indices" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const e1 = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, e1);
    try c.entry_map.put(e1.source_path, 0);

    const e2 = try makeTestEntry(testing.allocator, "b.glb", "b.zmesh");
    try c.pushCacheEntry(testing.allocator, e2);
    try c.entry_map.put(e2.source_path, 1);

    const e3 = try makeTestEntry(testing.allocator, "c.glb", "c.zmesh");
    try c.pushCacheEntry(testing.allocator, e3);
    try c.entry_map.put(e3.source_path, 2);

    const source_files = [_]SourceFile{
        .{ .path = "a.glb", .extension = .glb },
        .{ .path = "c.glb", .extension = .glb },
    };

    _ = c.pruneDeleted(testing.allocator, &source_files);

    const sf_a = SourceFile{ .path = "a.glb", .extension = .glb };
    const sf_c = SourceFile{ .path = "c.glb", .extension = .glb };
    try testing.expectEqual(@as(u32, 0), c.getIdx(sf_a).?);
    try testing.expectEqual(@as(u32, 1), c.getIdx(sf_c).?);
}

test "pruneDeleted on empty cache returns zero" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const empty: []const SourceFile = &.{};
    const removed = c.pruneDeleted(testing.allocator, empty);
    try testing.expectEqual(@as(u32, 0), removed);
}

test "read parses single entry with all fields" {
    const source = "meshes/cube.glb";
    const cooked = "cube.zmesh";

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const entry = CacheEntry{
        .source_path = source,
        .source_path_hash = 0xAAAA,
        .content_hash = 0xBBBB,
        .source_size = 2048,
        .source_mtime = 999_000_000_000,
        .cooked_path = cooked,
        .cooked_path_hash = 0xCCCC,
        .cooked_size = 1024,
        .cooked_at = 1775606400 * std.time.ns_per_s,
        .asset_kind = .mesh,
    };
    try writeTestCache(&writer, &.{entry});

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c = try Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), c.header.entry_count);
    const e = c.entries.items[0];
    try testing.expectEqual(@as(u64, 0xAAAA), e.source_path_hash);
    try testing.expectEqual(@as(u64, 0xBBBB), e.content_hash);
    try testing.expectEqual(@as(u64, 2048), e.source_size);
    try testing.expectEqual(@as(i96, 999_000_000_000), e.source_mtime);
    try testing.expectEqual(@as(u64, 0xCCCC), e.cooked_path_hash);
    try testing.expectEqual(@as(u64, 1024), e.cooked_size);
    try testing.expectEqual(AssetKind.mesh, e.asset_kind);
    try testing.expectEqualStrings(source, e.source_path);
    try testing.expectEqualStrings(cooked, e.cooked_path);
}

test "read parses multiple entries" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const entries = [_]CacheEntry{
        .{
            .source_path = "a.glb",
            .source_path_hash = 1,
            .content_hash = 2,
            .source_size = 100,
            .source_mtime = 0,
            .cooked_path = "a.zmesh",
            .cooked_path_hash = 3,
            .cooked_size = 50,
            .cooked_at = 0,
            .asset_kind = .mesh,
        },
        .{
            .source_path = "b.gltf",
            .source_path_hash = 4,
            .content_hash = 5,
            .source_size = 200,
            .source_mtime = 0,
            .cooked_path = "b.zmesh",
            .cooked_path_hash = 6,
            .cooked_size = 75,
            .cooked_at = 0,
            .asset_kind = null,
        },
    };
    try writeTestCache(&writer, &entries);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c = try Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), c.header.entry_count);
    try testing.expectEqualStrings("a.glb", c.entries.items[0].source_path);
    try testing.expectEqualStrings("b.gltf", c.entries.items[1].source_path);
    try testing.expectEqual(AssetKind.mesh, c.entries.items[0].asset_kind);
    try testing.expect(c.entries.items[1].asset_kind == null);
}

test "read parses dependency graph rows" {
    const source = SourceFile.fromPath("shaders/main.frag");
    const deps = [_]SourceFile{
        SourceFile.fromPath("shaders/common.glsl"),
        SourceFile.fromPath("shared/light.glsl"),
    };

    var row = try DependencyRow.create(testing.allocator, source, .{
        .size = 123,
        .modified_ns = 456,
    }, &deps);
    defer row.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestCacheWithOutputDirAndDependencies(&writer, &.{}, ".", &.{row});

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c = try Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), c.dependency_graph.rows.items.len);
    try testing.expectEqual(@as(usize, 2), c.dependency_graph.totalEdgeCount());

    const parsed = c.lookupDependencyRow(source) orelse return error.MissingDependencyRow;
    try testing.expectEqualStrings("shaders/main.frag", parsed.source_path);
    try testing.expectEqual(@as(u64, 123), parsed.source_size);
    try testing.expectEqual(@as(i96, 456), parsed.source_mtime);
    try testing.expectEqualStrings("shaders/common.glsl", parsed.dependencies.items[0].path);
    try testing.expectEqual(deps[0].hashPath(), parsed.dependencies.items[0].path_hash);
    try testing.expectEqualStrings("shared/light.glsl", parsed.dependencies.items[1].path);
}

test "upsertDependencyRow replaces existing dependency graph row" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const source = SourceFile.fromPath("main.frag");
    const dep_a = [_]SourceFile{SourceFile.fromPath("a.glsl")};
    const dep_b = [_]SourceFile{SourceFile.fromPath("b.glsl")};

    try c.upsertDependencyRow(testing.allocator, source, .{
        .size = 10,
        .modified_ns = 20,
    }, &dep_a);
    try c.upsertDependencyRow(testing.allocator, source, .{
        .size = 30,
        .modified_ns = 40,
    }, &dep_b);

    try testing.expectEqual(@as(usize, 1), c.dependency_graph.rows.items.len);
    const row = c.lookupDependencyRow(source) orelse return error.MissingDependencyRow;
    try testing.expect(row.isFresh(.{ .size = 30, .modified_ns = 40 }));
    try testing.expectEqualStrings("b.glsl", row.dependencies.items[0].path);
}

test "pruneDeletedDependencyRows removes rows for deleted sources" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const keep = SourceFile.fromPath("keep.frag");
    const remove = SourceFile.fromPath("remove.frag");
    try c.upsertDependencyRow(testing.allocator, keep, .{ .size = 1, .modified_ns = 1 }, &.{});
    try c.upsertDependencyRow(testing.allocator, remove, .{ .size = 1, .modified_ns = 1 }, &.{});

    const removed = c.pruneDeletedDependencyRows(testing.allocator, &.{keep});
    try testing.expectEqual(@as(u32, 1), removed);
    try testing.expect(c.lookupDependencyRow(keep) != null);
    try testing.expect(c.lookupDependencyRow(remove) == null);
}

test "read accepts zero entries" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestCache(&writer, &.{});

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c = try Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), c.header.entry_count);
    try testing.expectEqual(@as(usize, 0), c.entries.items.len);
}

test "read returns StaleVersion for wrong version" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, 999, .little);
    try writer.writeInt(u32, 0, .little);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    try testing.expectError(error.StaleVersion, Cache.read(testing.allocator, &reader));
}

test "read handles entry with empty paths" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const entry = CacheEntry{
        .source_path = "",
        .source_path_hash = 0,
        .content_hash = 0,
        .source_size = 0,
        .source_mtime = 0,
        .cooked_path = "",
        .cooked_path_hash = 0,
        .cooked_size = 0,
        .cooked_at = 0,
        .asset_kind = null,
    };
    try writeTestCache(&writer, &.{entry});

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c = try Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), c.entries.items[0].source_path.len);
    try testing.expectEqual(@as(usize, 0), c.entries.items[0].cooked_path.len);
}

test "read errors on truncated entry data" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, VERSION, .little);
    try writer.writeInt(u32, 1, .little);
    try writer.writeInt(u16, 1, .little); // output_dir_path len
    try writer.writeAll("."); // output_dir_path
    try writer.writeInt(u16, @intCast(currentHostOsName().len), .little); // host_os len
    try writer.writeAll(currentHostOsName()); // host_os
    try writer.writeAll(&ProjectId.zero.uuid.bytes); // project_id
    try writer.writeInt(u64, 0xAAAA, .little);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    try testing.expectError(error.EndOfStream, Cache.read(testing.allocator, &reader));
}

test "read errors on truncated header" {
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, VERSION, .little);
    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    try testing.expectError(error.EndOfStream, Cache.read(testing.allocator, &reader));
}

test "write then read round-trip preserves all fields" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var c = try Cache.init(testing.allocator, tmp.dir, ".");
    defer c.deinit(testing.allocator);

    const entry1 = try makeTestEntry(testing.allocator, "models/hero.glb", "hero.zmesh");
    try c.pushCacheEntry(testing.allocator, entry1);

    var entry2 = try makeTestEntry(testing.allocator, "models/tree.gltf", "tree.zmesh");
    entry2.content_hash = 0x12345678;
    entry2.source_size = 8192;
    entry2.cooked_size = 4096;
    entry2.asset_kind = null;
    try c.pushCacheEntry(testing.allocator, entry2);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestCache(&writer, c.entries.items);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c2 = try Cache.read(testing.allocator, &reader);
    defer c2.deinit(testing.allocator);

    try testing.expectEqual(c.header.entry_count, c2.header.entry_count);

    for (c.entries.items, c2.entries.items) |original, parsed| {
        try testing.expectEqualStrings(original.source_path, parsed.source_path);
        try testing.expectEqual(original.source_path_hash, parsed.source_path_hash);
        try testing.expectEqual(original.content_hash, parsed.content_hash);
        try testing.expectEqual(original.source_size, parsed.source_size);
        try testing.expectEqual(original.source_mtime, parsed.source_mtime);
        try testing.expectEqualStrings(original.cooked_path, parsed.cooked_path);
        try testing.expectEqual(original.cooked_path_hash, parsed.cooked_path_hash);
        try testing.expectEqual(original.cooked_size, parsed.cooked_size);
        try testing.expectEqual(original.cooked_at, parsed.cooked_at);
        try testing.expectEqual(original.asset_kind, parsed.asset_kind);
    }
}

test "write then read round-trip with zero entries" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestCache(&writer, c.entries.items);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c2 = try Cache.read(testing.allocator, &reader);
    defer c2.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), c2.header.entry_count);
    try testing.expectEqual(@as(usize, 0), c2.entries.items.len);
}

test "HEADER_SIZE matches expected layout" {
    try testing.expectEqual(@as(u32, MAGIC.len + @sizeOf(u16) + @sizeOf(u32) + @sizeOf(u16) + @sizeOf(u16) + 16), HEADER_SIZE);
}

test "write then readFromDir preserves the project id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var c = try Cache.init(testing.allocator, tmp.dir, ".");
    defer c.deinit(testing.allocator);
    const project_id = ProjectId.parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc");
    c.setProjectId(project_id);
    try c.write(testing.allocator, testing.io, tmp.dir, ".zcache");

    var c2 = try Cache.readFromDir(testing.allocator, testing.io, tmp.dir, ".", tmp.dir, ".zcache");
    defer c2.deinit(testing.allocator);
    try testing.expect(c2.project_id.eql(project_id));
}

test "upsertEntry inserts new entry when not in cache" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const sf = SourceFile{ .path = "a.glb", .extension = .glb };
    const entry = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.upsertEntry(testing.allocator, sf, entry);

    try testing.expectEqual(@as(u32, 1), c.header.entry_count);
    try testing.expectEqualStrings("a.glb", c.entries.items[0].source_path);
}

test "upsertEntry overwrites existing entry with matching path" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const sf = SourceFile{ .path = "a.glb", .extension = .glb };
    const entry1 = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, entry1);
    try c.entry_map.put(entry1.source_path, 0);

    var entry2 = try makeTestEntry(testing.allocator, "a.glb", "a_v2.zmesh");
    entry2.cooked_size = 999;
    try c.upsertEntry(testing.allocator, sf, entry2);

    try testing.expectEqualStrings("a_v2.zmesh", c.entries.items[0].cooked_path);
    try testing.expectEqual(@as(u64, 999), c.entries.items[0].cooked_size);
}

test "upsertEntry handles multiple distinct entries" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const sf_a = SourceFile{ .path = "a.glb", .extension = .glb };
    const sf_b = SourceFile{ .path = "b.glb", .extension = .glb };

    try c.upsertEntry(testing.allocator, sf_a, try makeTestEntry(testing.allocator, "a.glb", "a.zmesh"));
    try c.upsertEntry(testing.allocator, sf_b, try makeTestEntry(testing.allocator, "b.glb", "b.zmesh"));

    try testing.expectEqual(@as(u32, 2), c.header.entry_count);
}
