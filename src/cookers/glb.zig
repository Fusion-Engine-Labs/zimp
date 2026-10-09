const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const CookInput = @import("cooker.zig").CookInput;
const ZMesh = @import("../formats/zmesh.zig").ZMesh;
const GLBFile = @import("../parsers/gltf/glb_parser.zig").GLBFile;
const Gltf = @import("../parsers/gltf/gltf_json_parser.zig").Gltf;
const CookedModel = @import("../parsers/gltf/model.zig").CookedModel;
const material_generator = @import("../parsers/gltf/material_generator.zig");

pub fn cooker() Cooker {
    return .{ .cook_fn = cookGlb };
}

fn cookGlb(input: *const CookInput) !void {
    const glb_file = try GLBFile.parse(input.allocator, input.bytes);
    defer input.allocator.destroy(glb_file);

    var gltf = try Gltf.parse(glb_file.json, input.allocator);
    defer gltf.deinit();

    const buffers = [_][]const u8{glb_file.bin};
    var model = try CookedModel.build(input.allocator, &gltf.value, &buffers);
    defer model.deinit();

    const material_paths = try material_generator.resolveMaterialPaths(input.allocator, input.io, input.source_dir, input.source.path, &gltf.value);
    defer material_generator.freeMaterialPaths(input.allocator, material_paths);
    const material_ids = try input.referenceIds(material_paths);
    defer input.allocator.free(material_ids);

    try ZMesh.write(input.allocator, input.writer, material_ids, model.parts, .{});
}
