//! GitHub REST and GraphQL integration for the profile generator.

const client = @import("github/client.zig");

pub const Client = client.Client;
pub const Config = client.Config;
pub const RetryConfig = client.RetryConfig;
pub const Transport = client.Transport;
pub const Header = client.Header;
pub const Request = client.Request;
pub const RawResponse = client.RawResponse;
pub const RateLimit = client.RateLimit;
pub const FailureKind = client.FailureKind;
pub const Failure = client.Failure;
pub const Result = client.Result;

test {
    _ = client;
    _ = @import("github/client_test.zig");
    _ = @import("github/json.zig");
    _ = @import("github/redact.zig");
    _ = @import("github/retry.zig");
    _ = @import("github/transport.zig");
}
