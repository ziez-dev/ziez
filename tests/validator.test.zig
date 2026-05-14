const std = @import("std");
const validator = @import("ziez").validator;

// ---------------------------------------------------------------------------
// Basic
// ---------------------------------------------------------------------------

test "isAscii: valid ascii strings" {
    try std.testing.expect(validator.isAscii("hello world"));
    try std.testing.expect(validator.isAscii("ABC123!@#"));
    try std.testing.expect(validator.isAscii(""));
    try std.testing.expect(validator.isAscii(" "));
}

test "isAscii: rejects non-ascii" {
    try std.testing.expect(!validator.isAscii("h\xc3\xa9llo"));
    try std.testing.expect(!validator.isAscii("\xff"));
}

test "isAlpha: valid alpha strings" {
    try std.testing.expect(validator.isAlpha("hello"));
    try std.testing.expect(validator.isAlpha("HelloWorld"));
    try std.testing.expect(validator.isAlpha("abc"));
    try std.testing.expect(validator.isAlpha("Z"));
}

test "isAlpha: rejects non-alpha" {
    try std.testing.expect(!validator.isAlpha("hello123"));
    try std.testing.expect(!validator.isAlpha(""));
    try std.testing.expect(!validator.isAlpha("hello world"));
    try std.testing.expect(!validator.isAlpha("hello!"));
}

test "isAlphanumeric: valid strings" {
    try std.testing.expect(validator.isAlphanumeric("hello123"));
    try std.testing.expect(validator.isAlphanumeric("ABC"));
    try std.testing.expect(validator.isAlphanumeric("123"));
    try std.testing.expect(validator.isAlphanumeric("a1B2"));
}

test "isAlphanumeric: rejects special chars" {
    try std.testing.expect(!validator.isAlphanumeric("hello!"));
    try std.testing.expect(!validator.isAlphanumeric("hello world"));
    try std.testing.expect(!validator.isAlphanumeric(""));
}

test "isNumeric: valid digit strings" {
    try std.testing.expect(validator.isNumeric("12345"));
    try std.testing.expect(validator.isNumeric("0"));
    try std.testing.expect(validator.isNumeric("999999"));
}

test "isNumeric: rejects non-digits" {
    try std.testing.expect(!validator.isNumeric("12a34"));
    try std.testing.expect(!validator.isNumeric("12.34"));
    try std.testing.expect(!validator.isNumeric(""));
    try std.testing.expect(!validator.isNumeric("-5"));
}

test "isLowercase: valid" {
    try std.testing.expect(validator.isLowercase("hello"));
    try std.testing.expect(validator.isLowercase("abcdef"));
}

test "isLowercase: rejects mixed/upper" {
    try std.testing.expect(!validator.isLowercase("Hello"));
    try std.testing.expect(!validator.isLowercase("HELLO"));
    try std.testing.expect(!validator.isLowercase(""));
    try std.testing.expect(!validator.isLowercase("hello123"));
}

test "isUppercase: valid" {
    try std.testing.expect(validator.isUppercase("HELLO"));
    try std.testing.expect(validator.isUppercase("ABCDEF"));
}

test "isUppercase: rejects mixed/lower" {
    try std.testing.expect(!validator.isUppercase("Hello"));
    try std.testing.expect(!validator.isUppercase("hello"));
    try std.testing.expect(!validator.isUppercase(""));
    try std.testing.expect(!validator.isUppercase("HELLO123"));
}

test "isEmpty: empty string" {
    try std.testing.expect(validator.isEmpty(""));
}

test "isEmpty: non-empty string" {
    try std.testing.expect(!validator.isEmpty("a"));
    try std.testing.expect(!validator.isEmpty(" "));
}

// ---------------------------------------------------------------------------
// Number
// ---------------------------------------------------------------------------

test "isInt: valid integers" {
    try std.testing.expect(validator.isInt("123", .{}));
    try std.testing.expect(validator.isInt("-42", .{}));
    try std.testing.expect(validator.isInt("+7", .{}));
    try std.testing.expect(validator.isInt("0", .{}));
}

test "isInt: rejects non-integers" {
    try std.testing.expect(!validator.isInt("12.3", .{}));
    try std.testing.expect(!validator.isInt("", .{}));
    try std.testing.expect(!validator.isInt("abc", .{}));
    try std.testing.expect(!validator.isInt("--5", .{}));
    try std.testing.expect(!validator.isInt("5-", .{}));
}

