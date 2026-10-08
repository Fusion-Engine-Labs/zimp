const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const CookInput = @import("cooker.zig").CookInput;
const zmesh = @import("../formats/zmesh.zig");
const ObjParser = @import("../parsers/obj/obj_parser.zig").ObjParser;
const CookedMesh = @import("../assets/cooked/mesh.zig").CookedMesh;
const material_generator = @import("../parsers/gltf/material_generator.zig");

pub fn cooker() Cooker {
    return .{ .cook_fn = cookObj };
}

fn cookObj(input: *const CookInput) !void {
    var parser = ObjParser{ .allocator = input.allocator, .file_bytes = input.bytes };
    defer parser.deinit();

    var raw_mesh = try parser.parse(input.allocator);
    defer input.allocator.free(raw_mesh.vertices);
    defer input.allocator.free(raw_mesh.indices);
    defer input.allocator.free(raw_mesh.submeshes);

    var cooked_mesh = try CookedMesh.cook(input.allocator, &raw_mesh);
    defer cooked_mesh.deinit(input.allocator);

    const parts = [_]zmesh.ZMesh.CookPart{.{
        .mesh = cooked_mesh,
        .transform = zmesh.identity_transform,
    }};
    const material_path = try material_generator.resolveDefaultMaterialPath(input.allocator, input.io, input.source_dir, input.source.path);
    defer input.allocator.free(material_path);

    const material_ids = [_]zmesh.AssetId{try input.referenceId(material_path)};
    try zmesh.ZMesh.write(input.writer, &material_ids, &parts);
}
