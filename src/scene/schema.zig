const std = @import("std");

const id_types = @import("../id/id_types.zig");

const AssetKind = @import("../assets/asset.zig").AssetKind;
const ComponentTypeId = id_types.ComponentTypeId;
const Value = @import("value.zig").Value;

/// Cooked scenes store field numbers as u16.
pub const max_field_number: u32 = std.math.maxInt(u16);

pub const EnumSchema = struct {
    name: []const u8,
    entries: []const struct { name: []const u8, value: u32 },
};

pub const FieldKind = union(enum) {
    bool,
    i32,
    u32,
    f32,
    string,
    vec2,
    vec3,
    quat,
    asset_ref: AssetKind,
    entity_ref,
    enum_ref: EnumSchema,
};

pub const EditorFieldHints = struct {
    min: ?f32 = null,
    max: ?f32 = null,
    step: ?f32 = null,
    slider: bool = false,
    hidden: bool = false,
    readonly: bool = false,
    multiline: bool = false,
};

pub const ComponentSchema = struct {
    id: ComponentTypeId,
    name: []const u8,
    display_name: []const u8,
    version: u32,
    fields: []const FieldSchema,
};

pub const FieldSchema = struct {
    number: u32,
    name: []const u8,
    display_name: []const u8,
    kind: FieldKind,
    default_value: Value,
    editor: EditorFieldHints,
};

// Human-Authored Overides
pub const SchemaMeta = struct {
    id: []const u8,
    name: []const u8,
    display_name: ?[]const u8 = null,
    version: u32,
    fields: []const FieldMeta,
};

pub const FieldMeta = struct {
    name: []const u8,
    number: u32,
    display_name: ?[]const u8 = null,
    kind_override: ?FieldKind = null,
    default_override: ?Value = null,
    editor: EditorFieldHints = .{},
    transient: bool = false,
};

pub const SchemaError = error{
    InvalidComponentId,
    InvalidComponentName,
    InvalidComponentVersion,
    InvalidFieldNumber,
    InvalidFieldName,
    DuplicateFieldNumber,
    DuplicateFieldName,
    DefaultValueKindMismatch,
    HintsOnNonNumericField,
};

pub fn validateSchema(schema: ComponentSchema) SchemaError!void {
    if (schema.id.isZero()) {
        return error.InvalidComponentId;
    }
    if (schema.name.len == 0) {
        return error.InvalidComponentName;
    }
    if (schema.version == 0) {
        return error.InvalidComponentVersion;
    }

    for (schema.fields, 0..) |field, i| {
        if (field.number == 0 or field.number > max_field_number) {
            return error.InvalidFieldNumber;
        }
        if (field.name.len == 0) {
            return error.InvalidFieldName;
        }
        if (!field.default_value.kindMatches(field.kind)) {
            return error.DefaultValueKindMismatch;
        }

        const numeric = switch (field.kind) {
            .i32, .u32, .f32, .vec2, .vec3 => true,
            else => false,
        };
        if (!numeric and (field.editor.min != null or field.editor.max != null or field.editor.step != null))
            return error.HintsOnNonNumericField;

        for (schema.fields[0..i]) |prev| {
            if (prev.number == field.number) {
                return error.DuplicateFieldNumber;
            }
            if (std.mem.eql(u8, prev.name, field.name)) {
                return error.DuplicateFieldName;
            }
        }
    }
}

const testing = std.testing;

const valid_component_id = ComponentTypeId.parseComptime("12345678-9abc-4def-8012-3456789abcde");

fn validSchema(fields: []const FieldSchema) ComponentSchema {
    return .{
        .id = valid_component_id,
        .name = "Transform",
        .display_name = "Transform",
        .version = 1,
        .fields = fields,
    };
}

test "validateSchema accepts a valid component schema" {
    const fields = [_]FieldSchema{
        .{
            .number = 1,
            .name = "visible",
            .display_name = "Visible",
            .kind = .bool,
            .default_value = .{ .bool = true },
            .editor = .{},
        },
        .{
            .number = 2,
            .name = "position",
            .display_name = "Position",
            .kind = .vec3,
            .default_value = .{ .vec3 = .{ 0, 0, 0 } },
            .editor = .{ .min = -100, .max = 100, .step = 0.5 },
        },
    };

    try validateSchema(validSchema(&fields));
}

