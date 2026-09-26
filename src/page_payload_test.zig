const std = @import("std");
const config = @import("config.zig");
const github_workflow = @import("github_workflow.zig");
const git_activity = @import("git_activity.zig");
const language_stats = @import("language_stats.zig");
const page_payload = @import("page_payload.zig");

const now: i64 = 1_700_000_000;
const empty_contributions: github_workflow.Contributions = .{ .calendar_total = 0, .active_days = 0, .commits = 0, .issues = 0, .pull_requests = 0, .reviews = 0, .repositories_created = 0, .viewer_inaccessible = 0 };

fn fixtureConfig(sections: []const config.Section, org_repos: ?[]const []const u8, include_external: bool, exclude_external: bool) config.Config {
    return .{
        .login = "target",
        .timezone = .asia_shanghai,
        .theme = .{ .base = "000000", .accent = "000000", .cyan = "000000" },
        .author_emails = &.{"owner@example.test"},
        .org = .{ .login = "org", .repos = org_repos },
        .window_days = 30,
        .include_external = include_external,
        .sections = sections,
        .stats = .{ .header = "Stats" },
        .typing = .{ .lines = null, .font = "font", .size = 1, .width = 1, .height = null, .duration = null, .pause = null, .background = null },
        .banner = .{ .height = 1, .instance = null, .text = null, .desc = null, .font_size = null, .font_align = null, .desc_size = null, .desc_align = null },
        .languages = .{ .header = "Languages", .top = 3, .icon_height = 1, .types = null },
        .org_card = .{ .enabled = true, .header = "Org", .logo_height = 1 },
        .recent_project = .{ .enabled = true, .header = "Recent", .icon_height = 1, .exclude_external = exclude_external },
    };
}

fn fixtureProfile(access: github_workflow.Access, repositories: []const github_workflow.Repository, contributed: []const github_workflow.ContributedRepository, contribution: github_workflow.Contributions) github_workflow.Profile {
    return .{ .login = "target", .access = access, .contributions = contribution, .owned_repositories = repositories, .contributed_repositories = contributed };
}

fn fixtureAggregate(repositories: []const git_activity.Repository) git_activity.Aggregate {
    return .{ .repositories = repositories, .repository_count = repositories.len, .unavailable_count = 0, .commit_count = 0, .text_additions = 0, .text_deletions = 0, .binary_files = 0, .renamed_files = 0 };
}

fn commit(timestamp: i64) git_activity.Commit {
    return .{ .id = "commit", .author_email = "owner@example.test", .timestamp = timestamp, .changes = &.{} };
}

fn repository(name: []const u8, commits: []const git_activity.Commit, status: git_activity.RepositoryStatus) git_activity.Repository {
    return .{ .name = name, .location = name, .status = status, .failure = null, .commits = commits, .commit_count = commits.len, .text_additions = 0, .text_deletions = 0, .binary_files = 0, .renamed_files = 0 };
}

fn baseInput(cfg: *const config.Config, profile: *const github_workflow.Profile, activity: *const git_activity.Aggregate, languages: *const language_stats.Result) page_payload.BuildInput {
    return .{ .config = cfg, .profile = profile, .organization = null, .repository_metadata = &.{}, .activity = activity, .languages = languages, .now_utc = now };
}

