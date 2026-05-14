const std = @import("std");
const ziez = @import("ziez");

test "serialize: basic struct passthrough" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
    };
    const user = User{ .id = 1, .name = "Alice" };
    const config = ziez.SerializerConfig(User){};
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice"}
    , result);
}

test "serialize: exclude fields" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        password_hash: []const u8,
    };
    const user = User{ .id = 1, .name = "Alice", .password_hash = "secret" };
    const config = ziez.SerializerConfig(User){
        .exclude = &.{"password_hash"},
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice"}
    , result);
}

test "serialize: whitelist fields" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
        role: []const u8,
    };
    const user = User{ .id = 1, .name = "Alice", .email = "a@b.com", .role = "admin" };
    const config = ziez.SerializerConfig(User){
        .fields = &.{ "id", "name" },
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice"}
    , result);
}

test "serialize: transforms" {
    const allocator = std.testing.allocator;
    const upper = struct {
        fn call(val: []const u8) []const u8 {
            return val;
        }
    }.call;

    const User = struct {
        id: u64,
        name: []const u8,
    };
    const user = User{ .id = 1, .name = "alice" };
    const config = ziez.SerializerConfig(User){
        .transforms = struct {
            pub const name = upper;
        },
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"alice"}
    , result);
}

test "serialize: computed fields" {
    const allocator = std.testing.allocator;
    const User = struct {
        first_name: []const u8,
        last_name: []const u8,
    };
    const user = User{ .first_name = "Alice", .last_name = "Smith" };

    const fullName = struct {
        var buf: [128]u8 = undefined;
        fn call(u: *const User) []const u8 {
            const joined = std.fmt.bufPrint(&buf, "{s} {s}", .{ u.first_name, u.last_name }) catch "unknown";
            return joined;
        }
    }.call;

    const config = ziez.SerializerConfig(User){
        .computed = struct {
            pub const full_name = fullName;
        },
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"first_name":"Alice","last_name":"Smith","full_name":"Alice Smith"}
    , result);
}

test "serialize: exclude_null" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        email: ?[]const u8,
    };
    const user = User{ .id = 1, .name = "Alice", .email = null };
    const config = ziez.SerializerConfig(User){
        .exclude_null = true,
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice"}
    , result);
}

test "serialize: exclude_null with non-null value" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        email: ?[]const u8,
    };
    const user = User{ .id = 1, .name = "Alice", .email = "alice@test.com" };
    const config = ziez.SerializerConfig(User){
        .exclude_null = true,
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","email":"alice@test.com"}
    , result);
}

test "serialize: conditions" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        secret: []const u8,
        is_admin: bool,
    };
    const user = User{ .id = 1, .name = "Alice", .secret = "top", .is_admin = false };
    const config = ziez.SerializerConfig(User){
        .conditions = struct {
            pub const secret = struct {
                fn call(u: *const User) bool {
                    return u.is_admin;
                }
            }.call;
        },
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","is_admin":false}
    , result);
}

test "serialize: conditions with true" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        secret: []const u8,
        is_admin: bool,
    };
    const user = User{ .id = 1, .name = "Alice", .secret = "top", .is_admin = true };
    const config = ziez.SerializerConfig(User){
        .conditions = struct {
            pub const secret = struct {
                fn call(u: *const User) bool {
                    return u.is_admin;
                }
            }.call;
        },
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","secret":"top","is_admin":true}
    , result);
}

test "serialize: nested" {
    const allocator = std.testing.allocator;
    const Address = struct {
        city: []const u8,
        zip: []const u8,
    };
    const User = struct {
        id: u64,
        name: []const u8,
        address: Address,
    };
    const user = User{
        .id = 1,
        .name = "Alice",
        .address = .{ .city = "Jakarta", .zip = "12345" },
    };
    const config = ziez.SerializerConfig(User){
        .nested = struct {
            pub const address = ziez.SerializerConfig(Address){
                .fields = &.{"city"},
            };
        },
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","address":{"city":"Jakarta"}}
    , result);
}

test "serialize: groups" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
        role: []const u8,
    };
    const user = User{ .id = 1, .name = "Alice", .email = "a@b.com", .role = "admin" };

    const public_config = ziez.SerializerConfig(User){
        .group_fields = struct {
            pub const @"public" = &.{ "id", "name" };
            pub const admin = &.{ "id", "name", "email", "role" };
        },
        .groups = &.{"public"},
    };
    const result1 = try ziez.serialize(allocator, user, public_config);
    defer allocator.free(result1);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice"}
    , result1);

    const admin_config = ziez.SerializerConfig(User){
        .group_fields = struct {
            pub const @"public" = &.{ "id", "name" };
            pub const admin = &.{ "id", "name", "email", "role" };
        },
        .groups = &.{"admin"},
    };
    const result2 = try ziez.serialize(allocator, user, admin_config);
    defer allocator.free(result2);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","email":"a@b.com","role":"admin"}
    , result2);
}

test "serialize: multiple groups" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
        role: []const u8,
    };
    const user = User{ .id = 1, .name = "Alice", .email = "a@b.com", .role = "admin" };

    const config = ziez.SerializerConfig(User){
        .group_fields = struct {
            pub const basic = &.{"id"};
            pub const @"public" = &.{ "id", "name" };
            pub const admin = &.{ "id", "name", "email", "role" };
        },
        .groups = &.{ "basic", "admin" },
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","email":"a@b.com","role":"admin"}
    , result);
}

test "serializeMany: array of structs" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        password: []const u8,
    };
    const users = [_]User{
        .{ .id = 1, .name = "Alice", .password = "secret1" },
        .{ .id = 2, .name = "Bob", .password = "secret2" },
    };
    const config = ziez.SerializerConfig(User){
        .exclude = &.{"password"},
    };
    const result = try ziez.serializeMany(allocator, &users, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]
    , result);
}

test "serialize: combined features" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        password: []const u8,
        bio: ?[]const u8,
    };
    const user = User{ .id = 1, .name = "Alice", .password = "secret", .bio = null };

    const upperName = struct {
        fn call(val: []const u8) []const u8 {
            return val;
        }
    }.call;

    const config = ziez.SerializerConfig(User){
        .exclude = &.{"password"},
        .exclude_null = true,
        .transforms = struct {
            pub const name = upperName;
        },
        .computed = struct {
            pub const display_name = struct {
                fn call(u: *const User) []const u8 {
                    return u.name;
                }
            }.call;
        },
    };
    const result = try ziez.serialize(allocator, user, config);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","display_name":"Alice"}
    , result);
}
