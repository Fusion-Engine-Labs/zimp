const std = @import("std");
const document = @import("document.zig");
const value = @import("value.zig");
const id = @import("../id/id_types.zig");
const Uuid = @import("../id/uuid.zig").Uuid;

pub const magic = "ZSCN";
pub const version: u32 = 2;
pub const SceneBinaryHeader = struct {
    version: u32,
    schema_hash: u64,
    asset_manifest_hash: u64,
    scene_id: [16]u8,
    project_id: [16]u8,
    entity_count: u32,
};

pub const DecodeError = error{
    InvalidMagic,
    UnsupportedVersion,
    Truncated,
    InvalidScene,
    DuplicateEntityId,
    InvalidValue,
};

const value_tag = enum(u8) {
    bool,
    i32,
    u32,
    f32,
    string,
    vec2,
    vec3,
    quat,
    asset_ref,
    entity_ref,
};
const header_size = magic.len + 4 + 8 + 8 + 16 + 16 + 4;
const min_entity_size = 16 + 16 + 4 + 16 + 16 + 16 + 4;
const min_component_size = 16 + 4 + 4;
const min_field_size = 4 + 1 + 1;

pub fn encodeAlloc(allocator: std.mem.Allocator, scene: *const document.SceneDocument) ![]u8 {
    if (scene.scene_id.isZero() or
        scene.project_id.isZero() or
        scene.entities.len > std.math.maxInt(u32))
    {
        return error.InvalidScene;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, magic);
    try appendInt(&out, allocator, u32, version);
    try appendInt(&out, allocator, u64, scene.schema_hash);
    try appendInt(&out, allocator, u64, scene.asset_manifest_hash);
    try appendUuid(&out, allocator, scene.scene_id.uuid);
    try appendUuid(&out, allocator, scene.project_id.uuid);
    try appendInt(&out, allocator, u32, @intCast(scene.entities.len));

    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(allocator);
    var string_indices = std.StringHashMap(u32).init(allocator);
    defer string_indices.deinit();
    try collectStrings(allocator, &strings, &string_indices, scene);
    try appendInt(&out, allocator, u32, @intCast(strings.items.len));
    for (strings.items) |text| {
        try appendStringData(&out, allocator, text);
    }

    try appendStringIndex(&out, allocator, &string_indices, scene.name);
    for (scene.entities) |entity| {
        try appendEntity(&out, allocator, &string_indices, entity);
    }

    return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !document.SceneDocument {
    var reader = Reader{ .bytes = bytes };
    const found_magic = try reader.take(magic.len);
    if (!std.mem.eql(u8, found_magic, magic)) {
        return error.InvalidMagic;
    }

    const file_version = try reader.int(u32);
    if (file_version != version) {
        return error.UnsupportedVersion;
    }

    const schema_hash = try reader.int(u64);
    const asset_manifest_hash = try reader.int(u64);
    const scene_id = id.SceneId.fromUuid(try reader.uuid());
    const project_id = id.ProjectId.fromUuid(try reader.uuid());
    const entity_count = try reader.int(u32);
    if (scene_id.isZero() or project_id.isZero()) {
        return error.InvalidScene;
    }

    const string_count = try reader.int(u32);
    if (@as(usize, string_count) > reader.remaining() / 4) {
        return error.Truncated;
    }

    var scene = try document.SceneDocument.init(allocator, scene_id, project_id, "");
    errdefer scene.deinit();

    const storage = scene.arena.allocator();
    scene.schema_hash = schema_hash;
    scene.asset_manifest_hash = asset_manifest_hash;
    const strings = try readStringTable(storage, &reader, string_count);
    scene.name = try reader.stringReference(strings);

    // Each entity requires at least this many bytes, so never allocate an
    // attacker-controlled count unless the remaining input can contain it.
    if (@as(usize, entity_count) > reader.remaining() / min_entity_size) {
        return error.Truncated;
    }

    scene.entities = try storage.alloc(document.SceneEntity, entity_count);
    var loaded: usize = 0;
    errdefer scene.entities = scene.entities[0..loaded];

    var entity_ids = std.AutoHashMap([16]u8, void).init(allocator);
    defer entity_ids.deinit();
    try entity_ids.ensureTotalCapacity(entity_count);

    for (scene.entities) |*entity| {
        entity.* = try readEntity(storage, &reader, strings);
        const entry = try entity_ids.getOrPut(entity.id.uuid.bytes);
        if (entry.found_existing) {
            return error.DuplicateEntityId;
        }
        loaded += 1;
    }

    if (reader.remaining() != 0) {
        return error.InvalidScene;
    }

    return scene;
}

fn appendEntity(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    string_indices: *const std.StringHashMap(u32),
    entity: document.SceneEntity,
) !void {
    if (entity.components.len > std.math.maxInt(u32)) {
        return error.InvalidScene;
    }

    try appendUuid(out, allocator, entity.id.uuid);
    try appendUuid(out, allocator, if (entity.parent_id) |v| v.uuid else Uuid.zero);
    try appendStringIndex(out, allocator, string_indices, entity.name);
    try appendUuid(out, allocator, if (entity.prefab.prefab_asset) |v| v.uuid else Uuid.zero);
    try appendUuid(out, allocator, if (entity.prefab.source_entity) |v| v.uuid else Uuid.zero);
    try appendUuid(out, allocator, entity.prefab.override_set_id orelse Uuid.zero);
    try appendInt(out, allocator, u32, @intCast(entity.components.len));
    for (entity.components) |component| {
        try appendComponent(out, allocator, string_indices, component);
    }
}

fn appendComponent(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    string_indices: *const std.StringHashMap(u32),
    component: document.SceneComponent,
) !void {
    if (component.fields.len > std.math.maxInt(u32)) {
        return error.InvalidScene;
    }

    try appendUuid(out, allocator, component.type_id.uuid);
    try appendInt(out, allocator, u32, component.version);
    try appendInt(out, allocator, u32, @intCast(component.fields.len));
    for (component.fields) |field| {
        try appendInt(out, allocator, u32, field.number);
        try appendValue(out, allocator, string_indices, field.value);
    }
}

fn appendValue(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    string_indices: *const std.StringHashMap(u32),
    v: value.Value,
) !void {
    switch (v) {
        .bool => |x| {
            try appendTag(out, allocator, .bool);
            try appendInt(out, allocator, u8, @intFromBool(x));
        },
        .i32 => |x| {
            try appendTag(out, allocator, .i32);
            try appendInt(out, allocator, u32, @bitCast(x));
        },
        .u32 => |x| {
            try appendTag(out, allocator, .u32);
            try appendInt(out, allocator, u32, x);
        },
        .f32 => |x| {
            try appendTag(out, allocator, .f32);
            try appendInt(out, allocator, u32, @bitCast(x));
        },
        .string => |x| {
            try appendTag(out, allocator, .string);
            try appendStringIndex(out, allocator, string_indices, x);
        },
        .vec2 => |x| {
            try appendTag(out, allocator, .vec2);
            for (x) |n| try appendInt(out, allocator, u32, @bitCast(n));
        },
        .vec3 => |x| {
            try appendTag(out, allocator, .vec3);
            for (x) |n| try appendInt(out, allocator, u32, @bitCast(n));
        },
        .quat => |x| {
            try appendTag(out, allocator, .quat);
            for (x) |n| try appendInt(out, allocator, u32, @bitCast(n));
        },
        .asset_ref => |x| {
            try appendTag(out, allocator, .asset_ref);
            try appendUuid(out, allocator, x.uuid);
        },
        .entity_ref => |x| {
            try appendTag(out, allocator, .entity_ref);
            try appendUuid(out, allocator, x.uuid);
        },
        .none => return error.InvalidValue,
    }
}

fn appendTag(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tag: value_tag) !void {
    try appendInt(out, allocator, u8, @intFromEnum(tag));
}

fn appendUuid(out: *std.ArrayList(u8), allocator: std.mem.Allocator, uuid: Uuid) !void {
    try out.appendSlice(allocator, &uuid.bytes);
}

fn appendStringData(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (text.len > std.math.maxInt(u32)) {
        return error.InvalidScene;
    }

    try appendInt(out, allocator, u32, @intCast(text.len));
    try out.appendSlice(allocator, text);
}

fn appendStringIndex(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    string_indices: *const std.StringHashMap(u32),
    text: []const u8,
) !void {
    const index = string_indices.get(text) orelse return error.InvalidScene;
    try appendInt(out, allocator, u32, index);
}

fn appendInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, n: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, n, .little);
    try out.appendSlice(allocator, &bytes);
}

