const std = @import("std");
const util = @import("util.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const OriginPredicate = *const fn ([]const u8) bool;

pub const CorsOrigins = union(enum) {
    any: void,
    list: []const []const u8,
    predicate: OriginPredicate,
};

pub const CorsConfig = struct {
    origins: CorsOrigins = .{ .any = {} },
    methods: []const util.HttpMethod = &.{ .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS },
    allowed_headers: []const []const u8 = &.{ "Content-Type", "Authorization", "X-Request-ID" },
    exposed_headers: []const []const u8 = &.{},
    credentials: bool = false,
    max_age: ?u32 = null,
};

pub fn isOriginAllowed(origin: []const u8, config: CorsConfig) bool {
    return switch (config.origins) {
        .any => true,
        .list => |origins| {
            for (origins) |allowed| {
                if (std.mem.eql(u8, origin, allowed)) return true;
            }
            return false;
        },
        .predicate => |predicate| predicate(origin),
    };
}

pub fn handle(req: *Request, res: *Response, config: CorsConfig) bool {
    const origin = req.header("origin") orelse return true;

    if (isPreflight(req)) {
        return handlePreflight(req, res, origin, config);
    }

    if (isOriginAllowed(origin, config)) {
        setOriginHeaders(res, origin, config);
        if (config.exposed_headers.len > 0) {
            _ = res.setJoined("Access-Control-Expose-Headers", config.exposed_headers);
        }
    }

    return true;
}

fn isPreflight(req: *const Request) bool {
    return req.method == .OPTIONS and req.header("access-control-request-method") != null;
}

fn handlePreflight(req: *Request, res: *Response, origin: []const u8, config: CorsConfig) bool {
    if (!isOriginAllowed(origin, config)) {
        res.status(403).sendBody("");
        return false;
    }

    const requested_method = req.header("access-control-request-method").?;
    if (!isMethodAllowed(requested_method, config.methods)) {
        res.status(403).sendBody("");
        return false;
    }

    if (req.header("access-control-request-headers")) |requested_headers| {
        if (!areHeadersAllowed(requested_headers, config.allowed_headers)) {
            res.status(403).sendBody("");
            return false;
        }
    }

    setOriginHeaders(res, origin, config);
    setAllowMethods(res, config.methods);
    if (config.allowed_headers.len > 0) {
        _ = res.setJoined("Access-Control-Allow-Headers", config.allowed_headers);
    }
    if (config.max_age) |max_age| {
        _ = res.setFormatted("Access-Control-Max-Age", "{d}", .{max_age});
    }

    res.status(204).sendBody("");
    return false;
}

fn setOriginHeaders(res: *Response, origin: []const u8, config: CorsConfig) void {
    switch (config.origins) {
        .any => {
            if (config.credentials) {
                _ = res.set("Access-Control-Allow-Origin", origin);
                _ = res.set("Vary", "Origin");
            } else {
                _ = res.set("Access-Control-Allow-Origin", "*");
            }
        },
        .list, .predicate => {
            _ = res.set("Access-Control-Allow-Origin", origin);
            _ = res.set("Vary", "Origin");
        },
    }

    if (config.credentials) {
        _ = res.set("Access-Control-Allow-Credentials", "true");
    }
}

fn setAllowMethods(res: *Response, methods: []const util.HttpMethod) void {
    var method_names: [16][]const u8 = undefined;
    const count = @min(methods.len, method_names.len);
    for (methods[0..count], 0..) |method, i| {
        method_names[i] = methodName(method);
    }
    _ = res.setJoined("Access-Control-Allow-Methods", method_names[0..count]);
}

fn isMethodAllowed(requested_method: []const u8, methods: []const util.HttpMethod) bool {
    const method = std.mem.trim(u8, requested_method, " \t");
    for (methods) |allowed| {
        if (allowed == .ALL) return true;
        if (std.ascii.eqlIgnoreCase(method, methodName(allowed))) return true;
    }
    return false;
}

fn areHeadersAllowed(requested_headers: []const u8, allowed_headers: []const []const u8) bool {
    var it = std.mem.splitSequence(u8, requested_headers, ",");
    while (it.next()) |raw_header| {
        const header = std.mem.trim(u8, raw_header, " \t");
        if (header.len == 0) continue;
        if (!isHeaderAllowed(header, allowed_headers)) return false;
    }
    return true;
}

fn isHeaderAllowed(header: []const u8, allowed_headers: []const []const u8) bool {
    for (allowed_headers) |allowed| {
        if (std.mem.eql(u8, allowed, "*")) return true;
        if (std.ascii.eqlIgnoreCase(header, allowed)) return true;
    }
    return false;
}

fn methodName(method: util.HttpMethod) []const u8 {
    return switch (method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .HEAD => "HEAD",
        .OPTIONS => "OPTIONS",
        .ALL => "*",
    };
}
