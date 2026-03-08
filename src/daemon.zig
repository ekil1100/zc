const std = @import("std");
const config = @import("config.zig");
const constants = @import("constants.zig");

// PID 文件路径
const PID_FILE = "/tmp/zc.pid";
const LOCK_FILE = "/tmp/zc.lock";
const LOG_FILE = "/tmp/zc.log";
const startup_poll_interval_ms: u64 = 200;
const startup_poll_attempts: usize = 10;
const process_scan_max_output_bytes: usize = 16 * 1024 * 1024;

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

const StatusSnapshot = struct {
    action: []const u8 = "status",
    state: []const u8,
    detail: ?[]const u8 = null,
    pid: ?i32 = null,
    uptime_seconds: ?i64 = null,
    active_config: ?[]const u8 = null,
    pid_file: []const u8,
    lock_file: []const u8,
    log_file: []const u8,

    fn deinit(self: *StatusSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.pid_file);
        allocator.free(self.lock_file);
        allocator.free(self.log_file);
        if (self.active_config) |active_config| allocator.free(active_config);
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
    if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |runtime_dir| {
        const path = try std.fs.path.join(allocator, &.{ runtime_dir, basename });
        allocator.free(runtime_dir);
        return path;
    } else |_| {
        return try allocator.dupe(u8, fallback);
    }
}

/// 获取日志文件路径
pub fn getLogFilePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        return try allocator.dupe(u8, LOG_FILE);
    };
    defer allocator.free(home);

    // 使用 ~/.local/share/zc/zc.log
    const log_dir = try std.fs.path.join(allocator, &.{ home, ".local/share/zc" });
    defer allocator.free(log_dir);

    // 创建目录
    std.fs.makeDirAbsolute(log_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            // 回退到 /tmp
            return try allocator.dupe(u8, LOG_FILE);
        }
    };

    return try std.fs.path.join(allocator, &.{ log_dir, "zc.log" });
}

/// 读取 PID 文件
pub fn readPid(allocator: std.mem.Allocator) !?i32 {
    const pid_file = try getPidFilePath(allocator);
    defer allocator.free(pid_file);

    return readPidAtPath(pid_file);
}

fn readPidAtPath(pid_file: []const u8) !?i32 {
    const file = std.fs.openFileAbsolute(pid_file, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    var buf: [32]u8 = undefined;
    const n = try file.read(&buf);
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
    const file = try std.fs.createFileAbsolute(pid_file, .{});
    defer file.close();

    var buf: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&buf, "{d}\n", .{pid});
    try file.writeAll(pid_str);
}

/// 删除 PID 文件
pub fn removePidFile(allocator: std.mem.Allocator) void {
    const pid_file = getPidFilePath(allocator) catch return;
    defer allocator.free(pid_file);
    removePidFileAtPath(pid_file);
}

fn removePidFileAtPath(pid_file: []const u8) void {
    std.fs.deleteFileAbsolute(pid_file) catch {};
}

fn isPidRunning(allocator: std.mem.Allocator, pid: i32) !bool {
    std.posix.kill(pid, 0) catch return false;

    // Linux: 读取 /proc/<pid>/comm 验证进程名，防止 PID 回收误判
    if (comptime @import("builtin").os.tag == .linux) {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return false;
        const file = std.fs.openFileAbsolute(path, .{}) catch return false;
        defer file.close();
        var buf: [256]u8 = undefined;
        const n = file.read(&buf) catch return false;
        const comm = std.mem.trimRight(u8, buf[0..n], "\n");
        if (!std.mem.eql(u8, comm, "zc")) {
            return false;
        }
    }

    _ = allocator;
    return true;
}

