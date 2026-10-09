const std = @import("std");

const packer = @import("pack/packer.zig");
const zstd = @import("../shared/zstd.zig");
const path = @import("../path.zig");
const ProjectRoot = @import("../project/project_root.zig").ProjectRoot;
const Cache = @import("../cache/cache.zig").Cache;
const manifest_builder = @import("../manifest/builder.zig");
const manifest_codec = @import("../manifest/codec.zig");
const model = @import("../manifest/model.zig");
const AssetKind = @import("../assets/asset.zig").AssetKind;
const cook_metrics = @import("cook_metrics.zig");
const log = @import("../logger.zig");

pub const PackError = error{
    NotEnoughArguments,
    ConflictingFlags,
    SourceDirNotFound,
    ProjectOpenFailed,
    MissingFlagValue,
    UnknownFlag,
    DuplicateFlag,
    InvalidLevel,
};

/// `zimp pack --project <root> [--output <file>]` packs the project's cooked
/// assets, as listed by its `asset_manifest`, into its `asset_pack` (or
/// `--output`). `zimp pack --source <cooked_dir> --output <file>` packs a
/// directory-mode cook, listed by the `.zcache` in that directory.
pub const PackCommand = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    input: Input,
    /// `--output`, relative to the working directory. A project defaults to
    /// its `asset_pack`, relative to the project root.
    output: ?[]const u8 = null,
    options: packer.Options = .{},

    pub const Input = union(enum) {
        project: *ProjectRoot,
        source: std.Io.Dir,
    };

    pub fn parseFromArgs(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) PackError!PackCommand {
        var source_arg: ?[]const u8 = null;
        var project_arg: ?[]const u8 = null;
        var output_arg: ?[]const u8 = null;
        var level_arg: ?[]const u8 = null;
        var compress = true;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const flag = args[i];
            if (std.mem.eql(u8, "--no-compress", flag)) {
                if (!compress) return PackError.DuplicateFlag;
                compress = false;
                continue;
            }
            const slot: *?[]const u8 = if (std.mem.eql(u8, "--source", flag))
                &source_arg
            else if (std.mem.eql(u8, "--project", flag))
                &project_arg
            else if (std.mem.eql(u8, "--output", flag))
                &output_arg
            else if (std.mem.eql(u8, "--level", flag))
                &level_arg
            else {
                log.err("pack: unknown flag '{s}'", .{flag});
                return PackError.UnknownFlag;
            };
            if (slot.* != null) return PackError.DuplicateFlag;
            if (i + 1 >= args.len) {
                log.err("pack: missing value for {s}", .{flag});
                return PackError.MissingFlagValue;
            }
            slot.* = args[i + 1];
            i += 1;
        }

        var options: packer.Options = .{ .compress = compress };
        if (level_arg) |text| {
            options.level = std.fmt.parseInt(i32, text, 10) catch return PackError.InvalidLevel;
            if (options.level < 1 or options.level > zstd.max_level) {
                log.err("pack: --level must be 1-{d}, got '{s}'", .{ zstd.max_level, text });
                return PackError.InvalidLevel;
            }
        }

        if (project_arg != null and source_arg != null) {
            log.err("pack: --project and --source are mutually exclusive", .{});
            return PackError.ConflictingFlags;
        }
        if (project_arg) |project_path| {
            const root = allocator.create(ProjectRoot) catch return PackError.ProjectOpenFailed;
            root.* = ProjectRoot.open(allocator, io, project_path) catch |err| {
                allocator.destroy(root);
                log.err("pack: failed to open project '{s}': {s}. The directory must contain .fusion/fusion.proj", .{ project_path, @errorName(err) });
                return PackError.ProjectOpenFailed;
            };
            return .{ .allocator = allocator, .io = io, .input = .{ .project = root }, .output = output_arg, .options = options };
        }
        const source_path = source_arg orelse {
            log.err("pack: usage: zimp pack --project <root> [--output <file>] | --source <cooked_dir> --output <file> [--level 1-22] [--no-compress]", .{});
            return PackError.NotEnoughArguments;
        };
        if (output_arg == null) {
            log.err("pack: --source needs --output <file>", .{});
            return PackError.NotEnoughArguments;
        }
        const source = std.Io.Dir.cwd().openDir(io, source_path, .{}) catch |err| {
            log.err("pack: failed to open source directory '{s}': {s}", .{ source_path, @errorName(err) });
            return PackError.SourceDirNotFound;
        };
        return .{ .allocator = allocator, .io = io, .input = .{ .source = source }, .output = output_arg, .options = options };
    }

    pub fn run(self: *const PackCommand) !void {
        const gpa = self.allocator;
        const io = self.io;
        const start = std.Io.Clock.Timestamp.now(io, .awake);

        var manifest = switch (self.input) {
            .project => |root| try manifest_codec.loadFromDir(gpa, io, root.root_dir, root.manifest.asset_manifest),
            .source => |dir| try manifestFromCache(gpa, io, dir),
        };
        defer manifest.deinit();

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const inputs = try arena.allocator().alloc(packer.Input, manifest.entries.len);
        for (manifest.entries, inputs) |entry, *input| {
            input.* = .{ .id = entry.id, .kind = entry.kind, .path = try path.normalizeVirtual(arena.allocator(), entry.cooked_path) };
        }

        const cwd = std.Io.Dir.cwd();
        const cooked_dir, const out_dir, const out_path = switch (self.input) {
            .project => |root| .{
                try root.openDir(root.manifest.cooked_assets_dir, .{}),
                if (self.output != null) cwd else root.root_dir,
                self.output orelse root.manifest.asset_pack,
            },
            .source => |dir| .{ dir, cwd, self.output.? },
        };
        var options = self.options;
        options.allow_missing_builtins = self.input == .source;
        defer if (self.input == .project) cooked_dir.close(io);

        const stats = try packer.writeFile(gpa, io, cooked_dir, inputs, out_dir, out_path, options);
        const elapsed: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        logSummary(out_path, &stats, elapsed);
    }

    pub fn deinit(self: *const PackCommand) void {
        switch (self.input) {
            .project => |root| {
                root.deinit();
                self.allocator.destroy(root);
            },
            .source => |dir| dir.close(self.io),
        }
    }
};

