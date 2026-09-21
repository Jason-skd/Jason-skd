//! Existing-repository validation and bounded remote clone lifecycle.

const std = @import("std");
const process = @import("../process.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

pub const Source = union(enum) {
    existing: Existing,
    remote: Remote,

    pub const Existing = struct { name: []const u8, path: []const u8 };
    pub const Remote = struct {
        name: []const u8,
        url: []const u8,
    };
};

pub const Runner = struct {
    allocator: Allocator,
    io: Io,
    environ: *const Environ.Map,
    stdout_limit: usize,
    stderr_limit: usize,
    timeout: Io.Timeout,

    pub fn git(self: *const Runner, cwd: ?[]const u8, argv: []const []const u8, token: ?[]const u8) !process.Result {
        if (argv.len == 0 or !std.mem.eql(u8, argv[0], "git")) return error.InvalidGitCommand;
        var command = try std.ArrayList([]const u8).initCapacity(self.allocator, argv.len + 2);
        defer command.deinit(self.allocator);
        try command.appendSlice(self.allocator, &.{ "git", "-c", "credential.helper=" });
        try command.appendSlice(self.allocator, argv[1..]);
        var overrides: [9]process.EnvironmentOverride = undefined;
        var count: usize = 0;
        overrides[count] = .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" };
        count += 1;
        overrides[count] = .{ .name = "GIT_CONFIG_NOSYSTEM", .value = "1" };
        count += 1;
        overrides[count] = .{ .name = "GIT_ASKPASS", .value = "/usr/bin/false" };
        count += 1;
        overrides[count] = .{ .name = "SSH_ASKPASS", .value = "/usr/bin/false" };
        count += 1;
        const config_count_index = count;
        overrides[count] = .{ .name = "GIT_CONFIG_COUNT", .value = "1" };
        count += 1;
        overrides[count] = .{ .name = "GIT_CONFIG_KEY_0", .value = "http.extraHeader" };
        count += 1;
        overrides[count] = .{ .name = "GIT_CONFIG_VALUE_0", .value = "" };
        count += 1;
        var header: ?[]u8 = null;
        var credentials: ?[]u8 = null;
        var encoded: ?[]u8 = null;
        defer if (header) |value| @import("../process/secure_allocator.zig").secureFree(self.allocator, value);
        defer if (credentials) |value| @import("../process/secure_allocator.zig").secureFree(self.allocator, value);
        defer if (encoded) |value| @import("../process/secure_allocator.zig").secureFree(self.allocator, value);
        if (token) |secret| {
            credentials = try std.fmt.allocPrint(self.allocator, "x-access-token:{s}", .{secret});
            encoded = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(credentials.?.len));
            _ = std.base64.standard.Encoder.encode(encoded.?, credentials.?);
            header = try std.fmt.allocPrint(self.allocator, "Authorization: Basic {s}", .{encoded.?});
            overrides[config_count_index].value = "2";
            overrides[count] = .{ .name = "GIT_CONFIG_KEY_1", .value = "http.extraHeader" };
            count += 1;
            overrides[count] = .{ .name = "GIT_CONFIG_VALUE_1", .value = header.? };
            count += 1;
        }
        var secrets: [4][]const u8 = undefined;
        const secret_slice: []const []const u8 = if (token) |secret| blk: {
            secrets[0] = secret;
            secrets[1] = credentials.?;
            secrets[2] = encoded.?;
            secrets[3] = header.?;
            break :blk secrets[0..4];
        } else &.{};
        var result = try process.run(self.allocator, self.io, self.environ, .{
            .argv = command.items,
            .stdout_limit = self.stdout_limit,
            .stderr_limit = self.stderr_limit,
            .timeout = self.timeout,
            .cwd = cwd,
            .environ_overrides = overrides[0..count],
            .secrets = secret_slice,
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

pub fn cleanupClone(io: Io, path: []const u8) error{CleanupFailed}!void {
    const parent_path = std.fs.path.dirname(path) orelse return error.CleanupFailed;
    const name = std.fs.path.basename(path);
    var parent = std.Io.Dir.openDirAbsolute(io, parent_path, .{}) catch return error.CleanupFailed;
    defer parent.close(io);
    parent.deleteTree(io, name) catch return error.CleanupFailed;
}
