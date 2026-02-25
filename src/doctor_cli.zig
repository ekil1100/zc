const std = @import("std");
const config = @import("config.zig");
const validator = @import("config_validator.zig");
const daemon = @import("daemon.zig");

pub const PortEntry = struct {
    label: []const u8,
    port: u16,
    listening: bool,
};

pub const DoctorData = struct {
    config_ok: bool,
    config_source: []const u8,
    config_path: []const u8 = "(default)",
    daemon_running: bool,
    daemon_pid: ?i32,
    ports: [3]PortEntry,
    port_count: usize,
    version: []const u8 = "zc v" ++ @import("build_options").version,
    network_ok: bool = false,
    proxy_reachable: bool = false,
    config_errors: []const []const u8 = &.{},
    config_warnings: []const []const u8 = &.{},
    migration_hints: []const []const u8 = &.{},
    daemon_uptime_seconds: ?i64 = null,
};

pub fn runDoctorJson(allocator: std.mem.Allocator, config_path: ?[]const u8) !void {
    const data = try collectDoctorData(allocator, config_path);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.writer(allocator).print("{{\"ok\":true,\"data\":{{\"action\":\"doctor\",\"version\":\"{s}\",\"config_path\":\"{s}\",\"config_ok\":{s},\"config_source\":\"{s}\",\"daemon_running\":{s},\"network_ok\":{s},\"daemon_pid\":", .{
        data.version,
        data.config_path,
        if (data.config_ok) "true" else "false",
        data.config_source,
        if (data.daemon_running) "true" else "false",
        if (data.network_ok) "true" else "false",
    });

    if (data.daemon_pid) |pid| {
        try out.writer(allocator).print("{d}", .{pid});
    } else {
        try out.appendSlice(allocator, "null");
    }

    try out.appendSlice(allocator, ",\"ports\":[");
    var i: usize = 0;
    while (i < data.port_count) : (i += 1) {
        if (i > 0) try out.appendSlice(allocator, ",");
        const p = data.ports[i];
        try out.writer(allocator).print("{{\"label\":\"{s}\",\"port\":{d},\"listening\":{s}}}", .{ p.label, p.port, if (p.listening) "true" else "false" });
    }
    try out.appendSlice(allocator, "],\"proxy_reachable\":");
    try out.appendSlice(allocator, if (data.proxy_reachable) "true" else "false");

    // config_errors array
    try out.appendSlice(allocator, ",\"config_errors\":[");
    for (data.config_errors, 0..) |err, idx| {
        if (idx > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, err);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, "],\"config_warnings\":[");
    for (data.config_warnings, 0..) |w, idx| {
        if (idx > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, w);
        try out.appendSlice(allocator, "\"");
    }
    // config_warnings array
    try out.appendSlice(allocator, ",\"config_warnings\":[");
    for (data.config_warnings, 0..) |w, idx| {
        if (idx > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, w);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, "],\"migration_hints\":[");
    for (data.migration_hints, 0..) |h, idx| {
        if (idx > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, h);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, "],\"daemon_uptime_seconds\":");
    if (data.daemon_uptime_seconds) |uptime| {
        try out.writer(allocator).print("{d}}}}}\n", .{uptime});
    } else {
        try out.appendSlice(allocator, "null}}}\n");
    }

    std.debug.print("{s}", .{out.items});
}

pub fn runDoctor(allocator: std.mem.Allocator, config_path: ?[]const u8) !void {
    const data = try collectDoctorData(allocator, config_path);
    const report = try formatDoctorReport(allocator, &data);
    defer allocator.free(report);
    std.debug.print("{s}", .{report});
}

