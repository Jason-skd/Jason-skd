//! Adapts GitHub request descriptions to the Zig standard HTTP client.

const std = @import("std");

const max_response_bytes = 8 * 1024 * 1024;

/// One HTTP header passed across the GitHub transport boundary.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A complete request description consumed by an injected or standard transport.
pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    headers: []const Header,
};

/// Type-erased request sender used to replace real networking in tests.
pub const Transport = struct {
    /// Borrowed implementation state that must outlive every `send` call.
    context: *anyopaque,
    /// Implementation called by `send` after restoring the erased context.
    send_fn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!RawResponse,

    /// Sends one request and returns an owned response.
    pub fn send(self: Transport, allocator: std.mem.Allocator, request: Request) !RawResponse {
        return self.send_fn(self.context, allocator, request);
    }
};

/// Bounded owned text used for short response-header metadata.
pub const BoundedText = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,
    present: bool = false,

    /// Returns the stored value, or null when the header was absent.
    pub fn slice(self: *const BoundedText) ?[]const u8 {
        return if (self.present) self.bytes[0..self.len] else null;
    }

    fn set(self: *BoundedText, value: []const u8) void {
        self.present = true;
        self.len = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], value[0..self.len]);
    }
};

/// Rate-limit metadata parsed from GitHub response headers.
pub const RateLimit = struct {
    limit: ?u64 = null,
    remaining: ?u64 = null,
    used: ?u64 = null,
    reset: ?u64 = null,
    retry_after: ?u64 = null,
    resource: BoundedText = .{},

    /// Parses all recognized GitHub rate-limit headers.
    pub fn fromHeaders(headers: []const Header) RateLimit {
        var result: RateLimit = .{};
        for (headers) |header| result.addHeader(header);
        return result;
    }

    fn addHeader(self: *RateLimit, header: Header) void {
        if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-limit")) {
            self.limit = parseUnsigned(header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-remaining")) {
            self.remaining = parseUnsigned(header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-used")) {
            self.used = parseUnsigned(header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-reset")) {
            self.reset = parseUnsigned(header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            self.retry_after = parseUnsigned(header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-resource")) {
            self.resource.set(header.value);
        }
    }
};

fn parseUnsigned(value: []const u8) ?u64 {
    return std.fmt.parseUnsigned(u64, value, 10) catch null;
}

/// An HTTP response whose body is owned and must be deinitialized.
pub const RawResponse = struct {
    allocator: std.mem.Allocator,
    status: std.http.Status,
    rate_limit: RateLimit,
    body: []u8,

    /// Copies a scripted response into allocator-owned memory.
    pub fn init(
        allocator: std.mem.Allocator,
        status: std.http.Status,
        headers: []const Header,
        body: []const u8,
    ) !RawResponse {
        return .{
            .allocator = allocator,
            .status = status,
            .rate_limit = .fromHeaders(headers),
            .body = try allocator.dupe(u8, body),
        };
    }

    fn fromOwned(
        allocator: std.mem.Allocator,
        status: std.http.Status,
        rate_limit: RateLimit,
        body: []u8,
    ) RawResponse {
        return .{
            .allocator = allocator,
            .status = status,
            .rate_limit = rate_limit,
            .body = body,
        };
    }

    /// Frees the response body.
    pub fn deinit(self: *RawResponse) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

/// Production transport backed by one reusable `std.http.Client`.
pub const Std = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    /// Creates the standard transport and its connection pool.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Std {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    /// Releases all pooled HTTP connections and TLS resources.
    pub fn deinit(self: *Std) void {
        self.client.deinit();
        self.* = undefined;
    }

    /// Sends one request without automatically following redirects.
    pub fn send(self: *Std, request: Request) !RawResponse {
        const uri = try std.Uri.parse(request.url);
        var extra_headers: [5]std.http.Header = undefined;
        var privileged_headers: [5]std.http.Header = undefined;
        const header_counts = partitionHeaders(request.headers, &extra_headers, &privileged_headers);

        var req = try self.client.request(request.method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                // This nightly emits the standard override, but not privileged_headers.
                // Keep redirects unhandled so credentials cannot cross origins.
                .authorization = if (header_counts.privileged == 0)
                    .omit
                else
                    .{ .override = privileged_headers[0].value },
                .user_agent = .omit,
                .accept_encoding = .omit,
                .content_type = .omit,
            },
            .extra_headers = extra_headers[0..header_counts.extra],
        });
        defer req.deinit();

        if (request.payload) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var body_writer = try req.sendBody(&.{});
            try body_writer.writer.writeAll(payload);
            try body_writer.end();
        } else {
            try req.sendBodiless();
        }

        var response = try req.receiveHead(&.{});
        var rate_limit: RateLimit = .{};
        var header_iterator = response.head.iterateHeaders();
        while (header_iterator.next()) |header| {
            rate_limit.addHeader(.{ .name = header.name, .value = header.value });
        }

        const body = try response.reader(&.{}).allocRemaining(
            self.allocator,
            .limited(max_response_bytes),
        );
        return .fromOwned(self.allocator, response.head.status, rate_limit, body);
    }
};

const HeaderCounts = struct {
    extra: usize = 0,
    privileged: usize = 0,
};

fn partitionHeaders(
    headers: []const Header,
    extra: *[5]std.http.Header,
    privileged: *[5]std.http.Header,
) HeaderCounts {
    var counts: HeaderCounts = .{};
    for (headers) |header| {
        const std_header: std.http.Header = .{ .name = header.name, .value = header.value };
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            privileged[counts.privileged] = std_header;
            counts.privileged += 1;
        } else {
            extra[counts.extra] = std_header;
            counts.extra += 1;
        }
    }
    return counts;
}

