const std = @import("std");
const compat = @import("compat.zig");
const config = @import("config.zig");
const config_import = @import("config_import.zig");
const catalog_commands = @import("catalog_commands.zig");
const catalog_service = @import("catalog_service.zig");
const legacy_catalog_bootstrap = @import("legacy_catalog_bootstrap.zig");
const legacy_mirror = @import("legacy_mirror.zig");
const config_identity = @import("config_identity.zig");
const managed_config_loader = @import("managed_config_loader.zig");
const controller_endpoint = @import("controller_endpoint.zig");
const constants = @import("constants.zig");
const validator = @import("config_validator.zig");
const http_proxy = @import("proxy/http.zig");
const socks5_proxy = @import("proxy/socks5.zig");
const mixed_proxy = @import("proxy/mixed.zig");
const rule_engine = @import("rule/engine.zig");
const outbound = @import("proxy/outbound/manager.zig");
const meta = @import("meta.zig");
const api = @import("api/server.zig");
const daemon = @import("daemon.zig");
const proxy_cli = @import("proxy_cli.zig");
const runtime_selection = @import("runtime_selection.zig");
const runtime_descriptor = @import("runtime_descriptor.zig");
const selection_state = @import("selection_state.zig");
const state_authority = @import("state_authority.zig");
const test_cli = @import("test_cli.zig");
const doctor_cli = @import("doctor_cli.zig");
const override = @import("override.zig");
const override_materialization = @import("override_materialization.zig");
const cli_output = @import("cli/output.zig");
const cli_commands = @import("cli/commands.zig");
const build_options = @import("build_options");
const UpdateApplyMode = daemon.ApplyMode;
const shadowsocks = @import("proxy/outbound/shadowsocks.zig");

const ConfigOverrideAction = union(enum) {
    show,
    clear,
    set: []const u8,
};

const RuntimeCommand = enum {
    start,
    restart,
};

const catalog_listing_attempts = 4;
const listener_start_timeout_ms: i64 = 10_000;
const daemon_listener_start_timeout_ms: i64 = 15_000;
const listener_start_poll_ms: u64 = 10;

const ListenerStartupPhase = enum(u8) {
    initializing,
    committed,
    failed,
};

const ListenerStartup = struct {
    ready: std.atomic.Value(u8) = .init(0),
    phase: std.atomic.Value(ListenerStartupPhase) = .init(.initializing),
    control_available: std.atomic.Value(bool) = .init(false),
    committed: std.atomic.Value(bool) = .init(false),
};

const StartCommandOptions = struct {
    config_path: ?[]const u8 = null,
    port: ?u16 = null,
    /// 决策 D1：`zc start --foreground` 不 fork，在前台运行（容器/systemd）。
    foreground: bool = false,
};

// 全局配置路径，用于重载
var g_config_path: ?[]const u8 = null;
var gpa_holder: ?*std.heap.DebugAllocator(.{}) = null;

// Canonical command path for the JSON envelope ("command" field) and the
// global color switch; both set once in main() before dispatch.
var g_cli_command: []const u8 = "";
var g_cmd_buf: [64]u8 = undefined;
var g_no_color: bool = false;
var g_startup_token: ?runtime_descriptor.Nonce = null;
var g_runtime_nonce: ?runtime_descriptor.Nonce = null;
var g_daemon_lock_fd: ?std.posix.fd_t = null;

fn parseStartupToken(args: []const []const u8) !runtime_descriptor.Nonce {
    const prefix = "--startup-token=";
    var parsed: ?runtime_descriptor.Nonce = null;
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, prefix)) continue;
        if (parsed != null) return error.DuplicateStartupToken;
        parsed = runtime_descriptor.Nonce.parseHex(arg[prefix.len..]) catch
            return error.InvalidStartupToken;
    }
    return parsed orelse error.MissingStartupToken;
}

fn parseDaemonLockFd(args: []const []const u8) !std.posix.fd_t {
    const prefix = "--daemon-lock-fd=";
    var parsed: ?std.posix.fd_t = null;
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, prefix)) continue;
        if (parsed != null) return error.DuplicateDaemonLockFd;
        const value = std.fmt.parseInt(std.posix.fd_t, arg[prefix.len..], 10) catch
            return error.InvalidDaemonLockFd;
        if (value < 0) return error.InvalidDaemonLockFd;
        parsed = value;
    }
    return parsed orelse error.MissingDaemonLockFd;
}

fn collectArgs(allocator: std.mem.Allocator, raw_args: std.process.Args) ![]const []const u8 {
    var it = try std.process.Args.Iterator.initAllocator(raw_args, allocator);
    defer it.deinit();

    var args = std.ArrayList([]const u8).empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    while (it.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }
    return args.toOwnedSlice(allocator);
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

pub fn main(init: std.process.Init) !void {
    compat.setIo(init.io);
    compat.setEnvironMap(init.environ_map);

    var gpa = std.heap.DebugAllocator(.{}){};
    gpa_holder = &gpa;
    defer {
        if (g_config_path) |path| {
            gpa.allocator().free(path);
        }
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    // Parse command line args
    const args = try collectArgs(allocator, init.minimal.args);
    defer freeArgs(allocator, args);

    // 检查是否有子命令
    if (args.len < 2) {
        printShortUsage();
        std.process.exit(cli_output.exit_usage);
    }

    const cmd = cli_commands.canonicalTop(args[1]);
    const json_output = hasFlag(args, "--json");
    g_no_color = hasFlag(args, "--no-color");
    setCliCommand(cmd, args);

    var override_opts = override.parseCliOptions(allocator, args) catch |err| {
        // override flag 缺值/非法值是用法错误（spec.md 退出码表：exit 2）。
        printOverrideOptionError(json_output, err);
        std.process.exit(cli_output.exit_usage);
    };
    defer override_opts.deinit(allocator);

    // 处理 daemon 运行模式（内部使用）
    if (std.mem.eql(u8, cmd, "--daemon-run")) {
        const startup_token = parseStartupToken(args) catch {
            printCliError(
                json_output,
                "START_LOCK_HANDOFF_INVALID",
                "daemon startup token is missing or invalid",
                "launch the daemon through `zc start`",
            );
            std.process.exit(cli_output.exit_failure);
        };
        g_startup_token = startup_token;
        const lock_fd = parseDaemonLockFd(args) catch {
            daemon.publishStartupSignal(
                allocator,
                startup_token,
                .{ .failed = .lock_handoff },
            ) catch {};
            printCliError(
                json_output,
                "START_LOCK_HANDOFF_INVALID",
                "daemon lock handoff is missing or invalid",
                "launch the daemon through `zc start`",
            );
            std.process.exit(cli_output.exit_failure);
        };
        daemon.adoptInheritedDaemonLock(allocator, lock_fd) catch {
            daemon.publishStartupSignal(
                allocator,
                startup_token,
                .{ .failed = .lock_handoff },
            ) catch {};
            printCliError(
                json_output,
                "START_LOCK_HANDOFF_INVALID",
                "failed to protect the inherited daemon lock",
                "launch the daemon through `zc start`",
            );
            std.process.exit(cli_output.exit_failure);
        };
        g_daemon_lock_fd = lock_fd;
        const start_opts = parseStartCommandOptions(args, 2, .forwarded) catch |err| {
            printStartCommandOptionError(json_output, err, .start);
            std.process.exit(cli_output.exit_failure);
        };
        daemon.publishStartupReservation(
            allocator,
            startup_token,
            std.c.getpid(),
        ) catch |err| {
            daemon.publishStartupSignal(
                allocator,
                startup_token,
                .{ .failed = .runtime_publish },
            ) catch {};
            daemon.cleanupCurrentProcessRuntime(allocator);
            return err;
        };
        daemon.writePid(allocator, std.c.getpid()) catch |err| {
            daemon.publishStartupSignal(
                allocator,
                startup_token,
                .{ .failed = .runtime_publish },
            ) catch {};
            daemon.cleanupCurrentProcessRuntime(allocator);
            return err;
        };
        g_runtime_nonce = startup_token;
        runProxy(
            allocator,
            start_opts.config_path,
            start_opts.port,
            &override_opts,
            "daemon-run",
            json_output,
            .{
                .foreground = false,
                .prepared = hasFlag(args, "--prepared-runtime-config"),
                .config_path = start_opts.config_path,
                .port_override = start_opts.port,
            },
        ) catch |err| {
            daemon.publishStartupSignal(
                allocator,
                startup_token,
                .{ .failed = startupFailureForError(err) },
            ) catch {};
            daemon.cleanupCurrentProcessRuntime(allocator);
            return err;
        };
        return;
    }

    // 处理 help
    if (isHelpArg(cmd)) {
        if (std.mem.eql(u8, cmd, "help") and args.len >= 3) {
            if (!try printTopicHelpStdout(args[2..])) {
                printCliError(json_output, "HELP_TOPIC_UNKNOWN", "unknown help topic", "run `zc help` to list commands");
                std.process.exit(cli_output.exit_usage);
            }
        } else {
            try printGlobalHelpStdout();
        }
        return;
    }

    // 处理 version
    if (std.mem.eql(u8, cmd, "version")) {
        if (hasUnexpectedArgs(args, 2)) {
            printCliError(json_output, "VERSION_ARGUMENT_INVALID", "unknown or unexpected argument for `version`", "use `zc version [--json]`");
            std.process.exit(cli_output.exit_usage);
        }
        try printVersion(json_output);
        return;
    }

    // `zc <cmd> --help` 对表内顶层命令只打印帮助，绝不执行命令本身
    // （修复 `zc start --help` 真的启动 daemon 的问题）。
    if (cli_commands.find(cmd)) |table_cmd| {
        if (std.mem.indexOfScalar(u8, table_cmd.path, ' ') == null and wantsCommandHelp(args)) {
            try printCommandHelpStdout(table_cmd);
            return;
        }
    }

    // 处理 start 命令
    if (std.mem.eql(u8, cmd, "start")) {
        // 决策 D11 + spec.md 退出码表：参数用法错误（未知/缺值 flag）exit 2。
        const start_opts = parseStartCommandOptions(args, 2, .strict) catch |err| {
            printStartCommandOptionError(json_output, err, .start);
            std.process.exit(cli_output.exit_usage);
        };
        const daemon_running = daemon.isRunning(allocator) catch {
            printCliError(
                json_output,
                "START_PREFLIGHT_FAILED",
                "failed to validate daemon runtime artifacts",
                "remove unsafe runtime artifacts and retry",
            );
            std.process.exit(cli_output.exit_failure);
        };

        // 决策 D1：--foreground 不 fork，自己持锁 + 写 pid（容器/systemd）。
        if (start_opts.foreground) {
            const lock_file = daemon.acquireForegroundLock(allocator) catch |err| {
                if (err == error.DaemonAlreadyRunning) {
                    printCliError(json_output, "START_FAILED", "daemon already running", "stop it with `zc stop` before `zc start --foreground`");
                } else {
                    printCliError(json_output, "START_FAILED", "failed to acquire daemon lock", "check runtime directory permissions and retry");
                }
                std.process.exit(cli_output.exit_failure);
            };
            // Keep the lock file live until process exit.
            g_daemon_lock_fd = lock_file.handle;
            daemon.prepareForegroundRuntime(allocator) catch {
                printCliError(
                    json_output,
                    "START_RUNTIME_PUBLISH_FAILED",
                    "failed to prepare the foreground runtime descriptor",
                    "remove unsafe runtime artifacts and retry",
                );
                std.process.exit(cli_output.exit_failure);
            };
            const foreground_nonce = runtime_descriptor.Nonce.generate();
            daemon.publishStartupReservation(
                allocator,
                foreground_nonce,
                std.c.getpid(),
            ) catch {
                daemon.cleanupCurrentProcessRuntime(allocator);
                printCliError(
                    json_output,
                    "START_RUNTIME_PUBLISH_FAILED",
                    "failed to reserve foreground runtime state",
                    "remove unsafe runtime artifacts and retry",
                );
                std.process.exit(cli_output.exit_failure);
            };
            daemon.writePid(allocator, std.c.getpid()) catch {
                daemon.cleanupCurrentProcessRuntime(allocator);
                printCliError(
                    json_output,
                    "START_RUNTIME_PUBLISH_FAILED",
                    "failed to publish the daemon pid",
                    "remove unsafe runtime artifacts and retry",
                );
                std.process.exit(cli_output.exit_failure);
            };
            g_runtime_nonce = foreground_nonce;
            runProxy(
                allocator,
                start_opts.config_path,
                start_opts.port,
                &override_opts,
                "start",
                json_output,
                .{
                    .foreground = true,
                    .prepared = false,
                    .config_path = start_opts.config_path,
                    .port_override = start_opts.port,
                },
            ) catch |err| {
                _ = daemon.removeCurrentProcessPid(allocator) catch false;
                if (isPortPreflightError(err)) {
                    printRuntimeCommandPreflightError(.start, json_output, err);
                } else if (err == error.ListenerStartupTimeout) {
                    printCliError(
                        json_output,
                        "START_READINESS_TIMEOUT",
                        "daemon listeners did not become ready within 10 seconds",
                        "check port ownership and retry",
                    );
                } else if (!printOverrideRuntimeError(json_output, err)) {
                    printCliError(json_output, "START_FAILED", "failed to start proxy in foreground", "check config path and `zc log --no-follow`");
                }
                std.process.exit(cli_output.exit_failure);
            };
            return;
        }

        // 后台启动
        var forward_args = std.ArrayList([]const u8).empty;
        defer {
            for (forward_args.items) |item| allocator.free(item);
            forward_args.deinit(allocator);
        }
        try appendStartForwardArgs(allocator, &forward_args, start_opts);
        try override_opts.appendForwardArgs(allocator, &forward_args);

        var daemon_args = std.ArrayList([]const u8).empty;
        defer deinitForwardArgs(allocator, &daemon_args);
        var prepared: ?daemon.PreparedConfig = null;
        defer if (prepared) |*snapshot| snapshot.deinit();
        var tracked: ?daemon.TrackedRuntime = null;
        defer if (tracked) |*runtime| runtime.deinit(allocator);
        if (daemon_running) {
            tracked = daemon.captureTrackedRuntime(allocator) catch null;
        }
        if (tracked) |runtime| {
            if (runtime.invocation.foreground) {
                var streams = StdStreams{};
                var out = streams.output(json_output);
                if (json_output) {
                    out.success(.{
                        .action = "start",
                        .state = "running",
                        .detail = "already_running",
                        .pid = runtime.instance.pid,
                    }) catch {};
                } else {
                    out.print(
                        "zc daemon already running (pid: {d})\n",
                        .{runtime.instance.pid},
                    ) catch {};
                    out.flush() catch {};
                }
                return;
            }
        }
        const daemon_config_path: []const u8 = if (tracked) |*runtime| blk: {
            _ = validateTrackedPreparedRuntime(allocator, runtime) catch {
                printCliError(
                    json_output,
                    "START_PREFLIGHT_FAILED",
                    "running daemon does not have a trusted prepared config",
                    "leave it running and restart it through its original command",
                );
                std.process.exit(cli_output.exit_failure);
            };
            try runtime.invocation.appendForwardArgs(allocator, &daemon_args);
            break :blk runtime.invocation.config_path.?;
        } else blk: {
            prepared = prepareDaemonConfig(
                allocator,
                start_opts.config_path,
                start_opts.port,
                &override_opts,
                null,
                null,
                !(daemon_running and tracked == null),
            ) catch |err| {
                if (isPortPreflightError(err)) {
                    printRuntimeCommandPreflightError(.start, json_output, err);
                } else if (!printOverrideRuntimeError(json_output, err)) {
                    printCliError(
                        json_output,
                        "START_PREFLIGHT_FAILED",
                        "failed to prepare daemon runtime artifacts",
                        "check config providers, override output, and network access",
                    );
                }
                std.process.exit(cli_output.exit_failure);
            };
            try appendPreparedMarker(allocator, &daemon_args);
            break :blk prepared.?.path;
        };

        const outcome = daemon.startDaemon(
            allocator,
            daemon_config_path,
            daemon_args.items,
        ) catch |err| {
            switch (err) {
                error.PortAlreadyInUse,
                error.ControllerPortAlreadyInUse,
                error.PortConflict,
                error.InvalidBindAddress,
                error.InvalidExternalController,
                => printRuntimeCommandPreflightError(.start, json_output, err),
                error.UnsupportedCapability,
                error.OverrideScriptNotFound,
                error.OverrideScriptExecFailed,
                error.OverrideScriptTimeout,
                error.OverrideOutputInvalid,
                error.OverrideMergeFailed,
                => {
                    _ = printOverrideRuntimeError(json_output, err);
                },
                error.StartLockHandoffInvalid => printCliError(
                    json_output,
                    "START_LOCK_HANDOFF_INVALID",
                    "daemon lock handoff is invalid",
                    "remove replaced runtime locks and retry",
                ),
                error.ListenerStartupFailed => printCliError(
                    json_output,
                    "START_FAILED",
                    "daemon listener failed during startup",
                    "check port ownership and `zc log --no-follow`",
                ),
                error.StartRuntimePublishFailed,
                error.RuntimeDescriptorBusy,
                error.RuntimeDescriptorLockTimeout,
                error.RuntimeDescriptorLockFailed,
                => printCliError(
                    json_output,
                    "START_RUNTIME_PUBLISH_FAILED",
                    "failed to publish daemon runtime state",
                    "remove unsafe runtime artifacts and retry",
                ),
                error.StartFailed => printCliError(
                    json_output,
                    "START_FAILED",
                    "daemon exited before startup completed",
                    "check `zc log --no-follow` for details",
                ),
                error.StartupTimeout => printCliError(
                    json_output,
                    "START_READINESS_TIMEOUT",
                    "daemon did not publish readiness before the startup deadline",
                    "check override duration, port ownership, and the daemon log",
                ),
                else => printCliError(
                    json_output,
                    "START_FAILED",
                    "failed to start daemon",
                    "check the runtime directory, config path, and daemon log",
                ),
            }
            std.process.exit(cli_output.exit_failure);
        };
        if (outcome.detail == null and outcome.pid != null) {
            if (prepared) |*snapshot| snapshot.retain();
        }

        var streams = StdStreams{};
        var out = streams.output(json_output);
        if (json_output) {
            out.success(.{ .action = "start", .state = "running", .detail = outcome.detail, .pid = outcome.pid }) catch {};
        } else if (outcome.detail != null) {
            if (outcome.pid) |p| {
                out.print("zc daemon already running (pid: {d})\n", .{p}) catch {};
            } else {
                out.print("zc daemon already running or startup is in progress\n", .{}) catch {};
            }
            out.flush() catch {};
        } else {
            out.print("zc daemon started (pid: {d})\n", .{outcome.pid.?}) catch {};
            daemon.printStartupInfo(allocator, start_opts.config_path, forward_args.items, &out);
            const log_path = daemon.getLogFilePath(allocator) catch null;
            defer if (log_path) |p| allocator.free(p);
            if (log_path) |lp| out.print("  log:         {s}\n", .{lp}) catch {};
            out.flush() catch {};
        }
        return;
    }

    // 处理 stop 命令
    if (std.mem.eql(u8, cmd, "stop")) {
        // 决策 D11：stop 不接受任何位置参数/私有 flag。
        if (hasUnexpectedArgs(args, 2)) {
            printCliError(json_output, "STOP_ARGUMENT_INVALID", "unknown or unexpected argument for `stop`", "use `zc stop [--json]`");
            std.process.exit(cli_output.exit_usage);
        }
        const outcome = daemon.stopDaemon(allocator) catch |err| {
            switch (err) {
                error.DaemonPidUntracked => printCliError(json_output, "STOP_FAILED", "daemon appears to be running but pid is not trackable", "check `zc status`, `ps`, and runtime files before retrying `zc stop`"),
                error.DaemonStopTimeout => printCliError(
                    json_output,
                    "STOP_TIMEOUT",
                    "daemon did not acknowledge the stop request within 5 seconds",
                    "inspect `zc status` and the daemon log before retrying",
                ),
                error.DaemonPreparedCleanupFailed => printCliError(
                    json_output,
                    "STOP_CLEANUP_FAILED",
                    "daemon stopped but its prepared config could not be removed",
                    "remove the owner-only prepared snapshot from the runtime directory",
                ),
                error.DaemonStopRequestCleanupFailed => printCliError(
                    json_output,
                    "STOP_CLEANUP_FAILED",
                    "daemon stop timed out and the stop request could not be disarmed",
                    "keep the daemon isolated and repair the runtime directory before retrying",
                ),
                else => printCliError(json_output, "STOP_FAILED", "failed to stop daemon", "verify process permissions and retry `zc stop`"),
            }
            std.process.exit(cli_output.exit_failure);
        };

        var streams = StdStreams{};
        var out = streams.output(json_output);
        if (json_output) {
            out.success(.{ .action = "stop", .state = "stopped", .detail = outcome.detail, .pid = outcome.pid }) catch {};
        } else if (outcome.pid) |p| {
            out.print("zc daemon stopped (pid: {d})\n", .{p}) catch {};
            out.flush() catch {};
        } else {
            out.print("zc daemon already stopped\n", .{}) catch {};
            out.flush() catch {};
        }
        return;
    }

    // 处理 restart 命令
    if (std.mem.eql(u8, cmd, "restart")) {
        const start_opts = parseStartCommandOptions(args, 2, .strict) catch |err| {
            printStartCommandOptionError(json_output, err, .restart);
            std.process.exit(cli_output.exit_usage);
        };
        if (start_opts.foreground) {
            printCliError(json_output, "RESTART_FAILED", "`--foreground` is not supported by restart", "use `zc stop` then `zc start --foreground`");
            std.process.exit(cli_output.exit_usage);
        }

        var streams = StdStreams{};
        var out = streams.output(json_output);
        runRestartCommand(
            allocator,
            start_opts,
            &out,
            &override_opts,
            hasExplicitOverrideArguments(args),
        ) catch |err| {
            if (!printOverrideRuntimeError(json_output, err)) {
                switch (err) {
                    error.PortAlreadyInUse,
                    error.ControllerPortAlreadyInUse,
                    error.PortConflict,
                    error.InvalidBindAddress,
                    error.InvalidExternalController,
                    => printRuntimeCommandPreflightError(.restart, json_output, err),
                    error.ForegroundDaemonSupervised => printCliError(json_output, "RESTART_FAILED", "daemon is running in the foreground (likely under a supervisor)", "restart it via the supervisor (e.g. `systemctl restart`), or `zc stop` then `zc start --foreground`"),
                    error.DaemonInvocationUntracked,
                    error.InvalidPreparedConfig,
                    => printCliError(
                        json_output,
                        "RESTART_INVOCATION_UNTRACKED",
                        "running daemon invocation could not be captured safely",
                        "leave it running and restart it through its supervisor " ++
                            "or original command",
                    ),
                    error.DaemonInstanceChanged => printCliError(
                        json_output,
                        "RESTART_CONTENDED",
                        "the captured daemon instance changed before replacement",
                        "leave the current daemon running and retry only after " ++
                            "`zc status` is stable",
                    ),
                    error.RestartFailedRolledBack => printCliError(
                        json_output,
                        "RESTART_FAILED_ROLLED_BACK",
                        "new daemon failed, so the previous invocation was restored",
                        "inspect `zc log --no-follow`, fix the target config, and retry",
                    ),
                    error.RestartRollbackFailed,
                    error.RestartRollbackContended,
                    => printCliError(
                        json_output,
                        "RESTART_ROLLBACK_FAILED",
                        "new daemon failed and the previous invocation could not be restored",
                        "run `zc status`, inspect the daemon log, then start " ++
                            "the known-good config explicitly",
                    ),
                    error.RestartContended => printCliError(
                        json_output,
                        "RESTART_CONTENDED",
                        "another daemon acquired the runtime during restart",
                        "run `zc status` before deciding whether to retry",
                    ),
                    error.StartFailed => printCliError(json_output, "RESTART_FAILED", "daemon did not become trackable after restart", "check `zc status` and `zc log --no-follow` for recovery details"),
                    error.StartupTimeout => printCliError(
                        json_output,
                        "RESTART_READINESS_TIMEOUT",
                        "daemon did not publish readiness before the startup deadline",
                        "check override duration, port ownership, and the daemon log",
                    ),
                    error.DaemonPidUntracked => printCliError(json_output, "RESTART_FAILED", "daemon appears to be running but pid is not trackable", "check `zc status`, `ps`, and runtime files before retrying `zc restart`"),
                    else => printCliError(json_output, "RESTART_FAILED", "failed to restart daemon", "check logs and retry `zc restart -c <config>`"),
                }
            }
            std.process.exit(cli_output.exit_failure);
        };
        return;
    }

    // 处理 reload 命令（决策 D9：热重载当前配置，不重新下载任何内容）
    if (std.mem.eql(u8, cmd, "reload")) {
        if (hasUnexpectedArgs(args, 2)) {
            printCliError(json_output, "RELOAD_ARGUMENT_INVALID", "unknown or unexpected argument for `reload`", "use `zc reload [--json]`");
            std.process.exit(cli_output.exit_usage);
        }
        const running = daemon.isRunning(allocator) catch false;
        if (!running) {
            printCliError(json_output, "RELOAD_FAILED", "daemon is not running", "start it first with `zc start`");
            std.process.exit(cli_output.exit_failure);
        }
        const result = reloadOrRestartPrepared(
            allocator,
            null,
            .auto,
            true,
            null,
        ) catch |err| {
            switch (err) {
                // 受监管的前台 daemon（systemd/容器）：restart 兜底会杀掉 MainPID
                // 并逃逸监管，拒绝并把用户引向监管者。
                error.ForegroundDaemonSupervised => printCliError(json_output, "RELOAD_FAILED", "daemon is running in the foreground (likely under a supervisor)", "restart it via the supervisor (e.g. `systemctl restart`) instead of `zc reload`"),
                else => printCliError(json_output, "RELOAD_FAILED", "failed to reload daemon config", "check `zc log --no-follow`, then retry or run `zc restart`"),
            }
            std.process.exit(cli_output.exit_failure);
        };

        var streams = StdStreams{};
        var out = streams.output(json_output);
        if (json_output) {
            const applied = switch (result) {
                .hot_applied => "hot",
                .restart_applied => "restart",
                .restart_fallback => "restart_fallback",
            };
            out.success(.{ .action = "reload", .state = "running", .applied = applied }) catch {};
        } else {
            switch (result) {
                .hot_applied => out.print("Config applied via hot reload\n", .{}) catch {},
                .restart_applied => out.print("Config applied via restart\n", .{}) catch {},
                .restart_fallback => out.print("Config hot reload unavailable, fell back to restart\n", .{}) catch {},
            }
            out.flush() catch {};
        }
        return;
    }

    // 处理 status 命令
    if (std.mem.eql(u8, cmd, "status")) {
        if (hasUnexpectedArgs(args, 2)) {
            printCliError(json_output, "STATUS_ARGUMENT_INVALID", "unknown or unexpected argument for `status`", "use `zc status [--json]`");
            std.process.exit(cli_output.exit_usage);
        }
        var streams = StdStreams{};
        var out = streams.output(json_output);
        daemon.getStatus(allocator, &out) catch {
            printCliError(
                json_output,
                "STATUS_FAILED",
                "failed to read daemon status",
                "use a canonical owner-only runtime directory and retry",
            );
            std.process.exit(cli_output.exit_failure);
        };
        return;
    }

    // 处理 log 命令
    if (std.mem.eql(u8, cmd, "log")) {
        const log_args = parseLogCommandArgs(args, 2) catch |err| {
            printLogCommandArgError(json_output, err);
            std.process.exit(cli_output.exit_usage);
        };
        var lines = log_args.lines;
        var follow = log_args.follow;
        // --json 默认输出一次后退出（JSON Lines），除非显式 -f。
        if (json_output and !log_args.follow_explicit) {
            follow = false;
        }
        // 如果没有指定 -n，默认显示 50 行
        if (lines == null and !follow) {
            lines = 50;
        }

        var streams = StdStreams{};
        var out = streams.output(json_output);
        daemon.viewLog(allocator, lines, follow, &out) catch {
            printCliError(json_output, "LOG_FAILED", "failed to read daemon log", "check log file permissions; `zc status` shows the log path");
            std.process.exit(cli_output.exit_failure);
        };
        return;
    }

    // 处理 config 子命令（Batch 3：统一 envelope/退出码/stdout 路由）
    if (std.mem.eql(u8, cmd, "config")) {
        try runConfigCommand(allocator, args, json_output, &override_opts);
        return;
    }

    // 处理 proxy / profile 子命令（Batch 4：同一 handler，按命令路径渲染文案，
    // 决策 D10 —— 终结 profile 块对 proxy 块的整段复制粘贴）
    if (std.mem.eql(u8, cmd, "proxy")) {
        try runProxyFamilyCommand(allocator, args, json_output, &override_opts, &proxy_family_text);
        return;
    }
    if (std.mem.eql(u8, cmd, "profile")) {
        try runProxyFamilyCommand(allocator, args, json_output, &override_opts, &profile_family_text);
        return;
    }

    // 处理 test 命令（Batch 5：与 proxy/profile test 同一探测路径，决策 D3）
    if (std.mem.eql(u8, cmd, "test")) {
        try runStandaloneTestCommand(allocator, args, json_output, &override_opts);
        return;
    }

    // 处理 doctor 命令（Batch 5：CHECKS_FAILED 语义 + 两种模式同行为）
    if (std.mem.eql(u8, cmd, "doctor")) {
        // 决策 D11：只接受 `-c <config>`（外加全局/override flags）。
        const parsed = parseProxyFamilyArgs(args, 2, .{}) catch |err| {
            printDoctorArgError(json_output, err, "doctor");
            std.process.exit(cli_output.exit_usage);
        };
        try runDoctorCommand(allocator, parsed.config_path, json_output, &override_opts, "doctor");
        return;
    }

    // 处理 diag 子命令组（doctor 别名）。区分缺子命令（DIAG_SUBCOMMAND_MISSING，
    // 新）与未知子命令（DIAG_SUBCOMMAND_UNKNOWN，冻结），均 exit_usage；
    // 裸 `zc diag` 与其他组对齐：组帮助 stdout、exit 0。
    if (std.mem.eql(u8, cmd, "diag")) {
        switch (resolveDiagSubcommand(args)) {
            .bare, .help => try printDiagHelp(),
            .missing => {
                printCliError(json_output, "DIAG_SUBCOMMAND_MISSING", "missing diag subcommand", "use `zc diag doctor [-c <config>] [--json]`");
                std.process.exit(cli_output.exit_usage);
            },
            .unknown => {
                printCliError(json_output, "DIAG_SUBCOMMAND_UNKNOWN", "unknown diag subcommand", "use `zc diag doctor [-c <config>] [--json]`");
                std.process.exit(cli_output.exit_usage);
            },
            .doctor => |idx| {
                if (containsHelpArg(args, idx + 1)) {
                    try printDiagDoctorHelp();
                    return;
                }
                const parsed = parseProxyFamilyArgs(args, idx + 1, .{}) catch |err| {
                    printDoctorArgError(json_output, err, "diag doctor");
                    std.process.exit(cli_output.exit_usage);
                };
                try runDoctorCommand(allocator, parsed.config_path, json_output, &override_opts, "diag.doctor");
            },
        }
        return;
    }

    // 未知命令
    var unknown_buf: [128]u8 = undefined;
    const unknown_msg = std.fmt.bufPrint(&unknown_buf, "unknown command: {s}", .{cmd}) catch "unknown command";
    printCliError(json_output, "COMMAND_UNKNOWN", unknown_msg, "use `zc help` to list supported commands");
    std.process.exit(cli_output.exit_failure);
}

fn printCliError(json_output: bool, code: []const u8, message: []const u8, hint: []const u8) void {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(compat.io(), &out_buf);
    var stderr_writer = std.Io.File.stderr().writerStreaming(compat.io(), &err_buf);
    var out = cli_output.Output.init(
        if (json_output) .json else .text,
        g_cli_command,
        stdoutColorEnabled(),
        stderrColorEnabled(),
        &stdout_writer.interface,
        &stderr_writer.interface,
    );
    out.fail(code, message, hint) catch {};
}

/// 按流判定颜色：payload 看 stdout 的 TTY，诊断看 stderr 的 TTY
/// （`zc proxy list > f` 时 stderr 还是 TTY，但文件里绝不能混入 ANSI 码）。
fn streamColorEnabled(fd: std.posix.fd_t) bool {
    const is_tty = std.c.isatty(fd) == 1;
    const no_color_env = std.c.getenv("NO_COLOR") != null;
    return cli_output.shouldUseColor(is_tty, g_no_color, no_color_env);
}

fn stdoutColorEnabled() bool {
    return streamColorEnabled(std.posix.STDOUT_FILENO);
}

fn stderrColorEnabled() bool {
    return streamColorEnabled(std.posix.STDERR_FILENO);
}

/// 生命周期命令共用的 stdout/stderr Output 构造器。
/// 用法：`var streams = StdStreams{}; var out = streams.output(json_output);`
/// streams 必须比返回的 Output 活得久（两者都放在同一栈帧即可）。
/// 注意：必须用 writerStreaming —— 默认 positional writer 从 pos 0 pwrite，
/// 流重定向到普通文件时会覆盖 std.debug.print（streaming）已写入的内容
/// （例如 stderr 上的配置校验输出）。
const StdStreams = struct {
    out_buf: [4096]u8 = undefined,
    err_buf: [2048]u8 = undefined,
    stdout_writer: std.Io.File.Writer = undefined,
    stderr_writer: std.Io.File.Writer = undefined,

    fn output(self: *StdStreams, json_output: bool) cli_output.Output {
        self.stdout_writer = std.Io.File.stdout().writerStreaming(compat.io(), &self.out_buf);
        self.stderr_writer = std.Io.File.stderr().writerStreaming(compat.io(), &self.err_buf);
        return cli_output.Output.init(
            if (json_output) .json else .text,
            g_cli_command,
            stdoutColorEnabled(),
            stderrColorEnabled(),
            &self.stdout_writer.interface,
            &self.stderr_writer.interface,
        );
    }
};

fn setCliCommand(canonical_top: []const u8, args: []const []const u8) void {
    for (&cli_commands.groups) |*group| {
        // flag（`-...`）不是子命令：`zc diag -c x` 的 command 是 "diag"，
        // 不能拼成 "diag -c"。
        if (std.mem.eql(u8, group.name, canonical_top) and args.len >= 3 and
            args[2].len > 0 and args[2][0] != '-')
        {
            const joined = std.fmt.bufPrint(&g_cmd_buf, "{s} {s}", .{ canonical_top, args[2] }) catch {
                g_cli_command = canonical_top;
                return;
            };
            g_cli_command = if (cli_commands.find(joined)) |c| c.path else joined;
            return;
        }
    }
    g_cli_command = if (cli_commands.find(canonical_top)) |c| c.path else canonical_top;
}

fn printShortUsage() void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(compat.io(), &buf);
    w.interface.writeAll("Usage: zc <command> [options]\nRun `zc help` to list commands.\n") catch return;
    w.interface.flush() catch return;
}

fn printGlobalHelpStdout() !void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(compat.io(), &buf);
    try cli_commands.writeGlobalHelp(&w.interface, build_options.version);
}

