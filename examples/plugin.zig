const std = @import("std");
const ziez = @import("ziez");

// ---------------------------------------------------------------------------
// Pattern A: simple plugin (no cleanup)
// Install a response-time header on every request.
// Pass by value — struct needs only plugin_name, plugin_version, install().
// ---------------------------------------------------------------------------

const ResponseTimePlugin = struct {
    pub const plugin_name = "response-time";
    pub const plugin_version = "1.0.0";

    header_name: []const u8,

    pub fn install(self: *ResponseTimePlugin, app: *ziez.App) !void {
        _ = self;
        app.use(struct {
            fn mw(req: *ziez.Request, res: *ziez.Response, next: *ziez.Next) void {
                _ = req;
                next.call();
                _ = res.set("x-response-time", "0ms");
            }
        }.mw);
    }
};

// ---------------------------------------------------------------------------
// Pattern B: stateful plugin (heap-allocated, owns resources, has deinit)
// Simulate a plugin that holds a counter or external connection.
// ---------------------------------------------------------------------------

const MetricsPlugin = struct {
    request_count: u64,
    allocator: std.mem.Allocator,

    pub fn install(self: *MetricsPlugin, app: *ziez.App) !void {
        _ = self;
        app.use(struct {
            fn mw(req: *ziez.Request, res: *ziez.Response, next: *ziez.Next) void {
                _ = req;
                _ = res;
                next.call();
            }
        }.mw);
    }

    pub fn deinit(self: *MetricsPlugin, alloc: std.mem.Allocator) void {
        std.debug.print("MetricsPlugin: recorded {d} requests\n", .{self.request_count});
        alloc.destroy(self);
    }

    pub fn asPlugin(self: *MetricsPlugin) ziez.Plugin {
        return ziez.makePlugin("metrics", "1.0.0", MetricsPlugin, self);
    }
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    app.logging(.{ .level = .info });

    // Pattern A — struct by value, framework handles type erasure
    app.plugin(ResponseTimePlugin{ .header_name = "x-response-time" });

    // Pattern B — stateful, heap-allocated, deinit called by app.deinit()
    const metrics = try allocator.create(MetricsPlugin);
    metrics.* = .{ .request_count = 0, .allocator = allocator };
    app.plugin(metrics.asPlugin());

    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .message = "plugin system working!", .patterns = .{ "A", "B" } });
        }
    }.handler);

    std.debug.print("Plugin example listening on :3000\n", .{});
    std.debug.print("  GET /  — response includes x-response-time header\n", .{});
    try app.listen(io, "0.0.0.0:3000");
}
