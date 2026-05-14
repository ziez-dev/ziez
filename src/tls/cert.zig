const std = @import("std");
const tls = @import("../tls.zig");

const Certificate = std.crypto.Certificate;
const AlgorithmCategory = Certificate.AlgorithmCategory;

pub const Error = error{
    InvalidPemFormat,
    InvalidDerFormat,
    UnsupportedKeyType,
    UnsupportedCurve,
    OutOfMemory,
};

/// Decode a single PEM block to DER bytes. The caller must free the returned slice.
pub fn pemToDer(allocator: std.mem.Allocator, pem: []const u8) ![]const u8 {
    const begin_marker = "-----BEGIN ";
    const end_marker = "-----END ";
    const boundary_end = "-----";

    // Find the BEGIN marker
    const begin_idx = std.mem.indexOf(u8, pem, begin_marker) orelse return error.InvalidPemFormat;
    const name_start = begin_idx + begin_marker.len;
    const name_end = std.mem.indexOfPos(u8, pem, name_start, boundary_end) orelse return error.InvalidPemFormat;
    _ = name_end;

    // Find the end of the BEGIN line (first newline after the label)
    const first_nl = std.mem.indexOfScalarPos(u8, pem, begin_idx, '\n') orelse return error.InvalidPemFormat;
    const data_start = first_nl + 1;

    // Find the END marker
    const end_idx = std.mem.indexOf(u8, pem[data_start..], end_marker) orelse return error.InvalidPemFormat;
    const data_end = data_start + end_idx;

    // Trim trailing whitespace before the END marker
    var trimmed_end = data_end;
    while (trimmed_end > data_start and isWhitespace(pem[trimmed_end - 1])) {
        trimmed_end -= 1;
    }

    const b64_data = pem[data_start..trimmed_end];

    // Base64 decode: need to calculate actual output size
    // Pad the input if necessary to make it a multiple of 4
    const pad_len = (4 - (b64_data.len % 4)) % 4;
    const padded_len = b64_data.len + pad_len;
    const decoded_max = std.base64.standard.Encoder.calcSize(padded_len);
    const padded = try allocator.alloc(u8, padded_len);
    defer allocator.free(padded);
    @memcpy(padded, b64_data);
    for (0..pad_len) |i| {
        padded[b64_data.len + i] = '=';
    }

    const decoded = try allocator.alloc(u8, decoded_max);
    errdefer allocator.free(decoded);

    std.base64.standard.Decoder.decode(decoded, padded) catch {
        allocator.free(decoded);
        return error.InvalidPemFormat;
    };

    // Find actual decoded length by counting non-zero trailing bytes from the end
    var actual_len: usize = decoded_max;
    while (actual_len > 0 and decoded[actual_len - 1] == 0) {
        actual_len -= 1;
    }

    return decoded[0..actual_len];
}

/// Decode a PEM file containing multiple certificate blocks into a slice of DER byte slices.
pub fn pemToCertChain(allocator: std.mem.Allocator, pem: []const u8) ![][]const u8 {
    // Count certificates first
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, pem, search_from, "-----BEGIN CERTIFICATE-----")) |idx| {
        count += 1;
        search_from = idx + 1;
    }
    if (count == 0) return error.InvalidPemFormat;

    // Allocate array and parse each cert
    const certs = try allocator.alloc([]const u8, count);
    errdefer {
        for (certs) |c| allocator.free(c);
        allocator.free(certs);
    }

    search_from = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, pem, search_from, "-----BEGIN CERTIFICATE-----")) |begin_idx| {
        const end_marker = "-----END CERTIFICATE-----";
        const end_idx = std.mem.indexOfPos(u8, pem, begin_idx, end_marker) orelse return error.InvalidPemFormat;
        const after_end = end_idx + end_marker.len;
        const block = pem[begin_idx..after_end];
        certs[idx] = pemToDer(allocator, block) catch {
            // Free all previously allocated certs
            for (certs[0..idx]) |c| allocator.free(c);
            return error.InvalidPemFormat;
        };
        idx += 1;
        search_from = after_end;
    }

    return certs[0..idx];
}

