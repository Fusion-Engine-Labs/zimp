const std = @import("std");

const id_types = @import("../id/id_types.zig");
const document_mod = @import("document.zig");
const json_codec = @import("json_codec.zig");
const value_mod = @import("value.zig");

const max_field_number = @import("schema.zig").max_field_number;

const SceneComponent = document_mod.SceneComponent;
const SceneDocument = document_mod.SceneDocument;
const SceneEntity = document_mod.SceneEntity;
const SceneEntityId = id_types.SceneEntityId;
const ProjectId = id_types.ProjectId;

pub const Options = struct {
    expected_project_id: ?ProjectId = null,
    max_entities: usize = 1_000_000,
    max_components_per_entity: usize = 4_096,
    max_fields_per_component: usize = 16_384,
    max_name_bytes: usize = 4_096,
};

pub fn validate(scene: *const SceneDocument, allocator: std.mem.Allocator, options: Options) !void {
    try validateLimits(scene, options);

    var ids = std.AutoHashMap(SceneEntityId, usize).init(allocator);
    defer ids.deinit();
    try ids.ensureTotalCapacity(@intCast(scene.entities.len));

    for (scene.entities, 0..) |entity, index| {
        if (entity.id.isZero()) {
            return error.ZeroEntityId;
        }

        if ((try ids.getOrPut(entity.id)).found_existing) {
            return error.DuplicateEntityId;
        }

        ids.getPtr(entity.id).?.* = index;
        try validateEntityShape(entity);
    }
    try validateReferencesAndCycles(scene, &ids, allocator);
}

/// The header checks and size limits of `validate`, without the structural
/// checks. `binary_codec.decode` already enforces those (unique ids,
/// resolvable references, no cycles, no duplicate components or fields), so
/// binary scenes only need this.
pub fn validateLimits(scene: *const SceneDocument, options: Options) !void {
    try validateHeader(scene, options);
    for (scene.entities) |entity| {
        try validateName(entity.name, options);
        if (entity.components.len > options.max_components_per_entity) {
            return error.TooManyComponents;
        }
        for (entity.components) |component| {
            if (component.fields.len > options.max_fields_per_component) {
                return error.TooManyFields;
            }
        }
    }
}

fn validateHeader(scene: *const SceneDocument, options: Options) !void {
    if (!std.mem.eql(u8, scene.format, json_codec.scene_format)) {
        return error.InvalidSceneFormat;
    }

    if (scene.version != json_codec.scene_version) {
        return error.UnsupportedSceneVersion;
    }

    if (scene.scene_id.isZero()) {
        return error.ZeroSceneId;
    }

    if (scene.project_id.isZero()) {
        return error.ZeroProjectId;
    }

    if (options.expected_project_id) |expected| {
        if (!scene.project_id.eql(expected)) {
            return error.UnexpectedProjectId;
        }
    }

    if (scene.entities.len > options.max_entities) {
        return error.TooManyEntities;
    }
    try validateName(scene.name, options);
}

fn validateEntityShape(entity: SceneEntity) !void {
    for (entity.components, 0..) |component, component_index| {
        if (component.type_id.isZero()) {
            return error.ZeroComponentTypeId;
        }

        if (component.version == 0) {
            return error.ZeroComponentVersion;
        }

        for (entity.components[0..component_index]) |previous| {
            if (component.type_id.eql(previous.type_id)) {
                return error.DuplicateComponentTypeId;
            }
        }
        try validateFields(component);
    }
}

fn validateName(name: []const u8, options: Options) !void {
    if (name.len > options.max_name_bytes) {
        return error.NameTooLong;
    }
}

fn validateFields(component: SceneComponent) !void {
    for (component.fields, 0..) |field, field_index| {
        if (field.number == 0) {
            return error.ZeroFieldNumber;
        }

        if (field.number > max_field_number) {
            return error.FieldNumberTooLarge;
        }

        if (field.value == .none) {
            return error.NoneFieldValue;
        }

        for (component.fields[0..field_index]) |previous| {
            if (field.number == previous.number) {
                return error.DuplicateFieldNumber;
            }
        }
    }
}

