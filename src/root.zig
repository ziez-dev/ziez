const std = @import("std");

// ── Core ──────────────────────────────────────────────────────────────────────
pub const App = @import("core/app.zig").App;
pub const Router = @import("core/router.zig").Router;
pub const RouteGroup = @import("core/router.zig").RouteGroup;
pub const Request = @import("core/request.zig").Request;
pub const Response = @import("core/response.zig").Response;
pub const Next = @import("core/middleware.zig").Next;
pub const Middleware = @import("core/middleware.zig").Middleware;
pub const MiddlewareFn = @import("core/middleware.zig").MiddlewareFn;
pub const HandlerFn = @import("core/middleware.zig").HandlerFn;
pub const ErrorHandlerFn = @import("core/middleware.zig").ErrorHandlerFn;
pub const HttpMethod = @import("core/util.zig").HttpMethod;
pub const FileStat = @import("core/platform.zig").FileStat;
pub const platform = @import("core/platform.zig");

// ── Plugin provider types (for external plugin install functions) ──────────────
pub const RequestHook = @import("core/hook.zig").RequestHook;
pub const LogRequestFn = @import("core/listener.zig").LogRequestFn;
pub const CompressionFn = @import("core/listener.zig").CompressionFn;
pub const TlsHandleFn = @import("core/listener.zig").TlsHandleFn;
pub const RedirectRunFn = @import("core/listener.zig").RedirectRunFn;
pub const ConnConfig = @import("core/listener.zig").ConnConfig;
pub const RedirectPlan = @import("core/listener.zig").RedirectPlan;
pub const processRequests = @import("core/listener.zig").processRequests;
pub const handleRedirectConnection = @import("core/listener.zig").handleRedirectConnection;

// ── Env ───────────────────────────────────────────────────────────────────────
pub const Env = @import("core/env.zig").Env;
pub const getProcessEnv = @import("core/env.zig").getProcessEnv;

// ── Exceptions ────────────────────────────────────────────────────────────────
pub const Exception = @import("core/exceptions.zig").Exception;
pub const HttpError = @import("core/exceptions.zig").HttpError;
pub const errorToResponse = @import("core/exceptions.zig").errorToResponse;
pub const throw = @import("core/exceptions.zig").throw;

// ── Logging ───────────────────────────────────────────────────────────────────
pub const logging = @import("core/logging.zig");
pub const Logger = @import("core/logging.zig").Logger;
pub const LoggerConfig = @import("core/logging.zig").LoggerConfig;
pub const LogLevel = @import("core/logging.zig").LogLevel;
pub const LogSink = @import("core/logging.zig").Sink;

// ── URL / query utilities ─────────────────────────────────────────────────────
pub const FormParams = @import("core/util.zig").FormParams;
pub const Params = @import("core/util.zig").Params;
pub const QueryParams = @import("core/util.zig").QueryParams;
pub const matchRoute = @import("core/util.zig").matchRoute;
pub const parseQuery = @import("core/util.zig").parseQuery;
pub const parseForm = @import("core/util.zig").parseForm;
pub const splitPathQuery = @import("core/util.zig").splitPathQuery;
pub const percentDecode = @import("core/util.zig").percentDecode;

// ── Cookie utilities ──────────────────────────────────────────────────────────
pub const Cookies = @import("core/util.zig").Cookies;
pub const CookieOptions = @import("core/util.zig").CookieOptions;
pub const SameSite = @import("core/util.zig").SameSite;
pub const parseCookies = @import("core/util.zig").parseCookies;
pub const formatSetCookie = @import("core/util.zig").formatSetCookie;
pub const signCookie = @import("core/util.zig").signCookie;
pub const verifySignedCookie = @import("core/util.zig").verifySignedCookie;

// ── Multipart ─────────────────────────────────────────────────────────────────
pub const Multipart = @import("multipart/mod.zig").Multipart;
pub const Part = @import("multipart/mod.zig").Part;
pub const FormField = @import("multipart/mod.zig").FormField;
pub const UploadedFile = @import("multipart/mod.zig").UploadedFile;
pub const MultipartUpload = @import("multipart/mod.zig").MultipartUpload;
pub const UploadConfig = @import("multipart/mod.zig").UploadConfig;

// ── Serializer ────────────────────────────────────────────────────────────────
pub const SerializerConfig = @import("serializer/mod.zig").SerializerConfig;
pub const serialize = @import("serializer/mod.zig").serialize;
pub const serializeMany = @import("serializer/mod.zig").serializeMany;
pub const serialized = @import("core/interceptor.zig").serialized;

// ── Validator / Schema ────────────────────────────────────────────────────────
pub const validator = @import("validator/mod.zig");
pub const schema = @import("validator/schema.zig");

// ── Pipe helpers ──────────────────────────────────────────────────────────────
pub const intercept = @import("core/interceptor.zig").intercept;
pub const paramInt = @import("core/pipe.zig").paramInt;
pub const parseUUID = @import("core/pipe.zig").parseUUID;
pub const parseBool = @import("core/pipe.zig").parseBool;
pub const validateBody = @import("core/pipe.zig").validateBody;
pub const validateBodyWith = @import("core/pipe.zig").validateBodyWith;
pub const pipeParam = @import("core/pipe.zig").pipeParam;
pub const queryInt = @import("core/pipe.zig").queryInt;
pub const isValidUUID = @import("core/pipe.zig").isValidUUID;
pub const validateBodySchema = @import("core/pipe.zig").validateBodySchema;
pub const validateBodyWithSchema = @import("core/pipe.zig").validateBodyWithSchema;
pub const validateQuerySchema = @import("core/pipe.zig").validateQuerySchema;

// ── Streaming ─────────────────────────────────────────────────────────────────
pub const StreamWriter = @import("core/stream.zig").StreamWriter;
pub const NdjsonStreamWriter = @import("core/stream.zig").NdjsonStreamWriter;
pub const SseStreamWriter = @import("core/stream.zig").SseStreamWriter;
pub const CsvStreamWriter = @import("core/stream.zig").CsvStreamWriter;
pub const JsonArrayStreamWriter = @import("core/stream.zig").JsonArrayStreamWriter;
pub const StreamCallback = @import("core/stream.zig").StreamCallback;
pub const NdjsonCallback = @import("core/stream.zig").NdjsonCallback;
pub const SseCallback = @import("core/stream.zig").SseCallback;
pub const CsvCallback = @import("core/stream.zig").CsvCallback;
pub const JsonArrayCallback = @import("core/stream.zig").JsonArrayCallback;
pub const CsvStreamConfig = @import("core/stream.zig").CsvStreamConfig;
pub const FileStreamConfig = @import("core/response.zig").Response.FileStreamConfig;
pub const parseRange = @import("core/stream.zig").parseRange;
pub const ParsedRange = @import("core/stream.zig").ParsedRange;

pub fn init(allocator: std.mem.Allocator) App {
    return App.init(allocator);
}
