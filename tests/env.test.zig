const std = @import("std");
const ziez = @import("ziez");

test "parse .env" {
    const contents =
        \\# comment
        \\PORT=3000
        \\DB_URL=postgres://localhost:5432/mydb
        \\API_KEY="my secret key"
        \\SINGLE_QUOTES='hello world'
        \\EMPTY=
        \\  SPACED_KEY  =  spaced_value
        \\
    ;
    var env_obj = try ziez.Env.initWithContent(std.testing.allocator, contents);
    defer env_obj.deinit();

    try std.testing.expectEqualStrings("3000", env_obj.get("PORT").?);
    try std.testing.expectEqualStrings("postgres://localhost:5432/mydb", env_obj.get("DB_URL").?);
    try std.testing.expectEqualStrings("my secret key", env_obj.get("API_KEY").?);
    try std.testing.expectEqualStrings("hello world", env_obj.get("SINGLE_QUOTES").?);
    try std.testing.expectEqualStrings("", env_obj.get("EMPTY").?);
    try std.testing.expectEqualStrings("spaced_value", env_obj.get("SPACED_KEY").?);
    try std.testing.expect(env_obj.get("NONEXISTENT") == null);
}

test "getOr default" {
    var env_obj = try ziez.Env.initWithContent(std.testing.allocator, "PORT=3000\n");
    defer env_obj.deinit();

    try std.testing.expectEqualStrings("3000", env_obj.getOr("PORT", "8080"));
    try std.testing.expectEqualStrings("8080", env_obj.getOr("MISSING", "8080"));
}

test "getInt" {
    var env_obj = try ziez.Env.initWithContent(std.testing.allocator, "PORT=3000\nTIMEOUT=abc\n");
    defer env_obj.deinit();

    try std.testing.expectEqual(@as(u16, 3000), env_obj.getInt("PORT", u16, 8080));
    try std.testing.expectEqual(@as(u16, 8080), env_obj.getInt("MISSING", u16, 8080));
    try std.testing.expectEqual(@as(u16, 8080), env_obj.getInt("TIMEOUT", u16, 8080));
}

test "getBool" {
    var env_obj = try ziez.Env.initWithContent(std.testing.allocator, "DEBUG=true\nLOG=0\n");
    defer env_obj.deinit();

    try std.testing.expectEqual(true, env_obj.getBool("DEBUG", false));
    try std.testing.expectEqual(false, env_obj.getBool("LOG", true));
    try std.testing.expectEqual(true, env_obj.getBool("MISSING", true));
}
