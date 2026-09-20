const std = @import("std");
const model = @import("model.zig");
const raw_model = @import("raw.zig");

pub fn normalize(allocator: std.mem.Allocator, raw: raw_model.RawConfig) std.mem.Allocator.Error!model.Config {
    return .{
        .login = try allocator.dupe(u8, raw.login.?),
        .timezone = .asia_shanghai,
        .theme = .{
            .base = try normalizeColor(allocator, raw.theme.base orelse "1a1b26"),
            .accent = try normalizeColor(allocator, raw.theme.accent orelse "7aa2f7"),
            .cyan = try normalizeColor(allocator, raw.theme.cyan orelse "7dcfff"),
        },
        .author_emails = try copyStringList(allocator, raw.author_emails.?),
        .org = .{
            .login = try copyOptionalString(allocator, raw.org.login),
            .repos = try copyOptionalStringList(allocator, raw.org.repos),
        },
        .window_days = boundPositive(raw.window_days.?),
        .include_external = raw.include_external orelse true,
        .sections = try copySections(allocator, raw.sections.?),
        .stats = .{
            .header = if (raw.stats.header) |header|
                if (header.len == 0) try defaultStatsHeader(allocator, boundPositive(raw.window_days.?)) else try allocator.dupe(u8, header)
            else
                try defaultStatsHeader(allocator, boundPositive(raw.window_days.?)),
        },
        .typing = .{
            .lines = try copyOptionalStringList(allocator, raw.typing.lines),
            .font = try copyStringOrDefault(allocator, raw.typing.font, "Fira Code"),
            .size = boundPositiveOr(raw.typing.size, 22),
            .width = boundPositive(raw.typing.width.?),
            .height = boundOptionalPositive(raw.typing.height),
            .duration = boundOptionalPositive(raw.typing.duration),
            .pause = boundOptionalPositive(raw.typing.pause),
            .background = try copyOptionalString(allocator, raw.typing.background),
        },
        .banner = .{
            .height = boundPositiveOr(raw.banner.height, 200),
            .instance = try copyOptionalString(allocator, raw.banner.instance),
            .text = try copyOptionalString(allocator, raw.banner.text),
            .desc = try copyOptionalString(allocator, raw.banner.desc),
            .font_size = boundOptionalPositive(raw.banner.font_size),
            .font_align = boundOptionalPositive(raw.banner.font_align),
            .desc_size = boundOptionalPositive(raw.banner.desc_size),
            .desc_align = boundOptionalPositive(raw.banner.desc_align),
        },
        .languages = .{
            .header = try copyStringOrDefault(allocator, raw.languages.header, "🧑‍💻 Languages"),
            .top = boundPositiveOr(raw.languages.top, 8),
            .icon_height = boundPositiveOr(raw.languages.icon_height, 48),
            .types = try copyOptionalStringList(allocator, raw.languages.types),
        },
        .org_card = .{
            .enabled = raw.org_card.enabled orelse true,
            .header = try copyStringOrDefault(allocator, raw.org_card.header, "🏫 Organization"),
            .logo_height = boundPositiveOr(raw.org_card.logo_height, 96),
        },
        .recent_project = .{
            .enabled = raw.recent_project.enabled orelse true,
            .header = try copyStringOrDefault(allocator, raw.recent_project.header, "🚀 Recently Working On"),
            .icon_height = boundPositiveOr(raw.recent_project.icon_height, 96),
            .exclude_external = raw.recent_project.exclude_external orelse true,
        },
    };
}

fn copyStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| result[index] = try allocator.dupe(u8, value);
    return result;
}

fn copyOptionalStringList(allocator: std.mem.Allocator, values: ?[]const []const u8) !?[]const []const u8 {
    return if (values) |present| try copyStringList(allocator, present) else null;
}

fn copyOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |present| try allocator.dupe(u8, present) else null;
}

fn copyStringOrDefault(allocator: std.mem.Allocator, value: ?[]const u8, default: []const u8) ![]const u8 {
    if (value) |present| {
        if (present.len != 0) return allocator.dupe(u8, present);
    }
    return default;
}

fn copySections(allocator: std.mem.Allocator, values: []const []const u8) ![]const model.Section {
    const sections = try allocator.alloc(model.Section, values.len);
    for (values, 0..) |value, index| sections[index] = std.meta.stringToEnum(model.Section, value).?;
    return sections;
}

fn normalizeColor(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const source = if (value.len == 7 and value[0] == '#') value[1..] else value;
    const result = try allocator.alloc(u8, 6);
    for (source, 0..) |char, index| result[index] = std.ascii.toLower(char);
    return result;
}

fn defaultStatsHeader(allocator: std.mem.Allocator, window_days: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "📊 Last {d} Days", .{window_days});
}

fn boundPositive(value: []const u8) u32 {
    return std.fmt.parseInt(u32, value, 10) catch unreachable;
}

fn boundPositiveOr(value: ?[]const u8, default: u32) u32 {
    return if (value) |present| boundPositive(present) else default;
}

fn boundOptionalPositive(value: ?[]const u8) ?u32 {
    return if (value) |present| boundPositive(present) else null;
}
