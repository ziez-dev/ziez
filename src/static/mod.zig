const std = @import("std");
const builtin = @import("builtin");
const Request = @import("../core/request.zig").Request;
const Response = @import("../core/response.zig").Response;

// ── POSIX shim ────────────────────────────────────────────────────────────────
// Zig 0.16 moved all Dir/File I/O behind std.Io (async). For synchronous
// serving in handlers we fall back to raw POSIX syscalls, matching env.zig.
extern "c" fn close(fd: std.posix.fd_t) c_int;

/// FileStat holds the fields we need for ETag generation.
const FileStat = struct {
    mtime_ns: i64,
    size: u64,
    is_dir: bool,
};

/// Open a file by NUL-terminated absolute or relative path.
/// Returns POSIX fd or error.
fn posixOpen(path: [*:0]const u8) std.posix.OpenError!std.posix.fd_t {
    return std.posix.openatZ(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
}

/// Stat a file descriptor using `fstatx` (Linux) or `fstat` (others).
fn posixStat(fd: std.posix.fd_t) !FileStat {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const mask: linux.STATX = .{ .SIZE = true, .MTIME = true, .TYPE = true, .MODE = true };
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, mask, &sx);
        if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
        const is_dir = (sx.mode & linux.S.IFMT) == linux.S.IFDIR;
        return .{
            .mtime_ns = @as(i64, sx.mtime.sec) * std.time.ns_per_s + sx.mtime.nsec,
            .size = sx.size,
            .is_dir = is_dir,
        };
    } else {
        // Non-Linux — not the primary target for this framework
        return error.UnsupportedPlatform;
    }
}

/// Read the full contents of `fd` into a heap-allocated buffer.
/// Caller must free the returned slice.
fn posixReadAll(allocator: std.mem.Allocator, fd: std.posix.fd_t, max: usize) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    var tmp: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < max) {
        const n = std.posix.read(fd, &tmp) catch return error.ReadFailed;
        if (n == 0) break;
        try buf.appendSlice(allocator, tmp[0..n]);
        total += n;
    }
    return buf.toOwnedSlice(allocator);
}

// Cached error-code from the last statx call for directory detection
const ENOTDIR: i32 = 20;

// ── Public types ──────────────────────────────────────────────────────────────

/// Policy for handling dot-files (e.g. `.env`, `.htaccess`).
pub const DotfilePolicy = enum {
    /// Respond with 403 Forbidden.
    deny,
    /// Serve them like any other file.
    allow,
    /// Pretend they don't exist (pass-through to next handler).
    ignore,
};

/// Configuration for static-file serving.
pub const StaticConfig = struct {
    /// Filesystem directory that is the root of all served files.
    root: []const u8,
    /// URL prefix that must match before stripping and resolving.
    prefix: []const u8 = "/",
    /// Value of the `Cache-Control: max-age=N` directive in seconds.
    max_age: u32 = 86400,
    /// Whether to generate and honour `ETag` headers for 304 responses.
    etag: bool = true,
    /// Default file served when a directory URL is requested.
    index: []const u8 = "index.html",
    /// How to deal with files whose basename starts with `.`.
    dotfiles: DotfilePolicy = .deny,
};

// ── MIME type helper ──────────────────────────────────────────────────────────

fn getMimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return "application/octet-stream";

    var buf: [16]u8 = undefined;
    if (ext.len > buf.len) return "application/octet-stream";
    const ext_lower = std.ascii.lowerString(buf[0..ext.len], ext);

    if (std.mem.eql(u8, ext_lower, ".html") or std.mem.eql(u8, ext_lower, ".htm")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext_lower, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext_lower, ".js") or std.mem.eql(u8, ext_lower, ".mjs")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext_lower, ".json")) return "application/json";
    if (std.mem.eql(u8, ext_lower, ".png")) return "image/png";
    if (std.mem.eql(u8, ext_lower, ".jpg") or std.mem.eql(u8, ext_lower, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext_lower, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext_lower, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext_lower, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext_lower, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ext_lower, ".webp")) return "image/webp";
    if (std.mem.eql(u8, ext_lower, ".xml")) return "application/xml";
    if (std.mem.eql(u8, ext_lower, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext_lower, ".mp4")) return "video/mp4";
    if (std.mem.eql(u8, ext_lower, ".webm")) return "video/webm";
    if (std.mem.eql(u8, ext_lower, ".woff")) return "font/woff";
    if (std.mem.eql(u8, ext_lower, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext_lower, ".ttf")) return "font/ttf";

    return "application/octet-stream";
}

// ── Dotfile guard ─────────────────────────────────────────────────────────────

