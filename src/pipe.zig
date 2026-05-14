const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");
const schema_mod = @import("schema.zig");
const validator = @import("validator.zig");

/// Parse a route param into an integer type.
/// handler_fn signature: fn(*Request, *Response, IntType) anyerror!void
pub fn paramInt(
    comptime param_name: []const u8,
    comptime IntType: type,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const raw = req.param(param_name) orelse {
                res.error_message = "missing route param: " ++ param_name;
                return error.BadRequest;
            };
            const parsed = std.fmt.parseInt(IntType, raw, 10) catch {
                res.error_message = "invalid integer for param: " ++ param_name;
                return error.BadRequest;
            };
            try handler_fn(req, res, parsed);
        }
    }.wrapped;
}

/// Validate a route param as UUID (8-4-4-4-12 hex format).
/// handler_fn signature: fn(*Request, *Response, []const u8) anyerror!void
pub fn parseUUID(
    comptime param_name: []const u8,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const raw = req.param(param_name) orelse {
                res.error_message = "missing route param: " ++ param_name;
                return error.BadRequest;
            };
            if (!validator.isUUID(raw)) {
                res.error_message = "invalid UUID for param: " ++ param_name;
                return error.BadRequest;
            }
            try handler_fn(req, res, raw);
        }
    }.wrapped;
}

/// Parse a route param as bool ("true"/"false").
/// handler_fn signature: fn(*Request, *Response, bool) anyerror!void
pub fn parseBool(
    comptime param_name: []const u8,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const raw = req.param(param_name) orelse {
                res.error_message = "missing route param: " ++ param_name;
                return error.BadRequest;
            };
            const parsed = if (std.mem.eql(u8, raw, "true"))
                true
            else if (std.mem.eql(u8, raw, "false"))
                false
            else {
                res.error_message = "invalid bool for param: " ++ param_name;
                return error.BadRequest;
            };
            try handler_fn(req, res, parsed);
        }
    }.wrapped;
}

/// Parse and validate JSON body into type T.
/// handler_fn signature: fn(*Request, *Response, T) anyerror!void
pub fn validateBody(
    comptime T: type,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const body = req.body_json(T) orelse {
                res.error_message = "request body must be valid JSON";
                return error.BadRequest;
            };
            try handler_fn(req, res, body);
        }
    }.wrapped;
}

/// Parse and validate JSON body with a custom validation function.
/// validate_fn signature: fn(T) bool
/// handler_fn signature: fn(*Request, *Response, T) anyerror!void
pub fn validateBodyWith(
    comptime T: type,
    comptime validate_fn: anytype,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const body = req.body_json(T) orelse {
                res.error_message = "request body must be valid JSON";
                return error.BadRequest;
            };
            if (!validate_fn(body)) {
                res.error_message = "request body failed validation";
                return error.UnprocessableEntity;
            }
            try handler_fn(req, res, body);
        }
    }.wrapped;
}

/// Parse JSON body and validate against T.rules (schema validation).
/// handler_fn signature: fn(*Request, *Response, T) anyerror!void
pub fn validateBodySchema(
    comptime T: type,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const body = req.body_json(T) orelse {
                res.error_message = "request body must be valid JSON";
                return error.BadRequest;
            };
            const result = schema_mod.validate(req.allocator, body);
            if (!result.valid) {
                res.status(422);
                res.error_message = "Validation failed";
                return error.UnprocessableEntity;
            }
            try handler_fn(req, res, body);
        }
    }.wrapped;
}

/// Parse JSON body and validate against explicit rules.
/// handler_fn signature: fn(*Request, *Response, T) anyerror!void
pub fn validateBodyWithSchema(
    comptime T: type,
    comptime rules: anytype,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const body = req.body_json(T) orelse {
                res.error_message = "request body must be valid JSON";
                return error.BadRequest;
            };
            const result = schema_mod.validateWithRules(req.allocator, body, rules);
            if (!result.valid) {
                res.status(422);
                res.error_message = "Validation failed";
                return error.UnprocessableEntity;
            }
            try handler_fn(req, res, body);
        }
    }.wrapped;
}

/// Build T from query params and validate against T.rules.
/// handler_fn signature: fn(*Request, *Response, T) anyerror!void
pub fn validateQuerySchema(
    comptime T: type,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const val: T = buildQuery(T, req);
            const result = schema_mod.validate(req.allocator, val);
            if (!result.valid) {
                res.status(422);
                res.error_message = "Validation failed";
                return error.UnprocessableEntity;
            }
            try handler_fn(req, res, val);
        }
    }.wrapped;
}

/// Generic pipe: transform a route param with a custom function.
/// transform_fn signature: fn([]const u8) anyerror!OutputType
/// handler_fn signature: fn(*Request, *Response, OutputType) anyerror!void
pub fn pipeParam(
    comptime param_name: []const u8,
    comptime transform_fn: anytype,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const raw = req.param(param_name) orelse {
                res.error_message = "missing route param: " ++ param_name;
                return error.BadRequest;
            };
            const transformed = transform_fn(raw) catch {
                res.error_message = "pipe transform failed for param: " ++ param_name;
                return error.BadRequest;
            };
            try handler_fn(req, res, transformed);
        }
    }.wrapped;
}

/// Parse a query param into an integer type.
/// handler_fn signature: fn(*Request, *Response, IntType) anyerror!void
pub fn queryInt(
    comptime key: []const u8,
    comptime IntType: type,
    comptime handler_fn: anytype,
) middleware.HandlerFn {
    return struct {
        fn wrapped(req: *Request, res: *Response) anyerror!void {
            const raw = req.query_get(key) orelse {
                res.error_message = "missing query param: " ++ key;
                return error.BadRequest;
            };
            const parsed = std.fmt.parseInt(IntType, raw, 10) catch {
                res.error_message = "invalid integer for query param: " ++ key;
                return error.BadRequest;
            };
            try handler_fn(req, res, parsed);
        }
    }.wrapped;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Validate UUID format: delegates to validator.isUUID
pub fn isValidUUID(s: []const u8) bool {
    return validator.isUUID(s);
}

/// Build a struct of type T from query params at runtime.
fn buildQuery(comptime T: type, req: *Request) T {
    var val: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const raw = req.query_get(field.name);
        if (raw) |r| {
            switch (@typeInfo(field.type)) {
                .int => {
                    @field(val, field.name) = std.fmt.parseInt(field.type, r, 10) catch @as(field.type, 0);
                },
                .float => {
                    @field(val, field.name) = std.fmt.parseFloat(field.type, r) catch @as(field.type, 0);
                },
                .pointer => {
                    @field(val, field.name) = r;
                },
                .optional => {
                    @field(val, field.name) = r;
                },
                else => {
                    @compileError("validateQuerySchema only supports int, float, []const u8, and optional fields, got: " ++ @typeName(field.type));
                },
            }
        } else if (@typeInfo(field.type) == .optional) {
            @field(val, field.name) = null;
        } else if (field.default_value) |dv| {
            const ptr: *const field.type = @ptrCast(@alignCast(dv));
            @field(val, field.name) = ptr.*;
        }
    }
    return val;
}
