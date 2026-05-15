const std = @import("std");
const builtin = @import("builtin");

pub const FileStat = struct {
    mtime_ns: i64,
    size: u64,
    is_dir: bool,
};

pub fn openFileReadOnly(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
}

pub fn statFile(file: std.Io.File, io: std.Io) !FileStat {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const mask: linux.STATX = .{ .SIZE = true, .MTIME = true, .TYPE = true, .MODE = true };
        const rc = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, mask, &sx);
        if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
        const is_dir = (sx.mode & linux.S.IFMT) == linux.S.IFDIR;
        return .{
            .mtime_ns = @as(i64, sx.mtime.sec) * std.time.ns_per_s + sx.mtime.nsec,
            .size = sx.size,
            .is_dir = is_dir,
        };
    }
    const st = try file.stat(io);
    return .{
        .mtime_ns = @truncate(st.mtime.nanoseconds),
        .size = st.size,
        .is_dir = st.kind == .directory,
    };
}

pub fn readFileAll(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, max: usize) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    var pos: u64 = 0;
    while (list.items.len < max) {
        const remaining = max - list.items.len;
        const want = @min(remaining, 8192);
        var tmp: [8192]u8 = undefined;
        const n = try file.readPositionalAll(io, tmp[0..want], pos);
        if (n == 0) break;
        try list.appendSlice(allocator, tmp[0..n]);
        pos += n;
    }
    return list.toOwnedSlice(allocator);
}

pub fn fillRandomBytes(buf: []u8) void {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    io.randomSecure(buf) catch unreachable;
}
