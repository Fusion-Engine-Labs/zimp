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

/// A loaded cooked asset: one aligned allocation holding the file bytes plus
/// a view into it.
pub const Asset = struct {
    bytes: []align(wire.section_alignment) u8,
    view: AssetView,

    pub fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const CookedStore = struct {
    root: []u8,
    dir: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !CookedStore {
        const cwd = std.Io.Dir.cwd();
        const dir = try std.Io.Dir.openDir(cwd, io, root, .{});
        errdefer dir.close(io);
        return initFromDir(allocator, root, dir);
    }

    pub fn initFromDir(allocator: std.mem.Allocator, root: []const u8, dir: std.Io.Dir) !CookedStore {
        return .{
            .root = try allocator.dupe(u8, root),
            .dir = dir,
        };
    }

    pub fn deinit(self: *CookedStore, allocator: std.mem.Allocator, io: std.Io) void {
        self.dir.close(io);
        allocator.free(self.root);
    }

    /// Reads a cooked file into a buffer suitable for `viewBytes`.
    pub fn readAlloc(
        self: *CookedStore,
        allocator: std.mem.Allocator,
        io: std.Io,
        normalized_path: []const u8,
    ) ![]align(wire.section_alignment) u8 {
        try path_helpers.validateVirtual(normalized_path);
        return file_read.readFileAligned(allocator, io, self.dir, normalized_path);
    }
};

pub fn detectKind(path: []const u8) ?AssetKind {
    return AssetKind.fromCookedPath(path);
}

/// Loads a cooked asset with a single read into an aligned buffer and
/// validates it in place. No per-field parsing or per-stream allocation.
pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Asset {
    const normalized_path = try path_helpers.normalizeVirtual(allocator, path);
    defer allocator.free(normalized_path);

    const asset_kind = detectKind(normalized_path) orelse return error.UnsupportedAssetType;

    const bytes = try file_read.readFileAligned(allocator, io, dir, normalized_path);
    errdefer allocator.free(bytes);
    return .{ .bytes = bytes, .view = try viewBytes(bytes, asset_kind) };
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
    const model = asset.view.mesh;
    try testing.expectEqual(@as(usize, 1), model.partCount());
    const positions = model.part(0).mesh.positions;
    try testing.expectEqual(@as(usize, 3), positions.len);
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

test "viewBytes dispatches on asset kind" {
    var buf: [1024]u8 align(wire.section_alignment) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try mesh_format.writeTestZmeshFile(&writer);

    const view = try viewBytes(buf[0..writer.end], .mesh);
    try testing.expectEqualStrings("materials/test.zamat", view.mesh.materialSlot(0));
    try testing.expectError(error.InvalidMagic, viewBytes(buf[0..writer.end], .texture));
}
