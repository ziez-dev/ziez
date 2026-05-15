const std = @import("std");
const builtin = @import("builtin");

pub const LogLevel = enum(u8) {
    trace = 10,
    debug = 20,
    info = 30,
    warn = 40,
    @"error" = 50,
    fatal = 60,
};

pub const Sink = struct {
    context: ?*anyopaque = null,
    writeFn: *const fn (?*anyopaque, LogLevel, []const u8) void,

    pub fn stderr() Sink {
        return .{ .writeFn = stderrWrite };
    }

    pub fn write(self: Sink, level: LogLevel, line: []const u8) void {
        self.writeFn(self.context, level, line);
    }

    fn stderrWrite(_: ?*anyopaque, level: LogLevel, line: []const u8) void {
        const trimmed = trimTrailingNewline(line);
        switch (toStdLevel(level)) {
            .err => std.log.defaultLog(.err, .ziez, "{s}", .{trimmed}),
            .warn => std.log.defaultLog(.warn, .ziez, "{s}", .{trimmed}),
            .info => std.log.defaultLog(.info, .ziez, "{s}", .{trimmed}),
            .debug => std.log.defaultLog(.debug, .ziez, "{s}", .{trimmed}),
        }
    }

    fn toStdLevel(level: LogLevel) std.log.Level {
        return switch (level) {
            .trace => .debug,
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .@"error" => .err,
            .fatal => .err,
        };
    }

    fn trimTrailingNewline(line: []const u8) []const u8 {
        if (line.len == 0) return line;
        if (line[line.len - 1] == '\n') return line[0 .. line.len - 1];
        return line;
    }
};

pub const LoggerConfig = struct {
    level: LogLevel = .info,
    redact: []const []const u8 = &.{},
    sink: Sink = Sink.stderr(),
};

