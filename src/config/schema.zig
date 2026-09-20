const std = @import("std");
const model = @import("model.zig");
const diagnostic_module = @import("diagnostic.zig");

const Diagnostic = diagnostic_module.Diagnostic;
const Section = model.Section;
const invalid = diagnostic_module.invalid;

pub const SchemaReader = struct {
    yaml: []const u8,
    index: usize = 0,

    pub fn readLine(self: *SchemaReader, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.index >= self.yaml.len) return null;
        const remaining = self.yaml[self.index..];
        const end = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
        const line = try allocator.dupe(u8, remaining[0..end]);
        self.index += if (end < remaining.len) end + 1 else end;
        return line;
    }
};
const TopKey = enum(u4) {
    login,
    timezone,
    theme,
    author_emails,
    org,
    window_days,
    include_external,
    sections,
    stats,
    typing,
    banner,
    languages,
    org_card,
    recent_project,
};

const ValueKind = enum {
    string,
    positive_integer,
    boolean,
    string_list,
    mapping,
    theme_color,
};

const ChildSpec = struct {
    index: u5,
    kind: ValueKind,
    path: []const u8,
};

const MappingState = struct {
    present: [14]bool = @splat(false),
    nested_seen: [14]u32 = @splat(0),
    section_bits: u8 = 0,
    section_count: usize = 0,
    author_count: usize = 0,
    typing_line_count: usize = 0,
    org_repo_count: usize = 0,
    org_card_enabled: bool = true,
};

