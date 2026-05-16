const std = @import("std");

/// Type-erased plugin handle.
///
/// For simple plugins (Pattern A — no cleanup), pass your struct directly to
/// `app.plugin()`. The struct must declare `plugin_name`, `plugin_version`,
/// and `install(self, *App) !void` as pub decls.
///
/// For stateful plugins that own resources (Pattern B — with cleanup), create
/// a Plugin via `ziez.makePlugin()` and pass it to `app.plugin()`.
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    /// Opaque pointer to the plugin's state struct.
    ptr: *anyopaque,
    /// install_fn(plugin_ptr, app_ptr: *App cast to *anyopaque) !void
    install_fn: *const fn (*anyopaque, *anyopaque) anyerror!void,
    /// Optional cleanup called during app.deinit(). Null for stateless plugins.
    deinit_fn: ?*const fn (*anyopaque, std.mem.Allocator) void,
};
