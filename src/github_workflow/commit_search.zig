//! Discovers authored-commit repositories beyond GitHub's contribution calendar.
const std = @import("std");
const github = @import("../github.zig");
const model = @import("model.zig");
const query = @import("profile_query.zig");

const Allocator = std.mem.Allocator;
const max_results = 1000;

pub const Result = union(enum) {
    success: []model.ContributedRepository,
    failure: model.DataFailure,
};

pub fn discover(client: *github.Client, arena: Allocator, login: []const u8, since: i64, until: i64) Allocator.Error!Result {
    var output: std.ArrayList(model.ContributedRepository) = .empty;
    const first_day = @divFloor(since, 86400);
    const last_day = @divFloor(until, 86400);
    if (try searchRange(client, arena, login, first_day, last_day, &output)) |failure| return .{ .failure = failure };
    return .{ .success = output.items };
}

fn searchRange(client: *github.Client, arena: Allocator, login: []const u8, first_day: i64, last_day: i64, output: *std.ArrayList(model.ContributedRepository)) Allocator.Error!?model.DataFailure {
    const from = query.formatDateTime(first_day * 86400) catch unreachable;
    const to = query.formatDateTime(last_day * 86400) catch unreachable;
    var first = try query.fetchCommitSearch(client, arena, login, &from, &to, 1);
    defer first.deinit();
    const first_page = switch (first) {
        .failure => |failure| return .init(.profile, .{ .github = failure }, login),
        .success => |parsed| parsed.value,
    };
    if (first_page.incomplete_results or first_page.total_count > max_results) {
        if (first_day == last_day) return .init(.profile, .{ .invalid_response = .commit_search_incomplete }, login);
        const middle = first_day + @divFloor(last_day - first_day, 2);
        if (try searchRange(client, arena, login, first_day, middle, output)) |failure| return failure;
        return try searchRange(client, arena, login, middle + 1, last_day, output);
    }
    if (first_page.items.len != @min(first_page.total_count, 100)) return .init(.profile, .{ .invalid_response = .commit_search_incomplete }, login);
    if (try appendItems(arena, first_page.items, output, login)) |failure| return failure;
    const pages = (first_page.total_count + 99) / 100;
    var page: u32 = 2;
    while (page <= pages) : (page += 1) {
        var response = try query.fetchCommitSearch(client, arena, login, &from, &to, page);
        defer response.deinit();
        const data = switch (response) {
            .failure => |failure| return .init(.profile, .{ .github = failure }, login),
            .success => |parsed| parsed.value,
        };
        const expected = @min(first_page.total_count - (page - 1) * 100, 100);
        if (data.incomplete_results or data.total_count != first_page.total_count or data.items.len != expected) return .init(.profile, .{ .invalid_response = .commit_search_incomplete }, login);
        if (try appendItems(arena, data.items, output, login)) |failure| return failure;
    }
    return null;
}

fn appendItems(arena: Allocator, items: []const query.CommitSearchItem, output: *std.ArrayList(model.ContributedRepository), login: []const u8) Allocator.Error!?model.DataFailure {
    for (items) |item| {
        const repo = item.repository;
        const slash = std.mem.findScalar(u8, repo.full_name, '/') orelse return .init(.profile, .{ .invalid_response = .invalid_repository_identity }, login);
        if (slash == 0 or slash + 1 == repo.full_name.len or std.mem.findScalarPos(u8, repo.full_name, slash + 1, '/') != null or !std.ascii.eqlIgnoreCase(repo.full_name[0..slash], repo.owner.login)) return .init(.profile, .{ .invalid_response = .invalid_repository_identity }, login);
        var found = false;
        for (output.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.name_with_owner, repo.full_name)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        try output.append(arena, .{
            .name_with_owner = try arena.dupe(u8, repo.full_name),
            .owner_login = try arena.dupe(u8, repo.owner.login),
            .is_private = repo.private,
        });
    }
    return null;
}

test {
    _ = @import("commit_search_test.zig");
}