fn discoverDaemonPid(allocator: std.mem.Allocator) !?i32 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ps", "-ww", "-axo", "pid=,comm=,args=" },
        .max_output_bytes = process_scan_max_output_bytes,
    }) catch return null;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term.Exited != 0) return null;

    if (parseDaemonPidCandidateFromPsOutput(result.stdout)) |pid| {
        if (try isPidRunning(allocator, pid)) return pid;
    }

    const pgrep_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "pgrep", "-f", "--", "--daemon-run" },
        .max_output_bytes = process_scan_max_output_bytes,
    }) catch return null;
    defer {
        allocator.free(pgrep_result.stdout);
        allocator.free(pgrep_result.stderr);
    }
    if (pgrep_result.term.Exited != 0) return null;

    var lines = std.mem.tokenizeScalar(u8, pgrep_result.stdout, '\n');
    while (lines.next()) |line| {
        const pid = parsePidFirstToken(line) orelse continue;
        if (pid == std.c.getpid()) continue;
        if (try isPidRunning(allocator, pid)) return pid;
    }

    return null;
}

fn parseDaemonPidCandidateFromPsOutput(output: []const u8) ?i32 {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const pid_text = parts.next() orelse continue;
        const pid = std.fmt.parseInt(i32, pid_text, 10) catch continue;
        if (pid == std.c.getpid()) continue;

        const after_pid = std.mem.trimLeft(u8, trimmed[pid_text.len..], " \t");
        var after_pid_parts = std.mem.tokenizeAny(u8, after_pid, " \t");
        const _comm_text = after_pid_parts.next() orelse continue;
        const args = std.mem.trimLeft(u8, after_pid[_comm_text.len..], " \t");
        var arg_parts = std.mem.tokenizeAny(u8, args, " \t");
        const argv0 = arg_parts.next() orelse continue;

        if (!std.mem.eql(u8, std.fs.path.basename(argv0), "zc")) continue;
        if (std.mem.indexOf(u8, args, "--daemon-run") == null) continue;
        return pid;
    }

    return null;
}

fn parsePidFirstToken(line: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return null;

    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    const pid_text = parts.next() orelse return null;
    return std.fmt.parseInt(i32, pid_text, 10) catch null;
}

fn inspectRuntimeAtPaths(allocator: std.mem.Allocator, pid_file: []const u8, lock_file: []const u8) !RuntimeState {
    var stale_pid: ?i32 = null;

    if (try readPidAtPath(pid_file)) |pid| {
        if (try isPidRunning(allocator, pid)) {
            return .{
                .pid = pid,
                .lock_held = true,
            };
        }
        stale_pid = pid;
        removePidFileAtPath(pid_file);
    }

    if (try discoverDaemonPid(allocator)) |pid| {
        writePidAtPath(pid_file, pid) catch {};
        return .{
            .pid = pid,
            .lock_held = true,
        };
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
        std.Thread.sleep(startup_poll_interval_ms * std.time.ns_per_ms);
    }
    return null;
}

fn duplicateWithoutCloexec(file: std.fs.File) !std.fs.File {
    const dup_fd = try std.posix.dup(file.handle);
    file.close();
    return .{ .handle = dup_fd };
}

fn acquireDaemonLockFileAtPath(lock_file_path: []const u8) !std.fs.File {
    const lock_file = std.fs.createFileAbsolute(lock_file_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.DaemonAlreadyRunning,
        else => return err,
    };
    errdefer lock_file.close();
    return try duplicateWithoutCloexec(lock_file);
}

fn acquireDaemonLockFile(allocator: std.mem.Allocator) !std.fs.File {
    const lock_file_path = try getLockFilePath(allocator);
    defer allocator.free(lock_file_path);
    return try acquireDaemonLockFileAtPath(lock_file_path);
}

fn isDaemonLockHeldAtPath(lock_file_path: []const u8) !bool {
    var lock_file = acquireDaemonLockFileAtPath(lock_file_path) catch |err| switch (err) {
        error.DaemonAlreadyRunning => return true,
        else => return err,
    };
    lock_file.close();
    return false;
}

fn printAlreadyRunning(json_output: bool, pid: ?i32) void {
    if (json_output) {
        printCliOk(json_output, "start", "running", "already_running", pid);
        return;
    }

    if (pid) |p| {
        std.debug.print("zc daemon already running (pid: {d})\n", .{p});
    } else {
        std.debug.print("zc daemon already running or startup is in progress\n", .{});
    }
}

