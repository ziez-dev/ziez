const std = @import("std");
const builtin = @import("builtin");

extern "c" fn close(fd: std.posix.fd_t) c_int;
extern "c" fn write(fd: std.posix.fd_t, buf: [*]const u8, count: usize) isize;

var next_upload_id: std.atomic.Value(u64) = .init(1);

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,
};

pub const Multipart = struct {
    parts: std.ArrayList(Part),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Multipart {
        return .{
            .parts = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Multipart) void {
        self.parts.deinit(self.allocator);
    }

    pub fn parse(
        allocator: std.mem.Allocator,
        body: []const u8,
        boundary: []const u8,
    ) !Multipart {
        var mp = Multipart.init(allocator);

        const delim = try std.mem.join(allocator, "", &.{ "--", boundary });
        defer allocator.free(delim);

        var it = std.mem.splitSequence(u8, body, delim);
        _ = it.next();

        while (it.next()) |part_data| {
            if (part_data.len >= 2 and std.mem.eql(u8, part_data[0..2], "--")) break;
            const trimmed = std.mem.trim(u8, part_data, "\r\n");
            if (trimmed.len == 0) continue;

            if (parsePart(trimmed)) |part| {
                try mp.parts.append(allocator, part);
            }
        }

        return mp;
    }

    pub fn get(self: *const Multipart, name: []const u8) ?Part {
        for (self.parts.items) |part| {
            if (std.mem.eql(u8, part.name, name)) return part;
        }
        return null;
    }

    pub fn getFile(self: *const Multipart, name: []const u8) ?Part {
        for (self.parts.items) |part| {
            if (part.filename != null and std.mem.eql(u8, part.name, name)) return part;
        }
        return null;
    }

    fn parsePart(raw: []const u8) ?Part {
        const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
        const headers_section = raw[0..sep];
        const body = raw[sep + 4 ..];
        const body_trimmed = if (body.len >= 2 and std.mem.eql(u8, body[body.len - 2 ..], "\r\n"))
            body[0 .. body.len - 2]
        else
            body;

        const parsed = parseHeaders(headers_section) orelse return null;
        return .{
            .name = parsed.name,
            .filename = parsed.filename,
            .content_type = parsed.content_type,
            .data = body_trimmed,
        };
    }

    pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
        const marker = "boundary=";
        const start = std.mem.indexOf(u8, content_type, marker) orelse return null;
        const boundary_start = start + marker.len;
        var end = boundary_start;
        while (end < content_type.len and content_type[end] != ';' and content_type[end] != ' ') {
            end += 1;
        }
        var boundary = content_type[boundary_start..end];
        if (boundary.len >= 2 and boundary[0] == '"' and boundary[boundary.len - 1] == '"') {
            boundary = boundary[1 .. boundary.len - 1];
        }
        return boundary;
    }
};

pub const FormField = struct {
    name: []const u8,
    value: []const u8,
};

pub const UploadedFile = struct {
    field_name: []const u8,
    original_name: []const u8,
    sanitized_name: []const u8,
    content_type: []const u8,
    path: []const u8,
    size: usize,
};

pub const MultipartUpload = struct {
    allocator: std.mem.Allocator,
    fields: std.ArrayList(FormField),
    files: std.ArrayList(UploadedFile),

    pub fn init(allocator: std.mem.Allocator) MultipartUpload {
        return .{
            .allocator = allocator,
            .fields = .empty,
            .files = .empty,
        };
    }

    pub fn deinit(self: *MultipartUpload) void {
        for (self.fields.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        self.fields.deinit(self.allocator);

        for (self.files.items) |file| {
            self.allocator.free(file.field_name);
            self.allocator.free(file.original_name);
            self.allocator.free(file.sanitized_name);
            self.allocator.free(file.content_type);
            self.allocator.free(file.path);
        }
        self.files.deinit(self.allocator);
    }

    pub fn getField(self: *const MultipartUpload, name: []const u8) ?[]const u8 {
        for (self.fields.items) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.value;
        }
        return null;
    }

    pub fn getFile(self: *const MultipartUpload, name: []const u8) ?*const UploadedFile {
        for (self.files.items) |*file| {
            if (std.mem.eql(u8, file.field_name, name)) return file;
        }
        return null;
    }

    pub fn countFiles(self: *const MultipartUpload, name: []const u8) usize {
        var count: usize = 0;
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.field_name, name)) count += 1;
        }
        return count;
    }
};

pub const UploadConfig = struct {
    root_dir: []const u8,
    subdir: ?[]const u8 = null,
    max_body_size: usize = 50 * 1024 * 1024,
    max_file_size: usize = 10 * 1024 * 1024,
    max_files: usize = 1,
    allowed_types: []const []const u8 = &.{},
    file_fields: []const []const u8 = &.{},
    chunk_size: usize = 8192,
};

