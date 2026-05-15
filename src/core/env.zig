const std = @import("std");
const platform = @import("platform.zig");

pub const Env = struct {
    vars: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Env {
        const content = readFile(allocator, path) catch {
            return Env{
                .vars = std.StringHashMap([]const u8).init(allocator),
                .allocator = allocator,
            };
        };
        defer allocator.free(content);
        return initWithContent(allocator, content);
    }

    pub fn initWithContent(allocator: std.mem.Allocator, content: []const u8) !Env {
        var env = Env{
            .vars = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };

        var line_it = std.mem.splitSequence(u8, content, "\n");
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
                const key = std.mem.trim(u8, line[0..eq_pos], " \t");
                var val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
                if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or
                    (val[0] == '\'' and val[val.len - 1] == '\'')))
                {
                    val = val[1 .. val.len - 1];
                }
                if (key.len > 0) {
                    const dup_key = try allocator.dupe(u8, key);
                    const dup_val = try allocator.dupe(u8, val);
                    try env.vars.put(dup_key, dup_val);
                }
            }
        }

        return env;
    }

    pub fn deinit(self: *Env) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.vars.deinit();
    }

    pub fn get(self: *Env, key: []const u8) ?[]const u8 {
        return self.vars.get(key);
    }

    pub fn getOr(self: *Env, key: []const u8, default: []const u8) []const u8 {
        return self.get(key) orelse default;
    }

    pub fn getRequired(self: *Env, key: []const u8) ![]const u8 {
        return self.get(key) orelse error.MissingRequiredEnvVar;
    }

    pub fn getInt(self: *Env, key: []const u8, comptime T: type, default: T) T {
        const val = self.get(key) orelse return default;
        return std.fmt.parseInt(T, val, 10) catch default;
    }

    pub fn getBool(self: *Env, key: []const u8, default: bool) bool {
        const val = self.get(key) orelse return default;
        if (std.ascii.eqlIgnoreCase(val, "true") or std.mem.eql(u8, val, "1")) return true;
        if (std.ascii.eqlIgnoreCase(val, "false") or std.mem.eql(u8, val, "0")) return false;
        return default;
    }

    pub fn getFloat(self: *Env, key: []const u8, comptime T: type, default: T) T {
        const val = self.get(key) orelse return default;
        return std.fmt.parseFloat(T, val) catch default;
    }
};

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    const file = try platform.openFileReadOnly(io, path);
    defer file.close(io);
    return platform.readFileAll(allocator, file, io, 1024 * 1024);
}