test "authorization is separated from redirect-safe headers" {
    var extra: [5]std.http.Header = undefined;
    var privileged: [5]std.http.Header = undefined;
    const counts = partitionHeaders(&.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Authorization", .value = "Bearer SECRET" },
    }, &extra, &privileged);

    try std.testing.expectEqual(@as(usize, 1), counts.extra);
    try std.testing.expectEqualStrings("Accept", extra[0].name);
    try std.testing.expectEqual(@as(usize, 1), counts.privileged);
    try std.testing.expectEqualStrings("Authorization", privileged[0].name);
}

test "standard transport sends authorization on the wire and leaves redirects unhandled" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const Fixture = struct {
        fn serve(server: *std.Io.net.Server, expected_auth: ?[]const u8, status: std.http.Status) !void {
            var stream = try server.accept(std.testing.io);
            defer stream.close(std.testing.io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = stream.reader(std.testing.io, &read_buffer);
            var writer = stream.writer(std.testing.io, &write_buffer);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try http_server.receiveHead();
            var headers = request.iterateHeaders();
            var auth_count: usize = 0;
            var auth_matches = expected_auth == null;
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                    auth_count += 1;
                    auth_matches = if (expected_auth) |value| std.mem.eql(u8, value, header.value) else false;
                }
            }
            // Respond before asserting so a regression cannot leave the client waiting.
            try request.respond("fixture", .{
                .status = status,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "Location", .value = "http://127.0.0.1:0/must-not-follow" }},
            });
            try std.testing.expect(auth_matches);
            try std.testing.expectEqual(@as(usize, if (expected_auth == null) 0 else 1), auth_count);
        }
    };

    for ([_]std.http.Status{ .ok, .ok, .found }, [_]?[]const u8{ "Bearer fixture-token", null, "Bearer fixture-token" }) |status, authorization| {
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        var future = try io.concurrent(Fixture.serve, .{ &server, authorization, status });
        defer future.cancel(io) catch {};
        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
        defer allocator.free(url);
        var transport = Std.init(allocator, io);
        defer transport.deinit();
        var response = try transport.send(.{
            .method = .GET,
            .url = url,
            .payload = null,
            .headers = if (authorization) |value| &.{.{ .name = "aUtHoRiZaTiOn", .value = value }} else &.{},
        });
        defer response.deinit();
        try std.testing.expectEqual(status, response.status);
        try std.testing.expectEqualStrings("fixture", response.body);
        try future.await(io);
    }
}
