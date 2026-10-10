//! `.zscn`: the cooked binary form of a `SceneDocument`.
//!
//! File layout: `Header`, then these sections in order, each at the next
//! 16-byte boundary (`wire.Layout`). Section sizes follow from the header
//! counts, so the file carries no offsets:
//!
//!   entity_ids       [entity_count][16]u8, strictly ascending by bytes
//!   entities         [entity_count]Entity, in `entity_ids` order
//!   prefabs          [prefab_count]Prefab, one per entity with prefab bits
//!   component_types  [component_type_count]ComponentType, sorted by (id, version)
//!   components       [component_count]Component, entity by entity
//!   fields           [field_count]Field, component by component
//!   values           [value_lane_count]u32, field by field (`ValueKind.lanes`)
//!   strings          [string_bytes]u8: the scene name, then each entity's
//!                    name followed by its string values
//!
//! References inside the scene (parents, prefab sources, `entity_ref`
//! values) are indices into `entity_ids`. Ranges (an entity's components, a
//! component's fields, string offsets) follow from running sums of the
//! counts. `decode` accepts exactly what `encodeAlloc` produces: canonical
//! order, zero padding and reserved bytes, every component type used, and
//! counts that fill each section.

const std = @import("std");
const constants = @import("../shared/constants.zig");
const document = @import("document.zig");
const json_codec = @import("json_codec.zig");
const max_field_number = @import("schema.zig").max_field_number;
const value = @import("value.zig");
const wire = @import("../shared/wire.zig");
const id = @import("../id/id_types.zig");
const Uuid = @import("../id/uuid.zig").Uuid;

pub const magic = constants.FORMAT_MAGIC.ZSCN;
pub const version: u32 = 3;

/// Entity index meaning "no entity": a root's parent, an absent prefab
/// source, or a zero `entity_ref`.
pub const none: u32 = std.math.maxInt(u32);

pub const max_components_per_entity = std.math.maxInt(u16);
pub const max_fields_per_component = std.math.maxInt(u16);
/// `Component.type_index` is a u16.
pub const max_component_types = 1 << 16;

pub const Header = extern struct {
    file: wire.FileHeader,
    scene_id: [16]u8,
    project_id: [16]u8,
    schema_hash: u64,
    asset_manifest_hash: u64,
    entity_count: u32,
    prefab_count: u32,
    component_type_count: u32,
    component_count: u32,
    field_count: u32,
    value_lane_count: u32,
    string_bytes: u32,
    name_len: u32,
};

pub const Entity = extern struct {
    name_len: u32,
    /// Index of the parent entity, or `none`.
    parent: u32,
    component_count: u16,
    /// `prefab_*_bit`s; non-zero means the next `Prefab` record belongs here.
    prefab_flags: u8,
    _reserved: u8 = 0,
};

pub const prefab_asset_bit: u8 = 0x1;
pub const prefab_source_bit: u8 = 0x2;
pub const prefab_override_bit: u8 = 0x4;
const prefab_bits = prefab_asset_bit | prefab_source_bit | prefab_override_bit;

/// A field whose bit is clear is zero (`none` for `source_entity`); a field
/// whose bit is set is non-zero.
pub const Prefab = extern struct {
    prefab_asset: [16]u8,
    override_set_id: [16]u8,
    source_entity: u32,
};

pub const ComponentType = extern struct {
    id: [16]u8,
    version: u32,
};

pub const Component = extern struct {
    type_index: u16,
    field_count: u16,
};

pub const Field = extern struct {
    number: u16,
    /// `ValueKind`.
    kind: u8,
    _reserved: u8 = 0,
};

pub const ValueKind = enum(u8) {
    bool,
    i32,
    u32,
    f32,
    /// One lane: the byte length of the next string in `strings`.
    string,
    vec2,
    vec3,
    quat,
    asset_ref,
    /// One lane: an entity index, or `none` for the zero id.
    entity_ref,

    pub fn lanes(self: ValueKind) usize {
        return switch (self) {
            .bool, .i32, .u32, .f32, .string, .entity_ref => 1,
            .vec2 => 2,
            .vec3 => 3,
            .quat, .asset_ref => 4,
        };
    }
};

comptime {
    wire.assertTightLayout(Header);
    wire.assertTightLayout(Entity);
    wire.assertTightLayout(Prefab);
    wire.assertTightLayout(ComponentType);
    wire.assertTightLayout(Component);
    wire.assertTightLayout(Field);
    std.debug.assert(@sizeOf(Header) % wire.section_alignment == 0);
}

const Counts = struct {
    entities: usize = 0,
    prefabs: usize = 0,
    component_types: usize = 0,
    components: usize = 0,
    fields: usize = 0,
    value_lanes: usize = 0,
    string_bytes: usize = 0,
};

const section_names = .{ "entity_ids", "entities", "prefabs", "component_types", "components", "fields", "values", "strings" };

const Sections = struct {
    entity_ids: wire.Span,
    entities: wire.Span,
    prefabs: wire.Span,
    component_types: wire.Span,
    components: wire.Span,
    fields: wire.Span,
    values: wire.Span,
    strings: wire.Span,
    total_size: u32,
};

fn layoutFor(counts: Counts) !Sections {
    var layout = wire.Layout.init(@sizeOf(Header));
    var sections: Sections = undefined;
    sections.entity_ids = try reserve(&layout, counts.entities, 16);
    sections.entities = try reserve(&layout, counts.entities, @sizeOf(Entity));
    sections.prefabs = try reserve(&layout, counts.prefabs, @sizeOf(Prefab));
    sections.component_types = try reserve(&layout, counts.component_types, @sizeOf(ComponentType));
    sections.components = try reserve(&layout, counts.components, @sizeOf(Component));
    sections.fields = try reserve(&layout, counts.fields, @sizeOf(Field));
    sections.values = try reserve(&layout, counts.value_lanes, @sizeOf(u32));
    sections.strings = try reserve(&layout, counts.string_bytes, 1);
    sections.total_size = layout.totalSize();
    return sections;
}

fn reserve(layout: *wire.Layout, count: usize, size: usize) !wire.Span {
    return layout.reserve(std.math.mul(usize, count, size) catch return error.AssetTooLarge);
}

/// Typed views of a file's sections, validated for layout only.
const Tables = struct {
    header: *const Header,
    entity_ids: []const [16]u8,
    entities: []const Entity,
    prefabs: []const Prefab,
    component_types: []const ComponentType,
    components: []const Component,
    fields: []const Field,
    values: []const u32,
    strings: []const u8,
};

