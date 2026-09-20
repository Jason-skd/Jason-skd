//! GitHub REST and GraphQL integration for the profile generator.

const client = @import("client.zig");

/// Typed GitHub REST and GraphQL client with owned transport resources.
pub const Client = client.Client;
/// Dependencies and policy used to initialize a GitHub client.
pub const Config = client.Config;
/// Retry policy whose attempt count includes the initial request.
pub const RetryConfig = client.RetryConfig;
/// Type-erased wait operation used to make retry tests deterministic.
pub const Waiter = client.Waiter;
/// Type-erased request executor used by deterministic tests.
pub const Transport = client.Transport;
/// One HTTP header passed across the injectable transport boundary.
pub const Header = client.Header;
/// A complete request passed to an injected transport.
pub const Request = client.Request;
/// An owned transport response used by custom transports.
pub const RawResponse = client.RawResponse;
/// GitHub rate-limit metadata parsed from response headers.
pub const RateLimit = client.RateLimit;
/// Stable failure categories returned to callers.
pub const FailureKind = client.FailureKind;
/// A structured, secret-safe failure.
pub const Failure = client.Failure;
/// Either an owned typed value or a structured GitHub failure.
pub const Result = client.Result;

test {
    _ = client;
    _ = @import("client_test.zig");
    _ = @import("json.zig");
    _ = @import("redact.zig");
    _ = @import("retry.zig");
    _ = @import("transport.zig");
}
