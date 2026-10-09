const std = @import("std");

const file_read = @import("../../shared/file_read.zig");
const builtin = @import("../../builtin/registry.zig");
const path_helpers = @import("../../path.zig");
const log = @import("../../logger.zig");
const asset = @import("../asset.zig");

/// Variant bits are a u32, so a stage declares at most 32 variants.
pub const max_variants = 32;

pub const VariantKey = struct {
    bits: u32,

    pub const base: VariantKey = .{ .bits = 0 };

    pub fn fromBits(bits: u32) VariantKey {
        return .{ .bits = bits };
    }

    pub fn has(self: VariantKey, variant_index: usize) bool {
        const bit: u32 = @as(u32, 1) << @intCast(variant_index);
        return (self.bits & bit) != 0;
    }

    pub fn with(self: VariantKey, variant_index: usize) VariantKey {
        const bit: u32 = @as(u32, 1) << @intCast(variant_index);
        return .{ .bits = self.bits | bit };
    }
};

pub const ShaderStage = enum(u8) {
    vertex = 0,
    fragment = 1,
    compute = 2,
};

pub fn stageFromExtension(ext: asset.Extension) ?ShaderStage {
    return switch (ext) {
        .vert => .vertex,
        .frag => .fragment,
        .comp => .compute,
        else => null,
    };
}

pub const RawShader = struct {
    path: []const u8,
    stage: ShaderStage,
    source: []const u8,
    variants: []const []const u8,
    includes: []const []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        source_dir: std.Io.Dir,
        source: *const builtin.Source,
    ) !RawShader {
        const ext = asset.Extension.fromName(std.fs.path.basename(source.path));
        const stage = stageFromExtension(ext) orelse return error.NotCookableShader;

        const owned_path = try allocator.dupe(u8, source.path);
        errdefer allocator.free(owned_path);

        const variants = try parseVariantNames(source.bytes, allocator);
        errdefer freeVariantNames(allocator, variants);

        const preprocessed = try preprocessShader(source, source_dir, io, allocator);
        errdefer preprocessed.deinit(allocator);

        return .{
            .path = owned_path,
            .stage = stage,
            .source = preprocessed.source,
            .variants = variants,
            .includes = preprocessed.includes,
        };
    }

    pub fn deinit(self: *RawShader, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        freeVariantNames(allocator, self.variants);
        for (self.includes) |path| allocator.free(path);
        allocator.free(self.includes);
    }
};

pub const PreprocessResult = struct {
    source: []const u8,
    includes: []const []const u8,

    pub fn deinit(self: PreprocessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        for (self.includes) |path| {
            allocator.free(path);
        }
        allocator.free(self.includes);
    }
};

pub fn parseIncludeFilename(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "//")) {
        return null;
    }
    if (!std.mem.startsWith(u8, trimmed, "#include")) {
        return null;
    }

    if (trimmed.len == "#include".len) {
        return null;
    }
    const next = trimmed["#include".len];
    if (next != ' ' and next != '\t') {
        return null;
    }

    const after_directive = std.mem.trim(u8, trimmed["#include".len..], " \t\r");
    if (after_directive.len < 2) {
        return null;
    }

    const close_char: u8 = switch (after_directive[0]) {
        '"' => '"',
        '<' => '>',
        else => return null,
    };

    const rest = after_directive[1..];
    const end = std.mem.indexOfScalar(u8, rest, close_char) orelse return null;
    if (end == 0) {
        return null;
    }

    return rest[0..end];
}

pub fn includeUsesAngleBrackets(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "#include")) return false;
    const after_directive = std.mem.trim(u8, trimmed["#include".len..], " \t\r");
    return after_directive.len > 0 and after_directive[0] == '<';
}

pub fn preprocessShader(
    source: *const builtin.Source,
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) !PreprocessResult {
    var ctx = PreprocessContext{
        .allocator = allocator,
        .dir = dir,
        .io = io,
        .output = .empty,
        .includes = .empty,
        .included_once = std.StringHashMap(void).init(allocator),
        .active = std.AutoHashMap(u64, void).init(allocator),
        .stack = .empty,
    };
    defer ctx.deinitMaps();
    errdefer {
        for (ctx.includes.items) |path| allocator.free(path);
    }

    try ctx.preprocessInto(source.bytes, source.path);

    const out_source = try ctx.output.toOwnedSlice(allocator);
    errdefer allocator.free(out_source);
    const includes = try ctx.includes.toOwnedSlice(allocator);
    errdefer allocator.free(includes);

    return .{
        .source = out_source,
        .includes = includes,
    };
}

