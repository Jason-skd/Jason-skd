const std = @import("std");

pub const config = @import("config.zig");
pub const cli = @import("cli.zig");
pub const github = @import("github.zig");
pub const github_workflow = @import("github_workflow.zig");
pub const git_activity = @import("git_activity.zig");
pub const language_catalog_generator = @import("language_catalog_generator.zig");
pub const language_catalog_snapshot = @import("language_catalog_snapshot.zig");
pub const language_catalog = @import("language_catalog.zig");
pub const language_stats = @import("language_stats.zig");
pub const page_payload = @import("page_payload.zig");
pub const render = @import("render.zig");
pub const render_page = @import("render_page.zig");
pub const application = @import("application.zig");
pub const output = @import("output.zig");

/// Converts structured failures to bounded diagnostics at the process boundary.
pub fn run(init: std.process.Init) u8 {
    const now_utc = std.Io.Timestamp.now(init.io, .real).toSeconds();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        report(&stderr, "arguments", "OutOfMemory");
        return 1;
    };
    var diagnostic: cli.Diagnostic = .{};
    const command = cli.parse(init.gpa, args[1..], init.environ_map, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) {
            report(&stderr, "arguments", "OutOfMemory");
            return 1;
        }
        // clap's detailed diagnostic echoes argv; argv can contain credentials.
        report(&stderr, "arguments", "InvalidArguments");
        return 2;
    };
    switch (command) {
        .help => {
            cli.writeHelp(&stdout.interface) catch {
                report(&stderr, "output", "WriteFailed");
                return 1;
            };
            stdout.flush() catch {
                report(&stderr, "output", "WriteFailed");
                return 1;
            };
        },
        .run => |options| {
            const markdown = application.generate(init.gpa, init.io, init.environ_map, options, now_utc) catch |err| {
                report(&stderr, "application", @errorName(err));
                return 1;
            };
            defer init.gpa.free(markdown);
            output.deliver(init.io, options.output_path orelse "README.md", markdown, options.dry_run, &stdout.interface) catch {
                report(&stderr, "output", "DeliveryFailed");
                return 1;
            };
        },
    }
    return 0;
}

fn report(stderr: *std.Io.File.Writer, category: []const u8, cause: []const u8) void {
    stderr.interface.print("profile-generator: {s}: {s}\n", .{ category, cause }) catch return;
    stderr.flush() catch {};
}

test {
    _ = output;
    _ = application;
    _ = @import("application_input.zig");
    _ = config;
    _ = cli;
    _ = @import("dependency_validation.zig");
    _ = @import("process.zig");
    _ = github;
    _ = github_workflow;
    _ = git_activity;
    _ = language_catalog_generator;
    _ = language_catalog_snapshot;
    _ = language_catalog;
    _ = language_stats;
    _ = page_payload;
    _ = render;
    _ = render_page;
}
