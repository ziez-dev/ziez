const std = @import("std");
const util = @import("util.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");
const exceptions = @import("exceptions.zig");
const hook_mod = @import("hook.zig");
const logging = @import("logging.zig");

pub const Route = struct {
    pattern: []const u8,
    handler: middleware.HandlerFn,
    group_mw: ?*const middleware.MiddlewareList = null,
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
    hooks: std.ArrayListUnmanaged(hook_mod.RequestHook),
    groups: std.ArrayListUnmanaged(*RouteGroup),
    logger: logging.Logger,
    lifecycle_trace: bool = false,

    pub fn initSilent(allocator: std.mem.Allocator) Router {
        var r = Router.init(allocator);
        r.logger.configure(.{ .sink = logging.Sink.noop() });
        return r;
    }

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
            .hooks = .empty,
            .groups = .empty,
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
        for (self.hooks.items) |h| h.deinit(h.ptr, self.allocator);
        self.hooks.deinit(self.allocator);
        for (self.groups.items) |g| g.deinit(self.allocator);
        self.groups.deinit(self.allocator);
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

    /// Accept a bare MiddlewareFn (or coercible fn type) or a configured Middleware struct.
    pub fn use(self: *Router, mw: anytype) void {
        const T = @TypeOf(mw);
        if (T == middleware.Middleware) {
            self.mw.pushMiddleware(mw) catch |e| {
                std.debug.print("ziez: failed to add middleware: {}\n", .{e});
            };
            return;
        }
        const fn_ptr: middleware.MiddlewareFn = mw;
        self.mw.pushMiddleware(middleware.Middleware.wrapRuntime(fn_ptr)) catch |e| {
            std.debug.print("ziez: failed to add middleware: {}\n", .{e});
        };
    }

    /// Register a type-erased request hook. Used by external plugins.
    /// Hooks run before middleware in registration order; return false to short-circuit.
    pub fn addHook(self: *Router, hook: hook_mod.RequestHook) !void {
        try self.hooks.append(self.allocator, hook);
    }

    pub fn setErrorHandler(self: *Router, handler: middleware.ErrorHandlerFn) void {
        self.error_handler = handler;
    }

    /// Create a route group with a URL prefix. The group is owned by the router.
    pub fn group(self: *Router, prefix: []const u8) *RouteGroup {
        const g = self.allocator.create(RouteGroup) catch @panic("ziez: OOM creating RouteGroup");
        g.* = RouteGroup.init(self, prefix);
        self.groups.append(self.allocator, g) catch @panic("ziez: OOM appending RouteGroup");
        return g;
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
            trace(self, req, .{
                .event = "route_matched",
                .route_method = @tagName(req.method),
                .route_pattern = route.pattern,
            }, "route matched");
            executeHandler(self, req, res, route, @tagName(req.method));
            return;
        }

        // Try parameterized routes for exact method
        if (dispatchParameterized(self, method_routes, req, res, @tagName(req.method))) return;

        // Try ALL-method routes as fallback
        if (self.static_all.get(req.path)) |route| {
            req.params = .{};
            trace(self, req, .{ .event = "route_matched", .route_method = "ALL", .route_pattern = route.pattern }, "route matched");
            executeHandler(self, req, res, route, "ALL");
            return;
        }
        if (self.all_routes.items.len > 0) {
            if (dispatchParameterized(self, self.all_routes.items, req, res, "ALL")) return;
        }

        // 405 — path exists for other methods?
        var allow_buf: [128]u8 = undefined;
        if (self.hasPathForOtherMethods(req.path, req.method, &allow_buf)) |allow_header| {
            _ = res.set("Allow", allow_header);
            trace(self, req, .{ .event = "method_not_allowed" }, "method not allowed");
            res.status(405).json(.{ .@"error" = "Method Not Allowed", .statusCode = 405 });
            return;
        }

        // 404 — no route matched
        trace(self, req, .{ .event = "route_not_found" }, "route not found");
        res.status(404).json(.{ .@"error" = "Not Found", .statusCode = 404 });
    }

    /// Returns a comma-separated Allow header value if the path matches routes
    /// for any method other than the current one; otherwise null.
    /// `buf` must be caller-owned and live at least as long as the returned slice.
    fn hasPathForOtherMethods(self: *const Router, path: []const u8, current: util.HttpMethod, buf: []u8) ?[]const u8 {
        const all_methods = [_]struct { method: util.HttpMethod, tag: []const u8 }{
            .{ .method = .GET, .tag = "GET" },
            .{ .method = .POST, .tag = "POST" },
            .{ .method = .PUT, .tag = "PUT" },
            .{ .method = .DELETE, .tag = "DELETE" },
            .{ .method = .PATCH, .tag = "PATCH" },
            .{ .method = .HEAD, .tag = "HEAD" },
            .{ .method = .OPTIONS, .tag = "OPTIONS" },
        };
        var len: usize = 0;
        for (all_methods) |entry| {
            if (entry.method == current) continue;
            const routes = routesForMethod(self, entry.method);
            const static_map = staticMapForMethod(self, entry.method);
            var found = false;
            if (static_map.get(path) != null) {
                found = true;
            } else {
                for (routes) |route| {
                    if (util.matchRoute(route.pattern, path) != null) {
                        found = true;
                        break;
                    }
                }
            }
            if (found) {
                if (len > 0 and len + 2 < buf.len) {
                    buf[len] = ',';
                    buf[len + 1] = ' ';
                    len += 2;
                }
                if (len + entry.tag.len < buf.len) {
                    @memcpy(buf[len .. len + entry.tag.len], entry.tag);
                    len += entry.tag.len;
                }
            }
        }
        if (len == 0) return null;
        return buf[0..len];
    }
};

