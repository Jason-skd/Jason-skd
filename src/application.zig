//! Collects source values and builds a whole page before any output is opened.
const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const input = @import("application_input.zig");
const fixture = @import("application_fixture.zig");
const source = @import("application_source.zig");
const language_stats = @import("language_stats.zig");
const payload = @import("page_payload.zig");
const render = @import("render_page.zig");

/// Stable categories; internal response bodies, paths and credentials never
/// cross this boundary. OOM and cancellation keep their own identity.
pub const Error = error{ Configuration, Fixture, MissingCredential, RequiredGithubData, Source, Languages, Payload, Render, InvalidWindow, OutOfMemory, Canceled };

pub fn generate(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, options: cli.ApplicationInput, now_utc: i64) Error![]u8 {
    const yaml = std.Io.Dir.cwd().readFileAlloc(io, options.config_path, allocator, .limited(1024 * 1024)) catch |err| return classify(err, error.Configuration);
    defer allocator.free(yaml);
    var diagnostic: config.Diagnostic = .{};
    const parsed = config.parse(allocator, yaml, &diagnostic) catch |err| return classify(err, error.Configuration);
    defer parsed.deinit();
    const cfg = &parsed.value;
    if (options.fixtures_path) |path| {
        const snapshot = fixture.load(allocator, io, path) catch |err| return classify(err, error.Fixture);
        defer snapshot.deinit();
        _ = input.Window.init(snapshot.value.now_utc, cfg.window_days) catch return error.InvalidWindow;
        const data = snapshot.value.data orelse return error.RequiredGithubData;
        return renderData(allocator, cfg, data, snapshot.value.now_utc);
    }
    const window = input.Window.init(now_utc, cfg.window_days) catch return error.InvalidWindow;
    var data = source.load(allocator, io, environ, cfg, window, options.github_token) catch |err| return switch (err) {
        error.MissingCredential => error.MissingCredential,
        error.RequiredGithubData => error.RequiredGithubData,
        else => classify(err, error.Source),
    };
    defer data.deinit();
    return renderData(allocator, cfg, data.value, now_utc);
}

fn renderData(allocator: std.mem.Allocator, cfg: *const config.Config, data: input.Data, now_utc: i64) Error![]u8 {
    const languages = language_stats.aggregate(allocator, data.activity.repositories, cfg.languages.top) catch |err| return classify(err, error.Languages);
    defer languages.deinit();
    const page = payload.build(allocator, .{
        .config = cfg,
        .profile = &data.profile,
        .organization = if (data.organization) |*org| org else null,
        .repository_metadata = data.repository_metadata,
        .activity = &data.activity,
        .languages = &languages,
        .now_utc = now_utc,
    }) catch |err| return classify(err, error.Payload);
    defer page.deinit();
    return render.assemble(allocator, cfg, &page.value) catch |err| return classify(err, error.Render);
}

fn classify(err: anyerror, category: Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => category,
    };
}

test "fixture pipeline renders all sections offline and maps required data failures" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const options: cli.ApplicationInput = .{
        .config_path = "tests/fixtures/application/profile.yaml",
        .fixtures_path = "tests/fixtures/application/success",
    };
    var vtable = std.testing.io.vtable.*;
    vtable.processSpawn = std.Io.failing.vtable.processSpawn;
    vtable.processSpawnPath = std.Io.failing.vtable.processSpawnPath;
    vtable.netConnectIp = std.Io.failing.vtable.netConnectIp;
    vtable.netConnectUnix = std.Io.failing.vtable.netConnectUnix;
    vtable.netLookup = std.Io.failing.vtable.netLookup;
    var offline_io = std.testing.io;
    offline_io.vtable = &vtable;
    const page = try generate(gpa, offline_io, &env, options, 0);
    defer gpa.free(page);
    for ([_][]const u8{ "AUTO-GENERATED", "Activity Window", "Languages", "Octavia Labs", "Fixture metadata", "Building" }) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, page, marker) != null);
    }
    var changed = options;
    changed.fixtures_path = "tests/fixtures/application/local-failure";
    const partial = try generate(gpa, std.testing.io, &env, changed, 0);
    defer gpa.free(partial);
    try std.testing.expectEqualStrings(page, partial);
    changed.fixtures_path = "tests/fixtures/application/missing";
    try std.testing.expectError(error.RequiredGithubData, generate(gpa, std.testing.io, &env, changed, 0));
    changed.fixtures_path = "tests/fixtures/application/empty";
    try std.testing.expectError(error.Render, generate(gpa, std.testing.io, &env, changed, 0));
    changed.fixtures_path = null;
    try std.testing.expectError(error.MissingCredential, generate(gpa, std.testing.io, &env, changed, 1800000000));
    changed.config_path = "tests/fixtures/config/invalid_missing_login.yaml";
    try std.testing.expectError(error.Configuration, generate(gpa, std.testing.io, &env, changed, 1800000000));
}

test "optional metadata and organization obey enabled section requirements" {
    const gpa = std.testing.allocator;
    const loaded = try fixture.load(gpa, std.testing.io, "tests/fixtures/application/success");
    defer loaded.deinit();
    const yaml = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/application/profile.yaml", gpa, .limited(10000));
    defer gpa.free(yaml);
    var diagnostic: config.Diagnostic = .{};
    var parsed = try config.parse(gpa, yaml, &diagnostic);
    defer parsed.deinit();
    var data = loaded.value.data.?;
    data.organization = null;
    try std.testing.expectError(error.Payload, renderData(gpa, &parsed.value, data, loaded.value.now_utc));
    parsed.value.org_card.enabled = false;
    data.repository_metadata = &.{};
    const page = try renderData(gpa, &parsed.value, data, loaded.value.now_utc);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Offline project") != null);
    data.activity.repositories = &.{};
    parsed.value.sections = &.{ .stats, .recent_project };
    const empty = try renderData(gpa, &parsed.value, data, loaded.value.now_utc);
    defer gpa.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "AUTO-GENERATED") != null);
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const page = try generate(gpa, std.testing.io, &env, .{
        .config_path = "tests/fixtures/application/profile.yaml",
        .fixtures_path = "tests/fixtures/application/success",
    }, 0);
    defer gpa.free(page);
}

test "fixture pipeline releases allocations at every failed allocation" {
    // In-place remapping by the backing allocator can vary between iterations.
    // Force allocate/copy growth so the failure sweep has a stable sequence.
    var vtable = std.testing.allocator.vtable.*;
    vtable.resize = std.mem.Allocator.noResize;
    vtable.remap = std.mem.Allocator.noRemap;
    var backing = std.testing.allocator;
    backing.vtable = &vtable;
    try std.testing.checkAllAllocationFailures(backing, allocationScenario, .{});
}