const ParsedHeaders = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
};

const SaveContext = struct {
    allocator: std.mem.Allocator,
    config: UploadConfig,
    upload: MultipartUpload,
    pending: std.ArrayList(u8),
    bytes_read: usize = 0,
    eof: bool = false,
    boundary_start: []u8,
    boundary_inner: []u8,
    file_index: usize = 0,
    created_paths: std.ArrayList([]u8),

    fn init(allocator: std.mem.Allocator, config: UploadConfig, boundary: []const u8) !SaveContext {
        const boundary_start = try std.fmt.allocPrint(allocator, "--{s}\r\n", .{boundary});
        errdefer allocator.free(boundary_start);
        const boundary_inner = try std.fmt.allocPrint(allocator, "\r\n--{s}", .{boundary});
        errdefer allocator.free(boundary_inner);

        return .{
            .allocator = allocator,
            .config = config,
            .upload = MultipartUpload.init(allocator),
            .pending = .empty,
            .boundary_start = boundary_start,
            .boundary_inner = boundary_inner,
            .created_paths = .empty,
        };
    }

    fn deinit(self: *SaveContext) void {
        self.pending.deinit(self.allocator);
        self.allocator.free(self.boundary_start);
        self.allocator.free(self.boundary_inner);
        self.created_paths.deinit(self.allocator);
    }

    fn cleanupFiles(self: *SaveContext) void {
        if (comptime builtin.os.tag != .linux) return;
        for (self.created_paths.items) |path| {
            const zpath = self.allocator.dupeZ(u8, path) catch continue;
            defer self.allocator.free(zpath);
            _ = std.os.linux.unlinkat(std.os.linux.AT.FDCWD, zpath, 0);
        }
    }
};

const CurrentFile = struct {
    fd: std.posix.fd_t,
    path: []u8,
    field_name: []u8,
    original_name: []u8,
    sanitized_name: []u8,
    content_type: []u8,
    size: usize = 0,
};

pub fn saveUpload(
    allocator: std.mem.Allocator,
    reader: anytype,
    content_length: usize,
    boundary: []const u8,
    config: UploadConfig,
) !MultipartUpload {
    if (content_length > config.max_body_size) return error.PayloadTooLarge;

    var ctx = try SaveContext.init(allocator, config, boundary);
    errdefer ctx.deinit();
    errdefer ctx.cleanupFiles();
    errdefer ctx.upload.deinit();

    try expectInitialBoundary(&ctx, reader, content_length);

    while (true) {
        const reached_final = blk: {
            const header_block = try readHeaderBlock(&ctx, reader, content_length);
            defer allocator.free(header_block);
            const parsed = parseHeaders(header_block) orelse return error.BadRequest;

            if (parsed.filename != null) {
                if (ctx.upload.files.items.len >= config.max_files) return error.BadRequest;
                if (!isAllowedField(parsed.name, config.file_fields)) return error.BadRequest;

                const ctype = parsed.content_type orelse "application/octet-stream";
                if (!isAllowedMime(ctype, config.allowed_types)) return error.UnsupportedMediaType;

                var file = try openCurrentFile(&ctx, parsed.name, parsed.filename.?, ctype);
                const final = consumePartBody(&ctx, reader, content_length, &file, null) catch |err| {
                    cleanupCurrentFile(&ctx, &file);
                    return err;
                };
                defer closeCurrentFile(&file);

                try ctx.upload.files.append(allocator, .{
                    .field_name = file.field_name,
                    .original_name = file.original_name,
                    .sanitized_name = file.sanitized_name,
                    .content_type = file.content_type,
                    .path = file.path,
                    .size = file.size,
                });
                try ctx.created_paths.append(allocator, file.path);
                break :blk final;
            }

            var value = std.ArrayList(u8).empty;
            defer value.deinit(allocator);
            const final = try consumePartBody(&ctx, reader, content_length, null, &value);

            try ctx.upload.fields.append(allocator, .{
                .name = try allocator.dupe(u8, parsed.name),
                .value = try value.toOwnedSlice(allocator),
            });
            break :blk final;
        };

        if (reached_final) break;
    }

    const upload = ctx.upload;
    ctx.upload = MultipartUpload.init(allocator);
    ctx.deinit();
    return upload;
}

fn expectInitialBoundary(ctx: *SaveContext, reader: anytype, content_length: usize) !void {
    while (ctx.pending.items.len < ctx.boundary_start.len) {
        if (!try readMore(ctx, reader, content_length)) break;
    }

    if (!std.mem.startsWith(u8, ctx.pending.items, ctx.boundary_start)) return error.BadRequest;
    dropPendingPrefix(ctx, ctx.boundary_start.len);
}

