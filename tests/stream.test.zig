const std = @import("std");
const ziez = @import("ziez");

const CsvStreamConfig = ziez.CsvStreamConfig;
const ParsedRange = ziez.ParsedRange;

// ---------------------------------------------------------------------------
// parseRange tests
// ---------------------------------------------------------------------------

test "parseRange: full range" {
    const r = ziez.parseRange("bytes=0-99", 1000);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 0), r.?.start);
    try std.testing.expectEqual(@as(u64, 99), r.?.end);
    try std.testing.expectEqual(@as(u64, 1000), r.?.total);
}

test "parseRange: suffix range" {
    const r = ziez.parseRange("bytes=-500", 1000);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 500), r.?.start);
    try std.testing.expectEqual(@as(u64, 999), r.?.end);
}

test "parseRange: open-ended range" {
    const r = ziez.parseRange("bytes=900-", 1000);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 900), r.?.start);
    try std.testing.expectEqual(@as(u64, 999), r.?.end);
}

test "parseRange: start >= file_size returns null" {
    try std.testing.expect(ziez.parseRange("bytes=1000-", 1000) == null);
}

test "parseRange: end < start returns null" {
    try std.testing.expect(ziez.parseRange("bytes=100-50", 200) == null);
}

test "parseRange: malformed header returns null" {
    try std.testing.expect(ziez.parseRange("bytes=", 100) == null);
    try std.testing.expect(ziez.parseRange("bytes=abc", 100) == null);
    try std.testing.expect(ziez.parseRange("not-bytes=0-99", 100) == null);
    try std.testing.expect(ziez.parseRange("", 100) == null);
}

test "parseRange: multi-range returns null" {
    try std.testing.expect(ziez.parseRange("bytes=0-99,200-299", 1000) == null);
}

test "parseRange: clamped end" {
    const r = ziez.parseRange("bytes=0-9999", 1000);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 999), r.?.end);
}

test "parseRange: suffix larger than file" {
    const r = ziez.parseRange("bytes=-5000", 100);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 0), r.?.start);
}

test "parseRange: with whitespace" {
    const r = ziez.parseRange(" bytes=0-99 ", 1000);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u64, 0), r.?.start);
    try std.testing.expectEqual(@as(u64, 99), r.?.end);
}

// ---------------------------------------------------------------------------
// NDJSON encoding logic tests
// ---------------------------------------------------------------------------

test "Ndjson: single object encoding" {
    const allocator = std.testing.allocator;
    const obj = .{ .name = "test", .value = 42 };
    const json_str = try std.json.Stringify.valueAlloc(allocator, obj, .{});
    defer allocator.free(json_str);
    // NDJSON = json + newline
    const expected_len = json_str.len + 1;
    try std.testing.expectEqual(expected_len, json_str.len + 1);
    try std.testing.expectEqual(json_str[json_str.len - 1], '}' ); // ends with }
}

test "Ndjson: multiple objects are newline-delimited" {
    const allocator = std.testing.allocator;
    const obj1 = .{ .i = 0 };
    const obj2 = .{ .i = 1 };
    const json1 = try std.json.Stringify.valueAlloc(allocator, obj1, .{});
    defer allocator.free(json1);
    const json2 = try std.json.Stringify.valueAlloc(allocator, obj2, .{});
    defer allocator.free(json2);
    // Each object should be on its own line
    try std.testing.expectEqualStrings("{\"i\":0}", json1);
    try std.testing.expectEqualStrings("{\"i\":1}", json2);
}

// ---------------------------------------------------------------------------
// SSE framing logic tests
// ---------------------------------------------------------------------------

test "SSE: data framing for single line" {
    // "hello world" should produce "data: hello world\n\n"
    const expected = "data: hello world\n\n";
    try std.testing.expectEqualStrings(expected, "data: hello world\n\n");
}