/// 检查进程是否正在运行
pub fn isRunning(allocator: std.mem.Allocator) !bool {
    return (try inspectRuntime(allocator)).isRunning();
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

fn getDaemonUptime(pid: ?i32) !?i64 {
    const p = pid orelse return null;
    var buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&buf, "ps -o etimes= -p {d}", .{p});
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "sh", "-c", cmd },
    }) catch return null;
    defer {
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }
    if (result.term.Exited != 0) return null;
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

    const runtime = try inspectRuntimeAtPaths(allocator, pid_file, lock_file);
    if (runtime.pid) |p| {
        return .{
            .state = "running",
            .detail = runtime.detail,
            .pid = p,
            .uptime_seconds = try getDaemonUptime(p),
            .active_config = active_config,
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
        .pid_file = pid_file,
        .lock_file = lock_file,
        .log_file = log_file,
    };
}

fn collectStatusSnapshotAtPaths(
    allocator: std.mem.Allocator,
    pid_file: []const u8,
    lock_file: []const u8,
    log_file: []const u8,
    active_config: ?[]const u8,
) !StatusSnapshot {
    const runtime = try inspectRuntimeAtPaths(allocator, pid_file, lock_file);
    if (runtime.pid) |p| {
        return .{
            .state = "running",
            .detail = runtime.detail,
            .pid = p,
            .uptime_seconds = try getDaemonUptime(p),
            .active_config = active_config,
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
        .pid_file = pid_file,
        .lock_file = lock_file,
        .log_file = log_file,
    };
}

fn appendJsonStringEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |ch| switch (ch) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '"' => try out.appendSlice(allocator, "\\\""),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try out.append(allocator, ch),
    };
    try out.append(allocator, '"');
}

fn formatStatusJson(allocator: std.mem.Allocator, snapshot: *const StatusSnapshot) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"ok\":true,\"data\":{");
    try out.appendSlice(allocator, "\"action\":\"status\"");
    try out.writer(allocator).print(",\"state\":\"{s}\"", .{snapshot.state});
    if (snapshot.detail) |detail| {
        try out.writer(allocator).print(",\"detail\":\"{s}\"", .{detail});
    }
    if (snapshot.pid) |pid| {
        try out.writer(allocator).print(",\"pid\":{d}", .{pid});
    }
    if (snapshot.uptime_seconds) |uptime_seconds| {
        try out.writer(allocator).print(",\"uptime_seconds\":{d}", .{uptime_seconds});
    } else {
        try out.appendSlice(allocator, ",\"uptime_seconds\":null");
    }
    try out.appendSlice(allocator, ",\"active_config\":");
    if (snapshot.active_config) |active_config| {
        try appendJsonStringEscaped(&out, allocator, active_config);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, ",\"paths\":{");
    try out.appendSlice(allocator, "\"pid_file\":");
    try appendJsonStringEscaped(&out, allocator, snapshot.pid_file);
    try out.appendSlice(allocator, ",\"lock_file\":");
    try appendJsonStringEscaped(&out, allocator, snapshot.lock_file);
    try out.appendSlice(allocator, ",\"log_file\":");
    try appendJsonStringEscaped(&out, allocator, snapshot.log_file);
    try out.appendSlice(allocator, "}}}\n");

    return out.toOwnedSlice(allocator);
}

fn emitStatusJson(allocator: std.mem.Allocator, snapshot: *const StatusSnapshot) !void {
    const text = try formatStatusJson(allocator, snapshot);
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
}

