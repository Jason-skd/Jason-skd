//! Git repository lifecycle and structured activity aggregation.

const std = @import("std");
const process = @import("process.zig");
const lifecycle = @import("git_activity/lifecycle.zig");
const log = @import("git_activity/log.zig");
const model = @import("git_activity/model.zig");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;

/// Errors that abort the scan or classify one repository as unavailable.
pub const Error = process.RunError || error{ InvalidSource, InvalidGitCommand, CloneRootRequired, AuthenticationFailed, GitCommandFailed, CleanupFailed, MalformedGitOutput, TempPathCollision };
/// Public source type used by the scan API.
pub const Source = lifecycle.Source;
/// Public Git process runner used by callers that need direct execution.
pub const Runner = lifecycle.Runner;
/// Public repository status model.
pub const RepositoryStatus = model.RepositoryStatus;
/// Public repository failure category model.
pub const FailureKind = model.FailureKind;
/// Public repository failure detail model.
pub const Failure = model.Failure;
/// Public per-file change model.
pub const FileChange = model.FileChange;
/// Public commit model.
pub const Commit = model.Commit;
/// Public repository model.
pub const Repository = model.Repository;
/// Public aggregate model.
pub const Aggregate = model.Aggregate;
/// Public owned scan result.
pub const ScanResult = model.ScanResult;

/// Borrowed inputs, filters, credentials, and resource limits for one scan.
pub const Options = struct {
    /// Sources scanned in declaration order.
    sources: []const Source,
    /// Exact author emails accepted by the parser.
    author_emails: []const []const u8,
    /// Inclusive lower Unix timestamp bound.
    since: i64,
    /// Inclusive upper Unix timestamp bound.
    until: i64,
    /// Total timeout passed to each Git process.
    timeout: Io.Timeout,
    /// Optional token injected into Git's private environment.
    token: ?[]const u8 = null,
    /// Absolute parent directory for temporary remote clones.
    clone_root: ?[]const u8 = null,
    /// Maximum captured Git stdout bytes.
    stdout_limit: usize = 16 * 1024 * 1024,
    /// Maximum captured Git stderr bytes.
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
                .name = try gpa.dupe(u8, source.name()),
                .location = try gpa.dupe(u8, source.location()),
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

/// Dispatches one source to its existing-checkout or temporary-clone lifecycle.
fn scanSource(runner: *const Runner, gpa: Allocator, options: Options, source: Source) Error!Repository {
    return switch (source) {
        .existing => |existing| scanPath(runner, gpa, options, existing.name, existing.path),
        .remote => |remote| scanRemote(runner, gpa, options, remote),
    };
}

/// Clones a bounded remote checkout, scans it, and removes it on every outcome.
fn scanRemote(runner: *const Runner, gpa: Allocator, options: Options, remote: Source.Remote) Error!Repository {
    // Phase 1: validate policy and reserve a collision-free temporary path.
    const clone_root = try validateRemote(options, remote);
    const destination = try makeCloneDestination(runner, gpa, clone_root);
    defer gpa.free(destination);
    const since_arg = try std.fmt.allocPrint(gpa, "--shallow-since=@{d}", .{options.since});
    defer gpa.free(since_arg);
    const argv = [_][]const u8{
        "git",                "clone",   "--no-checkout", "--no-tags", "--no-single-branch",
        "--filter=blob:none", since_arg, remote.url,      destination,
    };
    // Phase 2: clone with the caller's token, then scan the temporary checkout.
    cloneRemote(runner, destination, &argv, options.token) catch |err| return err;
    var scanned = scanPath(runner, gpa, options, remote.name, destination) catch |err| {
        lifecycle.cleanupClone(runner.io, destination) catch return error.CleanupFailed;
        return err;
    };
    // Phase 3: cleanup is part of the lifecycle and can abort the whole scan.
    lifecycle.cleanupClone(runner.io, destination) catch return error.CleanupFailed;
    scanned.location = try gpa.dupe(u8, remote.url);
    return scanned;
}

/// Validates an existing checkout, reads its bounded log, and aggregates changes.
fn scanPath(runner: *const Runner, gpa: Allocator, options: Options, name: []const u8, path: []const u8) Error!Repository {
    if (name.len == 0 or path.len == 0) return error.InvalidSource;
    try validateCheckout(runner, path);
    var output = try readLog(runner, gpa, options, path);
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
    aggregateChanges(&repository, commits);
    return repository;
}

/// Validates the remote-only constraints required for a bounded shallow clone.
fn validateRemote(options: Options, remote: Source.Remote) Error![]const u8 {
    const clone_root = options.clone_root orelse return error.CloneRootRequired;
    if (remote.name.len == 0 or options.since <= 0 or !validRemoteUrl(remote.url) or !std.fs.path.isAbsolute(clone_root)) return error.InvalidSource;
    return clone_root;
}

/// Allocates and collision-checks a temporary clone destination.
///
/// The returned path belongs to `gpa`; the directory does not exist yet.
fn makeCloneDestination(runner: *const Runner, gpa: Allocator, clone_root: []const u8) Error![]u8 {
    var random_bytes: [12]u8 = undefined;
    runner.io.random(&random_bytes);
    var random_name: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&random_name, &random_bytes);
    const destination_name = try std.fmt.allocPrint(gpa, "git-activity-{s}", .{random_name});
    defer gpa.free(destination_name);
    const destination = try std.fs.path.join(gpa, &.{ clone_root, destination_name });
    errdefer gpa.free(destination);
    if (std.Io.Dir.openDirAbsolute(runner.io, destination, .{})) |dir| {
        dir.close(runner.io);
        return error.TempPathCollision;
    } else |err| switch (err) {
        error.FileNotFound => return destination,
        else => return error.InvalidSource,
    }
}

