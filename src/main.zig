const std = @import("std");
const compat = @import("compat.zig");
const config = @import("config.zig");
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
const test_cli = @import("test_cli.zig");
const doctor_cli = @import("doctor_cli.zig");
const override = @import("override.zig");
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

const StartCommandOptions = struct {
    config_path: ?[]const u8 = null,
    port: ?u16 = null,
};

// 全局配置路径，用于重载
var g_config_path: ?[]const u8 = null;
var gpa_holder: ?*std.heap.DebugAllocator(.{}) = null;

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
        // 无参数，显示帮助
        try printHelp();
        return;
    }

    const cmd = args[1];
    const json_output = hasFlag(args, "--json");

    var override_opts = override.parseCliOptions(allocator, args) catch |err| {
        printOverrideOptionError(json_output, err);
        return err;
    };
    defer override_opts.deinit(allocator);

    // 处理 daemon 运行模式（内部使用）
    if (std.mem.eql(u8, cmd, "--daemon-run")) {
        const start_opts = parseStartCommandOptions(args, 2) catch |err| {
            printStartCommandOptionError(json_output, err);
            return err;
        };
        daemon.writePid(allocator, std.c.getpid()) catch {};
        try runProxy(allocator, start_opts.config_path, start_opts.port, &override_opts, "daemon-run");
        return;
    }

    // 处理 help
    if (isHelpArg(cmd)) {
        if (std.mem.eql(u8, cmd, "help") and args.len >= 3) {
            try printHelpTopic(args[2]);
        } else {
            try printHelp();
        }
        return;
    }

    // 处理 start 命令
    if (std.mem.eql(u8, cmd, "start")) {
        const start_opts = parseStartCommandOptions(args, 2) catch |err| {
            printStartCommandOptionError(json_output, err);
            return err;
        };
        preflightRuntimeCommand(allocator, .start, start_opts, &override_opts) catch |err| {
            if (printOverrideRuntimeError(json_output, err)) return err;
            printRuntimeCommandPreflightError(.start, json_output, err);
            return err;
        };

        // 后台启动
        var forward_args = std.ArrayList([]const u8).empty;
        defer {
            for (forward_args.items) |item| allocator.free(item);
            forward_args.deinit(allocator);
        }
        try appendStartForwardArgs(allocator, &forward_args, start_opts);
        try override_opts.appendForwardArgs(allocator, &forward_args);

        daemon.startDaemon(allocator, start_opts.config_path, json_output, forward_args.items) catch |err| {
            printCliError(json_output, "START_FAILED", "failed to start daemon", "check config path and logs via `zc log --no-follow`");
            return err;
        };
        return;
    }

    // 处理 stop 命令
    if (std.mem.eql(u8, cmd, "stop")) {
        daemon.stopDaemon(allocator, json_output) catch |err| {
            printCliError(json_output, "STOP_FAILED", "failed to stop daemon", "verify process permissions and retry `zc stop`");
            return err;
        };
        return;
    }

    // 处理 restart 命令
    if (std.mem.eql(u8, cmd, "restart")) {
        const config_path = parseConfigPathArg(args, 2);
        var forward_args = std.ArrayList([]const u8).empty;
        defer {
            for (forward_args.items) |item| allocator.free(item);
            forward_args.deinit(allocator);
        }
        try override_opts.appendForwardArgs(allocator, &forward_args);

        runRestartCommand(allocator, config_path, json_output, &override_opts, forward_args.items) catch |err| {
            if (printOverrideRuntimeError(json_output, err)) return err;
            switch (err) {
                error.PortAlreadyInUse, error.PortConflict, error.InvalidBindAddress, error.InvalidExternalController => {
                    printRuntimeCommandPreflightError(.restart, json_output, err);
                },
                error.StartFailed, error.DaemonPidUntracked => {},
                else => {
                    printCliError(json_output, "RESTART_FAILED", "failed to restart daemon", "check logs and retry `zc restart -c <config>`");
                },
            }
            return err;
        };
        return;
    }

    // 处理 status 命令
    if (std.mem.eql(u8, cmd, "status")) {
        daemon.getStatus(allocator, json_output) catch |err| {
            printCliError(json_output, "STATUS_FAILED", "failed to read daemon status", "check pid file permissions and retry `zc status`");
            return err;
        };
        return;
    }

    // 处理 log 命令
    if (std.mem.eql(u8, cmd, "log")) {
        var lines: ?usize = null;
        var follow = true; // 默认持续刷新
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-n")) {
                if (i + 1 < args.len) {
                    lines = std.fmt.parseInt(usize, args[i + 1], 10) catch 50;
                    i += 1;
                }
            } else if (std.mem.eql(u8, args[i], "-f")) {
                follow = true;
            } else if (std.mem.eql(u8, args[i], "--no-follow")) {
                follow = false;
            }
        }
        // 如果没有指定 -n，默认显示 50 行
        if (lines == null and !follow) {
            lines = 50;
        }
        try daemon.viewLog(allocator, lines, follow);
        return;
    }

    // 处理 config 子命令
    if (std.mem.eql(u8, cmd, "config")) {
        if (args.len < 3) {
            try config.listConfigs(allocator);
            return;
        }

        const subcmd = args[2];

        if (isHelpArg(subcmd)) {
            try printConfigHelp();
            return;
        }

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            if (containsHelpArg(args, 3)) {
                try printConfigListHelp();
                return;
            }
            try config.listConfigs(allocator);
            return;
        }

        if (std.mem.eql(u8, subcmd, "download")) {
            if (containsHelpArg(args, 3)) {
                try printConfigDownloadHelp();
                return;
            }
            if (args.len < 4) {
                try printConfigDownloadHelp();
                return;
            }

            const url = args[3];
            var download_name: ?[]const u8 = null;

            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-n")) {
                    if (i + 1 < args.len) {
                        download_name = args[i + 1];
                        i += 1;
                    }
                }
            }

            const key = try config.downloadConfig(allocator, url, download_name);
            defer if (key) |k| allocator.free(k);
            return;
        }

        if (std.mem.eql(u8, subcmd, "update")) {
            if (containsHelpArg(args, 3)) {
                try printConfigUpdateHelp();
                return;
            }
            var config_name: ?[]const u8 = null;
            var apply_mode: UpdateApplyMode = .auto;

            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--apply")) {
                    if (i + 1 >= args.len) {
                        try printConfigUpdateHelp();
                        return;
                    }
                    apply_mode = parseUpdateApplyMode(args[i + 1]) catch {
                        std.debug.print("Invalid --apply value: {s}\n", .{args[i + 1]});
                        std.debug.print("Expected one of: auto, hot, restart\n", .{});
                        return;
                    };
                    i += 1;
                } else if (std.mem.startsWith(u8, args[i], "--apply=")) {
                    const value = args[i]["--apply=".len..];
                    apply_mode = parseUpdateApplyMode(value) catch {
                        std.debug.print("Invalid --apply value: {s}\n", .{value});
                        std.debug.print("Expected one of: auto, hot, restart\n", .{});
                        return;
                    };
                } else if (args[i].len > 0 and args[i][0] != '-') {
                    if (config_name == null) {
                        config_name = args[i];
                    }
                }
            }

            const current_config = config.getCurrentConfigName(allocator) catch null;
            defer if (current_config) |c| allocator.free(c);

            const target_name = config_name orelse current_config orelse {
                try printConfigUpdateHelp();
                return;
            };

            const filename = try config.updateConfig(allocator, target_name);
            defer if (filename) |f| allocator.free(f);

            if (filename != null) {
                // 应用策略：auto(默认)/hot/restart
                if (try daemon.isRunning(allocator)) {
                    const result = daemon.reloadOrRestart(allocator, null, json_output, apply_mode) catch |err| {
                        std.debug.print("Failed to apply updated config: {s}\n", .{@errorName(err)});
                        return err;
                    };

                    switch (result) {
                        .hot_applied => std.debug.print("Config applied via hot reload\n", .{}),
                        .restart_applied => std.debug.print("Config applied via restart\n", .{}),
                        .restart_fallback => std.debug.print("Config hot reload unavailable, fell back to restart\n", .{}),
                    }
                }
            }
            return;
        }

        if (std.mem.eql(u8, subcmd, "use")) {
            if (containsHelpArg(args, 3)) {
                try printConfigUseHelp();
                return;
            }
            if (args.len < 4) {
                try printConfigUseHelp();
                return;
            }

            try config.switchConfig(allocator, args[3]);
            return;
        }

        if (std.mem.eql(u8, subcmd, "dump")) {
            if (containsHelpArg(args, 3)) {
                try printConfigDumpHelp();
                return;
            }
            const config_path = parseConfigPathArg(args, 3);
            const no_override = hasFlag(args, "--no-override");
            var cfg = if (config_path) |path|
                try config.load(allocator, path)
            else
                try config.loadDefault(allocator);
            defer cfg.deinit();

            if (!no_override) {
                var persisted_script: ?[]u8 = null;
                defer if (persisted_script) |p| allocator.free(p);
                var effective_override = resolveEffectiveOverrideOptions(
                    allocator,
                    &override_opts,
                    config_path,
                    &persisted_script,
                ) catch |err| {
                    if (printOverrideRuntimeError(json_output, err)) return err;
                    printConfigDumpError(json_output, err);
                    return err;
                };

                override.apply(allocator, &cfg, &effective_override, "config.dump", config_path) catch |err| {
                    if (printOverrideRuntimeError(json_output, err)) return err;
                    printConfigDumpError(json_output, err);
                    return err;
                };
            }

            const dumped = if (json_output)
                override.dumpConfigJson(allocator, &cfg)
            else
                override.dumpConfigYaml(allocator, &cfg);
            const dumped_text = dumped catch |err| {
                printConfigDumpError(json_output, err);
                return err;
            };
            defer allocator.free(dumped_text);

            std.debug.print("{s}\n", .{dumped_text});
            return;
        }

        if (std.mem.eql(u8, subcmd, "override")) {
            if (containsHelpArg(args, 3)) {
                try printConfigOverrideHelp();
                return;
            }
            const action = parseConfigOverrideAction(args, 3) catch {
                if (json_output) {
                    printCliError(true, "CONFIG_OVERRIDE_ARGUMENT_INVALID", "invalid config override arguments", "use `zc config override <script.lua>` / `zc config override --clear` / `zc config override`");
                } else {
                    try printConfigOverrideHelp();
                }
                return;
            };

            const runtime_key = config.resolveRuntimeConfigKey(allocator, null) catch null;
            defer if (runtime_key) |k| allocator.free(k);
            const profile_name = runtime_key orelse "(none)";

            switch (action) {
                .set => |script| {
                    const managed_path = config.copyOverrideScriptForCurrentConfig(allocator, script) catch |err| {
                        printConfigOverrideError(json_output, err);
                        return err;
                    };
                    defer allocator.free(managed_path);

                    validateOverrideAndPrepareRuleProviders(allocator, managed_path) catch |err| {
                        compat.fs.deleteFileAbsolute(managed_path) catch {};
                        if (printOverrideRuntimeError(json_output, err)) return err;
                        printConfigOverridePrepareError(json_output, err);
                        return err;
                    };

                    config.persistOverrideScriptPathForCurrentConfig(allocator, managed_path) catch |err| {
                        compat.fs.deleteFileAbsolute(managed_path) catch {};
                        printConfigOverrideError(json_output, err);
                        return err;
                    };

                    applyConfigOverrideToRunningDaemon(allocator, json_output) catch |err| {
                        printConfigOverrideApplyError(json_output, err);
                        return err;
                    };

                    if (json_output) {
                        std.debug.print("{{\"ok\":true,\"data\":{{\"action\":\"config_override_set\",\"profile\":\"{s}\",\"enabled\":true,\"script\":\"{s}\"}}}}\n", .{
                            profile_name,
                            managed_path,
                        });
                    } else {
                        std.debug.print("Persisted override set for config {s}: {s}\n", .{ profile_name, managed_path });
                    }
                    return;
                },
                .clear => {
                    const had_override = config.clearPersistedOverrideScriptForCurrentConfig(allocator) catch |err| {
                        printConfigOverrideError(json_output, err);
                        return err;
                    };

                    if (had_override) {
                        applyConfigOverrideToRunningDaemon(allocator, json_output) catch |err| {
                            printConfigOverrideApplyError(json_output, err);
                            return err;
                        };
                    }

                    if (json_output) {
                        std.debug.print("{{\"ok\":true,\"data\":{{\"action\":\"config_override_clear\",\"profile\":\"{s}\",\"enabled\":false,\"cleared\":{s}}}}}\n", .{
                            profile_name,
                            if (had_override) "true" else "false",
                        });
                    } else if (had_override) {
                        std.debug.print("Cleared persisted override for config {s}\n", .{profile_name});
                    } else {
                        std.debug.print("No persisted override set for config {s}\n", .{profile_name});
                    }
                    return;
                },
                .show => {
                    const current_script = config.getPersistedOverrideScriptForCurrentConfig(allocator) catch |err| {
                        printConfigOverrideError(json_output, err);
                        return err;
                    };
                    defer if (current_script) |s| allocator.free(s);

                    if (json_output) {
                        if (current_script) |s| {
                            std.debug.print("{{\"ok\":true,\"data\":{{\"action\":\"config_override_get\",\"profile\":\"{s}\",\"enabled\":true,\"script\":\"{s}\"}}}}\n", .{
                                profile_name,
                                s,
                            });
                        } else {
                            std.debug.print("{{\"ok\":true,\"data\":{{\"action\":\"config_override_get\",\"profile\":\"{s}\",\"enabled\":false,\"script\":null}}}}\n", .{profile_name});
                        }
                    } else if (current_script) |s| {
                        std.debug.print("Config {s} persisted override: {s}\n", .{ profile_name, s });
                    } else {
                        std.debug.print("Config {s} persisted override: (none)\n", .{profile_name});
                    }
                    return;
                },
            }
        }

        std.debug.print("Unknown config subcommand: {s}\n", .{subcmd});
        return;
    }

    // 处理 proxy 子命令
    if (std.mem.eql(u8, cmd, "proxy")) {
        if (args.len < 3) {
            try printProxyHelp();
            return;
        }

        const subcmd = args[2];

        if (isHelpArg(subcmd)) {
            try printProxyHelp();
            return;
        }

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            if (containsHelpArg(args, 3)) {
                try printProxyListHelp();
                return;
            }
            // 解析 -c 参数
            var config_path: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-c")) {
                    if (i + 1 < args.len) {
                        config_path = args[i + 1];
                        i += 1;
                    }
                }
            }

            // 加载配置
            var cfg = loadAndValidateConfig(allocator, config_path, null, !json_output, &override_opts, "proxy.list") catch |err| {
                if (printOverrideRuntimeError(json_output, err)) return err;
                printCliError(json_output, "PROXY_CONFIG_LOAD_FAILED", "failed to load/validate config for proxy list", "check config path and retry with `-c <config>`");
                return err;
            };
            defer cfg.deinit();

            if (json_output) {
                try proxy_cli.listProxiesJson(allocator, &cfg);
            } else {
                try proxy_cli.listProxies(allocator, &cfg);
            }
            return;
        }

        if (std.mem.eql(u8, subcmd, "select")) {
            if (containsHelpArg(args, 3)) {
                try printProxySelectHelp("proxy");
                return;
            }
            var group_name: ?[]const u8 = null;
            var proxy_name: ?[]const u8 = null;
            var config_path: ?[]const u8 = null;

            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-g")) {
                    if (i + 1 < args.len) {
                        group_name = args[i + 1];
                        i += 1;
                    }
                } else if (std.mem.eql(u8, args[i], "-p")) {
                    if (i + 1 < args.len) {
                        proxy_name = args[i + 1];
                        i += 1;
                    }
                } else if (std.mem.eql(u8, args[i], "-c")) {
                    if (i + 1 < args.len) {
                        config_path = args[i + 1];
                        i += 1;
                    }
                }
            }

            // 加载配置（需要可变引用）
            var cfg = loadAndValidateConfig(allocator, config_path, null, !json_output, &override_opts, "proxy.select") catch |err| {
                if (printOverrideRuntimeError(json_output, err)) return err;
                printCliError(json_output, "PROXY_CONFIG_LOAD_FAILED", "failed to load/validate config for proxy select", "check config path and retry with `-c <config>`");
                return err;
            };
            defer cfg.deinit();

            if (json_output) {
                proxy_cli.selectProxyJson(allocator, &cfg, group_name, proxy_name) catch |err| {
                    switch (err) {
                        error.GroupNotFound => printCliError(true, "PROXY_GROUP_NOT_FOUND", "proxy group not found", "run `zc proxy list --json` to inspect groups"),
                        error.ProxyNotFound => printCliError(true, "PROXY_NOT_FOUND", "proxy not found in group", "run `zc proxy select -g <group> --json` to inspect choices"),
                        error.NoSelectGroup => printCliError(true, "PROXY_SELECT_GROUP_MISSING", "no select-type proxy group found", "check profile proxy-groups config"),
                        else => printCliError(true, "PROXY_SELECT_FAILED", "failed to select proxy", "retry with valid group/proxy arguments"),
                    }
                    return;
                };
            } else {
                try proxy_cli.selectProxy(allocator, &cfg, group_name, proxy_name);
            }
            return;
        }

        if (std.mem.eql(u8, subcmd, "test")) {
            if (containsHelpArg(args, 3)) {
                try printProxyTestHelp("proxy");
                return;
            }
            var config_path: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
                    config_path = args[i + 1];
                    i += 1;
                }
            }

            var cfg = loadAndValidateConfig(allocator, config_path, null, !json_output, &override_opts, "proxy.test") catch |err| {
                if (printOverrideRuntimeError(json_output, err)) return err;
                printCliError(json_output, "PROXY_CONFIG_LOAD_FAILED", "failed to load/validate config for proxy test", "check config path and retry with `-c <config>`");
                return err;
            };
            defer cfg.deinit();

            if (json_output) {
                try test_cli.testProxyJson(allocator, &cfg, null);
            } else {
                try test_cli.testProxy(allocator, &cfg, null);
            }
            return;
        }

        // 未知子命令
        if (json_output) {
            printCliError(json_output, "PROXY_SUBCOMMAND_UNKNOWN", "unknown proxy subcommand", "use `zc proxy --help` or `zc help`");
        } else {
            std.debug.print("Unknown proxy subcommand: {s}\n", .{subcmd});
            try printProxyHelp();
        }
        return;
    }

    // 处理 profile 子命令
    if (std.mem.eql(u8, cmd, "profile")) {
        if (args.len < 3) {
            if (json_output) {
                printCliError(json_output, "PROFILE_SUBCOMMAND_MISSING", "profile subcommand is required", "use `zc profile --help` or `zc help profile`");
            } else {
                try printProfileHelp();
            }
            return;
        }

        const subcmd = args[2];

        if (isHelpArg(subcmd)) {
            try printProfileHelp();
            return;
        }

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            if (containsHelpArg(args, 3)) {
                try printProfileListHelp();
                return;
            }
            // 解析 -c 参数
            var config_path: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-c")) {
                    if (i + 1 < args.len) {
                        config_path = args[i + 1];
                        i += 1;
                    }
                }
            }

            // 加载配置
            var cfg = loadAndValidateConfig(allocator, config_path, null, !json_output, &override_opts, "profile.list") catch |err| {
                if (printOverrideRuntimeError(json_output, err)) return err;
                printCliError(json_output, "PROXY_CONFIG_LOAD_FAILED", "failed to load/validate config for proxy list", "check config path and retry with `-c <config>`");
                return err;
            };
            defer cfg.deinit();

            if (json_output) {
                try proxy_cli.listProxiesJson(allocator, &cfg);
            } else {
                try proxy_cli.listProxies(allocator, &cfg);
            }
            return;
        }

        if (std.mem.eql(u8, subcmd, "select")) {
            if (containsHelpArg(args, 3)) {
                try printProxySelectHelp("profile");
                return;
            }
            var group_name: ?[]const u8 = null;
            var proxy_name: ?[]const u8 = null;
            var config_path: ?[]const u8 = null;

            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-g")) {
                    if (i + 1 < args.len) {
                        group_name = args[i + 1];
                        i += 1;
                    }
                } else if (std.mem.eql(u8, args[i], "-p")) {
                    if (i + 1 < args.len) {
                        proxy_name = args[i + 1];
                        i += 1;
                    }
                } else if (std.mem.eql(u8, args[i], "-c")) {
                    if (i + 1 < args.len) {
                        config_path = args[i + 1];
                        i += 1;
                    }
                }
            }

            // 加载配置（需要可变引用）
            var cfg = loadAndValidateConfig(allocator, config_path, null, !json_output, &override_opts, "profile.select") catch |err| {
                if (printOverrideRuntimeError(json_output, err)) return err;
                printCliError(json_output, "PROXY_CONFIG_LOAD_FAILED", "failed to load/validate config for proxy select", "check config path and retry with `-c <config>`");
                return err;
            };
            defer cfg.deinit();

            if (json_output) {
                proxy_cli.selectProxyJson(allocator, &cfg, group_name, proxy_name) catch |err| {
                    switch (err) {
                        error.GroupNotFound => printCliError(true, "PROXY_GROUP_NOT_FOUND", "proxy group not found", "run `zc proxy list --json` to inspect groups"),
                        error.ProxyNotFound => printCliError(true, "PROXY_NOT_FOUND", "proxy not found in group", "run `zc proxy select -g <group> --json` to inspect choices"),
                        error.NoSelectGroup => printCliError(true, "PROXY_SELECT_GROUP_MISSING", "no select-type proxy group found", "check profile proxy-groups config"),
                        else => printCliError(true, "PROXY_SELECT_FAILED", "failed to select proxy", "retry with valid group/proxy arguments"),
                    }
                    return;
                };
            } else {
                try proxy_cli.selectProxy(allocator, &cfg, group_name, proxy_name);
            }
            return;
        }

        if (std.mem.eql(u8, subcmd, "test")) {
            if (containsHelpArg(args, 3)) {
                try printProxyTestHelp("profile");
                return;
            }
            var config_path: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
                    config_path = args[i + 1];
                    i += 1;
                }
            }

            var cfg = loadAndValidateConfig(allocator, config_path, null, !json_output, &override_opts, "profile.test") catch |err| {
                if (printOverrideRuntimeError(json_output, err)) return err;
                printCliError(json_output, "PROXY_CONFIG_LOAD_FAILED", "failed to load/validate config for proxy test", "check config path and retry with `-c <config>`");
                return err;
            };
            defer cfg.deinit();

            if (json_output) {
                try test_cli.testProxyJson(allocator, &cfg, null);
            } else {
                try test_cli.testProxy(allocator, &cfg, null);
            }
            return;
        }

        // 未知子命令
        if (json_output) {
            printCliError(json_output, "PROFILE_SUBCOMMAND_UNKNOWN", "unknown profile subcommand", "use `zc profile --help` or `zc help profile`");
        } else {
            std.debug.print("Unknown profile subcommand: {s}\n", .{subcmd});
            try printProfileHelp();
        }
        return;
    }

    // 处理 test 命令
    if (std.mem.eql(u8, cmd, "test")) {
        const config_path = parseConfigPathArg(args, 2);

        var cfg = loadAndValidateConfig(allocator, config_path, null, !json_output, &override_opts, "test") catch |err| {
            if (printOverrideRuntimeError(json_output, err)) return err;
            return err;
        };
        defer cfg.deinit();

        try test_cli.testProxy(allocator, &cfg, null);
        return;
    }

    // 处理 doctor 命令
    if (std.mem.eql(u8, cmd, "doctor")) {
        const config_path = parseConfigPathArg(args, 2);
        var cfg_check = loadRawConfigForDoctor(allocator, config_path) catch |err| {
            if (printOverrideRuntimeError(json_output, err)) return err;
            if (json_output) {
                printCliError(true, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config and retry `zc doctor --json`");
            }
            return err;
        };
        defer cfg_check.deinit();

        var persisted_script: ?[]u8 = null;
        defer if (persisted_script) |p| allocator.free(p);
        var effective_override = resolveEffectiveOverrideOptions(
            allocator,
            &override_opts,
            config_path,
            &persisted_script,
        ) catch |err| {
            if (printOverrideRuntimeError(json_output, err)) return err;
            if (json_output) {
                printCliError(true, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config and retry `zc doctor --json`");
            }
            return err;
        };

        override.apply(allocator, &cfg_check, &effective_override, "doctor", config_path) catch |err| {
            if (printOverrideRuntimeError(json_output, err)) return err;
            if (json_output) {
                printCliError(true, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config and retry `zc doctor --json`");
            }
            return err;
        };

        if (json_output) {
            doctor_cli.runDoctorJsonWithConfig(allocator, &cfg_check, config_path) catch |err| {
                printCliError(true, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config and retry `zc doctor --json`");
                return err;
            };
        } else {
            try doctor_cli.runDoctorWithConfig(allocator, &cfg_check, config_path);
        }
        return;
    }

    // 处理 diag 子命令（doctor 别名）
    if (std.mem.eql(u8, cmd, "diag")) {
        if (args.len < 3) {
            if (json_output) {
                printCliError(json_output, "DIAG_SUBCOMMAND_UNKNOWN", "unknown diag subcommand", "use `zc diag --help` or `zc diag doctor [-c <config>] [--json]`");
            } else {
                try printDiagHelp();
            }
            return;
        }
        if (args.len >= 3 and isHelpArg(args[2])) {
            try printDiagHelp();
            return;
        }
        if (!std.mem.eql(u8, args[2], "doctor")) {
            printCliError(json_output, "DIAG_SUBCOMMAND_UNKNOWN", "unknown diag subcommand", "use `zc diag doctor [-c <config>] [--json]`");
            return;
        }
        if (containsHelpArg(args, 3)) {
            try printDiagDoctorHelp();
            return;
        }
        const config_path = parseConfigPathArg(args, 3);
        var cfg_check = loadRawConfigForDoctor(allocator, config_path) catch |err| {
            if (printOverrideRuntimeError(json_output, err)) return err;
            if (json_output) {
                printCliError(true, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config and retry `zc diag doctor --json`");
            }
            return err;
        };
        defer cfg_check.deinit();

        var persisted_script: ?[]u8 = null;
        defer if (persisted_script) |p| allocator.free(p);
        var effective_override = resolveEffectiveOverrideOptions(
            allocator,
            &override_opts,
            config_path,
            &persisted_script,
        ) catch |err| {
            if (printOverrideRuntimeError(json_output, err)) return err;
            if (json_output) {
                printCliError(true, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config and retry `zc diag doctor --json`");
            }
            return err;
        };

        override.apply(allocator, &cfg_check, &effective_override, "diag.doctor", config_path) catch |err| {
            if (printOverrideRuntimeError(json_output, err)) return err;
            if (json_output) {
                printCliError(true, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config and retry `zc diag doctor --json`");
            }
            return err;
        };

        if (json_output) {
            doctor_cli.runDoctorJsonWithConfig(allocator, &cfg_check, config_path) catch |err| {
                printCliError(true, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config and retry `zc diag doctor --json`");
                return err;
            };
        } else {
            try doctor_cli.runDoctorWithConfig(allocator, &cfg_check, config_path);
        }
        return;
    }

    // 未知命令
    if (json_output) {
        printCliError(true, "COMMAND_UNKNOWN", "unknown command", "use `zc help` to list supported commands");
    } else {
        std.debug.print("Unknown command: {s}\n", .{cmd});
        try printHelp();
    }
    std.process.exit(1);
}

fn importLocalProfile(allocator: std.mem.Allocator, source: []const u8, import_name: ?[]const u8) !?[]const u8 {
    const src_abs = compat.fs.cwd().realpathAlloc(allocator, source) catch {
        return error.FileNotFound;
    };
    defer allocator.free(src_abs);

    const config_dir = (try config.getDefaultConfigDir(allocator)) orelse return error.NoConfigDir;
    defer allocator.free(config_dir);

    compat.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const basename = compat.fs.path.basename(src_abs);
    const raw_name = import_name orelse basename;
    const final_name = if (std.mem.endsWith(u8, raw_name, ".yaml"))
        try allocator.dupe(u8, raw_name)
    else
        try std.fmt.allocPrint(allocator, "{s}.yaml", .{raw_name});

    const dst_abs = try compat.fs.path.join(allocator, &.{ config_dir, final_name });
    defer allocator.free(dst_abs);

    try compat.fs.copyFileAbsolute(src_abs, dst_abs, .{});
    return final_name;
}

fn resolveProfileConfig(allocator: std.mem.Allocator, target: ?[]const u8) !config.Config {
    if (target == null) {
        return try config.loadDefault(allocator);
    }

    const t = target.?;
    if (std.mem.indexOfScalar(u8, t, '/')) |_| {
        return try config.load(allocator, t);
    }

    const config_dir = (try config.getDefaultConfigDir(allocator)) orelse return error.NoConfigDir;
    defer allocator.free(config_dir);

    const profile_path = try compat.fs.path.join(allocator, &.{ config_dir, t });
    defer allocator.free(profile_path);

    return try config.load(allocator, profile_path);
}

fn printValidationJson(allocator: std.mem.Allocator, vr: *const validator.ValidationResult) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"ok\":true,\"data\":{\"valid\":");
    try out.appendSlice(allocator, if (vr.isValid()) "true" else "false");
    try out.appendSlice(allocator, ",\"warnings\":[");

    for (vr.warnings.items, 0..) |w, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, w.message);
        try out.appendSlice(allocator, "\"");
    }

    try out.appendSlice(allocator, "],\"errors\":[");
    for (vr.errors.items, 0..) |e, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, e.message);
        try out.appendSlice(allocator, "\"");
    }

    try out.appendSlice(allocator, "]}}\n");
    std.debug.print("{s}", .{out.items});
}

fn switchProfileSilent(allocator: std.mem.Allocator, filename: []const u8) !void {
    const config_dir = (try config.getDefaultConfigDir(allocator)) orelse return error.NoConfigDir;
    defer allocator.free(config_dir);

    const source_path = try compat.fs.path.join(allocator, &.{ config_dir, filename });
    defer allocator.free(source_path);

    const link_path = try compat.fs.path.join(allocator, &.{ config_dir, "config.yaml" });
    defer allocator.free(link_path);

    compat.fs.deleteFileAbsolute(link_path) catch {};

    compat.fs.symLinkAbsolute(source_path, link_path, .{}) catch |err| {
        if (err == error.AccessDenied or err == error.NotSupported or err == error.InvalidArgument) {
            try compat.fs.copyFileAbsolute(source_path, link_path, .{});
        } else {
            try compat.fs.copyFileAbsolute(source_path, link_path, .{});
        }
    };
}

fn profileExists(allocator: std.mem.Allocator, name: []const u8) !bool {
    const config_dir = (try config.getDefaultConfigDir(allocator)) orelse return false;
    defer allocator.free(config_dir);

    const profile_path = try compat.fs.path.join(allocator, &.{ config_dir, name });
    defer allocator.free(profile_path);

    compat.fs.accessAbsolute(profile_path, .{}) catch return false;
    return true;
}

fn printProfileListJson(allocator: std.mem.Allocator) !void {
    const config_dir = (try config.getDefaultConfigDir(allocator)) orelse {
        printCliError(true, "PROFILE_LIST_FAILED", "could not determine config directory", "check HOME and retry `zc profile list`");
        return error.NoConfigDir;
    };
    defer allocator.free(config_dir);

    var dir = compat.fs.openDirAbsolute(config_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("{{\"ok\":true,\"data\":{{\"profiles\":[],\"active\":null}}}}\n", .{});
            return;
        }
        printCliError(true, "PROFILE_LIST_FAILED", "failed to open config directory", "ensure ~/.config/zc exists and is readable");
        return err;
    };
    defer dir.close();

    const active_path = try compat.fs.path.join(allocator, &.{ config_dir, "config.yaml" });
    defer allocator.free(active_path);

    var active_buf: [compat.fs.max_path_bytes]u8 = undefined;
    var active_name: ?[]const u8 = null;

    if (compat.fs.accessAbsolute(active_path, .{})) |_| {
        if (compat.fs.readLinkAbsolute(active_path, &active_buf)) |target| {
            active_name = compat.fs.path.basename(target);
        } else |_| {
            active_name = "config.yaml";
        }
    } else |_| {}

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"ok\":true,\"data\":{\"profiles\":[");

    var it = dir.iterate();
    var first = true;
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".yaml")) {
            if (!first) try out.appendSlice(allocator, ",");
            first = false;
            try out.appendSlice(allocator, "\"");
            try out.appendSlice(allocator, entry.name);
            try out.appendSlice(allocator, "\"");
        }
    }

    try out.appendSlice(allocator, "],\"active\":");
    if (active_name) |a| {
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, a);
        try out.appendSlice(allocator, "\"");
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, "}}\n");

    std.debug.print("{s}", .{out.items});
}

