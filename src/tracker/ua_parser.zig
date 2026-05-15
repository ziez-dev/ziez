// Zig port of ua-parser-js v2.0.9 core regex maps.
// Upstream: https://github.com/faisalman/ua-parser-js

const std = @import("std");
const tables = @import("ua_parser_tables.zig");
const extension_tables = @import("ua_parser_extension_tables.zig");

const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

pub const VERSION = "2.0.9";
pub const UA_MAX_LENGTH = 500;

pub const DeviceType = enum {
    mobile,
    tablet,
    desktop,
    smarttv,
    wearable,
    console,
    embedded,
    inapp,
    xr,
};

pub const Browser = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    major: []const u8 = "",
    type: []const u8 = "",
};

pub const Os = struct {
    name: []const u8 = "",
    version: []const u8 = "",
};

pub const Device = struct {
    type: ?DeviceType = null,
    vendor: []const u8 = "",
    model: []const u8 = "",
};

pub const Engine = struct {
    name: []const u8 = "",
    version: []const u8 = "",
};

pub const Cpu = struct {
    architecture: []const u8 = "",
};

pub const Result = struct {
    ua: []const u8,
    browser: Browser,
    os: Os,
    device: Device,
    engine: Engine,
    cpu: Cpu,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Extension = enum {
    bots,
    clis,
    crawlers,
    extra_devices,
    emails,
    fetchers,
    inapps,
    libraries,
    mediaplayers,
    vehicles,
};

pub const Brand = struct {
    brand: []const u8,
    version: []const u8 = "",
};

pub const ClientHints = struct {
    brands: []const Brand = &.{},
    full_version_list: []const Brand = &.{},
    mobile: ?bool = null,
    model: []const u8 = "",
    platform: []const u8 = "",
    platform_version: []const u8 = "",
    architecture: []const u8 = "",
    bitness: []const u8 = "",
    form_factors: []const []const u8 = &.{},
};

pub const Parser = struct {
    ua: []const u8 = "",

    pub fn init(ua: []const u8) Parser {
        return .{ .ua = normalizeUA(ua) };
    }

    pub fn setUA(self: *Parser, ua: []const u8) *Parser {
        self.ua = normalizeUA(ua);
        return self;
    }

    pub fn getUA(self: *const Parser) []const u8 {
        return self.ua;
    }

    pub fn getBrowser(self: *const Parser) Browser {
        return detectBrowser(self.ua);
    }

    pub fn getCPU(self: *const Parser) Cpu {
        return detectCpu(self.ua);
    }

    pub fn getDevice(self: *const Parser) Device {
        return detectDevice(self.ua);
    }

    pub fn getEngine(self: *const Parser) Engine {
        return detectEngine(self.ua);
    }

    pub fn getOS(self: *const Parser) Os {
        return detectOs(self.ua);
    }

    pub fn getResult(self: *const Parser) Result {
        return parse(self.ua);
    }
};

pub fn parse(ua: []const u8) Result {
    scratch.reset();
    const normalized = normalizeUA(ua);
    return parseNormalized(normalized);
}

pub fn parseWithClientHints(ua: []const u8, hints: ClientHints) Result {
    scratch.reset();
    var result = parseNormalized(normalizeUA(ua));
    applyClientHints(&result, hints);
    return result;
}

pub fn parseWithExtension(ua: []const u8, extension: Extension) Result {
    const extensions = [_]Extension{extension};
    return parseWithExtensions(ua, extensions[0..]);
}

pub fn parseWithExtensions(ua: []const u8, extensions: []const Extension) Result {
    scratch.reset();
    const normalized = normalizeUA(ua);
    return .{
        .ua = normalized,
        .browser = detectBrowserWithExtensions(normalized, extensions),
        .os = detectOsWithExtensions(normalized, extensions),
        .device = detectDeviceWithExtensions(normalized, extensions),
        .engine = detectEngineWithExtensions(normalized, extensions),
        .cpu = detectCpuWithExtensions(normalized, extensions),
    };
}

pub fn parseHeaders(headers: []const Header) Result {
    scratch.reset();
    const ua = normalizeUA(findHeader(headers, "user-agent") orelse "");
    const hints = parseClientHints(headers);
    var result = parseNormalized(ua);
    applyClientHints(&result, hints);
    return result;
}

fn parseNormalized(normalized: []const u8) Result {
    return .{
        .ua = normalized,
        .browser = detectBrowser(normalized),
        .os = detectOs(normalized),
        .device = detectDevice(normalized),
        .engine = detectEngine(normalized),
        .cpu = detectCpu(normalized),
    };
}

pub fn deviceTypeToString(dt: ?DeviceType) []const u8 {
    if (dt) |d| {
        return switch (d) {
            .mobile => "mobile",
            .tablet => "tablet",
            .desktop => "desktop",
            .smarttv => "smarttv",
            .wearable => "wearable",
            .console => "console",
            .embedded => "embedded",
            .inapp => "inapp",
            .xr => "xr",
        };
    }
    return "unknown";
}

pub fn deviceTypeFromString(value: []const u8) ?DeviceType {
    if (eqlIgnoreCase(value, "mobile")) return .mobile;
    if (eqlIgnoreCase(value, "tablet")) return .tablet;
    if (eqlIgnoreCase(value, "desktop")) return .desktop;
    if (eqlIgnoreCase(value, "smarttv")) return .smarttv;
    if (eqlIgnoreCase(value, "wearable")) return .wearable;
    if (eqlIgnoreCase(value, "console")) return .console;
    if (eqlIgnoreCase(value, "embedded")) return .embedded;
    if (eqlIgnoreCase(value, "inapp")) return .inapp;
    if (eqlIgnoreCase(value, "xr")) return .xr;
    return null;
}

const Scratch = struct {
    const slots_len = 96;
    const slot_len = 512;

    buffers: [slots_len][slot_len]u8 = undefined,
    brand_buffers: [4][16]Brand = undefined,
    string_list_buffers: [4][16][]const u8 = undefined,
    index: usize = 0,
    brand_index: usize = 0,
    string_list_index: usize = 0,

    fn reset(self: *Scratch) void {
        self.index = 0;
        self.brand_index = 0;
        self.string_list_index = 0;
    }

    fn copy(self: *Scratch, value: []const u8) []const u8 {
        const slot = self.index % slots_len;
        self.index += 1;
        const len = @min(value.len, slot_len);
        @memcpy(self.buffers[slot][0..len], value[0..len]);
        return self.buffers[slot][0..len];
    }

    fn lower(self: *Scratch, value: []const u8) []const u8 {
        const slot = self.index % slots_len;
        self.index += 1;
        const len = @min(value.len, slot_len);
        for (value[0..len], 0..) |ch, i| {
            self.buffers[slot][i] = std.ascii.toLower(ch);
        }
        return self.buffers[slot][0..len];
    }

    fn build(self: *Scratch) ScratchBuilder {
        const slot = self.index % slots_len;
        self.index += 1;
        return .{ .buf = self.buffers[slot][0..] };
    }

    fn copyBrands(self: *Scratch, value: []const Brand) []const Brand {
        const slot = self.brand_index % self.brand_buffers.len;
        self.brand_index += 1;
        const len = @min(value.len, self.brand_buffers[slot].len);
        @memcpy(self.brand_buffers[slot][0..len], value[0..len]);
        return self.brand_buffers[slot][0..len];
    }

    fn copyStringList(self: *Scratch, value: []const []const u8) []const []const u8 {
        const slot = self.string_list_index % self.string_list_buffers.len;
        self.string_list_index += 1;
        const len = @min(value.len, self.string_list_buffers[slot].len);
        @memcpy(self.string_list_buffers[slot][0..len], value[0..len]);
        return self.string_list_buffers[slot][0..len];
    }
};

const ScratchBuilder = struct {
    buf: []u8,
    len: usize = 0,

    fn append(self: *ScratchBuilder, value: []const u8) void {
        const n = @min(value.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len .. self.len + n], value[0..n]);
        self.len += n;
    }

    fn appendByte(self: *ScratchBuilder, value: u8) void {
        if (self.len >= self.buf.len) return;
        self.buf[self.len] = value;
        self.len += 1;
    }

    fn slice(self: *ScratchBuilder) []const u8 {
        return self.buf[0..self.len];
    }
};

