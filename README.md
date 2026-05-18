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
zig build run-streaming          # streaming demo
zig build run-multipart          # file upload demo
zig build run-env                # .env loader demo
zig build run-cookie             # cookie management demo
zig build run-validation         # validator + schema + pipes demo
zig build run-logging            # custom logger demo

# Run unit tests
zig build test
zig build test --summary all     # verbose per-file breakdown
```

## Project Structure

```
├── build.zig            # Build configuration
├── build.zig.zon        # Package manifest
├── src/
│   ├── root.zig         # Public API re-exports
│   ├── app.zig          # App & server
│   ├── router.zig       # Route matching
│   ├── listener.zig     # HTTP server
│   ├── middleware.zig    # Middleware types
│   ├── request.zig      # Request struct
│   ├── response.zig     # Response builder
│   ├── interceptor.zig  # Interceptor system
│   ├── pipe.zig         # Validation pipes
│   ├── hook.zig         # Request hook system
│   ├── stream.zig       # Streaming writers (SSE, NDJSON, CSV, etc.)
│   ├── logging.zig      # Structured JSON logger
│   ├── platform.zig     # Cross-platform utilities
│   ├── env.zig          # .env loader
│   ├── multipart/       # Multipart parser
│   ├── exceptions.zig   # HTTP errors
│   ├── util.zig         # URL parsing, form handling, cookies
│   ├── validator/       # Validation framework + schema
│   │   ├── mod.zig
│   │   └── schema.zig
│   └── serializer/      # Declarative serialization
│       └── mod.zig
├── tests/               # Unit tests (auto-discovered)
│   └── *.test.zig
└── examples/            # Example apps
    ├── basic.zig
    ├── serialization.zig
    ├── interceptor_pipe.zig
    ├── streaming.zig
    ├── multipart.zig
    ├── env.zig
    ├── cookie.zig
    ├── validation.zig
    └── logging.zig
```

## Usage

### Hello World

```zig
const std = @import("std");
const ziez = @import("ziez");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var app = ziez.init(allocator);
    defer app.deinit();

    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .message = "hello from ziez!" });
        }
    }.handler);

    try app.listen("0.0.0.0:3000");
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

### Streaming

```zig
// NDJSON streaming
app.get("/stream/ndjson", struct {
    fn handler(_: *ziez.Request, res: *ziez.Response) !void {
        res.streamNdjson(struct {
            fn write(sw: *ziez.NdjsonStreamWriter) anyerror!void {
                try sw.writeObject(.{ .index = 1, .message = "hello" });
            }
        }.write);
    }
}.handler);

// Server-Sent Events
app.get("/stream/sse", struct {
    fn handler(_: *ziez.Request, res: *ziez.Response) !void {
        res.streamSse(struct {
            fn write(sw: *ziez.SseStreamWriter) anyerror!void {
                try sw.setEvent("message");
                try sw.setData("hello");
            }
        }.write);
    }
}.handler);

// CSV streaming
res.streamCsv(.{ .write_bom = true }, struct {
    fn write(sw: *ziez.CsvStreamWriter) anyerror!void {
        try sw.writeRow(&.{"ID", "Name"});
        try sw.writeRow(&.{"1", "Alice"});
    }
}.write);

// JSON array streaming
res.streamJsonArray(struct {
    fn write(sw: *ziez.JsonArrayStreamWriter) anyerror!void {
        try sw.writeItem(.{ .id = 1, .name = "item" });
    }
}.write);

// Plain text streaming
res.streamText(struct {
    fn write(sw: *ziez.StreamWriter) anyerror!void {
        try sw.write("chunk\n");
        try sw.flush();
    }
}.write);
```

### Logging

```zig
// Configure with custom sink and field redaction
app.logging(.{
    .level = .debug,
    .sink = myCustomSink(),
    .redact = &.{"authorization"},
});

// Child logger with persistent fields
const req_logger = logger.child(.{ .request_id = "abc123" });
req_logger.info("request started", .{});
```

**LoggerConfig options:**

| Option | Type | Default | Description |
|---|---|---|---|
| `level` | `LogLevel` | `.info` | Minimum log level (trace/debug/info/warn/error/fatal) |
| `redact` | `[]const []const u8` | `&.{}` | Field paths to redact from output |
| `sink` | `?LogSink` | `null` | Custom output destination (default: stderr) |

### Cookies