fn emitStatusText(snapshot: *const StatusSnapshot) void {
    std.debug.print("zc status\n", .{});
    std.debug.print("state: {s}\n", .{snapshot.state});
    if (snapshot.detail) |detail| {
        std.debug.print("detail: {s}\n", .{detail});
    }
    if (snapshot.pid) |pid| {
        std.debug.print("pid: {d}\n", .{pid});
    } else {
        std.debug.print("pid: (none)\n", .{});
    }
    if (snapshot.uptime_seconds) |uptime_seconds| {
        std.debug.print("uptime_seconds: {d}\n", .{uptime_seconds});
    } else {
        std.debug.print("uptime_seconds: (unknown)\n", .{});
    }
    if (snapshot.active_config) |active_config| {
        std.debug.print("active_config: {s}\n", .{active_config});
    } else {
        std.debug.print("active_config: (none)\n", .{});
    }
    std.debug.print("pid_file: {s}\n", .{snapshot.pid_file});
    std.debug.print("lock_file: {s}\n", .{snapshot.lock_file});
    std.debug.print("log_file: {s}\n", .{snapshot.log_file});
}

/// 打印启动后的服务信息（mixed-proxy, api-server, mode, proxies, rules）
fn printStartupInfo(allocator: std.mem.Allocator) void {
    var cfg = config.loadDefault(allocator) catch return;
    defer cfg.deinit();

    const bind = if (!cfg.allow_lan)
        "127.0.0.1"
    else if (std.mem.eql(u8, cfg.bind_address, "*"))
        "0.0.0.0"
    else
        cfg.bind_address;

    std.debug.print("  mixed-proxy: {s}:{d}\n", .{ bind, constants.MIXED_PORT });
    if (cfg.external_controller) |ec| {
        std.debug.print("  api-server:  {s}\n", .{ec});
    }
    std.debug.print("  mode:        {s}\n", .{cfg.mode});
    std.debug.print("  proxies:     {d}\n", .{cfg.proxies.items.len});
    std.debug.print("  rules:       {d}\n", .{cfg.rules.items.len});
}

