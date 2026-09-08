const std = @import("std");

const path = @import("../path.zig");
const ProjectId = @import("../id/id_types.zig").ProjectId;
const atomic_file = @import("../shared/atomic_file.zig");

const log = @import("../logger.zig");

const MANIFEST_VERSION: u32 = 1;
const DEFAULT_COOKED_ASSETS_DIR = ".fusion/cooked";
const DEFAULT_ASSETS_DIR = "assets";
const DEFAULT_SCENES_DIR = "scenes";
const DEFAULT_ASSET_MANIFEST = ".fusion/assets.zmanifest";
const DEFAULT_NAME = "Untitled Project";
const DEFAULT_GENERATED_DIR = ".fusion";
const DEFAULT_FORMAT = "fusion.proj";

/// The manifest always lives at this filename. `format` is a pure identity
/// string and is never used as a save path (a custom `format` value fails
/// `validate()` instead of silently relocating the manifest).
pub const manifest_filename = "fusion.proj";
pub const default_manifest_path = DEFAULT_GENERATED_DIR ++ "/" ++ manifest_filename;

pub const max_manifest_bytes: usize = 64 * 1024;

pub const ValidateError = error{
    InvalidProjectFormat,
    UnsupportedProjectVersion,
    InvalidProjectId,
} || path.Error;

pub const ProjectManifest = struct {
    format: []const u8 = DEFAULT_FORMAT,
    version: u32 = MANIFEST_VERSION,
    name: []const u8 = DEFAULT_NAME,
    project_id: ProjectId,
    assets_dir: []const u8 = DEFAULT_ASSETS_DIR,
    scenes_dir: []const u8 = DEFAULT_SCENES_DIR,
    generated_dir: []const u8 = DEFAULT_GENERATED_DIR,
    cooked_assets_dir: []const u8 = DEFAULT_COOKED_ASSETS_DIR,
    asset_manifest: []const u8 = DEFAULT_ASSET_MANIFEST,
    default_scene: ?[]const u8 = null,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, file: []const u8) !ProjectManifest {
        const normalized_path = try path.normalizeVirtual(allocator, file);
        defer allocator.free(normalized_path);

        const cwd = std.Io.Dir.cwd();
        const dir = try cwd.openDir(io, ".", .{});
        defer dir.close(io);

        return loadFromDir(allocator, io, dir, normalized_path);
    }

    pub fn loadFromDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file: []const u8) !ProjectManifest {
        const normalized_path = try path.normalizeVirtual(allocator, file);
        defer allocator.free(normalized_path);

        const bytes = try readManifestBytes(allocator, io, dir, normalized_path);
        defer allocator.free(bytes);

        const parsed = try std.json.parseFromSlice(ProjectManifest, allocator, bytes, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        try parsed.value.validate();
        return parsed.value.cloneOwned(allocator);
    }

    /// Arena-oriented loader for aggregate owners such as `ProjectRoot`.
    /// Every returned string lives until `allocator` is deinitialized.
    pub fn loadFromDirLeaky(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file: []const u8) !ProjectManifest {
        const normalized_path = try path.normalizeVirtual(allocator, file);
        const bytes = try readManifestBytes(allocator, io, dir, normalized_path);
        const manifest = try std.json.parseFromSliceLeaky(ProjectManifest, allocator, bytes, .{
            .allocate = .alloc_always,
        });
        try manifest.validate();
        return manifest;
    }

    /// Reject manifests whose identity or paths would make later file
    /// operations unsafe. Called after every load and before every save.
    pub fn validate(self: *const ProjectManifest) ValidateError!void {
        if (!std.mem.eql(u8, self.format, DEFAULT_FORMAT)) return error.InvalidProjectFormat;
        if (self.version == 0 or self.version > MANIFEST_VERSION) return error.UnsupportedProjectVersion;
        if (self.project_id.isZero()) return error.InvalidProjectId;

        try path.validateVirtual(self.assets_dir);
        try path.validateVirtual(self.scenes_dir);
        try path.validateVirtual(self.generated_dir);
        try path.validateVirtual(self.cooked_assets_dir);
        try path.validateVirtual(self.asset_manifest);
        if (self.default_scene) |scene| try path.validateVirtual(scene);
    }

    pub fn assetsPath(self: *const ProjectManifest) []const u8 {
        return self.assets_dir;
    }

    pub fn cookedAssetsPath(self: *const ProjectManifest) []const u8 {
        return self.cooked_assets_dir;
    }

    pub fn assetManifestPath(self: *const ProjectManifest) []const u8 {
        return self.asset_manifest;
    }

    pub fn cloneOwned(self: *const ProjectManifest, allocator: std.mem.Allocator) !ProjectManifest {
        const format = try allocator.dupe(u8, self.format);
        errdefer allocator.free(format);
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const assets_dir = try allocator.dupe(u8, self.assets_dir);
        errdefer allocator.free(assets_dir);
        const scenes_dir = try allocator.dupe(u8, self.scenes_dir);
        errdefer allocator.free(scenes_dir);
        const generated_dir = try allocator.dupe(u8, self.generated_dir);
        errdefer allocator.free(generated_dir);
        const cooked_assets_dir = try allocator.dupe(u8, self.cooked_assets_dir);
        errdefer allocator.free(cooked_assets_dir);
        const asset_manifest = try allocator.dupe(u8, self.asset_manifest);
        errdefer allocator.free(asset_manifest);
        const default_scene = if (self.default_scene) |value| try allocator.dupe(u8, value) else null;
        errdefer if (default_scene) |value| allocator.free(value);

        return .{
            .format = format,
            .version = self.version,
            .name = name,
            .project_id = self.project_id,
            .assets_dir = assets_dir,
            .scenes_dir = scenes_dir,
            .generated_dir = generated_dir,
            .cooked_assets_dir = cooked_assets_dir,
            .asset_manifest = asset_manifest,
            .default_scene = default_scene,
        };
    }

    pub fn deinit(self: *ProjectManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.format);
        allocator.free(self.name);
        allocator.free(self.assets_dir);
        allocator.free(self.scenes_dir);
        allocator.free(self.generated_dir);
        allocator.free(self.cooked_assets_dir);
        allocator.free(self.asset_manifest);
        if (self.default_scene) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn save(self: *const ProjectManifest, allocator: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir) !void {
        try self.validate();

        var generated_dir = try root_dir.createDirPathOpen(io, self.generated_dir, .{});
        defer generated_dir.close(io);

        const bytes = try std.json.Stringify.valueAlloc(allocator, self, .{ .whitespace = .indent_2 });
        defer allocator.free(bytes);

        try atomic_file.writeFileAtomic(allocator, io, generated_dir, manifest_filename, bytes);
    }
};

