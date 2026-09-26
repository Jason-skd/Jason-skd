//! Production adapter; existing GitHub and Git modules own protocol handling.
const std = @import("std");
const config = @import("config.zig");
const github = @import("github.zig");
const workflow = @import("github_workflow.zig");
const git = @import("git_activity.zig");
const input = @import("application_input.zig");

/// All nested source arenas allocate from this arena and share its lifetime.
pub const OwnedData = struct {
    arena: std.heap.ArenaAllocator,
    value: input.Data,

    pub fn deinit(self: *OwnedData) void {
        self.arena.deinit();
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, cfg: *const config.Config, window: input.Window, token: ?[]const u8) !OwnedData {
    if (token == null or token.?.len == 0) return error.MissingCredential;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const gpa = arena.allocator();
    var client = try github.Client.init(allocator, io, .{ .token = token, .user_agent = "profile-generator" });
    defer client.deinit();
    const profile_result = try workflow.fetchProfile(&client, gpa, .{
        .login = cfg.login,
        .since = window.since,
        .until = window.until,
        .max_contributed_repositories = 100,
    });
    const profile = switch (profile_result) {
        .success => |value| value.value,
        .failure => return error.RequiredGithubData,
    };
    var organization: ?workflow.Organization = null;
    if (cfg.org.login) |login| {
        const result = try workflow.fetchOrganization(&client, gpa, login);
        if (result == .success) organization = result.success.value;
    }
    var sources: std.ArrayList(git.Source) = .empty;
    for (profile.owned_repositories) |repository| try addSource(gpa, &sources, repository.name_with_owner);
    if (cfg.org.repos) |repos| for (repos) |name| {
        try addSource(gpa, &sources, name);
    };
    if (cfg.include_external) for (profile.contributed_repositories) |repository| {
        try addSource(gpa, &sources, repository.name_with_owner);
    };
    var metadata: std.ArrayList(workflow.RepositoryMetadata) = .empty;
    for (sources.items) |source| {
        const result = try workflow.fetchRepositoryMetadata(&client, gpa, source.name());
        if (result == .success) try metadata.append(gpa, result.success.value);
    }
    const activity = try git.scan(gpa, io, environ, .{
        .sources = sources.items,
        .author_emails = cfg.author_emails,
        .since = window.since,
        .until = window.until,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
        .token = token,
        .clone_root = environ.get("TMPDIR") orelse "/tmp",
    });
    return .{ .arena = arena, .value = .{
        .profile = profile,
        .organization = organization,
        .repository_metadata = metadata.items,
        .activity = activity.value,
    } };
}

fn addSource(gpa: std.mem.Allocator, sources: *std.ArrayList(git.Source), name: []const u8) !void {
    for (sources.items) |source| if (std.ascii.eqlIgnoreCase(source.name(), name)) return;
    try sources.append(gpa, .{ .remote = .{ .name = name, .url = try std.fmt.allocPrint(gpa, "https://github.com/{s}.git", .{name}) } });
}
