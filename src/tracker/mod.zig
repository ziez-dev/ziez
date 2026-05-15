const std = @import("std");
const logging = @import("../core/logging.zig");

pub const ua_parser = @import("ua_parser.zig");

pub const TrackerConfig = struct {
    auto_request_log: bool = false,
    lifecycle_trace: bool = false,
    ua_parser_enabled: bool = true,
};

pub const RequestSummary = struct {
    req_id: []const u8,
    method: []const u8,
    path: []const u8,
    status: u16,
    response_time_ms: f64,
    user_agent: ?[]const u8 = null,
    content_length: ?u64 = null,
    browser_name: ?[]const u8 = null,
    browser_version: ?[]const u8 = null,
    os_name: ?[]const u8 = null,
    os_version: ?[]const u8 = null,
    device_type: ?[]const u8 = null,
};

pub fn buildSummary(
    req_id: []const u8,
    method: []const u8,
    path: []const u8,
    status: u16,
    response_time_ms: f64,
    user_agent_header: ?[]const u8,
    content_length: ?u64,
    cfg: TrackerConfig,
) RequestSummary {
    var summary = RequestSummary{
        .req_id = req_id,
        .method = method,
        .path = path,
        .status = status,
        .response_time_ms = response_time_ms,
        .user_agent = user_agent_header,
        .content_length = content_length,
    };

    if (cfg.ua_parser_enabled) {
        if (user_agent_header) |ua_str| {
            const result = ua_parser.parse(ua_str);
            if (result.browser.name.len > 0) summary.browser_name = result.browser.name;
            if (result.browser.version.len > 0) summary.browser_version = result.browser.version;
            if (result.os.name.len > 0) summary.os_name = result.os.name;
            if (result.os.version.len > 0) summary.os_version = result.os.version;
            if (result.device.type) |dt| summary.device_type = ua_parser.deviceTypeToString(dt);
        }
    }

    return summary;
}

pub fn logRequestSummary(logger: logging.Logger, summary: RequestSummary) void {
    logger.infoFields(.{
        .event = "request_completed",
        .req_id = summary.req_id,
        .method = summary.method,
        .path = summary.path,
        .status = summary.status,
        .response_time_ms = summary.response_time_ms,
        .user_agent = summary.user_agent,
        .content_length = summary.content_length,
        .browser_name = summary.browser_name,
        .browser_version = summary.browser_version,
        .os_name = summary.os_name,
        .os_version = summary.os_version,
        .device_type = summary.device_type,
    }, "request completed");
}
