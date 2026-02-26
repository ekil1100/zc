const std = @import("std");
const config = @import("config.zig");
const constants = @import("constants.zig");
const validator = @import("config_validator.zig");
const http_proxy = @import("proxy/http.zig");
const socks5_proxy = @import("proxy/socks5.zig");
const mixed_proxy = @import("proxy/mixed.zig");
const rule_engine = @import("rule/engine.zig");
const outbound = @import("proxy/outbound/manager.zig");
const api = @import("api/server.zig");
const tui = @import("tui.zig");
const daemon = @import("daemon.zig");
const proxy_cli = @import("proxy_cli.zig");
const test_cli = @import("test_cli.zig");
const doctor_cli = @import("doctor_cli.zig");
const build_options = @import("build_options");

// 全局配置路径，用于重载
var g_config_path: ?[]const u8 = null;
var gpa_holder: ?*std.heap.GeneralPurposeAllocator(.{}) = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    gpa_holder = &gpa;
    defer {
        if (g_config_path) |path| {
            gpa.allocator().free(path);
        }
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    // Parse command line args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // 检查是否有子命令
    if (args.len < 2) {
        // 无参数，显示帮助
        try printHelp();
        return;
    }

    const cmd = args[1];
    const json_output = hasFlag(args, "--json");

    // 处理 daemon 运行模式（内部使用）
    if (std.mem.eql(u8, cmd, "--daemon-run")) {
        var config_path: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-c")) {
                if (i + 1 < args.len) {
                    config_path = args[i + 1];
                    i += 1;
                }
            }
        }
        // 在 daemon 模式下运行代理（无 TUI）
        try runProxy(allocator, config_path, false);
        return;
    }

    // 处理 help
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        try printHelp();
        return;
    }

    // 处理 tui 命令
    if (std.mem.eql(u8, cmd, "tui")) {
        try runProxy(allocator, null, true);
        return;
    }

    // 处理 start 命令
    if (std.mem.eql(u8, cmd, "start")) {
        var config_path: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-c")) {
                if (i + 1 < args.len) {
                    config_path = args[i + 1];
                    i += 1;
                }
            }
        }
        // 后台启动
        daemon.startDaemon(allocator, config_path, json_output) catch |err| {
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
        var config_path: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-c")) {
                if (i + 1 < args.len) {
                    config_path = args[i + 1];
                    i += 1;
                }
            }
        }
        daemon.restartDaemon(allocator, config_path, json_output) catch |err| {
            printCliError(json_output, "RESTART_FAILED", "failed to restart daemon", "check logs and retry `zc restart -c <config>`");
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

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            try config.listConfigs(allocator);
            return;
        }

        if (std.mem.eql(u8, subcmd, "download")) {
            if (args.len < 4) {
                std.debug.print("Usage: zc config download <url> [-n <name>] [-d]\n", .{});
                return;
            }

            const url = args[3];
            var download_name: ?[]const u8 = null;
            var set_default = false;

            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-n")) {
                    if (i + 1 < args.len) {
                        download_name = args[i + 1];
                        i += 1;
                    }
                } else if (std.mem.eql(u8, args[i], "-d")) {
                    set_default = true;
                }
            }

            const filename = try config.downloadConfig(allocator, url, download_name);
            defer if (filename) |f| allocator.free(f);

            if (set_default and filename != null) {
                try config.switchConfig(allocator, filename.?);
            }
            return;
        }

        if (std.mem.eql(u8, subcmd, "update")) {
            var config_name: ?[]const u8 = null;

            if (args.len >= 4) {
                config_name = args[3];
            }

            const current_config = config.getCurrentConfigName(allocator) catch null;
            defer if (current_config) |c| allocator.free(c);

            const target_name = config_name orelse current_config orelse {
                std.debug.print("Usage: zc config update [<name>]\n", .{});
                std.debug.print("  <name>  Config name to update (default: current active config)\n", .{});
                return;
            };

            const filename = try config.updateConfig(allocator, target_name);
            defer if (filename) |f| allocator.free(f);

            if (filename) |f| {
                std.debug.print("Config updated: {s}\n", .{f});
            }
            return;
        }

        if (std.mem.eql(u8, subcmd, "use")) {
            if (args.len < 4) {
                std.debug.print("Usage: zc config use <name>\n", .{});
                return;
            }

            try config.switchConfig(allocator, args[3]);
            return;
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

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
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
            var cfg = loadAndValidateConfig(allocator, config_path, !json_output) catch |err| {
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
            var cfg = loadAndValidateConfig(allocator, config_path, !json_output) catch |err| {
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
            var config_path: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
                    config_path = args[i + 1];
                    i += 1;
                }
            }

            var cfg = loadAndValidateConfig(allocator, config_path, !json_output) catch |err| {
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
                printCliError(json_output, "PROFILE_SUBCOMMAND_MISSING", "profile subcommand is required", "use `zc profile list|use <name>`");
            } else {
                std.debug.print("Usage: zc profile list|use <name>\n", .{});
            }
            return;
        }

        const subcmd = args[2];

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
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
            var cfg = loadAndValidateConfig(allocator, config_path, !json_output) catch |err| {
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
            var cfg = loadAndValidateConfig(allocator, config_path, !json_output) catch |err| {
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
            var config_path: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
                    config_path = args[i + 1];
                    i += 1;
                }
            }

            var cfg = loadAndValidateConfig(allocator, config_path, !json_output) catch |err| {
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

    // 处理 test 命令
    if (std.mem.eql(u8, cmd, "test")) {
        const config_path = parseConfigPathArg(args, 2);

        var cfg = try loadAndValidateConfig(allocator, config_path, !json_output);
        defer cfg.deinit();

        try test_cli.testProxy(allocator, &cfg, null);
        return;
    }

    // 处理 doctor 命令
    if (std.mem.eql(u8, cmd, "doctor")) {
        const config_path = parseConfigPathArg(args, 2);
        if (json_output) {
            doctor_cli.runDoctorJson(allocator, config_path) catch |err| {
                printCliError(true, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config and retry `zc doctor --json`");
                return err;
            };
        } else {
            try doctor_cli.runDoctor(allocator, config_path);
        }
        return;
    }

    // 处理 diag 子命令（doctor 别名）
    if (std.mem.eql(u8, cmd, "diag")) {
        if (args.len < 3 or !std.mem.eql(u8, args[2], "doctor")) {
            printCliError(json_output, "DIAG_SUBCOMMAND_UNKNOWN", "unknown diag subcommand", "use `zc diag doctor [-c <config>] [--json]`");
            return;
        }
        const config_path = parseConfigPathArg(args, 3);
        if (json_output) {
            doctor_cli.runDoctorJson(allocator, config_path) catch |err| {
                printCliError(true, "DIAG_DOCTOR_FAILED", "failed to run doctor diagnostics", "check config and retry `zc diag doctor --json`");
                return err;
            };
        } else {
            try doctor_cli.runDoctor(allocator, config_path);
        }
        return;
    }

    // 未知命令
    std.debug.print("Unknown command: {s}\n", .{cmd});
    try printHelp();
}

fn importLocalProfile(allocator: std.mem.Allocator, source: []const u8, import_name: ?[]const u8) !?[]const u8 {
    const src_abs = std.fs.cwd().realpathAlloc(allocator, source) catch {
        return error.FileNotFound;
    };
    defer allocator.free(src_abs);

    const config_dir = (try config.getDefaultConfigDir(allocator)) orelse return error.NoConfigDir;
    defer allocator.free(config_dir);

    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const basename = std.fs.path.basename(src_abs);
    const raw_name = import_name orelse basename;
    const final_name = if (std.mem.endsWith(u8, raw_name, ".yaml"))
        try allocator.dupe(u8, raw_name)
    else
        try std.fmt.allocPrint(allocator, "{s}.yaml", .{raw_name});

    const dst_abs = try std.fs.path.join(allocator, &.{ config_dir, final_name });
    defer allocator.free(dst_abs);

    try std.fs.copyFileAbsolute(src_abs, dst_abs, .{});
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

    const profile_path = try std.fs.path.join(allocator, &.{ config_dir, t });
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

    const source_path = try std.fs.path.join(allocator, &.{ config_dir, filename });
    defer allocator.free(source_path);

    const link_path = try std.fs.path.join(allocator, &.{ config_dir, "config.yaml" });
    defer allocator.free(link_path);

    std.fs.deleteFileAbsolute(link_path) catch {};

    std.fs.symLinkAbsolute(source_path, link_path, .{}) catch |err| {
        if (err == error.AccessDenied or err == error.NotSupported or err == error.InvalidArgument) {
            try std.fs.copyFileAbsolute(source_path, link_path, .{});
        } else {
            try std.fs.copyFileAbsolute(source_path, link_path, .{});
        }
    };
}

fn profileExists(allocator: std.mem.Allocator, name: []const u8) !bool {
    const config_dir = (try config.getDefaultConfigDir(allocator)) orelse return false;
    defer allocator.free(config_dir);

    const profile_path = try std.fs.path.join(allocator, &.{ config_dir, name });
    defer allocator.free(profile_path);

    std.fs.accessAbsolute(profile_path, .{}) catch return false;
    return true;
}

fn printProfileListJson(allocator: std.mem.Allocator) !void {
    const config_dir = (try config.getDefaultConfigDir(allocator)) orelse {
        printCliError(true, "PROFILE_LIST_FAILED", "could not determine config directory", "check HOME and retry `zc profile list`");
        return error.NoConfigDir;
    };
    defer allocator.free(config_dir);

    var dir = std.fs.openDirAbsolute(config_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("{{\"ok\":true,\"data\":{{\"profiles\":[],\"active\":null}}}}\n", .{});
            return;
        }
        printCliError(true, "PROFILE_LIST_FAILED", "failed to open config directory", "ensure ~/.config/zc exists and is readable");
        return err;
    };
    defer dir.close();

    const active_path = try std.fs.path.join(allocator, &.{ config_dir, "config.yaml" });
    defer allocator.free(active_path);

    var active_buf: [std.fs.max_path_bytes]u8 = undefined;
    var active_name: ?[]const u8 = null;

    if (std.fs.accessAbsolute(active_path, .{})) |_| {
        if (std.fs.readLinkAbsolute(active_path, &active_buf)) |target| {
            active_name = std.fs.path.basename(target);
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

fn runProxy(allocator: std.mem.Allocator, config_path: ?[]const u8, use_tui: bool) !void {
    std.debug.print("zc v{s}\n", .{build_options.version});

    // 保存配置路径用于重载
    if (config_path) |path| {
        g_config_path = try allocator.dupe(u8, path);
    }

    // 加载并验证配置
    var cfg = try loadAndValidateConfig(allocator, config_path, true);
    defer cfg.deinit();

    // 启动前端口占用预检（可能修改 external-controller 端口）
    try preflightPortCheck(&cfg);

    // Initialize outbound manager
    var manager = try outbound.OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

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

    // Run TUI or stay in background
    if (use_tui) {
        try runTui(allocator, &cfg, &engine, &manager);
    } else {
        std.debug.print("Configuration loaded:\n", .{});
        std.debug.print("  Port: {}\n", .{cfg.port});
        std.debug.print("  SOCKS Port: {}\n", .{cfg.socks_port});
        std.debug.print("  Mixed Port: {}\n", .{cfg.mixed_port});
        std.debug.print("  Mode: {s}\n", .{cfg.mode});
        std.debug.print("  Proxies: {}\n", .{cfg.proxies.items.len});
        std.debug.print("  Rules: {}\n", .{cfg.rules.items.len});
        std.debug.print("\nProxy server running. Press Ctrl+C to stop.\n", .{});

        while (true) {
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
    }
}

fn loadAndValidateConfig(allocator: std.mem.Allocator, config_path: ?[]const u8, print_validation: bool) !config.Config {
    var cfg = if (config_path) |path|
        try config.load(allocator, path)
    else
        try config.loadDefault(allocator);

    // 强制使用 mixed-port 模式，忽略配置文件中的端口设置
    cfg.mixed_port = constants.MIXED_PORT;
    cfg.port = 0;
    cfg.socks_port = 0;

    var validation_result = try validator.validate(allocator, &cfg);
    defer validation_result.deinit();
    if (print_validation) {
        validator.printResult(&validation_result);
    }

    if (!validation_result.isValid()) {
        cfg.deinit();
        std.process.exit(1);
    }

    return cfg;
}

fn proxyThreadFn(allocator: std.mem.Allocator, cfg: *const config.Config, engine: *rule_engine.Engine, manager: *outbound.OutboundManager) void {
    std.Thread.sleep(100 * std.time.ns_per_ms);

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

fn runTui(allocator: std.mem.Allocator, cfg: *const config.Config, engine: *rule_engine.Engine, manager: *outbound.OutboundManager) !void {
    _ = engine;

    var tui_manager = try tui.TuiManager.init(allocator, cfg);
    tui_manager.outbound_manager = manager;
    defer tui_manager.deinit();

    // 设置重载回调
    tui_manager.setReloadCallback(struct {
        fn reload() void {
            std.debug.print("\nConfiguration reload requested\n", .{});
        }
    }.reload);

    // Add some sample logs
    try tui_manager.log("zc started");
    try tui_manager.log("Configuration loaded");
    try tui_manager.log("Proxy servers starting...");

    // Update stats
    tui_manager.updateStats(1024, 2048, 5);

    // Run TUI
    try tui_manager.run();
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

fn preflightPortCheck(cfg: *config.Config) !void {
    const bind_ip = effectiveBindAddress(cfg);

    // 进程内端口冲突检查
    if (try hasInProcessPortConflict(cfg)) {
        std.debug.print("Port precheck failed: in-process port conflict detected\n", .{});
        return error.PortConflict;
    }

    // 系统端口占用检查
    if (cfg.mixed_port > 0) {
        try checkPortAvailable(bind_ip, cfg.mixed_port);
    } else {
        if (cfg.port > 0) try checkPortAvailable(bind_ip, cfg.port);
        if (cfg.socks_port > 0) try checkPortAvailable(bind_ip, cfg.socks_port);
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
    const address = std.net.Address.parseIp4(ip, port) catch return false;
    var server = address.listen(.{ .reuse_address = true }) catch return false;
    server.deinit();
    return true;
}

fn checkPortAvailable(ip: []const u8, port: u16) !void {
    const address = std.net.Address.parseIp4(ip, port) catch {
        std.debug.print("Invalid bind-address '{s}'\n", .{ip});
        return error.InvalidBindAddress;
    };

    var server = address.listen(.{ .reuse_address = true }) catch {
        std.debug.print("Port precheck failed: {s}:{d} is already in use\n", .{ ip, port });
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

fn printHelp() !void {
    std.debug.print("\n", .{});
    std.debug.print("zc v{s} - A high-performance proxy tool in Zig\n", .{build_options.version});
    std.debug.print("\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("    zc <command> [options]\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("COMMANDS:\n", .{});
    std.debug.print("    help                    Show this help message\n", .{});
    std.debug.print("    tui                     Start TUI dashboard\n", .{});
    std.debug.print("    start [-c <config>]     Start proxy in background\n", .{});
    std.debug.print("    stop                    Stop proxy\n", .{});
    std.debug.print("    restart [-c <config>]   Restart proxy\n", .{});
    std.debug.print("    status                  Show proxy status\n", .{});
    std.debug.print("    log [-n <lines>]        View logs\n", .{});
    std.debug.print("    config <subcmd>         Manage configurations\n", .{});
    std.debug.print("    proxy <subcmd>          Manage proxies\n", .{});
    std.debug.print("    test [-c <config>]      Test network connectivity\n", .{});
    std.debug.print("    doctor [-c <config>]    Diagnose config/service/ports\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("CONFIG COMMANDS:\n", .{});
    std.debug.print("    zc config list                  List all available configs\n", .{});
    std.debug.print("    zc config ls                    Alias for list\n", .{});
    std.debug.print("    zc config download <url>        Download config from URL\n", .{});
    std.debug.print("                            -n <name>   Config filename (default: timestamp)\n", .{});
    std.debug.print("                            -d          Set as default after download\n", .{});
    std.debug.print("    zc config use <configname>     Switch to specified config\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("PROXY COMMANDS:\n", .{});
    std.debug.print("    zc proxy list                   List all proxy groups and nodes\n", .{});
    std.debug.print("    zc proxy ls                     Alias for list\n", .{});
    std.debug.print("    zc proxy select                 Show proxy selection UI\n", .{});
    std.debug.print("    zc proxy select -g <group>      Select proxy for specific group\n", .{});
    std.debug.print("    zc proxy select -g <group>      Select specific proxy\n", .{});
    std.debug.print("              -p <proxy>\n", .{});
    std.debug.print("EXAMPLES:\n", .{});
    std.debug.print("    # Start proxy in background\n", .{});
    std.debug.print("    zc start\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # Start with specific config\n", .{});
    std.debug.print("    zc start -c /path/to/config.yaml\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    # Start TUI\n", .{});
    std.debug.print("    zc tui\n", .{});
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
    std.debug.print("    zc config use <configname>     Switch to specified config\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("EXAMPLES:\n", .{});
    std.debug.print("    zc config download https://example.com/config.yaml\n", .{});
    std.debug.print("    zc config download https://example.com/config.yaml -n myconfig -d\n", .{});
    std.debug.print("    zc config list\n", .{});
    std.debug.print("    zc config use myconfig.yaml\n", .{});
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
    std.debug.print("\n", .{});
    std.debug.print("EXAMPLES:\n", .{});
    std.debug.print("    zc proxy list\n", .{});
    std.debug.print("    zc proxy select                 # Show selection UI\n", .{});
    std.debug.print("    zc proxy select -g Proxy -p HK  # Select HK in Proxy group\n", .{});
    std.debug.print("\n", .{});
}

test "parseExternalControllerPort valid and invalid" {
    const testing = std.testing;

    try testing.expectEqual(@as(u16, 9090), try parseExternalControllerPort("127.0.0.1:9090"));
    try testing.expectError(error.InvalidExternalController, parseExternalControllerPort("127.0.0.1"));
    try testing.expectError(error.InvalidExternalController, parseExternalControllerPort("127.0.0.1:abc"));
    try testing.expectError(error.InvalidExternalController, parseExternalControllerPort("127.0.0.1:0"));
}

test "parseConfigPathArg handles -c" {
    const testing = std.testing;

    const args = [_][]const u8{ "zc", "test", "-c", "./x.yaml" };
    try testing.expectEqualStrings("./x.yaml", parseConfigPathArg(args[0..], 2).?);

    const args2 = [_][]const u8{ "zc", "test" };
    try testing.expect(parseConfigPathArg(args2[0..], 2) == null);
}

test "include auxiliary cli tests" {
    _ = @import("test_cli.zig");
    _ = @import("doctor_cli.zig");
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
