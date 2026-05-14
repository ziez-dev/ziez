const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const exceptions = @import("exceptions.zig");

pub const Next = struct {
    proceed: bool = false,

    pub fn call(self: *Next) void {
        self.proceed = true;
    }
};

pub const MiddlewareFn = *const fn (*Request, *Response, *Next) void;
pub const HandlerFn = *const fn (*Request, *Response) anyerror!void;
pub const ErrorHandlerFn = *const fn (*Request, *Response, anyerror) void;
pub const TraceHook = *const fn (usize, *Request, *Response) void;

pub const ExecutionTrace = struct {
    enter: ?TraceHook = null,
    exit: ?TraceHook = null,
    short_circuit: ?TraceHook = null,
};

pub const MiddlewareList = struct {
    items: std.ArrayList(MiddlewareFn),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MiddlewareList {
        return .{
            .items = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MiddlewareList) void {
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *MiddlewareList, mw: MiddlewareFn) !void {
        try self.items.append(self.allocator, mw);
    }

    pub fn execute(self: *const MiddlewareList, req: *Request, res: *Response) bool {
        return self.executeWithTrace(req, res, .{});
    }

    pub fn executeWithTrace(self: *const MiddlewareList, req: *Request, res: *Response, trace: ExecutionTrace) bool {
        for (self.items.items, 0..) |mw, index| {
            if (trace.enter) |hook| hook(index, req, res);
            var next = Next{};
            mw(req, res, &next);
            if (res.sent or !next.proceed) {
                if (trace.short_circuit) |hook| hook(index, req, res);
                return false;
            }
            if (trace.exit) |hook| hook(index, req, res);
        }
        return true;
    }
};
