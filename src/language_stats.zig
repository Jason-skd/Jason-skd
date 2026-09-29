//! Weighted programming-language statistics from Git file changes.

const std = @import("std");
const git_activity = @import("git_activity.zig");
const language_catalog = @import("language_catalog.zig");
const exclusions = @import("exclusions.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{WeightOverflow};

pub const Entry = struct {
    /// Name borrowed from the static language catalog.
    name: []const u8,
    weight: u64,
    /// Tenths of a percentage point: 352 means 35.2%.
    percentage_tenths: u16,
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
/// Exclusions precede weights; a rename uses its current path. Percentages use
/// all eligible languages before top-N selection, matching the Python baseline.
pub const Options = struct {
    top: usize = 8,
    types: []const []const u8 = &.{"programming"},
    excludes: @import("config/model.zig").ExcludesConfig = .{},
};

pub fn aggregate(allocator: Allocator, repositories: []const git_activity.Repository, options: Options) Error!Result {
    var totals: std.StringHashMapUnmanaged(u64) = .empty;
    defer totals.deinit(allocator);

    for (repositories) |repository| {
        if (repository.status != .scanned or exclusions.repositoryExcluded(repository.name, options.excludes.repos)) continue;
        for (repository.commits) |commit| for (commit.changes) |change| {
            if (exclusions.pathExcluded(change.path(), options.excludes.paths) or
                exclusions.pathExcluded(change.path(), repository.attribute_excludes)) continue;
            const language = language_catalog.classify(change.path()) orelse continue;
            if (contains(options.excludes.languages, language.name) or !contains(options.types, @tagName(language.language_type))) continue;
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
    }

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacity(allocator, totals.count());
    var iterator = totals.iterator();
    while (iterator.next()) |item| {
        entries.appendAssumeCapacity(.{
            .name = item.key_ptr.*,
            .weight = item.value_ptr.*,
            .percentage_tenths = 0,
        });
    }
    std.mem.sort(Entry, entries.items, {}, lessEntry);
    assignPercentages(entries.items);
    entries.items.len = @min(entries.items.len, options.top);
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

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn assignPercentages(entries: []Entry) void {
    if (entries.len == 0) return;

    // The catalog has fewer than 1,000 languages, so the sum of their u64
    // weights and each weight times 1000 both fit in u128.
    var total: u128 = 0;
    for (entries) |entry| total += entry.weight;
    for (entries) |*entry| {
        // Python sources round to two decimals, then the component formats one.
        // Round the exact binary value, not its shortest decimal spelling.
        const pct = @as(f64, @floatFromInt(entry.weight)) * 100.0 / @as(f64, @floatFromInt(total));
        const rounded = @as(f64, @floatFromInt(roundDecimal(pct, 100))) / 100.0;
        entry.percentage_tenths = roundDecimal(rounded, 10);
    }
}

/// Round a finite nonnegative percentage to a decimal integer, ties to even.
fn roundDecimal(value: f64, scale: u8) u16 {
    std.debug.assert(value >= 0 and value <= 100);
    const bits: u64 = @bitCast(value);
    const exponent: i32 = @as(i32, @intCast((bits >> 52) & 0x7ff)) - 1023 - 52;
    // A value at most 100 has a negative exponent in this representation.
    if (-exponent >= 128) return 0;
    const shift: u7 = @intCast(-exponent);
    const mantissa: u128 = (bits & ((@as(u64, 1) << 52) - 1)) | (@as(u64, 1) << 52);
    const numerator = mantissa * scale;
    const whole = numerator >> shift;
    const remainder = numerator & ((@as(u128, 1) << shift) - 1);
    const half = @as(u128, 1) << (shift - 1);
    return @intCast(whole + @intFromBool(remainder > half or (remainder == half and whole & 1 != 0)));
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
    const result = try aggregate(std.testing.allocator, &repositories, .{ .top = 3 });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.entries.len);
    try std.testing.expectEqualStrings("Zig", result.entries[0].name);
    try std.testing.expectEqual(@as(u64, 9), result.entries[0].weight);
    try std.testing.expectEqualStrings("Python", result.entries[1].name);
    try std.testing.expectEqual(@as(u64, 5), result.entries[1].weight);
    try std.testing.expectEqualStrings("C", result.entries[2].name);
    try std.testing.expectEqual(@as(u64, 1), result.entries[2].weight);
    try std.testing.expectEqual(@as(u16, 600), result.entries[0].percentage_tenths);
    try std.testing.expectEqual(@as(u16, 333), result.entries[1].percentage_tenths);
    try std.testing.expectEqual(@as(u16, 67), result.entries[2].percentage_tenths);
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
    const result = try aggregate(std.testing.allocator, &repositories, .{ .top = 10 });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("Python", result.entries[0].name);
    try std.testing.expectEqual(@as(u16, 1000), result.entries[0].percentage_tenths);
}

test "sorts equal weights by name without redistributing rounding remainders" {
    const changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = 1, .deletions = 0 } },
        .{ .file = .{ .path = "src/b.py", .additions = 1, .deletions = 0 } },
        .{ .file = .{ .path = "src/c.c", .additions = 1, .deletions = 0 } },
    };
    const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
    const repositories = [_]git_activity.Repository{fixtureRepository(&commits)};
    const result = try aggregate(std.testing.allocator, &repositories, .{ .top = 3 });
    defer result.deinit();

    try std.testing.expectEqualStrings("C", result.entries[0].name);
    try std.testing.expectEqualStrings("Python", result.entries[1].name);
    try std.testing.expectEqualStrings("Zig", result.entries[2].name);
    try std.testing.expectEqual(@as(u16, 333), result.entries[0].percentage_tenths);
    try std.testing.expectEqual(@as(u16, 333), result.entries[1].percentage_tenths);
    try std.testing.expectEqual(@as(u16, 333), result.entries[2].percentage_tenths);
}

