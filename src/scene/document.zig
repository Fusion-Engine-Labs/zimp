const std = @import("std");

const atomic_file = @import("../shared/atomic_file.zig");
const binary_codec = @import("binary_codec.zig");
const id_types = @import("../id/id_types.zig");
const json_codec = @import("json_codec.zig");
const Uuid = @import("../id/uuid.zig").Uuid;
const validate = @import("validate.zig");
const path = @import("../path.zig");
const value = @import("value.zig");

pub const Format = enum {
    json,
    binary,
};

pub const SceneDocument = struct {
    arena: std.heap.ArenaAllocator,
    format: []const u8,
    version: u32,
    scene_id: id_types.SceneId,
    project_id: id_types.ProjectId,
    name: []const u8,
    schema_hash: u64 = 0,
    asset_manifest_hash: u64 = 0,
    entities: []SceneEntity,

    pub fn init(
        allocator: std.mem.Allocator,
        scene_id: id_types.SceneId,
        project_id: id_types.ProjectId,
        name: []const u8,
    ) !SceneDocument {
        const arena = std.heap.ArenaAllocator.init(allocator);
        var self = SceneDocument{
            .arena = arena,
            .format = undefined,
            .version = 2,
            .scene_id = scene_id,
            .project_id = project_id,
            .name = undefined,
            .entities = &.{},
        };
        errdefer self.arena.deinit();

        const storage = self.arena.allocator();
        self.format = try storage.dupe(u8, "fusion.scene");
        self.name = try storage.dupe(u8, name);

        return self;
    }

    pub fn deinit(self: *SceneDocument) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, options: validate.Options) !SceneDocument {
        try path.validateVirtual(name);
        const bytes = try dir.readFileAlloc(
            io,
            name,
            allocator,
            .limited(json_codec.max_scene_bytes),
        );
        defer allocator.free(bytes);

        if (std.mem.startsWith(u8, bytes, binary_codec.magic)) {
            return try binary_codec.decode(allocator, bytes);
        }

        var scene = try json_codec.decode(allocator, bytes);
        errdefer scene.deinit();

        try validate.validate(&scene, allocator, options);

        return scene;
    }

    const WriteOptions = struct {
        project_id: id_types.ProjectId,
        format: Format,
    };

    pub fn write(self: *const SceneDocument, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file: []const u8, options: WriteOptions) !void {
        try validate.validate(
            self,
            allocator,
            .{ .expected_project_id = options.project_id },
        );

        const bytes = switch (options.format) {
            .json => try json_codec.encodeAlloc(allocator, self),
            .binary => try binary_codec.encodeAlloc(allocator, self),
        };
        defer allocator.free(bytes);

        try atomic_file.writeFileAtomic(allocator, io, dir, file, bytes);
    }

    pub fn entityIndex(self: *const SceneDocument, id: id_types.SceneEntityId) ?usize {
        for (self.entities, 0..) |entity, index| {
            if (entity.id.eql(id)) {
                return index;
            }
        }
        return null;
    }

    pub fn clone(self: *const SceneDocument, allocator: std.mem.Allocator) !SceneDocument {
        var result = try SceneDocument.init(allocator, self.scene_id, self.project_id, self.name);
        errdefer result.deinit();

        const arena = result.arena.allocator();
        result.format = try arena.dupe(u8, self.format);
        result.version = self.version;
        result.schema_hash = self.schema_hash;
        result.asset_manifest_hash = self.asset_manifest_hash;
        result.entities = try arena.alloc(SceneEntity, self.entities.len);

        for (self.entities, result.entities) |src, *dst| {
            dst.* = .{
                .id = src.id,
                .parent_id = src.parent_id,
                .name = try arena.dupe(u8, src.name),
                .components = try cloneComponents(arena, src.components),
                .prefab = src.prefab,
            };
        }

        return result;
    }

    fn cloneComponents(allocator: std.mem.Allocator, source: []SceneComponent) ![]SceneComponent {
        const result = try allocator.alloc(SceneComponent, source.len);
        for (source, result) |*src, *dst| {
            dst.* = .{
                .type_id = src.type_id,
                .version = src.version,
                .fields = try cloneFields(allocator, src.fields),
            };
        }
        return result;
    }
};

