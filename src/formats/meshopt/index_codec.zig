//! Port of meshoptimizer's index buffer codec (version 1, byte-compatible).
//! Triangles are coded against a 16-entry edge FIFO and vertex FIFO; free
//! indices are zigzag varint deltas. Decoded triangles may be rotated
//! (same winding) relative to the input.
const std = @import("std");

const index_header: u8 = 0xe0;
const version: u8 = 1;
const fecmax: u32 = 13;

const triangle_order = [3][3]u2{ .{ 0, 1, 2 }, .{ 1, 2, 0 }, .{ 2, 0, 1 } };

/// Static codeaux table; also serves as the 16-byte stream tail.
const codeaux_table = [16]u8{ 0x00, 0x76, 0x87, 0x56, 0x67, 0x78, 0xa9, 0x86, 0x65, 0x89, 0x68, 0x98, 0x01, 0x69, 0, 0 };

const no_index: u32 = std.math.maxInt(u32);

const Fifos = struct {
    edges: [16][2]u32 = @splat(.{ no_index, no_index }),
    verts: [16]u32 = @splat(no_index),
    edge_offset: u32 = 0,
    vert_offset: u32 = 0,

    fn pushEdge(self: *Fifos, a: u32, b: u32) void {
        self.edges[self.edge_offset] = .{ a, b };
        self.edge_offset = (self.edge_offset + 1) & 15;
    }

    fn pushVertex(self: *Fifos, v: u32, cond: bool) void {
        self.verts[self.vert_offset] = v;
        self.vert_offset = (self.vert_offset + @intFromBool(cond)) & 15;
    }

    fn findEdge(self: *const Fifos, a: u32, b: u32, c: u32) ?u32 {
        for (0..16) |i| {
            const e = self.edges[(self.edge_offset -% 1 -% @as(u32, @intCast(i))) & 15];
            const fi: u32 = @intCast(i << 2);
            if (e[0] == a and e[1] == b) return fi | 0;
            if (e[0] == b and e[1] == c) return fi | 1;
            if (e[0] == c and e[1] == a) return fi | 2;
        }
        return null;
    }

    fn findVertex(self: *const Fifos, v: u32) ?u32 {
        for (0..16) |i| {
            if (self.verts[(self.vert_offset -% 1 -% @as(u32, @intCast(i))) & 15] == v) return @intCast(i);
        }
        return null;
    }

    fn vertexAt(self: *const Fifos, back: u32) u32 {
        return self.verts[(self.vert_offset -% back) & 15];
    }
};

pub fn encodeBound(index_count: usize, vertex_count: usize) usize {
    var vertex_bits: u6 = 1;
    while (vertex_bits < 32 and vertex_count > (@as(usize, 1) << vertex_bits)) vertex_bits += 1;
    const vertex_groups: usize = (@as(usize, vertex_bits) + 1 + 6) / 7;
    return 1 + (index_count / 3) * (2 + 3 * vertex_groups) + 16;
}

fn encodeVByte(out: []u8, pos: *usize, value: u32) void {
    var v = value;
    while (true) {
        out[pos.*] = @as(u8, @truncate(v & 127)) | (if (v > 127) @as(u8, 128) else 0);
        pos.* += 1;
        v >>= 7;
        if (v == 0) break;
    }
}

fn encodeIndex(out: []u8, pos: *usize, index: u32, last: u32) void {
    const d = index -% last;
    const sign: u32 = @bitCast(@as(i32, @bitCast(d)) >> 31);
    encodeVByte(out, pos, (d << 1) ^ sign);
}