fn tablesAt(bytes: wire.Bytes) !Tables {
    _ = try wire.FileHeader.validate(bytes, magic, version);
    const header = try wire.structAt(Header, bytes, 0);
    if (header.component_type_count > max_component_types) return error.TooManyComponentTypes;
    if (header.name_len > header.string_bytes) return error.InvalidStringLength;

    // Sized from the counts and checked against the file before anything is
    // allocated, so hostile counts fail here.
    const sections = try layoutFor(.{
        .entities = header.entity_count,
        .prefabs = header.prefab_count,
        .component_types = header.component_type_count,
        .components = header.component_count,
        .fields = header.field_count,
        .value_lanes = header.value_lane_count,
        .string_bytes = header.string_bytes,
    });
    if (sections.total_size != bytes.len) return error.InvalidLayout;

    var end: usize = @sizeOf(Header);
    inline for (section_names) |name| {
        const span = @field(sections, name);
        if (span.len != 0) {
            if (!allZero(bytes[end..span.offset])) return error.InvalidPadding;
            end = @intCast(span.end());
        }
    }

    return .{
        .header = header,
        .entity_ids = try wire.sliceAt([16]u8, bytes, sections.entity_ids.offset, header.entity_count),
        .entities = try wire.sliceAt(Entity, bytes, sections.entities.offset, header.entity_count),
        .prefabs = try wire.sliceAt(Prefab, bytes, sections.prefabs.offset, header.prefab_count),
        .component_types = try wire.sliceAt(ComponentType, bytes, sections.component_types.offset, header.component_type_count),
        .components = try wire.sliceAt(Component, bytes, sections.components.offset, header.component_count),
        .fields = try wire.sliceAt(Field, bytes, sections.fields.offset, header.field_count),
        .values = try wire.sliceAt(u32, bytes, sections.values.offset, header.value_lane_count),
        .strings = try wire.sliceAt(u8, bytes, sections.strings.offset, header.string_bytes),
    };
}

const Cursor = struct {
    prefab: usize = 0,
    component: usize = 0,
    field: usize = 0,
    lane: usize = 0,
    string: usize = 0,
};

/// Every content rule of the format. Shared by `decode` and `encodeAlloc`, so
/// the writer can't emit a file `decode` rejects.
fn checkTables(allocator: std.mem.Allocator, t: Tables) !void {
    const header = t.header;
    if (allZero(&header.scene_id) or allZero(&header.project_id)) return error.InvalidScene;

    for (t.entity_ids, 0..) |entity_id, i| {
        if (i == 0) {
            if (allZero(&entity_id)) return error.ZeroEntityId;
        } else if (idKey(&t.entity_ids[i - 1]) >= idKey(&entity_id)) {
            return error.UnsortedEntityIds;
        }
    }
    for (t.component_types, 0..) |component_type, i| {
        if (allZero(&component_type.id)) return error.ZeroComponentTypeId;
        if (component_type.version == 0) return error.ZeroComponentVersion;
        if (i > 0 and orderTypes(t.component_types[i - 1], component_type) != .lt) return error.UnsortedComponentTypes;
    }

    const entity_count = t.entities.len;
    const scratch = try allocator.alloc(u8, entity_count + t.component_types.len);
    defer allocator.free(scratch);
    @memset(scratch, 0);
    const type_used = scratch[entity_count..];

    var cursor: Cursor = .{ .string = header.name_len };
    for (t.entities, 0..) |entity, entity_index| {
        if (entity._reserved != 0) return error.InvalidReserved;
        try takeString(&cursor.string, entity.name_len, t.strings.len);
        if (entity.parent != none) {
            if (entity.parent >= entity_count) return error.InvalidEntityIndex;
            if (entity.parent == entity_index) return error.SelfParent;
        }
        if (entity.prefab_flags & ~prefab_bits != 0) return error.InvalidPrefab;
        if (entity.prefab_flags != 0) {
            const prefab = try take(Prefab, t.prefabs, &cursor.prefab, 1);
            try checkPrefab(prefab[0], entity.prefab_flags, entity_count);
        }

        const components = try take(Component, t.components, &cursor.component, entity.component_count);
        for (components, 0..) |component, i| {
            if (component.type_index >= t.component_types.len) return error.InvalidComponentType;
            if (i > 0) {
                const previous = components[i - 1].type_index;
                if (component.type_index <= previous) return error.UnsortedComponents;
                // Types are sorted by id, so a repeated id would sit next
                // to itself here.
                if (std.mem.eql(u8, &t.component_types[previous].id, &t.component_types[component.type_index].id))
                    return error.DuplicateComponentTypeId;
            }
            type_used[component.type_index] = 1;

            const fields = try take(Field, t.fields, &cursor.field, component.field_count);
            var previous_number: u16 = 0;
            for (fields) |field| {
                if (field._reserved != 0) return error.InvalidReserved;
                if (field.number <= previous_number) return error.UnsortedFieldNumbers;
                previous_number = field.number;
                const kind = try wire.enumFromInt(ValueKind, field.kind);
                const lanes = try take(u32, t.values, &cursor.lane, kind.lanes());
                switch (kind) {
                    .bool => if (lanes[0] > 1) return error.InvalidValue,
                    .string => try takeString(&cursor.string, lanes[0], t.strings.len),
                    .entity_ref => if (lanes[0] != none and lanes[0] >= entity_count) return error.InvalidEntityIndex,
                    else => {},
                }
            }
        }
    }
    if (cursor.prefab != t.prefabs.len or
        cursor.component != t.components.len or
        cursor.field != t.fields.len or
        cursor.lane != t.values.len or
        cursor.string != t.strings.len)
    {
        return error.InvalidLayout;
    }
    if (std.mem.indexOfScalar(u8, type_used, 0) != null) return error.UnusedComponentType;

    try checkAcyclic(t.entities, scratch[0..entity_count]);
}

fn checkPrefab(prefab: Prefab, flags: u8, entity_count: usize) !void {
    if ((flags & prefab_asset_bit != 0) == allZero(&prefab.prefab_asset)) return error.InvalidPrefab;
    if ((flags & prefab_override_bit != 0) == allZero(&prefab.override_set_id)) return error.InvalidPrefab;
    if (flags & prefab_source_bit != 0) {
        if (prefab.source_entity >= entity_count) return error.InvalidEntityIndex;
    } else if (prefab.source_entity != none) {
        return error.InvalidPrefab;
    }
}