fn printTopicHelpStdout(tokens: []const []const u8) !bool {
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(compat.io(), &buf);
    return cli_commands.writeTopicHelp(&w.interface, tokens);
}

fn printCommandHelpStdout(cmd: *const cli_commands.Command) !void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(compat.io(), &buf);
    try cli_commands.writeCommandHelp(&w.interface, cmd);
}

fn printVersion(json_output: bool) !void {
    var out_buf: [512]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(compat.io(), &out_buf);
    var stderr_writer = std.Io.File.stderr().writerStreaming(compat.io(), &err_buf);
    var out = cli_output.Output.init(
        if (json_output) .json else .text,
        "version",
        false,
        false,
        &stdout_writer.interface,
        &stderr_writer.interface,
    );
    if (json_output) {
        try out.success(.{ .version = build_options.version });
    } else {
        try out.print("zc {s}\n", .{build_options.version});
        try out.flush();
    }
}

fn wantsCommandHelp(args: []const []const u8) bool {
    if (args.len >= 3 and std.mem.eql(u8, args[2], "help")) return true;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

fn printOverrideOptionError(json_output: bool, err: anyerror) void {
    switch (err) {
        error.MissingOverrideScriptPath => printCliError(json_output, "OVERRIDE_SCRIPT_NOT_FOUND", "missing --override-script path", "use `--override-script <path>`"),
        error.InvalidOverrideTimeout => printCliError(json_output, "OVERRIDE_SCRIPT_TIMEOUT", "invalid --override-timeout-ms value", "use 1..60000 milliseconds, e.g. `--override-timeout-ms 5000`"),
        error.MissingOverrideArg => printCliError(json_output, "OVERRIDE_OUTPUT_INVALID", "missing --override-arg value", "use `--override-arg key=value`"),
        error.InvalidOverrideArg => printCliError(json_output, "OVERRIDE_OUTPUT_INVALID", "invalid --override-arg value", "use `--override-arg key=value`"),
        error.DeprecatedOverrideDumpOption => printCliError(json_output, "OVERRIDE_OPTION_DEPRECATED", "--override-dump-yaml/json has been removed", "use `zc config dump [-c <config>]`"),
        else => printCliError(json_output, "OVERRIDE_SCRIPT_EXEC_FAILED", "failed to parse override options", "check override flags and retry"),
    }
}

fn printOverrideRuntimeError(json_output: bool, err: anyerror) bool {
    switch (err) {
        error.OverrideScriptNotFound => {
            printCliError(json_output, "OVERRIDE_SCRIPT_NOT_FOUND", "override script or lua runtime not found", "verify `--override-script` path and lua runtime availability");
            return true;
        },
        error.OverrideScriptExecFailed => {
            printCliError(json_output, "OVERRIDE_SCRIPT_EXEC_FAILED", "override script execution failed", "ensure script exits 0 and prints valid yaml patch");
            return true;
        },
        error.OverrideScriptTimeout => {
            printCliError(json_output, "OVERRIDE_SCRIPT_TIMEOUT", "override script timed out", "increase `--override-timeout-ms` or optimize script");
            return true;
        },
        error.OverrideOutputInvalid => {
            printCliError(json_output, "OVERRIDE_OUTPUT_INVALID", "override script output is invalid", "return/print a yaml object with known config keys");
            return true;
        },
        error.OverrideMergeFailed => {
            printCliError(json_output, "OVERRIDE_MERGE_FAILED", "failed to merge override output", "check script output structure, or run `zc config override --clear` / `zc config dump --no-override`");
            return true;
        },
        error.UnsupportedCapability => {
            printCliError(
                json_output,
                "CONFIG_CAPABILITY_UNSUPPORTED",
                "config uses a capability not supported in zc v1.0",
                "run `zc doctor -c <config>` and use direct/reject/ss/trojan",
            );
            return true;
        },
        else => return false,
    }
}

fn printConfigOverrideError(json_output: bool, err: anyerror) void {
    switch (err) {
        error.NoActiveConfig => printCliError(json_output, "CONFIG_OVERRIDE_NO_ACTIVE", "no active config found for override", "run `zc config use <name>` first"),
        error.FileNotFound => printCliError(json_output, "CONFIG_OVERRIDE_SCRIPT_NOT_FOUND", "override script file not found", "check script path and retry"),
        error.RuleProviderDownloadFailed => printCliError(json_output, "RULE_PROVIDER_DOWNLOAD_FAILED", "failed to download rule-provider files", "check provider url/network and retry"),
        error.RuleProviderFileNotFound => printCliError(json_output, "RULE_PROVIDER_FILE_NOT_FOUND", "rule-provider file not found", "check `rule-providers.<name>.path` or provider url"),
        else => printCliError(json_output, "CONFIG_OVERRIDE_FAILED", "failed to update persisted config override", "check config state and retry"),
    }
}

fn printConfigOverridePrepareError(json_output: bool, err: anyerror) void {
    switch (err) {
        error.RuleProviderDownloadFailed => printCliError(json_output, "RULE_PROVIDER_DOWNLOAD_FAILED", "failed to download rule-provider files", "check provider url/network and retry"),
        error.RuleProviderFileNotFound => printCliError(json_output, "RULE_PROVIDER_FILE_NOT_FOUND", "rule-provider file not found", "check `rule-providers.<name>.path` or provider url"),
        else => printCliError(json_output, "CONFIG_OVERRIDE_FAILED", "failed to prepare merged config after override", "check script output and provider paths"),
    }
}

fn printConfigOverrideApplyError(json_output: bool, _: anyerror) void {
    printCliError(
        json_output,
        "CONFIG_OVERRIDE_APPLY_FAILED",
        "override persisted but failed to apply to running daemon",
        "check `zc log --no-follow`, then run `zc restart`",
    );
}

fn printConfigDumpError(json_output: bool, _: anyerror) void {
    printCliError(json_output, "CONFIG_DUMP_FAILED", "failed to dump merged config", "check config path/override script and retry");
}

// ---------------------------------------------------------------------------
// config 命令树（Batch 3）
// ---------------------------------------------------------------------------

const ConfigDownloadArgs = struct {
    url: []const u8,
    name: ?[]const u8 = null,
    /// `-d`：下载后设为默认（active）。
    set_default: bool = false,
};

/// 全局 flag（main() 经 hasFlag 解析）：子命令解析器跳过它们但不报错。
fn isGlobalCliFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--no-color");
}

/// 决策 D11：剩余参数里只允许全局 flag，任何其他残余参数都是用法错误。
/// 返回 true 表示存在意外参数（调用方负责报错 + exit_usage）。
fn hasUnexpectedArgs(args: []const []const u8, start_index: usize) bool {
    var i = start_index;
    while (i < args.len) : (i += 1) {
        if (!isGlobalCliFlag(args[i])) return true;
    }
    return false;
}

const LogCommandArgs = struct {
    lines: ?usize = null,
    /// 文本模式默认持续刷新。
    follow: bool = true,
    follow_explicit: bool = false,
};

/// `zc log [-n <lines>] [-f|--no-follow]`。
/// 决策 D11：未知 flag / 多余位置参数 / 缺值或非整数 `-n` -> 用法错误
/// （终结 `-n abc` 静默回退 50 行的行为）。
fn parseLogCommandArgs(args: []const []const u8, start_index: usize) !LogCommandArgs {
    var parsed = LogCommandArgs{};
    var i = start_index;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isGlobalCliFlag(arg)) continue;
        if (std.mem.eql(u8, arg, "-n")) {
            if (i + 1 >= args.len or isGlobalCliFlag(args[i + 1])) return error.MissingLinesValue;
            parsed.lines = std.fmt.parseInt(usize, args[i + 1], 10) catch return error.InvalidLinesValue;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-f")) {
            parsed.follow = true;
            parsed.follow_explicit = true;
        } else if (std.mem.eql(u8, arg, "--no-follow")) {
            parsed.follow = false;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return parsed;
}

fn printLogCommandArgError(json_output: bool, err: anyerror) void {
    const message = switch (err) {
        error.MissingLinesValue => "missing value for `-n`",
        error.InvalidLinesValue => "invalid `-n` value (use a non-negative integer)",
        else => "unknown or unexpected argument for `log`",
    };
    printCliError(json_output, "LOG_ARGUMENT_INVALID", message, "use `zc log [-n <lines>] [-f|--no-follow] [--json]`");
}

/// `zc config download <url> [-n <name>] [-d]`：url 必须是第一个位置参数。
/// 决策 D11：未知 flag / 多余位置参数 -> error.UnexpectedArgument。
fn parseConfigDownloadArgs(args: []const []const u8, start_index: usize) !ConfigDownloadArgs {
    if (args.len <= start_index) return error.MissingUrl;
    const url = args[start_index];
    if (url.len == 0 or url[0] == '-') return error.MissingUrl;

    var name: ?[]const u8 = null;
    var set_default = false;
    var i = start_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isGlobalCliFlag(arg)) continue;
        if (std.mem.eql(u8, arg, "-n")) {
            if (i + 1 >= args.len) return error.MissingNameValue;
            name = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "-d")) {
            set_default = true;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return .{ .url = url, .name = name, .set_default = set_default };
}

const ConfigUpdateArgs = struct {
    name: ?[]const u8 = null,
    apply_mode: UpdateApplyMode = .auto,
};

/// `zc config update [name] [--apply auto|hot|restart]`。
/// 决策 D11：未知 flag（如 `--aply` 拼写错误）/ 多余位置参数 ->
/// error.UnexpectedArgument，绝不静默忽略后照常执行。
fn parseConfigUpdateArgs(args: []const []const u8, start_index: usize) !ConfigUpdateArgs {
    var parsed = ConfigUpdateArgs{};
    var i = start_index;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isGlobalCliFlag(arg)) continue;
        if (std.mem.eql(u8, arg, "--apply")) {
            if (i + 1 >= args.len) return error.MissingApplyValue;
            parsed.apply_mode = try parseUpdateApplyMode(args[i + 1]);
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--apply=")) {
            parsed.apply_mode = try parseUpdateApplyMode(arg["--apply=".len..]);
        } else if (arg.len > 0 and arg[0] == '-') {
            return error.UnexpectedArgument;
        } else if (parsed.name == null) {
            parsed.name = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return parsed;
}

const ConfigDumpArgs = struct {
    config_path: ?[]const u8 = null,
    no_override: bool = false,
};

/// `zc config dump [-c <config>] [--no-override]`，外加帮助里声明的
/// override flags（它们由 override.parseCliOptions 全局解析/校验，这里只跳过）。
/// 决策 D11：其余未知 flag / 缺值 flag -> 用法错误（终结 hasFlag 全 argv 扫描）。
fn parseConfigDumpArgs(args: []const []const u8, start_index: usize) !ConfigDumpArgs {
    var parsed = ConfigDumpArgs{};
    var i = start_index;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isGlobalCliFlag(arg)) continue;
        if (std.mem.eql(u8, arg, "-c")) {
            if (i + 1 >= args.len) return error.MissingConfigPathValue;
            parsed.config_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-override")) {
            parsed.no_override = true;
        } else if (std.mem.eql(u8, arg, "--override-script") or
            std.mem.eql(u8, arg, "--override-timeout-ms") or
            std.mem.eql(u8, arg, "--override-arg"))
        {
            // 值的存在性/合法性由 override.parseCliOptions 负责（缺值在
            // dispatch 前就已报 usage 错误），这里跳过 flag 及其值。
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--override-script=") or
            std.mem.startsWith(u8, arg, "--override-timeout-ms=") or
            std.mem.startsWith(u8, arg, "--override-arg="))
        {
            // `=` 形式自带值，整体跳过。
        } else {
            return error.UnexpectedArgument;
        }
    }
    return parsed;
}

/// reload/update 共用的 apply 结果 token（与 `zc reload` 的 `applied` 取值一致）。
fn applyResultToken(result: ?daemon.ApplyResult) ?[]const u8 {
    const r = result orelse return null;
    return switch (r) {
        .hot_applied => "hot",
        .restart_applied => "restart",
        .restart_fallback => "restart_fallback",
    };
}

fn printInvalidConfigName(json_output: bool) void {
    printCliError(
        json_output,
        "CONFIG_NAME_INVALID",
        "invalid config name",
        "use 1-250 bytes of UTF-8 without control characters, '/' or '\\'",
    );
}

const CatalogHealth = struct {
    state_sync_error: ?anyerror = null,
    mirror_error: ?anyerror = null,

    fn durabilityUncertain(self: CatalogHealth) bool {
        return self.state_sync_error != null;
    }

    fn mirrorOutOfSync(self: CatalogHealth) bool {
        return self.mirror_error != null;
    }
};

const CatalogRoot = struct {
    dir: std.Io.Dir,
    bootstrap_health: CatalogHealth,

    fn deinit(self: *CatalogRoot) void {
        self.dir.close(compat.io());
        self.* = undefined;
    }

    fn healthWithReceipt(
        self: *const CatalogRoot,
        receipt: ?*const catalog_service.ApplyReceipt,
    ) CatalogHealth {
        const applied = receipt orelse return self.bootstrap_health;
        return .{
            .state_sync_error = applied.state_sync_error,
            .mirror_error = applied.mirror_error,
        };
    }
};

fn noteCatalogHealth(out: *cli_output.Output, health: CatalogHealth) void {
    if (health.state_sync_error) |err| {
        out.note("catalog committed, but durability is uncertain: {s}\n", .{
            @errorName(err),
        }) catch {};
    }
    if (health.mirror_error) |err| {
        out.note("legacy mirror is out of sync: {s}\n", .{@errorName(err)}) catch {};
    }
}

