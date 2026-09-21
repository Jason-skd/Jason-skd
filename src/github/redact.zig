//! Removes credentials from bounded error diagnostics before truncation.

const std = @import("std");

/// Writes text after replacing common credential forms with placeholders.
pub fn writeSanitized(writer: *std.Io.Writer, input: []const u8, token: ?[]const u8) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < input.len) {
        if (token) |secret| {
            if (secret.len != 0 and std.mem.startsWith(u8, input[index..], secret)) {
                try writer.writeAll("***");
                index += secret.len;
                continue;
            }
        }

        if (startsWithIgnoreCase(input[index..], "bearer ")) {
            try writer.writeAll("Bearer ***");
            index += "bearer ".len;
            while (index < input.len and !std.ascii.isWhitespace(input[index])) : (index += 1) {}
            continue;
        }

        if (std.mem.startsWith(u8, input[index..], "://")) {
            try writer.writeAll("://");
            index += 3;
            const authority_end = std.mem.findAnyPos(u8, input, index, "/?# \t\r\n") orelse input.len;
            if (std.mem.findLast(u8, input[index..authority_end], "@")) |at_offset| {
                try writer.writeAll("***@");
                index += at_offset + 1;
            }
            continue;
        }

        if (index == 0 or input[index - 1] == '?' or input[index - 1] == '&') {
            if (credentialValueStart(input, index)) |value_start| {
                try writer.writeAll(input[index..value_start]);
                try writer.writeAll("***");
                index = value_start;
                while (index < input.len and input[index] != '&' and input[index] != '#' and
                    !std.ascii.isWhitespace(input[index])) : (index += 1)
                {}
                continue;
            }
        }

        try writer.writeByte(input[index]);
        index += 1;
    }
}

fn credentialValueStart(input: []const u8, start: usize) ?usize {
    const equals = std.mem.findScalarPos(u8, input, start, '=') orelse return null;
    const key = input[start..equals];
    if (std.mem.findAny(u8, key, "&# \t\r\n") != null) return null;
    const credential_keys = [_][]const u8{
        "token",
        "access_token",
        "client_secret",
        "authorization",
    };
    for (credential_keys) |candidate| {
        if (std.ascii.eqlIgnoreCase(key, candidate)) return equals + 1;
    }
    return null;
}

fn startsWithIgnoreCase(input: []const u8, prefix: []const u8) bool {
    return input.len >= prefix.len and std.ascii.eqlIgnoreCase(input[0..prefix.len], prefix);
}

fn expectSanitized(expected: []const u8, input: []const u8, token: ?[]const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeSanitized(&writer, input, token);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "redacts direct tokens and authorization values" {
    try expectSanitized("failure for *** with Bearer ***", "failure for SECRET with Bearer SECRET", "SECRET");
}

test "redacts URL userinfo and credential query parameters" {
    try expectSanitized(
        "https://***@api.github.com/repos?access_token=***&page=1#fragment",
        "https://user:password@api.github.com/repos?access_token=query-secret&page=1#fragment",
        null,
    );
}
