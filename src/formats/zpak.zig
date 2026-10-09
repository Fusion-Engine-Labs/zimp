//! `.zpak`: every cooked asset of a build in one file, viewed in place.
//!
//! A pack is opened once (mmapped) and its table of contents is used where
//! it lies: lookup is a binary search over entries sorted by (kind, id).
//! Payloads are the cooked files byte for byte (`Codec.none`, viewed in
//! place) or chunked zstd frames (`Codec.zstd`, decoded into a buffer).

const std = @import("std");

pub const MAGIC = @import("../shared/constants.zig").FORMAT_MAGIC.ZPAK;
pub const ZPAK_VERSION: u32 = 1;

const wire = @import("../shared/wire.zig");
const path = @import("../path.zig");
const AssetKind = @import("../assets/asset.zig").AssetKind;
const AssetId = @import("../id/id_types.zig").AssetId;

/// Uncompressed bytes per zstd frame. Frames decode independently, so a
/// reader can decode only a prefix (texture mips are stored smallest first)
/// or decode the frames of one entry in parallel.
pub const chunk_size: u32 = 256 * 1024;

/// Payloads at least this large start on an `io_alignment` boundary, so they
/// share no partial page or disk block with a neighbor. Smaller payloads are
/// packed at `wire.section_alignment` so that many share a page.
pub const large_payload_bytes: u64 = 64 * 1024;
pub const io_alignment: u64 = 4096;

/// Alignment of the entry table that follows the last payload.
const toc_alignment: u64 = wire.section_alignment;

pub const kind_count = std.enums.values(AssetKind).len;

pub const Codec = enum(u8) {
    /// The payload is the cooked asset file byte for byte.
    none = 0,
    /// The payload is one zstd frame per `chunk_size` bytes of the asset.
    zstd = 1,
};

/// File layout:
///   `Header`
///   payloads in entry order, each at `payloadOffset(previous end, stored_size)`
///   `Entry[entry_count]` at `toc_offset`, 16-byte aligned after the last payload
///   `u32[chunk_count]` chunk end offsets, right after the entries
///   `names_size` bytes of entry names, right after the chunks; they end the file
pub const Header = extern struct {
    magic: [4]u8,
    version: u32,
    /// Reserved. Must be zero.
    flags: u32 = 0,
    entry_count: u32,
    chunk_count: u32,
    names_size: u32,
    toc_offset: u64,
    /// Exact pack length. Packs are not limited to 4 GiB.
    file_size: u64,
};

/// One asset. Entries are sorted by (kind, id), so each kind is a contiguous
/// range sorted by id.
pub const Entry = extern struct {
    id: wire.AssetRef,
    /// File offset of the stored payload.
    offset: u64,
    /// Payload bytes in the pack.
    stored_size: u32,
    /// Bytes of the cooked asset, which is also its `wire.FileHeader.total_size`.
    size: u32,
    /// Index of this entry's first chunk. Chunks are numbered in entry order
    /// and only zstd entries have any.
    first_chunk: u32,
    /// Cooked path, as a range of the name blob. Only for diagnostics and tools.
    name: wire.Span,
    kind: u8,
    codec: u8,
    _reserved: u16 = 0,
};

comptime {
    wire.assertTightLayout(Header);
    wire.assertTightLayout(Entry);
}

pub fn payloadAlignment(stored_size: u64) u64 {
    return if (stored_size >= large_payload_bytes) io_alignment else wire.section_alignment;
}

/// Where a payload of `stored_size` bytes starts when the previous one ended at `end`.
fn payloadOffset(end: u64, stored_size: u64) u64 {
    return std.mem.alignForward(u64, end, payloadAlignment(stored_size));
}

/// Number of zstd frames for an asset of `size` bytes.
pub fn chunkCount(size: u32) u32 {
    return @intCast((@as(u64, size) + chunk_size - 1) / chunk_size);
}

/// Uncompressed length of chunk `k` of an asset of `size` bytes.
pub fn chunkLen(size: u32, k: u32) u32 {
    return @min(chunk_size, size - k * chunk_size);
}

const Toc = struct {
    chunks: u64,
    names: u64,
    end: u64,
};

fn tocLayout(toc_offset: u64, entry_count: u32, chunk_count: u32, names_size: u32) !Toc {
    const chunks = std.math.add(u64, toc_offset, @as(u64, entry_count) * @sizeOf(Entry)) catch return error.Truncated;
    const names = std.math.add(u64, chunks, @as(u64, chunk_count) * @sizeOf(u32)) catch return error.Truncated;
    const end = std.math.add(u64, names, names_size) catch return error.Truncated;
    return .{ .chunks = chunks, .names = names, .end = end };
}