fn openDefaultCatalogRoot(allocator: std.mem.Allocator) !CatalogRoot {
    const root_path = try config.getDefaultConfigDir(allocator) orelse
        return error.NoConfigDir;
    defer allocator.free(root_path);
    if (!compat.fs.path.isAbsolute(root_path)) return error.NoConfigDir;
    try compat.fs.cwd().makePath(root_path);
    const root = try compat.fs.openDirAbsolute(root_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer root.close(compat.io());
    const outcome = try legacy_catalog_bootstrap.LegacyCatalogBootstrap.init(
        allocator,
        root,
    ).ensure();
    const health: CatalogHealth = switch (outcome) {
        .migrated, .already_current => |receipt| .{
            .mirror_error = receipt.mirror_error,
        },
        .durability_uncertain => |uncertain| .{
            .state_sync_error = uncertain.cause,
            .mirror_error = uncertain.receipt.mirror_error,
        },
        .blocked => return error.LegacyMigrationBlocked,
    };
    return .{ .dir = root, .bootstrap_health = health };
}

const StableCatalogListing = struct {
    listing: catalog_commands.Listing,
    health: CatalogHealth,

    fn deinit(self: *StableCatalogListing) void {
        self.listing.deinit();
        self.* = undefined;
    }
};

fn listCatalogStable(
    allocator: std.mem.Allocator,
    root: *const CatalogRoot,
    commands: catalog_commands.Commands,
) !StableCatalogListing {
    for (0..catalog_listing_attempts) |_| {
        var listing = try commands.list();
        const verified = legacy_mirror.LegacyMirror.init(
            allocator,
            root.dir,
        ).verify() catch |err| return .{
            .listing = listing,
            .health = .{
                .state_sync_error = root.bootstrap_health.state_sync_error,
                .mirror_error = err,
            },
        };
        if (verified.sequence == listing.token.sequence) {
            return .{
                .listing = listing,
                .health = .{
                    .state_sync_error = root.bootstrap_health.state_sync_error,
                },
            };
        }
        listing.deinit();
    }
    return error.StateConflict;
}

const StableActiveOverride = struct {
    snapshot: catalog_commands.ActiveOverride,
    health: CatalogHealth,

    fn deinit(self: *StableActiveOverride) void {
        self.snapshot.deinit();
        self.* = undefined;
    }
};

fn activeOverrideStable(
    allocator: std.mem.Allocator,
    root: *const CatalogRoot,
    commands: catalog_commands.Commands,
) !StableActiveOverride {
    for (0..catalog_listing_attempts) |_| {
        var snapshot = try commands.activeOverride();
        const verified = legacy_mirror.LegacyMirror.init(
            allocator,
            root.dir,
        ).verify() catch |err| return .{
            .snapshot = snapshot,
            .health = .{
                .state_sync_error = root.bootstrap_health.state_sync_error,
                .mirror_error = err,
            },
        };
        if (verified.sequence == snapshot.token.sequence) {
            return .{
                .snapshot = snapshot,
                .health = .{
                    .state_sync_error = root.bootstrap_health.state_sync_error,
                },
            };
        }
        snapshot.deinit();
    }
    return error.StateConflict;
}

fn renderCatalogListing(
    allocator: std.mem.Allocator,
    listing: *const catalog_commands.Listing,
    health: CatalogHealth,
    out: *cli_output.Output,
) !void {
    if (out.mode == .json) {
        const Entry = struct {
            name: []const u8,
            display: []const u8,
            active: bool,
        };
        const entries = try allocator.alloc(Entry, listing.entries.len);
        defer allocator.free(entries);
        for (listing.entries, entries) |source, *entry| {
            entry.* = .{
                .name = source.key,
                .display = source.display,
                .active = source.active,
            };
        }
        try out.success(.{
            .configs = entries,
            .active = listing.active,
            .durability_uncertain = health.durabilityUncertain(),
            .mirror_out_of_sync = health.mirrorOutOfSync(),
        });
        return;
    }

    noteCatalogHealth(out, health);
    try out.print("Available configs:\n\n", .{});
    for (listing.entries) |entry| {
        if (entry.active) {
            try out.print("  * {s}", .{entry.display});
        } else {
            try out.print("    {s}", .{entry.display});
        }
        if (!std.mem.eql(u8, entry.display, entry.key)) {
            try out.print(" ({s})", .{entry.key});
        }
        if (entry.active) try out.print(" (active)", .{});
        try out.print("\n", .{});
    }
    if (listing.entries.len == 0) {
        try out.print("  (no config files found)\n", .{});
    } else {
        try out.print("\nUse 'zc config use <key>' to switch config\n", .{});
    }
    try out.flush();
}

fn catalogMirrorPathAlloc(
    allocator: std.mem.Allocator,
    key: []const u8,
) ![]u8 {
    const configs_dir = try meta.getConfigsDir(allocator) orelse
        return error.NoConfigDir;
    defer allocator.free(configs_dir);
    const filename = try std.fmt.allocPrint(allocator, "{s}.yaml", .{key});
    defer allocator.free(filename);
    return compat.fs.path.join(allocator, &.{ configs_dir, filename });
}

/// config 命令树 dispatch。错误统一走 printCliError（envelope/error block）
/// 并以非零码退出；用法错误用 exit_usage，运行失败用 exit_failure。
fn runConfigCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    json_output: bool,
    override_opts: *const override.CliOptions,
) !void {
    // 裸 `zc config`（或只带全局 flag）-> 组帮助（stdout, exit 0）
    if (args.len < 3 or isHelpArg(args[2]) or
        std.mem.eql(u8, args[2], "--json") or std.mem.eql(u8, args[2], "--no-color"))
    {
        try printConfigHelp();
        return;
    }
    const subcmd = args[2];

    if (std.mem.eql(u8, subcmd, "load")) {
        if (containsHelpArg(args, 3)) {
            try printConfigLoadHelp();
            return;
        }
        if (args.len < 4 or args[3].len == 0 or args[3][0] == '-') {
            printCliError(json_output, "CONFIG_LOAD_PATH_REQUIRED", "missing <path> for config load", "use `zc config load <path>`");
            std.process.exit(cli_output.exit_usage);
        }
        if (hasUnexpectedArgs(args, 4)) {
            printCliError(json_output, "CONFIG_LOAD_ARGUMENT_INVALID", "unknown or unexpected argument for `config load`", "use `zc config load <path>`");
            std.process.exit(cli_output.exit_usage);
        }
        var receipt = config_import.loadDefault(allocator, args[3]) catch |err| {
            switch (err) {
                error.ManagedProfileAlreadyExists => printCliError(json_output, "CONFIG_ALREADY_EXISTS", "a config with this name already exists", "rename the file or delete the existing config first"),
                error.InvalidConfig, error.InvalidConfigKey => printCliError(json_output, "CONFIG_LOAD_INVALID", "local config is invalid", "fix the config and retry"),
                else => printCliError(json_output, "CONFIG_LOAD_FAILED", "failed to load local config", "check the path, local dependencies, and file permissions"),
            }
            std.process.exit(cli_output.exit_failure);
        };
        defer receipt.deinit(allocator);
        var streams = StdStreams{};
        var out = streams.output(json_output);
        const health: CatalogHealth = .{
            .state_sync_error = receipt.state_sync_error,
            .mirror_error = receipt.mirror_error,
        };
        noteCatalogHealth(&out, health);
        if (json_output) {
            var revision_hex: [32]u8 = undefined;
            out.success(.{
                .action = "config_load",
                .name = receipt.key,
                .revision = receipt.revision.formatHex(&revision_hex),
                .active = receipt.active,
                .applied = false,
                .durability_uncertain = health.durabilityUncertain(),
                .mirror_out_of_sync = health.mirrorOutOfSync(),
            }) catch {};
        } else {
            out.print("Loaded local config: {s}\n", .{receipt.key}) catch {};
            out.print("Config is active; run `zc reload` or `zc restart` to apply it\n", .{}) catch {};
            out.flush() catch {};
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        if (containsHelpArg(args, 3)) {
            try printConfigListHelp();
            return;
        }
        if (hasUnexpectedArgs(args, 3)) {
            printCliError(json_output, "CONFIG_LIST_ARGUMENT_INVALID", "unknown or unexpected argument for `config list`", "use `zc config list [--json]`");
            std.process.exit(cli_output.exit_usage);
        }
        var streams = StdStreams{};
        var out = streams.output(json_output);
        var root = openDefaultCatalogRoot(allocator) catch {
            printCliError(json_output, "CONFIG_LIST_FAILED", "failed to list configs", "ensure the config directory exists and is readable");
            std.process.exit(cli_output.exit_failure);
        };
        defer root.deinit();
        const commands = catalog_commands.Commands.init(allocator, root.dir);
        var stable = listCatalogStable(allocator, &root, commands) catch {
            printCliError(json_output, "CONFIG_LIST_FAILED", "failed to list configs", "repair the managed catalog and retry");
            std.process.exit(cli_output.exit_failure);
        };
        defer stable.deinit();
        renderCatalogListing(
            allocator,
            &stable.listing,
            stable.health,
            &out,
        ) catch {
            printCliError(json_output, "CONFIG_LIST_FAILED", "failed to render configs", "retry the command");
            std.process.exit(cli_output.exit_failure);
        };
        return;
    }

    if (std.mem.eql(u8, subcmd, "download")) {
        if (containsHelpArg(args, 3)) {
            try printConfigDownloadHelp();
            return;
        }
        const dl = parseConfigDownloadArgs(args, 3) catch |err| {
            switch (err) {
                error.MissingUrl => printCliError(json_output, "CONFIG_DOWNLOAD_URL_REQUIRED", "missing <url> for config download", "use `zc config download <url> [-n <name>] [-d]`"),
                error.MissingNameValue => printCliError(json_output, "CONFIG_DOWNLOAD_NAME_REQUIRED", "missing value for `-n`", "use `zc config download <url> -n <name>`"),
                error.UnexpectedArgument => printCliError(json_output, "CONFIG_DOWNLOAD_ARGUMENT_INVALID", "unknown or unexpected argument for `config download`", "use `zc config download <url> [-n <name>] [-d]`"),
            }
            std.process.exit(cli_output.exit_usage);
        };

        var streams = StdStreams{};
        var out = streams.output(json_output);
        const key = if (dl.name) |name|
            allocator.dupe(u8, config.normalizePortableManagedConfigKey(name) catch {
                printInvalidConfigName(json_output);
                std.process.exit(cli_output.exit_failure);
            }) catch return error.OutOfMemory
        else
            meta.generateKey(allocator) catch return error.OutOfMemory;
        defer allocator.free(key);
        const mirror_path = catalogMirrorPathAlloc(allocator, key) catch |err| {
            out.note("config path preparation failed: {s}\n", .{@errorName(err)}) catch {};
            printCliError(json_output, "CONFIG_DOWNLOAD_FAILED", "config destination could not be prepared", "check the config directory and retry");
            std.process.exit(cli_output.exit_failure);
        };
        defer allocator.free(mirror_path);
        const fetched = config.fetchConfig(allocator, dl.url) catch |err| {
            out.note("config download failed: {s}\n", .{@errorName(err)}) catch {};
            switch (err) {
                error.ConfigTooLarge => printCliError(
                    json_output,
                    "CONFIG_DOWNLOAD_TOO_LARGE",
                    "downloaded config exceeds the 16 MiB limit",
                    "reduce the config size and retry",
                ),
                error.DownloadTimeout => printCliError(
                    json_output,
                    "CONFIG_DOWNLOAD_TIMEOUT",
                    "config download exceeded the 30 second deadline",
                    "check the server or network and retry",
                ),
                else => printCliError(json_output, "CONFIG_DOWNLOAD_FAILED", "failed to download config", "check the url/network and retry"),
            }
            std.process.exit(cli_output.exit_failure);
        };
        defer allocator.free(fetched.body);
        if (fetched.status != .ok) {
            printCliError(json_output, "CONFIG_DOWNLOAD_FAILED", "config server returned a non-success status", "check the url and retry");
            std.process.exit(cli_output.exit_failure);
        }
        var root = openDefaultCatalogRoot(allocator) catch |err| {
            out.note("config catalog open failed: {s}\n", .{@errorName(err)}) catch {};
            printCliError(json_output, "CONFIG_DOWNLOAD_FAILED", "downloaded config could not be stored", "repair the managed catalog and retry");
            std.process.exit(cli_output.exit_failure);
        };
        defer root.deinit();
        const commands = catalog_commands.Commands.init(allocator, root.dir);
        const published = commands.publishDownloaded(.{
            .key = key,
            .source_bytes = fetched.body,
            .metadata = .{ .url = dl.url, .filename = key },
            .mode = .create,
            .activate = dl.set_default,
        }) catch |err| {
            out.note("config catalog publish failed: {s}\n", .{@errorName(err)}) catch {};
            switch (err) {
                error.ManagedProfileAlreadyExists => printCliError(json_output, "CONFIG_ALREADY_EXISTS", "a config with this name already exists", "use `zc config update`, or choose another name"),
                error.InvalidConfig, error.InvalidConfigKey => printCliError(json_output, "CONFIG_DOWNLOAD_FAILED", "downloaded config is invalid", "fix the source config and retry"),
                else => printCliError(json_output, "CONFIG_DOWNLOAD_FAILED", "downloaded config could not be committed", "repair the managed catalog and retry"),
            }
            std.process.exit(cli_output.exit_failure);
        };
        const health = root.healthWithReceipt(&published.receipt);
        noteCatalogHealth(&out, health);
        var listing: ?catalog_commands.Listing = commands.list() catch |err| blk: {
            out.note("config committed, but active-state verification failed: {s}\n", .{@errorName(err)}) catch {};
            break :blk null;
        };
        defer if (listing) |*value| value.deinit();
        const is_active = if (listing) |*value|
            if (value.active) |active| std.mem.eql(u8, active, key) else false
        else
            dl.set_default;
        if (json_output) {
            var revision_hex: [32]u8 = undefined;
            out.success(.{
                .name = key,
                .path = if (health.mirrorOutOfSync()) null else mirror_path,
                .revision = published.revision.formatHex(&revision_hex),
                .set_default = is_active,
                .durability_uncertain = health.durabilityUncertain(),
                .mirror_out_of_sync = health.mirrorOutOfSync(),
            }) catch {};
        } else {
            out.print("Config downloaded: {s} (key: {s})\n", .{ key, key }) catch {};
            if (!health.mirrorOutOfSync()) {
                out.print("Config saved to: {s}\n", .{mirror_path}) catch {};
            }
            if (is_active) out.print("Config set as default: {s}\n", .{key}) catch {};
            out.flush() catch {};
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "update")) {
        if (containsHelpArg(args, 3)) {
            try printConfigUpdateHelp();
            return;
        }
        const upd = parseConfigUpdateArgs(args, 3) catch |err| {
            switch (err) {
                error.MissingApplyValue => printCliError(json_output, "CONFIG_UPDATE_APPLY_INVALID", "missing value for `--apply`", "use `--apply auto|hot|restart`"),
                error.InvalidApplyMode => printCliError(json_output, "CONFIG_UPDATE_APPLY_INVALID", "invalid `--apply` value", "use `--apply auto|hot|restart`"),
                error.UnexpectedArgument => printCliError(json_output, "CONFIG_UPDATE_ARGUMENT_INVALID", "unknown or unexpected argument for `config update`", "use `zc config update [name] [--apply auto|hot|restart]`"),
            }
            std.process.exit(cli_output.exit_usage);
        };

        var streams = StdStreams{};
        var out = streams.output(json_output);
        var root = openDefaultCatalogRoot(allocator) catch {
            printCliError(json_output, "CONFIG_UPDATE_FAILED", "failed to open the managed catalog", "repair the managed catalog and retry");
            std.process.exit(cli_output.exit_failure);
        };
        defer root.deinit();
        const commands = catalog_commands.Commands.init(allocator, root.dir);
        var listing = commands.list() catch {
            printCliError(json_output, "CONFIG_UPDATE_FAILED", "failed to read the managed catalog", "repair the managed catalog and retry");
            std.process.exit(cli_output.exit_failure);
        };
        defer listing.deinit();
        const target_name = upd.name orelse listing.active orelse {
            printCliError(json_output, "CONFIG_UPDATE_NAME_REQUIRED", "no config name given and no active config", "use `zc config update <name>`, or `zc config use <name>` first");
            std.process.exit(cli_output.exit_usage);
        };
        const updated_key = config.normalizeManagedConfigKey(target_name) catch {
            printInvalidConfigName(json_output);
            std.process.exit(cli_output.exit_failure);
        };
        var subscription = commands.subscription(updated_key) catch |err| {
            switch (err) {
                error.NoSubscriptionUrl => printCliError(json_output, "CONFIG_UPDATE_NO_SUBSCRIPTION", "no subscription url recorded for this config", "use `zc config download <url>` to recreate it"),
                error.ManagedProfileNotFound => printCliError(json_output, "CONFIG_NOT_FOUND", "config not found", "run `zc config list` and choose an existing config"),
                else => printCliError(json_output, "CONFIG_UPDATE_FAILED", "failed to read the managed revision", "repair the managed catalog and retry"),
            }
            std.process.exit(cli_output.exit_failure);
        };
        defer subscription.deinit();
        const fetched = config.fetchConfig(allocator, subscription.url) catch |err| {
            switch (err) {
                error.ConfigTooLarge => printCliError(json_output, "CONFIG_UPDATE_TOO_LARGE", "updated config exceeds the 16 MiB limit", "reduce the config size and retry"),
                error.DownloadTimeout => printCliError(json_output, "CONFIG_UPDATE_TIMEOUT", "config update exceeded the 30 second deadline", "check the server or network and retry"),
                else => printCliError(json_output, "CONFIG_UPDATE_FAILED", "failed to download the updated config", "check the subscription url/network and retry"),
            }
            std.process.exit(cli_output.exit_failure);
        };
        defer allocator.free(fetched.body);
        if (fetched.status != .ok) {
            printCliError(json_output, "CONFIG_UPDATE_FAILED", "config server returned a non-success status", "check the subscription url and retry");
            std.process.exit(cli_output.exit_failure);
        }
        var process_runner = override_materialization.ProcessRunner.init(root.dir);
        const published = commands.publishDownloaded(.{
            .key = updated_key,
            .source_bytes = fetched.body,
            .mode = .update,
            .expected_revision = subscription.revision,
            .override_runner = process_runner.runner(),
        }) catch |err| {
            out.note("config catalog update failed: {s}\n", .{@errorName(err)}) catch {};
            switch (err) {
                error.InvalidConfig => printCliError(json_output, "CONFIG_UPDATE_FAILED", "updated config is invalid", "fix the subscription source and retry"),
                error.ManagedProfileNotFound => printCliError(json_output, "CONFIG_NOT_FOUND", "config not found", "run `zc config list` and choose an existing config"),
                error.ProfileIdentityConflict, error.StateConflict => printCliError(json_output, "CONFIG_UPDATE_CONFLICT", "config changed while its update was downloading", "retry `zc config update` against the new profile revision"),
                else => printCliError(json_output, "CONFIG_UPDATE_FAILED", "failed to commit the updated revision", "repair the managed catalog and retry"),
            }
            std.process.exit(cli_output.exit_failure);
        };
        const health = root.healthWithReceipt(&published.receipt);
        noteCatalogHealth(&out, health);

        // 应用策略：auto(默认)/hot/restart —— 只对运行中的 daemon 生效。
        // JSON 模式只输出一个最终 envelope（D6 同款），apply 结果折叠进 data。
        var apply_result: ?daemon.ApplyResult = null;
        if (daemon.isRunning(allocator) catch false) {
            const updated_path = managedConfigPathForKey(
                allocator,
                updated_key,
            ) catch |err| {
                out.note(
                    "config apply target resolution failed: {s}\n",
                    .{@errorName(err)},
                ) catch {};
                printCliError(
                    json_output,
                    "CONFIG_UPDATE_APPLY_FAILED",
                    "config updated but its exact apply target could not be resolved",
                    "run `zc config list`, then apply the updated profile explicitly",
                );
                std.process.exit(cli_output.exit_failure);
            };
            defer allocator.free(updated_path);
            apply_result = reloadOrRestartPrepared(
                allocator,
                updated_path,
                upd.apply_mode,
                false,
                .{
                    .key = updated_key,
                    .revision = published.revision,
                },
            ) catch |err| {
                switch (err) {
                    error.ForegroundDaemonSupervised => printCliError(json_output, "CONFIG_UPDATE_APPLY_FAILED", "config updated but daemon runs in the foreground (likely under a supervisor)", "restart it via the supervisor (e.g. `systemctl restart`)"),
                    else => printCliError(json_output, "CONFIG_UPDATE_APPLY_FAILED", "config updated but failed to apply to running daemon", "check `zc log --no-follow`, then run `zc restart`"),
                }
                std.process.exit(cli_output.exit_failure);
            };
        }

        if (json_output) {
            out.success(.{
                .name = updated_key,
                .applied = apply_result != null,
                .apply_result = applyResultToken(apply_result),
                .durability_uncertain = health.durabilityUncertain(),
                .mirror_out_of_sync = health.mirrorOutOfSync(),
            }) catch {};
        } else {
            out.print("Config updated: {s}\n", .{updated_key}) catch {};
            if (apply_result) |result| switch (result) {
                .hot_applied => out.print("Config applied via hot reload\n", .{}) catch {},
                .restart_applied => out.print("Config applied via restart\n", .{}) catch {},
                .restart_fallback => out.print("Config hot reload unavailable, fell back to restart\n", .{}) catch {},
            };
            out.flush() catch {};
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "use")) {
        if (containsHelpArg(args, 3)) {
            try printConfigUseHelp();
            return;
        }
        if (args.len < 4 or args[3].len == 0 or args[3][0] == '-') {
            printCliError(json_output, "CONFIG_USE_NAME_REQUIRED", "missing <name> for config use", "use `zc config use <name>`; run `zc config list` to see candidates");
            std.process.exit(cli_output.exit_usage);
        }
        if (hasUnexpectedArgs(args, 4)) {
            printCliError(json_output, "CONFIG_USE_ARGUMENT_INVALID", "unknown or unexpected argument for `config use`", "use `zc config use <name>`");
            std.process.exit(cli_output.exit_usage);
        }

        var streams = StdStreams{};
        var out = streams.output(json_output);
        const key = config.normalizeManagedConfigKey(args[3]) catch {
            printInvalidConfigName(json_output);
            std.process.exit(cli_output.exit_failure);
        };
        var root = openDefaultCatalogRoot(allocator) catch {
            printCliError(json_output, "CONFIG_SWITCH_FAILED", "failed to open the managed catalog", "repair the managed catalog and retry");
            std.process.exit(cli_output.exit_failure);
        };
        defer root.deinit();
        const receipt = catalog_commands.Commands.init(
            allocator,
            root.dir,
        ).activate(key) catch |err| {
            switch (err) {
                error.ManagedProfileNotFound => printCliError(json_output, "CONFIG_NOT_FOUND", "config not found", "run `zc config list` and pick an existing config name"),
                else => printCliError(json_output, "CONFIG_SWITCH_FAILED", "failed to switch active config", "repair the managed catalog and retry"),
            }
            std.process.exit(cli_output.exit_failure);
        };
        const health = root.healthWithReceipt(&receipt);
        noteCatalogHealth(&out, health);

        // 决策 D8：use 绝不自动 apply 到运行中的 daemon；data 注明 applied:false。
        if (json_output) {
            out.success(.{
                .name = key,
                .applied = false,
                .durability_uncertain = health.durabilityUncertain(),
                .mirror_out_of_sync = health.mirrorOutOfSync(),
            }) catch {};
        } else {
            out.print("Switched to config: {s}\n", .{key}) catch {};
            out.print("Run `zc reload` (or `zc restart`) to apply it\n", .{}) catch {};
            out.flush() catch {};
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "delete") or std.mem.eql(u8, subcmd, "rm") or std.mem.eql(u8, subcmd, "remove")) {
        if (containsHelpArg(args, 3)) {
            try printConfigDeleteHelp();
            return;
        }
        if (args.len < 4 or args[3].len == 0 or args[3][0] == '-') {
            printCliError(json_output, "CONFIG_DELETE_NAME_REQUIRED", "missing <name> for config delete", "use `zc config delete <name>`; run `zc config list` to see candidates");
            std.process.exit(cli_output.exit_usage);
        }
        if (hasUnexpectedArgs(args, 4)) {
            printCliError(json_output, "CONFIG_DELETE_ARGUMENT_INVALID", "unknown or unexpected argument for `config delete`", "use `zc config delete <name>`");
            std.process.exit(cli_output.exit_usage);
        }

        var streams = StdStreams{};
        var out = streams.output(json_output);
        const key = config.normalizeManagedConfigKey(args[3]) catch {
            printInvalidConfigName(json_output);
            std.process.exit(cli_output.exit_failure);
        };
        var root = openDefaultCatalogRoot(allocator) catch {
            printCliError(json_output, "CONFIG_DELETE_FAILED", "failed to open the managed catalog", "repair the managed catalog and retry");
            std.process.exit(cli_output.exit_failure);
        };
        defer root.deinit();
        const commands = catalog_commands.Commands.init(allocator, root.dir);
        const receipt = commands.delete(key) catch |err| {
            switch (err) {
                error.ManagedProfileNotFound => printCliError(json_output, "CONFIG_NOT_FOUND", "config not found", "run `zc config list` and pick an existing config name"),
                else => printCliError(json_output, "CONFIG_DELETE_FAILED", "failed to delete config", "repair the managed catalog and retry"),
            }
            std.process.exit(cli_output.exit_failure);
        };
        const health = root.healthWithReceipt(&receipt.receipt);
        noteCatalogHealth(&out, health);

        // 决策 D8 同款：delete 绝不自动 apply 到运行中的 daemon。
        if (json_output) {
            out.success(.{
                .name = key,
                .deleted = true,
                .was_active = receipt.was_active,
                .durability_uncertain = health.durabilityUncertain(),
                .mirror_out_of_sync = health.mirrorOutOfSync(),
            }) catch {};
        } else {
            out.print("Deleted config: {s}\n", .{key}) catch {};
            if (receipt.was_active) out.print("The active config was cleared; run `zc config use <name>` before the next restart\n", .{}) catch {};
            out.flush() catch {};
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "dump")) {
        if (containsHelpArg(args, 3)) {
            try printConfigDumpHelp();
            return;
        }
        const dump_args = parseConfigDumpArgs(args, 3) catch |err| {
            switch (err) {
                error.MissingConfigPathValue => printCliError(json_output, "CONFIG_DUMP_ARGUMENT_INVALID", "missing value for `-c`", "use `zc config dump -c <config>`"),
                error.UnexpectedArgument => printCliError(json_output, "CONFIG_DUMP_ARGUMENT_INVALID", "unknown or unexpected argument for `config dump`", "use `zc config dump [-c <config>] [--no-override]`"),
            }
            std.process.exit(cli_output.exit_usage);
        };
        const config_path = dump_args.config_path;
        const no_override = dump_args.no_override;
        var loaded = if (config_path) |path| blk: {
            const managed = tryLoadExactManagedRuntime(
                allocator,
                path,
                !no_override,
            ) catch |err| {
                printConfigDumpError(json_output, err);
                std.process.exit(cli_output.exit_failure);
            };
            if (managed) |exact| break :blk exact;
            break :blk RuntimeLoadedConfig{
                .allocator = allocator,
                .value = config.load(allocator, path) catch |err| {
                    printConfigDumpError(json_output, err);
                    std.process.exit(cli_output.exit_failure);
                },
                .identity = null,
            };
        } else (tryLoadExactManagedRuntime(
            allocator,
            null,
            !no_override,
        ) catch |err| {
            printConfigDumpError(json_output, err);
            std.process.exit(cli_output.exit_failure);
        }) orelse {
            printConfigDumpError(json_output, error.NoActiveManagedConfig);
            std.process.exit(cli_output.exit_failure);
        };
        defer loaded.deinit();

        if (!no_override) {
            if (loaded.identity != null) {
                if (override_opts.script_path != null) {
                    var effective_override = override_opts.*;
                    override.apply(
                        allocator,
                        &loaded.value,
                        &effective_override,
                        "config.dump",
                        config_path,
                    ) catch |err| {
                        if (!printOverrideRuntimeError(json_output, err))
                            printConfigDumpError(json_output, err);
                        std.process.exit(cli_output.exit_failure);
                    };
                }
            } else {
                var persisted_script: ?[]u8 = null;
                defer if (persisted_script) |path| allocator.free(path);
                var effective_override = resolveEffectiveOverrideOptions(
                    allocator,
                    override_opts,
                    config_path,
                    &persisted_script,
                ) catch |err| {
                    if (!printOverrideRuntimeError(json_output, err))
                        printConfigDumpError(json_output, err);
                    std.process.exit(cli_output.exit_failure);
                };
                override.apply(
                    allocator,
                    &loaded.value,
                    &effective_override,
                    "config.dump",
                    config_path,
                ) catch |err| {
                    if (!printOverrideRuntimeError(json_output, err))
                        printConfigDumpError(json_output, err);
                    std.process.exit(cli_output.exit_failure);
                };
            }
        }

        const dumped = if (json_output)
            override.dumpConfigJson(allocator, &loaded.value)
        else
            override.dumpConfigYaml(allocator, &loaded.value);
        const dumped_text = dumped catch |err| {
            printConfigDumpError(json_output, err);
            std.process.exit(cli_output.exit_failure);
        };
        defer allocator.free(dumped_text);

        // 决策 D2：dump 是唯一的裸文档例外 —— payload 走 stdout，可直接管道。
        var streams = StdStreams{};
        var out = streams.output(json_output);
        out.print("{s}\n", .{dumped_text}) catch {};
        out.flush() catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "override")) {
        if (containsHelpArg(args, 3)) {
            try printConfigOverrideHelp();
            return;
        }
        const action = parseConfigOverrideAction(args, 3) catch {
            // 两种模式同语义：用法错误 -> envelope/error block + exit_usage。
            printCliError(json_output, "CONFIG_OVERRIDE_ARGUMENT_INVALID", "invalid config override arguments", "use `zc config override <script.lua>`, `zc config override --clear`, or `zc config override`");
            std.process.exit(cli_output.exit_usage);
        };

        var streams = StdStreams{};
        var out = streams.output(json_output);
        var root = openDefaultCatalogRoot(allocator) catch |err| {
            printConfigOverrideError(json_output, err);
            std.process.exit(cli_output.exit_failure);
        };
        defer root.deinit();
        const commands = catalog_commands.Commands.init(allocator, root.dir);
        var stable = activeOverrideStable(allocator, &root, commands) catch |err| {
            printConfigOverrideError(json_output, err);
            std.process.exit(cli_output.exit_failure);
        };
        defer stable.deinit();
        const snapshot = &stable.snapshot;
        const profile_name = snapshot.key orelse "(none)";

        switch (action) {
            .set => |script_path| {
                const key = snapshot.key orelse {
                    printConfigOverrideError(json_output, error.NoActiveConfig);
                    std.process.exit(cli_output.exit_failure);
                };
                const script_bytes = compat.fs.cwd().readFileAlloc(
                    allocator,
                    script_path,
                    override_materialization.max_script_bytes,
                ) catch |err| {
                    printConfigOverrideError(json_output, err);
                    std.process.exit(cli_output.exit_failure);
                };
                defer allocator.free(script_bytes);
                var process_runner = override_materialization.ProcessRunner.init(root.dir);
                const published = commands.setOverride(.{
                    .key = key,
                    .script = .{
                        .name = compat.fs.path.basename(script_path),
                        .bytes = script_bytes,
                    },
                    .invocation = .{ .command = "config.override" },
                    .runner = process_runner.runner(),
                    .expected_token = snapshot.token,
                    .require_active = true,
                }) catch |err| {
                    switch (err) {
                        error.StateConflict, error.ActiveManagedProfileChanged => printCliError(
                            json_output,
                            "CONFIG_OVERRIDE_FAILED",
                            "active config changed while preparing the override",
                            "retry against the new active config",
                        ),
                        else => if (!printOverrideRuntimeError(json_output, err))
                            printConfigOverridePrepareError(json_output, err),
                    }
                    std.process.exit(cli_output.exit_failure);
                };
                const health = root.healthWithReceipt(&published.receipt);
                noteCatalogHealth(&out, health);
                applyConfigOverrideToRunningDaemon(
                    allocator,
                    key,
                    published.revision,
                ) catch |err| {
                    printConfigOverrideApplyError(json_output, err);
                    std.process.exit(cli_output.exit_failure);
                };

                if (json_output) {
                    out.success(.{
                        .action = "config_override_set",
                        .profile = profile_name,
                        .enabled = true,
                        .script = script_path,
                        .durability_uncertain = health.durabilityUncertain(),
                        .mirror_out_of_sync = health.mirrorOutOfSync(),
                    }) catch {};
                } else {
                    out.print("Persisted override set for config {s}: {s}\n", .{ profile_name, script_path }) catch {};
                    out.flush() catch {};
                }
            },
            .clear => {
                const key = snapshot.key orelse {
                    printConfigOverrideError(json_output, error.NoActiveConfig);
                    std.process.exit(cli_output.exit_failure);
                };
                const published = commands.clearOverride(.{
                    .key = key,
                    .expected_token = snapshot.token,
                    .require_active = true,
                }) catch |err| {
                    switch (err) {
                        error.StateConflict, error.ActiveManagedProfileChanged => printCliError(
                            json_output,
                            "CONFIG_OVERRIDE_FAILED",
                            "active config changed while clearing the override",
                            "retry against the new active config",
                        ),
                        else => printConfigOverrideError(json_output, err),
                    }
                    std.process.exit(cli_output.exit_failure);
                };
                const had_override = published != null;
                var health = stable.health;
                if (published) |receipt| {
                    health = root.healthWithReceipt(&receipt.receipt);
                    applyConfigOverrideToRunningDaemon(
                        allocator,
                        key,
                        receipt.revision,
                    ) catch |err| {
                        printConfigOverrideApplyError(json_output, err);
                        std.process.exit(cli_output.exit_failure);
                    };
                }

                noteCatalogHealth(&out, health);
                if (json_output) {
                    out.success(.{
                        .action = "config_override_clear",
                        .profile = profile_name,
                        .enabled = false,
                        .cleared = had_override,
                        .durability_uncertain = health.durabilityUncertain(),
                        .mirror_out_of_sync = health.mirrorOutOfSync(),
                    }) catch {};
                } else if (had_override) {
                    out.print("Cleared persisted override for config {s}\n", .{profile_name}) catch {};
                    out.flush() catch {};
                } else {
                    out.print("No persisted override set for config {s}\n", .{profile_name}) catch {};
                    out.flush() catch {};
                }
            },
            .show => {
                const current_script = snapshot.script_name;
                const health = stable.health;
                if (!json_output) noteCatalogHealth(&out, health);
                if (json_output) {
                    if (current_script) |script| {
                        out.success(.{
                            .action = "config_override_get",
                            .profile = profile_name,
                            .enabled = true,
                            .script = script,
                            .durability_uncertain = health.durabilityUncertain(),
                            .mirror_out_of_sync = health.mirrorOutOfSync(),
                        }) catch {};
                    } else {
                        out.success(.{
                            .action = "config_override_get",
                            .profile = profile_name,
                            .enabled = false,
                            .script = null,
                            .durability_uncertain = health.durabilityUncertain(),
                            .mirror_out_of_sync = health.mirrorOutOfSync(),
                        }) catch {};
                    }
                } else if (current_script) |script| {
                    out.print("Config {s} persisted override: {s}\n", .{ profile_name, script }) catch {};
                    out.flush() catch {};
                } else {
                    out.print("Config {s} persisted override: (none)\n", .{profile_name}) catch {};
                    out.flush() catch {};
                }
            },
        }
        return;
    }

    // 未知 config 子命令：两种模式同语义（envelope/error block）+ exit_usage。
    printCliError(json_output, "CONFIG_SUBCOMMAND_UNKNOWN", "unknown config subcommand", "use `zc config --help` to list config subcommands");
    std.process.exit(cli_output.exit_usage);
}

