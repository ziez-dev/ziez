const std = @import("std");

pub const cert = @import("cert.zig");
pub const rsa_sign = @import("rsa_sign.zig");
pub const sign_mod = @import("sign.zig");
pub const server = @import("server.zig").Server;
pub const server_entropy_len = @import("server.zig").Server.entropy_len;

const Certificate = std.crypto.Certificate;

/// Minimum TLS version the server will accept.
pub const TlsVersion = enum {
    tls_1_2,
    tls_1_3,
};

/// Client certificate authentication mode.
pub const ClientAuth = enum {
    /// Do not request a client certificate.
    none,
    /// Request a client certificate but allow the connection if none is provided.
    request,
    /// Require a valid client certificate; reject the handshake otherwise.
    require,
};

/// Supported cipher suites for TLS 1.3.
pub const CipherSuite = enum(u16) {
    AES_128_GCM_SHA256 = 0x1301,
    AES_256_GCM_SHA384 = 0x1302,
    CHACHA20_POLY1305_SHA256 = 0x1303,
};

/// Certificate source: file path or in-memory bytes.
pub const CertSource = union(enum) {
    file_path: []const u8,
    pem_bytes: []const u8,
    der_bytes: []const u8,
};

/// Private key source.
pub const KeySource = union(enum) {
    file_path: []const u8,
    pem_bytes: []const u8,
    der_bytes: []const u8,
};

/// HTTP listener configuration used to redirect plaintext traffic to HTTPS.
pub const RedirectHttpConfig = struct {
    enabled: bool = true,
    port: u16 = 80,
    to: ?u16 = null,
    exclude: []const []const u8 = &.{},

    pub fn shouldRedirect(self: RedirectHttpConfig, path: []const u8) bool {
        if (!self.enabled) return false;
        for (self.exclude) |excluded| {
            if (std.mem.eql(u8, excluded, path)) return false;
        }
        return true;
    }
};

/// TLS configuration passed to `App.tls()`.
pub const TlsConfig = struct {
    /// Server certificate chain (leaf + intermediates).
    cert: CertSource,
    /// Server private key.
    key: KeySource,
    /// Minimum TLS version to accept (default: TLS 1.2).
    min_version: TlsVersion = .tls_1_2,
    /// Cipher suites offered in preference order.
    cipher_suites: []const CipherSuite = &.{
        .AES_128_GCM_SHA256,
        .CHACHA20_POLY1305_SHA256,
        .AES_256_GCM_SHA384,
    },
    /// Client certificate authentication mode.
    client_auth: ClientAuth = .none,
    /// Trusted CA bundle for verifying client certificates (mTLS).
    client_ca: ?CertSource = null,
    /// Allowed SNI hostnames (null = accept any).
    sni_hostnames: ?[]const []const u8 = null,
};

/// Supported private key types.
pub const PrivateKey = union(enum) {
    ecdsa_p256: EcdsaP256Key,
    ecdsa_p384: EcdsaP384Key,
    ed25519: Ed25519Key,
    rsa: RsaKey,

    pub fn deinit(self: *const PrivateKey, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ecdsa_p256, .ecdsa_p384, .ed25519 => {},
            .rsa => |*k| {
                if (k.n) |n| allocator.free(n);
                if (k.d) |d| allocator.free(d);
                if (k.e) |e| allocator.free(e);
            },
        }
    }

    pub fn algoCategory(self: *const PrivateKey) std.crypto.Certificate.AlgorithmCategory {
        return switch (self.*) {
            .ecdsa_p256, .ecdsa_p384 => .X9_62_id_ecPublicKey,
            .ed25519 => .curveEd25519,
            .rsa => .rsaEncryption,
        };
    }
};

pub const EcdsaP256Key = struct {
    secret_key: [32]u8,
    public_key: [65]u8,
};

pub const EcdsaP384Key = struct {
    secret_key: [48]u8,
    public_key: [97]u8,
};

pub const Ed25519Key = struct {
    key_pair: std.crypto.sign.Ed25519.KeyPair,
};

