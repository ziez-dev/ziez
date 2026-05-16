const std = @import("std");
const testing = std.testing;
const ziez = @import("ziez");

var custom_error_handler_called = false;
var custom_error_received: anyerror = error.OutOfMemory;
var custom_status_set: u16 = 0;

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

fn dispatchError(comptime err: anyerror) u16 {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/test", struct {
        fn h(_: *ziez.Request, _: *ziez.Response) anyerror!void {
            return err;
        }
    }.h);
    var req = makeRequest(.GET, "/test");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);
    return res.status_code;
}

test "ErrorHandling: error.BadRequest → 400" {
    try testing.expectEqual(@as(u16, 400), dispatchError(error.BadRequest));
}

test "ErrorHandling: error.Unauthorized → 401" {
    try testing.expectEqual(@as(u16, 401), dispatchError(error.Unauthorized));
}

test "ErrorHandling: error.Forbidden → 403" {
    try testing.expectEqual(@as(u16, 403), dispatchError(error.Forbidden));
}

test "ErrorHandling: error.NotFound → 404" {
    try testing.expectEqual(@as(u16, 404), dispatchError(error.NotFound));
}

test "ErrorHandling: error.MethodNotAllowed → 405" {
    try testing.expectEqual(@as(u16, 405), dispatchError(error.MethodNotAllowed));
}

test "ErrorHandling: error.Conflict → 409" {
    try testing.expectEqual(@as(u16, 409), dispatchError(error.Conflict));
}

test "ErrorHandling: error.UnprocessableEntity → 422" {
    try testing.expectEqual(@as(u16, 422), dispatchError(error.UnprocessableEntity));
}

test "ErrorHandling: error.TooManyRequests → 429" {
    try testing.expectEqual(@as(u16, 429), dispatchError(error.TooManyRequests));
}

test "ErrorHandling: error.InternalServerError → 500" {
    try testing.expectEqual(@as(u16, 500), dispatchError(error.InternalServerError));
}

test "ErrorHandling: error.ServiceUnavailable → 503" {
    try testing.expectEqual(@as(u16, 503), dispatchError(error.ServiceUnavailable));
}

test "ErrorHandling: unknown error → 500" {
    try testing.expectEqual(@as(u16, 500), dispatchError(error.SomeUnknownError));
}

test "ErrorHandling: ziez.throw sets error_message on response" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.get("/test", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            return ziez.throw(error.BadRequest, "email is required", res);
        }
    }.h);

    var req = makeRequest(.GET, "/test");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 400), res.status_code);
    try testing.expect(res.error_message != null);
    try testing.expectEqualStrings("email is required", res.error_message.?);
}

test "ErrorHandling: custom on_error handler is called and overrides status" {
    custom_error_handler_called = false;
    custom_error_received = error.OutOfMemory;
    custom_status_set = 0;

    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.setErrorHandler(struct {
        fn h(_: *ziez.Request, res: *ziez.Response, err: anyerror) void {
            custom_error_handler_called = true;
            custom_error_received = err;
            custom_status_set = 599;
            res.status(599).send("custom error");
        }
    }.h);
    router.get("/test", struct {
        fn h(_: *ziez.Request, _: *ziez.Response) anyerror!void {
            return error.BadRequest;
        }
    }.h);

    var req = makeRequest(.GET, "/test");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expect(custom_error_handler_called);
    try testing.expectEqual(error.BadRequest, custom_error_received);
    try testing.expectEqual(@as(u16, 599), res.status_code);
}

test "ErrorHandling: no route matched → 404" {
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();

    var req = makeRequest(.GET, "/nothing-here");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 404), res.status_code);
}

test "ErrorHandling: error in middleware propagates to error handler" {
    custom_error_handler_called = false;
    var router = ziez.Router.initSilent(testing.allocator);
    defer router.deinit();
    router.setErrorHandler(struct {
        fn h(_: *ziez.Request, _: *ziez.Response, _: anyerror) void {
            custom_error_handler_called = true;
        }
    }.h);
    router.use(struct {
        fn mw(_: *ziez.Request, res: *ziez.Response, _: *ziez.Next) void {
            res.error_message = "blocked";
            _ = res.status(403);
        }
    }.mw);
    router.get("/test", struct {
        fn h(_: *ziez.Request, res: *ziez.Response) anyerror!void {
            res.send("should not reach here");
        }
    }.h);

    var req = makeRequest(.GET, "/test");
    var res = ziez.Response.init(testing.allocator);
    router.handle(&req, &res);

    try testing.expectEqual(@as(u16, 403), res.status_code);
}