test "isInt: with min/max" {
    try std.testing.expect(validator.isInt("5", .{ .min = 0, .max = 10 }));
    try std.testing.expect(validator.isInt("0", .{ .min = 0, .max = 10 }));
    try std.testing.expect(validator.isInt("10", .{ .min = 0, .max = 10 }));
    try std.testing.expect(!validator.isInt("15", .{ .min = 0, .max = 10 }));
    try std.testing.expect(!validator.isInt("-1", .{ .min = 0, .max = 10 }));
    try std.testing.expect(validator.isInt("-5", .{ .min = -10, .max = 10 }));
}

test "isFloat: valid floats" {
    try std.testing.expect(validator.isFloat("3.14", .{}));
    try std.testing.expect(validator.isFloat("-0.5", .{}));
    try std.testing.expect(validator.isFloat("42", .{}));
    try std.testing.expect(validator.isFloat("0.0", .{}));
    try std.testing.expect(validator.isFloat("+3.14", .{}));
}

test "isFloat: rejects non-floats" {
    try std.testing.expect(!validator.isFloat("abc", .{}));
    try std.testing.expect(!validator.isFloat("", .{}));
    try std.testing.expect(!validator.isFloat(".", .{}));
    try std.testing.expect(!validator.isFloat("3.14.15", .{}));
}

test "isFloat: with min/max" {
    try std.testing.expect(validator.isFloat("5.0", .{ .min = 0.0, .max = 10.0 }));
    try std.testing.expect(!validator.isFloat("15.0", .{ .min = 0.0, .max = 10.0 }));
    try std.testing.expect(!validator.isFloat("-1.0", .{ .min = 0.0, .max = 10.0 }));
}

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

test "isEmail: valid emails" {
    try std.testing.expect(validator.isEmail("user@example.com"));
    try std.testing.expect(validator.isEmail("user.name+tag@domain.co"));
    try std.testing.expect(validator.isEmail("a@b.co"));
    try std.testing.expect(validator.isEmail("test123@test123.com"));
}

test "isEmail: rejects invalid" {
    try std.testing.expect(!validator.isEmail("invalid"));
    try std.testing.expect(!validator.isEmail("@domain.com"));
    try std.testing.expect(!validator.isEmail("user@"));
    try std.testing.expect(!validator.isEmail("user@.com"));
    try std.testing.expect(!validator.isEmail("user@domain"));
    try std.testing.expect(!validator.isEmail(""));
}

test "isURL: valid URLs" {
    try std.testing.expect(validator.isURL("https://example.com", .{}));
    try std.testing.expect(validator.isURL("http://test.com/path", .{}));
    try std.testing.expect(validator.isURL("ftp://files.org", .{}));
    try std.testing.expect(validator.isURL("https://example.com:8080/path?q=1", .{}));
}

test "isURL: rejects invalid" {
    try std.testing.expect(!validator.isURL("not a url", .{}));
    try std.testing.expect(!validator.isURL("://missing-proto.com", .{}));
    try std.testing.expect(!validator.isURL("http://", .{}));
}

test "isURL: protocol filter" {
    try std.testing.expect(validator.isURL("https://example.com", .{ .protocols = &.{"https"} }));
    try std.testing.expect(!validator.isURL("http://example.com", .{ .protocols = &.{"https"} }));
}

test "isIPv4: valid addresses" {
    try std.testing.expect(validator.isIPv4("192.168.1.1"));
    try std.testing.expect(validator.isIPv4("0.0.0.0"));
    try std.testing.expect(validator.isIPv4("255.255.255.255"));
    try std.testing.expect(validator.isIPv4("10.0.0.1"));
}

test "isIPv4: rejects invalid" {
    try std.testing.expect(!validator.isIPv4("256.1.1.1"));
    try std.testing.expect(!validator.isIPv4("1.2.3"));
    try std.testing.expect(!validator.isIPv4("1.2.3.4.5"));
    try std.testing.expect(!validator.isIPv4("abc.def.ghi.jkl"));
    try std.testing.expect(!validator.isIPv4(""));
}

test "isIPv6: valid addresses" {
    try std.testing.expect(validator.isIPv6("::1"));
    try std.testing.expect(validator.isIPv6("2001:0db8:85a3:0000:0000:8a2e:0370:7334"));
    try std.testing.expect(validator.isIPv6("::"));
    try std.testing.expect(validator.isIPv6("fe80::1"));
}

test "isIPv6: rejects invalid" {
    try std.testing.expect(!validator.isIPv6(""));
    try std.testing.expect(!validator.isIPv6("not:ipv6:enough"));
}

