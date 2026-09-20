//! Credential and explicit-secret redaction for captured process output.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const security = @import("secure_allocator.zig");

const redacted_secret = "[REDACTED]";
const redacted_url = "[REDACTED_URL]";

/// Returns an owned copy with URL credentials and explicit secrets removed.
///
/// HTTP(S) authentication is removed first. Non-empty explicit secrets are then
/// replaced longest-first so an overlapping shorter value cannot expose the
/// suffix of a longer value. Intermediate owned buffers are cleared on every
/// success and failure path.
pub fn redact(gpa: Allocator, input: []const u8, secrets: []const []const u8) Allocator.Error![]u8 {
    var current = try redactCredentialUrls(gpa, input);
    errdefer security.secureFree(gpa, current);

    const ordered = try gpa.alloc([]const u8, secrets.len);
    defer gpa.free(ordered);
    @memcpy(ordered, secrets);
    sortSecretsLongestFirst(ordered);

    for (ordered) |secret| {
        if (secret.len == 0 or std.mem.find(u8, current, secret) == null) continue;
        const replaced = try std.mem.replaceOwned(u8, gpa, current, secret, redacted_secret);
        security.secureFree(gpa, current);
        current = replaced;
    }
    return current;
}

fn sortSecretsLongestFirst(secrets: [][]const u8) void {
    if (secrets.len < 2) return;
    for (secrets[1..], 1..) |secret, index| {
        var insertion_index = index;
        while (insertion_index > 0 and secrets[insertion_index - 1].len < secret.len) {
            secrets[insertion_index] = secrets[insertion_index - 1];
            insertion_index -= 1;
        }
        secrets[insertion_index] = secret;
    }
}

fn redactCredentialUrls(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    // Removing authentication does not grow a valid URL by more than the
    // formatter's optional slash; malformed replacements stay below this bound.
    const capacity = std.math.add(
        usize,
        std.math.mul(usize, input.len, 3) catch return error.OutOfMemory,
        1,
    ) catch return error.OutOfMemory;
    var output = try Io.Writer.Allocating.initCapacity(gpa, capacity);
    errdefer secureWriterDeinit(&output);

    var cursor: usize = 0;
    while (findHttpUrl(input, cursor)) |url_start| {
        append(&output, input[cursor..url_start]);

        const url_end = findUrlEnd(input, url_start);
        const candidate = input[url_start..url_end];
        if (!hasAuthorityUserInfo(candidate)) {
            append(&output, candidate);
        } else if (std.Uri.parse(candidate)) |uri| {
            if (uri.user == null or uri.host == null) {
                append(&output, redacted_url);
            } else {
                std.debug.assert(output.writer.buffer.len - output.writer.end >= candidate.len + 2);
                var flags = std.Uri.Format.Flags.all;
                flags.authentication = false;
                uri.writeToStream(&output.writer, flags) catch unreachable;
            }
        } else |_| {
            append(&output, redacted_url);
        }
        cursor = url_end;
    }
    append(&output, input[cursor..]);
    const result = try gpa.dupe(u8, output.written());
    secureWriterDeinit(&output);
    return result;
}

fn append(output: *Io.Writer.Allocating, bytes: []const u8) void {
    std.debug.assert(output.writer.buffer.len - output.writer.end >= bytes.len + 1);
    output.writer.writeAll(bytes) catch unreachable;
}

fn secureWriterDeinit(output: *Io.Writer.Allocating) void {
    std.crypto.secureZero(u8, output.writer.buffer);
    output.deinit();
}

fn findHttpUrl(input: []const u8, start: usize) ?usize {
    var index = start;
    while (index < input.len) : (index += 1) {
        if (startsWithHttpScheme(input[index..])) return index;
    }
    return null;
}

fn startsWithHttpScheme(input: []const u8) bool {
    return (input.len >= "http://".len and
        std.ascii.eqlIgnoreCase(input[0.."http://".len], "http://")) or
        (input.len >= "https://".len and
            std.ascii.eqlIgnoreCase(input[0.."https://".len], "https://"));
}

fn findUrlEnd(input: []const u8, start: usize) usize {
    var end = start;
    while (end < input.len and !isUrlDelimiter(input[end])) : (end += 1) {}
    return end;
}

fn isUrlDelimiter(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or switch (byte) {
        '\'', '"', '<', '>', '`' => true,
        else => false,
    };
}

fn hasAuthorityUserInfo(candidate: []const u8) bool {
    const scheme_end = std.mem.find(u8, candidate, "://") orelse return false;
    const authority_start = scheme_end + "://".len;
    const authority_end = std.mem.findAnyPos(u8, candidate, authority_start, "/?#") orelse
        candidate.len;
    return std.mem.findScalar(u8, candidate[authority_start..authority_end], '@') != null;
}
