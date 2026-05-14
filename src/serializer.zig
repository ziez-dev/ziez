const std = @import("std");

/// Declarative serialization config for type T.
/// All metadata is comptime-known; the compiler generates specialized code per type.
pub fn SerializerConfig(comptime _: type) type {
    return struct {
        /// Whitelist: if set, only these fields are included in output.
        fields: ?[]const []const u8 = null,

        /// Blacklist: these fields are always excluded.
        exclude: []const []const u8 = &.{},

        /// Per-field transform functions.
        /// Declare as: `struct { pub const field_name = transformFn; }`
        /// where transformFn is `*const fn (FieldType) OutputType`.
        transforms: ?type = null,

        /// Computed/virtual fields not present in the original struct.
        /// Declare as: `struct { pub const field_name = computeFn; }`
        /// where computeFn is `*const fn (*const T) OutputType`.
        computed: ?type = null,

        /// Nested serializer configs for sub-objects.
        /// Declare as: `struct { pub const field_name = SerializerConfig(SubType){...}; }`
        nested: ?type = null,

        /// Per-field condition functions. Field included only when condition returns true.
        /// Declare as: `struct { pub const field_name = conditionFn; }`
        /// where conditionFn is `*const fn (*const T) bool`.
        conditions: ?type = null,

        /// If true, fields with null values are omitted from output.
        exclude_null: bool = false,

        /// Struct mapping group names to field arrays.
        /// Declare as: `struct { pub const @"group_name" = &.{"field1", "field2"}; }`
        group_fields: ?type = null,

        /// Active group names for this serialization context (runtime).
        groups: []const []const u8 = &.{},
    };
}

// --- Comptime helper functions ---

fn isExcluded(comptime name: []const u8, comptime exclude: []const []const u8) bool {
    for (exclude) |e| {
        if (std.mem.eql(u8, name, e)) return true;
    }
    return false;
}

fn inWhitelist(comptime name: []const u8, comptime whitelist: []const []const u8) bool {
    for (whitelist) |w| {
        if (std.mem.eql(u8, name, w)) return true;
    }
    return false;
}

fn hasDecl(comptime DeclType: type, comptime name: []const u8) bool {
    const info = @typeInfo(DeclType);
    if (info != .@"struct") return false;
    for (info.@"struct".decls) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return true;
    }
    return false;
}

fn fieldInGroup(comptime field_name: []const u8, comptime group_fields: []const []const u8) bool {
    for (group_fields) |gf| {
        if (std.mem.eql(u8, field_name, gf)) return true;
    }
    return false;
}

fn isFieldInActiveGroups(
    comptime field_name: []const u8,
    comptime GroupFields: type,
    active_groups: []const []const u8,
) bool {
    const info = @typeInfo(GroupFields);
    if (info != .@"struct") return true;
    if (active_groups.len == 0) return true;

    inline for (info.@"struct".decls) |gdecl| {
        const group_list = @field(GroupFields, gdecl.name);
        if (fieldInGroup(field_name, group_list)) {
            for (active_groups) |active| {
                if (std.mem.eql(u8, active, gdecl.name)) return true;
            }
        }
    }
    return false;
}

fn isComputedInActiveGroups(
    comptime decl_name: []const u8,
    comptime GroupFields: type,
    active_groups: []const []const u8,
) bool {
    const info = @typeInfo(GroupFields);
    if (info != .@"struct") return true;
    if (active_groups.len == 0) return true;

    var in_any_group = false;
    inline for (info.@"struct".decls) |gdecl| {
        const group_list = @field(GroupFields, gdecl.name);
        if (fieldInGroup(decl_name, group_list)) {
            in_any_group = true;
            for (active_groups) |active| {
                if (std.mem.eql(u8, active, gdecl.name)) return true;
            }
        }
    }

    if (!in_any_group) return true;
    return false;
}

// --- Core serialization ---

pub fn serialize(
    allocator: std.mem.Allocator,
    data: anytype,
    comptime config: anytype,
) ![]const u8 {
    return try serializeInternal(allocator, data, config);
}

