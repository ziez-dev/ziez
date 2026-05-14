const std = @import("std");

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
        // Skip preamble (before first boundary)
        _ = it.next();

        while (it.next()) |part_data| {
            // End boundary has trailing --
            if (part_data.len >= 2 and std.mem.eql(u8, part_data[0..2], "--")) break;
            // Skip empty parts
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
        // Split headers from body at \r\n\r\n
        const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
        const headers_section = raw[0..sep];
        const body = raw[sep + 4 ..];
        // Trim trailing \r\n from body
        const body_trimmed = if (body.len >= 2 and std.mem.eql(u8, body[body.len - 2 ..], "\r\n"))
            body[0 .. body.len - 2]
        else
            body;

        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;

        // Parse headers line by line
        var header_it = std.mem.splitSequence(u8, headers_section, "\r\n");
        while (header_it.next()) |header_line| {
            if (header_line.len == 0) continue;

            if (std.mem.indexOfScalar(u8, header_line, ':')) |colon_pos| {
                const hname = std.mem.trim(u8, header_line[0..colon_pos], " \t");
                const hvalue = std.mem.trim(u8, header_line[colon_pos + 1 ..], " \t");

                if (std.ascii.eqlIgnoreCase(hname, "Content-Disposition")) {
                    // Parse: form-data; name="field1"; filename="foo.txt"
                    name = extractQuotedValue(hvalue, "name=") orelse extractQuotedValue(hvalue, "name=");
                    // Try quoted name
                    if (std.mem.indexOf(u8, hvalue, "name=\"")) |start| {
                        const val_start = start + 6;
                        if (std.mem.indexOfScalar(u8, hvalue[val_start..], '"')) |end_offset| {
                            name = hvalue[val_start .. val_start + end_offset];
                        }
                    } else if (std.mem.indexOf(u8, hvalue, "name=")) |start| {
                        const val_start = start + 5;
                        const rest = hvalue[val_start..];
                        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                        name = std.mem.trim(u8, rest[0..end], " ");
                    }

                    if (std.mem.indexOf(u8, hvalue, "filename=\"")) |start| {
                        const val_start = start + 10;
                        if (std.mem.indexOfScalar(u8, hvalue[val_start..], '"')) |end_offset| {
                            filename = hvalue[val_start .. val_start + end_offset];
                        }
                    } else if (std.mem.indexOf(u8, hvalue, "filename=")) |start| {
                        const val_start = start + 9;
                        const rest = hvalue[val_start..];
                        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                        filename = std.mem.trim(u8, rest[0..end], " ");
                    }
                } else if (std.ascii.eqlIgnoreCase(hname, "Content-Type")) {
                    content_type = hvalue;
                }
            }
        }

        return Part{
            .name = name orelse return null,
            .filename = filename,
            .content_type = content_type,
            .data = body_trimmed,
        };
    }

    fn extractQuotedValue(input: []const u8, key: []const u8) ?[]const u8 {
        _ = input;
        _ = key;
        return null;
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
        // Strip surrounding quotes if present
        if (boundary.len >= 2 and boundary[0] == '"' and boundary[boundary.len - 1] == '"') {
            boundary = boundary[1 .. boundary.len - 1];
        }
        return boundary;
    }
};
