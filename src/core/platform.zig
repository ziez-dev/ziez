const std = @import("std");
const builtin = @import("builtin");

pub const FileStat = struct {
    mtime_ns: i64,
    size: u64,
    is_dir: bool,
};

const buffered_read_chunk_size = if (builtin.os.tag == .windows) 64 * 1024 else 8 * 1024;

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
    if (file.length(io)) |len_u64| {
        const want_u64 = @min(len_u64, max);
        const want: usize = @intCast(want_u64);
        const buf = try allocator.alloc(u8, want);
        errdefer allocator.free(buf);

        const n = try file.readPositionalAll(io, buf, 0);
        if (n == buf.len) return buf;
        return allocator.realloc(buf, n);
    } else |err| switch (err) {
        error.Streaming => {},
        else => return err,
    }

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    var read_buf: [buffered_read_chunk_size]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    reader.interface.appendRemaining(allocator, &list, .limited(max)) catch |read_err| switch (read_err) {
        error.ReadFailed => return reader.err.?,
        else => return read_err,
    };

    return list.toOwnedSlice(allocator);
}

pub fn fillRandomBytes(buf: []u8) void {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    io.random(buf);
}
