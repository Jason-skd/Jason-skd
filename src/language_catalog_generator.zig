//! Offline generator for the reduced GitHub Linguist language catalog.

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const generator_version = "1";
pub const supported_types = .{ "programming", "markup", "data", "prose" };

pub const Error = Allocator.Error || std.Io.Writer.Error || error{
    EmptyDocument,
    InvalidTopLevelEntry,
    InvalidField,
    DuplicateField,
    MissingType,
    InvalidType,
    InvalidList,
    InvalidScalar,
    UnsupportedShape,
    EmptyLanguageName,
    EmptyRevision,
    InvalidMapping,
};

pub const Options = struct {
    source_revision: []const u8,
    source_path: []const u8 = "github-linguist/linguist/lib/linguist/languages.yml",
    generator_version: []const u8 = generator_version,
};

const Override = struct { key: []const u8, language: []const u8 };

const extension_overrides = [_]Override{
    .{ .key = ".h", .language = "C" },
    .{ .key = ".m", .language = "Objective-C" },
    .{ .key = ".mm", .language = "Objective-C" },
    .{ .key = ".sql", .language = "SQL" },
    .{ .key = ".pl", .language = "Perl" },
    .{ .key = ".r", .language = "R" },
    .{ .key = ".ts", .language = "TypeScript" },
    .{ .key = ".tsx", .language = "TypeScript" },
    .{ .key = ".rs", .language = "Rust" },
    .{ .key = ".php", .language = "PHP" },
    .{ .key = ".html", .language = "HTML" },
    .{ .key = ".md", .language = "Markdown" },
    .{ .key = ".mdx", .language = "Markdown" },
    .{ .key = ".yaml", .language = "YAML" },
    .{ .key = ".yml", .language = "YAML" },
    .{ .key = ".vsixmanifest", .language = "XML" },
};

const Language = struct {
    name: []const u8,
    language_type: []const u8,
    extensions: []const []const u8,
    filenames: []const []const u8,
};

const Mapping = struct {
    key: []const u8,
    language: []const u8,
};

const Parsed = struct {
    languages: []Language,
    extensions: []Mapping,
    filenames: []Mapping,
};