fn validateReferencesAndCycles(
    scene: *const SceneDocument,
    ids: *const std.AutoHashMap(SceneEntityId, usize),
    allocator: std.mem.Allocator,
) !void {
    for (scene.entities) |entity| {
        if (entity.parent_id) |parent| {
            if (entity.id.eql(parent)) {
                return error.SelfParent;
            }
            if (!ids.contains(parent)) {
                return error.MissingParentEntity;
            }
        }

        if (entity.prefab.source_entity) |source_entity| {
            if (!source_entity.isZero() and !ids.contains(source_entity)) {
                return error.MissingPrefabSourceEntity;
            }
        }

        for (entity.components) |component| {
            for (component.fields) |field| {
                switch (field.value) {
                    .entity_ref => |reference| {
                        if (!reference.isZero() and !ids.contains(reference)) {
                            return error.MissingEntityReference;
                        }
                    },
                    else => {},
                }
            }
        }
    }

    // White (0), gray (1), and black (2).  Parent links give every node at
    // most one outgoing edge, but this remains an explicit iterative DFS so
    // hostile nesting cannot consume the call stack.
    const colors = try allocator.alloc(u8, scene.entities.len);
    defer allocator.free(colors);
    @memset(colors, 0);

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);

    for (scene.entities, 0..) |_, start| {
        if (colors[start] != 0) continue;

        try stack.append(allocator, start);
        while (stack.items.len != 0) {
            const current = stack.items[stack.items.len - 1];
            if (colors[current] == 0) {
                colors[current] = 1;
            }

            const parent = scene.entities[current].parent_id;
            if (parent) |parent_id| {
                const parent_index = ids.get(parent_id).?;
                switch (colors[parent_index]) {
                    0 => {
                        try stack.append(allocator, parent_index);
                        continue;
                    },
                    1 => return error.EntityParentCycle,
                    2 => {},
                    else => unreachable,
                }
            }
            colors[current] = 2;
            _ = stack.pop();
        }
    }
}

const testing = std.testing;
const SceneId = id_types.SceneId;
const ComponentTypeId = id_types.ComponentTypeId;

const scene_id = SceneId.parseComptime("8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a");
const project_id = ProjectId.parseComptime("4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589");
const entity_a = SceneEntityId.parseComptime("11111111-1111-4111-8111-111111111111");
const entity_b = SceneEntityId.parseComptime("22222222-2222-4222-8222-222222222222");
const component_id = ComponentTypeId.parseComptime("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");

fn validScene(allocator: std.mem.Allocator) !SceneDocument {
    var scene = try SceneDocument.init(allocator, scene_id, project_id, "Scene");
    errdefer scene.deinit();
    const storage = scene.arena.allocator();
    scene.entities = try storage.dupe(SceneEntity, &.{.{
        .id = entity_a,
        .name = "Entity",
        .components = try storage.dupe(SceneComponent, &.{.{
            .type_id = component_id,
            .fields = try storage.dupe(value_mod.SceneField, &.{.{ .number = 1, .value = .{ .bool = true } }}),
        }}),
        .prefab = .{},
    }});
    return scene;
}

test "document validates structure without requiring schemas or assets" {
    var scene = try validScene(testing.allocator);
    defer scene.deinit();
    scene.schema_hash = 42;
    scene.entities[0].components[0].version = 99;
    scene.entities[0].components[0].fields[0].number = 999;
    try validate(&scene, testing.allocator, .{});
}

test "document rejects field numbers that do not fit a cooked scene" {
    var scene = try validScene(testing.allocator);
    defer scene.deinit();
    scene.entities[0].components[0].fields[0].number = max_field_number;
    try validate(&scene, testing.allocator, .{});
    scene.entities[0].components[0].fields[0].number = max_field_number + 1;
    try testing.expectError(error.FieldNumberTooLarge, validate(&scene, testing.allocator, .{}));
}

test "validateLimits checks the header and size limits only" {
    var scene = try validScene(testing.allocator);
    defer scene.deinit();
    scene.entities[0].parent_id = entity_b; // structural, so not checked here
    try validateLimits(&scene, .{ .expected_project_id = project_id });
    try testing.expectError(error.UnexpectedProjectId, validateLimits(&scene, .{ .expected_project_id = .parseComptime("d9b8e01a-f070-4cd7-bc83-19f8a6e40d17") }));
    try testing.expectError(error.TooManyFields, validateLimits(&scene, .{ .max_fields_per_component = 0 }));
    try testing.expectError(error.TooManyComponents, validateLimits(&scene, .{ .max_components_per_entity = 0 }));
    try testing.expectError(error.NameTooLong, validateLimits(&scene, .{ .max_name_bytes = 1 }));
}

test "document rejects bad ids, references, and cycles" {
    var scene = try validScene(testing.allocator);
    defer scene.deinit();

    scene.entities[0].parent_id = entity_a;
    try testing.expectError(error.SelfParent, validate(&scene, testing.allocator, .{}));
    scene.entities[0].parent_id = null;

    const storage = scene.arena.allocator();
    scene.entities = try storage.dupe(SceneEntity, &.{
        scene.entities[0],
        .{ .id = entity_b, .parent_id = entity_a, .name = "Child", .components = &.{}, .prefab = .{} },
    });
    scene.entities[0].parent_id = entity_b;
    try testing.expectError(error.EntityParentCycle, validate(&scene, testing.allocator, .{}));
}