test "top does not renormalize percentages and zero top is empty" {
    const changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = 3, .deletions = 0 } },
        .{ .file = .{ .path = "src/b.py", .additions = 2, .deletions = 0 } },
        .{ .file = .{ .path = "src/c.c", .additions = 1, .deletions = 0 } },
    };
    const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
    const repositories = [_]git_activity.Repository{fixtureRepository(&commits)};
    const result = try aggregate(std.testing.allocator, &repositories, .{ .top = 2 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
    try std.testing.expectEqual(@as(u16, 500), result.entries[0].percentage_tenths);
    try std.testing.expectEqual(@as(u16, 333), result.entries[1].percentage_tenths);

    const empty = try aggregate(std.testing.allocator, &repositories, .{ .top = 0 });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);
}

test "empty input has no percentages and wide totals stay exact" {
    const empty = try aggregate(std.testing.allocator, &.{}, .{ .top = 3 });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);

    const huge = std.math.maxInt(u64);
    const changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = huge, .deletions = 0 } },
        .{ .file = .{ .path = "src/b.c", .additions = huge, .deletions = 0 } },
    };
    const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
    const repositories = [_]git_activity.Repository{fixtureRepository(&commits)};
    const result = try aggregate(std.testing.allocator, &repositories, .{ .top = 2 });
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 500), result.entries[0].percentage_tenths);
    try std.testing.expectEqual(@as(u16, 500), result.entries[1].percentage_tenths);
}

test "weight additions and language totals report overflow" {
    const huge = std.math.maxInt(u64);
    const overflowing_change = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/main.zig", .additions = huge, .deletions = 1 } },
    };
    const first_commits = [_]git_activity.Commit{fixtureCommit(&overflowing_change)};
    const first_repositories = [_]git_activity.Repository{fixtureRepository(&first_commits)};
    try std.testing.expectError(error.WeightOverflow, aggregate(std.testing.allocator, &first_repositories, .{ .top = 1 }));

    const overflowing_total = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = huge, .deletions = 0 } },
        .{ .file = .{ .path = "src/b.zig", .additions = 1, .deletions = 0 } },
    };
    const second_commits = [_]git_activity.Commit{fixtureCommit(&overflowing_total)};
    const second_repositories = [_]git_activity.Repository{fixtureRepository(&second_commits)};
    try std.testing.expectError(error.WeightOverflow, aggregate(std.testing.allocator, &second_repositories, .{ .top = 1 }));
}