fn collectStrings(
    allocator: std.mem.Allocator,
    strings: *std.ArrayList([]const u8),
    indices: *std.StringHashMap(u32),
    scene: *const document.SceneDocument,
) !void {
    try internString(allocator, strings, indices, scene.name);
    for (scene.entities) |entity| {
        try internString(allocator, strings, indices, entity.name);
        for (entity.components) |component| {
            for (component.fields) |field| {
                if (field.value == .string) {
                    try internString(allocator, strings, indices, field.value.string);
                }
            }
        }
    }
}

fn internString(
    allocator: std.mem.Allocator,
    strings: *std.ArrayList([]const u8),
    indices: *std.StringHashMap(u32),
    text: []const u8,
) !void {
    const entry = try indices.getOrPut(text);
    if (entry.found_existing) {
        return;
    }
    if (strings.items.len >= std.math.maxInt(u32)) {
        return error.InvalidScene;
    }
    entry.value_ptr.* = @intCast(strings.items.len);
    try strings.append(allocator, text);
}

fn readEntity(allocator: std.mem.Allocator, reader: *Reader, strings: []const []const u8) !document.SceneEntity {
    const entity_id = id.SceneEntityId.fromUuid(try reader.uuid());
    const parent = try reader.uuid();
    var entity = document.SceneEntity{
        .id = entity_id,
        .parent_id = if (parent.isZero()) null else id.SceneEntityId.fromUuid(parent),
        .name = try reader.stringReference(strings),
        .components = &.{},
        .prefab = .{},
    };
    errdefer {
        allocator.free(entity.name);
        for (entity.components) |*c| freeComponent(allocator, c);
        allocator.free(entity.components);
    }
    const prefab_asset = try reader.uuid();
    const source_entity = try reader.uuid();
    const override_set_id = try reader.uuid();
    entity.prefab = .{
        .prefab_asset = if (prefab_asset.isZero()) null else id.AssetId.fromUuid(prefab_asset),
        .source_entity = if (source_entity.isZero()) null else id.SceneEntityId.fromUuid(source_entity),
        .override_set_id = if (override_set_id.isZero()) null else override_set_id,
    };
    const count = try reader.int(u32);
    if (@as(usize, count) > reader.remaining() / min_component_size) {
        return error.Truncated;
    }

    entity.components = try allocator.alloc(document.SceneComponent, count);
    var loaded: usize = 0;
    errdefer entity.components = entity.components[0..loaded];

    for (entity.components) |*component| {
        component.* = try readComponent(allocator, reader, strings);
        loaded += 1;
    }
    return entity;
}

