pub const RawTheme = struct {
    base: ?[]const u8,
    accent: ?[]const u8,
    cyan: ?[]const u8,
    _present: ?bool,
};

pub const RawOrg = struct {
    login: ?[]const u8,
    repos: ?[][]const u8,
    _present: ?bool,
};

pub const RawStats = struct {
    header: ?[]const u8,
    _present: ?bool,
};

pub const RawTyping = struct {
    lines: ?[][]const u8,
    font: ?[]const u8,
    size: ?[]const u8,
    width: ?[]const u8,
    height: ?[]const u8,
    duration: ?[]const u8,
    pause: ?[]const u8,
    background: ?[]const u8,
    _present: ?bool,
};

pub const RawBanner = struct {
    height: ?[]const u8,
    instance: ?[]const u8,
    text: ?[]const u8,
    desc: ?[]const u8,
    font_size: ?[]const u8,
    font_align: ?[]const u8,
    desc_size: ?[]const u8,
    desc_align: ?[]const u8,
    _present: ?bool,
};

pub const RawLanguages = struct {
    header: ?[]const u8,
    top: ?[]const u8,
    icon_height: ?[]const u8,
    types: ?[][]const u8,
    _present: ?bool,
};

pub const RawOrgCard = struct {
    enabled: ?bool,
    header: ?[]const u8,
    logo_height: ?[]const u8,
    _present: ?bool,
};

pub const RawRecentProject = struct {
    enabled: ?bool,
    header: ?[]const u8,
    icon_height: ?[]const u8,
    exclude_external: ?bool,
    _present: ?bool,
};

/// All fields are optional so ymlz cannot expose an uninitialized omission.
/// Nested mappings are synthesized by schema.zig when they are absent.
pub const RawConfig = struct {
    login: ?[]const u8,
    timezone: ?[]const u8,
    theme: RawTheme,
    author_emails: ?[][]const u8,
    org: RawOrg,
    window_days: ?[]const u8,
    include_external: ?bool,
    sections: ?[][]const u8,
    stats: RawStats,
    typing: RawTyping,
    banner: RawBanner,
    languages: RawLanguages,
    org_card: RawOrgCard,
    recent_project: RawRecentProject,
};
