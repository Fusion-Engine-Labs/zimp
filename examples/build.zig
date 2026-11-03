const std = @import("std");
const zimp = @import("zimp");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimp_dep = b.dependency("zimp", .{
        .target = target,
        .optimize = optimize,
    });
    const cook = zimp.addProjectCookStep(b, zimp_dep, b.path("."));
    const cook_step = b.step("cook", "Cook assets with zimp");
    cook_step.dependOn(&cook.step);

    const exe = b.addExecutable(.{
        .name = "examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zimp", .module = zimp_dep.module("zimp") },
            },
        }),
    });

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(&cook.step);

    run_cmd.addPassthruArgs();
}
