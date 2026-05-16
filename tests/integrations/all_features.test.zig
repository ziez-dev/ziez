/// Kitchen-sink integration test.
/// All features active simultaneously — goal: verify nothing conflicts.
///
/// Setup: App with CORS + Security + Middleware A + Middleware B + Interceptor + Plugin-MW.
/// Every dispatch asserts both feature effects AND correct status code.
const std = @import("std");
const testing = std.testing;
const ziez = @import("ziez");

var mw_a_ran = false;
var mw_b_ran = false;
var mw_plugin_ran = false;
var interceptor_ran = false;
var handler_ran = false;
var exec_order: [8]u8 = undefined;
var exec_len: usize = 0;
var observed_id: []const u8 = "";

fn reset() void {
    mw_a_ran = false;
    mw_b_ran = false;
    mw_plugin_ran = false;
    interceptor_ran = false;
    handler_ran = false;
    exec_len = 0;
}

fn push(n: u8) void {
    exec_order[exec_len] = n;
    exec_len += 1;
}

fn responseHeader(res: *const ziez.Response, name: []const u8) ?[]const u8 {
    for (0..res.headers_len) |i| {
        if (std.ascii.eqlIgnoreCase(res.headers[i].name, name)) return res.headers[i].value;
    }
    return null;
}

fn makeRequest(method: ziez.HttpMethod, path: []const u8, origin: ?[]const u8) ziez.Request {
    const head = if (origin) |o| blk: {
        _ = o;
        break :blk "GET / HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n";
    } else "GET / HTTP/1.1\r\n\r\n";
    return .{
        .method = method,
        .path = path,
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = testing.allocator,
        .head_buffer = head,
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
}

const ExecPlugin = struct {
    pub const plugin_name = "exec-plugin";
    pub const plugin_version = "0.1.0";
    pub fn install(_: *@This(), app: *ziez.App) !void {
        app.use(struct {
            fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
                mw_plugin_ran = true;
                push(3);
                next.call();
            }
        }.mw);
    }
};

fn setupApp(alloc: std.mem.Allocator) ziez.App {
    var app = ziez.init(alloc);
    app.logging(.{ .sink = ziez.LogSink.noop() });
    app.cors(.{});
    app.security(.{});
    app.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_a_ran = true;
            push(1);
            next.call();
        }
    }.mw);
    app.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_b_ran = true;
            push(2);
            next.call();
        }
    }.mw);
    app.plugin(ExecPlugin{});
    app.useInterceptor(struct {
        fn ic(ctx: *ziez.InterceptorCtx) anyerror!void {
            interceptor_ran = true;
            try ctx.proceed();
        }
    }.ic);
    return app;
}

test "AllFeatures: GET / — all features active, 200 + CORS + CSP + correct exec order" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();
    app.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_ran = true;
            push(9);
            res.json(.{ .status = "ok" });
        }
    }.h);

    var req = makeRequest(.GET, "/", "https://example.com");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(mw_a_ran);
    try testing.expect(mw_b_ran);
    try testing.expect(mw_plugin_ran);
    try testing.expect(interceptor_ran);
    try testing.expect(handler_ran);
    try testing.expect(responseHeader(&res, "access-control-allow-origin") != null);
    try testing.expect(responseHeader(&res, "content-security-policy") != null);

    try testing.expectEqual(@as(usize, 4), exec_len);
    try testing.expectEqual(@as(u8, 1), exec_order[0]);
    try testing.expectEqual(@as(u8, 2), exec_order[1]);
    try testing.expectEqual(@as(u8, 3), exec_order[2]);
    try testing.expectEqual(@as(u8, 9), exec_order[3]);
}

test "AllFeatures: GET /users/:id — param + CORS + CSP all present" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();

    observed_id = "";
    app.get("/users/:id", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_ran = true;
            observed_id = req.param("id") orelse "";
            res.send("ok");
        }
    }.h);

    var req: ziez.Request = .{
        .method = .GET,
        .path = "/users/99",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = testing.allocator,
        .head_buffer = "GET /users/99 HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("99", observed_id);
    try testing.expect(responseHeader(&res, "access-control-allow-origin") != null);
    try testing.expect(responseHeader(&res, "content-security-policy") != null);
    try testing.expect(mw_a_ran and mw_b_ran and mw_plugin_ran and interceptor_ran);
}

