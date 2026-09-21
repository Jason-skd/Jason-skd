const std = @import("std");
const activity = @import("profile_generator").git_activity;

const testing = std.testing;

fn runGit(env: *const std.process.Environ.Map, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        .environ_map = env,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(result.term.success());
}

fn temporaryRoot(tmp: *const testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    return std.fs.path.join(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
}

test "existing repository aggregation is isolated from an unavailable repository" {
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try temporaryRoot(&tmp);
    defer testing.allocator.free(root);

    try runGit(&environ, root, &.{ "git", "init", "-q", root });
    try runGit(&environ, root, &.{ "git", "config", "user.email", "owner@example.test" });
    try runGit(&environ, root, &.{ "git", "config", "user.name", "Owner" });
    const file_path = try std.fs.path.join(testing.allocator, &.{ root, "note.txt" });
    defer testing.allocator.free(file_path);
    var file = try std.Io.Dir.cwd().createFile(testing.io, file_path, .{});
    try file.writeStreamingAll(testing.io, "one\ntwo\n");
    file.close(testing.io);
    try runGit(&environ, root, &.{ "git", "add", "note.txt" });
    try runGit(&environ, root, &.{ "git", "commit", "-qm", "first" });

    const sources = [_]activity.Source{
        .{ .existing = .{ .name = "fixture", .path = root } },
        .{ .existing = .{ .name = "missing", .path = "/definitely/not/a/repository" } },
    };
    const authors = [_][]const u8{"owner@example.test"};
    var result = try activity.scan(testing.allocator, testing.io, &environ, .{
        .sources = &sources,
        .author_emails = &authors,
        .since = 0,
        .until = std.math.maxInt(i64),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.value.repository_count);
    try testing.expectEqual(@as(usize, 1), result.value.unavailable_count);
    try testing.expectEqual(@as(usize, 1), result.value.commit_count);
    try testing.expectEqual(@as(u64, 2), result.value.text_additions);
    try testing.expectEqual(activity.RepositoryStatus.scanned, result.value.repositories[0].status);
    try testing.expectEqual(activity.RepositoryStatus.unavailable, result.value.repositories[1].status);
}

test "local bare remote clone is bounded and its checkout is removed" {
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try temporaryRoot(&tmp);
    defer testing.allocator.free(root);
    const bare = try std.fs.path.join(testing.allocator, &.{ root, "remote.git" });
    defer testing.allocator.free(bare);
    const source_repo = try std.fs.path.join(testing.allocator, &.{ root, "source" });
    defer testing.allocator.free(source_repo);
    try runGit(&environ, root, &.{ "git", "init", "--bare", "-q", bare });
    try runGit(&environ, root, &.{ "git", "init", "-q", source_repo });
    try runGit(&environ, source_repo, &.{ "git", "config", "user.email", "owner@example.test" });
    try runGit(&environ, source_repo, &.{ "git", "config", "user.name", "Owner" });
    try environ.put("GIT_AUTHOR_DATE", "1700000000 +0000");
    try environ.put("GIT_COMMITTER_DATE", "1700000000 +0000");
    const source_file = try std.fs.path.join(testing.allocator, &.{ source_repo, "README.md" });
    defer testing.allocator.free(source_file);
    var file = try std.Io.Dir.cwd().createFile(testing.io, source_file, .{});
    try file.writeStreamingAll(testing.io, "fixture\n");
    file.close(testing.io);
    try runGit(&environ, source_repo, &.{ "git", "add", "README.md" });
    try runGit(&environ, source_repo, &.{ "git", "commit", "-qm", "fixture" });
    try runGit(&environ, source_repo, &.{ "git", "remote", "add", "origin", bare });
    try runGit(&environ, source_repo, &.{ "git", "push", "-q", "origin", "HEAD" });

    const authors = [_][]const u8{"owner@example.test"};
    const remote_url = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{bare});
    defer testing.allocator.free(remote_url);
    var result = try activity.scan(testing.allocator, testing.io, &environ, .{
        .sources = &.{.{ .remote = .{ .name = "owner/project", .url = remote_url } }},
        .author_emails = &authors,
        .since = 1699999999,
        .until = 1700000001,
        .clone_root = root,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.value.unavailable_count);
    try testing.expectEqual(@as(usize, 1), result.value.commit_count);
    try testing.expectEqualStrings(remote_url, result.value.repositories[0].location);
    var entries = tmp.dir.iterate();
    while (try entries.next(testing.io)) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry.name, "git-activity-"));
    }
}

test "Git credential config is injected without exposing the token" {
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    const runner: activity.Runner = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .environ = &environ,
        .stdout_limit = 1024,
        .stderr_limit = 1024,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    };
    var result = try runner.git(null, &.{ "git", "config", "--get", "http.extraHeader" }, "private-token");
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("[REDACTED]\n", result.stdout);
    try testing.expect(std.mem.find(u8, result.stdout, "private-token") == null);
    try testing.expect(std.mem.find(u8, result.stderr, "private-token") == null);
}

test "Git authentication failures retain a stable category" {
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    const runner: activity.Runner = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .environ = &environ,
        .stdout_limit = 1024,
        .stderr_limit = 1024,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    };
    try testing.expectError(error.AuthenticationFailed, runner.git(null, &.{
        "git",
        "-c",
        "alias.auth=!f() { echo 'Authentication failed' >&2; exit 1; }; f",
        "auth",
    }, null));
}

test "failed and credential-bearing remotes leave no temporary checkout" {
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try temporaryRoot(&tmp);
    defer testing.allocator.free(root);
    const authors = [_][]const u8{"owner@example.test"};
    const sources = [_]activity.Source{
        .{ .remote = .{ .name = "missing", .url = "file:///definitely/not/a/repository" } },
        .{ .remote = .{ .name = "credential-url", .url = "https://user:secret@example.test/repository" } },
    };
    var result = try activity.scan(testing.allocator, testing.io, &environ, .{
        .sources = &sources,
        .author_emails = &authors,
        .since = 1,
        .until = 2,
        .clone_root = root,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.value.unavailable_count);
    try testing.expectEqual(activity.FailureKind.git_command_failed, result.value.repositories[0].failure.?.kind);
    try testing.expectEqual(activity.FailureKind.invalid_input, result.value.repositories[1].failure.?.kind);
    var entries = tmp.dir.iterate();
    while (try entries.next(testing.io)) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry.name, "git-activity-"));
    }
}
