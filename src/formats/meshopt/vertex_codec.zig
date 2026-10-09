//! Port of meshoptimizer's vertex buffer codec (version 0, byte-compatible).
//! Each byte channel of a block is delta-coded against the previous vertex,
//! zigzagged, and packed in groups of 16 at 0/2/4/8 bits per value.
const std = @import("std");

const vertex_header: u8 = 0xa0;
const block_size_bytes = 8192;
const block_max_vertices = 256;
const group_size = 16;
const group_decode_limit = 24;
const tail_max_size = 32;

pub const max_stride = 256;

fn blockVertices(stride: usize) usize {
    const result = (block_size_bytes / stride) & ~@as(usize, group_size - 1);
    return @min(result, block_max_vertices);
}

fn tailSize(stride: usize) usize {
    return @max(stride, tail_max_size);
}

fn checkStride(stride: usize) !void {
    if (stride == 0 or stride > max_stride or stride % 4 != 0) return error.InvalidStride;
}

pub fn encodeBound(vertex_count: usize, stride: usize) usize {
    const block = blockVertices(stride);
    const block_count = (vertex_count + block - 1) / block;
    const header_size = (block / group_size + 3) / 4;
    return 1 + block_count * stride * (header_size + block) + tailSize(stride);
}

fn zigzag8(v: u8) u8 {
    return @as(u8, @bitCast(@as(i8, @bitCast(v)) >> 7)) ^ (v << 1);
}

fn measureGroup(group: *const [group_size]u8, bits: u4) usize {
    if (bits == 1) return if (std.mem.allEqual(u8, group, 0)) 0 else std.math.maxInt(usize);
    if (bits == 8) return group_size;
    const sentinel: u8 = (@as(u8, 1) << @intCast(bits)) - 1;
    var result: usize = group_size * @as(usize, bits) / 8;
    for (group) |v| result += @intFromBool(v >= sentinel);
    return result;
}

fn encodeGroup(out: []u8, pos: *usize, group: *const [group_size]u8, bits: u4) void {
    if (bits == 1) return;
    if (bits == 8) {
        @memcpy(out[pos.*..][0..group_size], group);
        pos.* += group_size;
        return;
    }
    const per_byte = 8 / @as(usize, bits);
    const sentinel: u8 = (@as(u8, 1) << @intCast(bits)) - 1;
    var i: usize = 0;
    while (i < group_size) : (i += per_byte) {
        var byte: u8 = 0;
        for (0..per_byte) |k| {
            const v = group[i + k];
            byte = (byte << @intCast(bits)) | @min(v, sentinel);
        }
        out[pos.*] = byte;
        pos.* += 1;
    }
    for (group) |v| if (v >= sentinel) {
        out[pos.*] = v;
        pos.* += 1;
    };
}

fn encodeBytes(out: []u8, pos: *usize, buffer: []const u8) !void {
    const header_size = (buffer.len / group_size + 3) / 4;
    if (out.len - pos.* < header_size) return error.NoSpaceLeft;
    const header = out[pos.*..][0..header_size];
    @memset(header, 0);
    pos.* += header_size;
    var i: usize = 0;
    while (i < buffer.len) : (i += group_size) {
        if (out.len - pos.* < group_decode_limit) return error.NoSpaceLeft;
        const group = buffer[i..][0..group_size];
        var best_bits: u4 = 8;
        var best_size = measureGroup(group, 8);
        for ([_]u4{ 1, 2, 4 }) |bits| {
            const size = measureGroup(group, bits);
            if (size < best_size) {
                best_bits = bits;
                best_size = size;
            }
        }
        const bitslog2: u8 = switch (best_bits) {
            1 => 0,
            2 => 1,
            4 => 2,
            else => 3,
        };
        const g = i / group_size;
        header[g / 4] |= bitslog2 << @intCast((g % 4) * 2);
        encodeGroup(out, pos, group, best_bits);
    }
}

/// Encodes `vertices` (`vertex_count * stride` bytes). Returns the encoded length.
pub fn encode(out: []u8, vertices: []const u8, stride: usize) !usize {
    try checkStride(stride);
    if (vertices.len % stride != 0) return error.InvalidLayout;
    const vertex_count = vertices.len / stride;
    if (out.len < 1 + stride) return error.NoSpaceLeft;
    out[0] = vertex_header;
    var pos: usize = 1;

    var first: [max_stride]u8 = @splat(0);
    if (vertex_count > 0) @memcpy(first[0..stride], vertices[0..stride]);
    var last = first;

    const block = blockVertices(stride);
    var buffer: [block_max_vertices]u8 = undefined;
    var offset: usize = 0;
    while (offset < vertex_count) {
        const count = @min(block, vertex_count - offset);
        const aligned = (count + group_size - 1) & ~@as(usize, group_size - 1);
        const src = vertices[offset * stride ..];
        for (0..stride) |k| {
            @memset(&buffer, 0);
            var p = last[k];
            for (0..count) |i| {
                const v = src[i * stride + k];
                buffer[i] = zigzag8(v -% p);
                p = v;
            }
            try encodeBytes(out, &pos, buffer[0..aligned]);
        }
        @memcpy(last[0..stride], src[(count - 1) * stride ..][0..stride]);
        offset += count;
    }

    const tail = tailSize(stride);
    if (out.len - pos < tail) return error.NoSpaceLeft;
    @memset(out[pos..][0 .. tail - stride], 0);
    pos += tail - stride;
    @memcpy(out[pos..][0..stride], first[0..stride]);
    return pos + stride;
}

