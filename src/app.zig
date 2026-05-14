const std = @import("std");
const middleware = @import("middleware.zig");
const interceptor = @import("interceptor.zig");
const compression = @import("compression.zig");
const cors_mod = @import("cors.zig");
const security_mod = @import("security.zig");
const Router = @import("router.zig").Router;
const listener = @import("listener.zig");

pub const App = struct {
    router: Router,
    allocator: std.mem.Allocator,
    compression_config: ?compression.CompressionConfig = null,

    pub fn init(allocator: std.mem.Allocator) App {
        return .{
            .router = Router.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *App) void {
        self.router.deinit();
    }

    pub fn listen(self: *App, io: std.Io, address: []const u8) !void {
        try listener.listenAndServe(self.allocator, io, address, &self.router, self.compression_config);
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
    pub fn compress(self: *App, config: compression.CompressionConfig) void {
        self.compression_config = config;
    }

    /// Enable global CORS handling.
    pub fn cors(self: *App, config: cors_mod.CorsConfig) void {
        self.router.useCors(config);
    }

    /// Configure default-on security headers and XSS sanitization.
    pub fn security(self: *App, config: security_mod.SecurityConfig) void {
        self.router.useSecurity(config);
    }

    /// Serve static files from a directory.
    pub fn serveStatic(self: *App, config: @import("static.zig").StaticConfig) void {
        self.router.useStatic(config);
    }

    /// Register a template engine for server-side rendering.
    pub fn setTemplateEngine(self: *App, engine: *@import("template.zig").TemplateEngine) void {
        self.router.setTemplateEngine(engine);
    }
};
