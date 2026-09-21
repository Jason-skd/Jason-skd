//! Converts owned HTTP bodies into typed REST or GraphQL results.

const std = @import("std");

const failures = @import("failure.zig");
const json = @import("json.zig");
const redact = @import("redact.zig");
const transport = @import("transport.zig");

const GraphqlError = struct {
    message: []const u8,
};

const GraphqlErrorEnvelope = struct {
    errors: ?[]const GraphqlError = null,
};

fn GraphqlEnvelope(comptime T: type) type {
    return struct {
        data: ?T = null,
        errors: ?[]const GraphqlError = null,
    };
}

/// Parses a successful REST response into an owned typed result.
pub fn parseRest(
    comptime T: type,
    allocator: std.mem.Allocator,
    token: ?[]const u8,
    response_value: transport.RawResponse,
    url: []const u8,
) !failures.Result(T) {
    var raw = response_value;
    defer raw.deinit();

    const parsed = json.parse(T, allocator, raw.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .init(
            .invalid_json,
            raw.status,
            raw.rate_limit,
            token,
            url,
            @errorName(err),
        ) };
    };
    return .{ .success = parsed };
}

/// Parses GraphQL errors first, then returns an owned typed `data` result.
pub fn parseGraphql(
    comptime T: type,
    allocator: std.mem.Allocator,
    token: ?[]const u8,
    response_value: transport.RawResponse,
    url: []const u8,
) !failures.Result(T) {
    var raw = response_value;
    defer raw.deinit();

    var error_envelope = json.parse(GraphqlErrorEnvelope, allocator, raw.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = invalidGraphqlJson(token, raw, url, @errorName(err)) };
    };
    defer error_envelope.deinit();

    if (error_envelope.value.errors) |errors| {
        if (errors.len != 0) return .{ .failure = graphqlFailure(token, raw, url, errors) };
    }

    var parsed = json.parse(GraphqlEnvelope(T), allocator, raw.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = invalidGraphqlJson(token, raw, url, @errorName(err)) };
    };

    const data = parsed.value.data orelse {
        parsed.deinit();
        return .{ .failure = invalidGraphqlJson(token, raw, url, "missing data") };
    };
    return .{ .success = .{
        .arena = parsed.arena,
        .value = data,
    } };
}

fn invalidGraphqlJson(
    token: ?[]const u8,
    raw: transport.RawResponse,
    url: []const u8,
    detail: []const u8,
) failures.Failure {
    return .init(
        .invalid_json,
        raw.status,
        raw.rate_limit,
        token,
        url,
        detail,
    );
}

fn graphqlFailure(
    token: ?[]const u8,
    raw: transport.RawResponse,
    url: []const u8,
    errors: []const GraphqlError,
) failures.Failure {
    var result = failures.Failure.init(
        .graphql,
        raw.status,
        raw.rate_limit,
        token,
        url,
        "",
    );
    var writer: std.Io.Writer = .fixed(result.diagnostic_buffer[result.diagnostic_len..]);
    writer.writeAll(": ") catch {};
    for (errors, 0..) |graphql_error, index| {
        if (index != 0) writer.writeAll("; ") catch {};
        redact.writeSanitized(&writer, graphql_error.message, token) catch {};
    }
    result.diagnostic_len += writer.buffered().len;
    return result;
}
