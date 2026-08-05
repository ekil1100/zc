const std = @import("std");
const compat = @import("compat.zig");
const builtin = @import("builtin");
const config = @import("config.zig");
const constants = @import("constants.zig");
const controller_endpoint = @import("controller_endpoint.zig");
const runtime_selection = @import("runtime_selection.zig");
const runtime_descriptor = @import("runtime_descriptor.zig");
const runtime_dir = @import("runtime_dir.zig");
const socket_options = @import("socket_options.zig");
const cli_output = @import("cli/output.zig");
const startup_poll_interval_ms: u64 = 25;
const startup_lock_wait_ms: i64 = 80_000;
const override_timeout_ms_default: i64 = 5_000;
const startup_overhead_timeout_ms: i64 = 20_000;
const command_probe_max_output_bytes: usize = 16 * 1024;
const daemon_status_response_max_bytes: usize = 4 * 1024 * 1024 + 64 * 1024;
const daemon_status_io_timeout_ms: i64 = 2_000;
pub const daemon_log_max_bytes: u64 = 8 * 1024 * 1024;

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
    runtime_state_available: ?bool = null,
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

fn getRuntimeFilePath(
    allocator: std.mem.Allocator,
    name: []const u8,
) ![]const u8 {
    const directory = try runtime_dir.defaultPath(allocator);
    defer allocator.free(directory);
    return compat.fs.path.join(allocator, &.{ directory, name });
}

pub fn getPidFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return getRuntimeFilePath(allocator, runtime_dir.pid_name);
}

fn getLockFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return getRuntimeFilePath(allocator, runtime_dir.lock_name);
}

pub fn getLogFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return getRuntimeFilePath(allocator, runtime_dir.log_name);
}

pub fn readPid(allocator: std.mem.Allocator) !?i32 {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse return null;
    defer runtime.deinit();
    return readPidInRuntime(runtime);
}

fn readPidInRuntime(runtime: runtime_dir.RuntimeDir) !?i32 {
    const file = runtime.openFile(runtime_dir.pid_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(compat.io());
    const stat = try file.stat(compat.io());
    if (stat.size == 0) return error.InvalidPidFile;
    if (stat.size > 32) return error.InvalidPidFile;
    var buffer: [32]u8 = undefined;
    const count = try compat.fileReadAll(file, buffer[0..@intCast(stat.size)]);
    if (count != stat.size) return error.InvalidPidFile;
    const text = std.mem.trim(u8, buffer[0..count], " \t\n\r");
    const pid = std.fmt.parseInt(i32, text, 10) catch
        return error.InvalidPidFile;
    if (pid <= 0) return error.InvalidPidFile;
    return pid;
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
    const pid = std.fmt.parseInt(i32, pid_str, 10) catch
        return error.InvalidPidFile;
    if (pid <= 0) return error.InvalidPidFile;
    return pid;
}

fn writePidInRuntime(runtime: runtime_dir.RuntimeDir, pid: i32) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}\n", .{pid});
    try runtime.replaceFile(runtime_dir.pid_name, text);
}

pub fn writePid(allocator: std.mem.Allocator, pid: i32) !void {
    var runtime = (try runtime_dir.openDefault(allocator, true)) orelse
        return error.InvalidRuntimeDirectory;
    defer runtime.deinit();
    return writePidInRuntime(runtime, pid);
}

fn writePidAtPath(pid_file: []const u8, pid: i32) !void {
    const file = try compat.fs.createFileAbsolute(pid_file, .{});
    defer file.close(compat.io());

    var buf: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&buf, "{d}\n", .{pid});
    try compat.fileWriteAll(file, pid_str);
}

pub fn removeCurrentProcessPid(allocator: std.mem.Allocator) !bool {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse return false;
    defer runtime.deinit();
    const current = (try readPidInRuntime(runtime)) orelse return false;
    if (current != std.c.getpid()) return false;
    try runtime.deleteFile(runtime_dir.pid_name);
    return true;
}

pub fn cleanupCurrentProcessRuntime(allocator: std.mem.Allocator) void {
    const pid = std.c.getpid();
    const nonce = descriptorNonceForPid(allocator, pid);
    _ = removeCurrentProcessPid(allocator) catch false;
    removeDescriptor(allocator, nonce);
}

pub const StartupFailure = enum {
    generic,
    port_in_use,
    controller_port_in_use,
    port_conflict,
    invalid_bind_address,
    invalid_controller,
    listener_failed,
    readiness,
    runtime_publish,
    lock_handoff,
    capability,
    override_not_found,
    override_exec,
    override_timeout,
    override_output,
    override_merge,
};

pub const StartupSignal = union(enum) {
    ready,
    failed: StartupFailure,
};

fn startupFailureError(failure: StartupFailure) anyerror {
    return switch (failure) {
        .generic => error.StartFailed,
        .port_in_use => error.PortAlreadyInUse,
        .controller_port_in_use => error.ControllerPortAlreadyInUse,
        .port_conflict => error.PortConflict,
        .invalid_bind_address => error.InvalidBindAddress,
        .invalid_controller => error.InvalidExternalController,
        .listener_failed => error.ListenerStartupFailed,
        .readiness => error.StartupTimeout,
        .runtime_publish => error.StartRuntimePublishFailed,
        .lock_handoff => error.StartLockHandoffInvalid,
        .capability => error.UnsupportedCapability,
        .override_not_found => error.OverrideScriptNotFound,
        .override_exec => error.OverrideScriptExecFailed,
        .override_timeout => error.OverrideScriptTimeout,
        .override_output => error.OverrideOutputInvalid,
        .override_merge => error.OverrideMergeFailed,
    };
}

fn nonceFileName(
    prefix: []const u8,
    nonce: runtime_descriptor.Nonce,
    buffer: []u8,
) []const u8 {
    std.debug.assert(buffer.len == prefix.len + 32);
    @memcpy(buffer[0..prefix.len], prefix);
    const hex: *[32]u8 = buffer[prefix.len..][0..32];
    _ = nonce.formatHex(hex);
    return buffer;
}

fn startupSignalText(signal: StartupSignal) []const u8 {
    return switch (signal) {
        .ready => "ready\n",
        .failed => |failure| switch (failure) {
            .generic => "error:generic\n",
            .port_in_use => "error:port_in_use\n",
            .controller_port_in_use => "error:controller_port_in_use\n",
            .port_conflict => "error:port_conflict\n",
            .invalid_bind_address => "error:invalid_bind_address\n",
            .invalid_controller => "error:invalid_controller\n",
            .listener_failed => "error:listener_failed\n",
            .readiness => "error:readiness\n",
            .runtime_publish => "error:runtime_publish\n",
            .lock_handoff => "error:lock_handoff\n",
            .capability => "error:capability\n",
            .override_not_found => "error:override_not_found\n",
            .override_exec => "error:override_exec\n",
            .override_timeout => "error:override_timeout\n",
            .override_output => "error:override_output\n",
            .override_merge => "error:override_merge\n",
        },
    };
}

pub fn publishStartupSignal(
    allocator: std.mem.Allocator,
    token: runtime_descriptor.Nonce,
    signal: StartupSignal,
) !void {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse
        return error.RuntimeDirectoryUnavailable;
    defer runtime.deinit();
    var name_buffer: [runtime_dir.startup_prefix.len + 32]u8 = undefined;
    const name = nonceFileName(
        runtime_dir.startup_prefix,
        token,
        &name_buffer,
    );
    try runtime.replaceFile(name, startupSignalText(signal));
}

