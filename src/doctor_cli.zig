const std = @import("std");
const compat = @import("compat.zig");
const config = @import("config.zig");
const constants = @import("constants.zig");
const validator = @import("config_validator.zig");
const daemon = @import("daemon.zig");

const network_probe_host = "1.1.1.1";
const network_probe_port: u16 = 443;
const network_probe_timeout_ms: i32 = 200;

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

    pub fn deinit(self: *DoctorData, allocator: std.mem.Allocator) void {
        if (self.config_errors.len > 0) {
            for (self.config_errors) |msg| allocator.free(msg);
            allocator.free(self.config_errors);
        }
        if (self.config_warnings.len > 0) {
            for (self.config_warnings) |msg| allocator.free(msg);
            allocator.free(self.config_warnings);
        }
        if (self.migration_hints.len > 0) {
            for (self.migration_hints) |hint| allocator.free(hint);
            allocator.free(self.migration_hints);
        }
    }
};

pub fn runDoctorJson(allocator: std.mem.Allocator, config_path: ?[]const u8) !void {
    var data = try collectDoctorData(allocator, config_path, null);
    defer data.deinit(allocator);
    try emitDoctorJson(allocator, &data);
}

pub fn runDoctorJsonWithConfig(allocator: std.mem.Allocator, cfg: *config.Config, config_path: ?[]const u8) !void {
    var data = try collectDoctorData(allocator, config_path, cfg);
    defer data.deinit(allocator);
    try emitDoctorJson(allocator, &data);
}

pub fn runDoctor(allocator: std.mem.Allocator, config_path: ?[]const u8) !void {
    var data = try collectDoctorData(allocator, config_path, null);
    defer data.deinit(allocator);
    const report = try formatDoctorReport(allocator, &data);
    defer allocator.free(report);
    std.debug.print("{s}", .{report});
}

pub fn runDoctorWithConfig(allocator: std.mem.Allocator, cfg: *config.Config, config_path: ?[]const u8) !void {
    var data = try collectDoctorData(allocator, config_path, cfg);
    defer data.deinit(allocator);
    const report = try formatDoctorReport(allocator, &data);
    defer allocator.free(report);
    std.debug.print("{s}", .{report});
}

fn emitDoctorJson(allocator: std.mem.Allocator, data: *const DoctorData) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.print(allocator, "{{\"ok\":true,\"data\":{{\"action\":\"doctor\",\"version\":\"{s}\",\"config_path\":\"{s}\",\"config_ok\":{s},\"config_source\":\"{s}\",\"daemon_running\":{s},\"network_ok\":{s},\"daemon_pid\":", .{
        data.version,
        data.config_path,
        if (data.config_ok) "true" else "false",
        data.config_source,
        if (data.daemon_running) "true" else "false",
        if (data.network_ok) "true" else "false",
    });

    if (data.daemon_pid) |pid| {
        try out.print(allocator, "{d}", .{pid});
    } else {
        try out.appendSlice(allocator, "null");
    }

    try out.appendSlice(allocator, ",\"ports\":[");
    var i: usize = 0;
    while (i < data.port_count) : (i += 1) {
        if (i > 0) try out.appendSlice(allocator, ",");
        const p = data.ports[i];
        try out.print(allocator, "{{\"label\":\"{s}\",\"port\":{d},\"listening\":{s}}}", .{ p.label, p.port, if (p.listening) "true" else "false" });
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
    try out.appendSlice(allocator, "],\"migration_hints\":[");
    for (data.migration_hints, 0..) |h, idx| {
        if (idx > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, h);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, "],\"daemon_uptime_seconds\":");
    if (data.daemon_uptime_seconds) |uptime| {
        try out.print(allocator, "{d}}}}}\n", .{uptime});
    } else {
        try out.appendSlice(allocator, "null}}}\n");
    }

    std.debug.print("{s}", .{out.items});
}

