//! Typed GitHub GraphQL queries and response ownership for the profile workflow.

const std = @import("std");
const github = @import("../github.zig");

const Allocator = std.mem.Allocator;

pub const max_timestamp: i64 = 253_402_300_799;

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

pub const RepositoryResponse = struct {
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

pub const RepositoryConnectionResponse = struct {
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

pub const ContributionRepositoryResponse = struct {
    repository: ContributedRepositoryResponse,
};

pub const ContributionsResponse = struct {
    totalCommitContributions: u64,
    totalIssueContributions: u64,
    totalPullRequestContributions: u64,
    totalPullRequestReviewContributions: u64,
    totalRepositoryContributions: u64,
    restrictedContributionsCount: u64,
    contributionCalendar: ContributionCalendarResponse,
    commitContributionsByRepository: []const ContributionRepositoryResponse,
};

pub const AccountResponse = struct {
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

pub const PageSource = enum { viewer, user };

pub const PageResult = union(enum) {
    success: ParsedPage,
    failure: github.Failure,
};

pub const ParsedPage = struct {
    parsed_viewer: ?std.json.Parsed(ViewerPageResponse) = null,
    parsed_user: ?std.json.Parsed(UserPageResponse) = null,
    connection: ?RepositoryConnectionResponse,

    pub fn deinit(self: *ParsedPage) void {
        if (self.parsed_viewer) |parsed| parsed.deinit();
        if (self.parsed_user) |parsed| parsed.deinit();
        self.* = undefined;
    }
};

pub fn fetchViewer(
    client: *github.Client,
    from: *const [20]u8,
    to: *const [20]u8,
    max_repositories: u32,
) Allocator.Error!github.Result(ViewerResponse) {
    return client.graphql(ViewerResponse, viewer_query, .{
        .from = from[0..],
        .to = to[0..],
        .maxRepositories = max_repositories,
        .after = @as(?[]const u8, null),
    }) catch |err| return escapingClientError(err);
}

pub fn fetchUser(
    client: *github.Client,
    login: []const u8,
    from: *const [20]u8,
    to: *const [20]u8,
    max_repositories: u32,
) Allocator.Error!github.Result(UserResponse) {
    return client.graphql(UserResponse, user_query, .{
        .login = login,
        .from = from[0..],
        .to = to[0..],
        .maxRepositories = max_repositories,
        .after = @as(?[]const u8, null),
    }) catch |err| return escapingClientError(err);
}

pub fn fetchRepositoryPage(
    client: *github.Client,
    source: PageSource,
    login: []const u8,
    cursor: []const u8,
) Allocator.Error!PageResult {
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

pub fn formatDateTime(timestamp: i64) error{InvalidTimestamp}![20]u8 {
    if (timestamp < 0 or timestamp > max_timestamp) return error.InvalidTimestamp;
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

fn escapingClientError(err: anyerror) Allocator.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
