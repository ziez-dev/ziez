const std = @import("std");
const ziez = @import("ziez");

// CORS and security are enabled by default (with_cors=true, with_security=true).
// Run with: zig build run-cors-security

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    // Allow specific origins, require credentials header.
    app.router.useCors(.{
        .origins = .{ .list = &.{
            "https://app.example.com",
            "https://admin.example.com",
        } },
        .methods = &.{ .GET, .POST, .PUT, .DELETE, .OPTIONS },
        .allowed_headers = &.{ "Content-Type", "Authorization", "X-Request-ID" },
        .credentials = true,
        .max_age = 86400,
    });

    // Apply security headers (Helmet) and XSS sanitization on request bodies.
    app.router.useSecurity(.{
        .helmet = .{
            .content_security_policy = .{
                .use_defaults = true,
                .directives = &.{
                    .{ .name = "script-src", .values = &.{ "'self'", "'nonce-abc123'" } },
                },
            },
            .strict_transport_security = .{
                .max_age = 63_072_000,
                .include_sub_domains = true,
                .preload = true,
            },
            .x_frame_options = "DENY",
        },
        .xss = .{
            .sanitize_body = true,
            .sanitize_query = true,
            .mode = .strip,
        },
    });

    app.get("/api/users", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .users = &[_][]const u8{ "alice", "bob" } });
        }
    }.handler);

    app.post("/api/comment", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const Body = struct { text: []const u8 };
            const body = req.body_json(Body) orelse
                return ziez.throw(error.BadRequest, "body must be JSON with 'text' field", res);
            // body.text has already been XSS-stripped by the security middleware.
            res.status(201).json(.{ .saved = body.text });
        }
    }.handler);

    std.debug.print("CORS + Security server listening on :3000\n", .{});
    try app.listen(io, "0.0.0.0:3000");
}
