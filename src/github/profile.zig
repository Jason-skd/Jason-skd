//! Fetches and adapts typed GitHub profile data through the shared client.

const std = @import("std");
const client_module = @import("client.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Client = client_module.Client;

pub const Error = Allocator.Error || error{InvalidOptions};

const max_graphql_timestamp: i64 = 253_402_300_799;

const viewer_query =
    \\query ProfileViewer($from: DateTime!, $to: DateTime!, $maxRepositories: Int!, $after: String) {
    \\  viewer {
    \\    login
    \\    repositories(first: 100, after: $after, ownerAffiliations: [OWNER], isFork: false, orderBy: {field: NAME, direction: ASC}) {
    \\      nodes { name nameWithOwner description isPrivate stargazerCount primaryLanguage { name } }
    \\      pageInfo { hasNextPage endCursor }
    \\    }
    \\    contributionsCollection(from: $from, to: $to) {
    \\      totalCommitContributions
    \\      totalIssueContributions
    \\      totalPullRequestContributions
    \\      totalPullRequestReviewContributions
    \\      totalRepositoryContributions
    \\      restrictedContributionsCount
    \\      contributionCalendar { totalContributions weeks { contributionDays { contributionCount } } }
    \\      commitContributionsByRepository(maxRepositories: $maxRepositories) {
    \\        repository { nameWithOwner isPrivate owner { login } }
    \\      }
    \\    }
    \\  }
    \\}
;

const user_query =
    \\query ProfileUser($login: String!, $from: DateTime!, $to: DateTime!, $maxRepositories: Int!, $after: String) {
    \\  user(login: $login) {
    \\    login
    \\    repositories(first: 100, after: $after, ownerAffiliations: [OWNER], isFork: false, orderBy: {field: NAME, direction: ASC}) {
    \\      nodes { name nameWithOwner description isPrivate stargazerCount primaryLanguage { name } }
    \\      pageInfo { hasNextPage endCursor }
    \\    }
    \\    contributionsCollection(from: $from, to: $to) {
    \\      totalCommitContributions
    \\      totalIssueContributions
    \\      totalPullRequestContributions
    \\      totalPullRequestReviewContributions
    \\      totalRepositoryContributions
    \\      restrictedContributionsCount
    \\      contributionCalendar { totalContributions weeks { contributionDays { contributionCount } } }
    \\      commitContributionsByRepository(maxRepositories: $maxRepositories) {
    \\        repository { nameWithOwner isPrivate owner { login } }
    \\      }
    \\    }
    \\  }
    \\}
;

const viewer_page_query =
    \\query ProfileViewerRepositories($after: String!) {
    \\  viewer {
    \\    repositories(first: 100, after: $after, ownerAffiliations: [OWNER], isFork: false, orderBy: {field: NAME, direction: ASC}) {
    \\      nodes { name nameWithOwner description isPrivate stargazerCount primaryLanguage { name } }
    \\      pageInfo { hasNextPage endCursor }
    \\    }
    \\  }
    \\}
;

const user_page_query =
    \\query ProfileUserRepositories($login: String!, $after: String!) {
    \\  user(login: $login) {
    \\    repositories(first: 100, after: $after, ownerAffiliations: [OWNER], isFork: false, orderBy: {field: NAME, direction: ASC}) {
    \\      nodes { name nameWithOwner description isPrivate stargazerCount primaryLanguage { name } }
    \\      pageInfo { hasNextPage endCursor }
    \\    }
    \\  }
    \\}
;

const LanguageResponse = struct {
    name: []const u8,
};

const RepositoryResponse = struct {
    name: []const u8,
    nameWithOwner: []const u8,
    description: ?[]const u8,
    isPrivate: bool,
    stargazerCount: u64,
    primaryLanguage: ?LanguageResponse,
};

const PageInfoResponse = struct {
    hasNextPage: bool,
    endCursor: ?[]const u8,
};

const RepositoryConnectionResponse = struct {
    nodes: []const RepositoryResponse,
    pageInfo: PageInfoResponse,
};

const ContributionDayResponse = struct {
    contributionCount: u64,
};

const ContributionWeekResponse = struct {
    contributionDays: []const ContributionDayResponse,
};

const ContributionCalendarResponse = struct {
    totalContributions: u64,
    weeks: []const ContributionWeekResponse,
};

const RepositoryOwnerResponse = struct {
    login: []const u8,
};

const ContributedRepositoryResponse = struct {
    nameWithOwner: []const u8,
    isPrivate: bool,
    owner: RepositoryOwnerResponse,
};

const ContributionRepositoryResponse = struct {
    repository: ContributedRepositoryResponse,
};

const ContributionsResponse = struct {
    totalCommitContributions: u64,
    totalIssueContributions: u64,
    totalPullRequestContributions: u64,
    totalPullRequestReviewContributions: u64,
    totalRepositoryContributions: u64,
    restrictedContributionsCount: u64,
    contributionCalendar: ContributionCalendarResponse,
    commitContributionsByRepository: []const ContributionRepositoryResponse,
};

const AccountResponse = struct {
    login: []const u8,
    repositories: RepositoryConnectionResponse,
    contributionsCollection: ContributionsResponse,
};

const ViewerResponse = struct {
    viewer: AccountResponse,
};

const UserResponse = struct {
    user: ?AccountResponse,
};

const ViewerPageResponse = struct {
    viewer: struct { repositories: RepositoryConnectionResponse },
};

const UserPageResponse = struct {
    user: ?struct { repositories: RepositoryConnectionResponse },
};

const PageSource = enum { viewer, user };

/// Fetches one complete profile result using caller-selected query bounds.
pub fn fetchProfile(client: *Client, allocator: Allocator, options: model.ProfileOptions) Error!model.ProfileResult {
    try validateOptions(options);
    if (!client.hasCredential()) {
        return .{ .failure = .init(.profile, .missing_credential, options.login) };
    }

    const from = formatDateTime(options.since) catch return error.InvalidOptions;
    const to = formatDateTime(options.until) catch return error.InvalidOptions;
    var viewer_result = client.graphql(ViewerResponse, viewer_query, .{
        .from = from[0..],
        .to = to[0..],
        .maxRepositories = options.max_contributed_repositories,
        .after = @as(?[]const u8, null),
    }) catch |err| return escapingClientError(err);
    defer viewer_result.deinit();

    return switch (viewer_result) {
        .failure => |failure| .{ .failure = dataFailure(.profile, options.login, failure) },
        .success => |parsed| if (std.ascii.eqlIgnoreCase(parsed.value.viewer.login, options.login))
            buildProfile(client, allocator, options, parsed.value.viewer, .authenticated_as_target, .viewer)
        else
            fetchPublicProfile(client, allocator, options, &from, &to),
    };
}

fn fetchPublicProfile(
    client: *Client,
    allocator: Allocator,
    options: model.ProfileOptions,
    from: *const [20]u8,
    to: *const [20]u8,
) Error!model.ProfileResult {
    var user_result = client.graphql(UserResponse, user_query, .{
        .login = options.login,
        .from = from[0..],
        .to = to[0..],
        .maxRepositories = options.max_contributed_repositories,
        .after = @as(?[]const u8, null),
    }) catch |err| return escapingClientError(err);
    defer user_result.deinit();

    return switch (user_result) {
        .failure => |failure| .{ .failure = dataFailure(.profile, options.login, failure) },
        .success => |parsed| if (parsed.value.user) |account|
            if (std.ascii.eqlIgnoreCase(account.login, options.login))
                buildProfile(client, allocator, options, account, .public_only, .user)
            else
                .{ .failure = .init(.profile, .{ .invalid_response = .unexpected_login }, options.login) }
        else
            .{ .failure = .init(.profile, .not_found, options.login) },
    };
}

fn buildProfile(
    client: *Client,
    allocator: Allocator,
    options: model.ProfileOptions,
    account: AccountResponse,
    access: model.Access,
    page_source: PageSource,
) Error!model.ProfileResult {
    var owned = try model.initOwned(model.Profile, allocator);
    errdefer owned.deinit();
    const arena = owned.arena.allocator();

    var repositories: std.ArrayList(model.Repository) = .empty;
    if (!try appendRepositories(arena, &repositories, account.repositories.nodes, account.login)) {
        return finishFailure(owned, .init(.profile, .{ .invalid_response = .invalid_repository_identity }, options.login));
    }

    var cursors: std.ArrayList([]const u8) = .empty;
    var has_next_page = account.repositories.pageInfo.hasNextPage;
    var next_cursor = account.repositories.pageInfo.endCursor;
    while (has_next_page) {
        const cursor = next_cursor orelse
            return finishFailure(owned, .init(.profile, .{ .invalid_response = .malformed_pagination }, options.login));
        if (cursor.len == 0 or containsString(cursors.items, cursor)) {
            return finishFailure(owned, .init(.profile, .{ .invalid_response = .malformed_pagination }, options.login));
        }
        const owned_cursor = try arena.dupe(u8, cursor);
        try cursors.append(arena, owned_cursor);
        const page_outcome = try fetchRepositoryPage(client, page_source, options.login, owned_cursor);
        switch (page_outcome) {
            .failure => |failure| return finishFailure(owned, dataFailure(.profile, options.login, failure)),
            .success => |page| {
                var page_result = page;
                defer page_result.deinit();
                const connection = page_result.connection orelse
                    return finishFailure(owned, .init(.profile, .not_found, options.login));
                if (!try appendRepositories(arena, &repositories, connection.nodes, account.login)) {
                    return finishFailure(owned, .init(.profile, .{ .invalid_response = .invalid_repository_identity }, options.login));
                }
                has_next_page = connection.pageInfo.hasNextPage;
                next_cursor = if (has_next_page) blk: {
                    const value = connection.pageInfo.endCursor orelse
                        return finishFailure(owned, .init(.profile, .{ .invalid_response = .malformed_pagination }, options.login));
                    break :blk try arena.dupe(u8, value);
                } else null;
            },
        }
    }

    const owned_repositories = try repositories.toOwnedSlice(arena);
    if (!validUniqueRepositories(owned_repositories, account.login)) {
        return finishFailure(owned, .init(.profile, .{ .invalid_response = .invalid_repository_identity }, options.login));
    }

    var contributed = try copyContributedRepositories(arena, account.contributionsCollection.commitContributionsByRepository);
    if (!normalizeContributedRepositories(&contributed)) {
        return finishFailure(owned, .init(.profile, .{ .invalid_response = .invalid_repository_identity }, options.login));
    }

    owned.value = .{
        .login = try arena.dupe(u8, account.login),
        .access = access,
        .contributions = contributions(account.contributionsCollection),
        .owned_repositories = owned_repositories,
        .contributed_repositories = contributed,
    };
    return .{ .success = owned };
}

const PageResult = union(enum) {
    success: ParsedPage,
    failure: client_module.Failure,
};

const ParsedPage = struct {
    parsed_viewer: ?std.json.Parsed(ViewerPageResponse) = null,
    parsed_user: ?std.json.Parsed(UserPageResponse) = null,
    connection: ?RepositoryConnectionResponse,

    fn deinit(self: *ParsedPage) void {
        if (self.parsed_viewer) |parsed| parsed.deinit();
        if (self.parsed_user) |parsed| parsed.deinit();
        self.* = undefined;
    }
};

fn fetchRepositoryPage(client: *Client, source: PageSource, login: []const u8, cursor: []const u8) Error!PageResult {
    return switch (source) {
        .viewer => blk: {
            const result = client.graphql(ViewerPageResponse, viewer_page_query, .{ .after = cursor }) catch |err|
                return escapingClientError(err);
            switch (result) {
                .failure => |failure| break :blk .{ .failure = failure },
                .success => |parsed| break :blk .{ .success = .{
                    .parsed_viewer = parsed,
                    .connection = parsed.value.viewer.repositories,
                } },
            }
        },
        .user => blk: {
            const result = client.graphql(UserPageResponse, user_page_query, .{ .login = login, .after = cursor }) catch |err|
                return escapingClientError(err);
            switch (result) {
                .failure => |failure| break :blk .{ .failure = failure },
                .success => |parsed| break :blk .{ .success = .{
                    .parsed_user = parsed,
                    .connection = if (parsed.value.user) |user| user.repositories else null,
                } },
            }
        },
    };
}

fn appendRepositories(
    arena: Allocator,
    output: *std.ArrayList(model.Repository),
    nodes: []const RepositoryResponse,
    account_login: []const u8,
) Allocator.Error!bool {
    try output.ensureUnusedCapacity(arena, nodes.len);
    for (nodes) |repository| {
        if (!validRepositoryIdentity(repository.nameWithOwner, account_login, repository.name)) return false;
        output.appendAssumeCapacity(.{
            .name = try arena.dupe(u8, repository.name),
            .name_with_owner = try arena.dupe(u8, repository.nameWithOwner),
            .description = if (repository.description) |value| try arena.dupe(u8, value) else null,
            .is_private = repository.isPrivate,
            .stars = repository.stargazerCount,
            .primary_language = if (repository.primaryLanguage) |language| try arena.dupe(u8, language.name) else null,
        });
    }
    return true;
}

fn copyContributedRepositories(arena: Allocator, entries: []const ContributionRepositoryResponse) ![]model.ContributedRepository {
    const result = try arena.alloc(model.ContributedRepository, entries.len);
    for (entries, result) |entry, *destination| {
        destination.* = .{
            .name_with_owner = try arena.dupe(u8, entry.repository.nameWithOwner),
            .owner_login = try arena.dupe(u8, entry.repository.owner.login),
            .is_private = entry.repository.isPrivate,
        };
    }
    return result;
}

fn normalizeContributedRepositories(items: *[]model.ContributedRepository) bool {
    std.mem.sort(model.ContributedRepository, items.*, {}, struct {
        fn lessThan(_: void, lhs: model.ContributedRepository, rhs: model.ContributedRepository) bool {
            const order = std.ascii.orderIgnoreCase(lhs.name_with_owner, rhs.name_with_owner);
            return order == .lt or (order == .eq and std.mem.order(u8, lhs.name_with_owner, rhs.name_with_owner) == .lt);
        }
    }.lessThan);

    var write_index: usize = 0;
    for (items.*) |item| {
        if (!validRepositoryIdentity(item.name_with_owner, item.owner_login, null)) return false;
        if (write_index != 0 and std.ascii.eqlIgnoreCase(items.*[write_index - 1].name_with_owner, item.name_with_owner)) {
            const previous = items.*[write_index - 1];
            if (!std.ascii.eqlIgnoreCase(previous.owner_login, item.owner_login) or previous.is_private != item.is_private) return false;
            continue;
        }
        items.*[write_index] = item;
        write_index += 1;
    }
    items.* = items.*[0..write_index];
    return true;
}

fn validUniqueRepositories(items: []model.Repository, account_login: []const u8) bool {
    for (items, 0..) |item, index| {
        if (!validRepositoryIdentity(item.name_with_owner, account_login, item.name)) return false;
        for (items[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.name_with_owner, item.name_with_owner)) return false;
        }
    }
    return true;
}

