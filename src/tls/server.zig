const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;

const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;

const TlsConfig = @import("mod.zig");
const handshake_mod = @import("handshake.zig");
const sign_mod = @import("sign.zig");

const hkdfExpandLabel = tls.hkdfExpandLabel;
const hmacExpandLabel = tls.hmacExpandLabel;
const hmac = tls.hmac;
const emptyHash = tls.emptyHash;
const int = tls.int;

pub const Server = struct {
    /// The encrypted stream from the client. Bytes are pulled here via `input`.
    input: *std.Io.Reader,
    /// Decrypted stream from the client.
    reader: std.Io.Reader,
    /// The encrypted stream to the client. Bytes are pushed here via `output`.
    output: *std.Io.Writer,
    /// Plaintext stream to the client.
    writer: std.Io.Writer,

    alert: ?tls.Alert = null,
    tls_version: tls.ProtocolVersion,
    read_seq: u64,
    write_seq: u64,
    received_close_notify: bool,
    application_cipher: tls.ApplicationCipher,

    /// Negotiated SNI hostname (if any).
    sni_hostname: ?[]const u8 = null,

    /// Client certificate info (mTLS, if verified).
    client_cert_parsed: ?Certificate.Parsed = null,

    pub const ReadError = error{
        TlsAlert,
        TlsBadLength,
        TlsBadRecordMac,
        TlsConnectionTruncated,
        TlsDecodeError,
        TlsRecordOverflow,
        TlsUnexpectedMessage,
        TlsIllegalParameter,
        TlsSequenceOverflow,
    };

    pub const InitError = error{
        TlsAlert,
        TlsUnexpectedMessage,
        TlsIllegalParameter,
        TlsDecryptFailure,
        TlsRecordOverflow,
        TlsBadRecordMac,
        TlsDecodeError,
        TlsNoMatchingCipherSuite,
        TlsNoMatchingKeyShare,
        TlsNoMatchingSignatureScheme,
        TlsBadCertificate,
        TlsCertificateRequired,
        InsufficientEntropy,
        TlsNotSupported,
        TlsConnectionTruncated,
    } || std.Io.Writer.Error || std.Io.Reader.ShortError || std.Io.Cancelable;

    pub const Options = struct {
        tls_context: *TlsConfig.TlsContext,
        write_buffer: []u8,
        read_buffer: []u8,
        entropy: *const [entropy_len]u8,
        realtime_now: std.Io.Timestamp,
    };

    pub const entropy_len = 64;

    pub const min_buffer_len = tls.max_ciphertext_record_len;

    /// Perform a TLS 1.3 handshake.
    /// After successful return, use `reader` and `writer` for application data.
    pub fn init(input: *std.Io.Reader, output: *std.Io.Writer, options: Options) InitError!Server {
        if (input.buffer.len < min_buffer_len or output.buffer.len < min_buffer_len)
            return error.TlsRecordOverflow;

        // Read the ClientHello record
        input.rebase(tls.max_ciphertext_record_len) catch |err| switch (err) {
            error.EndOfStream => return error.TlsConnectionTruncated,
            error.ReadFailed => |e| return e,
        };

        // Peek at record header to read content type
        _ = input.peek(tls.record_header_len) catch |err| switch (err) {
            error.EndOfStream => return error.TlsConnectionTruncated,
            error.ReadFailed => |e| return e,
        };

        const record_ct = input.takeEnumNonexhaustive(tls.ContentType, .big) catch unreachable;
        if (record_ct != .handshake) return error.TlsUnexpectedMessage;
        input.toss(2); // legacy_version
        const record_len = input.takeInt(u16, .big) catch unreachable;
        if (record_len > tls.max_ciphertext_len) return error.TlsRecordOverflow;
        const record_buffer = input.take(record_len) catch |err| switch (err) {
            error.EndOfStream => return error.TlsConnectionTruncated,
            error.ReadFailed => |e| return e,
        };

        var record_decoder = tls.Decoder.fromTheirSlice(record_buffer);

        // Parse handshake header
        record_decoder.ensure(4) catch return error.TlsDecodeError;
        const hs_type = record_decoder.decode(tls.HandshakeType);
        if (hs_type != .client_hello) return error.TlsUnexpectedMessage;
        const hs_len = record_decoder.decode(u24);
        var hsd = record_decoder.sub(hs_len) catch return error.TlsDecodeError;

        // Parse ClientHello
        const allocator = options.tls_context.allocator;
        var client_hello = handshake_mod.parseClientHello(&hsd, record_buffer, allocator) catch
            return error.TlsDecodeError;
        defer client_hello.deinit(allocator);

        // Check TLS 1.3 support
        if (!handshake_mod.supportsTls13(&client_hello)) return error.TlsNotSupported;

        // Negotiate cipher suite
        const server_suite_values = comptime_values: {
            var vals: [3]u16 = undefined;
            vals[0] = @intFromEnum(tls.CipherSuite.AES_128_GCM_SHA256);
            vals[1] = @intFromEnum(tls.CipherSuite.CHACHA20_POLY1305_SHA256);
            vals[2] = @intFromEnum(tls.CipherSuite.AES_256_GCM_SHA384);
            break :comptime_values vals;
        };
        const negotiated_suite = handshake_mod.negotiateCipherSuite(&client_hello, &server_suite_values) orelse
            return error.TlsNoMatchingCipherSuite;
        const suite_enum: tls.CipherSuite = @enumFromInt(negotiated_suite);
        const suite_with = suite_enum.with();

        // Find key share (try X25519 first, then secp256r1)
        const supported_groups = [_]u16{
            @intFromEnum(tls.NamedGroup.x25519),
            @intFromEnum(tls.NamedGroup.secp256r1),
        };
        const key_share = handshake_mod.findKeyShare(&client_hello, &supported_groups) orelse
            return error.TlsNoMatchingKeyShare;

        // Generate server key pair and compute shared secret
        const ks_result = computeSharedSecret(options.entropy, key_share) catch
            return error.TlsDecryptFailure;

        // Build and send ServerHello
        const server_random = options.entropy[0..32].*;
        const session_id = client_hello.session_id;
        var hello_buf: [512]u8 = undefined;
        const server_hello_msg = handshake_mod.buildServerHello(
            server_random,
            session_id,
            negotiated_suite,
            key_share.group,
            ks_result.pubkey[0..ks_result.pubkey_len],
            &hello_buf,
        );
        var wrapped_hello_buf: [517]u8 = undefined;
        const wrapped_server_hello = handshake_mod.wrapRecord(
            @intFromEnum(tls.ContentType.handshake),
            server_hello_msg,
            &wrapped_hello_buf,
        );

        // Send change_cipher_spec (compatibility)
        var ccs_buf: [6]u8 = undefined;
        const ccs_msg = handshake_mod.wrapRecord(
            @intFromEnum(tls.ContentType.change_cipher_spec),
            &.{0x01},
            &ccs_buf,
        );

        // Derive handshake keys (same as client, but roles swapped)
        // "s hs traffic" for server writing, "c hs traffic" for client writing
        return switch (suite_with) {
            .AES_128_GCM_SHA256 => doHandshake(
                @typeInfo(tls.HandshakeCipher).@"union".fields[0].type,
                .AES_128_GCM_SHA256,
                options,
                input,
                output,
                client_hello,
                ks_result.shared,
                server_hello_msg,
                wrapped_server_hello,
                ccs_msg,
                suite_with,
            ),
            .AES_256_GCM_SHA384 => doHandshake(
                @typeInfo(tls.HandshakeCipher).@"union".fields[1].type,
                .AES_256_GCM_SHA384,
                options,
                input,
                output,
                client_hello,
                ks_result.shared,
                server_hello_msg,
                wrapped_server_hello,
                ccs_msg,
                suite_with,
            ),
            .CHACHA20_POLY1305_SHA256 => doHandshake(
                @typeInfo(tls.HandshakeCipher).@"union".fields[2].type,
                .CHACHA20_POLY1305_SHA256,
                options,
                input,
                output,
                client_hello,
                ks_result.shared,
                server_hello_msg,
                wrapped_server_hello,
                ccs_msg,
                suite_with,
            ),
            else => error.TlsNoMatchingCipherSuite,
        };
    }

    /// Send close_notify and end the TLS session.
    pub fn end(s: *const Server) std.Io.Writer.Error!void {
        _ = s;
        // TODO: prepare and send close_notify alert
    }
};

