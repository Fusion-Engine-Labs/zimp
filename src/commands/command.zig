const std = @import("std");

const CookError = @import("cook_command.zig").CookError;
const PackError = @import("pack_command.zig").PackError;
const InspectError = @import("inspect_command.zig").InspectError;
const log = @import("../logger.zig");

const CookCommand = @import("cook_command.zig").CookCommand;
const PackCommand = @import("pack_command.zig").PackCommand;
const InspectCommand = @import("inspect_command.zig").InspectCommand;

pub const CommandError = error{
    UnknownCommand,
};

pub const Command = union(enum) {
    cook: CookCommand,
    pack: PackCommand,
    inspect: InspectCommand,

    pub fn parse(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) (CommandError || CookError || PackError || InspectError)!Command {
        if (args.len < 2) return CommandError.UnknownCommand;
        if (std.mem.eql(u8, args[1], "cook")) {
            const cmd = CookCommand.parseFromArgs(allocator, io, args) catch |err| {
                log.err("command: failed to parse 'cook' subcommand: {s}", .{@errorName(err)});
                return err;
            };
            return .{ .cook = cmd };
        }

        if (std.mem.eql(u8, args[1], "pack")) {
            const cmd = PackCommand.parseFromArgs(allocator, io, args) catch |err| {
                log.err("command: failed to parse 'pack' subcommand: {s}", .{@errorName(err)});
                return err;
            };
            return .{ .pack = cmd };
        }

        if (std.mem.eql(u8, args[1], "inspect")) {
            const cmd = InspectCommand.parseFromArgs(allocator, io, args) catch |err| {
                log.err("command: failed to parse 'inspect' subcommand: {s}", .{@errorName(err)});
                return err;
            };
            return .{ .inspect = cmd };
        }

        log.err("command: unknown command '{s}'. Available commands are: 'cook', 'pack', 'inspect'", .{args[1]});
        return CommandError.UnknownCommand;
    }

    pub fn run(self: Command, progress: std.Progress.Node) !void {
        return switch (self) {
            .cook => |cmd| cmd.run(progress),
            .pack => |cmd| cmd.run(),
            .inspect => |cmd| cmd.run(),
        };
    }

    pub fn toString(self: Command) []const u8 {
        return switch (self) {
            .cook => "cook",
            .pack => "pack",
            .inspect => "inspect",
        };
    }

    pub fn deinit(self: Command) void {
        return switch (self) {
            .cook => |cmd| cmd.deinit(),
            .pack => |cmd| cmd.deinit(),
            .inspect => |cmd| cmd.deinit(),
        };
    }
};

const testing = std.testing;
const writeTestZmeshFile = @import("../formats/zmesh.zig").writeTestZmeshFile;

test {
    _ = @import("cook_command.zig");
    _ = @import("pack_command.zig");
    _ = @import("inspect_command.zig");
}

test "Command.parse errors with UnknownCommand for unrecognized command" {
    const args: []const [:0]const u8 = &.{ "zimp", "unknown" };
    const result = Command.parse(testing.allocator, testing.io, args);
    try testing.expectError(CommandError.UnknownCommand, result);
}

test "Command.parse errors with UnknownCommand for empty command string" {
    const args: []const [:0]const u8 = &.{ "zimp", "" };
    const result = Command.parse(testing.allocator, testing.io, args);
    try testing.expectError(CommandError.UnknownCommand, result);
}

test "Command.parse routes to Cook variant" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const cmd = try Command.parse(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expect(std.meta.activeTag(cmd) == .cook);
    try testing.expectEqualStrings("cook", cmd.toString());
}

test "Command.parse routes to Pack variant" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "x.zpak" };
    const cmd = try Command.parse(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expect(std.meta.activeTag(cmd) == .pack);
    try testing.expectEqualStrings("pack", cmd.toString());
}

test "Command.parse routes to Inspect variant" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try Command.parse(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expect(std.meta.activeTag(cmd) == .inspect);
    try testing.expectEqualStrings("inspect", cmd.toString());
}

test "Command.parse propagates CookError.NotEnoughArguments" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook" };
    const result = Command.parse(testing.allocator, testing.io, args);
    try testing.expectError(CookError.NotEnoughArguments, result);
}

test "Command.parse propagates PackError.NotEnoughArguments" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack" };
    const result = Command.parse(testing.allocator, testing.io, args);
    try testing.expectError(PackError.NotEnoughArguments, result);
}

test "Command.parse propagates InspectError.NotEnoughArguments" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect" };
    const result = Command.parse(testing.allocator, testing.io, args);
    try testing.expectError(InspectError.NotEnoughArguments, result);
}

test "Command.parse propagates CookError.SourceDirNotFound" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", "nonexistent_dir_abc123", "--output", "." };
    const result = Command.parse(testing.allocator, testing.io, args);
    try testing.expectError(CookError.SourceDirNotFound, result);
}

test "Command.parse propagates InspectError.FileNotFound" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "nonexistent_file_abc123.txt" };
    const result = Command.parse(testing.allocator, testing.io, args);
    try testing.expectError(InspectError.FileNotFound, result);
}

test "Command.run dispatches to correct subcommand" {
    var source_tmp = testing.tmpDir(.{});
    defer source_tmp.cleanup();
    var output_tmp = testing.tmpDir(.{});
    defer output_tmp.cleanup();
    const source_dir = try source_tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    const output_dir = try output_tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    const cook: Command = .{ .cook = .{
        .source = source_dir,
        .output = output_dir,
        .io = testing.io,
        .allocator = testing.allocator,
    } };
    defer cook.deinit();
    try cook.run(.none);

    // Packing the (empty) cook output needs its `.zcache`, which the cook above wrote.
    var pack_out_tmp = testing.tmpDir(.{});
    defer pack_out_tmp.cleanup();
    const pack: Command = .{ .pack = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .input = .{ .source = try output_tmp.dir.openDir(testing.io, ".", .{}) },
        .output = "command-test.zpak",
    } };
    defer pack.deinit();
    defer std.Io.Dir.cwd().deleteFile(testing.io, "command-test.zpak") catch {};
    try pack.run(.none);

    // Inspect: write a temp zmesh file since examples/output may not exist on CI
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const zmesh_file = try tmp.dir.createFile(testing.io, "test.zmesh", .{});
    var zmesh_buf: [4096]u8 = undefined;
    var zmesh_writer = zmesh_file.writer(testing.io, &zmesh_buf);
    try writeTestZmeshFile(&zmesh_writer.interface);
    try zmesh_writer.flush();
    zmesh_file.close(testing.io);

    const inspect_file = try tmp.dir.openFile(testing.io, "test.zmesh", .{});
    const inspect: Command = .{ .inspect = .{
        .allocator = testing.allocator,
        .file = inspect_file,
        .io = testing.io,
    } };
    defer inspect.deinit();
    try inspect.run(.none);
}

test "Command.deinit cleans up all variants" {
    const cook_args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const cook = try Command.parse(testing.allocator, testing.io, cook_args);
    cook.deinit();

    const pack_args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "x.zpak" };
    const pack = try Command.parse(testing.allocator, testing.io, pack_args);
    pack.deinit();

    const inspect_args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const inspect = try Command.parse(testing.allocator, testing.io, inspect_args);
    inspect.deinit();
}
