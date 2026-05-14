const std = @import("std");
const ziez = @import("ziez");

var handler_called = false;
var middleware_called = false;

fn resetCalls() void {
    handler_called = false;
    middleware_called = false;
}

const okHandler: ziez.HandlerFn = struct {
    fn handler(_: *ziez.Request, res: *ziez.Response) anyerror!void {
        handler_called = true;
        res.status(200).send("ok");
    }
}.handler;

const trackingMiddleware: ziez.MiddlewareFn = struct {
    fn handler(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
        middleware_called = true;
        next.call();
    }
}.handler;

fn allowedByPredicate(origin: []const u8) bool {
    return std.mem.endsWith(u8, origin, ".example.com");
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

fn responseHeader(res: *const ziez.Response, name: []const u8) ?[]const u8 {
    for (0..res.headers_len) |i| {
        if (std.ascii.eqlIgnoreCase(res.headers[i].name, name)) {
            return res.headers[i].value;
        }
    }
    return null;
}

test "CORS origin matching supports wildcard list and predicate" {
    try std.testing.expect(ziez.cors.isOriginAllowed("https://anything.test", .{}));

    const origins = &.{ "https://app.example.com", "https://admin.example.com" };
    try std.testing.expect(ziez.cors.isOriginAllowed("https://app.example.com", .{
        .origins = .{ .list = origins },
    }));
    try std.testing.expect(!ziez.cors.isOriginAllowed("https://evil.example.net", .{
        .origins = .{ .list = origins },
    }));

    try std.testing.expect(ziez.cors.isOriginAllowed("api.example.com", .{
        .origins = .{ .predicate = allowedByPredicate },
    }));
    try std.testing.expect(!ziez.cors.isOriginAllowed("api.example.net", .{
        .origins = .{ .predicate = allowedByPredicate },
    }));
}

test "Router CORS: valid preflight returns 204 and skips handler" {
    resetCalls();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useCors(.{
        .origins = .{ .list = &.{"https://app.example.com"} },
        .methods = &.{ .GET, .POST, .OPTIONS },
        .allowed_headers = &.{ "Content-Type", "Authorization" },
        .max_age = 3600,
    });
    router.post("/items", okHandler);

    var req = makeRequest(
        .OPTIONS,
        "/items",
        "OPTIONS /items HTTP/1.1\r\nOrigin: https://app.example.com\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: Content-Type, Authorization\r\n\r\n",
    );
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(res.sent);
    try std.testing.expectEqual(@as(u16, 204), res.status_code);
    try std.testing.expect(!handler_called);
    try std.testing.expectEqualStrings("https://app.example.com", responseHeader(&res, "Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("GET, POST, OPTIONS", responseHeader(&res, "Access-Control-Allow-Methods").?);
    try std.testing.expectEqualStrings("Content-Type, Authorization", responseHeader(&res, "Access-Control-Allow-Headers").?);
    try std.testing.expectEqualStrings("3600", responseHeader(&res, "Access-Control-Max-Age").?);
}

test "Router CORS: invalid preflight origin returns 403" {
    resetCalls();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useCors(.{
        .origins = .{ .list = &.{"https://app.example.com"} },
    });
    router.post("/items", okHandler);

    var req = makeRequest(
        .OPTIONS,
        "/items",
        "OPTIONS /items HTTP/1.1\r\nOrigin: https://evil.example.com\r\nAccess-Control-Request-Method: POST\r\n\r\n",
    );
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(res.sent);
    try std.testing.expectEqual(@as(u16, 403), res.status_code);
    try std.testing.expect(!handler_called);
    try std.testing.expect(responseHeader(&res, "Access-Control-Allow-Origin") == null);
}

test "Router CORS: invalid requested preflight header returns 403" {
    resetCalls();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useCors(.{
        .origins = .{ .list = &.{"https://app.example.com"} },
        .allowed_headers = &.{"Content-Type"},
    });
    router.post("/items", okHandler);

    var req = makeRequest(
        .OPTIONS,
        "/items",
        "OPTIONS /items HTTP/1.1\r\nOrigin: https://app.example.com\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: X-Secret\r\n\r\n",
    );
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(res.sent);
    try std.testing.expectEqual(@as(u16, 403), res.status_code);
    try std.testing.expect(!handler_called);
}

test "Router CORS: simple request with valid origin gets headers and reaches route" {
    resetCalls();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useCors(.{});
    router.get("/items", okHandler);

    var req = makeRequest(
        .GET,
        "/items",
        "GET /items HTTP/1.1\r\nOrigin: https://app.example.com\r\n\r\n",
    );
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(res.sent);
    try std.testing.expect(handler_called);
    try std.testing.expectEqual(@as(u16, 200), res.status_code);
    try std.testing.expectEqualStrings("*", responseHeader(&res, "Access-Control-Allow-Origin").?);
}

test "Router CORS: simple request with invalid origin reaches route without CORS headers" {
    resetCalls();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useCors(.{
        .origins = .{ .list = &.{"https://app.example.com"} },
    });
    router.get("/items", okHandler);

    var req = makeRequest(
        .GET,
        "/items",
        "GET /items HTTP/1.1\r\nOrigin: https://evil.example.com\r\n\r\n",
    );
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(res.sent);
    try std.testing.expect(handler_called);
    try std.testing.expectEqual(@as(u16, 200), res.status_code);
    try std.testing.expect(responseHeader(&res, "Access-Control-Allow-Origin") == null);
}

test "Router CORS: wildcard with credentials echoes origin and sets Vary" {
    resetCalls();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useCors(.{
        .credentials = true,
        .exposed_headers = &.{ "X-Total-Count", "X-Page" },
    });
    router.get("/items", okHandler);

    var req = makeRequest(
        .GET,
        "/items",
        "GET /items HTTP/1.1\r\nOrigin: https://app.example.com\r\n\r\n",
    );
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(handler_called);
    try std.testing.expectEqualStrings("https://app.example.com", responseHeader(&res, "Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("true", responseHeader(&res, "Access-Control-Allow-Credentials").?);
    try std.testing.expectEqualStrings("Origin", responseHeader(&res, "Vary").?);
    try std.testing.expectEqualStrings("X-Total-Count, X-Page", responseHeader(&res, "Access-Control-Expose-Headers").?);
}

test "Router CORS: preflight runs before middleware" {
    resetCalls();
    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.useCors(.{});
    router.use(trackingMiddleware);
    router.post("/items", okHandler);

    var req = makeRequest(
        .OPTIONS,
        "/items",
        "OPTIONS /items HTTP/1.1\r\nOrigin: https://app.example.com\r\nAccess-Control-Request-Method: POST\r\n\r\n",
    );
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(res.sent);
    try std.testing.expectEqual(@as(u16, 204), res.status_code);
    try std.testing.expect(!middleware_called);
    try std.testing.expect(!handler_called);
}

test "App.cors enables router CORS config" {
    var app = ziez.init(std.testing.allocator);
    defer app.deinit();

    app.cors(.{});

    try std.testing.expect(app.router.cors_config != null);
}