pub fn preflight(
    allocator: std.mem.Allocator,
    yaml: []const u8,
    diagnostic: *Diagnostic,
) (std.mem.Allocator.Error || error{InvalidConfig})![]const u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, yaml.len + 256);
    defer output.deinit(allocator);

    var state: MappingState = .{};
    var seen_top: u16 = 0;
    var current_top: ?TopKey = null;
    var current_list: ?ChildSpec = null;

    var line_iterator = std.mem.splitScalar(u8, yaml, '\n');
    var line_number: usize = 0;
    while (line_iterator.next()) |raw_with_cr| {
        line_number += 1;
        const raw_line = std.mem.trimEnd(u8, raw_with_cr, "\r");
        if (std.mem.indexOfScalar(u8, raw_line, '\t') != null) {
            return invalid(diagnostic, .invalid_yaml, line_number, "", raw_line, "tabs are not allowed in profile YAML indentation");
        }

        const uncommented = stripComment(raw_line) catch {
            return invalid(diagnostic, .invalid_yaml, line_number, "", raw_line, "unterminated quoted scalar");
        };
        const content = std.mem.trimEnd(u8, uncommented, " ");
        if (std.mem.trim(u8, content, " ").len == 0) continue;
        if (std.mem.eql(u8, std.mem.trim(u8, content, " "), "---")) continue;

        const indent = leadingSpaces(content);
        if (indent != 0 and indent != 2 and indent != 4) {
            return invalid(diagnostic, .invalid_yaml, line_number, "", raw_line, "profile YAML uses two-space mapping and list indentation");
        }

        if (indent == 0) {
            const entry = splitMapping(content) orelse
                return invalid(diagnostic, .invalid_yaml, line_number, "", raw_line, "top-level entries must be mappings");
            const top = std.meta.stringToEnum(TopKey, entry.key) orelse {
                const code: Diagnostic.Code = if (isUnsupported(entry.key)) .unsupported_field else .unknown_field;
                const message = if (code == .unsupported_field)
                    "field is not supported by the Zig profile schema"
                else
                    "unknown top-level profile field";
                return invalid(diagnostic, code, line_number, entry.key, raw_line, message);
            };
            const bit = bitFor(top);
            if (seen_top & bit != 0) {
                return invalid(diagnostic, .duplicate_field, line_number, entry.key, raw_line, "duplicate top-level profile field");
            }
            seen_top |= bit;
            state.present[@backingInt(top)] = true;
            current_top = top;
            current_list = null;

            const kind = topKind(top);
            if (kind == .mapping or kind == .string_list) {
                if (entry.value.len != 0) {
                    return invalid(diagnostic, .invalid_type, line_number, entry.key, raw_line, "mapping and list fields must use indented block syntax");
                }
            } else {
                try validateScalar(kind, entry.value, entry.key, line_number, raw_line, diagnostic);
                if (top == .timezone and !std.mem.eql(u8, scalarText(entry.value), "Asia/Shanghai")) {
                    return invalid(diagnostic, .invalid_value, line_number, "timezone", raw_line, "timezone must be Asia/Shanghai");
                }
                if (top == .login and scalarText(entry.value).len == 0) {
                    return invalid(diagnostic, .invalid_value, line_number, "login", raw_line, "login must not be empty");
                }
            }
            try appendLine(&output, allocator, content);
            continue;
        }

        const top = current_top orelse
            return invalid(diagnostic, .invalid_yaml, line_number, "", raw_line, "indented content requires a parent profile field");

        if (indent == 2 and topKind(top) == .string_list) {
            const item = listItem(content[2..]) orelse
                return invalid(diagnostic, .invalid_type, line_number, @tagName(top), raw_line, "field must contain a block list of strings");
            try validateString(item, @tagName(top), line_number, raw_line, diagnostic);
            if (scalarText(item).len == 0) {
                return invalid(diagnostic, .invalid_value, line_number, @tagName(top), raw_line, "list entries must not be empty");
            }
            if (top == .author_emails) state.author_count += 1;
            if (top == .sections) try validateSection(&state, item, line_number, raw_line, diagnostic);
            try appendLine(&output, allocator, content);
            continue;
        }

        if (indent == 2) {
            if (topKind(top) != .mapping) {
                return invalid(diagnostic, .invalid_yaml, line_number, @tagName(top), raw_line, "unexpected nested mapping entry");
            }
            const entry = splitMapping(content[2..]) orelse
                return invalid(diagnostic, .invalid_yaml, line_number, @tagName(top), raw_line, "nested entries must be mappings");
            const spec = childSpec(top, entry.key) orelse {
                const code: Diagnostic.Code = if (isUnsupported(entry.key)) .unsupported_field else .unknown_field;
                return invalid(diagnostic, code, line_number, entry.key, raw_line, "unknown nested profile field");
            };
            const nested_bit = @as(u32, 1) << spec.index;
            if (state.nested_seen[@backingInt(top)] & nested_bit != 0) {
                return invalid(diagnostic, .duplicate_field, line_number, spec.path, raw_line, "duplicate nested profile field");
            }
            state.nested_seen[@backingInt(top)] |= nested_bit;
            current_list = null;

            if (spec.kind == .string_list) {
                if (entry.value.len != 0) {
                    return invalid(diagnostic, .invalid_type, line_number, spec.path, raw_line, "field must use an indented block list");
                }
                current_list = spec;
            } else {
                try validateScalar(spec.kind, entry.value, spec.path, line_number, raw_line, diagnostic);
                if (top == .org and std.mem.eql(u8, entry.key, "login") and scalarText(entry.value).len == 0) {
                    return invalid(diagnostic, .invalid_value, line_number, spec.path, raw_line, "org.login must not be empty");
                }
                if (top == .org_card and std.mem.eql(u8, entry.key, "enabled")) {
                    state.org_card_enabled = parseBoolean(scalarText(entry.value)).?;
                }
            }

            if (spec.kind == .theme_color) {
                try appendThemeColor(&output, allocator, entry.key, scalarText(entry.value));
            } else {
                try appendLine(&output, allocator, content);
            }
            continue;
        }

        const list_spec = current_list orelse
            return invalid(diagnostic, .invalid_yaml, line_number, @tagName(top), raw_line, "unexpected deeply nested profile value");
        const item = listItem(content[4..]) orelse
            return invalid(diagnostic, .invalid_type, line_number, list_spec.path, raw_line, "field must contain a block list of strings");
        try validateString(item, list_spec.path, line_number, raw_line, diagnostic);
        if (scalarText(item).len == 0) {
            return invalid(diagnostic, .invalid_value, line_number, list_spec.path, raw_line, "list entries must not be empty");
        }
        if (top == .typing) state.typing_line_count += 1;
        if (top == .org) state.org_repo_count += 1;
        try appendLine(&output, allocator, content);
    }

    try validateRequired(state, seen_top, diagnostic);
    const nested_tops = [_]TopKey{ .theme, .org, .stats, .typing, .banner, .languages, .org_card, .recent_project };
    inline for (nested_tops) |top| {
        if (!state.present[@backingInt(top)]) {
            try output.appendSlice(allocator, @tagName(top));
            try output.appendSlice(allocator, ":\n  _present: false\n");
        }
    }
    return output.toOwnedSlice(allocator);
}
fn validateRequired(state: MappingState, seen_top: u16, diagnostic: *Diagnostic) error{InvalidConfig}!void {
    const required_fields = [_]TopKey{ .login, .timezone, .theme, .author_emails, .window_days, .sections };
    inline for (required_fields) |required| {
        if (seen_top & bitFor(required) == 0) {
            return invalid(diagnostic, .missing_field, 0, @tagName(required), null, "required profile field is missing");
        }
    }
    if (state.author_count == 0) {
        return invalid(diagnostic, .invalid_value, 0, "author_emails", null, "author_emails must contain at least one non-empty value");
    }
    if (state.section_count == 0) {
        return invalid(diagnostic, .invalid_value, 0, "sections", null, "sections must contain at least one section");
    }
    const typing_width_bit = @as(u32, 1) << childSpec(.typing, "width").?.index;
    if (!state.present[@backingInt(TopKey.typing)] or state.nested_seen[@backingInt(TopKey.typing)] & typing_width_bit == 0) {
        return invalid(diagnostic, .missing_field, 0, "typing.width", null, "typing.width is required");
    }
    if (state.section_bits & sectionBit(.typing) != 0 and state.typing_line_count == 0) {
        return invalid(diagnostic, .missing_field, 0, "typing.lines", null, "typing.lines is required when the typing section is listed");
    }
    if (state.section_bits & sectionBit(.org_card) != 0 and state.org_card_enabled) {
        const login_bit = @as(u32, 1) << childSpec(.org, "login").?.index;
        if (!state.present[@backingInt(TopKey.org)] or state.nested_seen[@backingInt(TopKey.org)] & login_bit == 0) {
            return invalid(diagnostic, .missing_field, 0, "org.login", null, "org.login is required when org_card is listed and enabled");
        }
        if (state.org_repo_count == 0) {
            return invalid(diagnostic, .missing_field, 0, "org.repos", null, "org.repos must be non-empty when org_card is listed and enabled");
        }
    }
}

