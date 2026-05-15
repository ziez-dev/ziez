/// Tests for src/static.zig
///
/// All filesystem work uses std.posix directly (Zig 0.16 — std.Io required
/// for std.Io.Dir/File operations; here we keep tests synchronous and simple).
///
/// Covered behaviours:
///   1. 200 OK with correct Content-Type on a real file
///   2. ETag generation + 304 Not Modified
///   3. Path traversal rejected (pass-through, not 200)
///   4. Dotfile `.deny` → 403 Forbidden
///   5. Dotfile `.ignore` → pass-through (false)
///   6. URL prefix mismatch → pass-through
///   7. POST request → pass-through
///   8. Cache-Control header reflects `max_age`
///   9. Missing file → pass-through
///  10. App.serveStatic stores config in router
const std = @import("std");
const ziez = @import("ziez");
const opts = @import("ziez_options");

// ---------------------------------------------------------------------------
// POSIX helpers — write / delete files without std.Io
// ---------------------------------------------------------------------------

extern "c" fn close(fd: std.posix.fd_t) c_int;
extern "c" fn write(fd: std.posix.fd_t, buf: [*]const u8, count: usize) isize;

const linux = std.os.linux;

/// Write `content` to the file at `path` (NUL-terminated), creating it.
fn writeFileZ(path: [*:0]const u8, content: []const u8) !void {
    const fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    defer _ = close(fd);

    var written: usize = 0;
    while (written < content.len) {
        const n = write(fd, content.ptr + written, content.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

/// Delete a file by NUL-terminated path.
fn deleteFileZ(path: [*:0]const u8) void {
    _ = linux.unlinkat(linux.AT.FDCWD, path, 0);
}

/// Create a directory (best-effort; ignores EEXIST).
fn mkdirZ(path: [*:0]const u8) void {
    _ = linux.mkdirat(linux.AT.FDCWD, path, 0o755);
}

/// Delete a directory.
fn rmdirZ(path: [*:0]const u8) void {
    _ = linux.unlinkat(linux.AT.FDCWD, path, linux.AT.REMOVEDIR);
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn makeRequest(method: ziez.HttpMethod, path: []const u8, head_buffer: []const u8) ziez.Request {
    return .{
        .method = method,
        .path = path,
        .query = .{},
        .params = .{},
        .body_raw = "",
        .allocator = std.testing.allocator,
        .head_buffer = head_buffer,
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
}

fn makeResponse() ziez.Response {
    return ziez.Response.init(std.testing.allocator);
}

fn responseHeader(res: *const ziez.Response, name: []const u8) ?[]const u8 {
    for (0..res.headers_len) |i| {
        if (std.ascii.eqlIgnoreCase(res.headers[i].name, name)) {
            return res.headers[i].value;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// 1. Successful file read → 200 OK with Content-Type
// ---------------------------------------------------------------------------

test "Static: serves existing file with 200 and correct Content-Type" {
    if (comptime opts.with_static) {
        mkdirZ(".zig-cache/test-static-1");
        try writeFileZ(".zig-cache/test-static-1/hello.html", "<h1>Hello</h1>");
        defer {
            deleteFileZ(".zig-cache/test-static-1/hello.html");
            rmdirZ(".zig-cache/test-static-1");
        }
        var req = makeRequest(.GET, "/static/hello.html", "GET /static/hello.html HTTP/1.1\r\n\r\n");
        var res = makeResponse();
        const handled = try ziez.staticHandle(&req, &res, .{ .root = ".zig-cache/test-static-1", .prefix = "/static", .etag = false });
        try std.testing.expect(handled);
        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        const ct = responseHeader(&res, "content-type") orelse responseHeader(&res, "Content-Type");
        try std.testing.expect(ct != null);
        try std.testing.expect(std.mem.indexOf(u8, ct.?, "text/html") != null);
    }
}

// ---------------------------------------------------------------------------
// 2. ETag round-trip → 304 Not Modified
// ---------------------------------------------------------------------------

test "Static: ETag round-trip returns 304 Not Modified" {
    if (comptime opts.with_static) {
        mkdirZ(".zig-cache/test-static-2");
        try writeFileZ(".zig-cache/test-static-2/data.json", "{\"ok\":true}");
        defer {
            deleteFileZ(".zig-cache/test-static-2/data.json");
            rmdirZ(".zig-cache/test-static-2");
        }
        var etag_value: [64]u8 = undefined;
        var etag_len: usize = 0;
        {
            var req = makeRequest(.GET, "/data.json", "GET /data.json HTTP/1.1\r\n\r\n");
            var res = makeResponse();
            const handled = try ziez.staticHandle(&req, &res, .{ .root = ".zig-cache/test-static-2", .prefix = "/", .etag = true });
            try std.testing.expect(handled);
            try std.testing.expectEqual(@as(u16, 200), res.status_code);
            const etag = responseHeader(&res, "ETag") orelse unreachable;
            @memcpy(etag_value[0..etag.len], etag);
            etag_len = etag.len;
        }
        {
            var head_buf: [256]u8 = undefined;
            const head = try std.fmt.bufPrint(&head_buf, "GET /data.json HTTP/1.1\r\nIf-None-Match: {s}\r\n\r\n", .{etag_value[0..etag_len]});
            var req = makeRequest(.GET, "/data.json", head);
            var res = makeResponse();
            const handled = try ziez.staticHandle(&req, &res, .{ .root = ".zig-cache/test-static-2", .prefix = "/", .etag = true });
            try std.testing.expect(handled);
            try std.testing.expectEqual(@as(u16, 304), res.status_code);
        }
    }
}

// ---------------------------------------------------------------------------
// 3. Path traversal → pass-through
// ---------------------------------------------------------------------------

test "Static: rejects path traversal attempt" {
    if (comptime opts.with_static) {
        mkdirZ(".zig-cache/test-static-3");
        defer rmdirZ(".zig-cache/test-static-3");
        var req = makeRequest(.GET, "/static/../../../etc/passwd", "GET /static/../../../etc/passwd HTTP/1.1\r\n\r\n");
        var res = makeResponse();
        const handled = try ziez.staticHandle(&req, &res, .{ .root = ".zig-cache/test-static-3", .prefix = "/static" });
        try std.testing.expect(!handled);
    }
}

// ---------------------------------------------------------------------------
// 4. Dotfile deny → 403
// ---------------------------------------------------------------------------

test "Static: dotfile deny returns 403 Forbidden" {
    if (comptime opts.with_static) {
        mkdirZ(".zig-cache/test-static-4");
        try writeFileZ(".zig-cache/test-static-4/.env", "SECRET=hunter2");
        defer {
            deleteFileZ(".zig-cache/test-static-4/.env");
            rmdirZ(".zig-cache/test-static-4");
        }
        var req = makeRequest(.GET, "/.env", "GET /.env HTTP/1.1\r\n\r\n");
        var res = makeResponse();
        const handled = try ziez.staticHandle(&req, &res, .{ .root = ".zig-cache/test-static-4", .prefix = "/", .dotfiles = .deny });
        try std.testing.expect(handled);
        try std.testing.expectEqual(@as(u16, 403), res.status_code);
    }
}

// ---------------------------------------------------------------------------
// 5. Dotfile ignore → pass-through
// ---------------------------------------------------------------------------

test "Static: dotfile ignore returns false (pass-through)" {
    if (comptime opts.with_static) {
        mkdirZ(".zig-cache/test-static-5");
        try writeFileZ(".zig-cache/test-static-5/.htaccess", "Options -Indexes");
        defer {
            deleteFileZ(".zig-cache/test-static-5/.htaccess");
            rmdirZ(".zig-cache/test-static-5");
        }
        var req = makeRequest(.GET, "/.htaccess", "GET /.htaccess HTTP/1.1\r\n\r\n");
        var res = makeResponse();
        const handled = try ziez.staticHandle(&req, &res, .{ .root = ".zig-cache/test-static-5", .prefix = "/", .dotfiles = .ignore });
        try std.testing.expect(!handled);
        try std.testing.expect(!res.sent);
    }
}

// ---------------------------------------------------------------------------
// 6. URL prefix mismatch → pass-through
// ---------------------------------------------------------------------------

test "Static: prefix mismatch returns false" {
    if (comptime opts.with_static) {
        mkdirZ(".zig-cache/test-static-6");
        try writeFileZ(".zig-cache/test-static-6/app.js", "console.log(1)");
        defer {
            deleteFileZ(".zig-cache/test-static-6/app.js");
            rmdirZ(".zig-cache/test-static-6");
        }
        var req = makeRequest(.GET, "/other/app.js", "GET /other/app.js HTTP/1.1\r\n\r\n");
        var res = makeResponse();
        const handled = try ziez.staticHandle(&req, &res, .{ .root = ".zig-cache/test-static-6", .prefix = "/assets" });
        try std.testing.expect(!handled);
    }
}

// ---------------------------------------------------------------------------
// 7. POST method → pass-through
// ---------------------------------------------------------------------------

test "Static: POST method is ignored (pass-through)" {
    if (comptime opts.with_static) {
        mkdirZ(".zig-cache/test-static-7");
        try writeFileZ(".zig-cache/test-static-7/file.txt", "hello");
        defer {
            deleteFileZ(".zig-cache/test-static-7/file.txt");
            rmdirZ(".zig-cache/test-static-7");
        }
        var req = makeRequest(.POST, "/file.txt", "POST /file.txt HTTP/1.1\r\n\r\n");
        var res = makeResponse();
        const handled = try ziez.staticHandle(&req, &res, .{ .root = ".zig-cache/test-static-7", .prefix = "/" });
        try std.testing.expect(!handled);
    }
}

// ---------------------------------------------------------------------------
// 8. Cache-Control header reflects max_age
// ---------------------------------------------------------------------------

test "Static: Cache-Control header reflects max_age config" {
    if (comptime opts.with_static) {
        mkdirZ(".zig-cache/test-static-8");
        try writeFileZ(".zig-cache/test-static-8/style.css", "body{}");
        defer {
            deleteFileZ(".zig-cache/test-static-8/style.css");
            rmdirZ(".zig-cache/test-static-8");
        }
        var req = makeRequest(.GET, "/style.css", "GET /style.css HTTP/1.1\r\n\r\n");
        var res = makeResponse();
        _ = try ziez.staticHandle(&req, &res, .{ .root = ".zig-cache/test-static-8", .prefix = "/", .max_age = 3600, .etag = false });
        const cc = responseHeader(&res, "Cache-Control");
        try std.testing.expect(cc != null);
        try std.testing.expect(std.mem.indexOf(u8, cc.?, "3600") != null);
    }
}

// ---------------------------------------------------------------------------
// 9. Missing file → pass-through
// ---------------------------------------------------------------------------

test "Static: missing file returns false (pass-through)" {
    if (comptime opts.with_static) {
        mkdirZ(".zig-cache/test-static-9");
        defer rmdirZ(".zig-cache/test-static-9");
        var req = makeRequest(.GET, "/does-not-exist.txt", "GET /does-not-exist.txt HTTP/1.1\r\n\r\n");
        var res = makeResponse();
        const handled = try ziez.staticHandle(&req, &res, .{ .root = ".zig-cache/test-static-9", .prefix = "/" });
        try std.testing.expect(!handled);
    }
}

// ---------------------------------------------------------------------------
// 10. App.serveStatic stores config in router
// ---------------------------------------------------------------------------

test "App.serveStatic stores config in router" {
    if (comptime opts.with_static) {
        var app = ziez.init(std.testing.allocator);
        defer app.deinit();
        app.serveStatic(.{ .root = "./public", .prefix = "/assets" });
        try std.testing.expectEqual(@as(usize, 1), app.router.static_configs.items.len);
        try std.testing.expectEqualStrings("./public", app.router.static_configs.items[0].root);
        try std.testing.expectEqualStrings("/assets", app.router.static_configs.items[0].prefix);
    }
}
