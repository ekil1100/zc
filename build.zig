const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 从 build.zig.zon 读取版本号，通过 build_options 传入源码
    const pkg = @import("build.zig.zon");
    const options = b.addOptions();
    options.addOption([]const u8, "version", pkg.version);
    options.addOption(bool, "api_owner_spawn_fault", false);

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

    // Compile and execute the startup barrier fault fixture as a real
    // ReleaseFast child process. This keeps the late startup acquire contract
    // covered under the optimization mode where detached-thread UAFs matter.
    const startup_barrier_process_mod = b.createModule(.{
        .root_source_file = b.path("src/state_authority_process_test.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .ReleaseFast,
    });
    startup_barrier_process_mod.link_libc = true;
    const startup_barrier_process_exe = b.addExecutable(.{
        .name = "zc-startup-barrier-process-test",
        .root_module = startup_barrier_process_mod,
    });
    const startup_barrier_process_cmd = b.addRunArtifact(
        startup_barrier_process_exe,
    );
    startup_barrier_process_cmd.addArg("selection-barrier-fault");
    const startup_barrier_process_step = b.step(
        "test-startup-barrier-process",
        "Run ReleaseFast startup barrier fault-injection process test",
    );
    startup_barrier_process_step.dependOn(&startup_barrier_process_cmd.step);

    const socket_write_process_cmd = b.addRunArtifact(
        startup_barrier_process_exe,
    );
    socket_write_process_cmd.addArg("socket-write-after-rst");
    const socket_write_process_step = b.step(
        "test-socket-write-process",
        "Run ReleaseFast write-after-RST SIGPIPE regression",
    );
    socket_write_process_step.dependOn(&socket_write_process_cmd.step);

    // A compile-time-only fault binary exercises the exact post-proxy API
    // spawn failure path as a real ReleaseFast daemon child. The driver gives
    // it isolated HOME/runtime roots and verifies startup-signal/artifact cleanup.
    const api_owner_fault_options = b.addOptions();
    api_owner_fault_options.addOption([]const u8, "version", pkg.version);
    api_owner_fault_options.addOption(bool, "api_owner_spawn_fault", true);
    const api_owner_fault_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .ReleaseFast,
    });
    api_owner_fault_mod.link_libc = true;
    api_owner_fault_mod.addOptions("build_options", api_owner_fault_options);
    const api_owner_fault_exe = b.addExecutable(.{
        .name = "zc-api-owner-spawn-fault",
        .root_module = api_owner_fault_mod,
    });
    const api_owner_process_cmd = b.addRunArtifact(
        startup_barrier_process_exe,
    );
    api_owner_process_cmd.addArg("api-owner-startup-fault");
    api_owner_process_cmd.addArtifactArg(api_owner_fault_exe);
    api_owner_process_cmd.addArg(
        b.pathFromRoot(".zig-cache/api-owner-process-test"),
    );
    api_owner_process_cmd.setEnvironmentVariable(
        "HOME",
        b.pathFromRoot(".zig-cache/api-owner-process-test/home"),
    );
    api_owner_process_cmd.setEnvironmentVariable(
        "XDG_RUNTIME_DIR",
        b.pathFromRoot(".zig-cache/api-owner-process-test/run"),
    );
    const api_owner_process_step = b.step(
        "test-api-owner-process",
        "Run ReleaseFast API owner startup-failure process test",
    );
    api_owner_process_step.dependOn(&api_owner_process_cmd.step);

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
    const secure_test_runtime = b.addSystemCommand(&.{
        "chmod",
        "700",
        b.pathFromRoot(".zig-cache/zc-test-run"),
    });
    secure_test_runtime.step.dependOn(&prepare_test_home.step);
    run_exe_unit_tests.step.dependOn(&secure_test_runtime.step);
    run_exe_unit_tests.setEnvironmentVariable("HOME", b.pathFromRoot(".zig-cache/zc-test-home"));
    run_exe_unit_tests.setEnvironmentVariable("XDG_RUNTIME_DIR", b.pathFromRoot(".zig-cache/zc-test-run"));

    // The independent oracle is also a real unit-test root. Keeping this
    // host-native test artifact separate from the E2E executable makes its
    // embedded seams visible in the build graph without installing it.
    const e2e_obfs_oracle_test_mod = b.createModule(.{
        .root_source_file = b.path("src/e2e_obfs_oracle.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    e2e_obfs_oracle_test_mod.link_libc = true;
    const e2e_obfs_oracle_unit_tests = b.addTest(.{
        .name = "zc-e2e-obfs-oracle-test",
        .root_module = e2e_obfs_oracle_test_mod,
        .filters = test_filters,
    });
    const run_e2e_obfs_oracle_unit_tests = b.addRunArtifact(
        e2e_obfs_oracle_unit_tests,
    );
    run_e2e_obfs_oracle_unit_tests.step.dependOn(&secure_test_runtime.step);
    run_e2e_obfs_oracle_unit_tests.setEnvironmentVariable(
        "HOME",
        b.pathFromRoot(".zig-cache/zc-test-home"),
    );
    run_e2e_obfs_oracle_unit_tests.setEnvironmentVariable(
        "XDG_RUNTIME_DIR",
        b.pathFromRoot(".zig-cache/zc-test-run"),
    );

    // The Shadowsocks UDP oracle remains a separate host-native test root. It
    // imports only std/builtin and is never linked into the production module.
    const e2e_shadowsocks_udp_oracle_test_mod = b.createModule(.{
        .root_source_file = b.path("src/e2e_shadowsocks_udp_oracle.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });
    e2e_shadowsocks_udp_oracle_test_mod.link_libc = true;
    const e2e_shadowsocks_udp_oracle_unit_tests = b.addTest(.{
        .name = "zc-e2e-shadowsocks-udp-oracle-test",
        .root_module = e2e_shadowsocks_udp_oracle_test_mod,
        .filters = test_filters,
    });
    const run_e2e_shadowsocks_udp_oracle_unit_tests = b.addRunArtifact(
        e2e_shadowsocks_udp_oracle_unit_tests,
    );
    run_e2e_shadowsocks_udp_oracle_unit_tests.step.dependOn(
        &secure_test_runtime.step,
    );
    run_e2e_shadowsocks_udp_oracle_unit_tests.setEnvironmentVariable(
        "HOME",
        b.pathFromRoot(".zig-cache/zc-test-home"),
    );
    run_e2e_shadowsocks_udp_oracle_unit_tests.setEnvironmentVariable(
        "XDG_RUNTIME_DIR",
        b.pathFromRoot(".zig-cache/zc-test-run"),
    );

    const config_flow_cmd = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("scripts/test-config-load-selection.sh"),
    });
    config_flow_cmd.addArtifactArg(exe);

    const test_step = b.step("test", "Run unit, process, and CLI flow tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_e2e_obfs_oracle_unit_tests.step);
    test_step.dependOn(&run_e2e_shadowsocks_udp_oracle_unit_tests.step);
    test_step.dependOn(&authority_process_cmd.step);
    test_step.dependOn(&startup_barrier_process_cmd.step);
    test_step.dependOn(&socket_write_process_cmd.step);
    test_step.dependOn(&api_owner_process_cmd.step);
    test_step.dependOn(&config_flow_cmd.step);

    const e2e_zc_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    e2e_zc_mod.link_libc = true;
    e2e_zc_mod.addOptions("build_options", options);
    const e2e_zc = b.addExecutable(.{
        .name = "zc",
        .root_module = e2e_zc_mod,
    });
    const e2e_origin_mod = b.createModule(.{
        .root_source_file = b.path("src/e2e_origin.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .ReleaseSafe,
    });
    e2e_origin_mod.link_libc = true;
    const e2e_origin = b.addExecutable(.{
        .name = "zc-e2e-origin",
        .root_module = e2e_origin_mod,
    });
    const e2e_obfs_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/e2e_obfs_oracle.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .ReleaseSafe,
    });
    e2e_obfs_oracle_mod.link_libc = true;
    const e2e_obfs_oracle = b.addExecutable(.{
        .name = "zc-e2e-obfs-oracle",
        .root_module = e2e_obfs_oracle_mod,
    });
    const e2e_shadowsocks_udp_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/e2e_shadowsocks_udp_oracle.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .ReleaseSafe,
    });
    e2e_shadowsocks_udp_oracle_mod.link_libc = true;
    const e2e_shadowsocks_udp_oracle = b.addExecutable(.{
        .name = "zc-e2e-shadowsocks-udp-oracle",
        .root_module = e2e_shadowsocks_udp_oracle_mod,
    });
    const e2e_fixture_root = b.pathFromRoot(".zig-cache/e2e-fixtures");
    const fetch_e2e_fixtures = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("scripts/e2e/fetch-static-fixtures.sh"),
        e2e_fixture_root,
    });
    const run_core_e2e = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("scripts/e2e/run-core.sh"),
    });
    run_core_e2e.addArtifactArg(e2e_zc);
    run_core_e2e.addArtifactArg(e2e_origin);
    run_core_e2e.addArtifactArg(e2e_obfs_oracle);
    run_core_e2e.addArtifactArg(e2e_shadowsocks_udp_oracle);
    run_core_e2e.addArgs(&.{
        e2e_fixture_root,
        b.pathFromRoot("testdata/e2e"),
    });
    run_core_e2e.step.dependOn(&fetch_e2e_fixtures.step);
    const run_installer_e2e = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("scripts/install/test-oneline-installer.sh"),
    });
    run_installer_e2e.addArtifactArg(e2e_zc);
    run_installer_e2e.addArtifactArg(e2e_origin);
    const e2e_step = b.step("e2e", "Run installer and real network end-to-end tests");
    e2e_step.dependOn(&run_e2e_obfs_oracle_unit_tests.step);
    e2e_step.dependOn(&run_e2e_shadowsocks_udp_oracle_unit_tests.step);
    e2e_step.dependOn(&run_installer_e2e.step);
    e2e_step.dependOn(&run_core_e2e.step);

    const run_release_core_e2e = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("scripts/e2e/run-core.sh"),
    });
    run_release_core_e2e.addArtifactArg(exe);
    run_release_core_e2e.addArtifactArg(e2e_origin);
    run_release_core_e2e.addArtifactArg(e2e_obfs_oracle);
    run_release_core_e2e.addArtifactArg(e2e_shadowsocks_udp_oracle);
    run_release_core_e2e.addArgs(&.{
        e2e_fixture_root,
        b.pathFromRoot("testdata/e2e"),
    });
    run_release_core_e2e.step.dependOn(&fetch_e2e_fixtures.step);
    const run_release_installer_e2e = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("scripts/install/test-oneline-installer.sh"),
    });
    run_release_installer_e2e.addArtifactArg(exe);
    run_release_installer_e2e.addArtifactArg(e2e_origin);
    const release_e2e_step = b.step(
        "e2e-release",
        "Run E2E against the configured release artifact",
    );
    release_e2e_step.dependOn(&run_e2e_obfs_oracle_unit_tests.step);
    release_e2e_step.dependOn(
        &run_e2e_shadowsocks_udp_oracle_unit_tests.step,
    );
    release_e2e_step.dependOn(&run_release_installer_e2e.step);
    release_e2e_step.dependOn(&run_release_core_e2e.step);

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
