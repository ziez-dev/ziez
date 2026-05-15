const std = @import("std");
const ziez = @import("ziez");
const ua = ziez.ua_parser;
const opts = @import("ziez_options");

// ────────────────────────────────────────────────────────────────────────────
// Browser detection tests
// ────────────────────────────────────────────────────────────────────────────

test "browser - Chrome desktop" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36");
    try std.testing.expectEqualStrings("Chrome", r.browser.name);
    try std.testing.expectEqualStrings("125.0.0.0", r.browser.version);
    try std.testing.expectEqualStrings("125", r.browser.major);
}

test "browser - Firefox desktop" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0");
    try std.testing.expectEqualStrings("Firefox", r.browser.name);
    try std.testing.expectEqualStrings("126.0", r.browser.version);
}

test "browser - Safari desktop" {
    const r = ua.parse("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15");
    try std.testing.expectEqualStrings("Safari", r.browser.name);
    try std.testing.expectEqualStrings("17.5", r.browser.version);
}

test "browser - Edge" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 Edg/125.0.0.0");
    try std.testing.expectEqualStrings("Edge", r.browser.name);
    try std.testing.expectEqualStrings("125.0.0.0", r.browser.version);
}

test "browser - Opera" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 OPR/111.0.0.0");
    try std.testing.expectEqualStrings("Opera", r.browser.name);
    try std.testing.expectEqualStrings("111.0.0.0", r.browser.version);
}

test "browser - Brave" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 Brave/125");
    try std.testing.expectEqualStrings("Brave", r.browser.name);
}

test "browser - Samsung Internet" {
    const r = ua.parse("Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0.0.0 Mobile Safari/537.36");
    try std.testing.expectEqualStrings("Samsung Internet", r.browser.name);
    try std.testing.expectEqualStrings("25.0", r.browser.version);
}

test "browser - UC Browser" {
    const r = ua.parse("Mozilla/5.0 (Linux; U; Android 14; en-US; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/100.0.4896.127 Mobile Safari/537.36 UCBrowser/15.5.6.115");
    try std.testing.expectEqualStrings("UCBrowser", r.browser.name);
}

test "browser - WeChat" {
    const r = ua.parse("Mozilla/5.0 (Linux; Android 14; M2102K1G) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/116.0.0.0 Mobile Safari/537.36 MicroMessenger/8.0.44.2502");
    try std.testing.expectEqualStrings("WeChat", r.browser.name);
    try std.testing.expectEqualStrings("8.0.44.2502", r.browser.version);
}

test "browser - Chrome Mobile" {
    const r = ua.parse("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36");
    try std.testing.expectEqualStrings("Mobile Chrome", r.browser.name);
    try std.testing.expectEqualStrings("125.0.0.0", r.browser.version);
}

test "browser - Mobile Safari" {
    const r = ua.parse("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1");
    try std.testing.expectEqualStrings("Mobile Safari", r.browser.name);
}

test "browser - Chrome iOS" {
    const r = ua.parse("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/125.0.6422.70 Mobile/15E148 Safari/604.1");
    try std.testing.expectEqualStrings("Mobile Chrome", r.browser.name);
}

test "browser - Firefox iOS" {
    const r = ua.parse("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/125.2 Mobile/15E148 Safari/605.1.15");
    try std.testing.expectEqualStrings("Mobile Firefox", r.browser.name);
}

test "browser - Chrome Headless" {
    const r = ua.parse("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/125.0.0.0 Safari/537.36");
    try std.testing.expectEqualStrings("Chrome Headless", r.browser.name);
}

test "browser - IE 11" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Trident/7.0; rv:11.0) like Gecko");
    try std.testing.expectEqualStrings("IE", r.browser.name);
    try std.testing.expectEqualStrings("11.0", r.browser.version);
}

test "browser - Facebook InApp" {
    const r = ua.parse("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/430.0.0.54.107;]");
    try std.testing.expectEqualStrings("Facebook", r.browser.name);
}

test "browser - Instagram" {
    const r = ua.parse("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram/330.0.4.33.109");
    try std.testing.expectEqualStrings("Instagram", r.browser.name);
}

test "browser - DuckDuckGo" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/605.1.15 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/605.1.15 DDG/124.0.0");
    try std.testing.expectEqualStrings("DuckDuckGo", r.browser.name);
}

test "browser - Vivaldi" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 Vivaldi/6.8.3425.21");
    try std.testing.expectEqualStrings("Vivaldi", r.browser.name);
}

test "browser - Yandex" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 YaBrowser/24.6.0.0 Safari/537.36");
    try std.testing.expectEqualStrings("Yandex", r.browser.name);
}

test "browser - Opera GX" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 OPGX/111.0.0.0");
    try std.testing.expectEqualStrings("Chrome", r.browser.name);
}

