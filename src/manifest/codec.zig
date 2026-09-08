const std = @import("std");

const ProjectId = @import("../id/id_types.zig").ProjectId;
const atomic_file = @import("../shared/atomic_file.zig");
const AssetId = @import("../id/id_types.zig").AssetId;
const kind_mod = @import("../assets/asset.zig");
const model = @import("model.zig");

pub const manifest_format = "fusion.asset_manifest";
pub const manifest_version: u32 = 1;
pub const max_manifest_bytes: usize = 64 * 1024 * 1024;

const JsonEntry = struct {
    id: AssetId,
    kind: []const u8,
    source_path: []const u8,
    cooked_path: []const u8,
    content_hash: u64,
    source_size: u64,
    cooked_size: u64,
    generated: bool = false,
};

const JsonManifest = struct {
    format: []const u8 = manifest_format,
    version: u32 = manifest_version,
    project_id: ProjectId,
    entries: []const JsonEntry = &.{},
};

pub fn encodeAlloc(gpa: std.mem.Allocator, m: *const model.AssetManifest) ![]u8 {
    try m.validate();

    var view_arena = std.heap.ArenaAllocator.init(gpa);
    defer view_arena.deinit();
    const va = view_arena.allocator();

    const json_entries = try va.alloc(JsonEntry, m.entries.len);
    for (m.entries, json_entries) |entry, *je| {
        je.* = .{
            .id = entry.id,
            .kind = @tagName(entry.kind),
            .source_path = entry.source_path,
            .cooked_path = entry.cooked_path,
            .content_hash = entry.content_hash,
            .source_size = entry.source_size,
            .cooked_size = entry.cooked_size,
            .generated = entry.generated,
        };
    }

    const json_manifest = JsonManifest{
        .project_id = m.project_id,
        .entries = json_entries,
    };

    const body = try std.json.Stringify.valueAlloc(gpa, json_manifest, .{ .whitespace = .indent_2 });
    defer gpa.free(body);
    return std.mem.concat(gpa, u8, &.{ body, "\n" });
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !model.AssetManifest {
    var parse_arena = std.heap.ArenaAllocator.init(gpa);
    defer parse_arena.deinit();

    const parsed = std.json.parseFromSliceLeaky(JsonManifest, parse_arena.allocator(), bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true, // forward compat: newer fields skipped
    }) catch return error.CorruptManifest;

    if (!std.mem.eql(u8, parsed.format, manifest_format)) return error.InvalidManifestFormat;
    if (parsed.version == 0 or parsed.version > manifest_version) return error.UnsupportedManifestVersion;

    var m = model.AssetManifest{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .project_id = parsed.project_id,
        .entries = &.{},
    };
    errdefer m.deinit();
    const a = m.arena.allocator();

    const entries = try a.alloc(model.AssetManifestEntry, parsed.entries.len);
    for (parsed.entries, entries) |je, *entry| {
        const kind = std.meta.stringToEnum(kind_mod.AssetKind, je.kind) orelse
            return error.UnknownAssetKind;
        entry.* = .{
            .id = je.id,
            .kind = kind,
            .source_path = try a.dupe(u8, je.source_path),
            .cooked_path = try a.dupe(u8, je.cooked_path),
            .content_hash = je.content_hash,
            .source_size = je.source_size,
            .cooked_size = je.cooked_size,
            .generated = je.generated,
        };
    }
    m.entries = entries;

    try m.validate();
    return m;
}

