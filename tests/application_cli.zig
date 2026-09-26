const std = @import("std");
const paths = @import("cli_test_options");
const testing = std.testing;

fn run(env: *const std.process.Environ.Map, args: []const []const u8) !std.process.RunResult {
    return std.process.run(testing.allocator, testing.io, .{
        .argv = args,
        .environ_map = env,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(16384),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(15), .clock = .awake } },
    });
}

fn release(result: std.process.RunResult) void {
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
}

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(expected, bytes);
}

test "CLI dry run atomic delivery and failures preserve filesystem and redact diagnostics" {
    const io = testing.io;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    // Even a mistaken attempt to execute Git cannot reach an installed binary.
    try env.put("PATH", "/nonexistent");
    try env.put("PROFILE_PAT", "fixture-secret-never-print");
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);
    const target = try std.fs.path.join(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "README.md" });
    defer testing.allocator.free(target);
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "original" });
    const base = "tests/fixtures/application/";
    const dry = try run(&env, &.{ paths.executable, "--config", base ++ "profile.yaml", "--fixtures", base ++ "success", "--output", target, "--dry-run" });
    defer release(dry);
    try testing.expect(dry.term.success());
    try testing.expectEqualStrings("", dry.stderr);
    try testing.expect(std.mem.startsWith(u8, dry.stdout, "<!-- AUTO-GENERATED"));
    try testing.expect(std.mem.endsWith(u8, dry.stdout, "\n"));
    try expectFile(tmp.dir, "README.md", "original");
    const normal = try run(&env, &.{ paths.executable, "--config", base ++ "profile.yaml", "--fixtures", base ++ "success", "--output", target });
    defer release(normal);
    try testing.expect(normal.term.success());
    try testing.expectEqualStrings("", normal.stdout);
    try testing.expectEqualStrings("", normal.stderr);
    try expectFile(tmp.dir, "README.md", dry.stdout);
    for ([_][]const u8{ "missing", "empty", "does-not-exist" }) |name| {
        const fixture_path = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ base, name });
        defer testing.allocator.free(fixture_path);
        const failed = try run(&env, &.{ paths.executable, "--config", base ++ "profile.yaml", "--fixtures", fixture_path, "--output", target });
        defer release(failed);
        try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, failed.term);
        try testing.expectEqualStrings("", failed.stdout);
        try testing.expect(std.mem.startsWith(u8, failed.stderr, "profile-generator: application: "));
        try testing.expect(std.mem.indexOf(u8, failed.stderr, "fixture-secret") == null);
        try expectFile(tmp.dir, "README.md", dry.stdout);
    }
    const invalid = try run(&env, &.{ paths.executable, "--https://user:fixture-secret-never-print@example.test" });
    defer release(invalid);
    try testing.expectEqual(std.process.Child.Term{ .exited = 2 }, invalid.term);
    try testing.expectEqualStrings("profile-generator: arguments: InvalidArguments\n", invalid.stderr);
    const help = try run(&env, &.{ paths.executable, "--help" });
    defer release(help);
    try testing.expect(help.term.success());
    try testing.expect(std.mem.indexOf(u8, help.stdout, "--fixtures") != null);
    try testing.expectEqualStrings("", help.stderr);
    const bad_target = try std.fmt.allocPrint(testing.allocator, "{s}/child.md", .{target});
    defer testing.allocator.free(bad_target);
    const failed_output = try run(&env, &.{ paths.executable, "--config", base ++ "profile.yaml", "--fixtures", base ++ "success", "--output", bad_target });
    defer release(failed_output);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, failed_output.term);
    try testing.expectEqualStrings("", failed_output.stdout);
    try testing.expectEqualStrings("profile-generator: output: DeliveryFailed\n", failed_output.stderr);
    try expectFile(tmp.dir, "README.md", dry.stdout);
    const failed_config = try run(&env, &.{ paths.executable, "--config", "tests/fixtures/config/invalid_missing_login.yaml", "--fixtures", base ++ "success", "--output", target });
    defer release(failed_config);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, failed_config.term);
    try testing.expectEqualStrings("profile-generator: application: Configuration\n", failed_config.stderr);
    try expectFile(tmp.dir, "README.md", dry.stdout);
    var iterator = tmp.dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    try testing.expectEqual(1, count);
}
