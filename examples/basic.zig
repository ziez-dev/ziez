const std = @import("std");
const ziez = @import("ziez");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    // Global error handler - catches all thrown errors
    app.on_error(struct {
        fn handler(req: *ziez.Request, res: *ziez.Response, err: anyerror) void {
            const info = ziez.errorToResponse(err);
            const msg = res.error_message orelse info.message;
            std.debug.print("[ziez] ERROR {s} → {} ({s})\n", .{ req.path, info.code, msg });
            res.status(info.code).json(.{
                .statusCode = info.code,
                .@"error" = msg,
                .path = req.path,
            });
        }
    }.handler);

    // Logger middleware
    app.use(struct {
        fn handler(req: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            std.debug.print("[ziez] {s} {s}\n", .{ @tagName(req.method), req.path });
            next.call();
        }
    }.handler);

    // GET /
    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .message = "hello from ziez!" });
        }
    }.handler);

    // GET /users/:id - throw NotFound if id too long
    app.get("/users/:id", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const id = req.param("id") orelse return error.BadRequest;
            if (id.len > 10) return error.NotFound;
            res.json(.{ .id = id });
        }
    }.handler);

    // POST /users - JSON body, throw with custom messages
    app.post("/users", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const User = struct { name: []const u8 };
            const user = req.body_json(User) orelse
                return ziez.throw(error.BadRequest, "request body must be valid JSON", res);
            if (user.name.len == 0)
                return ziez.throw(error.UnprocessableEntity, "name cannot be empty", res);
            res.status(201).json(.{ .id = 1, .name = user.name });
        }
    }.handler);

    // POST /login - throw with custom messages
    app.post("/login", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const Creds = struct { username: []const u8, password: []const u8 };
            const creds = req.body_json(Creds) orelse
                return ziez.throw(error.BadRequest, "username and password required", res);
            if (!std.mem.eql(u8, creds.username, "admin") or !std.mem.eql(u8, creds.password, "secret")) {
                return ziez.throw(error.Unauthorized, "invalid username or password", res);
            }
            res.json(.{ .token = "jwt-token-here" });
        }
    }.handler);

    // POST /contact - URL-encoded form
    app.post("/contact", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const form = req.body_form();
            const name = form.get("name") orelse return error.BadRequest;
            const email = form.get("email") orelse return error.BadRequest;
            res.json(.{ .message = "received", .name = name, .email = email });
        }
    }.handler);

    // GET /admin - throw Forbidden
    app.get("/admin", struct {
        fn handler(_: *ziez.Request, _: *ziez.Response) !void {
            return error.Forbidden;
        }
    }.handler);

    // GET /teapot - easter egg
    app.get("/teapot", struct {
        fn handler(_: *ziez.Request, _: *ziez.Response) !void {
            return error.Teapot;
        }
    }.handler);

    // GET /slow - throw ServiceUnavailable
    app.get("/slow", struct {
        fn handler(_: *ziez.Request, _: *ziez.Response) !void {
            return error.ServiceUnavailable;
        }
    }.handler);

    // Catch-all 404
    app.all("/*", struct {
        fn handler(_: *ziez.Request, _: *ziez.Response) !void {
            return error.NotFound;
        }
    }.handler);

    try app.listen(io, "0.0.0.0:3000");
}
