const std = @import("std");
const ziez = @import("ziez");

// --- Domain models ---

const User = struct {
    id: u64,
    name: []const u8,
    email: []const u8,
    password_hash: []const u8,
    role: []const u8,
    avatar: ?[]const u8,
    created_at: i64,
};

const Address = struct {
    city: []const u8,
    zip: []const u8,
    country: []const u8,
};

const Order = struct {
    id: u64,
    status: []const u8,
    total: u64,
    user: User,
    address: Address,
};

// --- Transform functions ---

const formatTimestamp = struct {
    fn call(ts: i64) []const u8 {
        // Simplified: in production use std.time
        _ = ts;
        return "2024-01-15T10:30:00Z";
    }
}.call;

const formatCents = struct {
    fn call(cents: u64) []const u8 {
        var buf: [32]u8 = undefined;
        const dollars = @as(f64, @floatFromInt(cents)) / 100.0;
        return std.fmt.bufPrint(&buf, "${d:.2}", .{ .d = dollars }) catch "$0.00";
    }
}.call;

// --- Serializer configs ---

const PublicUserSerializer = ziez.SerializerConfig(User){
    .exclude = &.{"password_hash"},
    .transforms = struct {
        pub const created_at = formatTimestamp;
    },
    .exclude_null = true,
};

const AdminUserSerializer = ziez.SerializerConfig(User){
    .exclude = &.{"password_hash"},
    .transforms = struct {
        pub const created_at = formatTimestamp;
    },
    .computed = struct {
        pub const display_name = struct {
            fn call(u: *const User) []const u8 {
                return u.name;
            }
        }.call;
    },
    .group_fields = struct {
        pub const @"public" = &.{ "id", "name", "avatar", "display_name" };
        pub const admin = &.{ "id", "name", "email", "role", "created_at", "display_name" };
    },
    .groups = &.{"admin"},
};

const AddressSerializer = ziez.SerializerConfig(Address){
    .fields = &.{ "city", "country" },
};

const OrderSerializer = ziez.SerializerConfig(Order){
    .fields = &.{ "id", "status", "total", "user", "address" },
    .transforms = struct {
        pub const total = formatCents;
    },
    .nested = struct {
        pub const user = PublicUserSerializer;
        pub const address = AddressSerializer;
    },
};

// --- Mock data ---

var mock_users = [_]User{
    .{ .id = 1, .name = "Alice", .email = "alice@test.com", .password_hash = "hashed_secret", .role = "admin", .avatar = null, .created_at = 1705312200 },
    .{ .id = 2, .name = "Bob", .email = "bob@test.com", .password_hash = "hashed_secret2", .role = "user", .avatar = "bob.png", .created_at = 1705312200 },
    .{ .id = 3, .name = "Charlie", .email = "charlie@test.com", .password_hash = "hashed_secret3", .role = "user", .avatar = "charlie.png", .created_at = 1705312200 },
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var app = ziez.init(allocator);
    defer app.deinit();

    // Logger middleware
    app.use(struct {
        fn handler(req: *ziez.Request, _: *ziez.Response, next: *ziez.Next) void {
            std.debug.print("[ziez] {s} {s}\n", .{ @tagName(req.method), req.path });
            next.call();
        }
    }.handler);

    // GET /users - list all users (manual serialization)
    app.get("/users", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.serializeMany(&mock_users, PublicUserSerializer);
        }
    }.handler);

    // GET /users/:id - get single user with groups (manual serialization)
    app.get("/users/:id", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            const id_str = req.param("id") orelse return error.BadRequest;
            const id = std.fmt.parseInt(u64, id_str, 10) catch return error.BadRequest;
            for (&mock_users) |*user| {
                if (user.id == id) {
                    res.serialize(user, AdminUserSerializer);
                    return;
                }
            }
            return error.NotFound;
        }
    }.handler);

    // GET /orders/:id - nested serialization (using serialized wrapper)
    app.get("/orders/:id", ziez.serialized(OrderSerializer, struct {
        fn handler(_: *ziez.Request) !Order {
            return Order{
                .id = 1001,
                .status = "shipped",
                .total = 4999,
                .user = mock_users[0],
                .address = .{ .city = "Jakarta", .zip = "12345", .country = "Indonesia" },
            };
        }
    }.handler));

    // GET / - basic health check
    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .status = "ok", .framework = "ziez" });
        }
    }.handler);

    try app.listen("0.0.0.0:3001");
}
