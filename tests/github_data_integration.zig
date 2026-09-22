//! Public API tests backed by embedded GitHub response fixtures.

const std = @import("std");
const github = @import("profile_generator").github;
const github_workflow = @import("profile_generator").github_workflow;

test "client and workflow remain separate public modules" {
    try std.testing.expect(!@hasDecl(github, "Profile"));
    try std.testing.expect(!@hasDecl(github, "fetchProfile"));
    try std.testing.expect(!@hasDecl(github_workflow, "Client"));
    try std.testing.expect(@hasDecl(github_workflow, "Profile"));
    try std.testing.expect(@hasDecl(github_workflow, "fetchProfile"));
}

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

const RestFixtureTransport = struct {
    body: []const u8,
    expected_path: []const u8,

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: github.Request) anyerror!github.RawResponse {
        const self: *@This() = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(std.http.Method.GET, request.method);
        try std.testing.expect(std.mem.endsWith(u8, request.url, self.expected_path));
        return github.RawResponse.init(allocator, .ok, &.{}, self.body);
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
    var result = try github_workflow.fetchProfile(&client, std.testing.allocator, .{
        .login = "profile-owner",
        .since = 0,
        .until = 1,
        .max_contributed_repositories = 100,
    });
    defer result.deinit();

    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| {
            try std.testing.expectEqual(github_workflow.Access.authenticated_as_target, owned.value.access);
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
    var result = try github_workflow.fetchProfile(&client, std.testing.allocator, .{
        .login = "profile-owner",
        .since = 0,
        .until = 1,
        .max_contributed_repositories = 100,
    });
    defer result.deinit();

    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| {
            try std.testing.expectEqual(github_workflow.Access.public_only, owned.value.access);
            try std.testing.expect(!owned.value.owned_repositories[0].is_private);
            try std.testing.expectEqual(@as(usize, 2), transport.calls);
        },
    }
}

test "public API returns organization and repository REST facts" {
    var organization_transport = RestFixtureTransport{
        .body = @embedFile("fixtures/github/organization.json"),
        .expected_path = "/orgs/sample-org",
    };
    var organization_client = try github.Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &organization_transport, .send_fn = RestFixtureTransport.send },
        .{ .user_agent = "github-data-integration", .retry = .{ .max_attempts = 1 } },
    );
    defer organization_client.deinit();
    var organization = try github_workflow.fetchOrganization(&organization_client, std.testing.allocator, "sample-org");
    defer organization.deinit();
    switch (organization) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| try std.testing.expectEqualStrings("Sample Organization", owned.value.display_name.?),
    }

    var repository_transport = RestFixtureTransport{
        .body = @embedFile("fixtures/github/repository.json"),
        .expected_path = "/repos/sample-org/sample-project",
    };
    var repository_client = try github.Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &repository_transport, .send_fn = RestFixtureTransport.send },
        .{ .user_agent = "github-data-integration", .retry = .{ .max_attempts = 1 } },
    );
    defer repository_client.deinit();
    var repository = try github_workflow.fetchRepositoryMetadata(
        &repository_client,
        std.testing.allocator,
        "sample-org/sample-project",
    );
    defer repository.deinit();
    switch (repository) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| try std.testing.expectEqualStrings("Zig", owned.value.primary_language.?),
    }
}
