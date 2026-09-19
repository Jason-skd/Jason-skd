const std = @import("std");

pub fn run(init: std.process.Init) !void {
    _ = init;
}

test {
    _ = @import("dependency_validation.zig");
}