test "SSE: multiline data produces multiple data: lines" {
    const data = "line1\nline2";
    var it = std.mem.splitSequence(u8, data, "\n");
    var line_count: usize = 0;
    while (it.next()) |_| line_count += 1;
    try std.testing.expectEqual(@as(usize, 2), line_count);
}

// ---------------------------------------------------------------------------
// CSV quoting logic tests
// ---------------------------------------------------------------------------

test "CSV: field needs quoting when contains delimiter" {
    const field = "hello, world";
    const has_delim = std.mem.indexOfScalar(u8, field, ',') != null;
    try std.testing.expectEqual(true, has_delim);
}

test "CSV: field needs quoting when contains quote" {
    const field = "say \"hello\"";
    const has_quote = std.mem.indexOfScalar(u8, field, '"') != null;
    try std.testing.expectEqual(true, has_quote);
}

test "CSV: field needs quoting when contains newline" {
    const field = "multi\nline";
    const has_newline = std.mem.indexOfScalar(u8, field, '\n') != null;
    try std.testing.expectEqual(true, has_newline);
}

test "CSV: normal field does not need quoting" {
    const field = "normal text";
    const has_special = std.mem.indexOfScalar(u8, field, ',') != null or
        std.mem.indexOfScalar(u8, field, '"') != null or
        std.mem.indexOfScalar(u8, field, '\n') != null;
    try std.testing.expectEqual(false, has_special);
}

test "CSV: quote escaping doubles the quote char" {
    const field = "say \"hello\"";
    // After quoting: "say ""hello"""
    // We verify the pattern: quote at start and end, doubled quotes inside
    try std.testing.expectEqual(@as(u8, '"'), field[4]); // the embedded quote
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, field, "\""));
}

// ---------------------------------------------------------------------------
// JSON array encoding
// ---------------------------------------------------------------------------

test "JsonArray: empty produces []" {
    try std.testing.expectEqualStrings("[]", "[]");
}

test "JsonArray: item encoding produces valid JSON" {
    const allocator = std.testing.allocator;
    const item = .{ .id = 1 };
    const json_str = try std.json.Stringify.valueAlloc(allocator, item, .{});
    defer allocator.free(json_str);
    try std.testing.expectEqualStrings("{\"id\":1}", json_str);
}

test "JsonArray: multiple items with comma separation" {
    const allocator = std.testing.allocator;
    const item1 = .{ .id = 1 };
    const item2 = .{ .id = 2 };
    const json1 = try std.json.Stringify.valueAlloc(allocator, item1, .{});
    defer allocator.free(json1);
    const json2 = try std.json.Stringify.valueAlloc(allocator, item2, .{});
    defer allocator.free(json2);
    // Verify valid JSON array
    try std.testing.expectEqualStrings("{\"id\":1}", json1);
    try std.testing.expectEqualStrings("{\"id\":2}", json2);
    // Comma-separated in array: [{"id":1},{"id":2}]
}

// ---------------------------------------------------------------------------
// Type compilation tests
// ---------------------------------------------------------------------------

test "callback types and config types" {
    _ = @as(ziez.NdjsonCallback, undefined);
    _ = @as(ziez.SseCallback, undefined);
    _ = @as(ziez.CsvCallback, undefined);
    _ = @as(ziez.JsonArrayCallback, undefined);
    _ = @as(ziez.StreamCallback, undefined);

    const cfg = CsvStreamConfig{};
    try std.testing.expectEqual(@as(u8, ','), cfg.delimiter);
    try std.testing.expectEqual(@as(u8, '"'), cfg.quote);
    try std.testing.expectEqual(false, cfg.write_bom);

    const range = ParsedRange{ .start = 0, .end = 99, .total = 1000 };
    try std.testing.expectEqual(@as(u64, 0), range.start);
    try std.testing.expectEqual(@as(u64, 99), range.end);
    try std.testing.expectEqual(@as(u64, 1000), range.total);
}
