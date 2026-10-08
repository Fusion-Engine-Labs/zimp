const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const CookInput = @import("cooker.zig").CookInput;
const ZMesh = @import("../formats/zmesh.zig").ZMesh;
const GltfDocument = @import("../parsers/gltf/document.zig").GltfDocument;
const CookedModel = @import("../parsers/gltf/model.zig").CookedModel;
const material_generator = @import("../parsers/gltf/material_generator.zig");

pub fn cooker() Cooker {
    return .{ .cook_fn = cookGltf };
}

fn cookGltf(input: *const CookInput) !void {
    var document = try GltfDocument.loadGltfFromBytes(
        input.allocator,
        input.io,
        input.source_dir,
        input.source.path,
        input.bytes,
    );
    defer document.deinit();

    var model = try CookedModel.build(input.allocator, &document.gltf.value, document.buffers);
    defer model.deinit();

    const material_paths = try material_generator.resolveMaterialPaths(input.allocator, input.io, input.source_dir, input.source.path, &document.gltf.value);
    defer material_generator.freeMaterialPaths(input.allocator, material_paths);
    const material_ids = try input.referenceIds(material_paths);
    defer input.allocator.free(material_ids);

    try ZMesh.write(input.writer, material_ids, model.parts);
}
