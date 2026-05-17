const std = @import("std");
const ziez = @import("ziez");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // Load .env file — does NOT error if file is missing, returns empty Env
    var env = try ziez.Env.load(allocator, ".env");
    defer env.deinit();

    // Typed access with defaults
    const port = env.getInt("PORT", u16, 3000);
    const host = env.getOr("HOST", "0.0.0.0");
    const debug = env.getBool("DEBUG", false);
    const app_name = env.getOr("APP_NAME", "ziez-app");
    const db_url = env.getOr("DATABASE_URL", "");
    const api_version = env.getInt("API_VERSION", u8, 1);

    // getRequired errors if key is missing
    // const secret = try env.getRequired("JWT_SECRET");

    std.debug.print("=== {s} configuration ===\n", .{app_name});
    std.debug.print("  HOST:PORT  : {s}:{d}\n", .{ host, port });
    std.debug.print("  DEBUG      : {}\n", .{debug});
    std.debug.print("  API_VERSION: v{d}\n", .{api_version});
    std.debug.print("  DATABASE_URL: {s}\n", .{if (db_url.len > 0) db_url else "(not set)"});

    var app = ziez.init(allocator);
    defer app.deinit();

    if (debug) {
        app.logging(.{ .level = .debug });
        std.debug.print("[debug] verbose logging enabled\n", .{});
    }

    // Env values are used at startup for configuration.
    // In Zig, inner functions cannot capture runtime variables directly;
    // pass configuration via global state or route context if needed at request time.
    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .status = "ok", .framework = "ziez" });
        }
    }.handler);

    app.get("/health", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .healthy = true });
        }
    }.handler);

    var addr_buf: [64]u8 = undefined;
    const address = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port }) catch unreachable;
    std.debug.print("Env example listening on {s}\n", .{address});
    try app.listen(address);
}
