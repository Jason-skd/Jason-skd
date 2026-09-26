//! Delivers a completed page without exposing an incomplete target file.
const std = @import("std");

pub fn deliver(io: std.Io, path: []const u8, markdown: []const u8, dry_run: bool, stdout: *std.Io.Writer) !void {
    if (dry_run) {
        try stdout.writeAll(markdown);
        try stdout.flush();
        return;
    }
    if (path.len == 0 or path[path.len - 1] == '/' or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidOutputPath;
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) return error.InvalidOutputPath;
    const dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{});
    defer dir.close(io);
    try replace(io, dir, basename, markdown);
}

fn replace(io: std.Io, dir: std.Io.Dir, basename: []const u8, markdown: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, basename, .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    writer.interface.writeAll(markdown) catch return writer.err.?;
    try writer.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

test "dry run writes all bytes without opening the target" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try deliver(std.testing.io, "/nonexistent/parent/README.md", "complete page\n", true, &writer.writer);
    try std.testing.expectEqualStrings("complete page\n", writer.written());
    var failing = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, deliver(std.testing.io, "unused", "page", true, &failing));
}

test "atomic replacement and failed replacement leave no temporary files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "old" });
    try replace(io, tmp.dir, "README.md", "new");
    const bytes = try tmp.dir.readFileAlloc(io, "README.md", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("new", bytes);
    try tmp.dir.createDir(io, "blocked", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked/old", .data = "preserved" });
    if (replace(io, tmp.dir, "blocked", "new")) |_| return error.ExpectedFailure else |_| {}
    var iterator = tmp.dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    try std.testing.expectEqual(2, count);
    const old = try tmp.dir.readFileAlloc(io, "blocked/old", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(old);
    try std.testing.expectEqualStrings("preserved", old);
}

test "flush sync rename and cancellation failures preserve old file and clean temporary state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const Fault = struct {
        fn write(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
            return error.NoSpaceLeft;
        }
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
        fn rename(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
            return error.AccessDenied;
        }
        fn cancel(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.Canceled;
        }
    };
    for (0..4) |index| {
        try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "old" });
        var vtable = io.vtable.*;
        const expected: anyerror = switch (index) {
            0 => blk: {
                vtable.fileWritePositional = Fault.write;
                break :blk error.NoSpaceLeft;
            },
            1 => blk: {
                vtable.fileSync = Fault.sync;
                break :blk error.InputOutput;
            },
            2 => blk: {
                vtable.dirRename = Fault.rename;
                break :blk error.AccessDenied;
            },
            else => blk: {
                vtable.fileSync = Fault.cancel;
                break :blk error.Canceled;
            },
        };
        var failing_io = io;
        failing_io.vtable = &vtable;
        try std.testing.expectError(expected, replace(failing_io, tmp.dir, "README.md", "new"));
        const bytes = try tmp.dir.readFileAlloc(io, "README.md", std.testing.allocator, .limited(100));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("old", bytes);
        var iterator = tmp.dir.iterate();
        var count: usize = 0;
        while (try iterator.next(io)) |_| count += 1;
        try std.testing.expectEqual(1, count);
    }
}
