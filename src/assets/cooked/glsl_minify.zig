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
    while (lines.next()) |line| if (endsWithContinuation(line)) return true;
    return false;
}

/// Iterates the characters of one line that are outside comments. A block
/// comment yields one space, as in the C preprocessor. Quoted strings (only
/// legal in directives, e.g. `#line 1 "a.glsl"`) are passed through verbatim.
const LineCode = struct {
    line: []const u8,
    in_block_comment: *bool,
    i: usize = 0,
    in_string: bool = false,

    fn next(self: *LineCode) ?u8 {
        while (self.i < self.line.len) {
            if (self.in_block_comment.*) {
                const end = std.mem.indexOfPos(u8, self.line, self.i, "*/") orelse {
                    self.i = self.line.len;
                    return null;
                };
                self.in_block_comment.* = false;
                self.i = end + 2;
                continue;
            }
            const c = self.line[self.i];
            if (self.in_string) {
                if (c == '"') self.in_string = false;
            } else if (c == '"') {
                self.in_string = true;
            } else if (c == '/' and self.i + 1 < self.line.len and self.line[self.i + 1] == '/') {
                self.i = self.line.len;
                return null;
            } else if (c == '/' and self.i + 1 < self.line.len and self.line[self.i + 1] == '*') {
                self.in_block_comment.* = true;
                self.i += 2;
                return ' ';
            }
            self.i += 1;
            return c;
        }
        return null;
    }

    /// Next character that is not whitespace, or null at the end of the line.
    fn nextNonSpace(self: *LineCode) ?u8 {
        while (self.next()) |c| if (!isSpace(c)) return c;
        return null;
    }

    fn drain(self: *LineCode) void {
        while (self.next()) |_| {}
    }
};

fn stripComments(allocator: std.mem.Allocator, code: *std.ArrayList(u8), line: []const u8, in_block_comment: *bool) !void {
    var it: LineCode = .{ .line = line, .in_block_comment = in_block_comment };
    while (it.next()) |c| try code.append(allocator, c);
}

/// Length of the prologue that variant defines must follow: any blank or
/// comment-only lines, then the `#version` line including its newline. Returns
/// 0 when the first code line is not `#version` (defines then go first), and
/// null when the version line cannot end a prologue because it is continued,
/// leaves a block comment open, or has no newline. Works on minified and
/// unminified source alike.
pub fn versionPrologueEnd(source: []const u8) ?usize {
    var in_block_comment = false;
    var start: usize = 0;
    while (start < source.len) {
        const newline = std.mem.indexOfScalarPos(u8, source, start, '\n');
        const line = source[start .. newline orelse source.len];
        var it: LineCode = .{ .line = line, .in_block_comment = &in_block_comment };
        const first = it.nextNonSpace() orelse {
            // A continued blank or comment line may splice onto `#version`.
            if (endsWithContinuation(line)) return null;
            start = (newline orelse return 0) + 1;
            continue;
        };
        if (first != '#' or !matchesVersion(&it)) return 0;
        it.drain();
        if (in_block_comment or endsWithContinuation(line)) return null;
        return (newline orelse return null) + 1;
    }
    return 0;
}

/// Matches `version` followed by whitespace or the end of the line, after a
/// `#` (GLSL allows whitespace between `#` and the directive name).
fn matchesVersion(it: *LineCode) bool {
    var c = it.nextNonSpace() orelse return false;
    for ("version", 0..) |expected, i| {
        if (i > 0) c = it.next() orelse return false;
        if (c != expected) return false;
    }
    const after = it.next() orelse return true;
    return isSpace(after);
}

fn endsWithContinuation(line: []const u8) bool {
    return std.mem.endsWith(u8, std.mem.trimEnd(u8, line, "\r"), "\\");
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

test "versionPrologueEnd skips blank and comment-only lines" {
    const cases = [_]struct { source: []const u8, end: ?usize }{
        .{ .source = "#version 330 core\nvoid main(){}\n", .end = 18 },
        .{ .source = "\n\n#version 330 core\nx\n", .end = 20 },
        .{ .source = "// header\n   \n#version 330 core\nx\n", .end = 32 },
        .{ .source = "\r\n#version 330 core\r\nx\n", .end = 21 },
        .{ .source = "/* license\n  text */\n#version 330 core\nx\n", .end = 39 },
        .{ .source = "/* a */ #version 330 core\nx\n", .end = 26 },
        .{ .source = "#  version 330\nx\n", .end = 15 },
        .{ .source = "#version 330 // note\nx\n", .end = 21 },
        // No leading #version: defines go first.
        .{ .source = "", .end = 0 },
        .{ .source = "void main(){}\n", .end = 0 },
        .{ .source = "#define A\n#version 330\n", .end = 0 },
        .{ .source = "#versionx 330\n", .end = 0 },
        .{ .source = "/* #version 330 */\nx\n", .end = 0 },
        // A version line that cannot end a prologue.
        .{ .source = "#version 420 \\\ncore\n", .end = null },
        .{ .source = "#version 330 /* open\n */\n", .end = null },
        .{ .source = "// hdr \\\n#version 330\n", .end = null },
        .{ .source = "#version 330", .end = null },
    };
    for (cases) |case| try testing.expectEqual(case.end, versionPrologueEnd(case.source));
}