/// Rejects parent cycles in O(n). `state` (one zeroed byte per entity)
/// marks entities on the current walk (1) and entities known to reach a
/// root (2). Parent indices must already be in range.
fn checkAcyclic(entities: []const Entity, state: []u8) !void {
    for (0..entities.len) |start| {
        if (state[start] != 0) continue;
        var i = start;
        while (true) {
            state[i] = 1;
            const parent = entities[i].parent;
            if (parent == none or state[parent] == 2) break;
            if (state[parent] == 1) return error.EntityParentCycle;
            i = parent;
        }
        i = start;
        while (state[i] == 1) {
            state[i] = 2;
            const parent = entities[i].parent;
            if (parent == none) break;
            i = parent;
        }
    }
}

fn take(comptime T: type, items: []const T, cursor: *usize, count: usize) ![]const T {
    if (count > items.len - cursor.*) return error.InvalidLayout;
    defer cursor.* += count;
    return items[cursor.*..][0..count];
}

fn takeString(cursor: *usize, len: u32, blob_len: usize) !void {
    if (len > blob_len - cursor.*) return error.InvalidStringLength;
    cursor.* += len;
}

/// Enforces the format's structure: everything needed to build a document
/// whose references resolve and whose ids, components, and fields are
/// unique. Size limits are the caller's policy, as for `json_codec.decode`;
/// `SceneDocument.load` applies them with `validate.validateLimits`.
pub fn decode(allocator: std.mem.Allocator, bytes: wire.Bytes) !document.SceneDocument {
    const t = try tablesAt(bytes);
    try checkTables(allocator, t);
    const header = t.header;

    var scene = try document.SceneDocument.init(allocator, .fromBytes(header.scene_id), .fromBytes(header.project_id), "");
    errdefer scene.deinit();
    scene.schema_hash = header.schema_hash;
    scene.asset_manifest_hash = header.asset_manifest_hash;

    // One block per table; entities, components, and strings are slices into them.
    const storage = scene.arena.allocator();
    const strings = try storage.dupe(u8, t.strings);
    const entities = try storage.alloc(document.SceneEntity, t.entities.len);
    const components = try storage.alloc(document.SceneComponent, t.components.len);
    const fields = try storage.alloc(value.SceneField, t.fields.len);

    var cursor: Cursor = .{ .string = header.name_len };
    scene.name = strings[0..header.name_len];
    for (t.entities, t.entity_ids, entities) |entity, entity_id, *out| {
        out.* = .{
            .id = .fromBytes(entity_id),
            .parent_id = if (entity.parent == none) null else id.SceneEntityId.fromBytes(t.entity_ids[entity.parent]),
            .name = strings[cursor.string..][0..entity.name_len],
            .components = components[cursor.component..][0..entity.component_count],
            .prefab = .{},
        };
        cursor.string += entity.name_len;
        if (entity.prefab_flags != 0) {
            out.prefab = prefabMetadata(t.prefabs[cursor.prefab], entity.prefab_flags, t.entity_ids);
            cursor.prefab += 1;
        }

        for (t.components[cursor.component..][0..entity.component_count], out.components) |component, *component_out| {
            const component_type = t.component_types[component.type_index];
            component_out.* = .{
                .type_id = .fromBytes(component_type.id),
                .version = component_type.version,
                .fields = fields[cursor.field..][0..component.field_count],
            };
            for (t.fields[cursor.field..][0..component.field_count], component_out.fields) |field, *field_out| {
                const kind: ValueKind = @enumFromInt(field.kind);
                const lanes = t.values[cursor.lane..][0..kind.lanes()];
                cursor.lane += lanes.len;
                field_out.* = .{
                    .number = field.number,
                    .value = decodeValue(kind, lanes, t.entity_ids, strings, &cursor.string),
                };
            }
            cursor.field += component.field_count;
        }
        cursor.component += entity.component_count;
    }
    scene.entities = entities;
    return scene;
}

fn prefabMetadata(prefab: Prefab, flags: u8, entity_ids: []const [16]u8) document.PrefabInstanceMetadata {
    return .{
        .prefab_asset = if (flags & prefab_asset_bit != 0) id.AssetId.fromBytes(prefab.prefab_asset) else null,
        .source_entity = if (flags & prefab_source_bit != 0) id.SceneEntityId.fromBytes(entity_ids[prefab.source_entity]) else null,
        .override_set_id = if (flags & prefab_override_bit != 0) Uuid.fromBytes(prefab.override_set_id) else null,
    };
}

fn decodeValue(kind: ValueKind, lanes: []const u32, entity_ids: []const [16]u8, strings: []const u8, string_cursor: *usize) value.Value {
    return switch (kind) {
        .bool => .{ .bool = lanes[0] != 0 },
        .i32 => .{ .i32 = @bitCast(lanes[0]) },
        .u32 => .{ .u32 = lanes[0] },
        .f32 => .{ .f32 = @bitCast(lanes[0]) },
        .string => blk: {
            const text = strings[string_cursor.*..][0..lanes[0]];
            string_cursor.* += lanes[0];
            break :blk .{ .string = text };
        },
        .vec2 => .{ .vec2 = @bitCast(lanes[0..2].*) },
        .vec3 => .{ .vec3 = @bitCast(lanes[0..3].*) },
        .quat => .{ .quat = @bitCast(lanes[0..4].*) },
        .asset_ref => .{ .asset_ref = .fromBytes(@bitCast(lanes[0..4].*)) },
        .entity_ref => .{ .entity_ref = if (lanes[0] == none) .zero else .fromBytes(entity_ids[lanes[0]]) },
    };
}

