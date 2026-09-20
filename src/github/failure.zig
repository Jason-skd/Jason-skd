const std = @import("std");

const redact = @import("redact.zig");
const transport = @import("transport.zig");

/// Stable categories callers can use without parsing diagnostic text.
pub const FailureKind = enum {
    transport,
    authentication,
    rate_limited,
    retryable_http,
    terminal_http,
    invalid_json,
    graphql,
};

/// A secret-safe GitHub failure with optional HTTP and rate-limit context.
pub const Failure = struct {
    kind: FailureKind,
    status: ?std.http.Status = null,
    rate_limit: transport.RateLimit = .{},
    diagnostic_buffer: [512]u8 = undefined,
    diagnostic_len: usize = 0,

    /// Returns the bounded, already-redacted diagnostic message.
    pub fn diagnostic(self: *const Failure) []const u8 {
        return self.diagnostic_buffer[0..self.diagnostic_len];
    }

    /// Builds a failure while redacting secrets from its context and detail.
    pub fn init(
        kind: FailureKind,
        status: ?std.http.Status,
        rate_limit: transport.RateLimit,
        token: ?[]const u8,
        context: []const u8,
        detail: []const u8,
    ) Failure {
        var result: Failure = .{
            .kind = kind,
            .status = status,
            .rate_limit = rate_limit,
        };
        var writer: std.Io.Writer = .fixed(&result.diagnostic_buffer);
        writer.writeAll(@tagName(kind)) catch {};
        writer.writeAll(": ") catch {};
        redact.writeSanitized(&writer, context, token) catch {};
        if (detail.len != 0) {
            writer.writeAll(": ") catch {};
            redact.writeSanitized(&writer, detail, token) catch {};
        }
        result.diagnostic_len = writer.buffered().len;
        return result;
    }

    /// Converts an unsuccessful HTTP response into a secret-safe failure.
    pub fn fromResponse(
        kind: FailureKind,
        response: *const transport.RawResponse,
        token: ?[]const u8,
        url: []const u8,
    ) Failure {
        var context_buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&context_buffer);
        writer.print("HTTP {d} for ", .{@backingInt(response.status)}) catch {};
        redact.writeSanitized(&writer, url, token) catch {};
        return .init(
            kind,
            response.status,
            response.rate_limit,
            token,
            writer.buffered(),
            response.body,
        );
    }
};

/// Returns either an owned typed JSON value or a structured GitHub failure.
pub fn Result(comptime T: type) type {
    return union(enum) {
        success: std.json.Parsed(T),
        failure: Failure,

        /// Releases allocations held by a successful parsed value.
        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .success => |*parsed| parsed.deinit(),
                .failure => {},
            }
            self.* = undefined;
        }
    };
}
