const std = @import("std");
const ziez = @import("ziez");

extern "c" fn close(fd: std.posix.fd_t) c_int;

const linux = std.os.linux;

fn mkdirZ(path: [*:0]const u8) void {
    _ = linux.mkdirat(linux.AT.FDCWD, path, 0o755);
}

fn deleteFileZ(path: [*:0]const u8) void {
    _ = linux.unlinkat(linux.AT.FDCWD, path, 0);
}

fn rmdirZ(path: [*:0]const u8) void {
    _ = linux.unlinkat(linux.AT.FDCWD, path, linux.AT.REMOVEDIR);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocator.dupeZ(u8, path);
    defer allocator.free(zpath);

    const fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        zpath,
        .{ .ACCMODE = .RDONLY },
        0,
    );
    defer _ = close(fd);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var tmp: [256]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &tmp);
        if (n == 0) break;
        try out.appendSlice(allocator, tmp[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

fn makeMultipartRequest(body: []const u8, content_type: []const u8) ziez.Request {
    return .{
        .method = .POST,
        .path = "/upload",
        .query = .{},
        .params = .{},
        .body_raw = body,
        .allocator = std.testing.allocator,
        .head_buffer = content_type,
        .owns_body = false,
        .cookies = .{},
        .cookies_parsed = false,
    };
}

test "extractBoundary" {
    const b = ziez.Multipart.extractBoundary("multipart/form-data; boundary=----WebKitFormBoundaryABC123");
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("----WebKitFormBoundaryABC123", b.?);
}

test "extractBoundary - quoted" {
    const b = ziez.Multipart.extractBoundary("multipart/form-data; boundary=\"myboundary\"");
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("myboundary", b.?);
}

test "parse multipart" {
    const body =
        "--myboundary\r\n" ++
        "Content-Disposition: form-data; name=\"field1\"\r\n" ++
        "\r\n" ++
        "value1\r\n" ++
        "--myboundary\r\n" ++
        "Content-Disposition: form-data; name=\"file1\"; filename=\"test.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "file content here\r\n" ++
        "--myboundary--\r\n";

    var mp = try ziez.Multipart.parse(std.testing.allocator, body, "myboundary");
    defer mp.deinit();

    try std.testing.expectEqual(@as(usize, 2), mp.parts.items.len);

    const field = mp.get("field1").?;
    try std.testing.expectEqualStrings("field1", field.name);
    try std.testing.expectEqualStrings("value1", field.data);
    try std.testing.expect(field.filename == null);

    const file = mp.getFile("file1").?;
    try std.testing.expectEqualStrings("file1", file.name);
    try std.testing.expectEqualStrings("test.txt", file.filename.?);
    try std.testing.expectEqualStrings("text/plain", file.content_type.?);
    try std.testing.expectEqualStrings("file content here", file.data);
}

test "saveMultipart writes file to local storage and preserves fields" {
    mkdirZ(".zig-cache/test-upload");
    mkdirZ(".zig-cache/test-upload/uploads");
    defer {
        rmdirZ(".zig-cache/test-upload/uploads");
        rmdirZ(".zig-cache/test-upload");
    }

    const body =
        "--boundary123\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "alice\r\n" ++
        "--boundary123\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"../../photo.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "hello upload\r\n" ++
        "--boundary123--";

    var req = makeMultipartRequest(
        body,
        "POST /upload HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=boundary123\r\nContent-Length: 218\r\n\r\n",
    );

    var upload = try req.saveMultipart(.{
        .root_dir = ".zig-cache/test-upload",
        .subdir = "uploads",
        .max_files = 2,
        .allowed_types = &.{"text/plain"},
        .file_fields = &.{"avatar"},
        .chunk_size = 5,
    });
    defer {
        for (upload.files.items) |file| {
            const zpath = std.testing.allocator.dupeZ(u8, file.path) catch continue;
            defer std.testing.allocator.free(zpath);
            deleteFileZ(zpath);
        }
        upload.deinit();
    }

    try std.testing.expectEqualStrings("alice", upload.getField("username").?);
    try std.testing.expectEqual(@as(usize, 1), upload.files.items.len);

    const file = upload.getFile("avatar").?;
    try std.testing.expectEqualStrings("../../photo.txt", file.original_name);
    try std.testing.expectEqualStrings("photo.txt", file.sanitized_name);
    try std.testing.expectEqualStrings("text/plain", file.content_type);
    try std.testing.expect(file.size == "hello upload".len);

    const saved = try readFileAlloc(std.testing.allocator, file.path);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("hello upload", saved);
}

test "saveMultipart rejects unsupported mime type" {
    const body =
        "--mimebound\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "hello\r\n" ++
        "--mimebound--";

    var req = makeMultipartRequest(
        body,
        "POST /upload HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=mimebound\r\nContent-Length: 130\r\n\r\n",
    );

    try std.testing.expectError(error.UnsupportedMediaType, req.saveMultipart(.{
        .root_dir = ".zig-cache/test-upload-mime",
        .allowed_types = &.{"image/*"},
        .file_fields = &.{"avatar"},
    }));
}

test "saveMultipart rejects oversized file" {
    mkdirZ(".zig-cache/test-upload-too-large");
    defer rmdirZ(".zig-cache/test-upload-too-large");

    const body =
        "--bigbound\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"big.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "0123456789\r\n" ++
        "--bigbound--";

    var req = makeMultipartRequest(
        body,
        "POST /upload HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=bigbound\r\nContent-Length: 127\r\n\r\n",
    );

    try std.testing.expectError(error.PayloadTooLarge, req.saveMultipart(.{
        .root_dir = ".zig-cache/test-upload-too-large",
        .max_file_size = 4,
        .allowed_types = &.{"text/plain"},
        .file_fields = &.{"avatar"},
        .chunk_size = 4,
    }));
}