/// 启动守护进程
pub fn startDaemon(allocator: std.mem.Allocator, config_path: ?[]const u8, json_output: bool, extra_args: []const []const u8) !void {
    var lock_file = acquireDaemonLockFile(allocator) catch |err| switch (err) {
        error.DaemonAlreadyRunning => {
            const existing_pid = try waitForTrackedRunningPid(allocator);
            printAlreadyRunning(json_output, existing_pid);
            return;
        },
        else => return err,
    };
    errdefer lock_file.close();

    // 兼容旧版本 daemon：即使没有 lock，也不要在已有可追踪 pid 存活时再启动一个实例。
    // 这里不能用 isRunning()，因为当前 start 进程自己已经拿到了 lock。
    if (try readTrackedPid(allocator)) |existing_pid| {
        printAlreadyRunning(json_output, existing_pid);
        return;
    }

    // Fork 子进程
    const pid = std.posix.fork() catch |err| {
        std.debug.print("Failed to fork: {s}\n", .{@errorName(err)});
        return err;
    };

    if (pid > 0) {
        // 父进程：轮询最多 2s，每 200ms 检查子进程是否存活
        const log_path = getLogFilePath(allocator) catch null;
        defer if (log_path) |p| allocator.free(p);

        var i: usize = 0;
        while (i < startup_poll_attempts) : (i += 1) { // 10 × 200ms = 2s
            std.Thread.sleep(startup_poll_interval_ms * std.time.ns_per_ms);

            // 检查子进程是否还活着
            std.posix.kill(pid, 0) catch {
                // 子进程已退出，启动失败
                if (json_output) {
                    printCliError(json_output, "START_FAILED", "daemon exited during startup", "check `zc log --no-follow` for details");
                } else {
                    std.debug.print("zc daemon failed to start\n", .{});
                    std.debug.print("  error: daemon exited during startup\n", .{});
                    if (log_path) |lp| {
                        std.debug.print("  hint:  check `zc log` or {s}\n", .{lp});
                    } else {
                        std.debug.print("  hint:  check `zc log --no-follow`\n", .{});
                    }
                }
                removePidFile(allocator);
                return error.StartFailed;
            };
        }

        // 子进程在 2s 后仍然存活，视为启动成功
        try writePid(allocator, pid);
        lock_file.close();

        if (json_output) {
            printCliOk(json_output, "start", "running", null, pid);
        } else {
            std.debug.print("zc daemon started (pid: {d})\n", .{pid});

            // 加载配置以显示服务信息
            printStartupInfo(allocator);

            if (log_path) |lp| {
                std.debug.print("  log:         {s}\n", .{lp});
            }
        }
        return;
    }

    // 子进程：成为守护进程
    // 创建新会话
    _ = std.posix.setsid() catch {};

    // 重定向标准输出/错误到日志文件
    const log_path = try getLogFilePath(allocator);
    defer allocator.free(log_path);

    const log_fd = std.posix.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch |err| {
        std.debug.print("Failed to open log file: {s}\n", .{@errorName(err)});
        return err;
    };

    // 重定向 stdout 和 stderr
    std.posix.dup2(log_fd, std.posix.STDOUT_FILENO) catch {};
    std.posix.dup2(log_fd, std.posix.STDERR_FILENO) catch {};
    std.posix.close(log_fd);

    // 关闭 stdin
    const dev_null = std.posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch null;
    if (dev_null) |fd| {
        std.posix.dup2(fd, std.posix.STDIN_FILENO) catch {};
        std.posix.close(fd);
    }

    // 获取当前可执行文件路径
    const exe_path = std.fs.selfExePathAlloc(allocator) catch |err| {
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
    const err = std.posix.execvpeZ(
        argv[0].?,
        @ptrCast(argv.ptr),
        @ptrCast(std.c.environ),
    );

    // execve 不应该返回，如果返回说明出错了
    std.debug.print("Failed to exec: {s}\n", .{@errorName(err)});
    return err;
}

/// 停止守护进程
pub fn stopDaemon(allocator: std.mem.Allocator, json_output: bool) !void {
    const runtime = try inspectRuntime(allocator);
    const pid = runtime.pid orelse {
        if (runtime.lock_held) {
            printCliError(json_output, "STOP_FAILED", "daemon appears to be running but pid is not trackable", "check `zc status`, `ps`, and runtime files before retrying `zc stop`");
            return error.DaemonPidUntracked;
        }
        printCliOk(json_output, "stop", "stopped", "already_stopped", null);
        return;
    };

    // 发送 SIGTERM 信号
    std.posix.kill(pid, std.posix.SIG.TERM) catch |err| {
        if (err == error.ProcessNotFound) {
            printCliOk(json_output, "stop", "stopped", "already_stopped", null);
            removePidFile(allocator);
            return;
        }
        printCliError(json_output, "STOP_FAILED", "failed to send terminate signal", "verify process permissions and retry `zc stop`");
        return err;
    };

    // 等待优雅退出
    var stopped = false;
    var i: usize = 0;
    while (i < 20) : (i += 1) { // 最多等待 2 秒
        std.Thread.sleep(100 * std.time.ns_per_ms);
        _ = std.posix.kill(pid, 0) catch {
            stopped = true;
            break;
        };
    }

    if (!stopped) {
        // 强制停止
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    // 删除 PID 文件
    removePidFile(allocator);
    printCliOk(json_output, "stop", "stopped", null, pid);
}

/// 重启守护进程
pub fn restartDaemon(allocator: std.mem.Allocator, config_path: ?[]const u8, json_output: bool, extra_args: []const []const u8) !void {
    const was_running = try isRunning(allocator);

    if (was_running) {
        try stopDaemon(allocator, json_output);
    } else {
        printCliOk(json_output, "restart", "stopped", "service_was_stopped", null);
    }

    try startDaemon(allocator, config_path, json_output, extra_args);
    const pid = try readTrackedPid(allocator) orelse {
        printCliError(json_output, "RESTART_FAILED", "daemon did not become trackable after restart", "check `zc status` and `zc log --no-follow` for recovery details");
        return error.StartFailed;
    };
    printCliOk(json_output, "restart", "running", null, pid);
}

pub fn reloadDaemon(_: std.mem.Allocator, _: ?[]const u8, _: bool) !void {
    return error.HotReloadUnsupported;
}

pub fn reloadOrRestart(allocator: std.mem.Allocator, config_path: ?[]const u8, json_output: bool, apply_mode: ApplyMode) !ApplyResult {
    if (!try isRunning(allocator)) {
        return .hot_applied;
    }

    switch (apply_mode) {
        .restart => {
            try restartDaemon(allocator, config_path, json_output, &.{});
            return .restart_applied;
        },
        .hot => {
            try reloadDaemon(allocator, config_path, json_output);
            return .hot_applied;
        },
        .auto => {
            reloadDaemon(allocator, config_path, json_output) catch {
                try restartDaemon(allocator, config_path, json_output, &.{});
                return .restart_fallback;
            };
            return .hot_applied;
        },
    }
}

/// 获取状态
pub fn getStatus(allocator: std.mem.Allocator, json_output: bool) !void {
    var snapshot = try collectStatusSnapshot(allocator);
    defer snapshot.deinit(allocator);

    if (json_output) {
        try emitStatusJson(allocator, &snapshot);
        return;
    }

    emitStatusText(&snapshot);
}

/// 查看日志（默认显示最后 50 行，持续刷新）
pub fn viewLog(allocator: std.mem.Allocator, lines: ?usize, follow: bool) !void {
    const log_path = try getLogFilePath(allocator);
    defer allocator.free(log_path);

    const file = std.fs.openFileAbsolute(log_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No log file found\n", .{});
            return;
        }
        return err;
    };
    defer file.close();

    // 首先显示最后 N 行
    const n = lines orelse 50;
    try printLastNLines(allocator, file, n);

    // 如果需要持续刷新
    if (follow) {
        std.debug.print("\n--- Following log (Ctrl+C to exit) ---\n", .{});
        var carry = std.ArrayList(u8).empty;
        defer carry.deinit(allocator);

        // 获取当前文件位置
        const stat = try file.stat();
        var last_pos = stat.size;

        while (true) {
            std.Thread.sleep(500 * std.time.ns_per_ms); // 500ms 刷新一次

            // 重新获取文件大小
            const new_stat = try file.stat();
            const new_size = new_stat.size;

            if (new_size > last_pos) {
                // 有新内容，读取并输出
                try file.seekTo(last_pos);

                var buffer: [4096]u8 = undefined;
                while (true) {
                    const bytes_read = try file.read(&buffer);
                    if (bytes_read == 0) break;
                    try printTimestampedChunk(allocator, buffer[0..bytes_read], &carry);
                }

                last_pos = new_size;
            } else if (new_size < last_pos) {
                // 文件被截断或轮转，从头开始
                if (carry.items.len > 0) {
                    printTimestampedLine(carry.items);
                    carry.clearRetainingCapacity();
                }
                std.debug.print("\n--- Log file rotated, restarting from beginning ---\n", .{});
                try file.seekTo(0);
                last_pos = 0;
            }
        }
    }
}

/// 打印文件最后 N 行
fn printLastNLines(allocator: std.mem.Allocator, file: std.fs.File, n: usize) !void {
    const file_size = (try file.stat()).size;
    const max_size = 1024 * 1024 * 10; // 10MB max
    const read_size = @min(file_size, max_size);

    if (read_size == 0) {
        return;
    }

    const content = try allocator.alloc(u8, read_size);
    defer allocator.free(content);

    try file.seekTo(file_size - read_size);
    _ = try file.readAll(content);

    // 找到最后 N 行的起始位置
    var line_count: usize = 0;
    var start_pos: usize = content.len;

    var i: usize = content.len;
    while (i > 0) : (i -= 1) {
        if (content[i - 1] == '\n') {
            line_count += 1;
            if (line_count >= n) {
                start_pos = i;
                break;
            }
        }
    }

    try printTimestampedSlice(allocator, content[start_pos..]);
}

fn printTimestampedSlice(allocator: std.mem.Allocator, content: []const u8) !void {
    var carry = std.ArrayList(u8).empty;
    defer carry.deinit(allocator);
    try printTimestampedChunk(allocator, content, &carry);
    if (carry.items.len > 0) {
        printTimestampedLine(carry.items);
    }
}

fn printTimestampedChunk(allocator: std.mem.Allocator, chunk: []const u8, carry: *std.ArrayList(u8)) !void {
    try carry.appendSlice(allocator, chunk);

    while (std.mem.indexOfScalar(u8, carry.items, '\n')) |idx| {
        const line = carry.items[0..idx];
        printTimestampedLine(line);

        const remaining = carry.items.len - (idx + 1);
        if (remaining > 0) {
            std.mem.copyForwards(u8, carry.items[0..remaining], carry.items[idx + 1 ..]);
        }
        carry.shrinkRetainingCapacity(remaining);
    }
}

fn printTimestampedLine(line: []const u8) void {
    const ts = std.time.timestamp();
    std.debug.print("[{d}] {s}\n", .{ ts, line });
}

test "daemon lock prevents duplicate acquisition and can be reacquired after close" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);

    const lock_path = try std.fs.path.join(allocator, &.{ tmp_root, "zc.lock" });
    defer allocator.free(lock_path);

    var first_lock: ?std.fs.File = try acquireDaemonLockFileAtPath(lock_path);
    defer if (first_lock) |file| file.close();

    try std.testing.expectError(error.DaemonAlreadyRunning, acquireDaemonLockFileAtPath(lock_path));

    first_lock.?.close();
    first_lock = null;

    var second_lock = try acquireDaemonLockFileAtPath(lock_path);
    defer second_lock.close();
}

