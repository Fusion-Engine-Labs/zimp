const std = @import("std");

const compression = @import("compression.zig");
const bc1 = @import("bc1.zig");
const bc4 = @import("bc4.zig");

/// Encode an RGBA8 image as BC3: a BC4-coded alpha block followed by a BC1
/// color block per 4x4 tile. `src` must be `width * height * 4` bytes. `dst`
/// must be `ceil(width/4) * ceil(height/4) * 16` bytes.
pub fn encode(src: []const u8, width: u32, height: u32, dst: []u8) void {
    std.debug.assert(src.len == @as(usize, width) * @as(usize, height) * 4);
    const blocks_x = (width + 3) / 4;
    const blocks_y = (height + 3) / 4;
    std.debug.assert(dst.len == @as(usize, blocks_x) * @as(usize, blocks_y) * 16);

    var block: [16][4]u8 = undefined;
    for (0..blocks_y) |by| {
        for (0..blocks_x) |bx| {
            compression.extractBlock4x4(src, width, height, 4, @as(u32, @intCast(bx)) * 4, @as(u32, @intCast(by)) * 4, std.mem.asBytes(&block));
            const encoded = encodeBlock(&block);
            @memcpy(dst[(by * blocks_x + bx) * 16 ..][0..16], &encoded);
        }
    }
}

pub fn encodeBlock(block: *const [16][4]u8) [16]u8 {
    var alpha: [16]u8 = undefined;
    for (block, &alpha) |px, *a| a.* = px[3];

    var out: [16]u8 = undefined;
    out[0..8].* = bc4.encodeBlock(alpha);
    out[8..16].* = bc1.encodeColorBlock(block);
    return out;
}

const testing = std.testing;

test "encodeBlock: alpha half is BC4 of the alpha channel, color half is BC1" {
    var block: [16][4]u8 = undefined;
    for (&block, 0..) |*px, i| px.* = .{ 30, 60, 90, @intCast(i * 17) };

    const encoded = encodeBlock(&block);
    // Endpoints are the alpha extremes (8-value mode: max first).
    try testing.expectEqual(@as(u8, 255), encoded[0]);
    try testing.expectEqual(@as(u8, 0), encoded[1]);

    const color = bc1.decodeBlock(encoded[8..16].*);
    for (color) |texel| {
        for (texel, [3]u8{ 30, 60, 90 }) |got, want| try testing.expect(@abs(@as(i32, got) - want) <= 1);
    }
}