const Parser = struct {
    allocator: Allocator,
    languages: ArrayList(Language),
    language_names: ArrayList([]const u8),

    fn init(allocator: Allocator) Parser {
        return .{ .allocator = allocator, .languages = .empty, .language_names = .empty };
    }

    fn deinit(self: *Parser) void {
        self.languages.deinit(self.allocator);
        self.language_names.deinit(self.allocator);
    }

    fn parse(self: *Parser, input: []const u8) Error!Parsed {
        var lines = ArrayList([]const u8).empty;
        defer lines.deinit(self.allocator);
        var input_lines = std.mem.splitScalar(u8, input, '\n');
        while (input_lines.next()) |line| try lines.append(self.allocator, line);

        var index: usize = 0;
        var saw_language = false;
        while (index < lines.items.len) {
            const raw_header = lines.items[index];
            index += 1;
            const header = std.mem.trim(u8, raw_header, " \t\r");
            if (header.len == 0 or header[0] == '#') continue;
            if (raw_header.len != header.len) return error.InvalidTopLevelEntry;
            if (std.mem.eql(u8, header, "---")) continue;

            const colon = std.mem.indexOfScalar(u8, header, ':') orelse return error.InvalidTopLevelEntry;
            if (colon + 1 != header.len) return error.InvalidTopLevelEntry;
            const name = try scalar(self.allocator, header[0..colon]);
            if (name.len == 0) return error.EmptyLanguageName;
            if (containsString(self.language_names.items, name)) return error.DuplicateField;

            var language_type: ?[]const u8 = null;
            var extensions = ArrayList([]const u8).empty;
            var filenames = ArrayList([]const u8).empty;
            var seen_type = false;
            var seen_extensions = false;
            var seen_filenames = false;

            while (index < lines.items.len) {
                const raw_field = lines.items[index];
                const trimmed = std.mem.trim(u8, raw_field, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') {
                    index += 1;
                    continue;
                }
                if (raw_field[0] != ' ') break;
                if (!std.mem.startsWith(u8, raw_field, "  ") or std.mem.startsWith(u8, raw_field, "    ")) return error.UnsupportedShape;
                index += 1;

                const field_line = raw_field[2..];
                const field_colon = std.mem.indexOfScalar(u8, field_line, ':') orelse return error.InvalidField;
                const field_name = field_line[0..field_colon];
                const value_text = std.mem.trim(u8, field_line[field_colon + 1 ..], " \t\r");

                if (std.mem.eql(u8, field_name, "type")) {
                    if (seen_type) return error.DuplicateField;
                    seen_type = true;
                    if (value_text.len == 0) return error.InvalidScalar;
                    language_type = try scalar(self.allocator, value_text);
                    if (!isSupportedType(language_type.?)) return error.InvalidType;
                } else if (std.mem.eql(u8, field_name, "extensions") or std.mem.eql(u8, field_name, "filenames")) {
                    const is_filenames = std.mem.eql(u8, field_name, "filenames");
                    if (is_filenames and seen_filenames or !is_filenames and seen_extensions) return error.DuplicateField;
                    if (is_filenames) seen_filenames = true else seen_extensions = true;
                    if (std.mem.eql(u8, value_text, "[]")) continue;
                    if (value_text.len != 0) return error.InvalidList;
                    var target = if (is_filenames) &filenames else &extensions;
                    while (index < lines.items.len) {
                        const raw_item = lines.items[index];
                        const item_trimmed = std.mem.trim(u8, raw_item, " \t\r");
                        if (item_trimmed.len == 0 or item_trimmed[0] == '#') {
                            index += 1;
                            continue;
                        }
                        if (!std.mem.startsWith(u8, raw_item, "  - ") and !std.mem.startsWith(u8, raw_item, "    - ")) break;
                        index += 1;
                        const item = try scalar(self.allocator, if (item_trimmed.len > 1) item_trimmed[2..] else "");
                        if (item.len == 0) return error.InvalidScalar;
                        for (@constCast(item)) |*character| character.* = std.ascii.toLower(character.*);
                        if (!validMapping(is_filenames, item)) return error.InvalidMapping;
                        if (containsString(target.items, item)) continue;
                        try target.append(self.allocator, item);
                    }
                } else if (isIgnoredListField(field_name)) {
                    if (std.mem.eql(u8, value_text, "[]")) continue;
                    if (value_text.len != 0) return error.InvalidList;
                    while (index < lines.items.len) {
                        const raw_item = lines.items[index];
                        const item_trimmed = std.mem.trim(u8, raw_item, " \t\r");
                        if (item_trimmed.len == 0 or item_trimmed[0] == '#') {
                            index += 1;
                            continue;
                        }
                        if (!std.mem.startsWith(u8, raw_item, "  - ") and !std.mem.startsWith(u8, raw_item, "    - ")) break;
                        const item = try scalar(self.allocator, if (item_trimmed.len > 1) item_trimmed[2..] else "");
                        if (item.len == 0) return error.InvalidScalar;
                        index += 1;
                    }
                } else if (isIgnoredScalarField(field_name)) {
                    if (value_text.len == 0) return error.InvalidScalar;
                } else return error.InvalidField;
            }

            if (language_type == null) return error.MissingType;
            try self.languages.append(self.allocator, .{
                .name = name,
                .language_type = language_type.?,
                .extensions = try extensions.toOwnedSlice(self.allocator),
                .filenames = try filenames.toOwnedSlice(self.allocator),
            });
            try self.language_names.append(self.allocator, name);
            saw_language = true;
        }

        if (!saw_language) return error.EmptyDocument;
        std.mem.sort(Language, self.languages.items, {}, lessLanguage);
        return .{
            .languages = self.languages.items,
            .extensions = try buildMappings(self.allocator, self.languages.items, false),
            .filenames = try buildMappings(self.allocator, self.languages.items, true),
        };
    }
};

