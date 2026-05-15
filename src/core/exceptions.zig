const std = @import("std");
const Response = @import("response.zig").Response;

/// Throw an HTTP error with custom message.
/// Usage in handler:
///   return ziez.throw(error.BadRequest, "email is required", res);
/// Router catches the error, reads custom message from res.error_message.
pub fn throw(err: anyerror, msg: []const u8, res: *Response) anyerror {
    res.error_message = msg;
    return err;
}

/// HTTP Exception - mirip NestJS HttpException.
/// Handler bisa return error lewat Zig error union:
///   return error.BadRequest;
///   return ziez.throw(error.BadRequest, "custom message", res);
/// Router auto-catch → kirim response dengan status code yang sesuai.
pub const Exception = struct {
    status_code: u16,
    message: []const u8,

    pub fn init(code: u16, msg: []const u8) Exception {
        return .{ .status_code = code, .message = msg };
    }

    // --- 4xx Client Errors ---

    pub const BadRequest = Exception{ .status_code = 400, .message = "Bad Request" };
    pub const Unauthorized = Exception{ .status_code = 401, .message = "Unauthorized" };
    pub const PaymentRequired = Exception{ .status_code = 402, .message = "Payment Required" };
    pub const Forbidden = Exception{ .status_code = 403, .message = "Forbidden" };
    pub const NotFound = Exception{ .status_code = 404, .message = "Not Found" };
    pub const MethodNotAllowed = Exception{ .status_code = 405, .message = "Method Not Allowed" };
    pub const NotAcceptable = Exception{ .status_code = 406, .message = "Not Acceptable" };
    pub const RequestTimeout = Exception{ .status_code = 408, .message = "Request Timeout" };
    pub const Conflict = Exception{ .status_code = 409, .message = "Conflict" };
    pub const Gone = Exception{ .status_code = 410, .message = "Gone" };
    pub const LengthRequired = Exception{ .status_code = 411, .message = "Length Required" };
    pub const PreconditionFailed = Exception{ .status_code = 412, .message = "Precondition Failed" };
    pub const ContentTooLarge = Exception{ .status_code = 413, .message = "Content Too Large" };
    pub const URITooLong = Exception{ .status_code = 414, .message = "URI Too Long" };
    pub const UnsupportedMediaType = Exception{ .status_code = 415, .message = "Unsupported Media Type" };
    pub const RangeNotSatisfiable = Exception{ .status_code = 416, .message = "Range Not Satisfiable" };
    pub const ExpectationFailed = Exception{ .status_code = 417, .message = "Expectation Failed" };
    pub const Teapot = Exception{ .status_code = 418, .message = "I'm a teapot" };
    pub const UnprocessableContent = Exception{ .status_code = 422, .message = "Unprocessable Content" };
    pub const TooEarly = Exception{ .status_code = 425, .message = "Too Early" };
    pub const UpgradeRequired = Exception{ .status_code = 426, .message = "Upgrade Required" };
    pub const PreconditionRequired = Exception{ .status_code = 428, .message = "Precondition Required" };
    pub const TooManyRequests = Exception{ .status_code = 429, .message = "Too Many Requests" };
    pub const RequestHeaderFieldsTooLarge = Exception{ .status_code = 431, .message = "Request Header Fields Too Large" };
    pub const UnavailableForLegalReasons = Exception{ .status_code = 451, .message = "Unavailable For Legal Reasons" };

    // --- 5xx Server Errors ---

    pub const InternalServerError = Exception{ .status_code = 500, .message = "Internal Server Error" };
    pub const NotImplemented = Exception{ .status_code = 501, .message = "Not Implemented" };
    pub const BadGateway = Exception{ .status_code = 502, .message = "Bad Gateway" };
    pub const ServiceUnavailable = Exception{ .status_code = 503, .message = "Service Unavailable" };
    pub const GatewayTimeout = Exception{ .status_code = 504, .message = "Gateway Timeout" };
    pub const HTTPVersionNotSupported = Exception{ .status_code = 505, .message = "HTTP Version Not Supported" };

    /// Custom exception with message
    pub fn badRequest(msg: []const u8) Exception {
        return .{ .status_code = 400, .message = msg };
    }
    pub fn unauthorized(msg: []const u8) Exception {
        return .{ .status_code = 401, .message = msg };
    }
    pub fn forbidden(msg: []const u8) Exception {
        return .{ .status_code = 403, .message = msg };
    }
    pub fn notFound(msg: []const u8) Exception {
        return .{ .status_code = 404, .message = msg };
    }
    pub fn conflict(msg: []const u8) Exception {
        return .{ .status_code = 409, .message = msg };
    }
    pub fn unprocessable(msg: []const u8) Exception {
        return .{ .status_code = 422, .message = msg };
    }
    pub fn tooManyRequests(msg: []const u8) Exception {
        return .{ .status_code = 429, .message = msg };
    }
    pub fn internal(msg: []const u8) Exception {
        return .{ .status_code = 500, .message = msg };
    }
    pub fn serviceUnavailable(msg: []const u8) Exception {
        return .{ .status_code = 503, .message = msg };
    }
};

