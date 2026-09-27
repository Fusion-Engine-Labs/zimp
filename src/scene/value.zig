const std = @import("std");

const id_types = @import("../id/id_types.zig");

const FieldKind = @import("schema.zig").FieldKind;
const ComponentTypeId = id_types.ComponentTypeId;
const SceneEntityId = id_types.SceneEntityId;
const AssetId = id_types.AssetId;

pub const Value = union(enum) {
    bool: bool,
    i32: i32,
    u32: u32,
    f32: f32,
    string: []const u8,
    vec2: [2]f32,
    vec3: [3]f32,
    quat: [4]f32,
    asset_ref: AssetId,
    entity_ref: SceneEntityId,
    none,

    /// Accepts a full `FieldKind` as well: a tagged union coerces to its tag.
    pub fn kindMatches(self: Value, kind: std.meta.Tag(FieldKind)) bool {
        return switch (self) {
            .bool => kind == .bool,
            .i32 => kind == .i32,
            .u32 => kind == .u32 or kind == .enum_ref,
            .f32 => kind == .f32,
            .string => kind == .string,
            .vec2 => kind == .vec2,
            .vec3 => kind == .vec3,
            .quat => kind == .quat,
            .asset_ref => kind == .asset_ref,
            .entity_ref => kind == .entity_ref,
            .none => false,
        };
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .string => |str| .{ .string = try allocator.dupe(u8, str) },
            else => self,
        };
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |str| allocator.free(str),
            else => {},
        }
        self.* = .none;
    }
};

pub const SceneField = struct {
    number: u32,
    value: Value,
};

pub const SceneComponentData = struct {
    component: ComponentTypeId,
    fields: []SceneField,

    pub fn deinit(self: *SceneComponentData, allocator: std.mem.Allocator) void {
        for (self.fields) |*f| {
            f.value.deinit(allocator);
        }
        allocator.free(self.fields);
        self.fields = &.{};
    }
};

const testing = std.testing;

test "Value.kindMatches maps values to schema field kinds" {
    const enum_schema: @import("schema.zig").EnumSchema = .{
        .name = "Mode",
        .entries = &.{.{ .name = "enabled", .value = 1 }},
    };

    try testing.expect((Value{ .bool = true }).kindMatches(.bool));
    try testing.expect((Value{ .i32 = -1 }).kindMatches(.i32));
    try testing.expect((Value{ .u32 = 1 }).kindMatches(.u32));
    try testing.expect((Value{ .u32 = 1 }).kindMatches(FieldKind{ .enum_ref = enum_schema }));
    try testing.expect((Value{ .f32 = 1.5 }).kindMatches(.f32));
    try testing.expect((Value{ .string = "name" }).kindMatches(.string));
    try testing.expect((Value{ .vec2 = .{ 1, 2 } }).kindMatches(.vec2));
    try testing.expect((Value{ .vec3 = .{ 1, 2, 3 } }).kindMatches(.vec3));
    try testing.expect((Value{ .quat = .{ 0, 0, 0, 1 } }).kindMatches(.quat));
    try testing.expect((Value{ .asset_ref = AssetId.zero }).kindMatches(FieldKind{ .asset_ref = .texture }));
    try testing.expect((Value{ .entity_ref = SceneEntityId.zero }).kindMatches(.entity_ref));
}

test "Value.kindMatches rejects mismatched and none values" {
    try testing.expect(!(Value{ .bool = true }).kindMatches(.f32));
    try testing.expect(!(Value{ .string = "name" }).kindMatches(.bool));
    try testing.expect(!(Value{ .none = {} }).kindMatches(.string));
}

test "Value.clone duplicates owned strings and copies scalar values" {
    const original = Value{ .string = "component" };
    var cloned = try original.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);

    try testing.expectEqualStrings("component", cloned.string);
    try testing.expect(cloned.string.ptr != original.string.ptr);

    const scalar = Value{ .f32 = 4.25 };
    const scalar_clone = try scalar.clone(testing.allocator);
    try testing.expectEqual(scalar, scalar_clone);
}

test "Value.deinit frees string storage and resets to none" {
    var value = try (Value{ .string = "temporary" }).clone(testing.allocator);
    value.deinit(testing.allocator);
    try testing.expectEqual(Value{ .none = {} }, value);
}

test "SceneComponentData.deinit frees fields and contained values" {
    const fields = try testing.allocator.alloc(SceneField, 2);
    fields[0] = .{ .number = 1, .value = try (Value{ .string = "name" }).clone(testing.allocator) };
    fields[1] = .{ .number = 2, .value = .{ .vec3 = .{ 1, 2, 3 } } };

    var data = SceneComponentData{
        .component = ComponentTypeId.zero,
        .fields = fields,
    };
    data.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), data.fields.len);
}