/// Encodes a triangle list. Returns the encoded length, or `error.NoSpaceLeft`.
pub fn encode(out: []u8, indices: []const u32) !usize {
    if (indices.len % 3 != 0) return error.InvalidIndexCount;
    const tri_count = indices.len / 3;
    if (out.len < 1 + tri_count + 16) return error.NoSpaceLeft;
    out[0] = index_header | version;

    var f: Fifos = .{};
    var next: u32 = 0;
    var last: u32 = 0;
    var code: usize = 1;
    var data: usize = 1 + tri_count;
    const data_safe_end = out.len - 16;

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        if (data > data_safe_end) return error.NoSpaceLeft;
        const tri = indices[i..][0..3];
        const fer = f.findEdge(tri[0], tri[1], tri[2]);
        if (fer != null and (fer.? >> 2) < 15) {
            const order = triangle_order[fer.? & 3];
            const a = tri[order[0]];
            const b = tri[order[1]];
            const c = tri[order[2]];
            const fe = fer.? >> 2;
            const fc = f.findVertex(c);
            var fec: u32 = if (fc != null and fc.? >= 1 and fc.? < fecmax) fc.? else if (c == next) blk: {
                next +%= 1;
                break :blk 0;
            } else 15;
            if (fec == 15) {
                if (c +% 1 == last) {
                    fec = 13;
                    last = c;
                }
                if (c == last +% 1) {
                    fec = 14;
                    last = c;
                }
            }
            out[code] = @intCast((fe << 4) | fec);
            code += 1;
            if (fec == 15) {
                encodeIndex(out, &data, c, last);
                last = c;
            }
            if (fec == 0 or fec >= fecmax) f.pushVertex(c, true);
            f.pushEdge(c, b);
            f.pushEdge(a, c);
        } else {
            const rotation: usize = if (tri[1] == next) 1 else if (tri[2] == next) 2 else 0;
            const order = triangle_order[rotation];
            const a = tri[order[0]];
            const b = tri[order[1]];
            const c = tri[order[2]];

            var reset = false;
            if (a == 0 and b == 1 and c == 2 and next > 0) {
                reset = true;
                next = 0;
                f.verts = @splat(no_index);
            }
            const fb = f.findVertex(b);
            const fc = f.findVertex(c);

            const fea: u32 = if (a == next) blk: {
                next +%= 1;
                break :blk 0;
            } else 15;
            const feb: u32 = if (fb != null and fb.? < 14) fb.? + 1 else if (b == next) blk: {
                next +%= 1;
                break :blk 0;
            } else 15;
            const fec: u32 = if (fc != null and fc.? < 14) fc.? + 1 else if (c == next) blk: {
                next +%= 1;
                break :blk 0;
            } else 15;

            const codeaux: u8 = @intCast((feb << 4) | fec);
            const aux_index = std.mem.indexOfScalar(u8, &codeaux_table, codeaux);
            if (fea == 0 and aux_index != null and aux_index.? < 14 and !reset) {
                out[code] = @intCast((15 << 4) | aux_index.?);
            } else {
                out[code] = @intCast((15 << 4) | 14 | fea);
                out[data] = codeaux;
                data += 1;
            }
            code += 1;

            if (fea == 15) {
                encodeIndex(out, &data, a, last);
                last = a;
            }
            if (feb == 15) {
                encodeIndex(out, &data, b, last);
                last = b;
            }
            if (fec == 15) {
                encodeIndex(out, &data, c, last);
                last = c;
            }
            if (fea == 0 or fea == 15) f.pushVertex(a, true);
            if (feb == 0 or feb == 15) f.pushVertex(b, true);
            if (fec == 0 or fec == 15) f.pushVertex(c, true);
            f.pushEdge(b, a);
            f.pushEdge(c, b);
            f.pushEdge(a, c);
        }
    }

    if (data > data_safe_end) return error.NoSpaceLeft;
    @memcpy(out[data..][0..16], &codeaux_table);
    return data + 16;
}

fn decodeVByte(data: []const u8, pos: *usize) u32 {
    const lead = data[pos.*];
    pos.* += 1;
    if (lead < 128) return lead;
    var result: u32 = lead & 127;
    var shift: u5 = 7;
    for (0..4) |_| {
        const group = data[pos.*];
        pos.* += 1;
        result |= @as(u32, group & 127) << shift;
        if (group < 128) break;
        shift +|= 7;
    }
    return result;
}

