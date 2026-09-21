//! Git repository lifecycle and structured activity aggregation.

const std = @import("std");
const process = @import("process.zig");
const lifecycle = @import("git_activity/lifecycle.zig");
const log = @import("git_activity/log.zig");
const model = @import("git_activity/model.zig");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;

pub const Error = process.RunError || error{ InvalidSource, InvalidGitCommand, CloneRootRequired, AuthenticationFailed, GitCommandFailed, CleanupFailed, MalformedGitOutput, TempPathCollision };
pub const Source = lifecycle.Source;
pub const Runner = lifecycle.Runner;
pub const RepositoryStatus = model.RepositoryStatus;
pub const FailureKind = model.FailureKind;
pub const Failure = model.Failure;
pub const FileChange = model.FileChange;
pub const Commit = model.Commit;
pub const Repository = model.Repository;
pub const Aggregate = model.Aggregate;
pub const ScanResult = model.ScanResult;

pub const Options = struct {
    sources: []const Source,
    author_emails: []const []const u8,
    since: i64,
    until: i64,
    timeout: Io.Timeout,
    token: ?[]const u8 = null,
    clone_root: ?[]const u8 = null,
    stdout_limit: usize = 16 * 1024 * 1024,
    stderr_limit: usize = 256 * 1024,
};

/// Scans repositories serially and returns one owned aggregate.
///
/// Repository-local failures remain visible in `Repository.failure`; allocation,
/// cancellation, and temporary-state cleanup failures abort the whole scan.
pub fn scan(allocator: Allocator, io: Io, environ: *const Environ.Map, options: Options) Error!ScanResult {
    if (options.until < options.since or options.author_emails.len == 0) return error.InvalidSource;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const gpa = arena.allocator();
    const runner: Runner = .{
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
        .timeout = options.timeout,
    };
    var repositories = try std.ArrayList(Repository).initCapacity(gpa, options.sources.len);
    var aggregate = Aggregate{
        .repositories = &.{},
        .repository_count = options.sources.len,
        .unavailable_count = 0,
        .commit_count = 0,
        .text_additions = 0,
        .text_deletions = 0,
        .binary_files = 0,
        .renamed_files = 0,
    };
    for (options.sources) |source| {
        const repository = scanSource(&runner, gpa, options, source) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled or err == error.CleanupFailed) return err;
            try repositories.append(gpa, .{
                .name = try gpa.dupe(u8, sourceName(source)),
                .location = try gpa.dupe(u8, sourceLocation(source)),
                .status = .unavailable,
                .failure = .{
                    .kind = failureKind(err),
                    .cause = try gpa.dupe(u8, @errorName(err)),
                },
                .commits = &.{},
                .commit_count = 0,
                .text_additions = 0,
                .text_deletions = 0,
                .binary_files = 0,
                .renamed_files = 0,
            });
            aggregate.unavailable_count += 1;
            continue;
        };
        aggregate.commit_count += repository.commit_count;
        aggregate.text_additions += repository.text_additions;
        aggregate.text_deletions += repository.text_deletions;
        aggregate.binary_files += repository.binary_files;
        aggregate.renamed_files += repository.renamed_files;
        try repositories.append(gpa, repository);
    }
    aggregate.repositories = try repositories.toOwnedSlice(gpa);
    return .{ .arena = arena, .value = aggregate };
}

fn scanSource(runner: *const Runner, gpa: Allocator, options: Options, source: Source) Error!Repository {
    return switch (source) {
        .existing => |existing| scanPath(runner, gpa, options, existing.name, existing.path),
        .remote => |remote| scanRemote(runner, gpa, options, remote),
    };
}

