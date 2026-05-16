const std = @import("std");
const ziez = @import("ziez");

fn monotonicNs() i128 {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    return @as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds));
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    // Structured JSON logger — tracker will emit request summaries through it.
    app.logging(.{ .level = .info });

    // Request tracking middleware — parses User-Agent and logs a summary after
    // every request.  This is a lightweight example; in production the tracker
    // module can be wired into the listener directly.
    app.use(struct {
        fn handler(req: *ziez.Request, res: *ziez.Response, next: *ziez.Next) void {
            const t0 = monotonicNs();
            next.call();
            const elapsed_ms: f64 = @as(f64, @floatFromInt(monotonicNs() - t0)) / 1_000_000.0;

            const summary = ziez.buildRequestSummary(
                req.request_id,
                @tagName(req.method),
                req.path,
                res.status_code,
                elapsed_ms,
                req.header("user-agent"),
                null,
                .{ .ua_parser_enabled = true },
            );

            if (res.logger) |log| ziez.logRequestSummary(log, summary);
        }
    }.handler);

    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .message = "check your terminal for the request summary log!" });
        }
    }.handler);

    app.get("/ua", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const ua_str = req.header("user-agent") orelse "";
            const parsed = ziez.ua_parser.parse(ua_str);
            res.json(.{
                .raw = ua_str,
                .browser = .{
                    .name = parsed.browser.name,
                    .version = parsed.browser.version,
                    .major = parsed.browser.major,
                },
                .os = .{
                    .name = parsed.os.name,
                    .version = parsed.os.version,
                },
                .device = .{
                    .type = ziez.ua_parser.deviceTypeToString(parsed.device.type),
                    .vendor = parsed.device.vendor,
                    .model = parsed.device.model,
                },
                .engine = .{
                    .name = parsed.engine.name,
                    .version = parsed.engine.version,
                },
                .cpu = .{ .arch = parsed.cpu.architecture },
            });
        }
    }.handler);

    std.debug.print("Tracker example listening on :3000\n", .{});
    std.debug.print("  GET /    — basic request with auto-logged summary\n", .{});
    std.debug.print("  GET /ua  — parse and return User-Agent breakdown\n", .{});
    try app.listen(io, "0.0.0.0:3000");
}
