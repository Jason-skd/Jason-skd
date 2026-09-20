const std = @import("std");

/// Profile YAML parsing, validation, and normalized configuration types.
pub const config = @import("config.zig");

/// CLI parsing, diagnostics, and credential resolution.
pub const cli = @import("cli.zig");

/// GitHub API integration used by the profile generator.
pub const github = @import("github.zig");

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
}