/// Runs the clone command and cleans up a partial checkout after failure.
fn cloneRemote(runner: *const Runner, destination: []const u8, argv: []const []const u8, token: ?[]const u8) Error!void {
    var result = runner.git(null, argv, token) catch |err| {
        lifecycle.cleanupClone(runner.io, destination) catch return error.CleanupFailed;
        return err;
    };
    result.deinit(runner.allocator);
}

/// Confirms that Git recognizes the path as a work tree.
fn validateCheckout(runner: *const Runner, path: []const u8) Error!void {
    const argv = [_][]const u8{ "git", "rev-parse", "--is-inside-work-tree" };
    var result = try runner.git(path, &argv, null);
    result.deinit(runner.allocator);
}

/// Builds inclusive log bounds and returns an owned captured Git log result.
///
/// The caller must deinitialize the result with `runner.allocator`.
fn readLog(runner: *const Runner, gpa: Allocator, options: Options, path: []const u8) Error!process.Result {
    const since_arg = try std.fmt.allocPrint(gpa, "--since=@{d}", .{if (options.since > 0) options.since - 1 else options.since});
    defer gpa.free(since_arg);
    const until_arg = try std.fmt.allocPrint(gpa, "--until=@{d}", .{if (options.until < std.math.maxInt(i64)) options.until + 1 else options.until});
    defer gpa.free(until_arg);
    const argv = [_][]const u8{
        "git",                               "log",     "--all",   "-M", "--numstat", "-z",
        "--format=%x1e%H%x00%at%x00%ae%x00", since_arg, until_arg,
    };
    return runner.git(path, &argv, null);
}

/// Adds text, binary, and rename counts from commits to one repository summary.
fn aggregateChanges(repository: *Repository, commits: []const Commit) void {
    for (commits) |commit| for (commit.changes) |change| switch (change) {
        .file => |value| addChange(repository, value.additions, value.deletions, false),
        .rename => |value| addChange(repository, value.additions, value.deletions, true),
    };
}

/// Adds one file change's counters to the owning repository.
fn addChange(repository: *Repository, additions: ?u64, deletions: ?u64, renamed: bool) void {
    if (renamed) repository.renamed_files += 1;
    if (additions != null and deletions != null) {
        repository.text_additions += additions.?;
        repository.text_deletions += deletions.?;
    } else repository.binary_files += 1;
}

/// Accepts only credential-free HTTPS URLs and local file URLs for tests.
fn validRemoteUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (uri.user != null or uri.password != null) return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "file");
}
/// Maps an internal failure to the stable repository-level failure category.
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
    _ = @import("git_activity/lifecycle.zig");
    _ = @import("git_activity/tests.zig");
}