pub fn generate(allocator: Allocator, input: []const u8, options: Options) Error![]u8 {
    if (options.source_revision.len == 0) return error.EmptyRevision;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator());
    defer parser.deinit();
    const parsed = try parser.parse(input);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeOutput(&output.writer, input, options, parsed);
    return try output.toOwnedSlice();
}

fn buildMappings(allocator: Allocator, languages: []const Language, filenames: bool) Error![]Mapping {
    var mappings = ArrayList(Mapping).empty;
    for (languages) |language| {
        const values = if (filenames) language.filenames else language.extensions;
        for (values) |value| {
            var found = false;
            for (mappings.items) |*mapping| {
                if (std.mem.eql(u8, mapping.key, value)) {
                    found = true;
                    break;
                }
            }
            if (!found) try mappings.append(allocator, .{ .key = value, .language = language.name });
        }
    }
    if (!filenames) {
        for (mappings.items) |*mapping| {
            if (overrideFor(mapping.key)) |override| {
                for (languages) |language| {
                    if (std.mem.eql(u8, language.name, override)) {
                        mapping.language = override;
                        break;
                    }
                }
            }
        }
    }
    std.mem.sort(Mapping, mappings.items, {}, lessMapping);
    return mappings.toOwnedSlice(allocator);
}

fn lessMapping(_: void, left: Mapping, right: Mapping) bool {
    return std.mem.lessThan(u8, left.key, right.key);
}

