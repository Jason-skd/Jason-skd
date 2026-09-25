//! Weighted programming-language statistics from Git file changes.

const std = @import("std");
const git_activity = @import("git_activity.zig");
const language_catalog = @import("language_catalog.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{WeightOverflow};

pub const Entry = struct {
    /// Name borrowed from the static language catalog.
    name: []const u8,
    weight: u64,
    percentage: u8,
};

/// Owns the entry slice; entry names remain borrowed from the static catalog.
pub const Result = struct {
    allocator: Allocator,
    entries: []const Entry,

    pub fn deinit(self: Result) void {
        self.allocator.free(self.entries);
    }
};

/// Aggregates text changes from scanned repositories into the top languages.
///
/// Binary, zero-weight, unknown, and non-programming changes are excluded.
/// A rename is classified using its current path. Percentages are calculated
/// only over the retained entries and sum to 100 when the result is nonempty.
pub fn aggregate(allocator: Allocator, repositories: []const git_activity.Repository, top: usize) Error!Result {
    var totals: std.StringHashMapUnmanaged(u64) = .empty;
    defer totals.deinit(allocator);

    for (repositories) |repository| for (repository.commits) |commit| for (commit.changes) |change| {
        const language = language_catalog.classify(change.path()) orelse continue;
        if (language.language_type != .programming) continue;
        const weight = switch (change) {
            .file => |value| try textWeight(value.additions, value.deletions),
            .rename => |value| try textWeight(value.additions, value.deletions),
        } orelse continue;

        if (totals.getPtr(language.name)) |existing| {
            existing.* = std.math.add(u64, existing.*, weight) catch return error.WeightOverflow;
        } else {
            try totals.put(allocator, language.name, weight);
        }
    };

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacity(allocator, totals.count());
    var iterator = totals.iterator();
    while (iterator.next()) |item| {
        entries.appendAssumeCapacity(.{
            .name = item.key_ptr.*,
            .weight = item.value_ptr.*,
            .percentage = 0,
        });
    }
    std.mem.sort(Entry, entries.items, {}, lessEntry);
    entries.items.len = @min(entries.items.len, top);
    try assignPercentages(allocator, entries.items);
    return .{ .allocator = allocator, .entries = try entries.toOwnedSlice(allocator) };
}

fn textWeight(additions: ?u64, deletions: ?u64) error{WeightOverflow}!?u64 {
    const added = additions orelse return null;
    const deleted = deletions orelse return null;
    const weight = std.math.add(u64, added, deleted) catch return error.WeightOverflow;
    return if (weight == 0) null else weight;
}

fn lessEntry(_: void, left: Entry, right: Entry) bool {
    if (left.weight != right.weight) return left.weight > right.weight;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn assignPercentages(allocator: Allocator, entries: []Entry) Allocator.Error!void {
    if (entries.len == 0) return;

    // The catalog has fewer than 1,000 languages, so the sum of their u64
    // weights and each weight times 100 both fit in u128.
    var total: u128 = 0;
    for (entries) |entry| total += entry.weight;
    const remainders = try allocator.alloc(u128, entries.len);
    defer allocator.free(remainders);

    var assigned: u16 = 0;
    for (entries, remainders) |*entry, *remainder| {
        const scaled = @as(u128, entry.weight) * 100;
        entry.percentage = @intCast(scaled / total);
        remainder.* = scaled % total;
        assigned += entry.percentage;
    }

    var left = 100 - assigned;
    while (left > 0) : (left -= 1) {
        var best: ?usize = null;
        for (remainders, 0..) |remainder, index| {
            if (remainder == 0) continue;
            if (best == null or remainder > remainders[best.?]) best = index;
        }
        entries[best.?].percentage += 1;
        remainders[best.?] = 0;
    }
}

fn fixtureRepository(commits: []const git_activity.Commit) git_activity.Repository {
    return .{
        .name = "fixture",
        .location = "fixture",
        .status = .scanned,
        .failure = null,
        .commits = commits,
        .commit_count = commits.len,
        .text_additions = 0,
        .text_deletions = 0,
        .binary_files = 0,
        .renamed_files = 0,
    };
}

fn fixtureCommit(changes: []const git_activity.FileChange) git_activity.Commit {
    return .{
        .id = "fixture",
        .author_email = "owner@example.test",
        .timestamp = 0,
        .changes = changes,
    };
}

test "aggregates additions and deletions across repositories and rename destinations" {
    const first_changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/main.zig", .additions = 3, .deletions = 2 } },
        .{ .file = .{ .path = "src/main.c", .additions = 1, .deletions = 0 } },
    };
    const second_changes = [_]git_activity.FileChange{
        .{ .rename = .{ .previous_path = "src/old.py", .path = "src/new.zig", .additions = 0, .deletions = 4 } },
        .{ .file = .{ .path = "src/other.py", .additions = 2, .deletions = 3 } },
    };
    const first_commits = [_]git_activity.Commit{fixtureCommit(&first_changes)};
    const second_commits = [_]git_activity.Commit{fixtureCommit(&second_changes)};
    const repositories = [_]git_activity.Repository{ fixtureRepository(&first_commits), fixtureRepository(&second_commits) };
    const result = try aggregate(std.testing.allocator, &repositories, 3);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.entries.len);
    try std.testing.expectEqualStrings("Zig", result.entries[0].name);
    try std.testing.expectEqual(@as(u64, 9), result.entries[0].weight);
    try std.testing.expectEqualStrings("Python", result.entries[1].name);
    try std.testing.expectEqual(@as(u64, 5), result.entries[1].weight);
    try std.testing.expectEqualStrings("C", result.entries[2].name);
    try std.testing.expectEqual(@as(u64, 1), result.entries[2].weight);
    try std.testing.expectEqual(@as(u8, 60), result.entries[0].percentage);
    try std.testing.expectEqual(@as(u8, 33), result.entries[1].percentage);
    try std.testing.expectEqual(@as(u8, 7), result.entries[2].percentage);
}

