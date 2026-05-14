const std = @import("std");
const ziez = @import("ziez");

var test_captured_id: u64 = 0;
var test_captured_bool: bool = false;
var test_captured_name: []const u8 = "";
var test_captured_val: []const u8 = "";
var test_captured_page: u32 = 0;

test "isValidUUID: valid UUIDs" {
    try std.testing.expect(ziez.isValidUUID("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(ziez.isValidUUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8"));
    try std.testing.expect(ziez.isValidUUID("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"));
    try std.testing.expect(ziez.isValidUUID("00000000-0000-0000-0000-000000000000"));
}

test "isValidUUID: invalid UUIDs" {
    try std.testing.expect(!ziez.isValidUUID("not-a-uuid"));
    try std.testing.expect(!ziez.isValidUUID("550e8400e29b41d4a716446655440000"));
    try std.testing.expect(!ziez.isValidUUID("550e8400-e29b-41d4-a716"));
    try std.testing.expect(!ziez.isValidUUID("550e8400-e29b-41d4-a716-44665544000G"));
    try std.testing.expect(!ziez.isValidUUID(""));
}

test "paramInt: parses valid integer param" {
    const allocator = std.testing.allocator;
    test_captured_id = 0;
    const wrapped = ziez.paramInt("id", u64, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, id: u64) anyerror!void {
            test_captured_id = id;
            _ = res.status(200);
        }
    }.handler);

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    req.params.names[0] = "id";
    req.params.values[0] = "42";
    req.params.len = 1;
    var res = ziez.Response.init(allocator);
    try wrapped(&req, &res);
    try std.testing.expectEqual(@as(u64, 42), test_captured_id);
}

test "paramInt: rejects non-numeric param" {
    const allocator = std.testing.allocator;
    const wrapped = ziez.paramInt("id", u64, struct {
        fn handler(_: *ziez.Request, _: *ziez.Response, _: u64) anyerror!void {}
    }.handler);

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    req.params.names[0] = "id";
    req.params.values[0] = "abc";
    req.params.len = 1;
    var res = ziez.Response.init(allocator);
    try std.testing.expectError(error.BadRequest, wrapped(&req, &res));
}

test "paramInt: rejects missing param" {
    const allocator = std.testing.allocator;
    const wrapped = ziez.paramInt("id", u64, struct {
        fn handler(_: *ziez.Request, _: *ziez.Response, _: u64) anyerror!void {}
    }.handler);

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(allocator);
    try std.testing.expectError(error.BadRequest, wrapped(&req, &res));
}

test "parseBool: parses true/false" {
    const allocator = std.testing.allocator;
    test_captured_bool = false;

    const wrapped = ziez.parseBool("active", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, val: bool) anyerror!void {
            test_captured_bool = val;
            _ = res.status(200);
        }
    }.handler);

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    req.params.names[0] = "active";
    req.params.values[0] = "true";
    req.params.len = 1;
    var res = ziez.Response.init(allocator);
    try wrapped(&req, &res);
    try std.testing.expect(test_captured_bool);

    req.params.values[0] = "false";
    res.reset();
    try wrapped(&req, &res);
    try std.testing.expect(!test_captured_bool);

    req.params.values[0] = "yes";
    res.reset();
    try std.testing.expectError(error.BadRequest, wrapped(&req, &res));
}

test "validateBody: parses valid JSON body" {
    const allocator = std.testing.allocator;
    const Body = struct { name: []const u8 };
    test_captured_name = "";

    const wrapped = ziez.validateBody(Body, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, body: Body) anyerror!void {
            test_captured_name = body.name;
            _ = res.status(200);
        }
    }.handler);

    var req = ziez.Request{
        .method = .POST,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "{\"name\":\"Alice\"}",
        .allocator = allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(allocator);
    try wrapped(&req, &res);
    try std.testing.expectEqualStrings("Alice", test_captured_name);
}

test "validateBody: rejects empty body" {
    const allocator = std.testing.allocator;
    const Body = struct { name: []const u8 };

    const wrapped = ziez.validateBody(Body, struct {
        fn handler(_: *ziez.Request, _: *ziez.Response, _: Body) anyerror!void {}
    }.handler);

    var req = ziez.Request{
        .method = .POST,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(allocator);
    try std.testing.expectError(error.BadRequest, wrapped(&req, &res));
}

test "validateBodyWith: passes valid body" {
    const allocator = std.testing.allocator;
    const Body = struct { name: []const u8 };

    const isValid = struct {
        fn call(body: Body) bool {
            return body.name.len >= 3;
        }
    }.call;

    test_captured_name = "";
    const wrapped = ziez.validateBodyWith(Body, isValid, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, body: Body) anyerror!void {
            test_captured_name = body.name;
            _ = res.status(200);
        }
    }.handler);

    var req = ziez.Request{
        .method = .POST,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "{\"name\":\"Alice\"}",
        .allocator = allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(allocator);
    try wrapped(&req, &res);
    try std.testing.expectEqualStrings("Alice", test_captured_name);
}

test "validateBodyWith: rejects body failing validation" {
    const allocator = std.testing.allocator;
    const Body = struct { name: []const u8 };

    const isValid = struct {
        fn call(body: Body) bool {
            return body.name.len >= 3;
        }
    }.call;

    const wrapped = ziez.validateBodyWith(Body, isValid, struct {
        fn handler(_: *ziez.Request, _: *ziez.Response, _: Body) anyerror!void {}
    }.handler);

    var req = ziez.Request{
        .method = .POST,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "{\"name\":\"AB\"}",
        .allocator = allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    var res = ziez.Response.init(allocator);
    try std.testing.expectError(error.UnprocessableEntity, wrapped(&req, &res));
}

test "pipeParam: transforms param with custom function" {
    const allocator = std.testing.allocator;

    const toUpper = struct {
        fn call(raw: []const u8) anyerror![]const u8 {
            return raw;
        }
    }.call;

    test_captured_val = "";
    const wrapped = ziez.pipeParam("name", toUpper, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, val: []const u8) anyerror!void {
            test_captured_val = val;
            _ = res.status(200);
        }
    }.handler);

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    req.params.names[0] = "name";
    req.params.values[0] = "hello";
    req.params.len = 1;
    var res = ziez.Response.init(allocator);
    try wrapped(&req, &res);
    try std.testing.expectEqualStrings("hello", test_captured_val);
}

test "queryInt: parses valid query param" {
    const allocator = std.testing.allocator;
    test_captured_page = 0;

    const wrapped = ziez.queryInt("page", u32, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, page: u32) anyerror!void {
            test_captured_page = page;
            _ = res.status(200);
        }
    }.handler);

    var req = ziez.Request{
        .method = .GET,
        .path = "/test",
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = allocator,
        .head_buffer = "",
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
    req.query.keys[0] = "page";
    req.query.vals[0] = "3";
    req.query.len = 1;
    var res = ziez.Response.init(allocator);
    try wrapped(&req, &res);
    try std.testing.expectEqual(@as(u32, 3), test_captured_page);
}