// ---------------------------------------------------------------------------
// proxy/profile 命令家族（Batch 4）
// ---------------------------------------------------------------------------

/// 决策 D10：profile 是 proxy 的别名组，两条路径共用同一 handler，
/// 文案/hint/错误码前缀按实际命令路径渲染（不再泄漏 "proxy" 字样）。
const ProxyFamilyText = struct {
    family: []const u8,
    list_cmd_name: []const u8,
    select_cmd_name: []const u8,
    test_cmd_name: []const u8,
    load_list_msg: []const u8,
    load_select_msg: []const u8,
    load_test_msg: []const u8,
    list_arg_code: []const u8,
    select_arg_code: []const u8,
    test_arg_code: []const u8,
    list_arg_msg: []const u8,
    select_arg_msg: []const u8,
    test_arg_msg: []const u8,
    list_usage_hint: []const u8,
    select_usage_hint: []const u8,
    test_usage_hint: []const u8,
    sub_unknown_code: []const u8,
    sub_unknown_msg: []const u8,
    sub_unknown_hint: []const u8,
    group_not_found_hint: []const u8,
    group_not_select_hint: []const u8,
    proxy_not_found_hint: []const u8,
    not_interactive_hint: []const u8,
};

fn proxyFamilyText(comptime family: []const u8, comptime code_prefix: []const u8) ProxyFamilyText {
    return .{
        .family = family,
        .list_cmd_name = family ++ ".list",
        .select_cmd_name = family ++ ".select",
        .test_cmd_name = family ++ ".test",
        .load_list_msg = "failed to load/validate config for " ++ family ++ " list",
        .load_select_msg = "failed to load/validate config for " ++ family ++ " select",
        .load_test_msg = "failed to load/validate config for " ++ family ++ " test",
        .list_arg_code = code_prefix ++ "_LIST_ARGUMENT_INVALID",
        .select_arg_code = code_prefix ++ "_SELECT_ARGUMENT_INVALID",
        .test_arg_code = code_prefix ++ "_TEST_ARGUMENT_INVALID",
        .list_arg_msg = "unknown or unexpected argument for `" ++ family ++ " list`",
        .select_arg_msg = "unknown or unexpected argument for `" ++ family ++ " select`",
        .test_arg_msg = "unknown or unexpected argument for `" ++ family ++ " test`",
        .list_usage_hint = "use `zc " ++ family ++ " list [-c <config>] [--json]`",
        .select_usage_hint = "use `zc " ++ family ++ " select [-g <group>] [-p <proxy>] [-c <config>] [--json]`",
        .test_usage_hint = "use `zc " ++ family ++ " test [-c <config>] [--port <port>] [--json]`",
        // 冻结错误码（integration tests / docs/api/error-codes.md 断言）。
        .sub_unknown_code = code_prefix ++ "_SUBCOMMAND_UNKNOWN",
        .sub_unknown_msg = "unknown " ++ family ++ " subcommand",
        .sub_unknown_hint = "use `zc " ++ family ++ " --help` or `zc help " ++ family ++ "`",
        .group_not_found_hint = "run `zc " ++ family ++ " list --json` to inspect groups",
        .group_not_select_hint = "only select-type groups support manual selection; run `zc " ++ family ++ " list` to see group types",
        .proxy_not_found_hint = "run `zc " ++ family ++ " select -g <group> --json` to inspect choices",
        .not_interactive_hint = "stdin is not a TTY; use `zc " ++ family ++ " select -g <group> -p <proxy>`",
    };
}

const proxy_family_text = proxyFamilyText("proxy", "PROXY");
const profile_family_text = proxyFamilyText("profile", "PROFILE");

const proxy_config_load_hint = "check config path and retry with `-c <config>`";

const ProxyFamilyArgs = struct {
    group: ?[]const u8 = null,
    proxy: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    /// test 系命令：`--port <n>` 覆盖本次探测的端口（与 `zc start --port`
    /// 对称；也让沙箱环境能用本地 listener 验证探测/退出码行为）。
    port: ?u16 = null,
};

const ProxyFamilyParseOptions = struct {
    allow_select_flags: bool = false,
    allow_port: bool = false,
};

/// list 只接受 `-c`；select 额外接受 `-g`/`-p`；test 额外接受 `--port`。
/// override flags 由 override.parseCliOptions 全局解析（含缺值校验），
/// 这里跳过 flag 及其值。
/// 决策 D11：其余未知 flag / 缺值 flag / 多余位置参数 -> 用法错误。
fn parseProxyFamilyArgs(args: []const []const u8, start_index: usize, opts: ProxyFamilyParseOptions) !ProxyFamilyArgs {
    var parsed = ProxyFamilyArgs{};
    var i = start_index;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isGlobalCliFlag(arg)) continue;
        if (std.mem.eql(u8, arg, "-c")) {
            // 紧跟全局 flag 视为缺值（`-g --json` 不能把 flag 吃成组名）。
            if (i + 1 >= args.len or isGlobalCliFlag(args[i + 1])) return error.MissingConfigPathValue;
            parsed.config_path = args[i + 1];
            i += 1;
        } else if (opts.allow_select_flags and std.mem.eql(u8, arg, "-g")) {
            if (i + 1 >= args.len or isGlobalCliFlag(args[i + 1])) return error.MissingGroupValue;
            parsed.group = args[i + 1];
            i += 1;
        } else if (opts.allow_select_flags and std.mem.eql(u8, arg, "-p")) {
            if (i + 1 >= args.len or isGlobalCliFlag(args[i + 1])) return error.MissingProxyValue;
            parsed.proxy = args[i + 1];
            i += 1;
        } else if (opts.allow_port and std.mem.eql(u8, arg, "--port")) {
            if (i + 1 >= args.len or isGlobalCliFlag(args[i + 1])) return error.MissingPortValue;
            parsed.port = try parseStartPortValue(args[i + 1]);
            i += 1;
        } else if (opts.allow_port and std.mem.startsWith(u8, arg, "--port=")) {
            parsed.port = try parseStartPortValue(arg["--port=".len..]);
        } else if (std.mem.eql(u8, arg, "--override-script") or
            std.mem.eql(u8, arg, "--override-timeout-ms") or
            std.mem.eql(u8, arg, "--override-arg"))
        {
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--override-script=") or
            std.mem.startsWith(u8, arg, "--override-timeout-ms=") or
            std.mem.startsWith(u8, arg, "--override-arg="))
        {
            // `=` 形式自带值，整体跳过。
        } else {
            return error.UnexpectedArgument;
        }
    }
    return parsed;
}

fn proxyArgsErrorMessage(err: anyerror, unexpected_msg: []const u8) []const u8 {
    return switch (err) {
        error.MissingConfigPathValue => "missing value for `-c`",
        error.MissingGroupValue => "missing value for `-g`",
        error.MissingProxyValue => "missing value for `-p`",
        error.MissingPortValue => "missing value for `--port`",
        error.InvalidStartPort => "invalid `--port` value (use an integer between 1 and 65535)",
        else => unexpected_msg,
    };
}

/// select 路径错误统一出口：envelope/error block + 非零退出码
/// （修复 JSON 模式 select 错误 exit 0 的缺口）。
fn exitProxySelectError(json_output: bool, err: anyerror, text: *const ProxyFamilyText) noreturn {
    switch (err) {
        error.GroupNotFound => printCliError(json_output, "PROXY_GROUP_NOT_FOUND", "proxy group not found", text.group_not_found_hint),
        error.GroupNotSelect => printCliError(json_output, "PROXY_GROUP_NOT_SELECTABLE", "group is not a select-type proxy group", text.group_not_select_hint),
        error.ProxyNotFound => printCliError(json_output, "PROXY_NOT_FOUND", "proxy not found in group", text.proxy_not_found_hint),
        error.NoSelectGroup => printCliError(json_output, "PROXY_SELECT_GROUP_MISSING", "no select-type proxy group found", "check profile proxy-groups config"),
        error.NotInteractive => {
            printCliError(json_output, "PROXY_SELECT_NOT_INTERACTIVE", "interactive selection requires a TTY on stdin", text.not_interactive_hint);
            std.process.exit(cli_output.exit_usage);
        },
        else => printCliError(json_output, "PROXY_SELECT_FAILED", "failed to select proxy", "retry with valid group/proxy arguments"),
    }
    std.process.exit(cli_output.exit_failure);
}

fn loadProxyFamilyConfig(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    mixed_port_override: ?u16,
    json_output: bool,
    override_opts: *const override.CliOptions,
    command_name: []const u8,
    load_msg: []const u8,
) config.Config {
    return loadAndValidateConfig(
        allocator,
        config_path,
        mixed_port_override,
        !json_output,
        override_opts,
        command_name,
        null,
    ) catch |err| {
        if (!printOverrideRuntimeError(json_output, err)) {
            printCliError(json_output, "PROXY_CONFIG_LOAD_FAILED", load_msg, proxy_config_load_hint);
        }
        std.process.exit(cli_output.exit_failure);
    };
}

/// proxy/profile 命令树 dispatch（结构与 runConfigCommand 对齐）：
/// 错误统一走 printCliError 并以非零码退出；用法错误 exit_usage。
fn runProxyFamilyCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    json_output: bool,
    override_opts: *const override.CliOptions,
    text: *const ProxyFamilyText,
) !void {
    // 裸 `zc proxy` / `zc profile`（或只带全局 flag）-> 组帮助（stdout, exit 0），
    // 与 config 组对齐。
    if (args.len < 3 or isHelpArg(args[2]) or
        std.mem.eql(u8, args[2], "--json") or std.mem.eql(u8, args[2], "--no-color"))
    {
        _ = try printTopicHelpStdout(&.{text.family});
        return;
    }
    const subcmd = args[2];

    if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        if (containsHelpArg(args, 3)) {
            _ = try printTopicHelpStdout(&.{ text.family, "list" });
            return;
        }
        const parsed = parseProxyFamilyArgs(args, 3, .{}) catch |err| {
            printCliError(json_output, text.list_arg_code, proxyArgsErrorMessage(err, text.list_arg_msg), text.list_usage_hint);
            std.process.exit(cli_output.exit_usage);
        };

        var cfg = loadProxyFamilyConfig(allocator, parsed.config_path, null, json_output, override_opts, text.list_cmd_name, text.load_list_msg);
        defer cfg.deinit();

        const config_key = config.resolveRuntimeConfigKey(
            allocator,
            parsed.config_path,
        ) catch {
            printCliError(
                json_output,
                "PROXY_CONFIG_LOAD_FAILED",
                text.load_list_msg,
                proxy_config_load_hint,
            );
            std.process.exit(cli_output.exit_failure);
        };
        defer if (config_key) |key| allocator.free(key);
        const selections = runtime_selection.collectSelectedProxies(
            allocator,
            &cfg,
            config_key,
        ) catch {
            printCliError(
                json_output,
                "PROXY_CONFIG_LOAD_FAILED",
                "failed to read persisted proxy selections",
                "repair `~/.config/zc/meta.json` and retry",
            );
            std.process.exit(cli_output.exit_failure);
        };
        defer runtime_selection.deinitSelectedProxies(
            allocator,
            selections,
        );

        var streams = StdStreams{};
        var out = streams.output(json_output);
        if (json_output) {
            proxy_cli.listProxiesJson(allocator, &cfg, selections, &out) catch std.process.exit(cli_output.exit_failure);
        } else {
            proxy_cli.listProxies(&cfg, selections, &out) catch std.process.exit(cli_output.exit_failure);
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "select")) {
        if (containsHelpArg(args, 3)) {
            _ = try printTopicHelpStdout(&.{ text.family, "select" });
            return;
        }
        const parsed = parseProxyFamilyArgs(args, 3, .{ .allow_select_flags = true }) catch |err| {
            printCliError(json_output, text.select_arg_code, proxyArgsErrorMessage(err, text.select_arg_msg), text.select_usage_hint);
            std.process.exit(cli_output.exit_usage);
        };

        var loaded = loadExactRuntimeConfig(
            allocator,
            parsed.config_path,
            null,
            override_opts,
            text.select_cmd_name,
            null,
            false,
        ) catch |err| {
            if (!printOverrideRuntimeError(json_output, err)) {
                printCliError(
                    json_output,
                    "PROXY_CONFIG_LOAD_FAILED",
                    text.load_select_msg,
                    proxy_config_load_hint,
                );
            }
            std.process.exit(cli_output.exit_failure);
        };
        defer loaded.deinit();
        const cfg = &loaded.value;

        var streams = StdStreams{};
        var out = streams.output(json_output);

        if (parsed.proxy) |proxy_name| {
            // 非交互路径：两种模式同语义 —— 只在 select 组里解析、应用、
            // 通知 daemon（修复 JSON 模式 state:"selected" 假成功的无操作）。
            const group = proxy_cli.resolveSelectGroup(cfg, parsed.group) catch |err|
                exitProxySelectError(json_output, err, text);
            proxy_cli.validateSelection(group, proxy_name) catch |err|
                exitProxySelectError(json_output, err, text);
            const managed_identity = loaded.identity orelse {
                printCliError(
                    json_output,
                    "PROXY_SELECTION_MANAGED_CONFIG_REQUIRED",
                    "selection requires a managed config revision",
                    "import the config with `zc config load <path>` first",
                );
                std.process.exit(cli_output.exit_failure);
            };
            const receipt = selection_state.persistDefault(
                allocator,
                managed_identity,
                group.name,
                proxy_name,
            ) catch |err| exitProxySelectError(json_output, err, text);
            const applied = proxy_cli.applySelection(
                allocator,
                group,
                proxy_name,
                receipt.identity,
                receipt.generation,
                cfg.secret,
                &out,
            ) catch |err| exitProxySelectError(json_output, err, text);
            if (json_output) {
                // data.applied 反映是否真的通知到了运行中的 daemon（工作项 7）。
                out.success(.{ .action = "proxy_select", .group = group.name, .proxy = proxy_name, .state = "selected", .applied = applied }) catch {};
            }
            return;
        }

        if (json_output) {
            // JSON 无 `-p`：只读列出候选，不改任何选择。
            const group = proxy_cli.resolveSelectGroup(cfg, parsed.group) catch |err|
                exitProxySelectError(json_output, err, text);
            out.success(.{ .action = "proxy_select", .group = group.name, .choices = group.proxies.items }) catch {};
            return;
        }

        // 文本交互（仅 TTY）：非 TTY 缺 `-p` 一律报错退出，绝不静默选第一个节点。
        const managed_identity = loaded.identity orelse {
            printCliError(
                json_output,
                "PROXY_SELECTION_MANAGED_CONFIG_REQUIRED",
                "selection requires a managed config revision",
                "import the config with `zc config load <path>` first",
            );
            std.process.exit(cli_output.exit_failure);
        };
        const selections = runtime_selection.collectSelectedProxies(
            allocator,
            cfg,
            managed_identity.key,
        ) catch {
            printCliError(
                json_output,
                "PROXY_CONFIG_LOAD_FAILED",
                "failed to read persisted proxy selections",
                "repair `~/.config/zc/meta.json` and retry",
            );
            std.process.exit(cli_output.exit_failure);
        };
        defer runtime_selection.deinitSelectedProxies(
            allocator,
            selections,
        );

        const picked = proxy_cli.selectProxyInteractive(
            allocator,
            cfg,
            parsed.group,
            selections,
            &out,
        ) catch |err| exitProxySelectError(json_output, err, text);
        if (picked) |selection| {
            const receipt = selection_state.persistDefault(
                allocator,
                managed_identity,
                selection.group.name,
                selection.proxy,
            ) catch |err| exitProxySelectError(json_output, err, text);
            _ = proxy_cli.applySelection(
                allocator,
                selection.group,
                selection.proxy,
                receipt.identity,
                receipt.generation,
                cfg.secret,
                &out,
            ) catch |err| exitProxySelectError(json_output, err, text);
        }
        // picker 取消（q/Esc）：无输出，exit 0。
        return;
    }

    if (std.mem.eql(u8, subcmd, "test")) {
        if (containsHelpArg(args, 3)) {
            _ = try printTopicHelpStdout(&.{ text.family, "test" });
            return;
        }
        const parsed = parseProxyFamilyArgs(args, 3, .{ .allow_port = true }) catch |err| {
            printCliError(json_output, text.test_arg_code, proxyArgsErrorMessage(err, text.test_arg_msg), text.test_usage_hint);
            std.process.exit(cli_output.exit_usage);
        };

        var cfg = loadProxyFamilyConfig(allocator, parsed.config_path, parsed.port, json_output, override_opts, text.test_cmd_name, text.load_test_msg);
        defer cfg.deinit();
        const config_key = config.resolveRuntimeConfigKey(allocator, parsed.config_path) catch null;
        defer if (config_key) |key| allocator.free(key);

        // 决策 D3：两种模式跑相同探测；检查失败 -> CHECKS_FAILED + exit 1。
        var streams = StdStreams{};
        var out = streams.output(json_output);
        runConnectivityTestOrExit(allocator, &cfg, config_key, &out, json_output);
        return;
    }

    // 未知子命令：两种模式同语义（envelope/error block）+ exit_usage。
    printCliError(json_output, text.sub_unknown_code, text.sub_unknown_msg, text.sub_unknown_hint);
    std.process.exit(cli_output.exit_usage);
}

