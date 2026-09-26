const std = @import("std");

const profile_generator = @import("profile_generator");

/// Transfers Zig's process-startup resources to the application module.
pub fn main(init: std.process.Init) u8 {
    return profile_generator.run(init);
}
