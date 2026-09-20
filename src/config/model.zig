const std = @import("std");

pub const Section = enum {
    banner,
    typing,
    stats,
    languages,
    org_card,
    recent_project,
};

pub const Timezone = enum {
    asia_shanghai,

    pub fn name(self: Timezone) []const u8 {
        return switch (self) {
            .asia_shanghai => "Asia/Shanghai",
        };
    }
};

pub const ThemeConfig = struct {
    base: []const u8,
    accent: []const u8,
    cyan: []const u8,
};

pub const OrgConfig = struct {
    login: ?[]const u8,
    repos: ?[]const []const u8,
};

pub const StatsConfig = struct {
    header: []const u8,
};

pub const TypingConfig = struct {
    lines: ?[]const []const u8,
    font: []const u8,
    size: u32,
    width: u32,
    height: ?u32,
    duration: ?u32,
    pause: ?u32,
    background: ?[]const u8,
};

pub const BannerConfig = struct {
    height: u32,
    instance: ?[]const u8,
    text: ?[]const u8,
    desc: ?[]const u8,
    font_size: ?u32,
    font_align: ?u32,
    desc_size: ?u32,
    desc_align: ?u32,
};

pub const LanguagesConfig = struct {
    header: []const u8,
    top: u32,
    icon_height: u32,
    types: ?[]const []const u8,
};

pub const OrgCardConfig = struct {
    enabled: bool,
    header: []const u8,
    logo_height: u32,
};

pub const RecentProjectConfig = struct {
    enabled: bool,
    header: []const u8,
    icon_height: u32,
    exclude_external: bool,
};

pub const Config = struct {
    login: []const u8,
    timezone: Timezone,
    theme: ThemeConfig,
    author_emails: []const []const u8,
    org: OrgConfig,
    window_days: u32,
    include_external: bool,
    sections: []const Section,
    stats: StatsConfig,
    typing: TypingConfig,
    banner: BannerConfig,
    languages: LanguagesConfig,
    org_card: OrgCardConfig,
    recent_project: RecentProjectConfig,
};

pub const ParsedConfig = struct {
    arena: *std.heap.ArenaAllocator,
    value: Config,

    /// Releases both the arena-owned config data and the arena object.
    pub fn deinit(self: ParsedConfig) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};
