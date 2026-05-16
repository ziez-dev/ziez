const std = @import("std");
const testing = std.testing;
const ziez = @import("ziez");

var mw_a_called = false;
var mw_b_called = false;
var mw_c_called = false;
var handler_called = false;
var observed_path: []const u8 = "";
var execution_order: [8]u8 = undefined;
var order_len: usize = 0;

fn reset() void {
    mw_a_called = false;
    mw_b_called = false;
    mw_c_called = false;
    handler_called = false;
    observed_path = "";
    order_len = 0;
}

fn pushOrder(n: u8) void {
    execution_order[order_len] = n;
    order_len += 1;
}

const mwA: ziez.MiddlewareFn = struct {
    fn call(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
        mw_a_called = true;
        pushOrder(1);
        next.call();
    }
}.call;

const mwB: ziez.MiddlewareFn = struct {
    fn call(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
        mw_b_called = true;
        pushOrder(2);
        next.call();
    }
}.call;

const mwC: ziez.MiddlewareFn = struct {
    fn call(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
        mw_c_called = true;
        pushOrder(3);
        next.call();
    }
}.call;

const shortCircuitMw: ziez.MiddlewareFn = struct {
    fn call(_: *ziez.Request, res: *ziez.Response, _: *ziez.Next) void {
        mw_a_called = true;
        res.status(403).send("forbidden by middleware");
    }
}.call;

const setHeaderMw: ziez.MiddlewareFn = struct {
    fn call(_: *ziez.Request, res: *ziez.Response, next: *ziez.Next) void {
        _ = res.set("x-custom-mw", "active");
        next.call();
    }
}.call;

const readPathMw: ziez.MiddlewareFn = struct {
    fn call(req: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
        observed_path = req.path;
        next.call();
    }
}.call;

const okHandler: ziez.HandlerFn = struct {
    fn call(_: *ziez.Request, res: *ziez.Response) anyerror!void {
        handler_called = true;
        pushOrder(9);
        res.send("ok");
    }
}.call;

fn makeRequest(method: ziez.HttpMethod, path: []const u8) ziez.Request {
    return .{
        .method = method,
        .path = path,
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = testing.allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
}

fn responseHeader(res: *const ziez.Response, name: []const u8) ?[]const u8 {
    for (0..res.headers_len) |i| {
        if (std.ascii.eqlIgnoreCase(res.headers[i].name, name)) return res.headers[i].value;
    }
    return null;
}

test "Middleware: single middleware runs before handler" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(mwA);
    router.get("/", okHandler);

    var req = makeRequest(.GET, "/");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expect(mw_a_called);
    try testing.expect(handler_called);
    try testing.expectEqual(@as(u16, 200), res.status_code);
}

test "Middleware: multiple middleware run in insertion order" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(mwA);
    router.use(mwB);
    router.use(mwC);
    router.get("/", okHandler);

    var req = makeRequest(.GET, "/");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(usize, 4), order_len);
    try testing.expectEqual(@as(u8, 1), execution_order[0]);
    try testing.expectEqual(@as(u8, 2), execution_order[1]);
    try testing.expectEqual(@as(u8, 3), execution_order[2]);
    try testing.expectEqual(@as(u8, 9), execution_order[3]);
}

test "Middleware: short-circuit blocks handler" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(shortCircuitMw);
    router.get("/", okHandler);

    var req = makeRequest(.GET, "/");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expect(mw_a_called);
    try testing.expect(!handler_called);
    try testing.expectEqual(@as(u16, 403), res.status_code);
}

test "Middleware: can set response header" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(setHeaderMw);
    router.get("/", okHandler);

    var req = makeRequest(.GET, "/");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(responseHeader(&res, "x-custom-mw") != null);
}

test "Middleware: reads request path" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(readPathMw);
    router.get("/api/v1/users", okHandler);

    var req = makeRequest(.GET, "/api/v1/users");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqualStrings("/api/v1/users", observed_path);
}

test "Middleware: global middleware applies to all routes" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(mwA);
    router.get("/a", okHandler);
    router.get("/b", okHandler);
    router.get("/c", okHandler);

    const paths = [_][]const u8{ "/a", "/b", "/c" };
    for (paths) |path| {
        mw_a_called = false;
        var req = makeRequest(.GET, path);
        var res = ziez.Response.init(testing.allocator);
        router.handle(&req, &res);
        try testing.expect(mw_a_called);
        try testing.expectEqual(@as(u16, 200), res.status_code);
    }
}

test "Middleware: error in handler does not affect subsequent requests" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(mwA);
    router.get("/bad", struct {
        fn h(_: *ziez.Request, _: *ziez.Response) anyerror!void {
            return error.InternalServerError;
        }
    }.h);
    router.get("/good", okHandler);

    var bad_req = makeRequest(.GET, "/bad");
    var bad_res = ziez.Response.init(testing.allocator);
    router.handle(&bad_req, &bad_res);
    try testing.expectEqual(@as(u16, 500), bad_res.status_code);

    mw_a_called = false;
    handler_called = false;
    var good_req = makeRequest(.GET, "/good");
    var good_res = ziez.Response.init(testing.allocator);
    router.handle(&good_req, &good_res);
    try testing.expect(mw_a_called);
    try testing.expect(handler_called);
    try testing.expectEqual(@as(u16, 200), good_res.status_code);
}

test "Middleware: no middleware still dispatches handler" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/", okHandler);

    var req = makeRequest(.GET, "/");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expect(handler_called);
    try testing.expectEqual(@as(u16, 200), res.status_code);
}
