const std = @import("std");
const ziez = @import("ziez");

// Build with: zig build -Dwith_multipart=true
// Run with:   zig build run-multipart -Dwith_multipart=true
//
// Test with curl:
//   curl -F "avatar=@photo.jpg" -F "name=alice" http://localhost:3000/upload

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var app = ziez.init(allocator);
    defer app.deinit();

    // Single-file upload — store in .zig-cache/uploads/
    app.post("/upload", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            var upload = try req.saveMultipart(.{
                .root_dir = ".zig-cache/uploads",
                .file_fields = &.{"avatar"},
                .allowed_types = &.{ "image/jpeg", "image/png", "image/webp", "image/gif" },
                .max_file_size = 5 * 1024 * 1024, // 5 MB
            });
            defer upload.deinit();

            const file = upload.getFile("avatar") orelse
                return ziez.throw(error.BadRequest, "missing 'avatar' file field", res);

            const name = upload.getField("name") orelse "anonymous";

            res.status(200).json(.{
                .uploaded_by = name,
                .filename = file.original_name,
                .path = file.path,
                .size = file.size,
                .content_type = file.content_type,
            });
        }
    }.handler);

    // Multi-file upload
    app.post("/upload/gallery", struct {
        fn handler(req: *ziez.Request, res: *ziez.Response) !void {
            var upload = try req.saveMultipart(.{
                .root_dir = ".zig-cache/gallery",
                .file_fields = &.{ "photo1", "photo2", "photo3" },
                .allowed_types = &.{ "image/*" },
                .max_file_size = 10 * 1024 * 1024,
            });
            defer upload.deinit();

            var count: u32 = 0;
            inline for (.{ "photo1", "photo2", "photo3" }) |field| {
                if (upload.getFile(field) != null) count += 1;
            }

            res.status(201).json(.{ .uploaded_files = count });
        }
    }.handler);

    app.get("/", struct {
        fn handler(_: *ziez.Request, res: *ziez.Response) !void {
            res.json(.{
                .endpoints = &[_][]const u8{
                    "POST /upload        (single image: avatar field)",
                    "POST /upload/gallery (multi image: photo1..3 fields)",
                },
            });
        }
    }.handler);

    std.debug.print("Multipart upload server listening on :3000\n", .{});
    try app.listen("0.0.0.0:3000");
}
