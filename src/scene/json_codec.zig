const std = @import("std");
const document = @import("document.zig");
const value = @import("value.zig");
const id = @import("../id/id_types.zig");
const Uuid = @import("../id/uuid.zig").Uuid;

pub const scene_format = "fusion.scene";
pub const scene_version: u32 = 2;
pub const max_scene_bytes: usize = 64 * 1024 * 1024;

pub const DecodeError = error{
    CorruptScene,
    InvalidSceneFormat,
    UnsupportedSceneVersion,
    UnknownField,
    MissingField,
    InvalidValue,
};

pub fn encodeAlloc(allocator: std.mem.Allocator, scene: *const document.SceneDocument) ![]u8 {
    if (!std.mem.eql(u8, scene.format, scene_format) or scene.version != scene_version) {
        return error.InvalidSceneFormat;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\n  \"format\": ");
    try json(allocator, &out, scene_format);

    try out.appendSlice(allocator, ",\n  \"version\": 2,\n  \"scene_id\": ");
    try json(allocator, &out, scene.scene_id);

    try out.appendSlice(allocator, ",\n  \"project_id\": ");
    try json(allocator, &out, scene.project_id);

    try out.appendSlice(allocator, ",\n  \"name\": ");
    try json(allocator, &out, scene.name);

    try out.appendSlice(allocator, ",\n  \"schema_hash\": ");
    try json(allocator, &out, scene.schema_hash);

    try out.appendSlice(allocator, ",\n  \"asset_manifest_hash\": ");
    try json(allocator, &out, scene.asset_manifest_hash);

    try out.appendSlice(allocator, ",\n  \"entities\": [");
    const entities = try allocator.dupe(document.SceneEntity, scene.entities);
    defer allocator.free(entities);
    std.mem.sort(document.SceneEntity, entities, {}, lessEntity);
    for (entities, 0..) |entity, i| {
        if (i != 0) {
            try out.append(allocator, ',');
        }
        try entityJson(allocator, &out, entity, 2);
    }
    try out.appendSlice(allocator, "]\n}\n");

    return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !document.SceneDocument {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.CorruptScene;
    defer parsed.deinit();

    const obj = try object(parsed.value);
    try rejectUnknown(obj, &.{ "format", "version", "scene_id", "project_id", "name", "schema_hash", "asset_manifest_hash", "entities" });

    const format = try string(try required(obj, "format"));
    if (!std.mem.eql(u8, format, scene_format)) {
        return error.InvalidSceneFormat;
    }

    const version = try u32Value(try required(obj, "version"));
    if (version != scene_version) {
        return error.UnsupportedSceneVersion;
    }

    const scene_id = try parseId(id.SceneId, try string(try required(obj, "scene_id")));
    const project_id = try parseId(id.ProjectId, try string(try required(obj, "project_id")));
    const name = try string(try required(obj, "name"));
    const schema_hash = try optionalU64(obj, "schema_hash");
    const asset_manifest_hash = try optionalU64(obj, "asset_manifest_hash");

    var scene = try document.SceneDocument.init(allocator, scene_id, project_id, name);
    errdefer scene.deinit();

    const storage = scene.arena.allocator();
    scene.version = version;
    scene.schema_hash = schema_hash;
    scene.asset_manifest_hash = asset_manifest_hash;

    const items = try array(try required(obj, "entities"));
    scene.entities = try storage.alloc(document.SceneEntity, items.len);

    var count: usize = 0;
    errdefer scene.entities = scene.entities[0..count];
    for (items, 0..) |item, i| {
        scene.entities[i] = try entityFromJson(storage, item);
        count += 1;
    }
    return scene;
}

fn entityJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entity: document.SceneEntity, indent: usize) !void {
    try spaces(allocator, out, indent);
    try out.appendSlice(allocator, "{\n");

    try spaces(allocator, out, indent + 2);
    try out.appendSlice(allocator, "\"id\": ");

    try json(allocator, out, entity.id);
    if (entity.parent_id) |v| {
        try out.appendSlice(allocator, ",\n");
        try spaces(allocator, out, indent + 2);
        try out.appendSlice(allocator, "\"parent_id\": ");
        try json(allocator, out, v);
    }

    try out.appendSlice(allocator, ",\n");
    try spaces(allocator, out, indent + 2);

    try out.appendSlice(allocator, "\"name\": ");
    try json(allocator, out, entity.name);
    try out.appendSlice(allocator, ",\n");
    try spaces(allocator, out, indent + 2);

    try out.appendSlice(allocator, "\"components\": [");
    const components = try allocator.dupe(document.SceneComponent, entity.components);
    defer allocator.free(components);
    std.mem.sort(document.SceneComponent, components, {}, lessComponent);
    for (components, 0..) |component, i| {
        if (i != 0) {
            try out.append(allocator, ',');
        }
        try componentJson(allocator, out, component, indent + 2);
    }

    try out.append(allocator, ']');
    if (entity.prefab.prefab_asset != null or entity.prefab.source_entity != null or entity.prefab.override_set_id != null) {
        try out.appendSlice(allocator, ",\n");
        try spaces(allocator, out, indent + 2);

        try out.appendSlice(allocator, "\"prefab\": {");
        var first = true;
        if (entity.prefab.prefab_asset) |v| {
            try objectPrefix(allocator, out, &first, "\"prefab_asset\": ");
            try json(allocator, out, v);
        }

        if (entity.prefab.source_entity) |v| {
            try objectPrefix(allocator, out, &first, "\"source_entity\": ");
            try json(allocator, out, v);
        }

        if (entity.prefab.override_set_id) |v| {
            try objectPrefix(allocator, out, &first, "\"override_set_id\": ");
            try json(allocator, out, v);
        }

        try out.append(allocator, '}');
    }

    try out.append(allocator, '\n');
    try spaces(allocator, out, indent);
    try out.append(allocator, '}');
}

