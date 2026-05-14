const std = @import("std");
const http = std.http;
const compression = @import("compression.zig");
const logging = @import("logging.zig");
const util = @import("util.zig");
const log = std.log.scoped(.ziez);

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

    const MAX_HEADERS = 32;
    const MAX_HEADER_VALUE = 2048;

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
};