/// Entities are written sorted by id, components by type, and fields by
/// number, so the output depends only on the document's content. A zero
/// `entity_ref` is stored as `none`; a zero prefab id counts as absent.
pub fn encodeAlloc(allocator: std.mem.Allocator, scene: *const document.SceneDocument) ![]align(wire.section_alignment) u8 {
    // Decoding always yields the current document format and version.
    if (!std.mem.eql(u8, scene.format, json_codec.scene_format) or scene.version != json_codec.scene_version)
        return error.InvalidSceneFormat;
    if (scene.scene_id.isZero() or scene.project_id.isZero()) return error.InvalidScene;
    const source: []const document.SceneEntity = scene.entities;
    if (source.len >= none) return error.InvalidScene;

    const order = try allocator.alloc(u32, source.len);
    defer allocator.free(order);
    for (order, 0..) |*index, i| index.* = @intCast(i);
    std.mem.sort(u32, order, source, lessEntity);

    const entity_ids = try allocator.alloc([16]u8, source.len);
    defer allocator.free(entity_ids);
    for (entity_ids, order) |*entity_id, index| entity_id.* = source[index].id.uuid.bytes;
    for (entity_ids, 0..) |entity_id, i| {
        if (i == 0) {
            if (allZero(&entity_id)) return error.ZeroEntityId;
        } else if (idKey(&entity_ids[i - 1]) == idKey(&entity_id)) {
            return error.DuplicateEntityId;
        }
    }

    // Count everything and collect the component types.
    var types: std.ArrayList(ComponentType) = .empty;
    defer types.deinit(allocator);
    var counts: Counts = .{ .entities = source.len, .string_bytes = scene.name.len };
    var max_components: usize = 0;
    var max_fields: usize = 0;
    for (source) |entity| {
        if (entity.components.len > max_components_per_entity) return error.TooManyComponents;
        max_components = @max(max_components, entity.components.len);
        counts.string_bytes += entity.name.len;
        if (prefabFlags(entity.prefab) != 0) counts.prefabs += 1;
        counts.components += entity.components.len;
        for (entity.components) |component| {
            if (component.fields.len > max_fields_per_component) return error.TooManyFields;
            if (component.type_id.isZero()) return error.ZeroComponentTypeId;
            if (component.version == 0) return error.ZeroComponentVersion;
            max_fields = @max(max_fields, component.fields.len);
            try types.append(allocator, .{ .id = component.type_id.uuid.bytes, .version = component.version });
            counts.fields += component.fields.len;
            for (component.fields) |field| {
                if (field.number == 0 or field.number > max_field_number) return error.InvalidFieldNumber;
                counts.value_lanes += (try kindOf(field.value)).lanes();
                if (field.value == .string) counts.string_bytes += field.value.string.len;
            }
        }
    }
    std.mem.sort(ComponentType, types.items, {}, lessType);
    var unique: usize = 0;
    for (types.items) |component_type| {
        if (unique == 0 or orderTypes(types.items[unique - 1], component_type) != .eq) {
            types.items[unique] = component_type;
            unique += 1;
        }
    }
    types.shrinkRetainingCapacity(unique);
    if (unique > max_component_types) return error.TooManyComponentTypes;
    counts.component_types = unique;

    const sections = try layoutFor(counts);
    const bytes = try allocator.alignedAlloc(u8, wire.alignment, sections.total_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);

    const header: *Header = @ptrCast(bytes.ptr);
    header.* = .{
        .file = .init(magic, version, sections.total_size),
        .scene_id = scene.scene_id.uuid.bytes,
        .project_id = scene.project_id.uuid.bytes,
        .schema_hash = scene.schema_hash,
        .asset_manifest_hash = scene.asset_manifest_hash,
        .entity_count = @intCast(counts.entities),
        .prefab_count = @intCast(counts.prefabs),
        .component_type_count = @intCast(counts.component_types),
        .component_count = @intCast(counts.components),
        .field_count = @intCast(counts.fields),
        .value_lane_count = @intCast(counts.value_lanes),
        .string_bytes = @intCast(counts.string_bytes),
        .name_len = @intCast(scene.name.len),
    };
    @memcpy(mutSection([16]u8, bytes, sections.entity_ids), entity_ids);
    @memcpy(mutSection(ComponentType, bytes, sections.component_types), types.items);
    const entities_out = mutSection(Entity, bytes, sections.entities);
    const prefabs_out = mutSection(Prefab, bytes, sections.prefabs);
    const components_out = mutSection(Component, bytes, sections.components);
    const fields_out = mutSection(Field, bytes, sections.fields);
    const values_out = mutSection(u32, bytes, sections.values);
    const strings_out = mutSection(u8, bytes, sections.strings);

    const sorted_components = try allocator.alloc(SortedComponent, max_components);
    defer allocator.free(sorted_components);
    const sorted_fields = try allocator.alloc(value.SceneField, max_fields);
    defer allocator.free(sorted_fields);

    var cursor: Cursor = .{};
    putString(strings_out, &cursor.string, scene.name);
    for (order, entities_out) |source_index, *entity_out| {
        const entity = &source[source_index];
        const flags = prefabFlags(entity.prefab);
        entity_out.* = .{
            .name_len = @intCast(entity.name.len),
            .parent = if (entity.parent_id) |parent| (findEntity(entity_ids, parent) orelse return error.MissingParentEntity) else none,
            .component_count = @intCast(entity.components.len),
            .prefab_flags = flags,
        };
        putString(strings_out, &cursor.string, entity.name);
        if (flags != 0) {
            const prefab = entity.prefab;
            prefabs_out[cursor.prefab] = .{
                .prefab_asset = if (flags & prefab_asset_bit != 0) prefab.prefab_asset.?.uuid.bytes else @splat(0),
                .override_set_id = if (flags & prefab_override_bit != 0) prefab.override_set_id.?.bytes else @splat(0),
                .source_entity = if (flags & prefab_source_bit != 0)
                    (findEntity(entity_ids, prefab.source_entity.?) orelse return error.MissingPrefabSourceEntity)
                else
                    none,
            };
            cursor.prefab += 1;
        }

        const components = sorted_components[0..entity.components.len];
        for (entity.components, components) |*component, *sorted| {
            sorted.* = .{ .type_index = findType(types.items, component), .component = component };
        }
        std.mem.sort(SortedComponent, components, {}, lessComponent);
        for (components, 0..) |sorted, i| {
            if (i > 0 and std.mem.eql(u8, &types.items[components[i - 1].type_index].id, &types.items[sorted.type_index].id))
                return error.DuplicateComponentTypeId;
            components_out[cursor.component] = .{
                .type_index = sorted.type_index,
                .field_count = @intCast(sorted.component.fields.len),
            };
            cursor.component += 1;

            const fields = sorted_fields[0..sorted.component.fields.len];
            @memcpy(fields, sorted.component.fields);
            std.mem.sort(value.SceneField, fields, {}, lessField);
            for (fields, 0..) |field, j| {
                if (j > 0 and fields[j - 1].number == field.number) return error.DuplicateFieldNumber;
                const kind = try kindOf(field.value);
                fields_out[cursor.field] = .{ .number = @intCast(field.number), .kind = @intFromEnum(kind) };
                cursor.field += 1;
                const lanes = values_out[cursor.lane..][0..kind.lanes()];
                cursor.lane += lanes.len;
                try encodeValue(field.value, lanes, entity_ids, strings_out, &cursor.string);
            }
        }
    }
    std.debug.assert(cursor.prefab == counts.prefabs and cursor.component == counts.components and
        cursor.field == counts.fields and cursor.lane == counts.value_lanes and cursor.string == counts.string_bytes);

    try checkTables(allocator, try tablesAt(bytes));
    return bytes;
}

