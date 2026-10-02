const std = @import("std");
const config = @import("profile_generator").config;
const options = @import("production_config_options");

test "production profile parses through the public configuration API" {
    const production_yaml = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        options.profile_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(production_yaml);

    var diagnostic: config.Diagnostic = .{};
    var parsed = try config.parse(std.testing.allocator, production_yaml, &diagnostic);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Jason-skd", parsed.value.login);
    try std.testing.expectEqual(@as(u32, 365), parsed.value.window_days);
    try std.testing.expectEqualStrings("📊 Last 365 Days", parsed.value.stats.header);
    try std.testing.expectEqualStrings("wintor76111@gmail.com", parsed.value.author_emails[0]);
    try std.testing.expectEqualStrings("SCNUAutoPtr", parsed.value.org.login.?);
    try std.testing.expect(parsed.value.org.repos == null);
    try std.testing.expectEqualStrings("wintor_ · CS @ SCNU/Aberdeen", parsed.value.typing.lines.?[0]);

    const expected = [_]config.Section{
        .banner,
        .typing,
        .stats,
        .languages,
        .org_card,
        .recent_project,
    };
    try std.testing.expectEqualSlices(config.Section, &expected, parsed.value.sections);
    try std.testing.expectEqualStrings("Groovy", parsed.value.excludes.languages[0]);
    try std.testing.expectEqual(@as(usize, 9), parsed.value.excludes.paths.len);
    try std.testing.expectEqualStrings("**/zig-pkg/**", parsed.value.excludes.paths[8]);
}
