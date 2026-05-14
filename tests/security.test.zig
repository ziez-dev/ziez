const std = @import("std");
const ziez = @import("ziez");

var handler_called = false;
var saw_security_header = false;
var observed_query: ?[]const u8 = null;
var observed_body: ?[]const u8 = null;

fn resetState() void {
    handler_called = false;
    saw_security_header = false;
    observed_query = null;
    observed_body = null;
}

fn responseHeader(res: *const ziez.Response, name: []const u8) ?[]const u8 {
    for (0..res.headers_len) |i| {
        if (std.ascii.eqlIgnoreCase(res.headers[i].name, name)) {
            return res.headers[i].value;
        }
    }
    return null;
}

fn makeRequest(method: ziez.HttpMethod, path: []const u8, head_buffer: []const u8) ziez.Request {
    return .{
        .method = method,
        .path = path,
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = std.testing.allocator,
        .head_buffer = head_buffer,
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
}

const okHandler: ziez.HandlerFn = struct {
    fn handler(_: *ziez.Request, res: *ziez.Response) anyerror!void {
        handler_called = true;
        saw_security_header = responseHeader(res, "Content-Security-Policy") != null;
        res.status(200).send("ok");
    }
}.handler;

const errorHandler: ziez.HandlerFn = struct {
    fn handler(_: *ziez.Request, _: *ziez.Response) anyerror!void {
        return error.BadRequest;
    }
}.handler;

const queryHandler: ziez.HandlerFn = struct {
    fn handler(req: *ziez.Request, res: *ziez.Response) anyerror!void {
        handler_called = true;
        observed_query = req.query_get("q");
        res.status(200).send("ok");
    }
}.handler;

const bodyHandler: ziez.HandlerFn = struct {
    fn handler(req: *ziez.Request, res: *ziez.Response) anyerror!void {
        handler_called = true;
        observed_body = req.body_raw_bytes();
        res.status(200).send("ok");
    }
}.handler;

test "Security: Helmet defaults are on for successful routes" {
    resetState();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.get("/ok", okHandler);

    var req = makeRequest(.GET, "/ok", "GET /ok HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(handler_called);
    try std.testing.expect(saw_security_header);
    try std.testing.expectEqualStrings("default-src 'self';base-uri 'self';font-src 'self' https: data:;form-action 'self';frame-ancestors 'self';img-src 'self' data:;object-src 'none';script-src 'self';script-src-attr 'none';style-src 'self' https: 'unsafe-inline';upgrade-insecure-requests", responseHeader(&res, "Content-Security-Policy").?);
    try std.testing.expectEqualStrings("same-origin", responseHeader(&res, "Cross-Origin-Opener-Policy").?);
    try std.testing.expectEqualStrings("same-origin", responseHeader(&res, "Cross-Origin-Resource-Policy").?);
    try std.testing.expectEqualStrings("?1", responseHeader(&res, "Origin-Agent-Cluster").?);
    try std.testing.expectEqualStrings("no-referrer", responseHeader(&res, "Referrer-Policy").?);
    try std.testing.expectEqualStrings("max-age=31536000; includeSubDomains", responseHeader(&res, "Strict-Transport-Security").?);
    try std.testing.expectEqualStrings("nosniff", responseHeader(&res, "X-Content-Type-Options").?);
    try std.testing.expectEqualStrings("off", responseHeader(&res, "X-DNS-Prefetch-Control").?);
    try std.testing.expectEqualStrings("noopen", responseHeader(&res, "X-Download-Options").?);
    try std.testing.expectEqualStrings("SAMEORIGIN", responseHeader(&res, "X-Frame-Options").?);
    try std.testing.expectEqualStrings("none", responseHeader(&res, "X-Permitted-Cross-Domain-Policies").?);
    try std.testing.expectEqualStrings("0", responseHeader(&res, "X-XSS-Protection").?);
}

test "Security: Helmet defaults are present on 404 and error responses" {
    var not_found_router = ziez.Router.init(std.testing.allocator);
    defer not_found_router.deinit();

    var not_found_req = makeRequest(.GET, "/missing", "GET /missing HTTP/1.1\r\n\r\n");
    var not_found_res = ziez.Response.init(std.testing.allocator);
    not_found_router.handle(&not_found_req, &not_found_res);

    try std.testing.expectEqual(@as(u16, 404), not_found_res.status_code);
    try std.testing.expect(responseHeader(&not_found_res, "Content-Security-Policy") != null);

    var error_router = ziez.Router.init(std.testing.allocator);
    defer error_router.deinit();
    error_router.get("/err", errorHandler);

    var error_req = makeRequest(.GET, "/err", "GET /err HTTP/1.1\r\n\r\n");
    var error_res = ziez.Response.init(std.testing.allocator);
    error_router.handle(&error_req, &error_res);

    try std.testing.expectEqual(@as(u16, 400), error_res.status_code);
    try std.testing.expect(responseHeader(&error_res, "Content-Security-Policy") != null);
}

test "Security: Helmet can be disabled" {
    resetState();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useSecurity(.{ .helmet = null });
    router.get("/ok", okHandler);

    var req = makeRequest(.GET, "/ok", "GET /ok HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(handler_called);
    try std.testing.expect(!saw_security_header);
    try std.testing.expect(responseHeader(&res, "Content-Security-Policy") == null);
    try std.testing.expect(responseHeader(&res, "X-Frame-Options") == null);
}

test "Security: Helmet partial override merges with defaults" {
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useSecurity(.{
        .helmet = .{
            .x_frame_options = "DENY",
            .strict_transport_security = .{
                .max_age = 63_072_000,
                .include_sub_domains = true,
                .preload = true,
            },
            .content_security_policy = .{
                .directives = &.{
                    .{ .name = "script-src", .values = &.{ "'self'", "cdn.jsdelivr.net" } },
                    .{ .name = "style-src", .values = null },
                },
            },
        },
    });
    router.get("/ok", okHandler);

    var req = makeRequest(.GET, "/ok", "GET /ok HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    const csp = responseHeader(&res, "Content-Security-Policy").?;
    try std.testing.expect(std.mem.indexOf(u8, csp, "default-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, csp, "script-src 'self' cdn.jsdelivr.net") != null);
    try std.testing.expect(std.mem.indexOf(u8, csp, "style-src") == null);
    try std.testing.expectEqualStrings("DENY", responseHeader(&res, "X-Frame-Options").?);
    try std.testing.expectEqualStrings("max-age=63072000; includeSubDomains; preload", responseHeader(&res, "Strict-Transport-Security").?);
}

test "Security: Helmet removes X-Powered-By when present" {
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.get("/ok", okHandler);

    var req = makeRequest(.GET, "/ok", "GET /ok HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(std.testing.allocator);
    _ = res.set("X-Powered-By", "ziez");

    router.handle(&req, &res);

    try std.testing.expect(responseHeader(&res, "X-Powered-By") == null);
}

test "Security: XSS strip sanitizes query values before handler" {
    resetState();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.get("/search", queryHandler);

    var req = makeRequest(.GET, "/search", "GET /search?q=x HTTP/1.1\r\n\r\n");
    req.query = ziez.parseQuery("q=<script>alert(1)</script><b>ok</b>");
    defer req.deinit();
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(handler_called);
    try std.testing.expectEqualStrings("ok", observed_query.?);
}

test "Security: XSS strip sanitizes JSON string values before handler" {
    resetState();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.post("/json", bodyHandler);

    var req = makeRequest(.POST, "/json", "POST /json HTTP/1.1\r\nContent-Type: application/json\r\n\r\n");
    req.body_raw = "{\"name\":\"<script>alert(1)</script><b>ok</b>\"}";
    var res = ziez.Response.init(std.testing.allocator);
    defer req.deinit();

    router.handle(&req, &res);

    try std.testing.expect(handler_called);
    try std.testing.expectEqualStrings("{\"name\":\"ok\"}", observed_body.?);
}

test "Security: XSS escape mode preserves text as entities" {
    resetState();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useSecurity(.{ .xss = .{ .mode = .escape } });
    router.get("/search", queryHandler);

    var req = makeRequest(.GET, "/search", "GET /search?q=x HTTP/1.1\r\n\r\n");
    req.query = ziez.parseQuery("q=<b>\"ok\"</b>");
    defer req.deinit();
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expectEqualStrings("&lt;b&gt;&quot;ok&quot;&lt;/b&gt;", observed_query.?);
}

test "Security: XSS can be disabled" {
    resetState();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useSecurity(.{ .xss = null });
    router.get("/search", queryHandler);

    var req = makeRequest(.GET, "/search", "GET /search?q=x HTTP/1.1\r\n\r\n");
    req.query = ziez.parseQuery("q=<b>ok</b>");
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expectEqualStrings("<b>ok</b>", observed_query.?);
}

test "Security: XSS skips multipart body" {
    resetState();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.post("/upload", bodyHandler);

    var req = makeRequest(.POST, "/upload", "POST /upload HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=x\r\n\r\n");
    req.body_raw = "<b>keep</b>";
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expectEqualStrings("<b>keep</b>", observed_body.?);
}

test "Security: Helmet headers are present on CORS preflight short-circuit" {
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useCors(.{});
    router.post("/items", okHandler);

    var req = makeRequest(
        .OPTIONS,
        "/items",
        "OPTIONS /items HTTP/1.1\r\nOrigin: https://app.example.com\r\nAccess-Control-Request-Method: POST\r\n\r\n",
    );
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expectEqual(@as(u16, 204), res.status_code);
    try std.testing.expect(responseHeader(&res, "Content-Security-Policy") != null);
    try std.testing.expect(responseHeader(&res, "Access-Control-Allow-Origin") != null);
}

test "App.security stores global config" {
    var app = ziez.init(std.testing.allocator);
    defer app.deinit();

    app.security(.{ .helmet = null, .xss = null });

    try std.testing.expect(app.router.security_config.helmet == null);
    try std.testing.expect(app.router.security_config.xss == null);
}
