const std = @import("std");
const compat = @import("compat.zig");
const builtin = @import("builtin");
const config = @import("config.zig");
const constants = @import("constants.zig");
const runtime_selection = @import("runtime_selection.zig");
const cli_output = @import("cli/output.zig");

// PID 文件路径
const PID_FILE = "/tmp/zc.pid";
const LOCK_FILE = "/tmp/zc.lock";
const LOG_FILE = "/tmp/zc.log";
const startup_poll_interval_ms: u64 = 200;
const startup_poll_attempts: usize = 10;
const command_probe_max_output_bytes: usize = 16 * 1024;

pub const ApplyMode = enum {
    auto,
    hot,
    restart,
};

pub const ApplyResult = enum {
    hot_applied,
    restart_applied,
    restart_fallback,
};

/// start/stop 的结构化结果：daemon 层只返回事实，envelope 由 main.zig
/// 经 cli/output.zig 恰好打印一次（修复双重打印，见 docs/cli/ux-workflow.md）。
pub const LifecycleOutcome = struct {
    /// 冻结 detail 词汇：already_running / already_stopped。
    detail: ?[]const u8 = null,
    pid: ?i32 = null,
};

const StatusSnapshot = struct {
    action: []const u8 = "status",
    state: []const u8,
    detail: ?[]const u8 = null,
    pid: ?i32 = null,
    uptime_seconds: ?i64 = null,
    active_config: ?[]const u8 = null,
    selected_proxies: []runtime_selection.SelectedProxy = &[_]runtime_selection.SelectedProxy{},
    pid_file: []const u8,
    lock_file: []const u8,
    log_file: []const u8,

    fn deinit(self: *StatusSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.pid_file);
        allocator.free(self.lock_file);
        allocator.free(self.log_file);
        if (self.active_config) |active_config| allocator.free(active_config);
        runtime_selection.deinitSelectedProxies(allocator, self.selected_proxies);
    }
};

const RuntimeState = struct {
    pid: ?i32 = null,
    detail: ?[]const u8 = null,
    lock_held: bool = false,
    stale_pid: ?i32 = null,

    fn isRunning(self: RuntimeState) bool {
        return self.pid != null or self.lock_held;
    }
};

const RuntimeInspector = struct {
    pid_is_daemon: *const fn (std.mem.Allocator, i32) anyerror!bool,
};

/// 获取 PID 文件路径
pub fn getPidFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return getRuntimeFilePath(allocator, "zc.pid", PID_FILE);
}

/// 获取 lock 文件路径
fn getLockFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return getRuntimeFilePath(allocator, "zc.lock", LOCK_FILE);
}

fn getRuntimeFilePath(allocator: std.mem.Allocator, basename: []const u8, fallback: []const u8) ![]const u8 {
    // 优先使用 XDG_RUNTIME_DIR，否则使用 /tmp
    if (compat.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |runtime_dir| {
        const path = try compat.fs.path.join(allocator, &.{ runtime_dir, basename });
        allocator.free(runtime_dir);
        return path;
    } else |_| {
        return try allocator.dupe(u8, fallback);
    }
}

/// 获取日志文件路径
pub fn getLogFilePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = compat.getEnvVarOwned(allocator, "HOME") catch {
        return try allocator.dupe(u8, LOG_FILE);
    };
    defer allocator.free(home);

    // 使用 ~/.local/share/zc/zc.log
    const log_dir = try compat.fs.path.join(allocator, &.{ home, ".local/share/zc" });
    defer allocator.free(log_dir);

    // 创建目录
    compat.fs.makeDirAbsolute(log_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            // 回退到 /tmp
            return try allocator.dupe(u8, LOG_FILE);
        }
    };

    return try compat.fs.path.join(allocator, &.{ log_dir, "zc.log" });
}

/// 读取 PID 文件
pub fn readPid(allocator: std.mem.Allocator) !?i32 {
    const pid_file = try getPidFilePath(allocator);
    defer allocator.free(pid_file);

    return readPidAtPath(pid_file);
}

fn readPidAtPath(pid_file: []const u8) !?i32 {
    const file = compat.fs.openFileAbsolute(pid_file, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(compat.io());

    var buf: [32]u8 = undefined;
    const n = try compat.fileRead(file, &buf);
    if (n == 0) return null;

    const pid_str = std.mem.trim(u8, buf[0..n], " \t\n\r");
    return std.fmt.parseInt(i32, pid_str, 10) catch null;
}

/// 写入 PID 文件
pub fn writePid(allocator: std.mem.Allocator, pid: i32) !void {
    const pid_file = try getPidFilePath(allocator);
    defer allocator.free(pid_file);

    try writePidAtPath(pid_file, pid);
}

fn writePidAtPath(pid_file: []const u8, pid: i32) !void {
    const file = try compat.fs.createFileAbsolute(pid_file, .{});
    defer file.close(compat.io());

    var buf: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&buf, "{d}\n", .{pid});
    try compat.fileWriteAll(file, pid_str);
}

/// 删除 PID 文件
pub fn removePidFile(allocator: std.mem.Allocator) void {
    const pid_file = getPidFilePath(allocator) catch return;
    defer allocator.free(pid_file);
    removePidFileAtPath(pid_file);
}

fn removePidFileAtPath(pid_file: []const u8) void {
    compat.fs.deleteFileAbsolute(pid_file) catch {};
}

fn isDaemonBinaryPath(argv0: []const u8) bool {
    const base = compat.fs.path.basename(argv0);
    // deb 包以 zclash 安装（scripts/build-deb.sh / zclash.service）。
    return std.mem.eql(u8, base, "zc") or std.mem.eql(u8, base, "zclash");
}

/// 一个进程是“本体 daemon”当且仅当：argv0 是 zc/zclash，且要么带内部
/// `--daemon-run` 标志，要么是 `start --foreground`（决策 D1 的受监管前台模式）。
fn tokensLookLikeDaemon(parts: anytype) bool {
    const argv0 = parts.next() orelse return false;
    if (!isDaemonBinaryPath(argv0)) return false;

    var first_word: ?[]const u8 = null;
    var saw_foreground = false;
    while (parts.next()) |arg| {
        if (std.mem.eql(u8, arg, "--daemon-run")) return true;
        if (std.mem.eql(u8, arg, "--foreground")) saw_foreground = true;
        if (first_word == null and arg.len > 0 and arg[0] != '-') first_word = arg;
    }

    if (saw_foreground) {
        if (first_word) |word| {
            return std.mem.eql(u8, word, "start") or std.mem.eql(u8, word, "up");
        }
    }

    return false;
}

