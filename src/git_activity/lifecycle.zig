//! Existing-repository validation and bounded remote clone lifecycle.

const std = @import("std");
const process = @import("../process.zig");
const security = @import("../process/secure_allocator.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

/// Identifies either an existing checkout or a remote repository to clone.
pub const Source = union(enum) {
    /// Uses a caller-managed checkout without cloning.
    existing: Existing,
    /// Creates and later removes a bounded temporary clone.
    remote: Remote,

    /// A repository already available on the local filesystem.
    pub const Existing = struct {
        /// Stable display name used in aggregate output.
        name: []const u8,
        /// Checkout path passed to Git.
        path: []const u8,
    };

    /// A repository cloned into temporary storage for one scan.
    pub const Remote = struct {
        /// Stable display name used in aggregate output.
        name: []const u8,
        /// Credential-free remote URL passed to Git.
        url: []const u8,
    };

    /// Returns the borrowed display name for this source.
    pub fn name(source: Source) []const u8 {
        return switch (source) {
            .existing => |value| value.name,
            .remote => |value| value.name,
        };
    }

    /// Returns the borrowed location reported for this source.
    pub fn location(source: Source) []const u8 {
        return switch (source) {
            .existing => |value| value.path,
            .remote => |value| value.url,
        };
    }
};

/// Holds the borrowed process dependencies and limits for Git invocations.
pub const Runner = struct {
    /// Allocator used for command and process-result memory.
    allocator: Allocator,
    /// I/O implementation used by child-process and filesystem operations.
    io: Io,
    /// Base environment cloned before Git-specific overrides are applied.
    environ: *const Environ.Map,
    /// Maximum captured stdout bytes.
    stdout_limit: usize,
    /// Maximum captured stderr bytes.
    stderr_limit: usize,
    /// Total timeout policy for each process invocation.
    timeout: Io.Timeout,

    /// Runs one non-interactive Git command with credential-safe settings.
    ///
    /// A successful result is owned by the caller and must be deinitialized with
    /// `allocator`; unsuccessful process results are released before returning.
    pub fn git(self: *const Runner, cwd: ?[]const u8, argv: []const []const u8, token: ?[]const u8) !process.Result {
        var invocation = try GitInvocation.init(self.allocator, argv, token);
        defer invocation.deinit(self.allocator);
        var result = try process.run(self.allocator, self.io, self.environ, .{
            .argv = invocation.command.items,
            .stdout_limit = self.stdout_limit,
            .stderr_limit = self.stderr_limit,
            .timeout = self.timeout,
            .cwd = cwd,
            .environ_overrides = invocation.overrides[0..invocation.override_count],
            .secrets = invocation.secrets[0..invocation.secret_count],
        });
        if (!result.success()) {
            const authentication_failed = isAuthenticationFailure(result.stderr);
            result.deinit(self.allocator);
            if (authentication_failed) return error.AuthenticationFailed;
            return error.GitCommandFailed;
        }
        return result;
    }
};

/// Owns one command list and all token-derived buffers for an invocation.
const GitInvocation = struct {
    /// Owned argument list whose argument bytes remain borrowed from the caller.
    command: std.ArrayList([]const u8),
    /// Environment overrides passed to Git.
    overrides: [9]process.EnvironmentOverride = undefined,
    /// Number of initialized entries in `overrides`.
    override_count: usize = 0,
    /// Values removed from captured output before it reaches callers.
    secrets: [4][]const u8 = undefined,
    /// Number of initialized entries in `secrets`.
    secret_count: usize = 0,
    /// Token-derived Authorization header.
    header: ?[]u8 = null,
    /// Token-derived username and token payload.
    credentials: ?[]u8 = null,
    /// Base64 representation of `credentials`.
    encoded: ?[]u8 = null,

    /// Builds a non-interactive Git invocation without placing the token in argv.
    fn init(gpa: Allocator, argv: []const []const u8, token: ?[]const u8) !GitInvocation {
        if (argv.len == 0 or !std.mem.eql(u8, argv[0], "git")) return error.InvalidGitCommand;
        var invocation = GitInvocation{ .command = try std.ArrayList([]const u8).initCapacity(gpa, argv.len + 2) };
        errdefer invocation.deinit(gpa);
        try invocation.command.appendSlice(gpa, &.{ "git", "-c", "credential.helper=" });
        try invocation.command.appendSlice(gpa, argv[1..]);

        // Disable every interactive credential fallback before adding optional auth.
        invocation.appendOverride("GIT_TERMINAL_PROMPT", "0");
        invocation.appendOverride("GIT_CONFIG_NOSYSTEM", "1");
        invocation.appendOverride("GIT_ASKPASS", "/usr/bin/false");
        invocation.appendOverride("SSH_ASKPASS", "/usr/bin/false");
        const config_count_index = invocation.override_count;
        invocation.appendOverride("GIT_CONFIG_COUNT", "1");
        invocation.appendOverride("GIT_CONFIG_KEY_0", "http.extraHeader");
        invocation.appendOverride("GIT_CONFIG_VALUE_0", "");
        if (token) |secret| {
            invocation.credentials = try std.fmt.allocPrint(gpa, "x-access-token:{s}", .{secret});
            invocation.encoded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(invocation.credentials.?.len));
            _ = std.base64.standard.Encoder.encode(invocation.encoded.?, invocation.credentials.?);
            invocation.header = try std.fmt.allocPrint(gpa, "Authorization: Basic {s}", .{invocation.encoded.?});
            invocation.overrides[config_count_index].value = "2";
            invocation.appendOverride("GIT_CONFIG_KEY_1", "http.extraHeader");
            invocation.appendOverride("GIT_CONFIG_VALUE_1", invocation.header.?);
            invocation.secrets[0] = secret;
            invocation.secrets[1] = invocation.credentials.?;
            invocation.secrets[2] = invocation.encoded.?;
            invocation.secrets[3] = invocation.header.?;
            invocation.secret_count = 4;
        }
        return invocation;
    }

    /// Releases command memory and securely clears every token-derived buffer.
    fn deinit(self: *GitInvocation, gpa: Allocator) void {
        self.command.deinit(gpa);
        if (self.header) |value| security.secureFree(gpa, value);
        if (self.credentials) |value| security.secureFree(gpa, value);
        if (self.encoded) |value| security.secureFree(gpa, value);
        self.* = undefined;
    }

    /// Appends one fixed-size environment assignment.
    fn appendOverride(self: *GitInvocation, name: []const u8, value: []const u8) void {
        self.overrides[self.override_count] = .{ .name = name, .value = value };
        self.override_count += 1;
    }
};