/// Parse a PEM-encoded private key into a PrivateKey union.
pub fn parsePrivateKey(allocator: std.mem.Allocator, pem: []const u8) !tls.PrivateKey {
    const begin_marker = "-----BEGIN ";
    const boundary_end = "-----";

    const begin_idx = std.mem.indexOf(u8, pem, begin_marker) orelse return error.InvalidPemFormat;
    const label_start = begin_idx + begin_marker.len;
    const label_end = std.mem.indexOfPos(u8, pem, label_start, boundary_end) orelse return error.InvalidPemFormat;
    const label = pem[label_start..label_end];

    const der = pemToDer(allocator, pem) catch return error.InvalidPemFormat;
    errdefer allocator.free(der);

    const key = parsePrivateKeyDer(allocator, der) catch |e| {
        allocator.free(der);
        return e;
    };
    _ = label;
    return key;
}

/// Parse a DER-encoded private key into a PrivateKey union.
/// Supports: PKCS#8 (EC and RSA), SEC1 (EC), PKCS#1 (RSA).
pub fn parsePrivateKeyDer(allocator: std.mem.Allocator, der: []const u8) !tls.PrivateKey {
    // Determine key type from ASN.1 structure
    // PKCS#8: SEQUENCE { SEQUENCE { OID }, OCTET STRING { ... } }
    // SEC1: SEQUENCE { INTEGER, OCTET STRING { ... } } (EC specific)
    // PKCS#1 RSA: SEQUENCE { INTEGER (version), INTEGER (n), INTEGER (e), INTEGER (d), ... }

    if (isEcPrivateKey(der)) {
        return parseEcPrivateKey(allocator, der);
    } else if (isRsaPrivateKey(der)) {
        return parseRsaPrivateKey(allocator, der);
    } else if (isPkcs8(der)) {
        return parsePkcs8Key(allocator, der);
    }

    return error.UnsupportedKeyType;
}

/// Load a certificate chain from a file path.
pub fn loadCertChainFromFile(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    const pem = readTextFileAlloc(allocator, path, 1024 * 1024) catch return error.FileNotFound;
    defer allocator.free(pem);
    return pemToCertChain(allocator, pem);
}

/// Load a private key from a file path.
pub fn loadKeyFromFile(allocator: std.mem.Allocator, path: []const u8) !tls.PrivateKey {
    const content = readTextFileAlloc(allocator, path, 256 * 1024) catch return error.FileNotFound;
    defer allocator.free(content);
    return parsePrivateKey(allocator, content);
}

fn readTextFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_size)) catch |err| switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.StreamTooLong => error.InvalidPemFormat,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidPemFormat,
    };
}

// --- Internal helpers ---

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Detect SEC1 EC private key: SEQUENCE { INTEGER, OCTET STRING }
fn isEcPrivateKey(der: []const u8) bool {
    if (der.len < 2) return false;
    if (der[0] != 0x30) return false;

    // Parse outer SEQUENCE length
    const seq_len = readDerLength(der[1..]) orelse return false;
    if (1 + derLengthSize(der[1..]) + @as(usize, seq_len) != der.len) return false;

    // First element should be INTEGER (version, typically 1)
    const content_start = 1 + derLengthSize(der[1..]);
    if (content_start >= der.len or der[content_start] != 0x02) return false;

    // Second element should be OCTET STRING (the private key bytes)
    const int_len = readDerLength(der[content_start + 1 ..]) orelse return false;
    const int_end = content_start + 1 + derLengthSize(der[content_start + 1 ..]) + @as(usize, int_len);
    if (int_end >= der.len or der[int_end] != 0x04) return false;

    return true;
}

