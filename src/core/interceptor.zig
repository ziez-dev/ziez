const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");
const serializer = @import("../serializer/mod.zig");

// ---------------------------------------------------------------------------
// Comptime per-route middleware chain builder
// ---------------------------------------------------------------------------

/// Signature for comptime-only interceptor functions (wraps a HandlerFn).
pub const InterceptorFn = *const fn (*Request, *Response, *middleware.Next) void;

/// Wrap a single middleware around an inner HandlerFn at comptime.
fn wrapOne(
    comptime mw_fn: InterceptorFn,
    comptime inner: middleware.HandlerFn,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            var ran_next = false;
            const NextState = struct { ran: *bool, inner: middleware.HandlerFn };
            var state = NextState{ .ran = &ran_next, .inner = inner };
            _ = &state;
            var next_inst = middleware.Next{ ._ctx = undefined };
            _ = &next_inst;
            mw_fn(req, res, &next_inst);
            if (!res.sent) try inner(req, res);
        }
    }.wrapped;
}

/// Build a comptime middleware chain around a handler.
/// `middlewares` is a struct/tuple of MiddlewareFn values.
/// Applied outer-to-inner.
///
/// Usage: `intercept(.{loggingMw, authMw}, myHandler)`
pub fn intercept(
    comptime middlewares: anytype,
    comptime handler_fn: middleware.HandlerFn,
) middleware.HandlerFn {
    const info = @typeInfo(@TypeOf(middlewares));
    if (info != .@"struct") {
        @compileError("intercept() expects a struct/tuple of middleware functions");
    }
    const fields = info.@"struct".fields;
    if (fields.len == 0) return handler_fn;

    const result = comptime blk: {
        var current: middleware.HandlerFn = handler_fn;
        var i: usize = fields.len;
        while (i > 0) {
            i -= 1;
            const field = fields[i];
            const mw_fn = @field(middlewares, field.name);
            current = wrapOne(mw_fn, current);
        }
        break :blk current;
    };
    return result;
}

// ---------------------------------------------------------------------------
// Serialization wrapper
// ---------------------------------------------------------------------------

/// Wraps a typed handler with automatic serialization.
/// handler_fn must have signature `fn(*Request) anyerror!T`.
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
