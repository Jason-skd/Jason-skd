//! Fetches organization and repository metadata through the GitHub REST API.

const std = @import("std");
const github = @import("../github.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Client = github.Client;

pub const Error = Allocator.Error || error{InvalidOptions};

const OrganizationResponse = struct {
    login: []const u8,
    name: ?[]const u8,
    avatar_url: []const u8,
    html_url: []const u8,
};

const RepositoryResponse = struct {
    full_name: []const u8,
    description: ?[]const u8,
    language: ?[]const u8,
};

/// Fetches one organization identity as an independently owned domain value.
pub fn fetchOrganization(client: *Client, allocator: Allocator, login: []const u8) Error!model.OrganizationResult {
    if (!validSegment(login)) return error.InvalidOptions;
    const path = try allocator.print("/orgs/{s}", .{login});
    defer allocator.free(path);

    var response = client.rest(OrganizationResponse, path) catch |err| return escapingClientError(err);
    defer response.deinit();
    return switch (response) {
        .failure => |failure| .{ .failure = normalizeFailure(.organization, login, failure) },
        .success => |parsed| if (!std.ascii.eqlIgnoreCase(parsed.value.login, login))
            .{ .failure = .init(.organization, .{ .invalid_response = .unexpected_login }, login) }
        else
            copyOrganization(allocator, parsed.value),
    };
}

/// Fetches supplemental metadata for one `owner/repository` identity.
pub fn fetchRepositoryMetadata(
    client: *Client,
    allocator: Allocator,
    name_with_owner: []const u8,
) Error!model.RepositoryMetadataResult {
    const identity = splitRepositoryIdentity(name_with_owner) orelse return error.InvalidOptions;
    const path = try allocator.print("/repos/{s}/{s}", .{ identity.owner, identity.name });
    defer allocator.free(path);

    var response = client.rest(RepositoryResponse, path) catch |err| return escapingClientError(err);
    defer response.deinit();
    return switch (response) {
        .failure => |failure| .{ .failure = normalizeFailure(.repository_metadata, name_with_owner, failure) },
        .success => |parsed| if (!std.ascii.eqlIgnoreCase(parsed.value.full_name, name_with_owner))
            .{ .failure = .init(.repository_metadata, .{ .invalid_response = .invalid_repository_identity }, name_with_owner) }
        else
            copyRepositoryMetadata(allocator, parsed.value),
    };
}

fn copyOrganization(allocator: Allocator, response: OrganizationResponse) Allocator.Error!model.OrganizationResult {
    var owned = try model.initOwned(model.Organization, allocator);
    errdefer owned.deinit();
    const arena = owned.arena.allocator();
    owned.value = .{
        .login = try arena.dupe(u8, response.login),
        .display_name = if (response.name) |value| try arena.dupe(u8, value) else null,
        .avatar_url = try arena.dupe(u8, response.avatar_url),
        .html_url = try arena.dupe(u8, response.html_url),
    };
    return .{ .success = owned };
}

fn copyRepositoryMetadata(allocator: Allocator, response: RepositoryResponse) Allocator.Error!model.RepositoryMetadataResult {
    var owned = try model.initOwned(model.RepositoryMetadata, allocator);
    errdefer owned.deinit();
    const arena = owned.arena.allocator();
    owned.value = .{
        .name_with_owner = try arena.dupe(u8, response.full_name),
        .description = if (response.description) |value| try arena.dupe(u8, value) else null,
        .primary_language = if (response.language) |value| try arena.dupe(u8, value) else null,
    };
    return .{ .success = owned };
}

fn normalizeFailure(operation: model.DataOperation, subject: []const u8, failure: github.Failure) model.DataFailure {
    if (failure.status == .not_found) return .init(operation, .not_found, subject);
    return .init(operation, .{ .github = failure }, subject);
}

const RepositoryIdentity = struct {
    owner: []const u8,
    name: []const u8,
};

fn splitRepositoryIdentity(value: []const u8) ?RepositoryIdentity {
    const slash = std.mem.findScalar(u8, value, '/') orelse return null;
    if (std.mem.findScalarPos(u8, value, slash + 1, '/') != null) return null;
    const owner = value[0..slash];
    const name = value[slash + 1 ..];
    if (!validSegment(owner) or !validSegment(name)) return null;
    return .{ .owner = owner, .name = name };
}

fn validSegment(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_' and char != '.') return false;
    }
    return true;
}

fn escapingClientError(err: anyerror) Allocator.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

test {
    _ = @import("metadata_test.zig");
}