fn componentJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), component: document.SceneComponent, indent: usize) !void {
    try out.append(allocator, '\n');
    try spaces(allocator, out, indent + 2);

    try out.appendSlice(allocator, "{\n");
    try spaces(allocator, out, indent + 4);

    try out.appendSlice(allocator, "\"type_id\": ");
    try json(allocator, out, component.type_id);
    try out.appendSlice(allocator, ",\n");
    try spaces(allocator, out, indent + 4);

    try out.appendSlice(allocator, "\"version\": ");
    try json(allocator, out, component.version);
    try out.appendSlice(allocator, ",\n");
    try spaces(allocator, out, indent + 4);

    try out.appendSlice(allocator, "\"fields\": [");
    const fields = try allocator.dupe(value.SceneField, component.fields);
    defer allocator.free(fields);
    std.mem.sort(value.SceneField, fields, {}, lessField);
    for (fields, 0..) |field, i| {
        if (i != 0) {
            try out.append(allocator, ',');
        }

        try out.append(allocator, '\n');
        try spaces(allocator, out, indent + 6);
        try out.appendSlice(allocator, "{\"number\": ");
        try json(allocator, out, field.number);

        try out.appendSlice(allocator, ", \"value\": ");
        try valueJson(allocator, out, field.value);
        try out.append(allocator, '}');
    }
    if (fields.len != 0) {
        try out.append(allocator, '\n');
        try spaces(allocator, out, indent + 4);
    }

    try out.appendSlice(allocator, "]\n");
    try spaces(allocator, out, indent + 2);
    try out.append(allocator, '}');
}

fn valueJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: value.Value) !void {
    try out.appendSlice(allocator, "{\"kind\": ");
    switch (v) {
        .bool => |x| try taggedJson(allocator, out, "bool", x),
        .i32 => |x| try taggedJson(allocator, out, "i32", x),
        .u32 => |x| try taggedJson(allocator, out, "u32", x),
        .f32 => |x| try taggedF32Json(allocator, out, "f32", x),
        .string => |x| try taggedJson(allocator, out, "string", x),
        .vec2 => |x| try taggedF32VectorJson(allocator, out, "vec2", &x),
        .vec3 => |x| try taggedF32VectorJson(allocator, out, "vec3", &x),
        .quat => |x| try taggedF32VectorJson(allocator, out, "quat", &x),
        .asset_ref => |x| try taggedJson(allocator, out, "asset_ref", x),
        .entity_ref => |x| try taggedJson(allocator, out, "entity_ref", x),
        .none => return error.InvalidValue,
    }
    try out.append(allocator, '}');
}

fn taggedJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, item: anytype) !void {
    try json(allocator, out, kind);
    try out.appendSlice(allocator, ", \"value\": ");
    try json(allocator, out, item);
}

