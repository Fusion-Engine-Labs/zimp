const std = @import("std");
const string_list = @import("../shared/string_list.zig");

const constants = @import("../shared/constants.zig");
const cooked_shader = @import("../assets/cooked/shader.zig");
const wire = @import("../shared/wire.zig");

pub const MAGIC = constants.FORMAT_MAGIC.ZSHDR;
pub const ZSHDR_VERSION: u32 = 2;

pub const ShaderStage = cooked_shader.ShaderStage;
pub const VariantKey = cooked_shader.VariantKey;
pub const CookedShader = cooked_shader.CookedShader;

const max_variants = 32;
const max_includes = 4096;
const max_permutations = 65536;

/// File layout: `Header`, then aligned sections: variant name refs, include
/// refs, the `PermutationEntry` table (sorted by key), and one string blob
/// holding names, includes, and sources.
pub const Header = extern struct {
    file: wire.FileHeader,
    stage: u8,
    _reserved0: u8 = 0,
    variant_count: u16,
    include_count: u16,
    _reserved1: u16 = 0,
    permutation_count: u32,
    variant_names: wire.Span,
    includes: wire.Span,
    permutations: wire.Span,
    strings: wire.Span,
};

pub const PermutationEntry = extern struct {
    key: u32,
    source: wire.Span,
};

comptime {
    wire.assertTightLayout(Header);
    wire.assertTightLayout(PermutationEntry);
}

pub const HEADER_SIZE: u32 = @sizeOf(Header);