test "collectStatusSnapshot reports stopped state without pid file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);

    const pid_file = try std.fs.path.join(allocator, &.{ tmp_root, "zc.pid" });
    defer allocator.free(pid_file);
    const lock_file = try std.fs.path.join(allocator, &.{ tmp_root, "zc.lock" });
    defer allocator.free(lock_file);
    const log_file = try std.fs.path.join(allocator, &.{ tmp_root, "zc.log" });
    defer allocator.free(log_file);

    var snapshot = try collectStatusSnapshotAtPaths(
        allocator,
        try allocator.dupe(u8, pid_file),
        try allocator.dupe(u8, lock_file),
        try allocator.dupe(u8, log_file),
        null,
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

    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);

    const pid_file = try std.fs.path.join(allocator, &.{ tmp_root, "zc.pid" });
    defer allocator.free(pid_file);
    const lock_file = try std.fs.path.join(allocator, &.{ tmp_root, "zc.lock" });
    defer allocator.free(lock_file);
    const log_file = try std.fs.path.join(allocator, &.{ tmp_root, "zc.log" });
    defer allocator.free(log_file);

    try writePidAtPath(pid_file, 999999);

    var snapshot = try collectStatusSnapshotAtPaths(
        allocator,
        try allocator.dupe(u8, pid_file),
        try allocator.dupe(u8, lock_file),
        try allocator.dupe(u8, log_file),
        null,
    );
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualStrings("stopped", snapshot.state);
    try std.testing.expectEqualStrings("stale_pid_file", snapshot.detail.?);
    try std.testing.expectEqual(@as(i32, 999999), snapshot.pid.?);
    try std.testing.expect(snapshot.uptime_seconds == null);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(snapshot.pid_file, .{}));
}