const Vec16 = @Vector(group_size, u8);

/// Unpacks one group of 16 values. `data[pos..]` holds at least
/// `group_decode_limit` bytes (checked by the caller), which also covers the
/// 16-byte over-read of the sentinel bytes.
fn decodeGroup(data: []const u8, pos: *usize, bitslog2: u2) Vec16 {
    switch (bitslog2) {
        0 => return @splat(0),
        3 => {
            const v: Vec16 = data[pos.*..][0..group_size].*;
            pos.* += group_size;
            return v;
        },
        1 => {
            const fixed: @Vector(4, u8) = data[pos.*..][0..4].*;
            // Value j of byte b sits at bits 7-2j..6-2j (first value highest).
            const spread: Vec16 = @shuffle(u8, fixed, undefined, [16]i32{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 });
            const shifts: Vec16 = .{ 6, 4, 2, 0, 6, 4, 2, 0, 6, 4, 2, 0, 6, 4, 2, 0 };
            return resolveSentinels(data, pos, 4, (spread >> @intCast(shifts)) & @as(Vec16, @splat(3)), 3);
        },
        2 => {
            const fixed: @Vector(8, u8) = data[pos.*..][0..8].*;
            const spread: Vec16 = @shuffle(u8, fixed, undefined, [16]i32{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7 });
            const shifts: Vec16 = .{ 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0 };
            return resolveSentinels(data, pos, 8, (spread >> @intCast(shifts)) & @as(Vec16, @splat(15)), 15);
        },
    }
}

/// Replaces each sentinel value with the next full byte stored after the
/// fixed-width part, in order.
fn resolveSentinels(data: []const u8, pos: *usize, fixed_len: usize, values: Vec16, sentinel: u8) Vec16 {
    const extra_start = pos.* + fixed_len;
    const is_extra = values == @as(Vec16, @splat(sentinel));
    const mask: u16 = @bitCast(is_extra);
    if (mask == 0) {
        pos.* = extra_start;
        return values;
    }
    const extra: [group_size]u8 = data[extra_start..][0..group_size].*;
    var result: [group_size]u8 = values;
    var next: usize = 0;
    for (&result, 0..) |*r, i| {
        if ((mask >> @intCast(i)) & 1 != 0) {
            r.* = extra[next];
            next += 1;
        }
    }
    pos.* = extra_start + @popCount(mask);
    return result;
}

/// Inclusive prefix sum of 16 bytes (wrapping), as a log-step shift-add.
fn prefixSum(v: Vec16) Vec16 {
    const zero: Vec16 = @splat(0);
    var x = v;
    x +%= @shuffle(u8, x, zero, [16]i32{ -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 });
    x +%= @shuffle(u8, x, zero, [16]i32{ -1, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 });
    x +%= @shuffle(u8, x, zero, [16]i32{ -1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 });
    x +%= @shuffle(u8, x, zero, [16]i32{ -1, -1, -1, -1, -1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7 });
    return x;
}

/// Decodes one byte channel of a block (`aligned` values) into `channel`,
/// undoing zigzag and delta coding against `p`.
fn decodeChannel(data: []const u8, pos: *usize, channel: []u8, p: u8) !void {
    const header_size = (channel.len / group_size + 3) / 4;
    if (data.len - pos.* < header_size) return error.Truncated;
    const header = data[pos.*..][0..header_size];
    pos.* += header_size;
    var carry: Vec16 = @splat(p);
    var g: usize = 0;
    while (g * group_size < channel.len) : (g += 1) {
        // A group reads at most 24 bytes (4-bit: 8 fixed + 16 sentinels).
        if (data.len - pos.* < group_decode_limit) return error.Truncated;
        const bitslog2: u2 = @truncate(header[g / 4] >> @intCast((g % 4) * 2));
        const v = decodeGroup(data, pos, bitslog2);
        const one: Vec16 = @splat(1);
        const deltas = (@as(Vec16, @splat(0)) -% (v & one)) ^ (v >> one);
        const values = prefixSum(deltas) +% carry;
        channel[g * group_size ..][0..group_size].* = values;
        carry = @splat(values[group_size - 1]);
    }
}