test "build copies stats and language payloads and preserves public degradation" {
    const repositories = [_]github_workflow.Repository{
        .{ .name = "one", .name_with_owner = "target/one", .description = null, .is_private = false, .stars = 3, .primary_language = null },
        .{ .name = "two", .name_with_owner = "target/two", .description = null, .is_private = false, .stars = 5, .primary_language = null },
    };
    const profile = fixtureProfile(.public_only, &repositories, &.{}, .{ .calendar_total = 9, .active_days = 4, .commits = 5, .issues = 1, .pull_requests = 2, .reviews = 1, .repositories_created = 0, .viewer_inaccessible = 7 });
    const cfg = fixtureConfig(&.{.stats}, null, true, true);
    const activity = fixtureAggregate(&.{});
    const entries = [_]language_stats.Entry{ .{ .name = "Zig", .weight = 10, .percentage_tenths = 667 }, .{ .name = "Go", .weight = 5, .percentage_tenths = 333 } };
    const languages = language_stats.Result{ .allocator = std.testing.allocator, .entries = &entries };
    var built = try page_payload.build(std.testing.allocator, baseInput(&cfg, &profile, &activity, &languages));
    defer built.deinit();
    try std.testing.expectEqual(@as(u64, 8), built.value.stats.stars);
    try std.testing.expectEqual(@as(u64, 9), built.value.stats.contributions);
    try std.testing.expectEqual(@as(u64, 7), built.value.stats.private_contributions);
    try std.testing.expect(built.value.stats.degraded);
    try std.testing.expectEqualStrings("Zig", built.value.languages[0].name);
    try std.testing.expectEqual(@as(u16, 667), built.value.languages[0].percentage_tenths);
}

test "organization is required only for an enabled organization section" {
    const profile = fixtureProfile(.authenticated_as_target, &.{}, &.{}, empty_contributions);
    const activity = fixtureAggregate(&.{});
    const languages = language_stats.Result{ .allocator = std.testing.allocator, .entries = &.{} };
    const enabled_cfg = fixtureConfig(&.{.org_card}, null, true, true);
    try std.testing.expectError(error.MissingOrganization, page_payload.build(std.testing.allocator, baseInput(&enabled_cfg, &profile, &activity, &languages)));
    const disabled_cfg = fixtureConfig(&.{.stats}, null, true, true);
    var built = try page_payload.build(std.testing.allocator, baseInput(&disabled_cfg, &profile, &activity, &languages));
    defer built.deinit();
    try std.testing.expect(built.value.organization == null);
}

test "recent project joins identities case insensitively and uses yesterday tier" {
    const owned = [_]github_workflow.Repository{.{ .name = "repo", .name_with_owner = "Target/Repo", .description = null, .is_private = false, .stars = 0, .primary_language = null }};
    const profile = fixtureProfile(.authenticated_as_target, &owned, &.{}, empty_contributions);
    const cfg = fixtureConfig(&.{.recent_project}, null, true, true);
    const yesterday = now - 24 * 60 * 60;
    const commits = [_]git_activity.Commit{ commit(yesterday), commit(yesterday + 60) };
    const activity_repositories = [_]git_activity.Repository{repository("target/repo", &commits, .scanned)};
    const activity = fixtureAggregate(&activity_repositories);
    const languages = language_stats.Result{ .allocator = std.testing.allocator, .entries = &.{} };
    var input = baseInput(&cfg, &profile, &activity, &languages);
    const metadata = [_]github_workflow.RepositoryMetadata{.{ .name_with_owner = "TARGET/REPO", .description = "A project", .primary_language = "Zig" }};
    input.repository_metadata = &metadata;
    var built = try page_payload.build(std.testing.allocator, input);
    defer built.deinit();
    switch (built.value.recent_project.selection) {
        .none => return error.TestUnexpectedResult,
        .project => |project| {
            try std.testing.expectEqualStrings("target/repo", project.identity);
            try std.testing.expectEqualStrings("repo", project.repository_name);
            try std.testing.expectEqualStrings("A project", project.description.?);
            try std.testing.expectEqualStrings("Zig", project.primary_language.?);
            try std.testing.expectEqual(@as(usize, 2), project.commit_count);
            try std.testing.expectEqual(page_payload.RecentProjectTier.yesterday, project.tier);
        },
    }
}