threadlocal var scratch: Scratch = .{};

const MAX_CAPTURES = 32;

const PcreCode = c.pcre2_code_8;

const RegexCache = struct {
    mutex: std.atomic.Mutex = .unlocked,
    caseless: std.StringHashMapUnmanaged(*PcreCode) = .empty,
    sensitive: std.StringHashMapUnmanaged(*PcreCode) = .empty,

    fn get(self: *RegexCache, pattern: []const u8, caseless: bool) ?*PcreCode {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
        defer self.mutex.unlock();

        var map = if (caseless) &self.caseless else &self.sensitive;
        if (map.get(pattern)) |code| return code;

        var err_code: c_int = 0;
        var err_offset: c.PCRE2_SIZE = 0;
        var options: u32 = 0;
        if (caseless) options |= c.PCRE2_CASELESS;

        const code = c.pcre2_compile_8(
            @ptrCast(pattern.ptr),
            pattern.len,
            options,
            &err_code,
            &err_offset,
            null,
        ) orelse return null;

        map.put(std.heap.page_allocator, pattern, code) catch {
            c.pcre2_code_free_8(code);
            return null;
        };
        return code;
    }
};

var regex_cache: RegexCache = .{};

const Captures = struct {
    values: [MAX_CAPTURES]?[]const u8 = @splat(null),
    count: usize = 0,

    fn get(self: *const Captures, index: usize) ?[]const u8 {
        if (index >= self.values.len) return null;
        return self.values[index];
    }
};

