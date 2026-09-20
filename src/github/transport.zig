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

/// Type-erased request executor used to replace real networking in tests.
pub const Transport = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!RawResponse,

    /// Executes one request and returns an owned response.
    pub fn execute(self: Transport, allocator: std.mem.Allocator, request: Request) !RawResponse {
        return self.execute_fn(self.context, allocator, request);
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

    /// Executes one request without automatically following redirects.
    pub fn execute(self: *Std, request: Request) !RawResponse {
        const uri = try std.Uri.parse(request.url);
        var extra_headers: [5]std.http.Header = undefined;
        var privileged_headers: [5]std.http.Header = undefined;
        const header_counts = partitionHeaders(request.headers, &extra_headers, &privileged_headers);

        var req = try self.client.request(request.method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .omit,
                .user_agent = .omit,
                .accept_encoding = .omit,
                .content_type = .omit,
            },
            .extra_headers = extra_headers[0..header_counts.extra],
            .privileged_headers = privileged_headers[0..header_counts.privileged],
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