pub const SceneEntity = struct {
    id: id_types.SceneEntityId,
    parent_id: ?id_types.SceneEntityId = null,
    name: []const u8,
    components: []SceneComponent,
    prefab: PrefabInstanceMetadata,

    pub fn componentIndex(self: *const SceneEntity, id: id_types.ComponentTypeId) ?usize {
        for (self.components, 0..) |component, index| {
            if (component.type_id.eql(id)) {
                return index;
            }
        }
        return null;
    }
};

pub const SceneComponent = struct {
    type_id: id_types.ComponentTypeId,
    version: u32 = 1,
    fields: []value.SceneField,

    pub fn asData(self: *const SceneComponent) value.SceneComponentData {
        return .{ .component = self.type_id, .fields = self.fields };
    }

    pub fn clone(self: *const SceneComponent, allocator: std.mem.Allocator) !SceneComponent {
        const result = try allocator.create(SceneComponent);
        errdefer allocator.destroy(result);

        result.* = .{
            .type_id = self.type_id,
            .version = self.version,
            .fields = try cloneFields(allocator, self.fields),
        };
        return result.*;
    }

    pub fn fieldIndex(self: *const SceneComponent, number: u32) ?usize {
        for (self.fields, 0..) |field, index| {
            if (field.number == number) {
                return index;
            }
        }
        return null;
    }
};

pub const PrefabInstanceMetadata = struct {
    prefab_asset: ?id_types.AssetId = null,
    source_entity: ?id_types.SceneEntityId = null,
    override_set_id: ?Uuid = null,
};

fn cloneFields(allocator: std.mem.Allocator, source: []value.SceneField) ![]value.SceneField {
    const result = try allocator.alloc(value.SceneField, source.len);
    for (source, result) |*src, *dst| {
        dst.* = .{
            .number = src.number,
            .value = try src.value.clone(allocator),
        };
    }
    return result;
}

const testing = std.testing;

