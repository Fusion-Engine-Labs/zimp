const std = @import("std");
const builtin = @import("builtin");

const log = @import("logger.zig");

const Command = @import("commands/command.zig").Command;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

/// Debug uses Zig's instrumented process services. Release builds construct
/// only the throughput-oriented services needed by the cooker.
const ProcessInit = if (builtin.mode == .debug) std.process.Init else std.process.Init.Minimal;
const performance_allocator = if (builtin.single_threaded) std.heap.c_allocator else std.heap.smp_allocator;

pub fn main(init: ProcessInit) !void {
    if (comptime builtin.mode == .debug) {
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        return run(init.gpa, init.io, args);
    }

    var arena = std.heap.ArenaAllocator.init(performance_allocator);
    defer arena.deinit();

    var io = std.Io.Threaded.init(performance_allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer io.deinit();

    const args = try init.args.toSlice(arena.allocator());
    return run(performance_allocator, io.io(), args);
}

fn run(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    if (args.len < 2) {
        log.err("Not enough arguments, must provide a command of 'cook', 'pack', or 'inspect'", .{});
        std.process.exit(1);
    }

    const command = Command.parse(allocator, io, args) catch |err| {
        log.err("Failed to parse command: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer command.deinit();

    const progress_node = std.Progress.start(io, .{});
    defer progress_node.end();

    command.run(progress_node) catch |err| {
        log.err("Command '{s}' failed: {s}", .{ command.toString(), @errorName(err) });
        std.process.exit(1);
    };
}
