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

    const catalog_generator = b.addExecutable(.{
        .name = "language-catalog-generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/language_catalog_generator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "profile_generator", .module = app_module },
            },
        }),
    });
    const catalog_run = b.addRunArtifact(catalog_generator);
    catalog_run.addPassthruArgs();
    const catalog_step = b.step("generate-language-catalog", "Generate the offline Zig language catalog");
    catalog_step.dependOn(&catalog_run.step);

    const unit_tests = b.addTest(.{
        .name = "unit-tests",
        .root_module = app_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_step = b.step("test-unit", "Run application and module unit tests");
    unit_step.dependOn(&run_unit_tests.step);

    const cli_test_options = b.addOptions();
    cli_test_options.addOptionPath("executable", executable.getEmittedBin());
    const cli_tests = b.addTest(.{
        .name = "application-cli-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/application_cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cli_test_options", .module = cli_test_options.createModule() }},
        }),
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const cli_step = b.step("test-cli", "Run offline application CLI tests");
    cli_step.dependOn(&run_cli_tests.step);

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

    const language_catalog_tests = b.addTest(.{
        .name = "language-catalog-generator-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/language_catalog_generator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "profile_generator", .module = app_module },
            },
        }),
    });
    const run_language_catalog_tests = b.addRunArtifact(language_catalog_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_git_activity_integration_tests.step);
    test_step.dependOn(&run_github_data_integration_tests.step);
    test_step.dependOn(&run_production_config_tests.step);
    test_step.dependOn(&run_language_catalog_tests.step);
}
