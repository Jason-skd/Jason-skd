const std = @import("std");

pub const config = @import("config.zig");
pub const cli = @import("cli.zig");
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