fn collectDoctorData(allocator: std.mem.Allocator, config_path: ?[]const u8) !DoctorData {
    var data = DoctorData{
        .config_ok = false,
        .config_source = if (config_path != null) "custom" else "default",
        .config_path = config_path orelse "(default)",
        .daemon_running = false,
        .daemon_pid = null,
        .ports = undefined,
        .port_count = 0,
    };

    var cfg: ?config.Config = null;
    if (config_path) |path| {
        cfg = config.load(allocator, path) catch null;
    } else {
        cfg = config.loadDefault(allocator) catch null;
    }

    if (cfg) |*loaded_cfg| {
        defer loaded_cfg.deinit();

        var vr = validator.validate(allocator, loaded_cfg) catch {
            data.config_ok = false;
            data.config_source = if (config_path != null) "custom (parse ok, validation failed)" else "default (parse ok, validation failed)";
            try fillEffectivePorts(allocator, loaded_cfg, &data);
            try fillDaemonStatus(allocator, &data);
            return data;
        };
        defer vr.deinit();

        data.config_ok = vr.isValid();

        // Capture config errors and warnings
        if (vr.errors.items.len > 0) {
            const errs = try allocator.alloc([]const u8, vr.errors.items.len);
            for (vr.errors.items, 0..) |e, idx| {
                errs[idx] = try allocator.dupe(u8, e.message);
            }
            data.config_errors = errs;
        }
        if (vr.warnings.items.len > 0) {
            const warns = try allocator.alloc([]const u8, vr.warnings.items.len);
            for (vr.warnings.items, 0..) |w, idx| {
                warns[idx] = try allocator.dupe(u8, w.message);
            }
            data.config_warnings = warns;
        }

        try fillEffectivePorts(allocator, loaded_cfg, &data);
    }

    data.daemon_pid = try daemon.readPid(allocator);
    data.daemon_running = try daemon.isRunning(allocator);
    data.daemon_uptime_seconds = try getDaemonUptime(data.daemon_pid);

    data.network_ok = checkNetworkConnectivity();
    data.migration_hints = try collectMigrationHints(allocator, config_path);
    // Check if any configured proxy port is actually listening
    var pi: usize = 0;
    while (pi < data.port_count) : (pi += 1) {
        if (data.ports[pi].listening) {
            data.proxy_reachable = true;
            break;
        }
    }
    return data;
}

fn checkNetworkConnectivity() bool {
    const stream = std.net.tcpConnectToHost(std.heap.page_allocator, "1.1.1.1", 53) catch return false;
    stream.close();
    return true;
}

