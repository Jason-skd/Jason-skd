//! Converts completed source-domain values into renderer-owned page payloads.

const std = @import("std");
const config = @import("config.zig");
const github_workflow = @import("github_workflow.zig");
const git_activity = @import("git_activity.zig");
const language_stats = @import("language_stats.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{
    MissingOrganization,
    InvalidRepositoryIdentity,
    RepositoryIdentityConflict,
    NumericOverflow,
    InvalidRecentProjectInput,
    InvalidWindow,
};

pub const ContributionBreakdown = struct {
    commits: u64,
    issues: u64,
    pull_requests: u64,
    reviews: u64,
    repositories_created: u64,
};

pub const StatsPayload = struct {
    stars: u64,
    contributions: u64,
    active_days: u32,
    window_days: u32,
    breakdown: ContributionBreakdown,
    private_contributions: u64,
    degraded: bool,
};

pub const LanguagePayload = struct {
    name: []const u8,
    weight: u64,
    /// Tenths of a percentage point, copied without rounding from statistics.
    percentage_tenths: u16,
};

pub const OrganizationPayload = struct {
    display_name: []const u8,
    avatar_url: []const u8,
    github_url: []const u8,
};

pub const RecentProjectTier = enum { yesterday, recently };

pub const RecentProjectPayload = struct {
    identity: []const u8,
    repository_name: []const u8,
    github_url: []const u8,
    description: ?[]const u8,
    primary_language: ?[]const u8,
    commit_count: usize,
    tier: RecentProjectTier,
};

pub const RecentProject = union(enum) {
    none,
    project: RecentProjectPayload,
};

/// The queried window remains available even when no eligible project exists.
pub const RecentProjectSection = struct {
    window_days: u32,
    selection: RecentProject,
};

pub const Page = struct {
    stats: StatsPayload,
    languages: []const LanguagePayload,
    organization: ?OrganizationPayload,
    recent_project: RecentProjectSection,
};