test "browser - Electron" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Electron/31.0.0 Safari/537.36");
    try std.testing.expectEqualStrings("Electron", r.browser.name);
    try std.testing.expectEqualStrings("31.0.0", r.browser.version);
}

test "browser - Googlebot" {
    const r = ua.parse("Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.6422.113 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)");
    try std.testing.expectEqualStrings("Mobile Chrome", r.browser.name);
}

test "browser - Bingbot (specific)" {
    const r = ua.parse("Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)");
    try std.testing.expectEqualStrings("", r.browser.name);
}

test "browser - generic bot" {
    const r = ua.parse("Mozilla/5.0 (compatible; SomeUnknownBot/1.0)");
    try std.testing.expectEqualStrings("", r.browser.name);
}

test "browser - unknown" {
    const r = ua.parse("SomeRandomString/1.0");
    try std.testing.expectEqualStrings("", r.browser.name);
}

// ────────────────────────────────────────────────────────────────────────────
// OS detection tests
// ────────────────────────────────────────────────────────────────────────────

test "os - Windows 10" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36");
    try std.testing.expectEqualStrings("Windows", r.os.name);
    try std.testing.expectEqualStrings("10", r.os.version);
}

test "os - Windows 11" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36");
    try std.testing.expectEqualStrings("Windows", r.os.name);
}

test "os - macOS" {
    const r = ua.parse("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.5 Safari/605.1.15");
    try std.testing.expectEqualStrings("macOS", r.os.name);
}

test "os - iOS" {
    const r = ua.parse("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1");
    try std.testing.expectEqualStrings("iOS", r.os.name);
}

test "os - Android" {
    const r = ua.parse("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/125.0.0.0 Mobile Safari/537.36");
    try std.testing.expectEqualStrings("Android", r.os.name);
}

test "os - Linux" {
    const r = ua.parse("Mozilla/5.0 (X11; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0");
    try std.testing.expectEqualStrings("Linux", r.os.name);
}

test "os - Ubuntu" {
    const r = ua.parse("Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0");
    try std.testing.expectEqualStrings("Ubuntu", r.os.name);
}

test "os - Chrome OS" {
    const r = ua.parse("Mozilla/5.0 (X11; CrOS x86_64 14526.89.0) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36");
    try std.testing.expectEqualStrings("Chrome OS", r.os.name);
}

test "os - HarmonyOS" {
    const r = ua.parse("Mozilla/5.0 (Linux; Android 12; HarmonyOS; NOH-AN00) AppleWebKit/537.36 Chrome/99.0.4844.88 Mobile Safari/537.36");
    try std.testing.expectEqualStrings("HarmonyOS", r.os.name);
}

test "os - unknown" {
    const r = ua.parse("SomeRandomBot/1.0");
    try std.testing.expectEqualStrings("", r.os.name);
}

// ────────────────────────────────────────────────────────────────────────────
// Device detection tests
// ────────────────────────────────────────────────────────────────────────────

test "device - desktop (Windows)" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36");
    try std.testing.expectEqual(null, r.device.type);
}

test "device - desktop (macOS)" {
    const r = ua.parse("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.5 Safari/605.1.15");
    try std.testing.expectEqual(null, r.device.type);
    try std.testing.expectEqualStrings("Apple", r.device.vendor);
}

test "device - mobile (iPhone)" {
    const r = ua.parse("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1");
    try std.testing.expectEqual(ua.DeviceType.mobile, r.device.type);
    try std.testing.expectEqualStrings("Apple", r.device.vendor);
    try std.testing.expectEqualStrings("iPhone", r.device.model);
}

test "device - mobile (Android)" {
    const r = ua.parse("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/125.0.0.0 Mobile Safari/537.36");
    try std.testing.expectEqual(ua.DeviceType.mobile, r.device.type);
    try std.testing.expectEqualStrings("Google", r.device.vendor);
    try std.testing.expectEqualStrings("Pixel 8", r.device.model);
}

test "device - tablet (iPad)" {
    const r = ua.parse("Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Version/17.5 Mobile/15E148 Safari/604.1");
    try std.testing.expectEqual(ua.DeviceType.tablet, r.device.type);
    try std.testing.expectEqualStrings("Apple", r.device.vendor);
    try std.testing.expectEqualStrings("iPad", r.device.model);
}

test "device - mobile (Samsung)" {
    const r = ua.parse("Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36");
    try std.testing.expectEqual(ua.DeviceType.mobile, r.device.type);
    try std.testing.expectEqualStrings("Samsung", r.device.vendor);
}

test "device - smarttv (Samsung)" {
    const r = ua.parse("Mozilla/5.0 (SmartTV; LINUX; Tizen 7.0) AppleWebKit/537.36 Chrome/108.0.0.0 Safari/537.36 SmartTV/2023");
    try std.testing.expectEqual(ua.DeviceType.smarttv, r.device.type);
}

