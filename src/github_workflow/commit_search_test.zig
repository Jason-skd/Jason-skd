const std = @import("std");
const github = @import("../github.zig");
const search = @import("commit_search.zig");

const Fake = struct {
    bodies: []const []const u8,
    calls: usize = 0,
    saw_second_page: bool = false,
    saw_split: bool = false,

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: github.Request) anyerror!github.RawResponse {
        const self: *@This() = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(std.http.Method.GET, request.method);
        try std.testing.expect(std.mem.find(u8, request.url, "author%3Atarget") != null);
        if (std.mem.find(u8, request.url, "page=2") != null) self.saw_second_page = true;
        if (std.mem.find(u8, request.url, "1970-01-01..1970-01-01") != null) self.saw_split = true;
        const body = self.bodies[@min(self.calls, self.bodies.len - 1)];
        self.calls += 1;
        return github.RawResponse.init(allocator, .ok, &.{}, body);
    }
};

fn client(fake: *Fake) !github.Client {
    return github.Client.initWithTransport(std.testing.allocator, std.Io.failing, .{ .context = fake, .send_fn = Fake.send }, .{ .token = "test", .user_agent = "test", .retry = .{ .max_attempts = 1 } });
}

const organization = "{\"repository\":{\"full_name\":\"SCNUAutoPtr/go-ce-v4\",\"private\":false,\"owner\":{\"login\":\"SCNUAutoPtr\"}}}";
const first = "{\"total_count\":1,\"incomplete_results\":false,\"items\":[" ++ organization ++ "]}";
const hundred = blk: {
    var body: []const u8 = "{\"total_count\":101,\"incomplete_results\":false,\"items\":[";
    for (0..100) |index| body = body ++ (if (index == 0) "" else ",") ++ organization;
    break :blk body ++ "]}";
};
const second = "{\"total_count\":101,\"incomplete_results\":false,\"items\":[" ++ organization ++ "]}";

test "paginates and deduplicates search results" {
    var fake = Fake{ .bodies = &.{ hundred, second } };
    var api = try client(&fake);
    defer api.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try search.discover(&api, arena.allocator(), "target", 0, 0);
    try std.testing.expect(result == .success);
    try std.testing.expect(fake.saw_second_page);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), result.success.len);
}

test "discovers organization repository omitted by contribution calendar" {
    var fake = Fake{ .bodies = &.{first} };
    var api = try client(&fake);
    defer api.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try search.discover(&api, arena.allocator(), "target", 0, 0);
    try std.testing.expect(result == .success);
    try std.testing.expectEqual(@as(usize, 1), result.success.len);
    try std.testing.expectEqualStrings("SCNUAutoPtr/go-ce-v4", result.success[0].name_with_owner);
}

test "incomplete search splits date range" {
    const overflow = "{\"total_count\":1001,\"incomplete_results\":false,\"items\":[]}";
    const empty = "{\"total_count\":0,\"incomplete_results\":false,\"items\":[]}";
    var fake = Fake{ .bodies = &.{ overflow, first, empty } };
    var api = try client(&fake);
    defer api.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try search.discover(&api, arena.allocator(), "target", 0, 86400);
    try std.testing.expect(result == .success);
    try std.testing.expect(fake.saw_split);
    try std.testing.expectEqual(@as(usize, 1), result.success.len);
}

test "one-day overflow fails explicitly" {
    const overflow = "{\"total_count\":1001,\"incomplete_results\":false,\"items\":[]}";
    var fake = Fake{ .bodies = &.{overflow} };
    var api = try client(&fake);
    defer api.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try search.discover(&api, arena.allocator(), "target", 0, 0);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(@import("model.zig").InvalidResponse.commit_search_incomplete, result.failure.cause.invalid_response);
}