pub const Logger = struct {
    state: *State,
    bindings_fragment: []const u8 = "",

    const MaxPathDepth = 16;

    const State = struct {
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        mutex: std.atomic.Mutex = .unlocked,
        level: LogLevel,
        redact: []const []const u8,
        sink: Sink,
    };

    const PathStack = struct {
        parts: [MaxPathDepth][]const u8 = undefined,
        len: usize = 0,

        fn push(self: *PathStack, part: []const u8) void {
            if (self.len >= self.parts.len) return;
            self.parts[self.len] = part;
            self.len += 1;
        }

        fn pop(self: *PathStack) void {
            if (self.len > 0) self.len -= 1;
        }

        fn slice(self: *const PathStack) []const []const u8 {
            return self.parts[0..self.len];
        }
    };

    pub fn init(allocator: std.mem.Allocator, cfg: LoggerConfig) Logger {
        const state = allocator.create(State) catch @panic("logger state allocation failed");
        state.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .level = cfg.level,
            .redact = &.{},
            .sink = cfg.sink,
        };

        var logger = Logger{ .state = state };
        logger.configure(cfg);
        return logger;
    }

    pub fn deinit(self: *Logger) void {
        self.state.arena.deinit();
        self.state.allocator.destroy(self.state);
    }

    pub fn configure(self: *Logger, cfg: LoggerConfig) void {
        lockState(self.state);
        defer self.state.mutex.unlock();

        self.state.level = cfg.level;
        self.state.sink = cfg.sink;
        self.state.redact = dupRedactPatterns(self.state, cfg.redact);
    }

    pub fn getConfig(self: Logger) LoggerConfig {
        lockState(self.state);
        defer self.state.mutex.unlock();

        return .{
            .level = self.state.level,
            .redact = self.state.redact,
            .sink = self.state.sink,
        };
    }

    pub fn child(self: Logger, bindings: anytype) Logger {
        lockState(self.state);
        defer self.state.mutex.unlock();

        const fragment = serializeFragmentPersistent(self.state, self.state.redact, bindings);
        if (fragment.len == 0) return self;

        if (self.bindings_fragment.len == 0) {
            return .{ .state = self.state, .bindings_fragment = fragment };
        }

        const allocator = self.state.arena.allocator();
        const merged = std.fmt.allocPrint(allocator, "{s},{s}", .{ self.bindings_fragment, fragment }) catch self.bindings_fragment;
        return .{ .state = self.state, .bindings_fragment = merged };
    }

    pub fn enabled(self: Logger, level: LogLevel) bool {
        lockState(self.state);
        defer self.state.mutex.unlock();
        return @intFromEnum(level) >= @intFromEnum(self.state.level);
    }

    pub fn trace(self: Logger, msg: []const u8) void {
        self.emit(.trace, msg, null);
    }

    pub fn debug(self: Logger, msg: []const u8) void {
        self.emit(.debug, msg, null);
    }

    pub fn info(self: Logger, msg: []const u8) void {
        self.emit(.info, msg, null);
    }

    pub fn warn(self: Logger, msg: []const u8) void {
        self.emit(.warn, msg, null);
    }

    pub fn @"error"(self: Logger, msg: []const u8) void {
        self.emit(.@"error", msg, null);
    }

    pub fn err(self: Logger, msg: []const u8) void {
        self.@"error"(msg);
    }

    pub fn fatal(self: Logger, msg: []const u8) void {
        self.emit(.fatal, msg, null);
    }

    pub fn traceFields(self: Logger, fields: anytype, msg: []const u8) void {
        self.emit(.trace, msg, fields);
    }

    pub fn debugFields(self: Logger, fields: anytype, msg: []const u8) void {
        self.emit(.debug, msg, fields);
    }

    pub fn infoFields(self: Logger, fields: anytype, msg: []const u8) void {
        self.emit(.info, msg, fields);
    }

    pub fn warnFields(self: Logger, fields: anytype, msg: []const u8) void {
        self.emit(.warn, msg, fields);
    }

    pub fn errorFields(self: Logger, fields: anytype, msg: []const u8) void {
        self.emit(.@"error", msg, fields);
    }

    pub fn fatalFields(self: Logger, fields: anytype, msg: []const u8) void {
        self.emit(.fatal, msg, fields);
    }

    fn emit(self: Logger, level: LogLevel, msg: []const u8, maybe_fields: anytype) void {
        lockState(self.state);
        defer self.state.mutex.unlock();

        if (@intFromEnum(level) < @intFromEnum(self.state.level)) return;

        // Fast path: build into a 4 KiB stack buffer — zero heap allocation for typical log lines.
        var stack_buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
        var line: std.ArrayList(u8) = .empty;
        if (buildLine(self, &line, fba.allocator(), level, msg, maybe_fields)) {
            self.state.sink.write(level, line.items);
            return;
        }

        // Slow path: line exceeded 4 KiB; fall back to heap allocator.
        line = .empty;
        defer line.deinit(self.state.allocator);
        if (buildLine(self, &line, self.state.allocator, level, msg, maybe_fields)) {
            self.state.sink.write(level, line.items);
        }
    }

    fn buildLine(self: Logger, line: *std.ArrayList(u8), alloc: std.mem.Allocator, level: LogLevel, msg: []const u8, maybe_fields: anytype) bool {
        line.append(alloc, '{') catch return false;
        var first = true;
        appendKeyValueString(line, alloc, "level", @tagName(level), &first) catch return false;
        appendKeyValueInt(line, alloc, "ts", wallTimestampMs(), &first) catch return false;

        if (self.bindings_fragment.len > 0) {
            appendSeparator(line, alloc, &first) catch return false;
            line.appendSlice(alloc, self.bindings_fragment) catch return false;
        }

        appendKeyValueString(line, alloc, "msg", msg, &first) catch return false;

        if (@TypeOf(maybe_fields) != @TypeOf(null)) {
            var path = PathStack{};
            appendObjectEntries(line, alloc, maybe_fields, &first, &path, self.state.redact) catch return false;
        }

        line.appendSlice(alloc, "}\n") catch return false;
        return true;
    }

    fn dupRedactPatterns(state: *State, patterns: []const []const u8) []const []const u8 {
        if (patterns.len == 0) return &.{};

        const arena = state.arena.allocator();
        const copied = arena.alloc([]const u8, patterns.len) catch return &.{};
        for (patterns, 0..) |pattern, i| {
            copied[i] = arena.dupe(u8, pattern) catch pattern;
        }
        return copied;
    }

    fn serializeFragmentPersistent(state: *State, redact: []const []const u8, fields: anytype) []const u8 {
        var path = PathStack{};
        var buf: std.ArrayList(u8) = .empty;
        var first = true;
        appendObjectEntries(&buf, state.arena.allocator(), fields, &first, &path, redact) catch return "";
        return buf.toOwnedSlice(state.arena.allocator()) catch "";
    }

    fn appendSeparator(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, first: *bool) !void {
        if (first.*) {
            first.* = false;
            return;
        }
        try buf.append(allocator, ',');
    }

    fn appendKey(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, first: *bool) !void {
        try appendSeparator(buf, allocator, first);
        try appendJsonString(buf, allocator, key);
        try buf.append(allocator, ':');
    }

    fn appendKeyValueString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8, first: *bool) !void {
        try appendKey(buf, allocator, key, first);
        try appendJsonString(buf, allocator, value);
    }

    fn appendKeyValueInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: anytype, first: *bool) !void {
        try appendKey(buf, allocator, key, first);
        try appendJsonNumber(buf, allocator, value);
    }

    fn appendObjectEntries(
        buf: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        value: anytype,
        first: *bool,
        path: *PathStack,
        redact: []const []const u8,
    ) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .@"struct" => |struct_info| {
                inline for (struct_info.fields) |field| {
                    path.push(field.name);
                    defer path.pop();

                    try appendKey(buf, allocator, field.name, first);
                    try appendValue(buf, allocator, @field(value, field.name), path, redact);
                }
            },
            else => @compileError("Logger fields must be a struct or anonymous struct"),
        }
    }

    fn appendValue(
        buf: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        value: anytype,
        path: *PathStack,
        redact: []const []const u8,
    ) !void {
        if (shouldRedact(path.slice(), redact)) {
            try appendJsonString(buf, allocator, "[REDACTED]");
            return;
        }

        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .bool => try buf.appendSlice(allocator, if (value) "true" else "false"),
            .int, .comptime_int, .float, .comptime_float => try appendJsonNumber(buf, allocator, value),
            .enum_literal => try appendJsonString(buf, allocator, @tagName(value)),
            .@"enum" => try appendJsonString(buf, allocator, @tagName(value)),
            .error_set => try appendJsonString(buf, allocator, @errorName(value)),
            .optional => {
                if (value) |inner| {
                    try appendValue(buf, allocator, inner, path, redact);
                } else {
                    try buf.appendSlice(allocator, "null");
                }
            },
            .pointer => |pointer_info| {
                if (pointer_info.size == .slice and pointer_info.child == u8) {
                    try appendJsonString(buf, allocator, value);
                    return;
                }
                if (pointer_info.size == .slice) {
                    try appendArray(buf, allocator, value, path, redact);
                    return;
                }
                if (pointer_info.size == .one) {
                    try appendValue(buf, allocator, value.*, path, redact);
                    return;
                }
                try appendJsonString(buf, allocator, "<pointer>");
            },
            .array => |array_info| {
                if (array_info.child == u8) {
                    try appendJsonString(buf, allocator, value[0..]);
                    return;
                }
                try appendArray(buf, allocator, value[0..], path, redact);
            },
            .@"struct" => {
                try buf.append(allocator, '{');
                var nested_first = true;
                try appendObjectEntries(buf, allocator, value, &nested_first, path, redact);
                try buf.append(allocator, '}');
            },
            else => {
                var fallback: [128]u8 = undefined;
                const rendered = std.fmt.bufPrint(&fallback, "{any}", .{value}) catch "<unprintable>";
                try appendJsonString(buf, allocator, rendered);
            },
        }
    }

    fn appendArray(
        buf: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        values: anytype,
        path: *PathStack,
        redact: []const []const u8,
    ) !void {
        try buf.append(allocator, '[');
        var first = true;
        for (values) |item| {
            try appendSeparator(buf, allocator, &first);
            try appendValue(buf, allocator, item, path, redact);
        }
        try buf.append(allocator, ']');
    }

    fn appendJsonNumber(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) !void {
        var tmp: [64]u8 = undefined;
        const rendered = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return;
        try buf.appendSlice(allocator, rendered);
    }

    fn appendJsonString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
        try buf.append(allocator, '"');
        for (value) |c| {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        var escaped: [6]u8 = undefined;
                        const text = std.fmt.bufPrint(&escaped, "\\u{X:0>4}", .{c}) catch continue;
                        try buf.appendSlice(allocator, text);
                    } else {
                        try buf.append(allocator, c);
                    }
                },
            }
        }
        try buf.append(allocator, '"');
    }

    fn shouldRedact(path: []const []const u8, patterns: []const []const u8) bool {
        for (patterns) |pattern| {
            if (matchesPattern(path, pattern)) return true;
        }
        return false;
    }

    fn lockState(state: *State) void {
        while (!state.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn wallTimestampMs() i64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
        return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
    }

    fn matchesPattern(path: []const []const u8, pattern: []const u8) bool {
        var parts: [MaxPathDepth][]const u8 = undefined;
        var len: usize = 0;
        var it = std.mem.splitScalar(u8, pattern, '.');
        while (it.next()) |segment| {
            if (len >= parts.len) break;
            parts[len] = segment;
            len += 1;
        }

        if (len != path.len) return false;
        for (path, 0..) |part, i| {
            if (std.mem.eql(u8, parts[i], "*")) continue;
            if (!std.mem.eql(u8, parts[i], part)) return false;
        }
        return true;
    }
};