/// Error set untuk handler yang bisa "throw" HTTP exceptions.
/// Handler return type: anyerror!void
/// Usage:
///   return error.BadRequest;
///   return error.NotFound;
pub const HttpError = error{
    BadRequest,
    Unauthorized,
    PaymentRequired,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    NotAcceptable,
    RequestTimeout,
    Conflict,
    Gone,
    LengthRequired,
    PreconditionFailed,
    PayloadTooLarge,
    URITooLong,
    UnsupportedMediaType,
    RangeNotSatisfiable,
    ExpectationFailed,
    Teapot,
    UnprocessableEntity,
    TooEarly,
    UpgradeRequired,
    PreconditionRequired,
    TooManyRequests,
    RequestHeaderFieldsTooLarge,
    UnavailableForLegalReasons,
    InternalServerError,
    NotImplemented,
    BadGateway,
    ServiceUnavailable,
    GatewayTimeout,
    HTTPVersionNotSupported,
};

/// Map Zig error → HTTP status code + message
pub fn errorToResponse(err: anyerror) struct { code: u16, message: []const u8 } {
    return switch (err) {
        error.BadRequest => .{ .code = 400, .message = "Bad Request" },
        error.Unauthorized => .{ .code = 401, .message = "Unauthorized" },
        error.PaymentRequired => .{ .code = 402, .message = "Payment Required" },
        error.Forbidden => .{ .code = 403, .message = "Forbidden" },
        error.NotFound => .{ .code = 404, .message = "Not Found" },
        error.MethodNotAllowed => .{ .code = 405, .message = "Method Not Allowed" },
        error.NotAcceptable => .{ .code = 406, .message = "Not Acceptable" },
        error.RequestTimeout => .{ .code = 408, .message = "Request Timeout" },
        error.Conflict => .{ .code = 409, .message = "Conflict" },
        error.Gone => .{ .code = 410, .message = "Gone" },
        error.LengthRequired => .{ .code = 411, .message = "Length Required" },
        error.PreconditionFailed => .{ .code = 412, .message = "Precondition Failed" },
        error.PayloadTooLarge => .{ .code = 413, .message = "Content Too Large" },
        error.URITooLong => .{ .code = 414, .message = "URI Too Long" },
        error.UnsupportedMediaType => .{ .code = 415, .message = "Unsupported Media Type" },
        error.RangeNotSatisfiable => .{ .code = 416, .message = "Range Not Satisfiable" },
        error.ExpectationFailed => .{ .code = 417, .message = "Expectation Failed" },
        error.Teapot => .{ .code = 418, .message = "I'm a teapot" },
        error.UnprocessableEntity => .{ .code = 422, .message = "Unprocessable Content" },
        error.TooEarly => .{ .code = 425, .message = "Too Early" },
        error.UpgradeRequired => .{ .code = 426, .message = "Upgrade Required" },
        error.PreconditionRequired => .{ .code = 428, .message = "Precondition Required" },
        error.TooManyRequests => .{ .code = 429, .message = "Too Many Requests" },
        error.RequestHeaderFieldsTooLarge => .{ .code = 431, .message = "Request Header Fields Too Large" },
        error.UnavailableForLegalReasons => .{ .code = 451, .message = "Unavailable For Legal Reasons" },
        error.InternalServerError => .{ .code = 500, .message = "Internal Server Error" },
        error.NotImplemented => .{ .code = 501, .message = "Not Implemented" },
        error.BadGateway => .{ .code = 502, .message = "Bad Gateway" },
        error.ServiceUnavailable => .{ .code = 503, .message = "Service Unavailable" },
        error.GatewayTimeout => .{ .code = 504, .message = "Gateway Timeout" },
        error.HTTPVersionNotSupported => .{ .code = 505, .message = "HTTP Version Not Supported" },
        else => .{ .code = 500, .message = "Internal Server Error" },
    };
}
