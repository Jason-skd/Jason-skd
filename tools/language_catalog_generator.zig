const std = @import("std");
const generator = @import("profile_generator").language_catalog_generator;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.InvalidArguments;

    const input_path = args[1];
    const output_path = args[2];
    const revision = args[3];
    var input_file = try std.Io.Dir.cwd().openFile(init.io, input_path, .{});
    defer input_file.close(init.io);
    var input_reader = input_file.readerStreaming(init.io, &.{});
    const input = try input_reader.interface.allocRemaining(init.gpa, .limited(64 * 1024 * 1024));
    defer init.gpa.free(input);

    const output = try generator.generate(init.gpa, input, .{ .source_revision = revision });
    defer init.gpa.free(output);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = output });
}