test "SceneDocument.clone preserves document data in independent storage" {
    const scene_id = id_types.SceneId.parseComptime("8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a");
    const project_id = id_types.ProjectId.parseComptime("4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589");
    const entity_id = id_types.SceneEntityId.parseComptime("11111111-1111-4111-8111-111111111111");
    const parent_id = id_types.SceneEntityId.parseComptime("22222222-2222-4222-8222-222222222222");
    const component_id = id_types.ComponentTypeId.parseComptime("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    const asset_id = id_types.AssetId.parseComptime("33333333-3333-4333-8333-333333333333");

    var source = try SceneDocument.init(testing.allocator, scene_id, project_id, "Sandbox");
    defer source.deinit();
    const storage = source.arena.allocator();
    const fields = try storage.dupe(value.SceneField, &.{
        .{ .number = 1, .value = .{ .string = "Main Camera" } },
        .{ .number = 2, .value = .{ .asset_ref = asset_id } },
    });
    const components = try storage.dupe(SceneComponent, &.{.{
        .type_id = component_id,
        .version = 3,
        .fields = fields,
    }});
    source.entities = try storage.dupe(SceneEntity, &.{.{
        .id = entity_id,
        .parent_id = parent_id,
        .name = "Camera",
        .components = components,
        .prefab = .{ .prefab_asset = asset_id, .source_entity = parent_id },
    }});
    source.version = 7;
    source.format = try storage.dupe(u8, "fusion.scene.test");
    source.schema_hash = 123;
    source.asset_manifest_hash = 456;

    var cloned = try source.clone(testing.allocator);
    defer cloned.deinit();

    try testing.expectEqualStrings(source.format, cloned.format);
    try testing.expectEqual(source.version, cloned.version);
    try testing.expect(source.scene_id.eql(cloned.scene_id));
    try testing.expect(source.project_id.eql(cloned.project_id));
    try testing.expectEqualStrings(source.name, cloned.name);
    try testing.expectEqual(source.schema_hash, cloned.schema_hash);
    try testing.expectEqual(source.asset_manifest_hash, cloned.asset_manifest_hash);
    try testing.expectEqual(@as(usize, 1), cloned.entities.len);

    const source_entity = source.entities[0];
    const cloned_entity = cloned.entities[0];
    try testing.expect(source_entity.id.eql(cloned_entity.id));
    try testing.expectEqual(source_entity.parent_id, cloned_entity.parent_id);
    try testing.expectEqualStrings(source_entity.name, cloned_entity.name);
    try testing.expectEqual(source_entity.prefab, cloned_entity.prefab);
    try testing.expectEqual(@as(usize, 1), cloned_entity.components.len);
    try testing.expect(source_entity.components[0].type_id.eql(cloned_entity.components[0].type_id));
    try testing.expectEqual(source_entity.components[0].version, cloned_entity.components[0].version);
    try testing.expectEqual(@as(usize, 2), cloned_entity.components[0].fields.len);
    try testing.expectEqual(source_entity.components[0].fields[0].number, cloned_entity.components[0].fields[0].number);
    try testing.expectEqualStrings(source_entity.components[0].fields[0].value.string, cloned_entity.components[0].fields[0].value.string);
    try testing.expectEqual(source_entity.components[0].fields[1].value, cloned_entity.components[0].fields[1].value);

    try testing.expect(source.name.ptr != cloned.name.ptr);
    try testing.expect(source.format.ptr != cloned.format.ptr);
    try testing.expect(source.entities.ptr != cloned.entities.ptr);
    try testing.expect(source_entity.name.ptr != cloned_entity.name.ptr);
    try testing.expect(source_entity.components.ptr != cloned_entity.components.ptr);
    try testing.expect(source_entity.components[0].fields.ptr != cloned_entity.components[0].fields.ptr);
    try testing.expect(source_entity.components[0].fields[0].value.string.ptr != cloned_entity.components[0].fields[0].value.string.ptr);
}

test "SceneDocument.write round trips JSON and binary scenes" {
    const scene_id = id_types.SceneId.parseComptime("8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a");
    const project_id = id_types.ProjectId.parseComptime("4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589");
    var scene = try SceneDocument.init(testing.allocator, scene_id, project_id, "scene.zscene");
    defer scene.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for ([_]Format{ .json, .binary }) |format| {
        try scene.write(testing.allocator, testing.io, tmp.dir, "test.json", .{
            .project_id = project_id,
            .format = format,
        });

        var loaded = try SceneDocument.load(testing.allocator, testing.io, tmp.dir, "test.json", .{
            .expected_project_id = project_id,
        });
        defer loaded.deinit();

        try testing.expect(loaded.scene_id.eql(scene_id));
        try testing.expect(loaded.project_id.eql(project_id));
        try testing.expectEqualStrings(scene.name, loaded.name);
    }
}

test "SceneDocument.write rejects a mismatched project" {
    const scene_id = id_types.SceneId.parseComptime("8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a");
    const project_id = id_types.ProjectId.parseComptime("4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589");
    const other_project_id = id_types.ProjectId.parseComptime("d9b8e01a-f070-4cd7-bc83-19f8a6e40d17");
    var scene = try SceneDocument.init(testing.allocator, scene_id, project_id, "scene.zscene");
    defer scene.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectError(error.UnexpectedProjectId, scene.write(testing.allocator, testing.io, tmp.dir, "test.json", .{
        .project_id = other_project_id,
        .format = .json,
    }));
}
