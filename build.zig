const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .linux) .{ .abi = .musl } else .{},
    });
    const optimize = b.standardOptimizeOption(.{});

    // --- ziez module ---
    const ziez_mod = b.addModule("ziez", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "ziez",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // --- Examples ---

    // Basic example
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

    // Multipart example
    {
        const mp_exe_mod = b.createModule(.{
            .root_source_file = b.path("examples/multipart.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ziez", .module = ziez_mod }},
        });
        const mp_example = b.addExecutable(.{ .name = "ziez-multipart", .root_module = mp_exe_mod });
        b.installArtifact(mp_example);
        const mp_run_cmd = b.addRunArtifact(mp_example);
        mp_run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| mp_run_cmd.addArgs(args);
        const mp_run_step = b.step("run-multipart", "Run the multipart upload example");
        mp_run_step.dependOn(&mp_run_cmd.step);
    }

    // ── Tests ─────────────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run unit tests");
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
    }

    // Integration tests (auto-discover tests/integrations/*.test.zig)
    const integration_step = b.step("integration", "Run integration tests");

    var integ_dir = b.build_root.handle.openDir(io, "tests/integrations", .{ .iterate = true }) catch null;
    if (integ_dir) |*dir| {
        defer dir.close(io);
        var integ_walker = dir.walk(b.allocator) catch return;
        defer integ_walker.deinit();
        while (integ_walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".test.zig")) continue;
            const integ_path = std.fmt.allocPrint(b.allocator, "tests/integrations/{s}", .{entry.path}) catch continue;
            const integ_mod = b.createModule(.{
                .root_source_file = b.path(integ_path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "ziez", .module = ziez_mod }},
            });
            const integ_test = b.addTest(.{ .root_module = integ_mod });
            const run_integ = b.addRunArtifact(integ_test);
            integration_step.dependOn(&run_integ.step);
        }
    }

    // Env example
    {
        const env_exe_mod = b.createModule(.{
            .root_source_file = b.path("examples/env.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ziez", .module = ziez_mod }},
        });
        const env_example = b.addExecutable(.{ .name = "ziez-env", .root_module = env_exe_mod });
        b.installArtifact(env_example);
        const env_run_cmd = b.addRunArtifact(env_example);
        env_run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| env_run_cmd.addArgs(args);
        const env_run_step = b.step("run-env", "Run the Env example");
        env_run_step.dependOn(&env_run_cmd.step);
    }

    // Cookie example
    {
        const ck_exe_mod = b.createModule(.{
            .root_source_file = b.path("examples/cookie.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ziez", .module = ziez_mod }},
        });
        const ck_example = b.addExecutable(.{ .name = "ziez-cookie", .root_module = ck_exe_mod });
        b.installArtifact(ck_example);
        const ck_run_cmd = b.addRunArtifact(ck_example);
        ck_run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| ck_run_cmd.addArgs(args);
        const ck_run_step = b.step("run-cookie", "Run the cookie example");
        ck_run_step.dependOn(&ck_run_cmd.step);
    }

    // Validation example
    {
        const val_exe_mod = b.createModule(.{
            .root_source_file = b.path("examples/validation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ziez", .module = ziez_mod }},
        });
        const val_example = b.addExecutable(.{ .name = "ziez-validation", .root_module = val_exe_mod });
        b.installArtifact(val_example);
        const val_run_cmd = b.addRunArtifact(val_example);
        val_run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| val_run_cmd.addArgs(args);
        const val_run_step = b.step("run-validation", "Run the validation + schema + pipes example");
        val_run_step.dependOn(&val_run_cmd.step);
    }

    // Logging example
    {
        const log_exe_mod = b.createModule(.{
            .root_source_file = b.path("examples/logging.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ziez", .module = ziez_mod }},
        });
        const log_example = b.addExecutable(.{ .name = "ziez-logging", .root_module = log_exe_mod });
        b.installArtifact(log_example);
        const log_run_cmd = b.addRunArtifact(log_example);
        log_run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| log_run_cmd.addArgs(args);
        const log_run_step = b.step("run-logging", "Run the custom Logger + LogSink example");
        log_run_step.dependOn(&log_run_cmd.step);
    }
}
