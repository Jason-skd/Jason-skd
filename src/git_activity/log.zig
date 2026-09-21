//! Parser for Git's NUL-delimited log and numstat output.

const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
/// Errors returned when Git output does not match the requested NUL format.
pub const Error = error{MalformedGitOutput};

/// Parses Git's record-separator stream into owned commits and file changes.
///
/// The returned slice and every nested string or slice belong to `gpa`.
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
        const header = try parseCommitHeader(record);
        const id = header.id;
        const timestamp = header.timestamp;
        const email = header.email;
        if (timestamp < since or timestamp > until or !matchesAuthor(email, authors)) continue;
        const payload = if (header.payload_start < record.len) record[header.payload_start..] else "";
        try commits.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .author_email = try gpa.dupe(u8, email),
            .timestamp = timestamp,
            .changes = try parseChanges(gpa, payload),
        });
    }
    return commits.toOwnedSlice(gpa);
}

/// Borrowed header fields and the offset of its change payload.
const CommitHeader = struct {
    /// Borrowed full Git object hash.
    id: []const u8,
    /// Borrowed Unix timestamp parsed from Git output.
    timestamp: i64,
    /// Borrowed author email.
    email: []const u8,
    /// Offset at which the numstat payload begins.
    payload_start: usize,
};

/// Parses the three NUL-delimited fields emitted by the log format.
fn parseCommitHeader(record: []const u8) Error!CommitHeader {
    const id_end = std.mem.indexOfScalar(u8, record, 0) orelse return error.MalformedGitOutput;
    const timestamp_start = id_end + 1;
    const timestamp_end = std.mem.indexOfScalarPos(u8, record, timestamp_start, 0) orelse return error.MalformedGitOutput;
    const email_start = timestamp_end + 1;
    const email_end = std.mem.indexOfScalarPos(u8, record, email_start, 0) orelse return error.MalformedGitOutput;
    return .{
        .id = record[0..id_end],
        .timestamp = std.fmt.parseInt(i64, record[timestamp_start..timestamp_end], 10) catch return error.MalformedGitOutput,
        .email = record[email_start..email_end],
        .payload_start = email_end + 1,
    };
}

/// Parses all NUL-delimited numstat entries in one commit payload.
fn parseChanges(gpa: Allocator, payload: []const u8) (Allocator.Error || Error)![]const model.FileChange {
    var changes = try std.ArrayList(model.FileChange).initCapacity(gpa, 4);
    var cursor: usize = if (payload.len > 0 and payload[0] == 0) 1 else 0;
    while (cursor < payload.len) {
        while (cursor < payload.len and (payload[cursor] == '\n' or payload[cursor] == '\r')) cursor += 1;
        if (cursor >= payload.len) break;
        const end = std.mem.indexOfScalarPos(u8, payload, cursor, 0) orelse return error.MalformedGitOutput;
        const stat = payload[cursor..end];
        cursor = end + 1;
        const fields = try parseNumstat(stat);
        const counts = try parseCounts(fields.added, fields.deleted);
        const path = fields.path;
        if (path.len == 0) {
            const paths = try parseRenamePaths(payload, &cursor);
            try changes.append(gpa, .{ .rename = .{
                .previous_path = try gpa.dupe(u8, paths.previous),
                .path = try gpa.dupe(u8, paths.current),
                .additions = counts.additions,
                .deletions = counts.deletions,
            } });
        } else {
            try changes.append(gpa, .{ .file = .{
                .path = try gpa.dupe(u8, path),
                .additions = counts.additions,
                .deletions = counts.deletions,
            } });
        }
    }
    return changes.toOwnedSlice(gpa);
}

/// Borrowed numstat columns for one file entry.
const Numstat = struct {
    /// Borrowed additions column, or `-` for binary content.
    added: []const u8,
    /// Borrowed deletions column, or `-` for binary content.
    deleted: []const u8,
    /// Borrowed current path, empty when rename paths follow.
    path: []const u8,
};

/// Splits one tab-delimited numstat entry into counts and path.
fn parseNumstat(stat: []const u8) Error!Numstat {
    const added_end = std.mem.indexOfScalar(u8, stat, '\t') orelse return error.MalformedGitOutput;
    const deleted_start = added_end + 1;
    const deleted_end = std.mem.indexOfScalarPos(u8, stat, deleted_start, '\t') orelse return error.MalformedGitOutput;
    return .{ .added = stat[0..added_end], .deleted = stat[deleted_start..deleted_end], .path = stat[deleted_end + 1 ..] };
}

/// Borrowed path pair emitted for one rename record.
const RenamePaths = struct {
    /// Borrowed path before the rename.
    previous: []const u8,
    /// Borrowed path after the rename.
    current: []const u8,
};

/// Reads the two path records that Git emits for a rename.
fn parseRenamePaths(payload: []const u8, cursor: *usize) Error!RenamePaths {
    const old_end = std.mem.indexOfScalarPos(u8, payload, cursor.*, 0) orelse return error.MalformedGitOutput;
    const previous = payload[cursor.*..old_end];
    cursor.* = old_end + 1;
    const new_end = std.mem.indexOfScalarPos(u8, payload, cursor.*, 0) orelse return error.MalformedGitOutput;
    const current = payload[cursor.*..new_end];
    cursor.* = new_end + 1;
    return .{ .previous = previous, .current = current };
}

/// Parses one numstat count, preserving `-` as a binary-file marker.
fn parseCount(text: []const u8) Error!?u64 {
    if (std.mem.eql(u8, text, "-")) return null;
    return std.fmt.parseInt(u64, text, 10) catch return error.MalformedGitOutput;
}

/// Requires both numstat counts to agree on text versus binary semantics.
fn parseCounts(added: []const u8, deleted: []const u8) Error!struct { additions: ?u64, deletions: ?u64 } {
    const additions = try parseCount(added);
    const deletions = try parseCount(deleted);
    if ((additions == null) != (deletions == null)) return error.MalformedGitOutput;
    return .{ .additions = additions, .deletions = deletions };
}

/// Returns whether an exact configured author email matches the commit email.
fn matchesAuthor(email: []const u8, authors: []const []const u8) bool {
    for (authors) |author| if (std.mem.eql(u8, email, author)) return true;
    return false;
}
