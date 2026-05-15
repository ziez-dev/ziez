const std = @import("std");
const validator = @import("mod.zig");

pub const Format = enum {
    email,
    url,
    uuid,
    ipv4,
    ipv6,
    ip,
    alpha,
    alphanumeric,
    numeric,
    date,
    iso8601,
    base64,
    hexadecimal,
    slug,
    credit_card,
    lowercase,
    uppercase,
    json,
};

pub const StringRule = struct {
    min_length: ?usize = null,
    max_length: ?usize = null,
    pattern: ?[]const u8 = null,
    format: ?Format = null,
    trim: bool = false,
    custom: ?*const fn ([]const u8) bool = null,
};

pub const IntRule = struct {
    min: ?i64 = null,
    max: ?i64 = null,
};

pub const FloatRule = struct {
    min: ?f64 = null,
    max: ?f64 = null,
};

pub const ValidationError = struct {
    field: []const u8,
    message: []const u8,
};

pub const MAX_ERRORS: usize = 32;

pub const ValidationResult = struct {
    valid: bool,
    errors: []ValidationError,

    pub fn init() ValidationResult {
        return .{ .valid = true, .errors = &.{} };
    }
};

pub const ValidationErrors = struct {
    items: [MAX_ERRORS]ValidationError = undefined,
    len: usize = 0,

    pub fn add(self: *ValidationErrors, field: []const u8, message: []const u8) void {
        if (self.len >= MAX_ERRORS) return;
        self.items[self.len] = .{ .field = field, .message = message };
        self.len += 1;
    }

    pub fn toResult(self: *ValidationErrors) ValidationResult {
        return .{
            .valid = self.len == 0,
            .errors = self.items[0..self.len],
        };
    }
};

fn checkFormat(fmt: Format, value: []const u8) bool {
    return switch (fmt) {
        .email => validator.isEmail(value),
        .url => validator.isURL(value, .{}),
        .uuid => validator.isUUID(value),
        .ipv4 => validator.isIPv4(value),
        .ipv6 => validator.isIPv6(value),
        .ip => validator.isIP(value),
        .alpha => validator.isAlpha(value),
        .alphanumeric => validator.isAlphanumeric(value),
        .numeric => validator.isNumeric(value),
        .date => validator.isDate(value),
        .iso8601 => validator.isISO8601(value),
        .base64 => validator.isBase64(value),
        .hexadecimal => validator.isHexadecimal(value),
        .slug => validator.isSlug(value),
        .credit_card => validator.isCreditCard(value),
        .lowercase => validator.isLowercase(value),
        .uppercase => validator.isUppercase(value),
        .json => validator.isJSON(value),
    };
}

/// Validate a struct value using its `pub const rules` declaration.
pub fn validate(allocator: std.mem.Allocator, value: anytype) ValidationResult {
    const T = @TypeOf(value);
    const ti = @typeInfo(T);
    if (ti != .@"struct") {
        var errs = ValidationErrors{};
        errs.add("root", "only struct types can be validated");
        return errs.toResult();
    }

    const has_rules = @hasDecl(T, "rules");
    if (!has_rules) {
        // No rules declared — validate recursively for nested structs
        var errs = ValidationErrors{};
        validateFieldsRecursive(allocator, value, &errs);
        return errs.toResult();
    }

    const rules = T.rules;
    var errs = ValidationErrors{};
    validateStructWithRules(allocator, value, rules, &errs);
    return errs.toResult();
}

fn validateFieldsRecursive(allocator: std.mem.Allocator, value: anytype, errs: *ValidationErrors) void {
    const T = @TypeOf(value);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const fv = @field(value, field.name);
        validateFieldRecursive(allocator, field.name, fv, errs);
    }
}

fn validateFieldRecursive(allocator: std.mem.Allocator, field_name: []const u8, fv: anytype, errs: *ValidationErrors) void {
    _ = field_name;
    const F = @TypeOf(fv);
    const fti = @typeInfo(F);
    if (fti == .@"struct") {
        const nested_has_rules = @hasDecl(F, "rules");
        if (nested_has_rules) {
            validateStructWithRules(allocator, fv, F.rules, errs);
        } else {
            validateFieldsRecursive(allocator, fv, errs);
        }
    } else if (fti == .optional) {
        const child = @typeInfo(fti.optional.child);
        if (child == .@"struct") {
            if (fv) |v| {
                const NestedT = @TypeOf(v);
                const nested_has_rules = @hasDecl(NestedT, "rules");
                if (nested_has_rules) {
                    validateStructWithRules(allocator, v, NestedT.rules, errs);
                } else {
                    validateFieldsRecursive(allocator, v, errs);
                }
            }
        }
    }
}