fn doHandshake(
    comptime CipherT: type,
    comptime tag: tls.CipherSuite.With,
    options: Server.Options,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    client_hello: handshake_mod.ClientHello,
    shared_secret: [32]u8,
    server_hello_msg: []const u8,
    wrapped_server_hello: []const u8,
    ccs_msg: []const u8,
    suite_with: tls.CipherSuite.With,
) Server.InitError!Server {
    const P = CipherT.A;
    var handshake_cipher: CipherT = undefined;

    // Transcript hash includes ClientHello + ServerHello
    var h = P.Hash.init(.{});
    h.update(client_hello.wrapped_message);
    h.update(server_hello_msg);
    const hello_hash = h.peek();

    // Key derivation
    const zeroes = [_]u8{0} ** P.Hkdf.prk_length;
    const early_secret = P.Hkdf.extract(&zeroes, &zeroes);
    const hs_derived_secret = hkdfExpandLabel(P.Hkdf, early_secret, "derived", &emptyHash(P.Hash), P.Hash.digest_length);
    var pv: @TypeOf(handshake_cipher.version.tls_1_3) = undefined;
    pv.handshake_secret = P.Hkdf.extract(&hs_derived_secret, &shared_secret);
    const ap_derived_secret = hkdfExpandLabel(P.Hkdf, pv.handshake_secret, "derived", &emptyHash(P.Hash), P.Hash.digest_length);
    pv.master_secret = P.Hkdf.extract(&ap_derived_secret, &zeroes);

    // Server writes with "s hs traffic", client reads with "s hs traffic"
    const server_hs_secret = hkdfExpandLabel(P.Hkdf, pv.handshake_secret, "s hs traffic", &hello_hash, P.Hash.digest_length);
    pv.server_finished_key = hkdfExpandLabel(P.Hkdf, server_hs_secret, "finished", "", P.Hmac.key_length);
    pv.server_handshake_key = hkdfExpandLabel(P.Hkdf, server_hs_secret, "key", "", P.AEAD.key_length);
    pv.server_handshake_iv = hkdfExpandLabel(P.Hkdf, server_hs_secret, "iv", "", P.AEAD.nonce_length);

    // Client writes with "c hs traffic", server reads with "c hs traffic"
    const client_hs_secret = hkdfExpandLabel(P.Hkdf, pv.handshake_secret, "c hs traffic", &hello_hash, P.Hash.digest_length);
    pv.client_finished_key = hkdfExpandLabel(P.Hkdf, client_hs_secret, "finished", "", P.Hmac.key_length);
    pv.client_handshake_key = hkdfExpandLabel(P.Hkdf, client_hs_secret, "key", "", P.AEAD.key_length);
    pv.client_handshake_iv = hkdfExpandLabel(P.Hkdf, client_hs_secret, "iv", "", P.AEAD.nonce_length);

    handshake_cipher.version.tls_1_3 = pv;
    handshake_cipher.transcript_hash = h;

    // Build encrypted handshake messages:
    // EncryptedExtensions, Certificate, CertificateVerify, Finished
    var write_seq: u64 = 0;

    // EncryptedExtensions (empty for now)
    const enc_ext_msg = buildEncryptedExtensions();
    {
        const pv2 = &handshake_cipher.version.tls_1_3;
        handshake_cipher.transcript_hash.update(&enc_ext_msg);

        const record_buf = options.write_buffer;
        const record = prepareHandshakeRecord(
            record_buf,
            &enc_ext_msg,
            pv2.server_handshake_key,
            pv2.server_handshake_iv,
            write_seq,
            P,
        );
        write_seq += 1;

        // Send ServerHello + CCS + EncryptedExtensions
        var iovs = [_][]const u8{
            wrapped_server_hello,
            ccs_msg,
            record,
        };
        try output.writeVecAll(&iovs);
        try output.flush();
    }

    // Certificate
    const cert_msg = buildCertificate(options.tls_context.chain_der);
    {
        handshake_cipher.transcript_hash.update(cert_msg);
        const record = prepareHandshakeRecord(
            options.write_buffer,
            cert_msg,
            pv.server_handshake_key,
            pv.server_handshake_iv,
            write_seq,
            P,
        );
        write_seq += 1;
        try output.writeAll(record);
        try output.flush();
    }

    // CertificateVerify
    const scheme = sign_mod.defaultScheme(&options.tls_context.private_key) orelse
        return error.TlsNoMatchingSignatureScheme;
    const verify_input = " " ** 64 ++ "TLS 1.3, server CertificateVerify\x00";
    {
        const allocator = options.tls_context.allocator;
        const transcript_hash_bytes = handshake_cipher.transcript_hash.peek();
        // Sign: hash(verify_input || transcript_hash)
        var h2 = P.Hash.init(.{});
        h2.update(verify_input);
        h2.update(&transcript_hash_bytes);
        var hash_output: [P.Hash.digest_length]u8 = undefined;
        h2.final(&hash_output);

        const signature = sign_mod.sign(allocator, &options.tls_context.private_key, scheme, &hash_output) catch
            return error.TlsDecryptFailure;
        defer allocator.free(signature);

        var cert_verify_buf: [512]u8 = undefined;
        const cert_verify_msg = buildCertificateVerify(scheme, signature, &cert_verify_buf);
        handshake_cipher.transcript_hash.update(cert_verify_msg);

        const record = prepareHandshakeRecord(
            options.write_buffer,
            cert_verify_msg,
            pv.server_handshake_key,
            pv.server_handshake_iv,
            write_seq,
            P,
        );
        write_seq += 1;
        try output.writeAll(record);
        try output.flush();
    }

    // Finished
    {
        const finished_hash = handshake_cipher.transcript_hash.peek();
        const finished_verify_data = tls.hmac(P.Hmac, &finished_hash, pv.server_finished_key);
        var finished_buf: [64]u8 = undefined;
        const finished_msg = buildFinished(&finished_verify_data, &finished_buf);
        handshake_cipher.transcript_hash.update(finished_msg);

        const record = prepareHandshakeRecord(
            options.write_buffer,
            finished_msg,
            pv.server_handshake_key,
            pv.server_handshake_iv,
            write_seq,
            P,
        );
        write_seq += 1;
        try output.writeAll(record);
        try output.flush();
    }

    // Read client Finished
    var read_seq: u64 = 0;
    var cleartext_buf: [tls.max_ciphertext_inner_record_len]u8 = undefined;
    const client_finished = readEncryptedRecord(
        input,
        read_seq,
        &handshake_cipher,
        suite_with,
        &cleartext_buf,
    ) catch |err| return err;
    read_seq += 1;

    {
        const expected_finished_hash = handshake_cipher.transcript_hash.peek();
        handshake_cipher.transcript_hash.update(client_finished);

        const expected_finished = tls.hmac(P.Hmac, &expected_finished_hash, pv.client_finished_key);
        // The client's Finished message content is after the handshake header (4 bytes)
        if (client_finished.len < 4 + expected_finished.len) return error.TlsBadRecordMac;
        const client_verify_data = client_finished[4..][0..expected_finished.len];
        if (!crypto.timing_safe.eql([expected_finished.len]u8, expected_finished, client_verify_data.*))
            return error.TlsBadRecordMac;

        // Derive application traffic keys
        const handshake_hash = handshake_cipher.transcript_hash.finalResult();
        const client_app_secret = hkdfExpandLabel(P.Hkdf, pv.master_secret, "c ap traffic", &handshake_hash, P.Hash.digest_length);
        const server_app_secret = hkdfExpandLabel(P.Hkdf, pv.master_secret, "s ap traffic", &handshake_hash, P.Hash.digest_length);

        return .{
            .input = input,
            .reader = .{
                .vtable = &.{
                    .stream = readerStream,
                    .readVec = readerReadVec,
                },
                .buffer = options.read_buffer,
                .seek = 0,
                .end = 0,
            },
            .output = output,
            .writer = .{
                .vtable = &.{
                    .drain = writerDrain,
                },
                .buffer = options.write_buffer,
                .end = 0,
            },
            .alert = null,
            .tls_version = .tls_1_3,
            .read_seq = read_seq,
            .write_seq = write_seq,
            .received_close_notify = false,
            .application_cipher = @unionInit(
                tls.ApplicationCipher,
                @tagName(tag),
                .{
                    .tls_1_3 = .{
                        .client_secret = client_app_secret,
                        .server_secret = server_app_secret,
                        .client_key = hkdfExpandLabel(P.Hkdf, client_app_secret, "key", "", P.AEAD.key_length),
                        .server_key = hkdfExpandLabel(P.Hkdf, server_app_secret, "key", "", P.AEAD.key_length),
                        .client_iv = hkdfExpandLabel(P.Hkdf, client_app_secret, "iv", "", P.AEAD.nonce_length),
                        .server_iv = hkdfExpandLabel(P.Hkdf, server_app_secret, "iv", "", P.AEAD.nonce_length),
                    },
                },
            ),
            .sni_hostname = client_hello.sni,
        };
    }
}

