const builtin = @import("builtin");
const std = @import("std");

const linux = std.os.linux;

const Snapshot = @import("snapshot.zig");
const log = @import("../logger.zig");

pub const WaitResult = enum {
    timeout, // no activity within duration
    activity, // OS-reported activity
    canceled, // future was cancelled
};

pub const WakeSource = switch (builtin.os.tag) {
    .linux => InotifyWake,
    else => TimerWake,
};

pub const TimerWake = struct {
    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir) TimerWake {
        _ = gpa;
        _ = io;
        _ = root;
        return .{};
    }

    pub fn deinit(self: *TimerWake) void {
        self.* = undefined;
    }

    pub fn sync(self: *TimerWake, snapshot: *const Snapshot) void {
        _ = self;
        _ = snapshot;
    }

    pub fn wait(self: *TimerWake, io: std.Io, timeout: std.Io.Duration) WaitResult {
        _ = self;
        io.sleep(timeout, .awake) catch return .canceled;
        return .timeout;
    }
};

pub const InotifyWake = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    root_path: []const u8,
    watches: std.StringHashMapUnmanaged(i32),

    // events to listen for
    const mask: u32 =
        linux.IN.CLOSE_WRITE | linux.IN.CREATE | linux.IN.DELETE |
        linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.DELETE_SELF |
        linux.IN.MOVE_SELF | linux.IN.ONLYDIR;

    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir) InotifyWake {
        var self: InotifyWake = .{
            .gpa = gpa,
            .fd = -1,
            .root_path = "",
            .watches = .empty,
        };

        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => self.fd = @intCast(rc),
            else => |err| {
                log.warn("watch: inotify unavailable ({t}); failling back to timer polling", .{err});
                return self;
            },
        }

        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = root.realPathFile(io, ".", &buf) catch |err| {
            log.warn("watch: cannot resolve asset roots ({s}); failling back to timer polling", .{@errorName(err)});
            self.degrade();
            return self;
        };
        self.root_path = gpa.dupe(u8, buf[0..len]) catch {
            self.degrade();
            return self;
        };

        return self;
    }

    pub fn deinit(self: *InotifyWake) void {
        self.degrade();
        self.* = undefined;
    }

    pub fn sync(self: *InotifyWake, snapshot: *const Snapshot) void {
        if (self.fd == -1) {
            return;
        }

        var dir_iter = snapshot.dirs.keyIterator();
        while (dir_iter.next()) |rel| {
            if (self.watches.contains(rel.*)) {
                continue;
            }

            self.addWatch(rel.*) catch |err| {
                log.err("watch: inotify add '{s}' failed: {s}", .{ rel.*, @errorName(err) });
            };
        }
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.gpa);
        var watch_iter = self.watches.iterator();
        while (watch_iter.next()) |entry| {
            if (snapshot.dirs.contains(entry.key_ptr.*)) {
                continue;
            }

            _ = linux.inotify_rm_watch(self.fd, entry.value_ptr.*);
            stale.append(self.gpa, entry.key_ptr.*) catch continue;
        }

        for (stale.items) |key| {
            const kv = self.watches.fetchRemove(key).?;
            self.gpa.free(kv.key);
        }
    }

    pub fn wait(self: *InotifyWake, io: std.Io, timeout: std.Io.Duration) WaitResult {
        if (self.fd == -1) {
            io.sleep(timeout, .awake) catch return .canceled;
            return .timeout;
        }

        var fds = [1]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const ms: i32 = @intCast(std.math.clamp(timeout.toMilliseconds(), 1, std.math.maxInt(i32)));
        const n = std.posix.poll(&fds, ms) catch |err| {
            log.err("watch: poll on inotify fd failed ({s}); falling back to timer polling", .{@errorName(err)});
            self.degrade();
            return .timeout;
        };

        if (n == 0) {
            return .timeout;
        }

        self.drainEvents();
        return .activity;
    }

    fn degrade(self: *InotifyWake) void {
        if (self.fd != -1) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }

        var iter = self.watches.keyIterator();
        while (iter.next()) |key| {
            self.gpa.free(key.*);
        }

        self.watches.deinit(self.gpa);
        self.watches = .empty;

        if (self.root_path.len > 0) {
            self.gpa.free(self.root_path);
            self.root_path = "";
        }
    }

    fn drainEvents(self: *InotifyWake) void {
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const n = std.posix.read(self.fd, &buf) catch {
                return;
            };

            if (n == 0) {
                return;
            }
        }
    }

    fn addWatch(self: *InotifyWake, rel: []const u8) !void {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const abs = if (rel.len == 0)
            try std.fmt.bufPrintSentinel(&path_buf, "{s}", .{self.root_path}, '\x00')
        else
            try std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ self.root_path, rel }, '\x00');

        const rc = linux.inotify_add_watch(self.fd, abs.ptr, mask);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                log.err("watch: inotify_add_watch('{s}') failed: {t}", .{ abs, err });
                return error.AddWatchFailed;
            },
        }

        const key = try self.gpa.dupe(u8, rel);
        errdefer self.gpa.free(key);

        try self.watches.put(self.gpa, key, @intCast(rc));
    }
};

const testing = std.testing;

test "TimerWake waits until its timeout" {
    var wake = TimerWake.init(testing.allocator, testing.io, std.Io.Dir.cwd());
    defer wake.deinit();

    try testing.expectEqual(WaitResult.timeout, wake.wait(testing.io, .fromMilliseconds(1)));
}

test "InotifyWake reports activity and drains queued events" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "shaders");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shaders/a.vert", .data = "x" });

    const dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);
    var snapshot = try Snapshot.capture(testing.allocator, testing.io, dir);
    defer snapshot.deinit();

    var wake = InotifyWake.init(testing.allocator, testing.io, dir);
    defer wake.deinit();
    if (wake.fd == -1) return error.SkipZigTest;

    wake.sync(&snapshot);
    try testing.expectEqual(@as(usize, 2), wake.watches.count());

    // Queue the event before waiting to avoid a timing-dependent test.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shaders/a.vert", .data = "updated" });
    try testing.expectEqual(WaitResult.activity, wake.wait(testing.io, .fromSeconds(2)));
    try testing.expectEqual(WaitResult.timeout, wake.wait(testing.io, .fromMilliseconds(1)));
}

test "InotifyWake sync adds and removes directory watches" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "old");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "old/a.obj", .data = "v 0 0 0" });

    const dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);
    var wake = InotifyWake.init(testing.allocator, testing.io, dir);
    defer wake.deinit();
    if (wake.fd == -1) return error.SkipZigTest;

    var before = try Snapshot.capture(testing.allocator, testing.io, dir);
    defer before.deinit();
    wake.sync(&before);
    try testing.expectEqual(@as(usize, 2), wake.watches.count());

    try tmp.dir.deleteTree(testing.io, "old");
    var after = try Snapshot.capture(testing.allocator, testing.io, dir);
    defer after.deinit();
    wake.sync(&after);
    try testing.expectEqual(@as(usize, 1), wake.watches.count());
    try testing.expect(wake.watches.contains(""));
}

test "degraded InotifyWake falls back to timeout polling" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var wake: InotifyWake = .{
        .gpa = testing.allocator,
        .fd = -1,
        .root_path = "",
        .watches = .empty,
    };
    defer wake.deinit();

    try testing.expectEqual(WaitResult.timeout, wake.wait(testing.io, .fromMilliseconds(1)));
}