fn validateSection(
    state: *MappingState,
    raw: []const u8,
    line: usize,
    offending: []const u8,
    diagnostic: *Diagnostic,
) error{InvalidConfig}!void {
    const text = scalarText(raw);
    const section = std.meta.stringToEnum(Section, text) orelse
        return invalid(diagnostic, .unknown_section, line, "sections", offending, "unknown profile section");
    const bit = sectionBit(section);
    if (state.section_bits & bit != 0) {
        return invalid(diagnostic, .duplicate_section, line, "sections", offending, "duplicate profile section");
    }
    state.section_bits |= bit;
    state.section_count += 1;
}

fn validateScalar(
    kind: ValueKind,
    raw: []const u8,
    path: []const u8,
    line: usize,
    offending: []const u8,
    diagnostic: *Diagnostic,
) error{InvalidConfig}!void {
    if (raw.len == 0) {
        return invalid(diagnostic, .invalid_type, line, path, offending, "field requires a scalar value");
    }
    switch (kind) {
        .string => try validateString(raw, path, line, offending, diagnostic),
        .theme_color => {
            _ = scalarTextChecked(raw) catch {
                return invalid(diagnostic, .invalid_yaml, line, path, offending, "quoted scalar must use matching quotes");
            };
            const value = scalarText(raw);
            const digits = if (value.len == 7 and value[0] == '#') value[1..] else value;
            if (digits.len != 6) {
                return invalid(diagnostic, .invalid_value, line, path, offending, "theme colors must contain exactly six hexadecimal digits");
            }
            for (digits) |char| {
                if (!std.ascii.isHex(char)) {
                    return invalid(diagnostic, .invalid_value, line, path, offending, "theme colors must contain exactly six hexadecimal digits");
                }
            }
        },
        .positive_integer => {
            const value = scalarText(raw);
            const parsed = std.fmt.parseInt(u32, value, 10) catch
                return invalid(diagnostic, .invalid_type, line, path, offending, "field must be a positive integer");
            if (parsed == 0) {
                return invalid(diagnostic, .invalid_value, line, path, offending, "field must be a positive integer");
            }
        },
        .boolean => {
            if (parseBoolean(scalarText(raw)) == null) {
                return invalid(diagnostic, .invalid_type, line, path, offending, "field must be a valid boolean");
            }
        },
        .mapping, .string_list => unreachable,
    }
}