/// `std.json.Stringify` promotes f32 values to f64 before formatting. Format
/// scene floats directly so their shortest f32 representation is preserved.
fn taggedF32Json(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, item: f32) !void {
    try json(allocator, out, kind);
    try out.appendSlice(allocator, ", \"value\": ");
    try f32Json(allocator, out, item);
}

fn taggedF32VectorJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, items: []const f32) !void {
    try json(allocator, out, kind);
    try out.appendSlice(allocator, ", \"value\": [");
    for (items, 0..) |item, i| {
        if (i != 0) try out.append(allocator, ',');
        try f32Json(allocator, out, item);
    }
    try out.append(allocator, ']');
}

fn f32Json(allocator: std.mem.Allocator, out: *std.ArrayList(u8), item: f32) !void {
    if (!std.math.isFinite(item)) return error.InvalidValue;
    var buf: [std.fmt.float.bufferSize(.decimal, f32)]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{}", .{item});
    try out.appendSlice(allocator, text);
}

fn entityFromJson(allocator: std.mem.Allocator, item: std.json.Value) !document.SceneEntity {
    const obj = try object(item);
    try rejectUnknown(obj, &.{ "id", "parent_id", "name", "components", "prefab" });
    var result = document.SceneEntity{ .id = try parseId(id.SceneEntityId, try string(try required(obj, "id"))), .parent_id = try optionalId(id.SceneEntityId, obj, "parent_id"), .name = try allocator.dupe(u8, try string(try required(obj, "name"))), .components = &.{}, .prefab = .{} };
    errdefer {
        allocator.free(result.name);
        for (result.components) |*c| {
            for (c.fields) |*f| f.value.deinit(allocator);
            allocator.free(c.fields);
        }
        allocator.free(result.components);
    }

    if (obj.get("prefab")) |p| {
        result.prefab = try prefabFromJson(p);
    }
    const items = try array(try required(obj, "components"));
    result.components = try allocator.alloc(document.SceneComponent, items.len);

    var count: usize = 0;
    errdefer result.components = result.components[0..count];
    for (items, 0..) |component, i| {
        result.components[i] = try componentFromJson(allocator, component);
        count += 1;
    }
    return result;
}

fn prefabFromJson(item: std.json.Value) !document.PrefabInstanceMetadata {
    const obj = try object(item);
    try rejectUnknown(obj, &.{ "prefab_asset", "source_entity", "override_set_id" });

    return .{
        .prefab_asset = try optionalId(id.AssetId, obj, "prefab_asset"),
        .source_entity = try optionalId(id.SceneEntityId, obj, "source_entity"),
        .override_set_id = try optionalId(Uuid, obj, "override_set_id"),
    };
}

fn componentFromJson(allocator: std.mem.Allocator, item: std.json.Value) !document.SceneComponent {
    const obj = try object(item);
    try rejectUnknown(obj, &.{ "type_id", "version", "fields" });

    var result = document.SceneComponent{ .type_id = try parseId(id.ComponentTypeId, try string(try required(obj, "type_id"))), .version = try u32Value(try required(obj, "version")), .fields = &.{} };
    errdefer {
        for (result.fields) |*f| f.value.deinit(allocator);
        allocator.free(result.fields);
    }
    const items = try array(try required(obj, "fields"));
    result.fields = try allocator.alloc(value.SceneField, items.len);

    var count: usize = 0;
    errdefer result.fields = result.fields[0..count];
    for (items, 0..) |field, i| {
        result.fields[i] = try fieldFromJson(allocator, field);
        count += 1;
    }
    return result;
}

fn fieldFromJson(allocator: std.mem.Allocator, item: std.json.Value) !value.SceneField {
    const obj = try object(item);
    try rejectUnknown(obj, &.{ "number", "value" });

    return .{
        .number = try u32Value(try required(obj, "number")),
        .value = try valueFromJson(allocator, try required(obj, "value")),
    };
}

