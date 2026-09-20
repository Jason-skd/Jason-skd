//! Behavioral and allocation-failure tests for the process adapter.

const std = @import("std");
const builtin = @import("builtin");

const process = @import("../process.zig");
const environment = @import("environment.zig");
const redaction = @import("redact.zig");
const security = @import("secure_allocator.zig");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;
const Result = process.Result;
const RunError = process.RunError;
const run = process.run;
const testing = std.testing;

fn testTimeout(seconds: i64) Io.Timeout {
    return .{ .duration = .{
        .raw = .fromSeconds(seconds),
        .clock = .awake,
    } };
}

fn emptyEnvironment() Environ.Map {
    return .init(testing.allocator);
}

fn requireProcessTests() !void {
    if (!std.process.can_spawn or builtin.os.tag == .windows)
        return error.SkipZigTest;
}

test "run validates empty argv and environment overrides" {
    var environ = emptyEnvironment();
    defer environ.deinit();

    try testing.expectError(error.EmptyArgv, run(
        testing.allocator,
        testing.io,
        &environ,
        .{
            .argv = &.{},
            .stdout_limit = 1,
            .stderr_limit = 1,
            .timeout = testTimeout(1),
        },
    ));

    try testing.expectError(error.InvalidEnvironmentName, run(
        testing.allocator,
        testing.io,
        &environ,
        .{
            .argv = &.{"unused"},
            .stdout_limit = 1,
            .stderr_limit = 1,
            .timeout = testTimeout(1),
            .environ_overrides = &.{.{ .name = "BAD=NAME", .value = "value" }},
        },
    ));

    try testing.expectError(error.EnvironmentValueContainsNul, run(
        testing.allocator,
        testing.io,
        &environ,
        .{
            .argv = &.{"unused"},
            .stdout_limit = 1,
            .stderr_limit = 1,
            .timeout = testTimeout(1),
            .environ_overrides = &.{.{ .name = "VALID", .value = "bad\x00value" }},
        },
    ));
}