fn orderKeys(a_kind: u8, a_id: *const [16]u8, b_kind: u8, b_id: *const [16]u8) std.math.Order {
    if (a_kind != b_kind) return std.math.order(a_kind, b_kind);
    return std.mem.order(u8, a_id, b_id);
}

/// Entries must be strictly increasing by (kind, id).
fn checkOrder(prev: *const Entry, next: *const Entry) !void {
    switch (orderKeys(prev.kind, &prev.id.bytes, next.kind, &next.id.bytes)) {
        .lt => {},
        .eq => return error.DuplicateAssetId,
        .gt => return error.UnsortedEntries,
    }
}

/// `result[k]..result[k + 1]` is the range of kind `k` in entries sorted by kind.
fn kindStarts(entries: []const Entry) [kind_count + 1]u32 {
    var starts: [kind_count + 1]u32 = undefined;
    var next_kind: usize = 0;
    for (entries, 0..) |entry, i| {
        while (next_kind <= entry.kind) : (next_kind += 1) starts[next_kind] = @intCast(i);
    }
    while (next_kind <= kind_count) : (next_kind += 1) starts[next_kind] = @intCast(entries.len);
    return starts;
}

/// Ids are unique within a kind because each kind is strictly sorted. A
/// k-way merge of the kind ranges puts equal ids next to each other, so ids
/// repeated across kinds are found in O(n) as well.
fn checkUniqueIds(entries: []const Entry, starts: [kind_count + 1]u32) !void {
    var heads: [kind_count]u32 = starts[0..kind_count].*;
    var last: ?*const [16]u8 = null;
    for (0..entries.len) |_| {
        var best: ?usize = null;
        for (0..kind_count) |k| {
            if (heads[k] == starts[k + 1]) continue;
            if (best) |b| {
                if (std.mem.order(u8, &entries[heads[k]].id.bytes, &entries[heads[b]].id.bytes) != .lt) continue;
            }
            best = k;
        }
        const k = best.?;
        const id = &entries[heads[k]].id.bytes;
        if (last) |prev| if (std.mem.eql(u8, prev, id)) return error.DuplicateAssetId;
        last = id;
        heads[k] += 1;
    }
}

pub const Range = struct {
    start: u32,
    end: u32,
};

