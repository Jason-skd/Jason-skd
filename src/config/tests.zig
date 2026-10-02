const std = @import("std");
const diagnostic_module = @import("diagnostic.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");

const Diagnostic = diagnostic_module.Diagnostic;
const Timezone = model.Timezone;
const parse = parser.parse;

const minimal_yaml =
    \\login: example-user
    \\timezone: Asia/Shanghai
    \\theme:
    \\author_emails:
    \\  - developer@example.test
    \\window_days: 30
    \\sections:
    \\  - banner
    \\typing:
    \\  width: 640
;

test "parse normalizes generic defaults into arena-owned config" {
    var diagnostic: Diagnostic = .{};
    var parsed = try parse(std.testing.allocator, minimal_yaml, &diagnostic);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("example-user", parsed.value.login);
    try std.testing.expectEqual(Timezone.asia_shanghai, parsed.value.timezone);
    try std.testing.expectEqualStrings("1a1b26", parsed.value.theme.base);
    try std.testing.expect(parsed.value.include_external);
    try std.testing.expectEqual(@as(u32, 200), parsed.value.banner.height);
    try std.testing.expectEqualStrings("Fira Code", parsed.value.typing.font);
    try std.testing.expectEqual(@as(u32, 22), parsed.value.typing.size);
    try std.testing.expectEqualStrings("📊 Last 30 Days", parsed.value.stats.header);
    try std.testing.expect(parsed.value.org.login == null);
    try std.testing.expect(parsed.value.typing.lines == null);
}

test "parse normalizes prefixed uppercase theme colors" {
    const yaml =
        \\login: example-user
        \\timezone: Asia/Shanghai
        \\theme:
        \\  accent: "#AABBCC"
        \\author_emails:
        \\  - developer@example.test
        \\window_days: 30
        \\sections:
        \\  - banner
        \\typing:
        \\  width: 640
    ;
    var diagnostic: Diagnostic = .{};
    var parsed = try parse(std.testing.allocator, yaml, &diagnostic);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("aabbcc", parsed.value.theme.accent);
}

test "parse rejects schema, duplicate, scalar, and cross-field failures" {
    const cases = [_]struct { yaml: []const u8, code: Diagnostic.Code }{
        .{ .yaml = minimal_yaml ++ "\nunknown: value\n", .code = .unknown_field },
        .{ .yaml = minimal_yaml ++ "\nlogin: duplicate\n", .code = .duplicate_field },
        .{ .yaml = minimal_yaml ++ "\nexclude:\n", .code = .unsupported_field },
        .{ .yaml = std.mem.replaceOwned(u8, std.testing.allocator, minimal_yaml, "window_days: 30", "window_days: 0") catch unreachable, .code = .invalid_value },
        .{ .yaml = std.mem.replaceOwned(u8, std.testing.allocator, minimal_yaml, "sections:\n  - banner", "sections:\n  - nope") catch unreachable, .code = .unknown_section },
    };
    defer std.testing.allocator.free(cases[3].yaml);
    defer std.testing.allocator.free(cases[4].yaml);

    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, case.yaml, &diagnostic));
        try std.testing.expectEqual(case.code, diagnostic.code);
    }
}

test "parse requires personalized values without inferring defaults" {
    const no_login =
        \\timezone: Asia/Shanghai
        \\theme:
        \\author_emails:
        \\  - developer@example.test
        \\window_days: 30
        \\sections:
        \\  - banner
        \\typing:
        \\  width: 640
    ;
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, no_login, &diagnostic));
    try std.testing.expectEqual(Diagnostic.Code.missing_field, diagnostic.code);
    try std.testing.expectEqualStrings("login", diagnostic.path);
}

test "parse requires typing lines when typing is listed" {
    const yaml = std.mem.replaceOwned(u8, std.testing.allocator, minimal_yaml, "  - banner", "  - typing") catch unreachable;
    defer std.testing.allocator.free(yaml);
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, yaml, &diagnostic));
    try std.testing.expectEqualStrings("typing.lines", diagnostic.path);
}

