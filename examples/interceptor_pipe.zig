const std = @import("std");
const ziez = @import("ziez");

// --- Domain ---

const User = struct {
    id: u64,
    name: []const u8,
    email: []const u8,
    role: []const u8,
};

const CreateUser = struct {
    name: []const u8,
    email: []const u8,
};

var mock_users = [_]User{
    .{ .id = 1, .name = "Alice", .email = "alice@test.com", .role = "admin" },
    .{ .id = 2, .name = "Bob", .email = "bob@test.com", .role = "user" },
};

// --- Interceptors ---

const timingInterceptor = struct {
    fn call(ctx: *ziez.InterceptorCtx) anyerror!void {
        std.debug.print("[TIMING] {s} start\n", .{ctx.req.path});
        try ctx.proceed();
        std.debug.print("[TIMING] {s} end -> {}\n", .{ ctx.req.path, ctx.res.status_code });
    }
}.call;

const loggingInterceptor = struct {
    fn call(ctx: *ziez.InterceptorCtx) anyerror!void {
        std.debug.print("[LOG] {s} {s}\n", .{ @tagName(ctx.req.method), ctx.req.path });
        try ctx.proceed();
        std.debug.print("[LOG] {s} -> {}\n", .{ ctx.req.path, ctx.res.status_code });
    }
}.call;

// --- Validation ---

const isValidUser = struct {
    fn call(user: CreateUser) bool {
        return user.name.len >= 2 and std.mem.indexOfScalar(u8, user.email, '@') != null;
    }
}.call;

// --- Serializer config ---

const UserSerializer = ziez.SerializerConfig(User){
    .fields = &.{ "id", "name", "email", "role" },
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    // Global interceptor — runs for ALL routes
    app.useInterceptor(timingInterceptor);

    // Logger middleware
    app.use(struct {
        fn handler(req: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            std.debug.print("[MW] {s} {s}\n", .{ @tagName(req.method), req.path });
            next.call();
        }
    }.handler);

    // Error handler
    app.on_error(struct {
        fn handler(req: *ziez.Request, res: *ziez.Response, err: anyerror) void {
            const info = ziez.errorToResponse(err);
            const msg = res.error_message orelse info.message;
            std.debug.print("[ERROR] {s} -> {} ({s})\n", .{ req.path, info.code, msg });
            res.status(info.code).json(.{
                .statusCode = info.code,
                .@"error" = msg,
            });
        }
    }.handler);

    // GET / — simple health check
    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .status = "ok", .framework = "ziez" });
        }
    }.handler);

    // GET /users — list users with per-route interceptor
    app.get("/users", ziez.intercept(.{loggingInterceptor}, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.serializeMany(&mock_users, UserSerializer);
        }
    }.handler));

    // GET /users/:id — paramInt pipe parses :id as u64
    app.get("/users/:id", ziez.paramInt("id", u64, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, id: u64) !void {
            for (&mock_users) |*user| {
                if (user.id == id) {
                    res.serialize(user, UserSerializer);
                    return;
                }
            }
            return ziez.throw(error.NotFound, "user not found", res);
        }
    }.handler));

    // GET /documents/:docId — parseUUID pipe validates UUID
    app.get("/documents/:docId", ziez.parseUUID("docId", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, doc_id: []const u8) !void {
            res.json(.{ .documentId = doc_id, .status = "found" });
        }
    }.handler));

    // GET /search — queryInt pipe parses query param
    app.get("/search", ziez.queryInt("page", u32, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, page: u32) !void {
            res.json(.{ .page = page, .results = "none" });
        }
    }.handler));

    // POST /users — validateBodyWith pipe validates JSON body
    app.post("/users", ziez.validateBodyWith(CreateUser, isValidUser, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, user: CreateUser) !void {
            std.debug.print("[CREATE] name={s} email={s}\n", .{ user.name, user.email });
            res.status(201).json(.{ .id = 3, .name = user.name, .email = user.email });
        }
    }.handler));

    // GET /active/:flag — parseBool pipe
    app.get("/active/:flag", ziez.parseBool("flag", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, active: bool) !void {
            res.json(.{ .active = active });
        }
    }.handler));

    try app.listen(io, "0.0.0.0:3002");
}
