const std = @import("std");
const platform = @import("../core/platform.zig");

// ── Public types ──────────────────────────────────────────────────────────────

/// Configuration for the native Zig template engine.
pub const TemplateConfig = struct {
    /// Root directory for view templates (relative to CWD or absolute).
    views_dir: []const u8 = "./views",
    /// Default layout file name (basename without extension).
    /// Set to `null` to disable layout wrapping.
    default_layout: ?[]const u8 = null,
    /// Cache parsed templates in memory to avoid repeated reads.
    cache: bool = true,
    /// File extension appended when loading templates by name.
    extension: []const u8 = ".html",
};

/// Native Zig server-side template engine.
///
/// Template syntax:
///   `{{field_name}}` — replaced with the value of the named field from the
///                      anonymous struct context passed to `renderAlloc`.
///   `{{body}}`       — reserved for layout injection when a layout is active.
///
/// Usage:
/// ```zig
/// var engine = TemplateEngine.init(allocator, .{});
/// defer engine.deinit();
/// const html = try engine.renderAlloc(allocator, "index", .{ .title = "Home" });
/// defer allocator.free(html);
/// ```
pub const TemplateEngine = struct {
    allocator: std.mem.Allocator,
    config: TemplateConfig,
    /// key  = view name (owned copy)
    /// value = template content (owned copy)
    cache: std.StringHashMap([]const u8),

    // ── Lifecycle ─────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator, config: TemplateConfig) TemplateEngine {
        return .{
            .allocator = allocator,
            .config = config,
            .cache = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *TemplateEngine) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cache.deinit();
    }

    // ── Internal: template loading ─────────────────────────────────────────

    /// Load a template by name.
    ///
    /// When caching is enabled the returned slice is stable until `deinit`.
    /// When caching is disabled the *caller* owns the returned memory.
    fn readTemplate(self: *TemplateEngine, name: []const u8) ![]const u8 {
        if (self.config.cache) {
            if (self.cache.get(name)) |cached| return cached;
        }

        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const file_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}{s}", .{
            self.config.views_dir,
            name,
            self.config.extension,
        }) catch return error.PathTooLong;

        var io_impl = std.Io.Threaded.init_single_threaded;
        const io = io_impl.io();
        const fd = std.Io.Dir.cwd().openFile(io, std.mem.sliceTo(file_path, 0), .{ .mode = .read_only }) catch |err| {
            std.debug.print("ziez/template: cannot open template '{s}': {}\n", .{ std.mem.sliceTo(file_path, 0), err });
            return err;
        };
        defer fd.close(io);

        const content = try platform.readFileAll(self.allocator, fd, io, 4 * 1024 * 1024);

        if (self.config.cache) {
            const key = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(key);
            try self.cache.put(key, content);
            return self.cache.get(name).?;
        }

        return content;
    }

    // ── Public: render ────────────────────────────────────────────────────

    /// Render view `name` with `context` and return the produced HTML.
    ///
    /// If `config.default_layout` is set, the view body is injected into the
    /// layout at the `{{body}}` placeholder.
    ///
    /// The caller owns the returned slice.
    pub fn renderAlloc(
        self: *TemplateEngine,
        allocator: std.mem.Allocator,
        name: []const u8,
        context: anytype,
    ) ![]const u8 {
        const view_tpl = try self.readTemplate(name);
        defer if (!self.config.cache) self.allocator.free(view_tpl);

        const body = try self.renderString(allocator, view_tpl, context);

        if (self.config.default_layout) |layout_name| {
            defer allocator.free(body);

            var layout_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const layout_view = std.fmt.bufPrint(&layout_path_buf, "layouts/{s}", .{layout_name}) catch return error.PathTooLong;

            const layout_tpl = try self.readTemplate(layout_view);
            defer if (!self.config.cache) self.allocator.free(layout_tpl);

            // Render layout with the same context (fills non-body vars)
            const rendered_layout = try self.renderString(allocator, layout_tpl, context);
            defer allocator.free(rendered_layout);

            // Inject the view body into `{{body}}`
            return std.mem.replaceOwned(u8, allocator, rendered_layout, "{{body}}", body);
        }

        return body;
    }

    // ── Internal: string interpolation ────────────────────────────────────

    /// Walk `tpl`, replacing `{{field}}` tokens with values from `context`.
    /// The caller owns the returned slice.
    fn renderString(
        _: *TemplateEngine,
        allocator: std.mem.Allocator,
        tpl: []const u8,
        context: anytype,
    ) ![]const u8 {
        const T = @TypeOf(context);
        const type_info = @typeInfo(T);

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < tpl.len) {
            if (i + 1 < tpl.len and tpl[i] == '{' and tpl[i + 1] == '{') {
                const token_start = i + 2;
                var token_end = token_start;

                while (token_end + 1 < tpl.len) : (token_end += 1) {
                    if (tpl[token_end] == '}' and tpl[token_end + 1] == '}') break;
                } else {
                    try out.appendSlice(allocator, "{{");
                    i += 2;
                    continue;
                }

                const var_name = std.mem.trim(u8, tpl[token_start..token_end], " \t\r\n");

                var found = false;
                if (type_info == .@"struct") {
                    inline for (std.meta.fields(T)) |field| {
                        if (std.mem.eql(u8, field.name, var_name)) {
                            found = true;
                            const val = @field(context, field.name);
                            try formatValue(allocator, &out, val);
                        }
                    }
                }

                if (!found) {
                    if (std.mem.eql(u8, var_name, "body")) {
                        try out.appendSlice(allocator, "{{body}}");
                    }
                }

                i = token_end + 2;
                continue;
            }

            try out.append(allocator, tpl[i]);
            i += 1;
        }

        return out.toOwnedSlice(allocator);
    }

    // ── Internal: value formatting ─────────────────────────────────────────

    fn formatValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), val: anytype) !void {
        const T = @TypeOf(val);
        switch (@typeInfo(T)) {
            .int, .comptime_int => try out.print(allocator, "{d}", .{val}),
            .float, .comptime_float => try out.print(allocator, "{d}", .{val}),
            .bool => try out.appendSlice(allocator, if (val) "true" else "false"),
            .optional => {
                if (val) |v| try formatValue(allocator, out, v);
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    try out.appendSlice(allocator, val);
                } else if (ptr_info.size == .one) {
                    try formatValue(allocator, out, val.*);
                } else {
                    try out.print(allocator, "{any}", .{val});
                }
            },
            .array => |arr_info| {
                if (arr_info.child == u8) {
                    try out.appendSlice(allocator, &val);
                } else {
                    try out.print(allocator, "{any}", .{val});
                }
            },
            else => try out.print(allocator, "{any}", .{val}),
        }
    }
};
