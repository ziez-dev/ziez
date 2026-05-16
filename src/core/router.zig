const std = @import("std");
const util = @import("util.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");
const interceptor = @import("interceptor.zig");
const exceptions = @import("exceptions.zig");
const hook_mod = @import("hook.zig");
const logging = @import("logging.zig");

pub const Route = struct {
    pattern: []const u8,
    handler: middleware.HandlerFn,
};

pub const Router = struct {
    get_routes: std.ArrayList(Route),
    post_routes: std.ArrayList(Route),
    put_routes: std.ArrayList(Route),
    delete_routes: std.ArrayList(Route),
    patch_routes: std.ArrayList(Route),
    head_routes: std.ArrayList(Route),
    options_routes: std.ArrayList(Route),
    all_routes: std.ArrayList(Route),
    static_get: std.StringHashMap(Route),
    static_post: std.StringHashMap(Route),
    static_put: std.StringHashMap(Route),
    static_delete: std.StringHashMap(Route),
    static_patch: std.StringHashMap(Route),
    static_head: std.StringHashMap(Route),
    static_options: std.StringHashMap(Route),
    static_all: std.StringHashMap(Route),
    mw: middleware.MiddlewareList,
    allocator: std.mem.Allocator,
    error_handler: ?middleware.ErrorHandlerFn,
    global_interceptors: std.ArrayList(interceptor.InterceptorFn),
    hooks: std.ArrayListUnmanaged(hook_mod.RequestHook),
    logger: logging.Logger,
    lifecycle_trace: bool = false,

    pub fn init(allocator: std.mem.Allocator) Router {
        const logger = logging.Logger.init(allocator, .{});
        return .{
            .get_routes = .empty,
            .post_routes = .empty,
            .put_routes = .empty,
            .delete_routes = .empty,
            .patch_routes = .empty,
            .head_routes = .empty,
            .options_routes = .empty,
            .all_routes = .empty,
            .static_get = .init(allocator),
            .static_post = .init(allocator),
            .static_put = .init(allocator),
            .static_delete = .init(allocator),
            .static_patch = .init(allocator),
            .static_head = .init(allocator),
            .static_options = .init(allocator),
            .static_all = .init(allocator),
            .mw = middleware.MiddlewareList.init(allocator),
            .allocator = allocator,
            .error_handler = null,
            .global_interceptors = .empty,
            .hooks = .empty,
            .logger = logger,
        };
    }

    pub fn deinit(self: *Router) void {
        self.get_routes.deinit(self.allocator);
        self.post_routes.deinit(self.allocator);
        self.put_routes.deinit(self.allocator);
        self.delete_routes.deinit(self.allocator);
        self.patch_routes.deinit(self.allocator);
        self.head_routes.deinit(self.allocator);
        self.options_routes.deinit(self.allocator);
        self.all_routes.deinit(self.allocator);
        self.static_get.deinit();
        self.static_post.deinit();
        self.static_put.deinit();
        self.static_delete.deinit();
        self.static_patch.deinit();
        self.static_head.deinit();
        self.static_options.deinit();
        self.static_all.deinit();
        self.mw.deinit();
        self.global_interceptors.deinit(self.allocator);
        for (self.hooks.items) |h| h.deinit(h.ptr, self.allocator);
        self.hooks.deinit(self.allocator);
        self.logger.deinit();
    }

    fn addRoute(self: *Router, method: util.HttpMethod, pattern: []const u8, handler: middleware.HandlerFn) void {
        const route = Route{
            .pattern = pattern,
            .handler = handler,
        };

        if (isStaticRoute(pattern)) {
            const static_map = switch (method) {
                .GET => &self.static_get,
                .POST => &self.static_post,
                .PUT => &self.static_put,
                .DELETE => &self.static_delete,
                .PATCH => &self.static_patch,
                .HEAD => &self.static_head,
                .OPTIONS => &self.static_options,
                .ALL => &self.static_all,
            };
            static_map.put(pattern, route) catch {};
        }

        const list = switch (method) {
            .GET => &self.get_routes,
            .POST => &self.post_routes,
            .PUT => &self.put_routes,
            .DELETE => &self.delete_routes,
            .PATCH => &self.patch_routes,
            .HEAD => &self.head_routes,
            .OPTIONS => &self.options_routes,
            .ALL => &self.all_routes,
        };
        list.append(self.allocator, route) catch |e| {
            std.debug.print("ziez: failed to add route: {}\n", .{e});
        };
    }

    /// Returns the total number of registered routes across all method groups.
    pub fn routeCount(self: *const Router) usize {
        return self.get_routes.items.len +
            self.post_routes.items.len +
            self.put_routes.items.len +
            self.delete_routes.items.len +
            self.patch_routes.items.len +
            self.head_routes.items.len +
            self.options_routes.items.len +
            self.all_routes.items.len;
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

    pub fn useCors(self: *Router, config: @import("../cors/mod.zig").CorsConfig) void {
        const h = @import("../cors/mod.zig").asHook(self.allocator, config);
        self.hooks.append(self.allocator, h) catch @panic("ziez: OOM adding CORS hook");
    }

    pub fn useSecurity(self: *Router, config: @import("../security/mod.zig").SecurityConfig) void {
        const h = @import("../security/mod.zig").asHook(self.allocator, config);
        self.hooks.append(self.allocator, h) catch @panic("ziez: OOM adding security hook");
    }

    pub fn useStatic(self: *Router, config: @import("../static/mod.zig").StaticConfig) void {
        const h = @import("../static/mod.zig").asHook(self.allocator, config);
        self.hooks.append(self.allocator, h) catch @panic("ziez: OOM adding static hook");
    }

    pub fn setTemplateEngine(self: *Router, engine: *@import("../template/mod.zig").TemplateEngine) void {
        const h = @import("../template/mod.zig").asHook(engine);
        self.hooks.append(self.allocator, h) catch @panic("ziez: OOM adding template hook");
    }

    pub fn handle(self: *Router, req: *Request, res: *Response) void {
        res.logger = self.logger;
        res.request_id = req.request_id;

        for (self.hooks.items) |h| {
            if (!h.run(h.ptr, req, res)) return;
        }

        if (!self.mw.executeWithTrace(req, res, .{
            .enter = if (self.lifecycle_trace) traceMiddlewareEnter else null,
            .exit = if (self.lifecycle_trace) traceMiddlewareExit else null,
            .short_circuit = if (self.lifecycle_trace) traceMiddlewareShortCircuit else null,
        })) return;

        // Method-partitioned dispatch: select routes matching the request method
        const method_routes = switch (req.method) {
            .GET => self.get_routes.items,
            .POST => self.post_routes.items,
            .PUT => self.put_routes.items,
            .DELETE => self.delete_routes.items,
            .PATCH => self.patch_routes.items,
            .HEAD => self.head_routes.items,
            .OPTIONS => self.options_routes.items,
            .ALL => self.all_routes.items,
        };

        // Try exact-method routes first (hash map for static, then parameterized)
        const static_map = switch (req.method) {
            .GET => &self.static_get,
            .POST => &self.static_post,
            .PUT => &self.static_put,
            .DELETE => &self.static_delete,
            .PATCH => &self.static_patch,
            .HEAD => &self.static_head,
            .OPTIONS => &self.static_options,
            .ALL => &self.static_all,
        };
        if (static_map.get(req.path)) |route| {
            req.params = .{};
            self.trace(req, .{
                .event = "route_matched",
                .route_method = @tagName(req.method),
                .route_pattern = route.pattern,
            }, "route matched");
            self.executeHandler(req, res, route, @tagName(req.method));
            return;
        }

        // Try parameterized routes for exact method
        if (dispatchParameterized(self, method_routes, req, res, @tagName(req.method))) return;

        // Try ALL-method routes as fallback
        if (self.static_all.get(req.path)) |route| {
            req.params = .{};
            self.trace(req, .{ .event = "route_matched", .route_method = "ALL", .route_pattern = route.pattern }, "route matched");
            self.executeHandler(req, res, route, "ALL");
            return;
        }
        if (self.all_routes.items.len > 0) {
            if (dispatchParameterized(self, self.all_routes.items, req, res, "ALL")) return;
        }

        // 404 - no route matched
        self.trace(req, .{ .event = "route_not_found" }, "route not found");
        res.status(404).json(.{ .@"error" = "Not Found", .statusCode = 404 });
    }

    /// Dispatch against parameterized routes only.
    fn dispatchParameterized(self: *Router, routes: []const Route, req: *Request, res: *Response, method_tag: []const u8) bool {
        for (routes) |route| {
            if (isStaticRoute(route.pattern)) continue;
            const result = util.matchRoute(route.pattern, req.path) orelse continue;
            req.params = result;

            self.trace(req, .{
                .event = "route_matched",
                .route_method = method_tag,
                .route_pattern = route.pattern,
            }, "route matched");

            self.executeHandler(req, res, route, method_tag);
            return true;
        }

        return false;
    }

    fn executeHandler(self: *Router, req: *Request, res: *Response, route: Route, method_tag: []const u8) void {
        if (self.global_interceptors.items.len > 0) {
            self.handleWithInterceptors(req, res, route, method_tag) catch |err| {
                self.handleError(req, res, err);
                return;
            };
        } else {
            self.trace(req, .{
                .event = "handler_enter",
                .route_method = method_tag,
                .route_pattern = route.pattern,
            }, "handler enter");
            route.handler(req, res) catch |err| {
                self.handleError(req, res, err);
                return;
            };
            self.trace(req, .{
                .event = "handler_exit",
                .route_method = method_tag,
                .route_pattern = route.pattern,
            }, "handler exit");
        }

        if (!res.sent and !res.streaming) {
            self.handleError(req, res, error.InternalServerError);
        }
    }

    /// Returns true if the route pattern contains no parameters (`:param`) or wildcards (`*`).
    fn isStaticRoute(pattern: []const u8) bool {
        for (pattern) |ch| {
            if (ch == ':' or ch == '*') return false;
        }
        return true;
    }

    fn handleWithInterceptors(
        self: *@This(),
        req: *Request,
        res: *Response,
        route: Route,
        method_tag: []const u8,
    ) anyerror!void {
        var chain = interceptor.InterceptorChain.init(
            self.global_interceptors.items,
            route.handler,
        );
        chain.trace = .{
            .enter = if (self.lifecycle_trace) traceInterceptorEnter else null,
            .exit = if (self.lifecycle_trace) traceInterceptorExit else null,
            .handler_enter = if (self.lifecycle_trace) traceHandlerEnter else null,
            .handler_exit = if (self.lifecycle_trace) traceHandlerExit else null,
        };
        var ctx = interceptor.InterceptorCtx{
            .req = req,
            .res = res,
            ._chain = &chain,
        };
        self.trace(req, .{
            .event = "interceptor_chain_start",
            .route_method = method_tag,
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
        if (!self.lifecycle_trace) return;
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
