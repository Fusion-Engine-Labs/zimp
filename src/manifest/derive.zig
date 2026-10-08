const std = @import("std");
const ids = @import("../id/id_types.zig");
const builtin_registry = @import("../builtin/registry.zig");
const path_helpers = @import("../path.zig");

pub fn assetIdForPath(project_id: ids.ProjectId, path: []const u8) ids.AssetId {
    return ids.AssetId.derive(project_id.uuid, path);
}

/// Id that the manifest will record for the asset at source path `raw_path`.
/// Cookers use this to embed references to other assets. Builtins (`fusion/`)
/// keep their project-independent ids; the path is normalized first so
/// `./textures/a.png` and `textures/a.png` name the same asset.
pub fn assetIdForReference(project_id: ids.ProjectId, raw_path: []const u8) path_helpers.Error!ids.AssetId {
    var buf: [path_helpers.max_virtual_path_len]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const normalized = try path_helpers.normalizeVirtual(fba.allocator(), raw_path);
    if (builtin_registry.isBuiltin(normalized)) return builtin_registry.idFor(normalized);
    return assetIdForPath(project_id, normalized);
}

const testing = std.testing;

const project_a = ids.ProjectId.parseComptime(
    "bf5a424f-e93e-4977-9a7a-0c522318dfdc",
);
const project_b = ids.ProjectId.parseComptime(
    "b0d5c1f2-88a1-4a5e-9f2d-77aa01c3e9b4",
);

test "assetIdForPath is deterministic and path-sensitive" {
    const first = assetIdForPath(project_a, "meshes/monkey.glb");
    const again = assetIdForPath(project_a, "meshes/monkey.glb");
    const moved = assetIdForPath(project_a, "models/monkey.glb");

    try testing.expect(first.eql(again));
    try testing.expect(!first.eql(moved));
    try testing.expect(!first.isZero());
}

test "assetIdForPath is scoped by project id" {
    const first = assetIdForPath(project_a, "meshes/monkey.glb");
    const second = assetIdForPath(project_b, "meshes/monkey.glb");

    try testing.expect(!first.eql(second));
}

test "assetIdForPath golden value is stable across releases" {
    const id = assetIdForPath(project_a, "meshes/monkey.glb");

    try testing.expectEqualStrings(
        "5313054d-3f6a-8e9b-b102-fa2bf68d10d5",
        &id.toString(),
    );
}

test "assetIdForReference matches manifest ids for project and builtin paths" {
    try testing.expect((try assetIdForReference(project_a, "./textures//a.png")).eql(assetIdForPath(project_a, "textures/a.png")));
    try testing.expect((try assetIdForReference(project_a, "fusion/standard.vert")).eql(builtin_registry.idFor("fusion/standard.vert")));
    try testing.expect((try assetIdForReference(project_b, "fusion/standard.vert")).eql(builtin_registry.idFor("fusion/standard.vert")));
    try testing.expectError(error.ParentTraversalNotAllowed, assetIdForReference(project_a, "../escape.png"));
}
