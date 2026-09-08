const std = @import("std");

const ProjectManifest = @import("../project/manifest.zig").ProjectManifest;
const CookContext = @import("../commands/cook/context.zig").CookContext;
const watcher_mod = @import("watcher.zig");

const WatchOptions = watcher_mod.Options;
const CookResult = watcher_mod.CookResult;
const Callback = watcher_mod.Callback;

const Watcher = watcher_mod.Watcher;
const WatcherRunResult = @typeInfo(@TypeOf(Watcher.run)).@"fn".return_type.?;

pub const WaitForInitialCookError = error{
    InitialCookFailed,
};

const WatchHandle = @This();

gpa: std.mem.Allocator,
io: std.Io,
project: *const ProjectManifest,
source: std.Io.Dir,
output: std.Io.Dir,
output_path: [:0]const u8,
watcher: Watcher,
future: std.Io.Future(WatcherRunResult),

pub fn stop(self: *WatchHandle) void {
    self.watcher.stop();

    _ = self.future.cancel(self.io) catch {};
    self.watcher.deinit();

    self.source.close(self.io);
    self.output.close(self.io);
    self.gpa.free(self.output_path);

    const gpa = self.gpa;
    gpa.destroy(self);
}

pub fn waitForInitialCook(self: *const WatchHandle) !void {
    while (true) {
        switch (self.watcher.initialCookState()) {
            .pending => try self.io.sleep(.fromMilliseconds(10), .awake),
            .succeeded => return,
            .failed => return WaitForInitialCookError.InitialCookFailed,
        }
    }
}

pub fn start(
    /// Must be thread-safe: cooking work is dispatched concurrently.
    gpa: std.mem.Allocator,
    io: std.Io,
    project: *const ProjectManifest,
    root_dir: std.Io.Dir,
    options: WatchOptions,
    callback: Callback,
) !*WatchHandle {
    const handle = try gpa.create(WatchHandle);
    errdefer gpa.destroy(handle);

    handle.gpa = gpa;
    handle.io = io;
    handle.project = project;

    handle.source = try root_dir.openDir(io, handle.project.assets_dir, .{ .iterate = true });
    errdefer handle.source.close(io);

    handle.output = try root_dir.createDirPathOpen(io, handle.project.cooked_assets_dir, .{ .open_options = .{ .iterate = true } });
    errdefer handle.output.close(io);

    handle.output_path = try root_dir.realPathFileAlloc(io, handle.project.cooked_assets_dir, gpa);
    errdefer gpa.free(handle.output_path);

    const ctx: CookContext = .{
        .io = io,
        .source = handle.source,
        .output = handle.output,
        .output_path = handle.output_path,
        .force = false,
        .project = .{
            .project_id = handle.project.project_id,
            .root_dir = root_dir,
            .manifest_path = handle.project.asset_manifest,
        },
    };

    handle.watcher = Watcher.init(gpa, io, ctx, options, callback);
    handle.future = try std.Io.concurrent(io, Watcher.run, .{&handle.watcher});

    return handle;
}

const testing = std.testing;
const ProjectId = @import("../id/id_types.zig").ProjectId;

const TestObserver = struct {
    calls: std.atomic.Value(usize) = .init(0),

    fn onCook(ctx: ?*anyopaque, result: watcher_mod.CookResult) void {
        _ = result;
        const self: *TestObserver = @ptrCast(@alignCast(ctx.?));
        _ = self.calls.fetchAdd(1, .monotonic);
    }

    fn callback(self: *TestObserver) Callback {
        return .{ .ctx = self, .on_cook = onCook };
    }
};

fn waitForCalls(observer: *const TestObserver, expected: usize) !void {
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        if (observer.calls.load(.acquire) >= expected) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.TimedOut;
}

fn testProject(tmp: testing.TmpDir) !ProjectManifest {
    const manifest: ProjectManifest = .{
        .project_id = ProjectId.parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
    };
    try manifest.save(testing.allocator, testing.io, tmp.dir);
    try tmp.dir.createDirPath(testing.io, "assets");
    return manifest.cloneOwned(testing.allocator);
}

test "WatchHandle starts an initial cook and creates the output directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project = try testProject(tmp);
    defer project.deinit(testing.allocator);

    var observer = TestObserver{};
    const handle = try start(testing.allocator, testing.io, &project, tmp.dir, .{
        .poll_interval = .fromMilliseconds(10),
        .debounce = .fromMilliseconds(5),
        .debounce_Max = .fromMilliseconds(100),
    }, observer.callback());

    try handle.waitForInitialCook();
    try testing.expectEqual(@as(usize, 1), observer.calls.load(.acquire));
    try tmp.dir.access(testing.io, ".fusion/cooked", .{});

    handle.stop();
}

test "WatchHandle reports an unsuccessful initial cook" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project = try testProject(tmp);
    defer project.deinit(testing.allocator);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/bad.jpg", .data = "not a JPEG" });

    const handle = try start(testing.allocator, testing.io, &project, tmp.dir, .{}, .{});
    defer handle.stop();

    try testing.expectError(WaitForInitialCookError.InitialCookFailed, handle.waitForInitialCook());
}

test "WatchHandle.start propagates a missing asset directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest: ProjectManifest = .{
        .project_id = ProjectId.parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
    };
    try manifest.save(testing.allocator, testing.io, tmp.dir);

    var project = try manifest.cloneOwned(testing.allocator);
    defer project.deinit(testing.allocator);
    try testing.expectError(error.FileNotFound, start(testing.allocator, testing.io, &project, tmp.dir, .{}, .{}));
}
