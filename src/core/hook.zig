const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// Type-erased per-request hook.
///
/// Hooks are called in registration order for every incoming request, before
/// middleware and route dispatch.  Return `false` to short-circuit the pipeline
/// (e.g. CORS preflight handled, static file served).
pub const RequestHook = struct {
    ptr: *anyopaque,
    run: *const fn (*anyopaque, *Request, *Response) bool,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
};
