const std = @import("std");
const mesh_format = @import("formats/zmesh.zig");
const texture_format = @import("formats/ztex.zig");
const shader_format = @import("formats/zshdr.zig");
const material_format = @import("formats/zamat.zig");
const path_helpers = @import("path.zig");
const wire = @import("shared/wire.zig");
const file_read = @import("shared/file_read.zig");
pub const AssetKind = @import("assets/asset.zig").AssetKind;

/// Zero-copy view of a cooked asset. Every slice inside points into the
/// buffer the view was created from.
pub const AssetView = union(enum) {
    mesh: mesh_format.ZMesh,
    texture: texture_format.Zatex,
    shader: shader_format.ZShader,
    material: material_format.Zamat,
};

/// A loaded cooked asset: its bytes plus a view into them.
pub const Asset = struct {
    /// The bytes `view` points into.
    bytes: wire.Bytes,
    view: AssetView,
    /// The heap buffer behind `bytes`, freed by `deinit`. Null when `bytes`
    /// borrows a mapped pack, which must then outlive the asset.
    owned: ?[]align(wire.section_alignment) u8 = null,

    pub fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
        self.* = undefined;
    }

    /// Takes ownership of `bytes` if they validate as `kind`; frees them if not.
    pub fn fromOwned(allocator: std.mem.Allocator, bytes: []align(wire.section_alignment) u8, kind: AssetKind) !Asset {
        errdefer allocator.free(bytes);
        return .{ .bytes = bytes, .owned = bytes, .view = try viewBytes(bytes, kind) };
    }
};

/// Where a build's cooked assets are loaded from, by `AssetId`: the loose
/// cooked directory (editor and dev) or a `.zpak` (shipping).
pub const AssetStore = @import("runtime/asset_store.zig").AssetStore;
pub const LooseStore = @import("runtime/loose_store.zig").LooseStore;
pub const PackStore = @import("runtime/pack_store.zig").PackStore;

pub fn detectKind(path: []const u8) ?AssetKind {
    return AssetKind.fromCookedPath(path);
}

/// Loads a cooked asset with a single read into an aligned buffer and
/// validates it in place. No per-field parsing or per-stream allocation.
pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Asset {
    const normalized_path = try path_helpers.normalizeVirtual(allocator, path);
    defer allocator.free(normalized_path);

    const asset_kind = detectKind(normalized_path) orelse return error.UnsupportedAssetType;

    return .fromOwned(allocator, try file_read.readFileAligned(allocator, io, dir, normalized_path), asset_kind);
}

/// Validates `bytes` as a cooked asset of `asset_kind` and returns a view
/// borrowing them. Works on heap buffers and memory maps alike.
pub fn viewBytes(bytes: wire.Bytes, asset_kind: AssetKind) !AssetView {
    return switch (asset_kind) {
        .mesh => .{ .mesh = try mesh_format.view(bytes) },
        .texture => .{ .texture = try texture_format.view(bytes) },
        .shader_stage => .{ .shader = try shader_format.view(bytes) },
        .material => .{ .material = try material_format.view(bytes) },
    };
}

const testing = std.testing;

test "detectKind maps cooked asset extensions" {
    try testing.expectEqual(AssetKind.mesh, detectKind("monkey.zmesh").?);
    try testing.expectEqual(AssetKind.material, detectKind("monkey.zamat").?);
    try testing.expectEqual(AssetKind.texture, detectKind("brick_albedo.ztex").?);
    try testing.expectEqual(AssetKind.shader_stage, detectKind("basic.vert.zshdr").?);
}

test "detectKind requires lowercase cooked extensions" {
    try testing.expect(detectKind("MONKEY.ZMESH") == null);
}

fn writeTestMesh(dir: std.Io.Dir) !void {
    const file = try dir.createFile(testing.io, "test.zmesh", .{});
    defer file.close(testing.io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try mesh_format.writeTestZmeshFile(&writer.interface);
    try writer.flush();
}

test "loadFromFile loads zmesh as an in-place view" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestMesh(tmp.dir);

    var asset = try loadFromFile(testing.allocator, testing.io, tmp.dir, "test.zmesh");
    defer asset.deinit(testing.allocator);

    try testing.expect(asset.view == .mesh);
    try testing.expect(asset.owned != null);
    const model = asset.view.mesh;
    try testing.expectEqual(@as(usize, 1), model.partCount());
    try testing.expectEqual(@as(u32, 3), model.vertexCount());
    const positions = model.streamBytes(.positions);
    const offset = @intFromPtr(positions.ptr) - @intFromPtr(asset.bytes.ptr);
    try testing.expect(offset < asset.bytes.len);
}

test "loadFromFile rejects unknown extension" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectError(error.UnsupportedAssetType, loadFromFile(testing.allocator, testing.io, tmp.dir, "unknown.xyz"));
}

test "loadFromFile frees the buffer when validation fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.zmesh", .data = "not a mesh at all" });

    try testing.expectError(error.InvalidMagic, loadFromFile(testing.allocator, testing.io, tmp.dir, "bad.zmesh"));
}

test {
    _ = @import("runtime/asset_store.zig");
    _ = @import("runtime/loose_store.zig");
    _ = @import("runtime/pack_store.zig");
}

test "viewBytes dispatches on asset kind" {
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try mesh_format.writeTestZmeshFile(&writer);

    const view = try viewBytes(buf[0..writer.end], .mesh);
    try testing.expect(view.mesh.materialSlot(0).eql(mesh_format.test_material_id));
    try testing.expectError(error.InvalidMagic, viewBytes(buf[0..writer.end], .texture));
}
