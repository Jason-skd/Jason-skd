//! Python-baseline repository and path exclusions; no filesystem access.
const std = @import("std");

pub const default_paths: []const []const u8 = &.{
    "**/vendor/**",      "**/vendors/**", "**/third_party/**", "**/thirdparty/**",
    "**/third-party/**", "**/extern/**",  "**/external/**",    "**/deps/**",
};

pub fn repositoryExcluded(name: []const u8, names: []const []const u8) bool {
    const bare = basename(name);
    for (names) |excluded| {
        if (std.ascii.eqlIgnoreCase(name, excluded) or std.ascii.eqlIgnoreCase(bare, excluded)) return true;
    }
    return false;
}

pub fn pathExcluded(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |raw| {
        var pattern = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t\r\n"), "/");
        if (pattern.len == 0 or pattern[0] == '#') continue;
        pattern = std.mem.trimStart(u8, pattern, "/");
        if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
            if (glob(pattern, basename(path))) return true;
        } else {
            if (glob(pattern, path)) return true;
            // Python's fnmatch does not give **/ a special zero-directory case.
            if (std.mem.startsWith(u8, pattern, "**/") and glob(pattern[3..], path)) return true;
        }
    }
    return false;
}

/// Copies root .gitattributes patterns using the baseline's marker semantics.
/// The caller owns the slice and its strings, usually in a scan arena.
pub fn attributePatterns(gpa: std.mem.Allocator, contents: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var patterns: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (patterns.items) |pattern| gpa.free(pattern);
        patterns.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const pattern = fields.next() orelse continue;
        if (pattern[0] == '#') continue;
        while (fields.next()) |attribute| {
            if (std.mem.startsWith(u8, attribute, "linguist-vendored") or std.mem.startsWith(u8, attribute, "linguist-generated")) {
                const copy = try gpa.dupe(u8, pattern);
                errdefer gpa.free(copy);
                try patterns.append(gpa, copy);
                break;
            }
        }
    }
    return patterns.toOwnedSlice(gpa);
}

fn basename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
}

/// fnmatch-style wildcards: * also spans '/', ? matches one codepoint,
/// bracket classes support ranges and ! negation. No recursive backtracking.
fn glob(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            p += 1;
            star = p;
            retry = t;
            continue;
        }
        if (p < pattern.len) {
            const token = matchToken(pattern[p..], text[t..]);
            if (token.matches) {
                p += token.pattern_bytes;
                t += codepoint(text[t..]).len;
                continue;
            }
        }
        if (star) |after| {
            retry += codepoint(text[retry..]).len;
            t = retry;
            p = after;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

const Codepoint = struct { value: u21, len: usize };

fn codepoint(bytes: []const u8) Codepoint {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .value = bytes[0], .len = 1 };
    if (len > bytes.len) return .{ .value = bytes[0], .len = 1 };
    const value = switch (len) {
        1 => @as(u21, bytes[0]),
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch return .{ .value = bytes[0], .len = 1 },
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch return .{ .value = bytes[0], .len = 1 },
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch return .{ .value = bytes[0], .len = 1 },
        else => unreachable,
    };
    return .{ .value = value, .len = len };
}

const Token = struct { matches: bool, pattern_bytes: usize };

fn matchToken(pattern: []const u8, text: []const u8) Token {
    const char = codepoint(text).value;
    if (pattern[0] == '?') return .{ .matches = true, .pattern_bytes = 1 };
    if (pattern[0] == '[') {
        const negated = pattern.len > 1 and pattern[1] == '!';
        const start: usize = if (negated) 2 else 1;
        var end = start;
        if (end < pattern.len and pattern[end] == ']') end += 1;
        while (end < pattern.len and pattern[end] != ']') : (end += 1) {}
        if (end < pattern.len) {
            var matched = false;
            var index = start;
            while (index < end) {
                const first = codepoint(pattern[index..end]);
                index += first.len;
                if (index + 1 < end and pattern[index] == '-') {
                    const last = codepoint(pattern[index + 1 .. end]);
                    matched = matched or (char >= first.value and char <= last.value);
                    index += 1 + last.len;
                } else matched = matched or char == first.value;
            }
            return .{ .matches = matched != negated, .pattern_bytes = end + 1 };
        }
    }
    const literal = codepoint(pattern);
    return .{ .matches = char == literal.value, .pattern_bytes = literal.len };
}

test "repository exclusions match bare or full names case insensitively without globs" {
    try std.testing.expect(repositoryExcluded("Org/Repo", &.{"repo"}));
    try std.testing.expect(repositoryExcluded("Org/Repo", &.{"org/repo"}));
    try std.testing.expect(!repositoryExcluded("Other/Repo", &.{"org/repo"}));
    try std.testing.expect(!repositoryExcluded("Org/Repo", &.{"*"}));
}

test "path exclusions match root nested basename ranges and Unicode like fnmatch" {
    for ([_][]const u8{ "vendor/a.c", "pkg/vendor/a.c", "deps/nested/b.go" }) |path|
        try std.testing.expect(pathExcluded(path, default_paths));
    try std.testing.expect(!pathExcluded("src/vendorish.c", default_paths));
    const cases = [_]struct { pattern: []const u8, path: []const u8, excluded: bool }{
        .{ .pattern = "*.generated.*", .path = "src/a.generated.go", .excluded = true },
        .{ .pattern = "/zig-pkg/**", .path = "zig-pkg/sqlite.c", .excluded = true },
        .{ .pattern = "a?/[!0-9].c", .path = "a中/x.c", .excluded = true },
        .{ .pattern = "[a-c].go", .path = "src/d.go", .excluded = false },
        .{ .pattern = "[]].go", .path = "].go", .excluded = true },
        .{ .pattern = "[.go", .path = "[.go", .excluded = true },
        .{ .pattern = "a*b*c", .path = "axbybz", .excluded = false },
        .{ .pattern = "a*b*c", .path = "axbybc", .excluded = true },
        .{ .pattern = "Vendor/**", .path = "vendor/a.c", .excluded = false },
    };
    for (cases) |case| try std.testing.expectEqual(case.excluded, pathExcluded(case.path, &.{case.pattern}));
}

fn attributeAllocation(gpa: std.mem.Allocator) !void {
    const patterns = try attributePatterns(gpa, "# comment\n*.pb.go linguist-generated=true\nzig-pkg/** linguist-vendored\n*.go text\n");
    defer {
        for (patterns) |pattern| gpa.free(pattern);
        gpa.free(patterns);
    }
    try std.testing.expectEqual(@as(usize, 2), patterns.len);
    try std.testing.expect(pathExcluded("src/api.pb.go", patterns));
    try std.testing.expect(!pathExcluded("src/main.go", patterns));
}

test "attribute patterns own their strings and release every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, attributeAllocation, .{});
}
