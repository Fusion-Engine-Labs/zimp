const std = @import("std");

pub fn addProjectCookStep(b: *std.Build, dep: *std.Build.Dependency, project_root: std.Build.LazyPath) *std.Build.Step.Run {
    const exe = dep.artifact("zimp");
    const run = b.addRunArtifact(exe);
    run.addArg("cook");
    run.addArg("--project");
    run.addDirectoryArg(project_root);
    return run;
}

pub const formats = struct {
    pub const zmesh = @import("formats/zmesh.zig");
    pub const ztex = @import("formats/ztex.zig");
    pub const zshdr = @import("formats/zshdr.zig");
    pub const zamat = @import("formats/zamat.zig");
};

pub const WatchHandle = @import("watcher/handle.zig");

pub const assets = struct {
    pub const asset = @import("assets/asset.zig");

    pub const raw = struct {
        pub const mesh = @import("assets/raw/mesh.zig");
        pub const texture = @import("assets/raw/texture.zig");
        pub const shader = @import("assets/raw/shader.zig");
        pub const material = @import("assets/raw/material.zig");
    };

    pub const cooked = struct {
        pub const mesh = @import("assets/cooked/mesh.zig");
        pub const texture = @import("assets/cooked/texture.zig");
        pub const shader = @import("assets/cooked/shader.zig");
        pub const material = @import("assets/cooked/material.zig");
    };
};

pub const builtin = struct {
    const registry = @import("builtin/registry.zig");
    pub const error_meterial_id = registry.error_material_id;
};

pub const runtime = @import("runtime.zig");
pub const path = @import("path.zig");

pub const id = struct {
    pub const uuid = @import("id/uuid.zig");
    pub const types = @import("id/id_types.zig");
};

pub const project = struct {
    pub const manifest = @import("project/manifest.zig");
    pub const root = @import("project/project_root.zig");
};

pub const ProjectManifest = project.manifest.ProjectManifest;
pub const ProjectRoot = project.root.ProjectRoot;

pub const manifest = struct {
    pub const derive = @import("manifest/derive.zig");
    pub const model = @import("manifest/model.zig");
    pub const codec = @import("manifest/codec.zig");
};
pub const AssetKind = assets.asset.AssetKind;
pub const AssetManifest = manifest.model.AssetManifest;
pub const AssetManifestEntry = manifest.model.AssetManifestEntry;

pub const scene = struct {
    pub const document = @import("scene/document.zig");
    pub const json_codec = @import("scene/json_codec.zig");
    pub const binary_codec = @import("scene/binary_codec.zig");
    pub const schema = @import("scene/schema.zig");
    pub const value = @import("scene/value.zig");
    pub const descriptor = @import("scene/schema_descriptor.zig");
    pub const validate = @import("scene/validate.zig");

    pub const FieldKind = schema.FieldKind;
    pub const ComponentSchema = schema.ComponentSchema;
    pub const FieldSchema = schema.FieldSchema;
    pub const SchemaMeta = schema.SchemaMeta;
    pub const FieldMeta = schema.FieldMeta;
    pub const EditorFieldHints = schema.EditorFieldHints;
    pub const validateSchema = schema.validateSchema;
    pub const Value = value.Value;
    pub const SceneField = value.SceneField;
    pub const SceneComponentData = value.SceneComponentData;
    pub const SceneDocument = document.SceneDocument;
    pub const SceneEntity = document.SceneEntity;
    pub const SceneComponent = document.SceneComponent;
};

pub const Uuid = id.uuid.Uuid;
pub const ProjectId = id.types.ProjectId;
pub const AssetId = id.types.AssetId;
pub const SceneId = id.types.SceneId;
pub const SceneEntityId = id.types.SceneEntityId;
pub const ComponentTypeId = id.types.ComponentTypeId;
pub const SchemaId = id.types.SchemaId;

