//! Owned domain values returned by one Git activity scan.

const std = @import("std");

pub const RepositoryStatus = enum { scanned, unavailable };

pub const FailureKind = enum {
    invalid_input,
    clone_root_required,
    authentication_failed,
    git_command_failed,
    timeout,
    malformed_git_output,
    temp_path_collision,
    process_failed,
};

pub const Failure = struct {
    kind: FailureKind,
    cause: []const u8,
};

/// A file change keeps one current path; only a rename carries its prior path.
pub const FileChange = union(enum) {
    file: struct {
        path: []const u8,
        additions: ?u64,
        deletions: ?u64,
    },
    rename: struct {
        previous_path: []const u8,
        path: []const u8,
        additions: ?u64,
        deletions: ?u64,
    },

    pub fn path(change: FileChange) []const u8 {
        return switch (change) {
            .file => |value| value.path,
            .rename => |value| value.path,
        };
    }
};

pub const Commit = struct {
    id: []const u8,
    author_email: []const u8,
    timestamp: i64,
    changes: []const FileChange,
};

pub const Repository = struct {
    name: []const u8,
    location: []const u8,
    status: RepositoryStatus,
    failure: ?Failure,
    commits: []const Commit,
    commit_count: usize,
    text_additions: u64,
    text_deletions: u64,
    binary_files: u64,
    renamed_files: u64,
};

pub const Aggregate = struct {
    repositories: []const Repository,
    repository_count: usize,
    unavailable_count: usize,
    commit_count: usize,
    text_additions: u64,
    text_deletions: u64,
    binary_files: u64,
    renamed_files: u64,
};

/// Owns all strings, commits, and change lists reachable from `value`.
pub const ScanResult = struct {
    arena: *std.heap.ArenaAllocator,
    value: Aggregate,

    pub fn deinit(self: ScanResult) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};