fn commandLineLooksLikeDaemon(command_line: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, std.mem.trim(u8, command_line, " \t\r\n"), " \t");
    return tokensLookLikeDaemon(&parts);
}

fn cmdlineBufferLooksLikeDaemon(cmdline: []const u8) bool {
    if (cmdline.len == 0) return false;

    var parts = std.mem.tokenizeScalar(u8, cmdline, 0);
    return tokensLookLikeDaemon(&parts);
}

fn linuxPidLooksLikeDaemon(allocator: std.mem.Allocator, pid: i32) !bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return false;
    const file = compat.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close(compat.io());

    const cmdline = compat.fileReadToEndAlloc(file, allocator, command_probe_max_output_bytes) catch return false;
    defer allocator.free(cmdline);

    return cmdlineBufferLooksLikeDaemon(cmdline);
}

fn psPidLooksLikeDaemon(allocator: std.mem.Allocator, pid: i32) !bool {
    var pid_buf: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    const result = compat.childRun(allocator, &.{ "ps", "-ww", "-o", "command=", "-p", pid_text }, command_probe_max_output_bytes) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term.exited != 0) return false;

    return commandLineLooksLikeDaemon(result.stdout);
}

fn pidMatchesRunningDaemon(allocator: std.mem.Allocator, pid: i32) !bool {
    std.posix.kill(pid, @enumFromInt(0)) catch return false;

    return switch (builtin.os.tag) {
        .linux => try linuxPidLooksLikeDaemon(allocator, pid),
        else => try psPidLooksLikeDaemon(allocator, pid),
    };
}

/// 已被 stop/restart/reload 依赖的“当前 daemon 的启动参数”快照，
/// 从 tracked pid 的命令行解析得到（-c / --port / --foreground）。
pub const TrackedInvocation = struct {
    pid: i32,
    /// `zc start --foreground`：受 systemd/容器监管的前台 daemon。
    foreground: bool = false,
    config_path: ?[]u8 = null,
    port: ?u16 = null,

    pub fn deinit(self: *TrackedInvocation, allocator: std.mem.Allocator) void {
        if (self.config_path) |p| allocator.free(p);
        self.config_path = null;
    }
};

fn rawDaemonCommandLineAlloc(allocator: std.mem.Allocator, pid: i32) !?[]u8 {
    switch (builtin.os.tag) {
        .linux => {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return null;
            const file = compat.fs.openFileAbsolute(path, .{}) catch return null;
            defer file.close(compat.io());
            return compat.fileReadToEndAlloc(file, allocator, command_probe_max_output_bytes) catch null;
        },
        else => {
            var pid_buf: [32]u8 = undefined;
            const pid_text = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return null;
            const result = compat.childRun(allocator, &.{ "ps", "-ww", "-o", "command=", "-p", pid_text }, command_probe_max_output_bytes) catch return null;
            allocator.free(result.stderr);
            if (result.term.exited != 0) {
                allocator.free(result.stdout);
                return null;
            }
            return result.stdout;
        },
    }
}

