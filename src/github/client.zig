//! Owns GitHub client configuration and orchestrates REST and GraphQL requests.

const std = @import("std");

const failures = @import("failure.zig");
const response_parser = @import("response.zig");
const retry = @import("retry.zig");
const transport = @import("transport.zig");

/// GitHub's GraphQL endpoint.
pub const graphql_url = "https://api.github.com/graphql";
/// Base URL used to resolve relative REST paths.
pub const rest_base_url = "https://api.github.com";
/// Default product identifier sent in the HTTP User-Agent header.
pub const default_user_agent = "Jason-skd-profile-gen";
/// GitHub REST API version requested by this client.
pub const api_version = "2022-11-28";

/// One HTTP header passed across the injectable transport boundary.
pub const Header = transport.Header;
/// A complete request passed to an injected transport.
pub const Request = transport.Request;
/// Type-erased request executor used by deterministic tests.
pub const Transport = transport.Transport;
/// An owned transport response used by custom transports.
pub const RawResponse = transport.RawResponse;
/// GitHub rate-limit metadata parsed from response headers.
pub const RateLimit = transport.RateLimit;
/// Stable failure categories returned to callers.
pub const FailureKind = failures.FailureKind;
/// A structured, secret-safe failure.
pub const Failure = failures.Failure;
/// Either an owned typed value or a structured GitHub failure.
pub const Result = failures.Result;

/// Retry policy whose attempt count includes the initial request.
pub const RetryConfig = retry.Config;

/// Type-erased wait operation used to make retry tests deterministic.
pub const Waiter = retry.Waiter;

/// Dependencies and policy used to initialize a GitHub client.
pub const Config = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    token: ?[]const u8 = null,
    user_agent: []const u8 = default_user_agent,
    retry: RetryConfig = .{},
    transport: ?Transport = null,
    waiter: ?Waiter = null,
};

