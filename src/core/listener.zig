const std = @import("std");
const http = std.http;
const net = std.Io.net;
const logging = @import("logging.zig");
const platform = @import("platform.zig");
const Router = @import("router.zig").Router;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// Function pointer type for per-request logging. No feature module references.
/// Args: logger, request_id, method, path, status, elapsed_ms, user_agent, content_length.
pub const LogRequestFn = *const fn (logging.Logger, []const u8, []const u8, []const u8, u16, f64, ?[]const u8, ?u64) void;

/// Type-erased per-connection configuration. No feature module references.
pub const ConnConfig = struct {
    compression_config: ?*anyopaque = null,
    compress_fn: ?*const fn (*anyopaque, []const u8, *Response) bool = null,
    log_request_fn: ?LogRequestFn = null,
};

/// Default built-in request logger — no tracker import, always safe to set as default.
pub fn defaultLogRequestFn(
    logger: logging.Logger,
    _: []const u8,
    method: []const u8,
    path: []const u8,
    status: u16,
    elapsed_ms: f64,
    _: ?[]const u8,
    _: ?u64,
) void {
    logger.infoFields(.{
        .event = "request_completed",
        .method = method,
        .path = path,
        .status = status,
        .elapsed_ms = elapsed_ms,
    }, "request completed");
}

/// Function pointer type for TLS connection handling (set from app.tls() lazily).
pub const TlsHandleFn = *const fn (std.mem.Allocator, net.Stream, *Router, ConnConfig, logging.Logger, *anyopaque) void;

/// Function pointer type for HTTP→HTTPS redirect listener (set from app.redirectHttp() lazily).
pub const RedirectRunFn = *const fn (std.mem.Allocator, []const u8, u16, *Router, ConnConfig, logging.Logger, *anyopaque) void;

var next_request_id: std.atomic.Value(u64) = .init(1);

// ---------------------------------------------------------------------------
// Thread Pool — bounded MPSC channel for connection dispatch
// ---------------------------------------------------------------------------

/// A bounded, thread-safe channel used to dispatch accepted connections from
/// the main accept thread to a fixed pool of worker threads.
const ConnectionChannel = struct {
    mutex: std.Io.Mutex,
    not_empty: std.Io.Condition,
    not_full: std.Io.Condition,
    items: []?net.Stream,
    head: usize,
    count: usize,
    capacity: usize,
    closed: bool,

    fn init(allocator: std.mem.Allocator, capacity: usize) !*ConnectionChannel {
        const items = try allocator.alloc(?net.Stream, capacity);
        @memset(items, null);
        const ch = try allocator.create(ConnectionChannel);
        ch.* = .{
            .mutex = .init,
            .not_empty = .init,
            .not_full = .init,
            .items = items,
            .head = 0,
            .count = 0,
            .capacity = capacity,
            .closed = false,
        };
        return ch;
    }

    fn deinit(self: *ConnectionChannel, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        allocator.destroy(self);
    }

    /// Push a connection. Blocks the caller if the channel is full.
    fn push(self: *ConnectionChannel, stream: net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.count >= self.capacity) {
            self.not_full.waitUncancelable(io, &self.mutex);
        }

        const tail = (self.head + self.count) % self.capacity;
        self.items[tail] = stream;
        self.count += 1;
        self.not_empty.signal(io);
    }

    /// Pop a connection. Blocks the caller if the channel is empty.
    /// Returns null when the channel has been closed and drained.
    fn pop(self: *ConnectionChannel, io: std.Io) ?net.Stream {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.count == 0) {
            if (self.closed) return null;
            self.not_empty.waitUncancelable(io, &self.mutex);
        }

        const stream = self.items[self.head].?;
        self.items[self.head] = null;
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
        self.not_full.signal(io);
        return stream;
    }

    /// Signal all workers that no more connections will arrive.
    fn close(self: *ConnectionChannel, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        self.not_empty.broadcast(io);
    }
};

fn defaultWorkerCount() usize {
    return @max(2, (std.Thread.getCpuCount() catch 2) * 2);
}

