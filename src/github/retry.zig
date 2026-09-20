//! Defines bounded retry policy, exponential backoff, and status classification.

const std = @import("std");

const failures = @import("failure.zig");
const transport = @import("transport.zig");

/// Bounded retry policy whose attempt count includes the initial request.
pub const Config = struct {
    max_attempts: u8 = 3,
    initial_backoff: std.Io.Duration = .fromSeconds(1),
};

/// Type-erased wait operation used to make retry tests deterministic.
pub const Waiter = struct {
    context: *anyopaque,
    wait_fn: *const fn (*anyopaque, std.Io.Duration) anyerror!void,

    /// Waits for one retry delay using the injected implementation.
    pub fn wait(self: Waiter, duration: std.Io.Duration) !void {
        return self.wait_fn(self.context, duration);
    }
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

test "rate limit classification covers 429 and exhausted 403 responses" {
    try std.testing.expectEqual(failures.FailureKind.rate_limited, classify(.too_many_requests, .{}).?);
    try std.testing.expectEqual(failures.FailureKind.rate_limited, classify(.forbidden, .{ .remaining = 0 }).?);
    try std.testing.expectEqual(failures.FailureKind.terminal_http, classify(.forbidden, .{}).?);
}
