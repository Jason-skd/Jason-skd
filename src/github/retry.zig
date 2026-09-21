//! Defines bounded retry policy, exponential backoff, and status classification.

const std = @import("std");

const failures = @import("failure.zig");
const transport = @import("transport.zig");

/// Bounded retry policy whose attempt count includes the initial request.
pub const Config = struct {
    /// Total request attempts, including the initial request.
    max_attempts: u8 = 3,
    /// Delay before the first retry; each later delay doubles.
    initial_backoff: std.Io.Duration = .fromSeconds(1),
};

/// Computes the saturated exponential delay for a zero-based retry index.
pub fn backoff(initial: std.Io.Duration, retry_index: u8) std.Io.Duration {
    var nanoseconds = initial.nanoseconds;
    var index: u8 = 0;
    while (index < retry_index) : (index += 1) {
        nanoseconds = std.math.mul(i96, nanoseconds, 2) catch std.math.maxInt(i96);
    }
    return .fromNanoseconds(nanoseconds);
}

/// Maps an HTTP response to a stable failure category, or null for success.
pub fn classify(status: std.http.Status, rate_limit: transport.RateLimit) ?failures.FailureKind {
    const code = @backingInt(status);
    if (code >= 200 and code < 300) return null;
    if (status == .unauthorized) return .authentication;
    if (status == .too_many_requests or
        (status == .forbidden and (rate_limit.remaining == 0 or rate_limit.retry_after != null)))
    {
        return .rate_limited;
    }
    if (code >= 500) return .retryable_http;
    return .terminal_http;
}

test "backoff doubles from the configured initial duration" {
    const initial = std.Io.Duration.fromMilliseconds(5);
    try std.testing.expectEqual(initial, backoff(initial, 0));
    try std.testing.expectEqual(std.Io.Duration.fromMilliseconds(10), backoff(initial, 1));
    try std.testing.expectEqual(std.Io.Duration.fromMilliseconds(20), backoff(initial, 2));
}

test "rate limit classification covers 429 and exhausted 403 responses" {
    try std.testing.expectEqual(failures.FailureKind.rate_limited, classify(.too_many_requests, .{}).?);
    try std.testing.expectEqual(failures.FailureKind.rate_limited, classify(.forbidden, .{ .remaining = 0 }).?);
    try std.testing.expectEqual(failures.FailureKind.terminal_http, classify(.forbidden, .{}).?);
}
