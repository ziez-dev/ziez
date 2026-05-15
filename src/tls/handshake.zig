const std = @import("std");
const tls_lib = std.crypto.tls;
const Certificate = std.crypto.Certificate;

/// Parsed ClientHello message.
pub const ClientHello = struct {
    /// Legacy version field (always 0x0303 for TLS 1.3).
    legacy_version: u16,
    /// Client random (32 bytes).
    random: [32]u8,
    /// Legacy session ID.
    session_id: []const u8,
    /// Offered cipher suites (u16 values).
    cipher_suites: []const u16,
    /// Supported TLS versions (from supported_versions extension).
    supported_versions: []const u16,
    /// Key share entries from the key_share extension.
    key_shares: []KeyShareEntry,
    /// Signature algorithms from the signature_algorithms extension.
    signature_algorithms: []const u16,
    /// Server Name Indication hostname (if present).
    sni: ?[]const u8,
    /// Raw buffer for the handshake message (for transcript hashing).
    wrapped_message: []const u8,
    /// Buffer that owns key_share data.
    key_share_buf: []const u8,

    pub fn deinit(self: *ClientHello, allocator: std.mem.Allocator) void {
        if (self.key_share_buf.len > 0) allocator.free(self.key_share_buf);
    }
};

pub const KeyShareEntry = struct {
    group: u16,
    public_key: []const u8,
};

/// Parse a ClientHello handshake message from raw bytes.
/// The decoder should be positioned at the start of the ClientHello content
/// (after the HandshakeType and length fields).
pub fn parseClientHello(decoder: *tls_lib.Decoder, wrapped_message: []const u8, allocator: std.mem.Allocator) !ClientHello {
    var result = ClientHello{
        .legacy_version = undefined,
        .random = undefined,
        .session_id = &.{},
        .cipher_suites = &.{},
        .supported_versions = &.{},
        .key_shares = &.{},
        .signature_algorithms = &.{},
        .sni = null,
        .wrapped_message = wrapped_message,
        .key_share_buf = &.{},
    };

    // legacy_version
    try decoder.ensure(2);
    result.legacy_version = decoder.decode(u16);

    // random (32 bytes)
    try decoder.ensure(32);
    const random_bytes = decoder.array(32);
    for (0..32) |i| {
        result.random[i] = random_bytes[i];
    }

    // legacy_session_id
    try decoder.ensure(1);
    const session_id_len = decoder.decode(u8);
    try decoder.ensure(session_id_len);
    result.session_id = decoder.slice(session_id_len);

    // cipher_suites (each suite is 2 bytes)
    try decoder.ensure(2);
    const cipher_suites_len = decoder.decode(u16);
    try decoder.ensure(cipher_suites_len);
    const num_suites = cipher_suites_len / 2;
    const suites_buf = try allocator.alloc(u16, num_suites);
    for (0..num_suites) |i| {
        suites_buf[i] = std.mem.readInt(u16, decoder.buf[decoder.idx + i * 2 ..][0..2], .big);
    }
    result.cipher_suites = suites_buf;
    decoder.idx += cipher_suites_len;

    // legacy_compression_methods
    try decoder.ensure(2);
    const compression_len = decoder.decode(u8);
    try decoder.ensure(compression_len);
    decoder.idx += compression_len;

    // extensions
    try decoder.ensure(2);
    const extensions_len = decoder.decode(u16);
    const extensions_end = decoder.idx + extensions_len;

    // Temporary storage for key shares
    var key_shares = std.ArrayList(KeyShareEntry).empty;
    errdefer key_shares.deinit(allocator);

    while (decoder.idx < extensions_end) {
        try decoder.ensure(4);
        const ext_type = decoder.decode(u16);
        const ext_len = decoder.decode(u16);
        const ext_end = decoder.idx + ext_len;

        switch (ext_type) {
            // supported_versions
            0x002b => {
                try decoder.ensure(1);
                const list_len = decoder.decode(u8);
                try decoder.ensure(list_len);
                const num_ver = list_len / 2;
                const ver_buf = try allocator.alloc(u16, num_ver);
                for (0..num_ver) |i| {
                    ver_buf[i] = std.mem.readInt(u16, decoder.buf[decoder.idx + i * 2 ..][0..2], .big);
                }
                result.supported_versions = ver_buf;
                decoder.idx += list_len;
            },
            // signature_algorithms
            0x000d => {
                try decoder.ensure(2);
                const list_len = decoder.decode(u16);
                try decoder.ensure(list_len);
                const num_sig = list_len / 2;
                const sig_buf = try allocator.alloc(u16, num_sig);
                for (0..num_sig) |i| {
                    sig_buf[i] = std.mem.readInt(u16, decoder.buf[decoder.idx + i * 2 ..][0..2], .big);
                }
                result.signature_algorithms = sig_buf;
                decoder.idx += list_len;
            },
            // key_share
            0x0033 => {
                try decoder.ensure(2);
                const shares_len = decoder.decode(u16);
                const shares_end = decoder.idx + shares_len;
                while (decoder.idx < shares_end) {
                    try decoder.ensure(4);
                    const group = decoder.decode(u16);
                    const key_len = decoder.decode(u16);
                    try decoder.ensure(key_len);
                    const pub_key = decoder.buf[decoder.idx .. decoder.idx + key_len];
                    decoder.idx += key_len;
                    try key_shares.append(allocator, .{ .group = group, .public_key = pub_key });
                }
                decoder.idx = shares_end;
            },
            // server_name (SNI)
            0x0000 => {
                try decoder.ensure(2);
                _ = decoder.decode(u16); // sni_list_len
                try decoder.ensure(2);
                _ = decoder.decode(u8); // name_type
                const name_len = decoder.decode(u16);
                try decoder.ensure(name_len);
                result.sni = decoder.buf[decoder.idx .. decoder.idx + name_len];
                decoder.idx += name_len;
                // Skip to ext_end to handle padding
                decoder.idx = ext_end;
            },
            else => {
                decoder.idx = ext_end;
            },
        }

        if (decoder.idx != ext_end) decoder.idx = ext_end;
    }

    // Store key shares data
    if (key_shares.items.len > 0) {
        // The key_shares point into the decoder buffer, which is valid for the handshake
        result.key_shares = key_shares.items;
    }

    return result;
}