// ---------------------------------------------------------------------------
// test / doctor / diag（Batch 5）
// ---------------------------------------------------------------------------

/// `zc test`：与 proxy/profile test 完全同一条探测路径（决策 D3）。
/// 配置加载失败在两种模式都输出 envelope/错误块（修复 JSON 模式静默 exit 1）。
fn runStandaloneTestCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    json_output: bool,
    override_opts: *const override.CliOptions,
) !void {
    const parsed = parseProxyFamilyArgs(args, 2, .{ .allow_port = true }) catch |err| {
        printCliError(
            json_output,
            "TEST_ARGUMENT_INVALID",
            proxyArgsErrorMessage(err, "unknown or unexpected argument for `test`"),
            "use `zc test [-c <config>] [--port <port>] [--json]`",
        );
        std.process.exit(cli_output.exit_usage);
    };

    var cfg = loadAndValidateConfig(
        allocator,
        parsed.config_path,
        parsed.port,
        !json_output,
        override_opts,
        "test",
        null,
    ) catch |err| {
        if (!printOverrideRuntimeError(json_output, err)) {
            printCliError(json_output, "PROXY_CONFIG_LOAD_FAILED", "failed to load/validate config for test", proxy_config_load_hint);
        }
        std.process.exit(cli_output.exit_failure);
    };
    defer cfg.deinit();
    const config_key = config.resolveRuntimeConfigKey(allocator, parsed.config_path) catch null;
    defer if (config_key) |key| allocator.free(key);

    var streams = StdStreams{};
    var out = streams.output(json_output);
    runConnectivityTestOrExit(allocator, &cfg, config_key, &out, json_output);
}

/// test 系命令共用出口：检查失败 -> exit 1（envelope/错误块已由
/// runConnectivityTest 输出）；内部错误 -> 单独 envelope + exit 1。
fn runConnectivityTestOrExit(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    config_key: ?[]const u8,
    out: *cli_output.Output,
    json_output: bool,
) void {
    const passed = test_cli.runConnectivityTest(allocator, cfg, config_key, out) catch {
        printCliError(json_output, "PROXY_TEST_FAILED", "failed to run connectivity test", "retry; `zc status` and `zc log --no-follow` show daemon state");
        std.process.exit(cli_output.exit_failure);
    };
    if (!passed) std.process.exit(cli_output.exit_failure);
}

/// doctor / diag doctor 共用参数用法错误（决策 D11）：与 DIAG_DOCTOR_FAILED
/// 一致，两条路径共用同一错误码；调用方以 exit_usage 退出。
fn printDoctorArgError(json_output: bool, err: anyerror, command_label: []const u8) void {
    var msg_buf: [96]u8 = undefined;
    const fallback = std.fmt.bufPrint(&msg_buf, "unknown or unexpected argument for `{s}`", .{command_label}) catch "unknown or unexpected argument";
    const hint = if (std.mem.eql(u8, command_label, "diag doctor"))
        "use `zc diag doctor [-c <config>] [--json]`"
    else
        "use `zc doctor [-c <config>] [--json]`";
    printCliError(json_output, "DIAG_DOCTOR_ARGUMENT_INVALID", proxyArgsErrorMessage(err, fallback), hint);
}

/// doctor / diag doctor 共用：配置加载失败在两种模式都输出 envelope/错误块
/// （修复 text 模式被 json-only guard 吞错后裸抛 Zig trace 的问题），检查
/// 失败 -> CHECKS_FAILED + exit 1（决策 D3）。
fn runDoctorCommand(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    json_output: bool,
    override_opts: *const override.CliOptions,
    command_name: []const u8,
) !void {
    var cfg_check = loadRuntimeConfig(
        allocator,
        config_path,
        null,
        override_opts,
        command_name,
        false,
        null,
    ) catch |err| {
        if (!printOverrideRuntimeError(json_output, err)) {
            printCliError(json_output, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config path/permissions and retry `zc doctor`");
        }
        std.process.exit(cli_output.exit_failure);
    };
    defer cfg_check.deinit();

    var streams = StdStreams{};
    var out = streams.output(json_output);
    const healthy = doctor_cli.runDoctorWithConfig(allocator, &cfg_check, config_path, &out) catch {
        printCliError(json_output, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config path/permissions and retry `zc doctor`");
        std.process.exit(cli_output.exit_failure);
    };
    if (!healthy) std.process.exit(cli_output.exit_failure);
}

const DiagResolution = union(enum) {
    /// 裸 `zc diag`（或只带全局 flag）：组帮助，exit 0。
    bare,
    help,
    /// 只有 flag、没有子命令词（如 `zc diag -c x`）：DIAG_SUBCOMMAND_MISSING。
    missing,
    /// `zc diag doctor ...`：值为 "doctor" 在 args 中的索引。
    doctor: usize,
    /// 位置词不是已知子命令：DIAG_SUBCOMMAND_UNKNOWN（冻结错误码）。
    unknown: usize,
};

fn resolveDiagSubcommand(args: []const []const u8) DiagResolution {
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isGlobalCliFlag(arg)) continue;
        if (isHelpArg(arg)) return .help;
        if (arg.len > 0 and arg[0] == '-') return .missing;
        if (std.mem.eql(u8, arg, "doctor")) return .{ .doctor = i };
        return .{ .unknown = i };
    }
    return .bare;
}

fn validateOverrideAndPrepareRuleProviders(allocator: std.mem.Allocator, script_path: []const u8) !void {
    var cfg = try config.loadDefault(allocator);
    defer cfg.deinit();

    var opts = override.CliOptions{};
    opts.script_path = try allocator.dupe(u8, script_path);
    defer opts.deinit(allocator);

    try override.apply(allocator, &cfg, &opts, "config.override.set", null);
    try config.prepareRuleProvidersForRuntime(allocator, &cfg, null);
}

fn applyConfigOverrideToRunningDaemon(
    allocator: std.mem.Allocator,
    key: []const u8,
    revision: config_identity.Revision,
) !void {
    if (!try daemon.isRunning(allocator)) return;
    const config_path = try managedConfigPathForKey(allocator, key);
    defer allocator.free(config_path);
    _ = try reloadOrRestartPrepared(
        allocator,
        config_path,
        .auto,
        false,
        .{ .key = key, .revision = revision },
    );
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn parseConfigOverrideAction(args: []const []const u8, start_index: usize) !ConfigOverrideAction {
    var clear = false;
    var script_path: ?[]const u8 = null;

    var i: usize = start_index;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isGlobalCliFlag(arg)) continue;
        if (std.mem.eql(u8, arg, "--clear")) {
            clear = true;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return error.InvalidConfigOverrideArgs;
        if (script_path == null) {
            script_path = arg;
        } else {
            return error.InvalidConfigOverrideArgs;
        }
    }

    if (clear and script_path != null) return error.InvalidConfigOverrideArgs;
    if (clear) return .clear;
    if (script_path) |script| return .{ .set = script };
    return .show;
}

fn parseUpdateApplyMode(s: []const u8) !UpdateApplyMode {
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "hot")) return .hot;
    if (std.mem.eql(u8, s, "restart")) return .restart;
    return error.InvalidApplyMode;
}

const RuntimeLoadedConfig = struct {
    allocator: std.mem.Allocator,
    value: config.Config,
    identity: ?config_identity.ManagedIdentity,

    fn deinit(self: *RuntimeLoadedConfig) void {
        self.value.deinit();
        if (self.identity) |identity| self.allocator.free(identity.key);
        self.* = undefined;
    }
};

fn finishManagedRuntimeLoad(
    allocator: std.mem.Allocator,
    loaded: *managed_config_loader.LoadedConfig,
) RuntimeLoadedConfig {
    loaded.validation.deinit();
    return .{
        .allocator = allocator,
        .value = loaded.config,
        .identity = loaded.identity,
    };
}

fn tryLoadExactManagedRuntime(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    include_frozen_override: bool,
) !?RuntimeLoadedConfig {
    if (config_path) |path| {
        const key = (try config.inferConfigKeyFromPath(allocator, path)) orelse
            return null;
        defer allocator.free(key);
        const root_path = (try config.getDefaultConfigDir(allocator)) orelse
            return null;
        defer allocator.free(root_path);
        const root = compat.fs.openDirAbsolute(root_path, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer root.close(compat.io());
        const loader = managed_config_loader.Loader.init(allocator, root);
        var loaded = (if (include_frozen_override)
            loader.loadHead(key)
        else
            loader.loadHeadWithoutOverride(key)) catch |err| switch (err) {
            error.Schema2CatalogRequired => return null,
            error.ManagedProfileNotFound => return err,
            else => return err,
        };
        return finishManagedRuntimeLoad(allocator, &loaded);
    }

    var root = try openDefaultCatalogRoot(allocator);
    defer root.deinit();
    if (root.bootstrap_health.state_sync_error != null) {
        return error.CatalogDurabilityUncertain;
    }
    const loader = managed_config_loader.Loader.init(allocator, root.dir);
    var loaded = if (include_frozen_override)
        try loader.loadActive()
    else
        try loader.loadActiveWithoutOverride();
    return finishManagedRuntimeLoad(allocator, &loaded);
}

fn loadPreparedRuntimeConfig(
    allocator: std.mem.Allocator,
    path: []const u8,
    mixed_port_override: ?u16,
    provider_policy: ?config.RuleProviderSyncPolicy,
) !RuntimeLoadedConfig {
    var content = try daemon.readPreparedConfig(allocator, path);
    defer content.deinit();
    var cfg = try config.parseDocument(allocator, content.yaml);
    errdefer cfg.deinit();
    try requireRuntimeCapabilities(allocator, &cfg);
    applyRuntimePortSelection(&cfg, mixed_port_override);
    try config.prepareRuleProvidersForRuntimeWithPolicy(
        allocator,
        &cfg,
        path,
        provider_policy orelse .missing_only,
    );
    try validateRuntimeEndpointSyntax(&cfg);
    var validation_result = try validator.validate(allocator, &cfg);
    defer validation_result.deinit();
    if (!validation_result.isValid()) return error.InvalidConfig;
    const identity: ?config_identity.ManagedIdentity = if (content.identity) |value| .{
        .key = try allocator.dupe(u8, value.key),
        .revision = value.revision,
    } else null;
    return .{
        .allocator = allocator,
        .value = cfg,
        .identity = identity,
    };
}

fn loadExactRuntimeConfig(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    mixed_port_override: ?u16,
    override_opts: *const override.CliOptions,
    command_name: []const u8,
    provider_policy: ?config.RuleProviderSyncPolicy,
    allow_prepared_override: bool,
) !RuntimeLoadedConfig {
    if (config_path) |path| {
        if (try daemon.isPreparedConfigNamespacePath(allocator, path)) {
            const has_override = override_opts.script_path != null or
                override_opts.args.items.len != 0 or
                override_opts.timeout_ms != override.timeout_ms_default;
            if (has_override and !allow_prepared_override) {
                return error.InvalidPreparedConfig;
            }
            var prepared = try loadPreparedRuntimeConfig(
                allocator,
                path,
                mixed_port_override,
                provider_policy,
            );
            errdefer prepared.deinit();
            if (has_override) {
                var effective_override = override_opts.*;
                try override.apply(
                    allocator,
                    &prepared.value,
                    &effective_override,
                    command_name,
                    path,
                );
                if (prepared.identity) |identity| allocator.free(identity.key);
                prepared.identity = null;
                try requireRuntimeCapabilities(allocator, &prepared.value);
                applyRuntimePortSelection(&prepared.value, mixed_port_override);
                try config.prepareRuleProvidersForRuntimeWithPolicy(
                    allocator,
                    &prepared.value,
                    path,
                    provider_policy orelse
                        ruleProviderSyncPolicyForCommand(command_name),
                );
                try validateRuntimeEndpointSyntax(&prepared.value);
                var validation_result = try validator.validate(
                    allocator,
                    &prepared.value,
                );
                defer validation_result.deinit();
                if (!validation_result.isValid()) return error.InvalidConfig;
            }
            return prepared;
        }
    }
    var loaded = (try tryLoadExactManagedRuntime(
        allocator,
        config_path,
        true,
    )) orelse
        return .{
            .allocator = allocator,
            .value = try loadAndValidateConfig(
                allocator,
                config_path,
                mixed_port_override,
                true,
                override_opts,
                command_name,
                provider_policy,
            ),
            .identity = null,
        };
    errdefer loaded.deinit();

    // Managed revisions already contain the frozen override result. Legacy
    // metadata is only a derived mirror and must never be reapplied to an
    // exact managed identity. An explicit one-shot CLI override intentionally
    // makes this runtime unmanaged.
    if (override_opts.script_path != null) {
        var effective_override = override_opts.*;
        try override.apply(
            allocator,
            &loaded.value,
            &effective_override,
            command_name,
            config_path,
        );
        if (loaded.identity) |identity| allocator.free(identity.key);
        loaded.identity = null;
    }
    try requireRuntimeCapabilities(allocator, &loaded.value);
    applyRuntimePortSelection(&loaded.value, mixed_port_override);
    if (loaded.identity == null) {
        try config.prepareRuleProvidersForRuntimeWithPolicy(
            allocator,
            &loaded.value,
            config_path,
            provider_policy orelse ruleProviderSyncPolicyForCommand(command_name),
        );
    } else {
        for (loaded.value.rules.items) |rule| {
            if (rule.rule_type == .rule_set) {
                return error.ManagedRemoteRuleProviderUnsupported;
            }
        }
    }
    try validateRuntimeEndpointSyntax(&loaded.value);
    var validation_result = try validator.validate(allocator, &loaded.value);
    defer validation_result.deinit();
    validator.printResult(&validation_result);
    if (!validation_result.isValid()) return error.InvalidConfig;
    return loaded;
}

fn startupFailureForError(err: anyerror) daemon.StartupFailure {
    return switch (err) {
        error.PortAlreadyInUse => .port_in_use,
        error.ControllerPortAlreadyInUse => .controller_port_in_use,
        error.PortConflict => .port_conflict,
        error.InvalidBindAddress => .invalid_bind_address,
        error.InvalidExternalController => .invalid_controller,
        error.ListenerStartupFailed => .listener_failed,
        error.ListenerStartupTimeout => .readiness,
        error.InvalidInheritedDaemonLock => .lock_handoff,
        error.UnsupportedCapability => .capability,
        error.OverrideScriptNotFound => .override_not_found,
        error.OverrideScriptExecFailed => .override_exec,
        error.OverrideScriptTimeout => .override_timeout,
        error.OverrideOutputInvalid => .override_output,
        error.OverrideMergeFailed => .override_merge,
        else => .generic,
    };
}

fn abortStartedRuntime(
    allocator: std.mem.Allocator,
    json_output: bool,
    code: []const u8,
    message: []const u8,
    hint: []const u8,
    err: anyerror,
) noreturn {
    std.debug.print("Runtime startup error: {}\n", .{err});
    if (g_startup_token) |token| {
        const failure: daemon.StartupFailure = if (std.mem.eql(
            u8,
            code,
            "START_RUNTIME_PUBLISH_FAILED",
        ))
            .runtime_publish
        else if (std.mem.eql(u8, code, "START_LOCK_HANDOFF_INVALID"))
            .lock_handoff
        else
            startupFailureForError(err);
        daemon.publishStartupSignal(
            allocator,
            token,
            .{ .failed = failure },
        ) catch {};
    }
    daemon.cleanupCurrentProcessRuntime(allocator);
    printCliError(json_output, code, message, hint);
    std.process.exit(cli_output.exit_failure);
}

fn runProxy(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    mixed_port_override: ?u16,
    override_opts: *const override.CliOptions,
    command_name: []const u8,
    json_output: bool,
    invocation: runtime_descriptor.InvocationInput,
) !void {
    std.debug.print("zc v{s}\n", .{build_options.version});

    // 保存配置路径用于重载
    if (config_path) |path| {
        g_config_path = try allocator.dupe(u8, path);
    }

    var loaded = try loadExactRuntimeConfig(
        allocator,
        config_path,
        mixed_port_override,
        override_opts,
        command_name,
        if (std.mem.eql(u8, command_name, "daemon-run"))
            .missing_only
        else
            null,
        false,
    );
    defer loaded.deinit();
    var invocation_source_path: ?[]u8 = null;
    defer if (invocation_source_path) |path| allocator.free(path);
    var exact_invocation = invocation;
    if (invocation.prepared) {
        const path = config_path orelse return error.InvalidPreparedConfig;
        var prepared_content = try daemon.readPreparedConfig(allocator, path);
        defer prepared_content.deinit();
        if (prepared_content.source_path) |source| {
            invocation_source_path = try allocator.dupe(u8, source);
        }
        exact_invocation.source_path = invocation_source_path;
        exact_invocation.port_override = prepared_content.port_override;
    } else {
        exact_invocation.source_path = config_path;
        exact_invocation.port_override = mixed_port_override;
    }
    const cfg = &loaded.value;
    try preflightPortCheck(cfg, true);

    var legacy_config_key: ?[]const u8 = null;
    defer if (legacy_config_key) |key| allocator.free(key);
    const config_key: ?[]const u8 = if (loaded.identity) |identity|
        identity.key
    else if (config_path == null) blk: {
        legacy_config_key = config.resolveRuntimeConfigKey(
            allocator,
            null,
        ) catch null;
        break :blk legacy_config_key;
    } else null;
    var manager = try outbound.OutboundManager.initWithKey(allocator, cfg, config_key);
    defer manager.deinit();
    manager.setTrafficReady(false);

    // Authority desired state is restored before any listener opens. Legacy
    // meta.json remains a fallback until every existing profile is migrated.
    var desired_snapshot: ?selection_state.DesiredSnapshot = if (loaded.identity) |identity|
        try selection_state.loadDesiredDefault(allocator, identity.key)
    else
        null;
    defer if (desired_snapshot) |*snapshot| snapshot.deinit();
    if (desired_snapshot) |snapshot| {
        const exact = loaded.identity orelse return error.RuntimeIdentityChanged;
        if (!std.mem.eql(u8, exact.key, snapshot.identity.key) or
            !exact.revision.eql(snapshot.identity.revision))
        {
            return error.RuntimeIdentityChanged;
        }
        if (!try manager.applyPersistedSelections(
            snapshot.selections,
            snapshot.generation,
        )) {
            return error.InvalidDesiredSelection;
        }
    } else {
        try manager.loadPersistedSelections();
    }
    const applied_identity: ?config_identity.ManagedIdentity = if (desired_snapshot) |snapshot|
        snapshot.identity
    else
        loaded.identity;
    const applied_generation: u64 = if (desired_snapshot) |snapshot|
        snapshot.generation
    else
        0;

    // Initialize rule engine
    var engine = try rule_engine.Engine.init(allocator, &cfg.rules);
    defer engine.deinit();

    var listener_startup = ListenerStartup{};
    var expected_listeners: u8 = 0;
    if (cfg.mixed_port > 0) {
        expected_listeners += 1;
    } else {
        if (cfg.port > 0) expected_listeners += 1;
        if (cfg.socks_port > 0) expected_listeners += 1;
    }

    const proxy_thread = try std.Thread.spawn(
        .{},
        proxyThreadFn,
        .{ allocator, cfg, &engine, &manager, &listener_startup },
    );
    proxy_thread.detach();

    if (cfg.external_controller) |ec| {
        expected_listeners += 1;
        const port = parseExternalControllerPort(ec) catch |err|
            abortStartedRuntime(
                allocator,
                json_output,
                "START_FAILED",
                "controller endpoint failed during startup",
                "check the configured external-controller endpoint",
                err,
            );
        const api_thread = std.Thread.spawn(
            .{},
            apiThreadFn,
            .{
                allocator,
                cfg,
                &engine,
                &manager,
                port,
                loaded.identity != null,
                &listener_startup,
            },
        ) catch |err| abortStartedRuntime(
            allocator,
            json_output,
            "START_FAILED",
            "controller thread failed during startup",
            "check process thread limits and retry",
            err,
        );
        api_thread.detach();
    }
    const readiness_timeout_ms = if (std.mem.eql(u8, command_name, "daemon-run"))
        daemon_listener_start_timeout_ms
    else
        listener_start_timeout_ms;
    waitForListenerReadiness(
        &listener_startup,
        expected_listeners,
        readiness_timeout_ms,
    ) catch |err| abortStartedRuntime(
        allocator,
        json_output,
        if (err == error.ListenerStartupTimeout)
            "START_READINESS_TIMEOUT"
        else
            "START_FAILED",
        if (err == error.ListenerStartupTimeout)
            "daemon listeners did not become ready before the deadline"
        else
            "daemon listener failed during startup",
        "check port ownership and the daemon log",
        err,
    );
    const runtime_nonce = publishRuntimeDescriptor(
        allocator,
        applied_identity,
        applied_generation,
        cfg.external_controller,
        exact_invocation,
    ) catch |err| abortStartedRuntime(
        allocator,
        json_output,
        "START_RUNTIME_PUBLISH_FAILED",
        "failed to publish the runtime descriptor",
        "remove unsafe runtime artifacts and retry",
        err,
    );
    _ = reconcileRuntimeDesired(
        allocator,
        &manager,
        applied_identity,
        runtime_nonce,
    ) catch |err| abortStartedRuntime(
        allocator,
        json_output,
        "START_FAILED",
        "desired runtime state changed during startup",
        "retry after config and selection updates settle",
        err,
    );
    listener_startup.control_available.store(true, .release);
    var final_guard: ?FinalDesiredGuard = null;
    if (applied_identity) |identity| {
        var attempt: u8 = 0;
        while (attempt < 16) : (attempt += 1) {
            _ = reconcileRuntimeDesired(
                allocator,
                &manager,
                applied_identity,
                runtime_nonce,
            ) catch |err| abortStartedRuntime(
                allocator,
                json_output,
                "START_FAILED",
                "desired runtime state did not stabilize during startup",
                "retry after config and selection updates settle",
                err,
            );
            manager.waitForPersistedSelectionUpdates();
            final_guard = acquireFinalDesiredGuard(
                allocator,
                identity,
                runtime_nonce,
            ) catch |err| abortStartedRuntime(
                allocator,
                json_output,
                "START_FAILED",
                "failed to lock the final desired runtime state",
                "retry after config and selection updates settle",
                err,
            );
            if (final_guard != null) break;
        }
        if (final_guard == null) {
            abortStartedRuntime(
                allocator,
                json_output,
                "START_FAILED",
                "desired runtime state remained unstable",
                "retry after config and selection updates settle",
                error.RuntimeDesiredStateUnstable,
            );
        }
    }
    if (g_daemon_lock_fd) |lock_fd| {
        daemon.validateInheritedDaemonLockIdentity(
            allocator,
            lock_fd,
        ) catch |err| abortStartedRuntime(
            allocator,
            json_output,
            "START_LOCK_HANDOFF_INVALID",
            "daemon lock identity changed during startup",
            "restore the canonical runtime lock and retry",
            err,
        );
    }
    if (listener_startup.phase.cmpxchgStrong(
        .initializing,
        .committed,
        .acq_rel,
        .acquire,
    ) != null) {
        abortStartedRuntime(
            allocator,
            json_output,
            "START_FAILED",
            "daemon listener failed while startup was committing",
            "check port ownership and the daemon log",
            error.ListenerStartupFailed,
        );
    }
    var selection_barrier = manager.acquireSelectionBarrier();
    listener_startup.committed.store(true, .release);
    promoteRuntimeDescriptorReady(allocator, runtime_nonce) catch |err|
        abortStartedRuntime(
            allocator,
            json_output,
            "START_RUNTIME_PUBLISH_FAILED",
            "failed to publish final daemon readiness",
            "remove unsafe runtime artifacts and retry",
            err,
        );
    manager.setTrafficReady(true);
    selection_barrier.deinit();
    if (final_guard) |*guard| guard.deinit();
    if (g_startup_token) |token| {
        daemon.publishStartupSignal(allocator, token, .ready) catch |err| {
            std.debug.print("Failed to publish startup signal: {}\n", .{err});
        };
    }

    std.debug.print("Configuration loaded:\n", .{});
    std.debug.print("  Port: {}\n", .{cfg.port});
    std.debug.print("  SOCKS Port: {}\n", .{cfg.socks_port});
    std.debug.print("  Mixed Port: {}\n", .{cfg.mixed_port});
    std.debug.print("  Mode: {s}\n", .{cfg.mode});
    std.debug.print("  Proxies: {}\n", .{cfg.proxies.items.len});
    std.debug.print("  Rules: {}\n", .{cfg.rules.items.len});
    std.debug.print("\nProxy server running. Press Ctrl+C to stop.\n", .{});

    const background_daemon = std.mem.eql(u8, command_name, "daemon-run");
    while (true) {
        if (g_daemon_lock_fd) |lock_fd| {
            daemon.validateInheritedDaemonLockIdentity(
                allocator,
                lock_fd,
            ) catch std.process.exit(cli_output.exit_failure);
        }
        if (background_daemon) {
            daemon.rotateDaemonLogIfNeeded(allocator) catch
                std.process.exit(cli_output.exit_failure);
        }
        if (daemon.consumeStopRequest(allocator, runtime_nonce) catch false) {
            std.process.exit(cli_output.exit_ok);
        }
        compat.sleepNs(100 * std.time.ns_per_ms);
    }
}

const FinalDesiredGuard = struct {
    root: std.Io.Dir,
    guard: state_authority.Authority.Guard,

    fn deinit(self: *FinalDesiredGuard) void {
        self.guard.deinit();
        self.root.close(compat.io());
        self.* = undefined;
    }
};

fn acquireFinalDesiredGuard(
    allocator: std.mem.Allocator,
    identity: config_identity.ManagedIdentity,
    instance_nonce: runtime_descriptor.Nonce,
) !?FinalDesiredGuard {
    const root_path = try config.getDefaultConfigDir(allocator) orelse
        return error.NoConfigDir;
    defer allocator.free(root_path);
    var root = try compat.fs.openDirAbsolute(root_path, .{
        .follow_symlinks = false,
    });
    var root_owned = true;
    defer if (root_owned) root.close(compat.io());
    var guard = try state_authority.Authority.init(
        allocator,
        root,
    ).acquireGuard();
    var guard_owned = true;
    defer if (guard_owned) guard.deinit();
    var inspection = try guard.inspect();
    defer inspection.deinit();
    const profiles = switch (inspection) {
        .catalog_v2 => |*observed| observed.catalog.state.profiles,
        .missing, .legacy_v1 => return error.RuntimeIdentityChanged,
    };
    var profile_generation: ?u64 = null;
    for (profiles) |profile| {
        if (!std.mem.eql(u8, profile.key, identity.key)) continue;
        if (!profile.head.eql(identity.revision)) {
            return error.RuntimeIdentityChanged;
        }
        profile_generation = profile.desired.generation;
        break;
    }
    const generation = profile_generation orelse
        return error.RuntimeIdentityChanged;

    var default_store = (try runtime_descriptor.openDefault(
        allocator,
        false,
    )) orelse return error.RuntimeDescriptorMissing;
    defer default_store.deinit();
    var descriptor = (try default_store.store().observe()) orelse
        return error.RuntimeDescriptorMissing;
    defer descriptor.deinit();
    const descriptor_identity = descriptor.identity orelse
        return error.RuntimeIdentityChanged;
    if (!descriptor.nonce.eql(instance_nonce) or descriptor.ready or
        generation != descriptor.generation or
        !std.mem.eql(u8, descriptor_identity.key, identity.key) or
        !descriptor_identity.revision.eql(identity.revision))
    {
        return null;
    }
    guard_owned = false;
    root_owned = false;
    return .{ .root = root, .guard = guard };
}

fn reconcileRuntimeDesired(
    allocator: std.mem.Allocator,
    manager: *outbound.OutboundManager,
    applied_identity: ?config_identity.ManagedIdentity,
    instance_nonce: runtime_descriptor.Nonce,
) !u64 {
    const identity = applied_identity orelse return 0;
    var attempt: u8 = 0;
    while (attempt < 16) : (attempt += 1) {
        var default_store = (try runtime_descriptor.openDefault(
            allocator,
            false,
        )) orelse return error.RuntimeDescriptorMissing;
        defer default_store.deinit();
        const store = default_store.store();
        var descriptor = (try store.observe()) orelse
            return error.RuntimeDescriptorMissing;
        defer descriptor.deinit();
        const observed_identity = descriptor.identity orelse
            return error.RuntimeIdentityChanged;
        if (!descriptor.nonce.eql(instance_nonce) or
            !std.mem.eql(u8, observed_identity.key, identity.key) or
            !observed_identity.revision.eql(identity.revision))
        {
            return error.RuntimeIdentityChanged;
        }

        var desired = (try selection_state.loadDesiredDefault(
            allocator,
            identity.key,
        )) orelse return error.RuntimeIdentityChanged;
        defer desired.deinit();
        if (!desired.identity.revision.eql(identity.revision) or
            desired.generation < descriptor.generation)
        {
            return error.RuntimeIdentityChanged;
        }
        if (desired.generation == descriptor.generation) {
            return descriptor.generation;
        }
        var transaction = (try manager.beginPersistedSelections(
            desired.selections,
            desired.generation,
        )) orelse {
            if (desired.generation < manager.persistedSelectionGeneration()) {
                continue;
            }
            return error.InvalidDesiredSelection;
        };
        defer transaction.deinit();
        const outcome = try store.publish(.{ .state = .{
            .nonce = descriptor.nonce,
            .generation = descriptor.generation,
        } }, .{
            .pid = descriptor.pid,
            .nonce = descriptor.nonce,
            .endpoint = descriptor.endpoint,
            .identity = observed_identity,
            .generation = desired.generation,
            .ready = descriptor.ready,
            .invocation = descriptor.invocation,
        });
        switch (outcome) {
            .committed, .durability_uncertain => {
                if (!transaction.commit()) continue;
            },
            .conflict => continue,
        }
    }
    return error.RuntimeDesiredStateUnstable;
}

fn promoteRuntimeDescriptorReady(
    allocator: std.mem.Allocator,
    instance_nonce: runtime_descriptor.Nonce,
) !void {
    var attempt: u8 = 0;
    while (attempt < 16) : (attempt += 1) {
        var default_store = (try runtime_descriptor.openDefault(
            allocator,
            false,
        )) orelse return error.RuntimeDescriptorMissing;
        defer default_store.deinit();
        const store = default_store.store();
        var descriptor = (try store.observe()) orelse
            return error.RuntimeDescriptorMissing;
        defer descriptor.deinit();
        if (!descriptor.nonce.eql(instance_nonce)) {
            return error.RuntimeIdentityChanged;
        }
        if (descriptor.ready) return;
        const outcome = try store.publish(.{ .state = .{
            .nonce = descriptor.nonce,
            .generation = descriptor.generation,
            .ready = false,
        } }, .{
            .pid = descriptor.pid,
            .nonce = descriptor.nonce,
            .endpoint = descriptor.endpoint,
            .identity = descriptor.identity,
            .generation = descriptor.generation,
            .ready = true,
            .invocation = descriptor.invocation,
        });
        switch (outcome) {
            .committed, .durability_uncertain => return,
            .conflict => continue,
        }
    }
    return error.RuntimeDesiredStateUnstable;
}

fn publishRuntimeDescriptor(
    allocator: std.mem.Allocator,
    applied_identity: ?config_identity.ManagedIdentity,
    applied_generation: u64,
    endpoint: ?[]const u8,
    invocation: runtime_descriptor.InvocationInput,
) !runtime_descriptor.Nonce {
    var default_store = (try runtime_descriptor.openDefault(allocator, true)) orelse
        return error.RuntimeDirectoryUnavailable;
    defer default_store.deinit();
    const store = default_store.store();
    var existing = try store.observe();
    defer if (existing) |*value| value.deinit();
    const nonce = g_runtime_nonce orelse runtime_descriptor.Nonce.generate();
    const expected: runtime_descriptor.Expected = if (g_runtime_nonce != null)
        .{ .nonce = nonce }
    else
        .missing;
    if (g_runtime_nonce != null and
        (existing == null or !existing.?.nonce.eql(nonce)))
    {
        return error.RuntimeDescriptorConflict;
    }
    const outcome = try store.publish(expected, .{
        .pid = @intCast(std.c.getpid()),
        .nonce = nonce,
        .endpoint = endpoint,
        .identity = applied_identity,
        .generation = applied_generation,
        .ready = false,
        .invocation = invocation,
    });
    switch (outcome) {
        .committed, .durability_uncertain => return nonce,
        .conflict => return error.RuntimeDescriptorConflict,
    }
}

fn parseStartPortValue(text: []const u8) !u16 {
    const port = std.fmt.parseInt(u16, text, 10) catch return error.InvalidStartPort;
    if (port == 0) return error.InvalidStartPort;
    return port;
}

const StartParseMode = enum {
    /// 用户命令（start/restart）。决策 D11：未知 flag / 多余位置参数 ->
    /// error.UnexpectedArgument，绝不静默忽略后照常执行。
    strict,
    /// 内部 `--daemon-run`：argv 由 zc 自己拼装转发（daemon.startDaemon），
    /// 保持宽松以兼容转发参数的前向演进。
    forwarded,
};

fn parseStartCommandOptions(args: []const []const u8, start_index: usize, mode: StartParseMode) !StartCommandOptions {
    var opts = StartCommandOptions{};
    var i = start_index;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c")) {
            // 紧跟全局 flag 视为缺值（`-c --json` 不能把 flag 吃成路径）。
            if (i + 1 >= args.len or isGlobalCliFlag(args[i + 1])) return error.MissingConfigPath;
            opts.config_path = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            if (i + 1 >= args.len or isGlobalCliFlag(args[i + 1])) return error.MissingPortValue;
            opts.port = try parseStartPortValue(args[i + 1]);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--port=")) {
            opts.port = try parseStartPortValue(arg["--port=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--foreground")) {
            opts.foreground = true;
            continue;
        }
        if (mode == .forwarded) continue;
        if (isGlobalCliFlag(arg)) continue;
        if (std.mem.eql(u8, arg, "--override-script") or
            std.mem.eql(u8, arg, "--override-timeout-ms") or
            std.mem.eql(u8, arg, "--override-arg"))
        {
            // 值的存在性/合法性由 override.parseCliOptions 负责（缺值在
            // dispatch 前就已报错），这里跳过 flag 及其值。
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--override-script=") or
            std.mem.startsWith(u8, arg, "--override-timeout-ms=") or
            std.mem.startsWith(u8, arg, "--override-arg="))
        {
            // `=` 形式自带值，整体跳过。
            continue;
        }
        return error.UnexpectedArgument;
    }

    return opts;
}

