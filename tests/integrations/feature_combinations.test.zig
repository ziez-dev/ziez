const std = @import("std");
const testing = std.testing;
const ziez = @import("ziez");

var mw_a_called = false;
var mw_plugin_called = false;
var interceptor_called = false;
var handler_called = false;

fn reset() void {
    mw_a_called = false;
    mw_plugin_called = false;
    interceptor_called = false;
    handler_called = false;
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

fn responseHeader(res: *const ziez.Response, name: []const u8) ?[]const u8 {
    for (0..res.headers_len) |i| {
        if (std.ascii.eqlIgnoreCase(res.headers[i].name, name)) return res.headers[i].value;
    }
    return null;
}

test "Combinations: CORS + GET route — CORS header present on 200" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.useCors(.{});
    router.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/", "GET / HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(responseHeader(&res, "access-control-allow-origin") != null);
}

test "Combinations: CORS + error response — CORS headers still present on 400" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.useCors(.{});
    router.get("/bad", struct {
        fn h(_: *ziez.Request, _: *ziez.Response) anyerror!void {
            return error.BadRequest;
        }
    }.h);

    var req = makeRequest(.GET, "/bad", "GET /bad HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 400), res.status_code);
    try testing.expect(responseHeader(&res, "access-control-allow-origin") != null);
}

test "Combinations: Security + GET route — security headers present on 200" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.useSecurity(.{});
    router.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/", "GET / HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(responseHeader(&res, "content-security-policy") != null);
    try testing.expect(responseHeader(&res, "x-content-type-options") != null);
}

test "Combinations: Security + error response — security headers present on 404" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.useSecurity(.{});

    var req = makeRequest(.GET, "/missing", "GET /missing HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 404), res.status_code);
    try testing.expect(responseHeader(&res, "content-security-policy") != null);
}

test "Combinations: CORS + Security together — both header sets present" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.useCors(.{});
    router.useSecurity(.{});
    router.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/", "GET / HTTP/1.1\r\nOrigin: https://app.example.com\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(responseHeader(&res, "access-control-allow-origin") != null);
    try testing.expect(responseHeader(&res, "content-security-policy") != null);
    try testing.expect(responseHeader(&res, "x-content-type-options") != null);
}

test "Combinations: Plugin installs middleware — middleware runs on route dispatch" {
    reset();

    const PluginA = struct {
        pub const plugin_name = "plugin-a";
        pub const plugin_version = "0.1.0";
        pub fn install(_: *@This(), app: *ziez.App) !void {
            app.use(struct {
                fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
                    mw_plugin_called = true;
                    next.call();
                }
            }.mw);
        }
    };

    var app = ziez.init(testing.allocator);
    defer app.deinit();
    app.plugin(PluginA{});
    app.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_called = true;
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/", "GET / HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);

    try testing.expect(mw_plugin_called);
    try testing.expect(handler_called);
    try testing.expectEqual(@as(u16, 200), res.status_code);
}

test "Combinations: Two plugins both install middleware — both run" {
    mw_a_called = false;
    mw_plugin_called = false;

    const PluginA = struct {
        pub const plugin_name = "plugin-a";
        pub const plugin_version = "0.1.0";
        pub fn install(_: *@This(), app: *ziez.App) !void {
            app.use(struct {
                fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
                    mw_a_called = true;
                    next.call();
                }
            }.mw);
        }
    };
    const PluginB = struct {
        pub const plugin_name = "plugin-b";
        pub const plugin_version = "0.1.0";
        pub fn install(_: *@This(), app: *ziez.App) !void {
            app.use(struct {
                fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
                    mw_plugin_called = true;
                    next.call();
                }
            }.mw);
        }
    };

    var app = ziez.init(testing.allocator);
    defer app.deinit();
    app.plugin(PluginA{});
    app.plugin(PluginB{});
    app.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/", "GET / HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);

    try testing.expect(mw_a_called);
    try testing.expect(mw_plugin_called);
}

test "Combinations: Middleware + global interceptor both execute" {
    reset();

    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.use(struct {
        fn mw(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            mw_a_called = true;
            next.call();
        }
    }.mw);
    router.useInterceptor(struct {
        fn ic(ctx: *ziez.InterceptorCtx) anyerror!void {
            interceptor_called = true;
            try ctx.proceed();
        }
    }.ic);
    router.get("/", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            handler_called = true;
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/", "GET / HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expect(mw_a_called);
    try testing.expect(interceptor_called);
    try testing.expect(handler_called);
    try testing.expectEqual(@as(u16, 200), res.status_code);
}

test "Combinations: Security headers present on catch-all 404" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.useSecurity(.{});

    var req = makeRequest(.GET, "/anything/not/registered", "GET /anything/not/registered HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 404), res.status_code);
    try testing.expect(responseHeader(&res, "content-security-policy") != null);
    try testing.expect(responseHeader(&res, "x-frame-options") != null);
}

test "Combinations: Plugin installs CORS via app.cors() — CORS active on route" {
    const CorsPlugin = struct {
        pub const plugin_name = "cors-plugin";
        pub const plugin_version = "0.1.0";
        pub fn install(_: *@This(), app: *ziez.App) !void {
            app.cors(.{});
        }
    };

    var app = ziez.init(testing.allocator);
    defer app.deinit();
    app.plugin(CorsPlugin{});
    app.get("/api", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/api", "GET /api HTTP/1.1\r\nOrigin: https://frontend.example.com\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    app.router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(responseHeader(&res, "access-control-allow-origin") != null);
}