const Item = union(enum) {
    browser: *Browser,
    cpu: *Cpu,
    device: *Device,
    engine: *Engine,
    os: *Os,
};

fn detectBrowser(ua: []const u8) Browser {
    var browser: Browser = .{};
    _ = applyRules(.{ .browser = &browser }, ua, tables.browser_rules[0..]);
    if (browser.version.len > 0) browser.major = majorize(browser.version);
    return browser;
}

fn detectCpu(ua: []const u8) Cpu {
    var cpu: Cpu = .{};
    _ = applyRules(.{ .cpu = &cpu }, ua, tables.cpu_rules[0..]);
    return cpu;
}

fn detectDevice(ua: []const u8) Device {
    var device: Device = .{};
    _ = applyRules(.{ .device = &device }, ua, tables.device_rules[0..]);
    return device;
}

fn detectEngine(ua: []const u8) Engine {
    var engine: Engine = .{};
    _ = applyRules(.{ .engine = &engine }, ua, tables.engine_rules[0..]);
    return engine;
}

fn detectOs(ua: []const u8) Os {
    var os: Os = .{};
    _ = applyRules(.{ .os = &os }, ua, tables.os_rules[0..]);
    if (std.mem.eql(u8, os.name, "iOS") and std.mem.eql(u8, os.version, "18.6")) {
        if (execPattern("\\) Version\\/([\\d\\.]+)", ua, false)) |caps| {
            if (caps.get(1)) |real_version| {
                if (parseLeadingInt(real_version) >= 26) os.version = real_version;
            }
        }
    }
    return os;
}

fn detectBrowserWithExtensions(ua: []const u8, extensions: []const Extension) Browser {
    var browser: Browser = .{};
    for (extensions) |extension| {
        if (applyRules(.{ .browser = &browser }, ua, extensionBrowserRules(extension))) break;
    } else {
        _ = applyRules(.{ .browser = &browser }, ua, tables.browser_rules[0..]);
    }
    if (browser.version.len > 0) browser.major = majorize(browser.version);
    return browser;
}

fn detectCpuWithExtensions(ua: []const u8, extensions: []const Extension) Cpu {
    var cpu: Cpu = .{};
    for (extensions) |extension| {
        if (applyRules(.{ .cpu = &cpu }, ua, extensionCpuRules(extension))) return cpu;
    }
    _ = applyRules(.{ .cpu = &cpu }, ua, tables.cpu_rules[0..]);
    return cpu;
}

