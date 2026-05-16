const std = @import("std");
const ziez = @import("ziez");

const alloc = std.testing.allocator;

fn mkdirZ(path: [*:0]const u8) void {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    std.Io.Dir.cwd().createDirPath(io, std.mem.sliceTo(path, 0)) catch {};
}

fn rmdirZ(path: [*:0]const u8) void {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    std.Io.Dir.cwd().deleteDir(io, std.mem.sliceTo(path, 0)) catch {};
}

fn writeFileZ(path: [*:0]const u8, content: []const u8) !void {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    const file = try std.Io.Dir.cwd().createFile(io, std.mem.sliceTo(path, 0), .{ .read = false });
    defer file.close(io);
    try file.writePositionalAll(io, content, 0);
}

fn deleteFileZ(path: [*:0]const u8) void {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    std.Io.Dir.cwd().deleteFile(io, std.mem.sliceTo(path, 0)) catch {};
}

test "Template: basic {{var}} interpolation" {
    mkdirZ(".zig-cache/test-tpl-1");
    try writeFileZ(".zig-cache/test-tpl-1/greeting.html", "Hello, {{name}}! You are {{age}} years old.");
    defer {
        deleteFileZ(".zig-cache/test-tpl-1/greeting.html");
        rmdirZ(".zig-cache/test-tpl-1");
    }
    var eng = ziez.TemplateEngine.init(alloc, .{ .views_dir = ".zig-cache/test-tpl-1", .default_layout = null, .cache = false, .extension = ".html" });
    defer eng.deinit();
    const result = try eng.renderAlloc(alloc, "greeting", .{ .name = "Alice", .age = @as(u32, 30) });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Hello, Alice! You are 30 years old.", result);
}

test "Template: integer, float, and bool fields" {
    mkdirZ(".zig-cache/test-tpl-2");
    try writeFileZ(".zig-cache/test-tpl-2/types.html", "i={{i}} f={{f}} b={{b}}");
    defer {
        deleteFileZ(".zig-cache/test-tpl-2/types.html");
        rmdirZ(".zig-cache/test-tpl-2");
    }
    var eng = ziez.TemplateEngine.init(alloc, .{ .views_dir = ".zig-cache/test-tpl-2", .default_layout = null, .cache = false, .extension = ".html" });
    defer eng.deinit();
    const result = try eng.renderAlloc(alloc, "types", .{ .i = @as(i32, -7), .f = @as(f64, 3.14), .b = true });
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "i=-7") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "b=true") != null);
}

test "Template: optional field with value renders correctly" {
    mkdirZ(".zig-cache/test-tpl-3");
    try writeFileZ(".zig-cache/test-tpl-3/opt.html", "val={{val}}");
    defer {
        deleteFileZ(".zig-cache/test-tpl-3/opt.html");
        rmdirZ(".zig-cache/test-tpl-3");
    }
    var eng = ziez.TemplateEngine.init(alloc, .{ .views_dir = ".zig-cache/test-tpl-3", .default_layout = null, .cache = false, .extension = ".html" });
    defer eng.deinit();
    const result = try eng.renderAlloc(alloc, "opt", .{ .val = @as(?[]const u8, "present") });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("val=present", result);
}

test "Template: unknown variable is silently dropped" {
    mkdirZ(".zig-cache/test-tpl-4");
    try writeFileZ(".zig-cache/test-tpl-4/unknown.html", "[{{unknown}}]");
    defer {
        deleteFileZ(".zig-cache/test-tpl-4/unknown.html");
        rmdirZ(".zig-cache/test-tpl-4");
    }
    var eng = ziez.TemplateEngine.init(alloc, .{ .views_dir = ".zig-cache/test-tpl-4", .default_layout = null, .cache = false, .extension = ".html" });
    defer eng.deinit();
    const result = try eng.renderAlloc(alloc, "unknown", .{ .name = "test" });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[]", result);
}

