//! Parser for Git's NUL-delimited log and numstat output.

const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
pub const Error = error{MalformedGitOutput};

pub fn parse(
    gpa: Allocator,
    output: []const u8,
    authors: []const []const u8,
    since: i64,
    until: i64,
) (Allocator.Error || Error)![]const model.Commit {
    var commits = try std.ArrayList(model.Commit).initCapacity(gpa, 8);
    var records = std.mem.splitScalar(u8, output, 0x1e);
    while (records.next()) |raw_record| {
        const record = std.mem.trim(u8, raw_record, "\n");
        if (record.len == 0) continue;
        const id_end = std.mem.indexOfScalar(u8, record, 0) orelse return error.MalformedGitOutput;
        const timestamp_start = id_end + 1;
        const timestamp_end = std.mem.indexOfScalarPos(u8, record, timestamp_start, 0) orelse return error.MalformedGitOutput;
        const email_start = timestamp_end + 1;
        const email_end = std.mem.indexOfScalarPos(u8, record, email_start, 0) orelse return error.MalformedGitOutput;
        const id = record[0..id_end];
        const timestamp = std.fmt.parseInt(i64, record[timestamp_start..timestamp_end], 10) catch return error.MalformedGitOutput;
        const email = record[email_start..email_end];
        if (timestamp < since or timestamp > until or !matchesAuthor(email, authors)) continue;
        const payload = if (email_end + 1 < record.len) record[email_end + 1 ..] else "";
        try commits.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .author_email = try gpa.dupe(u8, email),
            .timestamp = timestamp,
            .changes = try parseChanges(gpa, payload),
        });
    }
    return commits.toOwnedSlice(gpa);
}

fn parseChanges(gpa: Allocator, payload: []const u8) (Allocator.Error || Error)![]const model.FileChange {
    var changes = try std.ArrayList(model.FileChange).initCapacity(gpa, 4);
    var cursor: usize = if (payload.len > 0 and payload[0] == 0) 1 else 0;
    while (cursor < payload.len) {
        while (cursor < payload.len and (payload[cursor] == '\n' or payload[cursor] == '\r')) cursor += 1;
        if (cursor >= payload.len) break;
        const end = std.mem.indexOfScalarPos(u8, payload, cursor, 0) orelse return error.MalformedGitOutput;
        const stat = payload[cursor..end];
        cursor = end + 1;
        const added_end = std.mem.indexOfScalar(u8, stat, '\t') orelse return error.MalformedGitOutput;
        const deleted_start = added_end + 1;
        const deleted_end = std.mem.indexOfScalarPos(u8, stat, deleted_start, '\t') orelse return error.MalformedGitOutput;
        const added = stat[0..added_end];
        const deleted = stat[deleted_start..deleted_end];
        const path = stat[deleted_end + 1 ..];
        if (path.len == 0) {
            const old_end = std.mem.indexOfScalarPos(u8, payload, cursor, 0) orelse return error.MalformedGitOutput;
            const old_path = payload[cursor..old_end];
            cursor = old_end + 1;
            const new_end = std.mem.indexOfScalarPos(u8, payload, cursor, 0) orelse return error.MalformedGitOutput;
            const new_path = payload[cursor..new_end];
            cursor = new_end + 1;
            const counts = try parseCounts(added, deleted);
            try changes.append(gpa, .{ .rename = .{
                .previous_path = try gpa.dupe(u8, old_path),
                .path = try gpa.dupe(u8, new_path),
                .additions = counts.additions,
                .deletions = counts.deletions,
            } });
        } else {
            const counts = try parseCounts(added, deleted);
            try changes.append(gpa, .{ .file = .{
                .path = try gpa.dupe(u8, path),
                .additions = counts.additions,
                .deletions = counts.deletions,
            } });
        }
    }
    return changes.toOwnedSlice(gpa);
}

fn parseCount(text: []const u8) Error!?u64 {
    if (std.mem.eql(u8, text, "-")) return null;
    return std.fmt.parseInt(u64, text, 10) catch return error.MalformedGitOutput;
}

fn parseCounts(added: []const u8, deleted: []const u8) Error!struct { additions: ?u64, deletions: ?u64 } {
    const additions = try parseCount(added);
    const deletions = try parseCount(deleted);
    if ((additions == null) != (deletions == null)) return error.MalformedGitOutput;
    return .{ .additions = additions, .deletions = deletions };
}

fn matchesAuthor(email: []const u8, authors: []const []const u8) bool {
    for (authors) |author| if (std.mem.eql(u8, email, author)) return true;
    return false;
}