const WorkerContext = struct {
    channel: *ConnectionChannel,
    router: *Router,
    conn_config: ConnConfig,
    logger: logging.Logger,
    tls_runtime: ?*anyopaque,
    handle_tls_conn: ?TlsHandleFn,
};

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn listenAndServe(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: []const u8,
    router: *Router,
    conn_config: ConnConfig,
    logger: logging.Logger,
    tls_runtime: ?*anyopaque,
    handle_tls_conn: ?TlsHandleFn,
    redirect_config: ?*anyopaque,
    run_redirect: ?RedirectRunFn,
) !void {
    const ip_addr = try net.IpAddress.parseLiteral(address);
    var server = try ip_addr.listen(io, .{});
    defer server.deinit(io);

    if (tls_runtime != null and redirect_config != null) {
        try spawnRedirectListener(
            allocator,
            address,
            ip_addr.getPort(),
            router,
            conn_config,
            logger,
            redirect_config.?,
            run_redirect.?,
        );
    }

    // --- Thread pool setup ---
    const worker_count = defaultWorkerCount();
    const channel_capacity = worker_count * 4;
    const channel = try ConnectionChannel.init(allocator, channel_capacity);
    defer channel.deinit(allocator);

    logger.infoFields(.{
        .component = "listener",
        .event = "server_listening",
        .address = address,
        .route_count = router.routeCount(),
        .middleware_count = router.mw.items.items.len,
        .interceptor_count = router.global_interceptors.items.len,
        .compression_enabled = conn_config.compression_config != null,
        .tls_enabled = tls_runtime != null,
        .redirect_http_enabled = redirect_config != null,
        .worker_count = worker_count,
        .channel_capacity = channel_capacity,
    }, "server listening");

    // Spawn worker threads
    const workers: []std.Thread = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(workers);

    var ctx = WorkerContext{
        .channel = channel,
        .router = router,
        .conn_config = conn_config,
        .logger = logger,
        .tls_runtime = tls_runtime,
        .handle_tls_conn = handle_tls_conn,
    };

    var spawned_count: usize = 0;
    for (workers) |*worker| {
        worker.* = std.Thread.spawn(.{}, workerLoop, .{&ctx}) catch |e| {
            logger.errorFields(.{
                .component = "listener",
                .event = "worker_spawn_failed",
                .@"error" = @errorName(e),
            }, "worker spawn failed");
            continue;
        };
        spawned_count += 1;
    }

    if (spawned_count == 0) {
        return error.NoWorkersSpawned;
    }

    // Main accept loop: accept connections and dispatch to the channel
    while (true) {
        const stream = server.accept(io) catch |e| {
            logger.errorFields(.{
                .component = "listener",
                .event = "accept_failed",
                .@"error" = @errorName(e),
            }, "accept failed");
            continue;
        };

        channel.push(stream, io);
    }
}

// ---------------------------------------------------------------------------
// Worker loop
// ---------------------------------------------------------------------------

fn workerLoop(ctx: *WorkerContext) void {
    // Each worker creates its own Io.Threaded for I/O operations.
    const allocator = ctx.router.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    while (true) {
        const stream = ctx.channel.pop(io) orelse return;

        if (ctx.tls_runtime) |runtime| {
            if (ctx.handle_tls_conn) |handle_fn| {
                handle_fn(allocator, stream, ctx.router, ctx.conn_config, ctx.logger, runtime);
            }
            continue;
        }
        handlePlainConnection(allocator, stream, ctx.router, ctx.conn_config, ctx.logger);
    }
}

// ---------------------------------------------------------------------------
// Redirect listener (unchanged — single dedicated thread)
// ---------------------------------------------------------------------------

const RedirectArgs = struct {
    run_fn: RedirectRunFn,
    allocator: std.mem.Allocator,
    owned_address: []const u8,
    https_port: u16,
    router: *Router,
    conn_config: ConnConfig,
    logger: logging.Logger,
    config_ptr: *anyopaque,
};

