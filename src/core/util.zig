const std = @import("std");

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    ALL,

    pub fn fromStdMethod(m: std.http.Method) ?HttpMethod {
        return switch (m) {
            .GET => .GET,
            .HEAD => .HEAD,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
            .OPTIONS => .OPTIONS,
            .PATCH => .PATCH,
            else => null,
        };
    }
};

pub const Params = struct {
    const MAX_PARAMS = 16;

    names: [MAX_PARAMS][]const u8 = undefined,
    values: [MAX_PARAMS][]const u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        for (0..self.len) |i| {
            if (std.mem.eql(u8, self.names[i], name)) return self.values[i];
        }
        return null;
    }

    pub fn put(self: *Params, name: []const u8, value: []const u8) void {
        if (self.len >= MAX_PARAMS) return;
        self.names[self.len] = name;
        self.values[self.len] = value;
        self.len += 1;
    }
};

pub const QueryParams = struct {
    pub const MAX_ENTRIES = 32;

    keys: [MAX_ENTRIES][]const u8 = undefined,
    vals: [MAX_ENTRIES][]const u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const QueryParams, key: []const u8) ?[]const u8 {
        for (0..self.len) |i| {
            if (std.mem.eql(u8, self.keys[i], key)) return self.vals[i];
        }
        return null;
    }
};

pub const FormParams = QueryParams;

pub fn parseQuery(qs: []const u8) QueryParams {
    return parseKeyValue(qs);
}

pub fn parseForm(body: []const u8) FormParams {
    return parseKeyValue(body);
}

fn parseKeyValue(data: []const u8) QueryParams {
    var result = QueryParams{};
    if (data.len == 0) return result;

    var it = std.mem.splitSequence(u8, data, "&");
    while (it.next()) |pair| {
        if (result.len >= QueryParams.MAX_ENTRIES) break;
        if (pair.len == 0) continue;

        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            result.keys[result.len] = pair[0..eq_pos];
            result.vals[result.len] = pair[eq_pos + 1 ..];
        } else {
            result.keys[result.len] = pair;
            result.vals[result.len] = "";
        }
        result.len += 1;
    }
    return result;
}

pub fn splitPathQuery(target: []const u8) struct { path: []const u8, query: []const u8 } {
    if (std.mem.indexOfScalar(u8, target, '?')) |qmark| {
        return .{ .path = target[0..qmark], .query = target[qmark + 1 ..] };
    }
    return .{ .path = target, .query = "" };
}

pub fn matchRoute(pattern: []const u8, path: []const u8) ?Params {
    var params = Params{};

    const has_wildcard = pattern.len > 0 and pattern[pattern.len - 1] == '*' and
        (pattern.len == 1 or pattern[pattern.len - 2] == '/');

    if (std.mem.eql(u8, pattern, path)) return params;

    if (has_wildcard) {
        const prefix = if (pattern.len > 1) pattern[0 .. pattern.len - 2] else "";
        if (prefix.len == 0) {
            return params;
        }
        if (path.len >= prefix.len and std.mem.eql(u8, prefix, path[0..prefix.len])) {
            return params;
        }
        return null;
    }

    var pat_it = std.mem.splitSequence(u8, pattern, "/");
    var path_it = std.mem.splitSequence(u8, path, "/");

    while (true) {
        const pat_seg = pat_it.next();
        const path_seg = path_it.next();

        if (pat_seg == null and path_seg == null) return params;
        if (pat_seg == null or path_seg == null) return null;

        const ps = pat_seg.?;
        const hs = path_seg.?;

        if (ps.len > 0 and ps[0] == ':') {
            params.put(ps[1..], hs);
        } else if (!std.mem.eql(u8, ps, hs)) {
            return null;
        }
    }

    return null;
}

pub fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const byte = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch {
                try result.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try result.append(allocator, byte);
            i += 3;
        } else if (input[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Cookies
// ---------------------------------------------------------------------------

pub const Cookies = struct {
    const MAX_COOKIES = 32;

    keys: [MAX_COOKIES][]const u8 = undefined,
    vals: [MAX_COOKIES][]const u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const Cookies, key: []const u8) ?[]const u8 {
        for (0..self.len) |i| {
            if (std.mem.eql(u8, self.keys[i], key)) return self.vals[i];
        }
        return null;
    }
};

pub const SameSite = enum {
    strict,
    lax,
    none,

    pub fn toStr(self: SameSite) []const u8 {
        return switch (self) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        };
    }
};

pub const CookieOptions = struct {
    max_age: ?i64 = null,
    expires: ?[]const u8 = null,
    http_only: bool = false,
    secure: bool = false,
    same_site: ?SameSite = null,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    partitioned: bool = false,
};