fn detectDeviceWithExtensions(ua: []const u8, extensions: []const Extension) Device {
    var device: Device = .{};
    for (extensions) |extension| {
        if (applyRules(.{ .device = &device }, ua, extensionDeviceRules(extension))) return device;
    }
    _ = applyRules(.{ .device = &device }, ua, tables.device_rules[0..]);
    return device;
}

fn detectEngineWithExtensions(ua: []const u8, extensions: []const Extension) Engine {
    var engine: Engine = .{};
    for (extensions) |extension| {
        if (applyRules(.{ .engine = &engine }, ua, extensionEngineRules(extension))) return engine;
    }
    _ = applyRules(.{ .engine = &engine }, ua, tables.engine_rules[0..]);
    return engine;
}

fn detectOsWithExtensions(ua: []const u8, extensions: []const Extension) Os {
    var os: Os = .{};
    for (extensions) |extension| {
        if (applyRules(.{ .os = &os }, ua, extensionOsRules(extension))) return os;
    }
    return detectOs(ua);
}

fn applyClientHints(result: *Result, hints: ClientHints) void {
    applyBrowserClientHints(&result.browser, hints);
    applyEngineClientHints(&result.engine, hints);
    applyCpuClientHints(&result.cpu, hints);
    applyDeviceClientHints(&result.device, hints);
    applyOsClientHints(&result.os, hints);
}

fn applyBrowserClientHints(browser: *Browser, hints: ClientHints) void {
    const brands = if (hints.full_version_list.len > 0) hints.full_version_list else hints.brands;
    var previous_name: []const u8 = "";

    for (brands) |brand| {
        if (isNotABrand(brand.brand)) continue;

        const mapped_name = mapBrowserHint(brand.brand);
        const previous_result = browser.name;
        const can_replace =
            previous_name.len == 0 or
            (std.mem.indexOf(u8, previous_name, "Chrom") != null and !std.mem.eql(u8, mapped_name, "Chromium")) or
            (std.mem.eql(u8, previous_name, "Edge") and std.mem.indexOf(u8, mapped_name, "WebView2") != null);

        if (can_replace and !(previous_result.len > 0 and std.mem.indexOf(u8, previous_result, "Chrom") == null and std.mem.indexOf(u8, mapped_name, "Chrom") != null)) {
            browser.name = mapped_name;
            browser.version = brand.version;
            browser.major = if (brand.version.len > 0) majorize(brand.version) else "";
        }

        previous_name = mapped_name;
    }
}

fn applyEngineClientHints(engine: *Engine, hints: ClientHints) void {
    const brands = if (hints.full_version_list.len > 0) hints.full_version_list else hints.brands;
    for (brands) |brand| {
        if (std.mem.eql(u8, brand.brand, "Chromium")) {
            engine.name = "Blink";
            engine.version = brand.version;
        }
    }
}

fn applyCpuClientHints(cpu: *Cpu, hints: ClientHints) void {
    if (hints.architecture.len == 0) return;
    var builder = scratch.build();
    builder.append(hints.architecture);
    if (std.mem.eql(u8, hints.bitness, "64")) builder.append("64");
    const parsed = detectCpu(builder.slice());
    if (parsed.architecture.len > 0) cpu.architecture = parsed.architecture;
}

fn applyDeviceClientHints(device: *Device, hints: ClientHints) void {
    if (hints.mobile == true) device.type = .mobile;

    if (hints.model.len > 0) {
        device.model = hints.model;
        if (device.type == null or device.vendor.len == 0) {
            var builder = scratch.build();
            builder.append("droid 9; ");
            builder.append(hints.model);
            builder.append(")");
            const reparsed = detectDevice(builder.slice());
            if (device.type == null and reparsed.type != null) device.type = reparsed.type;
            if (device.vendor.len == 0 and reparsed.vendor.len > 0) device.vendor = reparsed.vendor;
        }
    }

    for (hints.form_factors) |form_factor| {
        if (mapFormFactor(form_factor)) |mapped| {
            device.type = mapped;
            break;
        }
    }
}

