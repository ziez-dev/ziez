const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");
const serializer = @import("../serializer/mod.zig");

// ---------------------------------------------------------------------------
// InterceptorCtx — context passed to every interceptor
// ---------------------------------------------------------------------------

pub const InterceptorCtx = struct {
    req: *Request,
    res: *Response,

    /// Comptime chain: function pointer to the next layer.
    _proceed_fn: ?*const fn (*InterceptorCtx) anyerror!void = null,

    /// Runtime chain: pointer to the InterceptorChain struct.
    _chain: ?*InterceptorChain = null,

    /// Call the next step in the chain (the inner interceptor or final handler).
    pub fn proceed(self: *InterceptorCtx) anyerror!void {
        if (self._chain) |chain| {
            try chain.next(self);
        } else if (self._proceed_fn) |fn_ptr| {
            try fn_ptr(self);
        }
    }
};

// ---------------------------------------------------------------------------
// InterceptorFn — function signature for interceptors
// ---------------------------------------------------------------------------

pub const InterceptorFn = *const fn (*InterceptorCtx) anyerror!void;

pub const TraceHooks = struct {
    enter: ?*const fn (usize, *Request, *Response) void = null,
    exit: ?*const fn (usize, *Request, *Response) void = null,
    handler_enter: ?*const fn (*Request, *Response) void = null,
    handler_exit: ?*const fn (*Request, *Response) void = null,
};

// ---------------------------------------------------------------------------
// Runtime interceptor chain (for global interceptors)
// ---------------------------------------------------------------------------

pub const InterceptorChain = struct {
    interceptors: []const InterceptorFn,
    handler: middleware.HandlerFn,
    index: usize,
    trace: TraceHooks = .{},

    pub fn init(
        interceptors: []const InterceptorFn,
        handler: middleware.HandlerFn,
    ) InterceptorChain {
        return .{
            .interceptors = interceptors,
            .handler = handler,
            .index = 0,
        };
    }

    /// Advance the chain: call the next interceptor or the final handler.
    pub fn next(self: *@This(), ctx: *InterceptorCtx) anyerror!void {
        if (self.index < self.interceptors.len) {
            const current_index = self.index;
            const ic_fn = self.interceptors[self.index];
            self.index += 1;
            ctx._chain = self;
            if (self.trace.enter) |hook| hook(current_index, ctx.req, ctx.res);
            try ic_fn(ctx);
            if (self.trace.exit) |hook| hook(current_index, ctx.req, ctx.res);
        } else {
            if (self.trace.handler_enter) |hook| hook(ctx.req, ctx.res);
            try self.handler(ctx.req, ctx.res);
            if (self.trace.handler_exit) |hook| hook(ctx.req, ctx.res);
        }
    }
};

// ---------------------------------------------------------------------------
// Comptime chain builder (for per-route interceptors)
// ---------------------------------------------------------------------------

/// Wrap a single interceptor around an inner HandlerFn.
/// The proceed function calls the inner handler with ctx.req/ctx.res.
fn wrapOne(
    comptime ic_fn: InterceptorFn,
    comptime inner: middleware.HandlerFn,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            var ctx = InterceptorCtx{
                .req = req,
                .res = res,
                ._proceed_fn = struct {
                    fn call(c: *InterceptorCtx) anyerror!void {
                        try inner(c.req, c.res);
                    }
                }.call,
            };
            try ic_fn(&ctx);
        }
    }.wrapped;
}

/// Build a comptime interceptor chain around a handler.
/// `interceptors` is a struct/tuple of InterceptorFn values.
/// Applied outer-to-inner: first item wraps second wraps ... wraps handler.
///
/// Usage: `intercept(.{loggingInterceptor, timingInterceptor}, myHandler)`
pub fn intercept(
    comptime interceptors: anytype,
    comptime handler_fn: middleware.HandlerFn,
) middleware.HandlerFn {
    const info = @typeInfo(@TypeOf(interceptors));
    if (info != .@"struct") {
        @compileError("intercept() expects a struct/tuple of interceptors");
    }
    const fields = info.@"struct".fields;
    if (fields.len == 0) return handler_fn;

    // Build from inside out: last interceptor wraps the handler,
    // second-to-last wraps that result, etc.
    const result = comptime blk: {
        var current: middleware.HandlerFn = handler_fn;
        var i: usize = fields.len;
        while (i > 0) {
            i -= 1;
            const field = fields[i];
            const ic_fn = @field(interceptors, field.name);
            current = wrapOne(ic_fn, current);
        }
        break :blk current;
    };
    return result;
}

// ---------------------------------------------------------------------------
// Serialization wrapper (existing)
// ---------------------------------------------------------------------------

/// Wraps a typed handler with automatic serialization.
/// handler_fn must have signature `fn(*Request) anyerror!T`.
/// The returned function has the standard HandlerFn signature and
/// automatically serializes the handler's return value as JSON.
pub fn serialized(
    comptime config: anytype,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const data = try handler_fn(req);
            const body = serializer.serialize(res.allocator, data, config) catch {
                res.status(500).sendBody("{\"error\":\"serialization failed\"}");
                return;
            };
            defer res.allocator.free(body);
            _ = res.set("content-type", "application/json");
            res.sendBody(body);
        }
    }.wrapped;
}
