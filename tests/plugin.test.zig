const std = @import("std");
const testing = std.testing;
const ziez = @import("ziez");
const App = ziez.App;

// ---------------------------------------------------------------------------
// Pattern A helpers
// ---------------------------------------------------------------------------

const MarkPlugin = struct {
    pub const plugin_name = "mark";
    pub const plugin_version = "0.1.0";

    flag: *bool,

    pub fn install(self: *MarkPlugin, app: *App) !void {
        _ = app;
        self.flag.* = true;
    }
};

const AddMiddlewarePlugin = struct {
    pub const plugin_name = "add-mw";
    pub const plugin_version = "0.1.0";

    counter: *u32,

    pub fn install(self: *AddMiddlewarePlugin, app: *App) !void {
        _ = self;
        app.use(struct {
            fn mw(req: *ziez.Request, res: *ziez.Response, next: *ziez.Next) void {
                _ = req;
                _ = res;
                next.call();
            }
        }.mw);
    }
};

// ---------------------------------------------------------------------------
// Pattern B helpers
// ---------------------------------------------------------------------------

const StatefulPlugin = struct {
    deinit_called: *bool,

    pub fn install(self: *StatefulPlugin, app: *App) !void {
        _ = self;
        _ = app;
    }

    pub fn deinit(self: *StatefulPlugin, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.deinit_called.* = true;
    }

    pub fn asPlugin(self: *StatefulPlugin) ziez.Plugin {
        return ziez.makePlugin("stateful", "1.0.0", StatefulPlugin, self);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Pattern A: install called immediately on app.plugin()" {
    var flag = false;
    var app = App.init(testing.allocator);
    defer app.deinit();

    app.plugin(MarkPlugin{ .flag = &flag });

    try testing.expect(flag);
}

test "Pattern A: no storage in plugins list (no deinit)" {
    var flag = false;
    var app = App.init(testing.allocator);
    defer app.deinit();

    app.plugin(MarkPlugin{ .flag = &flag });

    try testing.expectEqual(@as(usize, 0), app.plugins.items.len);
}

test "Pattern A: multiple plugins installed in registration order" {
    var order = std.ArrayListUnmanaged(u8).empty;
    defer order.deinit(testing.allocator);

    const Plugin1 = struct {
        pub const plugin_name = "p1";
        pub const plugin_version = "0.1.0";
        list: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        pub fn install(self: *@This(), app: *App) !void {
            _ = app;
            try self.list.append(self.alloc, 1);
        }
    };
    const Plugin2 = struct {
        pub const plugin_name = "p2";
        pub const plugin_version = "0.1.0";
        list: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        pub fn install(self: *@This(), app: *App) !void {
            _ = app;
            try self.list.append(self.alloc, 2);
        }
    };

    var app = App.init(testing.allocator);
    defer app.deinit();

    app.plugin(Plugin1{ .list = &order, .alloc = testing.allocator });
    app.plugin(Plugin2{ .list = &order, .alloc = testing.allocator });

    try testing.expectEqualSlices(u8, &.{ 1, 2 }, order.items);
}

test "Pattern A: plugin can call app.use() inside install()" {
    var counter: u32 = 0;
    var app = App.init(testing.allocator);
    defer app.deinit();

    app.plugin(AddMiddlewarePlugin{ .counter = &counter });

    try testing.expectEqual(@as(usize, 1), app.router.mw.items.items.len);
}

test "Pattern B: makePlugin with deinit stored in plugins list" {
    var deinit_called = false;
    var p = StatefulPlugin{ .deinit_called = &deinit_called };

    var app = App.init(testing.allocator);
    app.plugin(p.asPlugin());

    try testing.expectEqual(@as(usize, 1), app.plugins.items.len);
    try testing.expect(!deinit_called);

    app.deinit();
    try testing.expect(deinit_called);
}

test "Pattern B: makePlugin without deinit not stored" {
    const NoCleanupPlugin = struct {
        flag: *bool,

        pub fn install(self: *@This(), app: *App) !void {
            _ = app;
            self.flag.* = true;
        }
    };

    var flag = false;
    var p = NoCleanupPlugin{ .flag = &flag };

    var app = App.init(testing.allocator);
    defer app.deinit();

    app.plugin(ziez.makePlugin("no-cleanup", "1.0.0", NoCleanupPlugin, &p));

    try testing.expect(flag);
    try testing.expectEqual(@as(usize, 0), app.plugins.items.len);
}

test "Pattern B: plugin name and version stored correctly" {
    var p = StatefulPlugin{ .deinit_called = &(struct {
        var v = false;
    }.v) };

    var app = App.init(testing.allocator);
    defer app.deinit();

    app.plugin(ziez.makePlugin("my-plugin", "2.3.4", StatefulPlugin, &p));

    try testing.expectEqualStrings("my-plugin", app.plugins.items[0].name);
    try testing.expectEqualStrings("2.3.4", app.plugins.items[0].version);
}

test "Pattern B: multiple stateful plugins all have deinit called" {
    var a_called = false;
    var b_called = false;

    var pa = StatefulPlugin{ .deinit_called = &a_called };
    var pb = StatefulPlugin{ .deinit_called = &b_called };

    var app = App.init(testing.allocator);

    app.plugin(pa.asPlugin());
    app.plugin(pb.asPlugin());

    try testing.expectEqual(@as(usize, 2), app.plugins.items.len);

    app.deinit();
    try testing.expect(a_called);
    try testing.expect(b_called);
}

test "Pattern B: asPlugin() helper on plugin struct" {
    var called = false;
    var p = StatefulPlugin{ .deinit_called = &called };

    var app = App.init(testing.allocator);
    defer app.deinit();

    app.plugin(p.asPlugin());

    try testing.expectEqual(@as(usize, 1), app.plugins.items.len);
    try testing.expectEqualStrings("stateful", app.plugins.items[0].name);
}

test "Plugin: install is immediate, not deferred to listen()" {
    var installed = false;
    var app = App.init(testing.allocator);
    defer app.deinit();

    app.plugin(MarkPlugin{ .flag = &installed });

    try testing.expect(installed);
}
