const std = @import("std");

const path_helpers = @import("../path.zig");
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const ProjectId = @import("../id/id_types.zig").ProjectId;
const TargetProfile = @import("../assets/cooked/target_profile.zig").TargetProfile;
const AssetId = @import("../id/id_types.zig").AssetId;
const derive = @import("../manifest/derive.zig");

pub const CookInput = struct {
    /// Short-lived parser allocations. Cook jobs normally provide an arena.
    allocator: std.mem.Allocator,
    /// Optional allocator whose `free` operation immediately reclaims large
    /// working buffers. Texture cooking uses this instead of retaining every
    /// mip allocation in the job arena.
    temporary_allocator: ?std.mem.Allocator = null,
    io: std.Io,
    source_dir: std.Io.Dir,
    /// Namespace for the `AssetId`s of referenced assets (see
    /// `manifest/derive.zig:assetIdForReference`).
    project_id: ProjectId,
    target_profile: TargetProfile = .host(),
    source: SourceFile,
    bytes: []const u8,
    writer: *std.Io.Writer,

    /// Id of the asset at source path `path`, for embedding as a reference.
    pub fn referenceId(self: *const CookInput, path: []const u8) !AssetId {
        return derive.assetIdForReference(self.project_id, path);
    }

    /// `referenceId` for each path. Caller owns the returned slice.
    pub fn referenceIds(self: *const CookInput, paths: []const []const u8) ![]AssetId {
        const ids = try self.allocator.alloc(AssetId, paths.len);
        errdefer self.allocator.free(ids);
        for (paths, ids) |path, *id| id.* = try self.referenceId(path);
        return ids;
    }
};

pub const Cooker = struct {
    cook_fn: *const fn (input: *const CookInput) anyerror!void,

    pub fn cook(self: Cooker, input: *const CookInput) !void {
        return self.cook_fn(input);
    }

    pub fn outputPath(
        _: Cooker,
        allocator: std.mem.Allocator,
        source: SourceFile,
    ) ![]u8 {
        return path_helpers.cookedOutput(allocator, source.path, source.assetKind() orelse return error.UnsupportedAssetKind);
    }
};

const testing = std.testing;

var test_called: bool = false;

fn stubCook(_: *const CookInput) anyerror!void {
    test_called = true;
}

fn failingCook(_: *const CookInput) anyerror!void {
    return error.TestCookFailed;
}

test "Cooker.cook calls the provided function pointer" {
    test_called = false;
    const cooker = Cooker{ .cook_fn = stubCook };

    var buf: [1]u8 = .{0};
    var writer = std.Io.Writer.fixed(&buf);
    const input = CookInput{ .allocator = testing.allocator, .io = testing.io, .source_dir = std.Io.Dir.cwd(), .project_id = .zero, .source = SourceFile.fromPath(""), .bytes = "", .writer = &writer };
    try cooker.cook(&input);

    try testing.expect(test_called);
}

test "Cooker.cook propagates errors from cook_fn" {
    const cooker = Cooker{ .cook_fn = failingCook };

    var buf: [1]u8 = .{0};
    var writer = std.Io.Writer.fixed(&buf);
    const input = CookInput{ .allocator = testing.allocator, .io = testing.io, .source_dir = std.Io.Dir.cwd(), .project_id = .zero, .source = SourceFile.fromPath(""), .bytes = "", .writer = &writer };
    try testing.expectError(error.TestCookFailed, cooker.cook(&input));
}