const SortedComponent = struct {
    type_index: u16,
    component: *const document.SceneComponent,
};

fn mutSection(comptime T: type, bytes: []align(wire.section_alignment) u8, span: wire.Span) []T {
    const ptr: [*]T = @ptrCast(@alignCast(bytes.ptr + span.offset));
    return ptr[0 .. span.len / @sizeOf(T)];
}

fn putString(strings: []u8, cursor: *usize, text: []const u8) void {
    @memcpy(strings[cursor.*..][0..text.len], text);
    cursor.* += text.len;
}

fn kindOf(v: value.Value) !ValueKind {
    return switch (v) {
        .bool => .bool,
        .i32 => .i32,
        .u32 => .u32,
        .f32 => .f32,
        .string => .string,
        .vec2 => .vec2,
        .vec3 => .vec3,
        .quat => .quat,
        .asset_ref => .asset_ref,
        .entity_ref => .entity_ref,
        .none => error.InvalidValue,
    };
}

fn encodeValue(v: value.Value, lanes: []u32, entity_ids: []const [16]u8, strings: []u8, string_cursor: *usize) !void {
    switch (v) {
        .bool => |x| lanes[0] = @intFromBool(x),
        .i32 => |x| lanes[0] = @bitCast(x),
        .u32 => |x| lanes[0] = x,
        .f32 => |x| lanes[0] = @bitCast(x),
        .string => |x| {
            lanes[0] = @intCast(x.len);
            putString(strings, string_cursor, x);
        },
        .vec2 => |x| lanes[0..2].* = @bitCast(x),
        .vec3 => |x| lanes[0..3].* = @bitCast(x),
        .quat => |x| lanes[0..4].* = @bitCast(x),
        .asset_ref => |x| lanes[0..4].* = @bitCast(x.uuid.bytes),
        .entity_ref => |x| lanes[0] = if (x.isZero()) none else (findEntity(entity_ids, x) orelse return error.MissingEntityReference),
        .none => unreachable, // rejected while counting
    }
}

fn prefabFlags(prefab: document.PrefabInstanceMetadata) u8 {
    var flags: u8 = 0;
    if (prefab.prefab_asset) |v| {
        if (!v.isZero()) flags |= prefab_asset_bit;
    }
    if (prefab.source_entity) |v| {
        if (!v.isZero()) flags |= prefab_source_bit;
    }
    if (prefab.override_set_id) |v| {
        if (!v.isZero()) flags |= prefab_override_bit;
    }
    return flags;
}

/// Big-endian key, so integer order is byte order.
fn idKey(bytes: *const [16]u8) u128 {
    return std.mem.readInt(u128, bytes, .big);
}

fn allZero(bytes: []const u8) bool {
    return std.mem.allEqual(u8, bytes, 0);
}

fn orderTypes(a: ComponentType, b: ComponentType) std.math.Order {
    const by_id = std.math.order(idKey(&a.id), idKey(&b.id));
    return if (by_id == .eq) std.math.order(a.version, b.version) else by_id;
}

fn lessType(_: void, a: ComponentType, b: ComponentType) bool {
    return orderTypes(a, b) == .lt;
}

fn lessEntity(entities: []const document.SceneEntity, a: u32, b: u32) bool {
    return idKey(&entities[a].id.uuid.bytes) < idKey(&entities[b].id.uuid.bytes);
}

fn lessComponent(_: void, a: SortedComponent, b: SortedComponent) bool {
    return a.type_index < b.type_index;
}

fn lessField(_: void, a: value.SceneField, b: value.SceneField) bool {
    return a.number < b.number;
}

fn findEntity(entity_ids: []const [16]u8, target: id.SceneEntityId) ?u32 {
    const index = std.sort.binarySearch([16]u8, entity_ids, idKey(&target.uuid.bytes), struct {
        fn order(key: u128, item: [16]u8) std.math.Order {
            return std.math.order(key, idKey(&item));
        }
    }.order) orelse return null;
    return @intCast(index);
}

fn findType(types: []const ComponentType, component: *const document.SceneComponent) u16 {
    const key: ComponentType = .{ .id = component.type_id.uuid.bytes, .version = component.version };
    const index = std.sort.binarySearch(ComponentType, types, key, struct {
        fn order(k: ComponentType, item: ComponentType) std.math.Order {
            return orderTypes(k, item);
        }
    }.order).?; // every component's type was collected
    return @intCast(index);
}

const testing = std.testing;
const validate = @import("validate.zig");