fn decodeIndex(data: []const u8, pos: *usize, last: u32) u32 {
    const v = decodeVByte(data, pos);
    const d = (v >> 1) ^ (0 -% (v & 1));
    return last +% d;
}

/// Decodes into `out` (u16 or u32). Never reads outside `data`; malformed
/// input returns an error. Index values are not range-checked here.
pub fn decode(comptime T: type, out: []T, data: []const u8) !void {
    comptime std.debug.assert(T == u16 or T == u32);
    if (out.len % 3 != 0) return error.InvalidIndexCount;
    const tri_count = out.len / 3;
    if (data.len < 1 + tri_count + 16) return error.Truncated;
    if (data[0] & 0xf0 != index_header) return error.InvalidCodecHeader;
    if (data[0] & 0x0f != version) return error.UnsupportedCodecVersion;

    var f: Fifos = .{};
    var next: u32 = 0;
    var last: u32 = 0;
    var code: usize = 1;
    var pos: usize = 1 + tri_count;
    const data_safe_end = data.len - 16;
    const table = data[data_safe_end..][0..16];

    var i: usize = 0;
    while (i < out.len) : (i += 3) {
        // Each triangle reads at most 16 data bytes; the 16-byte tail pads that.
        if (pos > data_safe_end) return error.Truncated;
        const codetri = data[code];
        code += 1;
        var a: u32 = undefined;
        var b: u32 = undefined;
        var c: u32 = undefined;

        if (codetri < 0xf0) {
            const fe: u32 = codetri >> 4;
            const edge = f.edges[(f.edge_offset -% 1 -% fe) & 15];
            a = edge[0];
            b = edge[1];
            const fec: u32 = codetri & 15;
            if (fec < fecmax) {
                c = if (fec == 0) next else f.vertexAt(1 + fec);
                next +%= @intFromBool(fec == 0);
                f.pushVertex(c, fec == 0);
            } else {
                c = if (fec != 15) (if (fec == 13) last -% 1 else last +% 1) else decodeIndex(data, &pos, last);
                last = c;
                f.pushVertex(c, true);
            }
            f.pushEdge(c, b);
            f.pushEdge(a, c);
        } else if (codetri < 0xfe) {
            const codeaux = table[codetri & 15];
            const feb: u32 = codeaux >> 4;
            const fec: u32 = codeaux & 15;
            a = next;
            next +%= 1;
            b = if (feb == 0) next else f.vertexAt(feb);
            next +%= @intFromBool(feb == 0);
            c = if (fec == 0) next else f.vertexAt(fec);
            next +%= @intFromBool(fec == 0);
            f.pushVertex(a, true);
            f.pushVertex(b, feb == 0);
            f.pushVertex(c, fec == 0);
            f.pushEdge(b, a);
            f.pushEdge(c, b);
            f.pushEdge(a, c);
        } else {
            const codeaux = data[pos];
            pos += 1;
            const fea: u32 = if (codetri == 0xfe) 0 else 15;
            const feb: u32 = codeaux >> 4;
            const fec: u32 = codeaux & 15;
            if (codeaux == 0) next = 0;
            a = 0;
            if (fea == 0) {
                a = next;
                next +%= 1;
            }
            if (feb == 0) {
                b = next;
                next +%= 1;
            } else b = f.vertexAt(feb);
            if (fec == 0) {
                c = next;
                next +%= 1;
            } else c = f.vertexAt(fec);
            if (fea == 15) {
                a = decodeIndex(data, &pos, last);
                last = a;
            }
            if (feb == 15) {
                b = decodeIndex(data, &pos, last);
                last = b;
            }
            if (fec == 15) {
                c = decodeIndex(data, &pos, last);
                last = c;
            }
            f.pushVertex(a, true);
            f.pushVertex(b, feb == 0 or feb == 15);
            f.pushVertex(c, fec == 0 or fec == 15);
            f.pushEdge(b, a);
            f.pushEdge(c, b);
            f.pushEdge(a, c);
        }

        if (T == u16 and (a > 0xffff or b > 0xffff or c > 0xffff)) return error.IndexOutOfRange;
        out[i + 0] = @intCast(a);
        out[i + 1] = @intCast(b);
        out[i + 2] = @intCast(c);
    }
    if (pos != data_safe_end) return error.InvalidLayout;
}

