const std = @import("std");
const ziez = @import("ziez");

// ---------------------------------------------------------------------------
// parseCookies
// ---------------------------------------------------------------------------

test "parseCookies: basic parsing" {
    const cookies = ziez.parseCookies("session=abc123; user=john");
    try std.testing.expectEqual(@as(usize, 2), cookies.len);
    try std.testing.expectEqualStrings("abc123", cookies.get("session").?);
    try std.testing.expectEqualStrings("john", cookies.get("user").?);
}

test "parseCookies: empty string" {
    const cookies = ziez.parseCookies("");
    try std.testing.expectEqual(@as(usize, 0), cookies.len);
}

test "parseCookies: single cookie" {
    const cookies = ziez.parseCookies("token=abc");
    try std.testing.expectEqual(@as(usize, 1), cookies.len);
    try std.testing.expectEqualStrings("abc", cookies.get("token").?);
}

test "parseCookies: trims whitespace" {
    const cookies = ziez.parseCookies("  a = 1 ; b=2 ");
    try std.testing.expectEqualStrings("1", cookies.get("a").?);
    try std.testing.expectEqualStrings("2", cookies.get("b").?);
}

test "parseCookies: empty value" {
    const cookies = ziez.parseCookies("a=; b=2");
    try std.testing.expectEqualStrings("", cookies.get("a").?);
    try std.testing.expectEqualStrings("2", cookies.get("b").?);
}

test "parseCookies: missing key skipped" {
    const cookies = ziez.parseCookies("=novalue; b=2");
    try std.testing.expectEqual(@as(usize, 1), cookies.len);
    try std.testing.expectEqualStrings("2", cookies.get("b").?);
}

test "parseCookies: no equal sign" {
    const cookies = ziez.parseCookies("flag; b=2");
    try std.testing.expectEqualStrings("", cookies.get("flag").?);
    try std.testing.expectEqualStrings("2", cookies.get("b").?);
}

test "parseCookies: returns null for missing key" {
    const cookies = ziez.parseCookies("a=1");
    try std.testing.expect(cookies.get("nonexistent") == null);
}

// ---------------------------------------------------------------------------
// formatSetCookie
// ---------------------------------------------------------------------------

test "formatSetCookie: minimal" {
    var buf: [512]u8 = undefined;
    const result = ziez.formatSetCookie(&buf, "token", "abc123", .{}).?;
    try std.testing.expectEqualStrings("token=abc123", result);
}

test "formatSetCookie: with Max-Age" {
    var buf: [512]u8 = undefined;
    const result = ziez.formatSetCookie(&buf, "session", "xyz", .{ .max_age = 3600 }).?;
    try std.testing.expect(std.mem.indexOf(u8, result, "Max-Age=3600") != null);
    try std.testing.expect(std.mem.startsWith(u8, result, "session=xyz"));
}

test "formatSetCookie: with Path" {
    var buf: [512]u8 = undefined;
    const result = ziez.formatSetCookie(&buf, "id", "1", .{ .path = "/auth" }).?;
    try std.testing.expect(std.mem.indexOf(u8, result, "Path=/auth") != null);
}

