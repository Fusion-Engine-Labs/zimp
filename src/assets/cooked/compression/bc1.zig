const std = @import("std");

const compression = @import("compression.zig");

/// Encode an RGBA8 image as BC1 (opaque, 4-color mode). Alpha is ignored.
/// `src` must be `width * height * 4` bytes. `dst` must be
/// `ceil(width/4) * ceil(height/4) * 8` bytes.
pub fn encode(src: []const u8, width: u32, height: u32, dst: []u8) void {
    std.debug.assert(src.len == @as(usize, width) * @as(usize, height) * 4);
    const blocks_x = (width + 3) / 4;
    const blocks_y = (height + 3) / 4;
    std.debug.assert(dst.len == @as(usize, blocks_x) * @as(usize, blocks_y) * 8);

    var block: [16][4]u8 = undefined;
    for (0..blocks_y) |by| {
        for (0..blocks_x) |bx| {
            compression.extractBlock4x4(src, width, height, 4, @as(u32, @intCast(bx)) * 4, @as(u32, @intCast(by)) * 4, std.mem.asBytes(&block));
            const encoded = encodeColorBlock(&block);
            @memcpy(dst[(by * blocks_x + bx) * 8 ..][0..8], &encoded);
        }
    }
}

/// Encode the RGB channels of a 4x4 block as an 8-byte BC1 color block.
///
/// Always emits 4-color mode (`color0 > color1`), or `color0 == color1` with
/// every index 0. Either way no texel decodes as BC1's punch-through black, so
/// the block is also valid as the color half of a BC3 block, which always
/// decodes in 4-color mode.
pub fn encodeColorBlock(block: *const [16][4]u8) [8]u8 {
    var solid = true;
    for (block[1..]) |px| {
        if (px[0] != block[0][0] or px[1] != block[0][1] or px[2] != block[0][2]) {
            solid = false;
            break;
        }
    }
    if (solid) return encodeSolid(block[0]);

    var best = fitEndpoints(block);
    var best_error = blockError(block, best);

    // Least-squares refinement against the current index assignment. Two
    // passes capture nearly all of the gain (same as stb_dxt's high quality).
    for (0..2) |_| {
        const refined = refineEndpoints(block, best.indices) orelse break;
        if (refined.c0 == best.c0 and refined.c1 == best.c1) break;
        const candidate = assignIndices(block, refined.c0, refined.c1);
        const candidate_error = blockError(block, candidate);
        if (candidate_error >= best_error) break;
        best = candidate;
        best_error = candidate_error;
    }

    return pack(best);
}

const Fit = struct {
    c0: u16,
    c1: u16,
    /// 2 bits per texel, texel `i` at bit `2 * i`.
    indices: u32,
};

fn pack(fit: Fit) [8]u8 {
    var c0 = fit.c0;
    var c1 = fit.c1;
    var indices = fit.indices;
    if (c0 < c1) {
        // Swapping the endpoints maps index 0<->1 and 2<->3.
        std.mem.swap(u16, &c0, &c1);
        indices ^= 0x5555_5555;
    } else if (c0 == c1) {
        indices = 0;
    }

    var out: [8]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], c0, .little);
    std.mem.writeInt(u16, out[2..4], c1, .little);
    std.mem.writeInt(u32, out[4..8], indices, .little);
    return out;
}

