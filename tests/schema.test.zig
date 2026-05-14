const std = @import("std");
const ziez = @import("ziez");
const schema = ziez.schema;

// ---------------------------------------------------------------------------
// String rules
// ---------------------------------------------------------------------------

test "StringRule: min_length passes" {
    const S = struct {
        name: []const u8,
        pub const rules = .{
            .name = schema.StringRule{ .min_length = 3 },
        };
    };
    const val = S{ .name = "Alice" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "StringRule: min_length fails" {
    const S = struct {
        name: []const u8,
        pub const rules = .{
            .name = schema.StringRule{ .min_length = 5 },
        };
    };
    const val = S{ .name = "Al" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expectEqualStrings("name", result.errors[0].field);
}

test "StringRule: max_length passes" {
    const S = struct {
        name: []const u8,
        pub const rules = .{
            .name = schema.StringRule{ .max_length = 10 },
        };
    };
    const val = S{ .name = "Alice" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "StringRule: max_length fails" {
    const S = struct {
        name: []const u8,
        pub const rules = .{
            .name = schema.StringRule{ .max_length = 3 },
        };
    };
    const val = S{ .name = "Alice" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
}

test "StringRule: format email passes" {
    const S = struct {
        email: []const u8,
        pub const rules = .{
            .email = schema.StringRule{ .format = .email },
        };
    };
    const val = S{ .email = "user@example.com" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "StringRule: format email fails" {
    const S = struct {
        email: []const u8,
        pub const rules = .{
            .email = schema.StringRule{ .format = .email },
        };
    };
    const val = S{ .email = "not-an-email" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqualStrings("must be a valid email", result.errors[0].message);
}

test "StringRule: format uuid passes" {
    const S = struct {
        id: []const u8,
        pub const rules = .{
            .id = schema.StringRule{ .format = .uuid },
        };
    };
    const val = S{ .id = "550e8400-e29b-41d4-a716-446655440000" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "StringRule: format uuid fails" {
    const S = struct {
        id: []const u8,
        pub const rules = .{
            .id = schema.StringRule{ .format = .uuid },
        };
    };
    const val = S{ .id = "not-a-uuid" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
}

test "StringRule: custom validator passes" {
    const S = struct {
        code: []const u8,
        pub const rules = .{
            .code = schema.StringRule{ .custom = startsWithA },
        };
    };
    const val = S{ .code = "Alpha" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "StringRule: custom validator fails" {
    const S = struct {
        code: []const u8,
        pub const rules = .{
            .code = schema.StringRule{ .custom = startsWithA },
        };
    };
    const val = S{ .code = "Beta" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
}

fn startsWithA(s: []const u8) bool {
    return s.len > 0 and s[0] == 'A';
}

// ---------------------------------------------------------------------------
// Int rules
// ---------------------------------------------------------------------------

test "IntRule: min passes" {
    const S = struct {
        age: u8,
        pub const rules = .{
            .age = schema.IntRule{ .min = 0 },
        };
    };
    const val = S{ .age = 25 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "IntRule: min fails" {
    const S = struct {
        age: i8,
        pub const rules = .{
            .age = schema.IntRule{ .min = 0 },
        };
    };
    const val = S{ .age = -1 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
}

test "IntRule: max passes" {
    const S = struct {
        age: u8,
        pub const rules = .{
            .age = schema.IntRule{ .max = 150 },
        };
    };
    const val = S{ .age = 25 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "IntRule: max fails" {
    const S = struct {
        age: u8,
        pub const rules = .{
            .age = schema.IntRule{ .max = 150 },
        };
    };
    const val = S{ .age = 200 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
}

test "IntRule: min and max combined" {
    const S = struct {
        score: i32,
        pub const rules = .{
            .score = schema.IntRule{ .min = 0, .max = 100 },
        };
    };
    const valid = S{ .score = 50 };
    try std.testing.expect(schema.validate(std.testing.allocator, valid).valid);

    const too_low = S{ .score = -1 };
    try std.testing.expect(!schema.validate(std.testing.allocator, too_low).valid);

    const too_high = S{ .score = 101 };
    try std.testing.expect(!schema.validate(std.testing.allocator, too_high).valid);
}

// ---------------------------------------------------------------------------
// Float rules
// ---------------------------------------------------------------------------

test "FloatRule: min passes" {
    const S = struct {
        price: f64,
        pub const rules = .{
            .price = schema.FloatRule{ .min = 0.0 },
        };
    };
    const val = S{ .price = 9.99 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "FloatRule: min fails" {
    const S = struct {
        price: f64,
        pub const rules = .{
            .price = schema.FloatRule{ .min = 0.0 },
        };
    };
    const val = S{ .price = -1.0 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
}

test "FloatRule: max fails" {
    const S = struct {
        ratio: f32,
        pub const rules = .{
            .ratio = schema.FloatRule{ .max = 1.0 },
        };
    };
    const val = S{ .ratio = 1.5 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
}

// ---------------------------------------------------------------------------
// Optional fields
// ---------------------------------------------------------------------------

test "Optional: null value passes" {
    const S = struct {
        nickname: ?[]const u8,
        pub const rules = .{
            .nickname = schema.StringRule{ .min_length = 2 },
        };
    };
    const val = S{ .nickname = null };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "Optional: non-null valid value passes" {
    const S = struct {
        nickname: ?[]const u8,
        pub const rules = .{
            .nickname = schema.StringRule{ .min_length = 2 },
        };
    };
    const val = S{ .nickname = "Bob" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "Optional: non-null invalid value fails" {
    const S = struct {
        nickname: ?[]const u8,
        pub const rules = .{
            .nickname = schema.StringRule{ .min_length = 5 },
        };
    };
    const val = S{ .nickname = "Bob" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
}

test "Optional int: null passes" {
    const S = struct {
        bonus: ?i32,
        pub const rules = .{
            .bonus = schema.IntRule{ .min = 0 }
        };
    };
    const val = S{ .bonus = null };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "Optional int: non-null valid passes" {
    const S = struct {
        bonus: ?i32,
        pub const rules = .{
            .bonus = schema.IntRule{ .min = 0 }
        };
    };
    const val = S{ .bonus = 100 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "Optional int: non-null invalid fails" {
    const S = struct {
        bonus: ?i32,
        pub const rules = .{
            .bonus = schema.IntRule{ .min = 0 }
        };
    };
    const val = S{ .bonus = -5 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
}

// ---------------------------------------------------------------------------
// Nested structs
// ---------------------------------------------------------------------------

test "Nested struct: validates with own rules" {
    const Address = struct {
        city: []const u8,
        zip: []const u8,
        pub const rules = .{
            .city = schema.StringRule{ .min_length = 1 },
            .zip = schema.StringRule{ .format = .numeric }
        };
    };
    const User = struct {
        name: []const u8,
        address: Address,
        pub const rules = .{
            .name = schema.StringRule{ .min_length = 1 }
        };
    };
    const val = User{ .name = "Alice", .address = .{ .city = "Jakarta", .zip = "12345" } };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "Nested struct: nested validation fails" {
    const Address = struct {
        city: []const u8,
        zip: []const u8,
        pub const rules = .{
            .city = schema.StringRule{ .min_length = 1 },
            .zip = schema.StringRule{ .format = .numeric }
        };
    };
    const User = struct {
        name: []const u8,
        address: Address,
        pub const rules = .{
            .name = schema.StringRule{ .min_length = 1 }
        };
    };
    const val = User{ .name = "Alice", .address = .{ .city = "Jakarta", .zip = "abc" } };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
}

// ---------------------------------------------------------------------------
// No-rules struct
// ---------------------------------------------------------------------------

test "No rules struct: passes validation" {
    const S = struct {
        x: i32,
        y: i32,
    };
    const val = S{ .x = 1, .y = 2 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

// ---------------------------------------------------------------------------
// Multiple errors
// ---------------------------------------------------------------------------

test "Multiple errors: collects all violations" {
    const S = struct {
        name: []const u8,
        email: []const u8,
        age: u8,
        pub const rules = .{
            .name = schema.StringRule{ .min_length = 5 },
            .email = schema.StringRule{ .format = .email },
            .age = schema.IntRule{ .min = 18 },
        };
    };
    const val = S{ .name = "Al", .email = "bad", .age = 10 };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 3), result.errors.len);
}

test "Multiple errors: partial failures" {
    const S = struct {
        name: []const u8,
        email: []const u8,
        pub const rules = .{
            .name = schema.StringRule{ .min_length = 5 },
            .email = schema.StringRule{ .format = .email },
        };
    };
    const val = S{ .name = "Al", .email = "user@example.com" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expectEqualStrings("name", result.errors[0].field);
}

// ---------------------------------------------------------------------------
// validateWithRules
// ---------------------------------------------------------------------------

test "validateWithRules: uses explicit rules" {
    const S = struct {
        name: []const u8,
        age: u8,
    };
    const rules = .{
        .name = schema.StringRule{ .min_length = 1 },
        .age = schema.IntRule{ .max = 150 },
    };
    const val = S{ .name = "Alice", .age = 25 };
    const result = schema.validateWithRules(std.testing.allocator, val, rules);
    try std.testing.expect(result.valid);
}

test "validateWithRules: fails with bad data" {
    const S = struct {
        name: []const u8,
        age: u8,
    };
    const rules = .{
        .name = schema.StringRule{ .min_length = 5 },
        .age = schema.IntRule{ .max = 150 },
    };
    const val = S{ .name = "Al", .age = 200 };
    const result = schema.validateWithRules(std.testing.allocator, val, rules);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 2), result.errors.len);
}

// ---------------------------------------------------------------------------
// Mixed field types
// ---------------------------------------------------------------------------

test "Mixed types: bool and enum always valid" {
    const Color = enum { red, green, blue };
    const S = struct {
        active: bool,
        color: Color,
        name: []const u8,
        pub const rules = .{
            .name = schema.StringRule{ .min_length = 1 },
        };
    };
    const val = S{ .active = true, .color = .red, .name = "test" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

// ---------------------------------------------------------------------------
// Format variants
// ---------------------------------------------------------------------------

test "StringRule: format slug passes" {
    const S = struct {
        slug: []const u8,
        pub const rules = .{
            .slug = schema.StringRule{ .format = .slug },
        };
    };
    const val = S{ .slug = "my-blog-post" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "StringRule: format date passes" {
    const S = struct {
        born: []const u8,
        pub const rules = .{
            .born = schema.StringRule{ .format = .date },
        };
    };
    const val = S{ .born = "2024-01-15" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "StringRule: format url passes" {
    const S = struct {
        website: []const u8,
        pub const rules = .{
            .website = schema.StringRule{ .format = .url },
        };
    };
    const val = S{ .website = "https://example.com" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}

test "StringRule: format ipv4 passes" {
    const S = struct {
        ip: []const u8,
        pub const rules = .{
            .ip = schema.StringRule{ .format = .ipv4 },
        };
    };
    const val = S{ .ip = "192.168.1.1" };
    const result = schema.validate(std.testing.allocator, val);
    try std.testing.expect(result.valid);
}