test "AllFeatures: POST /users valid body — 201 + CORS + CSP" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();

    const CreateUser = struct { name: []const u8 };
    app.post("/users", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_ran = true;
            const body = req.body_json(CreateUser) orelse return error.BadRequest;
            res.status(201).json(.{ .name = body.name });
        }
    }.h);

    // Use page_allocator for req so parseFromSliceLeaky internal state
    // doesn't trigger the testing.allocator leak detector.
    var req: ziez.Request = .{
        .method = .POST,
        .path = "/users",
        .query = .{},
        .params = .{},
        .body_raw = "{\"name\":\"Alice\"}",
        .allocator = std.heap.page_allocator,
        .head_buffer = "POST /users HTTP/1.1\r\ncontent-type: application/json\r\nOrigin: https://example.com\r\n\r\n",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 201), res.status_code);
    try testing.expect(responseHeader(&res, "access-control-allow-origin") != null);
    try testing.expect(responseHeader(&res, "content-security-policy") != null);
}

test "AllFeatures: POST /users invalid body — 400 + CORS still present on error" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();

    const CreateUser = struct { name: []const u8 };
    app.post("/users", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            const body = req.body_json(CreateUser) orelse
                return ziez.throw(error.BadRequest, "invalid JSON", res);
            _ = body;
            res.status(201).send("ok");
        }
    }.h);

    var req: ziez.Request = .{
        .method = .POST,
        .path = "/users",
        .query = .{},
        .params = .{},
        .body_raw = "not-json",
        .allocator = testing.allocator,
        .head_buffer = "POST /users HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 400), res.status_code);
    try testing.expect(responseHeader(&res, "access-control-allow-origin") != null);
    try testing.expect(responseHeader(&res, "content-security-policy") != null);
}

test "AllFeatures: GET /admin — 403 + CORS on error + CSP on error" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();
    app.get("/admin", struct {
        fn h(_: *ziez.Request, _: *ziez.Response) anyerror!void {
            return error.Forbidden;
        }
    }.h);

    var req = makeRequest(.GET, "/admin", "https://example.com");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 403), res.status_code);
    try testing.expect(responseHeader(&res, "access-control-allow-origin") != null);
    try testing.expect(responseHeader(&res, "content-security-policy") != null);
}

test "AllFeatures: GET /not-found — 404 + security headers applied" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();

    var req = makeRequest(.GET, "/not-registered", null);
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 404), res.status_code);
    try testing.expect(responseHeader(&res, "content-security-policy") != null);
    try testing.expect(responseHeader(&res, "x-content-type-options") != null);
}

test "AllFeatures: schema validation works with all features active" {
    reset();
    var app = setupApp(testing.allocator);
    defer app.deinit();

    const Item = struct {
        name: []const u8,
        pub const rules = .{
            .name = ziez.schema.StringRule{ .min_length = 2 },
        };
    };

    app.post("/items", ziez.validateBodySchema(Item, struct {
        fn h(_: *ziez.Request, res: *ziez.Response, item: Item) anyerror!void {
            handler_ran = true;
            res.status(201).json(.{ .name = item.name });
        }
    }.h));

    // Use page_allocator: body_json's parseFromSliceLeaky + schema.validate
    // both allocate internal state that's never freed — intentional design.
    var valid_req: ziez.Request = .{
        .method = .POST,
        .path = "/items",
        .query = .{},
        .params = .{},
        .body_raw = "{\"name\":\"Widget\"}",
        .allocator = std.heap.page_allocator,
        .head_buffer = "POST /items HTTP/1.1\r\ncontent-type: application/json\r\n\r\n",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var valid_res = ziez.Response.init(testing.allocator);
    app.router.handle(&valid_req, &valid_res);
    try testing.expectEqual(@as(u16, 201), valid_res.status_code);
    try testing.expect(handler_ran);

    handler_ran = false;
    var invalid_req: ziez.Request = .{
        .method = .POST,
        .path = "/items",
        .query = .{},
        .params = .{},
        .body_raw = "{\"name\":\"X\"}",
        .allocator = std.heap.page_allocator,
        .head_buffer = "POST /items HTTP/1.1\r\ncontent-type: application/json\r\n\r\n",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var invalid_res = ziez.Response.init(testing.allocator);
    app.router.handle(&invalid_req, &invalid_res);
    try testing.expectEqual(@as(u16, 422), invalid_res.status_code);
    try testing.expect(!handler_ran);
    try testing.expect(responseHeader(&invalid_res, "content-security-policy") != null);
}