fn readComponent(allocator: std.mem.Allocator, reader: *Reader, strings: []const []const u8) !document.SceneComponent {
    var component = document.SceneComponent{
        .type_id = id.ComponentTypeId.fromUuid(try reader.uuid()),
        .version = try reader.int(u32),
        .fields = &.{},
    };
    errdefer freeComponent(allocator, &component);

    const count = try reader.int(u32);
    if (@as(usize, count) > reader.remaining() / min_field_size) {
        return error.Truncated;
    }

    component.fields = try allocator.alloc(value.SceneField, count);
    var loaded: usize = 0;
    errdefer component.fields = component.fields[0..loaded];

    for (component.fields) |*field| {
        field.number = try reader.int(u32);
        field.value = try readValue(reader, strings);
        loaded += 1;
    }
    return component;
}

fn readValue(reader: *Reader, strings: []const []const u8) !value.Value {
    const tag = std.enums.fromInt(value_tag, try reader.int(u8)) orelse return error.InvalidValue;
    return switch (tag) {
        .bool => switch (try reader.int(u8)) {
            0 => .{ .bool = false },
            1 => .{ .bool = true },
            else => error.InvalidValue,
        },
        .i32 => .{ .i32 = @bitCast(try reader.int(u32)) },
        .u32 => .{ .u32 = try reader.int(u32) },
        .f32 => .{ .f32 = @bitCast(try reader.int(u32)) },
        .string => .{ .string = try reader.stringReference(strings) },
        .vec2 => .{ .vec2 = .{ @bitCast(try reader.int(u32)), @bitCast(try reader.int(u32)) } },
        .vec3 => .{ .vec3 = .{ @bitCast(try reader.int(u32)), @bitCast(try reader.int(u32)), @bitCast(try reader.int(u32)) } },
        .quat => .{ .quat = .{ @bitCast(try reader.int(u32)), @bitCast(try reader.int(u32)), @bitCast(try reader.int(u32)), @bitCast(try reader.int(u32)) } },
        .asset_ref => .{ .asset_ref = id.AssetId.fromUuid(try reader.uuid()) },
        .entity_ref => .{ .entity_ref = id.SceneEntityId.fromUuid(try reader.uuid()) },
    };
}