// --- Key exchange ---

const SharedSecretResult = struct {
    shared: [32]u8,
    pubkey: [65]u8,
    pubkey_len: usize,
};

fn computeSharedSecret(entropy: []const u8, key_share: handshake_mod.KeyShareEntry) !SharedSecretResult {
    switch (key_share.group) {
        // X25519
        0x001D => {
            const seed: [32]u8 = entropy[32..64].*;
            const kp = crypto.dh.X25519.KeyPair.generateDeterministic(seed) catch return error.InsufficientEntropy;
            var result: SharedSecretResult = undefined;
            result.pubkey[0..32].* = kp.public_key;
            result.pubkey_len = 32;
            result.shared = crypto.dh.X25519.scalarmult(kp.secret_key, key_share.public_key[0..32].*) catch return error.InsufficientEntropy;
            return result;
        },
        // secp256r1
        0x0017 => {
            const secret_key: [32]u8 = entropy[32..64].*;
            const point = crypto.ecc.P256.basePoint.mul(secret_key, .big) catch return error.InsufficientEntropy;
            const affine_pub = point.affineCoordinates();
            var result: SharedSecretResult = undefined;
            result.pubkey[0] = 0x04;
            result.pubkey[1..33].* = affine_pub.x.toBytes(.big);
            result.pubkey[33..65].* = affine_pub.y.toBytes(.big);
            result.pubkey_len = 65;

            // Decode client's public key (uncompressed SEC1)
            if (key_share.public_key[0] != 0x04 or key_share.public_key.len != 65)
                return error.TlsDecodeError;

            const x: [32]u8 = key_share.public_key[1..33].*;
            const y: [32]u8 = key_share.public_key[33..65].*;

            const their_point = crypto.ecc.P256.fromSerializedAffineCoordinates(x, y, .big) catch return error.InsufficientEntropy;
            // For P256, ECDH shared secret = x_coordinate of (secret * their_public)
            const result_point = their_point.mul(secret_key, .big) catch return error.InsufficientEntropy;
            result.shared = result_point.affineCoordinates().x.toBytes(.big);
            return result;
        },
        else => return error.TlsNoMatchingKeyShare,
    }
}