fn parseTrackedInvocationFromCmdline(allocator: std.mem.Allocator, pid: i32, cmdline: []const u8) !TrackedInvocation {
    var inv = TrackedInvocation{ .pid = pid };
    errdefer inv.deinit(allocator);

    // /proc cmdline 是 NUL 分隔，ps 输出是空白分隔；统一按两者切词。
    var parts = std.mem.tokenizeAny(u8, cmdline, " \t\r\n\x00");
    _ = parts.next(); // argv0
    while (parts.next()) |arg| {
        if (std.mem.eql(u8, arg, "--foreground")) {
            inv.foreground = true;
        } else if (std.mem.eql(u8, arg, "-c")) {
            if (parts.next()) |value| {
                if (inv.config_path) |old| allocator.free(old);
                inv.config_path = try allocator.dupe(u8, value);
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (parts.next()) |value| {
                inv.port = std.fmt.parseInt(u16, value, 10) catch inv.port;
            }
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            inv.port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch inv.port;
        }
    }
    return inv;
}

/// 捕获 tracked daemon 的调用参数；daemon 不在运行（或命令行不可读）时返回 null。
pub fn captureTrackedInvocation(allocator: std.mem.Allocator) !?TrackedInvocation {
    const pid = (try readTrackedPid(allocator)) orelse return null;
    const maybe_cmdline = rawDaemonCommandLineAlloc(allocator, pid) catch null;
    const cmdline = maybe_cmdline orelse return null;
    defer allocator.free(cmdline);
    return try parseTrackedInvocationFromCmdline(allocator, pid, cmdline);
}

/// 运行时状态只信任本环境（XDG_RUNTIME_DIR）的 pid/lock 文件，绝不全局扫描
/// 进程表：旧版的 ps/pgrep 全局发现会把其他 HOME/XDG 环境的 zc daemon 误认为
/// 本环境的 —— status 会把别人的 pid 写进本地 pid 文件，stop 会杀掉别人的
/// 进程。pid 文件丢失而锁仍被持有时，如实上报 `lock_held_pid_untracked`。
fn inspectRuntimeAtPathsWithInspector(
    allocator: std.mem.Allocator,
    pid_file: []const u8,
    lock_file: []const u8,
    inspector: RuntimeInspector,
) !RuntimeState {
    var stale_pid: ?i32 = null;

    if (try readPidAtPath(pid_file)) |pid| {
        if (try inspector.pid_is_daemon(allocator, pid)) {
            return .{
                .pid = pid,
                .lock_held = true,
            };
        }
        stale_pid = pid;
        removePidFileAtPath(pid_file);
    }

    if (try isDaemonLockHeldAtPath(lock_file)) {
        return .{
            .detail = "lock_held_pid_untracked",
            .lock_held = true,
            .stale_pid = stale_pid,
        };
    }

    return .{
        .detail = if (stale_pid != null) "stale_pid_file" else null,
        .stale_pid = stale_pid,
    };
}

fn inspectRuntimeAtPaths(allocator: std.mem.Allocator, pid_file: []const u8, lock_file: []const u8) !RuntimeState {
    return inspectRuntimeAtPathsWithInspector(allocator, pid_file, lock_file, .{
        .pid_is_daemon = pidMatchesRunningDaemon,
    });
}

fn inspectRuntime(allocator: std.mem.Allocator) !RuntimeState {
    const pid_file = try getPidFilePath(allocator);
    defer allocator.free(pid_file);
    const lock_file = try getLockFilePath(allocator);
    defer allocator.free(lock_file);
    return try inspectRuntimeAtPaths(allocator, pid_file, lock_file);
}

fn readTrackedPid(allocator: std.mem.Allocator) !?i32 {
    return (try inspectRuntime(allocator)).pid;
}

fn waitForTrackedRunningPid(allocator: std.mem.Allocator) !?i32 {
    var attempt: usize = 0;
    while (attempt < startup_poll_attempts) : (attempt += 1) {
        if (try readTrackedPid(allocator)) |pid| return pid;
        compat.sleepNs(startup_poll_interval_ms * std.time.ns_per_ms);
    }
    return null;
}

fn duplicateWithoutCloexec(file: compat.fs.File) !compat.fs.File {
    const dup_fd = std.c.dup(file.handle);
    if (dup_fd < 0) return error.Unexpected;
    file.close(compat.io());
    return .{ .handle = dup_fd, .flags = file.flags };
}

fn acquireDaemonLockFileAtPath(lock_file_path: []const u8) !compat.fs.File {
    const lock_file = compat.fs.createFileAbsolute(lock_file_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.DaemonAlreadyRunning,
        else => return err,
    };
    errdefer lock_file.close(compat.io());
    return try duplicateWithoutCloexec(lock_file);
}

fn acquireDaemonLockFile(allocator: std.mem.Allocator) !compat.fs.File {
    const lock_file_path = try getLockFilePath(allocator);
    defer allocator.free(lock_file_path);
    return try acquireDaemonLockFileAtPath(lock_file_path);
}

fn isDaemonLockHeldAtPath(lock_file_path: []const u8) !bool {
    var lock_file = acquireDaemonLockFileAtPath(lock_file_path) catch |err| switch (err) {
        error.DaemonAlreadyRunning => return true,
        else => return err,
    };
    lock_file.close(compat.io());
    return false;
}

/// 检查进程是否正在运行
pub fn isRunning(allocator: std.mem.Allocator) !bool {
    return (try inspectRuntime(allocator)).isRunning();
}

/// `zc start --foreground`（决策 D1）：不 fork，由调用方持有 daemon 锁直到
/// 进程退出，防止与后台 daemon 双实例并存。
pub fn acquireForegroundLock(allocator: std.mem.Allocator) !compat.fs.File {
    return try acquireDaemonLockFile(allocator);
}

fn getDaemonUptime(pid: ?i32) !?i64 {
    const p = pid orelse return null;
    var buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&buf, "ps -o etimes= -p {d}", .{p});
    const result = compat.childRun(std.heap.page_allocator, &.{ "sh", "-c", cmd }, command_probe_max_output_bytes) catch return null;
    defer {
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }
    if (result.term.exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn collectStatusSnapshot(allocator: std.mem.Allocator) !StatusSnapshot {
    const pid_file = try getPidFilePath(allocator);
    errdefer allocator.free(pid_file);
    const lock_file = try getLockFilePath(allocator);
    errdefer allocator.free(lock_file);
    const log_file = try getLogFilePath(allocator);
    errdefer allocator.free(log_file);
    const active_config = try config.resolveRuntimeConfigKey(allocator, null);
    errdefer if (active_config) |value| allocator.free(value);
    const selected_proxies = try collectStatusSelectedProxies(allocator, active_config);
    errdefer runtime_selection.deinitSelectedProxies(allocator, selected_proxies);

    const runtime = try inspectRuntimeAtPaths(allocator, pid_file, lock_file);
    if (runtime.pid) |p| {
        return .{
            .state = "running",
            .detail = runtime.detail,
            .pid = p,
            .uptime_seconds = try getDaemonUptime(p),
            .active_config = active_config,
            .selected_proxies = selected_proxies,
            .pid_file = pid_file,
            .lock_file = lock_file,
            .log_file = log_file,
        };
    }

    if (runtime.lock_held) {
        return .{
            .state = "running",
            .detail = runtime.detail,
            .active_config = active_config,
            .selected_proxies = selected_proxies,
            .pid_file = pid_file,
            .lock_file = lock_file,
            .log_file = log_file,
        };
    }

    return .{
        .state = "stopped",
        .detail = runtime.detail,
        .pid = runtime.stale_pid,
        .active_config = active_config,
        .selected_proxies = selected_proxies,
        .pid_file = pid_file,
        .lock_file = lock_file,
        .log_file = log_file,
    };
}

fn collectStatusSelectedProxies(allocator: std.mem.Allocator, active_config: ?[]const u8) ![]runtime_selection.SelectedProxy {
    var cfg = config.loadDefaultQuiet(allocator) catch return try allocator.alloc(runtime_selection.SelectedProxy, 0);
    defer cfg.deinit();
    return try runtime_selection.collectSelectedProxies(allocator, &cfg, active_config);
}

fn collectStatusSnapshotAtPaths(
    allocator: std.mem.Allocator,
    pid_file: []const u8,
    lock_file: []const u8,
    log_file: []const u8,
    active_config: ?[]const u8,
    inspector: RuntimeInspector,
) !StatusSnapshot {
    const runtime = try inspectRuntimeAtPathsWithInspector(allocator, pid_file, lock_file, inspector);
    const empty_selected_proxies = try allocator.alloc(runtime_selection.SelectedProxy, 0);
    if (runtime.pid) |p| {
        return .{
            .state = "running",
            .detail = runtime.detail,
            .pid = p,
            .uptime_seconds = try getDaemonUptime(p),
            .active_config = active_config,
            .selected_proxies = empty_selected_proxies,
            .pid_file = pid_file,
            .lock_file = lock_file,
            .log_file = log_file,
        };
    }

    if (runtime.lock_held) {
        return .{
            .state = "running",
            .detail = runtime.detail,
            .active_config = active_config,
            .selected_proxies = empty_selected_proxies,
            .pid_file = pid_file,
            .lock_file = lock_file,
            .log_file = log_file,
        };
    }

    return .{
        .state = "stopped",
        .detail = runtime.detail,
        .pid = runtime.stale_pid,
        .active_config = active_config,
        .selected_proxies = empty_selected_proxies,
        .pid_file = pid_file,
        .lock_file = lock_file,
        .log_file = log_file,
    };
}

/// 经 cli/output.zig 渲染 status：JSON envelope（stdout，std.json 序列化）
/// 或人类可读文本（stdout）。字段名为冻结词汇（见 docs/cli/ux-workflow.md 第 3 节）。
fn emitStatus(allocator: std.mem.Allocator, out: *cli_output.Output, snapshot: *const StatusSnapshot) !void {
    if (out.mode == .json) {
        try out.success(.{
            .action = snapshot.action,
            .state = snapshot.state,
            .detail = snapshot.detail,
            .pid = snapshot.pid,
            .uptime_seconds = snapshot.uptime_seconds,
            .active_config = snapshot.active_config,
            .selected_proxies = snapshot.selected_proxies,
            .paths = .{
                .pid_file = snapshot.pid_file,
                .lock_file = snapshot.lock_file,
                .log_file = snapshot.log_file,
            },
        });
        return;
    }

    try out.print("zc status\n", .{});
    try out.print("state: {s}\n", .{snapshot.state});
    if (snapshot.detail) |detail| {
        try out.print("detail: {s}\n", .{detail});
    }
    if (snapshot.pid) |pid| {
        try out.print("pid: {d}\n", .{pid});
    } else {
        try out.print("pid: (none)\n", .{});
    }
    if (snapshot.uptime_seconds) |uptime_seconds| {
        try out.print("uptime_seconds: {d}\n", .{uptime_seconds});
    } else {
        try out.print("uptime_seconds: (unknown)\n", .{});
    }
    if (snapshot.active_config) |active_config| {
        try out.print("active_config: {s}\n", .{active_config});
    } else {
        try out.print("active_config: (none)\n", .{});
    }
    var selections_text = std.ArrayList(u8).empty;
    defer selections_text.deinit(allocator);
    try runtime_selection.appendSelectedProxiesText(&selections_text, allocator, snapshot.selected_proxies);
    try out.print("{s}", .{selections_text.items});
    try out.print("pid_file: {s}\n", .{snapshot.pid_file});
    try out.print("lock_file: {s}\n", .{snapshot.lock_file});
    try out.print("log_file: {s}\n", .{snapshot.log_file});
    try out.flush();
}

/// 打印启动后的服务信息（mixed-proxy, api-server, mode, proxies, rules）
fn parseStartPortOverride(extra_args: []const []const u8) ?u16 {
    var i: usize = 0;
    while (i < extra_args.len) : (i += 1) {
        if (std.mem.eql(u8, extra_args[i], "--port")) {
            if (i + 1 >= extra_args.len) return null;
            return std.fmt.parseInt(u16, extra_args[i + 1], 10) catch null;
        }
        if (std.mem.startsWith(u8, extra_args[i], "--port=")) {
            return std.fmt.parseInt(u16, extra_args[i]["--port=".len..], 10) catch null;
        }
    }
    return null;
}

pub fn printStartupInfo(allocator: std.mem.Allocator, config_path: ?[]const u8, extra_args: []const []const u8, out: *cli_output.Output) void {
    var cfg = blk: {
        if (config_path) |path| {
            break :blk config.load(allocator, path) catch return;
        }
        break :blk config.loadDefault(allocator) catch return;
    };
    defer cfg.deinit();

    const bind = if (!cfg.allow_lan)
        "127.0.0.1"
    else if (std.mem.eql(u8, cfg.bind_address, "*"))
        "0.0.0.0"
    else
        cfg.bind_address;

    const mixed_port = parseStartPortOverride(extra_args) orelse constants.MIXED_PORT;
    out.print("  mixed-proxy: {s}:{d}\n", .{ bind, mixed_port }) catch return;
    if (cfg.external_controller) |ec| {
        out.print("  api-server:  {s}\n", .{ec}) catch return;
    }
    out.print("  mode:        {s}\n", .{cfg.mode}) catch return;
    out.print("  proxies:     {d}\n", .{cfg.proxies.items.len}) catch return;
    out.print("  rules:       {d}\n", .{cfg.rules.items.len}) catch return;
}

/// 启动守护进程。只返回事实（LifecycleOutcome）或错误；envelope/文本由
/// main.zig 经 cli/output.zig 恰好打印一次。
pub fn startDaemon(allocator: std.mem.Allocator, config_path: ?[]const u8, extra_args: []const []const u8) !LifecycleOutcome {
    var lock_file = acquireDaemonLockFile(allocator) catch |err| switch (err) {
        error.DaemonAlreadyRunning => {
            const existing_pid = try waitForTrackedRunningPid(allocator);
            return .{ .detail = "already_running", .pid = existing_pid };
        },
        else => return err,
    };
    errdefer lock_file.close(compat.io());

    // 兼容旧版本 daemon：即使没有 lock，也不要在已有可追踪 pid 存活时再启动一个实例。
    // 这里不能用 isRunning()，因为当前 start 进程自己已经拿到了 lock。
    if (try readTrackedPid(allocator)) |existing_pid| {
        return .{ .detail = "already_running", .pid = existing_pid };
    }

    // Fork 子进程
    const fork_result = std.c.fork();
    if (fork_result < 0) {
        return error.Unexpected;
    }
    const pid: std.posix.pid_t = @intCast(fork_result);

    if (pid > 0) {
        // 父进程：轮询最多 2s，每 200ms 检查子进程是否存活
        var i: usize = 0;
        while (i < startup_poll_attempts) : (i += 1) { // 10 × 200ms = 2s
            compat.sleepNs(startup_poll_interval_ms * std.time.ns_per_ms);

            // 检查子进程是否还活着
            std.posix.kill(pid, @enumFromInt(0)) catch {
                // 子进程已退出，启动失败
                removePidFile(allocator);
                return error.StartFailed;
            };
        }

        // 子进程在 2s 后仍然存活，视为启动成功
        try writePid(allocator, pid);
        lock_file.close(compat.io());
        return .{ .pid = pid };
    }

    // 子进程：成为守护进程
    // 创建新会话
    _ = std.c.setsid();

    // 重定向标准输出/错误到日志文件
    const log_path = try getLogFilePath(allocator);
    defer allocator.free(log_path);

    const log_file = compat.fs.createFileAbsolute(log_path, .{ .truncate = false }) catch |err| {
        std.debug.print("Failed to open log file: {s}\n", .{@errorName(err)});
        return err;
    };
    const log_fd = log_file.handle;

    // 重定向 stdout 和 stderr
    _ = std.c.dup2(log_fd, std.c.STDOUT_FILENO);
    _ = std.c.dup2(log_fd, std.c.STDERR_FILENO);
    compat.posixClose(log_fd);

    // 关闭 stdin
    const dev_null = compat.fs.openFileAbsolute("/dev/null", .{}) catch null;
    if (dev_null) |file| {
        _ = std.c.dup2(file.handle, std.c.STDIN_FILENO);
        file.close(compat.io());
    }

    // 获取当前可执行文件路径
    const exe_path = compat.fs.selfExePathAlloc(allocator) catch |err| {
        std.debug.print("Failed to get exe path: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(exe_path);

    // 构建参数
    var argv_list = std.ArrayList([]const u8).empty;
    defer {
        for (argv_list.items) |arg| {
            allocator.free(arg);
        }
        argv_list.deinit(allocator);
    }

    try argv_list.append(allocator, try allocator.dupe(u8, exe_path));
    try argv_list.append(allocator, try allocator.dupe(u8, "--daemon-run"));

    if (config_path) |path| {
        try argv_list.append(allocator, try allocator.dupe(u8, "-c"));
        try argv_list.append(allocator, try allocator.dupe(u8, path));
    }
    for (extra_args) |arg| {
        try argv_list.append(allocator, try allocator.dupe(u8, arg));
    }

    // 转换为 null 终止的数组
    const argv = try allocator.alloc(?[*:0]const u8, argv_list.items.len + 1);
    defer allocator.free(argv);

    for (argv_list.items, 0..) |arg, i| {
        // 确保字符串是 null 终止的
        const sentinel_arg = try allocator.allocSentinel(u8, arg.len, 0);
        @memcpy(sentinel_arg[0..arg.len], arg);
        // 注意：我们不能在这里释放 arg，因为它还在 argv_list 里
        argv[i] = sentinel_arg.ptr;
    }
    argv[argv_list.items.len] = null;

    // 执行新的进程
    _ = std.c.execve(
        argv[0].?,
        @ptrCast(argv.ptr),
        @ptrCast(std.c.environ),
    );

    // execve 不应该返回，如果返回说明出错了
    std.debug.print("Failed to exec\n", .{});
    return error.ExecFailed;
}

/// 停止守护进程。只返回事实（LifecycleOutcome）或错误；envelope/文本由
/// main.zig 经 cli/output.zig 恰好打印一次。
pub fn stopDaemon(allocator: std.mem.Allocator) !LifecycleOutcome {
    const runtime = try inspectRuntime(allocator);
    const pid = runtime.pid orelse {
        if (runtime.lock_held) {
            return error.DaemonPidUntracked;
        }
        return .{ .detail = "already_stopped" };
    };

    // 发送 SIGTERM 信号
    std.posix.kill(pid, std.posix.SIG.TERM) catch |err| {
        if (err == error.ProcessNotFound) {
            removePidFile(allocator);
            return .{ .detail = "already_stopped" };
        }
        return err;
    };

    // 等待优雅退出
    var stopped = false;
    var i: usize = 0;
    while (i < 20) : (i += 1) { // 最多等待 2 秒
        compat.sleepNs(100 * std.time.ns_per_ms);
        _ = std.posix.kill(pid, @enumFromInt(0)) catch {
            stopped = true;
            break;
        };
    }

    if (!stopped) {
        // 强制停止
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        compat.sleepNs(100 * std.time.ns_per_ms);
    }

    // 删除 PID 文件
    removePidFile(allocator);
    return .{ .pid = pid };
}

/// 静默重启：供 reloadOrRestart（config update / config override / zc reload）
/// 使用，不产生任何 CLI 输出，调用方负责唯一的 envelope。
///
/// 保留旧 daemon 的 `-c`/`--port` 启动参数：否则 fallback restart 会把端口
/// 打回默认 mixed-port，绑定失败时旧 daemon 已被杀死、新 daemon 起不来。
/// 受监管的前台 daemon（`start --foreground`，systemd/容器 PID 1）绝不接管：
/// 杀掉它会让监管者陷入 respawn/锁竞争循环，直接拒绝。
fn restartDaemonQuiet(allocator: std.mem.Allocator, config_path: ?[]const u8) !void {
    var preserved: ?TrackedInvocation = null;
    defer if (preserved) |*inv| inv.deinit(allocator);

    if (try isRunning(allocator)) {
        preserved = captureTrackedInvocation(allocator) catch null;
        if (preserved) |inv| {
            if (inv.foreground) return error.ForegroundDaemonSupervised;
        }
        _ = try stopDaemon(allocator);
    }

    const effective_config: ?[]const u8 = config_path orelse
        (if (preserved) |inv| inv.config_path else null);

    var port_buf: [32]u8 = undefined;
    var extra_storage: [1][]const u8 = undefined;
    var extra_args: []const []const u8 = &.{};
    if (preserved) |inv| {
        if (inv.port) |port| {
            extra_storage[0] = try std.fmt.bufPrint(&port_buf, "--port={d}", .{port});
            extra_args = extra_storage[0..1];
        }
    }

    _ = try startDaemon(allocator, effective_config, extra_args);
    if ((try readTrackedPid(allocator)) == null) {
        return error.StartFailed;
    }
}

pub fn reloadDaemon(_: std.mem.Allocator, _: ?[]const u8) !void {
    return error.HotReloadUnsupported;
}

pub fn reloadOrRestart(allocator: std.mem.Allocator, config_path: ?[]const u8, apply_mode: ApplyMode) !ApplyResult {
    if (!try isRunning(allocator)) {
        return .hot_applied;
    }

    switch (apply_mode) {
        .restart => {
            try restartDaemonQuiet(allocator, config_path);
            return .restart_applied;
        },
        .hot => {
            try reloadDaemon(allocator, config_path);
            return .hot_applied;
        },
        .auto => {
            reloadDaemon(allocator, config_path) catch {
                try restartDaemonQuiet(allocator, config_path);
                return .restart_fallback;
            };
            return .hot_applied;
        },
    }
}

/// 获取状态并经 cli/output.zig 渲染（stdout）。
pub fn getStatus(allocator: std.mem.Allocator, out: *cli_output.Output) !void {
    var snapshot = try collectStatusSnapshot(allocator);
    defer snapshot.deinit(allocator);
    try emitStatus(allocator, out, &snapshot);
}

/// 查看日志（默认显示最后 50 行，持续刷新）。
/// 日志行是主输出，永远走 stdout：JSON 模式下为 JSON Lines（每行一个
/// {"line":"..."} 对象），文本模式下为时间戳行；横幅类提示是诊断，走 stderr。
pub fn viewLog(allocator: std.mem.Allocator, lines: ?usize, follow: bool, out: *cli_output.Output) !void {
    const log_path = try getLogFilePath(allocator);
    defer allocator.free(log_path);

    const file = compat.fs.openFileAbsolute(log_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            if (out.mode != .json) out.note("No log file found\n", .{}) catch {};
            return;
        }
        return err;
    };
    defer file.close(compat.io());

    // 首先显示最后 N 行
    const n = lines orelse 50;
    try printLastNLines(allocator, file, n, out);

    // 如果需要持续刷新
    if (follow) {
        if (out.mode != .json) out.note("\n--- Following log (Ctrl+C to exit) ---\n", .{}) catch {};
        var carry = std.ArrayList(u8).empty;
        defer carry.deinit(allocator);

        // 获取当前文件位置
        const stat = try file.stat(compat.io());
        var last_pos = stat.size;

        while (true) {
            compat.sleepNs(500 * std.time.ns_per_ms); // 500ms 刷新一次

            // 重新获取文件大小
            const new_stat = try file.stat(compat.io());
            const new_size = new_stat.size;

            if (new_size > last_pos) {
                // 有新内容，读取并输出
                try compat.fileSeekTo(file, last_pos);

                var buffer: [4096]u8 = undefined;
                while (true) {
                    const bytes_read = try compat.fileRead(file, &buffer);
                    if (bytes_read == 0) break;
                    try printTimestampedChunk(allocator, buffer[0..bytes_read], &carry, out);
                }

                last_pos = new_size;
            } else if (new_size < last_pos) {
                // 文件被截断或轮转，从头开始
                if (carry.items.len > 0) {
                    emitLogLine(out, carry.items);
                    carry.clearRetainingCapacity();
                }
                if (out.mode != .json) out.note("\n--- Log file rotated, restarting from beginning ---\n", .{}) catch {};
                try compat.fileSeekTo(file, 0);
                last_pos = 0;
            }
        }
    }
}

/// 打印文件最后 N 行
fn printLastNLines(allocator: std.mem.Allocator, file: compat.fs.File, n: usize, out: *cli_output.Output) !void {
    const file_size = (try file.stat(compat.io())).size;
    const max_size = 1024 * 1024 * 10; // 10MB max
    const read_size = @min(file_size, max_size);

    if (read_size == 0) {
        return;
    }

    const content = try allocator.alloc(u8, read_size);
    defer allocator.free(content);

    try compat.fileSeekTo(file, file_size - read_size);
    _ = try compat.fileReadAll(file, content);

    try printTimestampedSlice(allocator, tailLinesSlice(content, n), out);
}

/// 返回 content 中最后 n 行的切片。不足 n 行时返回整个 content（修复
/// fresh daemon 日志少于 50 行时 `zc log` 输出为空的问题）；结尾换行符
/// 不算行边界（修复 88 行取 50 只得 49 的 off-by-one）。
fn tailLinesSlice(content: []const u8, n: usize) []const u8 {
    if (content.len == 0 or n == 0) return content[content.len..];

    var line_count: usize = 0;
    var i: usize = content.len;
    if (content[i - 1] == '\n') i -= 1;
    while (i > 0) : (i -= 1) {
        if (content[i - 1] == '\n') {
            line_count += 1;
            if (line_count >= n) return content[i..];
        }
    }
    return content;
}

fn printTimestampedSlice(allocator: std.mem.Allocator, content: []const u8, out: *cli_output.Output) !void {
    var carry = std.ArrayList(u8).empty;
    defer carry.deinit(allocator);
    try printTimestampedChunk(allocator, content, &carry, out);
    if (carry.items.len > 0) {
        emitLogLine(out, carry.items);
    }
}

fn printTimestampedChunk(allocator: std.mem.Allocator, chunk: []const u8, carry: *std.ArrayList(u8), out: *cli_output.Output) !void {
    try carry.appendSlice(allocator, chunk);

    while (std.mem.indexOfScalar(u8, carry.items, '\n')) |idx| {
        const line = carry.items[0..idx];
        emitLogLine(out, line);

        const remaining = carry.items.len - (idx + 1);
        if (remaining > 0) {
            std.mem.copyForwards(u8, carry.items[0..remaining], carry.items[idx + 1 ..]);
        }
        carry.shrinkRetainingCapacity(remaining);
    }
}

/// 日志行 = 主输出 = stdout（契约 docs/cli/ux-workflow.md 第 1 节），
/// JSON 模式走 JSON Lines，文本模式走 Output.print（不再 std.debug.print 到 stderr）。
fn emitLogLine(out: *cli_output.Output, line: []const u8) void {
    if (out.mode == .json) {
        // JSON Lines：每行一个对象，无 envelope（流式约定，决策见 ux-workflow.md）。
        out.jsonLine(.{ .line = line }) catch {};
        return;
    }
    out.print("[{d}] {s}\n", .{ compat.timestamp(), line }) catch {};
    out.flush() catch {};
}

fn testPidNeverMatchesDaemon(_: std.mem.Allocator, _: i32) !bool {
    return false;
}

fn testTmpRootAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(compat.io(), allocator);
    defer allocator.free(cwd);
    return try compat.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

test "daemon lock prevents duplicate acquisition and can be reacquired after close" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try testTmpRootAlloc(allocator, &tmp);
    defer allocator.free(tmp_root);

    const lock_path = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.lock" });
    defer allocator.free(lock_path);

    var first_lock: ?compat.fs.File = try acquireDaemonLockFileAtPath(lock_path);
    defer if (first_lock) |file| file.close(compat.io());

    try std.testing.expectError(error.DaemonAlreadyRunning, acquireDaemonLockFileAtPath(lock_path));

    first_lock.?.close(compat.io());
    first_lock = null;

    var second_lock = try acquireDaemonLockFileAtPath(lock_path);
    defer second_lock.close(compat.io());
}

test "collectStatusSnapshot reports stopped state without pid file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try testTmpRootAlloc(allocator, &tmp);
    defer allocator.free(tmp_root);

    const pid_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.pid" });
    defer allocator.free(pid_file);
    const lock_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.lock" });
    defer allocator.free(lock_file);
    const log_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.log" });
    defer allocator.free(log_file);

    var snapshot = try collectStatusSnapshotAtPaths(
        allocator,
        try allocator.dupe(u8, pid_file),
        try allocator.dupe(u8, lock_file),
        try allocator.dupe(u8, log_file),
        null,
        .{
            .pid_is_daemon = testPidNeverMatchesDaemon,
        },
    );
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualStrings("stopped", snapshot.state);
    try std.testing.expect(snapshot.detail == null);
    try std.testing.expect(snapshot.pid == null);
    try std.testing.expect(snapshot.uptime_seconds == null);
    try std.testing.expect(snapshot.active_config == null);
    try std.testing.expect(std.mem.endsWith(u8, snapshot.pid_file, "zc.pid"));
    try std.testing.expect(std.mem.endsWith(u8, snapshot.lock_file, "zc.lock"));
    try std.testing.expect(std.mem.endsWith(u8, snapshot.log_file, "zc.log"));
}

test "collectStatusSnapshot reports stale pid file and removes it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try testTmpRootAlloc(allocator, &tmp);
    defer allocator.free(tmp_root);

    const pid_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.pid" });
    defer allocator.free(pid_file);
    const lock_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.lock" });
    defer allocator.free(lock_file);
    const log_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.log" });
    defer allocator.free(log_file);

    try writePidAtPath(pid_file, 999999);

    var snapshot = try collectStatusSnapshotAtPaths(
        allocator,
        try allocator.dupe(u8, pid_file),
        try allocator.dupe(u8, lock_file),
        try allocator.dupe(u8, log_file),
        null,
        .{
            .pid_is_daemon = testPidNeverMatchesDaemon,
        },
    );
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualStrings("stopped", snapshot.state);
    try std.testing.expectEqualStrings("stale_pid_file", snapshot.detail.?);
    try std.testing.expectEqual(@as(i32, 999999), snapshot.pid.?);
    try std.testing.expect(snapshot.uptime_seconds == null);
    try std.testing.expectError(error.FileNotFound, compat.fs.openFileAbsolute(snapshot.pid_file, .{}));
}