fn readHeaderBlock(ctx: *SaveContext, reader: anytype, content_length: usize) ![]u8 {
    while (true) {
        if (std.mem.indexOf(u8, ctx.pending.items, "\r\n\r\n")) |idx| {
            const owned = try ctx.allocator.dupe(u8, ctx.pending.items[0..idx]);
            dropPendingPrefix(ctx, idx + 4);
            return owned;
        }
        if (!try readMore(ctx, reader, content_length)) return error.BadRequest;
    }
}

fn consumePartBody(
    ctx: *SaveContext,
    reader: anytype,
    content_length: usize,
    current_file: ?*CurrentFile,
    current_field: ?*std.ArrayList(u8),
) !bool {
    while (true) {
        if (std.mem.indexOf(u8, ctx.pending.items, ctx.boundary_inner)) |idx| {
            try appendBodyChunk(ctx, current_file, current_field, ctx.pending.items[0..idx]);

            const needed = idx + ctx.boundary_inner.len + 2;
            while (ctx.pending.items.len < needed) {
                if (!try readMore(ctx, reader, content_length)) return error.BadRequest;
            }

            const trailer = ctx.pending.items[idx + ctx.boundary_inner.len .. idx + ctx.boundary_inner.len + 2];
            const final = std.mem.eql(u8, trailer, "--");
            if (!final and !std.mem.eql(u8, trailer, "\r\n")) return error.BadRequest;

            dropPendingPrefix(ctx, idx + ctx.boundary_inner.len + 2);
            return final;
        }

        const keep = @min(ctx.pending.items.len, ctx.boundary_inner.len + 4);
        const flush_len = ctx.pending.items.len - keep;
        if (flush_len > 0) {
            try appendBodyChunk(ctx, current_file, current_field, ctx.pending.items[0..flush_len]);
            dropPendingPrefix(ctx, flush_len);
        }

        if (!try readMore(ctx, reader, content_length)) return error.BadRequest;
    }
}

fn appendBodyChunk(
    ctx: *SaveContext,
    current_file: ?*CurrentFile,
    current_field: ?*std.ArrayList(u8),
    chunk: []const u8,
) !void {
    if (chunk.len == 0) return;

    if (current_file) |file| {
        const next_size = file.size + chunk.len;
        if (next_size > ctx.config.max_file_size) return error.PayloadTooLarge;
        try writeAll(file.fd, chunk);
        file.size = next_size;
        return;
    }

    if (current_field) |field| {
        try field.appendSlice(ctx.allocator, chunk);
    }
}

fn openCurrentFile(
    ctx: *SaveContext,
    field_name: []const u8,
    original_name: []const u8,
    content_type: []const u8,
) !CurrentFile {
    const sanitized_name = try sanitizeFilename(ctx.allocator, original_name);
    errdefer ctx.allocator.free(sanitized_name);

    const dir_path = try buildTargetDir(ctx.allocator, ctx.config);
    defer ctx.allocator.free(dir_path);
    try ensureDirRecursive(ctx.allocator, dir_path);

    const extension = std.fs.path.extension(sanitized_name);
    const suffix = next_upload_id.fetchAdd(1, .monotonic);
    const final_name = try std.fmt.allocPrint(ctx.allocator, "{x}-{d}{s}", .{
        suffix,
        ctx.file_index,
        extension,
    });
    errdefer ctx.allocator.free(final_name);
    defer ctx.allocator.free(final_name);
    ctx.file_index += 1;

    const full_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ dir_path, final_name });
    errdefer ctx.allocator.free(full_path);

    const zpath = try ctx.allocator.dupeZ(u8, full_path);
    defer ctx.allocator.free(zpath);

    const fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        zpath,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );

    return .{
        .fd = fd,
        .path = full_path,
        .field_name = try ctx.allocator.dupe(u8, field_name),
        .original_name = try ctx.allocator.dupe(u8, original_name),
        .sanitized_name = sanitized_name,
        .content_type = try ctx.allocator.dupe(u8, content_type),
    };
}

fn closeCurrentFile(file: *CurrentFile) void {
    _ = close(file.fd);
}

fn cleanupCurrentFile(ctx: *SaveContext, file: *CurrentFile) void {
    closeCurrentFile(file);
    const zpath = ctx.allocator.dupeZ(u8, file.path) catch null;
    if (zpath) |owned_zpath| {
        defer ctx.allocator.free(owned_zpath);
        if (comptime builtin.os.tag == .linux) {
            _ = std.os.linux.unlinkat(std.os.linux.AT.FDCWD, owned_zpath, 0);
        }
    }
    ctx.allocator.free(file.path);
    ctx.allocator.free(file.field_name);
    ctx.allocator.free(file.original_name);
    ctx.allocator.free(file.sanitized_name);
    ctx.allocator.free(file.content_type);
}