// --- Handshake message builders ---

fn buildEncryptedExtensions() [4]u8 {
    // Empty EncryptedExtensions: type=0x08, length=0x000000
    return .{ 0x08, 0x00, 0x00, 0x00 };
}

fn buildCertificate(chain: [][]const u8) []const u8 {
    // For simplicity, build a minimal certificate message
    // This would need dynamic allocation for real use
    _ = chain;
    return &[_]u8{ 0x0b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
}

fn buildCertificateVerify(scheme: tls.SignatureScheme, signature: []const u8, buf: []u8) []u8 {
    const total = 4 + 2 + 2 + signature.len;
    std.debug.assert(buf.len >= total);
    buf[0] = 0x0f;
    std.mem.writeInt(u24, buf[1..4], @intCast(2 + 2 + signature.len), .big);
    std.mem.writeInt(u16, buf[4..6], @intFromEnum(scheme), .big);
    std.mem.writeInt(u16, buf[6..8], @intCast(signature.len), .big);
    @memcpy(buf[8 .. 8 + signature.len], signature);
    return buf[0..total];
}

fn buildFinished(verify_data: []const u8, buf: []u8) []u8 {
    const total = 4 + verify_data.len;
    std.debug.assert(buf.len >= total);
    buf[0] = 0x14;
    std.mem.writeInt(u24, buf[1..4], @intCast(verify_data.len), .big);
    @memcpy(buf[4 .. 4 + verify_data.len], verify_data);
    return buf[0..total];
}

// --- Record encryption/decryption ---

fn prepareHandshakeRecord(
    buf: []u8,
    cleartext: []const u8,
    key: anytype,
    iv: anytype,
    seq: u64,
    comptime P: type,
) []const u8 {
    const cleartext_with_type = cleartext.len + 1; // +1 for inner content type byte
    const ciphertext_len = cleartext_with_type + P.AEAD.tag_length;
    const record_len = tls.record_header_len + ciphertext_len;

    // Build AAD
    const ad = buf[0..tls.record_header_len];
    ad[0] = @intFromEnum(tls.ContentType.application_data);
    std.mem.writeInt(u16, ad[1..3], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    std.mem.writeInt(u16, ad[3..5], @intCast(ciphertext_len), .big);

    // Build nonce
    const nonce = computeNonce(iv, seq, P.AEAD.nonce_length);

    // Build cleartext with inner content type
    var ct_buf: [tls.max_ciphertext_inner_record_len + 1]u8 = undefined;
    @memcpy(ct_buf[0..cleartext.len], cleartext);
    ct_buf[cleartext.len] = @intFromEnum(tls.ContentType.handshake);

    // Encrypt
    const ciphertext = buf[tls.record_header_len..][0..cleartext_with_type];
    const auth_tag = buf[tls.record_header_len + cleartext_with_type ..][0..P.AEAD.tag_length];

    P.AEAD.encrypt(ciphertext, auth_tag, ct_buf[0..cleartext_with_type], ad, nonce, key);

    return buf[0..record_len];
}

fn computeNonce(iv: anytype, seq: u64, nonce_len: comptime_int) [nonce_len]u8 {
    const V = @Vector(nonce_len, u8);
    const pad = [1]u8{0} ** (nonce_len - 8);
    const operand: V = pad ++ @as([8]u8, @bitCast(std.mem.nativeToBig(u64, seq)));
    return @as(V, iv) ^ operand;
}

fn readEncryptedRecord(
    input: *std.Io.Reader,
    seq: u64,
    handshake_cipher: anytype,
    suite_with: tls.CipherSuite.With,
    cleartext_buf: *[tls.max_ciphertext_inner_record_len]u8,
) ![]const u8 {
    // Read record header
    input.rebase(tls.max_ciphertext_record_len) catch return error.TlsConnectionTruncated;
    const record_header = input.peek(tls.record_header_len) catch return error.TlsConnectionTruncated;

    const ct = input.takeEnumNonexhaustive(tls.ContentType, .big) catch unreachable;
    if (ct != .application_data) return error.TlsUnexpectedMessage;
    input.toss(2);
    const record_len = input.takeInt(u16, .big) catch unreachable;
    if (record_len > tls.max_ciphertext_len) return error.TlsRecordOverflow;
    const record_buffer = input.take(record_len) catch return error.TlsConnectionTruncated;

    switch (suite_with) {
        inline else => {
            const P = @TypeOf(handshake_cipher.*).A;
            const pv = &handshake_cipher.version.tls_1_3;

            if (record_len < P.AEAD.tag_length + 1) return error.TlsRecordOverflow;
            const ciphertext_len = record_len - P.AEAD.tag_length;
            const ciphertext = record_buffer[0..ciphertext_len];
            const auth_tag = record_buffer[ciphertext_len..][0..P.AEAD.tag_length];

            const nonce = computeNonce(pv.client_handshake_iv, seq, P.AEAD.nonce_length);
            P.AEAD.decrypt(cleartext_buf, ciphertext, auth_tag.*, record_header, nonce, pv.client_handshake_key) catch
                return error.TlsBadRecordMac;

            // Strip inner content type byte
            const cleartext_len = ciphertext_len;
            return cleartext_buf[0 .. cleartext_len - 1];
        },
    }
}

// --- Stream vtable stub functions ---

fn readerStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    _ = r;
    _ = w;
    _ = limit;
    return 0;
}

fn readerReadVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
    _ = r;
    _ = data;
    return 0;
}

fn writerDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = w;
    _ = data;
    _ = splat;
    return 0;
}

fn assert(condition: bool, comptime message: []const u8) void {
    if (!condition) @compileError(message);
}