/// Zero-copy view of a cooked shader stage. Borrows the bytes it was created from.
pub const ZShader = struct {
    stage: ShaderStage,
    variant_name_refs: []const wire.Span,
    include_refs: []const wire.Span,
    permutations: []const PermutationEntry,
    strings: []const u8,

    pub fn view(bytes: wire.Bytes) !ZShader {
        _ = try wire.FileHeader.validate(bytes, MAGIC, ZSHDR_VERSION);
        const header = try wire.structAt(Header, bytes, 0);
        const stage = try wire.enumFromInt(ShaderStage, header.stage);
        if (header.variant_count > max_variants) return error.TooManyVariants;
        if (header.include_count > max_includes) return error.TooManyIncludes;
        if (header.permutation_count > max_permutations) return error.TooManyPermutations;

        var order = wire.SectionOrder.init(HEADER_SIZE);
        for ([_]wire.Span{ header.variant_names, header.includes, header.permutations, header.strings }) |span| try order.next(span);
        try order.finish(bytes.len);

        const strings = try wire.sectionSlice(u8, bytes, header.strings, header.strings.len);
        const variant_names = try wire.sectionSlice(wire.Span, bytes, header.variant_names, header.variant_count);
        const includes = try wire.sectionSlice(wire.Span, bytes, header.includes, header.include_count);
        const permutations = try wire.sectionSlice(PermutationEntry, bytes, header.permutations, header.permutation_count);
        for (variant_names) |ref| try wire.checkString(strings, ref);
        for (includes) |ref| try wire.checkString(strings, ref);

        const valid_key_mask: u64 = (@as(u64, 1) << @intCast(header.variant_count)) - 1;
        var previous: ?u32 = null;
        for (permutations) |entry| {
            if (entry.key & ~valid_key_mask != 0) return error.InvalidVariantKey;
            if (previous) |p| if (entry.key <= p) return error.UnsortedPermutations;
            previous = entry.key;
            try wire.checkString(strings, entry.source);
        }

        return .{
            .stage = stage,
            .variant_name_refs = variant_names,
            .include_refs = includes,
            .permutations = permutations,
            .strings = strings,
        };
    }

    pub fn variantCount(self: *const ZShader) usize {
        return self.variant_name_refs.len;
    }

    pub fn variantName(self: *const ZShader, index: usize) []const u8 {
        return wire.stringAt(self.strings, self.variant_name_refs[index]);
    }

    pub fn includeCount(self: *const ZShader) usize {
        return self.include_refs.len;
    }

    pub fn include(self: *const ZShader, index: usize) []const u8 {
        return wire.stringAt(self.strings, self.include_refs[index]);
    }

    pub fn permutationSource(self: *const ZShader, index: usize) []const u8 {
        return wire.stringAt(self.strings, self.permutations[index].source);
    }

    pub fn baseSource(self: *const ZShader) ![]const u8 {
        return self.sourceFor(.base);
    }

    pub fn sourceFor(self: *const ZShader, key: VariantKey) ![]const u8 {
        const index = std.sort.binarySearch(PermutationEntry, self.permutations, key.bits, orderByKey) orelse
            return error.ShaderPermutationNotFound;
        return self.permutationSource(index);
    }

    fn orderByKey(key: u32, entry: PermutationEntry) std.math.Order {
        return std.math.order(key, entry.key);
    }

    pub fn variantKey(self: *const ZShader, enabled_variants: []const []const u8) !VariantKey {
        var key = VariantKey.base;
        for (enabled_variants) |enabled| {
            const index = self.variantIndex(enabled) orelse return error.UnknownShaderVariant;
            key = key.with(index);
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

pub fn view(bytes: wire.Bytes) !ZShader {
    return ZShader.view(bytes);
}

pub fn write(writer: *std.Io.Writer, cooked: CookedShader) !void {
    if (cooked.variant_names.len > max_variants) return error.TooManyVariants;
    if (cooked.includes.len > max_includes) return error.TooManyIncludes;
    if (cooked.permutations.len > max_permutations) return error.TooManyPermutations;
    if (cooked.permutations.len > 1) {
        for (cooked.permutations[1..], cooked.permutations[0 .. cooked.permutations.len - 1]) |perm, previous| {
            if (perm.key.bits <= previous.key.bits) return error.UnsortedPermutations;
        }
    }

    var string_bytes: usize = 0;
    for (cooked.variant_names) |name| string_bytes += name.len;
    for (cooked.includes) |name| string_bytes += name.len;
    for (cooked.permutations) |perm| string_bytes += perm.source.len;

    var layout = wire.Layout.init(HEADER_SIZE);
    const variant_names = try layout.reserve(cooked.variant_names.len * @sizeOf(wire.Span));
    const includes = try layout.reserve(cooked.includes.len * @sizeOf(wire.Span));
    const permutations = try layout.reserve(cooked.permutations.len * @sizeOf(PermutationEntry));
    const strings = try layout.reserve(string_bytes);
    const total_size = layout.totalSize();

    var out: wire.LayoutWriter = .{ .writer = writer };
    try out.value(Header{
        .file = .init(MAGIC, ZSHDR_VERSION, total_size),
        .stage = @intFromEnum(cooked.stage),
        .variant_count = @intCast(cooked.variant_names.len),
        .include_count = @intCast(cooked.includes.len),
        .permutation_count = @intCast(cooked.permutations.len),
        .variant_names = variant_names,
        .includes = includes,
        .permutations = permutations,
        .strings = strings,
    });

    var string_offset: u32 = 0;
    try out.beginSection(variant_names);
    for (cooked.variant_names) |name| try out.value(nextString(&string_offset, name));
    try out.beginSection(includes);
    for (cooked.includes) |name| try out.value(nextString(&string_offset, name));
    try out.beginSection(permutations);
    for (cooked.permutations) |perm| {
        try out.value(PermutationEntry{ .key = perm.key.bits, .source = nextString(&string_offset, perm.source) });
    }

    try out.beginSection(strings);
    for (cooked.variant_names) |name| try out.bytes(name);
    for (cooked.includes) |name| try out.bytes(name);
    for (cooked.permutations) |perm| try out.bytes(perm.source);
    try out.finish(total_size);
}

fn nextString(offset: *u32, text: []const u8) wire.Span {
    const span: wire.Span = .{ .offset = offset.*, .len = @intCast(text.len) };
    offset.* += span.len;
    return span;
}

const testing = std.testing;

fn makeCooked(variants: []const []const u8, includes: []const []const u8, perms: []const CookedShader.Permutation) !CookedShader {
    const permutations = try testing.allocator.alloc(CookedShader.Permutation, perms.len);
    for (perms, permutations) |src, *dst| dst.* = .{ .key = src.key, .source = try testing.allocator.dupe(u8, src.source) };
    return .{
        .stage = .vertex,
        .variant_names = try string_list.dupeStringList(testing.allocator, variants),
        .includes = try string_list.dupeStringList(testing.allocator, includes),
        .permutations = permutations,
    };
}

test "ZShader write and view round trips" {
    var cooked = try makeCooked(&.{"SKINNED"}, &.{"common.glsl"}, &.{
        .{ .key = .base, .source = "#version 330 core\n" },
        .{ .key = .fromBits(1), .source = "#version 330 core\n#define SKINNED\n" },
    });
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write(&writer, cooked);
    const bytes: wire.Bytes = buf[0..writer.end];

    try testing.expectEqualSlices(u8, MAGIC, bytes[0..4]);
    const shader = try ZShader.view(bytes);
    try testing.expectEqual(ShaderStage.vertex, shader.stage);
    try testing.expectEqualStrings("SKINNED", shader.variantName(0));
    try testing.expectEqualStrings("common.glsl", shader.include(0));
    try testing.expectEqual(@as(usize, 2), shader.permutations.len);
    try testing.expectEqualStrings("#version 330 core\n", try shader.baseSource());
    try testing.expectEqualStrings("#version 330 core\n#define SKINNED\n", try shader.sourceFor(.fromBits(1)));
    try testing.expectEqual(VariantKey.fromBits(1), try shader.variantKey(&.{"SKINNED"}));
    try testing.expectError(error.UnknownShaderVariant, shader.variantKey(&.{"MISSING"}));
}

test "ZShader.sourceFor reports missing permutations" {
    var cooked = try makeCooked(&.{ "A", "B" }, &.{}, &.{
        .{ .key = .base, .source = "base" },
        .{ .key = .fromBits(2), .source = "b" },
    });
    defer cooked.deinit(testing.allocator);

    var buf: [512]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write(&writer, cooked);

    const shader = try ZShader.view(buf[0..writer.end]);
    try testing.expectEqualStrings("b", try shader.sourceFor(.fromBits(2)));
    try testing.expectError(error.ShaderPermutationNotFound, shader.sourceFor(.fromBits(1)));
}

test "ZShader round trips a stage with no permutations" {
    var cooked = try makeCooked(&.{"SKINNED"}, &.{}, &.{});
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write(&writer, cooked);

    const shader = try ZShader.view(buf[0..writer.end]);
    try testing.expectEqualStrings("SKINNED", shader.variantName(0));
    try testing.expectError(error.ShaderPermutationNotFound, shader.baseSource());
}

test "write rejects unsorted permutations" {
    var cooked = try makeCooked(&.{"A"}, &.{}, &.{
        .{ .key = .fromBits(1), .source = "a" },
        .{ .key = .base, .source = "base" },
    });
    defer cooked.deinit(testing.allocator);

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.UnsortedPermutations, write(&writer, cooked));
}

test "ZShader.view rejects corrupted files" {
    var cooked = try makeCooked(&.{"A"}, &.{}, &.{
        .{ .key = .base, .source = "base" },
        .{ .key = .fromBits(1), .source = "a" },
    });
    defer cooked.deinit(testing.allocator);

    var buf: [512]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write(&writer, cooked);
    const len = writer.end;
    const header: *Header = @ptrCast(&buf);
    const entries: [*]PermutationEntry = @ptrCast(@alignCast(buf[header.permutations.offset..].ptr));

    entries[1].key = 4; // bit outside the declared variant set
    try testing.expectError(error.InvalidVariantKey, ZShader.view(buf[0..len]));
    entries[1].key = 0;
    try testing.expectError(error.UnsortedPermutations, ZShader.view(buf[0..len]));
    entries[1].key = 1;
    entries[1].source.len = 1000;
    try testing.expectError(error.InvalidStringRef, ZShader.view(buf[0..len]));
    entries[1].source.len = 1;
    header.stage = 99;
    try testing.expectError(error.InvalidEnumValue, ZShader.view(buf[0..len]));
    header.stage = 0;
    const permutations = header.permutations;
    header.permutations.offset = header.variant_names.offset;
    try testing.expectError(error.OverlappingSections, ZShader.view(buf[0..len]));
    header.permutations = permutations;
    _ = try ZShader.view(buf[0..len]);
    try testing.expectError(error.InvalidFileSize, ZShader.view(buf[0 .. len - 1]));
}
