const std = @import("std");
const flate = std.compress.flate;
const brotli_c = @import("brotli_c");

pub const Algorithm = enum {
    gzip,
    deflate,
    brotli,

    pub fn encodingName(self: Algorithm) []const u8 {
        return switch (self) {
            .gzip => "gzip",
            .deflate => "deflate",
            .brotli => "br",
        };
    }

    pub fn toContainer(self: Algorithm) flate.Container {
        return switch (self) {
            .gzip => .gzip,
            .deflate => .raw,
            .brotli => unreachable,
        };
    }
};

pub const CompressionConfig = struct {
    enabled: bool = true,
    threshold: usize = 1024,
    level: CompressionLevel = .default,
    algorithms: []const Algorithm = &.{ .gzip, .deflate },
    mime_types: []const []const u8 = &.{
        "text/html",
        "text/css",
        "text/javascript",
        "application/json",
        "application/javascript",
        "text/plain",
        "image/svg+xml",
        "text/xml",
        "application/xml",
    },
};

pub const CompressionLevel = enum(u8) {
    level_1 = 1,
    level_2 = 2,
    level_3 = 3,
    level_4 = 4,
    level_5 = 5,
    level_6 = 6,
    level_7 = 7,
    level_8 = 8,
    level_9 = 9,
    fastest = 10,
    default = 11,
    best = 12,

    pub fn toOptions(self: CompressionLevel) flate.Compress.Options {
        return switch (self) {
            .level_1, .fastest => flate.Compress.Options.level_1,
            .level_2 => flate.Compress.Options.level_2,
            .level_3 => flate.Compress.Options.level_3,
            .level_4 => flate.Compress.Options.level_4,
            .level_5 => flate.Compress.Options.level_5,
            .level_6, .default => flate.Compress.Options.level_6,
            .level_7 => flate.Compress.Options.level_7,
            .level_8 => flate.Compress.Options.level_8,
            .level_9, .best => flate.Compress.Options.level_9,
        };
    }

    pub fn toBrotliQuality(self: CompressionLevel) c_int {
        return switch (self) {
            .level_1, .fastest => 1,
            .level_2 => 2,
            .level_3 => 3,
            .level_4 => 4,
            .level_5 => 5,
            .level_6, .default => 6,
            .level_7 => 7,
            .level_8 => 9,
            .level_9, .best => 11,
        };
    }
};

pub const CompressionResult = struct {
    body: []const u8,
    encoding: []const u8,
};

/// Parse Accept-Encoding header and select best algorithm from config.
/// Returns null if no supported algorithm is found.
pub fn selectAlgorithm(accept_encoding: []const u8, config: CompressionConfig) ?Algorithm {
    if (accept_encoding.len == 0) return null;

    for (config.algorithms) |algo| {
        const name = algo.encodingName();
        if (containsEncoding(accept_encoding, name)) return algo;
    }
    return null;
}

fn containsEncoding(accept_encoding: []const u8, encoding: []const u8) bool {
    var start: usize = 0;
    while (start < accept_encoding.len) {
        // skip whitespace and commas
        while (start < accept_encoding.len and (accept_encoding[start] == ' ' or accept_encoding[start] == ',')) {
            start += 1;
        }
        if (start >= accept_encoding.len) break;

        // find end of token
        var end = start;
        while (end < accept_encoding.len and accept_encoding[end] != ',' and accept_encoding[end] != ';') {
            end += 1;
        }

        const token = std.mem.trim(u8, accept_encoding[start..end], " ");
        if (std.mem.eql(u8, token, encoding)) return true;

        // skip past semicolons (for q= values)
        start = end;
        while (start < accept_encoding.len and accept_encoding[start] != ',') {
            start += 1;
        }
    }
    return false;
}

