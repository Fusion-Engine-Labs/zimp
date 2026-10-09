const std = @import("std");
const string_list = @import("../shared/string_list.zig");

const constants = @import("../shared/constants.zig");
const cooked_shader = @import("../assets/cooked/shader.zig");
const glsl_minify = @import("../assets/cooked/glsl_minify.zig");
const raw_shader = @import("../assets/raw/shader.zig");
const wire = @import("../shared/wire.zig");

pub const MAGIC = constants.FORMAT_MAGIC.ZSHDR;
pub const ZSHDR_VERSION: u32 = 3;

pub const ShaderStage = cooked_shader.ShaderStage;
pub const VariantKey = cooked_shader.VariantKey;
pub const CookedShader = cooked_shader.CookedShader;

pub const max_variants = 32;
const define_prefix = "#define ";

/// File layout: `Header`, then two aligned sections: the variant table (one
/// string ref per variant, each a `#define NAME\n` line) and one string blob
/// holding the define lines, the prologue, and the body, in that order.
///
/// A variant's source is `prologue ++ defines for set bits ++ body`. The
/// prologue runs through the `#version` line (after any blank or comment-only
/// lines), or is
/// empty when the shader does not start with one.
pub const Header = extern struct {
    file: wire.FileHeader,
    stage: u8,
    _reserved0: u8 = 0,
    variant_count: u16,
    variant_defines: wire.Span,
    prologue: wire.Span,
    body: wire.Span,
    strings: wire.Span,
};

comptime {
    wire.assertTightLayout(Header);
}

pub const HEADER_SIZE: u32 = @sizeOf(Header);

/// Zero-copy view of a cooked shader stage. Borrows the bytes it was created from.
pub const ZShader = struct {
    stage: ShaderStage,
    variant_define_refs: []const wire.Span,
    prologue: []const u8,
    body: []const u8,
    strings: []const u8,

    /// Source pieces for one variant, ready for `glShaderSource`.
    pub const SourceParts = [max_variants + 2][]const u8;

    pub fn view(bytes: wire.Bytes) !ZShader {
        _ = try wire.FileHeader.validate(bytes, MAGIC, ZSHDR_VERSION);
        const header = try wire.structAt(Header, bytes, 0);
        const stage = try wire.enumFromInt(ShaderStage, header.stage);
        if (header.variant_count > max_variants) return error.TooManyVariants;

        var order = wire.SectionOrder.init(HEADER_SIZE);
        for ([_]wire.Span{ header.variant_defines, header.strings }) |span| try order.next(span);
        try order.finish(bytes.len);

        const strings = try wire.sectionSlice(u8, bytes, header.strings, header.strings.len);
        const defines = try wire.sectionSlice(wire.Span, bytes, header.variant_defines, header.variant_count);

        // Strings are packed back to back in write order and fill the blob exactly.
        var cursor: u64 = 0;
        for (defines, 0..) |ref, i| {
            try nextString(strings, ref, &cursor);
            const name = defineName(wire.stringAt(strings, ref)) orelse return error.InvalidVariantDefine;
            for (defines[0..i]) |other| {
                if (std.mem.eql(u8, name, defineName(wire.stringAt(strings, other)).?)) return error.DuplicateVariant;
            }
        }
        try nextString(strings, header.prologue, &cursor);
        try nextString(strings, header.body, &cursor);
        if (cursor != strings.len) return error.InvalidStringRef;

        const prologue = wire.stringAt(strings, header.prologue);
        if (!isValidPrologue(prologue)) return error.InvalidPrologue;

        return .{
            .stage = stage,
            .variant_define_refs = defines,
            .prologue = prologue,
            .body = wire.stringAt(strings, header.body),
            .strings = strings,
        };
    }

    pub fn variantCount(self: *const ZShader) usize {
        return self.variant_define_refs.len;
    }

    pub fn variantName(self: *const ZShader, index: usize) []const u8 {
        const line = self.variantDefine(index);
        return line[define_prefix.len .. line.len - 1];
    }

    /// The `#define NAME\n` line for a variant.
    pub fn variantDefine(self: *const ZShader, index: usize) []const u8 {
        return wire.stringAt(self.strings, self.variant_define_refs[index]);
    }

    /// Returns the source of variant `key` as pieces to concatenate (or pass
    /// as-is to `glShaderSource`): the prologue, one define per set bit in
    /// bit order, then the body. The pieces borrow from the view.
    pub fn sourceParts(self: *const ZShader, key: VariantKey, out: *SourceParts) ![]const []const u8 {
        const count = self.variantCount();
        if (count < 32 and key.bits >> @intCast(count) != 0) return error.InvalidVariantKey;

        var len: usize = 0;
        if (self.prologue.len > 0) {
            out[len] = self.prologue;
            len += 1;
        }
        for (0..count) |i| {
            if (!key.has(i)) continue;
            out[len] = self.variantDefine(i);
            len += 1;
        }
        out[len] = self.body;
        len += 1;
        return out[0..len];
    }

    /// Concatenated source of variant `key`. Caller owns the result.
    pub fn sourceAlloc(self: *const ZShader, allocator: std.mem.Allocator, key: VariantKey) ![]u8 {
        var parts: SourceParts = undefined;
        return std.mem.concat(allocator, u8, try self.sourceParts(key, &parts));
    }

    pub fn variantKey(self: *const ZShader, enabled_variants: []const []const u8) !VariantKey {
        var key = VariantKey.base;
        for (enabled_variants) |enabled| {
            const index = self.variantIndex(enabled) orelse return error.UnknownShaderVariant;
            key = key.with(index);
        }
        return key;
    }

    /// Key enabling every variant of this stage whose `wire.nameHash` is in
    /// `sorted_hashes` (a material's `variant_hashes`). Hashes this stage does
    /// not declare are ignored, since they may belong to the other stage.
    pub fn variantKeyFromHashes(self: *const ZShader, sorted_hashes: []const u64) VariantKey {
        var key = VariantKey.base;
        for (0..self.variantCount()) |i| {
            const hash = wire.nameHash(self.variantName(i));
            if (std.sort.binarySearch(u64, sorted_hashes, hash, orderU64) != null) key = key.with(i);
        }
        return key;
    }

    fn variantIndex(self: *const ZShader, name: []const u8) ?usize {
        for (0..self.variantCount()) |i| {
            if (std.mem.eql(u8, self.variantName(i), name)) return i;
        }
        return null;
    }
};

