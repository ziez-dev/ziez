const std = @import("std");
const ziez = @import("ziez");

// Build with: zig build -Dwith_compression=true
// Run with:   zig build run-compression -Dwith_compression=true

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    // Enable response compression.
    // Only compresses responses >= threshold bytes for listed MIME types.
    // Brotli is included to leverage the brotli C library dependency.
    app.compress(.{
        .enabled = true,
        .threshold = 512,
        .algorithms = &.{ .brotli, .gzip, .deflate },
    });

    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .message = "This response will be compressed if the client accepts it." });
        }
    }.handler);

    // Returns a larger payload that will always hit the threshold.
    app.get("/data", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            const Item = struct { id: u32, name: []const u8, value: f64 };
            const items = [_]Item{
                .{ .id = 1, .name = "alpha",   .value = 1.1 },
                .{ .id = 2, .name = "beta",    .value = 2.2 },
                .{ .id = 3, .name = "gamma",   .value = 3.3 },
                .{ .id = 4, .name = "delta",   .value = 4.4 },
                .{ .id = 5, .name = "epsilon", .value = 5.5 },
            };
            res.json(.{ .items = items[0..] });
        }
    }.handler);

    std.debug.print("Compression server listening on :3000\n", .{});
    try app.listen(io, "0.0.0.0:3000");
}
