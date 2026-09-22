//! Deterministic tests for the typed GitHub profile data source.

const std = @import("std");
const client_module = @import("client.zig");
const model = @import("model.zig");
const profile = @import("profile.zig");

const Client = client_module.Client;
const RawResponse = client_module.RawResponse;
const Request = client_module.Request;
const user_agent = "profile-source-test";

const FakeResponse = struct { body: []const u8 };

const FakeTransport = struct {
    responses: []const FakeResponse,
    calls: usize = 0,
    saw_start: bool = false,
    saw_end: bool = false,
    saw_limit: bool = false,

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: Request) anyerror!RawResponse {
        const self: *@This() = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(std.http.Method.POST, request.method);
        try std.testing.expectEqualStrings(client_module.graphql_url, request.url);
        const payload = request.payload orelse return error.MissingPayload;
        if (std.mem.indexOf(u8, payload, "1970-01-01T00:00:00Z") != null) self.saw_start = true;
        if (std.mem.indexOf(u8, payload, "1970-01-01T00:00:01Z") != null) self.saw_end = true;
        if (std.mem.indexOf(u8, payload, "\"maxRepositories\":2") != null) self.saw_limit = true;
        const response = self.responses[@min(self.calls, self.responses.len - 1)];
        self.calls += 1;
        return RawResponse.init(allocator, .ok, &.{}, response.body);
    }
};

fn initClientWithAllocator(allocator: std.mem.Allocator, fake: *FakeTransport, token: ?[]const u8) !Client {
    return Client.initWithTransport(
        allocator,
        std.Io.failing,
        .{ .context = fake, .send_fn = FakeTransport.send },
        .{ .token = token, .user_agent = user_agent, .retry = .{ .max_attempts = 1 } },
    );
}

fn initClient(fake: *FakeTransport, token: ?[]const u8) !Client {
    return initClientWithAllocator(std.testing.allocator, fake, token);
}

const profile_body =
    "{\"data\":{\"viewer\":{\"login\":\"target-user\",\"repositories\":{" ++
    "\"nodes\":[{\"name\":\"alpha\",\"nameWithOwner\":\"target-user/alpha\",\"description\":null," ++
    "\"isPrivate\":false,\"stargazerCount\":4,\"primaryLanguage\":{\"name\":\"Zig\"}}]," ++
    "\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}," ++
    "\"contributionsCollection\":{\"totalCommitContributions\":4,\"totalIssueContributions\":2," ++
    "\"totalPullRequestContributions\":1,\"totalPullRequestReviewContributions\":3," ++
    "\"totalRepositoryContributions\":1,\"restrictedContributionsCount\":2," ++
    "\"contributionCalendar\":{\"totalContributions\":10,\"weeks\":[{" ++
    "\"contributionDays\":[{\"contributionCount\":1},{\"contributionCount\":0}]}]}," ++
    "\"commitContributionsByRepository\":[{" ++
    "\"repository\":{\"nameWithOwner\":\"z-org/zeta\",\"isPrivate\":false,\"owner\":{\"login\":\"z-org\"}}},{" ++
    "\"repository\":{\"nameWithOwner\":\"A-org/alpha\",\"isPrivate\":false,\"owner\":{\"login\":\"A-org\"}}},{" ++
    "\"repository\":{\"nameWithOwner\":\"a-org/alpha\",\"isPrivate\":false,\"owner\":{\"login\":\"a-org\"}}}]}}}}";

const empty_contributions =
    "\"contributionsCollection\":{\"totalCommitContributions\":0,\"totalIssueContributions\":0," ++
    "\"totalPullRequestContributions\":0,\"totalPullRequestReviewContributions\":0," ++
    "\"totalRepositoryContributions\":0,\"restrictedContributionsCount\":0," ++
    "\"contributionCalendar\":{\"totalContributions\":0,\"weeks\":[]}," ++
    "\"commitContributionsByRepository\":[]}";

const fallback_viewer_body =
    "{\"data\":{\"viewer\":{\"login\":\"different-user\",\"repositories\":{" ++
    "\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}," ++ empty_contributions ++ "}}}";

const fallback_user_body =
    "{\"data\":{\"user\":{\"login\":\"target-user\",\"repositories\":{" ++
    "\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}," ++ empty_contributions ++ "}}}";