fn appendStartForwardArgs(
    allocator: std.mem.Allocator,
    forward_args: *std.ArrayList([]const u8),
    opts: StartCommandOptions,
) !void {
    if (opts.port) |port| {
        try forward_args.append(allocator, try std.fmt.allocPrint(allocator, "--port={d}", .{port}));
    }
}

/// start/restart 共用同一参数解析器，因此 restart 也发射冻结的 START_* 码
/// （error-codes.md 有注记）；message/hint 按命令路径渲染。
/// 这些都是用法错误：调用方以 exit_usage 退出（spec.md 退出码表）。
fn printStartCommandOptionError(json_output: bool, err: anyerror, command: RuntimeCommand) void {
    const restart = command == .restart;
    switch (err) {
        error.MissingConfigPath => printCliError(json_output, "START_CONFIG_PATH_REQUIRED", "missing value for `-c`", if (restart) "use `zc restart -c <config>`" else "use `zc start -c <config>`"),
        error.MissingPortValue => printCliError(json_output, "START_PORT_REQUIRED", "missing value for `--port`", if (restart) "use `zc restart --port <1-65535>`" else "use `zc start --port <1-65535>`"),
        error.InvalidStartPort => printCliError(json_output, "START_PORT_INVALID", "invalid `--port` value", "use an integer between 1 and 65535"),
        error.UnexpectedArgument => printCliError(
            json_output,
            "START_ARGS_INVALID",
            if (restart) "unknown or unexpected argument for `restart`" else "unknown or unexpected argument for `start`",
            if (restart) "use `zc restart [-c <config>] [--port <port>] [--json]`" else "use `zc start [-c <config>] [--port <port>] [--foreground] [--json]`",
        ),
        else => printCliError(json_output, "START_ARGS_INVALID", if (restart) "invalid restart arguments" else "invalid start arguments", "check `zc help`"),
    }
}

fn isPortPreflightError(err: anyerror) bool {
    return switch (err) {
        error.PortAlreadyInUse,
        error.ControllerPortAlreadyInUse,
        error.PortConflict,
        error.InvalidBindAddress,
        error.InvalidExternalController,
        => true,
        else => false,
    };
}

const CliErrorInfo = struct {
    code: []const u8,
    message: []const u8,
    hint: []const u8,
};

fn runtimeCommandPreflightErrorInfo(command: RuntimeCommand, err: anyerror) CliErrorInfo {
    return switch (command) {
        .start => switch (err) {
            error.PortAlreadyInUse => .{
                .code = "START_PORT_IN_USE",
                .message = "requested start port is already in use",
                .hint = "retry with `zc start --port <free-port>`",
            },
            error.ControllerPortAlreadyInUse => .{
                .code = "START_CONTROLLER_PORT_IN_USE",
                .message = "configured controller port is already in use",
                .hint = "free the exact `external-controller` port or update the config",
            },
            error.PortConflict => .{
                .code = "START_PORT_CONFLICT",
                .message = "requested start port conflicts with another runtime listener",
                .hint = "change the port or fix the conflicting runtime config",
            },
            error.InvalidBindAddress => .{
                .code = "START_BIND_ADDRESS_INVALID",
                .message = "invalid bind address for start preflight",
                .hint = "fix `bind-address` in config and retry",
            },
            error.InvalidExternalController => .{
                .code = "START_EXTERNAL_CONTROLLER_INVALID",
                .message = "invalid `external-controller` address in config",
                .hint = "use an explicit loopback endpoint such as `127.0.0.1:9090`",
            },
            else => .{
                .code = "START_PREFLIGHT_FAILED",
                .message = "failed to validate daemon start ports",
                .hint = "check config and retry",
            },
        },
        .restart => switch (err) {
            error.PortAlreadyInUse => .{
                .code = "RESTART_PORT_IN_USE",
                .message = "restart target port is already in use",
                .hint = "free the occupied port, then retry `zc restart`",
            },
            error.ControllerPortAlreadyInUse => .{
                .code = "RESTART_CONTROLLER_PORT_IN_USE",
                .message = "restart controller port is already in use",
                .hint = "free the exact `external-controller` port before " ++
                    "retrying `zc restart`",
            },
            error.PortConflict => .{
                .code = "RESTART_PORT_CONFLICT",
                .message = "restart target port conflicts with another runtime listener",
                .hint = "fix the conflicting runtime config before retrying `zc restart`",
            },
            error.InvalidBindAddress => .{
                .code = "RESTART_BIND_ADDRESS_INVALID",
                .message = "invalid bind address for restart preflight",
                .hint = "fix `bind-address` in config and retry `zc restart`",
            },
            error.InvalidExternalController => .{
                .code = "RESTART_EXTERNAL_CONTROLLER_INVALID",
                .message = "invalid `external-controller` address in config",
                .hint = "use an explicit loopback endpoint such as `127.0.0.1:9090`",
            },
            else => .{
                .code = "RESTART_PREFLIGHT_FAILED",
                .message = "failed to validate daemon restart ports",
                .hint = "check config and retry",
            },
        },
    };
}

fn printRuntimeCommandPreflightError(command: RuntimeCommand, json_output: bool, err: anyerror) void {
    const info = runtimeCommandPreflightErrorInfo(command, err);
    printCliError(json_output, info.code, info.message, info.hint);
}

fn deinitForwardArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
) void {
    for (args.items) |item| allocator.free(item);
    args.deinit(allocator);
}

fn hasExplicitOverrideArguments(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--override-script") or
            std.mem.eql(u8, arg, "--override-timeout-ms") or
            std.mem.eql(u8, arg, "--override-arg") or
            std.mem.startsWith(u8, arg, "--override-script=") or
            std.mem.startsWith(u8, arg, "--override-timeout-ms=") or
            std.mem.startsWith(u8, arg, "--override-arg="))
        {
            return true;
        }
    }
    return false;
}

fn appendOwnedForwardArg(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try args.append(allocator, owned);
}

fn appendPreparedMarker(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
) !void {
    try appendOwnedForwardArg(allocator, args, "--prepared-runtime-config");
}

const PreparedListenerPorts = struct {
    mixed: u16,
    controller: ?u16,
};

fn preparedListenerPorts(
    allocator: std.mem.Allocator,
    path: []const u8,
) !PreparedListenerPorts {
    var no_override = override.CliOptions{};
    defer no_override.deinit(allocator);
    var loaded = try loadExactRuntimeConfig(
        allocator,
        path,
        null,
        &no_override,
        "daemon-run",
        .missing_only,
        false,
    );
    defer loaded.deinit();
    const controller = if (loaded.value.external_controller) |endpoint|
        try parseExternalControllerPort(endpoint)
    else
        null;
    try preflightPortCheckAllowing(
        &loaded.value,
        false,
        loaded.value.mixed_port,
        controller,
    );
    return .{ .mixed = loaded.value.mixed_port, .controller = controller };
}

fn managedConfigPathForKey(
    allocator: std.mem.Allocator,
    key: []const u8,
) ![]u8 {
    const root_path = (try config.getDefaultConfigDir(allocator)) orelse
        return error.ConfigDirectoryUnavailable;
    defer allocator.free(root_path);
    const yaml_name = try std.fmt.allocPrint(allocator, "{s}.yaml", .{key});
    defer allocator.free(yaml_name);
    return compat.fs.path.join(
        allocator,
        &.{ root_path, "configs", yaml_name },
    );
}

fn prepareDaemonManagedIdentity(
    allocator: std.mem.Allocator,
    identity: config_identity.ManagedIdentity,
    source_path: []const u8,
    port_override: ?u16,
    allowed_mixed_port: ?u16,
    allowed_controller_port: ?u16,
) !daemon.PreparedConfig {
    var root = try openDefaultCatalogRoot(allocator);
    defer root.deinit();
    const loader = managed_config_loader.Loader.init(allocator, root.dir);
    var managed = try loader.loadExact(identity);
    var loaded = finishManagedRuntimeLoad(allocator, &managed);
    defer loaded.deinit();
    try requireRuntimeCapabilities(allocator, &loaded.value);
    applyRuntimePortSelection(&loaded.value, port_override);
    for (loaded.value.rules.items) |rule| {
        if (rule.rule_type == .rule_set) {
            return error.ManagedRemoteRuleProviderUnsupported;
        }
    }
    try validateRuntimeEndpointSyntax(&loaded.value);
    var validation_result = try validator.validate(allocator, &loaded.value);
    defer validation_result.deinit();
    if (!validation_result.isValid()) return error.InvalidConfig;
    try preflightPortCheckAllowing(
        &loaded.value,
        false,
        allowed_mixed_port,
        allowed_controller_port,
    );
    const bytes = try override.dumpRuntimeConfigYaml(allocator, &loaded.value);
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    return daemon.publishPreparedConfig(
        allocator,
        bytes,
        loaded.identity,
        source_path,
        port_override,
    );
}

fn prepareDaemonConfig(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    port: ?u16,
    override_opts: *const override.CliOptions,
    allowed_mixed_port: ?u16,
    allowed_controller_port: ?u16,
    check_ports: bool,
) !daemon.PreparedConfig {
    var source_path: ?[]u8 = null;
    defer if (source_path) |path| allocator.free(path);
    var effective_port = port;
    if (config_path) |path| {
        if (try daemon.isPreparedConfigNamespacePath(allocator, path)) {
            var inherited = try daemon.readPreparedConfig(allocator, path);
            defer inherited.deinit();
            if (inherited.source_path) |source| {
                source_path = try allocator.dupe(u8, source);
            }
            if (effective_port == null) {
                effective_port = inherited.port_override;
            }
        } else {
            const managed_key = try config.inferConfigKeyFromPath(
                allocator,
                path,
            );
            defer if (managed_key) |key| allocator.free(key);
            if (managed_key != null) {
                source_path = try compat.fs.path.resolve(allocator, &.{path});
            } else {
                source_path = try compat.fs.realpathAlloc(allocator, path);
            }
        }
    }
    var loaded = try loadExactRuntimeConfig(
        allocator,
        config_path,
        effective_port,
        override_opts,
        "daemon-run",
        .eager,
        true,
    );
    defer loaded.deinit();
    if (check_ports) {
        try preflightPortCheckAllowing(
            &loaded.value,
            false,
            allowed_mixed_port,
            allowed_controller_port,
        );
    }
    const bytes = try override.dumpRuntimeConfigYaml(allocator, &loaded.value);
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    return daemon.publishPreparedConfig(
        allocator,
        bytes,
        loaded.identity,
        source_path,
        effective_port,
    );
}

fn validateTrackedPreparedRuntime(
    allocator: std.mem.Allocator,
    tracked: *const daemon.TrackedRuntime,
) !PreparedListenerPorts {
    const path = tracked.invocation.config_path orelse
        return error.DaemonInvocationUntracked;
    if (!tracked.invocation.prepared or
        !try daemon.isPreparedConfigPath(allocator, path))
    {
        return error.DaemonInvocationUntracked;
    }
    return preparedListenerPorts(allocator, path);
}