/// Typed GitHub REST and GraphQL client with owned transport resources.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    token: ?[]u8,
    bearer: ?[]u8,
    user_agent: []u8,
    retry: RetryConfig,
    injected_transport: ?Transport,
    waiter: ?Waiter,
    standard_transport: transport.Std,

    /// Initializes the client and copies credential and User-Agent data.
    pub fn init(config: Config) !Client {
        if (config.retry.max_attempts == 0 or config.retry.initial_backoff.nanoseconds < 0) {
            return error.InvalidRetryConfig;
        }
        if (containsNewline(config.user_agent) or
            (config.token != null and containsNewline(config.token.?)))
        {
            return error.InvalidHeaderValue;
        }

        const token = if (config.token) |value| try config.allocator.dupe(u8, value) else null;
        errdefer if (token) |value| config.allocator.free(value);

        const bearer = if (token) |value|
            try std.fmt.allocPrint(config.allocator, "Bearer {s}", .{value})
        else
            null;
        errdefer if (bearer) |value| config.allocator.free(value);

        const user_agent = try config.allocator.dupe(u8, config.user_agent);
        errdefer config.allocator.free(user_agent);

        return .{
            .allocator = config.allocator,
            .io = config.io,
            .token = token,
            .bearer = bearer,
            .user_agent = user_agent,
            .retry = config.retry,
            .injected_transport = config.transport,
            .waiter = config.waiter,
            .standard_transport = .init(config.allocator, config.io),
        };
    }

    /// Releases the standard HTTP client, credential copies, and User-Agent.
    pub fn deinit(self: *Client) void {
        self.standard_transport.deinit();
        if (self.bearer) |value| self.allocator.free(value);
        if (self.token) |value| self.allocator.free(value);
        self.allocator.free(self.user_agent);
        self.* = undefined;
    }

    /// Performs a REST GET and parses its successful body into `T`.
    pub fn rest(self: *Client, comptime T: type, path_or_url: []const u8) !Result(T) {
        const url = try self.resolveRestUrl(path_or_url);
        defer self.allocator.free(url);

        const outcome = try self.perform(.GET, url, null);
        return switch (outcome) {
            .failure => |failure| .{ .failure = failure },
            .response => |response_value| response_parser.parseRest(
                T,
                self.allocator,
                self.token,
                response_value,
                url,
            ),
        };
    }

    /// Performs a GraphQL POST and parses the response `data` member into `T`.
    ///
    /// Retryable failures may resend the POST, so callers must use this helper
    /// only for operations that are safe to execute more than once.
    pub fn graphql(self: *Client, comptime T: type, query: []const u8, variables: anytype) !Result(T) {
        const payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .query = query,
            .variables = variables,
        }, .{});
        defer self.allocator.free(payload);

        const outcome = try self.perform(.POST, graphql_url, payload);
        return switch (outcome) {
            .failure => |failure| .{ .failure = failure },
            .response => |response_value| response_parser.parseGraphql(
                T,
                self.allocator,
                self.token,
                response_value,
                graphql_url,
            ),
        };
    }

    fn resolveRestUrl(self: *Client, path_or_url: []const u8) ![]u8 {
        if (std.mem.startsWith(u8, path_or_url, "/")) {
            return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ rest_base_url, path_or_url });
        }

        const uri = std.Uri.parse(path_or_url) catch return error.InvalidUrl;
        const host = uri.host orelse return error.InvalidUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or
            !std.ascii.eqlIgnoreCase(host.percent_encoded, "api.github.com") or
            uri.user != null or uri.password != null)
        {
            return error.InvalidUrl;
        }
        return self.allocator.dupe(u8, path_or_url);
    }

    const RequestOutcome = union(enum) {
        response: RawResponse,
        failure: Failure,
    };

    fn perform(self: *Client, method: std.http.Method, url: []const u8, payload: ?[]const u8) !RequestOutcome {
        var header_buffer: [5]Header = undefined;
        const headers = self.prepareHeaders(&header_buffer, payload != null);
        const request: Request = .{
            .method = method,
            .url = url,
            .payload = payload,
            .headers = headers,
        };

        var attempt: u8 = 0;
        while (attempt < self.retry.max_attempts) : (attempt += 1) {
            var response = self.execute(request) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (attempt + 1 == self.retry.max_attempts) {
                    return .{ .failure = .init(
                        .transport,
                        null,
                        .{},
                        self.token,
                        url,
                        @errorName(err),
                    ) };
                }
                self.waitBeforeRetry(attempt) catch |wait_error| {
                    return retryWaitFailure(self.token, wait_error);
                };
                continue;
            };

            const failure_kind = retry.classify(response.status, response.rate_limit) orelse {
                return .{ .response = response };
            };
            const can_retry = failure_kind == .rate_limited or failure_kind == .retryable_http;
            if (!can_retry or attempt + 1 == self.retry.max_attempts) {
                const failure = Failure.fromResponse(failure_kind, &response, self.token, url);
                response.deinit();
                return .{ .failure = failure };
            }

            response.deinit();
            self.waitBeforeRetry(attempt) catch |wait_error| {
                return retryWaitFailure(self.token, wait_error);
            };
        }
        unreachable;
    }

    fn prepareHeaders(self: *Client, buffer: *[5]Header, has_payload: bool) []const Header {
        var count: usize = 0;
        buffer[count] = .{ .name = "Accept", .value = "application/vnd.github+json" };
        count += 1;
        buffer[count] = .{ .name = "X-GitHub-Api-Version", .value = api_version };
        count += 1;
        buffer[count] = .{ .name = "User-Agent", .value = self.user_agent };
        count += 1;
        if (self.bearer) |bearer| {
            buffer[count] = .{ .name = "Authorization", .value = bearer };
            count += 1;
        }
        if (has_payload) {
            buffer[count] = .{ .name = "Content-Type", .value = "application/json" };
            count += 1;
        }
        return buffer[0..count];
    }

    fn execute(self: *Client, request: Request) !RawResponse {
        if (self.injected_transport) |injected| {
            return injected.execute(self.allocator, request);
        }
        return self.standard_transport.execute(request);
    }

    fn waitBeforeRetry(self: *Client, retry_index: u8) !void {
        const duration = retry.backoff(self.retry.initial_backoff, retry_index);
        if (self.waiter) |waiter| return waiter.wait(duration);
        return self.io.sleep(duration, .awake);
    }
};

fn retryWaitFailure(token: ?[]const u8, wait_error: anyerror) Client.RequestOutcome {
    return .{ .failure = .init(
        .transport,
        null,
        .{},
        token,
        "retry wait failed",
        @errorName(wait_error),
    ) };
}

fn containsNewline(value: []const u8) bool {
    return std.mem.findAny(u8, value, "\r\n") != null;
}