/// Returns `true` if this dotfile was handled (the caller must stop).
/// For `.deny` a 403 is written and `true` is returned.
/// For `.ignore` `true` is returned without writing anything.
/// For `.allow` `false` is returned so the caller continues normally.
fn applyDotfilePolicy(res: *Response, basename: []const u8, policy: DotfilePolicy) bool {
    if (!std.mem.startsWith(u8, basename, ".")) return false;
    switch (policy) {
        .deny => {
            res.status(403).json(.{ .@"error" = "Forbidden", .statusCode = 403 });
            return true;
        },
        .ignore => return true,
        .allow => return false,
    }
}

// ── Public handler ────────────────────────────────────────────────────────────

/// Intercept a GET/HEAD request and serve the matching file from `config.root`.
///
/// Returns:
///   `true`  → this handler sent the response (caller must return).
///   `false` → request not claimed, fall through.
pub fn handle(req: *Request, res: *Response, config: StaticConfig) !bool {
    if (req.method != .GET and req.method != .HEAD) return false;
    if (!std.mem.startsWith(u8, req.path, config.prefix)) return false;

    // Strip prefix and ensure leading /
    var path_prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    var req_path: []const u8 = req.path[config.prefix.len..];
    if (req_path.len == 0 or req_path[0] != '/') {
        req_path = std.fmt.bufPrint(&path_prefix_buf, "/{s}", .{req_path}) catch return false;
    }

    // ── Path traversal protection ─────────────────────────────────────────
    if (std.mem.indexOf(u8, req_path, "..") != null) return false;
    if (std.mem.indexOfScalar(u8, req_path, 0) != null) return false;

    // ── Build NUL-terminated filesystem path ──────────────────────────────
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const file_path = std.fmt.bufPrintZ(&path_buf, "{s}{s}", .{ config.root, req_path }) catch return false;

    // ── Dotfile guard (requested path) ────────────────────────────────────
    {
        const basename = std.fs.path.basename(std.mem.sliceTo(file_path, 0));
        if (applyDotfilePolicy(res, basename, config.dotfiles)) {
            return config.dotfiles == .deny; // deny=true(sent 403), ignore=false(pass-through)
        }
    }

    // ── Open file ─────────────────────────────────────────────────────────
    const fd = posixOpen(file_path) catch |err| switch (err) {
        error.IsDir => blk: {
            // Try appending the index file
            if (config.index.len == 0) return false;

            var idx_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            // Strip trailing slash from the original path
            const base = std.mem.sliceTo(file_path, 0);
            const trimmed = if (std.mem.endsWith(u8, base, "/")) base[0 .. base.len - 1] else base;
            const idx_path = std.fmt.bufPrintZ(&idx_buf, "{s}/{s}", .{ trimmed, config.index }) catch return false;

            // Dotfile guard for the index file
            const idx_basename = std.fs.path.basename(std.mem.sliceTo(idx_path, 0));
            if (applyDotfilePolicy(res, idx_basename, config.dotfiles)) {
                return config.dotfiles == .deny;
            }

            // Patch the active file_path in-place for MIME type lookup
            @memcpy(path_buf[0..idx_buf.len], &idx_buf);

            break :blk posixOpen(idx_path) catch return false;
        },
        error.FileNotFound, error.NotDir, error.AccessDenied => return false,
        else => return false,
    };
    defer _ = close(fd);

    // ── Stat ──────────────────────────────────────────────────────────────
    const stat = posixStat(fd) catch return false;

    // If we opened a directory fd somehow, bail
    if (stat.is_dir) return false;

    // ── ETag generation and 304 short-circuit ─────────────────────────────
    if (config.etag) {
        var etag_buf: [64]u8 = undefined;
        const etag = std.fmt.bufPrint(&etag_buf, "\"{d}-{d}\"", .{ stat.mtime_ns, stat.size }) catch return false;

        if (req.header("if-none-match")) |inm| {
            if (std.mem.eql(u8, inm, etag)) {
                _ = res.status(304).setOrReplaceHeader("ETag", etag);
                res.sendBody("");
                return true;
            }
        }
        _ = res.setOrReplaceHeader("ETag", etag);
    }

    // ── Cache-Control & Content-Type ──────────────────────────────────────
    _ = res.setFormattedOrReplace("Cache-Control", "public, max-age={d}", .{config.max_age});
    _ = res.type_of(getMimeType(std.mem.sliceTo(&path_buf, 0)));

    if (req.method == .HEAD) {
        _ = res.status(200);
        res.sendBody("");
        return true;
    }

    // ── Read and send ─────────────────────────────────────────────────────
    const content = posixReadAll(res.allocator, fd, 64 * 1024 * 1024) catch return false;
    defer res.allocator.free(content);

    _ = res.status(200);
    res.sendBody(content);
    return true;
}