```zig
// Set cookie with options
res.setCookie("theme", "dark", .{
    .path = "/",
    .max_age = 86400 * 30,
    .same_site = .lax,
});

// Signed cookie (HMAC-SHA256)
try res.setSignedCookie("session", "user:admin", .{
    .http_only = true,
    .same_site = .strict,
    .max_age = 3600,
}, secret);

// Read cookies
const theme = req.cookie("theme") orelse "system";
const session = req.signedCookie("session", secret) orelse
    return ziez.throw(error.Unauthorized, "invalid session", res);

// Clear cookie
res.clearCookie("session", .{ .path = "/" });
```

**CookieOptions:**

| Option | Type | Default | Description |
|---|---|---|---|
| `max_age` | `?u32` | `null` | Max age in seconds |
| `http_only` | `bool` | `false` | HttpOnly flag |
| `secure` | `bool` | `false` | Secure flag |
| `same_site` | `SameSite` | — | `strict`, `lax`, or `none` |
| `path` | `[]const u8` | `"/"` | Cookie path |
| `domain` | `?[]const u8` | `null` | Cookie domain |
| `partitioned` | `bool` | `false` | Partitioned (CHIPS) |

### Validation

```zig
// Standalone validators
const valid_email = ziez.validator.isEmail("user@example.com");
const valid_url = ziez.validator.isURL("https://example.com", .{});
const valid_uuid = ziez.validator.isUUID("550e8400-e29b-41d4-a716-446655440000");
const strong = ziez.validator.isStrongPassword("MyP@ss123", .{});
```

**Available validators:** `isEmail`, `isURL`, `isIP`, `isIPv4`, `isIPv6`, `isUUID`, `isCreditCard`, `isSlug`, `isStrongPassword`, `isAscii`, `isAlpha`, `isAlphanumeric`, `isNumeric`, `isDate`, `isISO8601`, `isBase64`, `isJSON`, `isPostalCode`, `isMobilePhone`, and more.

### Schema Validation

```zig
const CreateUser = struct {
    name: []const u8,
    email: []const u8,
    age: i64,

    pub const rules = .{
        .name = ziez.schema.StringRule{ .min_length = 2, .max_length = 64 },
        .email = ziez.schema.StringRule{ .format = .email },
        .age = ziez.schema.IntRule{ .min = 18, .max = 120 },
    };
};

// Validate JSON body against schema
app.post("/users", ziez.validateBodySchema(CreateUser, struct {
    fn handler(_: *ziez.Request, res: *ziez.Response, user: CreateUser) !void {
        res.status(201).json(.{ .name = user.name });
    }
}.handler));

// Validate query params
app.get("/search", ziez.validateQuerySchema(SearchQuery, handler));
```

**Schema rules:**

| Rule | Fields |
|---|---|
| `StringRule` | `min_length`, `max_length`, `pattern`, `format`, `trim`, `custom` |
| `IntRule` | `min`, `max` |
| `FloatRule` | `min`, `max` |
| `Format` | email, url, uuid, ipv4, ipv6, ip, alpha, alphanumeric, numeric, date, iso8601, base64, slug, credit_card, json, and more |

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

## Plugins

Official plugins for common web framework needs:

| Plugin | Description |
|---|---|
| [ziez-compression](https://github.com/ziez-dev/compression) | gzip/deflate/brotli response compression |
| [ziez-cors](https://github.com/ziez-dev/cors) | CORS middleware with origin whitelist/predicate |
| [ziez-security](https://github.com/ziez-dev/security) | Helmet + XSS protection middleware |
| [ziez-static](https://github.com/ziez-dev/static) | Static file serving middleware |
| [ziez-template](https://github.com/ziez-dev/template) | Template engine with layouts and caching |
| [ziez-tls](https://github.com/ziez-dev/tls) | TLS/HTTPS with HTTP→HTTPS redirect |
| [ziez-tracker](https://github.com/ziez-dev/tracker) | Request logging with UA parsing |
| [ziez-ua-parser](https://github.com/ziez-dev/ua-parser) | User-Agent parser (standalone) |
| [ziez-plugin-example](https://github.com/ziez-dev/plugin-example) | Example plugin scaffold |

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
        .url = "https://github.com/ziez-dev/ziez/archive/refs/tags/v0.0.1.tar.gz",
        .hash = "1220b1fe03d61a1cc83ee28e918e1a2e4f0e0d6d1e23844e0c0e28194a8bbbe9d2e8",
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