/// Decodes into `out` (`vertex_count * stride` bytes). Never reads outside
/// `data`; malformed input returns an error.
pub fn decode(out: []u8, data: []const u8, stride: usize) !void {
    try checkStride(stride);
    if (out.len % stride != 0) return error.InvalidLayout;
    const vertex_count = out.len / stride;
    const tail = tailSize(stride);
    if (data.len < 1 + tail) return error.Truncated;
    if (data[0] & 0xf0 != vertex_header) return error.InvalidCodecHeader;
    if (data[0] & 0x0f != 0) return error.UnsupportedCodecVersion;
    var pos: usize = 1;

    var last: [max_stride]u8 = undefined;
    @memcpy(last[0..stride], data[data.len - stride ..]);

    const block = blockVertices(stride);
    // Channel-major block: channel k at `channels[k * aligned ..]`.
    var channels: [block_size_bytes]u8 align(16) = undefined;
    var offset: usize = 0;
    while (offset < vertex_count) {
        const count = @min(block, vertex_count - offset);
        const aligned = (count + group_size - 1) & ~@as(usize, group_size - 1);
        for (0..stride) |k| {
            try decodeChannel(data, &pos, channels[k * aligned ..][0..aligned], last[k]);
        }

        // Transpose four channels at a time into vertex-major order.
        const dst = out[offset * stride ..];
        var q: usize = 0;
        while (q < stride) : (q += 4) {
            const c0 = channels[(q + 0) * aligned ..];
            const c1 = channels[(q + 1) * aligned ..];
            const c2 = channels[(q + 2) * aligned ..];
            const c3 = channels[(q + 3) * aligned ..];
            var i: usize = 0;
            while (i < count) : (i += group_size) {
                const Wide = @Vector(group_size, u32);
                const a: Wide = @as(Vec16, c0[i..][0..group_size].*);
                const b: Wide = @as(Vec16, c1[i..][0..group_size].*);
                const c: Wide = @as(Vec16, c2[i..][0..group_size].*);
                const d: Wide = @as(Vec16, c3[i..][0..group_size].*);
                const words: [group_size]u32 = a | (b << @splat(8)) | (c << @splat(16)) | (d << @splat(24));
                for (words[0..@min(group_size, count - i)], 0..) |word, j| {
                    std.mem.writeInt(u32, dst[(i + j) * stride + q ..][0..4], word, .little);
                }
            }
        }
        for (0..stride) |k| last[k] = channels[k * aligned + count - 1];
        offset += count;
    }
    if (data.len - pos != tail) return error.InvalidLayout;
}

const testing = std.testing;

fn roundTrip(vertices: []const u8, stride: usize) !usize {
    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, encodeBound(vertices.len / stride, stride));
    defer allocator.free(buf);
    const len = try encode(buf, vertices, stride);
    const out = try allocator.alloc(u8, vertices.len);
    defer allocator.free(out);
    try decode(out, buf[0..len], stride);
    try testing.expectEqualSlices(u8, vertices, out);
    return len;
}

test "vertex codec round-trips degenerate sizes and strides" {
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    var data: [300 * 256]u8 = undefined;
    random.bytes(&data);
    for ([_]usize{ 4, 8, 12, 256 }) |stride| {
        for ([_]usize{ 0, 1, 15, 16, 17, 255, 256, 257, 300 }) |n| {
            _ = try roundTrip(data[0 .. n * stride], stride);
        }
    }
}

test "vertex codec compresses smooth data" {
    var verts: [4096][4]u16 = undefined;
    for (&verts, 0..) |*v, i| {
        const x: u16 = @intCast(i % 64);
        const y: u16 = @intCast(i / 64);
        v.* = .{ x * 1000, y * 1000, 7, 0 };
    }
    const bytes = std.mem.sliceAsBytes(&verts);
    const len = try roundTrip(bytes, 8);
    try testing.expect(len < bytes.len / 2);
}

test "vertex codec rejects every truncation and survives corruption" {
    var verts: [40][8]u8 = undefined;
    for (&verts, 0..) |*v, i| v.* = .{ @intCast(i), @intCast(i * 3), 0, 255, @intCast(i * 37 % 256), 1, 2, 3 };
    const bytes = std.mem.sliceAsBytes(&verts);
    var buf: [1024]u8 = undefined;
    const len = try encode(&buf, bytes, 8);
    var out: [40 * 8]u8 = undefined;
    for (0..len) |cut| try testing.expect(std.meta.isError(decode(&out, buf[0..cut], 8)));

    var prng = std.Random.DefaultPrng.init(5);
    const random = prng.random();
    var corrupt: [1024]u8 = undefined;
    for (0..2000) |_| {
        @memcpy(corrupt[0..len], buf[0..len]);
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| corrupt[random.uintLessThan(usize, len)] = random.int(u8);
        decode(&out, corrupt[0..len], 8) catch {};
    }
}
