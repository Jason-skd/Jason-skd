const std = @import("std");
const generator = @import("profile_generator").language_catalog_generator;
const snapshot = @import("profile_generator").language_catalog_snapshot;

test "vendored snapshot records the fixed upstream source" {
    try std.testing.expectEqualStrings(
        "538da05f034fa5c83bd81df128d144e2088983da",
        snapshot.source_revision,
    );
    try std.testing.expectEqual(@as(usize, 836), snapshot.language_count);
    try std.testing.expectEqual(@as(usize, 1489), snapshot.extension_count);
    try std.testing.expectEqual(@as(usize, 411), snapshot.filename_count);
    try std.testing.expectEqual(snapshot.language_count, snapshot.languages.len);
    try std.testing.expectEqual(snapshot.extension_count, snapshot.extensions.len);
    try std.testing.expectEqual(snapshot.filename_count, snapshot.filenames.len);
}

test "fixture produces language types, filename mappings, and extension mappings" {
    const output = try generator.generate(
        std.testing.allocator,
        @embedFile("fixtures/language_catalog/languages.yml"),
        .{ .source_revision = "fixture" },
    );
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "language_count: usize = 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".h\", .language = \"C\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "build.zig\", .language = \"Zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name = \"Markdown\", .language_type = \"prose\"") != null);
}

test "ambiguous mappings use first declaration deterministically" {
    const input = "C:\n" ++
        "  type: programming\n" ++
        "  extensions:\n" ++
        "    - .h\n" ++
        "C++:\n" ++
        "  type: programming\n" ++
        "  extensions:\n" ++
        "    - .h\n";
    const output = try generator.generate(std.testing.allocator, input, .{ .source_revision = "fixture" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, ".h\", .language = \"C\"") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, output, ".h\", .language = \"C++\""));
}

test "profile overrides win while ordinary conflicts retain sorted first" {
    const input = "C++:\n" ++
        "  type: programming\n" ++
        "  extensions:\n" ++
        "    - .h\n" ++
        "    - .as\n" ++
        "ActionScript:\n" ++
        "  type: programming\n" ++
        "  extensions:\n" ++
        "    - .as\n" ++
        "C:\n" ++
        "  type: programming\n" ++
        "  extensions:\n" ++
        "    - .h\n";
    const output = try generator.generate(std.testing.allocator, input, .{ .source_revision = "fixture" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, ".h\", .language = \"C\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".as\", .language = \"ActionScript\"") != null);
}

test "profile override also applies without a collision" {
    const input = "Markdown:\n  type: prose\nMDX:\n  type: markup\n  extensions:\n  - .mdx\n";
    const output = try generator.generate(std.testing.allocator, input, .{ .source_revision = "fixture" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, ".mdx\", .language = \"Markdown\"") != null);
}

test "generated strings are escaped as Zig literals" {
    const input = "A\\\"Language:\n" ++
        "  type: programming\n" ++
        "  extensions:\n" ++
        "    - .a\n";
    const output = try generator.generate(std.testing.allocator, input, .{ .source_revision = "rev\\\"1" });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "source_revision = \"rev\\\\\\\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name = \"A\\\\\\\"Language\"") != null);
}

test "unsupported nested source shape fails" {
    const input = "Zig:\n  extensions:\n    - .zig\n    nested:\n      - bad\n";
    try std.testing.expectError(error.UnsupportedShape, generator.generate(std.testing.allocator, input, .{ .source_revision = "fixture" }));
}
