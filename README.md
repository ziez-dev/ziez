# ziez

Declarative Zig web framework with comptime serialization, interceptor chains, and validation pipes.

## Requirements

- Zig 0.16.0+

## Quick Start

```bash
# Build library
zig build

# Run examples
zig build run                    # basic example → localhost:3000
zig build run-serialization      # serialization demo → localhost:3001
zig build run-interceptor-pipe   # interceptor & pipe demo → localhost:3002

# Run unit tests
zig build test
zig build test --summary all     # verbose per-file breakdown
```

## Project Structure

```
├── build.zig            # Build configuration
├── build.zig.zon        # Package manifest
├── src/                 # Framework source
│   ├── root.zig         # Public API re-exports
│   ├── app.zig          # App & server
│   ├── router.zig       # Route matching
│   ├── listener.zig     # HTTP server
│   ├── middleware.zig    # Middleware types
│   ├── request.zig      # Request struct
│   ├── response.zig     # Response builder
│   ├── interceptor.zig  # Interceptor system
│   ├── pipe.zig         # Validation pipes
│   ├── serializer.zig   # Declarative serialization
│   ├── env.zig          # .env loader
│   ├── multipart.zig    # Multipart parser
│   ├── exceptions.zig   # HTTP errors
│   └── util.zig         # URL parsing, route matching
├── tests/               # Unit tests (auto-discovered)
│   └── *.test.zig
└── examples/            # Example apps
    ├── basic.zig
    ├── serialization.zig
    └── interceptor_pipe.zig
```

## Usage

### Hello World

```zig
const std = @import("std");
const ziez = @import("ziez");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .message = "hello from ziez!" });
        }
    }.handler);

    try app.listen(io, "0.0.0.0:3000");
}
```

### Routing

```zig
// Named parameters
app.get("/users/:id", struct {
    fn handler(req: *ziez.Request, res: *ziez.Response) !void {
        const id = req.param("id").?;
        res.json(.{ .id = id });
    }
}.handler);

// Wildcard
app.all("/*", struct {
    fn handler(_: *ziez.Request, _: *ziez.Response) !void {
        return error.NotFound;
    }
}.handler);
```

### Request

```zig
// JSON body
const User = struct { name: []const u8 };
const user = req.body_json(User) orelse return error.BadRequest;

// URL-encoded form
const form = req.body_form();
const name = form.get("name").?;

// Multipart
var upload = try req.saveMultipart(.{
    .root_dir = "./uploads",
    .file_fields = &.{"upload"},
    .allowed_types = &.{"image/*", "application/pdf"},
});
defer upload.deinit();
const file = upload.getFile("upload").?;

// Query params
const page = req.query_get("page");
```

### Response

```zig
res.json(.{ .id = 1, .name = "Alice" });
res.status(201).json(.{ .created = true });
res.html("<h1>Hello</h1>");
res.redirect("/new-path");
res.set("content-type", "text/plain");
res.sendBody("raw bytes");
```

### Middleware

```zig
app.use(struct {
    fn handler(req: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
        std.debug.print("{s} {s}\n", .{ @tagName(req.method), req.path });
        next.call();
    }
}.handler);
```

### Error Handling

```zig
app.on_error(struct {
    fn handler(req: *ziez.Request, res: *ziez.Response, err: anyerror) void {
        const info = ziez.errorToResponse(err);
        const msg = res.error_message orelse info.message;
        res.status(info.code).json(.{
            .statusCode = info.code,
            .@"error" = msg,
        });
    }
}.handler);

// In handlers — throw with custom message
return ziez.throw(error.BadRequest, "name is required", res);
```

Available errors: `BadRequest`, `Unauthorized`, `Forbidden`, `NotFound`, `Teapot`, `UnprocessableEntity`, `TooManyRequests`, `InternalServerError`, `ServiceUnavailable`.

### Environment Variables

```zig
var env = try ziez.Env.load(allocator, ".env");
defer env.deinit();

const port = env.getInt("PORT", u16, 3000);
const host = env.getOr("HOST", "0.0.0.0");
const debug = env.getBool("DEBUG", false);
```

### Serialization

```zig
const User = struct {
    id: u64,
    name: []const u8,
    email: []const u8,
    password_hash: []const u8,
    role: []const u8,
    avatar: ?[]const u8,
};

// Exclude sensitive fields
const PublicUser = ziez.SerializerConfig(User){
    .exclude = &.{"password_hash"},
    .exclude_null = true,
};

res.serialize(&user, PublicUser);

// Or use serialized() wrapper for auto-serialization
app.get("/me", ziez.serialized(PublicUser, struct {
    fn handler(_: *ziez.Request) !User {
        return User{ ... };
    }
}.handler));
```

**SerializerConfig options:**

| Option | Type | Description |
|---|---|---|
| `fields` | `?[]const []const u8` | Whitelist — only include these fields |
| `exclude` | `[]const []const u8` | Blacklist — always exclude these fields |
| `transforms` | `?type` | Per-field transform functions |
| `computed` | `?type` | Computed/virtual fields |
| `nested` | `?type` | Nested serializer configs |
| `conditions` | `?type` | Per-field condition functions |
| `exclude_null` | `bool` | Omit null fields from output |
| `group_fields` | `?type` | Group name → field array mapping |
| `groups` | `[]const []const u8` | Active groups for this context |

### Interceptors

```zig
const timingInterceptor = struct {
    fn call(ctx: *ziez.InterceptorCtx) anyerror!void {
        std.debug.print("[START] {s}\n", .{ctx.req.path});
        try ctx.proceed();
        std.debug.print("[END] {s}\n", .{ctx.req.path});
    }
}.call;

// Global — runs for all routes
app.useInterceptor(timingInterceptor);

// Per-route — comptime chain
app.get("/users", ziez.intercept(.{timingInterceptor, loggingInterceptor}, handler));
```

Interceptors execute in onion order: first interceptor wraps second wraps handler. `ctx.proceed()` calls the next layer.

### Validation Pipes

```zig
// Parse route param as integer
app.get("/users/:id", ziez.paramInt("id", u64, struct {
    fn handler(_: *ziez.Request, res: *ziez.Response, id: u64) !void {
        res.json(.{ .id = id });
    }
}.handler));

// Validate UUID format
app.get("/docs/:docId", ziez.parseUUID("docId", handler));

// Parse boolean param
app.get("/active/:flag", ziez.parseBool("flag", handler));

// Parse query param as integer
app.get("/search", ziez.queryInt("page", u32, handler));

// Validate JSON body
app.post("/users", ziez.validateBody(CreateUser, handler));

// Validate with custom function
app.post("/users", ziez.validateBodyWith(CreateUser, isValidUser, handler));

// Custom transform
app.get("/items/:slug", ziez.pipeParam("slug", toUpper, handler));
```

## Writing Tests

Test files go in `tests/` with the naming convention `name.test.zig`. They are auto-discovered by the build system.

```zig
// tests/myfeature.test.zig
const std = @import("std");
const ziez = @import("ziez");

test "matchRoute finds exact match" {
    const r = ziez.matchRoute("/", "/");
    try std.testing.expect(r != null);
}
```

Run with `zig build test`.

## Adding as Dependency

In your project's `build.zig.zon`:

```zig
.dependencies = .{
    .ziez = .{
        .url = "https://github.com/user/ziez/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

In your `build.zig`:

```zig
const ziez_dep = b.dependency("ziez", .{
    .target = target,
    .optimize = optimize,
});
const ziez_mod = ziez_dep.module("ziez");

// Add to your executable
exe_mod.addImport("ziez", ziez_mod);
```

## License

MIT