/// Check if a response should be compressed based on config rules.
pub fn shouldCompress(
    body: []const u8,
    content_type: ?[]const u8,
    content_encoding: ?[]const u8,
    config: CompressionConfig,
) bool {
    if (!config.enabled) return false;
    if (body.len < config.threshold) return false;

    // Already compressed — don't double-compress
    if (content_encoding != null) return false;

    // Check MIME type
    const ct = content_type orelse return false;
    var match = false;
    for (config.mime_types) |mime| {
        if (std.mem.indexOf(u8, ct, mime) != null) {
            match = true;
            break;
        }
    }
    return match;
}

/// Compress body using the specified algorithm.
/// Caller owns the returned slice — must free with allocator.
pub fn compressBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    algo: Algorithm,
    level: CompressionLevel,
) ![]const u8 {
    switch (algo) {
        .gzip, .deflate => return compressFlate(allocator, body, algo, level),
        .brotli => return compressBrotli(allocator, body, level),
    }
}

fn compressFlate(
    allocator: std.mem.Allocator,
    body: []const u8,
    algo: Algorithm,
    level: CompressionLevel,
) ![]const u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, body.len);
    errdefer aw.deinit();

    var buf: [flate.max_window_len]u8 = undefined;

    var compressor = try flate.Compress.init(
        &aw.writer,
        &buf,
        algo.toContainer(),
        level.toOptions(),
    );
    try compressor.writer.writeAll(body);
    try compressor.finish();

    return try aw.toOwnedSlice();
}

fn compressBrotli(
    allocator: std.mem.Allocator,
    body: []const u8,
    level: CompressionLevel,
) ![]const u8 {
    const quality = level.toBrotliQuality();
    const max_size = brotli_c.BrotliEncoderMaxCompressedSize(body.len);
    const output = try allocator.alloc(u8, max_size);
    errdefer allocator.free(output);

    var encoded_size: usize = output.len;
    const result = brotli_c.BrotliEncoderCompress(
        quality,
        brotli_c.BROTLI_DEFAULT_WINDOW,
        brotli_c.BROTLI_MODE_GENERIC,
        body.len,
        body.ptr,
        &encoded_size,
        output.ptr,
    );

    if (result != brotli_c.BROTLI_TRUE) return error.BrotliEncodeFailed;

    return allocator.realloc(output, encoded_size);
}

// ── Type-erased adapter for DCE integration ───────────────────────────────────

/// Called via function pointer from Response.sendBody when compression is active.
/// Accesses all needed data through public struct fields on Response.
pub fn applyFn(config_ptr: *anyopaque, body: []const u8, res: *@import("../core/response.zig").Response) bool {
    const config: *const CompressionConfig = @ptrCast(@alignCast(config_ptr));
    const req = res.server_request orelse return false;

    var content_type: ?[]const u8 = null;
    var content_encoding: ?[]const u8 = null;
    for (res.headers[0..res.headers_len]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) content_type = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "content-encoding")) content_encoding = h.value;
    }

    if (!shouldCompress(body, content_type, content_encoding, config.*)) return false;

    var accept_encoding: []const u8 = "";
    var it = std.http.HeaderIterator.init(req.head_buffer);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) {
            accept_encoding = h.value;
            break;
        }
    }

    const algo = selectAlgorithm(accept_encoding, config.*) orelse return false;
    const compressed = compressBody(res.allocator, body, algo, config.level) catch return false;
    defer res.allocator.free(compressed);

    _ = res.set("content-encoding", algo.encodingName());

    var extra_headers: [32]std.http.Header = undefined;
    for (res.headers[0..res.headers_len], 0..) |h, i| extra_headers[i] = h;
    req.respond(compressed, .{
        .status = @enumFromInt(res.status_code),
        .extra_headers = extra_headers[0..res.headers_len],
        .keep_alive = true,
    }) catch {};
    return true;
}

pub fn freeConfigFn(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    allocator.destroy(@as(*CompressionConfig, @ptrCast(@alignCast(ptr))));
}
