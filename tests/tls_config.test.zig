const std = @import("std");
const ziez = @import("ziez");

test "TlsConfig default values" {
    const config = ziez.TlsConfig{
        .cert = .{ .pem_bytes = "dummy" },
        .key = .{ .pem_bytes = "dummy" },
    };

    try std.testing.expectEqual(ziez.TlsVersion.tls_1_2, config.min_version);
    try std.testing.expectEqual(ziez.ClientAuth.none, config.client_auth);
    try std.testing.expect(config.client_ca == null);
    try std.testing.expect(config.sni_hostnames == null);
    try std.testing.expect(config.cipher_suites.len > 0);
}

test "TlsConfig client_auth variants" {
    const config_none = ziez.TlsConfig{
        .cert = .{ .der_bytes = "x" },
        .key = .{ .der_bytes = "x" },
        .client_auth = .none,
    };
    try std.testing.expectEqual(ziez.ClientAuth.none, config_none.client_auth);

    const config_request = ziez.TlsConfig{
        .cert = .{ .der_bytes = "x" },
        .key = .{ .der_bytes = "x" },
        .client_auth = .request,
    };
    try std.testing.expectEqual(ziez.ClientAuth.request, config_request.client_auth);

    const config_require = ziez.TlsConfig{
        .cert = .{ .der_bytes = "x" },
        .key = .{ .der_bytes = "x" },
        .client_auth = .require,
    };
    try std.testing.expectEqual(ziez.ClientAuth.require, config_require.client_auth);
}

test "TlsConfig with mTLS CA" {
    const config = ziez.TlsConfig{
        .cert = .{ .der_bytes = "x" },
        .key = .{ .der_bytes = "x" },
        .client_auth = .require,
        .client_ca = .{ .pem_bytes = "ca-pem" },
    };

    try std.testing.expectEqual(ziez.ClientAuth.require, config.client_auth);
    try std.testing.expect(config.client_ca != null);
}

test "TlsConfig with SNI hostnames" {
    const hostnames = [_][]const u8{"example.com", "www.example.com"};
    const config = ziez.TlsConfig{
        .cert = .{ .der_bytes = "x" },
        .key = .{ .der_bytes = "x" },
        .sni_hostnames = &hostnames,
    };

    try std.testing.expect(config.sni_hostnames != null);
    try std.testing.expectEqual(@as(usize, 2), config.sni_hostnames.?.len);
}

test "TlsConfig cipher suite ordering" {
    const config = ziez.TlsConfig{
        .cert = .{ .der_bytes = "x" },
        .key = .{ .der_bytes = "x" },
        .cipher_suites = &.{
            .CHACHA20_POLY1305_SHA256,
            .AES_128_GCM_SHA256,
            .AES_256_GCM_SHA384,
        },
    };

    try std.testing.expectEqual(@as(usize, 3), config.cipher_suites.len);
    try std.testing.expectEqual(ziez.CipherSuite.CHACHA20_POLY1305_SHA256, config.cipher_suites[0]);
    try std.testing.expectEqual(ziez.CipherSuite.AES_128_GCM_SHA256, config.cipher_suites[1]);
    try std.testing.expectEqual(ziez.CipherSuite.AES_256_GCM_SHA384, config.cipher_suites[2]);
}

test "App.tls() stores config" {
    var app = ziez.App.init(std.testing.allocator);
    defer app.deinit();

    app.tls(.{
        .cert = .{ .pem_bytes = "cert" },
        .key = .{ .pem_bytes = "key" },
    });

    try std.testing.expect(app.tls_config != null);
}

test "App without TLS has null tls_config" {
    var app = ziez.App.init(std.testing.allocator);
    defer app.deinit();

    try std.testing.expect(app.tls_config == null);
}

test "RedirectHttpConfig defaults and exclusions" {
    const config = ziez.RedirectHttpConfig{};

    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(@as(u16, 80), config.port);
    try std.testing.expect(config.to == null);
    try std.testing.expect(config.shouldRedirect("/"));
    try std.testing.expect(config.shouldRedirect("/items"));

    const excluded = ziez.RedirectHttpConfig{
        .exclude = &.{ "/health", "/.well-known/acme-challenge" },
    };

    try std.testing.expect(!excluded.shouldRedirect("/health"));
    try std.testing.expect(!excluded.shouldRedirect("/.well-known/acme-challenge"));
    try std.testing.expect(excluded.shouldRedirect("/api"));
}

test "App.redirectHttp() stores config" {
    var app = ziez.App.init(std.testing.allocator);
    defer app.deinit();

    app.redirectHttp(.{
        .port = 8080,
        .to = 3443,
        .exclude = &.{"/health"},
    });

    try std.testing.expect(app.redirect_http_config != null);
    try std.testing.expectEqual(@as(u16, 8080), app.redirect_http_config.?.port);
    try std.testing.expectEqual(@as(u16, 3443), app.redirect_http_config.?.to.?);
}

test "App.reloadTls() updates stored config before runtime exists" {
    var app = ziez.App.init(std.testing.allocator);
    defer app.deinit();

    try app.reloadTls(.{
        .cert = .{ .pem_bytes = "next-cert" },
        .key = .{ .pem_bytes = "next-key" },
        .min_version = .tls_1_3,
    });

    try std.testing.expect(app.tls_config != null);
    try std.testing.expectEqual(ziez.TlsVersion.tls_1_3, app.tls_config.?.min_version);
}

test "CipherSuite enum values match TLS 1.3 spec" {
    try std.testing.expectEqual(@as(u16, 0x1301), @intFromEnum(ziez.CipherSuite.AES_128_GCM_SHA256));
    try std.testing.expectEqual(@as(u16, 0x1302), @intFromEnum(ziez.CipherSuite.AES_256_GCM_SHA384));
    try std.testing.expectEqual(@as(u16, 0x1303), @intFromEnum(ziez.CipherSuite.CHACHA20_POLY1305_SHA256));
}

test "CertSource and KeySource variants" {
    const cert_file = ziez.tls.CertSource{ .file_path = "/etc/certs/cert.pem" };
    const cert_pem = ziez.tls.CertSource{ .pem_bytes = "-----BEGIN" };
    const cert_der = ziez.tls.CertSource{ .der_bytes = &[_]u8{0x30} };

    try std.testing.expectEqualStrings("/etc/certs/cert.pem", cert_file.file_path);

    const key_file = ziez.tls.KeySource{ .file_path = "/etc/certs/key.pem" };
    const key_pem = ziez.tls.KeySource{ .pem_bytes = "-----BEGIN" };
    const key_der = ziez.tls.KeySource{ .der_bytes = &[_]u8{0x30} };

    try std.testing.expectEqualStrings("/etc/certs/key.pem", key_file.file_path);
    _ = cert_pem;
    _ = cert_der;
    _ = key_pem;
    _ = key_der;
}

test "TlsVersion enum values" {
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(ziez.TlsVersion.tls_1_2));
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(ziez.TlsVersion.tls_1_3));
}
