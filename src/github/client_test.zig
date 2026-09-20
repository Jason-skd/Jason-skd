//! Deterministic GitHub client tests backed by an injected transport and I/O.

const std = @import("std");

const github = @import("client.zig");

const Client = github.Client;
const FailureKind = github.FailureKind;
const Header = github.Header;
const RawResponse = github.RawResponse;
const Request = github.Request;
const test_user_agent = "github-client-test";

const FakeResponse = struct {
    status: std.http.Status,
    body: []const u8,
    headers: []const Header = &.{},
};

const FakeTransport = struct {
    responses: []const FakeResponse,
    expect_secret: bool = false,
    expect_login_variable: bool = false,
    calls: usize = 0,

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: Request) anyerror!RawResponse {
        const self: *@This() = @ptrCast(@alignCast(context));
        const response = self.responses[@min(self.calls, self.responses.len - 1)];
        self.calls += 1;
        try std.testing.expectEqual(std.http.Method.GET, request.method);
        try std.testing.expect(std.mem.startsWith(u8, request.url, github.rest_base_url));
        try std.testing.expect(request.payload == null);
        try std.testing.expect(hasHeader(request.headers, "Accept", "application/vnd.github+json"));
        try std.testing.expect(hasHeader(request.headers, "X-GitHub-Api-Version", github.api_version));
        try std.testing.expect(hasHeader(request.headers, "User-Agent", test_user_agent));
        if (self.expect_secret) {
            try std.testing.expect(hasHeader(request.headers, "Authorization", "Bearer SECRET"));
        } else {
            try std.testing.expect(!hasHeaderName(request.headers, "Authorization"));
        }
        return RawResponse.init(allocator, response.status, response.headers, response.body);
    }
};

fn hasHeader(headers: []const Header, name: []const u8, value: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name) and std.mem.eql(u8, header.value, value)) return true;
    }
    return false;
}

fn hasHeaderName(headers: []const Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
    }
    return false;
}

fn graphqlFakeSend(context: *anyopaque, allocator: std.mem.Allocator, request: Request) anyerror!RawResponse {
    const self: *FakeTransport = @ptrCast(@alignCast(context));
    try std.testing.expectEqual(std.http.Method.POST, request.method);
    try std.testing.expectEqualStrings(github.graphql_url, request.url);
    try std.testing.expect(request.payload != null);
    try std.testing.expect(std.mem.indexOf(u8, request.payload.?, "Viewer") != null);
    if (self.expect_login_variable) {
        try std.testing.expect(std.mem.indexOf(u8, request.payload.?, "octocat") != null);
    }
    try std.testing.expect(hasHeader(request.headers, "Content-Type", "application/json"));
    const response = self.responses[@min(self.calls, self.responses.len - 1)];
    self.calls += 1;
    return RawResponse.init(allocator, response.status, response.headers, response.body);
}

fn failingSend(_: *anyopaque, _: std.mem.Allocator, _: Request) anyerror!RawResponse {
    return error.ConnectionResetByPeer;
}

fn restAllocationFailure(allocator: std.mem.Allocator) !void {
    const Payload = struct { login: []const u8 };
    const responses = [_]FakeResponse{.{
        .status = .ok,
        .body = "{\"login\":\"octocat\"}",
    }};
    var fake = FakeTransport{ .responses = &responses, .expect_secret = true };
    var client = try Client.initWithTransport(
        allocator,
        std.Io.failing,
        .{ .context = &fake, .send_fn = FakeTransport.send },
        .{
            .token = "SECRET",
            .user_agent = test_user_agent,
        },
    );
    defer client.deinit();

    var result = try client.rest(Payload, "/user");
    defer result.deinit();
    switch (result) {
        .success => |parsed| try std.testing.expectEqualStrings("octocat", parsed.value.login),
        .failure => return error.UnexpectedFailure,
    }
}

test "REST success sends authenticated GitHub headers and typed JSON" {
    const Payload = struct {
        login: []const u8,
        bio: ?[]const u8,
    };
    const responses = [_]FakeResponse{.{
        .status = .ok,
        .body = "{\"login\":\"octocat\",\"bio\":null,\"new_field\":true}",
    }};
    var fake = FakeTransport{ .responses = &responses, .expect_secret = true };
    var client = try Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &fake, .send_fn = FakeTransport.send },
        .{ .token = "SECRET", .user_agent = test_user_agent },
    );
    defer client.deinit();

    var result = try client.rest(Payload, "/user");
    defer result.deinit();
    switch (result) {
        .failure => return error.UnexpectedFailure,
        .success => |parsed| {
            try std.testing.expectEqualStrings("octocat", parsed.value.login);
            try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.bio);
        },
    }
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "retry configuration controls total attempts" {
    const responses = [_]FakeResponse{
        .{ .status = .internal_server_error, .body = "temporary" },
        .{ .status = .internal_server_error, .body = "temporary" },
        .{ .status = .ok, .body = "{\"ok\":true}" },
    };
    const Payload = struct { ok: bool };
    var fake = FakeTransport{ .responses = &responses };
    var client = try Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &fake, .send_fn = FakeTransport.send },
        .{
            .user_agent = test_user_agent,
            .retry = .{ .max_attempts = 3, .initial_backoff = .fromMilliseconds(5) },
        },
    );
    defer client.deinit();

    var result = try client.rest(Payload, "/user");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expect(result == .success);
}

