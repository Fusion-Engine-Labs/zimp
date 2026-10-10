const std = @import("std");
const zimp = @import("src/root.zig");

pub const addProjectCookStep = zimp.addProjectCookStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zob_dep = b.dependency("zob", .{
        .target = target,
        .optimize = optimize,
    });
    const zob_mod = zob_dep.module("zob");

    const mod = b.addModule("zimp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zob", .module = zob_mod },
        },
    });

    mod.addIncludePath(b.path("external/image"));
    mod.addCSourceFile(.{
        .file = b.path("external/image/stb_image.c"),
        .flags = &.{"-O3"},
    });
    addZstd(b, mod, target);
    mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "zimp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zimp", .module = mod },
            },
        }),
    });
    exe.root_module.addIncludePath(b.path("external/image"));
    exe.root_module.addIncludePath(b.path("external/zstd"));
    exe.root_module.addImport("zob", zob_mod);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const load_bench = b.addExecutable(.{
        .name = "zimp-load-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/perf/load_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zimp", .module = mod },
            },
        }),
    });
    const install_load_bench = b.addInstallArtifact(load_bench, .{});

    const perf_step = b.step("perf", "Run the local asset-cooking and loading stress suite");
    const perf_cmd = b.addSystemCommand(&.{ "python3", "scripts/perf/run_stress.py", "--zimp", "zig-out/bin/zimp", "--load-bench", "zig-out/bin/zimp-load-bench" });
    perf_cmd.has_side_effects = true;
    perf_cmd.step.dependOn(b.getInstallStep());
    perf_cmd.step.dependOn(&install_load_bench.step);
    if (b.args) |args| {
        perf_cmd.addArgs(args);
    }
    perf_step.dependOn(&perf_cmd.step);

    const docs_lib = b.addLibrary(.{
        .name = "zimp",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}

/// Vendored zstd (external/zstd): the pack writer compresses with it and
/// the runtime decompresses with it. Always built optimized, like stb_image,
/// so Debug builds still load packs at full speed.
fn addZstd(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const flags: []const []const u8 = &.{ "-O3", "-DXXH_NAMESPACE=ZSTD_", "-DZSTD_LEGACY_SUPPORT=0" };
    mod.addIncludePath(b.path("external/zstd"));
    mod.addCSourceFiles(.{
        .root = b.path("external/zstd"),
        .files = &.{
            "common/debug.c",
            "common/entropy_common.c",
            "common/error_private.c",
            "common/fse_decompress.c",
            "common/pool.c",
            "common/threading.c",
            "common/xxhash.c",
            "common/zstd_common.c",
            "compress/fse_compress.c",
            "compress/hist.c",
            "compress/huf_compress.c",
            "compress/zstd_compress.c",
            "compress/zstd_compress_literals.c",
            "compress/zstd_compress_sequences.c",
            "compress/zstd_compress_superblock.c",
            "compress/zstd_double_fast.c",
            "compress/zstd_fast.c",
            "compress/zstd_lazy.c",
            "compress/zstd_ldm.c",
            "compress/zstd_opt.c",
            "compress/zstd_preSplit.c",
            "compress/zstdmt_compress.c",
            "decompress/huf_decompress.c",
            "decompress/zstd_ddict.c",
            "decompress/zstd_decompress.c",
            "decompress/zstd_decompress_block.c",
        },
        .flags = flags,
    });
    // The BMI2 Huffman decoder; zstd only enables it on x86_64 ELF/Mach-O.
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag != .windows) {
        mod.addCSourceFile(.{ .file = b.path("external/zstd/decompress/huf_decompress_amd64.S"), .flags = flags });
    }
}
