//! Tests for owned GitHub data-source values and failures.

const std = @import("std");
const model = @import("model.zig");

test "data failure owns bounded subject context" {
    var source: [300]u8 = @splat('a');
    const failure = model.DataFailure.init(.profile, .missing_credential, &source);
    @memset(&source, 'x');

    try std.testing.expectEqual(@as(usize, 256), failure.subject().len);
    try std.testing.expectEqual(@as(u8, 'a'), failure.subject()[0]);
    try std.testing.expectEqual(@as(u8, 'a'), failure.subject()[255]);
}

test "owned result releases independent domain storage" {
    var owned = try model.initOwned(model.Organization, std.testing.allocator);
    const allocator = owned.arena.allocator();
    owned.value = .{
        .login = try allocator.dupe(u8, "sample-org"),
        .display_name = null,
        .avatar_url = try allocator.dupe(u8, "https://example.test/avatar"),
        .html_url = try allocator.dupe(u8, "https://example.test/org"),
    };
    var result: model.OrganizationResult = .{ .success = owned };
    result.deinit();
}