fn applyOsClientHints(os: *Os, hints: ClientHints) void {
    if (hints.platform.len > 0) {
        os.name = hints.platform;
        os.version = hints.platform_version;
        if (std.mem.eql(u8, os.name, "Windows")) {
            os.version = if (parseLeadingInt(majorize(os.version)) >= 13) "11" else "10";
        }
    }
    if (std.mem.eql(u8, os.name, "Windows") and std.mem.eql(u8, hints.model, "Xbox")) {
        os.name = "Xbox";
        os.version = "";
    }
}

fn applyRules(item: Item, ua: []const u8, rules: []const tables.Rule) bool {
    if (ua.len == 0) return false;

    for (rules) |rule| {
        for (rule.patterns) |pattern| {
            if (execPattern(pattern, ua, true)) |caps| {
                for (rule.props, 0..) |prop, prop_index| {
                    const cap = caps.get(prop_index + 1);
                    setField(item, prop.field, applyProp(prop, cap));
                }
                return true;
            }
        }
    }
    return false;
}

fn applyProp(prop: tables.Prop, capture: ?[]const u8) ?[]const u8 {
    return switch (prop.kind) {
        .capture => if (capture) |v| if (v.len > 0) v else null else null,
        .static => prop.value,
        .static_null => null,
        .func => applyFunction(prop.func, capture, prop.mapper),
        .replace => blk: {
            const value = capture orelse break :blk null;
            if (value.len == 0) break :blk null;
            break :blk replaceValue(value, prop.replace);
        },
        .replace_func => blk: {
            const value = capture orelse break :blk null;
            if (value.len == 0) break :blk null;
            const replaced = replaceValue(value, prop.replace);
            break :blk applyFunction(prop.func, replaced, prop.mapper);
        },
    };
}

fn applyFunction(func: tables.Function, value: ?[]const u8, mapper: ?*const tables.Mapper) ?[]const u8 {
    const v = value orelse return null;
    return switch (func) {
        .lowerize => scratch.lower(v),
        .trim => trimLeading(v),
        .str_mapper => strMapper(v, mapper.?),
        .normalize_email_name => normalizeEmailName(v),
        .whatsapp_os => if (std.mem.eql(u8, v, "A")) "Android" else "iOS",
    };
}

fn setField(item: Item, field: tables.Field, value: ?[]const u8) void {
    const v = value orelse "";
    switch (item) {
        .browser => |browser| switch (field) {
            .name => browser.name = v,
            .version => browser.version = v,
            .major => browser.major = v,
            .type => browser.type = v,
            else => {},
        },
        .cpu => |cpu| switch (field) {
            .architecture => cpu.architecture = v,
            else => {},
        },
        .device => |device| switch (field) {
            .vendor => device.vendor = v,
            .model => device.model = v,
            .type => device.type = deviceTypeFromString(v),
            else => {},
        },
        .engine => |engine| switch (field) {
            .name => engine.name = v,
            .version => engine.version = v,
            else => {},
        },
        .os => |os| switch (field) {
            .name => os.name = normalizeOsName(v),
            .version => os.version = v,
            else => {},
        },
    }
}

fn execPattern(pattern: []const u8, subject: []const u8, caseless: bool) ?Captures {
    const code = regex_cache.get(pattern, caseless) orelse return null;

    const match_data = c.pcre2_match_data_create_from_pattern_8(code, null) orelse return null;
    defer c.pcre2_match_data_free_8(match_data);

    const rc = c.pcre2_match_8(
        code,
        @ptrCast(subject.ptr),
        subject.len,
        0,
        0,
        match_data,
        null,
    );
    if (rc <= 0) return null;

    const ovec = c.pcre2_get_ovector_pointer_8(match_data);
    var caps: Captures = .{};
    caps.count = @min(@as(usize, @intCast(rc)), MAX_CAPTURES);
    const unset = ~@as(c.PCRE2_SIZE, 0);
    for (0..caps.count) |i| {
        const start = ovec[i * 2];
        const end = ovec[i * 2 + 1];
        if (start == unset or end == unset or end < start) {
            caps.values[i] = null;
        } else {
            caps.values[i] = subject[@intCast(start)..@intCast(end)];
        }
    }
    return caps;
}

