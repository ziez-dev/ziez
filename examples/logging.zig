const std = @import("std");
const ziez = @import("ziez");

// ---------------------------------------------------------------------------
// Custom log sink — writes JSON-like lines to stderr with timestamp
// ---------------------------------------------------------------------------

const JsonSink = struct {
    fn write(_: ?*anyopaque, level: ziez.LogLevel, line: []const u8) void {
        const level_str: []const u8 = switch (level) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .@"error" => "ERROR",
            .fatal => "FATAL",
        };
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\n')
            line[0 .. line.len - 1]
        else
            line;
        std.debug.print("[{s}] {s}\n", .{ level_str, trimmed });
    }

    fn sink() ziez.LogSink {
        return .{ .context = null, .writeFn = write };
    }
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    // Configure: DEBUG level, custom JSON sink, redact Authorization header
    app.logging(.{
        .level = .debug,
        .sink = JsonSink.sink(),
        .redact = &.{"authorization"},
    });

    app.on_error(struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, err: anyerror) void {
            const info = ziez.errorToResponse(err);
            res.status(info.code).json(.{ .statusCode = info.code, .@"error" = info.message });
        }
    }.handler);

    // GET / — successful request (shows info-level log)
    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .status = "ok" });
        }
    }.handler);

    // GET /debug — only visible with debug-level sink
    app.get("/debug", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .level = "debug", .message = "debug output enabled" });
        }
    }.handler);

    // GET /warn — returns 429 to generate a warn-level log
    app.get("/warn", struct {
        fn handler(_: *ziez.Request, _: *ziez.Response) !void {
            return error.TooManyRequests;
        }
    }.handler);

    // GET /fail — returns 500 to generate an error-level log
    app.get("/fail", struct {
        fn handler(_: *ziez.Request, _: *ziez.Response) !void {
            return error.InternalServerError;
        }
    }.handler);

    std.debug.print("Logging example listening on :3000\n", .{});
    std.debug.print("  Log level: DEBUG  (all requests logged)\n", .{});
    std.debug.print("  Sink: custom JSON-like stderr\n", .{});
    std.debug.print("  Redacted: authorization header\n", .{});
    std.debug.print("  GET /        — 200 info log\n", .{});
    std.debug.print("  GET /debug   — 200 debug log\n", .{});
    std.debug.print("  GET /warn    — 429 warn log\n", .{});
    std.debug.print("  GET /fail    — 500 error log\n", .{});
    try app.listen(io, "0.0.0.0:3000");
}
