const std = @import("std");

// GL_RGB9_E5 (EXT_texture_shared_exponent, core since GL 3.0): three 9-bit
// mantissas sharing one 5-bit exponent, packed little-endian as
// r | g << 9 | b << 18 | e << 27 (GL_UNSIGNED_INT_5_9_9_9_REV).
const mantissa_bits = 9;
const exponent_bias = 15;
const max_biased_exponent = 31;
/// Largest representable value: (511 / 512) * 2^16.
pub const max_value: f32 = 65408.0;

/// Packs a linear RGB color, following the encoding in the extension spec.
/// Negative and NaN components become 0; values above `max_value` clamp.
pub fn pack(r: f32, g: f32, b: f32) u32 {
    const rc = clampComponent(r);
    const gc = clampComponent(g);
    const bc = clampComponent(b);
    const max_c = @max(rc, @max(gc, bc));

    // floor(log2(max_c)), exactly, via frexp: max_c = m * 2^e with m in [0.5, 1).
    const floor_log2: i32 = if (max_c == 0) -exponent_bias - 1 else std.math.frexp(max_c).exponent - 1;
    var exponent: i32 = @max(-exponent_bias - 1, floor_log2) + 1 + exponent_bias;
    // Rounding the largest component can carry into the next exponent.
    if (mantissa(max_c, exponent) == 1 << mantissa_bits) exponent += 1;
    std.debug.assert(exponent >= 0 and exponent <= max_biased_exponent);

    const rm = mantissa(rc, exponent);
    const gm = mantissa(gc, exponent);
    const bm = mantissa(bc, exponent);
    return rm | (gm << 9) | (bm << 18) | (@as(u32, @intCast(exponent)) << 27);
}

pub fn unpack(value: u32) [3]f32 {
    const s = scale(@intCast(value >> 27));
    return .{
        @as(f32, @floatFromInt(value & 0x1ff)) * s,
        @as(f32, @floatFromInt((value >> 9) & 0x1ff)) * s,
        @as(f32, @floatFromInt((value >> 18) & 0x1ff)) * s,
    };
}

/// floor(v / step + 0.5) in f64: in f32 the `+ 0.5` itself rounds, so a value
/// just under a half step (0.49999997) would round up.
fn mantissa(v: f32, exponent: i32) u32 {
    const step = std.math.ldexp(@as(f64, 1.0), exponent - exponent_bias - mantissa_bits);
    return @intFromFloat(@floor(@as(f64, v) / step + 0.5));
}

/// Value of one mantissa step at biased exponent `exponent`.
fn scale(exponent: i32) f32 {
    return std.math.ldexp(@as(f32, 1.0), exponent - exponent_bias - mantissa_bits);
}

fn clampComponent(v: f32) f32 {
    if (std.math.isNan(v) or v <= 0) return 0;
    return @min(v, max_value);
}

const testing = std.testing;

test "pack: zero, one, and max round-trip exactly" {
    try testing.expectEqual(@as(u32, 0), pack(0, 0, 0));
    try testing.expectEqual([3]f32{ 1, 0.5, 0.25 }, unpack(pack(1, 0.5, 0.25)));
    try testing.expectEqual([3]f32{ max_value, 0, 0 }, unpack(pack(max_value, 0, 0)));
}

test "pack: clamps out-of-range components" {
    try testing.expectEqual([3]f32{ max_value, 0, 0 }, unpack(pack(1e9, -3, std.math.nan(f32))));
    try testing.expectEqual([3]f32{ max_value, 0, 0 }, unpack(pack(std.math.inf(f32), 0, 0)));
}

test "pack: mantissa rounding carries into the exponent" {
    // 511.75 rounds to mantissa 512 at the first exponent, so it moves up one.
    try testing.expectEqual([3]f32{ 512, 0, 0 }, unpack(pack(511.75, 0, 0)));
}

test "pack: a value just under a half step rounds down" {
    // 0x3affffff / 2^-24 = 0.49999997: the spec's floor(x + 0.5) gives 0.
    const r: f32 = @bitCast(@as(u32, 0x3affffff));
    try testing.expectEqual(@as(u32, 0x80020000), pack(r, 1, 0));
}

test "pack: largest component keeps 9 bits of relative precision" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..10_000) |_| {
        // 2^-14 up to just below 2^16, the range that doesn't clamp.
        const exp = random.float(f32) * 29.9 - 14;
        const v = [3]f32{ std.math.exp2(exp), random.float(f32) * std.math.exp2(exp), random.float(f32) };
        const got = unpack(pack(v[0], v[1], v[2]));
        // Half a mantissa step of the shared exponent, relative to the largest component.
        const tolerance = @max(v[0], v[2]) / 512.0 + 1e-9;
        for (got, v) |g, want| try testing.expectApproxEqAbs(want, g, tolerance);
    }
}
