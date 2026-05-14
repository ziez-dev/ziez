const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const XssMode = enum {
    strip,
    escape,
};

pub const XssConfig = struct {
    sanitize_body: bool = true,
    sanitize_query: bool = true,
    mode: XssMode = .strip,
};

pub const HstsConfig = struct {
    max_age: u32 = 31_536_000,
    include_sub_domains: bool = true,
    preload: bool = false,
};

pub const CspDirective = struct {
    name: []const u8,
    values: ?[]const []const u8 = &.{},
};

pub const CspConfig = struct {
    use_defaults: bool = true,
    directives: []const CspDirective = &.{},
    report_only: bool = false,
};

pub const HelmetConfig = struct {
    content_security_policy: ?CspConfig = .{},
    cross_origin_opener_policy: ?[]const u8 = "same-origin",
    cross_origin_resource_policy: ?[]const u8 = "same-origin",
    origin_agent_cluster: ?[]const u8 = "?1",
    referrer_policy: ?[]const u8 = "no-referrer",
    strict_transport_security: ?HstsConfig = .{},
    x_content_type_options: ?[]const u8 = "nosniff",
    x_dns_prefetch_control: ?[]const u8 = "off",
    x_download_options: ?[]const u8 = "noopen",
    x_frame_options: ?[]const u8 = "SAMEORIGIN",
    x_permitted_cross_domain_policies: ?[]const u8 = "none",
    x_xss_protection: ?[]const u8 = "0",
    x_powered_by: bool = true,
};

pub const SecurityConfig = struct {
    helmet: ?HelmetConfig = .{},
    xss: ?XssConfig = .{},
};

const default_csp_directives = [_]CspDirective{
    .{ .name = "default-src", .values = &.{"'self'"} },
    .{ .name = "base-uri", .values = &.{"'self'"} },
    .{ .name = "font-src", .values = &.{ "'self'", "https:", "data:" } },
    .{ .name = "form-action", .values = &.{"'self'"} },
    .{ .name = "frame-ancestors", .values = &.{"'self'"} },
    .{ .name = "img-src", .values = &.{ "'self'", "data:" } },
    .{ .name = "object-src", .values = &.{"'none'"} },
    .{ .name = "script-src", .values = &.{"'self'"} },
    .{ .name = "script-src-attr", .values = &.{"'none'"} },
    .{ .name = "style-src", .values = &.{ "'self'", "https:", "'unsafe-inline'" } },
    .{ .name = "upgrade-insecure-requests", .values = &.{} },
};

pub fn apply(req: *Request, res: *Response, config: SecurityConfig) void {
    if (config.helmet) |helmet_config| {
        applyHelmet(res, helmet_config);
    }

    if (config.xss) |xss_config| {
        sanitizeRequest(req, xss_config);
    }
}

pub fn applyHelmet(res: *Response, config: HelmetConfig) void {
    if (config.x_powered_by) {
        res.removeHeader("X-Powered-By");
    }

    if (config.content_security_policy) |csp| setContentSecurityPolicy(res, csp);
    if (config.cross_origin_opener_policy) |value| _ = res.setOrReplaceHeader("Cross-Origin-Opener-Policy", value);
    if (config.cross_origin_resource_policy) |value| _ = res.setOrReplaceHeader("Cross-Origin-Resource-Policy", value);
    if (config.origin_agent_cluster) |value| _ = res.setOrReplaceHeader("Origin-Agent-Cluster", value);
    if (config.referrer_policy) |value| _ = res.setOrReplaceHeader("Referrer-Policy", value);
    if (config.strict_transport_security) |hsts| setHsts(res, hsts);
    if (config.x_content_type_options) |value| _ = res.setOrReplaceHeader("X-Content-Type-Options", value);
    if (config.x_dns_prefetch_control) |value| _ = res.setOrReplaceHeader("X-DNS-Prefetch-Control", value);
    if (config.x_download_options) |value| _ = res.setOrReplaceHeader("X-Download-Options", value);
    if (config.x_frame_options) |value| _ = res.setOrReplaceHeader("X-Frame-Options", value);
    if (config.x_permitted_cross_domain_policies) |value| _ = res.setOrReplaceHeader("X-Permitted-Cross-Domain-Policies", value);
    if (config.x_xss_protection) |value| _ = res.setOrReplaceHeader("X-XSS-Protection", value);
}

pub fn sanitizeRequest(req: *Request, config: XssConfig) void {
    if (config.sanitize_query) {
        sanitizeQuery(req, config.mode);
    }

    if (config.sanitize_body) {
        sanitizeBody(req, config.mode);
    }
}