test "retry configuration defaults to three attempts and one second" {
    const retry: github.RetryConfig = .{};
    try std.testing.expectEqual(@as(u8, 3), retry.max_attempts);
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(1), retry.initial_backoff);
}

test "authentication and exhausted rate limit failures remain distinguishable" {
    const Payload = struct { ok: bool };
    const unauthorized_responses = [_]FakeResponse{.{ .status = .unauthorized, .body = "SECRET" }};
    var unauthorized_fake = FakeTransport{ .responses = &unauthorized_responses, .expect_secret = true };
    var unauthorized_client = try Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &unauthorized_fake, .send_fn = FakeTransport.send },
        .{ .token = "SECRET", .user_agent = test_user_agent },
    );
    defer unauthorized_client.deinit();

    var unauthorized = try unauthorized_client.rest(Payload, "/user");
    defer unauthorized.deinit();
    try std.testing.expectEqual(FailureKind.authentication, unauthorized.failure.kind);
    try std.testing.expect(std.mem.indexOf(u8, unauthorized.failure.diagnostic(), "SECRET") == null);
    try std.testing.expectEqual(@as(usize, 1), unauthorized_fake.calls);

    const retry_responses = [_]FakeResponse{.{
        .status = .too_many_requests,
        .body = "token SECRET",
        .headers = &.{
            .{ .name = "X-RateLimit-Limit", .value = "60" },
            .{ .name = "X-RateLimit-Remaining", .value = "0" },
            .{ .name = "X-RateLimit-Reset", .value = "123" },
            .{ .name = "Retry-After", .value = "7" },
            .{ .name = "X-RateLimit-Resource", .value = "core" },
        },
    }};
    var retry_fake = FakeTransport{ .responses = &retry_responses, .expect_secret = true };
    var retry_client = try Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &retry_fake, .send_fn = FakeTransport.send },
        .{
            .token = "SECRET",
            .user_agent = test_user_agent,
            .retry = .{ .max_attempts = 2, .initial_backoff = .zero },
        },
    );
    defer retry_client.deinit();

    var rate_limited = try retry_client.rest(Payload, "/user");
    defer rate_limited.deinit();
    try std.testing.expectEqual(FailureKind.rate_limited, rate_limited.failure.kind);
    try std.testing.expectEqual(@as(?u64, 60), rate_limited.failure.rate_limit.limit);
    try std.testing.expectEqual(@as(?u64, 0), rate_limited.failure.rate_limit.remaining);
    try std.testing.expectEqual(@as(?u64, 7), rate_limited.failure.rate_limit.retry_after);
    try std.testing.expectEqualStrings("core", rate_limited.failure.rate_limit.resource.slice().?);
    try std.testing.expect(std.mem.indexOf(u8, rate_limited.failure.diagnostic(), "SECRET") == null);
    try std.testing.expectEqual(@as(usize, 2), retry_fake.calls);
}

test "GraphQL serializes variables and surfaces errors before invalid partial data" {
    const Payload = struct { viewer: struct { login: []const u8 } };
    const responses = [_]FakeResponse{.{
        .status = .ok,
        .body = "{\"data\":{\"viewer\":{\"login\":42}},\"errors\":[{\"message\":\"token SECRET rejected\"}]}",
    }};
    var fake = FakeTransport{ .responses = &responses, .expect_login_variable = true };
    var client = try Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &fake, .send_fn = graphqlFakeSend },
        .{ .token = "SECRET", .user_agent = test_user_agent },
    );
    defer client.deinit();

    var result = try client.graphql(Payload, "query Viewer { viewer { login } }", .{ .login = "octocat" });
    defer result.deinit();
    try std.testing.expectEqual(FailureKind.graphql, result.failure.kind);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.diagnostic(), "SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.diagnostic(), "rejected") != null);
}

test "transport JSON retryable rate-limit and terminal failures retain separate identities" {
    const Payload = struct { ok: bool };
    var unused_context: u8 = 0;
    var transport_client = try Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &unused_context, .send_fn = failingSend },
        .{ .user_agent = test_user_agent, .retry = .{ .max_attempts = 1 } },
    );
    defer transport_client.deinit();
    var transport_result = try transport_client.rest(Payload, "/user");
    defer transport_result.deinit();
    try std.testing.expectEqual(FailureKind.transport, transport_result.failure.kind);

    const cases = [_]struct {
        response: FakeResponse,
        expected: FailureKind,
    }{
        .{ .response = .{ .status = .not_found, .body = "not found" }, .expected = .terminal_http },
        .{ .response = .{ .status = .forbidden, .body = "forbidden" }, .expected = .terminal_http },
        .{
            .response = .{
                .status = .forbidden,
                .body = "limited",
                .headers = &.{.{ .name = "X-RateLimit-Remaining", .value = "0" }},
            },
            .expected = .rate_limited,
        },
        .{ .response = .{ .status = .service_unavailable, .body = "unavailable" }, .expected = .retryable_http },
        .{ .response = .{ .status = .ok, .body = "not json" }, .expected = .invalid_json },
    };
    for (cases) |case| {
        const responses = [_]FakeResponse{case.response};
        var fake = FakeTransport{ .responses = &responses };
        var client = try Client.initWithTransport(
            std.testing.allocator,
            std.Io.failing,
            .{ .context = &fake, .send_fn = FakeTransport.send },
            .{ .user_agent = test_user_agent, .retry = .{ .max_attempts = 1 } },
        );
        defer client.deinit();

        var result = try client.rest(Payload, "/user");
        defer result.deinit();
        try std.testing.expectEqual(case.expected, result.failure.kind);
    }
}