fn replaceValue(value: []const u8, replace: tables.Replace) []const u8 {
    if (replace.pattern.len == 0) return value;

    var builder = scratch.build();
    var offset: usize = 0;
    var replaced_any = false;

    while (offset <= value.len) {
        const haystack = value[offset..];
        const caps = execPattern(replace.pattern, haystack, replace.caseless) orelse break;
        const full = caps.get(0) orelse break;
        const rel_start = @intFromPtr(full.ptr) - @intFromPtr(haystack.ptr);
        const rel_end = rel_start + full.len;

        builder.append(haystack[0..rel_start]);
        appendReplacement(&builder, replace.replacement, &caps);
        replaced_any = true;

        offset += rel_end;
        if (!replace.global) {
            builder.append(value[offset..]);
            return builder.slice();
        }

        if (rel_end == rel_start) {
            if (offset >= value.len) break;
            builder.appendByte(value[offset]);
            offset += 1;
        }
    }

    if (!replaced_any) return value;
    if (offset < value.len) builder.append(value[offset..]);
    return builder.slice();
}

fn appendReplacement(builder: *ScratchBuilder, replacement: []const u8, caps: *const Captures) void {
    var i: usize = 0;
    while (i < replacement.len) {
        if (replacement[i] == '$' and i + 1 < replacement.len and std.ascii.isDigit(replacement[i + 1])) {
            const idx = replacement[i + 1] - '0';
            if (caps.get(idx)) |cap| builder.append(cap);
            i += 2;
            continue;
        }
        builder.appendByte(replacement[i]);
        i += 1;
    }
}

fn strMapper(value: []const u8, mapper: *const tables.Mapper) ?[]const u8 {
    for (mapper.entries) |entry| {
        for (entry.inputs) |input| {
            if (eqlIgnoreCase(input, value)) return entry.out;
        }
    }
    if (mapper.has_default) return mapper.default;
    return value;
}

fn parseClientHints(headers: []const Header) ClientHints {
    var hints: ClientHints = .{};

    if (findHeader(headers, "sec-ch-ua")) |value| {
        hints.brands = parseBrandList(value);
    }
    if (findHeader(headers, "sec-ch-ua-full-version-list")) |value| {
        hints.full_version_list = parseBrandList(value);
    }
    if (findHeader(headers, "sec-ch-ua-mobile")) |value| {
        hints.mobile = std.mem.indexOf(u8, value, "?1") != null;
    }
    if (findHeader(headers, "sec-ch-ua-model")) |value| {
        hints.model = stripQuotes(trimSpaces(value));
    }
    if (findHeader(headers, "sec-ch-ua-platform")) |value| {
        hints.platform = stripQuotes(trimSpaces(value));
    }
    if (findHeader(headers, "sec-ch-ua-platform-version")) |value| {
        hints.platform_version = stripQuotes(trimSpaces(value));
    }
    if (findHeader(headers, "sec-ch-ua-arch")) |value| {
        hints.architecture = stripQuotes(trimSpaces(value));
    }
    if (findHeader(headers, "sec-ch-ua-bitness")) |value| {
        hints.bitness = stripQuotes(trimSpaces(value));
    }
    if (findHeader(headers, "sec-ch-ua-form-factors")) |value| {
        hints.form_factors = parseStringList(value);
    }

    return hints;
}

fn parseBrandList(value: []const u8) []const Brand {
    var brands_buf: [16]Brand = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw_token| {
        if (count >= brands_buf.len) break;
        const token = trimSpaces(raw_token);
        if (token.len == 0) continue;

        var brand: []const u8 = token;
        var version: []const u8 = "";
        if (std.mem.indexOf(u8, token, ";v=")) |idx| {
            brand = token[0..idx];
            version = token[idx + 3 ..];
        }

        brands_buf[count] = .{
            .brand = stripQuotes(trimSpaces(brand)),
            .version = stripQuotes(trimSpaces(version)),
        };
        count += 1;
    }
    return scratch.copyBrands(brands_buf[0..count]);
}