fn readManifestBytes(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, normalized_path: []const u8) ![]u8 {
    try path.validateVirtual(normalized_path);
    return dir.readFileAlloc(io, normalized_path, allocator, .limited(max_manifest_bytes)) catch |err| switch (err) {
        error.StreamTooLong => {
            log.err("project manifest '{s}' exceeds {d} bytes; refusing to load", .{ normalized_path, max_manifest_bytes });
            return error.ProjectManifestTooLarge;
        },
        else => return err,
    };
}

const testing = std.testing;

const test_project_id = ProjectId.parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc");

test "ProjectManifest.save writes generated manifest file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest: ProjectManifest = .{
        .project_id = test_project_id,
    };

    try manifest.save(testing.allocator, testing.io, tmp.dir);

    const bytes = try tmp.dir.readFileAlloc(testing.io, ".fusion/fusion.proj", testing.allocator, .limited(4096));
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"project_id\": \"bf5a424f-e93e-4977-9a7a-0c522318dfdc\"") != null);

    const parsed = try std.json.parseFromSlice(ProjectManifest, testing.allocator, bytes, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(".fusion", parsed.value.generated_dir);
    try testing.expectEqualStrings("assets", parsed.value.assets_dir);
    try testing.expectEqualStrings(".fusion/cooked", parsed.value.cooked_assets_dir);
    try testing.expectEqualStrings(".fusion/assets.zmanifest", parsed.value.asset_manifest);
    try testing.expectEqualStrings("fusion.proj", parsed.value.format);
    try testing.expect(parsed.value.project_id.eql(test_project_id));
}