fn valueFromJson(allocator: std.mem.Allocator, item: std.json.Value) !value.Value {
    const obj = try object(item);
    try rejectUnknown(obj, &.{ "kind", "value" });
    const kind = try string(try required(obj, "kind"));
    const raw = try required(obj, "value");

    if (std.mem.eql(u8, kind, "bool")) return .{ .bool = try boolValue(raw) };
    if (std.mem.eql(u8, kind, "i32")) return .{ .i32 = try intValue(i32, raw) };
    if (std.mem.eql(u8, kind, "u32")) return .{ .u32 = try u32Value(raw) };
    if (std.mem.eql(u8, kind, "f32")) return .{ .f32 = try floatValue(raw) };
    if (std.mem.eql(u8, kind, "string")) return .{ .string = try allocator.dupe(u8, try string(raw)) };
    if (std.mem.eql(u8, kind, "asset_ref")) return .{ .asset_ref = try parseId(id.AssetId, try string(raw)) };
    if (std.mem.eql(u8, kind, "entity_ref")) return .{ .entity_ref = try parseId(id.SceneEntityId, try string(raw)) };
    if (std.mem.eql(u8, kind, "vec2")) return .{ .vec2 = try vector(2, raw) };
    if (std.mem.eql(u8, kind, "vec3")) return .{ .vec3 = try vector(3, raw) };
    if (std.mem.eql(u8, kind, "quat")) return .{ .quat = try vector(4, raw) };

    return error.InvalidValue;
}

fn required(obj: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return obj.get(key) orelse error.MissingField;
}

fn object(item: std.json.Value) !std.json.ObjectMap {
    return switch (item) {
        .object => |x| x,
        else => error.InvalidValue,
    };
}

fn array(item: std.json.Value) ![]std.json.Value {
    return switch (item) {
        .array => |x| x.items,
        else => error.InvalidValue,
    };
}

fn string(item: std.json.Value) ![]const u8 {
    return switch (item) {
        .string => |x| x,
        else => error.InvalidValue,
    };
}

fn boolValue(item: std.json.Value) !bool {
    return switch (item) {
        .bool => |x| x,
        else => error.InvalidValue,
    };
}

fn intValue(comptime T: type, item: std.json.Value) !T {
    const raw: i64 = switch (item) {
        .integer => |x| x,
        else => return error.InvalidValue,
    };
    return std.math.cast(T, raw) orelse error.InvalidValue;
}

fn u32Value(item: std.json.Value) !u32 {
    return intValue(u32, item);
}

fn optionalU64(obj: std.json.ObjectMap, key: []const u8) !u64 {
    const item = obj.get(key) orelse return 0;
    return intValue(u64, item);
}

fn floatValue(item: std.json.Value) !f32 {
    const raw: f64 = switch (item) {
        .integer => |x| @floatFromInt(x),
        .float => |x| x,
        else => return error.InvalidValue,
    };
    return @floatCast(raw);
}

fn vector(comptime N: usize, item: std.json.Value) ![N]f32 {
    const items = try array(item);
    if (items.len != N) return error.InvalidValue;
    var out: [N]f32 = undefined;
    for (items, 0..) |x, i| out[i] = try floatValue(x);
    return out;
}

fn parseId(comptime T: type, text: []const u8) !T {
    return T.parse(text) catch error.InvalidValue;
}

fn optionalId(comptime T: type, obj: std.json.ObjectMap, key: []const u8) !?T {
    const item = obj.get(key) orelse return null;
    if (item == .null) {
        return null;
    }

    return @as(?T, try parseId(T, try string(item)));
}

fn rejectUnknown(obj: std.json.ObjectMap, allowed: []const []const u8) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        var known = false;
        for (allowed) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return error.UnknownField;
    }
}

fn json(allocator: std.mem.Allocator, out: *std.ArrayList(u8), item: anytype) !void {
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    defer out.* = writer.toArrayList();

    var stringify = std.json.Stringify{ .writer = &writer.writer };
    try stringify.write(item);
}

fn spaces(allocator: std.mem.Allocator, out: *std.ArrayList(u8), n: usize) !void {
    for (0..n) |_| {
        try out.append(allocator, ' ');
    }
}

fn objectPrefix(allocator: std.mem.Allocator, out: *std.ArrayList(u8), first: *bool, key: []const u8) !void {
    if (!first.*) {
        try out.appendSlice(allocator, ", ");
    }
    first.* = false;
    try out.appendSlice(allocator, key);
}

fn lessEntity(_: void, a: document.SceneEntity, b: document.SceneEntity) bool {
    const aa = a.id.toString();
    const bb = b.id.toString();
    return std.mem.lessThan(u8, &aa, &bb);
}

fn lessComponent(_: void, a: document.SceneComponent, b: document.SceneComponent) bool {
    const aa = a.type_id.toString();
    const bb = b.type_id.toString();
    const order = std.mem.order(u8, &aa, &bb);
    return if (order == .eq) a.version < b.version else order == .lt;
}