fn parseStringList(value: []const u8) []const []const u8 {
    var items_buf: [16][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw_token| {
        if (count >= items_buf.len) break;
        const item = stripQuotes(trimSpaces(raw_token));
        if (item.len == 0) continue;
        items_buf[count] = item;
        count += 1;
    }
    return scratch.copyStringList(items_buf[0..count]);
}

fn findHeader(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn mapBrowserHint(value: []const u8) []const u8 {
    if (eqlIgnoreCase(value, "Google Chrome")) return "Chrome";
    if (eqlIgnoreCase(value, "Microsoft Edge")) return "Edge";
    if (eqlIgnoreCase(value, "Microsoft Edge WebView2")) return "Edge WebView2";
    if (eqlIgnoreCase(value, "Android WebView")) return "Chrome WebView";
    if (eqlIgnoreCase(value, "HeadlessChrome")) return "Chrome Headless";
    if (eqlIgnoreCase(value, "HuaweiBrowser")) return "Huawei Browser";
    if (eqlIgnoreCase(value, "Miui Browser")) return "MIUI Browser";
    if (eqlIgnoreCase(value, "OperaMobile")) return "Opera Mobi";
    if (eqlIgnoreCase(value, "YaBrowser")) return "Yandex";
    return value;
}

fn mapFormFactor(value: []const u8) ?DeviceType {
    if (eqlIgnoreCase(value, "Automotive")) return .embedded;
    if (eqlIgnoreCase(value, "Mobile")) return .mobile;
    if (eqlIgnoreCase(value, "Tablet") or eqlIgnoreCase(value, "EInk")) return .tablet;
    if (eqlIgnoreCase(value, "TV")) return .smarttv;
    if (eqlIgnoreCase(value, "Watch")) return .wearable;
    if (eqlIgnoreCase(value, "VR") or eqlIgnoreCase(value, "XR")) return .xr;
    if (eqlIgnoreCase(value, "Desktop") or eqlIgnoreCase(value, "Unknown")) return null;
    return null;
}

fn normalizeEmailName(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "YahooMobile")) return "Yahoo Mail";
    if (std.mem.eql(u8, value, "YahooMail")) return "Yahoo Mail";
    if (std.mem.eql(u8, value, "K-9")) return "K-9 Mail";
    if (std.mem.eql(u8, value, "K-9 Mail")) return "K-9 Mail";
    if (std.mem.eql(u8, value, "Zdesktop")) return "Zimbra";
    if (std.mem.eql(u8, value, "zdesktop")) return "Zimbra";
    return value;
}

fn extensionBrowserRules(extension: Extension) []const tables.Rule {
    return switch (extension) {
        .bots => extension_tables.bots_browser_rules[0..],
        .clis => extension_tables.clis_browser_rules[0..],
        .crawlers => extension_tables.crawlers_browser_rules[0..],
        .extra_devices => extension_tables.extra_devices_browser_rules[0..],
        .emails => extension_tables.emails_browser_rules[0..],
        .fetchers => extension_tables.fetchers_browser_rules[0..],
        .inapps => extension_tables.inapps_browser_rules[0..],
        .libraries => extension_tables.libraries_browser_rules[0..],
        .mediaplayers => extension_tables.mediaplayers_browser_rules[0..],
        .vehicles => extension_tables.vehicles_browser_rules[0..],
    };
}

fn extensionCpuRules(extension: Extension) []const tables.Rule {
    return switch (extension) {
        .bots => extension_tables.bots_cpu_rules[0..],
        .clis => extension_tables.clis_cpu_rules[0..],
        .crawlers => extension_tables.crawlers_cpu_rules[0..],
        .extra_devices => extension_tables.extra_devices_cpu_rules[0..],
        .emails => extension_tables.emails_cpu_rules[0..],
        .fetchers => extension_tables.fetchers_cpu_rules[0..],
        .inapps => extension_tables.inapps_cpu_rules[0..],
        .libraries => extension_tables.libraries_cpu_rules[0..],
        .mediaplayers => extension_tables.mediaplayers_cpu_rules[0..],
        .vehicles => extension_tables.vehicles_cpu_rules[0..],
    };
}

