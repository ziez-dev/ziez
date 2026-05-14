const std = @import("std");
const ziez = @import("ziez");

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