/// Endpoints from the extremes of the block along its principal axis.
fn fitEndpoints(block: *const [16][4]u8) Fit {
    var mean = [3]f32{ 0, 0, 0 };
    for (block) |px| {
        for (0..3) |c| mean[c] += @floatFromInt(px[c]);
    }
    for (&mean) |*m| m.* /= 16.0;

    // Covariance: xx, xy, xz, yy, yz, zz.
    var cov = [6]f32{ 0, 0, 0, 0, 0, 0 };
    for (block) |px| {
        const r = @as(f32, @floatFromInt(px[0])) - mean[0];
        const g = @as(f32, @floatFromInt(px[1])) - mean[1];
        const b = @as(f32, @floatFromInt(px[2])) - mean[2];
        cov[0] += r * r;
        cov[1] += r * g;
        cov[2] += r * b;
        cov[3] += g * g;
        cov[4] += g * b;
        cov[5] += b * b;
    }

    // Power iteration, seeded with the covariance column of the channel with
    // the most variance. (Seeding with the bounding-box diagonal can land in
    // the null space: red/green alternation gives diagonal (1,1,0) but the
    // only variance is along (1,-1,0).)
    const variance_channel: usize = if (cov[0] >= cov[3] and cov[0] >= cov[5]) 0 else if (cov[3] >= cov[5]) 1 else 2;
    var axis: [3]f32 = switch (variance_channel) {
        0 => .{ cov[0], cov[1], cov[2] },
        1 => .{ cov[1], cov[3], cov[4] },
        else => .{ cov[2], cov[4], cov[5] },
    };
    for (0..4) |_| {
        const next = [3]f32{
            axis[0] * cov[0] + axis[1] * cov[1] + axis[2] * cov[2],
            axis[0] * cov[1] + axis[1] * cov[3] + axis[2] * cov[4],
            axis[0] * cov[2] + axis[1] * cov[4] + axis[2] * cov[5],
        };
        const len = @max(@abs(next[0]), @max(@abs(next[1]), @abs(next[2])));
        if (len < 1e-6) break;
        axis = .{ next[0] / len, next[1] / len, next[2] / len };
    }

    var min_dot: f32 = std.math.inf(f32);
    var max_dot: f32 = -std.math.inf(f32);
    var min_px: [4]u8 = block[0];
    var max_px: [4]u8 = block[0];
    for (block) |px| {
        const dot = @as(f32, @floatFromInt(px[0])) * axis[0] +
            @as(f32, @floatFromInt(px[1])) * axis[1] +
            @as(f32, @floatFromInt(px[2])) * axis[2];
        if (dot < min_dot) {
            min_dot = dot;
            min_px = px;
        }
        if (dot > max_dot) {
            max_dot = dot;
            max_px = px;
        }
    }

    return assignIndices(block, to565(max_px[0], max_px[1], max_px[2]), to565(min_px[0], min_px[1], min_px[2]));
}

/// Solves for the endpoints that minimize squared error given fixed indices.
/// Returns null when every texel uses the same weight (singular system).
fn refineEndpoints(block: *const [16][4]u8, indices: u32) ?struct { c0: u16, c1: u16 } {
    // Weight of color0 for each 4-color-mode index.
    const w0 = [4]f32{ 1.0, 0.0, 2.0 / 3.0, 1.0 / 3.0 };
    var aa: f32 = 0;
    var ab: f32 = 0;
    var bb: f32 = 0;
    var ax = [3]f32{ 0, 0, 0 };
    var bx = [3]f32{ 0, 0, 0 };
    for (block, 0..) |px, i| {
        const idx: u2 = @truncate(indices >> @intCast(2 * i));
        const a = w0[idx];
        const b = 1.0 - a;
        aa += a * a;
        ab += a * b;
        bb += b * b;
        for (0..3) |c| {
            const v: f32 = @floatFromInt(px[c]);
            ax[c] += a * v;
            bx[c] += b * v;
        }
    }

    const det = aa * bb - ab * ab;
    if (@abs(det) < 1e-6) return null;
    var e0: [3]f32 = undefined;
    var e1: [3]f32 = undefined;
    for (0..3) |c| {
        e0[c] = (bb * ax[c] - ab * bx[c]) / det;
        e1[c] = (aa * bx[c] - ab * ax[c]) / det;
    }
    return .{ .c0 = to565f(e0), .c1 = to565f(e1) };
}

fn assignIndices(block: *const [16][4]u8, c0: u16, c1: u16) Fit {
    const palette = decodePalette(c0, c1);
    var indices: u32 = 0;
    for (block, 0..) |px, i| {
        var best_idx: u32 = 0;
        var best_err: u32 = std.math.maxInt(u32);
        for (palette, 0..) |entry, idx| {
            const err = colorDistance(px, entry);
            if (err < best_err) {
                best_err = err;
                best_idx = @intCast(idx);
            }
        }
        indices |= best_idx << @intCast(2 * i);
    }
    return .{ .c0 = c0, .c1 = c1, .indices = indices };
}