const rich_scene_json =
    \\{"format":"fusion.scene","version":2,"scene_id":"8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a","project_id":"4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589","name":"Sandbox","schema_hash":42,"asset_manifest_hash":7,"entities":[
    \\{"id":"30000000-0000-4000-8000-000000000003","parent_id":"10000000-0000-4000-8000-000000000001","name":"Child","components":[
    \\  {"type_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","version":2,"fields":[
    \\    {"number":7,"value":{"kind":"entity_ref","value":"20000000-0000-4000-8000-000000000002"}},
    \\    {"number":3,"value":{"kind":"entity_ref","value":"00000000-0000-0000-0000-000000000000"}},
    \\    {"number":65535,"value":{"kind":"string","value":""}}]},
    \\  {"type_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","version":1,"fields":[
    \\    {"number":13,"value":{"kind":"bool","value":false}},
    \\    {"number":1,"value":{"kind":"bool","value":true}},
    \\    {"number":2,"value":{"kind":"i32","value":-5}},
    \\    {"number":4,"value":{"kind":"u32","value":4000000000}},
    \\    {"number":5,"value":{"kind":"f32","value":0.25}},
    \\    {"number":6,"value":{"kind":"string","value":"hello"}},
    \\    {"number":8,"value":{"kind":"vec2","value":[1,2]}},
    \\    {"number":9,"value":{"kind":"vec3","value":[1,2,3]}},
    \\    {"number":10,"value":{"kind":"quat","value":[0,0,0,1]}},
    \\    {"number":11,"value":{"kind":"asset_ref","value":"fb88e345-df93-86d4-b883-85d897f4c22b"}},
    \\    {"number":12,"value":{"kind":"asset_ref","value":"00000000-0000-0000-0000-000000000000"}}]}],
    \\ "prefab":{"prefab_asset":"fb88e345-df93-86d4-b883-85d897f4c22b","source_entity":"20000000-0000-4000-8000-000000000002","override_set_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}},
    \\{"id":"10000000-0000-4000-8000-000000000001","name":"Root","components":[
    \\  {"type_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","version":1,"fields":[]},
    \\  {"type_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","version":1,"fields":[{"number":1,"value":{"kind":"string","value":"root tag"}}]}]},
    \\{"id":"20000000-0000-4000-8000-000000000002","parent_id":"10000000-0000-4000-8000-000000000001","name":"","components":[],
    \\ "prefab":{"prefab_asset":"fb88e345-df93-86d4-b883-85d897f4c22b"}},
    \\{"id":"40000000-0000-4000-8000-000000000004","name":"Source","components":[],"prefab":{"source_entity":"10000000-0000-4000-8000-000000000001"}},
    \\{"id":"50000000-0000-4000-8000-000000000005","parent_id":"30000000-0000-4000-8000-000000000003","name":"Override","components":[
    \\  {"type_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","version":3,"fields":[]}],
    \\ "prefab":{"override_set_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}}]}
;

/// Indices of the rich scene's entities in id order.
const rich_root = 0;
const rich_child = 2;

fn encodeJson(input: []const u8) ![]align(wire.section_alignment) u8 {
    var scene = try json_codec.decode(testing.allocator, input);
    defer scene.deinit();
    return encodeAlloc(testing.allocator, &scene);
}

fn expectSameJson(a: *const document.SceneDocument, b: *const document.SceneDocument) !void {
    const a_json = try json_codec.encodeAlloc(testing.allocator, a);
    defer testing.allocator.free(a_json);
    const b_json = try json_codec.encodeAlloc(testing.allocator, b);
    defer testing.allocator.free(b_json);
    try testing.expectEqualStrings(a_json, b_json);
}

/// If `decode` accepts `bytes`, the document must be valid and re-encode to
/// exactly `bytes`. (Mutations of the small test scenes can't exceed the
/// default size limits.)
fn expectCanonical(bytes: wire.Bytes) !void {
    var scene = decode(testing.allocator, bytes) catch return;
    defer scene.deinit();
    try validate.validate(&scene, testing.allocator, .{});
    const again = try encodeAlloc(testing.allocator, &scene);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}

/// Mutable views of an encoded file, for patching in tests.
const TestTables = struct {
    header: *Header,
    entity_ids: [][16]u8,
    entities: []Entity,
    prefabs: []Prefab,
    component_types: []ComponentType,
    components: []Component,
    fields: []Field,
    values: []u32,
    strings: []u8,

    fn of(bytes: []align(wire.section_alignment) u8) !TestTables {
        const t = try tablesAt(bytes);
        return .{
            .header = @constCast(t.header),
            .entity_ids = @constCast(t.entity_ids),
            .entities = @constCast(t.entities),
            .prefabs = @constCast(t.prefabs),
            .component_types = @constCast(t.component_types),
            .components = @constCast(t.components),
            .fields = @constCast(t.fields),
            .values = @constCast(t.values),
            .strings = @constCast(t.strings),
        };
    }
};

test "a scene round-trips through the binary format" {
    var source = try json_codec.decode(testing.allocator, rich_scene_json);
    defer source.deinit();
    const bytes = try encodeAlloc(testing.allocator, &source);
    defer testing.allocator.free(bytes);
    var decoded = try decode(testing.allocator, bytes);
    defer decoded.deinit();

    try expectSameJson(&source, &decoded);
    try validate.validate(&decoded, testing.allocator, .{});
    try testing.expectEqual(@as(u64, 42), decoded.schema_hash);
    try testing.expectEqual(@as(u64, 7), decoded.asset_manifest_hash);

    const t = try tablesAt(bytes);
    try testing.expectEqual(@as(usize, 5), t.entities.len);
    try testing.expectEqual(@as(usize, 4), t.prefabs.len);
    // (aaaa, 1), (aaaa, 3), (bbbb, 2), (dddd, 1)
    try testing.expectEqual(@as(usize, 4), t.component_types.len);
    try testing.expectEqual(@as(u32, rich_root), t.entities[rich_child].parent);
}

test "empty scenes and empty names round-trip" {
    const input =
        \\{"format":"fusion.scene","version":2,"scene_id":"8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a","project_id":"4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589","name":"","entities":[]}
    ;
    var source = try json_codec.decode(testing.allocator, input);
    defer source.deinit();
    const bytes = try encodeAlloc(testing.allocator, &source);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, @sizeOf(Header)), bytes.len);
    var decoded = try decode(testing.allocator, bytes);
    defer decoded.deinit();
    try expectSameJson(&source, &decoded);
}

test "encoding does not depend on entity, component, or field order" {
    var source = try json_codec.decode(testing.allocator, rich_scene_json);
    defer source.deinit();
    const bytes = try encodeAlloc(testing.allocator, &source);
    defer testing.allocator.free(bytes);

    std.mem.reverse(document.SceneEntity, source.entities);
    for (source.entities) |entity| {
        std.mem.reverse(document.SceneComponent, entity.components);
        for (entity.components) |component| std.mem.reverse(value.SceneField, component.fields);
    }
    const shuffled = try encodeAlloc(testing.allocator, &source);
    defer testing.allocator.free(shuffled);
    try testing.expectEqualSlices(u8, bytes, shuffled);
}

test "every truncation is rejected" {
    const bytes = try encodeJson(rich_scene_json);
    defer testing.allocator.free(bytes);
    for (0..bytes.len) |len| {
        if (decode(testing.allocator, bytes[0..len])) |scene| {
            var s = scene;
            s.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "any single-byte corruption is rejected or re-encodes to the same bytes" {
    const bytes = try encodeJson(rich_scene_json);
    defer testing.allocator.free(bytes);
    const copy = try testing.allocator.alignedAlloc(u8, wire.alignment, bytes.len);
    defer testing.allocator.free(copy);
    for (0..bytes.len) |i| {
        for ([_]u8{ 0x01, 0x80, 0xff }) |mask| {
            @memcpy(copy, bytes);
            copy[i] ^= mask;
            try expectCanonical(copy);
        }
    }
}

test "decode rejects hostile tables" {
    const bytes = try encodeJson(rich_scene_json);
    defer testing.allocator.free(bytes);
    const copy = try testing.allocator.alignedAlloc(u8, wire.alignment, bytes.len);
    defer testing.allocator.free(copy);

    const Case = struct {
        expected: anyerror,
        patch: *const fn (TestTables) void,
    };
    const cases = [_]Case{
        .{ .expected = error.EntityParentCycle, .patch = struct {
            fn f(t: TestTables) void {
                t.entities[rich_root].parent = rich_child;
            }
        }.f },
        .{ .expected = error.SelfParent, .patch = struct {
            fn f(t: TestTables) void {
                t.entities[rich_root].parent = rich_root;
            }
        }.f },
        .{ .expected = error.InvalidEntityIndex, .patch = struct {
            fn f(t: TestTables) void {
                t.entities[rich_root].parent = 5;
            }
        }.f },
        .{ .expected = error.UnsortedEntityIds, .patch = struct {
            fn f(t: TestTables) void {
                std.mem.swap([16]u8, &t.entity_ids[0], &t.entity_ids[1]);
            }
        }.f },
        .{ .expected = error.UnsortedEntityIds, .patch = struct {
            fn f(t: TestTables) void {
                t.entity_ids[1] = t.entity_ids[0];
            }
        }.f },
        .{ .expected = error.ZeroEntityId, .patch = struct {
            fn f(t: TestTables) void {
                t.entity_ids[0] = @splat(0);
            }
        }.f },
        .{ .expected = error.UnsortedComponentTypes, .patch = struct {
            fn f(t: TestTables) void {
                std.mem.swap(ComponentType, &t.component_types[0], &t.component_types[2]);
            }
        }.f },
        .{ .expected = error.ZeroComponentVersion, .patch = struct {
            fn f(t: TestTables) void {
                t.component_types[0].version = 0;
            }
        }.f },
        // Root's components are (aaaa, 1) = 0 and (dddd, 1) = 3; index 1 is (aaaa, 3).
        .{ .expected = error.DuplicateComponentTypeId, .patch = struct {
            fn f(t: TestTables) void {
                t.components[1].type_index = 1;
            }
        }.f },
        .{ .expected = error.UnsortedComponents, .patch = struct {
            fn f(t: TestTables) void {
                t.components[1].type_index = 0;
            }
        }.f },
        .{ .expected = error.InvalidComponentType, .patch = struct {
            fn f(t: TestTables) void {
                t.components[1].type_index = 4;
            }
        }.f },
        .{ .expected = error.UnusedComponentType, .patch = struct {
            fn f(t: TestTables) void {
                // Point Override's (aaaa, 3) at (aaaa, 1).
                t.components[t.components.len - 1].type_index = 0;
            }
        }.f },
        .{ .expected = error.UnsortedFieldNumbers, .patch = struct {
            fn f(t: TestTables) void {
                t.fields[0].number = 0;
            }
        }.f },
        .{ .expected = error.UnsortedFieldNumbers, .patch = struct {
            fn f(t: TestTables) void {
                t.fields[2].number = t.fields[1].number;
            }
        }.f },
        .{ .expected = error.InvalidPrefab, .patch = struct {
            fn f(t: TestTables) void {
                t.entities[rich_child].prefab_flags &= ~prefab_asset_bit;
            }
        }.f },
        .{ .expected = error.InvalidPrefab, .patch = struct {
            fn f(t: TestTables) void {
                t.entities[rich_child].prefab_flags |= 0x8;
            }
        }.f },
        // Root takes the next entity's prefab record, leaving that entity
        // with Child's.
        .{ .expected = error.InvalidPrefab, .patch = struct {
            fn f(t: TestTables) void {
                t.entities[rich_root].prefab_flags = prefab_asset_bit;
            }
        }.f },
        .{ .expected = error.InvalidLayout, .patch = struct {
            fn f(t: TestTables) void {
                t.entities[4].prefab_flags = 0;
            }
        }.f },
        .{ .expected = error.InvalidStringLength, .patch = struct {
            fn f(t: TestTables) void {
                t.entities[0].name_len = 1000;
            }
        }.f },
        .{ .expected = error.InvalidReserved, .patch = struct {
            fn f(t: TestTables) void {
                t.entities[0]._reserved = 1;
            }
        }.f },
        .{ .expected = error.InvalidReserved, .patch = struct {
            fn f(t: TestTables) void {
                t.fields[0]._reserved = 1;
            }
        }.f },
        .{ .expected = error.InvalidEnumValue, .patch = struct {
            fn f(t: TestTables) void {
                t.fields[0].kind = 10;
            }
        }.f },
        .{ .expected = error.InvalidLayout, .patch = struct {
            fn f(t: TestTables) void {
                t.fields[t.fields.len - 1].kind = @intFromEnum(ValueKind.quat);
            }
        }.f },
        .{ .expected = error.InvalidLayout, .patch = struct {
            fn f(t: TestTables) void {
                t.header.entity_count -= 1;
            }
        }.f },
        .{ .expected = error.InvalidScene, .patch = struct {
            fn f(t: TestTables) void {
                t.header.project_id = @splat(0);
            }
        }.f },
    };
    for (cases) |case| {
        @memcpy(copy, bytes);
        case.patch(try TestTables.of(copy));
        try testing.expectError(case.expected, decode(testing.allocator, copy));
    }
}

test "decode checks each value lane" {
    const input =
        \\{"format":"fusion.scene","version":2,"scene_id":"8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a","project_id":"4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589","name":"S","entities":[
        \\{"id":"10000000-0000-4000-8000-000000000001","name":"A","components":[{"type_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","version":1,"fields":[
        \\  {"number":1,"value":{"kind":"bool","value":true}},
        \\  {"number":2,"value":{"kind":"entity_ref","value":"10000000-0000-4000-8000-000000000001"}},
        \\  {"number":3,"value":{"kind":"string","value":"abc"}}]}]}]}
    ;
    const bytes = try encodeJson(input);
    defer testing.allocator.free(bytes);
    const t = try TestTables.of(bytes);

    t.values[0] = 2;
    try testing.expectError(error.InvalidValue, decode(testing.allocator, bytes));
    t.values[0] = 1;
    t.values[1] = 1;
    try testing.expectError(error.InvalidEntityIndex, decode(testing.allocator, bytes));
    t.values[1] = none;
    t.values[2] = 4;
    try testing.expectError(error.InvalidStringLength, decode(testing.allocator, bytes));
    t.values[2] = 2;
    try testing.expectError(error.InvalidLayout, decode(testing.allocator, bytes));
    t.values[2] = 3;

    var scene = try decode(testing.allocator, bytes);
    defer scene.deinit();
    try testing.expect(scene.entities[0].components[0].fields[1].value.entity_ref.isZero());
}

test "decode rejects non-zero padding" {
    const bytes = try encodeJson(rich_scene_json);
    defer testing.allocator.free(bytes);
    const t = try tablesAt(bytes);
    // The entity table (5 × 12 B) ends mid-block, before the prefab section.
    const padding = @intFromPtr(t.entities.ptr + t.entities.len) - @intFromPtr(bytes.ptr);
    try testing.expect(padding % wire.section_alignment != 0);
    bytes[padding] = 1;
    try testing.expectError(error.InvalidPadding, decode(testing.allocator, bytes));
}

test "hostile counts fail before any allocation" {
    const bytes = try encodeJson(rich_scene_json);
    defer testing.allocator.free(bytes);
    const t = try TestTables.of(bytes);
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    t.header.entity_count = std.math.maxInt(u32);
    try testing.expectError(error.AssetTooLarge, decode(failing.allocator(), bytes));
    t.header.entity_count = 5;
    t.header.component_type_count = max_component_types + 1;
    try testing.expectError(error.TooManyComponentTypes, decode(failing.allocator(), bytes));
    t.header.component_type_count = 4;
    t.header.name_len = t.header.string_bytes + 1;
    try testing.expectError(error.InvalidStringLength, decode(failing.allocator(), bytes));
}

test "a deep parent chain decodes without recursion" {
    const count = 100_000;
    var scene = try document.SceneDocument.init(
        testing.allocator,
        .parseComptime("8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a"),
        .parseComptime("4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589"),
        "Chain",
    );
    defer scene.deinit();
    const storage = scene.arena.allocator();
    scene.entities = try storage.alloc(document.SceneEntity, count);
    for (scene.entities, 0..) |*entity, i| {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &bytes, i + 1, .big);
        entity.* = .{ .id = .fromBytes(bytes), .name = "", .components = &.{}, .prefab = .{} };
        if (i > 0) entity.parent_id = scene.entities[i - 1].id;
    }

    const encoded = try encodeAlloc(testing.allocator, &scene);
    defer testing.allocator.free(encoded);
    var decoded = try decode(testing.allocator, encoded);
    defer decoded.deinit();
    try testing.expect(decoded.entities[count - 1].parent_id.?.eql(scene.entities[count - 2].id));

    // Closing the chain into a loop is caught by the writer's shared checks.
    scene.entities[0].parent_id = scene.entities[count - 1].id;
    try testing.expectError(error.EntityParentCycle, encodeAlloc(testing.allocator, &scene));
}

test "encodeAlloc rejects documents it cannot represent" {
    const entity_a = id.SceneEntityId.parseComptime("10000000-0000-4000-8000-000000000001");
    const entity_b = id.SceneEntityId.parseComptime("20000000-0000-4000-8000-000000000002");
    const missing = id.SceneEntityId.parseComptime("30000000-0000-4000-8000-000000000003");
    const type_a = id.ComponentTypeId.parseComptime("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");

    var scene = try document.SceneDocument.init(
        testing.allocator,
        .parseComptime("8a6ab21b-319a-4fd7-85cb-4bf563a0ff9a"),
        .parseComptime("4e6e1f6a-9cc0-4f58-b6e5-3b91c1d91589"),
        "Scene",
    );
    defer scene.deinit();
    const storage = scene.arena.allocator();
    const fields = try storage.dupe(value.SceneField, &.{
        .{ .number = 1, .value = .{ .bool = true } },
        .{ .number = 2, .value = .{ .entity_ref = entity_b } },
    });
    const components = try storage.dupe(document.SceneComponent, &.{
        .{ .type_id = type_a, .fields = fields },
        .{ .type_id = .parseComptime("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"), .fields = &.{} },
    });
    scene.entities = try storage.dupe(document.SceneEntity, &.{
        .{ .id = entity_a, .name = "A", .components = components, .prefab = .{} },
        .{ .id = entity_b, .parent_id = entity_a, .name = "B", .components = &.{}, .prefab = .{} },
    });
    const ok = try encodeAlloc(testing.allocator, &scene);
    testing.allocator.free(ok);

    const Expect = struct {
        fn err(expected: anyerror, s: *const document.SceneDocument) !void {
            try testing.expectError(expected, encodeAlloc(testing.allocator, s));
        }
    };

    scene.entities[1].id = entity_a;
    try Expect.err(error.DuplicateEntityId, &scene);
    scene.entities[1].id = .zero;
    try Expect.err(error.ZeroEntityId, &scene);
    scene.entities[1].id = entity_b;

    scene.entities[1].parent_id = missing;
    try Expect.err(error.MissingParentEntity, &scene);
    scene.entities[1].parent_id = entity_b;
    try Expect.err(error.SelfParent, &scene);
    scene.entities[1].parent_id = entity_a;
    scene.entities[0].parent_id = entity_b;
    try Expect.err(error.EntityParentCycle, &scene);
    scene.entities[0].parent_id = null;

    scene.entities[1].prefab.source_entity = missing;
    try Expect.err(error.MissingPrefabSourceEntity, &scene);
    scene.entities[1].prefab.source_entity = null;

    fields[1].value = .{ .entity_ref = missing };
    try Expect.err(error.MissingEntityReference, &scene);
    fields[1].value = .{ .none = {} };
    try Expect.err(error.InvalidValue, &scene);
    fields[1].value = .{ .u32 = 1 };

    fields[1].number = 0;
    try Expect.err(error.InvalidFieldNumber, &scene);
    fields[1].number = max_field_number + 1;
    try Expect.err(error.InvalidFieldNumber, &scene);
    fields[1].number = 1;
    try Expect.err(error.DuplicateFieldNumber, &scene);
    fields[1].number = 2;

    components[1].type_id = type_a;
    components[1].version = 2;
    try Expect.err(error.DuplicateComponentTypeId, &scene);
    components[1].type_id = .zero;
    try Expect.err(error.ZeroComponentTypeId, &scene);
    components[1].type_id = .parseComptime("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    components[1].version = 0;
    try Expect.err(error.ZeroComponentVersion, &scene);
    components[1].version = 1;

    scene.version = 999;
    try Expect.err(error.InvalidSceneFormat, &scene);
    scene.version = json_codec.scene_version;
    const format = scene.format;
    scene.format = "fusion.prefab";
    try Expect.err(error.InvalidSceneFormat, &scene);
    scene.format = format;

    scene.project_id = .zero;
    try Expect.err(error.InvalidScene, &scene);
}

test "zero prefab ids are stored as absent" {
    var scene = try json_codec.decode(testing.allocator, rich_scene_json);
    defer scene.deinit();
    for (scene.entities) |*entity| {
        if (entity.prefab.prefab_asset != null) entity.prefab.prefab_asset = .zero;
    }
    const bytes = try encodeAlloc(testing.allocator, &scene);
    defer testing.allocator.free(bytes);
    var decoded = try decode(testing.allocator, bytes);
    defer decoded.deinit();
    for (decoded.entities) |entity| try testing.expectEqual(@as(?id.AssetId, null), entity.prefab.prefab_asset);
}