test "parse requires organization identity when enabled org card is listed" {
    const yaml = std.mem.replaceOwned(u8, std.testing.allocator, minimal_yaml, "  - banner", "  - org_card") catch unreachable;
    defer std.testing.allocator.free(yaml);
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, yaml, &diagnostic));
    try std.testing.expectEqualStrings("org.login", diagnostic.path);
}

test "parse allows organization card without configured repository scan targets" {
    const yaml = try std.mem.replaceOwned(u8, std.testing.allocator, minimal_yaml ++ "\norg:\n  login: example-org\n", "  - banner", "  - org_card");
    defer std.testing.allocator.free(yaml);
    var diagnostic: Diagnostic = .{};
    var parsed = try parse(std.testing.allocator, yaml, &diagnostic);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("example-org", parsed.value.org.login.?);
    try std.testing.expect(parsed.value.org.repos == null);
}

test "parse rejects duplicate nested fields and sections" {
    const duplicate_nested = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        minimal_yaml,
        "  width: 640",
        "  width: 640\n  width: 720",
    );
    defer std.testing.allocator.free(duplicate_nested);
    try expectInvalid(duplicate_nested, .duplicate_field, "typing.width");

    const duplicate_section = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        minimal_yaml,
        "  - banner",
        "  - banner\n  - banner",
    );
    defer std.testing.allocator.free(duplicate_section);
    try expectInvalid(duplicate_section, .duplicate_section, "sections");
}

test "parse validates timezone numeric boolean and theme values" {
    const cases = [_]struct {
        old: []const u8,
        new: []const u8,
        code: Diagnostic.Code,
        path: []const u8,
    }{
        .{ .old = "Asia/Shanghai", .new = "UTC", .code = .invalid_value, .path = "timezone" },
        .{ .old = "window_days: 30", .new = "window_days: -1", .code = .invalid_type, .path = "window_days" },
        .{ .old = "theme:", .new = "theme:\n  base: 12345g", .code = .invalid_value, .path = "theme.base" },
        .{ .old = "typing:\n", .new = "org_card:\n  enabled: maybe\ntyping:\n", .code = .invalid_type, .path = "org_card.enabled" },
    };

    for (cases) |case| {
        const yaml = try std.mem.replaceOwned(u8, std.testing.allocator, minimal_yaml, case.old, case.new);
        defer std.testing.allocator.free(yaml);
        try expectInvalid(yaml, case.code, case.path);
    }
}

test "parse rejects nested unknown and legacy aliases" {
    const cases = [_]struct { field: []const u8, code: Diagnostic.Code }{
        .{ .field = "  unknown: value\n", .code = .unknown_field },
        .{ .field = "  exclude: value\n", .code = .unsupported_field },
        .{ .field = "  languages_card: value\n", .code = .unsupported_field },
    };
    for (cases) |case| {
        const replacement = try std.fmt.allocPrint(std.testing.allocator, "theme:\n{s}", .{case.field});
        defer std.testing.allocator.free(replacement);
        const yaml = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            minimal_yaml,
            "theme:\n",
            replacement,
        );
        defer std.testing.allocator.free(yaml);
        try expectInvalid(yaml, case.code, std.mem.trim(u8, case.field[0..std.mem.indexOfScalar(u8, case.field, ':').?], " "));
    }
}

test "successful result does not borrow the YAML buffer" {
    const input = try std.testing.allocator.dupe(u8, minimal_yaml);
    var diagnostic: Diagnostic = .{};
    var parsed = try parse(std.testing.allocator, input, &diagnostic);
    defer parsed.deinit();

    @memset(input, 'x');
    std.testing.allocator.free(input);
    try std.testing.expectEqualStrings("example-user", parsed.value.login);
    try std.testing.expectEqualStrings("developer@example.test", parsed.value.author_emails[0]);
}

test "parse cleans up every allocation failure path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAllocationFailure, .{});
}