fn collectDoctorData(allocator: std.mem.Allocator, config_path: ?[]const u8, provided_cfg: ?*config.Config) !DoctorData {
    var data = DoctorData{
        .config_ok = false,
        .config_source = if (config_path != null) "custom" else "default",
        .config_path = config_path orelse "(default)",
        .daemon_running = false,
        .daemon_pid = null,
        .ports = undefined,
        .port_count = 0,
    };

    try fillDaemonStatus(allocator, &data);
    data.daemon_uptime_seconds = try getDaemonUptime(data.daemon_pid);
    const daemon_mixed_port = try detectDaemonMixedPort(allocator, data.daemon_running, data.daemon_pid);

    if (provided_cfg) |loaded_cfg| {
        if (try populateConfigData(allocator, loaded_cfg, config_path, daemon_mixed_port, &data)) return data;
    } else {
        var cfg: ?config.Config = null;
        if (config_path) |path| {
            cfg = config.load(allocator, path) catch null;
        } else {
            cfg = config.loadDefaultQuiet(allocator) catch null;
        }

        if (cfg) |*loaded_cfg| {
            defer loaded_cfg.deinit();
            if (try populateConfigData(allocator, loaded_cfg, config_path, daemon_mixed_port, &data)) return data;
        }
    }

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

fn populateConfigData(
    allocator: std.mem.Allocator,
    loaded_cfg: *config.Config,
    config_path: ?[]const u8,
    daemon_mixed_port: ?u16,
    data: *DoctorData,
) !bool {
    var vr = validator.validate(allocator, loaded_cfg) catch {
        data.config_ok = false;
        data.config_source = if (config_path != null) "custom (parse ok, validation failed)" else "default (parse ok, validation failed)";
        try fillEffectivePorts(allocator, loaded_cfg, daemon_mixed_port, data);
        return true;
    };
    defer vr.deinit();

    data.config_ok = vr.isValid();

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

    try fillEffectivePorts(allocator, loaded_cfg, daemon_mixed_port, data);
    return false;
}

fn checkNetworkConnectivity() bool {
    return tcpConnectIp4WithTimeout(network_probe_host, network_probe_port, network_probe_timeout_ms);
}

fn tcpConnectIp4WithTimeout(host: []const u8, port: u16, timeout_ms: i32) bool {
    if (timeout_ms <= 0) return false;

    const address = compat.net.Address.parseIp4(host, port) catch return false;
    const sa = switch (address) {
        .in => |a| a.sa,
        .in6 => return false,
    };

    const fd_rc = std.posix.system.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    switch (std.posix.errno(fd_rc)) {
        .SUCCESS => {},
        else => return false,
    }
    const fd: std.posix.fd_t = @intCast(fd_rc);
    defer compat.posixClose(fd);

    const flags_rc = std.posix.system.fcntl(fd, std.c.F.GETFL, @as(usize, 0));
    switch (std.posix.errno(flags_rc)) {
        .SUCCESS => {},
        else => return false,
    }
    const nonblock_flags = @as(usize, @intCast(flags_rc)) | (@as(usize, 1) << @bitOffsetOf(std.c.O, "NONBLOCK"));
    switch (std.posix.errno(std.posix.system.fcntl(fd, std.c.F.SETFL, nonblock_flags))) {
        .SUCCESS => {},
        else => return false,
    }

    const sockaddr: *const std.c.sockaddr = @ptrCast(&sa);
    const connect_rc = std.c.connect(fd, sockaddr, @sizeOf(@TypeOf(sa)));
    switch (std.posix.errno(connect_rc)) {
        .SUCCESS => return true,
        .INPROGRESS, .ALREADY, .AGAIN => {},
        else => return false,
    }

    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        },
    };
    const ready = std.posix.poll(&poll_fds, timeout_ms) catch return false;
    if (ready == 0) return false;
    if ((poll_fds[0].revents & (std.posix.POLL.OUT | std.posix.POLL.ERR | std.posix.POLL.HUP)) == 0) return false;

    var socket_error: c_int = 0;
    var socket_error_len: std.c.socklen_t = @sizeOf(@TypeOf(socket_error));
    const getsockopt_rc = std.c.getsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.ERROR,
        &socket_error,
        &socket_error_len,
    );
    if (getsockopt_rc != 0) return false;
    return socket_error == 0;
}

fn getDaemonUptime(pid: ?i32) !?i64 {
    const p = pid orelse return null;
    // Try to get process start time using ps
    var buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&buf, "ps -o etimes= -p {d}", .{p});
    const result = compat.childRun(std.heap.page_allocator, &.{ "sh", "-c", cmd }, 1024 * 1024) catch return null;
    defer {
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }
    if (result.term.exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn collectMigrationHints(allocator: std.mem.Allocator, config_path: ?[]const u8) ![]const []const u8 {
    const path = config_path orelse return &.{};
    const file_content = compat.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return &.{};
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

    return try hints.toOwnedSlice(allocator);
}

fn fillDaemonStatus(allocator: std.mem.Allocator, data: *DoctorData) !void {
    data.daemon_running = try daemon.isRunning(allocator);
    data.daemon_pid = try daemon.readPid(allocator);
}

fn detectDaemonMixedPort(allocator: std.mem.Allocator, daemon_running: bool, daemon_pid: ?i32) !?u16 {
    if (!daemon_running) return null;
    const pid = daemon_pid orelse return constants.MIXED_PORT;
    return (try detectDaemonPortOverride(allocator, pid)) orelse constants.MIXED_PORT;
}

fn detectDaemonPortOverride(allocator: std.mem.Allocator, pid: i32) !?u16 {
    var pid_buf: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    const result = compat.childRun(allocator, &.{ "ps", "-ww", "-o", "command=", "-p", pid_text }, 1024 * 1024) catch return null;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term.exited != 0) return null;
    return parseRuntimePortOverrideFromCommand(result.stdout);
}