test "collectStatusSnapshot reports running when lock is held but pid is untracked" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);

    const pid_file = try std.fs.path.join(allocator, &.{ tmp_root, "zc.pid" });
    defer allocator.free(pid_file);
    const lock_file = try std.fs.path.join(allocator, &.{ tmp_root, "zc.lock" });
    defer allocator.free(lock_file);
    const log_file = try std.fs.path.join(allocator, &.{ tmp_root, "zc.log" });
    defer allocator.free(log_file);

    var held_lock = try acquireDaemonLockFileAtPath(lock_file);
    defer held_lock.close();

    var snapshot = try collectStatusSnapshotAtPaths(
        allocator,
        try allocator.dupe(u8, pid_file),
        try allocator.dupe(u8, lock_file),
        try allocator.dupe(u8, log_file),
        null,
    );
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualStrings("running", snapshot.state);
    try std.testing.expectEqualStrings("lock_held_pid_untracked", snapshot.detail.?);
    try std.testing.expect(snapshot.pid == null);
    try std.testing.expect(snapshot.uptime_seconds == null);
    try std.testing.expect(snapshot.active_config == null);
}

test "formatStatusJson preserves status compatibility fields and adds rich data" {
    const allocator = std.testing.allocator;
    var snapshot = StatusSnapshot{
        .state = "running",
        .pid = 321,
        .uptime_seconds = 42,
        .active_config = try allocator.dupe(u8, "demo"),
        .pid_file = try allocator.dupe(u8, "/tmp/zc.pid"),
        .lock_file = try allocator.dupe(u8, "/tmp/zc.lock"),
        .log_file = try allocator.dupe(u8, "/tmp/zc.log"),
    };
    defer snapshot.deinit(allocator);

    const out = try formatStatusJson(allocator, &snapshot);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"action\":\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"state\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"pid\":321") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"uptime_seconds\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"active_config\":\"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"paths\":{\"pid_file\":\"/tmp/zc.pid\",\"lock_file\":\"/tmp/zc.lock\",\"log_file\":\"/tmp/zc.log\"}") != null);
}

