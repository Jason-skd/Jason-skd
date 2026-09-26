//! Side-effect-free section renderers. Inputs borrow normalized configuration
//! and completed payloads; the caller owns the Writer and handles partial writes.
const std = @import("std");
const config = @import("config.zig");
const payload = @import("page_payload.zig");
const Writer = std.Io.Writer;

pub const Error = Writer.Error || error{ MissingLanguages, MissingOrganization, InvalidSection };

pub fn banner(w: *Writer, cfg: *const config.BannerConfig, theme: *const config.ThemeConfig) Error!void {
    if (cfg.height == 0) return error.InvalidSection;
    const instance = std.mem.trimEnd(u8, cfg.instance orelse "https://capsule-render.vercel.app/api", "/");
    try w.print("<p align=\"center\">\n  <img src=\"{f}?type=waving&amp;color=0:{f},100:{f}&amp;height={d}&amp;section=header", .{ html(instance), query(theme.base), query(theme.accent), cfg.height });
    if (cfg.text) |text| {
        if (text.len != 0) try w.print("&amp;text={f}&amp;fontSize={d}&amp;fontAlign={d}", .{ query(text), cfg.font_size orelse 42, cfg.font_align orelse 50 });
    }
    if (cfg.desc) |desc| {
        if (desc.len != 0) try w.print("&amp;desc={f}&amp;descSize={d}&amp;descAlign={d}", .{ query(desc), cfg.desc_size orelse 20, cfg.desc_align orelse 50 });
    }
    try w.writeAll("\" alt=\"banner\" width=\"100%\" />\n</p>");
}

pub fn typing(w: *Writer, cfg: *const config.TypingConfig, theme: *const config.ThemeConfig) Error!void {
    const lines = cfg.lines orelse return error.InvalidSection;
    if (lines.len == 0 or cfg.size == 0 or cfg.width == 0) return error.InvalidSection;
    for (lines) |line| if (std.mem.trim(u8, line, " \t\r\n").len == 0) return error.InvalidSection;
    const height: u64 = cfg.height orelse (@as(u64, cfg.size) * 2 + 18);
    if (height == 0) return error.InvalidSection;
    try w.writeAll("<p align=\"center\">\n  <a href=\"https://git.io/typing-svg\">\n    <img src=\"https://readme-typing-svg.demolab.com/?lines=");
    for (lines, 0..) |line, index| {
        if (index != 0) try w.writeByte(';');
        try query(line).format(w);
    }
    try w.print("&amp;font={f}&amp;size={d}&amp;width={d}&amp;height={d}&amp;color={f}&amp;center=true&amp;vCenter=true&amp;duration={d}&amp;pause={d}", .{ query(cfg.font), cfg.size, cfg.width, height, query(theme.accent), cfg.duration orelse 4000, cfg.pause orelse 800 });
    if (cfg.background) |value| try w.print("&amp;background={f}", .{query(value)});
    try w.writeAll("\" alt=\"Typing SVG\" />\n  </a>\n</p>");
}

pub fn stats(w: *Writer, cfg: *const config.StatsConfig, theme: *const config.ThemeConfig, data: *const payload.StatsPayload) Error!void {
    if (data.window_days == 0) return error.InvalidSection;
    try heading(w, cfg.header);
    try w.writeAll("<p align=\"center\">\n");
    try badge(w, "Stars", "stars", data.stars, theme.accent);
    try badge(w, "Contributions", "contributions", data.contributions, theme.accent);
    try badge(w, "Active days", "active days", data.active_days, theme.accent);
    try w.print("\n</p>\n\n<p align=\"center\"><sub>Last {d} days · incl. {d} private contributions", .{ data.window_days, data.private_contributions });
    if (data.degraded) try w.writeAll(" | ⚠️ public data only (no PAT)");
    try w.writeAll("</sub></p>");
}

fn badge(w: *Writer, label: []const u8, slug: []const u8, value: u64, color: []const u8) Writer.Error!void {
    try w.print("  <img alt=\"{s}\" src=\"https://img.shields.io/badge/{f}-{d}-{f}?style=for-the-badge\" />", .{ label, query(slug), value, query(color) });
}

pub fn languages(w: *Writer, cfg: *const config.LanguagesConfig, data: []const payload.LanguagePayload) Error!void {
    if (data.len == 0) return error.MissingLanguages;
    if (cfg.icon_height == 0) return error.InvalidSection;
    try heading(w, cfg.header);
    try w.writeAll("<p align=\"center\">\n  ");
    // Top-N selection and normalization belong to language_stats, never here.
    for (data, 0..) |language, index| {
        if (language.name.len == 0 or language.percentage_tenths > 1000) return error.InvalidSection;
        if (index != 0) try w.writeAll("&nbsp;&nbsp;&nbsp;&nbsp;");
        if (iconFor(language.name)) |icon| {
            try w.print("<img src=\"" ++ icon_base ++ "{s}\" height=\"{d}\" alt=\"{f}\" title=\"{f} {d}.{d}%\" />", .{ icon, cfg.icon_height, html(language.name), html(language.name), language.percentage_tenths / 10, language.percentage_tenths % 10 });
        } else try w.print("<sub><b>{f}</b> {d}.{d}%</sub>", .{ html(language.name), language.percentage_tenths / 10, language.percentage_tenths % 10 });
    }
    try w.writeAll("\n</p>");
}