/// Recognizes Git diagnostics that indicate rejected or unavailable credentials.
fn isAuthenticationFailure(stderr: []const u8) bool {
    const messages = [_][]const u8{
        "authentication failed",
        "could not read username",
        "invalid username or password",
        "returned error: 401",
        "returned error: 403",
    };
    for (messages) |message| {
        if (std.ascii.findIgnoreCasePos(stderr, 0, message) != null) return true;
    }
    return false;
}

/// Removes one temporary clone and maps every filesystem failure to cleanup failure.
pub fn cleanupClone(io: Io, path: []const u8) error{CleanupFailed}!void {
    const parent_path = std.fs.path.dirname(path) orelse return error.CleanupFailed;
    const name = std.fs.path.basename(path);
    var parent = std.Io.Dir.openDirAbsolute(io, parent_path, .{}) catch return error.CleanupFailed;
    defer parent.close(io);
    parent.deleteTree(io, name) catch return error.CleanupFailed;
}

/// Exercises the complete owned invocation lifecycle under allocator failure.
fn allocationFailureInvocation(gpa: Allocator) !void {
    var invocation = try GitInvocation.init(gpa, &.{ "git", "status" }, "secret-token");
    defer invocation.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), invocation.secret_count);
}

test "Git invocation releases every allocation on failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureInvocation,
        .{},
    );
}