/// Zero-copy view of a pack. Borrows the bytes it was created from.
pub const ZPak = struct {
    bytes: wire.Bytes,
    entries: []const Entry,
    chunk_ends: []const u32,
    names: []const u8,
    kind_start: [kind_count + 1]u32,

    /// Validates the header and table of contents. A pack that passes has
    /// exactly the layout `Writer` produces: payloads in entry order at the
    /// offsets the alignment rule gives, no gaps, overlaps, or trailing bytes.
    /// Payload contents are validated per asset when they are loaded.
    pub fn view(bytes: wire.Bytes) !ZPak {
        const header = try wire.structAt(Header, bytes, 0);
        if (!std.mem.eql(u8, &header.magic, MAGIC)) return error.InvalidMagic;
        if (header.version != ZPAK_VERSION) return error.UnsupportedVersion;
        if (header.file_size != bytes.len) return error.InvalidFileSize;
        if (header.flags != 0) return error.UnsupportedFlags;

        const toc = try tocLayout(header.toc_offset, header.entry_count, header.chunk_count, header.names_size);
        if (toc.end > bytes.len) return error.Truncated;
        if (toc.end != bytes.len) return error.InvalidLayout;
        if (header.toc_offset < @sizeOf(Header) or header.toc_offset % toc_alignment != 0) return error.InvalidLayout;
        // Every table now lies inside `bytes`, so its offset fits a usize.
        const entries = try wire.sliceAt(Entry, bytes, @intCast(header.toc_offset), header.entry_count);
        const chunk_ends = try wire.sliceAt(u32, bytes, @intCast(toc.chunks), header.chunk_count);
        const names = bytes[@intCast(toc.names)..];

        var payload_end: u64 = @sizeOf(Header);
        var chunk_index: u32 = 0;
        var name_end: u32 = 0;
        for (entries, 0..) |*entry, i| {
            _ = try wire.enumFromInt(AssetKind, entry.kind);
            const codec = try wire.enumFromInt(Codec, entry.codec);
            if (entry._reserved != 0) return error.InvalidLayout;
            try entry.id.check();
            if (i > 0) try checkOrder(&entries[i - 1], entry);
            if (entry.size < @sizeOf(wire.FileHeader)) return error.InvalidLayout;
            if (entry.size > wire.max_asset_bytes) return error.AssetTooLarge;

            if (entry.offset != payloadOffset(payload_end, entry.stored_size)) return error.InvalidLayout;
            payload_end = entry.offset + entry.stored_size;
            if (payload_end > header.toc_offset) return error.InvalidLayout;

            if (entry.first_chunk != chunk_index) return error.InvalidLayout;
            switch (codec) {
                .none => if (entry.stored_size != entry.size) return error.InvalidLayout,
                .zstd => {
                    if (entry.stored_size >= entry.size) return error.InvalidLayout;
                    const chunks = chunkCount(entry.size);
                    if (chunks > chunk_ends.len - chunk_index) return error.InvalidLayout;
                    var end: u32 = 0;
                    for (chunk_ends[chunk_index..][0..chunks]) |chunk_end| {
                        if (chunk_end <= end) return error.InvalidLayout;
                        end = chunk_end;
                    }
                    if (end != entry.stored_size) return error.InvalidLayout;
                    chunk_index += chunks;
                },
            }

            if (entry.name.offset != name_end or entry.name.end() > names.len) return error.InvalidLayout;
            path.validateVirtual(wire.stringAt(names, entry.name)) catch return error.InvalidName;
            name_end += entry.name.len;
        }
        if (chunk_index != chunk_ends.len) return error.InvalidLayout;
        if (name_end != names.len) return error.InvalidLayout;
        if (header.toc_offset != std.mem.alignForward(u64, payload_end, toc_alignment)) return error.InvalidLayout;

        const starts = kindStarts(entries);
        try checkUniqueIds(entries, starts);
        return .{
            .bytes = bytes,
            .entries = entries,
            .chunk_ends = chunk_ends,
            .names = names,
            .kind_start = starts,
        };
    }

    pub fn count(self: *const ZPak) u32 {
        return @intCast(self.entries.len);
    }

    /// Indices of every entry of `kind`, sorted by id.
    pub fn kindRange(self: *const ZPak, kind: AssetKind) Range {
        const k = @intFromEnum(kind);
        return .{ .start = self.kind_start[k], .end = self.kind_start[k + 1] };
    }

    pub fn findKind(self: *const ZPak, kind: AssetKind, id: AssetId) ?u32 {
        const range = self.kindRange(kind);
        var lo = range.start;
        var hi = range.end;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, &self.entries[mid].id.bytes, &id.uuid.bytes)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    pub fn find(self: *const ZPak, id: AssetId) ?u32 {
        for (std.enums.values(AssetKind)) |kind| {
            if (self.findKind(kind, id)) |index| return index;
        }
        return null;
    }

    pub fn idAt(self: *const ZPak, index: u32) AssetId {
        return self.entries[index].id.toId();
    }

    pub fn kindAt(self: *const ZPak, index: u32) AssetKind {
        return @enumFromInt(self.entries[index].kind);
    }

    pub fn codecAt(self: *const ZPak, index: u32) Codec {
        return @enumFromInt(self.entries[index].codec);
    }

    pub fn nameAt(self: *const ZPak, index: u32) []const u8 {
        return wire.stringAt(self.names, self.entries[index].name);
    }

    /// The stored payload, compressed or not.
    pub fn payload(self: *const ZPak, index: u32) []const u8 {
        const entry = &self.entries[index];
        return self.bytes[@intCast(entry.offset)..][0..entry.stored_size];
    }

    /// The cooked asset bytes of a `none` entry, in place and aligned for views.
    pub fn rawBytes(self: *const ZPak, index: u32) wire.Bytes {
        std.debug.assert(self.codecAt(index) == .none);
        return @alignCast(self.payload(index));
    }

    /// Frame `k` of a `zstd` entry; it decodes to `chunkLen(size, k)` bytes.
    pub fn frame(self: *const ZPak, index: u32, k: u32) []const u8 {
        const entry = &self.entries[index];
        std.debug.assert(self.codecAt(index) == .zstd and k < chunkCount(entry.size));
        const ends = self.chunk_ends[entry.first_chunk..];
        const start = if (k == 0) 0 else ends[k - 1];
        return self.payload(index)[start..ends[k]];
    }
};