test "validateSchema rejects invalid component identity and metadata" {
    const fields = [_]FieldSchema{};

    var schema = validSchema(&fields);
    schema.id = ComponentTypeId.zero;
    try testing.expectError(error.InvalidComponentId, validateSchema(schema));

    schema = validSchema(&fields);
    schema.name = "";
    try testing.expectError(error.InvalidComponentName, validateSchema(schema));

    schema = validSchema(&fields);
    schema.version = 0;
    try testing.expectError(error.InvalidComponentVersion, validateSchema(schema));
}

test "validateSchema rejects invalid field number and name" {
    var fields = [_]FieldSchema{.{
        .number = 0,
        .name = "enabled",
        .display_name = "Enabled",
        .kind = .bool,
        .default_value = .{ .bool = true },
        .editor = .{},
    }};
    try testing.expectError(error.InvalidFieldNumber, validateSchema(validSchema(&fields)));

    fields[0].number = max_field_number + 1;
    try testing.expectError(error.InvalidFieldNumber, validateSchema(validSchema(&fields)));

    fields[0].number = 1;
    fields[0].name = "";
    try testing.expectError(error.InvalidFieldName, validateSchema(validSchema(&fields)));
}

test "validateSchema rejects duplicate field numbers and names" {
    var fields = [_]FieldSchema{
        .{
            .number = 1,
            .name = "enabled",
            .display_name = "Enabled",
            .kind = .bool,
            .default_value = .{ .bool = true },
            .editor = .{},
        },
        .{
            .number = 1,
            .name = "mode",
            .display_name = "Mode",
            .kind = .u32,
            .default_value = .{ .u32 = 0 },
            .editor = .{},
        },
    };
    try testing.expectError(error.DuplicateFieldNumber, validateSchema(validSchema(&fields)));

    fields[1].number = 2;
    fields[1].name = "enabled";
    try testing.expectError(error.DuplicateFieldName, validateSchema(validSchema(&fields)));
}

test "validateSchema rejects default values that do not match field kind" {
    const fields = [_]FieldSchema{.{
        .number = 1,
        .name = "enabled",
        .display_name = "Enabled",
        .kind = .bool,
        .default_value = .{ .f32 = 1.0 },
        .editor = .{},
    }};

    try testing.expectError(error.DefaultValueKindMismatch, validateSchema(validSchema(&fields)));
}

test "validateSchema accepts enum fields with u32 defaults" {
    const mode: EnumSchema = .{
        .name = "Mode",
        .entries = &.{
            .{ .name = "off", .value = 0 },
            .{ .name = "on", .value = 1 },
        },
    };
    const fields = [_]FieldSchema{.{
        .number = 1,
        .name = "mode",
        .display_name = "Mode",
        .kind = .{ .enum_ref = mode },
        .default_value = .{ .u32 = 1 },
        .editor = .{},
    }};

    try validateSchema(validSchema(&fields));
}

test "validateSchema permits numeric hints only on numeric fields" {
    const numeric_fields = [_]FieldSchema{
        .{ .number = 1, .name = "i", .display_name = "I", .kind = .i32, .default_value = .{ .i32 = 0 }, .editor = .{ .min = -1 } },
        .{ .number = 2, .name = "u", .display_name = "U", .kind = .u32, .default_value = .{ .u32 = 0 }, .editor = .{ .max = 10 } },
        .{ .number = 3, .name = "f", .display_name = "F", .kind = .f32, .default_value = .{ .f32 = 0 }, .editor = .{ .step = 0.25 } },
        .{ .number = 4, .name = "v2", .display_name = "V2", .kind = .vec2, .default_value = .{ .vec2 = .{ 0, 0 } }, .editor = .{ .min = -1 } },
        .{ .number = 5, .name = "v3", .display_name = "V3", .kind = .vec3, .default_value = .{ .vec3 = .{ 0, 0, 0 } }, .editor = .{ .max = 1 } },
    };
    try validateSchema(validSchema(&numeric_fields));

    const non_numeric_fields = [_]FieldSchema{.{
        .number = 1,
        .name = "label",
        .display_name = "Label",
        .kind = .string,
        .default_value = .{ .string = "" },
        .editor = .{ .min = 0 },
    }};
    try testing.expectError(error.HintsOnNonNumericField, validateSchema(validSchema(&non_numeric_fields)));
}