fn scanRemote(runner: *const Runner, gpa: Allocator, options: Options, remote: Source.Remote) Error!Repository {
    const clone_root = options.clone_root orelse return error.CloneRootRequired;
    if (remote.name.len == 0 or options.since <= 0 or !validRemoteUrl(remote.url) or !std.fs.path.isAbsolute(clone_root)) return error.InvalidSource;
    var random_bytes: [12]u8 = undefined;
    runner.io.random(&random_bytes);
    var random_name: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&random_name, &random_bytes);
    const destination_name = try std.fmt.allocPrint(gpa, "git-activity-{s}", .{random_name});
    defer gpa.free(destination_name);
    const destination = try std.fs.path.join(gpa, &.{ clone_root, destination_name });
    defer gpa.free(destination);
    if (std.Io.Dir.openDirAbsolute(runner.io, destination, .{})) |dir| {
        dir.close(runner.io);
        return error.TempPathCollision;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.InvalidSource,
    }
    const since_arg = try std.fmt.allocPrint(gpa, "--shallow-since=@{d}", .{options.since});
    defer gpa.free(since_arg);
    const argv = [_][]const u8{
        "git",                "clone",   "--no-checkout", "--no-tags", "--no-single-branch",
        "--filter=blob:none", since_arg, remote.url,      destination,
    };
    var result = runner.git(null, &argv, options.token) catch |err| {
        lifecycle.cleanupClone(runner.io, destination) catch return error.CleanupFailed;
        return err;
    };
    result.deinit(runner.allocator);
    var scanned = scanPath(runner, gpa, options, remote.name, destination) catch |err| {
        lifecycle.cleanupClone(runner.io, destination) catch return error.CleanupFailed;
        return err;
    };
    lifecycle.cleanupClone(runner.io, destination) catch return error.CleanupFailed;
    scanned.location = try gpa.dupe(u8, remote.url);
    return scanned;
}

fn scanPath(runner: *const Runner, gpa: Allocator, options: Options, name: []const u8, path: []const u8) Error!Repository {
    if (name.len == 0 or path.len == 0) return error.InvalidSource;
    const check_argv = [_][]const u8{ "git", "rev-parse", "--is-inside-work-tree" };
    var check = try runner.git(path, &check_argv, null);
    check.deinit(runner.allocator);
    const since_arg = try std.fmt.allocPrint(gpa, "--since=@{d}", .{if (options.since > 0) options.since - 1 else options.since});
    defer gpa.free(since_arg);
    const until_arg = try std.fmt.allocPrint(gpa, "--until=@{d}", .{if (options.until < std.math.maxInt(i64)) options.until + 1 else options.until});
    defer gpa.free(until_arg);
    const argv = [_][]const u8{
        "git",                               "log",     "--all",   "-M", "--numstat", "-z",
        "--format=%x1e%H%x00%at%x00%ae%x00", since_arg, until_arg,
    };
    var output = try runner.git(path, &argv, null);
    defer output.deinit(runner.allocator);
    const commits = try log.parse(gpa, output.stdout, options.author_emails, options.since, options.until);
    var repository = Repository{
        .name = try gpa.dupe(u8, name),
        .location = try gpa.dupe(u8, path),
        .status = .scanned,
        .failure = null,
        .commits = commits,
        .commit_count = commits.len,
        .text_additions = 0,
        .text_deletions = 0,
        .binary_files = 0,
        .renamed_files = 0,
    };
    for (commits) |commit| for (commit.changes) |change| switch (change) {
        .file => |value| {
            if (value.additions != null and value.deletions != null) {
                repository.text_additions += value.additions.?;
                repository.text_deletions += value.deletions.?;
            } else repository.binary_files += 1;
        },
        .rename => |value| {
            repository.renamed_files += 1;
            if (value.additions != null and value.deletions != null) {
                repository.text_additions += value.additions.?;
                repository.text_deletions += value.deletions.?;
            } else repository.binary_files += 1;
        },
    };
    return repository;
}

fn sourceName(source: Source) []const u8 {
    return switch (source) {
        .existing => |value| value.name,
        .remote => |value| value.name,
    };
}

fn validRemoteUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (uri.user != null or uri.password != null) return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "file");
}
fn sourceLocation(source: Source) []const u8 {
    return switch (source) {
        .existing => |value| value.path,
        .remote => |value| value.url,
    };
}

fn failureKind(err: anyerror) FailureKind {
    return switch (err) {
        error.GitCommandFailed => .git_command_failed,
        error.AuthenticationFailed => .authentication_failed,
        error.Timeout => .timeout,
        error.MalformedGitOutput => .malformed_git_output,
        error.CloneRootRequired => .clone_root_required,
        error.InvalidSource, error.InvalidGitCommand => .invalid_input,
        error.TempPathCollision => .temp_path_collision,
        else => .process_failed,
    };
}

test {
    _ = @import("git_activity/tests.zig");
}
