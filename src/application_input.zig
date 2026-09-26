//! Shared application query bounds and borrowed source-domain values.
const std = @import("std");
const github = @import("github_workflow.zig");
const git = @import("git_activity.zig");

pub const Window = struct {
    since: i64,
    until: i64,

    pub fn init(now_utc: i64, days: u32) error{InvalidWindow}!Window {
        if (days == 0 or now_utc < 0) return error.InvalidWindow;
        const since = std.math.sub(i64, now_utc, @as(i64, days) * 86400) catch return error.InvalidWindow;
        if (since < 0) return error.InvalidWindow;
        return .{ .since = since, .until = now_utc };
    }
};

/// These views remain owned by the selected source until rendering completes.
pub const Data = struct {
    profile: github.Profile,
    organization: ?github.Organization = null,
    repository_metadata: []const github.RepositoryMetadata = &.{},
    activity: git.Aggregate,
};

test "one startup time determines inclusive query bounds" {
    const window = try Window.init(1800000000, 30);
    try std.testing.expectEqual(1797408000, window.since);
    try std.testing.expectEqual(1800000000, window.until);
    try std.testing.expectError(error.InvalidWindow, Window.init(0, 30));
    try std.testing.expectError(error.InvalidWindow, Window.init(1800000000, 0));
}