fn getDaemonUptime(pid: ?i32) !?i64 {
    const p = pid orelse return null;
    // Try to get process start time using ps
    var buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&buf, "ps -o etimes= -p {d}", .{p});
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{"sh", "-c", cmd},
    }) catch return null;
    defer {
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }
    if (result.term.Exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn collectMigrationHints(allocator: std.mem.Allocator, config_path: ?[]const u8) ![]const []const u8 {
    const path = config_path orelse return &.{};
    const file_content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return &.{};
    defer allocator.free(file_content);

    var hints = std.ArrayList([]const u8).empty;

    // Check for tun mode (unsupported)
    if (std.mem.indexOf(u8, file_content, "tun:") != null) {
        try hints.append(allocator, try allocator.dupe(u8, "tun mode is not supported by zc and will be ignored"));
    }
    // Check for enhanced-mode (unsupported)
    if (std.mem.indexOf(u8, file_content, "enhanced-mode:") != null) {
        try hints.append(allocator, try allocator.dupe(u8, "dns.enhanced-mode is not supported and will be ignored"));
    }
    // Check for rule-providers (partial support)
    if (std.mem.indexOf(u8, file_content, "rule-providers:") != null) {
        try hints.append(allocator, try allocator.dupe(u8, "rule-providers remote update is not fully implemented; manual refresh recommended"));
    }
    // Check for proxy-providers (unsupported)
    if (std.mem.indexOf(u8, file_content, "proxy-providers:") != null) {
        try hints.append(allocator, try allocator.dupe(u8, "proxy-providers is not supported; declare proxies statically in the config"));
    }

    return hints.items;
}

fn fillDaemonStatus(allocator: std.mem.Allocator, data: *DoctorData) !void {
    data.daemon_pid = try daemon.readPid(allocator);
    data.daemon_running = try daemon.isRunning(allocator);
}

fn fillEffectivePorts(allocator: std.mem.Allocator, cfg: *const config.Config, data: *DoctorData) !void {
    _ = allocator;

    if (cfg.mixed_port > 0) {
        data.ports[0] = .{
            .label = "mixed",
            .port = cfg.mixed_port,
            .listening = try isLocalPortListening(cfg.mixed_port),
        };
        data.port_count = 1;
        return;
    }

    if (cfg.port > 0) {
        data.ports[data.port_count] = .{
            .label = "http",
            .port = cfg.port,
            .listening = try isLocalPortListening(cfg.port),
        };
        data.port_count += 1;
    }

    if (cfg.socks_port > 0) {
        data.ports[data.port_count] = .{
            .label = "socks",
            .port = cfg.socks_port,
            .listening = try isLocalPortListening(cfg.socks_port),
        };
        data.port_count += 1;
    }
}

fn isLocalPortListening(port: u16) !bool {
    const allocator = std.heap.page_allocator;
    const stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch return false;
    stream.close();
    return true;
}

pub fn formatDoctorReport(allocator: std.mem.Allocator, data: *const DoctorData) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    const w = out.writer(allocator);
    try w.print("zc doctor\n", .{});
    try w.print("{s:-^60}\n", .{""});

    try w.print("Version: {s}\n", .{data.version});
    try w.print("Config path: {s}\n", .{data.config_path});
    try w.print("Config: {s} ({s})\n", .{ if (data.config_ok) "OK" else "FAILED", data.config_source });

    if (data.daemon_running) {
        try w.print("Daemon: running", .{});
        if (data.daemon_pid) |pid| {
            try w.print(" (PID: {d})\n", .{pid});
        } else {
            try w.print("\n", .{});
        }
    } else {
        try w.print("Daemon: not running\n", .{});
    }

    try w.print("Network: {s}\n", .{if (data.network_ok) "OK" else "UNREACHABLE"});
    try w.print("Proxy reachable: {s}\n", .{if (data.proxy_reachable) "YES" else "NO"});
    try w.print("Effective ports:\n", .{});
    if (data.port_count == 0) {
        try w.print("  - none\n", .{});
    } else {
        var i: usize = 0;
        while (i < data.port_count) : (i += 1) {
            const p = data.ports[i];
            try w.print("  - {s}: 127.0.0.1:{d} [{s}]\n", .{ p.label, p.port, if (p.listening) "listening" else "not listening" });
        }
    }

    try w.print("Suggestions:\n", .{});
    if (!data.config_ok) {
        try w.print("  1. Fix config syntax/validation issues, then rerun `zc doctor`.\n", .{});
    }
    if (!data.daemon_running) {
        try w.print("  2. Start service: zc start -c <config>\n", .{});
    }
    var has_not_listening = false;
    var i: usize = 0;
    while (i < data.port_count) : (i += 1) {
        if (!data.ports[i].listening) {
            has_not_listening = true;
            break;
        }
    }
    if (has_not_listening) {
        try w.print("  3. Ensure configured proxy ports are bound by zc process.\n", .{});
    }
    if (data.config_ok and data.daemon_running and !has_not_listening) {
        try w.print("  - No action needed.\n", .{});
    }

    return try out.toOwnedSlice(allocator);
}

test "formatDoctorReport basic output" {
    const allocator = std.testing.allocator;

    var data = DoctorData{
        .config_ok = true,
        .config_source = "default",
        .daemon_running = false,
        .daemon_pid = null,
        .ports = undefined,
        .port_count = 1,
    };
    data.ports[0] = .{ .label = "mixed", .port = 7890, .listening = false };

    const report = try formatDoctorReport(allocator, &data);
    defer allocator.free(report);

    try std.testing.expect(std.mem.indexOf(u8, report, "zc doctor") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Effective ports") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "mixed: 127.0.0.1:7890") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Start service: zc start -c <config>") != null);
}
