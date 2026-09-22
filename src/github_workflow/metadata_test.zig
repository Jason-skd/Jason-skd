//! Deterministic tests for REST-backed GitHub data sources.

const std = @import("std");
const github = @import("../github.zig");
const model = @import("model.zig");
const metadata = @import("metadata.zig");

const FakeResponse = struct {
    status: std.http.Status,
    body: []const u8,
};

const FakeTransport = struct {
    response: FakeResponse,
    expected_path: []const u8,
    calls: usize = 0,

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: github.Request) anyerror!github.RawResponse {
        const self: *@This() = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(std.http.Method.GET, request.method);
        try std.testing.expect(std.mem.endsWith(u8, request.url, self.expected_path));
        self.calls += 1;
        return github.RawResponse.init(allocator, self.response.status, &.{}, self.response.body);
    }
};

fn initClient(fake: *FakeTransport, allocator: std.mem.Allocator) !github.Client {
    return github.Client.initWithTransport(
        allocator,
        std.Io.failing,
        .{ .context = fake, .send_fn = FakeTransport.send },
        .{ .user_agent = "rest-data-test", .retry = .{ .max_attempts = 1 } },
    );
}

test "organization source returns independently owned facts" {
    const source = try std.testing.allocator.dupe(u8, "{\"login\":\"sample-org\",\"name\":null,\"avatar_url\":\"https://example.test/avatar\"," ++
        "\"html_url\":\"https://example.test/org\",\"future\":true}");
    var fake = FakeTransport{
        .response = .{ .status = .ok, .body = source },
        .expected_path = "/orgs/sample-org",
    };
    var client = try initClient(&fake, std.testing.allocator);
    defer client.deinit();
    var result = try metadata.fetchOrganization(&client, std.testing.allocator, "sample-org");
    defer result.deinit();
    @memset(source, 'x');
    std.testing.allocator.free(source);

    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| {
            try std.testing.expectEqualStrings("sample-org", owned.value.login);
            try std.testing.expect(owned.value.display_name == null);
        },
    }
}

test "repository source maps supplemental metadata" {
    var fake = FakeTransport{
        .response = .{
            .status = .ok,
            .body = "{\"full_name\":\"sample-owner/sample-repo\",\"description\":\"fixture\",\"language\":\"Zig\"}",
        },
        .expected_path = "/repos/sample-owner/sample-repo",
    };
    var client = try initClient(&fake, std.testing.allocator);
    defer client.deinit();
    var result = try metadata.fetchRepositoryMetadata(&client, std.testing.allocator, "sample-owner/sample-repo");
    defer result.deinit();

    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |owned| {
            try std.testing.expectEqualStrings("fixture", owned.value.description.?);
            try std.testing.expectEqualStrings("Zig", owned.value.primary_language.?);
        },
    }
}

test "REST sources normalize not found and reject unsafe identities" {
    var fake = FakeTransport{
        .response = .{ .status = .not_found, .body = "not found" },
        .expected_path = "/orgs/missing-org",
    };
    var client = try initClient(&fake, std.testing.allocator);
    defer client.deinit();
    var missing = try metadata.fetchOrganization(&client, std.testing.allocator, "missing-org");
    defer missing.deinit();
    try std.testing.expect(missing == .failure);
    try std.testing.expect(missing.failure.cause == .not_found);

    try std.testing.expectError(error.InvalidOptions, metadata.fetchOrganization(&client, std.testing.allocator, "."));
    try std.testing.expectError(error.InvalidOptions, metadata.fetchOrganization(&client, std.testing.allocator, ".."));
    try std.testing.expectError(error.InvalidOptions, metadata.fetchOrganization(&client, std.testing.allocator, "../org"));
    try std.testing.expectError(error.InvalidOptions, metadata.fetchRepositoryMetadata(&client, std.testing.allocator, "owner/."));
    try std.testing.expectError(error.InvalidOptions, metadata.fetchRepositoryMetadata(&client, std.testing.allocator, "owner/.."));
    try std.testing.expectError(error.InvalidOptions, metadata.fetchRepositoryMetadata(&client, std.testing.allocator, "owner/repo/extra"));
}

test "REST sources reject response identity mismatches" {
    var fake = FakeTransport{
        .response = .{
            .status = .ok,
            .body = "{\"full_name\":\"other-owner/other-repo\",\"description\":null,\"language\":null}",
        },
        .expected_path = "/repos/sample-owner/sample-repo",
    };
    var client = try initClient(&fake, std.testing.allocator);
    defer client.deinit();
    var result = try metadata.fetchRepositoryMetadata(&client, std.testing.allocator, "sample-owner/sample-repo");
    defer result.deinit();
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(model.InvalidResponse.invalid_repository_identity, result.failure.cause.invalid_response);
}

test "REST sources reject missing required fields and preserve GitHub failure context" {
    var invalid_fake = FakeTransport{
        .response = .{
            .status = .ok,
            .body = "{\"login\":\"sample-org\",\"name\":null,\"html_url\":\"https://example.test/org\"}",
        },
        .expected_path = "/orgs/sample-org",
    };
    var invalid_client = try initClient(&invalid_fake, std.testing.allocator);
    defer invalid_client.deinit();
    var invalid = try metadata.fetchOrganization(&invalid_client, std.testing.allocator, "sample-org");
    defer invalid.deinit();
    try std.testing.expect(invalid == .failure);
    try std.testing.expectEqual(model.DataOperation.organization, invalid.failure.operation);
    try std.testing.expectEqual(github.FailureKind.invalid_json, invalid.failure.cause.github.kind);
    try std.testing.expectEqualStrings("sample-org", invalid.failure.subject());

    var failed_fake = FakeTransport{
        .response = .{ .status = .internal_server_error, .body = "temporarily unavailable" },
        .expected_path = "/repos/sample-owner/sample-repo",
    };
    var failed_client = try initClient(&failed_fake, std.testing.allocator);
    defer failed_client.deinit();
    var failed = try metadata.fetchRepositoryMetadata(&failed_client, std.testing.allocator, "sample-owner/sample-repo");
    defer failed.deinit();
    try std.testing.expect(failed == .failure);
    try std.testing.expectEqual(model.DataOperation.repository_metadata, failed.failure.operation);
    try std.testing.expectEqual(github.FailureKind.retryable_http, failed.failure.cause.github.kind);
    try std.testing.expectEqualStrings("sample-owner/sample-repo", failed.failure.subject());
}

fn organizationAllocationFailure(allocator: std.mem.Allocator) !void {
    var fake = FakeTransport{
        .response = .{
            .status = .ok,
            .body = "{\"login\":\"sample-org\",\"name\":\"Sample\",\"avatar_url\":\"https://example.test/avatar\"," ++
                "\"html_url\":\"https://example.test/org\"}",
        },
        .expected_path = "/orgs/sample-org",
    };
    var client = try initClient(&fake, allocator);
    defer client.deinit();
    var result = try metadata.fetchOrganization(&client, allocator, "sample-org");
    defer result.deinit();
    if (result == .failure) return error.UnexpectedFailure;
}

test "organization source cleans up every allocation failure path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, organizationAllocationFailure, .{});
}
