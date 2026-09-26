//! Offline source-domain snapshot. Never opens a repository or an HTTP client.
const std = @import("std");
const input = @import("application_input.zig");

pub const Snapshot = struct {
    now_utc: i64,
    /// Null models failure to obtain the required profile.
    data: ?input.Data,
};

/// Returned JSON owns every byte; the file buffer can be released immediately.
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(Snapshot) {
    const dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const bytes = try dir.readFileAlloc(io, "data.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
}