fn loadRawConfigForDoctor(allocator: std.mem.Allocator, config_path: ?[]const u8) !config.Config {
    if (config_path) |path| {
        return config.load(allocator, path);
    }
    return config.loadDefault(allocator);
}

fn printCliError(json_output: bool, code: []const u8, message: []const u8, hint: []const u8) void {
    if (json_output) {
        std.debug.print(
            "{{\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\",\"hint\":\"{s}\"}}}}\n",
            .{ code, message, hint },
        );
        return;
    }

    std.debug.print("error.code={s}\n", .{code});
    std.debug.print("error.message={s}\n", .{message});
    std.debug.print("error.hint={s}\n", .{hint});
}

fn printCliOk(json_output: bool, action: []const u8, state: []const u8, detail: ?[]const u8, pid: ?i32) void {
    if (json_output) {
        if (detail) |d| {
            if (pid) |p| {
                std.debug.print(
                    "{{\"ok\":true,\"data\":{{\"action\":\"{s}\",\"state\":\"{s}\",\"detail\":\"{s}\",\"pid\":{d}}}}}\n",
                    .{ action, state, d, p },
                );
            } else {
                std.debug.print(
                    "{{\"ok\":true,\"data\":{{\"action\":\"{s}\",\"state\":\"{s}\",\"detail\":\"{s}\"}}}}\n",
                    .{ action, state, d },
                );
            }
        } else if (pid) |p| {
            std.debug.print(
                "{{\"ok\":true,\"data\":{{\"action\":\"{s}\",\"state\":\"{s}\",\"pid\":{d}}}}}\n",
                .{ action, state, p },
            );
        } else {
            std.debug.print(
                "{{\"ok\":true,\"data\":{{\"action\":\"{s}\",\"state\":\"{s}\"}}}}\n",
                .{ action, state },
            );
        }
        return;
    }

    if (detail) |d| {
        if (pid) |p| {
            std.debug.print("ok action={s} state={s} detail={s} pid={d}\n", .{ action, state, d, p });
        } else {
            std.debug.print("ok action={s} state={s} detail={s}\n", .{ action, state, d });
        }
    } else if (pid) |p| {
        std.debug.print("ok action={s} state={s} pid={d}\n", .{ action, state, p });
    } else {
        std.debug.print("ok action={s} state={s}\n", .{ action, state });
    }
}