test "run captures success, environment, cwd, stdin EOF, and non-zero exit" {
    try requireProcessTests();
    var environ = emptyEnvironment();
    defer environment.deinit(&environ);
    try environ.put("PROCESS_ADAPTER_TEST", "base-secret");

    var success_result = try run(testing.allocator, testing.io, &environ, .{
        .argv = &.{ "/usr/bin/printf", "%s", "hello" },
        .stdout_limit = 64,
        .stderr_limit = 64,
        .timeout = testTimeout(5),
    });
    defer success_result.deinit(testing.allocator);
    try testing.expect(success_result.success());
    try testing.expectEqualStrings("hello", success_result.stdout);
    try testing.expectEqualStrings("", success_result.stderr);

    var environment_result = try run(testing.allocator, testing.io, &environ, .{
        .argv = &.{"/usr/bin/env"},
        .stdout_limit = 1024,
        .stderr_limit = 64,
        .timeout = testTimeout(5),
        .environ_overrides = &.{
            .{ .name = "PROCESS_ADAPTER_TEST", .value = "first" },
            .{ .name = "PROCESS_ADAPTER_TEST", .value = "override" },
        },
    });
    defer environment_result.deinit(testing.allocator);
    try testing.expect(std.mem.find(
        u8,
        environment_result.stdout,
        "PROCESS_ADAPTER_TEST=override",
    ) != null);
    try testing.expectEqualStrings("base-secret", environ.get("PROCESS_ADAPTER_TEST").?);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const process_cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(process_cwd);
    const tmp_path = try std.fs.path.join(testing.allocator, &.{
        process_cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer testing.allocator.free(tmp_path);

    var cwd_result = try run(testing.allocator, testing.io, &environ, .{
        .argv = &.{"/bin/pwd"},
        .stdout_limit = 1024,
        .stderr_limit = 64,
        .timeout = testTimeout(5),
        .cwd = tmp_path,
    });
    defer cwd_result.deinit(testing.allocator);
    try testing.expectEqualStrings(
        tmp_path,
        std.mem.trimEnd(u8, cwd_result.stdout, "\r\n"),
    );

    var eof_result = try run(testing.allocator, testing.io, &environ, .{
        .argv = &.{"/bin/cat"},
        .stdout_limit = 64,
        .stderr_limit = 64,
        .timeout = testTimeout(5),
    });
    defer eof_result.deinit(testing.allocator);
    try testing.expect(eof_result.success());
    try testing.expectEqualStrings("", eof_result.stdout);

    var failure_result = try run(testing.allocator, testing.io, &environ, .{
        .argv = &.{ "/bin/sh", "-c", "printf out; printf err >&2; exit 7" },
        .stdout_limit = 64,
        .stderr_limit = 64,
        .timeout = testTimeout(5),
    });
    defer failure_result.deinit(testing.allocator);
    try testing.expect(!failure_result.success());
    try testing.expectEqual(@as(u8, 7), failure_result.term.exited);
    try testing.expectEqualStrings("out", failure_result.stdout);
    try testing.expectEqualStrings("err", failure_result.stderr);

    var redacted_result = try run(testing.allocator, testing.io, &environ, .{
        .argv = &.{
            "/bin/sh",
            "-c",
            "printf 'secret https://user:password@example.com/repo'; " ++
                "printf 'secret https://user@example.com/error' >&2",
        },
        .stdout_limit = 256,
        .stderr_limit = 256,
        .timeout = testTimeout(5),
        .secrets = &.{"secret"},
    });
    defer redacted_result.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "[REDACTED] https://example.com/repo",
        redacted_result.stdout,
    );
    try testing.expectEqualStrings(
        "[REDACTED] https://example.com/error",
        redacted_result.stderr,
    );
}

test "run returns abnormal termination" {
    try requireProcessTests();
    var environ = emptyEnvironment();
    defer environ.deinit();

    var result = try run(testing.allocator, testing.io, &environ, .{
        .argv = &.{ "/bin/sh", "-c", "kill -TERM $$" },
        .stdout_limit = 64,
        .stderr_limit = 64,
        .timeout = testTimeout(5),
    });
    defer result.deinit(testing.allocator);

    try testing.expect(!result.success());
    try testing.expectEqual(std.posix.SIG.TERM, result.term.signal);
}

test "run enforces independent output limits" {
    try requireProcessTests();
    var environ = emptyEnvironment();
    defer environ.deinit();

    try testing.expectError(error.StreamTooLong, run(
        testing.allocator,
        testing.io,
        &environ,
        .{
            .argv = &.{ "/usr/bin/printf", "abcdef" },
            .stdout_limit = 3,
            .stderr_limit = 64,
            .timeout = testTimeout(5),
        },
    ));
    try testing.expectError(error.StreamTooLong, run(
        testing.allocator,
        testing.io,
        &environ,
        .{
            .argv = &.{ "/bin/sh", "-c", "printf abcdef >&2" },
            .stdout_limit = 64,
            .stderr_limit = 3,
            .timeout = testTimeout(5),
        },
    ));
}

test "run applies one total timeout" {
    try requireProcessTests();
    var environ = emptyEnvironment();
    defer environ.deinit();

    try testing.expectError(error.Timeout, run(
        testing.allocator,
        testing.io,
        &environ,
        .{
            .argv = &.{ "/bin/sleep", "60" },
            .stdout_limit = 64,
            .stderr_limit = 64,
            .timeout = .{ .duration = .{
                .raw = .fromMilliseconds(10),
                .clock = .awake,
            } },
        },
    ));
}

test "run preserves caller cancellation" {
    try requireProcessTests();
    var environ = emptyEnvironment();
    defer environ.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const process_cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(process_cwd);
    const ready_path = try std.fs.path.join(testing.allocator, &.{
        process_cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "ready",
    });
    defer testing.allocator.free(ready_path);

    const Context = struct {
        io: Io,
        environ: *const Environ.Map,
        ready_path: []const u8,

        fn execute(context: *@This()) RunError!Result {
            return run(testing.allocator, context.io, context.environ, .{
                .argv = &.{
                    "/bin/sh",
                    "-c",
                    "printf ready > \"$PROCESS_ADAPTER_READY\"; exec /bin/sleep 60",
                },
                .stdout_limit = 64,
                .stderr_limit = 64,
                .timeout = testTimeout(120),
                .environ_overrides = &.{.{
                    .name = "PROCESS_ADAPTER_READY",
                    .value = context.ready_path,
                }},
            });
        }
    };

    var context: Context = .{
        .io = testing.io,
        .environ = &environ,
        .ready_path = ready_path,
    };
    var future = testing.io.concurrent(Context.execute, .{&context}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    defer if (future.cancel(testing.io)) |completed_result| {
        var result = completed_result;
        result.deinit(testing.allocator);
    } else |_| {};

    for (0..5_000) |attempt| {
        var ready_file = tmp.dir.openFile(testing.io, "ready", .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (attempt == 4_999) return error.TestUnexpectedResult;
                try testing.io.sleep(.fromMilliseconds(1), .awake);
                continue;
            },
            else => return err,
        };
        ready_file.close(testing.io);
        break;
    }

    if (future.cancel(testing.io)) |completed_result| {
        var result = completed_result;
        defer result.deinit(testing.allocator);
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(error.Canceled, err);
    }
}

test "redact removes credential URLs and explicit secrets" {
    const input =
        "one secret-value secret secret-value " ++
        "https://user@example.com/user " ++
        "https://user:password@example.com/pass " ++
        "https://user:p@ss@@example.com/multi " ++
        "fatal: unable to access 'https://git:token@example.com/repo/': denied " ++
        "https://user:password@[broken";
    const output = try redaction.redact(testing.allocator, input, &.{
        "",
        "secret",
        "secret-value",
        "secret-value",
    });
    defer security.secureFree(testing.allocator, output);

    try testing.expectEqualStrings(
        "one [REDACTED] [REDACTED] [REDACTED] " ++
            "https://example.com/user " ++
            "https://example.com/pass " ++
            "https://example.com/multi " ++
            "fatal: unable to access 'https://example.com/repo/': denied " ++
            "[REDACTED_URL]",
        output,
    );
    try testing.expect(std.mem.find(u8, output, "secret") == null);
    try testing.expect(std.mem.find(u8, output, "password") == null);
    try testing.expect(std.mem.find(u8, output, "token") == null);
}

test "secure allocator clears memory before freeing" {
    var storage: [64]u8 = @splat(0xaa);
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var secure_allocator: security.SecureAllocator = .{ .backing = fixed.allocator() };
    const allocator = secure_allocator.allocator();

    const bytes = try allocator.alloc(u8, 16);
    @memset(bytes, 0xbb);
    allocator.free(bytes);

    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), storage[0..16]);
}

