const std = @import("std");
const ziez = @import("ziez");

var test_order: [8][]const u8 = undefined;
var test_order_len: usize = 0;

fn resetTestOrder() void {
    test_order_len = 0;
}

fn pushOrder(label: []const u8) void {
    test_order[test_order_len] = label;
    test_order_len += 1;
}

const testHandler: ziez.HandlerFn = struct {
    fn handler(_: *ziez.Request, res: *ziez.Response) anyerror!void {
        pushOrder("handler");
        _ = res.status(200);
    }
}.handler;

fn makeInterceptor(comptime label: []const u8) *const fn (*ziez.InterceptorCtx) anyerror!void {
    return struct {
        fn call(ctx: *ziez.InterceptorCtx) anyerror!void {
            pushOrder(label ++ "-before");
            try ctx.proceed();
            pushOrder(label ++ "-after");
        }
    }.call;
}

const ic_a = makeInterceptor("a");
const ic_b = makeInterceptor("b");

const shortCircuit: ziez.InterceptorFn = struct {
    fn call(ctx: *ziez.InterceptorCtx) anyerror!void {
        pushOrder("short-before");
        _ = ctx.res.status(204);
    }
}.call;

test "intercept: single interceptor wraps handler" {
    resetTestOrder();
    const wrapped = ziez.intercept(.{ic_a}, testHandler);

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = std.testing.allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(std.testing.allocator);
    try wrapped(&req, &res);

    try std.testing.expectEqual(@as(usize, 3), test_order_len);
    try std.testing.expectEqualStrings("a-before", test_order[0]);
    try std.testing.expectEqualStrings("handler", test_order[1]);
    try std.testing.expectEqualStrings("a-after", test_order[2]);
}

test "intercept: multiple interceptors execute in onion order" {
    resetTestOrder();
    const wrapped = ziez.intercept(.{ ic_a, ic_b }, testHandler);

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = std.testing.allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(std.testing.allocator);
    try wrapped(&req, &res);

    try std.testing.expectEqual(@as(usize, 5), test_order_len);
    try std.testing.expectEqualStrings("a-before", test_order[0]);
    try std.testing.expectEqualStrings("b-before", test_order[1]);
    try std.testing.expectEqualStrings("handler", test_order[2]);
    try std.testing.expectEqualStrings("b-after", test_order[3]);
    try std.testing.expectEqualStrings("a-after", test_order[4]);
}

test "intercept: interceptor can short-circuit (skip proceed)" {
    resetTestOrder();
    const wrapped = ziez.intercept(.{shortCircuit}, testHandler);

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = std.testing.allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(std.testing.allocator);
    try wrapped(&req, &res);

    try std.testing.expectEqual(@as(usize, 1), test_order_len);
    try std.testing.expectEqualStrings("short-before", test_order[0]);
}

test "intercept: zero interceptors returns handler directly" {
    const wrapped = ziez.intercept(.{}, testHandler);
    try std.testing.expectEqual(testHandler, wrapped);
}

test "InterceptorChain: runtime chain executes in order" {
    resetTestOrder();

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = std.testing.allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(std.testing.allocator);

    const ics = [_]ziez.InterceptorFn{ ic_a, ic_b };
    var chain = ziez.InterceptorChain.init(&ics, testHandler);
    var ctx = ziez.InterceptorCtx{
        .req = &req,
        .res = &res,
        ._chain = &chain,
    };
    try ctx.proceed();

    try std.testing.expectEqual(@as(usize, 5), test_order_len);
    try std.testing.expectEqualStrings("a-before", test_order[0]);
    try std.testing.expectEqualStrings("b-before", test_order[1]);
    try std.testing.expectEqualStrings("handler", test_order[2]);
    try std.testing.expectEqualStrings("b-after", test_order[3]);
    try std.testing.expectEqualStrings("a-after", test_order[4]);
}

test "InterceptorChain: empty chain calls handler directly" {
    resetTestOrder();

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = std.testing.allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(std.testing.allocator);

    var chain = ziez.InterceptorChain.init(&[_]ziez.InterceptorFn{}, testHandler);
    var ctx = ziez.InterceptorCtx{
        .req = &req,
        .res = &res,
        ._chain = &chain,
    };
    try ctx.proceed();

    try std.testing.expectEqual(@as(usize, 1), test_order_len);
    try std.testing.expectEqualStrings("handler", test_order[0]);
}