test "recent project excludes external and unavailable repositories" {
    const profile = fixtureProfile(.authenticated_as_target, &.{}, &.{.{ .name_with_owner = "outside/repo", .owner_login = "outside", .is_private = false }}, empty_contributions);
    const cfg = fixtureConfig(&.{.recent_project}, null, true, true);
    const commits = [_]git_activity.Commit{commit(now - 24 * 60 * 60)};
    const repositories = [_]git_activity.Repository{ repository("outside/repo", &commits, .scanned), repository("broken/repo", &commits, .unavailable) };
    const activity = fixtureAggregate(&repositories);
    const languages = language_stats.Result{ .allocator = std.testing.allocator, .entries = &.{} };
    var built = try page_payload.build(std.testing.allocator, baseInput(&cfg, &profile, &activity, &languages));
    defer built.deinit();
    try std.testing.expect(built.value.recent_project.selection == .none);
    try std.testing.expectEqual(@as(u32, 30), built.value.recent_project.window_days);
}

test "stars overflow, malformed identity, and metadata conflict are structured errors" {
    const repositories = [_]github_workflow.Repository{
        .{ .name = "a", .name_with_owner = "target/a", .description = null, .is_private = false, .stars = std.math.maxInt(u64), .primary_language = null },
        .{ .name = "b", .name_with_owner = "target/b", .description = null, .is_private = false, .stars = 1, .primary_language = null },
    };
    const profile = fixtureProfile(.authenticated_as_target, &repositories, &.{}, empty_contributions);
    const cfg = fixtureConfig(&.{.stats}, null, true, true);
    const activity = fixtureAggregate(&.{});
    const languages = language_stats.Result{ .allocator = std.testing.allocator, .entries = &.{} };
    try std.testing.expectError(error.NumericOverflow, page_payload.build(std.testing.allocator, baseInput(&cfg, &profile, &activity, &languages)));
    const valid_profile = fixtureProfile(.authenticated_as_target, &.{}, &.{}, empty_contributions);
    const recent_cfg = fixtureConfig(&.{.recent_project}, null, true, true);
    const commits = [_]git_activity.Commit{commit(now - 24 * 60 * 60)};
    const malformed = [_]git_activity.Repository{repository("malformed", &commits, .scanned)};
    const malformed_activity = fixtureAggregate(&malformed);
    try std.testing.expectError(error.InvalidRepositoryIdentity, page_payload.build(std.testing.allocator, baseInput(&recent_cfg, &valid_profile, &malformed_activity, &languages)));
    const metadata = [_]github_workflow.RepositoryMetadata{
        .{ .name_with_owner = "target/repo", .description = "one", .primary_language = null },
        .{ .name_with_owner = "TARGET/REPO", .description = "two", .primary_language = null },
    };
    const owned = [_]github_workflow.Repository{.{ .name = "repo", .name_with_owner = "target/repo", .description = null, .is_private = false, .stars = 0, .primary_language = null }};
    const conflict_profile = fixtureProfile(.authenticated_as_target, &owned, &.{}, empty_contributions);
    const conflict_commits = [_]git_activity.Commit{commit(now - 24 * 60 * 60)};
    const conflict_repositories = [_]git_activity.Repository{repository("target/repo", &conflict_commits, .scanned)};
    const conflict_activity = fixtureAggregate(&conflict_repositories);
    var conflict_input = baseInput(&recent_cfg, &conflict_profile, &conflict_activity, &languages);
    conflict_input.repository_metadata = &metadata;
    try std.testing.expectError(error.RepositoryIdentityConflict, page_payload.build(std.testing.allocator, conflict_input));
}

fn allocationFailureBuild(allocator: std.mem.Allocator) !void {
    const owned = [_]github_workflow.Repository{.{ .name = "repo", .name_with_owner = "target/repo", .description = null, .is_private = false, .stars = 1, .primary_language = null }};
    const profile = fixtureProfile(.authenticated_as_target, &owned, &.{}, empty_contributions);
    const cfg = fixtureConfig(&.{.recent_project}, null, true, true);
    const commits = [_]git_activity.Commit{commit(now - 24 * 60 * 60)};
    const repositories = [_]git_activity.Repository{repository("target/repo", &commits, .scanned)};
    const activity = fixtureAggregate(&repositories);
    const entries = [_]language_stats.Entry{.{ .name = "Zig", .weight = 1, .percentage_tenths = 1000 }};
    const languages = language_stats.Result{ .allocator = allocator, .entries = &entries };
    var built = try page_payload.build(allocator, baseInput(&cfg, &profile, &activity, &languages));
    defer built.deinit();
}

