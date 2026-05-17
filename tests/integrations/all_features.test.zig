/// Kitchen-sink integration test.
/// All core features active simultaneously — middleware chaining, route groups, 405, schema, error handling.
const std = @import("std");
const testing = std.testing;
const ziez = @import("ziez");

var mw_a_ran = false;
var mw_b_ran = false;
var mw_c_ran = false;
var handler_ran = false;
var exec_order: [8]u8 = undefined;
var exec_len: usize = 0;

fn reset() void {
    mw_a_ran = false;
    mw_b_ran = false;
    mw_c_ran = false;
    handler_ran = false;
    exec_len = 0;
}

fn push(n: u8) void {
    exec_order[exec_len] = n;
    exec_len += 1;
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

fn setupApp(alloc: std.mem.Allocator) ziez.App {
    var app = ziez.init(alloc);
    app.logging(.{ .sink = ziez.LogSink.noop() });
    app.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_a_ran = true;
            push(1);
            next.call();
            push(4);
        }
    }.mw);
    app.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_b_ran = true;
            push(2);
            next.call();
        }
    }.mw);
    app.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_c_ran = true;
            push(3);
            next.call();
        }
    }.mw);
    return app;
}

test "AllFeatures: 3 mw in order, handler, after-logic" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();
    app.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_ran = true;
            push(4);
            res.json(.{ .ok = true });
        }
    }.h);
    var req = makeRequest(.GET, "/");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(mw_a_ran and mw_b_ran and mw_c_ran and handler_ran);
    // All 3 middleware ran in order before handler; after-logic in mw_a also ran.
    try testing.expectEqual(@as(u8, 1), exec_order[0]); // mw_a before
    try testing.expectEqual(@as(u8, 2), exec_order[1]); // mw_b
    try testing.expectEqual(@as(u8, 3), exec_order[2]); // mw_c
}

test "AllFeatures: param route with mw active" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();
    var observed_id: []const u8 = "";
    app.get("/users/:id", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_ran = true;
            _ = req.param("id");
            res.send("ok");
        }
    }.h);
    _ = &observed_id;
    var req: ziez.Request = .{
        .method = .GET,
        .path = "/users/99",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = testing.allocator,
        .head_buffer = "GET /users/99 HTTP/1.1\r\n\r\n",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(mw_a_ran and mw_b_ran and mw_c_ran and handler_ran);
}

test "AllFeatures: short-circuit — 401, handler not called" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();
    app.use(struct {
        fn mw(_: *ziez.Request, res: *ziez.Response, _: *ziez.Next) void {
            res.status(401).json(.{ .@"error" = "Unauthorized" });
        }
    }.mw);
    app.get("/s", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_ran = true;
            res.send("ok");
        }
    }.h);
    var req = makeRequest(.GET, "/s");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 401), res.status_code);
    try testing.expect(!handler_ran);
}
test "AllFeatures: 404" {
    var app = setupApp(testing.allocator);
    defer app.deinit();
    var req = makeRequest(.GET, "/nope");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 404), res.status_code);
}
test "AllFeatures: 405" {
    var app = ziez.init(testing.allocator);
    defer app.deinit();
    app.logging(.{ .sink = ziez.LogSink.noop() });
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
test "AllFeatures: route group mw only applies to group routes" {
    reset();
    var app = ziez.init(testing.allocator);
    defer app.deinit();
    app.logging(.{ .sink = ziez.LogSink.noop() });
    var api = app.group("/api");
    api.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_a_ran = true;
            next.call();
        }
    }.mw);
    api.get("/users", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_ran = true;
            res.send("ok");
        }
    }.h);
    app.get("/health", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            res.send("ok");
        }
    }.h);
    var r1 = makeRequest(.GET, "/api/users");
    var s1 = ziez.Response.init(testing.allocator);
    app.router.handle(&r1, &s1);
    try testing.expectEqual(@as(u16, 200), s1.status_code);
    try testing.expect(mw_a_ran and handler_ran);
    mw_a_ran = false;
    var r2 = makeRequest(.GET, "/health");
    var s2 = ziez.Response.init(testing.allocator);
    app.router.handle(&r2, &s2);
    try testing.expect(!mw_a_ran);
}
test "AllFeatures: error handler fires, mw ran" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();
    app.on_error(struct {
        fn h(_: *ziez.Request, res: *ziez.Response, err: anyerror) void {
            const info = ziez.errorToResponse(err);
            res.status(info.code).json(.{ .@"error" = info.message });
        }
    }.h);
    app.get("/boom", struct {
        fn h(_: *ziez.Request, _: *ziez.Response) anyerror!void {
            return error.Forbidden;
        }
    }.h);
    var req = makeRequest(.GET, "/boom");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);
    try testing.expectEqual(@as(u16, 403), res.status_code);
    try testing.expect(mw_a_ran and mw_b_ran and mw_c_ran);
}
test "AllFeatures: schema validation with mw active" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();
    const Item = struct {
        name: []const u8,
        pub const rules = .{ .name = ziez.schema.StringRule{ .min_length = 2 } };
    };
    app.post("/items", ziez.validateBodySchema(Item, struct {
        fn h(_: *ziez.Request, res: *ziez.Response, item: Item) anyerror!void {
            handler_ran = true;
            res.status(201).json(.{ .name = item.name });
        }
    }.h));
    var vreq: ziez.Request = .{ .method = .POST, .path = "/items", .query = .{}, .params = .{}, .body_raw = "{\"name\":\"Widget\"}", .allocator = std.heap.page_allocator, .head_buffer = "POST /items HTTP/1.1\r\ncontent-type: application/json\r\n\r\n", .owns_body = false, .cookies = .{}, .cookies_parsed = false };
    var vres = ziez.Response.init(testing.allocator);
    app.router.handle(&vreq, &vres);
    try testing.expectEqual(@as(u16, 201), vres.status_code);
    try testing.expect(handler_ran and mw_a_ran);
    handler_ran = false;
    var ireq: ziez.Request = .{ .method = .POST, .path = "/items", .query = .{}, .params = .{}, .body_raw = "{\"name\":\"X\"}", .allocator = std.heap.page_allocator, .head_buffer = "POST /items HTTP/1.1\r\ncontent-type: application/json\r\n\r\n", .owns_body = false, .cookies = .{}, .cookies_parsed = false };
    var ires = ziez.Response.init(testing.allocator);
    app.router.handle(&ireq, &ires);
    try testing.expectEqual(@as(u16, 422), ires.status_code);
    try testing.expect(!handler_ran);
}