fn serializeInternal(
    allocator: std.mem.Allocator,
    data: anytype,
    comptime config: anytype,
) ![]const u8 {
    const RawT = @TypeOf(data);
    const T = switch (@typeInfo(RawT)) {
        .pointer => |info| info.child,
        else => RawT,
    };
    const actual_data: T = switch (@typeInfo(RawT)) {
        .pointer => |info| if (info.size == .one) data.* else data,
        else => data,
    };
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("serialize() expects a struct type, got " ++ @typeName(T));
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };

    try jw.beginObject();

    // --- Data fields ---
    // Comptime filtering uses comptime bool flags to skip fields.
    // Runtime filtering (groups, conditions, exclude_null) uses nested if-blocks
    // to avoid comptime control flow (continue) inside runtime conditions.
    inline for (type_info.@"struct".fields) |field| {
        const comptime_excluded = comptime isExcluded(field.name, config.exclude);
        const comptime_not_in_whitelist = comptime blk: {
            if (config.fields) |whitelist| {
                break :blk !inWhitelist(field.name, whitelist);
            }
            break :blk false;
        };
        if (comptime_excluded or comptime_not_in_whitelist) continue;

        // Runtime group check
        const in_group = if (comptime config.group_fields != null)
            isFieldInActiveGroups(field.name, config.group_fields.?, config.groups)
        else
            true;

        if (in_group) {
            // Runtime condition check
            const cond_passed = if (comptime config.conditions != null and hasDecl(config.conditions.?, field.name))
                @field(config.conditions.?, field.name)(&actual_data)
            else
                true;

            if (cond_passed) {
                const value = @field(actual_data, field.name);

                // Runtime null check
                const not_null = if (comptime config.exclude_null and @typeInfo(field.type) == .@"optional")
                    value != null
                else
                    true;

                if (not_null) {
                    try jw.objectField(field.name);

                    // Transform
                    const has_transform = comptime config.transforms != null and hasDecl(config.transforms.?, field.name);
                    if (comptime has_transform) {
                        const transform_fn = comptime @field(config.transforms.?, field.name);
                        const transformed = transform_fn(value);
                        try jw.write(transformed);
                    } else if (comptime config.nested != null and hasDecl(config.nested.?, field.name)) {
                        // Nested serialization
                        const nested_config = comptime @field(config.nested.?, field.name);
                        if (comptime @typeInfo(field.type) == .@"optional") {
                            if (value) |v| {
                                const nested_json = try serializeInternal(allocator, v, nested_config);
                                defer allocator.free(nested_json);
                                try jw.beginWriteRaw();
                                try jw.writer.writeAll(nested_json);
                                jw.endWriteRaw();
                            } else {
                                try jw.write(@as(?void, null));
                            }
                        } else {
                            const nested_json = try serializeInternal(allocator, value, nested_config);
                            defer allocator.free(nested_json);
                            try jw.beginWriteRaw();
                            try jw.writer.writeAll(nested_json);
                            jw.endWriteRaw();
                        }
                    } else {
                        try jw.write(value);
                    }
                }
            }
        }
    }

    // --- Computed fields ---
    if (config.computed) |Computed| {
        const computed_info = @typeInfo(Computed);
        inline for (computed_info.@"struct".decls) |decl| {
            const in_group = if (comptime config.group_fields != null)
                isComputedInActiveGroups(decl.name, config.group_fields.?, config.groups)
            else
                true;

            if (in_group) {
                const compute_fn = @field(Computed, decl.name);
                const result = compute_fn(&actual_data);

                try jw.objectField(decl.name);
                try jw.write(result);
            }
        }
    }

    try jw.endObject();
    return aw.toOwnedSlice();
}

/// Serialize a slice/array of items, each with the same config.
pub fn serializeMany(
    allocator: std.mem.Allocator,
    items: anytype,
    comptime config: anytype,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };

    try jw.beginArray();
    for (items) |item| {
        const item_json = try serializeInternal(allocator, item, config);
        defer allocator.free(item_json);
        try jw.beginWriteRaw();
        try jw.writer.writeAll(item_json);
        jw.endWriteRaw();
    }
    try jw.endArray();

    return aw.toOwnedSlice();
}