pub fn organization(w: *Writer, cfg: *const config.OrgCardConfig, data: *const payload.OrganizationPayload) Error!void {
    if (data.display_name.len == 0 or data.github_url.len == 0 or data.avatar_url.len == 0) return error.MissingOrganization;
    if (cfg.logo_height == 0) return error.InvalidSection;
    try heading(w, cfg.header);
    try w.print("<p align=\"center\">\n  <a href=\"{f}\"><img src=\"{f}\" width=\"{d}\" alt=\"{f}\" title=\"{f}\" /></a>\n</p>", .{ html(data.github_url), html(data.avatar_url), cfg.logo_height, html(data.display_name), html(data.display_name) });
}

pub fn recentProject(w: *Writer, cfg: *const config.RecentProjectConfig, data: *const payload.RecentProjectSection) Error!void {
    if (data.window_days == 0 or cfg.icon_height == 0) return error.InvalidSection;
    try heading(w, cfg.header);
    try w.writeAll("<p align=\"center\">");
    switch (data.selection) {
        .none => try w.print("<sub>No commits to show in the last {d} days</sub></p>", .{data.window_days}),
        .project => |project| {
            if (project.repository_name.len == 0 or project.github_url.len == 0) return error.InvalidSection;
            const language = project.primary_language orelse "";
            if (iconFor(language)) |icon| {
                try w.print("\n  <a href=\"{f}\"><img src=\"" ++ icon_base ++ "{s}\" height=\"{d}\" alt=\"{f}\" title=\"{f}", .{ html(project.github_url), icon, cfg.icon_height, html(language), html(project.repository_name) });
                if (project.description) |desc| {
                    if (desc.len != 0) try w.print(" — {f}", .{html(desc)});
                }
                try w.print("\" /></a>\n  <br/><b>{f}</b>", .{html(project.repository_name)});
            } else try w.print("\n  <a href=\"{f}\"><b>{f}</b></a>", .{ html(project.github_url), html(project.repository_name) });
            if (project.commit_count != 0) try w.print("\n  <br/><sub>{d} commits {s}</sub>", .{ project.commit_count, @tagName(project.tier) });
            try w.writeAll("\n</p>");
        },
    }
}

pub fn footer(w: *Writer, theme: *const config.ThemeConfig) Writer.Error!void {
    try w.print("<p align=\"center\">\n  <img src=\"https://capsule-render.vercel.app/api?type=waving&amp;color=0:{f},100:{f}&amp;height=120&amp;section=footer&amp;reversal=true\" alt=\"footer\" width=\"100%\" />\n</p>\n", .{ query(theme.base), query(theme.accent) });
}

fn heading(w: *Writer, text: []const u8) Writer.Error!void {
    try w.print("<h3 align=\"center\">{f}</h3>\n\n", .{html(text)});
}

const icon_base = "https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/";
fn iconFor(name: []const u8) ?[]const u8 {
    const map = .{
        .{ "C", "c/c-original.svg" },                            .{ "Python", "python/python-original.svg" },
        .{ "Zig", "zig/zig-original.svg" },                      .{ "TypeScript", "typescript/typescript-original.svg" },
        .{ "JavaScript", "javascript/javascript-original.svg" }, .{ "Kotlin", "kotlin/kotlin-original.svg" },
        .{ "C++", "cplusplus/cplusplus-original.svg" },          .{ "C#", "csharp/csharp-original.svg" },
        .{ "Go", "go/go-original-wordmark.svg" },                .{ "HTML", "html5/html5-original.svg" },
        .{ "CSS", "css3/css3-original.svg" },                    .{ "Shell", "bash/bash-original.svg" },
        .{ "Bash", "bash/bash-original.svg" },                   .{ "Markdown", "markdown/markdown-original.svg" },
    };
    inline for (map) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

fn query(value: []const u8) Query {
    return .{ .value = value };
}
const Query = struct {
    value: []const u8,
    pub fn format(self: Query, w: *Writer) Writer.Error!void {
        const component: std.Uri.Component = .{ .raw = self.value };
        try component.formatEscaped(w);
    }
};
fn html(value: []const u8) Html {
    return .{ .value = value };
}
const Html = struct {
    value: []const u8,
    pub fn format(self: Html, w: *Writer) Writer.Error!void {
        for (self.value) |byte| switch (byte) {
            '&' => try w.writeAll("&amp;"),
            '"' => try w.writeAll("&quot;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(byte),
        };
    }
};

test {
    _ = @import("render_test.zig");
}
