const std = @import("std");

const clap = @import("clap");

const parameters = clap.parseParamsComptime(
    \\-h, --help         Display help and exit.
    \\--config <PATH>    Path to the profile configuration.
    \\--output <PATH>    Path to the generated output.
    \\--fixtures <DIR>   Read data from an offline fixture directory.
    \\--dry-run          Validate and render without writing output.
    \\
);

const value_parsers = .{
    .PATH = clap.parsers.string,
    .DIR = clap.parsers.string,
};

/// Borrowed inputs needed by the profile generation application.
pub const ApplicationInput = struct {
    /// Profile configuration path borrowed from argv, or the static default.
    config_path: []const u8 = "profile.yaml",
    /// Output path borrowed from argv when explicitly provided.
    output_path: ?[]const u8 = null,
    /// Offline fixture directory borrowed from argv when explicitly provided.
    fixtures_path: ?[]const u8 = null,
    /// Whether the application should avoid writing generated output.
    dry_run: bool = false,
    /// GitHub credential borrowed from the environment map when available.
    github_token: ?[]const u8 = null,
};

/// Action selected by parsing the command line.
pub const Command = union(enum) {
    /// Render help without running the application.
    help,
    /// Run the application with the parsed inputs.
    run: ApplicationInput,
};

/// Parser context used to render a failed parse operation.
pub const Diagnostic = struct {
    /// Diagnostic details populated by zig-clap.
    clap_diagnostic: clap.Diagnostic = .{},
};

/// Parses arguments after the executable name. String fields in the returned
/// command borrow from `argv` and `environ_map`.
pub fn parse(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    environ_map: *const std.process.Environ.Map,
    diagnostic: *Diagnostic,
) !Command {
    var iterator: clap.args.SliceIterator = .{ .args = argv };
    var result = try clap.parseEx(
        clap.Help,
        &parameters,
        value_parsers,
        &iterator,
        .{
            .allocator = allocator,
            .diagnostic = &diagnostic.clap_diagnostic,
        },
    );
    defer result.deinit();

    if (result.args.help != 0) return .help;

    return .{ .run = .{
        .config_path = result.args.config orelse "profile.yaml",
        .output_path = result.args.output,
        .fixtures_path = result.args.fixtures,
        .dry_run = @field(result.args, "dry-run") != 0,
        .github_token = resolveGithubToken(environ_map),
    } };
}

/// Writes command usage and supported options.
pub fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: profile-generator [OPTIONS]
        \\
        \\Options:
        \\
    );
    try clap.help(writer, clap.Help, &parameters, .{
        .indent = 2,
        .spacing_between_parameters = 0,
    });
}

/// Writes a human-readable diagnostic for a parsing error.
pub fn writeDiagnostic(
    diagnostic: Diagnostic,
    writer: *std.Io.Writer,
    err: anyerror,
) !void {
    try diagnostic.clap_diagnostic.report(writer, err);
}

fn resolveGithubToken(environ_map: *const std.process.Environ.Map) ?[]const u8 {
    if (environ_map.get("PROFILE_PAT")) |token| {
        if (token.len != 0) return token;
    }
    if (environ_map.get("GITHUB_TOKEN")) |token| {
        if (token.len != 0) return token;
    }
    return null;
}

fn expectRun(command: Command) !ApplicationInput {
    return switch (command) {
        .run => |input| input,
        .help => error.ExpectedRunCommand,
    };
}

test "parse uses application defaults" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();

    var diagnostic: Diagnostic = .{};
    const input = try expectRun(try parse(
        std.testing.allocator,
        &.{},
        &environ_map,
        &diagnostic,
    ));

    try std.testing.expectEqualStrings("profile.yaml", input.config_path);
    try std.testing.expectEqual(@as(?[]const u8, null), input.output_path);
    try std.testing.expectEqual(@as(?[]const u8, null), input.fixtures_path);
    try std.testing.expect(!input.dry_run);
    try std.testing.expectEqual(@as(?[]const u8, null), input.github_token);
}

test "parse accepts all explicit application inputs" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("PROFILE_PAT", "profile-secret");

    const argv = [_][]const u8{
        "--config",
        "config/custom.yaml",
        "--output",
        "build/profile.md",
        "--fixtures",
        "test/fixtures",
        "--dry-run",
    };
    var diagnostic: Diagnostic = .{};
    const input = try expectRun(try parse(
        std.testing.allocator,
        &argv,
        &environ_map,
        &diagnostic,
    ));

    try std.testing.expectEqualStrings(argv[1], input.config_path);
    try std.testing.expectEqualStrings(argv[3], input.output_path.?);
    try std.testing.expectEqualStrings(argv[5], input.fixtures_path.?);
    try std.testing.expect(input.dry_run);
    try std.testing.expectEqualStrings("profile-secret", input.github_token.?);
    try std.testing.expectEqual(argv[1].ptr, input.config_path.ptr);
    try std.testing.expectEqual(
        environ_map.get("PROFILE_PAT").?.ptr,
        input.github_token.?.ptr,
    );
}