test "ProjectManifest.save never uses format as the filename" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest: ProjectManifest = .{
        .project_id = test_project_id,
        .format = "custom.proj",
    };
    try testing.expectError(error.InvalidProjectFormat, manifest.save(testing.allocator, testing.io, tmp.dir));
}

test "ProjectManifest round-trips through save and loadFromDir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest: ProjectManifest = .{
        .project_id = test_project_id,
        .asset_manifest = ".fusion/custom.zmanifest",
    };
    try manifest.save(testing.allocator, testing.io, tmp.dir);

    var loaded = try ProjectManifest.loadFromDir(testing.allocator, testing.io, tmp.dir, default_manifest_path);
    defer loaded.deinit(testing.allocator);
    try testing.expect(loaded.project_id.eql(test_project_id));
    try testing.expectEqualStrings(".fusion/custom.zmanifest", loaded.asset_manifest);
}

test "ProjectManifest.loadFromDir rejects invalid manifests" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "bad.proj",
        .data =
        \\{
        \\  "format": "custom.proj",
        \\  "project_id": "bf5a424f-e93e-4977-9a7a-0c522318dfdc"
        \\}
        ,
    });
    try testing.expectError(error.InvalidProjectFormat, ProjectManifest.loadFromDir(testing.allocator, testing.io, tmp.dir, "bad.proj"));
}

test "ProjectManifest parses project_id from canonical UUID text" {
    const bytes =
        \\{
        \\  "name": "Test Project",
        \\  "project_id": "00000000-0000-0000-0000-000000000000"
        \\}
    ;

    const parsed = try std.json.parseFromSlice(ProjectManifest, testing.allocator, bytes, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.project_id.eql(ProjectId.zero));
}

test "ProjectManifest.validate rejects bad identity and paths" {
    const valid: ProjectManifest = .{ .project_id = test_project_id };
    try valid.validate();

    var m = valid;
    m.format = "custom.proj";
    try testing.expectError(error.InvalidProjectFormat, m.validate());

    m = valid;
    m.version = 0;
    try testing.expectError(error.UnsupportedProjectVersion, m.validate());
    m.version = 99;
    try testing.expectError(error.UnsupportedProjectVersion, m.validate());

    m = valid;
    m.project_id = ProjectId.zero;
    try testing.expectError(error.InvalidProjectId, m.validate());

    m = valid;
    m.assets_dir = "/absolute/assets";
    try testing.expectError(error.AbsolutePathNotAllowed, m.validate());

    m = valid;
    m.cooked_assets_dir = "../escape/cooked";
    try testing.expectError(error.ParentTraversalNotAllowed, m.validate());
}

test "ProjectManifest cloneOwned owns all string fields" {
    const source: ProjectManifest = .{
        .name = "Test Project",
        .project_id = test_project_id,
        .assets_dir = "game-assets",
        .scenes_dir = "game-scenes",
        .generated_dir = ".cache",
        .cooked_assets_dir = ".cache/cooked",
        .asset_manifest = ".cache/assets.zmanifest",
        .default_scene = "game-scenes/main.scene",
    };
    var owned = try source.cloneOwned(testing.allocator);
    defer owned.deinit(testing.allocator);

    try testing.expectEqualStrings("fusion.proj", owned.format);
    try testing.expectEqualStrings("game-scenes/main.scene", owned.default_scene.?);
    try testing.expectEqualStrings(".cache/assets.zmanifest", owned.asset_manifest);
}

test "ProjectManifest path helpers expose configured asset roots" {
    const manifest: ProjectManifest = .{
        .name = "Test Project",
        .project_id = test_project_id,
        .assets_dir = "game-assets",
        .cooked_assets_dir = ".cache/cooked",
    };

    try testing.expectEqualStrings("game-assets", manifest.assetsPath());
    try testing.expectEqualStrings(".cache/cooked", manifest.cookedAssetsPath());
    try testing.expectEqualStrings(".fusion/assets.zmanifest", manifest.assetManifestPath());
}