pub fn view(bytes: wire.Bytes) !ZPak {
    return ZPak.view(bytes);
}

/// Streams a pack: a placeholder header, then each payload as it is added,
/// then the table of contents. Only the table is buffered. The caller writes
/// the `Header` returned by `finish` over the first `@sizeOf(Header)` bytes.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    pos: u64,
    entries: std.ArrayList(Entry) = .empty,
    chunk_ends: std.ArrayList(u32) = .empty,
    names: std.ArrayList(u8) = .empty,

    pub const Payload = union(Codec) {
        /// The cooked asset file.
        none: []const u8,
        /// `chunkCount(size)` frames, which must total fewer bytes than `size`.
        zstd: struct { size: u32, frames: []const []const u8 },
    };

    pub const Item = struct {
        id: AssetId,
        kind: AssetKind,
        /// Cooked path.
        name: []const u8,
        payload: Payload,
    };

    pub fn init(gpa: std.mem.Allocator, out: *std.Io.Writer) !Writer {
        try out.splatByteAll(0, @sizeOf(Header));
        return .{ .gpa = gpa, .out = out, .pos = @sizeOf(Header) };
    }

    pub fn deinit(self: *Writer) void {
        self.entries.deinit(self.gpa);
        self.chunk_ends.deinit(self.gpa);
        self.names.deinit(self.gpa);
        self.* = undefined;
    }

    /// Items must be added in strictly increasing (kind, id) order. Checks
    /// everything `ZPak.view` does, so the writer can't produce a pack the
    /// view rejects.
    pub fn add(self: *Writer, item: Item) !void {
        if (item.id.isZero()) return error.ZeroAssetRef;
        path.validateVirtual(item.name) catch return error.InvalidName;

        const size: u64, const stored: u64, const frame_count: usize = switch (item.payload) {
            .none => |bytes| .{ bytes.len, bytes.len, 0 },
            .zstd => |z| blk: {
                if (z.frames.len != chunkCount(z.size)) return error.InvalidLayout;
                var total: u64 = 0;
                for (z.frames) |f| {
                    if (f.len == 0) return error.InvalidLayout;
                    total += f.len;
                }
                if (total >= z.size) return error.InvalidLayout;
                break :blk .{ z.size, total, z.frames.len };
            },
        };
        if (size < @sizeOf(wire.FileHeader)) return error.InvalidLayout;
        if (size > wire.max_asset_bytes) return error.AssetTooLarge;
        if (self.entries.items.len >= std.math.maxInt(u32) or
            frame_count > std.math.maxInt(u32) - self.chunk_ends.items.len or
            item.name.len > std.math.maxInt(u32) - self.names.items.len)
            return error.PackTooLarge;

        const entry: Entry = .{
            .id = .fromId(item.id),
            .offset = payloadOffset(self.pos, stored),
            .stored_size = @intCast(stored),
            .size = @intCast(size),
            .first_chunk = @intCast(self.chunk_ends.items.len),
            .name = .{ .offset = @intCast(self.names.items.len), .len = @intCast(item.name.len) },
            .kind = @intFromEnum(item.kind),
            .codec = @intFromEnum(item.payload),
        };
        if (self.entries.items.len > 0) try checkOrder(&self.entries.items[self.entries.items.len - 1], &entry);

        // Reserve first so a failed allocation can't leave a half-recorded entry.
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        try self.chunk_ends.ensureUnusedCapacity(self.gpa, frame_count);
        try self.names.ensureUnusedCapacity(self.gpa, item.name.len);

        try self.out.splatByteAll(0, @intCast(entry.offset - self.pos));
        switch (item.payload) {
            .none => |bytes| try self.out.writeAll(bytes),
            .zstd => |z| {
                var end: u32 = 0;
                for (z.frames) |f| {
                    try self.out.writeAll(f);
                    end += @intCast(f.len);
                    self.chunk_ends.appendAssumeCapacity(end);
                }
            },
        }
        self.pos = entry.offset + stored;
        self.names.appendSliceAssumeCapacity(item.name);
        self.entries.appendAssumeCapacity(entry);
    }

    /// Writes the table of contents and returns the header for offset 0.
    pub fn finish(self: *Writer) !Header {
        try checkUniqueIds(self.entries.items, kindStarts(self.entries.items));

        const toc_offset = std.mem.alignForward(u64, self.pos, toc_alignment);
        try self.out.splatByteAll(0, @intCast(toc_offset - self.pos));
        try self.out.writeAll(std.mem.sliceAsBytes(self.entries.items));
        try self.out.writeAll(std.mem.sliceAsBytes(self.chunk_ends.items));
        try self.out.writeAll(self.names.items);

        const entry_count: u32 = @intCast(self.entries.items.len);
        const chunk_count: u32 = @intCast(self.chunk_ends.items.len);
        const names_size: u32 = @intCast(self.names.items.len);
        const toc = try tocLayout(toc_offset, entry_count, chunk_count, names_size);
        self.pos = toc.end;
        return .{
            .magic = MAGIC.*,
            .version = ZPAK_VERSION,
            .entry_count = entry_count,
            .chunk_count = chunk_count,
            .names_size = names_size,
            .toc_offset = toc_offset,
            .file_size = toc.end,
        };
    }
};