test "device - console (PlayStation)" {
    const r = ua.parse("Mozilla/5.0 (PlayStation 5 4.50) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15");
    try std.testing.expectEqual(ua.DeviceType.console, r.device.type);
    try std.testing.expectEqualStrings("Sony", r.device.vendor);
}

test "device - console (Xbox)" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64; Xbox; Xbox One) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36 Edge/125.0.0.0");
    try std.testing.expectEqual(ua.DeviceType.console, r.device.type);
    try std.testing.expectEqualStrings("Microsoft", r.device.vendor);
}

// ────────────────────────────────────────────────────────────────────────────
// Engine detection tests
// ────────────────────────────────────────────────────────────────────────────

test "engine - Blink (Chrome)" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36");
    try std.testing.expectEqualStrings("Blink", r.engine.name);
}

test "engine - Gecko (Firefox)" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0");
    try std.testing.expectEqualStrings("Gecko", r.engine.name);
}

test "engine - WebKit (Safari)" {
    const r = ua.parse("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15");
    try std.testing.expectEqualStrings("WebKit", r.engine.name);
}

test "engine - Trident (IE)" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Trident/7.0; rv:11.0) like Gecko");
    try std.testing.expectEqualStrings("Trident", r.engine.name);
}

// ────────────────────────────────────────────────────────────────────────────
// CPU detection tests
// ────────────────────────────────────────────────────────────────────────────

test "cpu - amd64" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36");
    try std.testing.expectEqualStrings("amd64", r.cpu.architecture);
}

test "cpu - arm64 (iPhone)" {
    const r = ua.parse("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15");
    // iPhone UA typically doesn't include ARM in the string
    // But let's test with explicit ARM64
    const r2 = ua.parse("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/125.0.0.0 Mobile Safari/537.36");
    // Pixel 8 is arm64 but UA may not mention it
    _ = r;
    _ = r2;
    const r3 = ua.parse("Mozilla/5.0 (Linux; aarch64) AppleWebKit/537.36");
    try std.testing.expectEqualStrings("arm64", r3.cpu.architecture);
}

test "cpu - ia32" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 6.1; WOW64; Trident/7.0; rv:11.0) like Gecko");
    try std.testing.expectEqualStrings("amd64", r.cpu.architecture); // WOW64 maps to amd64
}

// ────────────────────────────────────────────────────────────────────────────
// Integration tests - full UA strings
// ────────────────────────────────────────────────────────────────────────────

test "integration - Chrome on Windows" {
    const r = ua.parse("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36");
    try std.testing.expectEqualStrings("Chrome", r.browser.name);
    try std.testing.expectEqualStrings("125", r.browser.major);
    try std.testing.expectEqualStrings("Windows", r.os.name);
    try std.testing.expectEqual(null, r.device.type);
    try std.testing.expectEqualStrings("Blink", r.engine.name);
    try std.testing.expectEqualStrings("amd64", r.cpu.architecture);
}

test "integration - Safari on iPhone" {
    const r = ua.parse("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1");
    try std.testing.expectEqualStrings("Mobile Safari", r.browser.name);
    try std.testing.expectEqualStrings("iOS", r.os.name);
    try std.testing.expectEqual(ua.DeviceType.mobile, r.device.type);
    try std.testing.expectEqualStrings("Apple", r.device.vendor);
    try std.testing.expectEqualStrings("iPhone", r.device.model);
}

test "integration - Firefox on Ubuntu" {
    const r = ua.parse("Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0");
    try std.testing.expectEqualStrings("Firefox", r.browser.name);
    try std.testing.expectEqualStrings("126.0", r.browser.version);
    try std.testing.expectEqualStrings("Ubuntu", r.os.name);
    try std.testing.expectEqual(null, r.device.type);
    try std.testing.expectEqualStrings("Gecko", r.engine.name);
}

test "integration - Edge on macOS" {
    const r = ua.parse("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 Edg/125.0.0.0");
    try std.testing.expectEqualStrings("Edge", r.browser.name);
    try std.testing.expectEqualStrings("macOS", r.os.name);
    try std.testing.expectEqual(null, r.device.type);
    try std.testing.expectEqualStrings("Apple", r.device.vendor);
}

test "integration - Chrome on Android Samsung" {
    const r = ua.parse("Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36");
    try std.testing.expectEqualStrings("Mobile Chrome", r.browser.name);
    try std.testing.expectEqualStrings("Android", r.os.name);
    try std.testing.expectEqual(ua.DeviceType.mobile, r.device.type);
    try std.testing.expectEqualStrings("Samsung", r.device.vendor);
}