fn printOverrideOptionError(json_output: bool, err: anyerror) void {
    switch (err) {
        error.MissingOverrideScriptPath => printCliError(json_output, "OVERRIDE_SCRIPT_NOT_FOUND", "missing --override-script path", "use `--override-script <path>`"),
        error.InvalidOverrideTimeout => printCliError(json_output, "OVERRIDE_SCRIPT_TIMEOUT", "invalid --override-timeout-ms value", "use a positive integer, e.g. `--override-timeout-ms 500`"),
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

fn validateOverrideAndPrepareRuleProviders(allocator: std.mem.Allocator, script_path: []const u8) !void {
    var cfg = try config.loadDefault(allocator);
    defer cfg.deinit();

    var opts = override.CliOptions{};
    opts.script_path = try allocator.dupe(u8, script_path);
    defer opts.deinit(allocator);

    try override.apply(allocator, &cfg, &opts, "config.override.set", null);
    try config.prepareRuleProvidersForRuntime(allocator, &cfg, null);
}

fn applyConfigOverrideToRunningDaemon(allocator: std.mem.Allocator, json_output: bool) !void {
    if (!try daemon.isRunning(allocator)) return;
    _ = try daemon.reloadOrRestart(allocator, null, json_output, .auto);
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn parseConfigPathArg(args: []const []const u8, start_index: usize) ?[]const u8 {
    var i: usize = start_index;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

fn parseConfigOverrideAction(args: []const []const u8, start_index: usize) !ConfigOverrideAction {
    var clear = false;
    var script_path: ?[]const u8 = null;

    var i: usize = start_index;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) continue;
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

fn runProxy(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    mixed_port_override: ?u16,
    override_opts: *const override.CliOptions,
    command_name: []const u8,
) !void {
    std.debug.print("zc v{s}\n", .{build_options.version});

    // 保存配置路径用于重载
    if (config_path) |path| {
        g_config_path = try allocator.dupe(u8, path);
    }

    // 加载并验证配置
    var cfg = try loadAndValidateConfig(allocator, config_path, mixed_port_override, true, override_opts, command_name);
    defer cfg.deinit();

    // 启动前端口占用预检（可能修改 external-controller 端口）
    try preflightPortCheck(&cfg, true);

    // 获取运行时配置 key（优先显式 -c 路径，其次 active/default）
    const config_key = config.resolveRuntimeConfigKey(allocator, config_path) catch null;
    defer if (config_key) |k| allocator.free(k);

    // Initialize outbound manager with config key
    var manager = try outbound.OutboundManager.initWithKey(allocator, &cfg, config_key);
    defer manager.deinit();

    // 从 meta.json 恢复持久化的节点选择
    manager.loadPersistedSelections();

    // Initialize rule engine
    var engine = try rule_engine.Engine.init(allocator, &cfg.rules);
    defer engine.deinit();

    // Start proxy servers in background thread
    const proxy_thread = try std.Thread.spawn(.{}, proxyThreadFn, .{ allocator, &cfg, &engine, &manager });
    proxy_thread.detach();

    // Start API server if configured
    if (cfg.external_controller) |ec| {
        const port = try parseExternalControllerPort(ec);
        const api_thread = try std.Thread.spawn(.{}, apiThreadFn, .{ allocator, &cfg, &engine, &manager, port });
        api_thread.detach();
    }

    std.debug.print("Configuration loaded:\n", .{});
    std.debug.print("  Port: {}\n", .{cfg.port});
    std.debug.print("  SOCKS Port: {}\n", .{cfg.socks_port});
    std.debug.print("  Mixed Port: {}\n", .{cfg.mixed_port});
    std.debug.print("  Mode: {s}\n", .{cfg.mode});
    std.debug.print("  Proxies: {}\n", .{cfg.proxies.items.len});
    std.debug.print("  Rules: {}\n", .{cfg.rules.items.len});
    std.debug.print("\nProxy server running. Press Ctrl+C to stop.\n", .{});

    while (true) {
        compat.sleepNs(1 * std.time.ns_per_s);
    }
}

fn parseStartPortValue(text: []const u8) !u16 {
    const port = std.fmt.parseInt(u16, text, 10) catch return error.InvalidStartPort;
    if (port == 0) return error.InvalidStartPort;
    return port;
}

fn parseStartCommandOptions(args: []const []const u8, start_index: usize) !StartCommandOptions {
    var opts = StartCommandOptions{};
    var i = start_index;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-c")) {
            if (i + 1 >= args.len) return error.MissingConfigPath;
            opts.config_path = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--port")) {
            if (i + 1 >= args.len) return error.MissingPortValue;
            opts.port = try parseStartPortValue(args[i + 1]);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "--port=")) {
            opts.port = try parseStartPortValue(args[i]["--port=".len..]);
            continue;
        }
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

fn printStartCommandOptionError(json_output: bool, err: anyerror) void {
    switch (err) {
        error.MissingConfigPath => printCliError(json_output, "START_CONFIG_PATH_REQUIRED", "missing value for `-c`", "use `zc start -c <config>`"),
        error.MissingPortValue => printCliError(json_output, "START_PORT_REQUIRED", "missing value for `--port`", "use `zc start --port <1-65535>`"),
        error.InvalidStartPort => printCliError(json_output, "START_PORT_INVALID", "invalid `--port` value", "use an integer between 1 and 65535"),
        else => printCliError(json_output, "START_ARGS_INVALID", "invalid start arguments", "check `zc help`"),
    }
}

const CliErrorInfo = struct {
    code: []const u8,
    message: []const u8,
    hint: []const u8,
};

fn runtimeCommandPreflightErrorInfo(command: RuntimeCommand, err: anyerror) CliErrorInfo {
    return switch (command) {
        .start => switch (err) {
            error.PortAlreadyInUse => .{ .code = "START_PORT_IN_USE", .message = "requested start port is already in use", .hint = "retry with `zc start --port <free-port>`" },
            error.PortConflict => .{ .code = "START_PORT_CONFLICT", .message = "requested start port conflicts with another runtime listener", .hint = "change the port or fix the conflicting runtime config" },
            error.InvalidBindAddress => .{ .code = "START_BIND_ADDRESS_INVALID", .message = "invalid bind address for start preflight", .hint = "fix `bind-address` in config and retry" },
            error.InvalidExternalController => .{ .code = "START_EXTERNAL_CONTROLLER_INVALID", .message = "invalid `external-controller` address in config", .hint = "fix `external-controller` to `host:port` format" },
            else => .{ .code = "START_PREFLIGHT_FAILED", .message = "failed to validate daemon start ports", .hint = "check config and retry" },
        },
        .restart => switch (err) {
            error.PortAlreadyInUse => .{ .code = "RESTART_PORT_IN_USE", .message = "restart target port is already in use", .hint = "free the occupied port, then retry `zc restart` or use `zc start --port <free-port>`" },
            error.PortConflict => .{ .code = "RESTART_PORT_CONFLICT", .message = "restart target port conflicts with another runtime listener", .hint = "fix the conflicting runtime config before retrying `zc restart`" },
            error.InvalidBindAddress => .{ .code = "RESTART_BIND_ADDRESS_INVALID", .message = "invalid bind address for restart preflight", .hint = "fix `bind-address` in config and retry `zc restart`" },
            error.InvalidExternalController => .{ .code = "RESTART_EXTERNAL_CONTROLLER_INVALID", .message = "invalid `external-controller` address in config", .hint = "fix `external-controller` to `host:port` format before retrying `zc restart`" },
            else => .{ .code = "RESTART_PREFLIGHT_FAILED", .message = "failed to validate daemon restart ports", .hint = "check config and retry `zc restart`" },
        },
    };
}

fn printRuntimeCommandPreflightError(command: RuntimeCommand, json_output: bool, err: anyerror) void {
    const info = runtimeCommandPreflightErrorInfo(command, err);
    printCliError(json_output, info.code, info.message, info.hint);
}

fn runtimeCommandName(command: RuntimeCommand) []const u8 {
    return switch (command) {
        .start => "start",
        .restart => "restart",
    };
}

fn preflightRuntimeCommand(
    allocator: std.mem.Allocator,
    command: RuntimeCommand,
    start_opts: StartCommandOptions,
    override_opts: *const override.CliOptions,
) !void {
    var cfg = try loadRuntimeConfig(allocator, start_opts.config_path, start_opts.port, override_opts, runtimeCommandName(command), false);
    defer cfg.deinit();
    try preflightPortCheck(&cfg, false);
}

fn runRestartCommand(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    json_output: bool,
    override_opts: *const override.CliOptions,
    extra_args: []const []const u8,
) !void {
    const was_running = try daemon.isRunning(allocator);

    if (was_running) {
        try daemon.stopDaemon(allocator, json_output);
    }

    try preflightRuntimeCommand(allocator, .restart, .{ .config_path = config_path }, override_opts);

    if (!was_running) {
        printCliOk(json_output, "restart", "stopped", "service_was_stopped", null);
    }

    try daemon.startDaemon(allocator, config_path, json_output, extra_args);
    const pid = try daemon.readPid(allocator) orelse {
        printCliError(json_output, "RESTART_FAILED", "daemon did not become trackable after restart", "check `zc status` and `zc log --no-follow` for recovery details");
        return error.StartFailed;
    };
    printCliOk(json_output, "restart", "running", null, pid);
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

fn ruleProviderSyncPolicyForCommand(command_name: []const u8) config.RuleProviderSyncPolicy {
    if (std.mem.eql(u8, command_name, "test")) return .missing_only;
    return .eager;
}

fn loadRuntimeConfig(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    mixed_port_override: ?u16,
    override_opts: *const override.CliOptions,
    command_name: []const u8,
    prepare_runtime_artifacts: bool,
) !config.Config {
    var cfg = if (config_path) |path|
        try config.load(allocator, path)
    else
        try config.loadDefault(allocator);
    errdefer cfg.deinit();

    // 默认统一走 mixed-port，必要时允许 `zc start --port <n>` 覆盖本次 daemon 端口。
    cfg.mixed_port = constants.MIXED_PORT;
    cfg.port = 0;
    cfg.socks_port = 0;

    var persisted_script: ?[]u8 = null;
    defer if (persisted_script) |p| allocator.free(p);
    var effective_override = try resolveEffectiveOverrideOptions(
        allocator,
        override_opts,
        config_path,
        &persisted_script,
    );

    try override.apply(allocator, &cfg, &effective_override, command_name, config_path);
    applyRuntimePortSelection(&cfg, mixed_port_override);
    if (prepare_runtime_artifacts) {
        try config.prepareRuleProvidersForRuntimeWithPolicy(
            allocator,
            &cfg,
            config_path,
            ruleProviderSyncPolicyForCommand(command_name),
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
) !config.Config {
    var cfg = try loadRuntimeConfig(allocator, config_path, mixed_port_override, override_opts, command_name, true);
    errdefer cfg.deinit();

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

fn proxyThreadFn(allocator: std.mem.Allocator, cfg: *const config.Config, engine: *rule_engine.Engine, manager: *outbound.OutboundManager) void {
    compat.sleepNs(100 * std.time.ns_per_ms);

    const bind_ip = effectiveBindAddress(cfg);

    if (cfg.mixed_port > 0) {
        std.debug.print("Starting mixed proxy on {s}:{}\n", .{ bind_ip, cfg.mixed_port });
        mixed_proxy.start(allocator, bind_ip, cfg.mixed_port, engine, manager) catch |err| {
            std.debug.print("Mixed proxy fatal error: {}\n", .{err});
            std.process.exit(1);
        };
        return;
    }

    var http_thread: ?std.Thread = null;
    var socks_thread: ?std.Thread = null;

    if (cfg.port > 0) {
        std.debug.print("Starting HTTP proxy on {s}:{}\n", .{ bind_ip, cfg.port });
        http_thread = std.Thread.spawn(.{}, httpThreadFn, .{ allocator, bind_ip, cfg.port, engine, manager }) catch |err| {
            std.debug.print("Failed to start HTTP proxy thread: {}\n", .{err});
            std.process.exit(1);
        };
    }

    if (cfg.socks_port > 0) {
        std.debug.print("Starting SOCKS5 proxy on {s}:{}\n", .{ bind_ip, cfg.socks_port });
        socks_thread = std.Thread.spawn(.{}, socksThreadFn, .{ allocator, bind_ip, cfg.socks_port, engine, manager }) catch |err| {
            std.debug.print("Failed to start SOCKS5 proxy thread: {}\n", .{err});
            std.process.exit(1);
        };
    }

    if (http_thread) |t| t.join();
    if (socks_thread) |t| t.join();
}

fn apiThreadFn(allocator: std.mem.Allocator, cfg: *const config.Config, engine: *rule_engine.Engine, manager: *outbound.OutboundManager, port: u16) void {
    var api_server = api.ApiServer.init(allocator, cfg, engine, manager, port);
    api_server.start() catch |err| {
        std.debug.print("API server fatal error: {}\n", .{err});
        std.process.exit(1);
    };
}

fn httpThreadFn(allocator: std.mem.Allocator, bind_ip: []const u8, port: u16, engine: *rule_engine.Engine, manager: *outbound.OutboundManager) void {
    http_proxy.start(allocator, bind_ip, port, engine, manager) catch |err| {
        std.debug.print("HTTP proxy fatal error: {}\n", .{err});
        std.process.exit(1);
    };
}

fn socksThreadFn(allocator: std.mem.Allocator, bind_ip: []const u8, port: u16, engine: *rule_engine.Engine, manager: *outbound.OutboundManager) void {
    socks5_proxy.start(allocator, bind_ip, port, engine, manager) catch |err| {
        std.debug.print("SOCKS5 proxy fatal error: {}\n", .{err});
        std.process.exit(1);
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

fn preflightPortCheck(cfg: *config.Config, emit_errors: bool) !void {
    const bind_ip = effectiveBindAddress(cfg);

    // 进程内端口冲突检查
    if (try hasInProcessPortConflict(cfg)) {
        if (emit_errors) std.debug.print("Port precheck failed: in-process port conflict detected\n", .{});
        return error.PortConflict;
    }

    // 系统端口占用检查
    if (cfg.mixed_port > 0) {
        try checkPortAvailable(bind_ip, cfg.mixed_port, emit_errors);
    } else {
        if (cfg.port > 0) try checkPortAvailable(bind_ip, cfg.port, emit_errors);
        if (cfg.socks_port > 0) try checkPortAvailable(bind_ip, cfg.socks_port, emit_errors);
    }

    // external-controller 端口：被占用时自动尝试 port+1..+10
    if (cfg.external_controller) |ec| {
        const original_port = try parseExternalControllerPort(ec);
        if (isPortAvailable("127.0.0.1", original_port)) return;

        // 原始端口被占用，尝试 fallback
        var fallback_port: u16 = original_port;
        var found = false;
        for (1..11) |offset| {
            const try_port = original_port +| @as(u16, @intCast(offset));
            if (try_port <= original_port) break; // overflow
            if (isPortAvailable("127.0.0.1", try_port)) {
                fallback_port = try_port;
                found = true;
                break;
            }
        }

        if (found) {
            std.debug.print("external-controller: {d} in use, using {d}\n", .{ original_port, fallback_port });
            // 更新 cfg.external_controller 为新端口
            const new_ec = std.fmt.allocPrint(cfg.allocator, "127.0.0.1:{d}", .{fallback_port}) catch return;
            cfg.allocator.free(cfg.external_controller.?);
            cfg.external_controller = new_ec;
        } else {
            std.debug.print("warning: external-controller port {d}-{d} all in use, skipping API server\n", .{ original_port, original_port +| 10 });
            cfg.allocator.free(cfg.external_controller.?);
            cfg.external_controller = null;
        }
    }
}

fn isPortAvailable(ip: []const u8, port: u16) bool {
    const address = compat.net.Address.parseIp4(ip, port) catch return false;
    var server = address.listen(.{ .reuse_address = false }) catch return false;
    server.deinit();
    return true;
}

fn checkPortAvailable(ip: []const u8, port: u16, emit_errors: bool) !void {
    const address = compat.net.Address.parseIp4(ip, port) catch {
        if (emit_errors) std.debug.print("Invalid bind-address '{s}'\n", .{ip});
        return error.InvalidBindAddress;
    };

    var server = address.listen(.{ .reuse_address = false }) catch {
        if (emit_errors) std.debug.print("Port precheck failed: {s}:{d} is already in use\n", .{ ip, port });
        return error.PortAlreadyInUse;
    };
    server.deinit();
}

fn parseExternalControllerPort(ec: []const u8) !u16 {
    const colon_pos = std.mem.lastIndexOf(u8, ec, ":") orelse {
        return error.InvalidExternalController;
    };

    const port = std.fmt.parseInt(u16, ec[colon_pos + 1 ..], 10) catch {
        return error.InvalidExternalController;
    };

    if (port == 0) return error.InvalidExternalController;
    return port;
}

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or
        std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "--help");
}

fn containsHelpArg(args: []const []const u8, start: usize) bool {
    var i = start;
    while (i < args.len) : (i += 1) {
        if (isHelpArg(args[i])) return true;
    }
    return false;
}

fn printHelpTopic(topic: []const u8) !void {
    if (std.mem.eql(u8, topic, "config")) {
        try printConfigHelp();
    } else if (std.mem.eql(u8, topic, "proxy")) {
        try printProxyHelp();
    } else if (std.mem.eql(u8, topic, "profile")) {
        try printProfileHelp();
    } else if (std.mem.eql(u8, topic, "diag") or std.mem.eql(u8, topic, "doctor")) {
        try printDiagHelp();
    } else {
        std.debug.print("Unknown help topic: {s}\n", .{topic});
        try printHelp();
    }
}

fn printHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("zc v{s} - A high-performance proxy tool in Zig\n", .{build_options.version});
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc <command> [options]\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("COMMANDS:\n", .{});
    std.debug.print("    help                    Show this help message\n", .{});
    std.debug.print("    start [-c <config>] [--port <port>]\n", .{});
    std.debug.print("                            Start proxy in background\n", .{});
    std.debug.print("    stop                    Stop proxy\n", .{});
    std.debug.print("    restart [-c <config>]   Restart proxy\n", .{});
    std.debug.print("    status                  Show proxy status\n", .{});
    std.debug.print("    log [-n <lines>]        View logs\n", .{});
    std.debug.print("    config <subcmd>         Manage configurations\n", .{});
    std.debug.print("    proxy <subcmd>          Manage proxies\n", .{});
    std.debug.print("    profile <subcmd>        Alias for proxy profile operations\n", .{});
    std.debug.print("    test [-c <config>]      Test network connectivity\n", .{});
    std.debug.print("    doctor [-c <config>]    Diagnose config/service/ports\n", .{});
    std.debug.print("    diag <subcmd>           Diagnostic command group\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("HELP TOPICS:\n", .{});
    std.debug.print("    zc help config | zc config --help\n", .{});
    std.debug.print("    zc help proxy  | zc proxy --help\n", .{});
    std.debug.print("    zc help profile | zc profile --help\n", .{});
    std.debug.print("    zc help diag   | zc diag --help\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("OVERRIDE OPTIONS (for config-loading commands):\n", .{});
    std.debug.print("    --override-script <path>       Run override script (lua returns table, or executable prints YAML)\n", .{});
    std.debug.print("    --override-arg <k=v>           Pass key/value to override script (repeatable)\n", .{});
    std.debug.print("    --override-timeout-ms <n>      Override script timeout in milliseconds (default: 500)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("CONFIG COMMANDS:\n", .{});
    std.debug.print("    zc config list                  List all available configs\n", .{});
    std.debug.print("    zc config ls                    Alias for list\n", .{});
    std.debug.print("    zc config download <url>        Download config from URL\n", .{});
    std.debug.print("                            -n <name>   Config filename (default: timestamp)\n", .{});
    std.debug.print("                            -d          Set as default after download\n", .{});
    std.debug.print("    zc config update [<name>]       Update downloaded config\n", .{});
    std.debug.print("                            --apply <auto|hot|restart>\n", .{});
    std.debug.print("    zc config use <configname>     Switch to specified config\n", .{});
    std.debug.print("    zc config dump [-c <config>] [--no-override]\n", .{});
    std.debug.print("                               Print merged config (YAML default, JSON with --json)\n", .{});
    std.debug.print("    zc config override [script|--clear]\n", .{});
    std.debug.print("                               Bind/clear persisted override for current config\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("PROXY COMMANDS:\n", .{});
    std.debug.print("    zc proxy list                   List all proxy groups and nodes\n", .{});
    std.debug.print("    zc proxy ls                     Alias for list\n", .{});
    std.debug.print("    zc proxy select                 Show proxy selection UI\n", .{});
    std.debug.print("    zc proxy select -g <group>      Select proxy for specific group\n", .{});
    std.debug.print("    zc proxy select -g <group>      Select specific proxy\n", .{});
    std.debug.print("              -p <proxy>\n", .{});
    std.debug.print("    zc proxy test [-c <config>]     Test configured proxy connectivity\n", .{});
    std.debug.print("EXAMPLES:\n", .{});
    std.debug.print("    # Start proxy in background\n", .{});
    std.debug.print("    zc start\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # Start with specific config\n", .{});
    std.debug.print("    zc start -c /path/to/config.yaml\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # Start with an explicit mixed port for local development\n", .{});
    std.debug.print("    zc start --port 7901\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # Check status\n", .{});
    std.debug.print("    zc status\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # View logs (default: last 50 lines, auto-refresh)\n", .{});
    std.debug.print("    zc log\n", .{});
    std.debug.print("    zc log -n 100              # Show last 100 lines\n", .{});
    std.debug.print("    zc log --no-follow         # Show last 50 lines without refresh\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # Download a config\n", .{});
    std.debug.print("    zc config download https://example.com/config.yaml\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # Download and set as default\n", .{});
    std.debug.print("    zc config download https://example.com/config.yaml -n myconfig -d\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # List all configs\n", .{});
    std.debug.print("    zc config list\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # Switch config\n", .{});
    std.debug.print("    zc config use myconfig.yaml\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # Bind persisted override to current config\n", .{});
    std.debug.print("    zc config override ./override.lua\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # Dump merged config as YAML\n", .{});
    std.debug.print("    zc config dump\n", .{});
    std.debug.print("    zc config dump --no-override\n", .{});
    std.debug.print("\n", .{});
}

fn printConfigHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("zc config - Manage configurations\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc config list                  List all available configs\n", .{});
    std.debug.print("    zc config ls                    Alias for list\n", .{});
    std.debug.print("    zc config download <url>        Download config from URL\n", .{});
    std.debug.print("                            -n <name>   Config filename (default: timestamp)\n", .{});
    std.debug.print("                            -d          Set as default after download\n", .{});
    std.debug.print("    zc config update [<name>]       Update downloaded config\n", .{});
    std.debug.print("                            --apply <auto|hot|restart>\n", .{});
    std.debug.print("    zc config use <configname>     Switch to specified config\n", .{});
    std.debug.print("    zc config dump [-c <config>] [--no-override]\n", .{});
    std.debug.print("    zc config override [script|--clear]\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("EXAMPLES:\n", .{});
    std.debug.print("    zc config download https://example.com/config.yaml\n", .{});
    std.debug.print("    zc config download https://example.com/config.yaml -n myconfig -d\n", .{});
    std.debug.print("    zc config update --apply auto\n", .{});
    std.debug.print("    zc config list\n", .{});
    std.debug.print("    zc config use myconfig.yaml\n", .{});
    std.debug.print("    zc config dump\n", .{});
    std.debug.print("    zc config dump --no-override\n", .{});
    std.debug.print("    zc config override ./override.lua\n", .{});
    std.debug.print("    zc config override --clear\n", .{});
    std.debug.print("\n", .{});
}

fn printProxyHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("zc proxy - Manage proxies\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc proxy list                   List all proxy groups and nodes\n", .{});
    std.debug.print("    zc proxy ls                     Alias for list\n", .{});
    std.debug.print("    zc proxy select                 Show proxy selection UI\n", .{});
    std.debug.print("    zc proxy select -g <group>      Select proxy for specific group\n", .{});
    std.debug.print("    zc proxy select -g <group>      Select specific proxy\n", .{});
    std.debug.print("              -p <proxy>\n", .{});
    std.debug.print("    zc proxy test [-c <config>]     Test configured proxy connectivity\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("EXAMPLES:\n", .{});
    std.debug.print("    zc proxy list\n", .{});
    std.debug.print("    zc proxy select                 # Show selection UI\n", .{});
    std.debug.print("    zc proxy select -g Proxy -p HK  # Select HK in Proxy group\n", .{});
    std.debug.print("    zc proxy test\n", .{});
    std.debug.print("\n", .{});
}

fn printConfigListHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc config list\n", .{});
    std.debug.print("    zc config ls\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("List all locally downloaded configs.\n", .{});
    std.debug.print("\n", .{});
}

fn printConfigDownloadHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc config download <url> [-n <name>]\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("OPTIONS:\n", .{});
    std.debug.print("    -n <name>    Config filename/display name\n", .{});
    std.debug.print("\n", .{});
}

fn printConfigUpdateHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc config update [<name>] [--apply <auto|hot|restart>]\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("OPTIONS:\n", .{});
    std.debug.print("    <name>                 Config name to update (default: active config)\n", .{});
    std.debug.print("    --apply auto           Apply hot reload when possible, restart when needed\n", .{});
    std.debug.print("    --apply hot            Require hot reload\n", .{});
    std.debug.print("    --apply restart        Restart daemon after update\n", .{});
    std.debug.print("\n", .{});
}

fn printConfigUseHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc config use <name>\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Switch the active config.\n", .{});
    std.debug.print("\n", .{});
}

fn printConfigDumpHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc config dump [-c <config>] [--no-override] [--json]\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("OPTIONS:\n", .{});
    std.debug.print("    -c <config>       Config file/key to dump\n", .{});
    std.debug.print("    --no-override     Skip persisted or CLI override script\n", .{});
    std.debug.print("    --json            Print JSON instead of YAML\n", .{});
    std.debug.print("\n", .{});
}

fn printConfigOverrideHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc config override [<script.lua>|--clear] [--json]\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Bind, clear, or show the persisted override script for the active config.\n", .{});
    std.debug.print("\n", .{});
}

fn printProxyListHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc proxy list [-c <config>] [--json]\n", .{});
    std.debug.print("    zc proxy ls [-c <config>] [--json]\n", .{});
    std.debug.print("\n", .{});
}

fn printProfileListHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc profile list [-c <config>] [--json]\n", .{});
    std.debug.print("    zc profile ls [-c <config>] [--json]\n", .{});
    std.debug.print("\n", .{});
}

fn printProxySelectHelp(group: []const u8) !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc {s} select [-c <config>] [-g <group>] [-p <proxy>] [--json]\n", .{group});
    std.debug.print("\n", .{});
    std.debug.print("OPTIONS:\n", .{});
    std.debug.print("    -c <config>    Config file/key to inspect\n", .{});
    std.debug.print("    -g <group>     Proxy group name\n", .{});
    std.debug.print("    -p <proxy>     Proxy name to select\n", .{});
    std.debug.print("\n", .{});
}

fn printProxyTestHelp(group: []const u8) !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc {s} test [-c <config>] [--json]\n", .{group});
    std.debug.print("\n", .{});
    std.debug.print("Test configured proxy connectivity through the effective local port.\n", .{});
    std.debug.print("\n", .{});
}

fn printProfileHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("zc profile - Manage proxy profiles\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc profile list                 List all proxy groups and nodes\n", .{});
    std.debug.print("    zc profile ls                   Alias for list\n", .{});
    std.debug.print("    zc profile select               Show proxy selection UI\n", .{});
    std.debug.print("    zc profile select -g <group>    Select proxy for specific group\n", .{});
    std.debug.print("    zc profile select -g <group>    Select specific proxy\n", .{});
    std.debug.print("                -p <proxy>\n", .{});
    std.debug.print("    zc profile test [-c <config>]   Test configured proxy connectivity\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("EXAMPLES:\n", .{});
    std.debug.print("    zc profile list\n", .{});
    std.debug.print("    zc profile select -g Proxy -p HK\n", .{});
    std.debug.print("    zc profile test\n", .{});
    std.debug.print("\n", .{});
}

fn printDiagHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("zc diag - Diagnostics\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc diag doctor [-c <config>] [--json]\n", .{});
    std.debug.print("                               Diagnose config, service state, and ports\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("EXAMPLES:\n", .{});
    std.debug.print("    zc diag doctor\n", .{});
    std.debug.print("    zc diag doctor --json\n", .{});
    std.debug.print("\n", .{});
}

fn printDiagDoctorHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc diag doctor [-c <config>] [--json]\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Diagnose config validity, daemon state, and local port availability.\n", .{});
    std.debug.print("\n", .{});
}