fn runRestartCommand(
    allocator: std.mem.Allocator,
    start_opts: StartCommandOptions,
    out: *cli_output.Output,
    override_opts: *const override.CliOptions,
    explicit_override: bool,
) !void {
    const was_running = try daemon.isRunning(allocator);
    var tracked: ?daemon.TrackedRuntime = null;
    defer if (tracked) |*runtime| runtime.deinit(allocator);
    var old_ports: ?PreparedListenerPorts = null;
    if (was_running) {
        tracked = (try daemon.captureTrackedRuntime(allocator)) orelse
            return error.DaemonInvocationUntracked;
        if (tracked.?.invocation.foreground) return error.ForegroundDaemonSupervised;
        old_ports = try validateTrackedPreparedRuntime(allocator, &tracked.?);
    }

    const changed = start_opts.config_path != null or
        start_opts.port != null or explicit_override or !was_running;
    var prepared: ?daemon.PreparedConfig = null;
    defer if (prepared) |*config_snapshot| config_snapshot.deinit();
    const target_path: []const u8 = if (!changed) blk: {
        break :blk tracked.?.invocation.config_path.?;
    } else blk: {
        var no_override = override.CliOptions{};
        defer no_override.deinit(allocator);
        const base_path = start_opts.config_path orelse
            (if (tracked) |runtime|
                if (explicit_override)
                    runtime.invocation.source_path
                else
                    runtime.invocation.config_path
            else
                null);
        const target_port = start_opts.port orelse
            (if (tracked) |runtime| runtime.invocation.port else null);
        prepared = try prepareDaemonConfig(
            allocator,
            base_path,
            target_port,
            if (explicit_override) override_opts else &no_override,
            if (old_ports) |ports| ports.mixed else null,
            if (old_ports) |ports| ports.controller else null,
            true,
        );
        break :blk prepared.?.path;
    };
    var target_args = std.ArrayList([]const u8).empty;
    defer deinitForwardArgs(allocator, &target_args);
    try appendPreparedMarker(allocator, &target_args);
    var previous_args = std.ArrayList([]const u8).empty;
    defer deinitForwardArgs(allocator, &previous_args);
    if (tracked) |*runtime| {
        try runtime.invocation.appendForwardArgs(allocator, &previous_args);
    }

    if (was_running) {
        try out.note("replacing daemon...\n", .{});
    } else {
        try out.note("daemon was not running; starting fresh\n", .{});
    }
    const previous: ?daemon.PreviousRequest = if (tracked) |runtime| .{
        .start = .{
            .config_path = runtime.invocation.config_path,
            .extra_args = previous_args.items,
        },
        .instance = runtime.instance,
    } else null;
    const outcome = daemon.replaceDaemonWithRollback(
        allocator,
        .{ .config_path = target_path, .extra_args = target_args.items },
        previous,
    ) catch |err| {
        if (err == error.RestartFailedRolledBack) {
            out.note("restart failed; previous daemon restored\n", .{}) catch {};
        } else if (err == error.RestartRollbackFailed or
            err == error.RestartRollbackContended)
        {
            out.note("restart and rollback both failed\n", .{}) catch {};
        }
        return err;
    };
    if (outcome.detail != null) return error.RestartContended;
    const pid = outcome.pid orelse return error.StartFailed;
    if (prepared) |*config_snapshot| config_snapshot.retain();
    if (tracked) |runtime| {
        if (!std.mem.eql(u8, runtime.invocation.config_path.?, target_path)) {
            daemon.removePreparedConfig(
                allocator,
                runtime.invocation.config_path.?,
            ) catch |err| out.note(
                "old prepared config cleanup failed: {s}\n",
                .{@errorName(err)},
            ) catch {};
        }
    }
    if (out.mode == .json) {
        try out.success(.{ .action = "restart", .state = "running", .pid = pid });
    } else {
        try out.print("zc daemon restarted (pid: {d})\n", .{pid});
        try out.flush();
    }
}

fn replaceRunningDaemonWithPrepared(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    use_tracked_source: bool,
    exact_identity: ?config_identity.ManagedIdentity,
) !void {
    var tracked = (try daemon.captureTrackedRuntime(allocator)) orelse
        return error.DaemonInvocationUntracked;
    defer tracked.deinit(allocator);
    if (tracked.invocation.foreground) return error.ForegroundDaemonSupervised;
    const old_ports = try validateTrackedPreparedRuntime(allocator, &tracked);
    var no_override = override.CliOptions{};
    defer no_override.deinit(allocator);
    const source_path = if (use_tracked_source)
        tracked.invocation.source_path
    else
        config_path;
    var prepared = if (exact_identity) |identity|
        try prepareDaemonManagedIdentity(
            allocator,
            identity,
            source_path orelse return error.ConfigPathRequired,
            tracked.invocation.port,
            old_ports.mixed,
            old_ports.controller,
        )
    else
        try prepareDaemonConfig(
            allocator,
            source_path,
            tracked.invocation.port,
            &no_override,
            old_ports.mixed,
            old_ports.controller,
            true,
        );
    defer prepared.deinit();
    var target_args = std.ArrayList([]const u8).empty;
    defer deinitForwardArgs(allocator, &target_args);
    try appendPreparedMarker(allocator, &target_args);
    var previous_args = std.ArrayList([]const u8).empty;
    defer deinitForwardArgs(allocator, &previous_args);
    try tracked.invocation.appendForwardArgs(allocator, &previous_args);
    const outcome = try daemon.replaceDaemonWithRollback(
        allocator,
        .{ .config_path = prepared.path, .extra_args = target_args.items },
        .{
            .start = .{
                .config_path = tracked.invocation.config_path,
                .extra_args = previous_args.items,
            },
            .instance = tracked.instance,
        },
    );
    if (outcome.detail != null or outcome.pid == null) {
        return error.RestartContended;
    }
    prepared.retain();
    daemon.removePreparedConfig(
        allocator,
        tracked.invocation.config_path.?,
    ) catch {};
}

fn reloadOrRestartPrepared(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    apply_mode: daemon.ApplyMode,
    use_tracked_source: bool,
    exact_identity: ?config_identity.ManagedIdentity,
) !daemon.ApplyResult {
    if (!try daemon.isRunning(allocator)) return .hot_applied;
    switch (apply_mode) {
        .restart => {
            try replaceRunningDaemonWithPrepared(
                allocator,
                config_path,
                use_tracked_source,
                exact_identity,
            );
            return .restart_applied;
        },
        .hot => {
            try daemon.reloadDaemon(allocator, config_path);
            return .hot_applied;
        },
        .auto => {
            daemon.reloadDaemon(allocator, config_path) catch {
                try replaceRunningDaemonWithPrepared(
                    allocator,
                    config_path,
                    use_tracked_source,
                    exact_identity,
                );
                return .restart_fallback;
            };
            return .hot_applied;
        },
    }
}

fn observedRuntimeControllerPort(allocator: std.mem.Allocator) ?u16 {
    const pid = (daemon.readPid(allocator) catch return null) orelse return null;
    if (pid <= 0 or !(daemon.isRunning(allocator) catch false)) return null;
    var default_store = (runtime_descriptor.openDefault(allocator, false) catch return null) orelse
        return null;
    defer default_store.deinit();
    var descriptor = (default_store.store().observe() catch return null) orelse return null;
    defer descriptor.deinit();
    if (descriptor.pid != @as(u32, @intCast(pid))) return null;
    const endpoint = descriptor.endpoint orelse return null;
    return parseExternalControllerPort(endpoint) catch null;
}

fn applyRuntimePortSelection(cfg: *config.Config, mixed_port_override: ?u16) void {
    if (mixed_port_override) |port| {
        cfg.mixed_port = port;
    } else if (cfg.mixed_port == 0) {
        cfg.mixed_port = constants.MIXED_PORT;
    }
    cfg.port = 0;
    cfg.socks_port = 0;
}

fn requireRuntimeCapabilities(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
) !void {
    var result = try validator.validateRuntimeCapabilities(allocator, cfg);
    defer result.deinit();
    if (result.isValid()) return;
    validator.printResult(&result);
    return error.UnsupportedCapability;
}

fn ruleProviderSyncPolicyForCommand(command_name: []const u8) config.RuleProviderSyncPolicy {
    if (std.mem.eql(u8, command_name, "test") or
        std.mem.eql(u8, command_name, "doctor") or
        std.mem.eql(u8, command_name, "diag.doctor"))
    {
        return .missing_only;
    }
    return .eager;
}

fn commandUsesQuietDefaultConfig(command_name: []const u8) bool {
    return std.mem.eql(u8, command_name, "doctor") or
        std.mem.eql(u8, command_name, "diag.doctor");
}

fn loadRuntimeConfig(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    mixed_port_override: ?u16,
    override_opts: *const override.CliOptions,
    command_name: []const u8,
    prepare_runtime_artifacts: bool,
    provider_policy: ?config.RuleProviderSyncPolicy,
) !config.Config {
    var cfg = if (config_path) |path| blk: {
        if (try config.inferConfigKeyFromPath(allocator, path)) |managed_key| {
            allocator.free(managed_key);
            break :blk try config.loadDocument(allocator, path);
        }
        break :blk try config.load(allocator, path);
    } else try config.loadDefaultManaged(allocator, !commandUsesQuietDefaultConfig(command_name));
    errdefer cfg.deinit();

    var persisted_script: ?[]u8 = null;
    defer if (persisted_script) |p| allocator.free(p);
    var effective_override = try resolveEffectiveOverrideOptions(
        allocator,
        override_opts,
        config_path,
        &persisted_script,
    );

    try override.apply(allocator, &cfg, &effective_override, command_name, config_path);
    try requireRuntimeCapabilities(allocator, &cfg);
    applyRuntimePortSelection(&cfg, mixed_port_override);
    if (prepare_runtime_artifacts) {
        try config.prepareRuleProvidersForRuntimeWithPolicy(
            allocator,
            &cfg,
            config_path,
            provider_policy orelse ruleProviderSyncPolicyForCommand(command_name),
        );
    }
    return cfg;
}

fn loadAndValidateConfig(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    mixed_port_override: ?u16,
    print_validation: bool,
    override_opts: *const override.CliOptions,
    command_name: []const u8,
    provider_policy: ?config.RuleProviderSyncPolicy,
) !config.Config {
    var cfg = try loadRuntimeConfig(
        allocator,
        config_path,
        mixed_port_override,
        override_opts,
        command_name,
        true,
        provider_policy,
    );
    errdefer cfg.deinit();

    try validateRuntimeEndpointSyntax(&cfg);
    var validation_result = try validator.validate(allocator, &cfg);
    defer validation_result.deinit();
    if (print_validation) {
        validator.printResult(&validation_result);
    }

    if (!validation_result.isValid()) {
        return error.InvalidConfig;
    }

    return cfg;
}

fn resolveEffectiveOverrideOptions(
    allocator: std.mem.Allocator,
    base_opts: *const override.CliOptions,
    config_path: ?[]const u8,
    persisted_script: *?[]u8,
) !override.CliOptions {
    var effective = base_opts.*;
    persisted_script.* = null;

    if (effective.script_path == null) {
        persisted_script.* = try config.getPersistedOverrideScriptForRuntime(allocator, config_path);
        if (persisted_script.*) |p| effective.script_path = p;
    }

    return effective;
}

fn reportListenerFailure(
    startup: *ListenerStartup,
    label: []const u8,
    err: anyerror,
) void {
    std.debug.print("{s} fatal error: {}\n", .{ label, err });
    const previous = startup.phase.swap(.failed, .acq_rel);
    if (previous == .committed) std.process.exit(cli_output.exit_failure);
}

fn waitForListenerReadiness(
    startup: *ListenerStartup,
    expected: u8,
    timeout_ms: i64,
) !void {
    std.debug.assert(timeout_ms > 0);
    const deadline = compat.monotonicMilliTimestamp() + timeout_ms;
    while (startup.ready.load(.acquire) < expected) {
        if (startup.phase.load(.acquire) == .failed) {
            return error.ListenerStartupFailed;
        }
        if (compat.monotonicMilliTimestamp() >= deadline) {
            return error.ListenerStartupTimeout;
        }
        compat.sleepNs(listener_start_poll_ms * std.time.ns_per_ms);
    }
    if (startup.phase.load(.acquire) == .failed) {
        return error.ListenerStartupFailed;
    }
}

fn proxyThreadFn(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    engine: *rule_engine.Engine,
    manager: *outbound.OutboundManager,
    startup: *ListenerStartup,
) void {
    const bind_ip = effectiveBindAddress(cfg);

    if (cfg.mixed_port > 0) {
        std.debug.print("Starting mixed proxy on {s}:{}\n", .{ bind_ip, cfg.mixed_port });
        mixed_proxy.startWithReady(
            allocator,
            bind_ip,
            cfg.mixed_port,
            engine,
            manager,
            &startup.ready,
            &startup.committed,
        ) catch |err| {
            reportListenerFailure(startup, "Mixed proxy", err);
            return;
        };
        return;
    }

    var http_thread: ?std.Thread = null;
    var socks_thread: ?std.Thread = null;

    if (cfg.port > 0) {
        std.debug.print("Starting HTTP proxy on {s}:{}\n", .{ bind_ip, cfg.port });
        http_thread = std.Thread.spawn(
            .{},
            httpThreadFn,
            .{ allocator, bind_ip, cfg.port, engine, manager, startup },
        ) catch |err| {
            reportListenerFailure(startup, "HTTP proxy thread", err);
            return;
        };
    }

    if (cfg.socks_port > 0) {
        std.debug.print("Starting SOCKS5 proxy on {s}:{}\n", .{ bind_ip, cfg.socks_port });
        socks_thread = std.Thread.spawn(
            .{},
            socksThreadFn,
            .{ allocator, bind_ip, cfg.socks_port, engine, manager, startup },
        ) catch |err| {
            reportListenerFailure(startup, "SOCKS5 proxy thread", err);
            return;
        };
    }

    if (http_thread) |t| t.join();
    if (socks_thread) |t| t.join();
}

fn apiThreadFn(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    engine: *rule_engine.Engine,
    manager: *outbound.OutboundManager,
    port: u16,
    managed_runtime: bool,
    startup: *ListenerStartup,
) void {
    var api_server = api.ApiServer.init(
        allocator,
        cfg,
        engine,
        manager,
        port,
        managed_runtime,
    );
    api_server.startWithAcceptGate(
        &startup.ready,
        &startup.control_available,
        &startup.committed,
    ) catch |err| {
        reportListenerFailure(startup, "API server", err);
    };
}

fn httpThreadFn(
    allocator: std.mem.Allocator,
    bind_ip: []const u8,
    port: u16,
    engine: *rule_engine.Engine,
    manager: *outbound.OutboundManager,
    startup: *ListenerStartup,
) void {
    http_proxy.startWithReady(
        allocator,
        bind_ip,
        port,
        engine,
        manager,
        &startup.ready,
        &startup.committed,
    ) catch |err| {
        reportListenerFailure(startup, "HTTP proxy", err);
    };
}

fn socksThreadFn(
    allocator: std.mem.Allocator,
    bind_ip: []const u8,
    port: u16,
    engine: *rule_engine.Engine,
    manager: *outbound.OutboundManager,
    startup: *ListenerStartup,
) void {
    socks5_proxy.startWithReady(
        allocator,
        bind_ip,
        port,
        engine,
        manager,
        &startup.ready,
        &startup.committed,
    ) catch |err| {
        reportListenerFailure(startup, "SOCKS5 proxy", err);
    };
}

fn effectiveBindAddress(cfg: *const config.Config) []const u8 {
    if (!cfg.allow_lan) return "127.0.0.1";
    if (std.mem.eql(u8, cfg.bind_address, "*")) return "0.0.0.0";
    return cfg.bind_address;
}

fn hasInProcessPortConflict(cfg: *const config.Config) !bool {
    if (cfg.mixed_port > 0) {
        if (cfg.external_controller) |ec| {
            return (try parseExternalControllerPort(ec)) == cfg.mixed_port;
        }
        return false;
    }

    if (cfg.port > 0 and cfg.socks_port > 0 and cfg.port == cfg.socks_port) {
        return true;
    }

    if (cfg.external_controller) |ec| {
        const api_port = try parseExternalControllerPort(ec);
        if (cfg.port > 0 and api_port == cfg.port) return true;
        if (cfg.socks_port > 0 and api_port == cfg.socks_port) return true;
    }

    return false;
}

fn validateRuntimeEndpointSyntax(cfg: *const config.Config) !void {
    _ = compat.net.Address.parseIp4(effectiveBindAddress(cfg), 1) catch
        return error.InvalidBindAddress;
    if (cfg.external_controller) |value| {
        _ = parseExternalControllerPort(value) catch
            return error.InvalidExternalController;
    }
}

fn preflightPortCheck(cfg: *config.Config, emit_errors: bool) !void {
    return preflightPortCheckAllowing(cfg, emit_errors, null, null);
}

/// Skip ports proven to belong to the daemon that restart is about to stop.
fn preflightPortCheckAllowing(
    cfg: *config.Config,
    emit_errors: bool,
    allowed_proxy_port: ?u16,
    allowed_controller_port: ?u16,
) !void {
    const bind_ip = effectiveBindAddress(cfg);

    // 进程内端口冲突检查
    if (try hasInProcessPortConflict(cfg)) {
        if (emit_errors) std.debug.print("Port precheck failed: in-process port conflict detected\n", .{});
        return error.PortConflict;
    }

    // 系统端口占用检查
    if (cfg.mixed_port > 0) {
        if (allowed_proxy_port == null or allowed_proxy_port.? != cfg.mixed_port) {
            try checkPortAvailable(bind_ip, cfg.mixed_port, emit_errors);
        }
    } else {
        if (cfg.port > 0) try checkPortAvailable(bind_ip, cfg.port, emit_errors);
        if (cfg.socks_port > 0) try checkPortAvailable(bind_ip, cfg.socks_port, emit_errors);
    }

    if (cfg.external_controller) |value| {
        const port = try parseExternalControllerPort(value);
        if (allowed_controller_port == null or allowed_controller_port.? != port) {
            checkPortAvailable("127.0.0.1", port, emit_errors) catch |err| switch (err) {
                error.PortAlreadyInUse => return error.ControllerPortAlreadyInUse,
                else => return err,
            };
        }
    }
}

fn isPortAvailable(ip: []const u8, port: u16) bool {
    const address = compat.net.Address.parseIp4(ip, port) catch return false;
    // Mirror the real listeners (SO_REUSEADDR-only) so this probe predicts the
    // actual bind: a TIME_WAIT remnant is available, an active listener is not.
    var server = compat.net.listenReuseAddr(address) catch return false;
    server.deinit();
    return true;
}

fn checkPortAvailable(ip: []const u8, port: u16, emit_errors: bool) !void {
    const address = compat.net.Address.parseIp4(ip, port) catch {
        if (emit_errors) std.debug.print("Invalid bind-address '{s}'\n", .{ip});
        return error.InvalidBindAddress;
    };

    // Mirror the real listeners (SO_REUSEADDR-only) so the preflight predicts
    // the bind: a TIME_WAIT remnant (e.g. right after `zc restart` stops the old
    // daemon) is treated as available, while a genuine active listener on the
    // port still fails -> PortAlreadyInUse.
    var server = compat.net.listenReuseAddr(address) catch {
        if (emit_errors) std.debug.print("Port precheck failed: {s}:{d} is already in use\n", .{ ip, port });
        return error.PortAlreadyInUse;
    };
    server.deinit();
}

fn parseExternalControllerPort(value: []const u8) !u16 {
    const endpoint = controller_endpoint.parse(value) catch
        return error.InvalidExternalController;
    return endpoint.port;
}

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or
        std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "--help");
}

fn containsHelpArg(args: []const []const u8, start: usize) bool {
    // 裸 "help" 只在子命令首位识别，避免吃掉恰好取值为 help 的参数；
    // -h/--help 在任意位置生效。
    if (args.len > start and std.mem.eql(u8, args[start], "help")) return true;
    var i = start;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) return true;
    }
    return false;
}

// 以下帮助函数全部由 src/cli/commands.zig 的命令表生成（stdout, exit 0）。
fn printHelp() !void {
    try printGlobalHelpStdout();
}

fn printConfigHelp() !void {
    _ = try printTopicHelpStdout(&.{"config"});
}

fn printDiagHelp() !void {
    _ = try printTopicHelpStdout(&.{"diag"});
}

fn printConfigLoadHelp() !void {
    _ = try printTopicHelpStdout(&.{ "config", "load" });
}

fn printConfigListHelp() !void {
    _ = try printTopicHelpStdout(&.{ "config", "list" });
}

fn printConfigDownloadHelp() !void {
    _ = try printTopicHelpStdout(&.{ "config", "download" });
}

fn printConfigUpdateHelp() !void {
    _ = try printTopicHelpStdout(&.{ "config", "update" });
}

fn printConfigUseHelp() !void {
    _ = try printTopicHelpStdout(&.{ "config", "use" });
}

fn printConfigDeleteHelp() !void {
    _ = try printTopicHelpStdout(&.{ "config", "delete" });
}

fn printConfigDumpHelp() !void {
    _ = try printTopicHelpStdout(&.{ "config", "dump" });
}

fn printConfigOverrideHelp() !void {
    _ = try printTopicHelpStdout(&.{ "config", "override" });
}

fn printDiagDoctorHelp() !void {
    _ = try printTopicHelpStdout(&.{ "diag", "doctor" });
}

test "parseExternalControllerPort valid and invalid" {
    const testing = std.testing;

    try testing.expectEqual(@as(u16, 9090), try parseExternalControllerPort("127.0.0.1:9090"));
    try testing.expectError(
        error.InvalidExternalController,
        parseExternalControllerPort("0.0.0.0:9090"),
    );
    try testing.expectError(
        error.InvalidExternalController,
        parseExternalControllerPort("localhost:9090"),
    );
    try testing.expectError(error.InvalidExternalController, parseExternalControllerPort("127.0.0.1"));
    try testing.expectError(error.InvalidExternalController, parseExternalControllerPort("127.0.0.1:abc"));
    try testing.expectError(error.InvalidExternalController, parseExternalControllerPort("127.0.0.1:0"));
}

test "isHelpArg accepts common help spellings" {
    const testing = std.testing;

    try testing.expect(isHelpArg("help"));
    try testing.expect(isHelpArg("--help"));
    try testing.expect(isHelpArg("-h"));
    try testing.expect(!isHelpArg("list"));
}

test "containsHelpArg scans after subcommand" {
    const testing = std.testing;

    const args = [_][]const u8{ "zc", "config", "download", "--help" };
    try testing.expect(containsHelpArg(args[0..], 3));

    const args2 = [_][]const u8{ "zc", "config", "download", "https://example.com" };
    try testing.expect(!containsHelpArg(args2[0..], 3));
}

test "parseStartCommandOptions strict mode rejects unknown args, skips global/override flags" {
    const testing = std.testing;

    const ok_args = [_][]const u8{ "zc", "start", "-c", "./x.yaml", "--port", "7899", "--json", "--override-script", "o.lua", "--override-arg=k=v" };
    const parsed = try parseStartCommandOptions(ok_args[0..], 2, .strict);
    try testing.expectEqualStrings("./x.yaml", parsed.config_path.?);
    try testing.expectEqual(@as(?u16, 7899), parsed.port);

    const bogus = [_][]const u8{ "zc", "start", "--bogus" };
    try testing.expectError(error.UnexpectedArgument, parseStartCommandOptions(bogus[0..], 2, .strict));

    const stray = [_][]const u8{ "zc", "restart", "extra" };
    try testing.expectError(error.UnexpectedArgument, parseStartCommandOptions(stray[0..], 2, .strict));

    // `-c --json` 不能把全局 flag 吃成路径。
    const missing_c = [_][]const u8{ "zc", "start", "-c", "--json" };
    try testing.expectError(error.MissingConfigPath, parseStartCommandOptions(missing_c[0..], 2, .strict));

    const missing_port = [_][]const u8{ "zc", "restart", "--port" };
    try testing.expectError(error.MissingPortValue, parseStartCommandOptions(missing_port[0..], 2, .strict));

    // 内部 --daemon-run 转发模式保持宽松。
    const forwarded = [_][]const u8{ "zc", "--daemon-run", "-c", "./x.yaml", "--port=7899", "--future-flag" };
    const lenient = try parseStartCommandOptions(forwarded[0..], 2, .forwarded);
    try testing.expectEqual(@as(?u16, 7899), lenient.port);
}

test "parseLogCommandArgs validates -n and rejects unknown args" {
    const testing = std.testing;

    const ok_args = [_][]const u8{ "zc", "log", "-n", "20", "--no-follow", "--json" };
    const parsed = try parseLogCommandArgs(ok_args[0..], 2);
    try testing.expectEqual(@as(?usize, 20), parsed.lines);
    try testing.expect(!parsed.follow);

    const follow_args = [_][]const u8{ "zc", "log", "-f" };
    const followed = try parseLogCommandArgs(follow_args[0..], 2);
    try testing.expect(followed.follow and followed.follow_explicit);

    const missing_n = [_][]const u8{ "zc", "log", "-n" };
    try testing.expectError(error.MissingLinesValue, parseLogCommandArgs(missing_n[0..], 2));

    const bad_n = [_][]const u8{ "zc", "log", "-n", "abc" };
    try testing.expectError(error.InvalidLinesValue, parseLogCommandArgs(bad_n[0..], 2));

    const bogus = [_][]const u8{ "zc", "log", "--bogus" };
    try testing.expectError(error.UnexpectedArgument, parseLogCommandArgs(bogus[0..], 2));
}

