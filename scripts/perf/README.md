# Local performance snapshot

Create a current local snapshot with:

```sh
zig build perf -Doptimize=ReleaseFast
```

For a quicker smoke snapshot:

```sh
zig build perf -Doptimize=ReleaseFast -- --quick
```

This is deliberately a local observation tool, not a CI gate. It creates a
deterministic fixture once, copies it for each scenario, and writes the current
results to `.perf/zimp-stress/results.json`.

The snapshot covers a forced cold cook, a warm no-op cook, and a one-file
dependency invalidation. Its generated sources include textures, a large OBJ,
shared-material shader fan-in, repeated-instance and interleaved-accessor glTF
files, shader variant declarations, a large-scene document, and a high count of
dependency-only files. Results include wall time, Linux peak RSS and process
I/O where available, cooked-output size/change counts, fixture parameters, and
build/machine metadata so a snapshot remains understandable when viewed later.

The normal command runs 30 independent samples per scenario and retains raw
samples plus median, minimum, maximum, and median absolute deviation.
Per-sample fixtures are removed after measurement; add `--keep-fixtures` to
inspect them. Use `--samples N` after `--` to tune the duration.

The default corpus uses 1024² textures, a 320×320 mesh grid, 256 instances,
and 384 dependency-only files. For the
original heavier stress size, add
`--texture-size 2048 --mesh-grid 384 --materials 32 --include-depth 24`
`--instances 512 --metadata-assets 1000 --scene-entities 10000` after `--`.

With `--load-bench` (passed automatically by `zig build perf`), every cold
sample is also load-benchmarked: `zimp-load-bench` (`load_bench.zig`) loads
each cooked file through `runtime.loadFromFile` repeatedly, after a warm-up
pass, and the suite reports median pass time, per-file cost, and throughput
per asset kind. The suite also breaks down cooked output bytes per kind.

Each cold output is also packed twice with `zimp pack --source`, as
`pack-zstd.zpak` (the default policy) and `pack-raw.zpak` (`--no-compress`).
The suite reports pack time and size, and the load bench loads every asset
from each pack through `runtime.PackStore`, mapping the pack afresh for every
pass so page faults count, and reports the pack open time separately. See
`PERFORMANCE.md` for the baseline and per-item before/after numbers.
