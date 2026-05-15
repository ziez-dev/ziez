const std = @import("std");
const ziez = @import("ziez");
const platform = ziez.platform;

fn io() std.Io {
    var threaded = std.Io.Threaded.init_single_threaded;
    return threaded.io();
}

// ── fillRandomBytes ───────────────────────────────────────────────────────────

test "fillRandomBytes: returns non-zero bytes" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    platform.fillRandomBytes(&buf);
    var all_zero = true;
    for (buf) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try std.testing.expect(!all_zero);
}

test "fillRandomBytes: different calls produce different results" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    platform.fillRandomBytes(&a);
    platform.fillRandomBytes(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "fillRandomBytes: works with empty buffer" {
    var buf: [0]u8 = undefined;
    platform.fillRandomBytes(&buf);
}

// ── openFileReadOnly ──────────────────────────────────────────────────────────

test "openFileReadOnly: returns error for missing file" {
    const result = platform.openFileReadOnly(io(), "ziez-platform-test/missing-file.zig");
    try std.testing.expectError(error.FileNotFound, result);
}

// ── statFile ─────────────────────────────────────────────────────────────────

test "statFile: regular file metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io(), "data.bin", .{ .read = true });
    defer file.close(io());

    const stat = try platform.statFile(file, io());
    try std.testing.expect(stat.size == 0);
    try std.testing.expect(!stat.is_dir);
    try std.testing.expect(stat.mtime_ns > 0);
}

test "statFile: file with known content size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io(), "hello.txt", .{ .read = true });
    const content = "hello world";
    _ = try file.writePositionalAll(io(), content, 0);
    file.close(io());

    const file2 = try tmp.dir.openFile(io(), "hello.txt", .{ .mode = .read_only });
    defer file2.close(io());

    const stat = try platform.statFile(file2, io());
    try std.testing.expect(stat.size == content.len);
    try std.testing.expect(!stat.is_dir);
}

// ── readFileAll ──────────────────────────────────────────────────────────────

test "readFileAll: reads file content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io(), "content.txt", .{ .read = true });
    const payload = "hello from platform test";
    _ = try file.writePositionalAll(io(), payload, 0);
    file.close(io());

    const file2 = try tmp.dir.openFile(io(), "content.txt", .{ .mode = .read_only });
    defer file2.close(io());

    const content = try platform.readFileAll(std.testing.allocator, file2, io(), 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqual(payload.len, content.len);
    try std.testing.expect(std.mem.eql(u8, payload, content));
}

test "readFileAll: respects max limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io(), "big.txt", .{ .read = true });
    const payload = "0123456789ABCDEF"; // 16 bytes
    _ = try file.writePositionalAll(io(), payload, 0);
    file.close(io());

    const file2 = try tmp.dir.openFile(io(), "big.txt", .{ .mode = .read_only });
    defer file2.close(io());

    const content = try platform.readFileAll(std.testing.allocator, file2, io(), 10);
    defer std.testing.allocator.free(content);
    try std.testing.expect(content.len == 10);
    try std.testing.expect(std.mem.eql(u8, content, payload[0..10]));
}

test "readFileAll: reads empty file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io(), "empty.dat", .{ .read = true });
    defer file.close(io());

    const content = try platform.readFileAll(std.testing.allocator, file, io(), 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(content.len == 0);
}

// ── FileStat struct ───────────────────────────────────────────────────────────

test "FileStat: struct fields" {
    const stat = ziez.FileStat{
        .mtime_ns = 1700000000000000000,
        .size = 42,
        .is_dir = false,
    };
    try std.testing.expect(stat.mtime_ns == 1700000000000000000);
    try std.testing.expect(stat.size == 42);
    try std.testing.expect(!stat.is_dir);
}
