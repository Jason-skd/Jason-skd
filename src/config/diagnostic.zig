/// Structured details for an invalid profile configuration.
pub const Diagnostic = struct {
    /// Stable category for the reported configuration failure.
    pub const Code = enum {
        none,
        invalid_yaml,
        unknown_field,
        unsupported_field,
        duplicate_field,
        missing_field,
        invalid_type,
        invalid_value,
        unknown_section,
        duplicate_section,
    };

    code: Code = .none,
    line: usize = 0,
    path: []const u8 = "",
    message: []const u8 = "",
    /// May borrow the YAML input supplied to `config.parse`.
    offending_text: ?[]const u8 = null,
};

pub fn invalid(
    diagnostic: *Diagnostic,
    code: Diagnostic.Code,
    line: usize,
    path: []const u8,
    offending_text: ?[]const u8,
    message: []const u8,
) error{InvalidConfig} {
    diagnostic.* = .{
        .code = code,
        .line = line,
        .path = path,
        .message = message,
        .offending_text = offending_text,
    };
    return error.InvalidConfig;
}