test "parseConfigOverrideAction supports show set clear" {
    const testing = std.testing;

    const show_args = [_][]const u8{ "zc", "config", "override" };
    const a1 = try parseConfigOverrideAction(show_args[0..], 3);
    try testing.expect(a1 == .show);

    const set_args = [_][]const u8{ "zc", "config", "override", "./override.lua" };
    const a2 = try parseConfigOverrideAction(set_args[0..], 3);
    try testing.expect(a2 == .set);
    try testing.expectEqualStrings("./override.lua", a2.set);

    const clear_args = [_][]const u8{ "zc", "config", "override", "--clear" };
    const a3 = try parseConfigOverrideAction(clear_args[0..], 3);
    try testing.expect(a3 == .clear);

    const set_json_args = [_][]const u8{ "zc", "config", "override", "./override.lua", "--json" };
    const a4 = try parseConfigOverrideAction(set_json_args[0..], 3);
    try testing.expect(a4 == .set);
    try testing.expectEqualStrings("./override.lua", a4.set);
}

test "parseConfigOverrideAction rejects invalid args" {
    const testing = std.testing;

    const both_args = [_][]const u8{ "zc", "config", "override", "--clear", "./override.lua" };
    try testing.expectError(error.InvalidConfigOverrideArgs, parseConfigOverrideAction(both_args[0..], 3));

    const unknown_flag_args = [_][]const u8{ "zc", "config", "override", "--bad" };
    try testing.expectError(error.InvalidConfigOverrideArgs, parseConfigOverrideAction(unknown_flag_args[0..], 3));
}

test "include auxiliary cli tests" {
    _ = @import("test_cli.zig");
    _ = @import("doctor_cli.zig");
    _ = @import("override.zig");
    _ = @import("protocol/trojan.zig");
    _ = @import("proxy_cli.zig");
}

test "parseProxyFamilyArgs parses -c and select flags, rejects strays (D11)" {
    const testing = std.testing;

    const list_args = [_][]const u8{ "zc", "proxy", "list", "-c", "./x.yaml", "--json" };
    const parsed = try parseProxyFamilyArgs(list_args[0..], 3, .{});
    try testing.expectEqualStrings("./x.yaml", parsed.config_path.?);
    try testing.expect(parsed.group == null);

    const select_args = [_][]const u8{ "zc", "proxy", "select", "-g", "Proxy", "-p", "HK", "--no-color" };
    const parsed2 = try parseProxyFamilyArgs(select_args[0..], 3, .{ .allow_select_flags = true });
    try testing.expectEqualStrings("Proxy", parsed2.group.?);
    try testing.expectEqualStrings("HK", parsed2.proxy.?);

    // list/test 不接受 -g/-p
    try testing.expectError(error.UnexpectedArgument, parseProxyFamilyArgs(select_args[0..], 3, .{}));

    const missing_c = [_][]const u8{ "zc", "proxy", "list", "-c" };
    try testing.expectError(error.MissingConfigPathValue, parseProxyFamilyArgs(missing_c[0..], 3, .{}));

    const missing_g = [_][]const u8{ "zc", "proxy", "select", "-g" };
    try testing.expectError(error.MissingGroupValue, parseProxyFamilyArgs(missing_g[0..], 3, .{ .allow_select_flags = true }));

    // `-g --json` 不能把全局 flag 吃成组名
    const flag_as_value = [_][]const u8{ "zc", "proxy", "select", "-g", "--json" };
    try testing.expectError(error.MissingGroupValue, parseProxyFamilyArgs(flag_as_value[0..], 3, .{ .allow_select_flags = true }));

    const missing_p = [_][]const u8{ "zc", "proxy", "select", "-p" };
    try testing.expectError(error.MissingProxyValue, parseProxyFamilyArgs(missing_p[0..], 3, .{ .allow_select_flags = true }));

    const stray = [_][]const u8{ "zc", "proxy", "list", "extra" };
    try testing.expectError(error.UnexpectedArgument, parseProxyFamilyArgs(stray[0..], 3, .{}));

    // override flags 由全局解析负责，这里跳过（含值）
    const with_override = [_][]const u8{ "zc", "proxy", "test", "--override-script", "./s.lua", "--override-arg=k=v" };
    const parsed3 = try parseProxyFamilyArgs(with_override[0..], 3, .{ .allow_port = true });
    try testing.expect(parsed3.config_path == null);
    try testing.expect(parsed3.port == null);
}

test "parseProxyFamilyArgs --port only for test commands, validated (Batch 5)" {
    const testing = std.testing;

    const with_port = [_][]const u8{ "zc", "test", "--port", "29123", "--json" };
    const parsed = try parseProxyFamilyArgs(with_port[0..], 2, .{ .allow_port = true });
    try testing.expectEqual(@as(?u16, 29123), parsed.port);

    const eq_form = [_][]const u8{ "zc", "proxy", "test", "--port=29124" };
    const parsed2 = try parseProxyFamilyArgs(eq_form[0..], 3, .{ .allow_port = true });
    try testing.expectEqual(@as(?u16, 29124), parsed2.port);

    const missing_value = [_][]const u8{ "zc", "test", "--port" };
    try testing.expectError(error.MissingPortValue, parseProxyFamilyArgs(missing_value[0..], 2, .{ .allow_port = true }));

    const invalid_value = [_][]const u8{ "zc", "test", "--port", "abc" };
    try testing.expectError(error.InvalidStartPort, parseProxyFamilyArgs(invalid_value[0..], 2, .{ .allow_port = true }));

    // list/select 不接受 --port
    const on_list = [_][]const u8{ "zc", "proxy", "list", "--port", "29123" };
    try testing.expectError(error.UnexpectedArgument, parseProxyFamilyArgs(on_list[0..], 3, .{}));
}

test "resolveDiagSubcommand distinguishes bare/help/missing/doctor/unknown" {
    const testing = std.testing;

    const bare = [_][]const u8{ "zc", "diag" };
    try testing.expect(resolveDiagSubcommand(bare[0..]) == .bare);

    // 只带全局 flag 等同裸命令（与 proxy/config 组对齐）
    const bare_json = [_][]const u8{ "zc", "diag", "--json" };
    try testing.expect(resolveDiagSubcommand(bare_json[0..]) == .bare);

    const help = [_][]const u8{ "zc", "diag", "--help" };
    try testing.expect(resolveDiagSubcommand(help[0..]) == .help);

    const missing = [_][]const u8{ "zc", "diag", "-c", "x.yaml" };
    try testing.expect(resolveDiagSubcommand(missing[0..]) == .missing);

    const doctor = [_][]const u8{ "zc", "diag", "--json", "doctor", "-c", "x.yaml" };
    const res = resolveDiagSubcommand(doctor[0..]);
    try testing.expect(res == .doctor);
    try testing.expectEqual(@as(usize, 3), res.doctor);

    const unknown = [_][]const u8{ "zc", "diag", "nope" };
    try testing.expect(resolveDiagSubcommand(unknown[0..]) == .unknown);
}

test "proxyFamilyText renders per-path wording without proxy leakage (D10)" {
    const testing = std.testing;

    try testing.expectEqualStrings("PROFILE_SUBCOMMAND_UNKNOWN", profile_family_text.sub_unknown_code);
    try testing.expectEqualStrings("PROXY_SUBCOMMAND_UNKNOWN", proxy_family_text.sub_unknown_code);
    try testing.expectEqualStrings("unknown profile subcommand", profile_family_text.sub_unknown_msg);
    try testing.expectEqualStrings("profile.select", profile_family_text.select_cmd_name);
    try testing.expectEqualStrings("failed to load/validate config for profile select", profile_family_text.load_select_msg);
    // profile 路径的 hint 必须指向 zc profile，而不是 zc proxy。
    try testing.expect(std.mem.indexOf(u8, profile_family_text.group_not_found_hint, "zc profile list") != null);
    try testing.expect(std.mem.indexOf(u8, profile_family_text.group_not_found_hint, "zc proxy") == null);
    try testing.expect(std.mem.indexOf(u8, profile_family_text.not_interactive_hint, "zc profile select") != null);
}

test "proxyArgsErrorMessage maps missing values to actionable text" {
    const testing = std.testing;

    try testing.expectEqualStrings("missing value for `-c`", proxyArgsErrorMessage(error.MissingConfigPathValue, "x"));
    try testing.expectEqualStrings("missing value for `-g`", proxyArgsErrorMessage(error.MissingGroupValue, "x"));
    try testing.expectEqualStrings("missing value for `-p`", proxyArgsErrorMessage(error.MissingProxyValue, "x"));
    try testing.expectEqualStrings("fallback", proxyArgsErrorMessage(error.UnexpectedArgument, "fallback"));
}

test "hasInProcessPortConflict detects conflicts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = config.Config{
        .allocator = allocator,
        .port = 7890,
        .socks_port = 7891,
        .mixed_port = 0,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "127.0.0.1"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    try testing.expect(!(try hasInProcessPortConflict(&cfg)));

    cfg.socks_port = 7890;
    try testing.expect(try hasInProcessPortConflict(&cfg));

    cfg.socks_port = 7891;
    cfg.external_controller = try allocator.dupe(u8, "127.0.0.1:7891");
    try testing.expect(try hasInProcessPortConflict(&cfg));
    allocator.free(cfg.external_controller.?);
    cfg.external_controller = null;

    cfg.mixed_port = 7892;
    cfg.external_controller = try allocator.dupe(u8, "127.0.0.1:7892");
    try testing.expect(try hasInProcessPortConflict(&cfg));
}

test "parseConfigDownloadArgs parses url, -n, -d and rejects missing url" {
    const testing = std.testing;

    const full = [_][]const u8{ "zc", "config", "download", "https://example.com/c.yaml", "-n", "myconf", "-d", "--json" };
    const parsed = try parseConfigDownloadArgs(full[0..], 3);
    try testing.expectEqualStrings("https://example.com/c.yaml", parsed.url);
    try testing.expectEqualStrings("myconf", parsed.name.?);
    try testing.expect(parsed.set_default);

    const bare = [_][]const u8{ "zc", "config", "download", "https://example.com/c.yaml" };
    const parsed2 = try parseConfigDownloadArgs(bare[0..], 3);
    try testing.expect(parsed2.name == null);
    try testing.expect(!parsed2.set_default);

    const missing_url = [_][]const u8{ "zc", "config", "download" };
    try testing.expectError(error.MissingUrl, parseConfigDownloadArgs(missing_url[0..], 3));

    const flag_first = [_][]const u8{ "zc", "config", "download", "--json" };
    try testing.expectError(error.MissingUrl, parseConfigDownloadArgs(flag_first[0..], 3));

    const missing_name = [_][]const u8{ "zc", "config", "download", "https://example.com/c.yaml", "-n" };
    try testing.expectError(error.MissingNameValue, parseConfigDownloadArgs(missing_name[0..], 3));
}

test "parseConfigDownloadArgs rejects unknown flags and stray positionals (D11)" {
    const testing = std.testing;

    const unknown_flag = [_][]const u8{ "zc", "config", "download", "https://example.com/c.yaml", "--bogus" };
    try testing.expectError(error.UnexpectedArgument, parseConfigDownloadArgs(unknown_flag[0..], 3));

    const stray_positional = [_][]const u8{ "zc", "config", "download", "https://example.com/c.yaml", "extra" };
    try testing.expectError(error.UnexpectedArgument, parseConfigDownloadArgs(stray_positional[0..], 3));

    // 全局 flag 不算未知
    const with_globals = [_][]const u8{ "zc", "config", "download", "https://example.com/c.yaml", "--json", "--no-color", "-d" };
    const parsed = try parseConfigDownloadArgs(with_globals[0..], 3);
    try testing.expect(parsed.set_default);
}

test "parseConfigUpdateArgs parses name and --apply, rejects bad values" {
    const testing = std.testing;

    const full = [_][]const u8{ "zc", "config", "update", "myconf", "--apply", "restart", "--json" };
    const parsed = try parseConfigUpdateArgs(full[0..], 3);
    try testing.expectEqualStrings("myconf", parsed.name.?);
    try testing.expectEqual(UpdateApplyMode.restart, parsed.apply_mode);

    const eq_form = [_][]const u8{ "zc", "config", "update", "--apply=hot" };
    const parsed2 = try parseConfigUpdateArgs(eq_form[0..], 3);
    try testing.expect(parsed2.name == null);
    try testing.expectEqual(UpdateApplyMode.hot, parsed2.apply_mode);

    const missing_value = [_][]const u8{ "zc", "config", "update", "--apply" };
    try testing.expectError(error.MissingApplyValue, parseConfigUpdateArgs(missing_value[0..], 3));

    const bad_value = [_][]const u8{ "zc", "config", "update", "--apply", "noop" };
    try testing.expectError(error.InvalidApplyMode, parseConfigUpdateArgs(bad_value[0..], 3));
}

test "parseConfigUpdateArgs rejects unknown flags and extra positionals (D11)" {
    const testing = std.testing;

    // 曾经的静默 bug：`--aply` 拼错被忽略后照常以 apply_mode=auto 执行
    const typo_flag = [_][]const u8{ "zc", "config", "update", "--aply", "hot" };
    try testing.expectError(error.UnexpectedArgument, parseConfigUpdateArgs(typo_flag[0..], 3));

    const extra_positional = [_][]const u8{ "zc", "config", "update", "one", "two" };
    try testing.expectError(error.UnexpectedArgument, parseConfigUpdateArgs(extra_positional[0..], 3));
}

test "parseConfigDumpArgs parses -c/--no-override, skips override flags, rejects unknown (D11)" {
    const testing = std.testing;

    const full = [_][]const u8{ "zc", "config", "dump", "-c", "./x.yaml", "--no-override", "--json" };
    const parsed = try parseConfigDumpArgs(full[0..], 3);
    try testing.expectEqualStrings("./x.yaml", parsed.config_path.?);
    try testing.expect(parsed.no_override);

    // override flags 由 override.parseCliOptions 全局解析，这里跳过（含值）
    const with_override = [_][]const u8{ "zc", "config", "dump", "--override-script", "./s.lua", "--override-arg=k=v" };
    const parsed2 = try parseConfigDumpArgs(with_override[0..], 3);
    try testing.expect(parsed2.config_path == null);
    try testing.expect(!parsed2.no_override);

    const missing_c = [_][]const u8{ "zc", "config", "dump", "-c" };
    try testing.expectError(error.MissingConfigPathValue, parseConfigDumpArgs(missing_c[0..], 3));

    const unknown_flag = [_][]const u8{ "zc", "config", "dump", "--no-overide" };
    try testing.expectError(error.UnexpectedArgument, parseConfigDumpArgs(unknown_flag[0..], 3));

    const stray_positional = [_][]const u8{ "zc", "config", "dump", "extra" };
    try testing.expectError(error.UnexpectedArgument, parseConfigDumpArgs(stray_positional[0..], 3));
}

test "hasUnexpectedArgs allows only global flags (D11)" {
    const testing = std.testing;

    const clean = [_][]const u8{ "zc", "config", "use", "smoke", "--json", "--no-color" };
    try testing.expect(!hasUnexpectedArgs(clean[0..], 4));

    const dirty = [_][]const u8{ "zc", "config", "use", "smoke", "--force" };
    try testing.expect(hasUnexpectedArgs(dirty[0..], 4));

    const dirty_positional = [_][]const u8{ "zc", "config", "list", "extra" };
    try testing.expect(hasUnexpectedArgs(dirty_positional[0..], 3));
}

test "applyResultToken matches zc reload applied tokens" {
    const testing = std.testing;

    try testing.expect(applyResultToken(null) == null);
    try testing.expectEqualStrings("hot", applyResultToken(.hot_applied).?);
    try testing.expectEqualStrings("restart", applyResultToken(.restart_applied).?);
    try testing.expectEqualStrings("restart_fallback", applyResultToken(.restart_fallback).?);
}

test "parseUpdateApplyMode supports auto hot restart" {
    const testing = std.testing;

    try testing.expectEqual(UpdateApplyMode.auto, try parseUpdateApplyMode("auto"));
    try testing.expectEqual(UpdateApplyMode.hot, try parseUpdateApplyMode("hot"));
    try testing.expectEqual(UpdateApplyMode.restart, try parseUpdateApplyMode("restart"));
    try testing.expectError(error.InvalidApplyMode, parseUpdateApplyMode("noop"));
}

test "parseStartCommandOptions supports config path and explicit port" {
    const testing = std.testing;

    const args = [_][]const u8{ "zc", "start", "-c", "./x.yaml", "--port", "7901", "--json" };
    const opts = try parseStartCommandOptions(args[0..], 2, .strict);
    try testing.expectEqualStrings("./x.yaml", opts.config_path.?);
    try testing.expectEqual(@as(?u16, 7901), opts.port);

    const args2 = [_][]const u8{ "zc", "start", "--port=7902" };
    const opts2 = try parseStartCommandOptions(args2[0..], 2, .strict);
    try testing.expect(opts2.config_path == null);
    try testing.expectEqual(@as(?u16, 7902), opts2.port);
}

test "parseStartCommandOptions supports --foreground (D1)" {
    const testing = std.testing;

    const args = [_][]const u8{ "zc", "start", "--foreground", "-c", "./x.yaml" };
    const opts = try parseStartCommandOptions(args[0..], 2, .strict);
    try testing.expect(opts.foreground);
    try testing.expectEqualStrings("./x.yaml", opts.config_path.?);

    const args2 = [_][]const u8{ "zc", "start" };
    const opts2 = try parseStartCommandOptions(args2[0..], 2, .strict);
    try testing.expect(!opts2.foreground);
}

test "parseStartCommandOptions rejects missing or invalid port values" {
    const testing = std.testing;

    const missing_port = [_][]const u8{ "zc", "start", "--port" };
    try testing.expectError(error.MissingPortValue, parseStartCommandOptions(missing_port[0..], 2, .strict));

    const invalid_port = [_][]const u8{ "zc", "start", "--port", "abc" };
    try testing.expectError(error.InvalidStartPort, parseStartCommandOptions(invalid_port[0..], 2, .strict));

    const zero_port = [_][]const u8{ "zc", "start", "--port=0" };
    try testing.expectError(error.InvalidStartPort, parseStartCommandOptions(zero_port[0..], 2, .strict));
}

test "appendStartForwardArgs forwards explicit port override" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var args = std.ArrayList([]const u8).empty;
    defer {
        for (args.items) |item| allocator.free(item);
        args.deinit(allocator);
    }

    try appendStartForwardArgs(allocator, &args, .{ .port = 7901 });
    try testing.expectEqual(@as(usize, 1), args.items.len);
    try testing.expectEqualStrings("--port=7901", args.items[0]);
}

test "ruleProviderSyncPolicyForCommand keeps zc test missing-only" {
    const testing = std.testing;

    try testing.expectEqual(config.RuleProviderSyncPolicy.missing_only, ruleProviderSyncPolicyForCommand("test"));
    try testing.expectEqual(config.RuleProviderSyncPolicy.missing_only, ruleProviderSyncPolicyForCommand("doctor"));
    try testing.expectEqual(config.RuleProviderSyncPolicy.missing_only, ruleProviderSyncPolicyForCommand("diag.doctor"));
    try testing.expectEqual(config.RuleProviderSyncPolicy.eager, ruleProviderSyncPolicyForCommand("start"));
    try testing.expectEqual(config.RuleProviderSyncPolicy.eager, ruleProviderSyncPolicyForCommand("proxy.test"));
}

test "commandUsesQuietDefaultConfig keeps doctor output clean" {
    const testing = std.testing;

    try testing.expect(commandUsesQuietDefaultConfig("doctor"));
    try testing.expect(commandUsesQuietDefaultConfig("diag.doctor"));
    try testing.expect(!commandUsesQuietDefaultConfig("start"));
}

test "runtime capability preflight rejects unsupported proxies" {
    // The runtime loader must invoke the validator before port or network work.
    const testing = std.testing;
    const allocator = testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: vmess-node
        \\    type: vmess
        \\    server: example.com
        \\    port: 443
        \\    uuid: 12345678-1234-1234-1234-123456789abc
    );
    defer cfg.deinit();

    try testing.expectError(
        error.UnsupportedCapability,
        requireRuntimeCapabilities(allocator, &cfg),
    );
}

test "applyRuntimePortSelection prefers explicit port and keeps mixed mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = config.Config{
        .allocator = allocator,
        .port = 7890,
        .socks_port = 7891,
        .mixed_port = constants.MIXED_PORT,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "127.0.0.1"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    applyRuntimePortSelection(&cfg, 7901);
    try testing.expectEqual(@as(u16, 7901), cfg.mixed_port);
    try testing.expectEqual(@as(u16, 0), cfg.port);
    try testing.expectEqual(@as(u16, 0), cfg.socks_port);
}

test "preflightPortCheck rejects mixed-port conflicts without fallback" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = config.Config{
        .allocator = allocator,
        .mixed_port = 7901,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "127.0.0.1"),
        .external_controller = try allocator.dupe(u8, "127.0.0.1:7901"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    try testing.expectError(error.PortConflict, preflightPortCheck(&cfg, false));
    try testing.expectEqual(@as(u16, 7901), cfg.mixed_port);
    try testing.expectEqualStrings("127.0.0.1:7901", cfg.external_controller.?);
}

test "preflight controller port conflict fails without endpoint drift" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try compat.net.listenReuseAddr(address);
    defer listener.deinit();
    const port = listener.listen_address.getPort();
    const endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{port});

    var cfg = config.Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "127.0.0.1"),
        .external_controller = endpoint,
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    try testing.expectError(
        error.ControllerPortAlreadyInUse,
        preflightPortCheck(&cfg, false),
    );
    try testing.expectEqualStrings(endpoint, cfg.external_controller.?);
}

test "SO_REUSEADDR-only listener rejects a second active listener" {
    const testing = std.testing;
    // Bind a real active listener via the SO_REUSEADDR-only helper used by the
    // proxy. Because SO_REUSEPORT is deliberately NOT set, a second active bind
    // to the same port must fail -> checkPortAvailable reports the conflict. This
    // is the guard that keeps the restart fix from ever permitting two daemons on
    // one port (the failure mode of Zig's bundled reuse_address=true).
    const addr = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try compat.net.listenReuseAddr(addr);
    defer listener.deinit();
    const port = listener.listen_address.getPort();

    try testing.expectError(error.PortAlreadyInUse, checkPortAvailable("127.0.0.1", port, false));
    // And a TIME_WAIT-free fresh ephemeral port is reported available.
    try testing.expect(isPortAvailable("127.0.0.1", 0));
}

test "runtimeCommandPreflightErrorInfo maps restart port conflicts" {
    const testing = std.testing;

    const info = runtimeCommandPreflightErrorInfo(.restart, error.PortAlreadyInUse);
    try testing.expectEqualStrings("RESTART_PORT_IN_USE", info.code);
    try testing.expectEqualStrings("restart target port is already in use", info.message);
    try testing.expect(std.mem.indexOf(u8, info.hint, "zc restart") != null);

    const controller = runtimeCommandPreflightErrorInfo(
        .restart,
        error.ControllerPortAlreadyInUse,
    );
    try testing.expectEqualStrings("RESTART_CONTROLLER_PORT_IN_USE", controller.code);
    try testing.expect(std.mem.indexOf(u8, controller.hint, "external-controller") != null);
}

test "mixed handler should explicitly close client stream on success path" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const content = try compat.fs.cwd().readFileAlloc(allocator, "src/proxy/mixed.zig", 1024 * 1024);
    defer allocator.free(content);

    const fn_pos = std.mem.indexOf(u8, content, "fn handleConnection(") orelse return error.TestUnexpectedResult;
    const next_fn_pos = std.mem.indexOfPos(u8, content, fn_pos, "fn handleSocks5(") orelse return error.TestUnexpectedResult;
    const fn_body = content[fn_pos..next_fn_pos];
    try testing.expect(std.mem.indexOf(u8, fn_body, "defer conn.stream.close();") != null);
}

test "mixed connection workers use bounded stack size" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const content = try compat.fs.cwd().readFileAlloc(allocator, "src/proxy/mixed.zig", 1024 * 1024);
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "connection_task_stack_size: usize = 512 * 1024") != null);
    try testing.expect(std.mem.indexOf(u8, content, ".stack_size = connection_task_stack_size") != null);
}

test "mixed relay uses finite idle reap instead of infinite poll" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const content = try compat.fs.cwd().readFileAlloc(allocator, "src/proxy/mixed.zig", 1024 * 1024);
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "const relay_poll_timeout_ms: i32 = 30 * 1000") != null);
    try testing.expect(std.mem.indexOf(u8, content, "const relay_idle_reap_ms: i64 = 15 * 60 * 1000") != null);
    try testing.expect(std.mem.indexOf(u8, content, "shouldReapIdleRelay(now_ms, last_activity_ms, relay_idle_reap_ms)") != null);
}

test "shadowsocks hasPendingRead should ignore encrypted leftover-only state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var client = try shadowsocks.ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");
    defer client.deinit();

    client.read_leftover = try allocator.dupe(u8, "partial");
    try testing.expect(!client.hasPendingRead());
}