/// Check if the client supports TLS 1.3.
pub fn supportsTls13(ch: *const ClientHello) bool {
    const tls_1_3: u16 = 0x0304;
    for (ch.supported_versions) |v| {
        if (v == tls_1_3) return true;
    }
    return false;
}

/// Find a matching cipher suite between client and server preferences.
pub fn negotiateCipherSuite(ch: *const ClientHello, server_suites: []const u16) ?u16 {
    for (server_suites) |ss| {
        for (ch.cipher_suites) |cs| {
            if (cs == ss) return cs;
        }
    }
    return null;
}

/// Find a supported key share group.
pub fn findKeyShare(ch: *const ClientHello, supported_groups: []const u16) ?KeyShareEntry {
    for (supported_groups) |sg| {
        for (ch.key_shares) |*ks| {
            if (ks.group == sg) return ks.*;
        }
    }
    return null;
}

/// Find a matching signature algorithm.
pub fn findSignatureAlgorithm(ch: *const ClientHello, server_algos: []const u16) ?u16 {
    for (server_algos) |sa| {
        for (ch.signature_algorithms) |ca| {
            if (ca == sa) return ca;
        }
    }
    return null;
}

/// Build a ServerHello message.
/// Returns the complete handshake record (type + length + content).
pub fn buildServerHello(
    server_random: [32]u8,
    session_id: []const u8,
    cipher_suite: u16,
    key_share_group: u16,
    key_share_pubkey: []const u8,
    buf: []u8,
) []u8 {
    const supported_versions_ext = [_]u8{
        0x00, 0x2b, // ExtensionType: supported_versions
        0x00, 0x02, // length
        0x02, // list length
        0x03, 0x04, // TLS 1.3
    };
    const key_share_ext_len: u16 = 2 + 4 + @as(u16, @intCast(key_share_pubkey.len));
    const extensions_len: u16 = @intCast(supported_versions_ext.len + 4 + key_share_ext_len);
    const content_len: u24 = @intCast(2 + 32 + 1 + session_id.len + 2 + 1 + 2 + 2 + extensions_len);

    const msg = buf;
    var pos: usize = 0;

    // HandshakeType.server_hello
    msg[pos] = 0x02;
    pos += 1;
    // Length (u24)
    std.mem.writeInt(u24, msg[pos..][0..3], content_len, .big);
    pos += 3;
    // legacy_version = TLS 1.2 (0x0303) for compat
    std.mem.writeInt(u16, msg[pos..][0..2], 0x0303, .big);
    pos += 2;
    // random
    @memcpy(msg[pos..][0..32], &server_random);
    pos += 32;
    // session_id
    msg[pos] = @intCast(session_id.len);
    pos += 1;
    @memcpy(msg[pos..][0..session_id.len], session_id);
    pos += session_id.len;
    // cipher_suite
    std.mem.writeInt(u16, msg[pos..][0..2], cipher_suite, .big);
    pos += 2;
    // compression_method = null
    msg[pos] = 0;
    pos += 1;
    // extensions length
    std.mem.writeInt(u16, msg[pos..][0..2], extensions_len, .big);
    pos += 2;
    // supported_versions extension
    @memcpy(msg[pos..][0..supported_versions_ext.len], &supported_versions_ext);
    pos += supported_versions_ext.len;
    // key_share extension header
    std.mem.writeInt(u16, msg[pos..][0..2], 0x0033, .big); // ExtensionType: key_share
    pos += 2;
    std.mem.writeInt(u16, msg[pos..][0..2], key_share_ext_len, .big); // length
    pos += 2;
    // key_share entry
    std.mem.writeInt(u16, msg[pos..][0..2], key_share_ext_len - 2, .big); // client_shares_length
    pos += 2;
    std.mem.writeInt(u16, msg[pos..][0..2], key_share_group, .big); // group
    pos += 2;
    std.mem.writeInt(u16, msg[pos..][0..2], @intCast(key_share_pubkey.len), .big); // key_exchange length
    pos += 2;
    @memcpy(msg[pos..][0..key_share_pubkey.len], key_share_pubkey);
    pos += key_share_pubkey.len;

    return msg[0..pos];
}

/// Build a TLS record header wrapping the given content into buf.
pub fn wrapRecord(content_type: u8, content: []const u8, buf: []u8) []u8 {
    buf[0] = content_type;
    std.mem.writeInt(u16, buf[1..3], 0x0303, .big); // legacy_version TLS 1.2
    std.mem.writeInt(u16, buf[3..5], @intCast(content.len), .big);
    @memcpy(buf[5..][0..content.len], content);
    return buf[0 .. 5 + content.len];
}

const builtin_endian = @import("builtin").cpu.arch.endian();