fn validateString(
    raw: []const u8,
    path: []const u8,
    line: usize,
    offending: []const u8,
    diagnostic: *Diagnostic,
) error{InvalidConfig}!void {
    _ = scalarTextChecked(raw) catch {
        return invalid(diagnostic, .invalid_yaml, line, path, offending, "quoted scalar must use matching quotes");
    };
    const value = scalarText(raw);
    if (std.mem.indexOf(u8, value, ": ") != null or std.mem.indexOfScalar(u8, value, '#') != null) {
        return invalid(diagnostic, .invalid_yaml, line, path, offending, "scalar uses syntax unsupported by the locked YAML binding");
    }
}

fn parseBoolean(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "True") or
        std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "On")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "False") or
        std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "Off")) return false;
    return null;
}

fn topKind(top: TopKey) ValueKind {
    return switch (top) {
        .login, .timezone => .string,
        .window_days => .positive_integer,
        .include_external => .boolean,
        .author_emails, .sections => .string_list,
        .theme, .org, .stats, .typing, .banner, .languages, .org_card, .recent_project => .mapping,
    };
}

fn childSpec(top: TopKey, key: []const u8) ?ChildSpec {
    return switch (top) {
        .theme => if (std.mem.eql(u8, key, "base")) .{ .index = 0, .kind = .theme_color, .path = "theme.base" } else if (std.mem.eql(u8, key, "accent")) .{ .index = 1, .kind = .theme_color, .path = "theme.accent" } else if (std.mem.eql(u8, key, "cyan")) .{ .index = 2, .kind = .theme_color, .path = "theme.cyan" } else null,
        .org => if (std.mem.eql(u8, key, "login")) .{ .index = 0, .kind = .string, .path = "org.login" } else if (std.mem.eql(u8, key, "repos")) .{ .index = 1, .kind = .string_list, .path = "org.repos" } else null,
        .stats => if (std.mem.eql(u8, key, "header")) .{ .index = 0, .kind = .string, .path = "stats.header" } else null,
        .typing => childSpecFromNames(key, "typing", &.{
            .{ "lines", .string_list },       .{ "font", .string },               .{ "size", .positive_integer },  .{ "width", .positive_integer },
            .{ "height", .positive_integer }, .{ "duration", .positive_integer }, .{ "pause", .positive_integer }, .{ "background", .string },
        }),
        .banner => childSpecFromNames(key, "banner", &.{
            .{ "height", .positive_integer },    .{ "instance", .string },             .{ "text", .string },                .{ "desc", .string },
            .{ "font_size", .positive_integer }, .{ "font_align", .positive_integer }, .{ "desc_size", .positive_integer }, .{ "desc_align", .positive_integer },
        }),
        .languages => childSpecFromNames(key, "languages", &.{
            .{ "header", .string }, .{ "top", .positive_integer }, .{ "icon_height", .positive_integer }, .{ "types", .string_list },
        }),
        .org_card => childSpecFromNames(key, "org_card", &.{
            .{ "enabled", .boolean }, .{ "header", .string }, .{ "logo_height", .positive_integer },
        }),
        .recent_project => childSpecFromNames(key, "recent_project", &.{
            .{ "enabled", .boolean }, .{ "header", .string }, .{ "icon_height", .positive_integer }, .{ "exclude_external", .boolean },
        }),
        else => null,
    };
}

