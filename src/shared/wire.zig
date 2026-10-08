const std = @import("std");
const builtin = @import("builtin");

comptime {
    // Cooked formats are viewed in place, so their on-disk byte order must
    // match the host.
    if (builtin.cpu.arch.endian() != .little) @compileError("zimp cooked formats require a little-endian host");
}

pub const max_asset_bytes: usize = 512 * 1024 * 1024;

/// Every section of a cooked file starts on this boundary, and loaders hand
/// format views buffers with at least this alignment.
pub const section_alignment = 16;
pub const alignment: std.mem.Alignment = .fromByteUnits(section_alignment);
pub const Bytes = []align(section_alignment) const u8;

/// Common 16-byte prefix of every cooked asset file.
pub const FileHeader = extern struct {
    magic: [4]u8,
    version: u32,
    /// Exact file length in bytes; a mismatch means truncation or trailing junk.
    total_size: u32,
    /// Reserved for per-file codec flags. Must be zero.
    flags: u32 = 0,

    pub fn init(magic: *const [4]u8, version: u32, total_size: u32) FileHeader {
        return .{ .magic = magic.*, .version = version, .total_size = total_size };
    }

    /// Validates the prefix of `bytes` and returns it in place.
    pub fn validate(bytes: Bytes, magic: *const [4]u8, version: u32) !*const FileHeader {
        const header = try structAt(FileHeader, bytes, 0);
        if (!std.mem.eql(u8, &header.magic, magic)) return error.InvalidMagic;
        if (header.version != version) return error.UnsupportedVersion;
        if (header.total_size != bytes.len) return error.InvalidFileSize;
        if (header.flags != 0) return error.UnsupportedFlags;
        return header;
    }
};

/// A byte range. Offsets are relative to the file start for sections and to
/// the owning string blob for strings.
pub const Span = extern struct {
    offset: u32 = 0,
    len: u32 = 0,

    pub fn end(self: Span) u64 {
        return @as(u64, self.offset) + self.len;
    }
};

/// Fails compilation if `T` has implicit padding, which would make written
/// bytes nondeterministic.
pub fn assertTightLayout(comptime T: type) void {
    comptime {
        var sum: usize = 0;
        for (@typeInfo(T).@"struct".fields) |field| sum += @sizeOf(field.type);
        if (sum != @sizeOf(T)) @compileError(@typeName(T) ++ " has implicit padding");
        if (@alignOf(T) > section_alignment) @compileError(@typeName(T) ++ " is over-aligned");
    }
}

pub fn structAt(comptime T: type, bytes: Bytes, offset: usize) !*const T {
    return &(try sliceAt(T, bytes, offset, 1))[0];
}

/// Bounds- and alignment-checked typed view into `bytes`.
pub fn sliceAt(comptime T: type, bytes: Bytes, offset: usize, count: usize) ![]const T {
    if (offset % @alignOf(T) != 0) return error.MisalignedSection;
    const size = std.math.mul(usize, count, @sizeOf(T)) catch return error.Truncated;
    const end_offset = std.math.add(usize, offset, size) catch return error.Truncated;
    if (end_offset > bytes.len) return error.Truncated;
    const ptr: [*]const T = @ptrCast(@alignCast(bytes.ptr + offset));
    return ptr[0..count];
}

/// View a section that must hold exactly `count` elements of `T`.
pub fn sectionSlice(comptime T: type, bytes: Bytes, span: Span, count: usize) ![]const T {
    if (@as(u64, count) * @sizeOf(T) != span.len) return error.InvalidLayout;
    if (span.offset % section_alignment != 0) return error.MisalignedSection;
    return sliceAt(T, bytes, span.offset, count);
}

/// Enforces that sections appear in write order without overlapping. A file
/// that passes has exactly the layout `Layout` produces, so section sizes can
/// never sum past the file length.
pub const SectionOrder = struct {
    end: u64,

    pub fn init(fixed_bytes: usize) SectionOrder {
        return .{ .end = fixed_bytes };
    }

    /// Empty sections occupy no bytes and are ignored.
    pub fn next(self: *SectionOrder, span: Span) !void {
        if (span.len == 0) return;
        if (span.offset < self.end) return error.OverlappingSections;
        self.end = span.end();
    }
};

/// Validates that a string reference lies inside `blob`.
pub fn checkString(blob: []const u8, ref: Span) !void {
    if (ref.end() > blob.len) return error.InvalidStringRef;
}

/// Resolve a string reference already validated with `checkString`.
pub fn stringAt(blob: []const u8, ref: Span) []const u8 {
    return blob[ref.offset..][0..ref.len];
}

pub fn alignSection(offset: u64) u64 {
    return std.mem.alignForward(u64, offset, section_alignment);
}

/// Computes section offsets for a file before it is written.
pub const Layout = struct {
    size: u64,

    pub fn init(fixed_bytes: usize) Layout {
        return .{ .size = fixed_bytes };
    }

    /// Reserve an aligned section of `len` bytes. Empty sections get a zero span.
    pub fn reserve(self: *Layout, len: usize) !Span {
        if (len == 0) return .{};
        const offset = alignSection(self.size);
        self.size = offset + len;
        if (self.size > max_asset_bytes) return error.AssetTooLarge;
        return .{ .offset = @intCast(offset), .len = @intCast(len) };
    }

    pub fn totalSize(self: Layout) u32 {
        return @intCast(self.size);
    }
};

