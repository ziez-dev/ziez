const std = @import("std");
const ziez = @import("ziez");

const Allocator = std.mem.Allocator;

test "Integration: basic.zig example handler logic" {
    const allocator = std.testing.allocator;

    // Test GET / handler
    {
        var app = ziez.init(allocator);
        defer app.deinit();

        app.get("/", struct {
            fn handler(_: *ziez.Request, res: *ziez.Response) !void {
                res.json(.{ .message = "hello from ziez!" });
            }
        }.handler);
    }

    // Test GET /users/:id handler with valid id
    {
        var app = ziez.init(allocator);
        defer app.deinit();

        app.get("/users/:id", struct {
            fn handler(req: *ziez.Request, res: *ziez.Response) !void {
                const id = req.param("id") orelse return error.BadRequest;
                if (id.len > 10) return error.NotFound;
                res.json(.{ .id = id });
            }
        }.handler);
    }

    // Test POST /users handler
    {
        var app = ziez.init(allocator);
        defer app.deinit();

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
    }

    // Test POST /login handler
    {
        var app = ziez.init(allocator);
        defer app.deinit();

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
    }

    // Test error handlers
    {
        var app = ziez.init(allocator);
        defer app.deinit();

        app.get("/admin", struct {
            fn handler(_: *ziez.Request, _: *ziez.Response) !void {
                return error.Forbidden;
            }
        }.handler);

        app.get("/teapot", struct {
            fn handler(_: *ziez.Request, _: *ziez.Response) !void {
                return error.Teapot;
            }
        }.handler);

        app.get("/slow", struct {
            fn handler(_: *ziez.Request, _: *ziez.Response) !void {
                return error.ServiceUnavailable;
            }
        }.handler);
    }

    // Test 404 handler
    {
        var app = ziez.init(allocator);
        defer app.deinit();

        app.all("/*", struct {
            fn handler(_: *ziez.Request, _: *ziez.Response) !void {
                return error.NotFound;
            }
        }.handler);
    }
}