fn validRepositoryIdentity(name_with_owner: []const u8, owner_login: []const u8, repository_name: ?[]const u8) bool {
    const slash = std.mem.indexOfScalar(u8, name_with_owner, '/') orelse return false;
    if (slash == 0 or slash + 1 == name_with_owner.len) return false;
    if (std.mem.indexOfScalarPos(u8, name_with_owner, slash + 1, '/') != null) return false;
    if (owner_login.len == 0 or !std.ascii.eqlIgnoreCase(name_with_owner[0..slash], owner_login)) return false;
    return if (repository_name) |name| std.mem.eql(u8, name_with_owner[slash + 1 ..], name) else true;
}

fn contributions(response: ContributionsResponse) model.Contributions {
    var active_days: u32 = 0;
    for (response.contributionCalendar.weeks) |week| {
        for (week.contributionDays) |day| {
            if (day.contributionCount > 0) active_days += 1;
        }
    }
    return .{
        .calendar_total = response.contributionCalendar.totalContributions,
        .active_days = active_days,
        .commits = response.totalCommitContributions,
        .issues = response.totalIssueContributions,
        .pull_requests = response.totalPullRequestContributions,
        .reviews = response.totalPullRequestReviewContributions,
        .repositories_created = response.totalRepositoryContributions,
        .viewer_inaccessible = response.restrictedContributionsCount,
    };
}

fn validateOptions(options: model.ProfileOptions) error{InvalidOptions}!void {
    if (options.login.len == 0 or options.since < 0 or options.until < options.since or
        options.until > max_graphql_timestamp or options.max_contributed_repositories > 100)
    {
        return error.InvalidOptions;
    }
}

fn formatDateTime(timestamp: i64) error{InvalidTimestamp}![20]u8 {
    if (timestamp < 0 or timestamp > max_graphql_timestamp) return error.InvalidTimestamp;
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp) };
    const day = epoch_seconds.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = epoch_seconds.getDaySeconds();
    var buffer: [20]u8 = undefined;
    _ = std.mem.print(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year,
        month.month.numeric(),
        month.day_index + 1,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
    }) catch unreachable;
    return buffer;
}

fn containsString(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn dataFailure(operation: model.DataOperation, subject: []const u8, failure: client_module.Failure) model.DataFailure {
    return .init(operation, .{ .github = failure }, subject);
}

fn finishFailure(owned: model.Owned(model.Profile), failure: model.DataFailure) model.ProfileResult {
    owned.deinit();
    return .{ .failure = failure };
}

fn escapingClientError(err: anyerror) Allocator.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

test {
    _ = @import("profile_test.zig");
}