fn blockError(block: *const [16][4]u8, fit: Fit) u32 {
    const palette = decodePalette(fit.c0, fit.c1);
    var total: u32 = 0;
    for (block, 0..) |px, i| {
        const idx: u2 = @truncate(fit.indices >> @intCast(2 * i));
        total += colorDistance(px, palette[idx]);
    }
    return total;
}

fn colorDistance(a: [4]u8, b: [3]u8) u32 {
    var total: u32 = 0;
    for (0..3) |c| {
        const d = @as(i32, a[c]) - @as(i32, b[c]);
        total += @intCast(d * d);
    }
    return total;
}

/// 4-color-mode palette in 8-bit RGB.
fn decodePalette(c0: u16, c1: u16) [4][3]u8 {
    const e0 = expand565(c0);
    const e1 = expand565(c1);
    var palette: [4][3]u8 = undefined;
    for (0..3) |c| {
        const a: u32 = e0[c];
        const b: u32 = e1[c];
        palette[0][c] = e0[c];
        palette[1][c] = e1[c];
        palette[2][c] = @intCast((2 * a + b) / 3);
        palette[3][c] = @intCast((a + 2 * b) / 3);
    }
    return palette;
}

fn expand565(c: u16) [3]u8 {
    const r: u8 = @intCast(c >> 11);
    const g: u8 = @intCast((c >> 5) & 0x3f);
    const b: u8 = @intCast(c & 0x1f);
    return .{ expand5(r), expand6(g), expand5(b) };
}

fn expand5(v: u8) u8 {
    return (v << 3) | (v >> 2);
}

fn expand6(v: u8) u8 {
    return (v << 2) | (v >> 4);
}

fn to565(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, quantize(r, 31)) << 11) | (@as(u16, quantize(g, 63)) << 5) | quantize(b, 31);
}

fn quantize(v: u8, max: u16) u16 {
    return @intCast((@as(u32, v) * max + 127) / 255);
}

fn to565f(v: [3]f32) u16 {
    const r = std.math.clamp(@round(v[0] * 31.0 / 255.0), 0, 31);
    const g = std.math.clamp(@round(v[1] * 63.0 / 255.0), 0, 63);
    const b = std.math.clamp(@round(v[2] * 31.0 / 255.0), 0, 31);
    return (@as(u16, @intFromFloat(r)) << 11) | (@as(u16, @intFromFloat(g)) << 5) | @as(u16, @intFromFloat(b));
}

/// For each 8-bit value, the endpoint pair whose 2/3-1/3 interpolation
/// (index 2) is closest to it. Lets a solid block hit colors that 565 can't
/// store directly.
fn buildSingleColorTable(comptime bits: u4) [256][2]u8 {
    @setEvalBranchQuota(10_000_000);
    const levels: u32 = 1 << bits;
    var table: [256][2]u8 = undefined;
    for (0..256) |v_index| {
        const v: u32 = v_index;
        var best_cost: u32 = std.math.maxInt(u32);
        for (0..levels) |a| {
            for (0..levels) |b| {
                const ea: u32 = if (bits == 5) expand5(@intCast(a)) else expand6(@intCast(a));
                const eb: u32 = if (bits == 5) expand5(@intCast(b)) else expand6(@intCast(b));
                const interp = (2 * ea + eb) / 3;
                const diff = if (interp > v) interp - v else v - interp;
                // Prefer close endpoints on ties: decoders differ slightly in
                // how they round the interpolation.
                const spread = if (ea > eb) ea - eb else eb - ea;
                const cost = diff * 1024 + spread;
                if (cost < best_cost) {
                    best_cost = cost;
                    table[v_index] = .{ @intCast(a), @intCast(b) };
                }
            }
        }
    }
    return table;
}

const single5 = buildSingleColorTable(5);
const single6 = buildSingleColorTable(6);

fn encodeSolid(px: [4]u8) [8]u8 {
    const r = single5[px[0]];
    const g = single6[px[1]];
    const b = single5[px[2]];
    const c0 = (@as(u16, r[0]) << 11) | (@as(u16, g[0]) << 5) | b[0];
    const c1 = (@as(u16, r[1]) << 11) | (@as(u16, g[1]) << 5) | b[1];
    return pack(.{ .c0 = c0, .c1 = c1, .indices = 0xAAAA_AAAA });
}

