#!/usr/bin/env python3
"""Generate a deterministic large asset suite and measure zimp cooking.

The fixture is generated locally rather than checked in as binary blobs: it is
large enough to exercise texture compression, mesh conversion, dependency
planning, cache hits, and invalidation without bloating the repository.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import statistics
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path
from typing import Any


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MARKER_NAME = ".zimp-perf-fixture"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run zimp's deterministic, dependency-heavy cooking stress suite."
    )
    parser.add_argument(
        "--zimp",
        default="zig-out/bin/zimp",
        help="Path to the zimp executable built by Zig (default: zig-out/bin/zimp).",
    )
    parser.add_argument(
        "--load-bench",
        default=None,
        help="Path to the zimp-load-bench executable. When given, cold-cook outputs are also load-benchmarked.",
    )
    parser.add_argument(
        "--work-dir",
        default=".perf/zimp-stress",
        help="Directory used for generated sources, outputs, and results.",
    )
    parser.add_argument(
        "--texture-size",
        type=int,
        default=1024,
        help="Width and height of each generated RGBA texture (default: 1024).",
    )
    parser.add_argument(
        "--mesh-grid",
        type=int,
        default=320,
        help="Number of quads on each axis of the generated OBJ mesh (default: 320).",
    )
    parser.add_argument(
        "--materials",
        type=int,
        default=24,
        help="Number of materials sharing the shader and texture dependency fan-in.",
    )
    parser.add_argument(
        "--include-depth",
        type=int,
        default=20,
        help="Depth of the generated shader include chain.",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Use one smaller sample for a fast smoke run.",
    )
    parser.add_argument("--samples", type=int, default=30, help="Independent deterministic samples per scenario (default: 30).")
    parser.add_argument("--instances", type=int, default=256, help="Nodes that reference one mesh in the repeated-instance glTF fixture.")
    parser.add_argument("--metadata-assets", type=int, default=384, help="Dependency-only files used for file-count scaling.")
    parser.add_argument("--scene-entities", type=int, default=5000, help="Entities in the generated large-scene JSON fixture.")
    parser.add_argument("--keep-fixtures", action="store_true", help="Keep per-sample source/output trees instead of removing them after measurement.")
    parser.add_argument("--optimize", default="ReleaseFast", help="Build optimization mode recorded in result metadata.")
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    for name in ("texture_size", "mesh_grid", "materials", "include_depth", "samples", "instances", "metadata_assets", "scene_entities"):
        if getattr(args, name) < 1:
            raise SystemExit(f"--{name.replace('_', '-')} must be at least 1")
    if args.texture_size < 4:
        raise SystemExit("--texture-size must be at least 4 for block compression")


def ensure_owned_work_dir(repo_root: Path, work_dir: Path) -> None:
    resolved_root = repo_root.resolve()
    resolved_work = work_dir.resolve()
    if resolved_work == resolved_root or resolved_root not in resolved_work.parents:
        raise SystemExit("--work-dir must be a child of the repository root")

    if work_dir.exists():
        marker = work_dir / MARKER_NAME
        if not marker.exists():
            raise SystemExit(
                f"Refusing to replace '{work_dir}': it is not a stress-suite directory. "
                f"Delete it manually or choose another --work-dir."
            )
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True)
    (work_dir / MARKER_NAME).write_text("This directory is owned by scripts/perf/run_stress.py\n")


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def pixel_row(width: int, y: int, salt: int, texture_kind: str) -> bytes:
    # PNG filter method 0. `shake_256` produces deterministic, incompressible
    # bytes in C rather than spending minutes in a Python loop for a full-size
    # fixture. Channel slicing also runs in C and keeps normal/mask inputs
    # representative of their intended use.
    seed = f"zimp-perf:{salt}:{y}".encode("ascii")
    pixels = bytearray(hashlib.shake_256(seed).digest(width * 4))
    if texture_kind == "normal":
        pixels[0::4] = b"\x80" * width
        pixels[1::4] = b"\x80" * width
        pixels[2::4] = b"\xff" * width
    elif texture_kind == "mask":
        pixels[1::4] = pixels[0::4]
        pixels[2::4] = pixels[0::4]
    pixels[3::4] = b"\xff" * width
    return b"\0" + pixels


def write_png(path: Path, size: int, salt: int, texture_kind: str) -> None:
    compressor = zlib.compressobj(level=1)
    with path.open("wb") as output:
        output.write(PNG_SIGNATURE)
        output.write(png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)))
        output.write(png_chunk(b"IDAT", compressor.compress(pixel_row(size, 0, salt, texture_kind))))
        for y in range(1, size):
            compressed = compressor.compress(pixel_row(size, y, salt, texture_kind))
            if compressed:
                output.write(png_chunk(b"IDAT", compressed))
        final = compressor.flush()
        if final:
            output.write(png_chunk(b"IDAT", final))
        output.write(png_chunk(b"IEND", b""))


def write_mesh(path: Path, grid: int) -> None:
    """Write a large indexed grid with >65k vertices to exercise u32 indices."""
    side = grid + 1
    with path.open("w", encoding="utf-8", newline="\n") as output:
        output.write("# Generated zimp performance stress mesh\n")
        for y in range(side):
            fy = y / grid
            for x in range(side):
                fx = x / grid
                z = ((x * 17 + y * 31) % 23) / 2300.0
                output.write(f"v {fx:.6f} {fy:.6f} {z:.6f}\n")
        for _ in range(side * side):
            output.write("vn 0.0 0.0 1.0\n")
        for y in range(side):
            fy = y / grid
            for x in range(side):
                output.write(f"vt {x / grid:.6f} {fy:.6f}\n")
        for y in range(grid):
            for x in range(grid):
                a = y * side + x + 1
                b = a + 1
                c = a + side
                d = c + 1
                output.write(f"f {a}/{a}/{a} {b}/{b}/{b} {c}/{c}/{c}\n")
                output.write(f"f {a}/{a}/{a} {c}/{c}/{c} {d}/{d}/{d}\n")


def write_shaders(shader_dir: Path, include_depth: int) -> None:
    includes = shader_dir / "includes"
    includes.mkdir(parents=True)
    (includes / "layer_00.glsl").write_text(
        "float perfLayer00(float value) { return value + 0.0001; }\n", encoding="utf-8"
    )
    for layer in range(1, include_depth):
        (includes / f"layer_{layer:02d}.glsl").write_text(
            f'#include "layer_{layer - 1:02d}.glsl"\n'
            f"float perfLayer{layer:02d}(float value) {{ return perfLayer{layer - 1:02d}(value) * 1.00001; }}\n",
            encoding="utf-8",
        )

    # Four branches create a wide dependency fan-out while all paths share the
    # same include chain. Any leaf change therefore tests reverse invalidation.
    branch_layers = [include_depth - 1, include_depth * 3 // 4, include_depth // 2, include_depth // 4]
    for branch, layer in enumerate(branch_layers):
        (includes / f"branch_{branch}.glsl").write_text(
            f'#include "layer_{layer:02d}.glsl"\n'
            f"float perfBranch{branch}(float value) {{ return perfLayer{layer:02d}(value) + {branch}.0; }}\n",
            encoding="utf-8",
        )

    last = include_depth - 1
    (shader_dir / "stress.vert").write_text(
        "#version 330 core\n"
        '#include "includes/branch_0.glsl"\n'
        "layout(location = 0) in vec3 a_position;\n"
        "uniform mat4 u_model;\n"
        "void main() { gl_Position = u_model * vec4(a_position, perfBranch0(1.0)); }\n",
        encoding="utf-8",
    )
    (shader_dir / "stress.frag").write_text(
        "#version 330 core\n"
        "// VARIANTS: HAS_ALBEDO_MAP, HAS_NORMAL_MAP, HAS_ORM_MAP, HAS_ROUGHNESS_MAP, HAS_EMISSIVE_MAP\n"
        + "".join(f'#include "includes/branch_{branch}.glsl"\n' for branch in range(4))
        + "uniform sampler2D u_albedo;\n"
        "uniform sampler2D u_normal;\n"
        "uniform sampler2D u_orm;\n"
        "uniform sampler2D u_roughness;\n"
        "uniform sampler2D u_emissive;\n"
        "uniform float u_roughness_scale;\n"
        "uniform vec3 u_tint;\n"
        "in vec2 v_uv;\n"
        "out vec4 frag_color;\n"
        "void main() {\n"
        "  float v = perfBranch0(perfBranch1(perfBranch2(perfBranch3(v_uv.x))));\n"
        "  vec3 color = texture(u_albedo, v_uv).rgb * u_tint;\n"
        "  frag_color = vec4(color * (v + u_roughness_scale), 1.0);\n"
        "}\n",
        encoding="utf-8",
    )

    # Material-less glTF/OBJ fixtures receive zimp's generated DefaultMaterial,
    # whose stable shader path is shaders/basic.
    (shader_dir / "basic.vert").write_text(
        "#version 330 core\n"
        "layout(location = 0) in vec3 a_position;\n"
        "uniform mat4 u_model;\n"
        "void main() { gl_Position = u_model * vec4(a_position, 1.0); }\n",
        encoding="utf-8",
    )
    (shader_dir / "basic.frag").write_text(
        "#version 330 core\n"
        "uniform vec4 u_base_color;\n"
        "uniform float u_metallic;\n"
        "uniform float u_roughness;\n"
        "uniform vec3 u_emissive;\n"
        "out vec4 frag_color;\n"
        "void main() { frag_color = vec4(u_base_color.rgb + u_emissive * (1.0 - u_metallic), u_base_color.a); }\n",
        encoding="utf-8",
    )


def material_source(index: int) -> str:
    return f'''# Generated material {index}
[material]
shader = "shaders/stress"

[texture.u_albedo]
path = "textures/world_albedo.png"

[texture.u_normal]
path = "textures/world_normal.png"

[texture.u_orm]
path = "textures/world_orm.png"

[texture.u_roughness]
path = "textures/world_roughness.png"

[texture.u_emissive]
path = "textures/world_emissive.png"

[params]
u_roughness_scale = {0.2 + (index % 10) / 20:.2f}
u_tint = [1.0, {0.5 + (index % 8) / 16:.3f}, 0.75]
'''


def write_gltf_fixture(directory: Path, name: str, instances: int, interleaved: bool) -> None:
    """Write a small mesh with either packed or strided accessors.

    Both files describe the same quad. The repeated-instance file places the
    same mesh on many nodes, while the interleaved form gives the importer a
    realistic byteStride path without adding a second geometry payload.
    """
    positions = ((-0.5, -0.5, 0.0), (0.5, -0.5, 0.0), (0.5, 0.5, 0.0), (-0.5, 0.5, 0.0))
    normals = ((0.0, 0.0, 1.0),) * 4
    uvs = ((0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0))
    indices = (0, 1, 2, 0, 2, 3)
    binary = bytearray()
    if interleaved:
        for position, normal, uv in zip(positions, normals, uvs):
            binary.extend(struct.pack("<3f3f2f", *position, *normal, *uv))
        views = [
            {"buffer": 0, "byteOffset": 0, "byteLength": 128, "byteStride": 32, "target": 34962},
            {"buffer": 0, "byteOffset": 0, "byteLength": 128, "byteStride": 32, "target": 34962},
            {"buffer": 0, "byteOffset": 0, "byteLength": 128, "byteStride": 32, "target": 34962},
            {"buffer": 0, "byteOffset": 128, "byteLength": 12, "target": 34963},
        ]
        accessors = [
            {"bufferView": 0, "byteOffset": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [-0.5, -0.5, 0.0], "max": [0.5, 0.5, 0.0]},
            {"bufferView": 1, "byteOffset": 12, "componentType": 5126, "count": 4, "type": "VEC3"},
            {"bufferView": 2, "byteOffset": 24, "componentType": 5126, "count": 4, "type": "VEC2"},
        ]
    else:
        for position in positions:
            binary.extend(struct.pack("<3f", *position))
        for normal in normals:
            binary.extend(struct.pack("<3f", *normal))
        for uv in uvs:
            binary.extend(struct.pack("<2f", *uv))
        views = [
            {"buffer": 0, "byteOffset": 0, "byteLength": 48, "target": 34962},
            {"buffer": 0, "byteOffset": 48, "byteLength": 48, "target": 34962},
            {"buffer": 0, "byteOffset": 96, "byteLength": 32, "target": 34962},
            {"buffer": 0, "byteOffset": 128, "byteLength": 12, "target": 34963},
        ]
        accessors = [
            {"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [-0.5, -0.5, 0.0], "max": [0.5, 0.5, 0.0]},
            {"bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"},
        ]
    binary.extend(struct.pack("<6H", *indices))
    accessors.append({"bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR", "min": [0], "max": [3]})
    binary_path = directory / f"{name}.bin"
    binary_path.write_bytes(binary)
    nodes = [{"mesh": 0, "translation": [float(index % 32), float(index // 32), 0.0]} for index in range(instances)]
    gltf = {
        "asset": {"version": "2.0", "generator": "zimp perf fixture"},
        "scene": 0,
        "scenes": [{"nodes": list(range(instances))}],
        "nodes": nodes,
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3}]}],
        "buffers": [{"uri": binary_path.name, "byteLength": len(binary)}],
        "bufferViews": views,
        "accessors": accessors,
    }
    (directory / f"{name}.gltf").write_text(json.dumps(gltf, separators=(",", ":")), encoding="utf-8")


def write_shader_variant_fixtures(shader_dir: Path) -> None:
    for variant_count in (0, 4, 6, 8):
        variants = ", ".join(f"PERF_VARIANT_{index}" for index in range(variant_count))
        (shader_dir / f"variant_{variant_count}.frag").write_text(
            "#version 330 core\n"
            + (f"// VARIANTS: {variants}\n" if variants else "")
            + "out vec4 frag_color;\nvoid main() { frag_color = vec4(1.0); }\n",
            encoding="utf-8",
        )


def write_large_scene_fixture(scene_dir: Path, entities: int) -> None:
    scene_dir.mkdir(parents=True)
    document = {
        "fixture": "large_scene",
        "entities": [
            {
                "id": index,
                "name": f"entity_{index:06d}",
                "parent": index // 8 - 1 if index else None,
                "components": {"transform": [float(index % 97), float(index % 31), 0.0], "tag": "even" if index % 2 == 0 else "odd"},
                "reference": (index * 17) % entities if entities else None,
            }
            for index in range(entities)
        ],
    }
    (scene_dir / "large_scene.json").write_text(json.dumps(document, separators=(",", ":")), encoding="utf-8")


def generate_fixture(source: Path, texture_size: int, mesh_grid: int, materials: int, include_depth: int, instances: int, metadata_assets: int, scene_entities: int) -> dict[str, int]:
    textures = source / "textures"
    shaders = source / "shaders"
    material_dir = source / "materials"
    mesh_dir = source / "meshes"
    fixture_dir = source / "fixtures"
    metadata_dir = source / "metadata_pressure"
    for directory in (textures, shaders, material_dir, mesh_dir, fixture_dir, metadata_dir):
        directory.mkdir(parents=True)

    texture_specs = (
        ("world_albedo.png", "color"),
        ("world_normal.png", "normal"),
        ("world_orm.png", "color"),
        ("world_roughness.png", "mask"),
        ("world_emissive.png", "color"),
    )
    for salt, (name, kind) in enumerate(texture_specs, start=1):
        write_png(textures / name, texture_size, salt, kind)

    write_mesh(mesh_dir / "terrain_stress.obj", mesh_grid)
    write_shaders(shaders, include_depth)
    write_shader_variant_fixtures(shaders)
    write_gltf_fixture(fixture_dir, "repeated_instances", instances, interleaved=False)
    write_gltf_fixture(fixture_dir, "interleaved_accessors", 1, interleaved=True)
    write_large_scene_fixture(fixture_dir / "scene", scene_entities)
    for index in range(materials):
        (material_dir / f"stress_{index:03d}.zamat").write_text(material_source(index), encoding="utf-8")
    for index in range(metadata_assets):
        (metadata_dir / f"metadata_{index:05d}.glsl").write_text(f"// dependency-only metadata fixture {index}\n", encoding="utf-8")

    return {
        "textures": len(texture_specs),
        "meshes": 1,
        "shader_stages": 4,
        "shader_includes": include_depth + 4,
        "materials": materials + 3,
        "unique_geometry_count": 2,
        "repeated_instance_count": instances,
        "interleaved_accessor_meshes": 1,
        "shader_variant_declarations": 0 + 4 + 6 + 8,
        "shader_variant_permutations": 1 + 16 + 64 + 256,
        "large_scene_entities": scene_entities,
        "metadata_assets": metadata_assets,
        # Every material depends directly on two stages and five textures.
        "direct_material_edges": materials * 7 + 3 * 2,
    }


def linux_process_metrics(pid: int) -> dict[str, int | None]:
    """Read process-owned OS counters without treating allocator bytes as RSS."""
    result: dict[str, int | None] = {"peak_rss_bytes": None, "read_bytes": None, "write_bytes": None}
    try:
        status = Path(f"/proc/{pid}/status").read_text(encoding="utf-8")
        match = re.search(r"^VmHWM:\s+(\d+)\s+kB$", status, re.MULTILINE)
        if match:
            result["peak_rss_bytes"] = int(match.group(1)) * 1024
        io_text = Path(f"/proc/{pid}/io").read_text(encoding="utf-8")
        values = dict(re.findall(r"^(read_bytes|write_bytes):\s+(\d+)$", io_text, re.MULTILINE))
        result["read_bytes"] = int(values["read_bytes"]) if "read_bytes" in values else None
        result["write_bytes"] = int(values["write_bytes"]) if "write_bytes" in values else None
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        pass
    return result


def run_cook(zimp: Path, source: Path, output: Path, label: str, force: bool) -> dict[str, Any]:
    command = [str(zimp), "cook", "--source", str(source), "--output", str(output)]
    if force:
        command.append("--force")

    start_ns = time.perf_counter_ns()
    process = subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os_metrics: dict[str, int | None] = {"peak_rss_bytes": None, "read_bytes": None, "write_bytes": None}
    while process.poll() is None:
        if sys.platform.startswith("linux"):
            observed = linux_process_metrics(process.pid)
            for key, value in observed.items():
                if key == "peak_rss_bytes" and value is not None:
                    os_metrics[key] = max(os_metrics[key] or 0, value)
                elif value is not None:
                    os_metrics[key] = value
        time.sleep(0.002)
    stdout, stderr = process.communicate()
    wall_ns = time.perf_counter_ns() - start_ns
    combined = stdout + "\n" + stderr
    if process.returncode != 0:
        print(combined, file=sys.stderr)
        raise RuntimeError(f"{label} cook returned {process.returncode}")
    return {"wall_ns": wall_ns, "os": os_metrics}


def format_duration(ns: int | float) -> str:
    if ns >= 1_000_000_000:
        return f"{ns / 1_000_000_000:.2f}s"
    if ns >= 1_000_000:
        return f"{ns / 1_000_000:.1f}ms"
    if ns >= 1_000:
        return f"{ns / 1_000:.1f}us"
    return f"{ns:.0f}ns"


def format_bytes(value: int | float) -> str:
    units = ("B", "KiB", "MiB", "GiB")
    amount = float(value)
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            return f"{amount:.1f}{unit}" if unit != "B" else f"{amount:.0f}B"
        amount /= 1024
    return f"{amount:.1f}GiB"


def aggregate_values(values: list[Any]) -> Any:
    """Aggregate numeric observations while retaining the raw local samples."""
    first = values[0]
    if isinstance(first, dict):
        keys = set(first)
        if any(not isinstance(value, dict) or set(value) != keys for value in values):
            return None
        return {key: aggregate_values([value[key] for value in values]) for key in sorted(keys)}
    if isinstance(first, (int, float)) and not isinstance(first, bool):
        numbers = [float(value) for value in values]
        median = statistics.median(numbers)
        return {"median": median, "min": min(numbers), "max": max(numbers), "mad": statistics.median(abs(value - median) for value in numbers)}
    return first if all(value == first for value in values) else None


def aggregate_scenario(samples: list[dict[str, Any]]) -> dict[str, Any]:
    return aggregate_values(samples)


def metric_median(scenario: dict[str, Any], *path: str) -> float:
    current: Any = scenario["aggregate"]
    for key in path:
        current = current[key]
    return float(current["median"])


def print_table(headers: tuple[str, ...], rows: list[tuple[str, ...]]) -> None:
    """Print a plain-text table that remains readable in terminals."""
    widths = [len(header) for header in headers]
    for row in rows:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))

    separator = "+" + "+".join("-" * (width + 2) for width in widths) + "+"
    print(separator)
    print("|" + "|".join(f" {header:<{width}} " for header, width in zip(headers, widths)) + "|")
    print(separator)
    for row in rows:
        print("|" + "|".join(f" {cell:<{width}} " for cell, width in zip(row, widths)) + "|")
    print(separator)


def print_results(scenarios: dict[str, dict[str, Any]]) -> None:
    print("\nRESULTS AT A GLANCE")
    print_table(
        ("Scenario", "Wall median", "MAD", "RSS median", "Output", "Changed cooked files"),
        [
            (
                name,
                format_duration(metric_median(scenario, "wall_ns")),
                format_duration(scenario["aggregate"]["wall_ns"]["mad"]),
                "unavailable" if scenario["aggregate"]["os"]["peak_rss_bytes"] is None else format_bytes(scenario["aggregate"]["os"]["peak_rss_bytes"]["median"]),
                format_bytes(metric_median(scenario, "cooked_output_bytes")),
                f"{metric_median(scenario, 'changed_cooked_files'):.0f}",
            )
            for name, scenario in scenarios.items()
            if name != "load"
        ],
    )
    by_kind = scenarios["cold"]["aggregate"].get("cooked_by_kind")
    if by_kind:
        print("\nCOOKED OUTPUT BY KIND (cold)")
        print_table(
            ("Kind", "Files", "Bytes"),
            [(kind, f"{stats['files']['median']:.0f}", format_bytes(stats["bytes"]["median"])) for kind, stats in by_kind.items()],
        )
    load = scenarios.get("load")
    if load:
        print("\nLOAD (runtime.loadFromFile over the cold output, warm page cache)")
        print_table(
            ("Kind", "Files", "Bytes", "Pass median", "Per file", "Throughput"),
            [
                (
                    kind,
                    f"{stats['files']['median']:.0f}",
                    format_bytes(stats["bytes"]["median"]),
                    format_duration(stats["median_pass_ns"]["median"]),
                    format_duration(stats["us_per_file"]["median"] * 1000),
                    f"{stats['gb_per_s']['median']:.2f} GB/s",
                )
                for kind, stats in load["aggregate"].items()
            ],
        )
    cold_total = metric_median(scenarios["cold"], "wall_ns")
    warm_total = metric_median(scenarios["warm_noop"], "wall_ns")
    invalidated_total = metric_median(scenarios["one_file_invalidation"], "wall_ns")
    warm_speedup = cold_total / warm_total if warm_total else 0.0
    invalidation_speedup = cold_total / invalidated_total if invalidated_total else 0.0
    print("\nKEY COMPARISONS")
    print(f"  Warm no-op: {warm_speedup:.1f}× faster than cold.")
    print(f"  One-file invalidation: {invalidation_speedup:.1f}× faster than cold.")


def collect_metadata(args: argparse.Namespace) -> dict[str, Any]:
    zig_version = subprocess.run(["zig", "version"], text=True, capture_output=True, check=False).stdout.strip() or None
    cpu_model = None
    if sys.platform.startswith("linux"):
        try:
            cpu_model = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines() if line.startswith("model name")), None)
        except OSError:
            pass
    return {
        "commit": subprocess.run(["git", "rev-parse", "HEAD"], text=True, capture_output=True, check=False).stdout.strip() or None,
        "zig_version": zig_version,
        "optimize": args.optimize,
        "platform": platform.platform(),
        "cpu_model": cpu_model,
        "cpu_count": os.cpu_count(),
        "target_triple": platform.machine() + "-" + sys.platform,
        "python": platform.python_version(),
    }


def prepare_sample(root: Path, fixture_source: Path) -> tuple[Path, Path]:
    source = root / "source"
    output = root / "cooked"
    root.mkdir(parents=True)
    shutil.copytree(fixture_source, source)
    output.mkdir()
    return source, output


def cooked_file_snapshot(output: Path) -> dict[str, tuple[int, int]]:
    """Return only cooked asset files; the cache is not a cooked output."""
    return {
        str(path.relative_to(output)): (path.stat().st_size, path.stat().st_mtime_ns)
        for path in output.rglob("*")
        if path.is_file() and path.name != ".zcache"
    }


def add_output_snapshot(result: dict[str, Any], before: dict[str, tuple[int, int]], output: Path) -> dict[str, Any]:
    after = cooked_file_snapshot(output)
    result["cooked_output_bytes"] = sum(size for size, _ in after.values())
    result["cooked_output_files"] = len(after)
    result["changed_cooked_files"] = sum(1 for path, stat in after.items() if before.get(path) != stat)
    by_kind: dict[str, dict[str, int]] = {}
    for path, (size, _) in after.items():
        kind = by_kind.setdefault(Path(path).suffix.lstrip(".") or "(none)", {"bytes": 0, "files": 0})
        kind["bytes"] += size
        kind["files"] += 1
    result["cooked_by_kind"] = by_kind
    return result


def run_load_bench(load_bench: Path, output: Path) -> dict[str, Any]:
    """Load every cooked asset through zimp's runtime loader; see load_bench.zig."""
    process = subprocess.run([str(load_bench), str(output)], text=True, capture_output=True, check=False)
    if process.returncode != 0:
        print(process.stdout + "\n" + process.stderr, file=sys.stderr)
        raise RuntimeError(f"load bench returned {process.returncode}")
    result: dict[str, Any] = {}
    for line in process.stdout.splitlines():
        row = json.loads(line)
        median_ns = row["median_pass_ns"]
        result[row["kind"]] = {
            "files": row["files"],
            "bytes": row["bytes"],
            "median_pass_ns": median_ns,
            "us_per_file": median_ns / 1000 / row["files"],
            "gb_per_s": row["bytes"] / median_ns if median_ns else 0.0,
        }
    return result