test "inspectRuntime ignores stale live pid when it is not a zc daemon" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try testTmpRootAlloc(allocator, &tmp);
    defer allocator.free(tmp_root);

    const pid_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.pid" });
    defer allocator.free(pid_file);
    const lock_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.lock" });
    defer allocator.free(lock_file);

    try writePidAtPath(pid_file, std.c.getpid());

    const runtime = try inspectRuntimeAtPathsWithInspector(allocator, pid_file, lock_file, .{
        .pid_is_daemon = testPidNeverMatchesDaemon,
    });

    try std.testing.expect(runtime.pid == null);
    try std.testing.expect(!runtime.lock_held);
    try std.testing.expectEqualStrings("stale_pid_file", runtime.detail.?);
    try std.testing.expectEqual(std.c.getpid(), runtime.stale_pid.?);
    try std.testing.expectError(error.FileNotFound, compat.fs.openFileAbsolute(pid_file, .{}));
}

test "collectStatusSnapshot reports running when lock is held but pid is untracked" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try testTmpRootAlloc(allocator, &tmp);
    defer allocator.free(tmp_root);

    const pid_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.pid" });
    defer allocator.free(pid_file);
    const lock_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.lock" });
    defer allocator.free(lock_file);
    const log_file = try compat.fs.path.join(allocator, &.{ tmp_root, "zc.log" });
    defer allocator.free(log_file);

    var held_lock = try acquireDaemonLockFileAtPath(lock_file);
    defer held_lock.close(compat.io());

    var snapshot = try collectStatusSnapshotAtPaths(
        allocator,
        try allocator.dupe(u8, pid_file),
        try allocator.dupe(u8, lock_file),
        try allocator.dupe(u8, log_file),
        null,
        .{
            .pid_is_daemon = testPidNeverMatchesDaemon,
        },
    );
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualStrings("running", snapshot.state);
    try std.testing.expectEqualStrings("lock_held_pid_untracked", snapshot.detail.?);
    try std.testing.expect(snapshot.pid == null);
    try std.testing.expect(snapshot.uptime_seconds == null);
    try std.testing.expect(snapshot.active_config == null);
}