const testing = std.testing;

const id_a = AssetId.parseComptime("11111111-1111-4111-8111-111111111111");
const id_b = AssetId.parseComptime("22222222-2222-4222-8222-222222222222");
const id_c = AssetId.parseComptime("33333333-3333-4333-8333-333333333333");
const id_d = AssetId.parseComptime("44444444-4444-4444-8444-444444444444");

/// Writes `items` into an aligned buffer the way the pack command writes a file.
fn buildPack(items: []const Writer.Item) ![]align(wire.section_alignment) u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer = try Writer.init(testing.allocator, &out.writer);
    defer writer.deinit();
    for (items) |item| try writer.add(item);
    const header = try writer.finish();

    const written = out.written();
    try testing.expectEqual(header.file_size, written.len);
    const bytes = try testing.allocator.alignedAlloc(u8, wire.alignment, written.len);
    @memcpy(bytes, written);
    @memcpy(bytes[0..@sizeOf(Header)], std.mem.asBytes(&header));
    return bytes;
}

fn filled(buf: []u8, seed: u8) []u8 {
    for (buf, 0..) |*b, i| b.* = seed +% @as(u8, @truncate(i * 7));
    return buf;
}

var small_mesh: [40]u8 = undefined;
var large_texture: [large_payload_bytes + 5]u8 = undefined;
var shader: [100]u8 = undefined;
const two_frames: []const []const u8 = &.{ "frame-zero", "frame-one!" };

fn sampleItems() [4]Writer.Item {
    return .{
        .{ .id = id_b, .kind = .mesh, .name = "meshes/b.zmesh", .payload = .{ .none = filled(&small_mesh, 1) } },
        .{ .id = id_c, .kind = .mesh, .name = "meshes/c.zmesh", .payload = .{ .zstd = .{ .size = chunk_size + 100, .frames = two_frames } } },
        .{ .id = id_a, .kind = .texture, .name = "textures/a.ztex", .payload = .{ .none = filled(&large_texture, 2) } },
        .{ .id = id_d, .kind = .shader_stage, .name = "shaders/d.vert.zshdr", .payload = .{ .none = filled(&shader, 3) } },
    };
}

fn samplePack() ![]align(wire.section_alignment) u8 {
    return buildPack(&sampleItems());
}

fn headerOf(bytes: []u8) *align(1) Header {
    return std.mem.bytesAsValue(Header, bytes[0..@sizeOf(Header)]);
}

fn entryOf(bytes: []u8, index: usize) *align(1) Entry {
    const offset: usize = @intCast(headerOf(bytes).toc_offset + index * @sizeOf(Entry));
    return std.mem.bytesAsValue(Entry, bytes[offset..][0..@sizeOf(Entry)]);
}

test "Header and Entry sizes are fixed" {
    try testing.expectEqual(@as(usize, 40), @sizeOf(Header));
    try testing.expectEqual(@as(usize, 48), @sizeOf(Entry));
}