test "malformed YAML shapes return diagnostics before typed binding" {
    const cases = [_][]const u8{
        "",
        "- profile\n",
        "login:value\n",
        "login: example\n   timezone: Asia/Shanghai\n",
        "login: example\n\ttimezone: Asia/Shanghai\n",
        "login: example\ntimezone: Asia/Shanghai\ntheme: {}\n",
    };
    for (cases) |yaml| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, yaml, &diagnostic));
        try std.testing.expect(diagnostic.code != .none);
    }
}

fn parseAllocationFailure(allocator: std.mem.Allocator) !void {
    var diagnostic: Diagnostic = .{};
    var parsed = try parse(allocator, minimal_yaml, &diagnostic);
    defer parsed.deinit();
}

fn expectInvalid(yaml: []const u8, code: Diagnostic.Code, path: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, yaml, &diagnostic));
    try std.testing.expectEqual(code, diagnostic.code);
    try std.testing.expectEqualStrings(path, diagnostic.path);
}

test "excludes defaults flow lists and explicit empty lists preserve caller intent" {
    var diagnostic: Diagnostic = .{};
    const defaults = try parse(std.testing.allocator, minimal_yaml, &diagnostic);
    defer defaults.deinit();
    try std.testing.expectEqual(@as(usize, 8), defaults.value.excludes.paths.len);
    try std.testing.expectEqual(@as(usize, 0), defaults.value.excludes.repos.len);
    try std.testing.expectEqualStrings("markup", defaults.value.languages.types.?[1]);
    const explicit = try parse(std.testing.allocator, minimal_yaml ++
        "\nexcludes:\n  repos: [Org/Repo, other]\n  languages: [Groovy, ]\n  paths: []\nlanguages:\n  types: []\n", &diagnostic);
    defer explicit.deinit();
    try std.testing.expectEqualStrings("Org/Repo", explicit.value.excludes.repos[0]);
    try std.testing.expectEqualStrings("other", explicit.value.excludes.repos[1]);
    try std.testing.expectEqualStrings("Groovy", explicit.value.excludes.languages[0]);
    try std.testing.expectEqual(@as(usize, 0), explicit.value.excludes.paths.len);
    try std.testing.expectEqual(@as(usize, 0), explicit.value.languages.types.?.len);
    const override = try parse(std.testing.allocator, minimal_yaml ++ "\nexcludes:\n  paths:\n    - '**/zig-pkg/**'\n", &diagnostic);
    defer override.deinit();
    try std.testing.expectEqual(@as(usize, 1), override.value.excludes.paths.len);
    try std.testing.expectEqualStrings("**/zig-pkg/**", override.value.excludes.paths[0]);
    try expectInvalid(minimal_yaml ++ "\nexcludes:\n  paths: wrong\n", .invalid_type, "excludes.paths");
    try expectInvalid(minimal_yaml ++ "\nexcludes:\n  paths: []\n  paths: []\n", .duplicate_field, "excludes.paths");
    try expectInvalid(minimal_yaml ++ "\nexcludes:\n  paths: [one,,two]\n", .invalid_value, "excludes.paths");
    try expectInvalid(minimal_yaml ++ "\nexcludes:\n  typo: []\n", .unknown_field, "typo");
}

fn parseExcludesAllocation(gpa: std.mem.Allocator) !void {
    const bytes = try gpa.dupe(u8, minimal_yaml ++ "\nexcludes:\n  repos: [Org/Repo]\n  languages: [Groovy]\n  paths: ['**/vendor/**', '**/zig-pkg/**']\n");
    defer gpa.free(bytes);
    var diagnostic: Diagnostic = .{};
    const parsed = try parse(gpa, bytes, &diagnostic);
    defer parsed.deinit();
    @memset(bytes, 'x');
    try std.testing.expectEqualStrings("Org/Repo", parsed.value.excludes.repos[0]);
    try std.testing.expectEqualStrings("**/zig-pkg/**", parsed.value.excludes.paths[1]);
}

test "excludes config owns its input and cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseExcludesAllocation, .{});
}