fn setContentSecurityPolicy(res: *Response, config: CspConfig) void {
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    var first = true;

    if (config.use_defaults) {
        for (default_csp_directives) |directive| {
            const override = findDirectiveOverride(directive.name, config.directives);
            const values = if (override) |custom| custom.values else directive.values;
            if (values) |actual_values| {
                appendCspDirective(&buf, &len, &first, directive.name, actual_values) catch return;
            }
        }
    }

    for (config.directives) |directive| {
        if (config.use_defaults and isDefaultCspDirective(directive.name)) continue;
        if (directive.values) |values| {
            appendCspDirective(&buf, &len, &first, directive.name, values) catch return;
        }
    }

    if (len == 0) return;
    const header = if (config.report_only) "Content-Security-Policy-Report-Only" else "Content-Security-Policy";
    _ = res.setOrReplaceHeader(header, buf[0..len]);
}

fn setHsts(res: *Response, config: HstsConfig) void {
    var buf: [128]u8 = undefined;
    var len: usize = 0;

    const max_age = std.fmt.bufPrint(buf[len..], "max-age={d}", .{config.max_age}) catch return;
    len += max_age.len;

    if (config.include_sub_domains) {
        const value = "; includeSubDomains";
        if (len + value.len > buf.len) return;
        @memcpy(buf[len .. len + value.len], value);
        len += value.len;
    }

    if (config.preload) {
        const value = "; preload";
        if (len + value.len > buf.len) return;
        @memcpy(buf[len .. len + value.len], value);
        len += value.len;
    }

    _ = res.setOrReplaceHeader("Strict-Transport-Security", buf[0..len]);
}

fn appendCspDirective(
    buf: []u8,
    len: *usize,
    first: *bool,
    name: []const u8,
    values: []const []const u8,
) !void {
    if (!first.*) {
        try appendBytes(buf, len, ";");
    }
    first.* = false;

    try appendBytes(buf, len, name);
    for (values) |value| {
        try appendBytes(buf, len, " ");
        try appendBytes(buf, len, value);
    }
}

fn appendBytes(buf: []u8, len: *usize, value: []const u8) !void {
    if (len.* + value.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[len.* .. len.* + value.len], value);
    len.* += value.len;
}

fn findDirectiveOverride(name: []const u8, directives: []const CspDirective) ?CspDirective {
    for (directives) |directive| {
        if (std.ascii.eqlIgnoreCase(name, directive.name)) return directive;
    }
    return null;
}

fn isDefaultCspDirective(name: []const u8) bool {
    for (default_csp_directives) |directive| {
        if (std.ascii.eqlIgnoreCase(name, directive.name)) return true;
    }
    return false;
}

fn sanitizeQuery(req: *Request, mode: XssMode) void {
    for (0..req.query.len) |i| {
        const sanitized = sanitizeText(req.allocator, req.query.vals[i], mode) catch continue;
        req.setOwnedQueryValue(i, sanitized);
    }
}

fn sanitizeBody(req: *Request, mode: XssMode) void {
    if (req.body_raw.len == 0) return;

    const content_type = req.content_type() orelse return;
    if (!isTextualContentType(content_type)) return;

    const sanitized = if (containsIgnoreCase(content_type, "json"))
        sanitizeJsonStringLiterals(req.allocator, req.body_raw, mode)
    else if (startsWithIgnoreCase(content_type, "application/x-www-form-urlencoded"))
        sanitizeFormEncoded(req.allocator, req.body_raw, mode)
    else
        sanitizeText(req.allocator, req.body_raw, mode);

    const body = sanitized catch return;
    req.replaceBodyOwned(body);
}

fn isTextualContentType(content_type: []const u8) bool {
    if (startsWithIgnoreCase(content_type, "multipart/form-data")) return false;
    if (startsWithIgnoreCase(content_type, "text/")) return true;
    if (startsWithIgnoreCase(content_type, "application/x-www-form-urlencoded")) return true;
    if (containsIgnoreCase(content_type, "json")) return true;
    if (containsIgnoreCase(content_type, "xml")) return true;
    if (startsWithIgnoreCase(content_type, "application/javascript")) return true;
    return false;
}

pub fn sanitizeText(allocator: std.mem.Allocator, input: []const u8, mode: XssMode) ![]u8 {
    return switch (mode) {
        .escape => escapeHtml(allocator, input),
        .strip => stripXss(allocator, input),
    };
}