fn observeStartupSignal(
    runtime: runtime_dir.RuntimeDir,
    token: runtime_descriptor.Nonce,
) !?StartupSignal {
    var name_buffer: [runtime_dir.startup_prefix.len + 32]u8 = undefined;
    const name = nonceFileName(
        runtime_dir.startup_prefix,
        token,
        &name_buffer,
    );
    const file = runtime.openFile(name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(compat.io());
    var buffer: [64]u8 = undefined;
    const count = try compat.fileReadAll(file, &buffer);
    const text = buffer[0..count];
    if (std.mem.eql(u8, text, "ready\n")) return .ready;
    inline for (std.meta.fields(StartupFailure)) |field| {
        const expected = "error:" ++ field.name ++ "\n";
        if (std.mem.eql(u8, text, expected)) {
            return .{ .failed = @enumFromInt(field.value) };
        }
    }
    return error.InvalidStartupSignal;
}

fn removeStartupSignal(
    runtime: runtime_dir.RuntimeDir,
    token: runtime_descriptor.Nonce,
) void {
    var name_buffer: [runtime_dir.startup_prefix.len + 32]u8 = undefined;
    const name = nonceFileName(
        runtime_dir.startup_prefix,
        token,
        &name_buffer,
    );
    runtime.deleteFile(name) catch {};
}

fn stopRequestBytes(nonce: runtime_descriptor.Nonce, buffer: *[33]u8) []const u8 {
    const hex: *[32]u8 = buffer[0..32];
    _ = nonce.formatHex(hex);
    buffer[32] = '\n';
    return buffer;
}

fn stopRequestName(
    nonce: runtime_descriptor.Nonce,
    buffer: *[runtime_dir.stop_prefix.len + 32]u8,
) []const u8 {
    @memcpy(buffer[0..runtime_dir.stop_prefix.len], runtime_dir.stop_prefix);
    const hex: *[32]u8 = buffer[runtime_dir.stop_prefix.len..];
    _ = nonce.formatHex(hex);
    return buffer;
}

fn publishStopRequest(
    allocator: std.mem.Allocator,
    nonce: runtime_descriptor.Nonce,
) !void {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse
        return error.RuntimeDirectoryUnavailable;
    defer runtime.deinit();
    var name_buffer: [runtime_dir.stop_prefix.len + 32]u8 = undefined;
    const name = stopRequestName(nonce, &name_buffer);
    var content_buffer: [33]u8 = undefined;
    try runtime.replaceFile(name, stopRequestBytes(nonce, &content_buffer));
}

pub fn consumeStopRequest(
    allocator: std.mem.Allocator,
    expected: runtime_descriptor.Nonce,
) !bool {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse return false;
    defer runtime.deinit();
    var name_buffer: [runtime_dir.stop_prefix.len + 32]u8 = undefined;
    const name = stopRequestName(expected, &name_buffer);
    const file = runtime.openFile(name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(compat.io());
    const stat = try file.stat(compat.io());
    if (stat.size != 33) return error.InvalidStopRequest;
    var buffer: [33]u8 = undefined;
    const count = try compat.fileReadAll(file, &buffer);
    if (count != buffer.len or buffer[32] != '\n') {
        return error.InvalidStopRequest;
    }
    const observed = runtime_descriptor.Nonce.parseHex(buffer[0..32]) catch
        return error.InvalidStopRequest;
    if (!observed.eql(expected)) return false;
    try runtime.deleteFile(name);
    return true;
}

fn removePidFileAtPath(pid_file: []const u8) void {
    compat.fs.deleteFileAbsolute(pid_file) catch {};
}

fn removePidIfMatchesInRuntime(
    runtime: runtime_dir.RuntimeDir,
    expected_pid: i32,
) !bool {
    var lock = acquireDaemonLockFileInRuntime(runtime) catch |err| switch (err) {
        error.DaemonAlreadyRunning => return false,
        else => return err,
    };
    defer lock.close(compat.io());
    const current = (try readPidInRuntime(runtime)) orelse return false;
    if (current != expected_pid) return false;
    try runtime.deleteFile(runtime_dir.pid_name);
    return true;
}

fn removePidIfMatches(
    allocator: std.mem.Allocator,
    expected_pid: i32,
) !bool {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse return false;
    defer runtime.deinit();
    return removePidIfMatchesInRuntime(runtime, expected_pid);
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

const DescriptorProcess = struct {
    pid: i32,
    ready: bool,
};

fn descriptorProcessInRuntime(
    allocator: std.mem.Allocator,
    runtime: runtime_dir.RuntimeDir,
) !?DescriptorProcess {
    const store = runtime_descriptor.Store.init(allocator, runtime.dir);
    var descriptor = (try store.observe()) orelse return null;
    defer descriptor.deinit();
    if (descriptor.pid > std.math.maxInt(i32)) {
        return error.RuntimeIdentityUncertain;
    }
    return .{
        .pid = @intCast(descriptor.pid),
        .ready = descriptor.ready,
    };
}

fn inspectRuntimeWithInspector(
    allocator: std.mem.Allocator,
    inspector: RuntimeInspector,
) !RuntimeState {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse
        return .{};
    defer runtime.deinit();
    var stale_pid: ?i32 = null;
    var candidate_pid: ?i32 = null;

    if (try readPidInRuntime(runtime)) |pid| {
        if (try inspector.pid_is_daemon(allocator, pid)) {
            candidate_pid = pid;
        } else {
            stale_pid = pid;
            _ = removePidIfMatchesInRuntime(runtime, pid) catch false;
        }
    }
    const lock_held = try isDaemonLockHeldInRuntime(runtime);
    const descriptor_process = try descriptorProcessInRuntime(
        allocator,
        runtime,
    );
    if (candidate_pid) |pid| {
        const descriptor_matches = descriptor_process != null and
            descriptor_process.?.pid == pid;
        if (lock_held) {
            if (descriptor_matches and descriptor_process.?.ready) {
                return .{ .pid = pid, .lock_held = true };
            }
            return .{
                .detail = if (descriptor_matches)
                    "startup_in_progress"
                else
                    "lock_held_pid_untracked",
                .lock_held = true,
            };
        }
        if (descriptor_matches) return error.RuntimeLockIntegrityLost;
        return error.RuntimeIdentityUncertain;
    }
    if (descriptor_process) |process| {
        if (try inspector.pid_is_daemon(allocator, process.pid)) {
            if (!lock_held) return error.RuntimeLockIntegrityLost;
            if (process.ready) {
                return .{ .pid = process.pid, .lock_held = true };
            }
            return .{
                .detail = "startup_in_progress",
                .lock_held = true,
            };
        }
    }
    if (lock_held) {
        return .{
            .detail = "startup_in_progress",
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
    return inspectRuntimeWithInspector(allocator, .{
        .pid_is_daemon = pidMatchesRunningDaemon,
    });
}

fn rejectLiveTrackedPidAfterLockAcquire(
    allocator: std.mem.Allocator,
) !void {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse return;
    defer runtime.deinit();
    const descriptor_process = try descriptorProcessInRuntime(
        allocator,
        runtime,
    );
    const pid = (try readPidInRuntime(runtime)) orelse
        (if (descriptor_process) |process| process.pid else return);
    if (try pidMatchesRunningDaemon(allocator, pid) and
        descriptor_process != null and descriptor_process.?.pid == pid)
    {
        return error.RuntimeLockIntegrityLost;
    }
}

fn readTrackedPid(allocator: std.mem.Allocator) !?i32 {
    return (try inspectRuntime(allocator)).pid;
}

const LockWaitOutcome = union(enum) {
    ready: i32,
    unlocked,
    timeout,
};

fn waitForReadyOrUnlocked(
    allocator: std.mem.Allocator,
    deadline: i64,
) !LockWaitOutcome {
    while (compat.monotonicMilliTimestamp() < deadline) {
        const runtime = try inspectRuntime(allocator);
        if (runtime.pid) |pid| return .{ .ready = pid };
        if (!runtime.lock_held) return .unlocked;
        compat.sleepNs(startup_poll_interval_ms * std.time.ns_per_ms);
    }
    return .timeout;
}

fn duplicateWithoutCloexec(file: compat.fs.File) !compat.fs.File {
    const dup_fd = std.c.fcntl(
        file.handle,
        std.c.F.DUPFD,
        @as(c_int, 3),
    );
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

fn acquireDaemonLockFileInRuntime(
    runtime: runtime_dir.RuntimeDir,
) !compat.fs.File {
    while (true) {
        const lock_file = runtime.openFile(runtime_dir.lock_name, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                const created = runtime.createExclusive(runtime_dir.lock_name) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => continue,
                    else => return create_err,
                };
                created.close(compat.io());
                continue;
            },
            error.WouldBlock => return error.DaemonAlreadyRunning,
            error.SymLinkLoop, error.IsDir => return error.InvalidRuntimeLock,
            else => return err,
        };
        errdefer lock_file.close(compat.io());
        try lock_file.setPermissions(compat.io(), runtime_dir.ownerFilePermissions());
        return duplicateWithoutCloexec(lock_file);
    }
}

fn acquireDaemonLockFile(allocator: std.mem.Allocator) !compat.fs.File {
    var runtime = (try runtime_dir.openDefault(allocator, true)) orelse
        return error.InvalidRuntimeDirectory;
    defer runtime.deinit();
    return acquireDaemonLockFileInRuntime(runtime);
}

fn isDaemonLockHeldInRuntime(runtime: runtime_dir.RuntimeDir) !bool {
    const lock_file = runtime.openFile(runtime_dir.lock_name, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.WouldBlock => return true,
        error.SymLinkLoop, error.IsDir => return error.InvalidRuntimeLock,
        else => return err,
    };
    lock_file.close(compat.io());
    return false;
}

fn resetLogPathIfOversized(runtime: runtime_dir.RuntimeDir) !bool {
    const file = runtime.openFile(runtime_dir.log_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    const size = (try file.stat(compat.io())).size;
    file.close(compat.io());
    if (size <= daemon_log_max_bytes) return false;
    try runtime.replaceFile(runtime_dir.log_name, "");
    return true;
}

pub fn rotateDaemonLogIfNeeded(allocator: std.mem.Allocator) !void {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse return;
    defer runtime.deinit();
    const writer: std.Io.File = .{
        .handle = std.c.STDERR_FILENO,
        .flags = .{ .nonblocking = false },
    };
    const writer_stat = try writer.stat(compat.io());
    const path_stat = runtime.dir.statFile(
        compat.io(),
        runtime_dir.log_name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const path_matches = if (path_stat) |stat|
        stat.kind == .file and stat.inode == writer_stat.inode
    else
        false;
    if (path_matches and writer_stat.size <= daemon_log_max_bytes) return;

    var temporary_name_buffer: [64]u8 = undefined;
    const temporary_name = try std.fmt.bufPrint(
        &temporary_name_buffer,
        "zc.log.rotate.{d}",
        .{std.c.getpid()},
    );
    runtime.deleteFile(temporary_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const replacement = try runtime.createExclusive(temporary_name);
    defer replacement.close(compat.io());
    var temporary_owned = true;
    defer if (temporary_owned) runtime.deleteFile(temporary_name) catch {};
    try replacement.setPermissions(
        compat.io(),
        runtime_dir.ownerFilePermissions(),
    );
    if (std.c.dup2(replacement.handle, std.c.STDOUT_FILENO) < 0 or
        std.c.dup2(replacement.handle, std.c.STDERR_FILENO) < 0)
    {
        return error.LogRedirectFailed;
    }
    try runtime.dir.rename(
        temporary_name,
        runtime.dir,
        runtime_dir.log_name,
        compat.io(),
    );
    temporary_owned = false;
    const parent = try runtime.dir.openFile(
        compat.io(),
        ".",
        .{ .allow_directory = true },
    );
    defer parent.close(compat.io());
    try parent.sync(compat.io());
}

fn openLogFileInRuntime(runtime: runtime_dir.RuntimeDir) !compat.fs.File {
    _ = try resetLogPathIfOversized(runtime);
    while (true) {
        const file = runtime.openFile(runtime_dir.log_name, .{
            .mode = .read_write,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                const created = runtime.createExclusive(runtime_dir.log_name) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => continue,
                    else => return create_err,
                };
                created.close(compat.io());
                continue;
            },
            error.SymLinkLoop, error.IsDir => return error.InvalidRuntimeLog,
            else => return err,
        };
        errdefer file.close(compat.io());
        try file.setPermissions(compat.io(), runtime_dir.ownerFilePermissions());
        const size = (try file.stat(compat.io())).size;
        try compat.fileSeekTo(file, size);
        return file;
    }
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
pub fn protectDaemonLockFromExec(fd: std.posix.fd_t) !void {
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) < 0) {
        return error.DaemonLockCloexecFailed;
    }
}

const FileIdentity = struct {
    device: u64,
    inode: u64,

    fn eql(a: FileIdentity, b: FileIdentity) bool {
        return a.device == b.device and a.inode == b.inode;
    }
};

fn fileIdentity(fd: std.posix.fd_t) !FileIdentity {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stat = std.mem.zeroes(linux.Statx);
        const result = linux.statx(
            fd,
            "",
            linux.AT.EMPTY_PATH,
            .{ .INO = true },
            &stat,
        );
        if (linux.errno(result) != .SUCCESS or !stat.mask.INO) {
            return error.FileIdentityUnavailable;
        }
        return .{
            .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor,
            .inode = stat.ino,
        };
    }

    var stat = std.mem.zeroes(std.posix.Stat);
    if (std.posix.errno(std.posix.system.fstat(fd, &stat)) != .SUCCESS) {
        return error.FileIdentityUnavailable;
    }
    return .{
        .device = @intCast(stat.dev),
        .inode = @intCast(stat.ino),
    };
}

fn runtimeLockIdentity(runtime: runtime_dir.RuntimeDir) !FileIdentity {
    const file = try runtime.dir.openFile(compat.io(), runtime_dir.lock_name, .{
        .path_only = true,
        .follow_symlinks = false,
    });
    defer file.close(compat.io());
    if ((try file.stat(compat.io())).kind != .file) {
        return error.InvalidInheritedDaemonLock;
    }
    return fileIdentity(file.handle);
}

pub fn validateInheritedDaemonLockIdentity(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
) !void {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse
        return error.InvalidRuntimeDirectory;
    defer runtime.deinit();
    const inherited: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    const actual = try fileIdentity(fd);
    const expected = try runtimeLockIdentity(runtime);
    if ((try inherited.stat(compat.io())).kind != .file or
        !actual.eql(expected))
    {
        return error.InvalidInheritedDaemonLock;
    }
}

pub fn adoptInheritedDaemonLock(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
) !void {
    var runtime = (try runtime_dir.openDefault(allocator, false)) orelse
        return error.InvalidRuntimeDirectory;
    defer runtime.deinit();
    const inherited: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    if ((try inherited.stat(compat.io())).kind != .file) {
        return error.InvalidInheritedDaemonLock;
    }
    const actual = try fileIdentity(fd);
    if (!actual.eql(try runtimeLockIdentity(runtime))) {
        return error.InvalidInheritedDaemonLock;
    }
    if (!try inherited.tryLock(compat.io(), .exclusive)) {
        return error.InvalidInheritedDaemonLock;
    }
    if (!actual.eql(try runtimeLockIdentity(runtime))) {
        return error.InvalidInheritedDaemonLock;
    }
    try protectDaemonLockFromExec(fd);
}

pub fn publishStartupReservation(
    allocator: std.mem.Allocator,
    nonce: runtime_descriptor.Nonce,
    pid: i32,
) !void {
    if (pid <= 0) return error.InvalidRuntimeDescriptor;
    var default_store = (try runtime_descriptor.openDefault(
        allocator,
        true,
    )) orelse return error.RuntimeDirectoryUnavailable;
    defer default_store.deinit();
    const outcome = try default_store.store().publish(.missing, .{
        .pid = @intCast(pid),
        .nonce = nonce,
        .ready = false,
    });
    switch (outcome) {
        .committed, .durability_uncertain => {},
        .conflict => return error.RuntimeDescriptorConflict,
    }
}

pub fn prepareForegroundRuntime(allocator: std.mem.Allocator) !void {
    return clearStaleDescriptorBeforeStart(allocator);
}

pub fn acquireForegroundLock(allocator: std.mem.Allocator) !compat.fs.File {
    const lock = try acquireDaemonLockFile(allocator);
    errdefer lock.close(compat.io());
    try protectDaemonLockFromExec(lock.handle);
    return lock;
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
    const runtime = try inspectRuntime(allocator);
    if (runtime.detail != null and
        std.mem.eql(u8, runtime.detail.?, "startup_in_progress"))
    {
        return error.RuntimeStartupInProgress;
    }
    const active_config: ?[]const u8 = if (runtime.pid == null and !runtime.lock_held)
        try config.resolveRuntimeConfigKey(allocator, null)
    else
        null;
    errdefer if (active_config) |value| allocator.free(value);
    const selected_proxies = if (runtime.pid == null and !runtime.lock_held)
        try collectStatusSelectedProxies(allocator, active_config)
    else
        try allocator.alloc(runtime_selection.SelectedProxy, 0);
    errdefer runtime_selection.deinitSelectedProxies(allocator, selected_proxies);
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

fn collectStatusSelectedProxies(
    allocator: std.mem.Allocator,
    active_config: ?[]const u8,
) ![]runtime_selection.SelectedProxy {
    var cfg = try config.loadDefaultQuiet(allocator);
    defer cfg.deinit();
    return try runtime_selection.collectSelectedProxies(
        allocator,
        &cfg,
        active_config,
    );
}

/// daemon GET /status 返回的实际运行时状态。status 经 IPC 读取以反映 daemon
/// 真实状态（config_key + 内存 selections），而非 meta.json[用户指针]——后者
/// 在 config_key 与 active_config 错位（配置切换未重启 daemon）时读到空，误报
/// default。
const DaemonStatus = struct {
    config_key: ?[]const u8 = null,
    selected_proxies: []runtime_selection.SelectedProxy = &[_]runtime_selection.SelectedProxy{},

    fn deinit(self: *DaemonStatus, allocator: std.mem.Allocator) void {
        if (self.config_key) |k| allocator.free(k);
        runtime_selection.deinitSelectedProxies(allocator, self.selected_proxies);
    }
};

/// 解析 daemon GET /status 的 JSON body 为 DaemonStatus。纯函数（不起 socket），
/// 便于测试。失败（非 JSON / 缺字段）返回 null，调用方回退到文件路径。
fn parseDaemonStatusJson(allocator: std.mem.Allocator, body: []const u8) !?DaemonStatus {
    var shape = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return null;
    defer shape.deinit();
    if (shape.value != .object or
        shape.value.object.get("config_key") == null or
        shape.value.object.get("selected_proxies") == null)
    {
        return null;
    }

    const StatusProxy = struct {
        group: []const u8 = "",
        proxy: ?[]const u8 = null,
        source: []const u8 = "default",
    };
    const StatusResp = struct {
        config_key: ?[]const u8 = null,
        selected_proxies: []const StatusProxy = &.{},
    };

    var parsed = std.json.parseFromSlice(StatusResp, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    const resp = parsed.value;

    var config_key: ?[]const u8 = null;
    if (resp.config_key) |k| config_key = try allocator.dupe(u8, k);

    var selections = std.ArrayList(runtime_selection.SelectedProxy).empty;
    errdefer {
        for (selections.items) |*sp| sp.deinit(allocator);
        selections.deinit(allocator);
        if (config_key) |k| allocator.free(k);
    }

    for (resp.selected_proxies) |item| {
        const group = allocator.dupe(u8, item.group) catch continue;
        const proxy: ?[]const u8 = if (item.proxy) |pr| (allocator.dupe(u8, pr) catch null) else null;
        const source: runtime_selection.SelectionSource = if (std.mem.eql(
            u8,
            item.source,
            "persisted",
        ))
            .persisted
        else if (std.mem.eql(u8, item.source, "transient"))
            .transient
        else
            .default;
        selections.append(allocator, .{ .group_name = group, .proxy_name = proxy, .source = source }) catch {
            allocator.free(group);
            if (proxy) |pr| allocator.free(pr);
            continue;
        };
    }

    return DaemonStatus{
        .config_key = config_key,
        .selected_proxies = try selections.toOwnedSlice(allocator),
    };
}

/// 经 live runtime descriptor 读取 daemon 实际运行时状态。descriptor、PID
/// 或响应不匹配时返回 null，调用方仅展示 durable fallback。
fn fetchDaemonStatusOverIpc(
    allocator: std.mem.Allocator,
    expected_pid: i32,
) !?DaemonStatus {
    if (expected_pid <= 0) return null;
    var default_store = (runtime_descriptor.openDefault(allocator, false) catch return null) orelse
        return null;
    defer default_store.deinit();
    var descriptor = (default_store.store().observe() catch return null) orelse
        return null;
    defer descriptor.deinit();
    if (!descriptor.ready or
        descriptor.pid != @as(u32, @intCast(expected_pid))) return null;
    const endpoint = descriptor.endpoint orelse return null;
    var status = (try fetchDaemonStatusOverIpcEc(allocator, endpoint)) orelse
        return null;
    errdefer status.deinit(allocator);
    if (!try runtimeInstanceMatches(allocator, expected_pid, descriptor.nonce)) {
        status.deinit(allocator);
        return null;
    }
    return status;
}

fn waitForStatusSocket(
    fd: std.posix.fd_t,
    events: i16,
    deadline: i64,
) !void {
    while (true) {
        const remaining = deadline - compat.monotonicMilliTimestamp();
        if (remaining <= 0) return error.StatusRequestTimeout;
        var descriptors = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = events,
            .revents = 0,
        }};
        const ready = try std.posix.poll(
            &descriptors,
            @intCast(@min(remaining, std.math.maxInt(i32))),
        );
        if (ready == 0) return error.StatusRequestTimeout;
        const revents = descriptors[0].revents;
        if (revents & std.posix.POLL.NVAL != 0 or
            revents & std.posix.POLL.ERR != 0)
        {
            return error.StatusSocketFailure;
        }
        if (revents & events != 0 or revents & std.posix.POLL.HUP != 0) return;
    }
}

fn writeStatusRequest(
    fd: std.posix.fd_t,
    request: []const u8,
    deadline: i64,
) !void {
    var offset: usize = 0;
    while (offset < request.len) {
        try waitForStatusSocket(fd, std.posix.POLL.OUT, deadline);
        const flags: u32 = if (comptime @hasDecl(std.posix.MSG, "NOSIGNAL"))
            std.posix.MSG.NOSIGNAL
        else
            0;
        const result = std.c.send(
            fd,
            request[offset..].ptr,
            request.len - offset,
            flags,
        );
        if (result < 0) switch (std.c.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return error.StatusSocketFailure,
        };
        if (result == 0) return error.StatusSocketFailure;
        offset += @intCast(result);
    }
}

fn readStatusChunk(
    fd: std.posix.fd_t,
    buffer: []u8,
    deadline: i64,
) !usize {
    while (true) {
        try waitForStatusSocket(fd, std.posix.POLL.IN, deadline);
        const result = std.c.recv(fd, buffer.ptr, buffer.len, 0);
        if (result >= 0) return @intCast(result);
        switch (std.c.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return error.StatusSocketFailure,
        }
    }
}

fn fetchDaemonStatusOverIpcEc(allocator: std.mem.Allocator, ec: []const u8) !?DaemonStatus {
    const deadline = compat.monotonicMilliTimestamp() + daemon_status_io_timeout_ms;
    const endpoint = controller_endpoint.parse(ec) catch return null;
    const stream = compat.net.tcpConnectToHost(
        allocator,
        controller_endpoint.loopback_host,
        endpoint.port,
    ) catch return null;
    defer stream.close();
    socket_options.configureConnectedStream(stream) catch return null;
    compat.setNonBlock(stream.handle) catch return null;

    const req = std.fmt.allocPrint(allocator, "GET /status HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ec}) catch return null;
    defer allocator.free(req);
    writeStatusRequest(stream.handle, req, deadline) catch return null;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = readStatusChunk(stream.handle, &chunk, deadline) catch return null;
        if (n == 0) break;
        if (buf.items.len > daemon_status_response_max_bytes - n) return null;
        buf.appendSlice(allocator, chunk[0..n]) catch break;
    }

    if (!std.mem.startsWith(u8, buf.items, "HTTP/1.1 200") and !std.mem.startsWith(u8, buf.items, "HTTP/1.0 200")) return null;

    const body = if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |hdr_end| buf.items[hdr_end + 4 ..] else buf.items;
    return try parseDaemonStatusJson(allocator, body);
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
            .runtime_state_available = snapshot.runtime_state_available,
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
    if (snapshot.runtime_state_available) |available| {
        try out.print("runtime_state_available: {}\n", .{available});
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

fn clearStaleDescriptorBeforeStart(allocator: std.mem.Allocator) !void {
    var default_store = (try runtime_descriptor.openDefault(allocator, false)) orelse
        return;
    defer default_store.deinit();
    const store = default_store.store();
    var descriptor = (try store.observe()) orelse return;
    defer descriptor.deinit();
    var stop_name_buffer: [runtime_dir.stop_prefix.len + 32]u8 = undefined;
    const stop_name = stopRequestName(descriptor.nonce, &stop_name_buffer);
    default_store.runtime.deleteFile(stop_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    switch (try store.remove(descriptor.nonce)) {
        .removed, .absent => {},
        .conflict => return error.ConcurrentRuntimeDescriptorUpdate,
        .durability_uncertain => |err| return err,
    }
}

fn descriptorMatchesInstance(
    allocator: std.mem.Allocator,
    pid: std.posix.pid_t,
    nonce: runtime_descriptor.Nonce,
) !bool {
    if (pid <= 0) return false;
    var default_store = (try runtime_descriptor.openDefault(allocator, false)) orelse
        return false;
    defer default_store.deinit();
    var descriptor = (try default_store.store().observe()) orelse return false;
    defer descriptor.deinit();
    return descriptor.ready and
        descriptor.pid == @as(u32, @intCast(pid)) and
        descriptor.nonce.eql(nonce);
}

const ChildState = enum { running, exited, unavailable };

fn childState(pid: std.posix.pid_t) ChildState {
    while (true) {
        var status: c_int = 0;
        const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (result == pid) return .exited;
        if (result == 0) return .running;
        if (std.c.errno(result) == .INTR) continue;
        return .unavailable;
    }
}

fn terminateAndReapChild(pid: std.posix.pid_t) void {
    if (childState(pid) != .running) return;
    std.posix.kill(pid, std.posix.SIG.TERM) catch return;
    var attempt: u8 = 0;
    while (attempt < 40) : (attempt += 1) {
        if (childState(pid) != .running) return;
        compat.sleepNs(25 * std.time.ns_per_ms);
    }
    if (childState(pid) != .running) return;
    std.posix.kill(pid, std.posix.SIG.KILL) catch return;
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
}

fn cleanupOwnedStartupChild(
    allocator: std.mem.Allocator,
    pid: i32,
) void {
    terminateAndReapChild(pid);
    const nonce = descriptorNonceForPid(allocator, pid);
    _ = removePidIfMatches(allocator, pid) catch false;
    removeDescriptor(allocator, nonce);
}

fn normalizeStandardDescriptors() !void {
    const dev_null = try std.Io.Dir.openFileAbsolute(compat.io(), "/dev/null", .{
        .mode = .read_write,
    });
    var keep_open = dev_null.handle <= std.c.STDERR_FILENO;
    defer if (!keep_open) dev_null.close(compat.io());
    for ([_]std.posix.fd_t{
        std.c.STDIN_FILENO,
        std.c.STDOUT_FILENO,
        std.c.STDERR_FILENO,
    }) |target| {
        if (std.c.fcntl(target, std.c.F.GETFD) >= 0) continue;
        if (std.c.dup2(dev_null.handle, target) < 0) {
            return error.StandardDescriptorSetupFailed;
        }
        if (dev_null.handle == target) keep_open = true;
    }
}

fn forwardedOverrideTimeoutMs(extra_args: []const []const u8) i64 {
    for (extra_args, 0..) |arg, index| {
        if (!std.mem.eql(u8, arg, "--override-timeout-ms")) continue;
        if (index + 1 >= extra_args.len) return override_timeout_ms_default;
        return std.fmt.parseInt(i64, extra_args[index + 1], 10) catch
            override_timeout_ms_default;
    }
    return override_timeout_ms_default;
}

/// 启动守护进程。只返回事实（LifecycleOutcome）或错误；envelope/文本由
/// main.zig 经 cli/output.zig 恰好打印一次。
pub fn startDaemon(allocator: std.mem.Allocator, config_path: ?[]const u8, extra_args: []const []const u8) !LifecycleOutcome {
    const lock_wait_deadline = compat.monotonicMilliTimestamp() +
        startup_lock_wait_ms;
    var lock_file: compat.fs.File = undefined;
    while (true) {
        lock_file = acquireDaemonLockFile(allocator) catch |err| switch (err) {
            error.DaemonAlreadyRunning => switch (try waitForReadyOrUnlocked(
                allocator,
                lock_wait_deadline,
            )) {
                .ready => |pid| return .{ .detail = "already_running", .pid = pid },
                .unlocked => continue,
                .timeout => return error.StartupTimeout,
            },
            else => return err,
        };
        break;
    }
    var lock_open = true;
    errdefer if (lock_open) lock_file.close(compat.io());

    try rejectLiveTrackedPidAfterLockAcquire(allocator);
    try clearStaleDescriptorBeforeStart(allocator);
    const startup_token = runtime_descriptor.Nonce.generate();

    // Fork 子进程
    const fork_result = std.c.fork();
    if (fork_result < 0) {
        return error.Unexpected;
    }
    const pid: std.posix.pid_t = @intCast(fork_result);

    if (pid > 0) {
        var owns_child = true;
        defer if (owns_child) cleanupOwnedStartupChild(allocator, pid);
        var signal_runtime = (try runtime_dir.openDefault(allocator, false)) orelse
            return error.InvalidRuntimeDirectory;
        defer signal_runtime.deinit();
        defer removeStartupSignal(signal_runtime, startup_token);
        const startup_deadline = compat.monotonicMilliTimestamp() +
            forwardedOverrideTimeoutMs(extra_args) + startup_overhead_timeout_ms;
        while (compat.monotonicMilliTimestamp() < startup_deadline) {
            if (try observeStartupSignal(signal_runtime, startup_token)) |signal| {
                switch (signal) {
                    .ready => {
                        if (!(descriptorMatchesInstance(
                            allocator,
                            pid,
                            startup_token,
                        ) catch false) or
                            childState(pid) != .running)
                        {
                            return error.StartFailed;
                        }
                        lock_file.close(compat.io());
                        lock_open = false;
                        owns_child = false;
                        return .{ .pid = pid };
                    },
                    .failed => |failure| {
                        lock_file.close(compat.io());
                        lock_open = false;
                        _ = removePidIfMatches(allocator, pid) catch false;
                        return startupFailureError(failure);
                    },
                }
            }
            if (descriptorMatchesInstance(
                allocator,
                pid,
                startup_token,
            ) catch false) {
                if (childState(pid) != .running) return error.StartFailed;
                lock_file.close(compat.io());
                lock_open = false;
                owns_child = false;
                return .{ .pid = pid };
            }
            if (childState(pid) != .running) {
                if (try observeStartupSignal(signal_runtime, startup_token)) |signal| {
                    switch (signal) {
                        .failed => |failure| {
                            lock_file.close(compat.io());
                            lock_open = false;
                            return startupFailureError(failure);
                        },
                        .ready => {},
                    }
                }
                const nonce = descriptorNonceForPid(allocator, pid);
                lock_file.close(compat.io());
                lock_open = false;
                _ = removePidIfMatches(allocator, pid) catch false;
                removeDescriptor(allocator, nonce);
                return error.StartFailed;
            }
            compat.sleepNs(startup_poll_interval_ms * std.time.ns_per_ms);
        }

        terminateAndReapChild(pid);
        if (try observeStartupSignal(signal_runtime, startup_token)) |signal| {
            switch (signal) {
                .failed => |failure| {
                    lock_file.close(compat.io());
                    lock_open = false;
                    return startupFailureError(failure);
                },
                .ready => {},
            }
        }
        const nonce = descriptorNonceForPid(allocator, pid);
        lock_file.close(compat.io());
        lock_open = false;
        _ = removePidIfMatches(allocator, pid) catch false;
        removeDescriptor(allocator, nonce);
        return error.StartupTimeout;
    }

    // The fork child must never return into any caller's CLI rendering path.
    execDaemonChild(
        allocator,
        config_path,
        extra_args,
        lock_file,
        startup_token,
    ) catch {
        publishStartupSignal(
            allocator,
            startup_token,
            .{ .failed = .generic },
        ) catch {};
        std.c._exit(cli_output.exit_failure);
    };
    unreachable;
}

fn execDaemonChild(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
    extra_args: []const []const u8,
    lock_file: compat.fs.File,
    startup_token: runtime_descriptor.Nonce,
) !noreturn {
    try normalizeStandardDescriptors();
    if (std.c.setsid() < 0) return error.SessionSetupFailed;

    // Redirect through the verified runtime directory; never follow log links.
    var runtime = (try runtime_dir.openDefault(allocator, true)) orelse
        return error.InvalidRuntimeDirectory;
    defer runtime.deinit();
    const log_file = openLogFileInRuntime(runtime) catch |err| {
        std.debug.print("Failed to open log file: {s}\n", .{@errorName(err)});
        return err;
    };
    const log_fd = log_file.handle;

    if (std.c.dup2(log_fd, std.c.STDOUT_FILENO) < 0 or
        std.c.dup2(log_fd, std.c.STDERR_FILENO) < 0)
    {
        return error.LogRedirectFailed;
    }
    compat.posixClose(log_fd);

    const dev_null = try compat.fs.openFileAbsolute("/dev/null", .{});
    defer dev_null.close(compat.io());
    if (std.c.dup2(dev_null.handle, std.c.STDIN_FILENO) < 0) {
        return error.StandardDescriptorSetupFailed;
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
    try argv_list.append(
        allocator,
        try std.fmt.allocPrint(
            allocator,
            "--daemon-lock-fd={d}",
            .{lock_file.handle},
        ),
    );
    var startup_token_hex: [32]u8 = undefined;
    try argv_list.append(
        allocator,
        try std.fmt.allocPrint(
            allocator,
            "--startup-token={s}",
            .{startup_token.formatHex(&startup_token_hex)},
        ),
    );

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

fn descriptorNonceForPid(
    allocator: std.mem.Allocator,
    pid: i32,
) ?runtime_descriptor.Nonce {
    if (pid <= 0) return null;
    var default_store = (runtime_descriptor.openDefault(allocator, false) catch return null) orelse
        return null;
    defer default_store.deinit();
    var descriptor = (default_store.store().observe() catch return null) orelse return null;
    defer descriptor.deinit();
    if (descriptor.pid != @as(u32, @intCast(pid))) return null;
    return descriptor.nonce;
}

fn removeDescriptor(
    allocator: std.mem.Allocator,
    expected: ?runtime_descriptor.Nonce,
) void {
    const nonce = expected orelse return;
    var default_store = (runtime_descriptor.openDefault(allocator, false) catch return) orelse
        return;
    defer default_store.deinit();
    _ = default_store.store().remove(nonce) catch return;
}

fn runtimeInstanceMatches(
    allocator: std.mem.Allocator,
    pid: i32,
    nonce: runtime_descriptor.Nonce,
) !bool {
    const state = try inspectRuntime(allocator);
    if (state.pid == null or state.pid.? != pid) return false;
    const observed = descriptorNonceForPid(allocator, pid) orelse return false;
    return observed.eql(nonce);
}

/// 停止守护进程。只返回事实（LifecycleOutcome）或错误；envelope/文本由
/// main.zig 经 cli/output.zig 恰好打印一次。
pub fn stopDaemon(allocator: std.mem.Allocator) !LifecycleOutcome {
    const runtime = try inspectRuntime(allocator);
    const pid = runtime.pid orelse {
        if (runtime.lock_held) return error.DaemonPidUntracked;
        return .{ .detail = "already_stopped" };
    };
    const nonce = descriptorNonceForPid(allocator, pid) orelse
        return error.DaemonPidUntracked;
    if (!try runtimeInstanceMatches(allocator, pid, nonce)) {
        return error.DaemonInstanceChanged;
    }
    try publishStopRequest(allocator, nonce);

    var attempt: u8 = 0;
    while (attempt < 50) : (attempt += 1) {
        compat.sleepNs(100 * std.time.ns_per_ms);
        if (!try runtimeInstanceMatches(allocator, pid, nonce)) {
            const current = try inspectRuntime(allocator);
            if (current.lock_held) return error.DaemonInstanceChanged;
            _ = try removePidIfMatches(allocator, pid);
            removeDescriptor(allocator, nonce);
            return .{ .pid = pid };
        }
    }
    return error.DaemonStopTimeout;
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

    const outcome = try startDaemon(allocator, effective_config, extra_args);
    if (outcome.detail != null) return error.RestartContended;
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

    // A running daemon is never projected from the current active profile.
    // The matching descriptor supplies a bounded fallback identity; a successful
    // IPC response then replaces both fields authoritatively, including null/empty.
    if (snapshot.pid) |pid| {
        snapshot.runtime_state_available = false;
        if (snapshot.active_config) |old| allocator.free(old);
        snapshot.active_config = null;
        runtime_selection.deinitSelectedProxies(
            allocator,
            snapshot.selected_proxies,
        );
        snapshot.selected_proxies = try allocator.alloc(
            runtime_selection.SelectedProxy,
            0,
        );

        var default_store = (runtime_descriptor.openDefault(allocator, false) catch null);
        defer if (default_store) |*value| value.deinit();
        if (default_store) |value| {
            var descriptor = (value.store().observe() catch null);
            defer if (descriptor) |*observed| observed.deinit();
            if (descriptor) |observed| {
                if (observed.pid == @as(u32, @intCast(pid))) {
                    if (observed.identity) |identity| {
                        snapshot.active_config = try allocator.dupe(u8, identity.key);
                    }
                }
            }
        }

        if (try fetchDaemonStatusOverIpc(allocator, pid)) |ds_val| {
            snapshot.runtime_state_available = true;
            var ds = ds_val;
            defer ds.deinit(allocator);
            if (snapshot.active_config) |old| allocator.free(old);
            snapshot.active_config = ds.config_key;
            ds.config_key = null;
            runtime_selection.deinitSelectedProxies(
                allocator,
                snapshot.selected_proxies,
            );
            snapshot.selected_proxies = ds.selected_proxies;
            ds.selected_proxies = &.{};
        }
    }

    try emitStatus(allocator, out, &snapshot);
}

fn openRuntimeForLog(
    allocator: std.mem.Allocator,
    follow: bool,
) !?runtime_dir.RuntimeDir {
    return runtime_dir.openDefault(allocator, false) catch |err| switch (err) {
        error.InvalidRuntimeDirectory => if (follow) null else return err,
        else => return err,
    };
}

/// 查看日志（默认显示最后 50 行，持续刷新）。
/// 日志行是主输出，永远走 stdout：JSON 模式下为 JSON Lines（每行一个
/// {"line":"..."} 对象），文本模式下为时间戳行；横幅类提示是诊断，走 stderr。
pub fn viewLog(allocator: std.mem.Allocator, lines: ?usize, follow: bool, out: *cli_output.Output) !void {
    var runtime: runtime_dir.RuntimeDir = while (true) {
        if (try openRuntimeForLog(allocator, follow)) |value| break value;
        if (!follow) {
            if (out.mode != .json) out.note("No log file found\n", .{}) catch {};
            return;
        }
        compat.sleepNs(500 * std.time.ns_per_ms);
    };
    defer runtime.deinit();
    var file: compat.fs.File = while (true) {
        break runtime.openFile(runtime_dir.log_name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (!follow) {
                    if (out.mode != .json) {
                        out.note("No log file found\n", .{}) catch {};
                    }
                    return;
                }
                compat.sleepNs(500 * std.time.ns_per_ms);
                if (try openRuntimeForLog(allocator, true)) |opened| {
                    var candidate = opened;
                    var candidate_owned = true;
                    defer if (candidate_owned) candidate.deinit();
                    const candidate_stat = try candidate.dir.stat(compat.io());
                    const current_stat = try runtime.dir.stat(compat.io());
                    if (candidate_stat.inode != current_stat.inode) {
                        runtime.deinit();
                        runtime = candidate;
                        candidate_owned = false;
                    }
                }
                continue;
            },
            else => return err,
        };
    };
    defer file.close(compat.io());

    // 首先显示最后 N 行
    const n = lines orelse 50;
    const initial_size = try printLastNLines(allocator, file, n, out);

    // 如果需要持续刷新
    if (follow) {
        if (out.mode != .json) out.note("\n--- Following log (Ctrl+C to exit) ---\n", .{}) catch {};
        var carry = std.ArrayList(u8).empty;
        defer carry.deinit(allocator);

        var last_pos = initial_size;

        while (true) {
            compat.sleepNs(500 * std.time.ns_per_ms); // 500ms 刷新一次

            var current_runtime = (try openRuntimeForLog(
                allocator,
                true,
            )) orelse {
                const old_size = (try file.stat(compat.io())).size;
                try emitLogRange(
                    allocator,
                    file,
                    &last_pos,
                    old_size,
                    &carry,
                    out,
                );
                continue;
            };
            var current_runtime_owned = true;
            defer if (current_runtime_owned) current_runtime.deinit();
            const current_dir_stat = try current_runtime.dir.stat(compat.io());
            const open_dir_stat = try runtime.dir.stat(compat.io());
            if (current_dir_stat.inode != open_dir_stat.inode) {
                const replacement = current_runtime.openFile(
                    runtime_dir.log_name,
                    .{},
                ) catch |err| switch (err) {
                    error.FileNotFound => {
                        const old_size = (try file.stat(compat.io())).size;
                        try emitLogRange(
                            allocator,
                            file,
                            &last_pos,
                            old_size,
                            &carry,
                            out,
                        );
                        continue;
                    },
                    else => return err,
                };
                const old_size = (try file.stat(compat.io())).size;
                try emitLogRange(
                    allocator,
                    file,
                    &last_pos,
                    old_size,
                    &carry,
                    out,
                );
                file.close(compat.io());
                runtime.deinit();
                runtime = current_runtime;
                current_runtime_owned = false;
                file = replacement;
                if (carry.items.len > 0) {
                    emitLogLine(out, carry.items);
                    carry.clearRetainingCapacity();
                }
                if (out.mode != .json) {
                    out.note(
                        "\n--- Runtime directory recreated, reopening log ---\n",
                        .{},
                    ) catch {};
                }
                last_pos = 0;
            }

            const path_stat = runtime.dir.statFile(
                compat.io(),
                runtime_dir.log_name,
                .{ .follow_symlinks = false },
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    const old_size = (try file.stat(compat.io())).size;
                    try emitLogRange(
                        allocator,
                        file,
                        &last_pos,
                        old_size,
                        &carry,
                        out,
                    );
                    continue;
                },
                else => return err,
            };
            const open_stat = try file.stat(compat.io());
            if (path_stat.kind != .file) return error.InvalidRuntimeLog;
            if (path_stat.inode != open_stat.inode) {
                try emitLogRange(
                    allocator,
                    file,
                    &last_pos,
                    open_stat.size,
                    &carry,
                    out,
                );
                const replacement = try runtime.openFile(runtime_dir.log_name, .{});
                file.close(compat.io());
                file = replacement;
                if (carry.items.len > 0) {
                    emitLogLine(out, carry.items);
                    carry.clearRetainingCapacity();
                }
                if (out.mode != .json) {
                    out.note("\n--- Log file rotated, reopening ---\n", .{}) catch {};
                }
                last_pos = 0;
            }

            const new_size = (try file.stat(compat.io())).size;

            if (new_size > last_pos) {
                try emitLogRange(
                    allocator,
                    file,
                    &last_pos,
                    new_size,
                    &carry,
                    out,
                );
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
fn emitLogRange(
    allocator: std.mem.Allocator,
    file: compat.fs.File,
    position: *u64,
    end: u64,
    carry: *std.ArrayList(u8),
    out: *cli_output.Output,
) !void {
    if (end <= position.*) return;
    try compat.fileSeekTo(file, position.*);
    var buffer: [4096]u8 = undefined;
    while (position.* < end) {
        const remaining: usize = @intCast(@min(
            end - position.*,
            buffer.len,
        ));
        const bytes_read = try compat.fileRead(file, buffer[0..remaining]);
        if (bytes_read == 0) break;
        try printTimestampedChunk(
            allocator,
            buffer[0..bytes_read],
            carry,
            out,
        );
        position.* += @intCast(bytes_read);
    }
}

fn printLastNLines(
    allocator: std.mem.Allocator,
    file: compat.fs.File,
    n: usize,
    out: *cli_output.Output,
) !u64 {
    const file_size = (try file.stat(compat.io())).size;
    const max_size = 1024 * 1024 * 10; // 10MB max
    const read_size = @min(file_size, max_size);

    if (read_size == 0) return file_size;

    const content = try allocator.alloc(u8, read_size);
    defer allocator.free(content);

    try compat.fileSeekTo(file, file_size - read_size);
    _ = try compat.fileReadAll(file, content);

    try printTimestampedSlice(allocator, tailLinesSlice(content, n), out);
    return file_size;
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
    try std.testing.expect(first_lock.?.handle >= 3);
    try protectDaemonLockFromExec(first_lock.?.handle);
    const fd_flags = std.c.fcntl(first_lock.?.handle, std.c.F.GETFD);
    try std.testing.expect(fd_flags >= 0);
    try std.testing.expect(fd_flags & std.posix.FD_CLOEXEC != 0);

    try std.testing.expectError(error.DaemonAlreadyRunning, acquireDaemonLockFileAtPath(lock_path));

    first_lock.?.close(compat.io());
    first_lock = null;

    var second_lock = try acquireDaemonLockFileAtPath(lock_path);
    defer second_lock.close(compat.io());
}

test "daemon log path resets after the hard size limit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.setDirPermissions(
        tmp.dir,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const path = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(path);
    var runtime = (try runtime_dir.openPath(allocator, path, false)).?;
    defer runtime.deinit();
    const log = try runtime.createExclusive(runtime_dir.log_name);
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.ftruncate(log.handle, @intCast(daemon_log_max_bytes + 1)),
    );
    log.close(compat.io());
    try std.testing.expect(try resetLogPathIfOversized(runtime));
    const replacement = try runtime.openFile(runtime_dir.log_name, .{});
    defer replacement.close(compat.io());
    try std.testing.expectEqual(@as(u64, 0), (try replacement.stat(compat.io())).size);
}

test "pid cleanup compares under the daemon lock" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.setDirPermissions(
        tmp.dir,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const path = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(path);
    var runtime = (try runtime_dir.openPath(allocator, path, false)).?;
    defer runtime.deinit();

    try writePidInRuntime(runtime, 101);
    try std.testing.expect(!try removePidIfMatchesInRuntime(runtime, 202));
    try std.testing.expectEqual(@as(?i32, 101), try readPidInRuntime(runtime));

    var held_lock = try acquireDaemonLockFileInRuntime(runtime);
    try std.testing.expect(!try removePidIfMatchesInRuntime(runtime, 101));
    held_lock.close(compat.io());
    try std.testing.expect(try removePidIfMatchesInRuntime(runtime, 101));
    try std.testing.expect(try readPidInRuntime(runtime) == null);
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
    var out = cli_output.Output.init(.text, "log", false, false, &out_aw.writer, &err_aw.writer);

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
    var out = cli_output.Output.init(.json, "log", false, false, &out_aw.writer, &err_aw.writer);

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
    var out = cli_output.Output.init(.json, "status", false, false, &out_aw.writer, &err_aw.writer);

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
    var out = cli_output.Output.init(.text, "status", false, false, &out_aw.writer, &err_aw.writer);

    try emitStatus(allocator, &out, &snapshot);

    try std.testing.expect(std.mem.indexOf(u8, out_aw.written(), "state: stopped") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_aw.written(), "detail: stale_pid_file") != null);
    try std.testing.expectEqualStrings("", err_aw.written());
}

test "parseDaemonStatusJson preserves selection sources" {
    const allocator = std.testing.allocator;
    const body = "{\"config_key\":\"Flower_Trojan\",\"selected_proxies\":[{\"group\":\"Proxies\",\"proxy\":\"SG-1\",\"source\":\"persisted\"},{\"group\":\"Temp\",\"proxy\":\"US-1\",\"source\":\"transient\"},{\"group\":\"HK\",\"proxy\":\"HK-1\",\"source\":\"default\"}]}";
    var ds = (try parseDaemonStatusJson(allocator, body)).?;
    defer ds.deinit(allocator);

    try std.testing.expectEqualStrings("Flower_Trojan", ds.config_key.?);
    try std.testing.expectEqual(@as(usize, 3), ds.selected_proxies.len);
    try std.testing.expectEqualStrings("Proxies", ds.selected_proxies[0].group_name);
    try std.testing.expectEqualStrings("SG-1", ds.selected_proxies[0].proxy_name.?);
    try std.testing.expectEqual(runtime_selection.SelectionSource.persisted, ds.selected_proxies[0].source);
    try std.testing.expectEqual(runtime_selection.SelectionSource.transient, ds.selected_proxies[1].source);
    try std.testing.expectEqual(runtime_selection.SelectionSource.default, ds.selected_proxies[2].source);
}

test "parseDaemonStatusJson: null config_key and empty selections" {
    const allocator = std.testing.allocator;
    const body = "{\"config_key\":null,\"selected_proxies\":[]}";
    var ds = (try parseDaemonStatusJson(allocator, body)).?;
    defer ds.deinit(allocator);
    try std.testing.expect(ds.config_key == null);
    try std.testing.expectEqual(@as(usize, 0), ds.selected_proxies.len);
}

test "parseDaemonStatusJson: malformed or incomplete JSON returns null" {
    const allocator = std.testing.allocator;
    try std.testing.expect(
        (try parseDaemonStatusJson(allocator, "not json")) == null,
    );
    try std.testing.expect(
        (try parseDaemonStatusJson(allocator, "{}")) == null,
    );
    try std.testing.expect(
        (try parseDaemonStatusJson(
            allocator,
            "{\"config_key\":null}",
        )) == null,
    );
}
