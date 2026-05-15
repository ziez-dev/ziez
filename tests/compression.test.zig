const std = @import("std");
const ziez = @import("ziez");
const opts = @import("ziez_options");

// ---------------------------------------------------------------------------
// Algorithm
// ---------------------------------------------------------------------------

test "Algorithm: encodingName returns correct strings" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        try std.testing.expectEqualStrings("gzip", compression.Algorithm.gzip.encodingName());
        try std.testing.expectEqualStrings("deflate", compression.Algorithm.deflate.encodingName());
        try std.testing.expectEqualStrings("br", compression.Algorithm.brotli.encodingName());
    }
}

test "Algorithm: toContainer maps correctly" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        try std.testing.expect(std.compress.flate.Container.gzip == compression.Algorithm.gzip.toContainer());
        try std.testing.expect(std.compress.flate.Container.raw == compression.Algorithm.deflate.toContainer());
    }
}

// ---------------------------------------------------------------------------
// selectAlgorithm
// ---------------------------------------------------------------------------

test "selectAlgorithm: picks gzip when available" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const result = compression.selectAlgorithm("gzip, deflate", config);
        try std.testing.expect(result != null);
        try std.testing.expect(result.? == .gzip);
    }
}

test "selectAlgorithm: picks deflate when no gzip" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const result = compression.selectAlgorithm("deflate", config);
        try std.testing.expect(result != null);
        try std.testing.expect(result.? == .deflate);
    }
}

test "selectAlgorithm: picks brotli when available" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const algos: []const compression.Algorithm = &.{ .brotli, .gzip, .deflate };
        const config = compression.CompressionConfig{ .algorithms = algos };
        const result = compression.selectAlgorithm("br", config);
        try std.testing.expect(result != null);
        try std.testing.expect(result.? == .brotli);
    }
}

test "selectAlgorithm: returns null for empty header" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const result = compression.selectAlgorithm("", config);
        try std.testing.expect(result == null);
    }
}

test "selectAlgorithm: handles wildcard identity" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const result = compression.selectAlgorithm("*", config);
        try std.testing.expect(result == null);
    }
}

test "selectAlgorithm: picks first configured algorithm" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const algos: []const compression.Algorithm = &.{ .deflate, .gzip };
        const config = compression.CompressionConfig{ .algorithms = algos };
        const result = compression.selectAlgorithm("gzip, deflate", config);
        try std.testing.expect(result != null);
        try std.testing.expect(result.? == .deflate);
    }
}

test "selectAlgorithm: handles Accept-Encoding with spaces" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const result = compression.selectAlgorithm("gzip, deflate, br", config);
        try std.testing.expect(result != null);
        try std.testing.expect(result.? == .gzip);
    }
}

// ---------------------------------------------------------------------------
// shouldCompress
// ---------------------------------------------------------------------------

test "shouldCompress: returns true for eligible response" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const body = "a" ** 2048;
        try std.testing.expect(compression.shouldCompress(body, "application/json", null, config));
    }
}

test "shouldCompress: returns false when disabled" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{ .enabled = false };
        const body = "a" ** 2048;
        try std.testing.expect(!compression.shouldCompress(body, "application/json", null, config));
    }
}

test "shouldCompress: returns false below threshold" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{ .threshold = 1024 };
        const body = "hello";
        try std.testing.expect(!compression.shouldCompress(body, "application/json", null, config));
    }
}

test "shouldCompress: returns false for binary content-type" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const body = "a" ** 2048;
        try std.testing.expect(!compression.shouldCompress(body, "image/png", null, config));
    }
}

test "shouldCompress: returns false when already encoded" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const body = "a" ** 2048;
        try std.testing.expect(!compression.shouldCompress(body, "application/json", "gzip", config));
    }
}

test "shouldCompress: returns false for nil content-type" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const body = "a" ** 2048;
        try std.testing.expect(!compression.shouldCompress(body, null, null, config));
    }
}

test "shouldCompress: matches text/html" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const body = "<html>" ** 500;
        try std.testing.expect(compression.shouldCompress(body, "text/html; charset=utf-8", null, config));
    }
}

