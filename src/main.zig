const std = @import("std");

const profile_generator = @import("profile_generator");

/// Transfers Zig's process-startup resources to the application module.
pub fn main(init: std.process.Init) !void {
    try profile_generator.run(init);
}