// ---------------------------------------------------------------------------
// RouteGroup — prefix-scoped routes with optional middleware
// ---------------------------------------------------------------------------

pub const RouteGroup = struct {
    router: *Router,
    prefix: []const u8,
    mw: middleware.MiddlewareList,
    /// Patterns allocated during group route registration (freed on deinit).
    allocated_patterns: std.ArrayList([]const u8),

    pub fn init(router: *Router, prefix: []const u8) RouteGroup {
        const owned = router.allocator.dupe(u8, prefix) catch @panic("ziez: OOM duping group prefix");
        return .{
            .router = router,
            .prefix = owned,
            .mw = middleware.MiddlewareList.init(router.allocator),
            .allocated_patterns = .empty,
        };
    }

    pub fn deinit(self: *RouteGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        self.mw.deinit();
        for (self.allocated_patterns.items) |p| allocator.free(p);
        self.allocated_patterns.deinit(allocator);
        allocator.destroy(self);
    }

    /// Add a bare MiddlewareFn (or coercible fn type) or a configured Middleware to this group.
    pub fn use(self: *RouteGroup, mw_item: anytype) void {
        const T = @TypeOf(mw_item);
        if (T == middleware.Middleware) {
            self.mw.pushMiddleware(mw_item) catch {};
            return;
        }
        const fn_ptr: middleware.MiddlewareFn = mw_item;
        self.mw.pushMiddleware(middleware.Middleware.wrapRuntime(fn_ptr)) catch {};
    }

    pub fn get(self: *RouteGroup, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.GET, pattern, handler);
    }
    pub fn post(self: *RouteGroup, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.POST, pattern, handler);
    }
    pub fn put(self: *RouteGroup, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.PUT, pattern, handler);
    }
    pub fn delete(self: *RouteGroup, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.DELETE, pattern, handler);
    }
    pub fn patch(self: *RouteGroup, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.PATCH, pattern, handler);
    }
    pub fn all(self: *RouteGroup, pattern: []const u8, handler: middleware.HandlerFn) void {
        self.addRoute(.ALL, pattern, handler);
    }

    /// Create a sub-group with an extended prefix.
    pub fn group(self: *RouteGroup, sub_prefix: []const u8) *RouteGroup {
        const full = std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, sub_prefix }) catch @panic("ziez: OOM");
        defer self.router.allocator.free(full);
        return self.router.group(full); // init() dupes the prefix so free is safe
    }

    fn addRoute(self: *RouteGroup, method: util.HttpMethod, pattern: []const u8, handler: middleware.HandlerFn) void {
        const full = std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, pattern }) catch return;
        self.allocated_patterns.append(self.router.allocator, full) catch {
            self.router.allocator.free(full);
            return;
        };
        const route = Route{
            .pattern = full,
            .handler = handler,
            .group_mw = if (self.mw.items.items.len > 0) &self.mw else null,
        };
        const list = switch (method) {
            .GET => &self.router.get_routes,
            .POST => &self.router.post_routes,
            .PUT => &self.router.put_routes,
            .DELETE => &self.router.delete_routes,
            .PATCH => &self.router.patch_routes,
            .HEAD => &self.router.head_routes,
            .OPTIONS => &self.router.options_routes,
            .ALL => &self.router.all_routes,
        };
        list.append(self.router.allocator, route) catch {};
    }
};

