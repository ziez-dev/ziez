const std = @import("std");
const util = @import("util.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");
const interceptor = @import("interceptor.zig");
const exceptions = @import("exceptions.zig");
const cors = @import("cors.zig");
const logging = @import("logging.zig");
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
    logger: logging.Logger,

    pub fn init(allocator: std.mem.Allocator) Router {
        const logger = logging.Logger.init(allocator, .{});
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
            .logger = logger,
        };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
        self.mw.deinit();
        self.global_interceptors.deinit(self.allocator);
        self.static_configs.deinit(self.allocator);
        self.logger.deinit();
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
        res.logger = self.logger;
        res.request_id = req.request_id;
        security.apply(req, res, self.security_config);

        if (self.cors_config) |config| {
            if (!cors.handle(req, res, config)) return;
        }

        for (self.static_configs.items) |config| {
            if (static.handle(req, res, config) catch false) {
                if (res.sent) return;
            }
        }

        if (!self.mw.executeWithTrace(req, res, .{
            .enter = if (self.logger.lifecycleTraceEnabled()) traceMiddlewareEnter else null,
            .exit = if (self.logger.lifecycleTraceEnabled()) traceMiddlewareExit else null,
            .short_circuit = if (self.logger.lifecycleTraceEnabled()) traceMiddlewareShortCircuit else null,
        })) return;

        for (self.routes.items) |route| {
            const method_match = route.method == .ALL or route.method == req.method;
            if (!method_match) continue;

            const result = util.matchRoute(route.pattern, req.path) orelse continue;
            req.params = result;

            self.trace(req, .{
                .event = "route_matched",
                .route_method = @tagName(route.method),
                .route_pattern = route.pattern,
            }, "route matched");

            if (self.global_interceptors.items.len > 0) {
                self.handleWithInterceptors(req, res, route) catch |err| {
                    self.handleError(req, res, err);
                    return;
                };
            } else {
                self.trace(req, .{
                    .event = "handler_enter",
                    .route_method = @tagName(route.method),
                    .route_pattern = route.pattern,
                }, "handler enter");
                route.handler(req, res) catch |err| {
                    self.handleError(req, res, err);
                    return;
                };
                self.trace(req, .{
                    .event = "handler_exit",
                    .route_method = @tagName(route.method),
                    .route_pattern = route.pattern,
                }, "handler exit");
            }

            if (!res.sent and !res.streaming) {
                self.handleError(req, res, error.InternalServerError);
            }
            return;
        }

        // 404 - no route matched
        self.trace(req, .{ .event = "route_not_found" }, "route not found");
        res.status(404).json(.{ .@"error" = "Not Found", .statusCode = 404 });
    }

    fn handleWithInterceptors(
        self: *@This(),
        req: *Request,
        res: *Response,
        route: Route,
    ) anyerror!void {
        var chain = interceptor.InterceptorChain.init(
            self.global_interceptors.items,
            route.handler,
        );
        chain.trace = .{
            .enter = if (self.logger.lifecycleTraceEnabled()) traceInterceptorEnter else null,
            .exit = if (self.logger.lifecycleTraceEnabled()) traceInterceptorExit else null,
            .handler_enter = if (self.logger.lifecycleTraceEnabled()) traceHandlerEnter else null,
            .handler_exit = if (self.logger.lifecycleTraceEnabled()) traceHandlerExit else null,
        };
        var ctx = interceptor.InterceptorCtx{
            .req = req,
            .res = res,
            ._chain = &chain,
        };
        self.trace(req, .{
            .event = "interceptor_chain_start",
            .route_method = @tagName(route.method),
            .route_pattern = route.pattern,
            .count = self.global_interceptors.items.len,
        }, "interceptor chain start");
        try ctx.proceed();
    }

    fn handleError(self: *Router, req: *Request, res: *Response, err: anyerror) void {
        if (res.sent) return;

        const info = exceptions.errorToResponse(err);
        if (info.code >= 500) {
            self.logger.errorFields(.{
                .component = "router",
                .event = "error_caught",
                .req_id = req.request_id,
                .path = req.path,
                .status = info.code,
                .@"error" = @errorName(err),
            }, "router error");
        }
        self.trace(req, .{
            .event = "error_caught",
            .status = info.code,
            .@"error" = @errorName(err),
        }, "error caught");

        // Custom error handler takes priority
        if (self.error_handler) |handler| {
            self.trace(req, .{ .event = "error_handler_enter" }, "error handler enter");
            handler(req, res, err);
            self.trace(req, .{ .event = "error_handler_exit" }, "error handler exit");
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

    fn trace(self: *const Router, req: *const Request, fields: anytype, msg: []const u8) void {
        if (!self.logger.lifecycleTraceEnabled()) return;
        self.logger.debugFields(.{
            .component = "router",
            .req_id = req.request_id,
            .path = req.path,
            .method = @tagName(req.method),
            .trace = fields,
        }, msg);
    }

    fn traceMiddlewareEnter(index: usize, req: *Request, res: *Response) void {
        logLifecycleFromResponse(res, .{
            .event = "middleware_enter",
            .index = index,
            .req_id = req.request_id,
            .path = req.path,
            .method = @tagName(req.method),
        }, "middleware enter");
    }

    fn traceMiddlewareExit(index: usize, req: *Request, res: *Response) void {
        logLifecycleFromResponse(res, .{
            .event = "middleware_exit",
            .index = index,
            .req_id = req.request_id,
            .path = req.path,
            .method = @tagName(req.method),
        }, "middleware exit");
    }

    fn traceMiddlewareShortCircuit(index: usize, req: *Request, res: *Response) void {
        logLifecycleFromResponse(res, .{
            .event = "middleware_short_circuit",
            .index = index,
            .req_id = req.request_id,
            .path = req.path,
            .method = @tagName(req.method),
            .status = res.status_code,
            .sent = res.sent,
        }, "middleware short circuit");
    }

    fn traceInterceptorEnter(index: usize, req: *Request, res: *Response) void {
        logLifecycleFromResponse(res, .{
            .event = "interceptor_enter",
            .index = index,
            .req_id = req.request_id,
            .path = req.path,
            .method = @tagName(req.method),
        }, "interceptor enter");
    }

    fn traceInterceptorExit(index: usize, req: *Request, res: *Response) void {
        logLifecycleFromResponse(res, .{
            .event = "interceptor_exit",
            .index = index,
            .req_id = req.request_id,
            .path = req.path,
            .method = @tagName(req.method),
            .status = res.status_code,
        }, "interceptor exit");
    }

    fn traceHandlerEnter(req: *Request, res: *Response) void {
        logLifecycleFromResponse(res, .{
            .event = "handler_enter",
            .req_id = req.request_id,
            .path = req.path,
            .method = @tagName(req.method),
        }, "handler enter");
    }

    fn traceHandlerExit(req: *Request, res: *Response) void {
        logLifecycleFromResponse(res, .{
            .event = "handler_exit",
            .req_id = req.request_id,
            .path = req.path,
            .method = @tagName(req.method),
            .status = res.status_code,
        }, "handler exit");
    }

    fn logLifecycleFromResponse(res: *Response, fields: anytype, msg: []const u8) void {
        if (res.logger) |logger| {
            logger.debugFields(.{ .component = "router", .trace = fields }, msg);
        }
    }
};
