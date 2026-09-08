const std = @import("std");

const AssetId = @import("../id/id_types.zig").AssetId;

pub const PREFIX = "fusion/";

pub const Source = struct {
    path: []const u8,
    bytes: []const u8,

    pub fn hashBytes(self: Source) u64 {
        var hasher = std.hash.XxHash64.init(0);
        hasher.update(self.bytes);
        return hasher.final();
    }
};

pub const assets = [_]Source{
    .{ .path = PREFIX ++ "standard.vert", .bytes = @embedFile("shaders/standard.vert") },
    .{ .path = PREFIX ++ "standard.frag", .bytes = @embedFile("shaders/standard.frag") },
    .{ .path = PREFIX ++ "error.vert", .bytes = @embedFile("shaders/error.vert") },
    .{ .path = PREFIX ++ "error.frag", .bytes = @embedFile("shaders/error.frag") },
    .{ .path = PREFIX ++ "error.zamat", .bytes = @embedFile("materials/error.zamat") },
};

pub fn isBuiltin(file_path: []const u8) bool {
    return std.mem.startsWith(u8, file_path, PREFIX);
}

pub fn find(file_path: []const u8) ?Source {
    for (assets) |a| {
        if (std.mem.eql(u8, a.path, file_path)) {
            return a;
        }
    }

    return null;
}

pub fn idFor(file_path: []const u8) AssetId {
    @setEvalBranchQuota(1750);
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("fusion.builtin.v1:");
    hasher.update(file_path);
    var out: [16]u8 = undefined;
    hasher.final(&out);
    out[6] = (out[6] & 0x0f) | 0x50; // version 5
    out[8] = (out[8] & 0x3f) | 0x80; // RFC 4122 variant
    return AssetId.fromBytes(out);
}

pub const error_material_id = idFor(PREFIX ++ "error.zamat");

const testing = std.testing;
const asset_registry = @import("../assets/asset_registry.zig");
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const AssetKind = @import("../assets/asset.zig").AssetKind;
const path = @import("../path.zig");

test "builtin.find" {
    try testing.expectEqual(assets[0].path, find(PREFIX ++ "standard.vert").?.path);
    try testing.expectEqual(assets[1].path, find(PREFIX ++ "standard.frag").?.path);
    try testing.expectEqual(assets[2].path, find(PREFIX ++ "error.vert").?.path);
    try testing.expectEqual(assets[3].path, find(PREFIX ++ "error.frag").?.path);
    try testing.expectEqual(assets[4].path, find(PREFIX ++ "error.zamat").?.path);
}

test "all builtin assets are valid and cookable" {
    for (assets, 0..) |source, index| {
        try path.validateVirtual(source.path);
        try testing.expect(std.mem.startsWith(u8, source.path, PREFIX));
        try testing.expect(source.bytes.len > 0);
        try testing.expect(!idFor(source.path).isZero());

        const file = SourceFile.fromPath(source.path);
        const descriptor = asset_registry.descriptorForSource(file);
        try testing.expect(descriptor.cooker != null);
        try testing.expect(file.assetKind() != null);

        for (assets[0..index]) |previous| {
            try testing.expect(!std.mem.eql(
                u8,
                previous.path,
                source.path,
            ));
        }
    }
}

test "builtin ids are deterministic" {
    const first = idFor("fusion/standard.vert");
    const second = idFor("fusion/standard.vert");
    const fragment = idFor("fusion/standard.frag");

    try testing.expect(first.eql(second));
    try testing.expect(!first.eql(fragment));
}
