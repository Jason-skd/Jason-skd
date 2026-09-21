const std = @import("std");
const log = @import("log.zig");

const testing = std.testing;

test "log parser preserves file variants and filters exact author and inclusive bounds" {
    const output =
        "\x1ebefore\x001699999999\x00owner@example.test\x00\x00\n1\t0\tbefore.txt\x00" ++
        "\x1estart\x001700000000\x00owner@example.test\x00\x00\n" ++
        "1\t2\tsrc/tab\tand-newline\n.zig\x00" ++
        "-\t-\tassets/image.bin\x00" ++
        "0\t0\t\x00src/old.zig\x00src/new.zig\x00" ++
        "\x1eother\x001700000001\x00other@example.test\x00\x00\n4\t0\tother.txt\x00" ++
        "\x1eend\x001700000002\x00owner@example.test\x00\x00\n1\t0\tend.txt\x00" ++
        "\x1eafter\x001700000003\x00owner@example.test\x00\x00\n1\t0\tafter.txt\x00";
    const authors = [_][]const u8{"owner@example.test"};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const commits = try log.parse(arena.allocator(), output, &authors, 1700000000, 1700000002);

    try testing.expectEqual(@as(usize, 2), commits.len);
    try testing.expectEqualStrings("start", commits[0].id);
    try testing.expectEqualStrings("end", commits[1].id);
    try testing.expectEqual(@as(usize, 3), commits[0].changes.len);
    switch (commits[0].changes[0]) {
        .file => |value| {
            try testing.expectEqualStrings("src/tab\tand-newline\n.zig", value.path);
            try testing.expectEqual(@as(?u64, 1), value.additions);
            try testing.expectEqual(@as(?u64, 2), value.deletions);
        },
        .rename => return error.TestUnexpectedResult,
    }
    switch (commits[0].changes[1]) {
        .file => |value| {
            try testing.expectEqualStrings("assets/image.bin", value.path);
            try testing.expectEqual(@as(?u64, null), value.additions);
            try testing.expectEqual(@as(?u64, null), value.deletions);
        },
        .rename => return error.TestUnexpectedResult,
    }
    switch (commits[0].changes[2]) {
        .rename => |value| {
            try testing.expectEqualStrings("src/old.zig", value.previous_path);
            try testing.expectEqualStrings("src/new.zig", value.path);
        },
        .file => return error.TestUnexpectedResult,
    }
}

test "log parser accepts empty history and rejects malformed records" {
    const authors = [_][]const u8{"owner@example.test"};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try log.parse(
        arena.allocator(),
        "",
        &authors,
        0,
        std.math.maxInt(i64),
    )).len);
    try testing.expectError(error.MalformedGitOutput, log.parse(
        arena.allocator(),
        "\x1ecommit-without-fields",
        &authors,
        0,
        std.math.maxInt(i64),
    ));
    try testing.expectError(error.MalformedGitOutput, log.parse(
        arena.allocator(),
        "\x1ecommit\x001700000000\x00owner@example.test\x00\x00\nnot-numstat\x00",
        &authors,
        0,
        std.math.maxInt(i64),
    ));
    try testing.expectError(error.MalformedGitOutput, log.parse(
        arena.allocator(),
        "\x1ecommit\x001700000000\x00owner@example.test\x00\x00\n-\t1\tmixed.bin\x00",
        &authors,
        0,
        std.math.maxInt(i64),
    ));
}