test "formatSetCookie: HttpOnly and Secure" {
    var buf: [512]u8 = undefined;
    const result = ziez.formatSetCookie(&buf, "rt", "tok", .{
        .http_only = true,
        .secure = true,
    }).?;
    try std.testing.expect(std.mem.indexOf(u8, result, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Secure") != null);
}

test "formatSetCookie: SameSite strict" {
    var buf: [512]u8 = undefined;
    const result = ziez.formatSetCookie(&buf, "c", "v", .{ .same_site = .strict }).?;
    try std.testing.expect(std.mem.indexOf(u8, result, "SameSite=Strict") != null);
}

test "formatSetCookie: SameSite none" {
    var buf: [512]u8 = undefined;
    const result = ziez.formatSetCookie(&buf, "c", "v", .{ .same_site = .none }).?;
    try std.testing.expect(std.mem.indexOf(u8, result, "SameSite=None") != null);
}

test "formatSetCookie: all options" {
    var buf: [512]u8 = undefined;
    const result = ziez.formatSetCookie(&buf, "refresh_token", "tok123", .{
        .max_age = 86400,
        .path = "/auth",
        .http_only = true,
        .secure = true,
        .same_site = .strict,
    }).?;
    try std.testing.expect(std.mem.startsWith(u8, result, "refresh_token=tok123"));
    try std.testing.expect(std.mem.indexOf(u8, result, "Max-Age=86400") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Path=/auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Secure") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "SameSite=Strict") != null);
}

test "formatSetCookie: Partitioned" {
    var buf: [512]u8 = undefined;
    const result = ziez.formatSetCookie(&buf, "c", "v", .{
        .secure = true,
        .partitioned = true,
    }).?;
    try std.testing.expect(std.mem.indexOf(u8, result, "Partitioned") != null);
}

test "formatSetCookie: with Domain" {
    var buf: [512]u8 = undefined;
    const result = ziez.formatSetCookie(&buf, "c", "v", .{ .domain = "example.com" }).?;
    try std.testing.expect(std.mem.indexOf(u8, result, "Domain=example.com") != null);
}

// ---------------------------------------------------------------------------
// signCookie / verifySignedCookie
// ---------------------------------------------------------------------------

test "signCookie: produces value.signature format" {
    const allocator = std.testing.allocator;
    const signed = try ziez.signCookie(allocator, "abc123", "secret");
    defer allocator.free(signed);

    // Should contain a dot separator
    const dot = std.mem.indexOfScalar(u8, signed, '.');
    try std.testing.expect(dot != null);
    // Value before dot should be original
    try std.testing.expectEqualStrings("abc123", signed[0..dot.?]);
    // Signature after dot should be 64 hex chars (SHA256 = 32 bytes * 2)
    try std.testing.expectEqual(@as(usize, 64), signed[dot.? + 1 ..].len);
}

test "signCookie: verify round-trip" {
    const allocator = std.testing.allocator;
    const signed = try ziez.signCookie(allocator, "session_value", "mysecret");
    defer allocator.free(signed);

    const verified = ziez.verifySignedCookie(allocator, signed, "mysecret");
    try std.testing.expect(verified != null);
    defer allocator.free(verified.?);
    try std.testing.expectEqualStrings("session_value", verified.?);
}

test "verifySignedCookie: tampered value returns null" {
    const allocator = std.testing.allocator;
    const signed = try ziez.signCookie(allocator, "good_value", "secret");
    defer allocator.free(signed);

    // Tamper with the value part
    var tampered = try allocator.dupe(u8, signed);
    defer allocator.free(tampered);
    tampered[0] = 'X';

    const result = ziez.verifySignedCookie(allocator, tampered, "secret");
    try std.testing.expect(result == null);
}

test "verifySignedCookie: wrong secret returns null" {
    const allocator = std.testing.allocator;
    const signed = try ziez.signCookie(allocator, "value", "secret1");
    defer allocator.free(signed);

    const result = ziez.verifySignedCookie(allocator, signed, "secret2");
    try std.testing.expect(result == null);
}

test "verifySignedCookie: no dot returns null" {
    const allocator = std.testing.allocator;
    const result = ziez.verifySignedCookie(allocator, "nodotvalue", "secret");
    try std.testing.expect(result == null);
}

test "verifySignedCookie: invalid signature length returns null" {
    const allocator = std.testing.allocator;
    const result = ziez.verifySignedCookie(allocator, "value.abc", "secret");
    try std.testing.expect(result == null);
}

// ---------------------------------------------------------------------------
// Request.cookie (lazy parsing integration)
// ---------------------------------------------------------------------------

test "Request.cookie: lazy parsing" {
    const allocator = std.testing.allocator;
    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = allocator,
        .head_buffer = "GET /test HTTP/1.1\r\nCookie: session=abc123; user=john\r\n\r\n",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };

    try std.testing.expect(!req.cookies_parsed);
    const val = req.cookie("session");
    try std.testing.expect(req.cookies_parsed);
    try std.testing.expectEqualStrings("abc123", val.?);
    try std.testing.expectEqualStrings("john", req.cookie("user").?);
    try std.testing.expect(req.cookie("nonexistent") == null);
}

test "Request.cookie: no cookie header" {
    const allocator = std.testing.allocator;
    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = allocator,
        .head_buffer = "GET /test HTTP/1.1\r\n\r\n",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };

    try std.testing.expect(req.cookie("anything") == null);
    try std.testing.expect(req.cookies_parsed);
}