pub const RsaKey = struct {
    n: ?[]const u8 = null,
    d: ?[]const u8 = null,
    e: ?[]const u8 = null,
    bits: usize = 0,
};

/// Information extracted from a client certificate (mTLS).
pub const ClientCertInfo = struct {
    subject: []const u8,
    issuer: []const u8,
    serial_number: []const u8,
    not_before: u64,
    not_after: u64,
    fingerprint: [32]u8,
};

/// Errors that can occur during TLS context initialization.
pub const TlsInitError = error{
    CertificateFileNotFound,
    CertificateParseError,
    CertificateExpired,
    CertificateNotYetValid,
    KeyFileNotFound,
    KeyParseError,
    KeyCertMismatch,
    InvalidPemFormat,
    UnsupportedKeyType,
    UnsupportedCurve,
    OutOfMemory,
};

/// Parsed and validated TLS material, ready for handshake.
/// Immutable once created — safe to share across connections.
pub const TlsContext = struct {
    allocator: std.mem.Allocator,
    /// Parsed leaf certificate (DER).
    leaf_cert: Certificate.Parsed,
    /// DER bytes for the full certificate chain (leaf first, then intermediates).
    chain_der: [][]const u8,
    /// Server private key.
    private_key: PrivateKey,
    /// Client auth mode.
    client_auth: ClientAuth,
    /// Client CA bundle for mTLS (if configured).
    client_ca_bundle: ?Certificate.Bundle = null,
    /// Allowed SNI hostnames.
    sni_hostnames: ?[]const []const u8 = null,
    /// Cipher suites to offer.
    cipher_suites: []const CipherSuite,
    /// Minimum TLS version.
    min_version: TlsVersion,
    /// Raw leaf cert DER bytes (owned, kept for sending in handshake).
    leaf_der: []const u8,

    pub fn init(allocator: std.mem.Allocator, config: TlsConfig) TlsInitError!TlsContext {
        // Load certificate chain
        const chain_der = loadCertChain(allocator, config.cert) catch |e| {
            switch (e) {
                error.FileNotFound => return error.CertificateFileNotFound,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CertificateParseError,
            }
        };
        errdefer freeChainDer(allocator, chain_der);

        if (chain_der.len == 0) return error.CertificateParseError;

        // Parse leaf certificate
        const leaf_cert = Certificate.parse(.{ .buffer = chain_der[0], .index = 0 }) catch
            return error.CertificateParseError;

        // Check certificate validity
        const now_sec: i64 = currentUnixSeconds();
        if (now_sec < leaf_cert.validity.not_before) return error.CertificateNotYetValid;
        if (now_sec > leaf_cert.validity.not_after) return error.CertificateExpired;

        // Verify chain if intermediates are present
        if (chain_der.len > 1) {
            for (1..chain_der.len) |i| {
                _ = Certificate.parse(.{ .buffer = chain_der[i], .index = 0 }) catch
                    return error.CertificateParseError;
                Certificate.verify(
                    .{ .buffer = chain_der[i - 1], .index = 0 },
                    .{ .buffer = chain_der[i], .index = 0 },
                    now_sec,
                ) catch return error.CertificateParseError;
            }
        }

        // Load private key
        const private_key = loadPrivateKey(allocator, config.key) catch |e| {
            switch (e) {
                error.FileNotFound => return error.KeyFileNotFound,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.KeyParseError,
            }
        };
        errdefer private_key.deinit(allocator);

        // Verify key-cert match: the public key algorithm should match
        const key_algo = private_key.algoCategory();
        const cert_algo = leaf_cert.pub_key_algo;
        if (!algoMatches(cert_algo, key_algo)) return error.KeyCertMismatch;

        // Load client CA bundle if mTLS is configured
        var client_ca_bundle: ?Certificate.Bundle = null;
        if (config.client_ca != null and config.client_auth != .none) {
            const ca_source = config.client_ca.?;
            const ca_der = switch (ca_source) {
                .file_path => |p| blk: {
                    const chain = cert.loadCertChainFromFile(allocator, p) catch |err| switch (err) {
                        error.FileNotFound => return error.CertificateFileNotFound,
                        else => return error.CertificateParseError,
                    };
                    defer {
                        for (chain[1..]) |der| allocator.free(der);
                        allocator.free(chain);
                    }
                    if (chain.len == 0) return error.CertificateParseError;
                    break :blk try allocator.dupe(u8, chain[0]);
                },
                .pem_bytes => |pem| cert.pemToDer(allocator, pem) catch
                    return error.CertificateParseError,
                .der_bytes => |der| try allocator.dupe(u8, der),
            };
            errdefer if (ca_source != .der_bytes) allocator.free(ca_der);

            client_ca_bundle = Certificate.Bundle.empty;
            try client_ca_bundle.?.bytes.appendSlice(allocator, ca_der);
            client_ca_bundle.?.parseCert(allocator, 0, std.time.epoch.unix) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CertificateParseError,
            };
        }

        // Duplicate leaf DER for owned storage
        const leaf_der = try allocator.dupe(u8, chain_der[0]);
        errdefer allocator.free(leaf_der);

        return .{
            .allocator = allocator,
            .leaf_cert = leaf_cert,
            .chain_der = chain_der,
            .private_key = private_key,
            .client_auth = config.client_auth,
            .client_ca_bundle = client_ca_bundle,
            .sni_hostnames = config.sni_hostnames,
            .cipher_suites = config.cipher_suites,
            .min_version = config.min_version,
            .leaf_der = leaf_der,
        };
    }

    pub fn deinit(self: *TlsContext) void {
        for (self.chain_der) |der| {
            self.allocator.free(der);
        }
        self.allocator.free(self.chain_der);
        self.allocator.free(self.leaf_der);
        self.private_key.deinit(self.allocator);
        // client_ca_bundle has no deinit in stdlib
    }
};