fn extensionDeviceRules(extension: Extension) []const tables.Rule {
    return switch (extension) {
        .bots => extension_tables.bots_device_rules[0..],
        .clis => extension_tables.clis_device_rules[0..],
        .crawlers => extension_tables.crawlers_device_rules[0..],
        .extra_devices => extension_tables.extra_devices_device_rules[0..],
        .emails => extension_tables.emails_device_rules[0..],
        .fetchers => extension_tables.fetchers_device_rules[0..],
        .inapps => extension_tables.inapps_device_rules[0..],
        .libraries => extension_tables.libraries_device_rules[0..],
        .mediaplayers => extension_tables.mediaplayers_device_rules[0..],
        .vehicles => extension_tables.vehicles_device_rules[0..],
    };
}

fn extensionEngineRules(extension: Extension) []const tables.Rule {
    return switch (extension) {
        .bots => extension_tables.bots_engine_rules[0..],
        .clis => extension_tables.clis_engine_rules[0..],
        .crawlers => extension_tables.crawlers_engine_rules[0..],
        .extra_devices => extension_tables.extra_devices_engine_rules[0..],
        .emails => extension_tables.emails_engine_rules[0..],
        .fetchers => extension_tables.fetchers_engine_rules[0..],
        .inapps => extension_tables.inapps_engine_rules[0..],
        .libraries => extension_tables.libraries_engine_rules[0..],
        .mediaplayers => extension_tables.mediaplayers_engine_rules[0..],
        .vehicles => extension_tables.vehicles_engine_rules[0..],
    };
}

fn extensionOsRules(extension: Extension) []const tables.Rule {
    return switch (extension) {
        .bots => extension_tables.bots_os_rules[0..],
        .clis => extension_tables.clis_os_rules[0..],
        .crawlers => extension_tables.crawlers_os_rules[0..],
        .extra_devices => extension_tables.extra_devices_os_rules[0..],
        .emails => extension_tables.emails_os_rules[0..],
        .fetchers => extension_tables.fetchers_os_rules[0..],
        .inapps => extension_tables.inapps_os_rules[0..],
        .libraries => extension_tables.libraries_os_rules[0..],
        .mediaplayers => extension_tables.mediaplayers_os_rules[0..],
        .vehicles => extension_tables.vehicles_os_rules[0..],
    };
}

fn stripQuotes(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and (value[start] == '"' or value[start] == '\\')) start += 1;
    while (end > start and (value[end - 1] == '"' or value[end - 1] == '\\')) end -= 1;
    return value[start..end];
}

fn trimSpaces(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn majorize(version: []const u8) []const u8 {
    if (version.len == 0) return "";
    var builder = scratch.build();
    for (version) |ch| {
        if (std.ascii.isDigit(ch) or ch == '.') builder.appendByte(ch);
    }
    const stripped = builder.slice();
    if (stripped.len == 0) return "";
    if (std.mem.indexOfScalar(u8, stripped, '.')) |idx| return stripped[0..idx];
    return stripped;
}

fn normalizeUA(ua: []const u8) []const u8 {
    const trimmed = trimLeading(ua);
    return trimmed[0..@min(trimmed.len, UA_MAX_LENGTH)];
}

fn trimLeading(value: []const u8) []const u8 {
    var start: usize = 0;
    while (start < value.len and std.ascii.isWhitespace(value[start])) start += 1;
    return value[start..];
}

fn normalizeOsName(value: []const u8) []const u8 {
    if (eqlIgnoreCase(value, "mac os x") or eqlIgnoreCase(value, "macintosh") or eqlIgnoreCase(value, "mac_powerpc")) return "macOS";
    return value;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isNotABrand(value: []const u8) bool {
    return containsIgnoreCase(value, "not") and containsIgnoreCase(value, "brand");
}

fn parseLeadingInt(value: []const u8) u32 {
    var n: u32 = 0;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch)) break;
        n = n * 10 + @as(u32, ch - '0');
    }
    return n;
}
