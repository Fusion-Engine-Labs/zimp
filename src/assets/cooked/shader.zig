const std = @import("std");
const string_list = @import("../../shared/string_list.zig");

const glsl_minify = @import("glsl_minify.zig");
const raw_shader = @import("../raw/shader.zig");

pub const ShaderStage = raw_shader.ShaderStage;
pub const VariantKey = raw_shader.VariantKey;
pub const RawShader = raw_shader.RawShader;

/// One minified source per stage. The runtime builds a variant by inserting
/// `#define` lines between `prologue` (the `#version` line, or empty) and `body`
/// (which starts with a `#line` directive restoring the original numbering).
pub const CookedShader = struct {
    stage: ShaderStage,
    variant_names: []const []const u8,
    prologue: []const u8,
    body: []const u8,

    pub fn cook(allocator: std.mem.Allocator, raw: *const RawShader) !CookedShader {
        const variant_names = try string_list.dupeStringList(allocator, raw.variants);
        errdefer string_list.freeStringList(allocator, variant_names);

        const minified = try glsl_minify.minify(allocator, raw.source);
        defer allocator.free(minified);

        const split = versionLineEnd(minified);
        const prologue = try allocator.dupe(u8, minified[0..split]);
        errdefer allocator.free(prologue);
        if (prologue.len > 0 and std.mem.endsWith(u8, std.mem.trimEnd(u8, prologue, "\r\n"), "\\")) {
            return error.ContinuedVersionDirective;
        }

        // Each glShaderSource string restarts line numbering and bumps the
        // source string number, so restore both for the body: errors then point
        // at the original line, as if the defines were not there.
        const prologue_lines = std.mem.count(u8, prologue, "\n");
        const body = try std.fmt.allocPrint(allocator, "#line {d} 0\n{s}", .{ prologue_lines + 1, minified[split..] });

        return .{
            .stage = raw.stage,
            .variant_names = variant_names,
            .prologue = prologue,
            .body = body,
        };
    }

    pub fn deinit(self: *CookedShader, allocator: std.mem.Allocator) void {
        string_list.freeStringList(allocator, self.variant_names);
        allocator.free(self.prologue);
        allocator.free(self.body);
    }
};

/// End of the `#version` line (after its newline) when only blank lines
/// precede it, else 0. Defines must follow `#version`, and otherwise go first.
/// Minified source has no comments, so blank lines are exactly `\n`.
fn versionLineEnd(source: []const u8) usize {
    const start = std.mem.indexOfNone(u8, source, "\n") orelse return 0;
    const newline = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse return 0;
    return if (raw_shader.isVersionLine(source[start..newline])) newline + 1 else 0;
}

const testing = std.testing;

test "CookedShader cook minifies and splits off the version line" {
    const variants = [_][]const u8{"SKINNED"};
    const raw = RawShader{
        .path = "basic.vert",
        .stage = .vertex,
        .source = "#version 330 core\n// VARIANTS: SKINNED\nvoid main()  {}\n",
        .variants = &variants,
        .includes = &.{},
    };

    var cooked = try CookedShader.cook(testing.allocator, &raw);
    defer cooked.deinit(testing.allocator);

    try testing.expectEqual(ShaderStage.vertex, cooked.stage);
    try testing.expectEqualStrings("SKINNED", cooked.variant_names[0]);
    try testing.expectEqualStrings("#version 330 core\n", cooked.prologue);
    try testing.expectEqualStrings("#line 2 0\n\nvoid main(){}\n", cooked.body);
}

test "CookedShader cook keeps leading comment lines in the prologue" {
    const raw = RawShader{
        .path = "basic.vert",
        .stage = .vertex,
        .source = "// header comment\n\n#version 330 core\nvoid main() {}\n",
        .variants = &.{},
        .includes = &.{},
    };

    var cooked = try CookedShader.cook(testing.allocator, &raw);
    defer cooked.deinit(testing.allocator);

    try testing.expectEqualStrings("\n\n#version 330 core\n", cooked.prologue);
    try testing.expectEqualStrings("#line 4 0\nvoid main(){}\n", cooked.body);
}

test "CookedShader cook leaves the prologue empty without a version line" {
    const raw = RawShader{
        .path = "basic.vert",
        .stage = .vertex,
        .source = "\nvoid main() {}\n",
        .variants = &.{},
        .includes = &.{},
    };

    var cooked = try CookedShader.cook(testing.allocator, &raw);
    defer cooked.deinit(testing.allocator);

    try testing.expectEqualStrings("", cooked.prologue);
    try testing.expectEqualStrings("#line 1 0\n\nvoid main(){}\n", cooked.body);
}

test "CookedShader cook rejects a continued version directive" {
    const raw = RawShader{
        .path = "basic.vert",
        .stage = .vertex,
        .source = "#version 420 \\\ncore\nvoid main() {}\n",
        .variants = &.{},
        .includes = &.{},
    };
    try testing.expectError(error.ContinuedVersionDirective, CookedShader.cook(testing.allocator, &raw));
}
