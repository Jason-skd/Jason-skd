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

    const unit_tests = b.addTest(.{
        .name = "unit-tests",
        .root_module = app_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const integration_tests = b.addTest(.{
        .name = "config-integration-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/config_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "profile_generator", .module = app_module },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const git_activity_integration_tests = b.addTest(.{
        .name = "git-activity-integration-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/git_activity_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "profile_generator", .module = app_module },
            },
        }),
    });
    const run_git_activity_integration_tests = b.addRunArtifact(git_activity_integration_tests);

    const github_data_integration_tests = b.addTest(.{
        .name = "github-data-integration-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/github_data_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "profile_generator", .module = app_module },
            },
        }),
    });
    const run_github_data_integration_tests = b.addRunArtifact(github_data_integration_tests);

    const production_config_options = b.addOptions();
    production_config_options.addOptionPath("profile_path", b.path("profile.yaml"));
    const production_config_tests = b.addTest(.{
        .name = "production-config-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/config_production.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "profile_generator", .module = app_module },
                .{ .name = "production_config_options", .module = production_config_options.createModule() },
            },
        }),
    });
    const run_production_config_tests = b.addRunArtifact(production_config_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_git_activity_integration_tests.step);
    test_step.dependOn(&run_github_data_integration_tests.step);
    test_step.dependOn(&run_production_config_tests.step);
}