fn orderU64(target: u64, item: u64) std.math.Order {
    return std.math.order(target, item);
}

fn nextString(strings: []const u8, ref: wire.Span, cursor: *u64) !void {
    try wire.checkString(strings, ref);
    if (ref.offset != cursor.*) return error.InvalidStringRef;
    cursor.* = ref.end();
}

/// The identifier in a `#define NAME\n` line, or null if the line has any other shape.
fn defineName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, define_prefix) or !std.mem.endsWith(u8, line, "\n")) return null;
    if (line.len < define_prefix.len + 1) return null;
    const name = line[define_prefix.len .. line.len - 1];
    return if (raw_shader.isValidVariantName(name)) name else null;
}

/// Empty, or blank/comment-only lines followed by one `#version` line
/// including its newline (see `glsl_minify.versionPrologueEnd`).
pub fn isValidPrologue(prologue: []const u8) bool {
    return prologue.len == 0 or glsl_minify.versionPrologueEnd(prologue) == prologue.len;
}

pub fn view(bytes: wire.Bytes) !ZShader {
    return ZShader.view(bytes);
}

pub fn write(writer: *std.Io.Writer, cooked: CookedShader) !void {
    if (cooked.variant_names.len > max_variants) return error.TooManyVariants;
    if (!isValidPrologue(cooked.prologue)) return error.InvalidPrologue;
    for (cooked.variant_names, 0..) |name, i| {
        if (!raw_shader.isValidVariantName(name)) return error.InvalidVariantName;
        for (cooked.variant_names[0..i]) |other| {
            if (std.mem.eql(u8, name, other)) return error.DuplicateVariant;
        }
    }

    var string_bytes: usize = cooked.prologue.len + cooked.body.len;
    for (cooked.variant_names) |name| string_bytes += defineLineLen(name);

    var layout = wire.Layout.init(HEADER_SIZE);
    const variant_defines = try layout.reserve(cooked.variant_names.len * @sizeOf(wire.Span));
    const strings = try layout.reserve(string_bytes);
    const total_size = layout.totalSize();

    var string_offset: u32 = 0;
    var define_refs: [max_variants]wire.Span = undefined;
    for (cooked.variant_names, define_refs[0..cooked.variant_names.len]) |name, *ref| {
        ref.* = nextRef(&string_offset, defineLineLen(name));
    }
    const prologue = nextRef(&string_offset, cooked.prologue.len);
    const body = nextRef(&string_offset, cooked.body.len);

    var out: wire.LayoutWriter = .{ .writer = writer };
    try out.value(Header{
        .file = .init(MAGIC, ZSHDR_VERSION, total_size),
        .stage = @intFromEnum(cooked.stage),
        .variant_count = @intCast(cooked.variant_names.len),
        .variant_defines = variant_defines,
        .prologue = prologue,
        .body = body,
        .strings = strings,
    });

    try out.beginSection(variant_defines);
    try out.slice(define_refs[0..cooked.variant_names.len]);

    try out.beginSection(strings);
    for (cooked.variant_names) |name| {
        try out.bytes(define_prefix);
        try out.bytes(name);
        try out.bytes("\n");
    }
    try out.bytes(cooked.prologue);
    try out.bytes(cooked.body);
    try out.finish(total_size);
}