pub const ZMesh = formats.zmesh.ZMesh;
pub const ZMeshHeader = formats.zmesh.Header;
pub const MeshPart = formats.zmesh.MeshPart;
pub const FormatFlags = assets.cooked.mesh.FormatFlags;
pub const CookedVertex = assets.cooked.mesh.CookedVertex;
pub const AABB = assets.cooked.mesh.AABB;
pub const IndexFormat = assets.cooked.mesh.IndexFormat;
pub const IndexBuffer = assets.cooked.mesh.IndexBuffer;
pub const CookedMesh = assets.cooked.mesh.CookedMesh;
pub const Zatex = formats.ztex.Zatex;
pub const ZatexHeader = formats.ztex.Header;
pub const TextureType = formats.ztex.TextureType;
pub const TexelFormat = assets.cooked.texture.TexelFormat;
pub const ColorSpace = assets.raw.texture.ColorSpace;
pub const TextureClass = assets.raw.texture.TextureClass;
pub const CookedMip = assets.cooked.texture.CookedMip;
pub const CookedTexture = assets.cooked.texture.CookedTexture;
pub const ZShader = formats.zshdr.ZShader;
pub const ShaderStage = formats.zshdr.ShaderStage;
pub const VariantKey = formats.zshdr.VariantKey;
pub const CookedShader = assets.cooked.shader.CookedShader;
pub const Zamat = formats.zamat.Zamat;
pub const ZamatHeader = formats.zamat.Header;
pub const AlphaMode = assets.cooked.material.AlphaMode;
pub const CullMode = assets.cooked.material.CullMode;
pub const BlendMode = assets.cooked.material.BlendMode;
pub const FilterMode = assets.cooked.material.FilterMode;
pub const MipFilterMode = assets.cooked.material.MipFilterMode;
pub const WrapMode = assets.cooked.material.WrapMode;
pub const SamplerDesc = assets.cooked.material.SamplerDesc;
pub const RenderState = assets.cooked.material.RenderState;
pub const TextureSlotIndex = assets.cooked.material.TextureSlotIndex;
pub const slotNameToIndex = assets.cooked.material.slotNameToIndex;
pub const TextureSlotEntry = assets.cooked.material.TextureSlotEntry;
pub const ParamType = assets.cooked.material.ParamType;
pub const ParamEntry = assets.cooked.material.ParamEntry;
pub const ParamBuildResult = assets.cooked.material.ParamBuildResult;
pub const CookedMaterial = assets.cooked.material.CookedMaterial;
pub const MaterialSource = assets.raw.material.MaterialSource;
pub const TextureSlot = assets.raw.material.TextureSlot;
pub const ParamValue = assets.raw.material.ParamValue;
pub const parseMaterialSource = assets.raw.material.parseMaterialSource;
pub const parseAlphaMode = assets.raw.material.parseAlphaMode;
pub const mesh = assets.cooked.mesh;
pub const material = assets.cooked.material;

const asset = @import("assets/asset.zig");
pub const Extension = asset.Extension;

test "public API exposes format and asset construction types" {
    _ = formats.zmesh.ZMesh;
    _ = formats.ztex.Zatex;
    _ = formats.zshdr.ZShader;
    _ = formats.zamat.Zamat;

    _ = assets.raw.mesh.RawMesh;
    _ = assets.raw.texture.RawTexture;
    _ = assets.raw.shader.RawShader;
    _ = assets.raw.material.MaterialSource;

    _ = CookedMesh;
    _ = CookedTexture;
    _ = CookedShader;
    _ = CookedMaterial;
    _ = AlphaMode;
    _ = CullMode;
    _ = BlendMode;
    _ = FilterMode;
    _ = MipFilterMode;
    _ = WrapMode;
    _ = SamplerDesc;
    _ = RenderState;
    _ = TextureSlotIndex;
    _ = slotNameToIndex;
    _ = TextureSlotEntry;
    _ = ParamType;
    _ = ParamEntry;
    _ = ParamBuildResult;
    _ = MaterialSource;
    _ = TextureSlot;
    _ = ParamValue;
    _ = parseMaterialSource;
    _ = parseAlphaMode;
    _ = scene.schema;
    _ = scene.value;
    _ = scene.descriptor;
    _ = scene.FieldKind;
    _ = scene.ComponentSchema;
    _ = scene.FieldSchema;
    _ = scene.SchemaMeta;
    _ = scene.FieldMeta;
    _ = scene.EditorFieldHints;
    _ = scene.validateSchema;
    _ = scene.Value;
    _ = scene.SceneField;
    _ = scene.SceneComponentData;
    _ = path.normalizeVirtual;
    _ = path.resolveShaderInclude;
    _ = path.cookedOutput;
    _ = WatchHandle;
}