test "tenths preserve fractional and tiny shares with a total of 1000" {
    const cases = [_]struct { first: u64, second: u64, expected: [2]u16 }{
        .{ .first = 2, .second = 1, .expected = .{ 667, 333 } },
        .{ .first = 999, .second = 1, .expected = .{ 999, 1 } },
        .{ .first = 10000, .second = 1, .expected = .{ 1000, 0 } },
    };
    for (cases) |case| {
        const changes = [_]git_activity.FileChange{
            .{ .file = .{ .path = "src/a.zig", .additions = case.first, .deletions = 0 } },
            .{ .file = .{ .path = "src/b.py", .additions = case.second, .deletions = 0 } },
        };
        const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
        const repositories = [_]git_activity.Repository{fixtureRepository(&commits)};
        const result = try aggregate(std.testing.allocator, &repositories, .{ .top = 2 });
        defer result.deinit();
        try std.testing.expectEqual(case.expected[0], result.entries[0].percentage_tenths);
        try std.testing.expectEqual(case.expected[1], result.entries[1].percentage_tenths);
        var total: u16 = 0;
        for (result.entries) |entry| total += entry.percentage_tenths;
        try std.testing.expectEqual(@as(u16, 1000), total);
    }
}

fn allocationFailureAggregate(allocator: Allocator) !void {
    const changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "src/a.zig", .additions = 3, .deletions = 1 } },
        .{ .file = .{ .path = "src/b.py", .additions = 2, .deletions = 1 } },
        .{ .file = .{ .path = "src/c.c", .additions = 1, .deletions = 1 } },
    };
    const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
    const repositories = [_]git_activity.Repository{fixtureRepository(&commits)};
    const result = try aggregate(allocator, &repositories, .{ .top = 2 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
}

test "complete aggregation releases every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureAggregate, .{});
}

test "vendored C generated paths and explicit language exclusions precede all-language percentages" {
    const changes = [_]git_activity.FileChange{
        .{ .file = .{ .path = "zig-pkg/sqlite.c", .additions = 1000000, .deletions = 1000000 } },
        .{ .file = .{ .path = "vendor/copied.c", .additions = 1000000, .deletions = 0 } },
        .{ .file = .{ .path = "src/api.pb.go", .additions = 1000000, .deletions = 0 } },
        .{ .file = .{ .path = "src/script.groovy", .additions = 1000, .deletions = 0 } },
        .{ .file = .{ .path = "main.py", .additions = 30, .deletions = 10 } },
        .{ .file = .{ .path = "main.go", .additions = 30, .deletions = 0 } },
        .{ .file = .{ .path = "main.zig", .additions = 20, .deletions = 0 } },
        .{ .rename = .{ .previous_path = "before.css", .path = "after.css", .additions = 10, .deletions = 0 } },
    };
    const commits = [_]git_activity.Commit{fixtureCommit(&changes)};
    var repository = fixtureRepository(&commits);
    repository.attribute_excludes = &.{"*.pb.go"};
    const result = try aggregate(std.testing.allocator, &.{repository}, .{
        .top = 2,
        .types = &.{ "programming", "markup" },
        .excludes = .{ .languages = &.{"Groovy"}, .paths = exclusions.default_paths ++ &[_][]const u8{"**/zig-pkg/**"} },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Python", result.entries[0].name);
    try std.testing.expectEqualStrings("Go", result.entries[1].name);
    try std.testing.expectEqual(@as(u64, 40), result.entries[0].weight);
    try std.testing.expectEqual(@as(u16, 400), result.entries[0].percentage_tenths);
    try std.testing.expectEqual(@as(u16, 300), result.entries[1].percentage_tenths);
    const excluded_repo = try aggregate(std.testing.allocator, &.{repository}, .{ .excludes = .{ .repos = &.{"FIXTURE"} } });
    defer excluded_repo.deinit();
    try std.testing.expectEqual(@as(usize, 0), excluded_repo.entries.len);
    const empty_types = try aggregate(std.testing.allocator, &.{repository}, .{ .types = &.{} });
    defer empty_types.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_types.entries.len);
}

test "percentage rounding matches Python binary-float ties at both decimal stages" {
    try std.testing.expectEqual(@as(u16, 267), roundDecimal(2.675, 100));
    try std.testing.expectEqual(@as(u16, 269), roundDecimal(2.685, 100));
    try std.testing.expectEqual(@as(u16, 166), roundDecimal(16.65, 10));
    try std.testing.expectEqual(@as(u16, 168), roundDecimal(16.75, 10));
    try std.testing.expectEqual(@as(u16, 0), roundDecimal(0, 100));
}