test "parse accepts long option assignment syntax" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();

    var diagnostic: Diagnostic = .{};
    const input = try expectRun(try parse(
        std.testing.allocator,
        &.{
            "--config=assigned.yaml",
            "--output=assigned.md",
            "--fixtures=fixtures/assigned",
        },
        &environ_map,
        &diagnostic,
    ));

    try std.testing.expectEqualStrings("assigned.yaml", input.config_path);
    try std.testing.expectEqualStrings("assigned.md", input.output_path.?);
    try std.testing.expectEqualStrings("fixtures/assigned", input.fixtures_path.?);
}

test "parse returns help command for either help option" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();

    for ([_][]const u8{ "-h", "--help" }) |help_option| {
        var diagnostic: Diagnostic = .{};
        const command = try parse(
            std.testing.allocator,
            &.{help_option},
            &environ_map,
            &diagnostic,
        );
        try std.testing.expect(command == .help);
    }
}

test "parse reports unknown options positionals and missing values" {
    const Case = struct {
        argv: []const []const u8,
        expected_error: anyerror,
        expected_diagnostic: []const u8,
    };
    const cases = [_]Case{
        .{
            .argv = &.{"--unknown"},
            .expected_error = error.InvalidArgument,
            .expected_diagnostic = "Invalid argument '--unknown'\n",
        },
        .{
            .argv = &.{"unexpected"},
            .expected_error = error.InvalidArgument,
            .expected_diagnostic = "Invalid argument 'unexpected'\n",
        },
        .{
            .argv = &.{"--config"},
            .expected_error = error.MissingValue,
            .expected_diagnostic = "The argument '--config' requires a value but none was supplied\n",
        },
    };

    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();

    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(case.expected_error, parse(
            std.testing.allocator,
            case.argv,
            &environ_map,
            &diagnostic,
        ));

        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writeDiagnostic(diagnostic, &writer, case.expected_error);
        try std.testing.expectEqualStrings(case.expected_diagnostic, writer.buffered());
    }
}

test "token resolution uses non-empty PROFILE_PAT before GITHUB_TOKEN" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("PROFILE_PAT", "preferred-secret");
    try environ_map.put("GITHUB_TOKEN", "fallback-secret");

    var diagnostic: Diagnostic = .{};
    const input = try expectRun(try parse(
        std.testing.allocator,
        &.{},
        &environ_map,
        &diagnostic,
    ));

    try std.testing.expectEqualStrings("preferred-secret", input.github_token.?);
}

test "token resolution falls back from empty values" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("PROFILE_PAT", "");
    try environ_map.put("GITHUB_TOKEN", "fallback-secret");

    var diagnostic: Diagnostic = .{};
    const fallback_input = try expectRun(try parse(
        std.testing.allocator,
        &.{},
        &environ_map,
        &diagnostic,
    ));
    try std.testing.expectEqualStrings("fallback-secret", fallback_input.github_token.?);

    try environ_map.put("GITHUB_TOKEN", "");
    const missing_input = try expectRun(try parse(
        std.testing.allocator,
        &.{},
        &environ_map,
        &diagnostic,
    ));
    try std.testing.expectEqual(@as(?[]const u8, null), missing_input.github_token);
}

test "help and diagnostics never include environment credentials" {
    const secret = "github_pat_secret_value_for_redaction_test";
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("PROFILE_PAT", secret);

    var help_buffer: [1024]u8 = undefined;
    var help_writer = std.Io.Writer.fixed(&help_buffer);
    try writeHelp(&help_writer);
    const help_text = help_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, help_text, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "--data-dir") == null);
    for ([_][]const u8{ "--help", "--config", "--output", "--fixtures", "--dry-run" }) |option| {
        try std.testing.expect(std.mem.indexOf(u8, help_text, option) != null);
    }

    var diagnostic: Diagnostic = .{};
    _ = parse(
        std.testing.allocator,
        &.{"--unknown"},
        &environ_map,
        &diagnostic,
    ) catch |err| {
        var diagnostic_buffer: [256]u8 = undefined;
        var diagnostic_writer = std.Io.Writer.fixed(&diagnostic_buffer);
        try writeDiagnostic(diagnostic, &diagnostic_writer, err);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic_writer.buffered(), secret) == null);
        return;
    };
    return error.ExpectedParseError;
}