/// Detect PKCS#8: SEQUENCE { SEQUENCE { OID, ... }, OCTET STRING { ... } }
fn isPkcs8(der: []const u8) bool {
    if (der.len < 2) return false;
    if (der[0] != 0x30) return false;

    const content_start = 1 + derLengthSize(der[1..]);
    if (content_start >= der.len) return false;

    // First inner element: SEQUENCE (algorithm identifier)
    if (der[content_start] != 0x30) return false;

    // Second inner element: OCTET STRING (the private key)
    const inner_seq_len = readDerLength(der[content_start + 1 ..]) orelse return false;
    const inner_seq_end = content_start + 1 + derLengthSize(der[content_start + 1 ..]) + @as(usize, inner_seq_len);
    if (inner_seq_end >= der.len or der[inner_seq_end] != 0x04) return false;

    return true;
}

/// Detect PKCS#1 RSA private key: SEQUENCE { INTEGER, INTEGER, INTEGER, ... }
fn isRsaPrivateKey(der: []const u8) bool {
    if (der.len < 2) return false;
    if (der[0] != 0x30) return false;

    const content_start = 1 + derLengthSize(der[1..]);
    if (content_start >= der.len) return false;

    // First element should be INTEGER (version, typically 0)
    if (der[content_start] != 0x02) return false;

    // Look for the RSA OID 1.2.840.113549.1.1.1 in PKCS#8; for PKCS#1,
    // just having multiple INTEGERs and a large modulus is sufficient heuristic.
    // PKCS#1 RSA has: version, n, e, d, p, q, dp, dq, qi — at least 9 integers.
    var pos = content_start;
    var int_count: usize = 0;
    while (pos < der.len) {
        if (der[pos] != 0x02) break;
        const len = readDerLength(der[pos + 1 ..]) orelse break;
        pos += 1 + derLengthSize(der[pos + 1 ..]) + @as(usize, len);
        int_count += 1;
    }

    // RSA PKCS#1 has at least version + n + e + d = 4 integers
    return int_count >= 4;
}

fn parseEcPrivateKey(_: std.mem.Allocator, der: []const u8) !tls.PrivateKey {
    // Use std.crypto.Certificate's DER parser to extract the private key value
    // and the curve parameters (either from ECParameters or from public key)
    var content_start = 1 + derLengthSize(der[1..]);

    // Skip version INTEGER
    const int_len = readDerLength(der[content_start + 1 ..]) orelse return error.InvalidDerFormat;
    content_start += 1 + derLengthSize(der[content_start + 1 ..]) + @as(usize, int_len);

    // Read OCTET STRING containing the actual private key
    if (content_start >= der.len or der[content_start] != 0x04) return error.InvalidDerFormat;
    const priv_key_len = readDerLength(der[content_start + 1 ..]) orelse return error.InvalidDerFormat;
    content_start += 1 + derLengthSize(der[content_start + 1 ..]);

    if (content_start + priv_key_len > der.len) return error.InvalidDerFormat;
    const priv_key_bytes = der[content_start .. content_start + @as(usize, priv_key_len)];

    // Determine curve from key length
    // P-256: 32 bytes, P-384: 48 bytes, P-521: 66 bytes
    return switch (priv_key_bytes.len) {
        32 => {
            var key = tls.EcdsaP256Key{ .secret_key = undefined, .public_key = undefined };
            var scalar: [32]u8 = undefined;
            @memcpy(&scalar, priv_key_bytes);
            @memcpy(&key.secret_key, &scalar);
            // Derive public key from private key
            const pk = try std.crypto.ecc.P256.basePoint.mulPublic(scalar, .big);
            const affine = pk.affineCoordinates();
            key.public_key[0] = 0x04; // uncompressed point
            const x_bytes = std.crypto.ecc.P256.Fe.toBytes(affine.x, .big);
            const y_bytes = std.crypto.ecc.P256.Fe.toBytes(affine.y, .big);
            @memcpy(key.public_key[1..33], &x_bytes);
            @memcpy(key.public_key[33..65], &y_bytes);
            return .{ .ecdsa_p256 = key };
        },
        48 => {
            var key = tls.EcdsaP384Key{ .secret_key = undefined, .public_key = undefined };
            @memcpy(&key.secret_key, priv_key_bytes);
            return .{ .ecdsa_p384 = key };
        },
        else => error.UnsupportedCurve,
    };
}

