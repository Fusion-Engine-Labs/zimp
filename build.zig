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
}