/// Writes a file laid out by `Layout`, tracking position so sections can be
/// padded to their reserved offsets.
pub const LayoutWriter = struct {
    writer: *std.Io.Writer,
    pos: u64 = 0,

    pub fn bytes(self: *LayoutWriter, data: []const u8) !void {
        try self.writer.writeAll(data);
        self.pos += data.len;
    }

    pub fn value(self: *LayoutWriter, v: anytype) !void {
        try self.bytes(std.mem.asBytes(&v));
    }

    pub fn slice(self: *LayoutWriter, items: anytype) !void {
        try self.bytes(std.mem.sliceAsBytes(items));
    }

    /// Zero-pad up to `offset`, which must not be behind the current position.
    pub fn padTo(self: *LayoutWriter, offset: u64) !void {
        std.debug.assert(offset >= self.pos);
        try self.writer.splatByteAll(0, @intCast(offset - self.pos));
        self.pos = offset;
    }

    /// Pad to the start of `span`. Empty sections occupy no bytes and are skipped.
    pub fn beginSection(self: *LayoutWriter, span: Span) !void {
        if (span.len == 0) return;
        try self.padTo(span.offset);
    }

    /// Pad to `span` and write `data` as that section.
    pub fn section(self: *LayoutWriter, span: Span, data: []const u8) !void {
        std.debug.assert(data.len == span.len);
        try self.beginSection(span);
        try self.bytes(data);
    }

    pub fn finish(self: *LayoutWriter, total_size: u32) !void {
        try self.padTo(total_size);
    }
};

pub fn enumFromInt(comptime E: type, raw: anytype) !E {
    return std.enums.fromInt(E, raw) orelse error.InvalidEnumValue;
}

// Streaming helpers for build-time files (the cook cache) that are not viewed in place.

pub fn checkedAddWithinLimit(total: *usize, amount: usize, limit: usize) !void {
    total.* = std.math.add(usize, total.*, amount) catch return error.AssetTooLarge;
    if (total.* > limit) return error.AssetTooLarge;
}

/// Write a u16 length prefix followed by the bytes.
pub fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeInt(u16, @intCast(value.len), .little);
    try writer.writeAll(value);
}

/// Read a string written by `writeString`. The caller owns the result.
pub fn readString(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const len = try reader.takeInt(u16, .little);
    const value = try allocator.alloc(u8, len);
    errdefer allocator.free(value);
    try reader.readSliceAll(value);
    return value;
}

test "Layout aligns sections and LayoutWriter pads to them" {
    const Header = extern struct { file: FileHeader, data: Span };
    assertTightLayout(Header);

    var layout = Layout.init(@sizeOf(Header));
    const data = try layout.reserve(3);
    try std.testing.expectEqual(@as(u32, 32), data.offset);
    try std.testing.expectEqual(Span{}, try layout.reserve(0));

    var buf: [64]u8 align(section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var out: LayoutWriter = .{ .writer = &writer };
    try out.value(Header{ .file = .init("TEST", 7, layout.totalSize()), .data = data });
    try out.section(data, "abc");
    try out.finish(layout.totalSize());

    const bytes: Bytes = buf[0..writer.end];
    _ = try FileHeader.validate(bytes, "TEST", 7);
    const header = try structAt(Header, bytes, 0);
    try std.testing.expectEqualStrings("abc", try sectionSlice(u8, bytes, header.data, 3));
}

test "FileHeader.validate rejects bad magic, version, and size" {
    var buf: [16]u8 align(section_alignment) = undefined;
    @memcpy(&buf, std.mem.asBytes(&FileHeader.init("GOOD", 1, 16)));
    try std.testing.expectError(error.InvalidMagic, FileHeader.validate(&buf, "BAD!", 1));
    try std.testing.expectError(error.UnsupportedVersion, FileHeader.validate(&buf, "GOOD", 2));
    try std.testing.expectError(error.Truncated, FileHeader.validate(buf[0..8], "GOOD", 1));

    var long: [32]u8 align(section_alignment) = @splat(0);
    @memcpy(long[0..16], std.mem.asBytes(&FileHeader.init("GOOD", 1, 32)));
    _ = try FileHeader.validate(&long, "GOOD", 1);
    try std.testing.expectError(error.InvalidFileSize, FileHeader.validate(long[0..16], "GOOD", 1));
}

test "SectionOrder rejects overlapping and out-of-order sections" {
    var order = SectionOrder.init(32);
    try order.next(.{ .offset = 32, .len = 8 });
    try order.next(.{});
    try std.testing.expectError(error.OverlappingSections, order.next(.{ .offset = 32, .len = 1 }));
    try order.next(.{ .offset = 48, .len = 1 });
    try std.testing.expectError(error.OverlappingSections, order.next(.{ .offset = 16, .len = 1 }));
}

test "sliceAt rejects out-of-bounds and misaligned views" {
    var buf: [32]u8 align(section_alignment) = @splat(0);
    try std.testing.expectError(error.Truncated, sliceAt(u32, &buf, 16, 5));
    try std.testing.expectError(error.MisalignedSection, sliceAt(u32, &buf, 2, 1));
    try std.testing.expectError(error.Truncated, sliceAt(u32, &buf, 0, std.math.maxInt(usize)));
}

test "writeString and readString round-trip" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeString(&writer, "cooked/mesh.zmesh");

    var reader = std.Io.Reader.fixed(writer.buffered());
    const value = try readString(std.testing.allocator, &reader);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("cooked/mesh.zmesh", value);
}

test "enumFromInt rejects invalid exhaustive enum values" {
    const E = enum(u8) { a = 0, b = 1 };
    try std.testing.expectEqual(E.b, try enumFromInt(E, 1));
    try std.testing.expectError(error.InvalidEnumValue, enumFromInt(E, 2));
}