/// Parse a Cookie header value into a Cookies struct.
/// Zero-allocation — all slices reference the input.
pub fn parseCookies(header: []const u8) Cookies {
    var result = Cookies{};
    if (header.len == 0) return result;

    var it = std.mem.splitSequence(u8, header, ";");
    while (it.next()) |pair| {
        if (result.len >= Cookies.MAX_COOKIES) break;
        const trimmed = std.mem.trim(u8, pair, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            if (key.len == 0) continue;
            result.keys[result.len] = key;
            result.vals[result.len] = val;
        } else {
            result.keys[result.len] = trimmed;
            result.vals[result.len] = "";
        }
        result.len += 1;
    }
    return result;
}

/// Format a Set-Cookie header value into a fixed buffer.
/// Returns the formatted slice. Returns null if buffer too small.
pub fn formatSetCookie(buf: []u8, name: []const u8, value: []const u8, opts: CookieOptions) ?[]const u8 {
    var pos: usize = 0;

    const write = struct {
        fn append(p: *usize, b: []u8, data: []const u8) bool {
            if (p.* + data.len > b.len) return false;
            @memcpy(b[p.* .. p.* + data.len], data);
            p.* += data.len;
            return true;
        }
    }.append;

    if (!write(&pos, buf, name)) return null;
    if (!write(&pos, buf, "=")) return null;
    if (!write(&pos, buf, value)) return null;

    if (opts.max_age) |ma| {
        if (!write(&pos, buf, "; Max-Age=")) return null;
        var int_buf: [20]u8 = undefined;
        const int_len = std.fmt.printInt(&int_buf, ma, 10, .lower, .{});
        if (!write(&pos, buf, int_buf[0..int_len])) return null;
    } else if (opts.expires) |exp| {
        if (!write(&pos, buf, "; Expires=")) return null;
        if (!write(&pos, buf, exp)) return null;
    }

    if (opts.domain) |d| {
        if (!write(&pos, buf, "; Domain=")) return null;
        if (!write(&pos, buf, d)) return null;
    }

    if (opts.path) |p| {
        if (!write(&pos, buf, "; Path=")) return null;
        if (!write(&pos, buf, p)) return null;
    }

    if (opts.secure) {
        if (!write(&pos, buf, "; Secure")) return null;
    }

    if (opts.http_only) {
        if (!write(&pos, buf, "; HttpOnly")) return null;
    }

    if (opts.same_site) |ss| {
        switch (ss) {
            .strict => if (!write(&pos, buf, "; SameSite=Strict")) return null,
            .lax => if (!write(&pos, buf, "; SameSite=Lax")) return null,
            .none => if (!write(&pos, buf, "; SameSite=None")) return null,
        }
    }

    if (opts.partitioned) {
        if (!write(&pos, buf, "; Partitioned")) return null;
    }

    return buf[0..pos];
}

// ---------------------------------------------------------------------------
// Signed Cookies (HMAC-SHA256)
// ---------------------------------------------------------------------------

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const hmac_mac_len = HmacSha256.mac_length;

fn byteToHex(byte: u8) [2]u8 {
    const hex_chars = "0123456789abcdef";
    return .{ hex_chars[byte >> 4], hex_chars[byte & 0x0f] };
}

/// Sign a cookie value. Returns "value.hex_signature" (caller must free).
pub fn signCookie(allocator: std.mem.Allocator, value: []const u8, secret: []const u8) ![]const u8 {
    var mac: [hmac_mac_len]u8 = undefined;
    HmacSha256.create(&mac, value, secret);

    const total_len = value.len + 1 + hmac_mac_len * 2;
    var buf = try allocator.alloc(u8, total_len);
    @memcpy(buf[0..value.len], value);
    buf[value.len] = '.';

    var offset = value.len + 1;
    for (&mac) |byte| {
        const hex = byteToHex(byte);
        buf[offset] = hex[0];
        buf[offset + 1] = hex[1];
        offset += 2;
    }
    return buf;
}

/// Verify a signed cookie value. Returns the original value (caller must free) or null.
pub fn verifySignedCookie(allocator: std.mem.Allocator, signed_value: []const u8, secret: []const u8) ?[]const u8 {
    const dot_pos = std.mem.lastIndexOfScalar(u8, signed_value, '.') orelse return null;
    const value = signed_value[0..dot_pos];
    const sig_hex = signed_value[dot_pos + 1 ..];
    if (sig_hex.len != hmac_mac_len * 2) return null;

    var mac: [hmac_mac_len]u8 = undefined;
    HmacSha256.create(&mac, value, secret);

    var expected_hex: [hmac_mac_len * 2]u8 = undefined;
    var offset: usize = 0;
    for (&mac) |byte| {
        const hex = byteToHex(byte);
        expected_hex[offset] = hex[0];
        expected_hex[offset + 1] = hex[1];
        offset += 2;
    }

    // Timing-safe comparison
    var equal: u8 = 0;
    for (&expected_hex, sig_hex[0 .. hmac_mac_len * 2]) |a, b| {
        equal |= a ^ b;
    }
    if (equal != 0) return null;

    return allocator.dupe(u8, value) catch null;
}