fn freeComponent(allocator: std.mem.Allocator, component: *document.SceneComponent) void {
    for (component.fields) |*field| field.value.deinit(allocator);
    allocator.free(component.fields);
}

fn readStringTable(allocator: std.mem.Allocator, reader: *Reader, count: u32) ![]const []const u8 {
    const strings = try allocator.alloc([]const u8, count);
    for (strings) |*text| {
        text.* = try reader.stringAlloc(allocator);
    }
    return strings;
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.pos;
    }

    fn take(self: *Reader, len: usize) ![]const u8 {
        if (len > self.remaining()) return error.Truncated;
        const result = self.bytes[self.pos..][0..len];
        self.pos += len;
        return result;
    }

    fn int(self: *Reader, comptime T: type) !T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    fn uuid(self: *Reader) !Uuid {
        var bytes: [16]u8 = undefined;
        @memcpy(&bytes, try self.take(16));
        return .{ .bytes = bytes };
    }

    fn stringAlloc(self: *Reader, allocator: std.mem.Allocator) ![]u8 {
        const len = try self.int(u32);
        if (@as(usize, len) > self.remaining()) {
            return error.Truncated;
        }
        return allocator.dupe(u8, try self.take(len));
    }

    fn stringReference(self: *Reader, strings: []const []const u8) ![]const u8 {
        const index = try self.int(u32);
        if (index >= strings.len) {
            return error.InvalidScene;
        }
        return strings[index];
    }
};

test "JSON source and cooked binary decode to equivalent documents" {
    const json_codec = @import("json_codec.zig");
    const testing = std.testing;
    const input =
        \\{"format":"fusion.scene","version":2,"scene_id":"8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a","project_id":"4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589","name":"Sandbox","entities":[{"id":"00000000-0000-4000-8000-000000000001","name":"Camera","components":[{"type_id":"11111111-1111-4111-8111-111111111111","version":1,"fields":[{"number":1,"value":{"kind":"string","value":"main"}}]}]}]}
    ;
    var source = try json_codec.decode(testing.allocator, input);
    defer source.deinit();
    const bytes = try encodeAlloc(testing.allocator, &source);
    defer testing.allocator.free(bytes);
    var cooked = try decode(testing.allocator, bytes);
    defer cooked.deinit();
    try testing.expect(cooked.scene_id.eql(source.scene_id));
    try testing.expect(cooked.project_id.eql(source.project_id));
    try testing.expectEqualStrings(source.name, cooked.name);
    try testing.expectEqual(@as(usize, 1), cooked.entities.len);
    try testing.expectEqualStrings("main", cooked.entities[0].components[0].fields[0].value.string);
}

test "truncated cooked data fails before a large allocation" {
    const testing = std.testing;
    var bytes: [header_size]u8 = [_]u8{0} ** header_size;
    @memcpy(bytes[0..magic.len], magic);
    std.mem.writeInt(u32, bytes[4..8], version, .little);
    bytes[24] = 1; // non-zero scene id
    bytes[40] = 1; // non-zero project id
    std.mem.writeInt(u32, bytes[header_size - 4 ..], std.math.maxInt(u32), .little);
    try testing.expectError(error.Truncated, decode(testing.allocator, &bytes));
}