pub const OwnedPage = struct {
    arena: *std.heap.ArenaAllocator,
    value: Page,

    pub fn deinit(self: OwnedPage) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

pub const BuildInput = struct {
    /// The caller must use this configuration's window_days for source queries
    /// as well as payload construction. It is not inferred from commit dates.
    config: *const config.Config,
    profile: *const github_workflow.Profile,
    organization: ?*const github_workflow.Organization,
    repository_metadata: []const github_workflow.RepositoryMetadata,
    activity: *const git_activity.Aggregate,
    languages: *const language_stats.Result,
    now_utc: i64,
};

const Identity = struct { owner: []const u8, name: []const u8 };

const Metadata = struct {
    identity: []const u8,
    description: ?[]const u8,
    primary_language: ?[]const u8,
};

const Candidate = struct {
    identity: []const u8,
    day: i64,
    commit_count: usize,
    last_timestamp: i64,
};

pub fn build(allocator: Allocator, input: BuildInput) Error!OwnedPage {
    if (input.config.window_days == 0) return error.InvalidWindow;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const gpa = arena.allocator();

    const stats = try buildStats(input.config, input.profile);
    const languages = try buildLanguages(gpa, input.languages);
    const organization = try buildOrganization(gpa, input.config, input.organization);
    const recent_project = try buildRecentProject(gpa, input);

    return .{ .arena = arena, .value = .{
        .stats = stats,
        .languages = languages,
        .organization = organization,
        .recent_project = .{ .window_days = input.config.window_days, .selection = recent_project },
    } };
}

fn buildStats(cfg: *const config.Config, profile: *const github_workflow.Profile) Error!StatsPayload {
    var stars: u64 = 0;
    for (profile.owned_repositories) |repository| {
        stars = std.math.add(u64, stars, repository.stars) catch return error.NumericOverflow;
    }
    const contributions = profile.contributions;
    return .{
        .stars = stars,
        .contributions = contributions.calendar_total,
        .active_days = contributions.active_days,
        .window_days = cfg.window_days,
        .breakdown = .{
            .commits = contributions.commits,
            .issues = contributions.issues,
            .pull_requests = contributions.pull_requests,
            .reviews = contributions.reviews,
            .repositories_created = contributions.repositories_created,
        },
        .private_contributions = contributions.viewer_inaccessible,
        .degraded = profile.access == .public_only,
    };
}

fn buildLanguages(gpa: Allocator, source: *const language_stats.Result) Allocator.Error![]const LanguagePayload {
    const result = try gpa.alloc(LanguagePayload, source.entries.len);
    for (source.entries, result) |entry, *destination| {
        destination.* = .{
            .name = try gpa.dupe(u8, entry.name),
            .weight = entry.weight,
            .percentage_tenths = entry.percentage_tenths,
        };
    }
    return result;
}

fn buildOrganization(
    gpa: Allocator,
    cfg: *const config.Config,
    source: ?*const github_workflow.Organization,
) Error!?OrganizationPayload {
    if (!hasSection(cfg, .org_card) or !cfg.org_card.enabled) return null;
    const organization = source orelse return error.MissingOrganization;
    if (organization.avatar_url.len == 0 or organization.html_url.len == 0 or
        !isCompleteUrl(organization.avatar_url) or !isCompleteUrl(organization.html_url))
        return error.InvalidRecentProjectInput;
    const display_name = if (organization.display_name) |value| if (value.len != 0) value else organization.login else organization.login;
    return .{
        .display_name = try gpa.dupe(u8, display_name),
        .avatar_url = try gpa.dupe(u8, organization.avatar_url),
        .github_url = try gpa.dupe(u8, organization.html_url),
    };
}

fn buildRecentProject(gpa: Allocator, input: BuildInput) Error!RecentProject {
    if (!hasSection(input.config, .recent_project) or !input.config.recent_project.enabled) return .none;
    const now_day = localDay(input.now_utc) catch return error.InvalidRecentProjectInput;

    var owned = std.ArrayList(Identity).empty;
    defer owned.deinit(gpa);
    for (input.profile.owned_repositories) |repository| {
        if (identityIn(owned.items, try parseIdentity(repository.name_with_owner))) {
            return error.RepositoryIdentityConflict;
        }
        try addIdentity(&owned, gpa, repository.name_with_owner);
    }

    var organizations = std.ArrayList(Identity).empty;
    defer organizations.deinit(gpa);
    if (input.config.org.repos) |repositories| {
        for (repositories) |repository| try addIdentity(&organizations, gpa, repository);
    }

    var external = std.ArrayList(Identity).empty;
    defer external.deinit(gpa);
    if (input.config.include_external and !input.config.recent_project.exclude_external) {
        for (input.profile.contributed_repositories) |repository| {
            try addIdentity(&external, gpa, repository.name_with_owner);
        }
    }

    var metadata = std.ArrayList(Metadata).empty;
    defer metadata.deinit(gpa);
    for (input.repository_metadata) |entry| {
        const identity = try parseIdentity(entry.name_with_owner);
        if (findMetadata(metadata.items, identity)) |existing| {
            if (!optionalEqual(existing.description, entry.description) or
                !optionalEqual(existing.primary_language, entry.primary_language)) return error.RepositoryIdentityConflict;
            continue;
        }
        try metadata.append(gpa, .{
            .identity = entry.name_with_owner,
            .description = entry.description,
            .primary_language = entry.primary_language,
        });
    }

    var best: ?Candidate = null;
    for (input.activity.repositories, 0..) |repository, index| {
        if (repository.status != .scanned) continue;
        const identity = parseIdentity(repository.name) catch return error.InvalidRepositoryIdentity;
        if (!identityIn(owned.items, identity) and !identityIn(organizations.items, identity) and
            !identityIn(external.items, identity)) continue;
        for (input.activity.repositories[0..index]) |previous| {
            if (previous.status == .scanned and identityMatches(previous.name, identity)) return error.RepositoryIdentityConflict;
        }
        const candidate = candidateForRepository(repository, now_day, input.config.window_days) catch return error.InvalidRecentProjectInput;
        if (candidate == null) continue;
        if (best == null or betterCandidate(candidate.?, best.?)) best = candidate;
    }

    const selected = best orelse return .none;
    const parsed = try parseIdentity(selected.identity);
    var description: ?[]const u8 = null;
    var primary_language: ?[]const u8 = null;
    for (input.profile.owned_repositories) |repository| {
        if (identityMatches(repository.name_with_owner, parsed)) {
            description = repository.description;
            primary_language = repository.primary_language;
            break;
        }
    }
    if (metadataValues(metadata.items, parsed)) |values| {
        description = values.description;
        primary_language = values.primary_language;
    }
    const age = std.math.sub(i64, now_day, selected.day) catch return error.InvalidRecentProjectInput;
    return .{ .project = .{
        .identity = try gpa.dupe(u8, selected.identity),
        .repository_name = try gpa.dupe(u8, parsed.name),
        .github_url = try std.fmt.allocPrint(gpa, "https://github.com/{s}", .{selected.identity}),
        .description = if (description) |value| try gpa.dupe(u8, value) else null,
        .primary_language = if (primary_language) |value| try gpa.dupe(u8, value) else null,
        .commit_count = selected.commit_count,
        .tier = if (age == 1) .yesterday else .recently,
    } };
}

fn candidateForRepository(repository: git_activity.Repository, now_day: i64, window_days: u32) Error!?Candidate {
    var best_day: ?i64 = null;
    var count: usize = 0;
    var last_timestamp: i64 = std.math.minInt(i64);
    for (repository.commits) |commit| {
        const day = localDay(commit.timestamp) catch return error.InvalidRecentProjectInput;
        const age = std.math.sub(i64, now_day, day) catch return error.InvalidRecentProjectInput;
        if (age < 1 or age > window_days) continue;
        if (best_day == null or day > best_day.?) {
            best_day = day;
            count = 1;
            last_timestamp = commit.timestamp;
        } else if (day == best_day.?) {
            count += 1;
            if (commit.timestamp > last_timestamp) last_timestamp = commit.timestamp;
        }
    }
    return if (best_day) |day| .{
        .identity = repository.name,
        .day = day,
        .commit_count = count,
        .last_timestamp = last_timestamp,
    } else null;
}

fn betterCandidate(left: Candidate, right: Candidate) bool {
    if (left.day != right.day) return left.day > right.day;
    if (left.commit_count != right.commit_count) return left.commit_count > right.commit_count;
    if (left.last_timestamp != right.last_timestamp) return left.last_timestamp > right.last_timestamp;
    return std.ascii.orderIgnoreCase(left.identity, right.identity) == .lt or
        (std.ascii.eqlIgnoreCase(left.identity, right.identity) and std.mem.order(u8, left.identity, right.identity) == .lt);
}

fn localDay(timestamp: i64) error{InvalidRecentProjectInput}!i64 {
    const shifted = std.math.add(i64, timestamp, 8 * 60 * 60) catch return error.InvalidRecentProjectInput;
    return @divFloor(shifted, 24 * 60 * 60);
}

fn addIdentity(list: *std.ArrayList(Identity), gpa: Allocator, value: []const u8) Error!void {
    const parsed = try parseIdentity(value);
    if (identityIn(list.items, parsed)) return;
    try list.append(gpa, parsed);
}

fn parseIdentity(value: []const u8) Error!Identity {
    const slash = std.mem.findScalar(u8, value, '/') orelse return error.InvalidRepositoryIdentity;
    if (slash == 0 or slash + 1 >= value.len or std.mem.findScalarPos(u8, value, slash + 1, '/') != null)
        return error.InvalidRepositoryIdentity;
    const owner = value[0..slash];
    const name = value[slash + 1 ..];
    if (!validSegment(owner) or !validSegment(name)) return error.InvalidRepositoryIdentity;
    return .{ .owner = owner, .name = name };
}

fn validSegment(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_' and char != '.') return false;
    }
    return true;
}

fn identityIn(values: []const Identity, target: Identity) bool {
    for (values) |value| if (std.ascii.eqlIgnoreCase(value.owner, target.owner) and std.ascii.eqlIgnoreCase(value.name, target.name)) return true;
    return false;
}

fn findMetadata(values: []const Metadata, target: Identity) ?Metadata {
    for (values) |value| {
        if (identityMatches(value.identity, target)) return value;
    }
    return null;
}

fn metadataValues(values: []const Metadata, target: Identity) ?struct { description: ?[]const u8, primary_language: ?[]const u8 } {
    if (findMetadata(values, target)) |value| return .{ .description = value.description, .primary_language = value.primary_language };
    return null;
}

fn identityMatches(value: []const u8, target: Identity) bool {
    const parsed = parseIdentity(value) catch return false;
    return std.ascii.eqlIgnoreCase(parsed.owner, target.owner) and std.ascii.eqlIgnoreCase(parsed.name, target.name);
}

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn hasSection(cfg: *const config.Config, section: config.Section) bool {
    for (cfg.sections) |value| if (value == section) return true;
    return false;
}

fn isCompleteUrl(value: []const u8) bool {
    return (std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "http://")) and value.len > 8;
}

test {
    _ = @import("page_payload_test.zig");
}
