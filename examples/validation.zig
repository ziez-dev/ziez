const std = @import("std");
const ziez = @import("ziez");

// ---------------------------------------------------------------------------
// Domain types with schema rules
// ---------------------------------------------------------------------------

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

const SearchQuery = struct {
    q: []const u8,
    page: i64,

    pub const rules = .{
        .q = ziez.schema.StringRule{ .min_length = 1, .max_length = 100 },
        .page = ziez.schema.IntRule{ .min = 1 },
    };
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var app = ziez.init(allocator);
    defer app.deinit();

    app.on_error(struct {
        fn handler(req: *ziez.Request, res: *ziez.Response, err: anyerror) void {
            const info = ziez.errorToResponse(err);
            const msg = res.error_message orelse info.message;
            std.debug.print("[ERROR] {s} {d}: {s}\n", .{ req.path, info.code, msg });
            res.status(info.code).json(.{ .statusCode = info.code, .@"error" = msg });
        }
    }.handler);

    // --- Param pipes ---

    // GET /users/:id — paramInt converts :id to u64 automatically
    app.get("/users/:id", ziez.paramInt("id", u64, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, id: u64) !void {
            res.json(.{ .id = id, .name = "Alice" });
        }
    }.handler));

    // GET /docs/:docId — parseUUID rejects non-UUID values with 400
    app.get("/docs/:docId", ziez.parseUUID("docId", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, doc_id: []const u8) !void {
            res.json(.{ .docId = doc_id, .status = "found" });
        }
    }.handler));

    // GET /flags/:active — parseBool converts :active to bool
    app.get("/flags/:active", ziez.parseBool("active", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, active: bool) !void {
            res.json(.{ .active = active });
        }
    }.handler));

    // --- Query pipes ---

    // GET /items?page=2 — queryInt converts ?page= to u32
    app.get("/items", ziez.queryInt("page", u32, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, page: u32) !void {
            res.json(.{ .page = page, .per_page = 20 });
        }
    }.handler));

    // --- Schema validation ---

    // POST /users — validateBodySchema runs CreateUser.rules on the JSON body
    // Returns 422 with validation errors if any rule fails
    app.post("/users", ziez.validateBodySchema(CreateUser, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, user: CreateUser) !void {
            res.status(201).json(.{
                .id = 42,
                .name = user.name,
                .email = user.email,
                .age = user.age,
            });
        }
    }.handler));

    // GET /search — validateQuerySchema builds SearchQuery from query params and validates
    app.get("/search", ziez.validateQuerySchema(SearchQuery, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, q: SearchQuery) !void {
            res.json(.{ .query = q.q, .page = q.page, .results = .{} });
        }
    }.handler));

    // POST /products — validateBodyWithSchema with inline rules (no struct-level rules needed)
    const Product = struct { title: []const u8, price: i64 };
    app.post("/products", ziez.validateBodyWithSchema(Product, .{
        .title = ziez.schema.StringRule{ .min_length = 1, .max_length = 200 },
        .price = ziez.schema.IntRule{ .min = 0 },
    }, struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, p: Product) !void {
            res.status(201).json(.{ .id = 99, .title = p.title, .price = p.price });
        }
    }.handler));

    // --- Standalone validator functions ---

    // GET /validate?email=...&uuid=...&url=...
    app.get("/validate", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const email = req.query_get("email") orelse "";
            const uuid = req.query_get("uuid") orelse "";
            const url = req.query_get("url") orelse "";
            res.json(.{
                .email = .{ .value = email, .valid = ziez.validator.isEmail(email) },
                .uuid = .{ .value = uuid, .valid = ziez.validator.isUUID(uuid) },
                .url = .{ .value = url, .valid = ziez.validator.isURL(url, .{}) },
            });
        }
    }.handler);

    std.debug.print("Validation example listening on :3000\n", .{});
    std.debug.print("  GET  /users/:id       paramInt pipe\n", .{});
    std.debug.print("  GET  /docs/:uuid      parseUUID pipe\n", .{});
    std.debug.print("  POST /users           validateBodySchema (CreateUser.rules)\n", .{});
    std.debug.print("  GET  /search?q=x&page=1  validateQuerySchema\n", .{});
    std.debug.print("  POST /products        validateBodyWithSchema (inline rules)\n", .{});
    std.debug.print("  GET  /validate?email=x&uuid=y&url=z  standalone validators\n", .{});
    try app.listen("0.0.0.0:3000");
}