pub const TlsLease = struct {
    runtime: *TlsRuntime,
    entry: *ManagedTlsContext,

    pub fn context(self: *const TlsLease) *TlsContext {
        return &self.entry.context;
    }

    pub fn release(self: *TlsLease) void {
        self.runtime.release(self.entry);
        self.* = undefined;
    }
};

const ManagedTlsContext = struct {
    context: TlsContext,
    refs: std.atomic.Value(u32) = .init(0),
    retired: bool = false,
    next_retired: ?*ManagedTlsContext = null,
};

/// Long-lived TLS state used by the listener so certificates can be reloaded.
pub const TlsRuntime = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    active: ?*ManagedTlsContext = null,
    retired_head: ?*ManagedTlsContext = null,

    pub fn create(allocator: std.mem.Allocator, config: TlsConfig) !*TlsRuntime {
        const runtime = try allocator.create(TlsRuntime);
        errdefer allocator.destroy(runtime);

        runtime.* = .{
            .allocator = allocator,
            .mutex = .unlocked,
            .active = null,
            .retired_head = null,
        };

        runtime.active = try runtime.createManaged(config);
        return runtime;
    }

    pub fn destroy(self: *TlsRuntime) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        if (self.active) |active| {
            self.freeManaged(active);
            self.active = null;
        }

        var cursor = self.retired_head;
        while (cursor) |entry| {
            const next = entry.next_retired;
            self.freeManaged(entry);
            cursor = next;
        }
        self.retired_head = null;

        self.allocator.destroy(self);
    }

    pub fn reload(self: *TlsRuntime, config: TlsConfig) !void {
        const replacement = try self.createManaged(config);

        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const previous = self.active;
        self.active = replacement;
        if (previous) |old| self.retireLocked(old);
    }

    pub fn acquire(self: *TlsRuntime) ?TlsLease {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const active = self.active orelse return null;
        _ = active.refs.fetchAdd(1, .acq_rel);
        return .{
            .runtime = self,
            .entry = active,
        };
    }

    fn release(self: *TlsRuntime, entry: *ManagedTlsContext) void {
        const previous = entry.refs.fetchSub(1, .acq_rel);
        if (previous != 1 or !entry.retired) return;

        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        if (entry.retired and entry.refs.load(.acquire) == 0) {
            _ = self.unlinkRetiredLocked(entry);
            self.freeManaged(entry);
        }
    }

    fn createManaged(self: *TlsRuntime, config: TlsConfig) !*ManagedTlsContext {
        const entry = try self.allocator.create(ManagedTlsContext);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .context = try TlsContext.init(self.allocator, config),
            .refs = .init(0),
            .retired = false,
            .next_retired = null,
        };
        return entry;
    }

    fn retireLocked(self: *TlsRuntime, entry: *ManagedTlsContext) void {
        entry.retired = true;
        entry.next_retired = self.retired_head;
        self.retired_head = entry;

        if (entry.refs.load(.acquire) == 0) {
            _ = self.unlinkRetiredLocked(entry);
            self.freeManaged(entry);
        }
    }

    fn unlinkRetiredLocked(self: *TlsRuntime, target: *ManagedTlsContext) bool {
        var prev: ?*ManagedTlsContext = null;
        var cursor = self.retired_head;
        while (cursor) |entry| {
            if (entry == target) {
                if (prev) |p| {
                    p.next_retired = entry.next_retired;
                } else {
                    self.retired_head = entry.next_retired;
                }
                entry.next_retired = null;
                return true;
            }
            prev = entry;
            cursor = entry.next_retired;
        }
        return false;
    }

    fn freeManaged(self: *TlsRuntime, entry: *ManagedTlsContext) void {
        entry.context.deinit();
        self.allocator.destroy(entry);
    }
};

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