test "transport failures redact tokens and credential query parameters" {
    const Payload = struct { ok: bool };
    var unused_context: u8 = 0;
    var client = try Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &unused_context, .send_fn = failingSend },
        .{
            .token = "TOKEN_SECRET",
            .user_agent = test_user_agent,
            .retry = .{ .max_attempts = 1 },
        },
    );
    defer client.deinit();

    var result = try client.rest(
        Payload,
        "https://api.github.com/user?access_token=URL_SECRET",
    );
    defer result.deinit();
    try std.testing.expectEqual(FailureKind.transport, result.failure.kind);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.diagnostic(), "TOKEN_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.diagnostic(), "URL_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.diagnostic(), "access_token=***") != null);
}

test "HTTP diagnostics redact a token across the former body summary boundary" {
    const Payload = struct { ok: bool };
    const prefix: [298]u8 = @splat('x');
    const body = try std.fmt.allocPrint(std.testing.allocator, "{s}SECRET suffix", .{&prefix});
    defer std.testing.allocator.free(body);
    const responses = [_]FakeResponse{.{ .status = .unauthorized, .body = body }};
    var fake = FakeTransport{ .responses = &responses, .expect_secret = true };
    var client = try Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &fake, .send_fn = FakeTransport.send },
        .{
            .token = "SECRET",
            .user_agent = test_user_agent,
            .retry = .{ .max_attempts = 1 },
        },
    );
    defer client.deinit();

    var result = try client.rest(Payload, "/user");
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.failure.diagnostic(), "SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.failure.diagnostic(), "***") != null);
}

test "GraphQL success returns typed data with owned strings" {
    const Payload = struct { viewer: struct { login: []const u8 } };
    const responses = [_]FakeResponse{.{
        .status = .ok,
        .body = "{\"data\":{\"viewer\":{\"login\":\"octocat\"}}}",
    }};
    var fake = FakeTransport{ .responses = &responses };
    var client = try Client.initWithTransport(
        std.testing.allocator,
        std.Io.failing,
        .{ .context = &fake, .send_fn = graphqlFakeSend },
        .{ .user_agent = test_user_agent },
    );
    defer client.deinit();

    var result = try client.graphql(Payload, "query Viewer { viewer { login } }", .{});
    defer result.deinit();
    switch (result) {
        .success => |parsed| try std.testing.expectEqualStrings("octocat", parsed.value.viewer.login),
        .failure => return error.UnexpectedFailure,
    }
}

test "GraphQL errors-only and missing data remain distinguishable" {
    const Payload = struct { viewer: struct { login: []const u8 } };
    const cases = [_]struct {
        body: []const u8,
        expected: FailureKind,
    }{
        .{ .body = "{\"errors\":[{\"message\":\"denied\"}]}", .expected = .graphql },
        .{ .body = "{}", .expected = .invalid_json },
    };
    for (cases) |case| {
        const responses = [_]FakeResponse{.{ .status = .ok, .body = case.body }};
        var fake = FakeTransport{ .responses = &responses };
        var client = try Client.initWithTransport(
            std.testing.allocator,
            std.Io.failing,
            .{ .context = &fake, .send_fn = graphqlFakeSend },
            .{ .user_agent = test_user_agent },
        );
        defer client.deinit();

        var result = try client.graphql(Payload, "query Viewer { viewer { login } }", .{});
        defer result.deinit();
        try std.testing.expectEqual(case.expected, result.failure.kind);
    }
}

test "invalid retry configuration headers and foreign REST hosts are rejected" {
    try std.testing.expectError(
        error.InvalidRetryConfig,
        Client.init(std.testing.allocator, std.Io.failing, .{
            .user_agent = test_user_agent,
            .retry = .{ .max_attempts = 0 },
        }),
    );
    try std.testing.expectError(
        error.InvalidHeaderValue,
        Client.init(std.testing.allocator, std.Io.failing, .{
            .token = "SECRET\r\nInjected: true",
            .user_agent = test_user_agent,
        }),
    );

    var client = try Client.init(std.testing.allocator, std.Io.failing, .{ .user_agent = test_user_agent });
    defer client.deinit();
    try std.testing.expectError(error.InvalidUrl, client.rest(struct {}, "https://example.com/private"));
}

test "REST ownership chain cleans up every allocation failure path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, restAllocationFailure, .{});
}
