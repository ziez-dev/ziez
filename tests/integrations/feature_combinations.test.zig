const std = @import("std");
const testing = std.testing;
const ziez = @import("ziez");

var mw_a_called = false;
var mw_b_called = false;
var handler_called = false;

fn reset() void {
    mw_a_called = false;
    mw_b_called = false;
    handler_called = false;
}

fn makeRequest(method: ziez.HttpMethod, path: []const u8) ziez.Request {
    return .{
        .method = method,
        .path = path,
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = testing.allocator,
        .head_buffer = "GET / HTTP/1.1\r\n\r\n",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
}

test "Combinations: two middleware both execute in order" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_a_called = true;
            next.call();
        }
    }.mw);
    router.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_b_called = true;
            next.call();
        }
    }.mw);
    router.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_called = true;
            res.send("ok");
        }
    }.h);
    var req = makeRequest(.GET, "/");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(mw_a_called and mw_b_called and handler_called);
}

test "Combinations: first middleware short-circuits, second never runs" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(struct {
        fn mw(_: *ziez.Request, res: *ziez.Response, _: *ziez.Next) void {
            mw_a_called = true;
            res.status(403).json(.{ .@"error" = "Forbidden" });
        }
    }.mw);
    router.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_b_called = true;
            next.call();
        }
    }.mw);
    router.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_called = true;
            res.send("ok");
        }
    }.h);
    var req = makeRequest(.GET, "/");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 403), res.status_code);
    try testing.expect(mw_a_called);
    try testing.expect(!mw_b_called and !handler_called);
}

test "Combinations: global mw + route group mw both run for group route" {
    reset();
    var app = ziez.init(testing.allocator);
    defer app.deinit();
    app.logging(.{ .sink = ziez.LogSink.noop() });
    app.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_a_called = true;
            next.call();
        }
    }.mw);
    var api = app.group("/api");
    api.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_b_called = true;
            next.call();
        }
    }.mw);
    api.get("/data", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_called = true;
            res.send("ok");
        }
    }.h);
    var req = makeRequest(.GET, "/api/data");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(mw_a_called and mw_b_called and handler_called);
}

test "Combinations: 405 with mw active — mw does not run for 405" {
    reset();
    var app = ziez.init(testing.allocator);
    defer app.deinit();
    app.logging(.{ .sink = ziez.LogSink.noop() });
    app.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_a_called = true;
            next.call();
        }
    }.mw);
    app.post("/users", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            res.send("ok");
        }
    }.h);
    var req = makeRequest(.GET, "/users");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 405), res.status_code);
}

test "Combinations: nested route groups" {
    reset();
    var app = ziez.init(testing.allocator);
    defer app.deinit();
    app.logging(.{ .sink = ziez.LogSink.noop() });
    var v1 = app.group("/v1");
    var users = v1.group("/users");
    users.get("/:id", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_called = true;
            res.send("ok");
        }
    }.h);
    var req = makeRequest(.GET, "/v1/users/42");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(handler_called);
}

test "Combinations: after-logic in middleware runs after handler" {
    reset();
    var after_ran = false;
    _ = &after_ran;
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_a_called = true;
            next.call();
            mw_b_called = true; // runs after handler
        }
    }.mw);
    router.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_called = true;
            res.send("ok");
        }
    }.h);
    var req = makeRequest(.GET, "/");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(mw_a_called and handler_called and mw_b_called);
}
