const std = @import("std");
const http = std.http;
const logging = @import("logging.zig");

pub const StreamWriter = struct {
    writer: *std.Io.Writer,
    body_writer: *http.BodyWriter,
    allocator: std.mem.Allocator,
    logger: ?logging.Logger,
    request_id: []const u8,

    pub const Error = http.BodyWriter.Error;

    pub fn write(self: *StreamWriter, data: []const u8) Error!void {
        try self.writer.writeAll(data);
    }

    pub fn print(self: *StreamWriter, comptime fmt: []const u8, args: anytype) Error!void {
        try self.writer.print(fmt, args);
    }

    pub fn flush(self: *StreamWriter) Error!void {
        try self.body_writer.flush();
    }

    pub fn end(self: *StreamWriter) Error!void {
        try self.body_writer.end();
    }
};

pub const StreamCallback = *const fn (*StreamWriter) anyerror!void;

pub const NdjsonStreamWriter = struct {
    inner: *StreamWriter,

    pub fn writeObject(self: *NdjsonStreamWriter, data: anytype) !void {
        const json_str = std.json.Stringify.valueAlloc(self.inner.allocator, data, .{}) catch |e| return e;
        defer self.inner.allocator.free(json_str);
        try self.inner.write(json_str);
        try self.inner.write("\n");
        try self.inner.flush();
    }

    pub fn end(self: *NdjsonStreamWriter) !void {
        try self.inner.end();
    }
};

pub const NdjsonCallback = *const fn (*NdjsonStreamWriter) anyerror!void;

pub const SseStreamWriter = struct {
    inner: *StreamWriter,

    pub fn setEvent(self: *SseStreamWriter, event: []const u8) !void {
        try self.inner.print("event: {s}\n", .{event});
    }

    pub fn setData(self: *SseStreamWriter, data: []const u8) !void {
        var it = std.mem.splitSequence(u8, data, "\n");
        while (it.next()) |line| {
            try self.inner.print("data: {s}\n", .{line});
        }
        try self.inner.write("\n");
        try self.inner.flush();
    }

    pub fn setId(self: *SseStreamWriter, id: []const u8) !void {
        try self.inner.print("id: {s}\n", .{id});
    }

    pub fn setRetry(self: *SseStreamWriter, ms: u32) !void {
        try self.inner.print("retry: {d}\n", .{ms});
    }

    pub fn comment(self: *SseStreamWriter, text: []const u8) !void {
        try self.inner.print(": {s}\n\n", .{text});
    }

    pub fn end(self: *SseStreamWriter) !void {
        try self.inner.end();
    }
};

pub const SseCallback = *const fn (*SseStreamWriter) anyerror!void;

pub const CsvStreamConfig = struct {
    delimiter: u8 = ',',
    quote: u8 = '"',
    write_bom: bool = false,
};

pub const CsvStreamWriter = struct {
    inner: *StreamWriter,
    delimiter: u8,
    quote: u8,

    pub fn writeRow(self: *CsvStreamWriter, fields: []const []const u8) !void {
        for (fields, 0..) |field, i| {
            if (i > 0) try self.inner.write(&.{self.delimiter});
            const needs_quote = containsChar(field, self.delimiter) or
                containsChar(field, self.quote) or
                containsChar(field, '\n') or
                containsChar(field, '\r');
            if (needs_quote) {
                try self.inner.write(&.{self.quote});
                var remaining = field;
                while (indexOfChar(remaining, self.quote)) |idx| {
                    try self.inner.write(remaining[0..idx]);
                    try self.inner.write(&[_]u8{ self.quote, self.quote });
                    remaining = remaining[idx + 1 ..];
                }
                try self.inner.write(remaining);
                try self.inner.write(&.{self.quote});
            } else {
                try self.inner.write(field);
            }
        }
        try self.inner.write("\r\n");
        try self.inner.flush();
    }

    pub fn end(self: *CsvStreamWriter) !void {
        try self.inner.end();
    }
};

pub const CsvCallback = *const fn (*CsvStreamWriter) anyerror!void;

pub const JsonArrayStreamWriter = struct {
    inner: *StreamWriter,
    first: bool = true,

    pub fn writeItem(self: *JsonArrayStreamWriter, data: anytype) !void {
        if (self.first) {
            self.first = false;
            try self.inner.write("[");
        } else {
            try self.inner.write(",");
        }
        const json_str = std.json.Stringify.valueAlloc(self.inner.allocator, data, .{}) catch |e| return e;
        defer self.inner.allocator.free(json_str);
        try self.inner.write(json_str);
        try self.inner.flush();
    }

    pub fn end(self: *JsonArrayStreamWriter) !void {
        if (self.first) {
            try self.inner.write("[]");
        } else {
            try self.inner.write("]");
        }
        try self.inner.end();
    }
};

pub const JsonArrayCallback = *const fn (*JsonArrayStreamWriter) anyerror!void;

// ---------------------------------------------------------------------------
// Range header parsing (RFC 7233)
// ---------------------------------------------------------------------------

pub const ParsedRange = struct {
    start: u64,
    end: u64,
    total: u64,
};

pub fn parseRange(header: []const u8, file_size: u64) ?ParsedRange {
    const spec = std.mem.trim(u8, header, " ");
    if (!std.mem.startsWith(u8, spec, "bytes=")) return null;
    const range_spec = spec["bytes=".len..];

    // Only support a single range
    if (std.mem.indexOfScalar(u8, range_spec, ',')) |_| return null;

    const dash = indexOfChar(range_spec, '-') orelse return null;

    if (dash == 0) {
        // Suffix range: bytes=-N (last N bytes)
        const suffix = std.fmt.parseInt(u64, range_spec[1..], 10) catch return null;
        if (suffix == 0) return null;
        const start = if (suffix > file_size) 0 else file_size - suffix;
        return .{ .start = start, .end = file_size - 1, .total = file_size };
    }

    const start = std.fmt.parseInt(u64, range_spec[0..dash], 10) catch return null;
    if (start >= file_size) return null;

    const end = if (dash + 1 < range_spec.len)
        std.fmt.parseInt(u64, range_spec[dash + 1 ..], 10) catch file_size - 1
    else
        file_size - 1;

    if (end < start) return null;
    const clamped_end = @min(end, file_size - 1);
    return .{ .start = start, .end = clamped_end, .total = file_size };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn containsChar(haystack: []const u8, needle: u8) bool {
    return indexOfChar(haystack, needle) != null;
}

fn indexOfChar(haystack: []const u8, needle: u8) ?usize {
    return std.mem.indexOfScalar(u8, haystack, needle);
}
