const std = @import("std");

pub const config = @import("config.zig");
pub const cli = @import("cli.zig");
pub const github = @import("github.zig");
pub const github_workflow = @import("github_workflow.zig");
pub const git_activity = @import("git_activity.zig");
pub const language_catalog_generator = @import("language_catalog_generator.zig");
pub const language_catalog_snapshot = @import("language_catalog_snapshot.zig");
pub const language_catalog = @import("language_catalog.zig");
pub const language_stats = @import("language_stats.zig");
pub const page_payload = @import("page_payload.zig");
pub const render = @import("render.zig");

/// Application entry point reserved for process orchestration.
pub fn run(init: std.process.Init) !void {
    _ = init;
}

test {
    _ = config;
    _ = cli;
    _ = @import("dependency_validation.zig");
    _ = @import("process.zig");
    _ = github;
    _ = github_workflow;
    _ = git_activity;
    _ = language_catalog_generator;
    _ = language_catalog_snapshot;
    _ = language_catalog;
    _ = language_stats;
    _ = page_payload;
    _ = render;
}