fn defineLineLen(name: []const u8) usize {
    return define_prefix.len + name.len + 1;
}

fn nextRef(offset: *u32, len: usize) wire.Span {
    const span: wire.Span = .{ .offset = offset.*, .len = @intCast(len) };
    offset.* += span.len;
    return span;
}

const testing = std.testing;

fn makeCooked(variants: []const []const u8, prologue: []const u8, body: []const u8) !CookedShader {
    return .{
        .stage = .vertex,
        .variant_names = try string_list.dupeStringList(testing.allocator, variants),
        .prologue = try testing.allocator.dupe(u8, prologue),
        .body = try testing.allocator.dupe(u8, body),
    };
}

fn writeCooked(buf: []align(wire.section_alignment) u8, cooked: CookedShader) !wire.Bytes {
    var writer = std.Io.Writer.fixed(buf);
    try write(&writer, cooked);
    return buf[0..writer.end];
}

fn expectSource(shader: *const ZShader, key: VariantKey, expected: []const u8) !void {
    const source = try shader.sourceAlloc(testing.allocator, key);
    defer testing.allocator.free(source);
    try testing.expectEqualStrings(expected, source);
}

test "ZShader write and view round trips" {
    var cooked = try makeCooked(&.{ "SKINNED", "HAS_AO" }, "#version 330 core\n", "\nvoid main(){}\n");
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    const bytes = try writeCooked(&buf, cooked);

    try testing.expectEqualSlices(u8, MAGIC, bytes[0..4]);
    const shader = try ZShader.view(bytes);
    try testing.expectEqual(ShaderStage.vertex, shader.stage);
    try testing.expectEqual(@as(usize, 2), shader.variantCount());
    try testing.expectEqualStrings("SKINNED", shader.variantName(0));
    try testing.expectEqualStrings("HAS_AO", shader.variantName(1));
    try expectSource(&shader, .base, "#version 330 core\n\nvoid main(){}\n");
    try expectSource(&shader, .fromBits(1), "#version 330 core\n#define SKINNED\n\nvoid main(){}\n");
    try expectSource(&shader, .fromBits(2), "#version 330 core\n#define HAS_AO\n\nvoid main(){}\n");
    try expectSource(&shader, .fromBits(3), "#version 330 core\n#define SKINNED\n#define HAS_AO\n\nvoid main(){}\n");
    try testing.expectEqual(VariantKey.fromBits(3), try shader.variantKey(&.{ "HAS_AO", "SKINNED" }));
    try testing.expectError(error.UnknownShaderVariant, shader.variantKey(&.{"MISSING"}));

    var hashes = [_]u64{ wire.nameHash("HAS_AO"), wire.nameHash("OTHER_STAGE") };
    std.mem.sort(u64, &hashes, {}, std.sort.asc(u64));
    try testing.expectEqual(VariantKey.fromBits(2), shader.variantKeyFromHashes(&hashes));
    try testing.expectEqual(VariantKey.base, shader.variantKeyFromHashes(&.{}));

    var parts: ZShader.SourceParts = undefined;
    try testing.expectError(error.InvalidVariantKey, shader.sourceParts(.fromBits(4), &parts));
}

test "ZShader without a version line puts defines first" {
    var cooked = try makeCooked(&.{"A"}, "", "void main(){}\n");
    defer cooked.deinit(testing.allocator);

    var buf: [512]u8 align(wire.section_alignment) = undefined;
    const shader = try ZShader.view(try writeCooked(&buf, cooked));
    try expectSource(&shader, .base, "void main(){}\n");
    try expectSource(&shader, .fromBits(1), "#define A\nvoid main(){}\n");
}

test "ZShader round trips a stage with no variants" {
    var cooked = try makeCooked(&.{}, "#version 330 core\n", "");
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    const shader = try ZShader.view(try writeCooked(&buf, cooked));
    try testing.expectEqual(@as(usize, 0), shader.variantCount());
    try expectSource(&shader, .base, "#version 330 core\n");
    var parts: ZShader.SourceParts = undefined;
    try testing.expectError(error.InvalidVariantKey, shader.sourceParts(.fromBits(1), &parts));
}

