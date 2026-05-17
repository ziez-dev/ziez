const std = @import("std");
const ziez = @import("ziez");

const Capture = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) Capture {
        return .{
            .allocator = allocator,
            .buf = .empty,
        };
    }

    fn deinit(self: *Capture) void {
        self.buf.deinit(self.allocator);
    }

    fn sink(self: *Capture) ziez.LogSink {
        return .{
            .context = self,
            .writeFn = write,
        };
    }

    fn write(ctx: ?*anyopaque, _: ziez.LogLevel, line: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        self.buf.appendSlice(self.allocator, line) catch unreachable;
    }
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn makeRequest(method: ziez.HttpMethod, path: []const u8, req_id: []const u8, head_buffer: []const u8) ziez.Request {
    return .{
        .method = method,
        .path = path,
        .request_id = req_id,
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = std.testing.allocator,
        .head_buffer = head_buffer,
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
}

const okHandler: ziez.HandlerFn = struct {
    fn handler(_: *ziez.Request, res: *ziez.Response) anyerror!void {
        res.status(200).send("ok");
    }
}.handler;

const passMiddleware: ziez.MiddlewareFn = struct {
    fn handler(_: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
        next.call();
    }
}.handler;

test "Logger emits JSON and redacts nested fields" {
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();

    var logger = ziez.Logger.init(std.testing.allocator, .{
        .level = .trace,
        .redact = &.{ "req.headers.authorization", "body.password" },
        .sink = capture.sink(),
    });
    defer logger.deinit();

    logger.infoFields(.{
        .req = .{
            .headers = .{
                .authorization = "Bearer secret",
                .accept = "application/json",
            },
        },
        .body = .{
            .password = "secret123",
            .username = "john",
        },
    }, "login attempt");

    try std.testing.expect(contains(capture.buf.items, "\"level\":\"info\""));
    try std.testing.expect(contains(capture.buf.items, "\"msg\":\"login attempt\""));
    try std.testing.expect(contains(capture.buf.items, "\"authorization\":\"[REDACTED]\""));
    try std.testing.expect(contains(capture.buf.items, "\"password\":\"[REDACTED]\""));
    try std.testing.expect(contains(capture.buf.items, "\"username\":\"john\""));
    try std.testing.expect(!contains(capture.buf.items, "secret123"));
}

test "Logger child merges bindings into output" {
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();

    var logger = ziez.Logger.init(std.testing.allocator, .{
        .level = .debug,
        .sink = capture.sink(),
    });
    defer logger.deinit();

    const child = logger.child(.{ .service = "OrderService", .region = "ap-southeast-1" });
    child.infoFields(.{ .order_id = "ord_123" }, "order created");

    try std.testing.expect(contains(capture.buf.items, "\"service\":\"OrderService\""));
    try std.testing.expect(contains(capture.buf.items, "\"region\":\"ap-southeast-1\""));
    try std.testing.expect(contains(capture.buf.items, "\"order_id\":\"ord_123\""));
}

test "App logging defaults: level is info" {
    var app = ziez.App.init(std.testing.allocator);
    defer app.deinit();

    const cfg = app.logger.getConfig();
    try std.testing.expectEqual(ziez.LogLevel.info, cfg.level);
}

test "Router lifecycle trace emits middleware and handler events" {
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();

    var router = ziez.Router.init(std.testing.allocator);
    defer router.deinit();
    router.lifecycle_trace = true;
    router.logger.configure(.{
        .level = .debug,
        .sink = capture.sink(),
    });
    router.use(passMiddleware);
    router.get("/items/:id", okHandler);

    var req = makeRequest(
        .GET,
        "/items/42",
        "req-lifecycle",
        "GET /items/42 HTTP/1.1\r\n\r\n",
    );
    var res = ziez.Response.init(std.testing.allocator);

    router.handle(&req, &res);

    try std.testing.expect(contains(capture.buf.items, "\"event\":\"route_matched\""));
    try std.testing.expect(contains(capture.buf.items, "\"event\":\"middleware_enter\""));
    try std.testing.expect(contains(capture.buf.items, "\"event\":\"middleware_exit\""));
    try std.testing.expect(contains(capture.buf.items, "\"event\":\"handler_enter\""));
    try std.testing.expect(contains(capture.buf.items, "\"event\":\"handler_exit\""));
    try std.testing.expect(contains(capture.buf.items, "\"req_id\":\"req-lifecycle\""));
}
