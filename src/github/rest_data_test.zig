//! Deterministic tests for REST-backed GitHub data sources.

const std = @import("std");
const client_module = @import("client.zig");
const model = @import("model.zig");
const rest_data = @import("rest_data.zig");

const FakeResponse = struct {
    status: std.http.Status,
    body: []const u8,
};

const FakeTransport = struct {
    response: FakeResponse,
    expected_path: []const u8,
    calls: usize = 0,

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: client_module.Request) anyerror!client_module.RawResponse {
        const self: *@This() = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(std.http.Method.GET, request.method);
        try std.testing.expect(std.mem.endsWith(u8, request.url, self.expected_path));
        self.calls += 1;
        return client_module.RawResponse.init(allocator, self.response.status, &.{}, self.response.body);
    }
};

fn initClient(fake: *FakeTransport, allocator: std.mem.Allocator) !client_module.Client {
    return client_module.Client.initWithTransport(
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
    var result = try rest_data.fetchOrganization(&client, std.testing.allocator, "sample-org");
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
    var result = try rest_data.fetchRepositoryMetadata(&client, std.testing.allocator, "sample-owner/sample-repo");
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
    var missing = try rest_data.fetchOrganization(&client, std.testing.allocator, "missing-org");
    defer missing.deinit();
    try std.testing.expect(missing == .failure);
    try std.testing.expect(missing.failure.cause == .not_found);

    try std.testing.expectError(error.InvalidOptions, rest_data.fetchOrganization(&client, std.testing.allocator, "../org"));
    try std.testing.expectError(error.InvalidOptions, rest_data.fetchRepositoryMetadata(&client, std.testing.allocator, "owner/repo/extra"));
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
    var result = try rest_data.fetchRepositoryMetadata(&client, std.testing.allocator, "sample-owner/sample-repo");
    defer result.deinit();
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(model.InvalidResponse.invalid_repository_identity, result.failure.cause.invalid_response);
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
    var result = try rest_data.fetchOrganization(&client, allocator, "sample-org");
    defer result.deinit();
    if (result == .failure) return error.UnexpectedFailure;
}

test "organization source cleans up every allocation failure path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, organizationAllocationFailure, .{});
}
