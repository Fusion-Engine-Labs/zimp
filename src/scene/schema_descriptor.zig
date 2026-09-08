const std = @import("std");
const schema_mod = @import("schema.zig");
const ComponentSchema = schema_mod.ComponentSchema;

pub const SchemaDescriptor = struct {
    format: []const u8 = "fusion.schema",
    version: u32 = 1,
    schema_hash: u64,
    components: []const ComponentSchema,
};

/// `schemas` must already be sorted by component id bytes (the registry
/// guarantees this) so the hash is order-independent.
pub fn schemaHash(schemas: []const ComponentSchema) u64 {
    var h = std.hash.Wyhash.init(0x7e9f_a4c2_5eed_0001);
    for (schemas) |s| {
        h.update(&s.id.uuid.bytes);
        h.update(std.mem.asBytes(&s.version));
        for (s.fields) |f| {
            h.update(std.mem.asBytes(&f.number));
            h.update(@tagName(f.kind));
            switch (f.kind) {
                .asset_ref => |kind| h.update(std.mem.asBytes(&@intFromEnum(kind))),
                .enum_ref => |es| for (es.entries) |e| {
                    h.update(e.name);
                    h.update(std.mem.asBytes(&e.value));
                },
                else => {},
            }
        }
    }
    return h.final();
}