fn runRedirectThread(args_ptr: *RedirectArgs) void {
    const args = args_ptr.*;
    args.allocator.destroy(args_ptr);
    args.run_fn(args.allocator, args.owned_address, args.https_port, args.router, args.conn_config, args.logger, args.config_ptr);
}

fn spawnRedirectListener(
    allocator: std.mem.Allocator,
    address: []const u8,
    https_port: u16,
    router: *Router,
    conn_config: ConnConfig,
    logger: logging.Logger,
    redirect_config_ptr: *anyopaque,
    run_fn: RedirectRunFn,
) !void {
    const owned_address = try allocator.dupe(u8, address);
    errdefer allocator.free(owned_address);

    const args = try allocator.create(RedirectArgs);
    args.* = .{
        .run_fn = run_fn,
        .allocator = allocator,
        .owned_address = owned_address,
        .https_port = https_port,
        .router = router,
        .conn_config = conn_config,
        .logger = logger,
        .config_ptr = redirect_config_ptr,
    };

    _ = try std.Thread.spawn(.{}, runRedirectThread, .{args});
}

// ---------------------------------------------------------------------------
// Connection handlers
// ---------------------------------------------------------------------------

const MAX_BODY = 10 * 1024 * 1024; // 10MB

fn handlePlainConnection(
    allocator: std.mem.Allocator,
    stream: net.Stream,
    router: *Router,
    conn_config: ConnConfig,
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

    processRequests(allocator, &http_server, router, conn_config, logger, false, null, null);
}