fn parseRsaPrivateKey(allocator: std.mem.Allocator, der: []const u8) !tls.PrivateKey {
    // Parse PKCS#1 RSA: SEQUENCE { version, n, e, d, ... }
    var parser = DerParser.init(der);
    _ = try parser.readSequence(); // outer SEQUENCE
    _ = try parser.readInteger(); // version (typically 0)

    const n = try parser.readIntegerBytes(allocator);
    errdefer allocator.free(n);
    const e = try parser.readIntegerBytes(allocator);
    errdefer allocator.free(e);
    const d = try parser.readIntegerBytes(allocator);
    errdefer allocator.free(d);

    // Strip leading zero byte from unsigned integers if present
    const n_clean = stripLeadingZero(allocator, n) catch n;
    const e_clean = stripLeadingZero(allocator, e) catch e;
    const d_clean = stripLeadingZero(allocator, d) catch d;

    const bits = n_clean.len * 8;

    return .{ .rsa = .{
        .n = n_clean,
        .e = e_clean,
        .d = d_clean,
        .bits = bits,
    } };
}

fn parsePkcs8Key(allocator: std.mem.Allocator, der: []const u8) !tls.PrivateKey {
    // PKCS#8: SEQUENCE { algorithmIdentifier, OCTET STRING { privateKey } }
    var parser = DerParser.init(der);
    _ = try parser.readSequence(); // outer SEQUENCE

    // Parse algorithm identifier SEQUENCE
    _ = try parser.readSequence(); // inner SEQUENCE for algorithm
    // Read the OID to determine key type
    const oid_bytes = try parser.readOid();
    const algo_id_end = parser.pos;

    // Known OIDs:
    // EC: 1.2.840.10045.2.1
    // RSA: 1.2.840.113549.1.1.1
    // Ed25519: 1.3.101.112

    // Skip to the OCTET STRING
    parser.pos = algo_id_end;
    if (parser.pos >= der.len or der[parser.pos] != 0x04) return error.InvalidDerFormat;
    const octet_len = readDerLength(der[parser.pos + 1 ..]) orelse return error.InvalidDerFormat;
    parser.pos += 1 + derLengthSize(der[parser.pos + 1 ..]);
    if (parser.pos + octet_len > der.len) return error.InvalidDerFormat;
    const private_key_der = der[parser.pos .. parser.pos + @as(usize, octet_len)];

    const is_ec = std.mem.eql(u8, &[_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 }, oid_bytes) or
        std.mem.eql(u8, &[_]u8{ 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 }, oid_bytes);

    const is_rsa = std.mem.eql(u8, &[_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 }, oid_bytes) or
        std.mem.eql(u8, &[_]u8{ 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 }, oid_bytes);

    const is_ed25519 = std.mem.endsWith(u8, oid_bytes, &[_]u8{ 0x03, 0x01, 0x01, 0x70 }) or
        std.mem.eql(u8, &[_]u8{ 0x03, 0x01, 0x01, 0x70 }, oid_bytes) or
        std.mem.eql(u8, &[_]u8{ 0x06, 0x03, 0x2B, 0x65, 0x70 }, oid_bytes);

    if (is_ec) {
        // PKCS#8 EC: the OCTET STRING contains the raw private key scalar
        return switch (private_key_der.len) {
            32 => {
                var key = tls.EcdsaP256Key{ .secret_key = undefined, .public_key = undefined };
                var scalar: [32]u8 = undefined;
                @memcpy(&scalar, private_key_der);
                @memcpy(&key.secret_key, &scalar);
                const pk = try std.crypto.ecc.P256.basePoint.mulPublic(scalar, .big);
                const affine = pk.affineCoordinates();
                key.public_key[0] = 0x04;
                const x_bytes = std.crypto.ecc.P256.Fe.toBytes(affine.x, .big);
                const y_bytes = std.crypto.ecc.P256.Fe.toBytes(affine.y, .big);
                @memcpy(key.public_key[1..33], &x_bytes);
                @memcpy(key.public_key[33..65], &y_bytes);
                return .{ .ecdsa_p256 = key };
            },
            48 => {
                var key = tls.EcdsaP384Key{ .secret_key = undefined, .public_key = undefined };
                @memcpy(&key.secret_key, private_key_der);
                return .{ .ecdsa_p384 = key };
            },
            else => error.UnsupportedCurve,
        };
    } else if (is_rsa) {
        // PKCS#8 RSA: the OCTET STRING contains a PKCS#1 RSAPrivateKey
        return parseRsaPrivateKey(allocator, private_key_der);
    } else if (is_ed25519) {
        if (private_key_der.len != 32) return error.InvalidDerFormat;
        var seed: [32]u8 = undefined;
        @memcpy(&seed, private_key_der);
        const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        return .{ .ed25519 = .{ .key_pair = key_pair } };
    }

    return error.UnsupportedKeyType;
}