fn routesForMethod(self: *const Router, method: util.HttpMethod) []const Route {
    return switch (method) {
        .GET => self.get_routes.items,
        .POST => self.post_routes.items,
        .PUT => self.put_routes.items,
        .DELETE => self.delete_routes.items,
        .PATCH => self.patch_routes.items,
        .HEAD => self.head_routes.items,
        .OPTIONS => self.options_routes.items,
        .ALL => self.all_routes.items,
    };
}

fn staticMapForMethod(self: *const Router, method: util.HttpMethod) std.StringHashMap(Route) {
    return switch (method) {
        .GET => self.static_get,
        .POST => self.static_post,
        .PUT => self.static_put,
        .DELETE => self.static_delete,
        .PATCH => self.static_patch,
        .HEAD => self.static_head,
        .OPTIONS => self.static_options,
        .ALL => self.static_all,
    };
}

/// Dispatch against parameterized routes only.
fn dispatchParameterized(self: *Router, routes: []const Route, req: *Request, res: *Response, method_tag: []const u8) bool {
    for (routes) |route| {
        const result = util.matchRoute(route.pattern, req.path) orelse continue;
        req.params = result;

        trace(self, req, .{
            .event = "route_matched",
            .route_method = method_tag,
            .route_pattern = route.pattern,
        }, "route matched");

        executeHandler(self, req, res, route, method_tag);
        return true;
    }

    return false;
}

fn executeHandler(self: *Router, req: *Request, res: *Response, route: Route, method_tag: []const u8) void {
    if (route.group_mw) |gm| {
        if (!gm.execute(req, res)) return;
    }
    trace(self, req, .{
        .event = "handler_enter",
        .route_method = method_tag,
        .route_pattern = route.pattern,
    }, "handler enter");
    route.handler(req, res) catch |err| {
        handleError(self, req, res, err);
        return;
    };
    trace(self, req, .{
        .event = "handler_exit",
        .route_method = method_tag,
        .route_pattern = route.pattern,
    }, "handler exit");

    if (!res.sent and !res.streaming) {
        handleError(self, req, res, error.InternalServerError);
    }
}

/// Returns true if the route pattern contains no parameters (`:param`) or wildcards (`*`).
fn isStaticRoute(pattern: []const u8) bool {
    for (pattern) |ch| {
        if (ch == ':' or ch == '*') return false;
    }
    return true;
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
    trace(self, req, .{
        .event = "error_caught",
        .status = info.code,
        .@"error" = @errorName(err),
    }, "error caught");

    // Custom error handler takes priority
    if (self.error_handler) |handler| {
        trace(self, req, .{ .event = "error_handler_enter" }, "error handler enter");
        handler(req, res, err);
        trace(self, req, .{ .event = "error_handler_exit" }, "error handler exit");
        if (!res.sent) {
            sendDefaultError(self, res, err);
        }
        return;
    }

    sendDefaultError(self, res, err);
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

fn logLifecycleFromResponse(res: *Response, fields: anytype, msg: []const u8) void {
    if (res.logger) |logger| {
        logger.debugFields(.{ .component = "router", .trace = fields }, msg);
    }
}
