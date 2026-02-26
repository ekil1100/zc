const std = @import("std");
const config = @import("config.zig");
const constants = @import("constants.zig");

// PID 文件路径
const PID_FILE = "/tmp/zc.pid";
const LOG_FILE = "/tmp/zc.log";

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

/// 获取 PID 文件路径
pub fn getPidFilePath(allocator: std.mem.Allocator) ![]const u8 {
    // 优先使用 XDG_RUNTIME_DIR，否则使用 /tmp
    if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |runtime_dir| {
        const path = try std.fs.path.join(allocator, &.{ runtime_dir, "zc.pid" });
        allocator.free(runtime_dir);
        return path;
    } else |_| {
        return try allocator.dupe(u8, PID_FILE);
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
    
    const file = try std.fs.createFileAbsolute(pid_file, .{});
    defer file.close();
    
    const pid_str = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(pid_str);
    
    try file.writeAll(pid_str);
}

/// 删除 PID 文件
pub fn removePidFile(allocator: std.mem.Allocator) void {
    const pid_file = getPidFilePath(allocator) catch return;
    defer allocator.free(pid_file);
    std.fs.deleteFileAbsolute(pid_file) catch {};
}

/// 检查进程是否正在运行
pub fn isRunning(allocator: std.mem.Allocator) !bool {
    const pid = try readPid(allocator) orelse return false;

    // 发送信号 0 检查进程是否存在
    std.posix.kill(pid, 0) catch return false;

    // Linux: 读取 /proc/<pid>/comm 验证进程名，防止 PID 回收误判
    if (comptime @import("builtin").os.tag == .linux) {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return false;
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            removePidFile(allocator);
            return false;
        };
        defer file.close();
        var buf: [256]u8 = undefined;
        const n = file.read(&buf) catch return false;
        const comm = std.mem.trimRight(u8, buf[0..n], "\n");
        if (!std.mem.eql(u8, comm, "zc")) {
            removePidFile(allocator);
            return false;
        }
    }

    return true;
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
pub fn startDaemon(allocator: std.mem.Allocator, config_path: ?[]const u8, json_output: bool) !void {
    // 检查是否已经在运行
    if (try isRunning(allocator)) {
        const existing_pid = try readPid(allocator);
        if (json_output) {
            printCliOk(json_output, "start", "running", "already_running", existing_pid);
        } else {
            std.debug.print("zc daemon already running (pid: {d})\n", .{existing_pid.?});
        }
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
        while (i < 10) : (i += 1) { // 10 × 200ms = 2s
            std.Thread.sleep(200 * std.time.ns_per_ms);

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
    const pid = try readPid(allocator) orelse {
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
pub fn restartDaemon(allocator: std.mem.Allocator, config_path: ?[]const u8, json_output: bool) !void {
    const was_running = try isRunning(allocator);

    if (was_running) {
        try stopDaemon(allocator, json_output);
    } else {
        printCliOk(json_output, "restart", "stopped", "service_was_stopped", null);
    }

    try startDaemon(allocator, config_path, json_output);
    printCliOk(json_output, "restart", "running", null, null);
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
            try restartDaemon(allocator, config_path, json_output);
            return .restart_applied;
        },
        .hot => {
            try reloadDaemon(allocator, config_path, json_output);
            return .hot_applied;
        },
        .auto => {
            reloadDaemon(allocator, config_path, json_output) catch {
                try restartDaemon(allocator, config_path, json_output);
                return .restart_fallback;
            };
            return .hot_applied;
        },
    }
}

/// 获取状态
pub fn getStatus(allocator: std.mem.Allocator, json_output: bool) !void {
    const pid = try readPid(allocator);

    if (pid) |p| {
        if (try isRunning(allocator)) {
            printCliOk(json_output, "status", "running", null, p);
        } else {
            printCliOk(json_output, "status", "stopped", "stale_pid_file", p);
            removePidFile(allocator);
        }
    } else {
        printCliOk(json_output, "status", "stopped", null, null);
    }
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
    try printLastNLines(file, n);

    // 如果需要持续刷新
    if (follow) {
        std.debug.print("\n--- Following log (Ctrl+C to exit) ---\n", .{});

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
                    std.debug.print("{s}", .{buffer[0..bytes_read]});
                }

                last_pos = new_size;
            } else if (new_size < last_pos) {
                // 文件被截断或轮转，从头开始
                std.debug.print("\n--- Log file rotated, restarting from beginning ---\n", .{});
                try file.seekTo(0);
                last_pos = 0;
            }
        }
    }
}

/// 打印文件最后 N 行
fn printLastNLines(file: std.fs.File, n: usize) !void {
    const file_size = (try file.stat()).size;
    const max_size = 1024 * 1024 * 10; // 10MB max
    const read_size = @min(file_size, max_size);

    if (read_size == 0) {
        return;
    }

    // 分配缓冲区
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    // 输出内容
    std.debug.print("{s}", .{content[start_pos..]});
}