const PreprocessContext = struct {
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    output: std.ArrayList(u8),
    includes: std.ArrayList([]const u8),
    included_once: std.StringHashMap(void),
    active: std.AutoHashMap(u64, void),
    stack: std.ArrayList([]const u8),

    fn deinitMaps(self: *PreprocessContext) void {
        self.output.deinit(self.allocator);
        self.includes.deinit(self.allocator);
        self.included_once.deinit();
        self.active.deinit();
        self.stack.deinit(self.allocator);
    }

    fn preprocessInto(self: *PreprocessContext, source: []const u8, source_path: []const u8) anyerror!void {
        const path_hash = std.hash.Wyhash.hash(0, source_path);
        if (self.active.contains(path_hash)) {
            try self.reportCircularInclude(source_path);
            return error.CircularInclude;
        }

        try self.active.put(path_hash, {});
        try self.stack.append(self.allocator, source_path);
        defer {
            _ = self.active.remove(path_hash);
            _ = self.stack.pop();
        }

        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            if (parseIncludeFilename(line)) |include_name| {
                if (includeUsesAngleBrackets(line)) {
                    return error.AngleBracketIncludeUnsupported;
                }
                try self.insertInclude(source_path, line_no, include_name);
            } else {
                try self.output.appendSlice(self.allocator, line);
                try self.output.append(self.allocator, '\n');
            }
        }
    }

    fn insertInclude(
        self: *PreprocessContext,
        source_path: []const u8,
        line_no: usize,
        include_name: []const u8,
    ) anyerror!void {
        const include_path = try path_helpers.resolveShaderInclude(self.allocator, source_path, include_name);
        var include_path_owned = true;
        errdefer if (include_path_owned) self.allocator.free(include_path);

        const include_hash = std.hash.Wyhash.hash(0, include_path);
        if (self.active.contains(include_hash)) {
            try self.reportCircularInclude(include_path);
            return error.CircularInclude;
        }

        if (self.included_once.contains(include_path)) {
            self.allocator.free(include_path);
            include_path_owned = false;
            return;
        }

        const file_result = self.readInclude(include_path) catch |err| {
            log.err("{s}:{d}: #include \"{s}\" failed: {s}", .{ source_path, line_no, include_name, @errorName(err) });
            return err;
        };
        defer self.allocator.free(file_result);

        try self.included_once.put(include_path, {});
        errdefer _ = self.included_once.remove(include_path);
        try self.includes.append(self.allocator, include_path);
        include_path_owned = false;

        try self.output.print(self.allocator, "#line 1 \"{s}\"\n", .{include_path});
        try self.preprocessInto(file_result, include_path);
        if (self.output.items.len > 0 and self.output.items[self.output.items.len - 1] != '\n') {
            try self.output.append(self.allocator, '\n');
        }
        try self.output.print(self.allocator, "#line {d} \"{s}\"\n", .{ line_no + 1, source_path });
    }

    fn readInclude(self: *PreprocessContext, include_path: []const u8) ![]u8 {
        return file_read.readFileAllocChunked(self.allocator, self.io, self.dir, include_path);
    }

    fn reportCircularInclude(self: *PreprocessContext, source_path: []const u8) !void {
        var message: std.ArrayList(u8) = .empty;
        defer message.deinit(self.allocator);

        try message.appendSlice(self.allocator, "circular include detected: ");
        for (self.stack.items, 0..) |path, i| {
            if (i > 0) {
                try message.appendSlice(self.allocator, " -> ");
            }
            try message.appendSlice(self.allocator, path);
        }
        try message.appendSlice(self.allocator, " -> ");
        try message.appendSlice(self.allocator, source_path);

        log.err("{s}", .{message.items});
    }
};

pub fn parseVariantNames(source: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var variants: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (variants.items) |name| allocator.free(name);
        variants.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "//")) {
            continue;
        }

        const after_comment = std.mem.trim(u8, trimmed[2..], " \t");
        if (!std.mem.startsWith(u8, after_comment, "VARIANTS:")) {
            continue;
        }

        const payload = after_comment["VARIANTS:".len..];
        var names = std.mem.splitScalar(u8, payload, ',');
        while (names.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t\r");
            if (name.len == 0) {
                continue;
            }
            if (!isValidVariantName(name)) {
                return error.InvalidVariantName;
            }
            for (variants.items) |existing| {
                if (std.mem.eql(u8, existing, name)) return error.DuplicateVariantName;
            }
            if (variants.items.len == max_variants) return error.TooManyShaderVariants;

            try variants.append(allocator, try allocator.dupe(u8, name));
        }
        break;
    }

    return variants.toOwnedSlice(allocator);
}

pub fn freeVariantNames(allocator: std.mem.Allocator, variants: []const []const u8) void {
    for (variants) |name| {
        allocator.free(name);
    }
    allocator.free(variants);
}

pub fn isValidVariantName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isIdentStart(name[0])) return false;
    for (name[1..]) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

const testing = std.testing;

test "parseIncludeFilename matches quoted include" {
    try testing.expectEqualStrings("foo.glsl", parseIncludeFilename("#include \"foo.glsl\"\n").?);
}

