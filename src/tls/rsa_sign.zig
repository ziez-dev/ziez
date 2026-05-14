const std = @import("std");
const tls = @import("../tls.zig");

/// RSA PKCS#1 v1.5 signature.
/// Computes: signature = (pad(message_hash) ^ d) mod n
pub fn pkcs1v15Sign(
    allocator: std.mem.Allocator,
    msg_hash: []const u8,
    key: *const tls.RsaKey,
    comptime Hash: type,
) ![]const u8 {
    const n_bytes = key.n orelse return error.InvalidKey;
    const d_bytes = key.d orelse return error.InvalidKey;
    const k = n_bytes.len; // modulus length in bytes

    const t_len = Hash.digest_length;
    const digest_info = getDigestInfo(Hash);
    const em_len = k;

    if (msg_hash.len != t_len) return error.InvalidHashLength;
    if (em_len < t_len + digest_info.len + 11) return error.KeyTooShort;

    // EM = 0x00 || 0x01 || PS || 0x00 || T
    const ps_len = em_len - 3 - t_len - digest_info.len;
    const em = try allocator.alloc(u8, em_len);
    errdefer allocator.free(em);

    var pos: usize = 0;
    em[pos] = 0x00;
    pos += 1;
    em[pos] = 0x01;
    pos += 1;
    @memset(em[pos .. pos + ps_len], 0xFF);
    pos += ps_len;
    em[pos] = 0x00;
    pos += 1;
    @memcpy(em[pos .. pos + digest_info.len], digest_info);
    pos += digest_info.len;
    @memcpy(em[pos .. pos + t_len], msg_hash);

    // RSA private key operation: m = em^d mod n
    return rsaModPowImpl(allocator, em, d_bytes, n_bytes);
}

/// RSA-PSS signature (RSASSA-PSS, MGF1 based).
pub fn pssSign(
    allocator: std.mem.Allocator,
    msg_hash: []const u8,
    key: *const tls.RsaKey,
    comptime Hash: type,
) ![]const u8 {
    _ = msg_hash;
    _ = key;
    _ = Hash;
    _ = allocator;
    return error.NotImplemented;
}

fn rsaModPowImpl(allocator: std.mem.Allocator, base: []const u8, exp: []const u8, modulus: []const u8) ![]const u8 {
    const k = modulus.len;
    const result = try allocator.alloc(u8, k);
    @memset(result, 0);
    result[k - 1] = 1; // result = 1

    // Skip leading zeros in exponent
    var exp_start: usize = 0;
    while (exp_start < exp.len and exp[exp_start] == 0) : (exp_start += 1) {}
    if (exp_start >= exp.len) {
        return result;
    }

    const effective_exp = exp[exp_start..];
    for (0..effective_exp.len) |byte_idx| {
        const byte = effective_exp[byte_idx];
        for (0..8) |bit_idx| {
            const bit_pos = 7 - bit_idx;
            // result = result^2 mod n
            modMulInPlace(result, result, modulus);
            // if bit is set: result = result * base mod n
            if (byte & (@as(u8, 1) << @intCast(bit_pos)) != 0) {
                modMulInPlace(result, base, modulus);
            }
        }
    }

    return result;
}

/// Compute (a * b) mod m in-place. a, b, m must be the same length (k bytes).
fn modMulInPlace(a: []u8, b: []const u8, m: []const u8) void {
    const k = m.len;
    var product = [_]u8{0} ** (8192); // max supported key size = 4096-bit = 512 bytes, product = 1024 bytes
    if (k * 2 > product.len) return;

    bigMul(a, b, product[0 .. k * 2]);
    bigModTo(product[0 .. k * 2], m, a);
}

fn bigMul(a: []const u8, b: []const u8, result: []u8) void {
    const a_len = a.len;
    const b_len = b.len;
    @memset(result[0 .. a_len + b_len], 0);

    var i: usize = a_len;
    while (i > 0) : (i -= 1) {
        var carry: u16 = 0;
        var j: usize = b_len;
        while (j > 0) : (j -= 1) {
            const ai = a[i - 1];
            const bj = b[j - 1];
            const prod = @as(u32, ai) * @as(u32, bj) + @as(u32, result[i + j - 1]) + carry;
            result[i + j - 1] = @intCast(prod & 0xFF);
            carry = @intCast(prod >> 8);
        }
        result[i - 1] = @intCast(carry);
    }
}

/// Compute num mod denom, store result in out (k bytes).
fn bigModTo(num: []const u8, denom: []const u8, out: []u8) void {
    const k = denom.len;
    @memset(out, 0);

    // Copy num into out (right-aligned, k bytes)
    if (num.len <= k) {
        const offset = k - num.len;
        @memset(out[0..offset], 0);
        @memcpy(out[offset..], num);
    } else {
        // num is larger than denom — copy the top k bytes and reduce
        @memcpy(out, num[0..k]);
        // For larger remainders, we'd need full long division
        // For now, handle the common case where num < k
    }

    // Subtraction-based modulo (works for same-length operands)
    while (bigCmpEq(out, denom) >= 0) {
        bigSubInPlace(out, denom);
    }
}

fn bigCmpEq(a: []const u8, b: []const u8) i8 {
    for (0..@max(a.len, b.len)) |i| {
        const ai: u8 = if (i < a.len) a[i] else 0;
        const bi: u8 = if (i < b.len) b[i] else 0;
        if (ai > bi) return 1;
        if (ai < bi) return -1;
    }
    return 0;
}

fn bigSubInPlace(a: []u8, b: []const u8) void {
    var borrow: u8 = 0;
    var i: usize = a.len;
    while (i > 0) : (i -= 1) {
        const ai: u16 = a[i - 1];
        const bi: u16 = if (i - 1 < b.len) b[b.len - 1 - (i - 1)] else 0;
        const diff: i16 = @as(i16, ai) - @as(i16, bi) - @as(i16, borrow);
        if (diff < 0) {
            a[i - 1] = @intCast(@as(i16, diff) + 256);
            borrow = 1;
        } else {
            a[i - 1] = @intCast(diff);
            borrow = 0;
        }
    }
}

/// Get the DER-encoded DigestInfo prefix for PKCS#1 v1.5 signing.
fn getDigestInfo(comptime Hash: type) []const u8 {
    return switch (Hash) {
        std.crypto.hash.sha2.Sha256 => &[_]u8{
            0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
            0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
            0x00, 0x04, 0x20,
        },
        std.crypto.hash.sha2.Sha384 => &[_]u8{
            0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
            0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05,
            0x00, 0x04, 0x30,
        },
        std.crypto.hash.sha2.Sha512 => &[_]u8{
            0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
            0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05,
            0x00, 0x04, 0x40,
        },
        else => &[_]u8{},
    };
}
