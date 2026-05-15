const std = @import("std");
const http = std.http;
const compression = @import("compression.zig");
const logging = @import("logging.zig");
const util = @import("util.zig");
const log = std.log.scoped(.ziez);
const stream_mod = @import("stream.zig");

pub const Response = struct {
    status_code: u16 = 200,
    headers: [MAX_HEADERS]http.Header = undefined,
    headers_len: usize = 0,
    header_value_storage: [MAX_HEADERS][MAX_HEADER_VALUE]u8 = undefined,
    allocator: std.mem.Allocator,
    sent: bool = false,
    server_request: ?*http.Server.Request = null,
    error_message: ?[]const u8 = null,
    compression_config: ?compression.CompressionConfig = null,
    template_engine: ?*@import("template.zig").TemplateEngine = null,
    logger: ?logging.Logger = null,
    request_id: []const u8 = "",
    streaming: bool = false,
    stream_buffer: [STREAM_BUF_SIZE]u8 = undefined,

    const MAX_HEADERS = 32;
    const MAX_HEADER_VALUE = 2048;
    const STREAM_BUF_SIZE = 8192;

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .allocator = allocator,
            .status_code = 200,
            .headers_len = 0,
            .sent = false,
            .server_request = null,
        };
    }

    pub fn reset(self: *Response) void {
        self.status_code = 200;
        self.headers_len = 0;
        self.sent = false;
        self.server_request = null;
        self.template_engine = null;
        self.logger = null;
        self.request_id = "";
        self.streaming = false;
    }

    pub fn status(self: *Response, code: u16) *Response {
        self.status_code = code;
        return self;
    }

    pub fn set(self: *Response, key: []const u8, val: []const u8) *Response {
        if (self.headers_len < MAX_HEADERS) {
            self.headers[self.headers_len] = .{ .name = key, .value = val };
            self.headers_len += 1;
        }
        return self;
    }

    pub fn setHeader(self: *Response, key: []const u8, val: []const u8) *Response {
        return self.set(key, val);
    }

    pub fn setOrReplaceHeader(self: *Response, key: []const u8, val: []const u8) *Response {
        if (val.len > MAX_HEADER_VALUE) return self;

        if (!std.ascii.eqlIgnoreCase(key, "set-cookie")) {
            for (0..self.headers_len) |i| {
                if (std.ascii.eqlIgnoreCase(self.headers[i].name, key)) {
                    return self.setStoredAt(i, key, val);
                }
            }
        }

        if (self.headers_len >= MAX_HEADERS) return self;
        const index = self.headers_len;
        _ = self.setStoredAt(index, key, val);
        self.headers_len += 1;
        return self;
    }

    pub fn removeHeader(self: *Response, key: []const u8) void {
        var write: usize = 0;
        for (0..self.headers_len) |read| {
            if (std.ascii.eqlIgnoreCase(self.headers[read].name, key)) continue;
            if (write != read) self.headers[write] = self.headers[read];
            write += 1;
        }
        self.headers_len = write;
    }

    pub fn setJoined(self: *Response, key: []const u8, values: []const []const u8) *Response {
        if (values.len == 0 or self.headers_len >= MAX_HEADERS) return self;

        var buf = self.header_value_storage[self.headers_len][0..];
        var len: usize = 0;
        for (values, 0..) |value, i| {
            if (i > 0) {
                if (len + 2 > buf.len) return self;
                @memcpy(buf[len .. len + 2], ", "[0..2]);
                len += 2;
            }
            if (len + value.len > buf.len) return self;
            @memcpy(buf[len .. len + value.len], value);
            len += value.len;
        }

        self.headers[self.headers_len] = .{ .name = key, .value = buf[0..len] };
        self.headers_len += 1;
        return self;
    }

    pub fn setJoinedOrReplace(self: *Response, key: []const u8, values: []const []const u8) *Response {
        if (values.len == 0) return self;

        var buf: [MAX_HEADER_VALUE]u8 = undefined;
        var len: usize = 0;
        for (values, 0..) |value, i| {
            if (i > 0) {
                if (len + 2 > buf.len) return self;
                @memcpy(buf[len .. len + 2], ", "[0..2]);
                len += 2;
            }
            if (len + value.len > buf.len) return self;
            @memcpy(buf[len .. len + value.len], value);
            len += value.len;
        }

        return self.setOrReplaceHeader(key, buf[0..len]);
    }

    pub fn setFormatted(self: *Response, key: []const u8, comptime fmt: []const u8, args: anytype) *Response {
        if (self.headers_len >= MAX_HEADERS) return self;
        const value = std.fmt.bufPrint(&self.header_value_storage[self.headers_len], fmt, args) catch return self;
        self.headers[self.headers_len] = .{ .name = key, .value = value };
        self.headers_len += 1;
        return self;
    }

    pub fn setFormattedOrReplace(self: *Response, key: []const u8, comptime fmt: []const u8, args: anytype) *Response {
        var buf: [MAX_HEADER_VALUE]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, fmt, args) catch return self;
        return self.setOrReplaceHeader(key, value);
    }

    fn setStoredAt(self: *Response, index: usize, key: []const u8, val: []const u8) *Response {
        if (index >= MAX_HEADERS or val.len > MAX_HEADER_VALUE) return self;
        @memcpy(self.header_value_storage[index][0..val.len], val);
        self.headers[index] = .{
            .name = key,
            .value = self.header_value_storage[index][0..val.len],
        };
        return self;
    }

    pub fn type_of(self: *Response, content_type: []const u8) *Response {
        return self.set("content-type", content_type);
    }

    pub fn send(self: *Response, data: []const u8) void {
        _ = self.set("content-type", "text/plain; charset=utf-8");
        self.sendBody(data);
    }

    pub fn json(self: *Response, data: anytype) void {
        const body = std.json.Stringify.valueAlloc(self.allocator, data, .{}) catch |e| {
            self.logError("response", "json_stringify_failed", e);
            self.status(500).sendBody("{\"error\":\"json stringify failed\"}");
            return;
        };
        defer self.allocator.free(body);
        _ = self.set("content-type", "application/json");
        self.sendBody(body);
    }

    /// Serialize data with a SerializerConfig, applying field filtering,
    /// transforms, computed fields, groups, etc.
    pub fn serialize(self: *Response, data: anytype, comptime config: anytype) void {
        const body = @import("serializer.zig").serialize(self.allocator, data, config) catch |e| {
            self.logError("response", "serialize_failed", e);
            self.status(500).sendBody("{\"error\":\"serialization failed\"}");
            return;
        };
        defer self.allocator.free(body);
        _ = self.set("content-type", "application/json");
        self.sendBody(body);
    }

    /// Serialize a slice/array of items with a SerializerConfig.
    pub fn serializeMany(self: *Response, items: anytype, comptime config: anytype) void {
        const body = @import("serializer.zig").serializeMany(self.allocator, items, config) catch |e| {
            self.logError("response", "serialize_many_failed", e);
            self.status(500).sendBody("{\"error\":\"serialization failed\"}");
            return;
        };
        defer self.allocator.free(body);
        _ = self.set("content-type", "application/json");
        self.sendBody(body);
    }

    pub fn html(self: *Response, data: []const u8) void {
        _ = self.set("content-type", "text/html; charset=utf-8");
        self.sendBody(data);
    }

    pub fn render(self: *Response, view: []const u8, context: anytype) void {
        const engine = self.template_engine orelse {
            self.logMessage(.@"error", "response", "template_engine_missing", "render failed");
            self.status(500).sendBody("{\"error\":\"template engine not configured\"}");
            return;
        };

        const result = engine.renderAlloc(self.allocator, view, context) catch |e| {
            self.logError("response", "render_failed", e);
            self.status(500).sendBody("{\"error\":\"template rendering failed\"}");
            return;
        };
        defer self.allocator.free(result);

        self.html(result);
    }

    pub fn redirect(self: *Response, url: []const u8) void {
        _ = self.status(302).set("location", url);
        self.sendBody("");
    }

    pub fn sendStatus(self: *Response, code: u16) void {
        self.status(code).sendBody("");
    }

    /// Set a cookie on the response.
    pub fn setCookie(self: *Response, name: []const u8, value: []const u8, opts: util.CookieOptions) void {
        var buf: [512]u8 = undefined;
        const formatted = util.formatSetCookie(&buf, name, value, opts) orelse return;
        _ = self.set("set-cookie", formatted);
    }

    /// Clear a cookie by setting Max-Age=0.
    pub fn clearCookie(self: *Response, name: []const u8, opts: util.CookieOptions) void {
        var clear_opts = opts;
        clear_opts.max_age = 0;
        self.setCookie(name, "", clear_opts);
    }

    /// Set a signed cookie (value + HMAC-SHA256 signature).
    pub fn setSignedCookie(self: *Response, name: []const u8, value: []const u8, opts: util.CookieOptions, secret: []const u8) !void {
        const signed = try util.signCookie(self.allocator, value, secret);
        defer self.allocator.free(signed);
        self.setCookie(name, signed, opts);
    }

    pub fn sendBody(self: *Response, body: []const u8) void {
        if (self.sent) return;
        self.sent = true;

        const req = self.server_request orelse return;

        // Attempt compression if configured
        if (self.compression_config) |config| {
            const content_type = self.getHeader("content-type");
            const content_encoding = self.getHeader("content-encoding");

            if (compression.shouldCompress(body, content_type, content_encoding, config)) {
                const accept_encoding = self.getAcceptEncoding();
                if (compression.selectAlgorithm(accept_encoding, config)) |algo| {
                    if (compression.compressBody(self.allocator, body, algo, config.level)) |compressed| {
                        _ = self.set("content-encoding", algo.encodingName());
                        self.respondCompressed(req, compressed);
                        self.allocator.free(compressed);
                        return;
                    } else |_| {
                        // Compression failed — send uncompressed
                    }
                }
            }
        }

        self.respondUncompressed(req, body);
    }

    fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        for (0..self.headers_len) |i| {
            if (std.ascii.eqlIgnoreCase(self.headers[i].name, name)) {
                return self.headers[i].value;
            }
        }
        return null;
    }

    fn getAcceptEncoding(self: *const Response) []const u8 {
        const req = self.server_request orelse return "";
        var it = http.HeaderIterator.init(req.head_buffer);
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) return h.value;
        }
        return "";
    }

    fn respondUncompressed(self: *Response, req: *http.Server.Request, body: []const u8) void {
        var extra_headers: [MAX_HEADERS]http.Header = undefined;
        for (0..self.headers_len) |i| {
            extra_headers[i] = self.headers[i];
        }
        const http_status: http.Status = @enumFromInt(self.status_code);
        req.respond(body, .{
            .status = http_status,
            .extra_headers = extra_headers[0..self.headers_len],
            .keep_alive = false,
        }) catch |e| {
            self.logError("response", "respond_uncompressed_failed", e);
        };
    }

    fn respondCompressed(self: *Response, req: *http.Server.Request, body: []const u8) void {
        var extra_headers: [MAX_HEADERS]http.Header = undefined;
        for (0..self.headers_len) |i| {
            extra_headers[i] = self.headers[i];
        }
        const http_status: http.Status = @enumFromInt(self.status_code);
        req.respond(body, .{
            .status = http_status,
            .extra_headers = extra_headers[0..self.headers_len],
            .keep_alive = false,
        }) catch |e| {
            self.logError("response", "respond_compressed_failed", e);
        };
    }

    fn logError(self: *const Response, component: []const u8, event: []const u8, err: anyerror) void {
        if (self.logger) |logger| {
            logger.errorFields(.{
                .component = component,
                .event = event,
                .req_id = self.request_id,
                .@"error" = @errorName(err),
            }, "response error");
            return;
        }

        log.err("{s} error: {s}", .{ component, @errorName(err) });
    }

    fn logMessage(
        self: *const Response,
        level: logging.LogLevel,
        component: []const u8,
        event: []const u8,
        msg: []const u8,
    ) void {
        if (self.logger) |logger| {
            switch (level) {
                .trace => logger.traceFields(.{ .component = component, .event = event, .req_id = self.request_id }, msg),
                .debug => logger.debugFields(.{ .component = component, .event = event, .req_id = self.request_id }, msg),
                .info => logger.infoFields(.{ .component = component, .event = event, .req_id = self.request_id }, msg),
                .warn => logger.warnFields(.{ .component = component, .event = event, .req_id = self.request_id }, msg),
                .@"error" => logger.errorFields(.{ .component = component, .event = event, .req_id = self.request_id }, msg),
                .fatal => logger.fatalFields(.{ .component = component, .event = event, .req_id = self.request_id }, msg),
            }
            return;
        }

        switch (level) {
            .trace, .debug => log.debug("{s}: {s}", .{ component, msg }),
            .info => log.info("{s}: {s}", .{ component, msg }),
            .warn => log.warn("{s}: {s}", .{ component, msg }),
            .@"error", .fatal => log.err("{s}: {s}", .{ component, msg }),
        }
    }

    // -----------------------------------------------------------------------
    // Streaming
    // -----------------------------------------------------------------------

    pub const FileStreamConfig = struct {
        content_type: ?[]const u8 = null,
        download_name: ?[]const u8 = null,
        buffer_size: usize = 65536,
    };

    fn beginStream(self: *Response, content_type: []const u8) !http.BodyWriter {
        if (self.sent) return error.AlreadySent;
        const req = self.server_request orelse return error.NoServerRequest;
        self.sent = true;
        self.streaming = true;

        var extra_headers: [MAX_HEADERS]http.Header = undefined;
        for (0..self.headers_len) |i| {
            extra_headers[i] = self.headers[i];
        }
        extra_headers[self.headers_len] = .{ .name = "content-type", .value = content_type };
        const header_count = self.headers_len + 1;
        const http_status: http.Status = @enumFromInt(self.status_code);

        return req.respondStreaming(&self.stream_buffer, .{
            .respond_options = .{
                .status = http_status,
                .extra_headers = extra_headers[0..header_count],
                .keep_alive = false,
            },
        });
    }

    fn beginStreamWithContentLength(self: *Response, content_type: []const u8, content_length: u64) !http.BodyWriter {
        if (self.sent) return error.AlreadySent;
        const req = self.server_request orelse return error.NoServerRequest;
        self.sent = true;
        self.streaming = true;

        var extra_headers: [MAX_HEADERS]http.Header = undefined;
        for (0..self.headers_len) |i| {
            extra_headers[i] = self.headers[i];
        }
        extra_headers[self.headers_len] = .{ .name = "content-type", .value = content_type };
        const header_count = self.headers_len + 1;
        const http_status: http.Status = @enumFromInt(self.status_code);

        return req.respondStreaming(&self.stream_buffer, .{
            .content_length = content_length,
            .respond_options = .{
                .status = http_status,
                .extra_headers = extra_headers[0..header_count],
                .keep_alive = false,
            },
        });
    }

    fn makeStreamWriter(body_writer: *http.BodyWriter, allocator: std.mem.Allocator, logger: ?logging.Logger, request_id: []const u8) stream_mod.StreamWriter {
        return .{
            .writer = &body_writer.writer,
            .body_writer = body_writer,
            .allocator = allocator,
            .logger = logger,
            .request_id = request_id,
        };
    }

    pub fn stream(self: *Response, content_type: []const u8, callback: stream_mod.StreamCallback) void {
        var body_writer = self.beginStream(content_type) catch return;
        var sw = makeStreamWriter(&body_writer, self.allocator, self.logger, self.request_id);
        callback(&sw) catch |e| {
            self.logError("response", "stream_callback_failed", e);
        };
    }

    pub fn streamNdjson(self: *Response, callback: stream_mod.NdjsonCallback) void {
        var body_writer = self.beginStream("application/x-ndjson") catch return;
        var sw = makeStreamWriter(&body_writer, self.allocator, self.logger, self.request_id);
        var ndjson = stream_mod.NdjsonStreamWriter{ .inner = &sw };
        callback(&ndjson) catch |e| {
            self.logError("response", "ndjson_stream_failed", e);
        };
    }

    pub fn streamSse(self: *Response, callback: stream_mod.SseCallback) void {
        _ = self.set("cache-control", "no-cache");
        _ = self.set("connection", "keep-alive");
        _ = self.set("x-accel-buffering", "no");
        var body_writer = self.beginStream("text/event-stream") catch return;
        var sw = makeStreamWriter(&body_writer, self.allocator, self.logger, self.request_id);
        var sse = stream_mod.SseStreamWriter{ .inner = &sw };
        callback(&sse) catch |e| {
            self.logError("response", "sse_stream_failed", e);
        };
    }

    pub fn streamCsv(self: *Response, config: stream_mod.CsvStreamConfig, callback: stream_mod.CsvCallback) void {
        var body_writer = self.beginStream("text/csv; charset=utf-8") catch return;
        var sw = makeStreamWriter(&body_writer, self.allocator, self.logger, self.request_id);

        if (config.write_bom) {
            sw.write("\xEF\xBB\xBF") catch return;
        }

        var csv = stream_mod.CsvStreamWriter{
            .inner = &sw,
            .delimiter = config.delimiter,
            .quote = config.quote,
        };
        callback(&csv) catch |e| {
            self.logError("response", "csv_stream_failed", e);
        };
    }

    pub fn streamJsonArray(self: *Response, callback: stream_mod.JsonArrayCallback) void {
        var body_writer = self.beginStream("application/json") catch return;
        var sw = makeStreamWriter(&body_writer, self.allocator, self.logger, self.request_id);
        var arr = stream_mod.JsonArrayStreamWriter{ .inner = &sw };
        callback(&arr) catch |e| {
            self.logError("response", "json_array_stream_failed", e);
        };
    }

    pub fn streamText(self: *Response, callback: stream_mod.StreamCallback) void {
        self.stream("text/plain; charset=utf-8", callback);
    }

    pub fn streamFile(self: *Response, file_path: []const u8, config: FileStreamConfig) void {
        if (self.sent) return;
        const allocator = self.allocator;

        const file = std.fs.cwd().openFile(file_path, .{}) catch |e| {
            self.logError("response", "file_open_failed", e);
            self.sent = true;
            self.streaming = true;
            return;
        };
        defer file.close();

        const stat = file.stat() catch |e| {
            self.logError("response", "file_stat_failed", e);
            self.sent = true;
            self.streaming = true;
            return;
        };
        const file_size: u64 = @intCast(stat.size);

        const ct = config.content_type orelse inferMimeType(file_path);
        _ = self.set("content-type", ct);
        _ = self.set("accept-ranges", "bytes");

        if (config.download_name) |name| {
            var buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "attachment; filename=\"{s}\"", .{name})) |disp| {
                _ = self.setOrReplaceHeader("content-disposition", disp);
            } else |_| {}
        }

        const range_header = self.getRequestHeader("range");

        if (range_header) |rh| {
            if (stream_mod.parseRange(rh, file_size)) |range| {
                if (range.start > range.end or range.start >= file_size) {
                    self.sent = true;
                    self.streaming = true;
                    self.status_code = 416;
                    return;
                }

                self.status_code = 206;
                const range_content_length = range.end - range.start + 1;

                var cr_buf: [128]u8 = undefined;
                const cr = std.fmt.bufPrint(&cr_buf, "bytes {d}-{d}/{d}", .{ range.start, range.end, range.total }) catch "";
                _ = self.setOrReplaceHeader("content-range", cr);

                var cl_buf: [32]u8 = undefined;
                const cl = std.fmt.bufPrint(&cl_buf, "{d}", .{range_content_length}) catch "";
                _ = self.setOrReplaceHeader("content-length", cl);

                var body_writer = self.beginStreamWithContentLength(ct, range_content_length) catch return;
                var sw = makeStreamWriter(&body_writer, allocator, self.logger, self.request_id);

                const offset = std.math.cast(i64, range.start) orelse return;
                file.seekTo(offset) catch |e| {
                    self.logError("response", "file_seek_failed", e);
                    return;
                };

                const remaining = range.end - range.start + 1;
                var read_buf = allocator.alloc(u8, config.buffer_size) catch return;
                defer allocator.free(read_buf);

                var to_read = remaining;
                while (to_read > 0) {
                    const chunk_len = @min(to_read, read_buf.len);
                    const n = file.read(read_buf[0..chunk_len]) catch |e| {
                        self.logError("response", "file_read_failed", e);
                        break;
                    };
                    if (n == 0) break;
                    sw.write(read_buf[0..n]) catch |e| {
                        self.logError("response", "file_write_failed", e);
                        break;
                    };
                    to_read -= n;
                }

                sw.end() catch {};
                return;
            }
        }

        // Full file response
        var cl_buf: [32]u8 = undefined;
        const cl = std.fmt.bufPrint(&cl_buf, "{d}", .{file_size}) catch "";
        _ = self.setOrReplaceHeader("content-length", cl);

        var body_writer = self.beginStreamWithContentLength(ct, file_size) catch return;
        var sw = makeStreamWriter(&body_writer, allocator, self.logger, self.request_id);

        var read_buf = allocator.alloc(u8, config.buffer_size) catch return;
        defer allocator.free(read_buf);

        while (true) {
            const n = file.read(read_buf) catch |e| {
                self.logError("response", "file_read_failed", e);
                break;
            };
            if (n == 0) break;
            sw.write(read_buf[0..n]) catch |e| {
                self.logError("response", "file_write_failed", e);
                break;
            };
        }

        sw.end() catch {};
    }

    fn getRequestHeader(self: *const Response, name: []const u8) ?[]const u8 {
        const req = self.server_request orelse return null;
        var it = http.HeaderIterator.init(req.head_buffer);
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    fn inferMimeType(path: []const u8) []const u8 {
        const ext_idx = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
        const ext = path[ext_idx..];
        if (std.ascii.eqlIgnoreCase(ext, ".html")) return "text/html; charset=utf-8";
        if (std.ascii.eqlIgnoreCase(ext, ".css")) return "text/css; charset=utf-8";
        if (std.ascii.eqlIgnoreCase(ext, ".js")) return "application/javascript; charset=utf-8";
        if (std.ascii.eqlIgnoreCase(ext, ".json")) return "application/json; charset=utf-8";
        if (std.ascii.eqlIgnoreCase(ext, ".xml")) return "application/xml; charset=utf-8";
        if (std.ascii.eqlIgnoreCase(ext, ".csv")) return "text/csv; charset=utf-8";
        if (std.ascii.eqlIgnoreCase(ext, ".txt")) return "text/plain; charset=utf-8";
        if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "application/pdf";
        if (std.ascii.eqlIgnoreCase(ext, ".zip")) return "application/zip";
        if (std.ascii.eqlIgnoreCase(ext, ".gz")) return "application/gzip";
        if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
        if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
        if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
        if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "image/svg+xml";
        if (std.ascii.eqlIgnoreCase(ext, ".ico")) return "image/x-icon";
        if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
        if (std.ascii.eqlIgnoreCase(ext, ".mp4")) return "video/mp4";
        if (std.ascii.eqlIgnoreCase(ext, ".webm")) return "video/webm";
        if (std.ascii.eqlIgnoreCase(ext, ".mp3")) return "audio/mpeg";
        if (std.ascii.eqlIgnoreCase(ext, ".ogg")) return "audio/ogg";
        if (std.ascii.eqlIgnoreCase(ext, ".wasm")) return "application/wasm";
        if (std.ascii.eqlIgnoreCase(ext, ".tar")) return "application/x-tar";
        return "application/octet-stream";
    }
};