test {
    _ = @import("assets/asset.zig");
    _ = @import("assets/asset_registry.zig");
    _ = @import("assets/asset_scanner.zig");
    _ = @import("assets/dependency_graph.zig");
    _ = @import("assets/source_file.zig");
    _ = @import("assets/raw/mesh.zig");
    _ = @import("assets/raw/texture.zig");
    _ = @import("assets/raw/shader.zig");
    _ = @import("assets/raw/material.zig");
    _ = @import("assets/cooked/mesh.zig");
    _ = @import("assets/cooked/texture.zig");
    _ = @import("assets/cooked/shader.zig");
    _ = @import("assets/cooked/material.zig");
    _ = @import("formats/zshdr.zig");
    _ = @import("formats/zamat.zig");
    _ = @import("assets/cooked/compression/compression.zig");
    _ = @import("assets/cooked/compression/bc4.zig");
    _ = @import("assets/cooked/compression/bc5.zig");
    _ = @import("assets/cooked/compression/bc7.zig");
    _ = @import("assets/cooked/compression/bc6h.zig");
    _ = @import("commands/command.zig");
    _ = @import("commands/cook_metrics.zig");
    _ = @import("parsers/gltf/glb_parser.zig");
    _ = @import("parsers/gltf/gltf_json_parser.zig");
    _ = @import("parsers/gltf/document.zig");
    _ = @import("parsers/gltf/mesh.zig");
    _ = @import("parsers/gltf/model.zig");
    _ = @import("parsers/gltf/material_generator.zig");
    _ = @import("cookers/cooker.zig");
    _ = @import("cookers/glb.zig");
    _ = @import("cookers/gltf.zig");
    _ = @import("cookers/obj.zig");
    _ = @import("cookers/shader.zig");
    _ = @import("cookers/material.zig");
    _ = @import("extractors/extractor.zig");
    _ = @import("extractors/mesh.zig");
    _ = @import("extractors/shader.zig");
    _ = @import("extractors/material.zig");
    _ = @import("parsers/obj/obj_parser.zig");
    _ = @import("inspectors/inspect.zig");
    _ = @import("inspectors/zmesh.zig");
    _ = @import("inspectors/zshdr.zig");
    _ = @import("inspectors/zamat.zig");
    _ = @import("inspectors/zcache.zig");
    _ = @import("inspectors/utils.zig");
    _ = @import("cache/cache.zig");
    _ = @import("cache/cache_dep_graph.zig");
    _ = @import("cache/entry.zig");
    _ = @import("shared/file_read.zig");
    _ = @import("runtime.zig");
    _ = @import("path.zig");
    _ = @import("id/uuid.zig");
    _ = @import("id/id_types.zig");
    _ = @import("project/manifest.zig");
    _ = @import("project/project_root.zig");
    _ = @import("shared/atomic_file.zig");
    _ = @import("shared/wire.zig");
    _ = @import("shared/string_list.zig");
    _ = @import("manifest/derive.zig");
    _ = @import("manifest/model.zig");
    _ = @import("manifest/codec.zig");
    _ = @import("manifest/builder.zig");
    _ = @import("watcher/handle.zig");
    _ = @import("watcher/snapshot.zig");
    _ = @import("watcher/wake.zig");
    _ = @import("watcher/watcher.zig");
    _ = @import("scene/schema.zig");
    _ = @import("scene/value.zig");
    _ = @import("scene/schema_descriptor.zig");
    _ = @import("scene/document.zig");
    _ = @import("scene/validate.zig");
    _ = @import("scene/json_codec.zig");
    _ = @import("scene/binary_codec.zig");
    _ = @import("builtin/registry.zig");
}

/// Public declarations are analyzed lazily, so a broken `pub const` in this
/// file compiles fine until a downstream consumer touches it. Walk the exported
/// surface at comptime so that breakage is a build failure here instead.
fn touchDecls(comptime T: type, comptime depth: u8) void {
    if (depth == 0) return;
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return,
    }
    for (std.meta.declarations(T)) |decl| {
        const field = @field(T, decl.name);
        if (@TypeOf(field) == type) touchDecls(field, depth - 1);
    }
}

test "public API surface resolves" {
    @setEvalBranchQuota(200000);
    comptime touchDecls(@This(), 4);
}
