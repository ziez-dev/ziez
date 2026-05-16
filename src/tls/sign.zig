const std = @import("std");
const tls = @import("mod.zig");
const rsa_sign = @import("rsa_sign.zig");

const SignatureScheme = std.crypto.tls.SignatureScheme;

/// Sign a message hash using the server's private key with the given signature scheme.
/// Returns the DER-encoded signature. Caller must free the returned slice.
pub fn sign(
    allocator: std.mem.Allocator,
    key: *const tls.PrivateKey,
    scheme: SignatureScheme,
    msg_hash: []const u8,
) ![]const u8 {
    switch (scheme) {
        // RSA PKCS#1 v1.5
        .rsa_pkcs1_sha256 => return rsa_sign.pkcs1v15Sign(allocator, msg_hash, &key.rsa, std.crypto.hash.sha2.Sha256),
        .rsa_pkcs1_sha384 => return rsa_sign.pkcs1v15Sign(allocator, msg_hash, &key.rsa, std.crypto.hash.sha2.Sha384),
        .rsa_pkcs1_sha512 => return rsa_sign.pkcs1v15Sign(allocator, msg_hash, &key.rsa, std.crypto.hash.sha2.Sha512),

        // RSA PSS
        .rsa_pss_rsae_sha256 => return rsa_sign.pssSign(allocator, msg_hash, &key.rsa, std.crypto.hash.sha2.Sha256),
        .rsa_pss_rsae_sha384 => return rsa_sign.pssSign(allocator, msg_hash, &key.rsa, std.crypto.hash.sha2.Sha384),
        .rsa_pss_rsae_sha512 => return rsa_sign.pssSign(allocator, msg_hash, &key.rsa, std.crypto.hash.sha2.Sha512),

        // ECDSA
        .ecdsa_secp256r1_sha256 => return signEcdsa(allocator, &key.ecdsa_p256, msg_hash, 32),
        .ecdsa_secp384r1_sha384 => return signEcdsaP384(allocator, &key.ecdsa_p384, 48),

        // Ed25519
        .ed25519 => return signEd25519(allocator, &key.ed25519, msg_hash),

        // Unsupported schemes
        else => return error.UnsupportedSignatureScheme,
    }
}

/// Get the default signature scheme for a given key type.
pub fn defaultScheme(key: *const tls.PrivateKey) ?SignatureScheme {
    return switch (key.*) {
        .ecdsa_p256 => .ecdsa_secp256r1_sha256,
        .ecdsa_p384 => .ecdsa_secp384r1_sha384,
        .ed25519 => .ed25519,
        .rsa => .rsa_pkcs1_sha256,
    };
}

/// Get the hash algorithm associated with a signature scheme.
pub fn schemeHash(scheme: SignatureScheme) ?type {
    return switch (scheme) {
        .rsa_pkcs1_sha256, .rsa_pss_rsae_sha256, .ecdsa_secp256r1_sha256 => std.crypto.hash.sha2.Sha256,
        .rsa_pkcs1_sha384, .rsa_pss_rsae_sha384, .ecdsa_secp384r1_sha384 => std.crypto.hash.sha2.Sha384,
        .rsa_pkcs1_sha512, .rsa_pss_rsae_sha512 => std.crypto.hash.sha2.Sha512,
        .ed25519 => std.crypto.hash.sha2.Sha512,
        else => null,
    };
}

fn signEcdsa(
    allocator: std.mem.Allocator,
    key: *const tls.EcdsaP256Key,
    msg_hash: []const u8,
    expected_hash_len: usize,
) ![]const u8 {
    if (msg_hash.len != expected_hash_len) return error.InvalidHashLength;

    const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const secret_key = EcdsaP256.SecretKey{ .bytes = key.secret_key };
    const public_key = EcdsaP256.PublicKey{
        .p = std.crypto.ecc.P256.fromSec1(&key.public_key) catch return error.InvalidKey,
    };
    const kp = EcdsaP256.KeyPair{ .secret_key = secret_key, .public_key = public_key };

    const sig = kp.sign(msg_hash, null) catch return error.InvalidKey;
    var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
    const der = sig.toDer(&der_buf);

    return allocator.dupe(u8, der);
}

fn signEcdsaP384(
    allocator: std.mem.Allocator,
    key: *const tls.EcdsaP384Key,
    expected_hash_len: usize,
) ![]const u8 {
    _ = key;
    _ = expected_hash_len;
    _ = allocator;
    // ECDSA P-384 requires a separate signing implementation.
    // The stdlib currently only provides built-in P256 signing.
    return error.NotImplemented;
}

fn signEd25519(
    allocator: std.mem.Allocator,
    key: *const tls.Ed25519Key,
    msg_hash: []const u8,
) ![]const u8 {
    const sig = key.key_pair.sign(msg_hash, null) catch return error.InvalidKey;
    const result = try allocator.alloc(u8, 64);
    @memcpy(result, &sig.toBytes());
    return result;
}

fn writeDerLength(buf: []u8, len: usize) usize {
    if (len < 0x80) {
        buf[0] = @intCast(len);
        return 1;
    }
    // Long form: count needed bytes
    var tmp = len;
    var num_bytes: u8 = 0;
    while (tmp > 0) : (tmp >>= 8) {
        num_bytes += 1;
    }
    buf[0] = 0x80 | num_bytes;
    var pos: usize = 1;
    tmp = len;
    var i: u8 = num_bytes;
    while (i > 0) : (i -= 1) {
        buf[pos] = @intCast((tmp >> (@as(usize, i - 1) * 8)) & 0xFF);
        pos += 1;
    }
    return pos;
}

test "defaultScheme returns correct scheme for each key type" {
    const ecdsa_key = tls.EcdsaP256Key{ .secret_key = [_]u8{0} ** 32, .public_key = [_]u8{0} ** 65 };
    const ecdsa_pk: tls.PrivateKey = .{ .ecdsa_p256 = ecdsa_key };
    try std.testing.expectEqual(SignatureScheme.ecdsa_secp256r1_sha256, defaultScheme(&ecdsa_pk).?);

    const ed_key = tls.Ed25519Key{ .key_pair = undefined };
    const ed_pk: tls.PrivateKey = .{ .ed25519 = ed_key };
    try std.testing.expectEqual(SignatureScheme.ed25519, defaultScheme(&ed_pk).?);

    const rsa_pk: tls.PrivateKey = .{ .rsa = .{} };
    try std.testing.expectEqual(SignatureScheme.rsa_pkcs1_sha256, defaultScheme(&rsa_pk).?);
}

test "schemeHash returns correct hash type" {
    try std.testing.expectEqual(std.crypto.hash.sha2.Sha256, schemeHash(.rsa_pkcs1_sha256).?);
    try std.testing.expectEqual(std.crypto.hash.sha2.Sha384, schemeHash(.ecdsa_secp384r1_sha384).?);
    try std.testing.expect(std.meta.eql(std.crypto.hash.sha2.Sha512, schemeHash(.ed25519).?));
    try std.testing.expect(schemeHash(.rsa_pkcs1_sha1) == null);
}
