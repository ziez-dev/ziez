const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const exceptions = @import("exceptions.zig");

pub const HandlerFn = *const fn (*Request, *Response) anyerror!void;
pub const ErrorHandlerFn = *const fn (*Request, *Response, anyerror) void;
pub const TraceHook = *const fn (usize, *Request, *Response) void;

pub const ExecutionTrace = struct {
    enter: ?TraceHook = null,
    exit: ?TraceHook = null,
    short_circuit: ?TraceHook = null,
};

// ---------------------------------------------------------------------------
// Middleware — type-erased configured middleware with optional cleanup
// ---------------------------------------------------------------------------

/// Type-erased configured middleware. `ptr` is null for bare-function middleware.
pub const Middleware = struct {
    ptr: ?*anyopaque = null,
    handler: *const fn (?*anyopaque, *Request, *Response, *Next) void,
    deinit_fn: ?*const fn (?*anyopaque, std.mem.Allocator) void = null,

    /// Wrap a bare MiddlewareFn (comptime-known) into a Middleware.
    pub fn wrap(comptime f: MiddlewareFn) Middleware {
        return .{
            .ptr = null,
            .handler = struct {
                fn call(_: ?*anyopaque, req: *Request, res: *Response, next: *Next) void {
                    f(req, res, next);
                }
            }.call,
            .deinit_fn = null,
        };
    }

    /// Wrap a runtime MiddlewareFn into a Middleware (stores fn ptr in `ptr` field).
    pub fn wrapRuntime(f: MiddlewareFn) Middleware {
        return .{
            .ptr = @ptrCast(@constCast(f)),
            .handler = struct {
                fn call(ptr: ?*anyopaque, req: *Request, res: *Response, next: *Next) void {
                    const fn_ptr: MiddlewareFn = @ptrCast(@alignCast(ptr.?));
                    fn_ptr(req, res, next);
                }
            }.call,
            .deinit_fn = null,
        };
    }
};

/// Bare middleware function — same signature as before; `Next.call()` now chains properly.
pub const MiddlewareFn = *const fn (*Request, *Response, *Next) void;

// ---------------------------------------------------------------------------
// Next — drives the middleware chain via MiddlewareCtx
// ---------------------------------------------------------------------------

pub const MiddlewareCtx = struct {
    items: []const Middleware,
    req: *Request,
    res: *Response,
    index: usize,
    trace: ExecutionTrace,
};

/// Calling `next.call()` actually invokes the next middleware in the chain
/// (or returns silently when the end of the chain is reached).
/// "After" logic placed after `next.call()` runs AFTER all downstream middleware.
pub const Next = struct {
    _ctx: *MiddlewareCtx,

    pub fn call(self: *Next) void {
        dispatchMiddleware(self._ctx);
    }
};

pub fn dispatchMiddleware(ctx: *MiddlewareCtx) void {
    if (ctx.res.sent) return;
    if (ctx.index >= ctx.items.len) return;

    const idx = ctx.index;
    const mw = ctx.items[idx];
    ctx.index += 1;

    if (ctx.trace.enter) |hook| hook(idx, ctx.req, ctx.res);
    var next_inst = Next{ ._ctx = ctx };
    mw.handler(mw.ptr, ctx.req, ctx.res, &next_inst);
    if (ctx.res.sent) {
        if (ctx.trace.short_circuit) |hook| hook(idx, ctx.req, ctx.res);
    } else {
        if (ctx.trace.exit) |hook| hook(idx, ctx.req, ctx.res);
    }
}

// ---------------------------------------------------------------------------
// MiddlewareList
// ---------------------------------------------------------------------------

pub const MiddlewareList = struct {
    items: std.ArrayList(Middleware),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MiddlewareList {
        return .{
            .items = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MiddlewareList) void {
        for (self.items.items) |mw| {
            if (mw.deinit_fn) |f| f(mw.ptr, self.allocator);
        }
        self.items.deinit(self.allocator);
    }

    /// Add a bare MiddlewareFn (wrapped automatically).
    pub fn push(self: *MiddlewareList, mw: MiddlewareFn) !void {
        try self.items.append(self.allocator, Middleware.wrap(mw));
    }

    /// Add a configured Middleware directly.
    pub fn pushMiddleware(self: *MiddlewareList, mw: Middleware) !void {
        try self.items.append(self.allocator, mw);
    }

    pub fn execute(self: *const MiddlewareList, req: *Request, res: *Response) bool {
        return self.executeWithTrace(req, res, .{});
    }

    pub fn executeWithTrace(self: *const MiddlewareList, req: *Request, res: *Response, trace: ExecutionTrace) bool {
        if (self.items.items.len == 0) return true;
        var ctx = MiddlewareCtx{
            .items = self.items.items,
            .req = req,
            .res = res,
            .index = 0,
            .trace = trace,
        };
        dispatchMiddleware(&ctx);
        return !res.sent;
    }
};