fn stripLeadingZero(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (bytes.len > 0 and bytes[0] == 0) {
        const stripped = bytes[1..];
        const duped = try allocator.dupe(u8, stripped);
        return duped;
    }
    return bytes;
}

fn readDerLength(data: []const u8) ?u64 {
    if (data.len == 0) return null;
    const first = data[0];
    if (first < 0x80) return first;
    const num_bytes = first & 0x7f;
    if (num_bytes == 0 or data.len < 1 + num_bytes) return null;
    var result: u64 = 0;
    for (1..1 + num_bytes) |i| {
        result = (result << 8) | data[i];
    }
    return result;
}

fn derLengthSize(data: []const u8) usize {
    if (data.len == 0) return 0;
    const first = data[0];
    if (first < 0x80) return 1;
    return 1 + (first & 0x7f);
}

/// Simple DER parser for extracting structured elements.
const DerParser = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) DerParser {
        return .{ .data = data, .pos = 0 };
    }

    fn readSequence(self: *DerParser) !void {
        if (self.pos >= self.data.len or self.data[self.pos] != 0x30)
            return error.InvalidDerFormat;
        const len = readDerLength(self.data[self.pos + 1 ..]) orelse return error.InvalidDerFormat;
        self.pos += 1 + derLengthSize(self.data[self.pos + 1 ..]) + @as(usize, len);
    }

    fn readInteger(self: *DerParser) !void {
        if (self.pos >= self.data.len or self.data[self.pos] != 0x02)
            return error.InvalidDerFormat;
        const len = readDerLength(self.data[self.pos + 1 ..]) orelse return error.InvalidDerFormat;
        self.pos += 1 + derLengthSize(self.data[self.pos + 1 ..]) + @as(usize, len);
    }

    fn readIntegerBytes(self: *DerParser, allocator: std.mem.Allocator) ![]const u8 {
        if (self.pos >= self.data.len or self.data[self.pos] != 0x02)
            return error.InvalidDerFormat;
        const len = readDerLength(self.data[self.pos + 1 ..]) orelse return error.InvalidDerFormat;
        const size = derLengthSize(self.data[self.pos + 1 ..]);
        const data_start = self.pos + 1 + size;
        self.pos = data_start + @as(usize, len);
        if (self.pos > self.data.len) return error.InvalidDerFormat;
        return allocator.dupe(u8, self.data[data_start..self.pos]);
    }

    fn readOid(self: *DerParser) ![]const u8 {
        if (self.pos >= self.data.len or self.data[self.pos] != 0x06)
            return error.InvalidDerFormat;
        const len = readDerLength(self.data[self.pos + 1 ..]) orelse return error.InvalidDerFormat;
        const size = derLengthSize(self.data[self.pos + 1 ..]);
        const data_start = self.pos + 1 + size;
        self.pos = data_start + @as(usize, len);
        if (self.pos > self.data.len) return error.InvalidDerFormat;
        return self.data[data_start..self.pos];
    }
};

// --- Tests ---