test "recent selection uses the configured window and preserves it in empty payloads" {
    const owned = [_]github_workflow.Repository{.{ .name = "repo", .name_with_owner = "target/repo", .description = null, .is_private = false, .stars = 0, .primary_language = null }};
    const profile = fixtureProfile(.authenticated_as_target, &owned, &.{}, empty_contributions);
    const languages = language_stats.Result{ .allocator = std.testing.allocator, .entries = &.{} };
    const cases = [_]struct { days: u32, age: i64, selected: bool }{
        .{ .days = 365, .age = 60, .selected = true },
        .{ .days = 365, .age = 61, .selected = true },
        .{ .days = 365, .age = 365, .selected = true },
        .{ .days = 365, .age = 366, .selected = false },
        .{ .days = 30, .age = 30, .selected = true },
        .{ .days = 30, .age = 31, .selected = false },
        .{ .days = 365, .age = 0, .selected = false },
        .{ .days = 365, .age = -1, .selected = false },
    };
    for (cases) |case| {
        var cfg = fixtureConfig(&.{.recent_project}, null, true, true);
        cfg.window_days = case.days;
        const commits = [_]git_activity.Commit{commit(now - case.age * 86400)};
        const repositories = [_]git_activity.Repository{repository("target/repo", &commits, .scanned)};
        const activity = fixtureAggregate(&repositories);
        var built = try page_payload.build(std.testing.allocator, baseInput(&cfg, &profile, &activity, &languages));
        defer built.deinit();
        try std.testing.expectEqual(case.selected, built.value.recent_project.selection == .project);
        try std.testing.expectEqual(case.days, built.value.recent_project.window_days);
        try std.testing.expectEqual(case.days, built.value.stats.window_days);
    }
}

test "recent selection uses UTC plus eight midnight and excludes today's commits" {
    const midnight = @divFloor(now + 8 * 3600, 86400) * 86400 - 8 * 3600;
    const owned = [_]github_workflow.Repository{.{ .name = "repo", .name_with_owner = "target/repo", .description = null, .is_private = false, .stars = 0, .primary_language = null }};
    const profile = fixtureProfile(.authenticated_as_target, &owned, &.{}, empty_contributions);
    const cfg = fixtureConfig(&.{.recent_project}, null, true, true);
    const languages = language_stats.Result{ .allocator = std.testing.allocator, .entries = &.{} };
    const commits = [_]git_activity.Commit{ commit(midnight - 1), commit(midnight), commit(midnight + 1) };
    const repositories = [_]git_activity.Repository{repository("target/repo", &commits, .scanned)};
    const activity = fixtureAggregate(&repositories);
    var input = baseInput(&cfg, &profile, &activity, &languages);
    input.now_utc = midnight;
    var built = try page_payload.build(std.testing.allocator, input);
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, 1), built.value.recent_project.selection.project.commit_count);
    try std.testing.expectEqual(page_payload.RecentProjectTier.yesterday, built.value.recent_project.selection.project.tier);
}

test "zero collection window is rejected even without recent projects" {
    var cfg = fixtureConfig(&.{.stats}, null, true, true);
    cfg.window_days = 0;
    const profile = fixtureProfile(.authenticated_as_target, &.{}, &.{}, empty_contributions);
    const activity = fixtureAggregate(&.{});
    const languages = language_stats.Result{ .allocator = std.testing.allocator, .entries = &.{} };
    try std.testing.expectError(error.InvalidWindow, page_payload.build(std.testing.allocator, baseInput(&cfg, &profile, &activity, &languages)));
}

test "complete page payload construction releases allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureBuild, .{});
}
