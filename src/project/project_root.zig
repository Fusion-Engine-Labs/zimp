const std = @import("std");
const path = @import("../path.zig");
const manifest_mod = @import("manifest.zig");
const ProjectManifest = manifest_mod.ProjectManifest;

/// An opened project: owns the root directory handle, an arena holding every
/// manifest string, and path resolution helpers. This is the supported owner
/// of a loaded `ProjectManifest` — teardown is one arena deinit, with no
/// per-field ownership tracking.
pub const ProjectRoot = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    /// Absolute or cwd-relative filesystem path of the project root.
    root_path: []const u8,
    root_dir: std.Io.Dir,
    manifest: ProjectManifest,

    /// `root_fs_path` is the directory that contains `.fusion/fusion.proj`.
    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        root_fs_path: []const u8,
    ) !ProjectRoot {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const root_dir = std.Io.Dir.cwd().openDir(io, root_fs_path, .{ .iterate = true }) catch
            return error.ProjectNotFound;
        errdefer root_dir.close(io);

        const manifest = try ProjectManifest.loadFromDirLeaky(alloc, io, root_dir, manifest_mod.default_manifest_path);

        var real_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const real_path_len = try root_dir.realPathFile(io, ".", &real_path_buf);

        return .{
            .arena = arena,
            .io = io,
            .root_path = try alloc.dupe(u8, real_path_buf[0..real_path_len]),
            .root_dir = root_dir,
            .manifest = manifest,
        };
    }

    pub fn deinit(self: *ProjectRoot) void {
        self.root_dir.close(self.io);
        self.arena.deinit();
    }

    /// Open a manifest-declared directory relative to the project root.
    pub fn openDir(self: *const ProjectRoot, virtual_dir: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
        try path.validateVirtual(virtual_dir);
        return self.root_dir.openDir(self.io, virtual_dir, options);
    }

    /// Create-if-missing variant for generated directories.
    pub fn makeOpenDir(self: *const ProjectRoot, virtual_dir: []const u8) !std.Io.Dir {
        try path.validateVirtual(virtual_dir);
        return self.root_dir.createDirPathOpen(self.io, virtual_dir, .{ .open_options = .{ .iterate = true } });
    }

    /// Join the project root with a manifest-relative virtual path.
    /// Caller owns the returned slice (allocated from `allocator`).
    pub fn resolve(self: *const ProjectRoot, allocator: std.mem.Allocator, virtual_path: []const u8) ![]u8 {
        try path.validateVirtual(virtual_path);
        return std.fs.path.join(allocator, &.{ self.root_path, virtual_path });
    }
};

const testing = std.testing;

test "ProjectRoot opens a project and resolves manifest directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest: ProjectManifest = .{
        .name = "Root Test Project",
        .project_id = .parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
    };
    try manifest.save(testing.allocator, testing.io, tmp.dir);

    var real_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path_len = try tmp.dir.realPathFile(testing.io, ".", &real_path_buf);
    const root_path = real_path_buf[0..real_path_len];

    var root = try ProjectRoot.open(testing.allocator, testing.io, root_path);
    defer root.deinit();

    try testing.expectEqualStrings("Root Test Project", root.manifest.name);
    try testing.expectEqualStrings(root_path, root.root_path);

    var cooked = try root.makeOpenDir(root.manifest.cooked_assets_dir);
    defer cooked.close(testing.io);
    try cooked.writeFile(testing.io, .{ .sub_path = "probe.bin", .data = "x" });

    const probe = try tmp.dir.readFileAlloc(testing.io, ".fusion/cooked/probe.bin", testing.allocator, .limited(16));
    defer testing.allocator.free(probe);
    try testing.expectEqualStrings("x", probe);

    const resolved = try root.resolve(testing.allocator, root.manifest.asset_manifest);
    defer testing.allocator.free(resolved);
    try testing.expect(std.mem.endsWith(u8, resolved, ".fusion/assets.zmanifest"));
}

test "ProjectRoot.open fails on a directory without a manifest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var real_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path_len = try tmp.dir.realPathFile(testing.io, ".", &real_path_buf);
    const root_path = real_path_buf[0..real_path_len];

    try testing.expectError(error.FileNotFound, ProjectRoot.open(testing.allocator, testing.io, root_path));
}
