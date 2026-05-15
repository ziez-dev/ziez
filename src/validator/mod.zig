const std = @import("std");

// ---------------------------------------------------------------------------
// Basic
// ---------------------------------------------------------------------------

pub fn isAscii(s: []const u8) bool {
    for (s) |c| {
        if (c > 127) return false;
    }
    return true;
}

pub fn isAlpha(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphabetic(c)) return false;
    }
    return true;
}

pub fn isAlphanumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

pub fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

pub fn isLowercase(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isLower(c)) return false;
    }
    return true;
}

pub fn isUppercase(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

pub fn isEmpty(s: []const u8) bool {
    return s.len == 0;
}

// ---------------------------------------------------------------------------
// Number
// ---------------------------------------------------------------------------

pub const IntOptions = struct {
    min: ?i64 = null,
    max: ?i64 = null,
};

pub fn isInt(s: []const u8, opts: IntOptions) bool {
    if (s.len == 0) return false;
    var start: usize = 0;
    if (s[0] == '-' or s[0] == '+') {
        if (s.len == 1) return false;
        start = 1;
    }
    for (s[start..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    if (opts.min != null or opts.max != null) {
        const val = std.fmt.parseInt(i64, s, 10) catch return false;
        if (opts.min) |m| if (val < m) return false;
        if (opts.max) |m| if (val > m) return false;
    }
    return true;
}

pub const FloatOptions = struct {
    min: ?f64 = null,
    max: ?f64 = null,
};

pub fn isFloat(s: []const u8, opts: FloatOptions) bool {
    if (s.len == 0) return false;
    var start: usize = 0;
    if (s[0] == '-' or s[0] == '+') start = 1;
    if (start >= s.len) return false;

    var has_dot = false;
    var has_digit = false;
    for (s[start..]) |c| {
        if (c == '.') {
            if (has_dot) return false;
            has_dot = true;
        } else if (c >= '0' and c <= '9') {
            has_digit = true;
        } else {
            return false;
        }
    }
    if (!has_digit) return false;

    if (opts.min != null or opts.max != null) {
        const val = std.fmt.parseFloat(f64, s) catch return false;
        if (opts.min) |m| if (val < m) return false;
        if (opts.max) |m| if (val > m) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

pub fn isEmail(s: []const u8) bool {
    if (s.len < 3 or s.len > 254) return false;
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0) return false;
    const local = s[0..at];
    const domain = s[at + 1 ..];
    if (domain.len == 0) return false;

    // local part
    for (local, 0..) |c, i| {
        if (c == '.' and i == 0) return false;
        if (c == '.' and i == local.len - 1) return false;
        if (c == '.') continue;
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '+') return false;
    }

    // domain part
    if (domain[0] == '.' or domain[domain.len - 1] == '.') return false;
    var has_dot = false;
    for (domain, 0..) |c, i| {
        if (c == '.') {
            if (i > 0 and domain[i - 1] == '.') return false;
            has_dot = true;
            continue;
        }
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return has_dot;
}

pub const URLOptions = struct {
    protocols: ?[]const []const u8 = null,
};

pub fn isURL(s: []const u8, opts: URLOptions) bool {
    const proto_end = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    const proto = s[0..proto_end];
    if (proto.len == 0) return false;
    for (proto) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }

    if (opts.protocols) |allowed| {
        var found = false;
        for (allowed) |p| {
            if (std.mem.eql(u8, proto, p)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    if (!std.mem.startsWith(u8, s[proto_end..], "://")) return false;
    const rest = s[proto_end + 3 ..];
    if (rest.len == 0) return false;

    // host part
    var slash_pos: usize = rest.len;
    if (std.mem.indexOfScalar(u8, rest, '/')) |sp| slash_pos = sp;
    const host = rest[0..slash_pos];
    if (host.len == 0) return false;

    // strip port
    const host_end = std.mem.indexOfScalar(u8, host, ':') orelse host.len;
    const hostname = host[0..host_end];
    if (hostname.len == 0) return false;
    for (hostname) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return false;
    }
    return true;
}

pub fn isIP(s: []const u8) bool {
    return isIPv4(s) or isIPv6(s);
}

pub fn isIPv4(s: []const u8) bool {
    var count: usize = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (i == start) return false;
            const octet = std.fmt.parseInt(u8, s[start..i], 10) catch return false;
            _ = octet;
            count += 1;
            start = i + 1;
        } else if (c < '0' or c > '9') {
            return false;
        }
    }
    if (start >= s.len) return false;
    const octet = std.fmt.parseInt(u8, s[start..], 10) catch return false;
    _ = octet;
    count += 1;
    return count == 4;
}

pub fn isIPv6(s: []const u8) bool {
    if (s.len < 2) return false;
    var groups: usize = 0;
    var has_double_colon = false;
    var i: usize = 0;

    while (i < s.len) {
        if (s[i] == ':') {
            if (i + 1 < s.len and s[i + 1] == ':') {
                if (has_double_colon) return false;
                has_double_colon = true;
                i += 2;
                groups += 1;
                continue;
            }
            i += 1;
            continue;
        }
        // read hex group
        var hex_len: usize = 0;
        while (i < s.len and hex_len < 4) : ({
            i += 1;
            hex_len += 1;
        }) {
            if (s[i] == ':') break;
            if (!std.ascii.isHex(s[i])) return false;
        }
        if (hex_len == 0) return false;
        groups += 1;
    }

    if (has_double_colon) {
        return groups <= 8;
    }
    return groups == 8;
}

pub fn isUUID(s: []const u8) bool {
    if (s.len != 36) return false;
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Date
// ---------------------------------------------------------------------------

pub fn isDate(s: []const u8) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return false;
    _ = year;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return false;
    if (month < 1 or month > 12) return false;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return false;
    if (day < 1 or day > 31) return false;
    return true;
}

pub fn isISO8601(s: []const u8) bool {
    // YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS(Z or +/-HH:MM)
    if (s.len < 10) return false;
    if (!isDate(s[0..10])) return false;
    if (s.len == 10) return true;
    if (s[10] != 'T' and s[10] != ' ') return false;
    if (s.len == 11) return false;
    // time part: HH:MM:SS
    if (s.len < 19) return false;
    if (s[13] != ':' or s[16] != ':') return false;
    const hh = std.fmt.parseInt(u8, s[11..13], 10) catch return false;
    if (hh > 23) return false;
    const mm = std.fmt.parseInt(u8, s[14..16], 10) catch return false;
    if (mm > 59) return false;
    const ss = std.fmt.parseInt(u8, s[17..19], 10) catch return false;
    if (ss > 59) return false;
    if (s.len == 19) return true;
    // timezone
    const tz = s[19..];
    if (tz.len == 1 and tz[0] == 'Z') return true;
    if (tz.len == 1 and tz[0] == 'z') return true;
    if (tz.len != 6) return false;
    if (tz[0] != '+' and tz[0] != '-') return false;
    if (tz[3] != ':') return false;
    const tz_h = std.fmt.parseInt(u8, tz[1..3], 10) catch return false;
    if (tz_h > 23) return false;
    const tz_m = std.fmt.parseInt(u8, tz[4..6], 10) catch return false;
    if (tz_m > 59) return false;
    return true;
}

pub fn isTime(s: []const u8) bool {
    // HH:MM or HH:MM:SS
    if (s.len != 5 and s.len != 8) return false;
    if (s[2] != ':') return false;
    const hh = std.fmt.parseInt(u8, s[0..2], 10) catch return false;
    if (hh > 23) return false;
    const mm = std.fmt.parseInt(u8, s[3..5], 10) catch return false;
    if (mm > 59) return false;
    if (s.len == 5) return true;
    if (s[5] != ':') return false;
    const ss = std.fmt.parseInt(u8, s[6..8], 10) catch return false;
    if (ss > 59) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

pub fn isBase64(s: []const u8) bool {
    if (s.len == 0) return false;
    const b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var padding: usize = 0;
    var data_len: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '=') {
            if (i < s.len - 2) return false;
            padding += 1;
            continue;
        }
        if (padding > 0) return false;
        var found = false;
        for (b64) |b| {
            if (c == b) {
                found = true;
                break;
            }
        }
        if (!found) return false;
        data_len += 1;
    }
    if (data_len == 0) return false;
    // valid padding: 0, 1, or 2 '='
    if (padding > 2) return false;
    return true;
}

pub fn isHexadecimal(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn isJSON(s: []const u8) bool {
    if (s.len == 0) return false;
    switch (s[0]) {
        '{', '[', '"', 't', 'f', 'n' => {},
        '-', '0'...'9' => {},
        else => return false,
    }
    // Quick structural check for objects/arrays
    if (s[0] == '{') {
        if (s.len < 2 or s[s.len - 1] != '}') return false;
        return true;
    }
    if (s[0] == '[') {
        if (s.len < 2 or s[s.len - 1] != ']') return false;
        return true;
    }
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) return true;
    // quoted string
    if (s[0] == '"' and s.len >= 2 and s[s.len - 1] == '"') return true;
    // number
    _ = std.fmt.parseFloat(f64, s) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

pub fn isCreditCard(s: []const u8) bool {
    // strip spaces and dashes
    var digits: [20]u8 = undefined;
    var dlen: usize = 0;
    for (s) |c| {
        if (c == ' ' or c == '-') continue;
        if (c < '0' or c > '9') return false;
        if (dlen >= 20) return false;
        digits[dlen] = c;
        dlen += 1;
    }
    if (dlen < 13 or dlen > 19) return false;

    // Luhn algorithm
    var sum: u32 = 0;
    const parity = dlen % 2;
    for (digits[0..dlen], 0..) |c, i| {
        var d: u32 = c - '0';
        if (i % 2 == parity) {
            d *= 2;
            if (d > 9) d -= 9;
        }
        sum += d;
    }
    return sum % 10 == 0;
}

pub fn isSlug(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '-' or s[s.len - 1] == '-') return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Password
// ---------------------------------------------------------------------------

pub const StrongPasswordOptions = struct {
    min_length: usize = 8,
    min_lowercase: usize = 1,
    min_uppercase: usize = 1,
    min_numbers: usize = 1,
    min_symbols: usize = 1,
};

pub fn isStrongPassword(s: []const u8, opts: StrongPasswordOptions) bool {
    if (s.len < opts.min_length) return false;
    var lower: usize = 0;
    var upper: usize = 0;
    var nums: usize = 0;
    var syms: usize = 0;
    for (s) |c| {
        if (std.ascii.isLower(c)) lower += 1
        else if (std.ascii.isUpper(c)) upper += 1
        else if (c >= '0' and c <= '9') nums += 1
        else syms += 1;
    }
    if (lower < opts.min_lowercase) return false;
    if (upper < opts.min_uppercase) return false;
    if (nums < opts.min_numbers) return false;
    if (syms < opts.min_symbols) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Locale
// ---------------------------------------------------------------------------

pub fn isPostalCode(s: []const u8, country_code: []const u8) bool {
    if (std.mem.eql(u8, country_code, "US")) {
        // 5 digits or 5-4
        if (s.len == 5 and isNumeric(s)) return true;
        if (s.len == 10 and s[5] == '-' and isNumeric(s[0..5]) and isNumeric(s[6..10])) return true;
        return false;
    }
    if (std.mem.eql(u8, country_code, "UK")) {
        // UK postcode: basic check, 5-8 chars with space
        if (s.len < 5 or s.len > 8) return false;
        var has_space = false;
        for (s) |c| {
            if (c == ' ') {
                has_space = true;
            } else if (!std.ascii.isAlphanumeric(c)) {
                return false;
            }
        }
        return has_space;
    }
    if (std.mem.eql(u8, country_code, "CA")) {
        // A1A 1A1
        if (s.len != 7) return false;
        if (!std.ascii.isUpper(s[0])) return false;
        if (!isNumeric(s[1..2])) return false;
        if (!std.ascii.isUpper(s[2])) return false;
        if (s[3] != ' ') return false;
        if (!isNumeric(s[4..5])) return false;
        if (!std.ascii.isUpper(s[5])) return false;
        if (!isNumeric(s[6..7])) return false;
        return true;
    }
    // Generic: alphanumeric + spaces/dashes, 3-10 chars
    if (s.len < 3 or s.len > 10) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != ' ' and c != '-') return false;
    }
    return true;
}

pub fn isMobilePhone(s: []const u8, country_code: []const u8) bool {
    if (s.len == 0) return false;
    var digits: [20]u8 = undefined;
    var dlen: usize = 0;
    for (s) |c| {
        if (c == ' ' or c == '-' or c == '(' or c == ')' or c == '+') continue;
        if (c < '0' or c > '9') return false;
        if (dlen >= 20) return false;
        digits[dlen] = c;
        dlen += 1;
    }
    if (dlen == 0) return false;

    if (std.mem.eql(u8, country_code, "US") or std.mem.eql(u8, country_code, "CA")) {
        if (dlen != 10 and dlen != 11) return false;
        if (dlen == 11 and digits[0] != '1') return false;
        return true;
    }
    if (std.mem.eql(u8, country_code, "ID")) {
        // Indonesia: 10-13 digits
        return dlen >= 10 and dlen <= 13;
    }
    if (std.mem.eql(u8, country_code, "GB")) {
        return dlen >= 10 and dlen <= 11;
    }
    // Generic: 7-15 digits
    return dlen >= 7 and dlen <= 15;
}

