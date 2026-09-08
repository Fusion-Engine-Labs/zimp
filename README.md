# zimp (Fusion Asset Compiler- IN DEVELOPMENT)

A build-time asset compiler for Zig 0.16 that converts source assets into GPU-optimized binary formats, maintains durable asset identity, and generates the asset manifest the engine resolves assets through at runtime.

Designed for the [Fusion Game Engine](https://github.com/Fusion-Engine) but fully standalone — usable in any Zig project that needs an offline asset pipeline.

## Features

- **Build-time cooking** — converts source assets (glTF/GLB, OBJ, PNG/JPG/HDR, GLSL, TOML materials) into flat binary formats optimized for direct GPU upload.
- **Asset manifest** — project cooks emit `assets.zmanifest`, a deterministic database mapping `AssetId` → source path, cooked path, kind, and content hash. The runtime resolves assets through it instead of hard-coded paths.
- **Project mode** — `zimp cook --project <root>` reads `.fusion/fusion.proj` and derives all directories from the project manifest; no hand-wired source/output paths.
- **SoA mesh layout** — vertex streams stored separately (positions, normals, UVs) so the engine binds only what each render pass needs.
- **Vertex quantization** — octahedral normals (`[2]i16`), `f16` tangents, normalized `u16` UVs, `u16` indices where they fit.
- **Texture classification** — automatic format selection (BC7/BC5/BC4) from filename convention (`*_albedo`, `*_normal`, ...) and material slot.
- **Block compression** — built-in BC4, BC5, BC6H, and BC7 encoders written in Zig. No external texture tools required.
- **Shader preprocessing** — `#include` resolution and variant expansion; cooked shaders store final GLSL source per stage.
- **glTF material extraction** — materials and embedded images inside `.glb`/`.gltf` are auto-generated as sources under `generated/` (with deterministic derived ids) and cooked in the same run.
- **Incremental builds** — content-hashed `.zcache` with dependency graph tracking. Only re-cooks what changed.
- **Dual interface** — plugs into `build.zig` as a build step (`addProjectCookStep`) or runs as a standalone CLI.
- **Zero runtime dependencies** — cooked formats are self-contained binary blobs. No third-party parsers at runtime.

## Compiler Overview

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                          Source Assets                              │
  │      .glb  .gltf  .obj  .png  .jpg  .hdr  .vert  .frag  .zamat      │
  │                                                                     │
  └──────────────────────────────┬──────────────────────────────────────┘
                                 │
                                 ▼
                          ┌────────────┐
                          │  Discover  │  scan dir, hash files, build dependency graph
                          └──────┬─────┘
                                 │
                                 ▼
                          ┌────────────┐
                          │    Cook    │  convert to binary formats (parallel, incremental)
                          └──────┬─────┘
                                 │
                 ┌───────────┬───┴─────┬───────────┐
                 ▼           ▼         ▼           ▼
              .zmesh      .ztex     .zshdr      .zamat
                                 │
                                 ▼ 
                          ┌────────────┐
                          │  Identity  │ write assets.zmanifest
                          └──────┬─────┘
                                 │
                                 ▼
                        assets.zmanifest
```

## Requirements

- Zig 0.16+

## Installing

Add zimp as a dependency in your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/Fusion-Engine/zimp.git
```

Then in your `build.zig`, cook the project as a build step:

```zig
const zimp = @import("zimp");

const zimp_dep = b.dependency("zimp", .{
    .target = target,
    .optimize = .ReleaseFast,
});

// Project root = the directory containing .fusion/fusion.proj.
const cook = zimp.addProjectCookStep(b, zimp_dep, b.path("."));
const cook_step = b.step("cook", "Cook assets with zimp");
cook_step.dependOn(&cook.step);

// Game exe depends on cooked assets
run_cmd.step.dependOn(&cook.step);
```

## Running the CLI

```sh
zig build run -- <command> [flags]
```

### Cook a project (recommended)

Reads `.fusion/fusion.proj`, cooks `assets_dir` into `cooked_assets_dir`, resolves durable ids, and writes `assets.zmanifest`:

```sh
zimp cook --project path/to/project
```

### Cook a bare directory

Directory mode cooks without a project: no identity, no manifest. Useful for ad-hoc conversion; the Fusion runtime requires a manifest and will not load from a dir-mode cook.

```sh
zimp cook --source assets/ --output cooked/

# Force a full recook, ignoring the incremental cache
zimp cook --project . --force

# Emit machine-readable metrics for CI parsing
zimp cook --source assets/ --output cooked/ --metrics-json
```

### Inspect cooked assets

```sh
zimp inspect cooked/monkey.zmesh
zimp inspect cooked/basic.vert.zshdr
zimp inspect cooked/monkey.zamat
zimp inspect cooked/.zcache          # directory mode
zimp inspect .fusion/.zcache         # project mode
```

## Running tests

```sh
zig build test --summary all
```

## Durable asset identity

zimp is the source of truth for asset identity (see [`docs/identity.md`](docs/identity.md) for the full rules):

- **`assets.zmanifest`** is generated output (never committed): a deterministic, validated JSON database of every cooked asset. Identical inputs produce byte-identical manifests.
- Ids are resolved by three frozen rules, in order: `generated/**` paths get deterministic derived ids (pure function of the path, no sidecar); an existing sidecar wins; otherwise a fresh UUIDv4 is minted and a sidecar written.
- Duplicate ids (e.g. a file copied together with its sidecar) are a hard cook error naming both paths. Corrupt sidecars are hard errors — zimp never silently re-identifies an asset. Sidecars are flushed only after the manifest write succeeds.

The shared ID types (`Uuid`, `AssetId`, `SceneId`, `SceneEntityId`, `ProjectId`, `ComponentTypeId`, `SchemaId`) live in `zimp.id` as distinct wrapper types, and the project manifest model (`zimp.ProjectManifest`, `zimp.ProjectRoot`) lives in `zimp.project`, so the cooker, runtime, and editor all share one definition.

## Performance stress suite

Run a representative local cook benchmark from the repository root:

```sh
zig build perf -Doptimize=ReleaseFast
```


For a quick smoke run, use:

```sh
zig build perf -Doptimize=ReleaseFast -- --quick
```

See [`scripts/perf/README.md`](scripts/perf/README.md) for the workload and
tuning options. Performance measurement is intentionally local rather than a
CI gate: the suite can be repeated on the same machine with a workload large
enough to expose meaningful changes without noisy hosted-runner comparisons.

## Cooked formats

### Meshes (`.zmesh`)

Source: `.glb`, `.gltf`, `.obj`

Version 2 is a model container made of one or more transformed mesh parts.
Each part stores SoA vertex streams that are directly uploadable to the GPU:

```zig
const zmesh = @import("zimp").formats.zmesh;

var read_buffer: [8192]u8 = undefined;
var file_reader = file.reader(io, &read_buffer);
var mesh = try zmesh.read(allocator, &file_reader.interface);
defer mesh.deinit(allocator);

for (mesh.parts) |part| {
    // part.transform is the glTF node's local-to-model matrix.
    upload(part.mesh.positions, part.mesh.indices_u16, part.mesh.indices_u32);
}
```

| Stream | Type | Notes |
|--------|------|-------|
| Positions | `[3]f32` | Always present |
| Normals | `[2]i16` | Octahedral encoding, reconstruct Z in shader |
| Tangents | `[4]f16` | Optional |
| UV0 | `[2]u16` | Normalized to 0–65535 |
| UV1 | `[2]u16` | Optional second UV set |
| Joint indices | `[4]u16` | For skinned meshes |
| Joint weights | `[4]f16` | For skinned meshes |

Each part includes an AABB bounding box; indices are `u16` when they fit,
`u32` otherwise. glTF scene nodes are traversed from the default scene,
including nested node transforms and repeated mesh instances. Files without a
scene graph import every declared mesh with an identity transform.

The cache checks the magic and version embedded in every cooked output before
accepting a cache hit. When a cooked format version changes, only assets of
that format are recooked.

### Textures (`.ztex`)

Source: `.png`, `.jpg`, `.jpeg`, `.hdr`

Pre-mipmapped and block-compressed. Format is auto-selected by texture classification:

| Usage | Format | Classification |
|-------|--------|----------------|
| Color / Albedo | BC7 (sRGB) | `*_albedo.*`, `*_diffuse.*`, `*_basecolor.*` |
| Normal maps | BC5 (linear) | `*_normal.*`, `*_nrm.*` |
| Roughness / Metallic / AO (packed) | BC7 (linear) | `*_orm.*`, `*_rm.*` |
| Single channel (roughness, height, AO) | BC4 (linear) | `*_roughness.*`, `*_height.*`, `*_ao.*` |

Classification priority: material slot name > filename convention > default (BC7 sRGB).

### Shaders (`.zshdr`)

Source: `.vert`, `.frag`, `.comp` (with `.glsl` includes)

Preprocessed GLSL per stage with `#include` resolution and variant expansion; stores final GLSL source text for runtime compilation. One cooked file per stage (`basic.vert.zshdr`, `basic.frag.zshdr`); the runtime links stage pairs into programs.

### Materials (`.zamat`)

Source: `.zamat` (TOML text)

Binary material definitions referencing cooked shaders and textures by path hash, with inline parameter blocks packed for shader uniform upload. The material writer only hashes referenced paths and does not need cooked shader or texture outputs, but the dependency graph still records those logical edges so cache invalidation cascades correctly.

```toml
[material]
shader = "shaders/pbr_standard"

[render_state]
alpha_mode = "solid"
alpha_cutoff = 0.5
double_sided = false
cull_mode = "back"
depth_test = true
depth_write = true
blend_mode = "disabled"

[texture.u_albedo]
path = "textures/brick_albedo.png"

[texture.u_normal_map]
path = "textures/brick_normal.png"

[texture.u_roughness_metallic_map]
path = "textures/brick_rm.png"

[params]
u_uv_scale = [2.0, 2.0]
u_emissive_strength = 0.0
```

`[material]` holds metadata. `shader` is a base path that resolves to `<shader>.vert` and `<shader>.frag`; `[render_state]` stores draw-state such as alpha mode, culling, depth, and blending. Each `[texture.<sampler>]` supplies a texture for the sampler with that exact name; the standard shader uses `u_albedo`, `u_normal_map`, `u_roughness_metallic_map`, `u_ao_map`, and `u_emissive_map`. Custom sampler names work the same way. `[params]` is a flat map from exact shader uniform names to scalar, boolean, vec2, vec3, or vec4 literals. Shader bindings are deliberately not authored in materials.

When `.glb` or `.gltf` files contain materials, zimp auto-generates material source files under `generated/materials/` and embedded image files under `generated/textures/`, then rescans so they cook in the same run. Generated sources get deterministic derived `AssetId`s (a pure function of their path — no sidecars) so regenerating them never changes identity. Hand-written files in `materials/` with the same generated filename take priority and are never overwritten. GLTF PBR fields map to standard slots and uniforms: base color texture to `albedo`, metallic-roughness texture to `roughness_metallic`, normal to `normal`, occlusion to `ao`, emissive texture to `emissive`, and factors to `u_base_color`, `u_metallic`, `u_roughness`, and `u_emissive`.

## Incremental builds

zimp maintains a `.zcache` file that tracks content hashes and dependency relationships. Project mode stores it at `<project>/.fusion/.zcache`; directory mode stores it inside the selected output directory. This keeps independent projects and output roots from sharing mutable cache state. On subsequent runs, only assets whose source files changed (or whose dependencies changed) are re-cooked. A material that references `brick_normal.png` will automatically re-cook when that texture is modified.

```sh
# First run: cooks everything
zimp cook --project .
# Cooked 47 assets in 3.2s

# Second run: nothing changed
zimp cook --project .
# 0 assets to cook (47 cached)

# After editing brick_normal.png
zimp cook --project .
# Cooked 2 assets in 0.4s (brick_normal.ztex + brick.zamat)
```

Asset identity does not depend on the cache: deleting `.zcache` (or the whole cooked directory and manifest) and recooking reproduces identical `AssetId`s from the committed sidecars.

Cooked paths preserve the source directory structure and replace the source extension. For example, `meshes/characters/hero.glb` becomes `meshes/characters/hero.zmesh`. Shader stage extensions are retained (`shaders/basic.vert` becomes `shaders/basic.vert.zshdr`). This prevents assets in different directories from colliding; two source files in the same directory that would map to one output are rejected during planning.

## Planned

- `zimp pack` — combine cooked assets into a single archive with a sorted TOC for O(log n) lookup (the CLI command exists as a stub).
- Audio (`.wav`, `.ogg`) and font (`.ttf`) cooking.
- Skeleton/animation extraction from glTF.
- SPIR-V shader compilation with reflection extraction for a future Vulkan backend.
