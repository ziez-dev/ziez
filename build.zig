const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .linux) .{ .abi = .musl } else .{},
    });
    const optimize = b.standardOptimizeOption(.{});

    // --- Brotli C library ---
    const upstream = b.dependency("brotli", .{});

    const brotli_root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    const brotli_lib = b.addLibrary(.{
        .name = "brotli_lib",
        .root_module = brotli_root_module,
    });
    brotli_lib.root_module.addIncludePath(upstream.path("c/include"));

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const c_root = upstream.path("c");
    const c_sources = getCSources(arena_alloc, upstream.builder.build_root, b.graph.io, "c", b.allocator);
    defer b.allocator.free(c_sources);

    if (c_sources.len == 0) {
        std.debug.print("Error: no .c source files found in brotli/c\n", .{});
        return;
    }

    brotli_lib.root_module.addCSourceFiles(.{
        .root = c_root,
        .files = c_sources,
    });

    switch (target.result.os.tag) {
        .linux => brotli_lib.root_module.addCMacro("OS_LINUX", "1"),
        .freebsd => brotli_lib.root_module.addCMacro("OS_FREEBSD", "1"),
        .macos => brotli_lib.root_module.addCMacro("OS_MACOSX", "1"),
        else => {},
    }

    b.installArtifact(brotli_lib);

    const pcre2_source_root = b.path("include/pcre2");
    const pcre2_generated_headers = b.addWriteFiles();
    const pcre2_include = pcre2_generated_headers.getDirectory();
    _ = pcre2_generated_headers.addCopyFile(pcre2_source_root.path(b, "pcre2.h.generic"), "pcre2.h");
    _ = pcre2_generated_headers.addCopyFile(pcre2_source_root.path(b, "config.h.generic"), "config.h");
    const pcre2_chartables = pcre2_generated_headers.addCopyFile(pcre2_source_root.path(b, "pcre2_chartables.c.dist"), "pcre2_chartables.c");
    const pcre2_root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    const pcre2_lib = b.addLibrary(.{
        .name = "pcre2_8",
        .root_module = pcre2_root_module,
    });
    pcre2_lib.root_module.addIncludePath(pcre2_include);
    pcre2_lib.root_module.addIncludePath(pcre2_source_root);
    pcre2_lib.root_module.addCMacro("HAVE_CONFIG_H", "1");
    pcre2_lib.root_module.addCMacro("PCRE2_CODE_UNIT_WIDTH", "8");
    pcre2_lib.root_module.addCMacro("PCRE2_STATIC", "1");
    pcre2_lib.root_module.addCMacro("SUPPORT_UNICODE", "1");
    pcre2_lib.root_module.addCMacro("SUPPORT_PCRE2_8", "1");
    pcre2_lib.root_module.addCSourceFiles(.{
        .root = pcre2_source_root,
        .files = &.{
            "pcre2_auto_possess.c",
            "pcre2_chkdint.c",
            "pcre2_compile.c",
            "pcre2_compile_class.c",
            "pcre2_config.c",
            "pcre2_context.c",
            "pcre2_convert.c",
            "pcre2_dfa_match.c",
            "pcre2_error.c",
            "pcre2_extuni.c",
            "pcre2_find_bracket.c",
            "pcre2_maketables.c",
            "pcre2_match.c",
            "pcre2_match_data.c",
            "pcre2_newline.c",
            "pcre2_ord2utf.c",
            "pcre2_pattern_info.c",
            "pcre2_script_run.c",
            "pcre2_serialize.c",
            "pcre2_string_utils.c",
            "pcre2_study.c",
            "pcre2_substitute.c",
            "pcre2_substring.c",
            "pcre2_tables.c",
            "pcre2_ucd.c",
            "pcre2_valid_utf.c",
            "pcre2_xclass.c",
        },
    });
    pcre2_lib.root_module.addCSourceFile(.{ .file = pcre2_chartables });
    b.installArtifact(pcre2_lib);

    const brotli_translate = b.addTranslateC(.{
        .root_source_file = b.path("include/brotli_c.h"),
        .target = target,
        .optimize = optimize,
    });
    brotli_translate.addIncludePath(upstream.path("c/include"));

    const brotli_c_mod = b.addModule("brotli_c", .{
        .root_source_file = brotli_translate.getOutput(),
    });

    // --- ziez module ---
    const ziez_mod = b.addModule("ziez", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "brotli_c", .module = brotli_c_mod },
        },
    });
    ziez_mod.addIncludePath(pcre2_include);
    ziez_mod.addIncludePath(pcre2_source_root);
    ziez_mod.linkLibrary(brotli_lib);
    ziez_mod.linkLibrary(pcre2_lib);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "ziez",
        .root_module = lib_mod,
    });
    lib.root_module.addImport("brotli_c", brotli_c_mod);
    lib.root_module.addIncludePath(pcre2_include);
    lib.root_module.addIncludePath(pcre2_source_root);
    lib.root_module.linkLibrary(brotli_lib);
    lib.root_module.linkLibrary(pcre2_lib);
    b.installArtifact(lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziez", .module = ziez_mod },
        },
    });

    const example = b.addExecutable(.{
        .name = "ziez-basic",
        .root_module = exe_mod,
    });
    b.installArtifact(example);

    const run_cmd = b.addRunArtifact(example);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the basic example");
    run_step.dependOn(&run_cmd.step);

    // Serialization example
    const ser_exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/serialization.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziez", .module = ziez_mod },
        },
    });

    const ser_example = b.addExecutable(.{
        .name = "ziez-serialization",
        .root_module = ser_exe_mod,
    });
    b.installArtifact(ser_example);

    const ser_run_cmd = b.addRunArtifact(ser_example);
    ser_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| ser_run_cmd.addArgs(args);

    const ser_run_step = b.step("run-serialization", "Run the serialization example");
    ser_run_step.dependOn(&ser_run_cmd.step);

    // Interceptor & Pipe example
    const ic_optimize = if (optimize == .Debug) .ReleaseSmall else optimize;
    const ic_exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/interceptor_pipe.zig"),
        .target = target,
        .optimize = ic_optimize,
        .imports = &.{
            .{ .name = "ziez", .module = ziez_mod },
        },
    });

    const ic_example = b.addExecutable(.{
        .name = "ziez-interceptor-pipe",
        .root_module = ic_exe_mod,
    });
    b.installArtifact(ic_example);

    const ic_run_cmd = b.addRunArtifact(ic_example);
    ic_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| ic_run_cmd.addArgs(args);

    const ic_run_step = b.step("run-interceptor-pipe", "Run the interceptor & pipe example");
    ic_run_step.dependOn(&ic_run_cmd.step);

    // Streaming example
    const stream_exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/streaming.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziez", .module = ziez_mod },
        },
    });

    const stream_example = b.addExecutable(.{
        .name = "ziez-streaming",
        .root_module = stream_exe_mod,
    });
    b.installArtifact(stream_example);

    const stream_run_cmd = b.addRunArtifact(stream_example);
    stream_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| stream_run_cmd.addArgs(args);

    const stream_run_step = b.step("run-streaming", "Run the streaming example");
    stream_run_step.dependOn(&stream_run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const test_ua_step = b.step("test-ua", "Run UA parser tests only");
    const io = b.graph.io;

    var test_dir = b.build_root.handle.openDir(io, "tests", .{ .iterate = true }) catch return;
    defer test_dir.close(io);

    var walker = test_dir.walk(b.allocator) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".test.zig")) continue;

        const test_path = std.fmt.allocPrint(b.allocator, "tests/{s}", .{entry.path}) catch continue;

        const test_mod = b.createModule(.{
            .root_source_file = b.path(test_path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziez", .module = ziez_mod },
            },
        });

        const unit_test = b.addTest(.{
            .root_module = test_mod,
        });

        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
        if (std.mem.eql(u8, entry.path, "ua_parser.test.zig")) {
            test_ua_step.dependOn(&run_unit_test.step);
        }
    }
}

fn getCSources(arena: std.mem.Allocator, parent: std.Build.Cache.Directory, io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) [][]const u8 {
    var cr_dir = parent.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Error: {}, opening {s}\n", .{ err, dir_path });
        return &[_][]const u8{};
    };
    defer cr_dir.close(io);

    var walker = cr_dir.walk(arena) catch |err| {
        std.debug.print("Error: {}, walking {s}\n", .{ err, dir_path });
        return &[_][]const u8{};
    };
    defer walker.deinit();

    var list: std.ArrayListAligned([]const u8, null) = .empty;
    defer list.deinit(allocator);

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, "fuzz/")) continue;
        if (std.mem.startsWith(u8, entry.path, "tools/")) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".c")) continue;
        const duped = arena.dupe(u8, entry.path) catch continue;
        list.append(arena, duped) catch continue;
    }

    return list.toOwnedSlice(allocator) catch &[_][]const u8{};
}