/// Test-only reference decoder for one BC1 block (4-color or 3-color mode).
pub fn decodeBlock(bytes: [8]u8) [16][3]u8 {
    const c0 = std.mem.readInt(u16, bytes[0..2], .little);
    const c1 = std.mem.readInt(u16, bytes[2..4], .little);
    const indices = std.mem.readInt(u32, bytes[4..8], .little);
    var palette = decodePalette(c0, c1);
    if (c0 <= c1) {
        const e0 = expand565(c0);
        const e1 = expand565(c1);
        for (0..3) |c| palette[2][c] = @intCast((@as(u32, e0[c]) + e1[c]) / 2);
        palette[3] = .{ 0, 0, 0 };
    }
    var out: [16][3]u8 = undefined;
    for (&out, 0..) |*texel, i| texel.* = palette[@as(u2, @truncate(indices >> @intCast(2 * i)))];
    return out;
}

const testing = std.testing;

fn maxChannelError(block: *const [16][4]u8, encoded: [8]u8) u32 {
    const decoded = decodeBlock(encoded);
    var worst: u32 = 0;
    for (block, decoded) |src, dst| {
        for (0..3) |c| worst = @max(worst, @abs(@as(i32, src[c]) - @as(i32, dst[c])));
    }
    return worst;
}

test "encodeColorBlock: solid blocks decode within one step of the source" {
    var v: u32 = 0;
    while (v < 256) : (v += 5) {
        const px = [4]u8{ @intCast(v), @intCast(255 - v), @intCast((v * 7) & 0xff), 255 };
        const block = [_][4]u8{px} ** 16;
        const encoded = encodeColorBlock(&block);
        try testing.expect(maxChannelError(&block, encoded) <= 1);
    }
}

test "encodeColorBlock: never emits 3-color mode with non-zero indices" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (0..2000) |_| {
        var block: [16][4]u8 = undefined;
        // Mix of random and near-flat blocks to hit endpoint collisions.
        const base = random.int(u8);
        const spread = random.uintAtMost(u8, if (random.boolean()) 3 else 255);
        for (&block) |*px| {
            for (0..3) |c| px[c] = base +% random.uintAtMost(u8, spread);
            px[3] = 255;
        }
        const encoded = encodeColorBlock(&block);
        const c0 = std.mem.readInt(u16, encoded[0..2], .little);
        const c1 = std.mem.readInt(u16, encoded[2..4], .little);
        try testing.expect(c0 >= c1);
        if (c0 == c1) try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, encoded[4..8], .little));
    }
}

test "encodeColorBlock: a two-color block is reproduced closely" {
    var block: [16][4]u8 = undefined;
    for (&block, 0..) |*px, i| px.* = if (i % 3 == 0) .{ 200, 40, 10, 255 } else .{ 16, 120, 240, 255 };
    try testing.expect(maxChannelError(&block, encodeColorBlock(&block)) <= 4);
}

test "encodeColorBlock: alternating complementary colors keep both endpoints" {
    var block: [16][4]u8 = undefined;
    for (&block, 0..) |*px, i| px.* = if (i % 2 == 0) .{ 255, 0, 0, 255 } else .{ 0, 255, 0, 255 };
    try testing.expect(maxChannelError(&block, encodeColorBlock(&block)) <= 4);
}

test "encodeColorBlock: a gradient along one axis stays within quantization error" {
    var block: [16][4]u8 = undefined;
    for (&block, 0..) |*px, i| {
        const t: u8 = @intCast(i * 16);
        px.* = .{ t, t, t, 255 };
    }
    // 4 palette entries over a 240-wide ramp: worst case is ~1/6 of the span.
    try testing.expect(maxChannelError(&block, encodeColorBlock(&block)) <= 44);
}

test "encode: covers partial edge blocks" {
    var src: [3 * 5 * 4]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i * 29) & 0xff);
    var dst: [2 * 8]u8 = undefined;
    encode(&src, 3, 5, &dst);
}