const NameKind = struct { []const u8, ValueKind };

fn childSpecFromNames(key: []const u8, comptime parent: []const u8, comptime names: []const NameKind) ?ChildSpec {
    inline for (names, 0..) |entry, index| {
        if (std.mem.eql(u8, key, entry[0])) {
            return .{ .index = index, .kind = entry[1], .path = parent ++ "." ++ entry[0] };
        }
    }
    return null;
}

fn appendThemeColor(output: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const digits = if (value.len == 7 and value[0] == '#') value[1..] else value;
    try output.appendSlice(allocator, "  ");
    try output.appendSlice(allocator, key);
    try output.appendSlice(allocator, ": ");
    try output.appendSlice(allocator, digits);
    try output.append(allocator, '\n');
}

fn appendLine(output: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) !void {
    try output.appendSlice(allocator, line);
    try output.append(allocator, '\n');
}

const MappingEntry = struct {
    key: []const u8,
    value: []const u8,
};

fn splitMapping(line: []const u8) ?MappingEntry {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " ");
    if (key.len == 0 or std.mem.indexOfScalar(u8, key, ' ') != null) return null;
    if (colon + 1 < line.len and line[colon + 1] != ' ') return null;
    return .{ .key = key, .value = std.mem.trim(u8, line[colon + 1 ..], " ") };
}

fn listItem(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '-' or line[1] != ' ') return null;
    return std.mem.trim(u8, line[2..], " ");
}

fn scalarText(raw: []const u8) []const u8 {
    return scalarTextChecked(raw) catch unreachable;
}

fn scalarTextChecked(raw: []const u8) error{InvalidQuotes}![]const u8 {
    const value = std.mem.trim(u8, raw, " ");
    if (value.len == 0) return value;
    const first_quote = value[0] == '\'' or value[0] == '"';
    const last_quote = value[value.len - 1] == '\'' or value[value.len - 1] == '"';
    if (first_quote or last_quote) {
        if (value.len < 2 or value[0] != value[value.len - 1]) return error.InvalidQuotes;
        return value[1 .. value.len - 1];
    }
    return value;
}

fn stripComment(line: []const u8) error{InvalidQuotes}![]const u8 {
    var quote: ?u8 = null;
    for (line, 0..) |char, index| {
        if (quote) |active| {
            if (char == active) quote = null;
            continue;
        }
        if (char == '\'' or char == '"') {
            quote = char;
        } else if (char == '#' and (index == 0 or std.ascii.isWhitespace(line[index - 1]))) {
            return std.mem.trimEnd(u8, line[0..index], " ");
        }
    }
    if (quote != null) return error.InvalidQuotes;
    return line;
}

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn isUnsupported(key: []const u8) bool {
    return std.mem.eql(u8, key, "excludes") or std.mem.eql(u8, key, "exclude") or std.mem.eql(u8, key, "languages_card");
}

fn bitFor(top: TopKey) u16 {
    return @as(u16, 1) << @backingInt(top);
}

fn sectionBit(section: Section) u8 {
    return @as(u8, 1) << @backingInt(section);
}
