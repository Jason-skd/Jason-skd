const std = @import("std");

const profile_generator = @import("profile_generator");

pub fn main(init: std.process.Init) !void {
    try profile_generator.run(init);
}