test "isIP: accepts both v4 and v6" {
    try std.testing.expect(validator.isIP("192.168.1.1"));
    try std.testing.expect(validator.isIP("::1"));
    try std.testing.expect(!validator.isIP("not an ip"));
}

test "isUUID: valid UUIDs" {
    try std.testing.expect(validator.isUUID("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(validator.isUUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8"));
    try std.testing.expect(validator.isUUID("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"));
    try std.testing.expect(validator.isUUID("00000000-0000-0000-0000-000000000000"));
}

test "isUUID: rejects invalid" {
    try std.testing.expect(!validator.isUUID("not-a-uuid"));
    try std.testing.expect(!validator.isUUID("550e8400e29b41d4a716446655440000"));
    try std.testing.expect(!validator.isUUID(""));
    try std.testing.expect(!validator.isUUID("550e8400-e29b-41d4-a716"));
}

// ---------------------------------------------------------------------------
// Date
// ---------------------------------------------------------------------------

test "isDate: valid dates" {
    try std.testing.expect(validator.isDate("2024-01-15"));
    try std.testing.expect(validator.isDate("1999-12-31"));
    try std.testing.expect(validator.isDate("2000-01-01"));
}

test "isDate: rejects invalid" {
    try std.testing.expect(!validator.isDate("2024-13-01"));
    try std.testing.expect(!validator.isDate("2024-01-32"));
    try std.testing.expect(!validator.isDate("not-a-date"));
    try std.testing.expect(!validator.isDate("24-1-1"));
    try std.testing.expect(!validator.isDate(""));
}

test "isISO8601: date only" {
    try std.testing.expect(validator.isISO8601("2024-01-15"));
    try std.testing.expect(validator.isISO8601("1999-12-31"));
}

test "isISO8601: with time" {
    try std.testing.expect(validator.isISO8601("2024-01-15T10:30:00"));
    try std.testing.expect(validator.isISO8601("2024-01-15T10:30:00Z"));
    try std.testing.expect(validator.isISO8601("2024-01-15T10:30:00z"));
    try std.testing.expect(validator.isISO8601("2024-01-15T10:30:00+07:00"));
    try std.testing.expect(validator.isISO8601("2024-01-15T10:30:00-05:00"));
}

test "isISO8601: rejects invalid" {
    try std.testing.expect(!validator.isISO8601("not-iso"));
    try std.testing.expect(!validator.isISO8601("2024-13-01T10:30:00"));
    try std.testing.expect(!validator.isISO8601(""));
}

test "isTime: valid times" {
    try std.testing.expect(validator.isTime("10:30"));
    try std.testing.expect(validator.isTime("23:59:59"));
    try std.testing.expect(validator.isTime("00:00"));
    try std.testing.expect(validator.isTime("00:00:00"));
}

