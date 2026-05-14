const std = @import("std");
const http = std.http;
const net = std.Io.net;
const logging = @import("logging.zig");
const Router = @import("router.zig").Router;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const compression = @import("compression.zig");
const tls_mod = @import("tls.zig");

var next_request_id: std.atomic.Value(u64) = .init(1);

pub fn listenAndServe(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: []const u8,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
    logger: logging.Logger,
    tls_runtime: ?*tls_mod.TlsRuntime,
    redirect_http: ?tls_mod.RedirectHttpConfig,
) !void {
    const ip_addr = try net.IpAddress.parseLiteral(address);
    var server = try ip_addr.listen(io, .{});
    defer server.deinit(io);

    if (tls_runtime != null and redirect_http != null) {
        try spawnRedirectListener(
            allocator,
            address,
            ip_addr.getPort(),
            router,
            compression_config,
            logger,
            redirect_http.?,
        );
    }

    logger.infoFields(.{
        .component = "listener",
        .event = "server_listening",
        .address = address,
        .route_count = router.routes.items.len,
        .middleware_count = router.mw.items.items.len,
        .interceptor_count = router.global_interceptors.items.len,
        .compression_enabled = compression_config != null,
        .tls_enabled = tls_runtime != null,
        .redirect_http_enabled = redirect_http != null,
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

        if (tls_runtime) |runtime| {
            spawnTlsThread(allocator, stream, router, compression_config, logger, runtime) catch |e| {
                logger.errorFields(.{
                    .component = "listener",
                    .event = "thread_spawn_failed",
                    .@"error" = @errorName(e),
                }, "thread spawn failed");
                stream.close(io);
                continue;
            };
        } else {
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

fn spawnTlsThread(
    allocator: std.mem.Allocator,
    stream: net.Stream,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
    logger: logging.Logger,
    tls_runtime: *tls_mod.TlsRuntime,
) !void {
    _ = try std.Thread.spawn(.{}, handleTlsConnection, .{ allocator, stream, router, compression_config, logger, tls_runtime });
}

fn spawnRedirectListener(
    allocator: std.mem.Allocator,
    address: []const u8,
    https_port: u16,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
    logger: logging.Logger,
    redirect_http: tls_mod.RedirectHttpConfig,
) !void {
    const owned_address = try allocator.dupe(u8, address);
    errdefer allocator.free(owned_address);

    _ = try std.Thread.spawn(.{}, runRedirectListener, .{
        allocator,
        owned_address,
        https_port,
        router,
        compression_config,
        logger,
        redirect_http,
    });
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

    processRequests(allocator, &http_server, router, compression_config, logger, false, null, null, null);
}

fn handleTlsConnection(
    allocator: std.mem.Allocator,
    stream: net.Stream,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
    logger: logging.Logger,
    tls_runtime: *tls_mod.TlsRuntime,
) void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer stream.close(threaded.io());

    const io = threaded.io();

    var read_buf: [tls_max_buffer_len]u8 = undefined;
    var write_buf: [tls_max_buffer_len]u8 = undefined;

    var net_reader = stream.reader(io, &read_buf);
    var net_writer = stream.writer(io, &write_buf);

    var lease = tls_runtime.acquire() orelse {
        logger.errorFields(.{
            .component = "listener",
            .event = "tls_context_missing",
        }, "TLS context missing");
        return;
    };
    defer lease.release();

    const tls_context = lease.context();

    var entropy: [tls_mod.server_entropy_len]u8 = undefined;
    std.crypto.random.bytes(&entropy);

    var tls_server = tls_mod.server.init(
        &net_reader.interface,
        &net_writer.interface,
        .{
            .tls_context = tls_context,
            .write_buffer = &write_buf,
            .read_buffer = &read_buf,
            .entropy = &entropy,
            .realtime_now = std.Io.Timestamp.now(io, .real),
        },
    ) catch |e| {
        logger.errorFields(.{
            .component = "listener",
            .event = "tls_handshake_failed",
            .@"error" = @errorName(e),
        }, "TLS handshake failed");
        return;
    };
    defer tls_server.end() catch {};

    // After handshake, use the TLS server's decrypted reader/writer
    // to feed into the HTTP server
    var tls_reader = tls_server.reader;
    var tls_writer = tls_server.writer;

    var http_server = http.Server.init(&tls_reader, &tls_writer);

    const sni_val = tls_server.sni_hostname orelse "unknown";
    processRequests(allocator, &http_server, router, compression_config, logger, true, sni_val, tls_context, null);
}

fn runRedirectListener(
    allocator: std.mem.Allocator,
    owned_address: []u8,
    https_port: u16,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
    logger: logging.Logger,
    redirect_http: tls_mod.RedirectHttpConfig,
) void {
    defer allocator.free(owned_address);

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var ip_addr = net.IpAddress.parseLiteral(owned_address) catch |e| {
        logger.errorFields(.{
            .component = "listener",
            .event = "redirect_address_parse_failed",
            .@"error" = @errorName(e),
            .address = owned_address,
        }, "redirect address parse failed");
        return;
    };
    ip_addr.setPort(redirect_http.port);

    var server = ip_addr.listen(io, .{}) catch |e| {
        logger.errorFields(.{
            .component = "listener",
            .event = "redirect_listener_failed",
            .@"error" = @errorName(e),
            .address = owned_address,
            .port = redirect_http.port,
        }, "redirect listener failed");
        return;
    };
    defer server.deinit(io);

    logger.infoFields(.{
        .component = "listener",
        .event = "redirect_listener_listening",
        .address = owned_address,
        .http_port = redirect_http.port,
        .https_port = redirect_http.to orelse https_port,
    }, "redirect listener listening");

    while (true) {
        const stream = server.accept(io) catch |e| {
            logger.errorFields(.{
                .component = "listener",
                .event = "redirect_accept_failed",
                .@"error" = @errorName(e),
            }, "redirect accept failed");
            continue;
        };

        _ = std.Thread.spawn(.{}, handleRedirectConnection, .{
            allocator,
            stream,
            router,
            compression_config,
            logger,
            RedirectPlan{
                .config = redirect_http,
                .https_port = redirect_http.to orelse https_port,
                .fallback_host = owned_address,
            },
        }) catch |e| {
            logger.errorFields(.{
                .component = "listener",
                .event = "redirect_thread_spawn_failed",
                .@"error" = @errorName(e),
            }, "redirect thread spawn failed");
            stream.close(io);
        };
    }
}

const tls_max_buffer_len = std.crypto.tls.max_ciphertext_record_len;

const RedirectPlan = struct {
    config: tls_mod.RedirectHttpConfig,
    https_port: u16,
    fallback_host: []const u8,
};

fn handleRedirectConnection(
    allocator: std.mem.Allocator,
    stream: net.Stream,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
    logger: logging.Logger,
    redirect_plan: RedirectPlan,
) void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer stream.close(threaded.io());

    const io = threaded.io();

    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;

    var net_reader = stream.reader(io, &read_buf);
    var net_writer = stream.writer(io, &write_buf);

    var http_server = http.Server.init(&net_reader.interface, &net_writer.interface);
    processRequests(allocator, &http_server, router, compression_config, logger, false, null, null, redirect_plan);
}

fn processRequests(
    allocator: std.mem.Allocator,
    http_server: *http.Server,
    router: *Router,
    compression_config: ?compression.CompressionConfig,
    logger: logging.Logger,
    is_tls: bool,
    sni: ?[]const u8,
    tls_context: ?*const tls_mod.TlsContext,
    redirect_plan: ?RedirectPlan,
) void {
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
        req.tls = is_tls;
        if (is_tls and sni != null) {
            req.tls_version = "TLSv1.3";
            req.client_cert_subject = if (tls_context != null and tls_context.?.client_auth != .none) null else null;
        }
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

        if (redirect_plan) |plan| {
            if (plan.config.shouldRedirect(req.path)) {
                const location = buildRedirectLocation(
                    allocator,
                    req.header("host"),
                    plan.fallback_host,
                    plan.https_port,
                    http_req.head.target,
                ) catch null;
                defer if (location) |owned| allocator.free(owned);

                var res = Response.init(allocator);
                res.server_request = &http_req;
                res.logger = logger;
                res.request_id = req.request_id;
                _ = res.status(308);
                if (location) |loc| _ = res.set("location", loc);
                res.sendBody("");

                if (logger.autoRequestLogEnabled()) {
                    const elapsed_ns = monotonicTimeNs() - started_ns;
                    logger.logRequestSummary(.{
                        .req_id = req.request_id,
                        .method = @tagName(req.method),
                        .path = req.path,
                        .status = res.status_code,
                        .response_time_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
                        .user_agent = req.header("user-agent"),
                        .content_length = null,
                    });
                }

                req.deinit();
                continue;
            }
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
        };

        var res = Response.init(allocator);
        res.server_request = &http_req;
        res.compression_config = compression_config;
        res.logger = logger;
        res.request_id = req.request_id;

        router.handle(&req, &res);

        if (!res.sent) {
            res.status(500).json(.{ .@"error" = "internal server error" });
        }

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
    }
}

fn buildRedirectLocation(
    allocator: std.mem.Allocator,
    host_header: ?[]const u8,
    fallback_host: []const u8,
    https_port: u16,
    target: []const u8,
) ![]u8 {
    const host = sanitizeRedirectHost(host_header orelse fallback_host, fallback_host);
    if (https_port == 443) {
        return std.fmt.allocPrint(allocator, "https://{s}{s}", .{ host, target });
    }
    return std.fmt.allocPrint(allocator, "https://{s}:{d}{s}", .{ host, https_port, target });
}

fn sanitizeRedirectHost(raw: []const u8, fallback_host: []const u8) []const u8 {
    if (raw.len == 0) return stripPort(fallback_host);
    return stripPort(raw);
}

fn stripPort(host: []const u8) []const u8 {
    if (host.len == 0) return host;

    if (host[0] == '[') {
        const end = std.mem.indexOfScalar(u8, host, ']') orelse return host;
        return host[0 .. end + 1];
    }

    const first = std.mem.indexOfScalar(u8, host, ':');
    const last = std.mem.lastIndexOfScalar(u8, host, ':');
    if (first != null and last != null and first.? == last.?) {
        return host[0..first.?];
    }
    return host;
}

fn readBody(
    allocator: std.mem.Allocator,
    http_req: *http.Server.Request,
    req: *Request,
) !void {
    if (!http_req.head.method.requestHasBody()) return;

    const content_length = http_req.head.content_length orelse return;
    if (content_length == 0 or content_length > MAX_BODY) return;

    var body_reader_buf: [4096]u8 = undefined;
    const body_reader = http_req.readerExpectNone(&body_reader_buf);

    var body_buf = try allocator.alloc(u8, @intCast(content_length));
    var total: usize = 0;

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