test "Writer output views back with lookups, names, and payloads" {
    const items = sampleItems();
    const bytes = try buildPack(&items);
    defer testing.allocator.free(bytes);
    const pak = try ZPak.view(bytes);

    try testing.expectEqual(@as(u32, 4), pak.count());
    try testing.expectEqual(Range{ .start = 0, .end = 2 }, pak.kindRange(.mesh));
    try testing.expectEqual(Range{ .start = 2, .end = 3 }, pak.kindRange(.texture));
    try testing.expectEqual(Range{ .start = 3, .end = 4 }, pak.kindRange(.shader_stage));
    try testing.expectEqual(Range{ .start = 4, .end = 4 }, pak.kindRange(.material));

    for (items, 0..) |item, i| {
        const index: u32 = @intCast(i);
        try testing.expectEqual(index, pak.find(item.id).?);
        try testing.expectEqual(index, pak.findKind(item.kind, item.id).?);
        try testing.expect(pak.idAt(index).eql(item.id));
        try testing.expectEqual(item.kind, pak.kindAt(index));
        try testing.expectEqualStrings(item.name, pak.nameAt(index));
        switch (item.payload) {
            .none => |raw| {
                const view_bytes = pak.rawBytes(index);
                try testing.expectEqualSlices(u8, raw, view_bytes);
                try testing.expectEqual(@as(u64, 0), (@intFromPtr(view_bytes.ptr) - @intFromPtr(bytes.ptr)) % payloadAlignment(raw.len));
            },
            .zstd => |z| for (z.frames, 0..) |f, k| try testing.expectEqualStrings(f, pak.frame(index, @intCast(k))),
        }
    }
    try testing.expect(pak.findKind(.texture, id_b) == null);
    try testing.expect(pak.find(AssetId.parseComptime("55555555-5555-4555-8555-555555555555")) == null);

    // The large payload is page aligned; the small ones are packed at 16 bytes.
    try testing.expectEqual(@as(u64, 0), pak.entries[2].offset % io_alignment);
    try testing.expectEqual(@as(u64, 48), pak.entries[0].offset);
    try testing.expectEqual(@as(u32, 2), chunkCount(chunk_size + 100));
    try testing.expectEqual(@as(u32, 100), chunkLen(chunk_size + 100, 1));
}

test "Writer output is deterministic" {
    const a = try samplePack();
    defer testing.allocator.free(a);
    const b = try samplePack();
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
}

test "an empty pack is a header and an aligned empty table" {
    const bytes = try buildPack(&.{});
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 48), bytes.len);
    const pak = try ZPak.view(bytes);
    try testing.expectEqual(@as(u32, 0), pak.count());
    try testing.expect(pak.find(id_a) == null);
}

test "Writer rejects what the view would reject" {
    var mesh: [32]u8 = @splat(1);
    const Case = struct { items: []const Writer.Item, err: anyerror };
    const cases = [_]Case{
        .{ .items = &.{
            .{ .id = id_b, .kind = .mesh, .name = "b", .payload = .{ .none = &mesh } },
            .{ .id = id_a, .kind = .mesh, .name = "a", .payload = .{ .none = &mesh } },
        }, .err = error.UnsortedEntries },
        .{ .items = &.{
            .{ .id = id_a, .kind = .texture, .name = "a", .payload = .{ .none = &mesh } },
            .{ .id = id_a, .kind = .mesh, .name = "b", .payload = .{ .none = &mesh } },
        }, .err = error.UnsortedEntries },
        .{ .items = &.{
            .{ .id = id_a, .kind = .mesh, .name = "a", .payload = .{ .none = &mesh } },
            .{ .id = id_a, .kind = .mesh, .name = "b", .payload = .{ .none = &mesh } },
        }, .err = error.DuplicateAssetId },
        .{ .items = &.{
            .{ .id = id_a, .kind = .mesh, .name = "a", .payload = .{ .none = &mesh } },
            .{ .id = id_a, .kind = .texture, .name = "b", .payload = .{ .none = &mesh } },
        }, .err = error.DuplicateAssetId },
        .{ .items = &.{.{ .id = .zero, .kind = .mesh, .name = "a", .payload = .{ .none = &mesh } }}, .err = error.ZeroAssetRef },
        .{ .items = &.{.{ .id = id_a, .kind = .mesh, .name = "../a", .payload = .{ .none = &mesh } }}, .err = error.InvalidName },
        .{ .items = &.{.{ .id = id_a, .kind = .mesh, .name = "", .payload = .{ .none = &mesh } }}, .err = error.InvalidName },
        .{ .items = &.{.{ .id = id_a, .kind = .mesh, .name = "a", .payload = .{ .none = mesh[0..15] } }}, .err = error.InvalidLayout },
        .{ .items = &.{.{ .id = id_a, .kind = .mesh, .name = "a", .payload = .{ .zstd = .{ .size = 1000, .frames = two_frames } } }}, .err = error.InvalidLayout },
        .{ .items = &.{.{ .id = id_a, .kind = .mesh, .name = "a", .payload = .{ .zstd = .{ .size = 20, .frames = &.{"twenty bytes exactly"} } } }}, .err = error.InvalidLayout },
        .{ .items = &.{.{ .id = id_a, .kind = .mesh, .name = "a", .payload = .{ .zstd = .{ .size = 100, .frames = &.{""} } } }}, .err = error.InvalidLayout },
    };
    for (cases) |case| try testing.expectError(case.err, buildPack(case.items));
}