/// Only analyzed when app.tls() is called — TlsMod only compiles when TLS is used.
pub fn handleTlsConnection(
    allocator: std.mem.Allocator,
    stream: net.Stream,
    router: *Router,
    conn_config: ConnConfig,
    logger: logging.Logger,
    tls_runtime_ptr: *anyopaque,
) void {
    const TlsMod = @import("../tls/mod.zig");
    const tls_runtime: *TlsMod.TlsRuntime = @ptrCast(@alignCast(tls_runtime_ptr));

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer stream.close(threaded.io());

    const io = threaded.io();

    var read_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
    var write_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;

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

    var entropy: [TlsMod.server_entropy_len]u8 = undefined;
    platform.fillRandomBytes(&entropy);

    var tls_server = TlsMod.server.init(
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

    var tls_reader = tls_server.reader;
    var tls_writer = tls_server.writer;

    var http_server = http.Server.init(&tls_reader, &tls_writer);

    const sni_val = tls_server.sni_hostname orelse "unknown";
    processRequests(allocator, &http_server, router, conn_config, logger, true, sni_val, null);
}

// ---------------------------------------------------------------------------
// Redirect listener (runs in its own thread)
// ---------------------------------------------------------------------------

/// Only analyzed when app.redirectHttp() is called — TlsMod only compiles when redirect+TLS is used.
pub fn runRedirectListenerFn(
    allocator: std.mem.Allocator,
    owned_address: []const u8,
    https_port: u16,
    router: *Router,
    conn_config: ConnConfig,
    logger: logging.Logger,
    redirect_config_ptr: *anyopaque,
) void {
    const TlsMod = @import("../tls/mod.zig");
    const redirect_http: *const TlsMod.RedirectHttpConfig = @ptrCast(@alignCast(redirect_config_ptr));

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

    const shouldRedirectFn = struct {
        fn f(ptr: *anyopaque, path: []const u8) bool {
            const TM = @import("../tls/mod.zig");
            return (@as(*const TM.RedirectHttpConfig, @ptrCast(@alignCast(ptr)))).shouldRedirect(path);
        }
    }.f;

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
            conn_config,
            logger,
            RedirectPlan{
                .should_redirect_fn = shouldRedirectFn,
                .config_ptr = redirect_config_ptr,
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

const RedirectPlan = struct {
    should_redirect_fn: *const fn (*anyopaque, []const u8) bool,
    config_ptr: *anyopaque,
    https_port: u16,
    fallback_host: []const u8,
};

fn handleRedirectConnection(
    allocator: std.mem.Allocator,
    stream: net.Stream,
    router: *Router,
    conn_config: ConnConfig,
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
    processRequests(allocator, &http_server, router, conn_config, logger, false, null, redirect_plan);
}

// ---------------------------------------------------------------------------
// Request processing loop (keep-alive aware)
// ---------------------------------------------------------------------------

fn processRequests(
    allocator: std.mem.Allocator,
    http_server: *http.Server,
    router: *Router,
    conn_config: ConnConfig,
    logger: logging.Logger,
    is_tls: bool,
    sni: ?[]const u8,
    redirect_plan: ?RedirectPlan,
) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (true) {
        if (!arena.reset(.retain_capacity)) {
            arena = std.heap.ArenaAllocator.init(allocator);
        }
        const arena_alloc = arena.allocator();

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

        const keep_alive = http_req.head.keep_alive;

        // Parse request metadata from head
        var req = Request.initFromHead(arena_alloc, http_req.head_buffer) catch |e| {
            logger.errorFields(.{
                .component = "listener",
                .event = "request_parse_failed",
                .@"error" = @errorName(e),
            }, "request parse failed");
            return;
        };
        req.assignRequestId(next_request_id.fetchAdd(1, .monotonic));
        req.tls = is_tls;
        req.server_request = &http_req;
        if (is_tls and sni != null) {
            req.tls_version = "TLSv1.3";
        }
        const started_ns = monotonicTimeNs();

        if (router.lifecycle_trace) {
            logger.debugFields(.{
                .component = "listener",
                .event = "request_started",
                .req_id = req.request_id,
                .method = @tagName(req.method),
                .path = req.path,
            }, "request started");
        }

        if (redirect_plan) |plan| {
            if (plan.should_redirect_fn(plan.config_ptr, req.path)) {
                const location = buildRedirectLocation(
                    arena_alloc,
                    req.header("host"),
                    plan.fallback_host,
                    plan.https_port,
                    http_req.head.target,
                ) catch null;
                defer if (location) |owned| arena_alloc.free(owned);

                var res = Response.init(arena_alloc);
                res.server_request = &http_req;
                res.logger = logger;
                res.request_id = req.request_id;
                _ = res.status(308);
                if (location) |loc| _ = res.set("location", loc);
                res.sendBody("");

                const elapsed_ns = monotonicTimeNs() - started_ns;
                if (conn_config.log_request_fn) |log_fn| {
                    log_fn(
                        logger,
                        req.request_id,
                        @tagName(req.method),
                        req.path,
                        res.status_code,
                        @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
                        req.header("user-agent"),
                        null,
                    );
                }

                if (!keep_alive) return;
                continue;
            }
        }

        if (!isMultipartRequest(&req)) {
            readBody(arena_alloc, &http_req, &req) catch |e| {
                logger.errorFields(.{
                    .component = "listener",
                    .event = "body_read_failed",
                    .req_id = req.request_id,
                    .path = req.path,
                    .@"error" = @errorName(e),
                }, "body read failed");
            };
        }

        var res = Response.init(arena_alloc);
        res.server_request = &http_req;
        res.compression_config = conn_config.compression_config;
        res.compress_fn = conn_config.compress_fn;
        res.logger = logger;
        res.request_id = req.request_id;

        router.handle(&req, &res);

        if (!res.sent and !res.streaming) {
            res.status(500).json(.{ .@"error" = "internal server error" });
        }

        const elapsed_ns = monotonicTimeNs() - started_ns;
        if (conn_config.log_request_fn) |log_fn| {
            var content_length: ?u64 = null;
            if (req.header("content-length")) |raw| {
                content_length = std.fmt.parseInt(u64, raw, 10) catch null;
            }
            log_fn(
                logger,
                req.request_id,
                @tagName(req.method),
                req.path,
                res.status_code,
                @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
                req.header("user-agent"),
                content_length,
            );
        }

        // Break the loop if the client does not want keep-alive
        if (!keep_alive) return;
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn isMultipartRequest(req: *const Request) bool {
    const ct = req.content_type() orelse return false;
    return std.mem.startsWith(u8, ct, "multipart/form-data");
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
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    return @as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds));
}