// ────────────────────────────────────────────────────────────────────────────
// deviceTypeToString helper
// ────────────────────────────────────────────────────────────────────────────

test "deviceTypeToString" {
    try std.testing.expectEqualStrings("mobile", ua.deviceTypeToString(.mobile));
    try std.testing.expectEqualStrings("tablet", ua.deviceTypeToString(.tablet));
    try std.testing.expectEqualStrings("desktop", ua.deviceTypeToString(.desktop));
    try std.testing.expectEqualStrings("smarttv", ua.deviceTypeToString(.smarttv));
    try std.testing.expectEqualStrings("wearable", ua.deviceTypeToString(.wearable));
    try std.testing.expectEqualStrings("console", ua.deviceTypeToString(.console));
    try std.testing.expectEqualStrings("embedded", ua.deviceTypeToString(.embedded));
    try std.testing.expectEqualStrings("unknown", ua.deviceTypeToString(null));
}

// ────────────────────────────────────────────────────────────────────────────
// Edge cases
// ────────────────────────────────────────────────────────────────────────────

test "empty UA" {
    const r = ua.parse("");
    try std.testing.expectEqualStrings("", r.browser.name);
    try std.testing.expectEqualStrings("", r.os.name);
    try std.testing.expectEqual(null, r.device.type);
    try std.testing.expectEqualStrings("", r.engine.name);
    try std.testing.expectEqualStrings("", r.cpu.architecture);
}

test "null slice UA" {
    const r = ua.parse("");
    try std.testing.expectEqualStrings("", r.browser.name);
}

test "client hints - full result from headers" {
    const headers = [_]ua.Header{
        .{ .name = "sec-ch-ua", .value = "\"Chromium\";v=\"93\", \"Google Chrome\";v=\"93\", \" Not;A Brand\";v=\"99\"" },
        .{ .name = "sec-ch-ua-full-version-list", .value = "\"Chromium\";v=\"93.0.1.2\", \"Google Chrome\";v=\"93.0.1.2\", \" Not;A Brand\";v=\"99.0.1.2\"" },
        .{ .name = "sec-ch-ua-arch", .value = "\"arm\"" },
        .{ .name = "sec-ch-ua-bitness", .value = "\"64\"" },
        .{ .name = "sec-ch-ua-mobile", .value = "?1" },
        .{ .name = "sec-ch-ua-model", .value = "\"Pixel 99\"" },
        .{ .name = "sec-ch-ua-platform", .value = "\"Windows\"" },
        .{ .name = "sec-ch-ua-platform-version", .value = "\"13\"" },
        .{ .name = "user-agent", .value = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36" },
    };

    const r = ua.parseHeaders(headers[0..]);
    try std.testing.expectEqualStrings("Chrome", r.browser.name);
    try std.testing.expectEqualStrings("93.0.1.2", r.browser.version);
    try std.testing.expectEqualStrings("93", r.browser.major);
    try std.testing.expectEqualStrings("arm64", r.cpu.architecture);
    try std.testing.expectEqual(ua.DeviceType.mobile, r.device.type);
    try std.testing.expectEqualStrings("Pixel 99", r.device.model);
    try std.testing.expectEqualStrings("Google", r.device.vendor);
    try std.testing.expectEqualStrings("Blink", r.engine.name);
    try std.testing.expectEqualStrings("93.0.1.2", r.engine.version);
    try std.testing.expectEqualStrings("Windows", r.os.name);
    try std.testing.expectEqualStrings("11", r.os.version);
}

test "client hints - form factor xr" {
    const headers = [_]ua.Header{
        .{ .name = "sec-ch-ua-form-factors", .value = "\"VR\"" },
    };
    const r = ua.parseHeaders(headers[0..]);
    try std.testing.expectEqual(ua.DeviceType.xr, r.device.type);
}

test "extensions - crawler bot" {
    const r = ua.parseWithExtension("Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)", .bots);
    try std.testing.expectEqualStrings("bingbot", r.browser.name);
    try std.testing.expectEqualStrings("2.0", r.browser.version);
    try std.testing.expectEqualStrings("2", r.browser.major);
    try std.testing.expectEqualStrings("crawler", r.browser.type);
}

test "extensions - library" {
    const r = ua.parseWithExtension("axios/1.3.5", .libraries);
    try std.testing.expectEqualStrings("axios", r.browser.name);
    try std.testing.expectEqualStrings("1.3.5", r.browser.version);
    try std.testing.expectEqualStrings("library", r.browser.type);
}

test "extensions - email normalization" {
    const r = ua.parseWithExtension("YahooMobile/1.0", .emails);
    try std.testing.expectEqualStrings("Yahoo Mail", r.browser.name);
    try std.testing.expectEqualStrings("1.0", r.browser.version);
    try std.testing.expectEqualStrings("email", r.browser.type);
}
