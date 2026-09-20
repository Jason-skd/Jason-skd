const std = @import("std");

pub const config = @import("config.zig");

pub fn run(init: std.process.Init) !void {
    _ = init;
}

test {
    _ = config;
    _ = @import("dependency_validation.zig");
}
