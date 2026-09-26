const std = @import("std");
const render = @import("render.zig");
const config = @import("config.zig");
const payload = @import("page_payload.zig");
const Writer = std.Io.Writer;

// Inputs mirror the independently maintained Python component fixtures.
pub const cfg: config.Config = .{
    .login = "Jason-skd",
    .timezone = .asia_shanghai,
    .theme = .{ .base = "1a1b26", .accent = "7aa2f7", .cyan = "7dcfff" },
    .author_emails = &.{},
    .org = .{ .login = "SCNUAutoPtr", .repos = null },
    .window_days = 365,
    .include_external = true,
    .sections = &.{ .banner, .typing, .stats, .languages, .org_card, .recent_project },
    .stats = .{ .header = "📊 Last 365 Days" },
    .typing = .{ .lines = &.{ "wintor_ · CS @ Aberdeen", "C / Python / Zig · 造轮子爱好者", "AutoBits @ SCNUAutoPtr 成员", "LeetCode & Codeforces 选手" }, .font = "Fira Code", .size = 22, .width = 470, .height = null, .duration = null, .pause = null, .background = null },
    .banner = .{ .height = 200, .instance = null, .text = null, .desc = null, .font_size = null, .font_align = null, .desc_size = null, .desc_align = null },
    .languages = .{ .header = "🧑‍💻 Languages", .top = 8, .icon_height = 36, .types = null },
    .org_card = .{ .enabled = true, .header = "🏫 Organization", .logo_height = 96 },
    .recent_project = .{ .enabled = true, .header = "🚀 Recently Working On", .icon_height = 96, .exclude_external = true },
};
pub const page: payload.Page = .{
    .stats = .{ .stars = 21, .contributions = 976, .active_days = 149, .window_days = 365, .private_contributions = 320, .degraded = false, .breakdown = .{ .commits = 538, .issues = 52, .pull_requests = 41, .reviews = 15, .repositories_created = 10 } },
    .languages = &.{
        .{ .name = "Python", .weight = 5230, .percentage_tenths = 352 },
        .{ .name = "TypeScript", .weight = 2980, .percentage_tenths = 201 },
        .{ .name = "Zig", .weight = 2650, .percentage_tenths = 178 },
        .{ .name = "C", .weight = 1190, .percentage_tenths = 80 },
        .{ .name = "Kotlin", .weight = 970, .percentage_tenths = 65 },
        .{ .name = "Go", .weight = 860, .percentage_tenths = 59 },
        .{ .name = "C#", .weight = 610, .percentage_tenths = 40 },
        .{ .name = "CSS", .weight = 370, .percentage_tenths = 25 },
    },
    .organization = .{ .display_name = "AutoBits @ SCNUAutoPtr", .avatar_url = "https://avatars.githubusercontent.com/u/129657365?v=4", .github_url = "https://github.com/SCNUAutoPtr" },
    .recent_project = .{ .window_days = 365, .selection = .{ .project = .{ .identity = "Jason-skd/dsh-session-fork", .repository_name = "dsh-session-fork", .github_url = "https://github.com/Jason-skd/dsh-session-fork", .description = "DeepSeek Harness 会话分支治理插件", .primary_language = "TypeScript", .commit_count = 6, .tier = .yesterday } } },
};

fn golden(comptime name: []const u8, comptime function: anytype, args: anytype) !void {
    var buffer: [8192]u8 = undefined;
    var w = Writer.fixed(&buffer);
    try @call(.auto, function, .{&w} ++ args);
    try std.testing.expectEqualStrings(@embedFile("render_fixtures/" ++ name ++ ".md"), w.buffered());
    var small: [1]u8 = undefined;
    var failing = Writer.fixed(&small);
    try std.testing.expectError(error.WriteFailed, @call(.auto, function, .{&failing} ++ args));
}

test "banner golden and writer failure" {
    try golden("banner", render.banner, .{ &cfg.banner, &cfg.theme });
}
test "typing golden and writer failure" {
    try golden("typing", render.typing, .{ &cfg.typing, &cfg.theme });
}
test "stats golden and writer failure" {
    try golden("stats", render.stats, .{ &cfg.stats, &cfg.theme, &page.stats });
}
test "languages golden and writer failure" {
    try golden("languages", render.languages, .{ &cfg.languages, page.languages });
}
test "organization golden and writer failure" {
    try golden("org_card", render.organization, .{ &cfg.org_card, &page.organization.? });
}
test "recent project golden and writer failure" {
    try golden("recent_project", render.recentProject, .{ &cfg.recent_project, &page.recent_project });
}

