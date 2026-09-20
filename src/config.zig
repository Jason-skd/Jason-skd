//! Typed profile configuration parsing, validation, and owned results.

const diagnostic_module = @import("config/diagnostic.zig");
const model = @import("config/model.zig");
const parser = @import("config/parser.zig");

pub const Diagnostic = diagnostic_module.Diagnostic;
pub const Section = model.Section;
pub const Timezone = model.Timezone;
pub const ThemeConfig = model.ThemeConfig;
pub const OrgConfig = model.OrgConfig;
pub const StatsConfig = model.StatsConfig;
pub const TypingConfig = model.TypingConfig;
pub const BannerConfig = model.BannerConfig;
pub const LanguagesConfig = model.LanguagesConfig;
pub const OrgCardConfig = model.OrgCardConfig;
pub const RecentProjectConfig = model.RecentProjectConfig;
pub const Config = model.Config;
pub const ParsedConfig = model.ParsedConfig;
pub const parse = parser.parse;

test {
    _ = @import("config/tests.zig");
}