test "commandLineLooksLikeDaemon requires zc daemon-run invocation" {
    try std.testing.expect(commandLineLooksLikeDaemon("/Users/like/.local/bin/zc --daemon-run -c /tmp/demo.yaml"));
    try std.testing.expect(!commandLineLooksLikeDaemon("/Users/like/.local/bin/zc status"));
    try std.testing.expect(!commandLineLooksLikeDaemon("/bin/zsh -lc /Users/like/.local/bin/zc --daemon-run"));
}

test "commandLineLooksLikeDaemon accepts supervised foreground daemon (D1)" {
    try std.testing.expect(commandLineLooksLikeDaemon("/usr/local/bin/zclash start --foreground"));
    try std.testing.expect(commandLineLooksLikeDaemon("/usr/bin/zc start --foreground -c /etc/zc/config.yaml"));
    try std.testing.expect(!commandLineLooksLikeDaemon("/usr/bin/zc start"));
    try std.testing.expect(!commandLineLooksLikeDaemon("/usr/bin/zc stop --foreground"));
}

test "cmdlineBufferLooksLikeDaemon parses nul-separated argv" {
    const daemon_cmdline = "/Users/like/.local/bin/zc\x00--daemon-run\x00-c\x00/tmp/demo.yaml\x00";
    const foreground_cmdline = "/usr/local/bin/zclash\x00start\x00--foreground\x00";
    const cli_cmdline = "/Users/like/.local/bin/zc\x00status\x00";

    try std.testing.expect(cmdlineBufferLooksLikeDaemon(daemon_cmdline));
    try std.testing.expect(cmdlineBufferLooksLikeDaemon(foreground_cmdline));
    try std.testing.expect(!cmdlineBufferLooksLikeDaemon(cli_cmdline));
}