fn lessField(_: void, a: value.SceneField, b: value.SceneField) bool {
    return a.number < b.number;
}

test "load save load preserves a source scene and canonicalizes ordering" {
    const testing = std.testing;
    const scene_id = id.SceneId.parseComptime("8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a");
    const project_id = id.ProjectId.parseComptime("4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589");
    const entity_a = id.SceneEntityId.parseComptime("11111111-1111-4111-8111-111111111111");
    const entity_b = id.SceneEntityId.parseComptime("00000000-0000-4000-8000-000000000000");
    const component_a = id.ComponentTypeId.parseComptime("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    const component_b = id.ComponentTypeId.parseComptime("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    var fields = [_]value.SceneField{
        .{ .number = 9, .value = .{ .string = "owned after decoding" } },
        .{ .number = 2, .value = .{ .vec3 = .{ 1, 2, 3 } } },
    };
    var components = [_]document.SceneComponent{
        .{ .type_id = component_b, .fields = fields[0..] },
        .{ .type_id = component_a, .fields = &.{} },
    };
    var entities = [_]document.SceneEntity{
        .{ .id = entity_a, .name = "A", .components = &.{}, .prefab = .{} },
        .{ .id = entity_b, .name = "B", .components = components[0..], .prefab = .{} },
    };
    var source = try document.SceneDocument.init(testing.allocator, scene_id, project_id, "Sandbox");
    defer source.deinit();
    source.entities = entities[0..];

    const encoded = try encodeAlloc(testing.allocator, &source);
    defer testing.allocator.free(encoded);
    var decoded = try decode(testing.allocator, encoded);
    defer decoded.deinit();
    const encoded_again = try encodeAlloc(testing.allocator, &decoded);
    defer testing.allocator.free(encoded_again);
    var decoded_again = try decode(testing.allocator, encoded_again);
    defer decoded_again.deinit();

    try testing.expectEqualStrings(encoded, encoded_again);
    try testing.expect(decoded.scene_id.eql(source.scene_id));
    try testing.expectEqual(@as(usize, 2), decoded.entities.len);
    try testing.expect(decoded.entities[0].id.eql(entity_b));
    try testing.expect(decoded.entities[0].components[0].type_id.eql(component_a));
    try testing.expectEqual(@as(u32, 2), decoded.entities[0].components[1].fields[0].number);
    try testing.expectEqualStrings("owned after decoding", decoded_again.entities[0].components[1].fields[1].value.string);
}

test "encode emits concise f32 values without promoting them to f64" {
    const testing = std.testing;
    const scene_id = id.SceneId.parseComptime("8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a");
    const project_id = id.ProjectId.parseComptime("4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589");
    const entity_id = id.SceneEntityId.parseComptime("11111111-1111-4111-8111-111111111111");
    const component_id = id.ComponentTypeId.parseComptime("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");

    var fields = [_]value.SceneField{
        .{ .number = 1, .value = .{ .f32 = 0.8 } },
        .{ .number = 2, .value = .{ .vec3 = .{ 2.1, 0.012, 0.8 } } },
    };
    var components = [_]document.SceneComponent{
        .{ .type_id = component_id, .fields = fields[0..] },
    };
    var entities = [_]document.SceneEntity{
        .{ .id = entity_id, .name = "Entity", .components = components[0..], .prefab = .{} },
    };
    var source = try document.SceneDocument.init(testing.allocator, scene_id, project_id, "Sandbox");
    defer source.deinit();
    source.entities = entities[0..];

    const encoded = try encodeAlloc(testing.allocator, &source);
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"value\": 0.8") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"value\": [2.1,0.012,0.8]") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "0.800000011920929") == null);
    try testing.expect(std.mem.indexOf(u8, encoded, "2.0999999046325684") == null);

    var decoded = try decode(testing.allocator, encoded);
    defer decoded.deinit();
    try testing.expectEqual(@as(f32, 0.8), decoded.entities[0].components[0].fields[0].value.f32);
    try testing.expectEqual([3]f32{ 2.1, 0.012, 0.8 }, decoded.entities[0].components[0].fields[1].value.vec3);
}

test "json appends escaped values without a temporary allocation" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try out.appendSlice(std.testing.allocator, "prefix:");
    try json(std.testing.allocator, &out, "quoted \"newline\n");

    try std.testing.expectEqualStrings("prefix:\"quoted \\\"newline\\n\"", out.items);
}
