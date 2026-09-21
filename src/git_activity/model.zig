//! Owned domain values returned by one Git activity scan.

const std = @import("std");

/// Outcome of scanning one configured repository.
pub const RepositoryStatus = enum {
    /// Git log was read successfully.
    scanned,
    /// The source could not be scanned and has a typed failure.
    unavailable,
};

/// Stable categories for repository-local failures.
pub const FailureKind = enum {
    /// Source or scan options violate the input contract.
    invalid_input,
    /// No absolute temporary clone parent was provided.
    clone_root_required,
    /// Git rejected or could not obtain credentials.
    authentication_failed,
    /// Git exited unsuccessfully for a non-authentication reason.
    git_command_failed,
    /// The process exceeded its configured timeout.
    timeout,
    /// Git output did not match the parser contract.
    malformed_git_output,
    /// The generated temporary clone path already exists.
    temp_path_collision,
    /// Any other process-layer failure.
    process_failed,
};

/// Failure details retained when a repository cannot be scanned.
pub const Failure = struct {
    /// Normalized category used by consumers.
    kind: FailureKind,
    /// Owned, non-secret error name or short cause.
    cause: []const u8,
};

/// A file change keeps one current path; only a rename carries its prior path.
pub const FileChange = union(enum) {
    /// A non-rename file change with one current path.
    file: struct {
        /// Current path of an added, modified, deleted, or copied file.
        path: []const u8,
        /// Added text lines, or null for binary content.
        additions: ?u64,
        /// Deleted text lines, or null for binary content.
        deletions: ?u64,
    },
    /// A rename with both its previous and current paths.
    rename: struct {
        /// Path before the rename.
        previous_path: []const u8,
        /// Path after the rename.
        path: []const u8,
        /// Added text lines, or null for binary content.
        additions: ?u64,
        /// Deleted text lines, or null for binary content.
        deletions: ?u64,
    },

    /// Returns the current path regardless of the change variant.
    pub fn path(change: FileChange) []const u8 {
        return switch (change) {
            .file => |value| value.path,
            .rename => |value| value.path,
        };
    }
};

/// One author- and time-filtered Git commit.
pub const Commit = struct {
    /// Full Git object hash for this commit.
    id: []const u8,
    /// Exact author email selected by the caller's filter.
    author_email: []const u8,
    /// Unix timestamp reported by Git.
    timestamp: i64,
    /// Owned file changes attached to this commit.
    changes: []const FileChange,
};

/// Aggregated activity and commit data for one source.
pub const Repository = struct {
    /// Stable configured display name.
    name: []const u8,
    /// Local checkout path or remote URL.
    location: []const u8,
    /// Whether the source was scanned or reported unavailable.
    status: RepositoryStatus,
    /// Failure details when `status` is `.unavailable`.
    failure: ?Failure,
    /// Commits matching the configured author and time bounds.
    commits: []const Commit,
    /// Number of matching commits.
    commit_count: usize,
    /// Added text lines across matching changes.
    text_additions: u64,
    /// Deleted text lines across matching changes.
    text_deletions: u64,
    /// Matching binary changes.
    binary_files: u64,
    /// Matching rename changes.
    renamed_files: u64,
};

/// Totals across all configured repositories.
pub const Aggregate = struct {
    /// Per-repository scan results.
    repositories: []const Repository,
    /// Number of configured sources, including unavailable ones.
    repository_count: usize,
    /// Number of unavailable sources.
    unavailable_count: usize,
    /// Total matching commits.
    commit_count: usize,
    /// Total added text lines.
    text_additions: u64,
    /// Total deleted text lines.
    text_deletions: u64,
    /// Total matching binary changes.
    binary_files: u64,
    /// Total matching renames.
    renamed_files: u64,
};

/// Owns all strings, commits, and change lists reachable from `value`.
pub const ScanResult = struct {
    /// Arena owning every allocation reachable from `value`.
    arena: *std.heap.ArenaAllocator,
    /// Aggregate returned by the scan.
    value: Aggregate,

    /// Releases the arena and all strings, commits, and changes it owns.
    pub fn deinit(self: ScanResult) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};