/// A directory-mode cook writes no manifest, but its `.zcache` lists every
/// cooked asset, and the manifest builder derives the same ids from it that
/// the cook embedded in references.
fn manifestFromCache(gpa: std.mem.Allocator, io: std.Io, cooked_dir: std.Io.Dir) !model.AssetManifest {
    var cache = Cache.readFile(gpa, io, cooked_dir, ".zcache") catch |err| {
        log.err("pack: cannot read '.zcache' in the source directory ({s}); --source must be a `zimp cook` output", .{@errorName(err)});
        return err;
    };
    defer cache.deinit(gpa);
    var stats: manifest_builder.BuildStats = .{};
    return manifest_builder.build(gpa, .{ .project_id = cache.project_id, .cache = &cache }, &stats);
}

fn logSummary(out_path: []const u8, stats: *const packer.Stats, elapsed_ns: u64) void {
    const total = stats.total();
    var duration_buf: [32]u8 = undefined;
    log.info("Packed {d} assets into '{s}' in {s}: {d} -> {d} bytes ({d} zstd)", .{
        total.entries,
        out_path,
        cook_metrics.fmtDuration(elapsed_ns, &duration_buf),
        total.asset_bytes,
        stats.file_bytes,
        total.compressed,
    });
    for (stats.kinds, 0..) |kind, k| {
        if (kind.entries == 0) continue;
        log.info("  {s}: {d} assets ({d} zstd), {d} -> {d} bytes", .{
            @tagName(@as(AssetKind, @enumFromInt(k))),
            kind.entries,
            kind.compressed,
            kind.asset_bytes,
            kind.stored_bytes,
        });
    }
}

const testing = std.testing;
const PackStore = @import("../runtime.zig").PackStore;
const CookCommand = @import("cook_command.zig").CookCommand;
const project_manifest = @import("../project/manifest.zig");

test {
    _ = @import("pack/packer.zig");
}

fn parse(args: []const [:0]const u8) PackError!PackCommand {
    return PackCommand.parseFromArgs(testing.allocator, testing.io, args);
}

test "PackCommand.parseFromArgs requires a project or a source with an output" {
    try testing.expectError(PackError.NotEnoughArguments, parse(&.{ "zimp", "pack" }));
    try testing.expectError(PackError.NotEnoughArguments, parse(&.{ "zimp", "pack", "--source", "." }));
    try testing.expectError(PackError.NotEnoughArguments, parse(&.{ "zimp", "pack", "--output", "x.zpak" }));
    try testing.expectError(PackError.ConflictingFlags, parse(&.{ "zimp", "pack", "--project", ".", "--source", "." }));
    try testing.expectError(PackError.SourceDirNotFound, parse(&.{ "zimp", "pack", "--source", "nonexistent_dir_abc123", "--output", "x.zpak" }));
    try testing.expectError(PackError.ProjectOpenFailed, parse(&.{ "zimp", "pack", "--project", "nonexistent_dir_abc123" }));
}