fn parseRuntimePortOverrideFromCommand(command: []const u8) ?u16 {
    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const value = it.next() orelse return null;
            return std.fmt.parseInt(u16, value, 10) catch null;
        }
        if (std.mem.startsWith(u8, arg, "--port=")) {
            return std.fmt.parseInt(u16, arg["--port=".len..], 10) catch null;
        }
    }
    return null;
}

fn fillEffectivePorts(allocator: std.mem.Allocator, cfg: *const config.Config, daemon_mixed_port: ?u16, data: *DoctorData) !void {
    _ = allocator;
    data.port_count = 0;

    const mixed_port = daemon_mixed_port orelse if (cfg.mixed_port > 0) cfg.mixed_port else constants.MIXED_PORT;
    data.ports[0] = .{
        .label = "mixed",
        .port = mixed_port,
        .listening = try isLocalPortListening(mixed_port),
    };
    data.port_count = 1;
}

fn isLocalPortListening(port: u16) !bool {
    const allocator = std.heap.page_allocator;
    const stream = compat.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch return false;
    stream.close();
    return true;
}

pub fn formatDoctorReport(allocator: std.mem.Allocator, data: *const DoctorData) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "Config: {s}\n", .{if (data.config_ok) "OK" else "FAILED"});
    try out.print(allocator, "Daemon: {s}\n", .{if (data.daemon_running) "running" else "stopped"});
    if (data.daemon_pid) |pid| {
        try out.print(allocator, "PID: {d}\n", .{pid});
    } else {
        try out.print(allocator, "PID: -\n", .{});
    }
    try out.print(allocator, "Port: ", .{});
    try appendPortSummary(allocator, &out, data);
    try out.print(allocator, "\n", .{});
    try out.print(allocator, "Connection: {s}\n", .{if (data.proxy_reachable) "OK" else "FAILED"});

    return try out.toOwnedSlice(allocator);
}

fn appendPortSummary(allocator: std.mem.Allocator, out: *std.ArrayList(u8), data: *const DoctorData) !void {
    if (data.port_count == 0) {
        try out.appendSlice(allocator, "-");
        return;
    }

    var i: usize = 0;
    while (i < data.port_count) : (i += 1) {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.print(allocator, "{d}", .{data.ports[i].port});
    }
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

    try std.testing.expect(std.mem.indexOf(u8, report, "Config: OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Daemon: stopped") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "PID: -") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Port: 7890") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Connection: FAILED") != null);
}

test "parseRuntimePortOverrideFromCommand reads daemon port flag" {
    try std.testing.expectEqual(@as(?u16, 29001), parseRuntimePortOverrideFromCommand("/bin/zc --daemon-run --port=29001"));
    try std.testing.expectEqual(@as(?u16, 29002), parseRuntimePortOverrideFromCommand("/bin/zc --daemon-run --port 29002"));
    try std.testing.expectEqual(@as(?u16, null), parseRuntimePortOverrideFromCommand("/bin/zc --daemon-run --port nope"));
    try std.testing.expectEqual(@as(?u16, null), parseRuntimePortOverrideFromCommand("/bin/zc --daemon-run"));
}

test "doctor network probe timeout stays bounded" {
    try std.testing.expectEqualStrings("1.1.1.1", network_probe_host);
    try std.testing.expectEqual(@as(u16, 443), network_probe_port);
    try std.testing.expect(network_probe_timeout_ms > 0);
    try std.testing.expect(network_probe_timeout_ms <= 1000);
}

test "fillEffectivePorts reports daemon runtime mixed port" {
    const allocator = std.testing.allocator;

    var cfg = config.Config{
        .allocator = allocator,
        .port = 7890,
        .socks_port = 7891,
        .mixed_port = 7892,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "127.0.0.1"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    var data = DoctorData{
        .config_ok = true,
        .config_source = "custom",
        .daemon_running = true,
        .daemon_pid = 123,
        .ports = undefined,
        .port_count = 0,
    };

    try fillEffectivePorts(allocator, &cfg, 29001, &data);
    try std.testing.expectEqual(@as(usize, 1), data.port_count);
    try std.testing.expectEqualStrings("mixed", data.ports[0].label);
    try std.testing.expectEqual(@as(u16, 29001), data.ports[0].port);
}
