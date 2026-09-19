const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap_dependency = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const ymlz_dependency = b.dependency("ymlz", .{
        .target = target,
        .optimize = optimize,
    });

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clap", .module = clap_dependency.module("clap") },
            .{ .name = "ymlz", .module = ymlz_dependency.module("root") },
        },
    });

    const executable = b.addExecutable(.{
        .name = "profile-generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "profile_generator", .module = app_module },
            },
        }),
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    run_command.addPassthruArgs();

    const run_step = b.step("run", "Run the profile generator");
    run_step.dependOn(&run_command.step);

    const tests = b.addTest(.{
        .root_module = app_module,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
