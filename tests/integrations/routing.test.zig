const std = @import("std");
const testing = std.testing;
const ziez = @import("ziez");

var observed_param: []const u8 = "";
var observed_param2: []const u8 = "";
var observed_param3: []const u8 = "";
var handler_called = false;

fn reset() void {
    observed_param = "";
    observed_param2 = "";
    observed_param3 = "";
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
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
}

const okHandler: ziez.HandlerFn = struct {
    fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
        handler_called = true;
        res.send("ok");
    }
}.h;

test "Routing: static GET / returns 200" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/", okHandler);

    var req = makeRequest(.GET, "/");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(handler_called);
}

test "Routing: dynamic param /users/:id extracted correctly" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/users/:id", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            observed_param = req.param("id") orelse "";
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/users/42");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("42", observed_param);
}

test "Routing: multiple params /orgs/:org/repos/:repo both extracted" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/orgs/:org/repos/:repo", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            observed_param = req.param("org") orelse "";
            observed_param2 = req.param("repo") orelse "";
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/orgs/ziez/repos/core");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("ziez", observed_param);
    try testing.expectEqualStrings("core", observed_param2);
}

test "Routing: POST on GET-only route returns 404" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/users", okHandler);

    var req = makeRequest(.POST, "/users");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 404), res.status_code);
    try testing.expect(!handler_called);
}

test "Routing: each HTTP method dispatches to correct handler" {
    const methods = [_]ziez.HttpMethod{ .GET, .POST, .PUT, .DELETE, .PATCH };
    inline for (methods) |method| {
        var router = ziez.Router.initSilent(testing.allocator);
        defer router.deinit();
        switch (method) {
            .GET => router.get("/r", okHandler),
            .POST => router.post("/r", okHandler),
            .PUT => router.put("/r", okHandler),
            .DELETE => router.delete("/r", okHandler),
            .PATCH => router.patch("/r", okHandler),
            else => {},
        }
        handler_called = false;
        var req = makeRequest(method, "/r");
        var res = ziez.Response.init(testing.allocator);
        router.handle(&req, &res);
        try testing.expectEqual(@as(u16, 200), res.status_code);
        try testing.expect(handler_called);
    }
}

test "Routing: router.all() matches GET, POST, and DELETE" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.all("/*", okHandler);

    const methods = [_]ziez.HttpMethod{ .GET, .POST, .DELETE };
    for (methods) |method| {
        handler_called = false;
        var req = makeRequest(method, "/anything");
        var res = ziez.Response.init(testing.allocator);
        router.handle(&req, &res);
        try testing.expect(handler_called);
        try testing.expectEqual(@as(u16, 200), res.status_code);
    }
}

test "Routing: unregistered path returns 404" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/exists", okHandler);

    var req = makeRequest(.GET, "/does-not-exist");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 404), res.status_code);
}

test "Routing: PUT and DELETE methods dispatched correctly" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.put("/resource", okHandler);
    router.delete("/resource", okHandler);

    handler_called = false;
    var put_req = makeRequest(.PUT, "/resource");
    var put_res = ziez.Response.init(testing.allocator);
    router.handle(&put_req, &put_res);
    try testing.expect(handler_called);
    try testing.expectEqual(@as(u16, 200), put_res.status_code);

    handler_called = false;
    var del_req = makeRequest(.DELETE, "/resource");
    var del_res = ziez.Response.init(testing.allocator);
    router.handle(&del_req, &del_res);
    try testing.expect(handler_called);
    try testing.expectEqual(@as(u16, 200), del_res.status_code);
}

test "Routing: three-level nested params all extracted" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/a/:x/b/:y/c/:z", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            observed_param = req.param("x") orelse "";
            observed_param2 = req.param("y") orelse "";
            observed_param3 = req.param("z") orelse "";
            res.send("ok");
        }
    }.h);

    var req = makeRequest(.GET, "/a/alpha/b/beta/c/gamma");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("alpha", observed_param);
    try testing.expectEqualStrings("beta", observed_param2);
    try testing.expectEqualStrings("gamma", observed_param3);
}

test "Routing: PATCH method dispatched correctly" {
    reset();
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.patch("/items/:id", struct {
        fn h(req: *ziez.Request, res: *ziez.Response) anyerror!void {
            observed_param = req.param("id") orelse "";
            res.send("patched");
        }
    }.h);

    var req = makeRequest(.PATCH, "/items/99");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("99", observed_param);
}