test "parseIncludeFilename matches angle-bracket include" {
    try testing.expectEqualStrings("bar.glsl", parseIncludeFilename("#include <bar.glsl>\n").?);
}

test "parseIncludeFilename allows leading whitespace" {
    try testing.expectEqualStrings("baz.glsl", parseIncludeFilename("    #include \"baz.glsl\"\n").?);
}

test "parseIncludeFilename ignores commented-out include" {
    try testing.expectEqual(@as(?[]const u8, null), parseIncludeFilename("// #include \"skip.glsl\"\n"));
    try testing.expectEqual(@as(?[]const u8, null), parseIncludeFilename("   // #include \"skip.glsl\"\n"));
}

test "parseIncludeFilename ignores line without whitespace after directive" {
    try testing.expectEqual(@as(?[]const u8, null), parseIncludeFilename("#includefoo\n"));
}

test "preprocessShader inserts include contents and line directives" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "shaders");
    try writeTestFile(tmp.dir, "shaders/common.glsl", "vec3 common() { return vec3(1.0); }\n");

    const source = builtin.Source{
        .bytes = "#version 330 core\n#include \"common.glsl\"\nvoid main() {}\n",
        .path = "shaders/basic.frag",
    };

    const result = try preprocessShader(
        &source,
        tmp.dir,
        testing.io,
        testing.allocator,
    );
    defer result.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, result.source, "vec3 common()") != null);
    try testing.expect(std.mem.indexOf(u8, result.source, "#line 1 \"shaders/common.glsl\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.source, "#line 3 \"shaders/basic.frag\"") != null);
    try testing.expectEqual(@as(usize, 1), result.includes.len);
    try testing.expectEqualStrings("shaders/common.glsl", result.includes[0]);
}

test "preprocessShader handles recursive includes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "a.glsl", "#include \"b.glsl\"\nA\n");
    try writeTestFile(tmp.dir, "b.glsl", "#include \"c.glsl\"\nB\n");
    try writeTestFile(tmp.dir, "c.glsl", "C\n");

    const src = builtin.Source{
        .bytes = "#include \"b.glsl\"\nROOT\n",
        .path = "a.frag",
    };
    const result = try preprocessShader(&src, tmp.dir, testing.io, testing.allocator);
    defer result.deinit(testing.allocator);

    const c_idx = std.mem.indexOf(u8, result.source, "C\n") orelse return error.MissingC;
    const b_idx = std.mem.indexOf(u8, result.source, "B\n") orelse return error.MissingB;
    const root_idx = std.mem.indexOf(u8, result.source, "ROOT\n") orelse return error.MissingRoot;
    try testing.expect(c_idx < b_idx);
    try testing.expect(b_idx < root_idx);
}

test "preprocessShader detects circular includes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "a.glsl", "#include \"b.glsl\"\n");
    try writeTestFile(tmp.dir, "b.glsl", "#include \"a.glsl\"\n");

    const src = builtin.Source{
        .bytes = "#include \"a.glsl\"\n",
        .path = "root.frag",
    };
    try testing.expectError(
        error.CircularInclude,
        preprocessShader(&src, tmp.dir, testing.io, testing.allocator),
    );
}

test "preprocessShader deduplicates duplicate includes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "b.glsl", "#include \"d.glsl\"\nB\n");
    try writeTestFile(tmp.dir, "c.glsl", "#include \"d.glsl\"\nC\n");
    try writeTestFile(tmp.dir, "d.glsl", "D\n");

    const src = builtin.Source{
        .bytes = "#include \"b.glsl\"\n#include \"c.glsl\"\n",
        .path = "a.frag",
    };
    const result = try preprocessShader(&src, tmp.dir, testing.io, testing.allocator);
    defer result.deinit(testing.allocator);

    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOf(u8, result.source[offset..], "D\n")) |idx| {
        count += 1;
        offset += idx + 2;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "parseVariantNames handles whitespace" {
    const variants = try parseVariantNames("// VARIANTS:  SKINNED , HAS_NORMAL_MAP , HAS_AO \n", testing.allocator);
    defer freeVariantNames(testing.allocator, variants);

    try testing.expectEqual(@as(usize, 3), variants.len);
    try testing.expectEqualStrings("SKINNED", variants[0]);
    try testing.expectEqualStrings("HAS_NORMAL_MAP", variants[1]);
    try testing.expectEqualStrings("HAS_AO", variants[2]);
}

test "parseVariantNames rejects duplicates and more than 32 names" {
    try testing.expectError(error.DuplicateVariantName, parseVariantNames("// VARIANTS: A, B, A\n", testing.allocator));

    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    try many.appendSlice(testing.allocator, "// VARIANTS: ");
    for (0..33) |i| try many.print(testing.allocator, "V{d},", .{i});
    try testing.expectError(error.TooManyShaderVariants, parseVariantNames(many.items, testing.allocator));
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(testing.io, path, .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    file.close(testing.io);
}