fn lessLanguage(_: void, left: Language, right: Language) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn writeOutput(writer: *std.Io.Writer, input: []const u8, options: Options, parsed: Parsed) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try writer.writeAll("//! Generated by language_catalog_generator. Do not edit.\n\n");
    try writer.writeAll("pub const source_revision = ");
    try writer.printStringEscaped(options.source_revision);
    try writer.writeAll(";\npub const source_path = ");
    try writer.printStringEscaped(options.source_path);
    try writer.writeAll(";\npub const input_sha256 = ");
    try writer.printStringEscaped(&digest_hex);
    try writer.writeAll(";\npub const generator_version = ");
    try writer.printStringEscaped(options.generator_version);
    try writer.writeAll(";\n");
    try writer.print("pub const language_count: usize = {d};\n", .{parsed.languages.len});
    try writer.print("pub const extension_count: usize = {d};\n", .{parsed.extensions.len});
    try writer.print("pub const filename_count: usize = {d};\n\n", .{parsed.filenames.len});
    try writer.writeAll("pub const Language = struct { name: []const u8, language_type: []const u8 };\n");
    try writer.writeAll("pub const Mapping = struct { key: []const u8, language: []const u8 };\n\n");
    try writer.writeAll("pub const languages = [_]Language{\n");
    for (parsed.languages) |language| {
        try writer.writeAll("    .{ .name = ");
        try writer.printStringEscaped(language.name);
        try writer.writeAll(", .language_type = ");
        try writer.printStringEscaped(language.language_type);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n\npub const extensions = [_]Mapping{\n");
    for (parsed.extensions) |mapping| {
        try writer.writeAll("    .{ .key = ");
        try writer.printStringEscaped(mapping.key);
        try writer.writeAll(", .language = ");
        try writer.printStringEscaped(mapping.language);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n\npub const filenames = [_]Mapping{\n");
    for (parsed.filenames) |mapping| {
        try writer.writeAll("    .{ .key = ");
        try writer.printStringEscaped(mapping.key);
        try writer.writeAll(", .language = ");
        try writer.printStringEscaped(mapping.language);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n");
}

fn scalar(allocator: Allocator, raw: []const u8) Error![]const u8 {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len == 0) return error.InvalidScalar;
    if (value[0] == '\'' or value[0] == '"') {
        if (value.len < 2 or value[value.len - 1] != value[0]) return error.InvalidScalar;
        const contents = value[1 .. value.len - 1];
        if (std.mem.indexOfScalar(u8, contents, value[0]) != null or
            value[0] == '"' and std.mem.indexOfScalar(u8, contents, '\\') != null)
            return error.UnsupportedShape;
        return allocator.dupe(u8, contents);
    }
    return allocator.dupe(u8, value);
}

fn containsString(values: []const []const u8, value: []const u8) bool {
    for (values) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

fn overrideFor(key: []const u8) ?[]const u8 {
    for (extension_overrides) |override| if (std.mem.eql(u8, override.key, key)) return override.language;
    return null;
}

fn validMapping(is_filenames: bool, value: []const u8) bool {
    if (value.len == 0) return false;
    if (is_filenames) {
        if (std.mem.indexOfScalar(u8, value, '/') != null) return false;
    } else if (value[0] != '.') return false;
    for (value) |character| if (std.ascii.isWhitespace(character) or character < 0x20 or character == '"' or character == '\\') return false;
    return true;
}

fn isSupportedType(value: []const u8) bool {
    inline for (supported_types) |item| if (std.mem.eql(u8, value, item)) return true;
    return false;
}

fn isIgnoredListField(name: []const u8) bool {
    return std.mem.eql(u8, name, "aliases") or std.mem.eql(u8, name, "interpreters");
}

fn isIgnoredScalarField(name: []const u8) bool {
    return std.mem.eql(u8, name, "ace_mode") or
        std.mem.eql(u8, name, "codemirror_mime_type") or
        std.mem.eql(u8, name, "codemirror_mode") or
        std.mem.eql(u8, name, "color") or
        std.mem.eql(u8, name, "fs_name") or
        std.mem.eql(u8, name, "group") or
        std.mem.eql(u8, name, "language_id") or
        std.mem.eql(u8, name, "searchable") or
        std.mem.eql(u8, name, "tm_scope") or
        std.mem.eql(u8, name, "wrap");
}

test "generator is deterministic and records source metadata" {
    const input = "Zig:\n" ++
        "  type: programming\n" ++
        "  extensions:\n" ++
        "    - .zig\n" ++
        "  filenames:\n" ++
        "    - build.zig\n" ++
        "Markdown:\n" ++
        "  type: prose\n" ++
        "  extensions:\n" ++
        "    - .md\n";
    const first = try generate(std.testing.allocator, input, .{ .source_revision = "fixture-1" });
    defer std.testing.allocator.free(first);
    const second = try generate(std.testing.allocator, input, .{ .source_revision = "fixture-1" });
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "source_revision = \"fixture-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "language_count: usize = 2") != null);
}

test "generator rejects unsupported and malformed input" {
    try std.testing.expectError(error.InvalidField, generate(std.testing.allocator, "Zig:\n  type: programming\n  color: \"x\"\n  unknown: value\n", .{ .source_revision = "x" }));
    try std.testing.expectError(error.InvalidType, generate(std.testing.allocator, "Zig:\n  type: unknown\n", .{ .source_revision = "x" }));
    try std.testing.expectError(error.DuplicateField, generate(std.testing.allocator, "Zig:\n  type: programming\n  type: prose\n", .{ .source_revision = "x" }));
    try std.testing.expectError(error.InvalidScalar, generate(std.testing.allocator, "Zig:\n  type: programming\n  aliases:\n  - \n", .{ .source_revision = "x" }));
    try std.testing.expectError(error.UnsupportedShape, generate(std.testing.allocator, "Zig:\n  type: programming\n  extensions:\n  - \".z\\x69g\"\n", .{ .source_revision = "x" }));
}