test "ZShader supports the full 32-variant key space" {
    var names: [max_variants][]const u8 = undefined;
    var name_bufs: [max_variants][4]u8 = undefined;
    for (&names, &name_bufs, 0..) |*name, *name_buf, i| name.* = try std.fmt.bufPrint(name_buf, "V{d}", .{i});
    var cooked = try makeCooked(&names, "#version 330 core\n", "x\n");
    defer cooked.deinit(testing.allocator);

    var buf: [2048]u8 align(wire.section_alignment) = undefined;
    const shader = try ZShader.view(try writeCooked(&buf, cooked));
    var parts: ZShader.SourceParts = undefined;
    const all = try shader.sourceParts(.fromBits(std.math.maxInt(u32)), &parts);
    try testing.expectEqual(@as(usize, max_variants + 2), all.len);
    try testing.expectEqualStrings("#define V31\n", all[max_variants]);
}

test "write rejects invalid input" {
    var buf: [512]u8 align(wire.section_alignment) = undefined;

    var duplicate = try makeCooked(&.{ "A", "A" }, "", "");
    defer duplicate.deinit(testing.allocator);
    try testing.expectError(error.DuplicateVariant, writeCooked(&buf, duplicate));

    var bad_name = try makeCooked(&.{"1A"}, "", "");
    defer bad_name.deinit(testing.allocator);
    try testing.expectError(error.InvalidVariantName, writeCooked(&buf, bad_name));

    var bad_prologue = try makeCooked(&.{}, "#version 330\n#extension X : enable\n", "");
    defer bad_prologue.deinit(testing.allocator);
    try testing.expectError(error.InvalidPrologue, writeCooked(&buf, bad_prologue));

    var continued_prologue = try makeCooked(&.{}, "#version 420 \\\n", "core\n");
    defer continued_prologue.deinit(testing.allocator);
    try testing.expectError(error.InvalidPrologue, writeCooked(&buf, continued_prologue));

    var commented_prologue = try makeCooked(&.{}, "// header\r\n  \n#version 330 core\r\n", "x\n");
    defer commented_prologue.deinit(testing.allocator);
    _ = try ZShader.view(try writeCooked(&buf, commented_prologue));
}

test "ZShader.view rejects corrupted files" {
    var cooked = try makeCooked(&.{ "A", "B" }, "#version 330 core\n", "void main(){}\n");
    defer cooked.deinit(testing.allocator);

    var buf: [512]u8 align(wire.section_alignment) = undefined;
    const len = (try writeCooked(&buf, cooked)).len;
    const header: *Header = @ptrCast(&buf);
    const defines: [*]wire.Span = @ptrCast(@alignCast(buf[header.variant_defines.offset..].ptr));
    const strings = buf[header.strings.offset..][0..header.strings.len];
    _ = try ZShader.view(buf[0..len]);

    // Define line shape: prefix, identifier, and newline.
    strings[1] = 'X';
    try testing.expectError(error.InvalidVariantDefine, ZShader.view(buf[0..len]));
    strings[1] = 'd';
    strings[8] = '9';
    try testing.expectError(error.InvalidVariantDefine, ZShader.view(buf[0..len]));
    strings[8] = 'A';
    strings[9] = ' ';
    try testing.expectError(error.InvalidVariantDefine, ZShader.view(buf[0..len]));
    strings[9] = '\n';

    // Duplicate variant names.
    strings[18] = 'A';
    try testing.expectError(error.DuplicateVariant, ZShader.view(buf[0..len]));
    strings[18] = 'B';

    // String refs must be packed in write order and fill the blob.
    defines[1].offset += 1;
    try testing.expectError(error.InvalidStringRef, ZShader.view(buf[0..len]));
    defines[1].offset -= 1;
    header.body.len -= 1;
    try testing.expectError(error.InvalidStringRef, ZShader.view(buf[0..len]));
    header.body.len += 1;
    header.body.len = 1000;
    try testing.expectError(error.InvalidStringRef, ZShader.view(buf[0..len]));
    header.body.len = @intCast(cooked.body.len);

    // Prologue must be a single #version line.
    const prologue_start = header.prologue.offset;
    strings[prologue_start + 1] = 'x';
    try testing.expectError(error.InvalidPrologue, ZShader.view(buf[0..len]));
    strings[prologue_start + 1] = 'v';
    strings[prologue_start + 8] = '\n';
    try testing.expectError(error.InvalidPrologue, ZShader.view(buf[0..len]));
    strings[prologue_start + 8] = ' ';

    header.stage = 99;
    try testing.expectError(error.InvalidEnumValue, ZShader.view(buf[0..len]));
    header.stage = 0;
    header.variant_count = 33;
    try testing.expectError(error.TooManyVariants, ZShader.view(buf[0..len]));
    header.variant_count = 2;
    const strings_span = header.strings;
    header.strings.offset = header.variant_defines.offset;
    try testing.expectError(error.OverlappingSections, ZShader.view(buf[0..len]));
    header.strings = strings_span;

    _ = try ZShader.view(buf[0..len]);
    try testing.expectError(error.InvalidFileSize, ZShader.view(buf[0 .. len - 1]));
}