def run_scenario(name: str, source: Path, output: Path, zimp: Path) -> dict[str, Any]:
    if name == "cold":
        result = add_output_snapshot(run_cook(zimp, source, output, name, force=True), {}, output)
    elif name == "warm_noop":
        before = cooked_file_snapshot(output)
        result = add_output_snapshot(run_cook(zimp, source, output, name, force=False), before, output)
    elif name == "one_file_invalidation":
        leaf = source / "shaders" / "includes" / "layer_00.glsl"
        leaf.write_text(leaf.read_text(encoding="utf-8") + "\n// changed once for this deterministic sample\n", encoding="utf-8")
        before = cooked_file_snapshot(output)
        result = add_output_snapshot(run_cook(zimp, source, output, name, force=False), before, output)
    else:
        raise AssertionError(name)
    return result


def main() -> int:
    args = parse_args()
    validate_args(args)
    if args.quick:
        args.texture_size = min(args.texture_size, 512)
        args.mesh_grid = min(args.mesh_grid, 128)
        args.materials = min(args.materials, 12)
        args.include_depth = min(args.include_depth, 12)
        args.instances = min(args.instances, 64)
        args.metadata_assets = min(args.metadata_assets, 128)
        args.scene_entities = min(args.scene_entities, 512)
        args.samples = min(args.samples, 1)

    repo_root = Path.cwd()
    zimp = Path(args.zimp)
    if not zimp.is_absolute():
        zimp = repo_root / zimp
    if not zimp.is_file():
        raise SystemExit(f"zimp executable not found: {zimp}. Run through 'zig build perf'.")
    load_bench = None
    if args.load_bench:
        load_bench = Path(args.load_bench)
        if not load_bench.is_absolute():
            load_bench = repo_root / load_bench
        if not load_bench.is_file():
            raise SystemExit(f"load bench executable not found: {load_bench}. Run through 'zig build perf'.")

    work_dir = Path(args.work_dir)
    if not work_dir.is_absolute():
        work_dir = repo_root / work_dir
    ensure_owned_work_dir(repo_root, work_dir)
    fixture_source = work_dir / "fixture-source"
    fixture_source.mkdir()
    fixture = generate_fixture(
        fixture_source,
        args.texture_size,
        args.mesh_grid,
        args.materials,
        args.include_depth,
        args.instances,
        args.metadata_assets,
        args.scene_entities,
    )
    print("zimp performance stress suite")
    print("=" * 29)
    print(f"Work directory: {work_dir}; samples per scenario: {args.samples}")
    scenarios: dict[str, dict[str, Any]] = {}
    samples_by_scenario: dict[str, list[dict[str, Any]]] = {
        "cold": [],
        "warm_noop": [],
        "one_file_invalidation": [],
    }
    for index in range(args.samples):
        sample_root = work_dir / "samples" / f"sample-{index:03d}"
        source, output = prepare_sample(sample_root, fixture_source)
        samples_by_scenario["cold"].append(run_scenario("cold", source, output, zimp))
        if load_bench is not None:
            samples_by_scenario.setdefault("load", []).append(run_load_bench(load_bench, output))
        samples_by_scenario["warm_noop"].append(run_scenario("warm_noop", source, output, zimp))
        samples_by_scenario["one_file_invalidation"].append(
            run_scenario("one_file_invalidation", source, output, zimp)
        )
        if not args.keep_fixtures:
            shutil.rmtree(sample_root)
    for name, samples in samples_by_scenario.items():
        scenarios[name] = {"samples": samples, "aggregate": aggregate_scenario(samples)}
    load_scenario = scenarios.pop("load", None)

    for sample in scenarios["warm_noop"]["samples"]:
        if sample["changed_cooked_files"] != 0:
            raise RuntimeError("warm no-op sample rewrote cooked files")
    for sample in scenarios["one_file_invalidation"]["samples"]:
        if sample["changed_cooked_files"] == 0:
            raise RuntimeError("one-file invalidation sample did not recook affected assets")

    if load_scenario is not None:
        scenarios["load"] = load_scenario
    print_results(scenarios)
    results = {
        "schema_version": 1,
        "metadata": collect_metadata(args),
        "fixture": {**fixture, "texture_size": args.texture_size, "mesh_grid": args.mesh_grid, "include_depth": args.include_depth, "samples": args.samples},
        "scenarios": scenarios,
    }
    result_path = work_dir / "results.json"
    result_path.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"\nMachine-readable results: {result_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"stress suite failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