const testing = std.testing;

/// Triangles must match up to rotation (winding is preserved).
fn expectSameTriangles(expected: []const u32, actual: anytype) !void {
    try testing.expectEqual(expected.len, actual.len);
    var i: usize = 0;
    while (i < expected.len) : (i += 3) {
        const e = expected[i..][0..3];
        const a = [3]u32{ actual[i], actual[i + 1], actual[i + 2] };
        const ok = for (triangle_order) |o| {
            if (a[0] == e[o[0]] and a[1] == e[o[1]] and a[2] == e[o[2]]) break true;
        } else false;
        if (!ok) {
            std.debug.print("triangle {d}: expected {any}, got {any}\n", .{ i / 3, e.*, a });
            return error.TestExpectedEqual;
        }
    }
}

fn gridIndices(allocator: std.mem.Allocator, n: u32) ![]u32 {
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(allocator);
    for (0..n) |y| for (0..n) |x| {
        const v: u32 = @intCast(y * (n + 1) + x);
        try list.appendSlice(allocator, &.{ v, v + n + 1, v + 1, v + 1, v + n + 1, v + n + 2 });
    };
    return list.toOwnedSlice(allocator);
}

fn roundTrip(indices: []const u32, vertex_count: usize) !usize {
    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, encodeBound(indices.len, vertex_count));
    defer allocator.free(buf);
    const len = try encode(buf, indices);
    const out = try allocator.alloc(u32, indices.len);
    defer allocator.free(out);
    try decode(u32, out, buf[0..len]);
    try expectSameTriangles(indices, out);
    return len;
}

test "index codec round-trips a grid and compresses it" {
    const indices = try gridIndices(testing.allocator, 64);
    defer testing.allocator.free(indices);
    const len = try roundTrip(indices, 65 * 65);
    try testing.expect(len < indices.len); // well under 1 byte per index
}

test "index codec round-trips empty, single, reset, and random triangles" {
    _ = try roundTrip(&.{}, 0);
    _ = try roundTrip(&.{ 0, 1, 2 }, 3);
    _ = try roundTrip(&.{ 0, 1, 2, 2, 1, 3, 0, 1, 2, 5, 4, 3 }, 6); // 0,1,2 again triggers a reset
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var indices: [3000]u32 = undefined;
    for (&indices) |*v| v.* = random.intRangeLessThan(u32, 0, 100_000);
    _ = try roundTrip(&indices, 100_000);
}

test "index codec decodes u16 output" {
    const indices = try gridIndices(testing.allocator, 8);
    defer testing.allocator.free(indices);
    var buf: [4096]u8 = undefined;
    const len = try encode(&buf, indices);
    var out: [8 * 8 * 6]u16 = undefined;
    try decode(u16, &out, buf[0..len]);
    try expectSameTriangles(indices, &out);
}

test "index codec rejects every truncation and survives corruption" {
    const indices = try gridIndices(testing.allocator, 8);
    defer testing.allocator.free(indices);
    var buf: [4096]u8 = undefined;
    const len = try encode(&buf, indices);
    var out: [8 * 8 * 6]u32 = undefined;
    for (0..len) |cut| try testing.expect(std.meta.isError(decode(u32, &out, buf[0..cut])));

    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();
    var corrupt: [4096]u8 = undefined;
    for (0..2000) |_| {
        @memcpy(corrupt[0..len], buf[0..len]);
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| corrupt[random.uintLessThan(usize, len)] = random.int(u8);
        decode(u32, &out, corrupt[0..len]) catch {};
    }
}