test "excludes binary, zero, unknown, and non-programming changes" {
    const changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = null, .deletions = null } },
        .{ .file = .{ .path = "src/b.zig", .additions = 0, .deletions = 0 } },
        .{ .file = .{ .path = "src/unknown", .additions = 5, .deletions = 0 } },
        .{ .file = .{ .path = "src/unknown.xyz-not-a-language", .additions = 5, .deletions = 0 } },
        .{ .file = .{ .path = "src/huge.xyz-not-a-language", .additions = std.math.maxInt(u64), .deletions = 1 } },
        .{ .file = .{ .path = "web/style.css", .additions = 5, .deletions = 0 } },
        .{ .file = .{ .path = "web/huge.css", .additions = std.math.maxInt(u64), .deletions = 1 } },
        .{ .file = .{ .path = "data/config.json", .additions = 5, .deletions = 0 } },
        .{ .file = .{ .path = "docs/readme.md", .additions = 5, .deletions = 0 } },
        .{ .file = .{ .path = "src/kept.py", .additions = 1, .deletions = 0 } },
    };
    const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
    const repositories = [_]git_activity.Repository{fixtureRepository(&commits)};
    const result = try aggregate(std.testing.allocator, &repositories, 10);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("Python", result.entries[0].name);
    try std.testing.expectEqual(@as(u8, 100), result.entries[0].percentage);
}

test "sorts equal weights by name and assigns tied remainders in that order" {
    const changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = 1, .deletions = 0 } },
        .{ .file = .{ .path = "src/b.py", .additions = 1, .deletions = 0 } },
        .{ .file = .{ .path = "src/c.c", .additions = 1, .deletions = 0 } },
    };
    const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
    const repositories = [_]git_activity.Repository{fixtureRepository(&commits)};
    const result = try aggregate(std.testing.allocator, &repositories, 3);
    defer result.deinit();

    try std.testing.expectEqualStrings("C", result.entries[0].name);
    try std.testing.expectEqualStrings("Python", result.entries[1].name);
    try std.testing.expectEqualStrings("Zig", result.entries[2].name);
    try std.testing.expectEqual(@as(u8, 34), result.entries[0].percentage);
    try std.testing.expectEqual(@as(u8, 33), result.entries[1].percentage);
    try std.testing.expectEqual(@as(u8, 33), result.entries[2].percentage);
}

test "top is applied before percentages and zero top is empty" {
    const changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = 3, .deletions = 0 } },
        .{ .file = .{ .path = "src/b.py", .additions = 2, .deletions = 0 } },
        .{ .file = .{ .path = "src/c.c", .additions = 1, .deletions = 0 } },
    };
    const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
    const repositories = [_]git_activity.Repository{fixtureRepository(&commits)};
    const result = try aggregate(std.testing.allocator, &repositories, 2);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
    try std.testing.expectEqual(@as(u8, 60), result.entries[0].percentage);
    try std.testing.expectEqual(@as(u8, 40), result.entries[1].percentage);

    const empty = try aggregate(std.testing.allocator, &repositories, 0);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);
}

test "empty input has no percentages and wide totals stay exact" {
    const empty = try aggregate(std.testing.allocator, &.{}, 3);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);

    const huge = std.math.maxInt(u64);
    const changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = huge, .deletions = 0 } },
        .{ .file = .{ .path = "src/b.c", .additions = huge, .deletions = 0 } },
    };
    const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
    const repositories = [_]git_activity.Repository{fixtureRepository(&commits)};
    const result = try aggregate(std.testing.allocator, &repositories, 2);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 50), result.entries[0].percentage);
    try std.testing.expectEqual(@as(u8, 50), result.entries[1].percentage);
}

test "weight additions and language totals report overflow" {
    const huge = std.math.maxInt(u64);
    const overflowing_change = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/main.zig", .additions = huge, .deletions = 1 } },
    };
    const first_commits = [_]git_activity.Commit{fixtureCommit(&overflowing_change)};
    const first_repositories = [_]git_activity.Repository{fixtureRepository(&first_commits)};
    try std.testing.expectError(error.WeightOverflow, aggregate(std.testing.allocator, &first_repositories, 1));

    const overflowing_total = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = huge, .deletions = 0 } },
        .{ .file = .{ .path = "src/b.zig", .additions = 1, .deletions = 0 } },
    };
    const second_commits = [_]git_activity.Commit{fixtureCommit(&overflowing_total)};
    const second_repositories = [_]git_activity.Repository{fixtureRepository(&second_commits)};
    try std.testing.expectError(error.WeightOverflow, aggregate(std.testing.allocator, &second_repositories, 1));
}

fn allocationFailureAggregate(allocator: Allocator) !void {
    const changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = 3, .deletions = 1 } },
        .{ .file = .{ .path = "src/b.py", .additions = 2, .deletions = 1 } },
        .{ .file = .{ .path = "src/c.c", .additions = 1, .deletions = 1 } },
    };
    const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
    const repositories = [_]git_activity.Repository{fixtureRepository(&commits)};
    const result = try aggregate(allocator, &repositories, 2);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
}

test "complete aggregation releases every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureAggregate, .{});
}
