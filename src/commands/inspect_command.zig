const std = @import("std");
const string_list = @import("../shared/string_list.zig");

const log = @import("../logger.zig");
const inspectors = @import("../inspectors/inspect.zig").inspector_registry;
const file_read = @import("../shared/file_read.zig");
const magic_len = @import("../shared/constants.zig").FORMAT_MAGIC.ZMESH.len;

pub const InspectError = error{
    NotEnoughArguments,
    TooManyArguments,
    FileNotFound,
    UnknownFormat,
};

pub const InspectCommand = struct {
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn parseFromArgs(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) InspectError!InspectCommand {
        const cwd = std.Io.Dir.cwd();

        if (args.len < 3) {
            log.err("inspect: not enough arguments (got {d}, need at least 3). Usage: zimp inspect <file_path>", .{args.len});
            return InspectError.NotEnoughArguments;
        }
        if (args.len > 3) return InspectError.TooManyArguments;

        const file = cwd.openFile(io, args[2], .{}) catch |err| {
            log.err("inspect: failed to open file '{s}': {s}. Ensure the file exists and has the correct permissions", .{ args[2], @errorName(err) });
            return InspectError.FileNotFound;
        };

        return .{
            .allocator = allocator,
            .file = file,
            .io = io,
        };
    }

    pub fn run(self: InspectCommand) !void {
        log.info("Running inspect command", .{});

        var buf: [8192]u8 = undefined;
        var file_reader = self.file.reader(self.io, &buf);
        const bytes = try file_read.readAllAligned(self.allocator, &file_reader.interface);
        defer self.allocator.free(bytes);

        const magic = bytes[0..@min(bytes.len, magic_len)];
        const inspector = inspectors.get(magic) orelse {
            log.err("No inspector found for file with magic '{s}'", .{magic});
            return InspectError.UnknownFormat;
        };

        try inspector.inspect(self.allocator, bytes);
    }

    pub fn deinit(self: InspectCommand) void {
        self.file.close(self.io);
    }
};

const testing = std.testing;
const writeTestZmeshFile = @import("../formats/zmesh.zig").writeTestZmeshFile;
const zshdr = @import("../formats/zshdr.zig");
const CookedShader = @import("../assets/cooked/shader.zig").CookedShader;

test "InspectCommand.parseFromArgs errors with NotEnoughArguments when no file provided" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect" };
    const result = InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(InspectError.NotEnoughArguments, result);
}

test "InspectCommand.parseFromArgs errors with FileNotFound for nonexistent file" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "nonexistent_file_abc123.txt" };
    const result = InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(InspectError.FileNotFound, result);
}

test "InspectCommand.parseFromArgs succeeds with valid file" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expect(cmd.file.handle != 0);
}

test "InspectCommand.parseFromArgs stores allocator" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expectEqual(testing.allocator, cmd.allocator);
}

test "InspectCommand.run returns UnknownFormat for non-asset file" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();
    try testing.expectError(InspectError.UnknownFormat, cmd.run());
}

test "InspectCommand.run succeeds for valid zmesh file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a minimal zmesh file
    const file = try tmp.dir.createFile(testing.io, "test.zmesh", .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writeTestZmeshFile(&writer.interface);
    try writer.flush();
    file.close(testing.io);

    // Inspect it
    const inspect_file = try tmp.dir.openFile(testing.io, "test.zmesh", .{});
    const cmd: InspectCommand = .{
        .allocator = testing.allocator,
        .file = inspect_file,
        .io = testing.io,
    };
    defer cmd.deinit();
    try cmd.run();
}

test "InspectCommand.run succeeds for valid zshdr file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const variant_names = try string_list.dupeStringList(testing.allocator, &.{"SKINNED"});
    const includes = try string_list.dupeStringList(testing.allocator, &.{});
    const permutations = try testing.allocator.alloc(CookedShader.Permutation, 2);
    permutations[0] = .{
        .key = .base,
        .source = try testing.allocator.dupe(u8, "#version 330 core\nvoid main() {}\n"),
    };
    permutations[1] = .{
        .key = zshdr.VariantKey.base.with(0),
        .source = try testing.allocator.dupe(u8, "#version 330 core\n#define SKINNED\nvoid main() {}\n"),
    };

    var cooked = CookedShader{
        .stage = .vertex,
        .variant_names = variant_names,
        .includes = includes,
        .permutations = permutations,
    };
    defer cooked.deinit(testing.allocator);

    const file = try tmp.dir.createFile(testing.io, "test.zshdr", .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try zshdr.write(&writer.interface, cooked);
    try writer.flush();
    file.close(testing.io);

    const inspect_file = try tmp.dir.openFile(testing.io, "test.zshdr", .{});
    const cmd: InspectCommand = .{
        .allocator = testing.allocator,
        .file = inspect_file,
        .io = testing.io,
    };
    defer cmd.deinit();
    try cmd.run();
}

test "InspectCommand.parseFromArgs errors with NotEnoughArguments for single arg" {
    const args: []const [:0]const u8 = &.{"zimp"};
    const result = InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(InspectError.NotEnoughArguments, result);
}

test "InspectCommand.parseFromArgs rejects extra operands" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig", "extra" };
    try testing.expectError(InspectError.TooManyArguments, InspectCommand.parseFromArgs(testing.allocator, testing.io, args));
}

test "InspectCommand.deinit cleans up without error" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    cmd.deinit();
}
