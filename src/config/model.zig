const std = @import("std");

/// A renderable profile section in its configured display order.
pub const Section = enum {
    banner,
    typing,
    stats,
    languages,
    org_card,
    recent_project,
};

/// A supported profile timezone.
pub const Timezone = enum {
    asia_shanghai,

    /// Returns the canonical IANA timezone name used in YAML.
    pub fn name(self: Timezone) []const u8 {
        return switch (self) {
            .asia_shanghai => "Asia/Shanghai",
        };
    }
};

/// Normalized six-digit lowercase theme colors without `#` prefixes.
pub const ThemeConfig = struct {
    base: []const u8,
    accent: []const u8,
    cyan: []const u8,
};

/// Optional organization identity used by organization-aware sections.
pub const OrgConfig = struct {
    login: ?[]const u8,
    repos: ?[]const []const u8,
};

/// Statistics section presentation.
pub const StatsConfig = struct {
    header: []const u8,
};

/// Typing section content and presentation.
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

/// Banner section content and presentation.
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

/// Language section filtering and presentation.
pub const LanguagesConfig = struct {
    header: []const u8,
    top: u32,
    icon_height: u32,
    types: ?[]const []const u8,
};

/// Organization card behavior and presentation.
pub const OrgCardConfig = struct {
    enabled: bool,
    header: []const u8,
    logo_height: u32,
};

/// Recent-project card behavior and presentation.
pub const RecentProjectConfig = struct {
    enabled: bool,
    header: []const u8,
    icon_height: u32,
    exclude_external: bool,
};

/// Validated profile configuration with all generic defaults applied.
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

/// Owns `value` and every string and slice reachable from it.
/// Call `deinit` exactly once when the configuration is no longer needed.
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
