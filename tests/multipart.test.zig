const std = @import("std");
const ziez = @import("ziez");
const opts = @import("ziez_options");

fn mkdirZ(path: [*:0]const u8) void {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    std.Io.Dir.cwd().createDirPath(io, std.mem.sliceTo(path, 0)) catch {};
}

fn deleteFileZ(path: [*:0]const u8) void {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    std.Io.Dir.cwd().deleteFile(io, std.mem.sliceTo(path, 0)) catch {};
}

fn rmdirZ(path: [*:0]const u8) void {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    std.Io.Dir.cwd().deleteDir(io, std.mem.sliceTo(path, 0)) catch {};
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const stat = try file.stat(io);
    var out = try allocator.alloc(u8, @as(usize, @intCast(stat.size)));
    const n = try file.readPositionalAll(io, out, 0);
    if (n != out.len) {
        out = try allocator.realloc(out, n);
    }
    return out;
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
    if (comptime opts.with_multipart) {
        const b = ziez.Multipart.extractBoundary("multipart/form-data; boundary=----WebKitFormBoundaryABC123");
        try std.testing.expect(b != null);
        try std.testing.expectEqualStrings("----WebKitFormBoundaryABC123", b.?);
    }
}

test "extractBoundary - quoted" {
    if (comptime opts.with_multipart) {
        const b = ziez.Multipart.extractBoundary("multipart/form-data; boundary=\"myboundary\"");
        try std.testing.expect(b != null);
        try std.testing.expectEqualStrings("myboundary", b.?);
    }
}

test "parse multipart" {
    if (comptime opts.with_multipart) {
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
}

test "saveMultipart writes file to local storage and preserves fields" {
    if (comptime opts.with_multipart) {
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
}

test "saveMultipart rejects unsupported mime type" {
    if (comptime opts.with_multipart) {
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
}

test "saveMultipart rejects oversized file" {
    if (comptime opts.with_multipart) {
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
}
