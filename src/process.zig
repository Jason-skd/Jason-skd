const std = @import("std");

const environment = @import("process/environment.zig");
const redaction = @import("process/redact.zig");
const security = @import("process/secure_allocator.zig");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;

/// A borrowed environment-variable assignment applied only to the child process.
pub const EnvironmentOverride = environment.Override;

/// Borrowed inputs and resource limits for one child-process execution.
///
/// Every slice remains owned by the caller and only needs to stay valid until
/// `run` returns.
pub const Options = struct {
    /// The executable and its arguments; the first item names the executable.
    argv: []const []const u8,
    /// Maximum raw stdout bytes accepted before returning `error.StreamTooLong`.
    stdout_limit: usize,
    /// Maximum raw stderr bytes accepted before returning `error.StreamTooLong`.
    stderr_limit: usize,
    /// Total time allowed for spawning, reading output, and waiting for exit.
    timeout: Io.Timeout,
    /// Child working directory, or the caller's working directory when null.
    cwd: ?[]const u8 = null,
    /// Assignments applied in order to a private clone of `base_environ`.
    environ_overrides: []const EnvironmentOverride = &.{},
    /// Non-empty byte strings removed from captured output before it is returned.
    secrets: []const []const u8 = &.{},
};

/// Errors that prevent a completed child-process result from being returned.
///
/// Spawn, I/O, allocation, timeout, cancellation, and output-limit errors retain
/// their standard-library identities. A child that exits non-zero or by signal
/// is instead returned as a normal `Result` with a non-successful termination.
pub const RunError = std.process.RunError || environment.ValidationError || error{EmptyArgv};

/// A completed child process and its already-redacted captured output.
///
/// `stdout` and `stderr` are owned allocations from the allocator passed to
/// `run`; call `deinit` with that same allocator when finished.
pub const Result = struct {
    /// The operating-system termination status, including non-zero and signals.
    term: std.process.Child.Term,
    /// Redacted bytes written to the child's normal-output channel.
    stdout: []u8,
    /// Redacted bytes written to the child's diagnostic-output channel.
    stderr: []u8,

    /// Returns true only when the child has a successful termination status.
    pub fn success(result: Result) bool {
        return result.term.success();
    }

    /// Securely clears and frees both captured streams with the allocator from `run`.
    pub fn deinit(result: *Result, gpa: Allocator) void {
        security.secureFree(gpa, result.stdout);
        security.secureFree(gpa, result.stderr);
        result.* = undefined;
    }
};

/// Runs one child process without an interactive stdin and captures both outputs.
///
/// The function clones `base_environ`, applies validated overrides, fixes the
/// timeout to one absolute deadline, and asks `std.process.run` to use ignored
/// stdin while reading stdout and stderr concurrently. Captured bytes are
/// redacted before ownership is returned in `Result`. All arguments and option
/// slices are borrowed only for this call.
pub fn run(
    gpa: Allocator,
    io: Io,
    base_environ: *const Environ.Map,
    options: Options,
) RunError!Result {
    if (options.argv.len == 0) return error.EmptyArgv;
    try environment.validateOverrides(options.environ_overrides);

    var secure_allocator: security.SecureAllocator = .{ .backing = gpa };
    const process_gpa = secure_allocator.allocator();

    var environ = try environment.clone(process_gpa, base_environ);
    defer environment.deinit(&environ);
    try environment.applyOverrides(&environ, options.environ_overrides);

    const raw = try std.process.run(process_gpa, io, .{
        .argv = options.argv,
        .stdout_limit = .limited(options.stdout_limit),
        .stderr_limit = .limited(options.stderr_limit),
        .timeout = options.timeout.toDeadline(io),
        .cwd = if (options.cwd) |cwd| .{ .path = cwd } else .inherit,
        .environ_map = &environ,
    });
    defer process_gpa.free(raw.stdout);
    defer process_gpa.free(raw.stderr);

    const stdout = try redaction.redact(gpa, raw.stdout, options.secrets);
    errdefer security.secureFree(gpa, stdout);
    const stderr = try redaction.redact(gpa, raw.stderr, options.secrets);

    return .{
        .term = raw.term,
        .stdout = stdout,
        .stderr = stderr,
    };
}
