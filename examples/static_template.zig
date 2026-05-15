const std = @import("std");
const ziez = @import("ziez");

// Build with: zig build -Dwith_static=true -Dwith_template=true
// Run with:   zig build run-static-template -Dwith_static=true -Dwith_template=true

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    // ── Static file serving ───────────────────────────────────────────────────
    // Serve files from ./public under the /static URL prefix.
    // Requests to /static/style.css → ./public/style.css
    app.router.useStatic(.{
        .root = "./public",
        .prefix = "/static",
        .max_age = 3600,
        .etag = true,
        .dotfiles = .deny,
    });

    // ── Template engine ───────────────────────────────────────────────────────
    // Load .html templates from ./views; cache them after first read.
    var engine = ziez.TemplateEngine.init(allocator, .{
        .views_dir = "./views",
        .extension = ".html",
        .cache = true,
    });
    defer engine.deinit();
    app.router.setTemplateEngine(&engine);

    // ── Routes ────────────────────────────────────────────────────────────────
    // Render views/index.html with {{title}} and {{greeting}} filled in.
    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.render("index", .{
                .title = "Welcome",
                .greeting = "Hello from ziez templates!",
            });
        }
    }.handler);

    app.get("/about", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.render("about", .{ .title = "About" });
        }
    }.handler);

    // API route alongside static serving — both can coexist.
    app.get("/api/status", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{ .status = "ok" });
        }
    }.handler);

    std.debug.print("Static + Template server listening on :3000\n", .{});
    std.debug.print("  Static files: ./public/ -> /static/\n", .{});
    std.debug.print("  Templates:    ./views/\n", .{});
    try app.listen(io, "0.0.0.0:3000");
}