pub fn writeToDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    m: *const model.AssetManifest,
) !void {
    const bytes = try encodeAlloc(gpa, m);
    defer gpa.free(bytes);
    const current = dir.readFileAlloc(io, name, gpa, .limited(max_manifest_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    if (current) |existing| {
        defer gpa.free(existing);
        if (std.mem.eql(u8, existing, bytes)) {
            return;
        }
    }
    try atomic_file.writeFileAtomic(gpa, io, dir, name, bytes);
}

pub fn loadFromDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
) !model.AssetManifest {
    const bytes = try dir.readFileAlloc(io, name, gpa, .limited(max_manifest_bytes));
    defer gpa.free(bytes);
    return decode(gpa, bytes);
}

const testing = std.testing;

const id_a = "3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01";
const id_b = "8c1d6602-b3f4-4910-9c44-4b7e9b1a2f6c";

fn fixture(gpa: std.mem.Allocator) !model.AssetManifest {
    return model.testManifest(gpa, &.{
        .{ .id = id_a, .source_path = "generated/materials/m.zamat", .kind = .material, .cooked_path = "generated/materials/m.zamat", .generated = true },
        .{ .id = id_b, .source_path = "meshes/monkey.glb", .cooked_path = "meshes/monkey.zmesh", .content_hash = 0xdead_beef },
    });
}

test "encode/decode roundtrip preserves all fields" {
    var m = try fixture(testing.allocator);
    defer m.deinit();

    const bytes = try encodeAlloc(testing.allocator, &m);
    defer testing.allocator.free(bytes);

    var back = try decode(testing.allocator, bytes);
    defer back.deinit();

    try testing.expect(back.project_id.eql(m.project_id));
    try testing.expectEqual(m.entries.len, back.entries.len);
    for (m.entries, back.entries) |want, got| {
        try testing.expect(want.id.eql(got.id));
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqualStrings(want.source_path, got.source_path);
        try testing.expectEqualStrings(want.cooked_path, got.cooked_path);
        try testing.expectEqual(want.content_hash, got.content_hash);
        try testing.expectEqual(want.generated, got.generated);
    }
}

test "encode is byte-deterministic" {
    var m1 = try fixture(testing.allocator);
    defer m1.deinit();
    var m2 = try fixture(testing.allocator);
    defer m2.deinit();

    const b1 = try encodeAlloc(testing.allocator, &m1);
    defer testing.allocator.free(b1);
    const b2 = try encodeAlloc(testing.allocator, &m2);
    defer testing.allocator.free(b2);
    try testing.expectEqualStrings(b1, b2);
}

test "decode rejects wrong format, future version, and garbage" {
    try testing.expectError(error.CorruptManifest, decode(testing.allocator, "not json"));
    try testing.expectError(error.InvalidManifestFormat, decode(testing.allocator,
        \\{"format":"nope","version":1,"project_id":"b0d5c1f2-88a1-4a5e-9f2d-77aa01c3e9b4","entries":[]}
    ));
    try testing.expectError(error.UnsupportedManifestVersion, decode(testing.allocator,
        \\{"format":"fusion.asset_manifest","version":99,"project_id":"b0d5c1f2-88a1-4a5e-9f2d-77aa01c3e9b4","entries":[]}
    ));
    try testing.expectError(error.UnknownAssetKind, decode(testing.allocator,
        \\{"format":"fusion.asset_manifest","version":1,"project_id":"b0d5c1f2-88a1-4a5e-9f2d-77aa01c3e9b4",
        \\ "entries":[{"id":"3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01","kind":"blob","source_path":"a","cooked_path":"a",
        \\             "content_hash":0,"source_size":0,"cooked_size":0}]}
    ));
}

test "decode tolerates unknown fields from newer writers" {
    var m = try decode(testing.allocator,
        \\{"format":"fusion.asset_manifest","version":1,
        \\ "project_id":"b0d5c1f2-88a1-4a5e-9f2d-77aa01c3e9b4",
        \\ "some_future_field": 42,
        \\ "entries":[]}
    );
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.entries.len);
}

test "writeToDir/loadFromDir round-trip and missing-file error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectError(error.FileNotFound, loadFromDir(testing.allocator, testing.io, tmp.dir, "assets.zmanifest"));

    var m = try fixture(testing.allocator);
    defer m.deinit();
    try writeToDir(testing.allocator, testing.io, tmp.dir, "assets.zmanifest", &m);

    var back = try loadFromDir(testing.allocator, testing.io, tmp.dir, "assets.zmanifest");
    defer back.deinit();
    try testing.expectEqual(@as(usize, 2), back.entries.len);
    try testing.expect(back.findBySourcePath("meshes/monkey.glb") != null);
}