test "pemToDer decodes valid PEM certificate" {
    const pem =
        "-----BEGIN CERTIFICATE-----\n" ++
        "MIIBkTCB+wIJAKHBfpegKBS5MA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBnRl\n" ++
        "c3RjYTAeFw0yNDAxMDEwMDAwMDBaFw0yNTAxMDEwMDAwMDBaMBExDzANBgNVBAMM\n" ++
        "BnRlc3RjYTBcMA0GCSqGSIb3DQEBAQUAA0sAMEgCQQC7o94RNsYJGBwQ5HhCXPLk\n" ++
        "fXvJR0qJP5XEPQM0mOELpRGpY4GmVBqKR0m7P9/e5TyvwNGtF5CPsPQDiWPj0Lt7\n" ++
        "AgMBAAEwDQYJKoZIhvcNAQELBQADQQBtFbPHx0sSuJszXXxnN9GZOgOJVqtZnVHe\n" ++
        "OmS0oPzL5n8TRdDjpG0SV8ZpY8F4lPVzPY3NJKMIvS6dGH7pNQ7\n" ++
        "-----END CERTIFICATE-----\n";

    const allocator = std.testing.allocator;
    const der = try pemToDer(allocator, pem);
    defer allocator.free(der);

    try std.testing.expect(der.len > 0);
    try std.testing.expect(der[0] == 0x30); // ASN.1 SEQUENCE
}

test "pemToCertChain decodes multiple certificates" {
    const cert1 =
        "-----BEGIN CERTIFICATE-----\n" ++
        "MIIBkTCB+wIJAKHBfpegKBS5MA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBnRl\n" ++
        "c3RjYTAeFw0yNDAxMDEwMDAwMDBaFw0yNTAxMDEwMDAwMDBaMBExDzANBgNVBAMM\n" ++
        "BnRlc3RjYTBcMA0GCSqGSIb3DQEBAQUAA0sAMEgCQQC7o94RNsYJGBwQ5HhCXPLk\n" ++
        "fXvJR0qJP5XEPQM0mOELpRGpY4GmVBqKR0m7P9/e5TyvwNGtF5CPsPQDiWPj0Lt7\n" ++
        "AgMBAAEwDQYJKoZIhvcNAQELBQADQQBtFbPHx0sSuJszXXxnN9GZOgOJVqtZnVHe\n" ++
        "OmS0oPzL5n8TRdDjpG0SV8ZpY8F4lPVzPY3NJKMIvS6dGH7pNQ7\n" ++
        "-----END CERTIFICATE-----\n";

    const cert2 =
        "-----BEGIN CERTIFICATE-----\n" ++
        "MIIBkTCB+wIJAJbVF3GPtCjRMA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBmNh\n" ++
        "Y2EwHhcNMjQwMTAxMDAwMDAwWhcNMjUwMTAxMDAwMDAwWjARMQ8wDQYDVQQDDAZj\n" ++
        "YWNhMFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBALLpEtXPN2SiQ5Hp9RbFSmGQ0YqX\n" ++
        "WPGpEHfSLQDrCbQ/JMSQn8mqZqGZrMbVKSJGMGdTZFeNGkVf4YZcX7m0CAwEAATAN\n" ++
        "BgkqhkiG9w0BAQsFAANBAJlmHmGKPNpR9lFhFJcCBQGWP4gXfONpVJ0ChnRqkLgE\n" ++
        "wY6rVnJpK8Pq5R3V9n5dMnRTY7GWT+H2Z9NjFzDXk=\n" ++
        "-----END CERTIFICATE-----\n";

    const allocator = std.testing.allocator;
    const chain = try pemToCertChain(allocator, cert1 ++ cert2);
    defer {
        for (chain) |c| allocator.free(c);
        allocator.free(chain);
    }

    try std.testing.expectEqual(@as(usize, 2), chain.len);
}

test "pemToDer rejects invalid PEM" {
    const allocator = std.testing.allocator;
    const result = pemToDer(allocator, "not a valid pem");
    try std.testing.expectError(error.InvalidPemFormat, result);
}

test "pemToCertChain rejects empty PEM" {
    const allocator = std.testing.allocator;
    const result = pemToCertChain(allocator, "");
    try std.testing.expectError(error.InvalidPemFormat, result);
}