fn writeAll(fd: std.posix.fd_t, content: []const u8) !void {
    var written: usize = 0;
    while (written < content.len) {
        const n = write(fd, content.ptr + written, content.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn buildTargetDir(allocator: std.mem.Allocator, config: UploadConfig) ![]u8 {
    if (config.subdir) |subdir| {
        const trimmed_root = trimTrailingSlashes(config.root_dir);
        const trimmed_subdir = std.mem.trim(u8, subdir, "/");
        if (trimmed_subdir.len == 0) return allocator.dupe(u8, trimmed_root);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_root, trimmed_subdir });
    }
    return allocator.dupe(u8, trimTrailingSlashes(config.root_dir));
}

fn ensureDirRecursive(allocator: std.mem.Allocator, dir_path: []const u8) !void {
    if (dir_path.len == 0) return;
    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);

    if (dir_path[0] == '/') try current.append(allocator, '/');
    var it = std.mem.tokenizeScalar(u8, dir_path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (current.items.len > 0 and current.items[current.items.len - 1] != '/') {
            try current.append(allocator, '/');
        }
        try current.appendSlice(allocator, segment);
        try mkdirIfMissing(allocator, current.items);
    }
}

fn mkdirIfMissing(allocator: std.mem.Allocator, path: []const u8) !void {
    const zpath = try allocator.dupeZ(u8, path);
    defer allocator.free(zpath);

    if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;

    const rc = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, zpath, 0o755);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS, .EXIST => {},
        else => return error.AccessDenied,
    }
}

fn trimTrailingSlashes(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 1 and input[end - 1] == '/') {
        end -= 1;
    }
    return input[0..end];
}

fn readMore(ctx: *SaveContext, reader: anytype, content_length: usize) !bool {
    if (ctx.eof) return false;
    if (ctx.bytes_read >= content_length) {
        ctx.eof = true;
        return false;
    }

    const chunk = try reader.take(@min(ctx.config.chunk_size, content_length - ctx.bytes_read));
    if (chunk.len == 0) {
        ctx.eof = true;
        return false;
    }

    ctx.bytes_read += chunk.len;
    try ctx.pending.appendSlice(ctx.allocator, chunk);
    return true;
}

fn dropPendingPrefix(ctx: *SaveContext, n: usize) void {
    if (n == 0) return;
    const rest = ctx.pending.items[n..];
    std.mem.copyForwards(u8, ctx.pending.items[0..rest.len], rest);
    ctx.pending.items.len = rest.len;
}

fn parseHeaders(headers_section: []const u8) ?ParsedHeaders {
    var name: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var content_type: ?[]const u8 = null;

    var header_it = std.mem.splitSequence(u8, headers_section, "\r\n");
    while (header_it.next()) |header_line| {
        if (header_line.len == 0) continue;

        if (std.mem.indexOfScalar(u8, header_line, ':')) |colon_pos| {
            const hname = std.mem.trim(u8, header_line[0..colon_pos], " \t");
            const hvalue = std.mem.trim(u8, header_line[colon_pos + 1 ..], " \t");

            if (std.ascii.eqlIgnoreCase(hname, "Content-Disposition")) {
                name = extractHeaderParam(hvalue, "name");
                filename = extractHeaderParam(hvalue, "filename");
            } else if (std.ascii.eqlIgnoreCase(hname, "Content-Type")) {
                content_type = hvalue;
            }
        }
    }

    return .{
        .name = name orelse return null,
        .filename = filename,
        .content_type = content_type,
    };
}

fn extractHeaderParam(header_value: []const u8, key: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, header_value, ';');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (!std.mem.startsWith(u8, part, key)) continue;
        if (part.len <= key.len or part[key.len] != '=') continue;
        var value = std.mem.trim(u8, part[key.len + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        return value;
    }
    return null;
}

fn sanitizeFilename(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const basename = std.fs.path.basename(name);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (basename) |ch| {
        if (ch == 0) continue;
        if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_') {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '_');
        }
    }

    if (out.items.len == 0) try out.appendSlice(allocator, "upload.bin");
    return out.toOwnedSlice(allocator);
}

fn isAllowedField(name: []const u8, allowed: []const []const u8) bool {
    if (allowed.len == 0) return true;
    for (allowed) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn isAllowedMime(actual: []const u8, allowed: []const []const u8) bool {
    if (allowed.len == 0) return true;
    for (allowed) |candidate| {
        if (std.mem.eql(u8, candidate, actual)) return true;
        if (candidate.len > 2 and std.mem.endsWith(u8, candidate, "/*")) {
            const slash_idx = std.mem.indexOfScalar(u8, candidate, '/') orelse continue;
            if (std.mem.indexOfScalar(u8, actual, '/')) |actual_slash| {
                if (std.mem.eql(u8, candidate[0..slash_idx], actual[0..actual_slash])) return true;
            }
        }
    }
    return false;
}
