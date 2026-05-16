const std = @import("std");
const testing = std.testing;
const ziez = @import("ziez");

var observed_param: []const u8 = "";
var observed_body_name: []const u8 = "";
var observed_form_field: []const u8 = "";
var observed_cookie: ?[]const u8 = null;
var observed_header: ?[]const u8 = null;
var observed_session: ?[]const u8 = null;
var observed_theme: ?[]const u8 = null;

fn reset() void {
    observed_param = "";
    observed_body_name = "";
    observed_form_field = "";
    observed_cookie = null;
    observed_header = null;
}

fn makeRequest(method: ziez.HttpMethod, path: []const u8, head_buffer: []const u8) ziez.Request {
    return .{
        .method = method,
        .path = path,
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = testing.allocator,
        .head_buffer = head_buffer,
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
}

test "RequestFeatures: route param extracted in dispatch context" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/users/:id", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            observed_param = req.param("id") orelse "";
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/users/abc123", "GET /users/abc123 HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("abc123", observed_param);
}

test "RequestFeatures: JSON body parsed correctly in dispatch" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.post("/users", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            const Body = struct { name: []const u8 };
            const b = req.body_json(Body) orelse return error.BadRequest;
            observed_body_name = b.name;
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.POST, "/users", "POST /users HTTP/1.1\r\ncontent-type: application/json\r\n\r\n");
    req.body_raw = "{\"name\":\"Bob\"}";
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("Bob", observed_body_name);
}

test "RequestFeatures: missing JSON body returns null (not crash)" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.post("/data", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            const Body = struct { x: i64 };
            if (req.body_json(Body) == null) {
                return ziez.throw(error.BadRequest, "body required", res);
            }
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.POST, "/data", "POST /data HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 400), res.status_code);
    try testing.expectEqualStrings("body required", res.error_message.?);
}

test "RequestFeatures: form body parsed correctly" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.post("/contact", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            const form = req.body_form();
            observed_form_field = form.get("email") orelse "";
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.POST, "/contact", "POST /contact HTTP/1.1\r\ncontent-type: application/x-www-form-urlencoded\r\n\r\n");
    req.body_raw = "name=Alice&email=alice-at-example";
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("alice-at-example", observed_form_field);
}

test "RequestFeatures: req.cookie() reads from Cookie header" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/profile", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            observed_cookie = req.cookie("session");
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/profile", "GET /profile HTTP/1.1\r\nCookie: session=tok123; theme=dark\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(observed_cookie != null);
    try testing.expectEqualStrings("tok123", observed_cookie.?);
}

test "RequestFeatures: req.cookie() returns null for missing cookie" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/profile", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            if (req.cookie("session") == null) {
                return ziez.throw(error.Unauthorized, "no session cookie", res);
            }
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/profile", "GET /profile HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 401), res.status_code);
}

test "RequestFeatures: multiple cookies parsed from single header" {
    observed_session = null;
    observed_theme = null;
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();

    router.get("/prefs", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            observed_session = req.cookie("session");
            observed_theme = req.cookie("theme");
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/prefs", "GET /prefs HTTP/1.1\r\nCookie: session=abc; theme=dark; lang=en\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqualStrings("abc", observed_session.?);
    try testing.expectEqualStrings("dark", observed_theme.?);
}

test "RequestFeatures: req.header() reads custom request header" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/api", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            observed_header = req.header("x-api-key");
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/api", "GET /api HTTP/1.1\r\nX-Api-Key: my-secret-key\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(observed_header != null);
    try testing.expectEqualStrings("my-secret-key", observed_header.?);
}

test "RequestFeatures: signed cookie round-trip verify" {
    const secret = "my-test-secret-key-that-is-long-enough";
    const value = "user:admin";

    const signed = try ziez.signCookie(testing.allocator, value, secret);
    defer testing.allocator.free(signed);

    var cookie_header_buf: [256]u8 = undefined;
    const cookie_header = try std.fmt.bufPrint(
        &cookie_header_buf,
        "GET /me HTTP/1.1\r\nCookie: session={s}\r\n\r\n",
        .{signed},
    );

    var req = makeRequest(.GET, "/me", cookie_header);
    const verified = req.signedCookie("session", secret);
    defer if (verified) |v| testing.allocator.free(v);

    try testing.expect(verified != null);
    try testing.expectEqualStrings(value, verified.?);
}

test "RequestFeatures: tampered signed cookie returns null" {
    var req = makeRequest(.GET, "/me", "GET /me HTTP/1.1\r\nCookie: session=tampered.invalidsig\r\n\r\n");
    const verified = req.signedCookie("session", "some-secret");
    defer if (verified) |v| testing.allocator.free(v);

    try testing.expect(verified == null);
}
