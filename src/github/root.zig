/// GitHub REST and GraphQL client API.
pub const client = @import("client.zig");
/// Typed JSON parsing policy shared by GitHub response handlers.
pub const json = @import("json.zig");

test {
    _ = client;
    _ = json;
    _ = @import("client_test.zig");
    _ = @import("redact.zig");
    _ = @import("retry.zig");
}
