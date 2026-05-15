const std = @import("std");
const http = std.http;
const util = @import("util.zig");
const multipart = @import("../multipart/mod.zig");

pub const Request = struct {
    method: util.HttpMethod,
    path: []const u8,
    request_id: []const u8 = "",
    query: util.QueryParams,
    params: util.Params,
    body_raw: []const u8,
    allocator: std.mem.Allocator,
    head_buffer: []const u8,
    owns_body: bool,
    server_request: ?*http.Server.Request = null,
    multipart_consumed: bool = false,
    owned_query_values: [util.QueryParams.MAX_ENTRIES]?[]const u8 = [_]?[]const u8{null} ** util.QueryParams.MAX_ENTRIES,
    request_id_storage: [32]u8 = undefined,
    cookies: util.Cookies,
    cookies_parsed: bool,
    /// True if the connection is TLS-encrypted.
    tls: bool = false,
    /// Negotiated TLS version string (e.g., "TLSv1.3").
    tls_version: ?[]const u8 = null,
    /// Client certificate subject (mTLS).
    client_cert_subject: ?[]const u8 = null,
    /// Client certificate SHA-256 fingerprint (mTLS).
    client_cert_fingerprint: ?[32]u8 = null,

    pub fn initFromHead(
        allocator: std.mem.Allocator,
        head_buffer: []const u8,
    ) !Request {
        const head = http.Server.Request.Head.parse(head_buffer) catch {
            return error.InvalidHead;
        };

        const target = head.target;
        const split = util.splitPathQuery(target);
        const method = util.HttpMethod.fromStdMethod(head.method) orelse .GET;

        return Request{
            .method = method,
            .path = split.path,
            .query = util.parseQuery(split.query),
            .params = .{},
            .body_raw = "",
            .request_id = "",
            .allocator = allocator,
            .head_buffer = head_buffer,
            .owns_body = false,
            .server_request = null,
            .multipart_consumed = false,
            .cookies = .{},
            .cookies_parsed = false,
        };
    }

    pub fn deinit(self: *Request) void {
        for (0..self.owned_query_values.len) |i| {
            if (self.owned_query_values[i]) |value| {
                self.allocator.free(value);
                self.owned_query_values[i] = null;
            }
        }

        if (self.owns_body and self.body_raw.len > 0) {
            self.allocator.free(@constCast(self.body_raw));
        }
    }

    pub fn setOwnedQueryValue(self: *Request, index: usize, value: []const u8) void {
        if (index >= self.query.len or index >= self.owned_query_values.len) {
            self.allocator.free(value);
            return;
        }

        if (self.owned_query_values[index]) |old| {
            self.allocator.free(old);
        }

        self.owned_query_values[index] = value;
        self.query.vals[index] = value;
    }

    pub fn replaceBodyOwned(self: *Request, body: []const u8) void {
        if (self.owns_body and self.body_raw.len > 0) {
            self.allocator.free(@constCast(self.body_raw));
        }

        self.body_raw = body;
        self.owns_body = true;
    }

    pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    pub fn assignRequestId(self: *Request, next_id: u64) void {
        if (self.header("x-request-id")) |existing| {
            self.request_id = existing;
            return;
        }

        self.request_id = std.fmt.bufPrint(&self.request_id_storage, "{x}", .{next_id}) catch "";
    }

    pub fn query_get(self: *const Request, key: []const u8) ?[]const u8 {
        return self.query.get(key);
    }

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        var it = http.HeaderIterator.init(self.head_buffer);
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn content_type(self: *const Request) ?[]const u8 {
        return self.header("content-type");
    }

    pub fn body_raw_bytes(self: *const Request) []const u8 {
        return self.body_raw;
    }

    pub fn body_json(self: *const Request, comptime T: type) ?T {
        if (self.body_raw.len == 0) return null;
        return std.json.parseFromSliceLeaky(T, self.allocator, self.body_raw, .{}) catch return null;
    }

    pub fn body_form(self: *const Request) util.FormParams {
        return util.parseForm(self.body_raw);
    }

    pub fn body_multipart(self: *Request) ?multipart.Multipart {
        const ct = self.content_type() orelse return null;
        if (!std.mem.startsWith(u8, ct, "multipart/form-data")) return null;

        const boundary = multipart.Multipart.extractBoundary(ct) orelse return null;
        return multipart.Multipart.parse(self.allocator, self.body_raw, boundary) catch return null;
    }

    pub fn saveMultipart(self: *Request, config: multipart.UploadConfig) !multipart.MultipartUpload {
        if (self.multipart_consumed) return error.BadRequest;

        const ct = self.content_type() orelse return error.UnsupportedMediaType;
        if (!std.mem.startsWith(u8, ct, "multipart/form-data")) return error.UnsupportedMediaType;

        const boundary = multipart.Multipart.extractBoundary(ct) orelse return error.BadRequest;
        self.multipart_consumed = true;

        if (self.body_raw.len > 0) {
            var reader = SliceReader{ .data = self.body_raw };
            return multipart.saveUpload(self.allocator, &reader, self.body_raw.len, boundary, config);
        }

        const server_request = self.server_request orelse return error.BadRequest;
        const content_length = server_request.head.content_length orelse return error.LengthRequired;
        if (content_length == 0) return error.BadRequest;

        var body_reader_buf: [4096]u8 = undefined;
        const body_reader = server_request.readerExpectNone(&body_reader_buf);
        var reader = HttpBodyReader{ .inner = body_reader };
        return multipart.saveUpload(self.allocator, &reader, @intCast(content_length), boundary, config);
    }

    /// Get a cookie value by name. Lazily parses Cookie header on first call.
    pub fn cookie(self: *Request, name: []const u8) ?[]const u8 {
        if (!self.cookies_parsed) {
            const raw = self.header("cookie") orelse "";
            self.cookies = util.parseCookies(raw);
            self.cookies_parsed = true;
        }
        return self.cookies.get(name);
    }

    /// Get and verify a signed cookie. Returns original value or null if tampered.
    /// Caller must free the returned slice.
    pub fn signedCookie(self: *Request, name: []const u8, secret: []const u8) ?[]const u8 {
        const raw = self.cookie(name) orelse return null;
        return util.verifySignedCookie(self.allocator, raw, secret);
    }

    /// Returns true if the connection is TLS-encrypted.
    pub fn isSecure(self: *const Request) bool {
        return self.tls;
    }

    pub fn scheme(self: *const Request) []const u8 {
        return if (self.tls) "https" else "http";
    }
};

const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn take(self: *SliceReader, max_bytes: usize) ![]const u8 {
        const remaining = self.data.len - self.pos;
        const n = @min(remaining, max_bytes);
        const chunk = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return chunk;
    }
};

const HttpBodyReader = struct {
    inner: *std.Io.Reader,

    pub fn take(self: *HttpBodyReader, max_bytes: usize) ![]const u8 {
        return self.inner.*.take(max_bytes);
    }
};
