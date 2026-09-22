//! Owned domain values and failures returned by GitHub profile data sources.

const std = @import("std");
const client = @import("client.zig");

/// Caller-selected inputs for one profile query.
pub const ProfileOptions = struct {
    login: []const u8,
    since: i64,
    until: i64,
    max_contributed_repositories: u32,
};

/// How the GitHub response was obtained for the target account.
pub const Access = enum {
    authenticated_as_target,
    public_only,
};

/// Contribution counts reported by GitHub for the selected time window.
pub const Contributions = struct {
    calendar_total: u64,
    active_days: u32,
    commits: u64,
    issues: u64,
    pull_requests: u64,
    reviews: u64,
    repositories_created: u64,
    viewer_inaccessible: u64,
};

/// Metadata for one non-fork repository owned by the target account.
pub const Repository = struct {
    name: []const u8,
    name_with_owner: []const u8,
    description: ?[]const u8,
    is_private: bool,
    stars: u64,
    primary_language: ?[]const u8,
};

/// A repository containing commit contributions by the target account.
pub const ContributedRepository = struct {
    name_with_owner: []const u8,
    owner_login: []const u8,
    is_private: bool,
};

/// Stable profile facts consumed by later pipeline stages.
pub const Profile = struct {
    login: []const u8,
    access: Access,
    contributions: Contributions,
    owned_repositories: []const Repository,
    contributed_repositories: []const ContributedRepository,
};

/// Organization identity returned by the GitHub REST API.
pub const Organization = struct {
    login: []const u8,
    display_name: ?[]const u8,
    avatar_url: []const u8,
    html_url: []const u8,
};

/// Supplemental metadata for one repository.
pub const RepositoryMetadata = struct {
    name_with_owner: []const u8,
    description: ?[]const u8,
    primary_language: ?[]const u8,
};

/// Public GitHub data-source operations.
pub const DataOperation = enum {
    profile,
    organization,
    repository_metadata,
};

/// Stable invalid-response categories produced above the HTTP client.
pub const InvalidResponse = enum {
    unexpected_login,
    invalid_repository_identity,
    malformed_pagination,
};

/// Cause of a GitHub data-source failure.
pub const DataFailureCause = union(enum) {
    github: client.Failure,
    missing_credential,
    not_found,
    invalid_response: InvalidResponse,
};

/// A self-contained data-source failure with bounded operation context.
pub const DataFailure = struct {
    operation: DataOperation,
    cause: DataFailureCause,
    subject_buffer: [256]u8 = undefined,
    subject_len: usize = 0,

    /// Copies a subject into bounded storage owned by the failure.
    pub fn init(operation: DataOperation, cause: DataFailureCause, subject_value: []const u8) DataFailure {
        var result: DataFailure = .{
            .operation = operation,
            .cause = cause,
        };
        result.subject_len = @min(result.subject_buffer.len, subject_value.len);
        @memcpy(result.subject_buffer[0..result.subject_len], subject_value[0..result.subject_len]);
        return result;
    }

    /// Returns the bounded subject copied into this failure.
    pub fn subject(self: *const DataFailure) []const u8 {
        return self.subject_buffer[0..self.subject_len];
    }
};

/// Owns a domain value and every allocation reachable from it.
pub fn Owned(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        /// Releases the arena and the arena object.
        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

/// Initializes an owned result whose value will be populated by the caller.
pub fn initOwned(comptime T: type, allocator: std.mem.Allocator) std.mem.Allocator.Error!Owned(T) {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    return .{ .arena = arena, .value = undefined };
}

/// Returns either one complete owned value or a self-contained failure.
pub fn DataResult(comptime T: type) type {
    return union(enum) {
        success: Owned(T),
        failure: DataFailure,

        /// Releases allocations held by a successful value.
        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .success => |owned| owned.deinit(),
                .failure => {},
            }
            self.* = undefined;
        }
    };
}

pub const ProfileResult = DataResult(Profile);
pub const OrganizationResult = DataResult(Organization);
pub const RepositoryMetadataResult = DataResult(RepositoryMetadata);