fn contains(actual: []const u8, expected: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, actual, expected) != null);
}

test "banner query values encode reserved and Unicode bytes with text defaults" {
    var options = cfg.banner;
    options.instance = "https://example.test/api///";
    options.text = "a b&c/é?=;#%";
    options.desc = "<Hello>";
    var buffer: [2048]u8 = undefined;
    var w = Writer.fixed(&buffer);
    try render.banner(&w, &options, &cfg.theme);
    try contains(w.buffered(), "https://example.test/api?type=");
    try contains(w.buffered(), "&amp;text=a%20b%26c%2F%C3%A9%3F%3D%3B%23%25&amp;fontSize=42&amp;fontAlign=50");
    try contains(w.buffered(), "&amp;desc=%3CHello%3E&amp;descSize=20&amp;descAlign=50");
}

test "typing rejects missing and blank lines and encodes line delimiters" {
    var options = cfg.typing;
    var buffer: [2048]u8 = undefined;
    var w = Writer.fixed(&buffer);
    options.lines = null;
    try std.testing.expectError(error.InvalidSection, render.typing(&w, &options, &cfg.theme));
    options.lines = &.{" \n "};
    try std.testing.expectError(error.InvalidSection, render.typing(&w, &options, &cfg.theme));
    options.lines = &.{ "a;b", "x&y" };
    options.height = 100;
    options.duration = 20;
    options.pause = 0;
    options.background = "123456";
    try render.typing(&w, &options, &cfg.theme);
    try contains(w.buffered(), "lines=a%3Bb;x%26y");
    try contains(w.buffered(), "&amp;height=100");
    try contains(w.buffered(), "&amp;duration=20&amp;pause=0&amp;background=123456");
}

test "language fallback escapes text and preserves tenths without selecting again" {
    var options = cfg.languages;
    options.top = 1;
    options.header = "<Languages & friends>";
    var buffer: [2048]u8 = undefined;
    var w = Writer.fixed(&buffer);
    try render.languages(&w, &options, &.{ .{ .name = "\"A&B<>'", .weight = 999, .percentage_tenths = 999 }, .{ .name = "Unknown", .weight = 1, .percentage_tenths = 1 } });
    try contains(w.buffered(), "&lt;Languages &amp; friends&gt;");
    try contains(w.buffered(), "<b>&quot;A&amp;B&lt;&gt;&#39;</b> 99.9%");
    try contains(w.buffered(), "<b>Unknown</b> 0.1%");
    try std.testing.expectError(error.MissingLanguages, render.languages(&w, &options, &.{}));
}

test "organization escapes attributes without double percent encoding URLs" {
    var org = page.organization.?;
    org.display_name = "A \"B\" & C";
    org.avatar_url = "https://example.test/a%20b?x=1&y=2";
    var buffer: [2048]u8 = undefined;
    var w = Writer.fixed(&buffer);
    try render.organization(&w, &cfg.org_card, &org);
    try contains(w.buffered(), "a%20b?x=1&amp;y=2");
    try contains(w.buffered(), "alt=\"A &quot;B&quot; &amp; C\"");
    org.avatar_url = "";
    try std.testing.expectError(error.MissingOrganization, render.organization(&w, &cfg.org_card, &org));
}

test "recent project empty copy carries actual window and fallback keeps link" {
    var buffer: [2048]u8 = undefined;
    var w = Writer.fixed(&buffer);
    try render.recentProject(&w, &cfg.recent_project, &.{ .window_days = 90, .selection = .none });
    try std.testing.expectEqualStrings("<h3 align=\"center\">🚀 Recently Working On</h3>\n\n<p align=\"center\"><sub>No commits to show in the last 90 days</sub></p>", w.buffered());
    w = Writer.fixed(&buffer);
    var data = page.recent_project;
    data.selection.project.primary_language = null;
    data.selection.project.repository_name = "A&B";
    data.selection.project.commit_count = 0;
    try render.recentProject(&w, &cfg.recent_project, &data);
    try contains(w.buffered(), "<b>A&amp;B</b></a>\n</p>");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "commits") == null);
}

test "stats reflects payload window degradation and configured accent" {
    var data = page.stats;
    data.window_days = 30;
    data.degraded = true;
    var theme = cfg.theme;
    theme.accent = "123456";
    var buffer: [2048]u8 = undefined;
    var w = Writer.fixed(&buffer);
    try render.stats(&w, &.{ .header = "Custom" }, &theme, &data);
    try contains(w.buffered(), "stars-21-123456");
    try contains(w.buffered(), "Last 30 days · incl. 320 private contributions | ⚠️ public data only (no PAT)");
}
