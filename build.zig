const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 从 build.zig.zon 读取版本号，通过 build_options 传入源码
    const pkg = @import("build.zig.zon");
    const options = b.addOptions();
    options.addOption([]const u8, "version", pkg.version);

    // Create module for the executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.link_libc = true;
    exe_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "zc",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Host-native ReleaseFast measurement harness. It reports raw samples only;
    // regression thresholds are added after stable baselines exist.
    const perf_mod = b.createModule(.{
        .root_source_file = b.path("src/perf_runner.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .ReleaseFast,
    });
    perf_mod.link_libc = true;
    const perf_exe = b.addExecutable(.{
        .name = "zc-perf",
        .root_module = perf_mod,
    });
    const perf_cmd = b.addRunArtifact(perf_exe);
    if (b.args) |args| perf_cmd.addArgs(args);
    const perf_step = b.step("perf", "Record host-native ReleaseFast measurements");
    perf_step.dependOn(&perf_cmd.step);

    const authority_process_mod = b.createModule(.{
        .root_source_file = b.path("src/state_authority_process_test.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
    });
    authority_process_mod.link_libc = true;
    const authority_process_exe = b.addExecutable(.{
        .name = "zc-state-authority-process-test",
        .root_module = authority_process_mod,
    });
    const authority_process_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("scripts/test-state-authority-process.sh"),
    });
    authority_process_cmd.addArtifactArg(authority_process_exe);
    const authority_process_step = b.step("test-authority-process", "Run StateAuthority cross-process tests");
    authority_process_step.dependOn(&authority_process_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_mod.link_libc = true;
    test_mod.addOptions("build_options", options);

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name contains the given substring (repeatable)",
    ) orelse &[_][]const u8{};

    const exe_unit_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = test_filters,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const prepare_test_home = b.addSystemCommand(&.{
        "mkdir",
        "-p",
        b.pathFromRoot(".zig-cache/zc-test-home/.config"),
        b.pathFromRoot(".zig-cache/zc-test-run"),
    });
    run_exe_unit_tests.step.dependOn(&prepare_test_home.step);
    run_exe_unit_tests.setEnvironmentVariable("HOME", b.pathFromRoot(".zig-cache/zc-test-home"));
    run_exe_unit_tests.setEnvironmentVariable("XDG_RUNTIME_DIR", b.pathFromRoot(".zig-cache/zc-test-run"));
    const config_flow_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("scripts/test-config-load-selection.sh"),
    });
    config_flow_cmd.addArtifactArg(exe);

    const test_step = b.step("test", "Run unit, process, and CLI flow tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&authority_process_cmd.step);
    test_step.dependOn(&config_flow_cmd.step);

    // Fuzz test
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });

    fuzz_mod.link_libc = true;

    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
    });

    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    fuzz_step.dependOn(&run_fuzz_tests.step);
}