fn validateStructWithRules(allocator: std.mem.Allocator, value: anytype, rules: anytype, errs: *ValidationErrors) void {
    const T = @TypeOf(value);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const fv = @field(value, field.name);
        const has_rule = @hasField(@TypeOf(rules), field.name);
        if (has_rule) {
            const rule = @field(rules, field.name);
            validateFieldWithRule(allocator, field.name, fv, rule, errs);
        } else {
            // No rule for this field — recurse if struct
            validateFieldRecursive(allocator, field.name, fv, errs);
        }
    }
}

fn validateFieldWithRule(allocator: std.mem.Allocator, field_name: []const u8, fv: anytype, rule: anytype, errs: *ValidationErrors) void {
    const F = @TypeOf(fv);
    const Rule = @TypeOf(rule);
    const rule_ti = @typeInfo(Rule);

    // Handle optional: skip if null, validate inner if non-null
    if (@typeInfo(F) == .optional) {
        if (fv) |inner| {
            validateFieldWithRule(allocator, field_name, inner, rule, errs);
        }
        return;
    }

    // Check if rule is StringRule
    if (rule_ti == .@"struct") {
        const is_string_rule = Rule == StringRule;
        const is_int_rule = Rule == IntRule;
        const is_float_rule = Rule == FloatRule;

        if (is_string_rule) {
            // Field must be []const u8
            validateStringField(field_name, fv, rule, errs);
        } else if (is_int_rule) {
            validateIntField(field_name, fv, rule, errs);
        } else if (is_float_rule) {
            validateFloatField(field_name, fv, rule, errs);
        } else {
            // Unknown rule type — try to match by field type
            validateByFieldType(allocator, field_name, fv, rule, errs);
        }
    }
}

fn validateStringField(field_name: []const u8, value: []const u8, rule: StringRule, errs: *ValidationErrors) void {
    if (rule.min_length) |min| {
        if (value.len < min) {
            errs.add(field_name, "must be at least %d characters");
            return;
        }
    }
    if (rule.max_length) |max| {
        if (value.len > max) {
            errs.add(field_name, "must be at most %d characters");
            return;
        }
    }
    if (rule.format) |fmt| {
        if (!checkFormat(fmt, value)) {
            errs.add(field_name, formatErrorMessage(fmt));
            return;
        }
    }
    if (rule.custom) |custom_fn| {
        if (!custom_fn(value)) {
            errs.add(field_name, "failed custom validation");
            return;
        }
    }
}

fn validateIntField(field_name: []const u8, value: anytype, rule: IntRule, errs: *ValidationErrors) void {
    const v: i64 = @intCast(value);
    if (rule.min) |min| {
        if (v < min) {
            errs.add(field_name, "must be at least %d");
            return;
        }
    }
    if (rule.max) |max| {
        if (v > max) {
            errs.add(field_name, "must be at most %d");
            return;
        }
    }
}

fn validateFloatField(field_name: []const u8, value: anytype, rule: FloatRule, errs: *ValidationErrors) void {
    const v: f64 = @floatCast(value);
    if (rule.min) |min| {
        if (v < min) {
            errs.add(field_name, "must be at least %d");
            return;
        }
    }
    if (rule.max) |max| {
        if (v > max) {
            errs.add(field_name, "must be at most %d");
            return;
        }
    }
}

fn validateByFieldType(allocator: std.mem.Allocator, field_name: []const u8, fv: anytype, rule: anytype, errs: *ValidationErrors) void {
    _ = rule;
    _ = field_name;
    const F = @TypeOf(fv);
    if (@typeInfo(F) == .@"struct") {
        const NestedT = F;
        const nested_has_rules = @hasDecl(NestedT, "rules");
        if (nested_has_rules) {
            validateStructWithRules(allocator, fv, NestedT.rules, errs);
        } else {
            validateFieldsRecursive(allocator, fv, errs);
        }
    }
}

fn formatErrorMessage(fmt: Format) []const u8 {
    return switch (fmt) {
        .email => "must be a valid email",
        .url => "must be a valid URL",
        .uuid => "must be a valid UUID",
        .ipv4 => "must be a valid IPv4 address",
        .ipv6 => "must be a valid IPv6 address",
        .ip => "must be a valid IP address",
        .alpha => "must contain only letters",
        .alphanumeric => "must contain only letters and numbers",
        .numeric => "must contain only digits",
        .date => "must be a valid date (YYYY-MM-DD)",
        .iso8601 => "must be a valid ISO 8601 datetime",
        .base64 => "must be valid base64",
        .hexadecimal => "must be valid hexadecimal",
        .slug => "must be a valid slug",
        .credit_card => "must be a valid credit card number",
        .lowercase => "must be lowercase",
        .uppercase => "must be uppercase",
        .json => "must be valid JSON",
    };
}

/// Validate with explicit rules (separate from struct declaration).
pub fn validateWithRules(allocator: std.mem.Allocator, value: anytype, rules: anytype) ValidationResult {
    var errs = ValidationErrors{};
    validateStructWithRules(allocator, value, rules, &errs);
    return errs.toResult();
}