test "parseTrackedInvocationFromCmdline extracts -c/--port/--foreground" {
    const allocator = std.testing.allocator;

    var bg = try parseTrackedInvocationFromCmdline(
        allocator,
        4321,
        "/Users/like/.local/bin/zc --daemon-run -c /tmp/demo.yaml --port=29101",
    );
    defer bg.deinit(allocator);
    try std.testing.expect(!bg.foreground);
    try std.testing.expectEqualStrings("/tmp/demo.yaml", bg.config_path.?);
    try std.testing.expectEqual(@as(?u16, 29101), bg.port);

    var fg = try parseTrackedInvocationFromCmdline(
        allocator,
        1,
        "/usr/local/bin/zclash\x00start\x00--foreground\x00--port\x007901\x00",
    );
    defer fg.deinit(allocator);
    try std.testing.expect(fg.foreground);
    try std.testing.expect(fg.config_path == null);
    try std.testing.expectEqual(@as(?u16, 7901), fg.port);

    var bare = try parseTrackedInvocationFromCmdline(allocator, 7, "/usr/bin/zc --daemon-run");
    defer bare.deinit(allocator);
    try std.testing.expect(!bare.foreground);
    try std.testing.expect(bare.config_path == null);
    try std.testing.expect(bare.port == null);
}