test "isTime: rejects invalid" {
    try std.testing.expect(!validator.isTime("25:00"));
    try std.testing.expect(!validator.isTime("10:60"));
    try std.testing.expect(!validator.isTime("10"));
    try std.testing.expect(!validator.isTime(""));
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

test "isBase64: valid" {
    try std.testing.expect(validator.isBase64("SGVsbG8gV29ybGQ="));
    try std.testing.expect(validator.isBase64("aGVsbG8="));
    try std.testing.expect(validator.isBase64("AA=="));
    try std.testing.expect(validator.isBase64("TWFu"));
}

test "isBase64: rejects invalid" {
    try std.testing.expect(!validator.isBase64("not!base64"));
    try std.testing.expect(!validator.isBase64(""));
    try std.testing.expect(!validator.isBase64("===a"));
}

test "isHexadecimal: valid" {
    try std.testing.expect(validator.isHexadecimal("deadbeef"));
    try std.testing.expect(validator.isHexadecimal("0123456789ABCDEF"));
    try std.testing.expect(validator.isHexadecimal("aBcD1234"));
}

test "isHexadecimal: rejects invalid" {
    try std.testing.expect(!validator.isHexadecimal("xyz"));
    try std.testing.expect(!validator.isHexadecimal(""));
    try std.testing.expect(!validator.isHexadecimal("0x1234"));
}

test "isJSON: valid JSON values" {
    try std.testing.expect(validator.isJSON("{\"key\":\"value\"}"));
    try std.testing.expect(validator.isJSON("[1,2,3]"));
    try std.testing.expect(validator.isJSON("true"));
    try std.testing.expect(validator.isJSON("false"));
    try std.testing.expect(validator.isJSON("null"));
    try std.testing.expect(validator.isJSON("42"));
    try std.testing.expect(validator.isJSON("-3.14"));
    try std.testing.expect(validator.isJSON("\"hello\""));
}

test "isJSON: rejects invalid" {
    try std.testing.expect(!validator.isJSON("not json"));
    try std.testing.expect(!validator.isJSON(""));
    try std.testing.expect(!validator.isJSON("{incomplete"));
    try std.testing.expect(!validator.isJSON("[incomplete"));
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

test "isCreditCard: valid cards (Luhn)" {
    try std.testing.expect(validator.isCreditCard("4111111111111111"));
    try std.testing.expect(validator.isCreditCard("4111 1111 1111 1111"));
    try std.testing.expect(validator.isCreditCard("4111-1111-1111-1111"));
}

test "isCreditCard: rejects invalid" {
    try std.testing.expect(!validator.isCreditCard("4111111111111112"));
    try std.testing.expect(!validator.isCreditCard("123"));
    try std.testing.expect(!validator.isCreditCard("abcd1234efgh5678"));
    try std.testing.expect(!validator.isCreditCard(""));
}

test "isSlug: valid slugs" {
    try std.testing.expect(validator.isSlug("hello-world"));
    try std.testing.expect(validator.isSlug("my-blog-post-2024"));
    try std.testing.expect(validator.isSlug("hello"));
    try std.testing.expect(validator.isSlug("a"));
}

test "isSlug: rejects invalid" {
    try std.testing.expect(!validator.isSlug("-hello"));
    try std.testing.expect(!validator.isSlug("hello-"));
    try std.testing.expect(!validator.isSlug("hello world"));
    try std.testing.expect(!validator.isSlug(""));
    try std.testing.expect(!validator.isSlug("hello_world"));
}

// ---------------------------------------------------------------------------
// Password
// ---------------------------------------------------------------------------

test "isStrongPassword: valid" {
    try std.testing.expect(validator.isStrongPassword("Abcdef1!", .{}));
    try std.testing.expect(validator.isStrongPassword("P@ssw0rd!", .{}));
}

test "isStrongPassword: rejects weak" {
    try std.testing.expect(!validator.isStrongPassword("weak", .{}));
    try std.testing.expect(!validator.isStrongPassword("alllowercase1!", .{}));
    try std.testing.expect(!validator.isStrongPassword("ALLUPPERCASE1!", .{}));
    try std.testing.expect(!validator.isStrongPassword("NoSymbols123", .{}));
    try std.testing.expect(!validator.isStrongPassword("NoDigits!@#", .{}));
}

test "isStrongPassword: custom options" {
    try std.testing.expect(validator.isStrongPassword("Aa1!x", .{ .min_length = 5 }));
    try std.testing.expect(!validator.isStrongPassword("Aa1!", .{ .min_length = 5 }));
    try std.testing.expect(validator.isStrongPassword("abc", .{ .min_length = 3, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 }));
}

// ---------------------------------------------------------------------------
// Locale
// ---------------------------------------------------------------------------

test "isPostalCode: US" {
    try std.testing.expect(validator.isPostalCode("12345", "US"));
    try std.testing.expect(validator.isPostalCode("12345-6789", "US"));
    try std.testing.expect(!validator.isPostalCode("1234", "US"));
    try std.testing.expect(!validator.isPostalCode("123456", "US"));
}

test "isPostalCode: CA" {
    try std.testing.expect(validator.isPostalCode("K1A 0B1", "CA"));
    try std.testing.expect(!validator.isPostalCode("12345", "CA"));
}

test "isPostalCode: generic" {
    try std.testing.expect(validator.isPostalCode("12345", "DE"));
    try std.testing.expect(!validator.isPostalCode("ab", "DE"));
}

test "isMobilePhone: US" {
    try std.testing.expect(validator.isMobilePhone("5551234567", "US"));
    try std.testing.expect(validator.isMobilePhone("15551234567", "US"));
    try std.testing.expect(validator.isMobilePhone("(555) 123-4567", "US"));
    try std.testing.expect(!validator.isMobilePhone("123", "US"));
}

test "isMobilePhone: ID (Indonesia)" {
    try std.testing.expect(validator.isMobilePhone("+628123456789", "ID"));
    try std.testing.expect(validator.isMobilePhone("081234567890", "ID"));
    try std.testing.expect(!validator.isMobilePhone("123", "ID"));
}

test "isMobilePhone: generic" {
    try std.testing.expect(validator.isMobilePhone("1234567", "XX"));
    try std.testing.expect(!validator.isMobilePhone("123456", "XX"));
}