const page_one_body =
    "{\"data\":{\"viewer\":{\"login\":\"target-user\",\"repositories\":{" ++
    "\"nodes\":[],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"cursor-1\"}}," ++ empty_contributions ++ "}}}";

const page_two_body =
    "{\"data\":{\"viewer\":{\"repositories\":{" ++
    "\"nodes\":[{\"name\":\"beta\",\"nameWithOwner\":\"target-user/beta\",\"description\":\"second\"," ++
    "\"isPrivate\":true,\"stargazerCount\":0,\"primaryLanguage\":null}]," ++
    "\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}";

test "profile source maps facts, sorts and deduplicates contributed repositories" {
    var fake = FakeTransport{ .responses = &.{.{ .body = profile_body }} };
    var client = try initClient(&fake, "token");
    defer client.deinit();

    var result = try profile.fetchProfile(&client, std.testing.allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 1,
        .max_contributed_repositories = 2,
    });
    defer result.deinit();

    try std.testing.expect(fake.saw_start);
    try std.testing.expect(fake.saw_end);
    try std.testing.expect(fake.saw_limit);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| {
            try std.testing.expectEqual(model.Access.authenticated_as_target, owned.value.access);
            try std.testing.expectEqual(@as(u32, 1), owned.value.contributions.active_days);
            try std.testing.expectEqual(@as(usize, 1), owned.value.owned_repositories.len);
            try std.testing.expectEqual(@as(usize, 2), owned.value.contributed_repositories.len);
            try std.testing.expectEqualStrings("A-org/alpha", owned.value.contributed_repositories[0].name_with_owner);
            try std.testing.expectEqualStrings("z-org/zeta", owned.value.contributed_repositories[1].name_with_owner);
        },
    }
}

test "profile source falls back from viewer identity to public user" {
    var fake = FakeTransport{ .responses = &.{
        .{ .body = fallback_viewer_body },
        .{ .body = fallback_user_body },
    } };
    var client = try initClient(&fake, "token");
    defer client.deinit();

    var result = try profile.fetchProfile(&client, std.testing.allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 0,
        .max_contributed_repositories = 1,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| try std.testing.expectEqual(model.Access.public_only, owned.value.access),
    }
}

test "profile source follows owned repository cursors" {
    var fake = FakeTransport{ .responses = &.{
        .{ .body = page_one_body },
        .{ .body = page_two_body },
    } };
    var client = try initClient(&fake, "token");
    defer client.deinit();

    var result = try profile.fetchProfile(&client, std.testing.allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 0,
        .max_contributed_repositories = 0,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| {
            try std.testing.expectEqual(@as(usize, 1), owned.value.owned_repositories.len);
            try std.testing.expectEqualStrings("target-user/beta", owned.value.owned_repositories[0].name_with_owner);
        },
    }
}

test "profile source distinguishes missing credentials and invalid options" {
    var fake = FakeTransport{ .responses = &.{.{ .body = profile_body }} };
    var client = try initClient(&fake, null);
    defer client.deinit();

    var missing = try profile.fetchProfile(&client, std.testing.allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 0,
        .max_contributed_repositories = 1,
    });
    defer missing.deinit();
    try std.testing.expect(missing == .failure);
    try std.testing.expect(missing.failure.cause == .missing_credential);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    try std.testing.expectError(error.InvalidOptions, profile.fetchProfile(&client, std.testing.allocator, .{
        .login = "target-user",
        .since = 2,
        .until = 1,
        .max_contributed_repositories = 1,
    }));
    try std.testing.expectError(error.InvalidOptions, profile.fetchProfile(&client, std.testing.allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 0,
        .max_contributed_repositories = 101,
    }));
}

test "profile source preserves GraphQL failures as structured data" {
    var fake = FakeTransport{ .responses = &.{.{ .body = "{\"errors\":[{\"message\":\"access denied\"}]}" }} };
    var client = try initClient(&fake, "token");
    defer client.deinit();

    var result = try profile.fetchProfile(&client, std.testing.allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 0,
        .max_contributed_repositories = 1,
    });
    defer result.deinit();
    try std.testing.expect(result == .failure);
    try std.testing.expect(result.failure.cause == .github);
    try std.testing.expectEqualStrings("target-user", result.failure.subject());
}

