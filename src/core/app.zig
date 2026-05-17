const std = @import("std");
const middleware = @import("middleware.zig");
const log_mod = @import("logging.zig");
const Router = @import("router.zig").Router;
const listener = @import("listener.zig");

pub const App = struct {
    router: Router,
    logger: log_mod.Logger,
    allocator: std.mem.Allocator,
    // Type-erased compression — only set when user calls app.compress()
    conn_config: listener.ConnConfig,
    compress_free_fn: ?*const fn (*anyopaque, std.mem.Allocator) void,
    // Type-erased TLS — only set when user calls app.tls()
    tls_runtime: ?*anyopaque,
    tls_config_ptr: ?*anyopaque,
    tls_create_fn: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!*anyopaque,
    tls_destroy_fn: ?*const fn (*anyopaque) void,
    tls_config_free_fn: ?*const fn (*anyopaque, std.mem.Allocator) void,
    tls_reload_fn: ?*const fn (*anyopaque, *anyopaque) anyerror!void,
    handle_tls_fn: ?listener.TlsHandleFn,
    // Type-erased redirect — only set when user calls app.redirectHttp()
    redirect_config_ptr: ?*anyopaque,
    redirect_config_free_fn: ?*const fn (*anyopaque, std.mem.Allocator) void,
    run_redirect_fn: ?listener.RedirectRunFn,

    pub fn init(allocator: std.mem.Allocator) App {
        const router = Router.init(allocator);
        return .{
            .router = router,
            .logger = router.logger,
            .allocator = allocator,
            .conn_config = .{ .log_request_fn = listener.defaultLogRequestFn },
            .compress_free_fn = null,
            .tls_runtime = null,
            .tls_config_ptr = null,
            .tls_create_fn = null,
            .tls_destroy_fn = null,
            .tls_config_free_fn = null,
            .tls_reload_fn = null,
            .handle_tls_fn = null,
            .redirect_config_ptr = null,
            .redirect_config_free_fn = null,
            .run_redirect_fn = null,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.tls_runtime) |ptr| {
            if (self.tls_destroy_fn) |destroy| destroy(ptr);
            self.tls_runtime = null;
        }
        if (self.tls_config_ptr) |ptr| {
            if (self.tls_config_free_fn) |free_fn| free_fn(ptr, self.allocator);
            self.tls_config_ptr = null;
        }
        if (self.redirect_config_ptr) |ptr| {
            if (self.redirect_config_free_fn) |free_fn| free_fn(ptr, self.allocator);
            self.redirect_config_ptr = null;
        }
        if (self.conn_config.compression_config) |ptr| {
            if (self.compress_free_fn) |free_fn| free_fn(ptr, self.allocator);
            self.conn_config.compression_config = null;
        }
        self.router.deinit();
    }

    pub fn listen(self: *App, io: std.Io, address: []const u8) !void {
        if (self.tls_config_ptr) |cfg_ptr| {
            if (self.tls_runtime == null) {
                if (self.tls_create_fn) |create_fn| {
                    self.tls_runtime = try create_fn(cfg_ptr, self.allocator);
                }
            }
        }
        if (self.redirect_config_ptr != null and self.tls_runtime == null) {
            return error.TlsRequiredForRedirect;
        }
        try listener.listenAndServe(
            self.allocator,
            io,
            address,
            &self.router,
            self.conn_config,
            self.logger,
            self.tls_runtime,
            self.handle_tls_fn,
            self.redirect_config_ptr,
            self.run_redirect_fn,
        );
    }

    pub fn get(self: *App, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.router.get(pattern, handler);
    }

    pub fn post(self: *App, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.router.post(pattern, handler);
    }

    pub fn put(self: *App, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.router.put(pattern, handler);
    }

    pub fn delete(self: *App, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.router.delete(pattern, handler);
    }

    pub fn patch(self: *App, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.router.patch(pattern, handler);
    }

    pub fn all(self: *App, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.router.all(pattern, handler);
    }

    /// Accept a bare MiddlewareFn (or coercible fn type) or a configured Middleware struct.
    pub fn use(self: *App, mw: anytype) void {
        self.router.use(mw);
    }

    /// Create a route group with a URL prefix.
    pub fn group(self: *App, prefix: []const u8) *@import("router.zig").RouteGroup {
        return self.router.group(prefix);
    }

    pub fn on_error(self: *App, handler: middleware.ErrorHandlerFn) void {
        self.router.setErrorHandler(handler);
    }

    // ── Plugin provider registration APIs ──────────────────────────────────────
    // External plugins call these from their setup/install functions.

    /// For ziez-compression plugin: registers compression provider.
    pub fn registerCompression(
        self: *App,
        config_ptr: *anyopaque,
        apply_fn: listener.CompressionFn,
        free_fn: *const fn (*anyopaque, std.mem.Allocator) void,
    ) void {
        if (self.conn_config.compression_config) |ptr| {
            if (self.compress_free_fn) |f| f(ptr, self.allocator);
        }
        self.conn_config.compression_config = config_ptr;
        self.conn_config.compress_fn = apply_fn;
        self.compress_free_fn = free_fn;
    }

    /// For ziez-tracker plugin: registers request logging provider.
    pub fn registerTracker(self: *App, log_fn: listener.LogRequestFn) void {
        self.conn_config.log_request_fn = log_fn;
    }

    /// For ziez-tls plugin: registers TLS provider.
    /// The plugin provides handle_fn which is called per-connection when TLS is active.
    pub fn registerTls(
        self: *App,
        config_ptr: *anyopaque,
        create_fn: *const fn (*anyopaque, std.mem.Allocator) anyerror!*anyopaque,
        destroy_fn: *const fn (*anyopaque) void,
        config_free_fn: *const fn (*anyopaque, std.mem.Allocator) void,
        reload_fn: *const fn (*anyopaque, *anyopaque) anyerror!void,
        handle_fn: listener.TlsHandleFn,
    ) void {
        if (self.tls_config_ptr) |ptr| {
            if (self.tls_config_free_fn) |f| f(ptr, self.allocator);
        }
        self.tls_config_ptr = config_ptr;
        self.tls_config_free_fn = config_free_fn;
        self.tls_create_fn = create_fn;
        self.tls_destroy_fn = destroy_fn;
        self.tls_reload_fn = reload_fn;
        self.handle_tls_fn = handle_fn;
    }

    /// For ziez-tls plugin: registers HTTP→HTTPS redirect.
    /// The plugin provides run_fn which spawns a dedicated redirect listener thread.
    pub fn registerRedirectHttp(
        self: *App,
        config_ptr: *anyopaque,
        config_free_fn: *const fn (*anyopaque, std.mem.Allocator) void,
        run_fn: listener.RedirectRunFn,
    ) void {
        if (self.redirect_config_ptr) |ptr| {
            if (self.redirect_config_free_fn) |f| f(ptr, self.allocator);
        }
        self.redirect_config_ptr = config_ptr;
        self.redirect_config_free_fn = config_free_fn;
        self.run_redirect_fn = run_fn;
    }

    pub fn logging(self: *App, config: log_mod.LoggerConfig) void {
        self.logger.configure(config);
        self.router.logger = self.logger;
    }
};