test "secureFree leaves zeroing as the final write before raw free" {
    var storage: [64]u8 = @splat(0xaa);
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fixed.allocator();

    const bytes = try allocator.alloc(u8, 16);
    @memset(bytes, 0xbb);
    security.secureFree(allocator, bytes);

    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), storage[0..16]);
}

fn allocationFailureRedaction(gpa: Allocator) !void {
    const input = "https://user:password@example.com/path long-secret short";
    const output = try redaction.redact(gpa, input, &.{ "short", "long-secret" });
    defer security.secureFree(gpa, output);
    try testing.expectEqualStrings(
        "https://example.com/path [REDACTED] [REDACTED]",
        output,
    );
}

test "redact releases every allocation on failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        allocationFailureRedaction,
        .{},
    );
}

fn allocationFailureRun(gpa: Allocator, fail_process: bool) !void {
    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var result = try run(gpa, testing.io, &environ, .{
        .argv = if (fail_process)
            &.{ "/bin/sh", "-c", "printf secret >&2; exit 9" }
        else
            &.{ "/usr/bin/printf", "secret" },
        .stdout_limit = 64,
        .stderr_limit = 64,
        .timeout = testTimeout(5),
        .secrets = &.{"secret"},
    });
    defer result.deinit(gpa);

    try testing.expectEqual(!fail_process, result.success());
    if (fail_process) {
        try testing.expectEqual(@as(u8, 9), result.term.exited);
        try testing.expectEqualStrings("[REDACTED]", result.stderr);
    } else {
        try testing.expectEqualStrings("[REDACTED]", result.stdout);
    }
}

test "run releases every allocation on success and process failure" {
    try requireProcessTests();
    try testing.checkAllAllocationFailures(
        testing.allocator,
        allocationFailureRun,
        .{false},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        allocationFailureRun,
        .{true},
    );
}