test "parseExternalControllerPort valid and invalid" {
    const testing = std.testing;

    try testing.expectEqual(@as(u16, 9090), try parseExternalControllerPort("127.0.0.1:9090"));
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

test "parseConfigPathArg handles -c" {
    const testing = std.testing;

    const args = [_][]const u8{ "zc", "test", "-c", "./x.yaml" };
    try testing.expectEqualStrings("./x.yaml", parseConfigPathArg(args[0..], 2).?);

    const args2 = [_][]const u8{ "zc", "test" };
    try testing.expect(parseConfigPathArg(args2[0..], 2) == null);
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
    const opts = try parseStartCommandOptions(args[0..], 2);
    try testing.expectEqualStrings("./x.yaml", opts.config_path.?);
    try testing.expectEqual(@as(?u16, 7901), opts.port);

    const args2 = [_][]const u8{ "zc", "start", "--port=7902" };
    const opts2 = try parseStartCommandOptions(args2[0..], 2);
    try testing.expect(opts2.config_path == null);
    try testing.expectEqual(@as(?u16, 7902), opts2.port);
}

test "parseStartCommandOptions rejects missing or invalid port values" {
    const testing = std.testing;

    const missing_port = [_][]const u8{ "zc", "start", "--port" };
    try testing.expectError(error.MissingPortValue, parseStartCommandOptions(missing_port[0..], 2));

    const invalid_port = [_][]const u8{ "zc", "start", "--port", "abc" };
    try testing.expectError(error.InvalidStartPort, parseStartCommandOptions(invalid_port[0..], 2));

    const zero_port = [_][]const u8{ "zc", "start", "--port=0" };
    try testing.expectError(error.InvalidStartPort, parseStartCommandOptions(zero_port[0..], 2));
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
    try testing.expectEqual(config.RuleProviderSyncPolicy.eager, ruleProviderSyncPolicyForCommand("start"));
    try testing.expectEqual(config.RuleProviderSyncPolicy.eager, ruleProviderSyncPolicyForCommand("proxy.test"));
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

test "runtimeCommandPreflightErrorInfo maps restart port conflicts" {
    const testing = std.testing;

    const info = runtimeCommandPreflightErrorInfo(.restart, error.PortAlreadyInUse);
    try testing.expectEqualStrings("RESTART_PORT_IN_USE", info.code);
    try testing.expectEqualStrings("restart target port is already in use", info.message);
    try testing.expect(std.mem.indexOf(u8, info.hint, "zc restart") != null);
}

test "restart command preflights ports before spawning a new daemon" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = try compat.fs.cwd().readFileAlloc(allocator, "src/main.zig", 1024 * 1024);
    defer allocator.free(content);

    const fn_pos = std.mem.indexOf(u8, content, "fn runRestartCommand(") orelse return error.TestUnexpectedResult;
    const next_fn_pos = std.mem.indexOfPos(u8, content, fn_pos, "fn applyRuntimePortSelection(") orelse return error.TestUnexpectedResult;
    const fn_body = content[fn_pos..next_fn_pos];

    const preflight_pos = std.mem.indexOf(u8, fn_body, "preflightRuntimeCommand(allocator, .restart") orelse return error.TestUnexpectedResult;
    const start_pos = std.mem.indexOf(u8, fn_body, "daemon.startDaemon(") orelse return error.TestUnexpectedResult;
    try testing.expect(preflight_pos < start_pos);
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
