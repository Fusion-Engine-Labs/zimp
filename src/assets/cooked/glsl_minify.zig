const std = @import("std");

/// Strips comments and redundant whitespace from preprocessed GLSL.
///
/// Line-preserving: every newline in the input survives, so compiler line
/// numbers and the `#line` directives emitted by the include preprocessor stay
/// correct. Token boundaries never change: whitespace is only dropped next to
/// single-character punctuators that cannot merge with a neighbour, and only
/// outside preprocessor directives (where `F (a)` and `F(a)` differ).
///
/// Source containing a backslash-newline is returned unchanged. GLSL 4.20+
/// splices such lines before comments and tokens are recognised, while 3.30 and
/// 4.10 (the macOS profile) have no continuations at all, so no single
/// minified output is correct under both readings.
pub fn minify(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (hasLineContinuation(source)) return allocator.dupe(u8, source);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, source.len);

    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(allocator);

    var in_block_comment = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;

        code.clearRetainingCapacity();
        try stripComments(allocator, &code, line, &in_block_comment);
        try appendNormalized(allocator, &out, code.items);
    }

    return out.toOwnedSlice(allocator);
}

fn hasLineContinuation(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, line, "\r"), "\\")) return true;
    }
    return false;
}

/// Copies `line` into `code` without comments. A block comment becomes one
/// space, as in the C preprocessor. Quoted strings (only legal in directives,
/// e.g. `#line 1 "a.glsl"`) are copied verbatim.
fn stripComments(allocator: std.mem.Allocator, code: *std.ArrayList(u8), line: []const u8, in_block_comment: *bool) !void {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) {
        if (in_block_comment.*) {
            const end = std.mem.indexOfPos(u8, line, i, "*/") orelse return;
            in_block_comment.* = false;
            i = end + 2;
            continue;
        }
        const c = line[i];
        if (in_string) {
            try code.append(allocator, c);
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            return;
        } else if (c == '/' and i + 1 < line.len and line[i + 1] == '*') {
            in_block_comment.* = true;
            try code.append(allocator, ' ');
            i += 2;
            continue;
        }
        try code.append(allocator, c);
        i += 1;
    }
}

fn appendNormalized(allocator: std.mem.Allocator, out: *std.ArrayList(u8), code: []const u8) !void {
    const trimmed = std.mem.trim(u8, code, whitespace);
    if (trimmed.len == 0) return;
    const directive = trimmed[0] == '#';

    var in_string = false;
    var pending_space = false;
    var previous: u8 = 0;
    for (trimmed) |c| {
        if (in_string) {
            try out.append(allocator, c);
            if (c == '"') in_string = false;
            previous = c;
            continue;
        }
        if (isSpace(c)) {
            pending_space = true;
            continue;
        }
        if (pending_space) {
            pending_space = false;
            if (directive or !(isPunctuator(previous) or isPunctuator(c))) try out.append(allocator, ' ');
        }
        if (c == '"') in_string = true;
        try out.append(allocator, c);
        previous = c;
    }
}

const whitespace = " \t\r\x0b\x0c";

fn isSpace(c: u8) bool {
    return std.mem.indexOfScalar(u8, whitespace, c) != null;
}

/// Single-character tokens that never combine with an adjacent character.
fn isPunctuator(c: u8) bool {
    return switch (c) {
        '(', ')', '{', '}', '[', ']', ';', ',' => true,
        else => false,
    };
}

const testing = std.testing;

fn expectMinified(expected: []const u8, source: []const u8) !void {
    const out = try minify(testing.allocator, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "minify strips comments and collapses whitespace" {
    try expectMinified(
        "#version 330 core\n\n\nuniform vec3 u_color;\nvoid main(){\nfloat x=a + b*c;\n}\n",
        "#version 330 core\n// VARIANTS: A, B\n\nuniform   vec3 u_color; // tint\nvoid main ( ) {\n    float x=a  +  b*c;\n}\n",
    );
}

test "minify preserves line count across block comments" {
    try expectMinified("a\n\n\nb\n", "a /* one\ntwo\nthree */\nb\n");
    try expectMinified("a b\n", "a/* x */b\n");
}

test "minify keeps operator spacing that separates tokens" {
    try expectMinified("x=a - -b;\n", "x=a - -b;\n");
    try expectMinified("x = a + +b;\n", "x = a + +b ;\n");
}

test "minify keeps directive whitespace semantics" {
    try expectMinified("#define F(a) a\n# define G (a)\n", "#define F(a)   a\n#  define G   (a)  // obj macro\n");
    try expectMinified("#line 1 \"dir//a  b.glsl\"\n", "#line   1  \"dir//a  b.glsl\" // tail\n");
}

test "minify leaves sources with line continuations untouched" {
    const sources = [_][]const u8{
        "// note \\\nconst int x = 1;\n",
        "#define X /* \\\n*/ 1\n",
        "int\\\r\n x=0;\n",
    };
    for (sources) |source| try expectMinified(source, source);
}

test "minify handles CRLF and an unterminated final line" {
    try expectMinified("a;\nb;", "a; \r\nb;");
}

test "minify shrinks the builtin standard shader without losing lines" {
    const source = @embedFile("../../builtin/shaders/standard.frag");
    const out = try minify(testing.allocator, source);
    defer testing.allocator.free(out);
    try testing.expect(out.len < source.len);
    try testing.expectEqual(std.mem.count(u8, source, "\n"), std.mem.count(u8, out, "\n"));
    try testing.expect(std.mem.indexOf(u8, out, "//") == null);
}
