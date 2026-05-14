const std = @import("std");
const http = std.http;
const net = std.Io.net;
const logging = @import("logging.zig");
const Router = @import("router.zig").Router;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const compression = @import("compression.zig");

var next_request_id: std.atomic.Value(u64) = .init(1);

pub fn listenAndServe(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: []const u8,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
    logger: logging.Logger,
) !void {
    const ip_addr = try net.IpAddress.parseLiteral(address);
    var server = try ip_addr.listen(io, .{});
    defer server.deinit(io);

    logger.infoFields(.{
        .component = "listener",
        .event = "server_listening",
        .address = address,
        .route_count = router.routes.items.len,
        .middleware_count = router.mw.items.items.len,
        .interceptor_count = router.global_interceptors.items.len,
        .compression_enabled = compression_config != null,
    }, "server listening");

    while (true) {
        const stream = server.accept(io) catch |e| {
            logger.errorFields(.{
                .component = "listener",
                .event = "accept_failed",
                .@"error" = @errorName(e),
            }, "accept failed");
            continue;
        };

        spawnThread(allocator, stream, router, compression_config, logger) catch |e| {
            logger.errorFields(.{
                .component = "listener",
                .event = "thread_spawn_failed",
                .@"error" = @errorName(e),
            }, "thread spawn failed");
            stream.close(io);
            continue;
        };
    }
}

fn spawnThread(
    allocator: std.mem.Allocator,
    stream: net.Stream,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
    logger: logging.Logger,
) !void {
    _ = try std.Thread.spawn(.{}, handleConnection, .{ allocator, stream, router, compression_config, logger });
}

const MAX_BODY = 10 * 1024 * 1024; // 10MB

fn handleConnection(
    allocator: std.mem.Allocator,
    stream: net.Stream,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
    logger: logging.Logger,
) void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer stream.close(threaded.io());

    const io = threaded.io();

    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;

    var net_reader = stream.reader(io, &read_buf);
    var net_writer = stream.writer(io, &write_buf);

    var http_server = http.Server.init(&net_reader.interface, &net_writer.interface);

    while (true) {
        var http_req = http_server.receiveHead() catch |e| {
            if (e != error.EndOfStream and e != error.HttpConnectionClosing) {
                logger.errorFields(.{
                    .component = "listener",
                    .event = "receive_head_failed",
                    .@"error" = @errorName(e),
                }, "receive head failed");
            }
            return;
        };

        // Parse request metadata from head
        var req = Request.initFromHead(allocator, http_req.head_buffer) catch |e| {
            logger.errorFields(.{
                .component = "listener",
                .event = "request_parse_failed",
                .@"error" = @errorName(e),
            }, "request parse failed");
            return;
        };
        req.assignRequestId(next_request_id.fetchAdd(1, .monotonic));
        const started_ns = monotonicTimeNs();

        if (logger.lifecycleTraceEnabled()) {
            logger.debugFields(.{
                .component = "listener",
                .event = "request_started",
                .req_id = req.request_id,
                .method = @tagName(req.method),
                .path = req.path,
            }, "request started");
        }

        // Read body if present
        readBody(allocator, &http_req, &req) catch |e| {
            logger.errorFields(.{
                .component = "listener",
                .event = "body_read_failed",
                .req_id = req.request_id,
                .path = req.path,
                .@"error" = @errorName(e),
            }, "body read failed");
            // Continue without body - handler can still respond
        };

        var res = Response.init(allocator);
        res.server_request = &http_req;
        res.compression_config = compression_config;
        res.logger = logger;
        res.request_id = req.request_id;

        // Handle request with error recovery
        router.handle(&req, &res);

        // Ensure a response is sent
        if (!res.sent) {
            res.status(500).json(.{ .@"error" = "internal server error" });
        }

        // Cleanup request body allocation
        if (logger.autoRequestLogEnabled()) {
            var content_length: ?u64 = null;
            if (req.header("content-length")) |raw| {
                content_length = std.fmt.parseInt(u64, raw, 10) catch null;
            }

            const elapsed_ns = monotonicTimeNs() - started_ns;
            logger.logRequestSummary(.{
                .req_id = req.request_id,
                .method = @tagName(req.method),
                .path = req.path,
                .status = res.status_code,
                .response_time_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
                .user_agent = req.header("user-agent"),
                .content_length = content_length,
            });
        }

        req.deinit();

        net_writer.interface.flush() catch return;
    }
}

fn readBody(
    allocator: std.mem.Allocator,
    http_req: *http.Server.Request,
    req: *Request,
) !void {
    if (!http_req.head.method.requestHasBody()) return;

    const content_length = http_req.head.content_length orelse return;
    if (content_length == 0 or content_length > MAX_BODY) return;

    // We need a buffer for the body reader's internal use
    var body_reader_buf: [4096]u8 = undefined;
    const body_reader = http_req.readerExpectNone(&body_reader_buf);

    // Allocate buffer for body
    var body_buf = try allocator.alloc(u8, @intCast(content_length));
    var total: usize = 0;

    // Read all body bytes
    while (total < content_length) {
        const remaining = content_length - total;
        const to_read: usize = @min(remaining, body_reader_buf.len);
        const chunk = body_reader.take(to_read) catch |e| {
            return e;
        };
        if (chunk.len == 0) break;
        @memcpy(body_buf[total .. total + chunk.len], chunk);
        total += chunk.len;
    }

    req.body_raw = body_buf[0..total];
    req.owns_body = true;
}

fn monotonicTimeNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, @intCast(ts.sec)) * 1_000_000_000 + @as(i128, @intCast(ts.nsec));
}
