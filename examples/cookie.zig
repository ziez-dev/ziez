const std = @import("std");
const ziez = @import("ziez");

const SESSION_SECRET = "super-secret-hmac-key-minimum-32-characters!!";

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var app = ziez.init(allocator);
    defer app.deinit();

    app.logging(.{ .level = .info });

    app.on_error(struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, err: anyerror) void {
            const info = ziez.errorToResponse(err);
            const msg = res.error_message orelse info.message;
            res.status(info.code).json(.{ .@"error" = msg, .statusCode = info.code });
        }
    }.handler);

    // POST /login — authenticate and set a signed session cookie
    app.post("/login", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const Creds = struct { username: []const u8, password: []const u8 };
            const creds = req.body_json(Creds) orelse
                return ziez.throw(error.BadRequest, "username and password required", res);

            if (!std.mem.eql(u8, creds.username, "admin") or
                !std.mem.eql(u8, creds.password, "secret"))
            {
                return ziez.throw(error.Unauthorized, "invalid credentials", res);
            }

            try res.setSignedCookie("session", "user:admin", .{
                .http_only = true,
                .same_site = .strict,
                .max_age = 3600,
                .path = "/",
            }, SESSION_SECRET);

            res.json(.{ .message = "logged in", .user = creds.username });
        }
    }.handler);

    // GET /profile — verify signed cookie and return user info
    app.get("/profile", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const session = req.signedCookie("session", SESSION_SECRET) orelse
                return ziez.throw(error.Unauthorized, "missing or invalid session", res);
            defer req.allocator.free(session);

            res.json(.{ .session = session, .authenticated = true });
        }
    }.handler);

    // GET /theme — set a plain (unsigned) preference cookie
    app.get("/theme", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const theme = req.query_get("set") orelse "dark";
            res.setCookie("theme", theme, .{
                .path = "/",
                .max_age = 86400 * 30,
                .same_site = .lax,
            });
            res.json(.{ .message = "theme cookie set", .theme = theme });
        }
    }.handler);

    // GET /prefs — read the theme cookie back
    app.get("/prefs", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const theme = req.cookie("theme") orelse "system";
            res.json(.{ .theme = theme });
        }
    }.handler);

    // POST /logout — clear session cookie
    app.post("/logout", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.clearCookie("session", .{ .path = "/" });
            res.json(.{ .message = "logged out" });
        }
    }.handler);

    std.debug.print("Cookie example listening on :3000\n", .{});
    std.debug.print("  POST /login    {{\"username\":\"admin\",\"password\":\"secret\"}}\n", .{});
    std.debug.print("  GET  /profile  Cookie: session=<signed-value>\n", .{});
    std.debug.print("  GET  /theme?set=dark\n", .{});
    std.debug.print("  GET  /prefs    Cookie: theme=dark\n", .{});
    std.debug.print("  POST /logout\n", .{});
    try app.listen("0.0.0.0:3000");
}