test "profile result does not borrow options or response storage" {
    const response_buffer = try std.testing.allocator.dupe(u8, profile_body);
    const login_buffer = try std.testing.allocator.dupe(u8, "target-user");
    var fake = FakeTransport{ .responses = &.{.{ .body = response_buffer }} };
    var client = try initClient(&fake, "token");
    defer client.deinit();

    var result = try profile.fetchProfile(&client, std.testing.allocator, .{
        .login = login_buffer,
        .since = 0,
        .until = 0,
        .max_contributed_repositories = 1,
    });
    defer result.deinit();
    @memset(response_buffer, 'x');
    @memset(login_buffer, 'x');
    std.testing.allocator.free(response_buffer);
    std.testing.allocator.free(login_buffer);

    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| {
            try std.testing.expectEqualStrings("target-user", owned.value.login);
            try std.testing.expectEqualStrings("target-user/alpha", owned.value.owned_repositories[0].name_with_owner);
        },
    }
}

test "profile source reports missing users and malformed pagination" {
    var missing_fake = FakeTransport{ .responses = &.{
        .{ .body = fallback_viewer_body },
        .{ .body = "{\"data\":{\"user\":null}}" },
    } };
    var missing_client = try initClient(&missing_fake, "token");
    defer missing_client.deinit();
    var missing = try profile.fetchProfile(&missing_client, std.testing.allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 0,
        .max_contributed_repositories = 1,
    });
    defer missing.deinit();
    try std.testing.expect(missing == .failure);
    try std.testing.expect(missing.failure.cause == .not_found);

    const no_cursor =
        "{\"data\":{\"viewer\":{\"login\":\"target-user\",\"repositories\":{" ++
        "\"nodes\":[],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":null}}," ++ empty_contributions ++ "}}}";
    var cursor_fake = FakeTransport{ .responses = &.{.{ .body = no_cursor }} };
    var cursor_client = try initClient(&cursor_fake, "token");
    defer cursor_client.deinit();
    var malformed = try profile.fetchProfile(&cursor_client, std.testing.allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 0,
        .max_contributed_repositories = 1,
    });
    defer malformed.deinit();
    try std.testing.expect(malformed == .failure);
    try std.testing.expectEqual(model.InvalidResponse.malformed_pagination, malformed.failure.cause.invalid_response);
}

test "profile source rejects missing required fields and ignores unrelated fields" {
    const missing_login = "{\"data\":{\"viewer\":{\"repositories\":{\"nodes\":[]," ++
        "\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}," ++ empty_contributions ++ "}}}";
    var missing_fake = FakeTransport{ .responses = &.{.{ .body = missing_login }} };
    var missing_client = try initClient(&missing_fake, "token");
    defer missing_client.deinit();
    var missing = try profile.fetchProfile(&missing_client, std.testing.allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 0,
        .max_contributed_repositories = 1,
    });
    defer missing.deinit();
    try std.testing.expect(missing == .failure);
    try std.testing.expectEqual(client_module.FailureKind.invalid_json, missing.failure.cause.github.kind);

    const with_future_field = profile_body[0 .. profile_body.len - 4] ++ ",\"future\":true}}}}";
    var future_fake = FakeTransport{ .responses = &.{.{ .body = with_future_field }} };
    var future_client = try initClient(&future_fake, "token");
    defer future_client.deinit();
    var future = try profile.fetchProfile(&future_client, std.testing.allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 0,
        .max_contributed_repositories = 1,
    });
    defer future.deinit();
    try std.testing.expect(future == .success);
}

fn profileAllocationFailure(allocator: std.mem.Allocator) !void {
    var fake = FakeTransport{ .responses = &.{.{ .body = profile_body }} };
    var client = try initClientWithAllocator(allocator, &fake, "token");
    defer client.deinit();
    var result = try profile.fetchProfile(&client, allocator, .{
        .login = "target-user",
        .since = 0,
        .until = 1,
        .max_contributed_repositories = 2,
    });
    defer result.deinit();
    if (result == .failure) return error.UnexpectedFailure;
}

test "profile source cleans up every allocation failure path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, profileAllocationFailure, .{});
}
