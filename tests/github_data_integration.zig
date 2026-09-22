//! Public API tests backed by embedded GitHub response fixtures.

const std = @import("std");
const github = @import("profile_generator").github;

const FixtureTransport = struct {
    bodies: []const []const u8,
    calls: usize = 0,

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: github.Request) anyerror!github.RawResponse {
        const self: *@This() = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(std.http.Method.POST, request.method);
        const body = self.bodies[@min(self.calls, self.bodies.len - 1)];
        self.calls += 1;
        return github.RawResponse.init(allocator, .ok, &.{}, body);
    }
};

fn initClient(transport: *FixtureTransport) !github.Client {
    return github.Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = transport, .send_fn = FixtureTransport.send },
        .{ .token = "fixture-token", .user_agent = "github-data-integration", .retry = .{ .max_attempts = 1 } },
    );
}

test "public API returns private facts for the authenticated target" {
    var transport = FixtureTransport{ .bodies = &.{@embedFile("fixtures/github/profile_owner.json")} };
    var client = try initClient(&transport);
    defer client.deinit();
    var result = try github.fetchProfile(&client, std.testing.allocator, .{
        .login = "profile-owner",
        .since = 0,
        .until = 1,
        .max_contributed_repositories = 100,
    });
    defer result.deinit();

    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| {
            try std.testing.expectEqual(github.Access.authenticated_as_target, owned.value.access);
            try std.testing.expect(owned.value.owned_repositories[0].is_private);
            try std.testing.expectEqual(@as(u64, 5), owned.value.contributions.viewer_inaccessible);
            try std.testing.expectEqualStrings(
                "external-org/shared-project",
                owned.value.contributed_repositories[0].name_with_owner,
            );
        },
    }
}

test "public API returns public-only facts after identity fallback" {
    var transport = FixtureTransport{ .bodies = &.{
        @embedFile("fixtures/github/profile_other_viewer.json"),
        @embedFile("fixtures/github/profile_public_user.json"),
    } };
    var client = try initClient(&transport);
    defer client.deinit();
    var result = try github.fetchProfile(&client, std.testing.allocator, .{
        .login = "profile-owner",
        .since = 0,
        .until = 1,
        .max_contributed_repositories = 100,
    });
    defer result.deinit();

    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| {
            try std.testing.expectEqual(github.Access.public_only, owned.value.access);
            try std.testing.expect(!owned.value.owned_repositories[0].is_private);
            try std.testing.expectEqual(@as(usize, 2), transport.calls);
        },
    }
}
