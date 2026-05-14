const std = @import("std");
const util = @import("util.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");
const interceptor = @import("interceptor.zig");
const exceptions = @import("exceptions.zig");
const cors = @import("cors.zig");
const security = @import("security.zig");
const static = @import("static.zig");

pub const Route = struct {
    method: util.HttpMethod,
    pattern: []const u8,
    handler: middleware.HandlerFn,
};

pub const Router = struct {
    routes: std.ArrayList(Route),
    mw: middleware.MiddlewareList,
    allocator: std.mem.Allocator,
    error_handler: ?middleware.ErrorHandlerFn,
    global_interceptors: std.ArrayList(interceptor.InterceptorFn),
    cors_config: ?cors.CorsConfig,
    security_config: security.SecurityConfig,
    static_configs: std.ArrayList(static.StaticConfig),
    template_engine: ?*@import("template.zig").TemplateEngine,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .routes = .empty,
            .mw = middleware.MiddlewareList.init(allocator),
            .allocator = allocator,
            .error_handler = null,
            .global_interceptors = .empty,
            .cors_config = null,
            .security_config = .{},
            .static_configs = .empty,
            .template_engine = null,
        };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
        self.mw.deinit();
        self.global_interceptors.deinit(self.allocator);
        self.static_configs.deinit(self.allocator);
    }

    fn addRoute(self: *Router, method: util.HttpMethod, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern,
            .handler = handler,
        }) catch |e| {
            std.debug.print("ziez: failed to add route: {}\n", .{e});
        };
    }

    pub fn get(self: *Router, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.GET, pattern, handler);
    }

    pub fn post(self: *Router, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.POST, pattern, handler);
    }

    pub fn put(self: *Router, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.PUT, pattern, handler);
    }

    pub fn delete(self: *Router, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.DELETE, pattern, handler);
    }

    pub fn patch(self: *Router, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.PATCH, pattern, handler);
    }

    pub fn all(self: *Router, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.ALL, pattern, handler);
    }

    pub fn use(self: *Router, mw: middleware.MiddlewareFn) void {
        self.mw.push(mw) catch |e| {
            std.debug.print("ziez: failed to add middleware: {}\n", .{e});
        };
    }

    /// Register a global interceptor that wraps all route handlers.
    pub fn useInterceptor(self: *Router, ic: interceptor.InterceptorFn) void {
        self.global_interceptors.append(self.allocator, ic) catch |e| {
            std.debug.print("ziez: failed to add interceptor: {}\n", .{e});
        };
    }

    pub fn setErrorHandler(self: *Router, handler: middleware.ErrorHandlerFn) void {
        self.error_handler = handler;
    }

    pub fn useCors(self: *Router, config: cors.CorsConfig) void {
        self.cors_config = config;
    }

    pub fn useSecurity(self: *Router, config: security.SecurityConfig) void {
        self.security_config = config;
    }

    pub fn useStatic(self: *Router, config: static.StaticConfig) void {
        self.static_configs.append(self.allocator, config) catch |e| {
            std.debug.print("ziez: failed to add static config: {}\n", .{e});
        };
    }

    pub fn setTemplateEngine(self: *Router, engine: *@import("template.zig").TemplateEngine) void {
        self.template_engine = engine;
    }

    pub fn handle(self: *Router, req: *Request, res: *Response) void {
        res.template_engine = self.template_engine;
        security.apply(req, res, self.security_config);

        if (self.cors_config) |config| {
            if (!cors.handle(req, res, config)) return;
        }

        for (self.static_configs.items) |config| {
            if (static.handle(req, res, config) catch false) {
                if (res.sent) return;
            }
        }

        if (!self.mw.execute(req, res)) return;

        for (self.routes.items) |route| {
            const method_match = route.method == .ALL or route.method == req.method;
            if (!method_match) continue;

            const result = util.matchRoute(route.pattern, req.path) orelse continue;
            req.params = result;

            if (self.global_interceptors.items.len > 0) {
                self.handleWithInterceptors(req, res, route.handler) catch |err| {
                    self.handleError(req, res, err);
                    return;
                };
            } else {
                route.handler(req, res) catch |err| {
                    self.handleError(req, res, err);
                    return;
                };
            }

            if (!res.sent) {
                self.handleError(req, res, error.InternalServerError);
            }
            return;
        }

        // 404 - no route matched
        res.status(404).json(.{ .@"error" = "Not Found", .statusCode = 404 });
    }

    fn handleWithInterceptors(
        self: *@This(),
        req: *Request,
        res: *Response,
        handler: middleware.HandlerFn,
    ) anyerror!void {
        var chain = interceptor.InterceptorChain.init(
            self.global_interceptors.items,
            handler,
        );
        var ctx = interceptor.InterceptorCtx{
            .req = req,
            .res = res,
            ._chain = &chain,
        };
        try ctx.proceed();
    }

    fn handleError(self: *Router, req: *Request, res: *Response, err: anyerror) void {
        if (res.sent) return;

        std.log.debug("ziez: {s} → error: {}", .{ req.path, err });

        // Custom error handler takes priority
        if (self.error_handler) |handler| {
            handler(req, res, err);
            if (!res.sent) {
                self.sendDefaultError(res, err);
            }
            return;
        }

        self.sendDefaultError(res, err);
    }

    fn sendDefaultError(self: *const Router, res: *Response, err: anyerror) void {
        _ = self;
        const info = exceptions.errorToResponse(err);
        const msg = res.error_message orelse info.message;
        res.status(info.code).json(.{
            .statusCode = info.code,
            .@"error" = msg,
        });
    }
};
