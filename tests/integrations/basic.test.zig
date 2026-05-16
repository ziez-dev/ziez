const std = @import("std");
const testing = std.testing;
const ziez = @import("ziez");

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

test "Integration: GET / returns 200 with JSON body" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .message = "hello from ziez!" });
        }
    }.handler);

    var req = makeRequest(.GET, "/", "GET / HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
}

test "Integration: GET /users/:id extracts param and returns 200" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/users/:id", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const id = req.param("id") orelse return error.BadRequest;
            if (id.len > 10) return error.NotFound;
            res.json(.{ .id = id });
        }
    }.handler);

    var req = makeRequest(.GET, "/users/42", "GET /users/42 HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
}

test "Integration: GET /users/:id with long id returns 404" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/users/:id", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const id = req.param("id") orelse return error.BadRequest;
            if (id.len > 10) return error.NotFound;
            res.json(.{ .id = id });
        }
    }.handler);

    var req = makeRequest(.GET, "/users/this-id-is-way-too-long", "GET /users/this-id-is-way-too-long HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 404), res.status_code);
}

test "Integration: POST /users with valid JSON body returns 201" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.post("/users", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const User = struct { name: []const u8 };
            const user = req.body_json(User) orelse
                return ziez.throw(error.BadRequest, "body must be valid JSON", res);
            if (user.name.len == 0)
                return ziez.throw(error.UnprocessableEntity, "name cannot be empty", res);
            res.status(201).json(.{ .id = 1, .name = user.name });
        }
    }.handler);

    var req = makeRequest(.POST, "/users", "POST /users HTTP/1.1\r\ncontent-type: application/json\r\n\r\n");
    req.body_raw = "{\"name\":\"Alice\"}";
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 201), res.status_code);
}

test "Integration: POST /users with empty name returns 422" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.post("/users", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const User = struct { name: []const u8 };
            const user = req.body_json(User) orelse
                return ziez.throw(error.BadRequest, "body must be valid JSON", res);
            if (user.name.len == 0)
                return ziez.throw(error.UnprocessableEntity, "name cannot be empty", res);
            res.status(201).json(.{ .id = 1, .name = user.name });
        }
    }.handler);

    var req = makeRequest(.POST, "/users", "POST /users HTTP/1.1\r\ncontent-type: application/json\r\n\r\n");
    req.body_raw = "{\"name\":\"\"}";
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 422), res.status_code);
}

test "Integration: POST /login with valid creds returns 200" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.post("/login", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const Creds = struct { username: []const u8, password: []const u8 };
            const creds = req.body_json(Creds) orelse
                return ziez.throw(error.BadRequest, "username and password required", res);
            if (!std.mem.eql(u8, creds.username, "admin") or
                !std.mem.eql(u8, creds.password, "secret"))
                return ziez.throw(error.Unauthorized, "invalid credentials", res);
            res.json(.{ .token = "jwt-token" });
        }
    }.handler);

    var req = makeRequest(.POST, "/login", "POST /login HTTP/1.1\r\ncontent-type: application/json\r\n\r\n");
    req.body_raw = "{\"username\":\"admin\",\"password\":\"secret\"}";
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 200), res.status_code);
}

test "Integration: POST /login with bad creds returns 401" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.post("/login", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const Creds = struct { username: []const u8, password: []const u8 };
            const creds = req.body_json(Creds) orelse
                return ziez.throw(error.BadRequest, "username and password required", res);
            if (!std.mem.eql(u8, creds.username, "admin") or
                !std.mem.eql(u8, creds.password, "secret"))
                return ziez.throw(error.Unauthorized, "invalid credentials", res);
            res.json(.{ .token = "jwt-token" });
        }
    }.handler);

    var req = makeRequest(.POST, "/login", "POST /login HTTP/1.1\r\ncontent-type: application/json\r\n\r\n");
    req.body_raw = "{\"username\":\"admin\",\"password\":\"wrong\"}";
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 401), res.status_code);
}

test "Integration: error codes map to correct HTTP status" {
    const cases = [_]struct { err: anyerror, code: u16 }{
        .{ .err = error.Forbidden, .code = 403 },
        .{ .err = error.Teapot, .code = 418 },
        .{ .err = error.ServiceUnavailable, .code = 503 },
    };

    inline for (cases) |tc| {
        var router = ziez.Router.initSilent(testing.allocator);
        defer router.deinit();
        router.get("/route", struct {
            fn handler(_: *ziez.Request, _: *ziez.Response) !void {
                return tc.err;
            }
        }.handler);
        var req = makeRequest(.GET, "/route", "GET /route HTTP/1.1\r\n\r\n");
        var res = ziez.Response.init(testing.allocator);
        router.handle(&req, &res);
        try testing.expectEqual(tc.code, res.status_code);
    }
}

test "Integration: unmatched route returns 404" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/exists", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.send("ok");
        }
    }.handler);

    var req = makeRequest(.GET, "/does-not-exist", "GET /does-not-exist HTTP/1.1\r\n\r\n");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 404), res.status_code);
}