fn escapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#x27;"),
            else => try out.append(allocator, c),
        }
    }

    return out.toOwnedSlice(allocator);
}

fn stripXss(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const without_scripts = try stripScriptBlocks(allocator, input);
    defer allocator.free(without_scripts);

    const without_events = try stripEventHandlers(allocator, without_scripts);
    defer allocator.free(without_events);

    const without_js_scheme = try stripJavascriptScheme(allocator, without_events);
    defer allocator.free(without_js_scheme);

    return stripTags(allocator, without_js_scheme);
}

fn stripScriptBlocks(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (findIgnoreCaseFrom(input, "<script", pos)) |start| {
        try out.appendSlice(allocator, input[pos..start]);
        const close_start = findIgnoreCaseFrom(input, "</script>", start) orelse {
            pos = input.len;
            break;
        };
        pos = close_start + "</script>".len;
    }

    if (pos < input.len) {
        try out.appendSlice(allocator, input[pos..]);
    }

    return out.toOwnedSlice(allocator);
}

fn stripEventHandlers(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (isEventHandlerStart(input, i)) {
            i = skipEventHandler(input, i);
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn stripJavascriptScheme(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (findIgnoreCaseFrom(input, "javascript:", pos)) |start| {
        try out.appendSlice(allocator, input[pos..start]);
        pos = start + "javascript:".len;
    }
    if (pos < input.len) try out.appendSlice(allocator, input[pos..]);

    return out.toOwnedSlice(allocator);
}

fn stripTags(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, input, i, '>')) |end| {
                i = end + 1;
                continue;
            }
        }
        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn sanitizeJsonStringLiterals(allocator: std.mem.Allocator, input: []const u8, mode: XssMode) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '"') {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }

        try out.append(allocator, '"');
        i += 1;

        const segment_start = i;
        var escaped = false;
        while (i < input.len) : (i += 1) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (input[i] == '\\') {
                escaped = true;
                continue;
            }
            if (input[i] == '"') break;
        }

        const sanitized = try sanitizeText(allocator, input[segment_start..i], mode);
        defer allocator.free(sanitized);
        try out.appendSlice(allocator, sanitized);

        if (i < input.len and input[i] == '"') {
            try out.append(allocator, '"');
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn sanitizeFormEncoded(allocator: std.mem.Allocator, input: []const u8, mode: XssMode) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var it = std.mem.splitSequence(u8, input, "&");
    var first = true;
    while (it.next()) |pair| {
        if (!first) try out.append(allocator, '&');
        first = false;

        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            try out.appendSlice(allocator, pair[0 .. eq_pos + 1]);
            const sanitized = try sanitizeText(allocator, pair[eq_pos + 1 ..], mode);
            defer allocator.free(sanitized);
            try out.appendSlice(allocator, sanitized);
        } else {
            const sanitized = try sanitizeText(allocator, pair, mode);
            defer allocator.free(sanitized);
            try out.appendSlice(allocator, sanitized);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn isEventHandlerStart(input: []const u8, start: usize) bool {
    if (start + 2 >= input.len) return false;
    if (!(input[start] == 'o' or input[start] == 'O')) return false;
    if (!(input[start + 1] == 'n' or input[start + 1] == 'N')) return false;
    if (start > 0 and !std.ascii.isWhitespace(input[start - 1]) and input[start - 1] != '<') return false;

    var i = start + 2;
    if (i >= input.len or !isNameChar(input[i])) return false;
    while (i < input.len and isNameChar(input[i])) : (i += 1) {}
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
    return i < input.len and input[i] == '=';
}

fn skipEventHandler(input: []const u8, start: usize) usize {
    var i = start + 2;
    while (i < input.len and isNameChar(input[i])) : (i += 1) {}
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
    if (i >= input.len or input[i] != '=') return start + 1;
    i += 1;
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}

    if (i < input.len and (input[i] == '"' or input[i] == '\'')) {
        const quote = input[i];
        i += 1;
        while (i < input.len and input[i] != quote) : (i += 1) {}
        if (i < input.len) i += 1;
        return i;
    }

    while (i < input.len and !std.ascii.isWhitespace(input[i]) and input[i] != '>') : (i += 1) {}
    return i;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':';
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return findIgnoreCaseFrom(haystack, needle, 0) != null;
}

fn findIgnoreCaseFrom(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (needle.len > haystack.len or start > haystack.len - needle.len) return null;

    var i = start;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}