fn loadCertChain(allocator: std.mem.Allocator, source: CertSource) ![][]const u8 {
    switch (source) {
        .file_path => |path| return cert.loadCertChainFromFile(allocator, path),
        .pem_bytes => |pem| return cert.pemToCertChain(allocator, pem),
        .der_bytes => |der| {
            const duped = try allocator.dupe(u8, der);
            const list = try allocator.alloc([]const u8, 1);
            list[0] = duped;
            return list;
        },
    }
}

fn loadPrivateKey(allocator: std.mem.Allocator, source: KeySource) !PrivateKey {
    switch (source) {
        .file_path => |path| return cert.loadKeyFromFile(allocator, path),
        .pem_bytes => |pem| return cert.parsePrivateKey(allocator, pem),
        .der_bytes => |der| return cert.parsePrivateKeyDer(allocator, der),
    }
}

fn freeChainDer(allocator: std.mem.Allocator, chain: [][]const u8) void {
    for (chain) |der| allocator.free(der);
    allocator.free(chain);
}

fn algoMatches(cert_algo: std.crypto.Certificate.Parsed.PubKeyAlgo, key_algo: std.crypto.Certificate.AlgorithmCategory) bool {
    return switch (cert_algo) {
        .rsaEncryption, .rsassa_pss => key_algo == .rsaEncryption,
        .X9_62_id_ecPublicKey => key_algo == .X9_62_id_ecPublicKey,
        .curveEd25519 => key_algo == .curveEd25519,
    };
}

fn currentUnixSeconds() i64 {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    return @as(i64, @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s)));
}

// ── Type-erased adapter functions for DCE integration ────────────────────────

pub fn createRuntimeFn(config_ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!*anyopaque {
    const config: *const TlsConfig = @ptrCast(@alignCast(config_ptr));
    const runtime = try TlsRuntime.create(allocator, config.*);
    return @ptrCast(runtime);
}

pub fn destroyRuntimeFn(runtime_ptr: *anyopaque) void {
    const runtime: *TlsRuntime = @ptrCast(@alignCast(runtime_ptr));
    runtime.destroy();
}

pub fn reloadRuntimeFn(runtime_ptr: *anyopaque, config_ptr: *anyopaque) anyerror!void {
    const runtime: *TlsRuntime = @ptrCast(@alignCast(runtime_ptr));
    const config: *const TlsConfig = @ptrCast(@alignCast(config_ptr));
    try runtime.reload(config.*);
}

pub fn freeConfigFn(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    allocator.destroy(@as(*TlsConfig, @ptrCast(@alignCast(ptr))));
}

pub fn freeRedirectConfigFn(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    allocator.destroy(@as(*RedirectHttpConfig, @ptrCast(@alignCast(ptr))));
}
