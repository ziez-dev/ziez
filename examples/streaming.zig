const std = @import("std");
const ziez = @import("ziez");

// Shared state for streaming handlers (Zig has no closures).
var ndjson_counter: i32 = 0;
var sse_counter: u32 = 0;

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var app = ziez.init(allocator);
    defer app.deinit();

    app.on_error(struct {
        fn handler(_: *ziez.Request, res: *ziez.Response, err: anyerror) void {
            const info = ziez.errorToResponse(err);
            const msg = res.error_message orelse info.message;
            res.status(info.code).json(.{ .statusCode = info.code, .@"error" = msg });
        }
    }.handler);

    // GET /stream/ndjson — NDJSON streaming
    app.get("/stream/ndjson", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            ndjson_counter = 0;
            res.streamNdjson(ndjsonHandler);
        }
        fn ndjsonHandler(sw: *ziez.NdjsonStreamWriter) anyerror!void {
            while (ndjson_counter < 5) {
                try sw.writeObject(.{
                    .index = ndjson_counter,
                    .message = "hello",
                });
                ndjson_counter += 1;

            }
        }
    }.handler);

    // GET /stream/sse — Server-Sent Events
    app.get("/stream/sse", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            sse_counter = 0;
            res.streamSse(sseHandler);
        }
        fn sseHandler(sw: *ziez.SseStreamWriter) anyerror!void {
            try sw.setEvent("message");
            while (sse_counter < 5) {
                const msg = std.fmt.allocPrint(sw.inner.allocator, "event #{d}", .{sse_counter}) catch "msg";
                try sw.setData(msg);
                try sw.setId(std.fmt.allocPrint(sw.inner.allocator, "{d}", .{sse_counter}) catch "0");
                sse_counter += 1;
            }
            try sw.setData("[DONE]");
        }
    }.handler);

    // GET /stream/csv — CSV streaming
    app.get("/stream/csv", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.streamCsv(.{ .write_bom = true }, csvHandler);
        }
        fn csvHandler(sw: *ziez.CsvStreamWriter) anyerror!void {
            try sw.writeRow(&.{"ID", "Name", "Email"});
            const users = [_][]const u8{
                "1",  "Alice", "alice@example.com",
                "2",  "Bob",   "bob@example.com",
                "3",  "Carol", "carol@example.com",
            };
            for (0..users.len / 3) |i| {
                const base = i * 3;
                try sw.writeRow(&.{ users[base], users[base + 1], users[base + 2] });
            }
        }
    }.handler);

    // GET /stream/json-array — JSON array streaming
    app.get("/stream/json-array", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.streamJsonArray(jsonArrayHandler);
        }
        fn jsonArrayHandler(sw: *ziez.JsonArrayStreamWriter) anyerror!void {
            var i: i32 = 0;
            while (i < 5) {
                try sw.writeItem(.{
                    .id = i,
                    .name = "item",
                    .active = true,
                });
                i += 1;
            }
        }
    }.handler);

    // GET /stream/text — plain text streaming
    app.get("/stream/text", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.streamText(textHandler);
        }
        fn textHandler(sw: *ziez.StreamWriter) anyerror!void {
            var i: i32 = 0;
            while (i < 5) {
                const line = std.fmt.allocPrint(sw.allocator, "chunk {d}\n", .{i}) catch "chunk\n";
                try sw.write(line);
                try sw.flush();
                i += 1;
            }
        }
    }.handler);

    std.debug.print("Streaming server listening on http://0.0.0.0:3000\n", .{});
    std.debug.print("Endpoints:\n", .{});
    std.debug.print("  curl -N http://localhost:3000/stream/ndjson\n", .{});
    std.debug.print("  curl -N http://localhost:3000/stream/sse\n", .{});
    std.debug.print("  curl -N http://localhost:3000/stream/csv\n", .{});
    std.debug.print("  curl -N http://localhost:3000/stream/json-array\n", .{});
    std.debug.print("  curl -N http://localhost:3000/stream/text\n", .{});

    app.listen(io, "0.0.0.0:3000") catch |e| {
        std.debug.print("server error: {s}\n", .{@errorName(e)});
    };
}
