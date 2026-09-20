const std = @import("std");

/// CLI parsing, diagnostics, and credential resolution.
pub const cli = @import("cli.zig");

/// Application entry point reserved for process orchestration.
pub fn run(init: std.process.Init) !void {
    _ = init;
}

test {
    _ = cli;
    _ = @import("dependency_validation.zig");
}