test "PackCommand.parseFromArgs rejects bad flags and values" {
    try testing.expectError(PackError.MissingFlagValue, parse(&.{ "zimp", "pack", "--source", ".", "--output" }));
    try testing.expectError(PackError.UnknownFlag, parse(&.{ "zimp", "pack", "--source", ".", "--fast" }));
    try testing.expectError(PackError.DuplicateFlag, parse(&.{ "zimp", "pack", "--source", ".", "--source", "." }));
    try testing.expectError(PackError.DuplicateFlag, parse(&.{ "zimp", "pack", "--no-compress", "--no-compress" }));
    try testing.expectError(PackError.InvalidLevel, parse(&.{ "zimp", "pack", "--source", ".", "--output", "x", "--level", "0" }));
    try testing.expectError(PackError.InvalidLevel, parse(&.{ "zimp", "pack", "--source", ".", "--output", "x", "--level", "23" }));
    try testing.expectError(PackError.InvalidLevel, parse(&.{ "zimp", "pack", "--source", ".", "--output", "x", "--level", "max" }));
}

test "PackCommand.parseFromArgs reads source, output, level, and --no-compress in any order" {
    const cmd = try parse(&.{ "zimp", "pack", "--no-compress", "--output", "x.zpak", "--level", "7", "--source", "." });
    defer cmd.deinit();
    try testing.expect(cmd.input == .source);
    try testing.expectEqualStrings("x.zpak", cmd.output.?);
    try testing.expectEqual(@as(i32, 7), cmd.options.level);
    try testing.expect(!cmd.options.compress);
}

fn realPath(dir: std.Io.Dir) ![:0]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPathFile(testing.io, ".", &buf);
    return testing.allocator.dupeZ(u8, buf[0..len]);
}

test "pack --source packs a directory-mode cook that loads back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src/shaders");
    try tmp.dir.createDirPath(testing.io, "cooked");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/shaders/tri.vert", .data = "#version 410 core\nvoid main() { gl_Position = vec4(0.0); }\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/shaders/tri.frag", .data = "#version 410 core\nout vec4 c;\nvoid main() { c = vec4(1.0); }\n" });

    const root = try realPath(tmp.dir);
    defer testing.allocator.free(root);
    const src = try std.fs.path.joinZ(testing.allocator, &.{ root, "src" });
    defer testing.allocator.free(src);
    const cooked = try std.fs.path.joinZ(testing.allocator, &.{ root, "cooked" });
    defer testing.allocator.free(cooked);
    const out = try std.fs.path.joinZ(testing.allocator, &.{ root, "build/assets.zpak" });
    defer testing.allocator.free(out);

    {
        const cook = try CookCommand.parseFromArgs(testing.allocator, testing.io, &.{ "zimp", "cook", "--source", src, "--output", cooked });
        defer cook.deinit();
        try cook.run(.none);
    }
    {
        const pack = try parse(&.{ "zimp", "pack", "--source", cooked, "--output", out });
        defer pack.deinit();
        try pack.run();
    }

    var store = try PackStore.open(testing.io, tmp.dir, "build/assets.zpak");
    defer store.close(testing.io);
    try testing.expectEqual(@as(u32, 2), store.pak.count());
    var names: [2][]const u8 = undefined;
    for (&names, 0..) |*name, i| {
        var asset = try store.load(testing.allocator, testing.io, @intCast(i));
        defer asset.deinit(testing.allocator);
        try testing.expect(asset.view == .shader);
        name.* = store.pak.nameAt(@intCast(i));
    }
    // Entries are in id order, not name order.
    std.mem.sort([]const u8, &names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    try testing.expectEqualStrings("shaders/tri.frag.zshdr", names[0]);
    try testing.expectEqualStrings("shaders/tri.vert.zshdr", names[1]);
}

test "pack --project writes the manifest's asset_pack with builtins included" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project: project_manifest.ProjectManifest = .{
        .project_id = .parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
        .asset_pack = "dist/game.zpak",
    };
    try project.save(testing.allocator, testing.io, tmp.dir);
    try tmp.dir.createDirPath(testing.io, "assets/shaders");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/shaders/tri.vert", .data = "#version 410 core\nvoid main() { gl_Position = vec4(0.0); }\n" });

    const root = try realPath(tmp.dir);
    defer testing.allocator.free(root);
    {
        const cook = try CookCommand.parseFromArgs(testing.allocator, testing.io, &.{ "zimp", "cook", "--project", root });
        defer cook.deinit();
        try cook.run(.none);
    }
    {
        const pack = try parse(&.{ "zimp", "pack", "--project", root });
        defer pack.deinit();
        try pack.run();
    }

    var manifest = try manifest_codec.loadFromDir(testing.allocator, testing.io, tmp.dir, project.asset_manifest);
    defer manifest.deinit();
    var store = try PackStore.open(testing.io, tmp.dir, "dist/game.zpak");
    defer store.close(testing.io);
    try testing.expectEqual(@as(u32, @intCast(manifest.entries.len)), store.pak.count());
    for (manifest.entries) |entry| {
        const index = store.pak.findKind(entry.kind, entry.id).?;
        var asset = try store.load(testing.allocator, testing.io, index);
        defer asset.deinit(testing.allocator);
    }
}
