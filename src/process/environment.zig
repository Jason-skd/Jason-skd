const std = @import("std");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const security = @import("secure_allocator.zig");

/// A borrowed environment-variable name and value to set for the child process.
pub const Override = struct {
    /// Environment-variable name; it must satisfy `Environ.Map.validateKeyForPut`.
    name: []const u8,
    /// Environment-variable value; it must not contain a NUL byte.
    value: []const u8,
};

/// Input errors reported before environment values are copied or a child is spawned.
pub const ValidationError = error{
    InvalidEnvironmentName,
    EnvironmentValueContainsNul,
};

/// Validates borrowed overrides without taking ownership or allocating memory.
pub fn validateOverrides(overrides: []const Override) ValidationError!void {
    for (overrides) |override| {
        if (!Environ.Map.validateKeyForPut(override.name))
            return error.InvalidEnvironmentName;
        if (std.mem.findScalar(u8, override.value, 0) != null)
            return error.EnvironmentValueContainsNul;
    }
}

/// Returns an independently owned copy of `source` allocated by `gpa`.
///
/// On failure, every value copied so far is cleared before its storage is freed.
pub fn clone(gpa: Allocator, source: *const Environ.Map) Allocator.Error!Environ.Map {
    var destination: Environ.Map = .init(gpa);
    errdefer deinit(&destination);

    for (source.keys(), source.values()) |name, value| {
        const name_copy = try gpa.dupe(u8, name);
        errdefer gpa.free(name_copy);
        const value_copy = try gpa.dupe(u8, value);
        errdefer security.secureFree(gpa, value_copy);

        try destination.putMove(name_copy, value_copy);
    }
    return destination;
}

/// Copies overrides into an owned environment, with later duplicate names winning.
///
/// Replaced values are cleared before `Environ.Map` releases their storage.
pub fn applyOverrides(
    environ: *Environ.Map,
    overrides: []const Override,
) Allocator.Error!void {
    const gpa = environ.allocator;
    for (overrides) |override| {
        const name_copy = try gpa.dupe(u8, override.name);
        errdefer gpa.free(name_copy);
        const value_copy = try gpa.dupe(u8, override.value);
        errdefer security.secureFree(gpa, value_copy);

        if (environ.getPtr(override.name)) |old_value|
            std.crypto.secureZero(u8, @constCast(old_value.*));
        try environ.putMove(name_copy, value_copy);
    }
}

/// Clears all owned values and then destroys the environment map.
pub fn deinit(environ: *Environ.Map) void {
    for (environ.values()) |value|
        std.crypto.secureZero(u8, @constCast(value));
    environ.deinit();
}