test "tailLinesSlice returns whole content when fewer than n lines" {
    const content = "l1\nl2\nl3\n";
    try std.testing.expectEqualStrings(content, tailLinesSlice(content, 50));
}

test "tailLinesSlice returns exactly the last n lines despite trailing newline" {
    const content = "l1\nl2\nl3\nl4\nl5\n";
    try std.testing.expectEqualStrings("l4\nl5\n", tailLinesSlice(content, 2));
    try std.testing.expectEqualStrings(content, tailLinesSlice(content, 5));
    try std.testing.expectEqualStrings("l5\n", tailLinesSlice(content, 1));
}

test "tailLinesSlice handles missing trailing newline and n == 0" {
    const content = "l1\nl2\nl3";
    try std.testing.expectEqualStrings("l2\nl3", tailLinesSlice(content, 2));
    try std.testing.expectEqualStrings("", tailLinesSlice(content, 0));
    try std.testing.expectEqualStrings("", tailLinesSlice("", 3));
}

test "text mode log lines go to stdout, not stderr" {
    const allocator = std.testing.allocator;

    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    var err_aw: std.Io.Writer.Allocating = .init(allocator);
    defer err_aw.deinit();
    var out = cli_output.Output.init(.text, "log", false, &out_aw.writer, &err_aw.writer);

    try printTimestampedSlice(allocator, "first line\nsecond line\n", &out);

    try std.testing.expect(std.mem.indexOf(u8, out_aw.written(), "first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_aw.written(), "second line") != null);
    try std.testing.expectEqualStrings("", err_aw.written());
}

test "json mode log lines are JSON Lines on stdout" {
    const allocator = std.testing.allocator;

    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    var err_aw: std.Io.Writer.Allocating = .init(allocator);
    defer err_aw.deinit();
    var out = cli_output.Output.init(.json, "log", false, &out_aw.writer, &err_aw.writer);

    try printTimestampedSlice(allocator, "alpha\nwith \"quotes\"\n", &out);

    var lines = std.mem.tokenizeScalar(u8, out_aw.written(), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("line") != null);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("", err_aw.written());
}

test "status json envelope preserves frozen field names and escapes strings" {
    const allocator = std.testing.allocator;

    const selections = try allocator.alloc(runtime_selection.SelectedProxy, 1);
    selections[0] = .{
        .group_name = try allocator.dupe(u8, "Pro\"xy"),
        .proxy_name = try allocator.dupe(u8, "HK 01"),
        .source = .persisted,
    };

    var snapshot = StatusSnapshot{
        .state = "running",
        .pid = 321,
        .uptime_seconds = 42,
        .active_config = try allocator.dupe(u8, "demo"),
        .selected_proxies = selections,
        .pid_file = try allocator.dupe(u8, "/tmp/zc.pid"),
        .lock_file = try allocator.dupe(u8, "/tmp/zc.lock"),
        .log_file = try allocator.dupe(u8, "/tmp/zc.log"),
    };
    defer snapshot.deinit(allocator);

    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    var err_aw: std.Io.Writer.Allocating = .init(allocator);
    defer err_aw.deinit();
    var out = cli_output.Output.init(.json, "status", false, &out_aw.writer, &err_aw.writer);

    try emitStatus(allocator, &out, &snapshot);

    // stderr 必须干净，stdout 恰好一行可解析 JSON。
    try std.testing.expectEqualStrings("", err_aw.written());
    const written = out_aw.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, std.mem.trimEnd(u8, written, "\n"), "\n") + 1);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, written, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("ok").?.bool);
    try std.testing.expectEqualStrings("status", root.get("command").?.string);

    const data = root.get("data").?.object;
    try std.testing.expectEqualStrings("status", data.get("action").?.string);
    try std.testing.expectEqualStrings("running", data.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 321), data.get("pid").?.integer);
    try std.testing.expectEqual(@as(i64, 42), data.get("uptime_seconds").?.integer);
    try std.testing.expectEqualStrings("demo", data.get("active_config").?.string);

    const selected = data.get("selected_proxies").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("Pro\"xy", selected[0].object.get("group").?.string);
    try std.testing.expectEqualStrings("HK 01", selected[0].object.get("proxy").?.string);
    try std.testing.expectEqualStrings("persisted", selected[0].object.get("source").?.string);

    const paths = data.get("paths").?.object;
    try std.testing.expectEqualStrings("/tmp/zc.pid", paths.get("pid_file").?.string);
    try std.testing.expectEqualStrings("/tmp/zc.lock", paths.get("lock_file").?.string);
    try std.testing.expectEqualStrings("/tmp/zc.log", paths.get("log_file").?.string);
}

test "status text output goes to stdout with state tokens" {
    const allocator = std.testing.allocator;
    var snapshot = StatusSnapshot{
        .state = "stopped",
        .detail = "stale_pid_file",
        .pid_file = try allocator.dupe(u8, "/tmp/zc.pid"),
        .lock_file = try allocator.dupe(u8, "/tmp/zc.lock"),
        .log_file = try allocator.dupe(u8, "/tmp/zc.log"),
    };
    defer snapshot.deinit(allocator);

    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    var err_aw: std.Io.Writer.Allocating = .init(allocator);
    defer err_aw.deinit();
    var out = cli_output.Output.init(.text, "status", false, &out_aw.writer, &err_aw.writer);

    try emitStatus(allocator, &out, &snapshot);

    try std.testing.expect(std.mem.indexOf(u8, out_aw.written(), "state: stopped") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_aw.written(), "detail: stale_pid_file") != null);
    try std.testing.expectEqualStrings("", err_aw.written());
}