test "shouldCompress: matches text/plain" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const config = compression.CompressionConfig{};
        const body = "a" ** 2048;
        try std.testing.expect(compression.shouldCompress(body, "text/plain", null, config));
    }
}

// ---------------------------------------------------------------------------
// compressBody
// ---------------------------------------------------------------------------

test "compressBody: gzip compression works" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const allocator = std.testing.allocator;
        const body = "Hello World! " ** 200;
        const compressed = try compression.compressBody(allocator, body, .gzip, .default);
        defer allocator.free(compressed);
        try std.testing.expect(compressed.len < body.len);
        try std.testing.expectEqual(@as(u8, 0x1f), compressed[0]);
        try std.testing.expectEqual(@as(u8, 0x8b), compressed[1]);
    }
}

test "compressBody: deflate compression works" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const allocator = std.testing.allocator;
        const body = "Hello World! " ** 200;
        const compressed = try compression.compressBody(allocator, body, .deflate, .default);
        defer allocator.free(compressed);
        try std.testing.expect(compressed.len < body.len);
    }
}

test "compressBody: fastest level produces output" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const allocator = std.testing.allocator;
        const body = "Hello World! " ** 200;
        const compressed = try compression.compressBody(allocator, body, .gzip, .fastest);
        defer allocator.free(compressed);
        try std.testing.expect(compressed.len > 0);
        try std.testing.expect(compressed.len < body.len);
    }
}

test "compressBody: best level produces output" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const allocator = std.testing.allocator;
        const body = "Hello World! " ** 200;
        const compressed = try compression.compressBody(allocator, body, .gzip, .best);
        defer allocator.free(compressed);
        try std.testing.expect(compressed.len > 0);
        try std.testing.expect(compressed.len < body.len);
    }
}

test "compressBody: gzip output has correct format" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const allocator = std.testing.allocator;
        const body = "Hello World! This is a test of compression in ziez framework. " ** 50;
        const compressed = try compression.compressBody(allocator, body, .gzip, .default);
        defer allocator.free(compressed);
        try std.testing.expectEqual(@as(u8, 0x1f), compressed[0]);
        try std.testing.expectEqual(@as(u8, 0x8b), compressed[1]);
        try std.testing.expectEqual(@as(u8, 0x08), compressed[2]);
        try std.testing.expect(compressed.len < body.len);
    }
}

test "compressBody: brotli compression works" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const allocator = std.testing.allocator;
        const body = "Hello World! " ** 200;
        const compressed = try compression.compressBody(allocator, body, .brotli, .default);
        defer allocator.free(compressed);
        try std.testing.expect(compressed.len > 0);
        try std.testing.expect(compressed.len < body.len);
    }
}

test "compressBody: brotli fastest level" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const allocator = std.testing.allocator;
        const body = "Hello World! " ** 200;
        const compressed = try compression.compressBody(allocator, body, .brotli, .fastest);
        defer allocator.free(compressed);
        try std.testing.expect(compressed.len > 0);
        try std.testing.expect(compressed.len < body.len);
    }
}

test "compressBody: brotli best level" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const allocator = std.testing.allocator;
        const body = "Hello World! " ** 200;
        const compressed = try compression.compressBody(allocator, body, .brotli, .best);
        defer allocator.free(compressed);
        try std.testing.expect(compressed.len > 0);
        try std.testing.expect(compressed.len < body.len);
    }
}

// ---------------------------------------------------------------------------
// CompressionLevel
// ---------------------------------------------------------------------------

test "CompressionLevel: maps to correct options" {
    if (comptime opts.with_compression) {
        const compression = ziez.compression;
        const opts1 = compression.CompressionLevel.fastest.toOptions();
        const opts_default = compression.CompressionLevel.default.toOptions();
        const opts9 = compression.CompressionLevel.best.toOptions();
        try std.testing.expect(opts1.chain <= opts_default.chain);
        try std.testing.expect(opts_default.chain <= opts9.chain);
    }
}
