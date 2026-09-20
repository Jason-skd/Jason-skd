const std = @import("std");

/// Parses typed JSON into owned memory while tolerating unknown fields.
pub fn parse(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, input, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = true,
    });
}

test "unknown fields are ignored while required fields and types remain strict" {
    const Payload = struct {
        name: []const u8,
        count: u32,
    };

    var parsed = try parse(
        Payload,
        std.testing.allocator,
        "{\"name\":\"profile\",\"count\":3,\"future\":true}",
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("profile", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.count);
    try std.testing.expectError(
        error.MissingField,
        parse(Payload, std.testing.allocator, "{\"name\":\"profile\"}"),
    );
    try std.testing.expectError(
        error.InvalidCharacter,
        parse(Payload, std.testing.allocator, "{\"name\":\"profile\",\"count\":\"three\"}"),
    );
}

test "nullable fields require optional types and remain required without a default" {
    const Nullable = struct { description: ?[]const u8 };
    const Required = struct { description: []const u8 };

    var parsed = try parse(
        Nullable,
        std.testing.allocator,
        "{\"description\":null}",
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.description);

    try std.testing.expectError(
        error.UnexpectedToken,
        parse(Required, std.testing.allocator, "{\"description\":null}"),
    );
    try std.testing.expectError(
        error.MissingField,
        parse(Nullable, std.testing.allocator, "{}"),
    );
}

test "duplicate fields retain the standard library error behavior" {
    const Payload = struct { value: u8 };
    try std.testing.expectError(
        error.DuplicateField,
        parse(Payload, std.testing.allocator, "{\"value\":1,\"value\":2}"),
    );
}

test "parsed strings do not borrow the response buffer" {
    const Payload = struct { name: []const u8 };
    const input = try std.testing.allocator.dupe(u8, "{\"name\":\"profile\"}");

    var parsed = try parse(Payload, std.testing.allocator, input);
    std.testing.allocator.free(input);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("profile", parsed.value.name);
}