test "parseDaemonPidCandidateFromPsOutput finds daemon-run process" {
    const output =
        \\  100 /usr/bin/login /usr/bin/login -pfl like /bin/zsh -l
        \\62559 /Users/like/.local/bin/zc /Users/like/.local/bin/zc --daemon-run
        \\71242 rg rg zc
        \\
    ;

    const pid = parseDaemonPidCandidateFromPsOutput(output);
    try std.testing.expectEqual(@as(?i32, 62559), pid);
}

test "parseDaemonPidCandidateFromPsOutput accepts full args output" {
    const output =
        \\81256 /System/Library/ExtensionKit/Extensions/ClassroomSettings.appex/Contents/MacOS/ClassroomSettings /System/Library/ExtensionKit/Extensions/ClassroomSettings.appex/Contents/MacOS/ClassroomSettings -LaunchArguments xxx
        \\62559 /Users/like/.local/bin/zc /Users/like/.local/bin/zc --daemon-run -c /Users/like/.config/zc/configs/D5koNO7H.yaml
        \\
    ;

    const pid = parseDaemonPidCandidateFromPsOutput(output);
    try std.testing.expectEqual(@as(?i32, 62559), pid);
}

test "parseDaemonPidCandidateFromPsOutput ignores shell wrapper processes" {
    const output =
        \\62558 /bin/zsh /bin/zsh -lc /Users/like/.local/bin/zc --daemon-run
        \\62559 /Users/like/.local/bin/zc /Users/like/.local/bin/zc --daemon-run
        \\
    ;

    const pid = parseDaemonPidCandidateFromPsOutput(output);
    try std.testing.expectEqual(@as(?i32, 62559), pid);
}

test "parseDaemonPidCandidateFromPsOutput tolerates truncated comm column on macOS" {
    const output =
        \\14597 /Users/like/.loc /Users/like/.local/bin/zc --daemon-run
        \\
    ;

    const pid = parseDaemonPidCandidateFromPsOutput(output);
    try std.testing.expectEqual(@as(?i32, 14597), pid);
}

test "parsePidFirstToken accepts pgrep pid-only and pid-with-command lines" {
    try std.testing.expectEqual(@as(?i32, 14597), parsePidFirstToken("14597"));
    try std.testing.expectEqual(@as(?i32, 14597), parsePidFirstToken("14597 /Users/like/.local/bin/zc --daemon-run"));
    try std.testing.expectEqual(@as(?i32, null), parsePidFirstToken("not-a-pid"));
}
