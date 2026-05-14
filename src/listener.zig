const std = @import("std");
const http = std.http;
const net = std.Io.net;
const Router = @import("router.zig").Router;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const compression = @import("compression.zig");

pub fn listenAndServe(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: []const u8,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
) !void {
    const ip_addr = try net.IpAddress.parseLiteral(address);
    var server = try ip_addr.listen(io, .{});
    defer server.deinit(io);

    std.debug.print("ziez: listening on {s}\n", .{address});

    while (true) {
        const stream = server.accept(io) catch |e| {
            std.debug.print("ziez: accept error: {}\n", .{e});
            continue;
        };

        spawnThread(allocator, stream, router, compression_config) catch |e| {
            std.debug.print("ziez: thread spawn error: {}\n", .{e});
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
) !void {
    _ = try std.Thread.spawn(.{}, handleConnection, .{ allocator, stream, router, compression_config });
}

const MAX_BODY = 10 * 1024 * 1024; // 10MB

fn handleConnection(
    allocator: std.mem.Allocator,
    stream: net.Stream,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
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
                std.debug.print("ziez: receive head error: {}\n", .{e});
            }
            return;
        };

        // Parse request metadata from head
        var req = Request.initFromHead(allocator, http_req.head_buffer) catch |e| {
            std.debug.print("ziez: request parse error: {}\n", .{e});
            return;
        };

        // Read body if present
        readBody(allocator, &http_req, &req) catch |e| {
            std.debug.print("ziez: body read error: {}\n", .{e});
            // Continue without body - handler can still respond
        };

        var res = Response.init(allocator);
        res.server_request = &http_req;
        res.compression_config = compression_config;

        // Handle request with error recovery
        router.handle(&req, &res);

        // Ensure a response is sent
        if (!res.sent) {
            res.status(500).json(.{ .@"error" = "internal server error" });
        }

        // Cleanup request body allocation
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
            std.debug.print("ziez: body read error: {}\n", .{e});
            break;
        };
        if (chunk.len == 0) break;
        @memcpy(body_buf[total .. total + chunk.len], chunk);
        total += chunk.len;
    }

    req.body_raw = body_buf[0..total];
    req.owns_body = true;
}
