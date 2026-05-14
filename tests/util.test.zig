const std = @import("std");
const ziez = @import("ziez");

test "matchRoute - exact match" {
    const r = ziez.matchRoute("/", "/");
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(usize, 0), r.?.len);
}

test "matchRoute - exact match with path" {
    const r = ziez.matchRoute("/users", "/users");
    try std.testing.expect(r != null);
}

test "matchRoute - no match" {
    const r = ziez.matchRoute("/users", "/posts");
    try std.testing.expect(r == null);
}

test "matchRoute - param" {
    const r = ziez.matchRoute("/users/:id", "/users/42");
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("42", r.?.get("id").?);
}

test "matchRoute - multiple params" {
    const r = ziez.matchRoute("/users/:userId/posts/:postId", "/users/1/posts/99");
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("1", r.?.get("userId").?);
    try std.testing.expectEqualStrings("99", r.?.get("postId").?);
}

test "matchRoute - wildcard" {
    const r = ziez.matchRoute("/assets/*", "/assets/css/style.css");
    try std.testing.expect(r != null);
}

test "parseQuery" {
    const q = ziez.parseQuery("name=foo&age=30");
    try std.testing.expectEqualStrings("foo", q.get("name").?);
    try std.testing.expectEqualStrings("30", q.get("age").?);
}

test "parseQuery - empty" {
    const q = ziez.parseQuery("");
    try std.testing.expectEqual(@as(usize, 0), q.len);
}

test "splitPathQuery" {
    const r = ziez.splitPathQuery("/users?id=1");
    try std.testing.expectEqualStrings("/users", r.path);
    try std.testing.expectEqualStrings("id=1", r.query);
}

test "splitPathQuery - no query" {
    const r = ziez.splitPathQuery("/users");
    try std.testing.expectEqualStrings("/users", r.path);
    try std.testing.expectEqualStrings("", r.query);
}

test "parseForm" {
    const f = ziez.parseForm("name=foo&email=test%40test.com");
    try std.testing.expectEqualStrings("foo", f.get("name").?);
    try std.testing.expectEqualStrings("test%40test.com", f.get("email").?);
}

test "percentDecode" {
    const decoded = try ziez.percentDecode(std.testing.allocator, "hello%20world%21");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world!", decoded);
}

test "percentDecode - plus sign" {
    const decoded = try ziez.percentDecode(std.testing.allocator, "name+value");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("name value", decoded);
}