test "view rejects corrupt headers" {
    const original = try samplePack();
    defer testing.allocator.free(original);
    const bytes = try testing.allocator.alignedAlloc(u8, wire.alignment, original.len);
    defer testing.allocator.free(bytes);

    const Mutation = struct {
        fn apply(buf: []u8, comptime field: []const u8, value: anytype) void {
            @field(headerOf(buf), field) = value;
        }
    };

    @memcpy(bytes, original);
    bytes[0] = 'X';
    try testing.expectError(error.InvalidMagic, ZPak.view(bytes));

    @memcpy(bytes, original);
    Mutation.apply(bytes, "version", ZPAK_VERSION + 1);
    try testing.expectError(error.UnsupportedVersion, ZPak.view(bytes));

    @memcpy(bytes, original);
    Mutation.apply(bytes, "flags", 1);
    try testing.expectError(error.UnsupportedFlags, ZPak.view(bytes));

    @memcpy(bytes, original);
    Mutation.apply(bytes, "file_size", original.len + 1);
    try testing.expectError(error.InvalidFileSize, ZPak.view(bytes));

    @memcpy(bytes, original);
    Mutation.apply(bytes, "toc_offset", headerOf(original).toc_offset + 16);
    try testing.expectError(error.Truncated, ZPak.view(bytes));

    @memcpy(bytes, original);
    Mutation.apply(bytes, "toc_offset", std.math.maxInt(u64) - 8);
    try testing.expectError(error.Truncated, ZPak.view(bytes));

    @memcpy(bytes, original);
    Mutation.apply(bytes, "entry_count", std.math.maxInt(u32));
    try testing.expectError(error.Truncated, ZPak.view(bytes));

    // Moving the table one entry later and shrinking the names keeps the
    // total size, but the table no longer follows the last payload.
    @memcpy(bytes, original);
    Mutation.apply(bytes, "toc_offset", headerOf(original).toc_offset + @sizeOf(Entry));
    Mutation.apply(bytes, "names_size", headerOf(original).names_size - @sizeOf(Entry));
    try testing.expectError(error.InvalidLayout, ZPak.view(bytes));

    @memcpy(bytes, original);
    Mutation.apply(bytes, "chunk_count", headerOf(original).chunk_count - 1);
    Mutation.apply(bytes, "names_size", headerOf(original).names_size + 4);
    try testing.expectError(error.InvalidLayout, ZPak.view(bytes));

    // Trailing bytes.
    const longer = try testing.allocator.alignedAlloc(u8, wire.alignment, original.len + 1);
    defer testing.allocator.free(longer);
    @memcpy(longer[0..original.len], original);
    longer[original.len] = 0;
    headerOf(longer).file_size = longer.len;
    try testing.expectError(error.InvalidLayout, ZPak.view(longer));
}

