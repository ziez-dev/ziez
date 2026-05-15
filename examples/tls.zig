const std = @import("std");
const ziez = @import("ziez");

// Build with: zig build -Dwith_tls=true
// Run with:   zig build run-tls -Dwith_tls=true

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    // Redirect plain HTTP (port 80) to HTTPS automatically.
    // Requests to /.well-known/acme-challenge are excluded for ACME/Let's Encrypt.
    app.redirectHttp(.{
        .port = 80,
        .to = 3443,
        .exclude = &.{"/.well-known/acme-challenge"},
    });

    // Configure TLS — swap cert/key paths for real PEM files.
    app.tls(.{
        .cert = .{ .file_path = "cert.pem" },
        .key = .{ .file_path = "key.pem" },
        .min_version = .tls_1_2,
        .cipher_suites = &.{
            .AES_128_GCM_SHA256,
            .AES_256_GCM_SHA384,
            .CHACHA20_POLY1305_SHA256,
        },
    });

    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .secure = true, .message = "Hello over HTTPS!" });
        }
    }.handler);

    app.get("/health", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .status = "ok" });
        }
    }.handler);

    std.debug.print("HTTPS listening on :3443 (HTTP :80 → :3443)\n", .{});
    try app.listen(io, "0.0.0.0:3443");
}
