const std = @import("std");

const Ymlz = @import("ymlz").Ymlz;

test "ymlz parses a typed mapping" {
    const Config = struct {
        enabled: bool,
    };

    var parser = try Ymlz(Config).init(std.testing.allocator);
    const config = try parser.loadRaw("enabled: true\n");
    defer parser.deinit(config);

    try std.testing.expect(config.enabled);
}
