const std = @import("std");
const config = @import("profile_generator").config;

test "public API parses a complete fictional profile" {
    var diagnostic: config.Diagnostic = .{};
    var parsed = try config.parse(
        std.testing.allocator,
        @embedFile("fixtures/config/valid_full.yaml"),
        &diagnostic,
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("octavia-example", parsed.value.login);
    try std.testing.expectEqualStrings("maintainer@octavia.example", parsed.value.author_emails[0]);
    try std.testing.expectEqualStrings("Octavia-Labs", parsed.value.org.login.?);
    try std.testing.expectEqualStrings("Octavia-Labs/atlas", parsed.value.org.repos.?[0]);
    try std.testing.expectEqual(@as(usize, 6), parsed.value.sections.len);
    try std.testing.expectEqual(config.Section.banner, parsed.value.sections[0]);
    try std.testing.expectEqual(config.Section.recent_project, parsed.value.sections[5]);
    try std.testing.expectEqualStrings("aabbcc", parsed.value.theme.accent);
    try std.testing.expect(!parsed.value.include_external);
}

test "public API applies only generic defaults" {
    var diagnostic: config.Diagnostic = .{};
    var parsed = try config.parse(
        std.testing.allocator,
        @embedFile("fixtures/config/valid_defaults.yaml"),
        &diagnostic,
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("1a1b26", parsed.value.theme.base);
    try std.testing.expectEqualStrings("7aa2f7", parsed.value.theme.accent);
    try std.testing.expectEqualStrings("7dcfff", parsed.value.theme.cyan);
    try std.testing.expectEqual(@as(u32, 200), parsed.value.banner.height);
    try std.testing.expectEqual(@as(u32, 8), parsed.value.languages.top);
    try std.testing.expect(parsed.value.org.login == null);
    try std.testing.expect(parsed.value.org.repos == null);
    try std.testing.expect(parsed.value.typing.lines == null);
}

test "public API reports schema failures without panicking" {
    const cases = [_]struct {
        fixture: []const u8,
        code: config.Diagnostic.Code,
        path: []const u8,
    }{
        .{ .fixture = @embedFile("fixtures/config/invalid_unknown.yaml"), .code = .unknown_field, .path = "mystery" },
        .{ .fixture = @embedFile("fixtures/config/invalid_duplicate.yaml"), .code = .duplicate_field, .path = "login" },
        .{ .fixture = @embedFile("fixtures/config/invalid_boolean.yaml"), .code = .invalid_type, .path = "org_card.enabled" },
        .{ .fixture = @embedFile("fixtures/config/invalid_legacy.yaml"), .code = .unsupported_field, .path = "excludes" },
        .{ .fixture = @embedFile("fixtures/config/invalid_missing_login.yaml"), .code = .missing_field, .path = "login" },
    };

    for (cases) |case| {
        var diagnostic: config.Diagnostic = .{};
        try std.testing.expectError(
            error.InvalidConfig,
            config.parse(std.testing.allocator, case.fixture, &diagnostic),
        );
        try std.testing.expectEqual(case.code, diagnostic.code);
        try std.testing.expectEqualStrings(case.path, diagnostic.path);
    }
}

test "missing personal fields never fall back to repository identity" {
    var diagnostic: config.Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        config.parse(
            std.testing.allocator,
            @embedFile("fixtures/config/invalid_missing_login.yaml"),
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings("login", diagnostic.path);
}
