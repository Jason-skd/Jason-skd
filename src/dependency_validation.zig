const std = @import("std");

const clap = @import("clap");
const Ymlz = @import("ymlz").Ymlz;

test "zig-clap parses a parameter specification" {
    const parameters = comptime clap.parseParamsComptime(
        \\-h, --help  Display help and exit.
        \\
    );

    try std.testing.expectEqual(@as(usize, 1), parameters.len);
}

test "ymlz parses a typed mapping" {
    const Config = struct {
        enabled: bool,
    };

    var parser = try Ymlz(Config).init(std.testing.allocator);
    const config = try parser.loadRaw("enabled: true\n");
    defer parser.deinit(config);

    try std.testing.expect(config.enabled);
}
