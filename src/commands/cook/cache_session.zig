const std = @import("std");

const SourceFile = @import("../../assets/source_file.zig").SourceFile;
const Cache = @import("../../cache/cache.zig").Cache;
const log = @import("../../logger.zig");
const CookContext = @import("context.zig").CookContext;

pub const CacheSession = struct {
    cache: Cache,

    const CacheLocation = struct {
        dir: std.Io.Dir,
        path: []const u8,
    };

    fn location(ctx: *const CookContext) CacheLocation {
        if (ctx.project) |project| {
            return .{ .dir = project.root_dir, .path = ".fusion/.zcache" };
        }
        return .{ .dir = ctx.output, .path = ".zcache" };
    }

    pub fn open(allocator: std.mem.Allocator, ctx: *const CookContext) !CacheSession {
        const cache_location = location(ctx);
        const cache = blk: {
            if (ctx.force) {
                break :blk try Cache.init(allocator, ctx.source, ctx.output_path);
            }

            break :blk Cache.readFromDir(
                allocator,
                ctx.io,
                ctx.source,
                ctx.output_path,
                cache_location.dir,
                cache_location.path,
            ) catch |err| {
                switch (err) {
                    error.OutputDirChanged => log.debug("Output directory changed, rebuilding cache", .{}),
                    error.StaleVersion => log.debug("Outdated cache version found, rebuilding entire cache", .{}),
                    error.FileNotFound => log.debug("No existing cache found, starting fresh", .{}),
                    else => log.debug("Failed to read cache ({s}), starting fresh", .{@errorName(err)}),
                }
                break :blk try Cache.init(allocator, ctx.source, ctx.output_path);
            };
        };

        return .{ .cache = cache };
    }

    pub fn deinit(self: *CacheSession, allocator: std.mem.Allocator) void {
        self.cache.deinit(allocator);
    }

    pub fn pruneDeleted(self: *CacheSession, allocator: std.mem.Allocator, source_files: []const SourceFile) void {
        const pruned = self.cache.pruneDeleted(allocator, source_files);
        if (pruned > 0) {
            log.debug("Removed {d} deleted source file(s) from cache", .{pruned});
        }

        const pruned_deps = self.cache.pruneDeletedDependencyRows(allocator, source_files);
        if (pruned_deps > 0) {
            log.debug("Removed {d} deleted dependency graph row(s) from cache", .{pruned_deps});
        }
    }

    pub fn persist(self: *CacheSession, allocator: std.mem.Allocator, ctx: *const CookContext) !u64 {
        try self.cache.setCurrentHostOs(allocator);
        if (!self.cache.dirty) {
            return 0;
        }

        const cache_location = location(ctx);
        try self.cache.write(allocator, ctx.io, cache_location.dir, cache_location.path);
        return cacheBytesWritten(ctx);
    }

    pub fn cacheBytesWritten(ctx: *const CookContext) u64 {
        const cache_location = location(ctx);
        const cache_file = cache_location.dir.openFile(ctx.io, cache_location.path, .{}) catch return 0;
        defer cache_file.close(ctx.io);

        const stat = cache_file.stat(ctx.io) catch return 0;
        return stat.size;
    }
};

const testing = std.testing;

test "CacheSession scopes directory-mode cache to output" {
    var source_tmp = testing.tmpDir(.{});
    defer source_tmp.cleanup();
    var output_tmp = testing.tmpDir(.{});
    defer output_tmp.cleanup();

    const ctx: CookContext = .{
        .io = testing.io,
        .source = source_tmp.dir,
        .output = output_tmp.dir,
        .output_path = ".",
        .force = false,
    };
    const cache_location = CacheSession.location(&ctx);
    try testing.expectEqual(output_tmp.dir.handle, cache_location.dir.handle);
    try testing.expectEqualStrings(".zcache", cache_location.path);
}

test "CacheSession scopes project-mode cache to project metadata" {
    var project_tmp = testing.tmpDir(.{});
    defer project_tmp.cleanup();

    const ctx: CookContext = .{
        .io = testing.io,
        .source = project_tmp.dir,
        .output = project_tmp.dir,
        .output_path = "output",
        .force = false,
        .project = .{
            .project_id = .zero,
            .root_dir = project_tmp.dir,
            .manifest_path = ".fusion/assets.zmanifest",
        },
    };
    const cache_location = CacheSession.location(&ctx);
    try testing.expectEqual(project_tmp.dir.handle, cache_location.dir.handle);
    try testing.expectEqualStrings(".fusion/.zcache", cache_location.path);
}
