const std = @import("std");
const opts = @import("ziez_options");
const middleware = @import("middleware.zig");
const interceptor = @import("interceptor.zig");
const CompressionMod = if (opts.with_compression) @import("../compression/mod.zig") else struct {};
const CorsMod = if (opts.with_cors) @import("../cors/mod.zig") else struct {};
const log_mod = @import("logging.zig");
const SecurityMod = if (opts.with_security) @import("../security/mod.zig") else struct {};
const TlsMod = if (opts.with_tls) @import("../tls/mod.zig") else struct {};
const StaticMod = if (opts.with_static) @import("../static/mod.zig") else struct {};
const TemplateMod = if (opts.with_template) @import("../template/mod.zig") else struct {};
const Router = @import("router.zig").Router;
const listener = @import("listener.zig");

pub const App = struct {
    router: Router,
    logger: log_mod.Logger,
    allocator: std.mem.Allocator,
    compression_config: if (opts.with_compression) ?CompressionMod.CompressionConfig else void,
    tls_config: if (opts.with_tls) ?TlsMod.TlsConfig else void,
    tls_runtime: if (opts.with_tls) ?*TlsMod.TlsRuntime else void,
    redirect_http_config: if (opts.with_tls) ?TlsMod.RedirectHttpConfig else void,

    pub fn init(allocator: std.mem.Allocator) App {
        const router = Router.init(allocator);
        return .{
            .router = router,
            .logger = router.logger,
            .allocator = allocator,
            .compression_config = if (opts.with_compression) null else {},
            .tls_config = if (opts.with_tls) null else {},
            .tls_runtime = if (opts.with_tls) null else {},
            .redirect_http_config = if (opts.with_tls) null else {},
        };
    }

    pub fn deinit(self: *App) void {
        if (opts.with_tls) {
            if (self.tls_runtime) |runtime| {
                runtime.destroy();
                self.tls_runtime = null;
            }
        }
        self.router.deinit();
    }

    pub fn listen(self: *App, io: std.Io, address: []const u8) !void {
        if (opts.with_tls) {
            if (self.tls_config) |config| {
                if (self.tls_runtime == null) {
                    self.tls_runtime = try TlsMod.TlsRuntime.create(self.allocator, config);
                }
                try listener.listenAndServe(
                    self.allocator,
                    io,
                    address,
                    &self.router,
                    self.compression_config,
                    self.logger,
                    self.tls_runtime,
                    self.redirect_http_config,
                );
                return;
            }
        }
        if (opts.with_tls and self.redirect_http_config != null) return error.TlsRequiredForRedirect;
        try listener.listenAndServe(
            self.allocator,
            io,
            address,
            &self.router,
            self.compression_config,
            self.logger,
            if (opts.with_tls) null else {},
            if (opts.with_tls) null else {},
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

    /// Enable response compression with optional config.
    pub fn compress(self: *App, config: CompressionMod.CompressionConfig) void {
        if (opts.with_compression == false) @compileError("Compression requires -Dwith_compression=true");
        self.compression_config = config;
    }

    /// Enable HTTPS/TLS with the given configuration.
    pub fn tls(self: *App, config: TlsMod.TlsConfig) void {
        if (opts.with_tls == false) @compileError("TLS requires -Dwith_tls=true");
        self.tls_config = config;
    }

    pub fn redirectHttp(self: *App, config: TlsMod.RedirectHttpConfig) void {
        if (opts.with_tls == false) @compileError("TLS redirect requires -Dwith_tls=true");
        self.redirect_http_config = config;
    }

    pub fn reloadTls(self: *App, config: TlsMod.TlsConfig) !void {
        if (opts.with_tls == false) @compileError("TLS requires -Dwith_tls=true");
        self.tls_config = config;
        if (self.tls_runtime) |runtime| {
            try runtime.reload(config);
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
    pub fn cors(self: *App, config: CorsMod.CorsConfig) void {
        self.router.useCors(config);
    }

    /// Configure default-on security headers and XSS sanitization.
    pub fn security(self: *App, config: SecurityMod.SecurityConfig) void {
        self.router.useSecurity(config);
    }

    /// Serve static files from a directory.
    pub fn serveStatic(self: *App, config: StaticMod.StaticConfig) void {
        if (opts.with_static == false) @compileError("Static file serving requires -Dwith_static=true");
        self.router.useStatic(config);
    }

    /// Register a template engine for server-side rendering.
    pub fn setTemplateEngine(self: *App, engine: *TemplateMod.TemplateEngine) void {
        if (opts.with_template == false) @compileError("Template engine requires -Dwith_template=true");
        self.router.setTemplateEngine(engine);
    }
};
