const std = @import("std");
const middleware = @import("middleware.zig");
const interceptor = @import("interceptor.zig");
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

    pub fn use(self: *App, mw: middleware.MiddlewareFn) void {
        self.router.use(mw);
    }

    /// Register a global interceptor that wraps all route handlers.
    pub fn useInterceptor(self: *App, ic: interceptor.InterceptorFn) void {
        self.router.useInterceptor(ic);
    }

    pub fn on_error(self: *App, handler: middleware.ErrorHandlerFn) void {
        self.router.setErrorHandler(handler);
    }

    /// Enable rich request/response logging via the tracker module.
    /// Only compiles tracker module when called; otherwise the built-in basic logger is used.
    pub fn useTracker(self: *App) void {
        const TrackerMod = @import("../tracker/mod.zig");
        self.conn_config.log_request_fn = TrackerMod.logRequestFn;
    }

    /// Enable response compression. Only compiles compression module when called.
    pub fn compress(self: *App, config: @import("../compression/mod.zig").CompressionConfig) void {
        const CompressionMod = @import("../compression/mod.zig");
        if (self.conn_config.compression_config) |ptr| {
            if (self.compress_free_fn) |free_fn| free_fn(ptr, self.allocator);
        }
        const owned = self.allocator.create(CompressionMod.CompressionConfig) catch @panic("ziez: OOM configuring compression");
        owned.* = config;
        self.conn_config.compression_config = owned;
        self.conn_config.compress_fn = CompressionMod.applyFn;
        self.compress_free_fn = CompressionMod.freeConfigFn;
    }

    /// Enable HTTPS/TLS. Only compiles TLS module when called.
    pub fn tls(self: *App, config: @import("../tls/mod.zig").TlsConfig) void {
        const TlsMod = @import("../tls/mod.zig");
        if (self.tls_config_ptr) |ptr| {
            if (self.tls_config_free_fn) |free_fn| free_fn(ptr, self.allocator);
        }
        const owned = self.allocator.create(TlsMod.TlsConfig) catch @panic("ziez: OOM configuring TLS");
        owned.* = config;
        self.tls_config_ptr = owned;
        self.tls_config_free_fn = TlsMod.freeConfigFn;
        self.tls_create_fn = TlsMod.createRuntimeFn;
        self.tls_destroy_fn = TlsMod.destroyRuntimeFn;
        self.handle_tls_fn = listener.handleTlsConnection;
    }

    /// Enable HTTP→HTTPS redirect. Only compiles TLS module when called.
    pub fn redirectHttp(self: *App, config: @import("../tls/mod.zig").RedirectHttpConfig) void {
        const TlsMod = @import("../tls/mod.zig");
        if (self.redirect_config_ptr) |ptr| {
            if (self.redirect_config_free_fn) |free_fn| free_fn(ptr, self.allocator);
        }
        const owned = self.allocator.create(TlsMod.RedirectHttpConfig) catch @panic("ziez: OOM configuring redirect");
        owned.* = config;
        self.redirect_config_ptr = owned;
        self.redirect_config_free_fn = TlsMod.freeRedirectConfigFn;
        self.run_redirect_fn = listener.runRedirectListenerFn;
    }

    pub fn reloadTls(self: *App, config: @import("../tls/mod.zig").TlsConfig) !void {
        const TlsMod = @import("../tls/mod.zig");
        if (self.tls_config_ptr) |ptr| {
            const stored: *TlsMod.TlsConfig = @ptrCast(@alignCast(ptr));
            stored.* = config;
        } else {
            const owned = try self.allocator.create(TlsMod.TlsConfig);
            owned.* = config;
            self.tls_config_ptr = owned;
            self.tls_config_free_fn = TlsMod.freeConfigFn;
        }
        if (self.tls_runtime) |runtime_ptr| {
            try TlsMod.reloadRuntimeFn(runtime_ptr, self.tls_config_ptr.?);
            self.logger.infoFields(.{
                .component = "tls",
                .event = "context_reloaded",
            }, "TLS context reloaded");
        }
    }

    pub fn logging(self: *App, config: log_mod.LoggerConfig) void {
        self.logger.configure(config);
        self.router.logger = self.logger;
    }

    /// Enable global CORS handling.
    pub fn cors(self: *App, config: @import("../cors/mod.zig").CorsConfig) void {
        self.router.useCors(config);
    }

    /// Configure security headers and XSS sanitization.
    pub fn security(self: *App, config: @import("../security/mod.zig").SecurityConfig) void {
        self.router.useSecurity(config);
    }

    /// Serve static files from a directory.
    pub fn serveStatic(self: *App, config: @import("../static/mod.zig").StaticConfig) void {
        self.router.useStatic(config);
    }

    /// Register a template engine for server-side rendering.
    pub fn setTemplateEngine(self: *App, engine: *@import("../template/mod.zig").TemplateEngine) void {
        self.router.setTemplateEngine(engine);
    }
};