test "view rejects corrupt entries" {
    const original = try samplePack();
    defer testing.allocator.free(original);
    const bytes = try testing.allocator.alignedAlloc(u8, wire.alignment, original.len);
    defer testing.allocator.free(bytes);

    const Case = struct {
        index: usize,
        mutate: *const fn (*align(1) Entry) void,
        err: anyerror,
    };
    const m = struct {
        fn badKind(e: *align(1) Entry) void {
            e.kind = 9;
        }
        fn badCodec(e: *align(1) Entry) void {
            e.codec = 7;
        }
        fn reserved(e: *align(1) Entry) void {
            e._reserved = 1;
        }
        fn zeroId(e: *align(1) Entry) void {
            e.id = .{ .bytes = @splat(0) };
        }
        fn sameId(e: *align(1) Entry) void {
            e.id = .fromId(id_b);
        }
        fn lowerId(e: *align(1) Entry) void {
            e.id = .fromId(id_a);
        }
        fn crossKindDuplicate(e: *align(1) Entry) void {
            e.id = .fromId(id_b);
        }
        fn shiftOffset(e: *align(1) Entry) void {
            e.offset += 16;
        }
        fn shrinkStored(e: *align(1) Entry) void {
            e.stored_size -= 1;
        }
        fn growSize(e: *align(1) Entry) void {
            e.size += 1;
        }
        fn tinySize(e: *align(1) Entry) void {
            e.size = 8;
            e.stored_size = 8;
        }
        fn hugeSize(e: *align(1) Entry) void {
            e.size = @intCast(wire.max_asset_bytes + 1);
        }
        fn noneWithChunks(e: *align(1) Entry) void {
            e.codec = @intFromEnum(Codec.none);
        }
        fn zstdNotSmaller(e: *align(1) Entry) void {
            e.codec = @intFromEnum(Codec.zstd);
        }
        fn firstChunk(e: *align(1) Entry) void {
            e.first_chunk += 1;
        }
        fn nameGap(e: *align(1) Entry) void {
            e.name.offset += 1;
        }
        fn nameEmpty(e: *align(1) Entry) void {
            e.name.len = 0;
        }
    };
    const cases = [_]Case{
        .{ .index = 0, .mutate = m.badKind, .err = error.InvalidEnumValue },
        .{ .index = 0, .mutate = m.badCodec, .err = error.InvalidEnumValue },
        .{ .index = 0, .mutate = m.reserved, .err = error.InvalidLayout },
        .{ .index = 0, .mutate = m.zeroId, .err = error.ZeroAssetRef },
        .{ .index = 1, .mutate = m.sameId, .err = error.DuplicateAssetId },
        .{ .index = 1, .mutate = m.lowerId, .err = error.UnsortedEntries },
        .{ .index = 2, .mutate = m.crossKindDuplicate, .err = error.DuplicateAssetId },
        .{ .index = 0, .mutate = m.shiftOffset, .err = error.InvalidLayout },
        .{ .index = 3, .mutate = m.shrinkStored, .err = error.InvalidLayout },
        .{ .index = 0, .mutate = m.growSize, .err = error.InvalidLayout },
        .{ .index = 0, .mutate = m.tinySize, .err = error.InvalidLayout },
        .{ .index = 1, .mutate = m.hugeSize, .err = error.AssetTooLarge },
        .{ .index = 1, .mutate = m.noneWithChunks, .err = error.InvalidLayout },
        .{ .index = 0, .mutate = m.zstdNotSmaller, .err = error.InvalidLayout },
        .{ .index = 2, .mutate = m.firstChunk, .err = error.InvalidLayout },
        .{ .index = 1, .mutate = m.nameGap, .err = error.InvalidLayout },
        .{ .index = 3, .mutate = m.nameEmpty, .err = error.InvalidName },
    };
    for (cases) |case| {
        @memcpy(bytes, original);
        case.mutate(entryOf(bytes, case.index));
        try testing.expectError(case.err, ZPak.view(bytes));
    }

    // Chunk ends must increase and end at the stored size.
    const chunks_at: usize = @intCast(headerOf(original).toc_offset + 4 * @sizeOf(Entry));
    @memcpy(bytes, original);
    std.mem.writeInt(u32, bytes[chunks_at..][0..4], 0, .little);
    try testing.expectError(error.InvalidLayout, ZPak.view(bytes));
    @memcpy(bytes, original);
    std.mem.writeInt(u32, bytes[chunks_at + 4 ..][0..4], 19, .little);
    try testing.expectError(error.InvalidLayout, ZPak.view(bytes));

    // Names must be valid virtual paths.
    const names_at = original.len - headerOf(original).names_size;
    @memcpy(bytes, original);
    @memcpy(bytes[names_at..][0..3], "../");
    try testing.expectError(error.InvalidName, ZPak.view(bytes));
}

test "view rejects every truncation and survives single-byte corruption" {
    const original = try samplePack();
    defer testing.allocator.free(original);
    for (0..original.len) |len| {
        try testing.expect(std.meta.isError(ZPak.view(original[0..len])));
    }

    const bytes = try testing.allocator.alignedAlloc(u8, wire.alignment, original.len);
    defer testing.allocator.free(bytes);
    for (0..original.len) |i| {
        @memcpy(bytes, original);
        bytes[i] ^= 0xa5;
        const pak = ZPak.view(bytes) catch continue;
        // Anything that still validates must stay in bounds.
        for (0..pak.count()) |index| {
            const idx: u32 = @intCast(index);
            _ = pak.nameAt(idx);
            switch (pak.codecAt(idx)) {
                .none => _ = pak.rawBytes(idx),
                .zstd => for (0..chunkCount(pak.entries[idx].size)) |k| {
                    _ = pak.frame(idx, @intCast(k));
                },
            }
        }
    }
}