test "Template: unclosed {{ is emitted literally" {
    mkdirZ(".zig-cache/test-tpl-5");
    try writeFileZ(".zig-cache/test-tpl-5/broken.html", "{{unclosed text");
    defer {
        deleteFileZ(".zig-cache/test-tpl-5/broken.html");
        rmdirZ(".zig-cache/test-tpl-5");
    }
    var eng = ziez.TemplateEngine.init(alloc, .{ .views_dir = ".zig-cache/test-tpl-5", .default_layout = null, .cache = false, .extension = ".html" });
    defer eng.deinit();
    const result = try eng.renderAlloc(alloc, "broken", .{});
    defer alloc.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "{{"));
}

test "Template: plain HTML without placeholders is unchanged" {
    mkdirZ(".zig-cache/test-tpl-6");
    const html = "<html><body><p>Static content</p></body></html>";
    try writeFileZ(".zig-cache/test-tpl-6/plain.html", html);
    defer {
        deleteFileZ(".zig-cache/test-tpl-6/plain.html");
        rmdirZ(".zig-cache/test-tpl-6");
    }
    var eng = ziez.TemplateEngine.init(alloc, .{ .views_dir = ".zig-cache/test-tpl-6", .default_layout = null, .cache = false, .extension = ".html" });
    defer eng.deinit();
    const result = try eng.renderAlloc(alloc, "plain", .{ .unused = "x" });
    defer alloc.free(result);
    try std.testing.expectEqualStrings(html, result);
}

test "Template: layout {{body}} is replaced with rendered view" {
    mkdirZ(".zig-cache/test-tpl-7");
    mkdirZ(".zig-cache/test-tpl-7/layouts");
    const layout = "<!DOCTYPE html><html><head><title>{{title}}</title></head><body>{{body}}</body></html>";
    try writeFileZ(".zig-cache/test-tpl-7/layouts/main.html", layout);
    try writeFileZ(".zig-cache/test-tpl-7/page.html", "<h1>{{heading}}</h1>");
    defer {
        deleteFileZ(".zig-cache/test-tpl-7/layouts/main.html");
        rmdirZ(".zig-cache/test-tpl-7/layouts");
        deleteFileZ(".zig-cache/test-tpl-7/page.html");
        rmdirZ(".zig-cache/test-tpl-7");
    }
    var eng = ziez.TemplateEngine.init(alloc, .{ .views_dir = ".zig-cache/test-tpl-7", .default_layout = "main", .cache = false, .extension = ".html" });
    defer eng.deinit();
    const result = try eng.renderAlloc(alloc, "page", .{ .title = "My Page", .heading = "Welcome" });
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<title>My Page</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<h1>Welcome</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "{{body}}") == null);
}

test "App.setTemplateEngine stores engine in router" {
    var app = ziez.init(alloc);
    defer app.deinit();
    var engine = ziez.TemplateEngine.init(alloc, .{});
    defer engine.deinit();
    app.setTemplateEngine(&engine);
    try std.testing.expectEqual(@as(usize, 1), app.router.hooks.items.len);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&engine)), app.router.hooks.items[0].ptr);
}

test "TemplateConfig: default values are sensible" {
    const cfg = ziez.TemplateConfig{};
    try std.testing.expectEqualStrings("./views", cfg.views_dir);
    try std.testing.expectEqualStrings(".html", cfg.extension);
    try std.testing.expect(cfg.cache);
    try std.testing.expect(cfg.default_layout == null);
}

test "Template: cache returns same content on second render" {
    mkdirZ(".zig-cache/test-tpl-10");
    try writeFileZ(".zig-cache/test-tpl-10/cached.html", "{{val}}");
    defer {
        deleteFileZ(".zig-cache/test-tpl-10/cached.html");
        rmdirZ(".zig-cache/test-tpl-10");
    }
    var eng = ziez.TemplateEngine.init(alloc, .{ .views_dir = ".zig-cache/test-tpl-10", .default_layout = null, .cache = true, .extension = ".html" });
    defer eng.deinit();
    const ctx = .{ .val = "hit" };
    const r1 = try eng.renderAlloc(alloc, "cached", ctx);
    defer alloc.free(r1);
    const r2 = try eng.renderAlloc(alloc, "cached", ctx);
    defer alloc.free(r2);
    try std.testing.expectEqualStrings(r1, r2);
    try std.testing.expectEqualStrings("hit", r1);
}
