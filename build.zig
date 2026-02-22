const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mod = b.addModule("json_zig_utils", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zon-json",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "json_zig_utils", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);
    // add test to zig-out for debugging (zig build to install).
    b.installArtifact(mod_tests);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    run_step.dependOn(&run_cmd.step);
}
