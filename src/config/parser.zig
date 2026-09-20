const std = @import("std");
const Ymlz = @import("ymlz").Ymlz;
const diagnostic_module = @import("diagnostic.zig");
const model = @import("model.zig");
const normalize_module = @import("normalize.zig");
const raw_model = @import("raw.zig");
const schema = @import("schema.zig");

const Diagnostic = diagnostic_module.Diagnostic;
const ParsedConfig = model.ParsedConfig;

/// Parses, normalizes, and validates a profile YAML document.
///
/// Successful results do not borrow `yaml`. `Diagnostic.offending_text` may
/// borrow `yaml` after `InvalidConfig`, so the caller must keep the input alive
/// while inspecting the diagnostic.
pub fn parse(
    allocator: std.mem.Allocator,
    yaml: []const u8,
    diagnostic: *Diagnostic,
) (std.mem.Allocator.Error || error{InvalidConfig})!ParsedConfig {
    diagnostic.* = .{};

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    // Validation and ymlz binding are temporary; normalization makes an independent result.
    const prepared_yaml = try schema.preflight(scratch.allocator(), yaml, diagnostic);
    var reader = schema.SchemaReader{ .yaml = prepared_yaml };
    var binder = try Ymlz(raw_model.RawConfig).init(scratch.allocator());
    const raw_config = binder.loadReader(&reader) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnostic.* = .{
                .code = .invalid_yaml,
                .message = "YAML value could not be bound to the profile schema",
            };
            return error.InvalidConfig;
        },
    };

    // The returned config has a separate arena whose lifetime belongs to the caller.
    var result = try initParsedConfig(allocator);
    errdefer result.deinit();
    result.value = try normalize_module.normalize(result.arena.allocator(), raw_config);
    return result;
}

fn initParsedConfig(allocator: std.mem.Allocator) std.mem.Allocator.Error!ParsedConfig {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return .{ .arena = arena, .value = undefined };
}
