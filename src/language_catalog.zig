//! Offline language lookup from the generated Linguist snapshot.

const std = @import("std");
const snapshot = @import("language_catalog_snapshot.zig");

pub const LanguageType = enum {
    programming,
    markup,
    data,
    prose,
};

pub const Language = struct {
    /// Name borrowed from the static catalog snapshot.
    name: []const u8,
    language_type: LanguageType,
};

/// Classifies a repository-relative path without I/O or allocation.
///
/// The last path component is checked as a special filename first. Extension
/// candidates are then tried from longest to shortest, including the dot.
pub fn classify(path: []const u8) ?Language {
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
    if (basename.len == 0) return null;
    if (findMapping(&snapshot.filenames, basename)) |name| return findLanguage(name);

    var dot = std.mem.indexOfScalar(u8, basename, '.') orelse return null;
    while (true) {
        if (findMapping(&snapshot.extensions, basename[dot..])) |name| return findLanguage(name);
        dot = std.mem.indexOfScalarPos(u8, basename, dot + 1, '.') orelse return null;
    }
}

fn findMapping(mappings: []const snapshot.Mapping, key: []const u8) ?[]const u8 {
    var low: usize = 0;
    var high: usize = mappings.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (orderIgnoreCase(key, mappings[middle].key)) {
            .lt => high = middle,
            .eq => return mappings[middle].language,
            .gt => low = middle + 1,
        }
    }
    return null;
}

fn findLanguage(name: []const u8) ?Language {
    var low: usize = 0;
    var high: usize = snapshot.languages.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, name, snapshot.languages[middle].name)) {
            .lt => high = middle,
            .eq => return .{
                .name = snapshot.languages[middle].name,
                .language_type = std.meta.stringToEnum(LanguageType, snapshot.languages[middle].language_type).?,
            },
            .gt => low = middle + 1,
        }
    }
    return null;
}

fn orderIgnoreCase(left: []const u8, right: []const u8) std.math.Order {
    const common = @min(left.len, right.len);
    for (left[0..common], right[0..common]) |a, b| {
        const order = std.math.order(std.ascii.toLower(a), std.ascii.toLower(b));
        if (order != .eq) return order;
    }
    return std.math.order(left.len, right.len);
}

test "special filenames precede extensions and ignore ASCII case" {
    const special = classify("config/TSCONFIG.JSON").?;
    try std.testing.expectEqualStrings("JSON with Comments", special.name);
    try std.testing.expectEqual(LanguageType.data, special.language_type);

    const extension = classify("config/other.JSON").?;
    try std.testing.expectEqualStrings("JSON", extension.name);
    try std.testing.expectEqual(LanguageType.data, extension.language_type);
}

test "ordinary and multi-part extensions use the longest catalog match" {
    try std.testing.expectEqualStrings("Zig", classify("src/MAIN.ZIG").?.name);
    try std.testing.expectEqualStrings("Blade", classify("views/page.BLADE.PHP").?.name);
    try std.testing.expectEqualStrings("PHP", classify("views/page.other.PHP").?.name);
}

test "unknown and extensionless paths have no language" {
    try std.testing.expect(classify("src/no-extension") == null);
    try std.testing.expect(classify("src/file.unknown-extension") == null);
    try std.testing.expect(classify("src/") == null);
    try std.testing.expectEqualStrings("Dockerfile", classify("nested/DOCKERFILE").?.name);
}

test "catalog returns all four closed language types" {
    try std.testing.expectEqual(LanguageType.programming, classify("src/main.zig").?.language_type);
    try std.testing.expectEqual(LanguageType.markup, classify("styles/main.css").?.language_type);
    try std.testing.expectEqual(LanguageType.data, classify("config/data.json").?.language_type);
    try std.testing.expectEqual(LanguageType.prose, classify("docs/readme.md").?.language_type);
}
