//! CLI 集成测试：驱动真实 `zc` 二进制，断言 envelope 形状与退出码。
//!
//! 运行环境约定（build.zig 的 test step 提供）：
//! - HOME / XDG_RUNTIME_DIR 已指向 .zig-cache 下的隔离目录，本文件的所有
//!   zc 调用绝不触碰真实用户环境或生产 daemon；
//! - cwd 为仓库根（与 main.zig 中读取 src/*.zig 的现有测试同一约定）。
//!
//! 二进制由首个用例触发 `zig build` 产出（zig-out/bin/zc），之后直接复用。

const std = @import("std");
const compat = @import("compat.zig");
const daemon = @import("daemon.zig");
const runtime_descriptor = @import("runtime_descriptor.zig");
const runtime_dir = @import("runtime_dir.zig");
const config_identity = @import("config_identity.zig");
const selection_state = @import("selection_state.zig");

const max_output = 1024 * 1024;
const zc_binary = "zig-out/bin/zc";

var zc_binary_ready = false;

fn exitCode(term: anytype) !u8 {
    return switch (term) {
        .exited => |code| code,
        else => error.AbnormalTermination,
    };
}

fn ensureZcBinary(allocator: std.mem.Allocator) !void {
    if (zc_binary_ready) return;
    const result = try compat.childRun(allocator, &.{ "zig", "build" }, max_output);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if ((try exitCode(result.term)) != 0) {
        std.debug.print("zig build failed:\n{s}\n", .{result.stderr});
        return error.ZcBuildFailed;
    }
    zc_binary_ready = true;
}

const CliRun = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(self: *CliRun, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !CliRun {
    try ensureZcBinary(allocator);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zc_binary);
    for (args) |arg| try argv.append(allocator, arg);

    const result = try compat.childRun(allocator, argv.items, max_output);
    errdefer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = try exitCode(result.term),
    };
}

fn runCliWithHome(
    allocator: std.mem.Allocator,
    home: []const u8,
    args: []const []const u8,
) !CliRun {
    try ensureZcBinary(allocator);
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zc_binary);
    for (args) |arg| try argv.append(allocator, arg);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    const result = try std.process.run(allocator, compat.io(), .{
        .argv = argv.items,
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    errdefer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = try exitCode(result.term),
    };
}

/// stdout 必须是恰好一行可解析的 JSON envelope。
fn parseEnvelope(
    allocator: std.mem.Allocator,
    stdout: []const u8,
) !std.json.Parsed(std.json.Value) {
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stdout, "\n"));
    return std.json.parseFromSlice(std.json.Value, allocator, stdout, .{});
}

fn expectErrorEnvelope(root: std.json.Value, command: []const u8, code: []const u8) !void {
    const obj = root.object;
    try std.testing.expect(!obj.get("ok").?.bool);
    try std.testing.expectEqualStrings(command, obj.get("command").?.string);
    const err = obj.get("error").?.object;
    try std.testing.expectEqualStrings(code, err.get("code").?.string);
    try std.testing.expect(err.get("message").?.string.len != 0);
    try std.testing.expect(err.get("hint").?.string.len != 0);
}

/// 写到 cwd（仓库根）下的 .zig-cache，返回 zc 子进程可用的相对路径。
fn writeTempConfig(allocator: std.mem.Allocator, name: []const u8, contents: []const u8) ![]u8 {
    const rel_path = try compat.fs.path.join(allocator, &.{ ".zig-cache", name });
    errdefer allocator.free(rel_path);
    const file = try std.Io.Dir.cwd().createFile(compat.io(), rel_path, .{});
    defer file.close(compat.io());
    try compat.fileWriteAll(file, contents);
    return rel_path;
}

/// 仓库 YAML 解析器要求 block-style（无 inline {}/[]）。
fn validConfigYaml(allocator: std.mem.Allocator, mixed_port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\mixed-port: {d}
        \\mode: rule
        \\log-level: info
        \\
        \\proxies:
        \\  - name: demo-ss
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: "password"
        \\
        \\proxy-groups:
        \\  - name: PROXY
        \\    type: select
        \\    proxies:
        \\      - demo-ss
        \\      - DIRECT
        \\
        \\rules:
        \\  - MATCH,PROXY
        \\
    , .{mixed_port});
}

/// 绑定再立刻释放一个端口：拿到“几乎必然无人监听”的端口号。
fn reserveClosedPort() !u16 {
    const addr = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try compat.net.listenReuseAddr(addr);
    const port = listener.listen_address.getPort();
    listener.deinit();
    return port;
}

// ---------------------------------------------------------------------------
// 未知/缺失子命令：envelope + exit_usage
// ---------------------------------------------------------------------------

test "integration: profile unknown subcommand -> PROFILE_SUBCOMMAND_UNKNOWN, exit_usage" {
    const allocator = std.testing.allocator;
    // 历史漂移：曾断言 PROFILE_NOT_FOUND，但没有任何 dispatch 输出该码；
    // `profile use` 实际走 unknown-subcommand 路径。
    var run = try runCli(allocator, &.{ "profile", "use", "not-exist.yaml", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "profile use", "PROFILE_SUBCOMMAND_UNKNOWN");
}

test "integration: proxy unknown subcommand -> PROXY_SUBCOMMAND_UNKNOWN, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "proxy", "nope", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "proxy nope", "PROXY_SUBCOMMAND_UNKNOWN");
}

test "integration: diag unknown subcommand -> DIAG_SUBCOMMAND_UNKNOWN, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "diag", "nope", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "diag nope", "DIAG_SUBCOMMAND_UNKNOWN");
}

test "integration: diag with flags but no subcommand -> DIAG_SUBCOMMAND_MISSING, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "diag", "-c", "x.yaml", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "diag", "DIAG_SUBCOMMAND_MISSING");
}

test "integration: bare diag prints group help on stdout, exit 0" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{"diag"});
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), run.code);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "Usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "doctor") != null);
    try std.testing.expectEqualStrings("", run.stderr);
}

// ---------------------------------------------------------------------------
// 生命周期命令用法错误（决策 D11）：未知/多余参数、缺值 flag -> exit_usage。
// 全部在参数解析阶段失败，绝不触碰 daemon（且测试环境 HOME/XDG 已隔离）。
// ---------------------------------------------------------------------------

test "integration: start unknown flag -> START_ARGS_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "start", "--bogus", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "start", "START_ARGS_INVALID");
}

test "integration: start unknown flag text mode -> error block on stderr, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "start", "--bogus" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    try std.testing.expectEqualStrings("", run.stdout);
    try std.testing.expect(std.mem.indexOf(u8, run.stderr, "error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stderr, "START_ARGS_INVALID") != null);
}

test "integration: restart missing --port value -> START_PORT_REQUIRED, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "restart", "--port", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "restart", "START_PORT_REQUIRED");
}

test "integration: stop extra argument -> STOP_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "stop", "extra", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "stop", "STOP_ARGUMENT_INVALID");
}

test "integration: status unknown flag -> STATUS_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "status", "--bogus", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "status", "STATUS_ARGUMENT_INVALID");
}

test "integration: reload extra argument -> RELOAD_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "reload", "nope", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "reload", "RELOAD_ARGUMENT_INVALID");
}

test "integration: log invalid -n value -> LOG_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "log", "-n", "abc", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "log", "LOG_ARGUMENT_INVALID");
}

test "integration: doctor unknown flag -> DIAG_DOCTOR_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "doctor", "--bogus", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "doctor", "DIAG_DOCTOR_ARGUMENT_INVALID");
}

test "integration: diag doctor extra argument -> DIAG_DOCTOR_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "diag", "doctor", "stray", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "diag doctor", "DIAG_DOCTOR_ARGUMENT_INVALID");
}

// ---------------------------------------------------------------------------
// zc test：--help、配置加载失败、CHECKS_FAILED（D3）
// ---------------------------------------------------------------------------

test "integration: zc test --help prints command help via table interception" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "test", "--help" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), run.code);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "zc test") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "--port <port>") != null);
    try std.testing.expectEqualStrings("", run.stderr);
}

test "integration: zc test config-load failure emits envelope in json mode" {
    const allocator = std.testing.allocator;
    var run = try runCli(
        allocator,
        &.{ "test", "-c", ".zig-cache/itest-definitely-missing.yaml", "--json" },
    );
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "test", "PROXY_CONFIG_LOAD_FAILED");
}

test "integration: zc test config-load failure prints error block in text mode" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "test", "-c", ".zig-cache/itest-definitely-missing.yaml" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), run.code);
    try std.testing.expect(std.mem.indexOf(u8, run.stderr, "PROXY_CONFIG_LOAD_FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "\"ok\":") == null);
}

test "integration: zc test --json fails with CHECKS_FAILED when port not listening" {
    const allocator = std.testing.allocator;

    const yaml = try validConfigYaml(allocator, 7892);
    defer allocator.free(yaml);
    const cfg_path = try writeTempConfig(allocator, "itest-test-valid.yaml", yaml);
    defer allocator.free(cfg_path);

    const closed_port = try reserveClosedPort();
    var port_buf: [8]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{closed_port});

    var run = try runCli(allocator, &.{ "test", "-c", cfg_path, "--port", port_text, "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "test", "CHECKS_FAILED");
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqualStrings("proxy_test", data.get("action").?.string);
    try std.testing.expect(data.get("daemon_state") != null);
    const ports = data.get("ports").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), ports.len);
    try std.testing.expect(!ports[0].object.get("listening").?.bool);
    try std.testing.expect(data.get("checks").?.array.items.len >= 1);
}

test "integration: zc test --json succeeds against a local responder (same probes as text)" {
    const allocator = std.testing.allocator;

    const yaml = try validConfigYaml(allocator, 7892);
    defer allocator.free(yaml);
    const cfg_path = try writeTempConfig(allocator, "itest-test-responder.yaml", yaml);
    defer allocator.free(cfg_path);

    var responder = try HttpResponder.start();
    defer responder.stop();

    var port_buf: [8]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{responder.port()});

    var run = try runCli(allocator, &.{ "test", "-c", cfg_path, "--port", port_text, "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("ok").?.bool);
    try std.testing.expectEqualStrings("test", root.get("command").?.string);
    const data = root.get("data").?.object;
    const checks = data.get("checks").?.array.items;
    for (checks) |check| try std.testing.expect(check.object.get("ok").?.bool);
    // JSON 模式跑了真探测：targets 非空（曾经 JSON 跳过全部探测、永不失败）。
    try std.testing.expect(data.get("targets").?.array.items.len > 0);
}

// ---------------------------------------------------------------------------
// zc doctor / diag doctor：CHECKS_FAILED + 配置加载失败
// ---------------------------------------------------------------------------

test "integration: zc doctor --json healthy config (stopped daemon) -> ok:true with facts" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "doctor", "-c", "testdata/config/minimal.yaml", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("ok").?.bool);
    try std.testing.expectEqualStrings("doctor", root.get("command").?.string);
    const data = root.get("data").?.object;
    // run-soak-real.sh 依赖该字段可从 stdout 读到。
    try std.testing.expect(data.get("proxy_reachable") != null);
    try std.testing.expect(data.get("network_ok") != null);
    try std.testing.expect(data.get("config_ok").?.bool);
    try std.testing.expectEqual(@as(usize, 2), data.get("checks").?.array.items.len);
}

test "integration: zc doctor --json invalid config -> CHECKS_FAILED with config_errors" {
    const allocator = std.testing.allocator;

    // 可解析但通不过校验：组引用未定义节点。
    const yaml =
        \\mixed-port: 7892
        \\mode: rule
        \\log-level: info
        \\
        \\proxies:
        \\  - name: demo-ss
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: "password"
        \\
        \\proxy-groups:
        \\  - name: PROXY
        \\    type: select
        \\    proxies:
        \\      - no-such-node
        \\
        \\rules:
        \\  - MATCH,PROXY
        \\
    ;
    const cfg_path = try writeTempConfig(allocator, "itest-doctor-invalid.yaml", yaml);
    defer allocator.free(cfg_path);

    var run = try runCli(allocator, &.{ "doctor", "-c", cfg_path, "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "doctor", "CHECKS_FAILED");
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expect(!data.get("config_ok").?.bool);
    try std.testing.expect(data.get("config_errors").?.array.items.len > 0);
    try std.testing.expect(data.get("proxy_reachable") != null);
}

test "integration: doctor config-load failure -> DIAG_DOCTOR_FAILED in both modes" {
    const allocator = std.testing.allocator;

    var json_run = try runCli(
        allocator,
        &.{ "doctor", "-c", ".zig-cache/itest-definitely-missing.yaml", "--json" },
    );
    defer json_run.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), json_run.code);
    var parsed = try parseEnvelope(allocator, json_run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "doctor", "DIAG_DOCTOR_FAILED");

    // text 模式曾被 json-only guard 吞错（裸 Zig trace）；现在必须有错误块。
    var text_run = try runCli(
        allocator,
        &.{ "doctor", "-c", ".zig-cache/itest-definitely-missing.yaml" },
    );
    defer text_run.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), text_run.code);
    try std.testing.expect(std.mem.indexOf(u8, text_run.stderr, "DIAG_DOCTOR_FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_run.stderr, "panic") == null);
}

test "integration: zc doctor text keeps frozen labels and exit 0 on healthy config" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "doctor", "-c", "testdata/config/minimal.yaml" });
    defer run.deinit(allocator);

    // e2e-test-podman.sh 依赖：有效配置（即使 daemon 停止）exit 0，
    // 文本含 "OK"（grep "OK\|valid"）与冻结标签。
    try std.testing.expectEqual(@as(u8, 0), run.code);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "Config: OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "Daemon:") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "PID:") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "Port:") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "Connection:") != null);
}

// ---------------------------------------------------------------------------
// 本地 HTTP 应答器：让连通性探测（curl 经“代理”端口）在沙箱内可确定成功。
// ---------------------------------------------------------------------------

const HttpResponder = struct {
    listener: compat.net.ReuseAddrListener,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),

    fn start() !*HttpResponder {
        const self = try std.heap.page_allocator.create(HttpResponder);
        errdefer std.heap.page_allocator.destroy(self);
        const addr = try compat.net.Address.parseIp4("127.0.0.1", 0);
        self.listener = try compat.net.listenReuseAddr(addr);
        self.stop_flag = std.atomic.Value(bool).init(false);
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
        return self;
    }

    fn port(self: *HttpResponder) u16 {
        return self.listener.listen_address.getPort();
    }

    fn stop(self: *HttpResponder) void {
        // serveLoop polls the listener with a timeout and re-checks stop_flag, so
        // setting the flag is enough to make it return — no need to wake a blocking
        // accept() with a self-connect. The old self-connect wake was best-effort
        // (其错误被 else |_| 吞掉); under full-suite load it could fail to wake the
        // accept(), leaving this join() deadlocked forever (worker parked in
        // inet_csk_accept, main in join). Flag + bounded poll removes that race.
        self.stop_flag.store(true, .seq_cst);
        self.thread.join();
        self.listener.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn serveLoop(self: *HttpResponder) void {
        while (true) {
            if (self.stop_flag.load(.seq_cst)) return;
            // Wait for a pending connection with a 100ms timeout instead of a bare
            // blocking accept(), so a concurrent stop() is noticed within one tick.
            var fds = [_]std.posix.pollfd{.{
                .fd = self.listener.fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&fds, 100) catch return;
            if (ready == 0) continue; // timeout: loop back and re-check stop_flag
            const conn = self.listener.accept() catch continue;
            var buf: [4096]u8 = undefined;
            _ = conn.stream.read(&buf) catch {};
            conn.stream.writeAll(
                "HTTP/1.1 204 No Content\r\n" ++
                    "Content-Length: 0\r\nConnection: close\r\n\r\n",
            ) catch {};
            conn.stream.close();
        }
    }
};

fn connectController(port: u16) !compat.net.Stream {
    const address = try compat.net.Address.parseIp4("127.0.0.1", port);
    return compat.net.tcpConnectToAddress(address);
}

fn waitForController(port: u16) !void {
    for (0..250) |_| {
        if (connectController(port)) |stream| {
            stream.close();
            return;
        } else |_| {}
        compat.sleepNs(20 * std.time.ns_per_ms);
    }
    return error.ControllerStartTimeout;
}

fn responseContentLength(header: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    _ = lines.next() orelse return error.InvalidHttpResponse;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch
            error.InvalidHttpResponse;
    }
    return error.InvalidHttpResponse;
}

fn readResponseWithin(
    stream: compat.net.Stream,
    buffer: []u8,
    timeout_ms: i32,
) ![]const u8 {
    const deadline = compat.monotonicMilliTimestamp() + timeout_ms;
    var used: usize = 0;
    while (true) {
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |header_end| {
            const body_length = try responseContentLength(buffer[0..header_end]);
            const total = header_end + 4 + body_length;
            if (total > buffer.len) return error.ResponseTooLarge;
            if (used >= total) return buffer[0..total];
        }
        if (used == buffer.len) return error.ResponseTooLarge;
        const remaining = deadline - compat.monotonicMilliTimestamp();
        if (remaining <= 0) return error.ResponseTimeout;
        var descriptors = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(
            &descriptors,
            @intCast(@min(remaining, std.math.maxInt(i32))),
        );
        if (ready == 0) return error.ResponseTimeout;
        const count = try stream.read(buffer[used..]);
        if (count == 0) return error.UnexpectedEndOfStream;
        used += count;
    }
}

fn stopIsolatedDaemon(
    allocator: std.mem.Allocator,
    environment: *std.process.Environ.Map,
) void {
    const result = std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "stop", "--json" },
        .environ_map = environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

test "integration: special pid files fail without blocking" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.setDirPermissions(
        tmp.dir,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const pid_path = try compat.fs.path.join(allocator, &.{ root, "zc.pid" });
    defer allocator.free(pid_path);
    const made = try compat.childRun(allocator, &.{ "mkfifo", pid_path }, max_output);
    defer allocator.free(made.stdout);
    defer allocator.free(made.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(made.term));

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("XDG_RUNTIME_DIR", root);
    const result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(1),
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(result.term));
    var envelope = try parseEnvelope(allocator, result.stdout);
    defer envelope.deinit();
    try expectErrorEnvelope(envelope.value, "status", "STATUS_FAILED");
}

test "integration: corrupt metadata fails closed without replacement" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(
        compat.io(),
        "home/.config/zc/configs",
    );
    const home = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "home",
        allocator,
    );
    defer allocator.free(home);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);

    for ([_][]const u8{ "{not-json\n", "" }) |corrupt_metadata| {
        try tmp.dir.writeFile(compat.io(), .{
            .sub_path = "home/.config/zc/meta.json",
            .data = corrupt_metadata,
        });
        const result = try std.process.run(allocator, compat.io(), .{
            .argv = &.{ zc_binary, "config", "list", "--json" },
            .environ_map = &environment,
            .stdout_limit = .limited(max_output),
            .stderr_limit = .limited(max_output),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(
            @as(u8, 1),
            try exitCode(result.term),
        );
        var parsed = try parseEnvelope(allocator, result.stdout);
        defer parsed.deinit();
        try expectErrorEnvelope(
            parsed.value,
            "config list",
            "CONFIG_LIST_FAILED",
        );
        const preserved = try tmp.dir.readFileAlloc(
            compat.io(),
            "home/.config/zc/meta.json",
            allocator,
            .limited(64),
        );
        defer allocator.free(preserved);
        try std.testing.expectEqualStrings(corrupt_metadata, preserved);
    }
}

test "integration: catalog without active config does not fall back during dump" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "source.yaml",
        .data = "mixed-port: 7890\n",
    });
    const home = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "home",
        allocator,
    );
    defer allocator.free(home);
    const source = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "source.yaml",
        allocator,
    );
    defer allocator.free(source);

    var loaded = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "load", source, "--json" },
    );
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), loaded.code);
    var load_envelope = try parseEnvelope(allocator, loaded.stdout);
    defer load_envelope.deinit();
    const load_data = load_envelope.value.object.get("data").?.object;
    try std.testing.expect(!load_data.get("durability_uncertain").?.bool);
    try std.testing.expect(!load_data.get("mirror_out_of_sync").?.bool);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "home/.config/zc/configs/ghost.yaml",
        .data = "mixed-port: 7000\n",
    });
    const ghost_path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "home/.config/zc/configs/ghost.yaml",
        allocator,
    );
    defer allocator.free(ghost_path);
    var ghost_dump = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "dump", "-c", ghost_path, "--json" },
    );
    defer ghost_dump.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), ghost_dump.code);
    var ghost_envelope = try parseEnvelope(allocator, ghost_dump.stdout);
    defer ghost_envelope.deinit();
    try expectErrorEnvelope(
        ghost_envelope.value,
        "config dump",
        "CONFIG_DUMP_FAILED",
    );

    var deleted = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "delete", "source", "--json" },
    );
    defer deleted.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), deleted.code);

    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "home/.config/zc/meta.json",
        .data = "{not-a-mirror\n",
    });
    var listed = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "list", "--json" },
    );
    defer listed.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    var list_envelope = try parseEnvelope(allocator, listed.stdout);
    defer list_envelope.deinit();
    const list_data = list_envelope.value.object.get("data").?.object;
    try std.testing.expect(!list_data.get("durability_uncertain").?.bool);
    try std.testing.expect(list_data.get("mirror_out_of_sync").?.bool);

    var dumped = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "dump", "--json" },
    );
    defer dumped.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), dumped.code);
    var envelope = try parseEnvelope(allocator, dumped.stdout);
    defer envelope.deinit();
    try expectErrorEnvelope(envelope.value, "config dump", "CONFIG_DUMP_FAILED");
}

test "integration: missing active config does not fall back to direct" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(
        compat.io(),
        "home/.config/zc/configs",
    );
    const metadata =
        "{\"active\":\"missing\",\"configs\":{\"missing\":{}}}\n";
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "home/.config/zc/meta.json",
        .data = metadata,
    });
    const home = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "home",
        allocator,
    );
    defer allocator.free(home);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);

    const result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "proxy", "list", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(result.term));
    var parsed = try parseEnvelope(allocator, result.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(
        parsed.value,
        "proxy list",
        "PROXY_CONFIG_LOAD_FAILED",
    );

    const override_result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "config", "override", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(override_result.stdout);
    defer allocator.free(override_result.stderr);
    try std.testing.expectEqual(
        @as(u8, 1),
        try exitCode(override_result.term),
    );
    var override_envelope = try parseEnvelope(
        allocator,
        override_result.stdout,
    );
    defer override_envelope.deinit();
    try expectErrorEnvelope(
        override_envelope.value,
        "config override",
        "CONFIG_OVERRIDE_FAILED",
    );
}

test "integration: configured missing runtime directory fails closed" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const missing = try compat.fs.path.join(allocator, &.{ root, "missing" });
    defer allocator.free(missing);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("XDG_RUNTIME_DIR", missing);

    const result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(result.term));
    var envelope = try parseEnvelope(allocator, result.stdout);
    defer envelope.deinit();
    try expectErrorEnvelope(envelope.value, "status", "STATUS_FAILED");
}

test "integration: startup preserves endpoint validation errors" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_path = try compat.fs.path.join(
        allocator,
        &.{ root, "invalid.yaml" },
    );
    defer allocator.free(config_path);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    try tmp.dir.createDirPath(compat.io(), "home/.config/zc");
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "home/.config/zc/meta.json",
        .data = "{corrupt-legacy-metadata\n",
    });

    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "invalid.yaml",
        .data =
        \\allow-lan: true
        \\bind-address: invalid-address
        \\mixed-port: 7891
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\rules:
        \\  - MATCH,DIRECT
        \\
        ,
    });
    for ([_][]const []const u8{
        &.{
            zc_binary,
            "start",
            "--foreground",
            "-c",
            config_path,
            "--json",
        },
        &.{ zc_binary, "start", "-c", config_path, "--json" },
    }) |argv| {
        const result = try std.process.run(allocator, compat.io(), .{
            .argv = argv,
            .environ_map = &environment,
            .stdout_limit = .limited(max_output),
            .stderr_limit = .limited(max_output),
            .timeout = .{ .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromSeconds(5),
            } },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 1), try exitCode(result.term));
        var envelope = try parseEnvelope(allocator, result.stdout);
        defer envelope.deinit();
        try expectErrorEnvelope(
            envelope.value,
            "start",
            "START_BIND_ADDRESS_INVALID",
        );
    }

    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "invalid.yaml",
        .data =
        \\mixed-port: 7891
        \\external-controller: localhost:9090
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\rules:
        \\  - MATCH,DIRECT
        \\
        ,
    });
    const controller = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(controller.stdout);
    defer allocator.free(controller.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(controller.term));
    var controller_envelope = try parseEnvelope(allocator, controller.stdout);
    defer controller_envelope.deinit();
    try expectErrorEnvelope(
        controller_envelope.value,
        "start",
        "START_EXTERNAL_CONTROLLER_INVALID",
    );
}

test "integration: provisional startup is not reported as running" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_path = try compat.fs.path.join(
        allocator,
        &.{ root, "startup.yaml" },
    );
    defer allocator.free(config_path);
    const script_path = try compat.fs.path.join(
        allocator,
        &.{ root, "slow-override.sh" },
    );
    defer allocator.free(script_path);
    const mixed_port = try reserveClosedPort();
    const source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nproxies:\n  - name: DIRECT\n    type: direct\nrules:\n  - MATCH,DIRECT\n",
        .{mixed_port},
    );
    defer allocator.free(source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "startup.yaml",
        .data = source,
    });
    const script = try tmp.dir.createFile(
        compat.io(),
        "slow-override.sh",
        .{ .permissions = std.Io.File.Permissions.fromMode(0o700) },
    );
    try compat.fileWriteAll(script, "#!/bin/sh\nsleep 1\nprintf '{}\\n'\n");
    script.close(compat.io());

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    defer stopIsolatedDaemon(allocator, &environment);

    const start_argv = [_][]const u8{
        zc_binary,
        "start",
        "-c",
        config_path,
        "--override-script",
        script_path,
        "--json",
    };
    var first = try std.process.spawn(compat.io(), .{
        .argv = &start_argv,
        .environ_map = &environment,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer first.kill(compat.io());

    var saw_provisional = false;
    var attempt: u8 = 0;
    while (attempt < 40) : (attempt += 1) {
        const bytes = tmp.dir.readFileAlloc(
            compat.io(),
            "run/zc.daemon.json",
            allocator,
            .limited(64 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                compat.sleepNs(25 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        defer allocator.free(bytes);
        var descriptor = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            bytes,
            .{},
        );
        defer descriptor.deinit();
        if (!descriptor.value.object.get("ready").?.bool) {
            saw_provisional = true;
            break;
        }
    }
    try std.testing.expect(saw_provisional);

    const status = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(status.stdout);
    defer allocator.free(status.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(status.term));
    var status_envelope = try parseEnvelope(allocator, status.stdout);
    defer status_envelope.deinit();
    try expectErrorEnvelope(status_envelope.value, "status", "STATUS_FAILED");

    const concurrent = try std.process.run(allocator, compat.io(), .{
        .argv = &start_argv,
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(concurrent.stdout);
    defer allocator.free(concurrent.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(concurrent.term));
    var concurrent_envelope = try parseEnvelope(allocator, concurrent.stdout);
    defer concurrent_envelope.deinit();
    try std.testing.expectEqualStrings(
        "already_running",
        concurrent_envelope.value.object.get("data").?.object.get("detail").?.string,
    );
    try std.testing.expectEqual(@as(u8, 0), try exitCode(try first.wait(compat.io())));
    const ready = try connectController(mixed_port);
    ready.close();
}

test "integration: background start returns only after listeners are ready" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );

    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_home = try compat.fs.path.join(allocator, &.{ home, ".config" });
    defer allocator.free(config_home);
    const state_home = try compat.fs.path.join(allocator, &.{ home, ".local", "state" });
    defer allocator.free(state_home);
    const config_path = try compat.fs.path.join(allocator, &.{ root, "config.yaml" });
    defer allocator.free(config_path);

    const mixed_port = try reserveClosedPort();
    var controller_port = try reserveClosedPort();
    while (controller_port == mixed_port) controller_port = try reserveClosedPort();
    const source = try std.fmt.allocPrint(allocator,
        \\mixed-port: {d}
        \\external-controller: 127.0.0.1:{d}
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\  - name: REJECT
        \\    type: reject
        \\proxy-groups:
        \\  - name: Proxy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.yaml
        \\rules:
        \\  - RULE-SET,local,Proxy
        \\  - MATCH,DIRECT
        \\
    , .{ mixed_port, controller_port });
    defer allocator.free(source);
    const file = try tmp.dir.createFile(compat.io(), "config.yaml", .{});
    defer file.close(compat.io());
    try compat.fileWriteAll(file, source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "rules.yaml",
        .data = "payload:\n  - example.com\n",
    });

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_CONFIG_HOME", config_home);
    try environment.put("XDG_STATE_HOME", state_home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    defer stopIsolatedDaemon(allocator, &environment);

    const imported = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "config", "load", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(imported.stdout);
    defer allocator.free(imported.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(imported.term));
    try tmp.dir.deleteFile(compat.io(), "rules.yaml");

    const started = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(15),
        } },
    });
    defer allocator.free(started.stdout);
    defer allocator.free(started.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(started.term));
    var envelope = try parseEnvelope(allocator, started.stdout);
    defer envelope.deinit();
    try std.testing.expect(envelope.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings(
        "running",
        envelope.value.object.get("data").?.object.get("state").?.string,
    );

    const mixed = try connectController(mixed_port);
    mixed.close();
    const route_probe = try connectController(mixed_port);
    try route_probe.writeAll(
        "CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n",
    );
    var route_response: [1024]u8 = undefined;
    _ = route_probe.read(&route_response) catch {};
    route_probe.close();
    compat.sleepNs(150 * std.time.ns_per_ms);
    const route_log = try tmp.dir.readFileAlloc(
        compat.io(),
        "run/zc.log",
        allocator,
        .limited(256 * 1024),
    );
    defer allocator.free(route_log);
    try std.testing.expect(
        std.mem.indexOf(u8, route_log, "[Engine]") == null,
    );
    const controller = try connectController(controller_port);
    controller.close();
    try tmp.dir.access(compat.io(), "run/zc.pid", .{});
    var descriptor_path_buffer: [64]u8 = undefined;
    const descriptor_path = try std.fmt.bufPrint(
        &descriptor_path_buffer,
        "run/{s}",
        .{runtime_descriptor.file_name},
    );
    try tmp.dir.access(compat.io(), descriptor_path, .{});

    var lock_path_buffer: [128]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(
        &lock_path_buffer,
        "run/{s}",
        .{runtime_dir.lock_name},
    );
    var old_lock_path_buffer: [160]u8 = undefined;
    const old_lock_path = try std.fmt.bufPrint(
        &old_lock_path_buffer,
        "run/{s}.old",
        .{runtime_dir.lock_name},
    );
    const tracked_pid_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        "run/zc.pid",
        allocator,
        .limited(32),
    );
    defer allocator.free(tracked_pid_bytes);
    const tracked_pid = try std.fmt.parseInt(
        i32,
        std.mem.trim(u8, tracked_pid_bytes, " \t\r\n"),
        10,
    );
    try std.posix.kill(tracked_pid, std.posix.SIG.STOP);
    var daemon_paused = true;
    defer if (daemon_paused) {
        std.posix.kill(tracked_pid, std.posix.SIG.CONT) catch {};
    };
    try tmp.dir.deleteFile(compat.io(), "run/zc.pid");
    try tmp.dir.rename(lock_path, tmp.dir, old_lock_path, compat.io());
    const replacement_lock = try tmp.dir.createFile(
        compat.io(),
        lock_path,
        .{ .read = true, .truncate = false },
    );
    replacement_lock.close(compat.io());
    const uncertain_status = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(uncertain_status.stdout);
    defer allocator.free(uncertain_status.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(uncertain_status.term));
    var uncertain_envelope = try parseEnvelope(
        allocator,
        uncertain_status.stdout,
    );
    defer uncertain_envelope.deinit();
    try expectErrorEnvelope(uncertain_envelope.value, "status", "STATUS_FAILED");
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "run/zc.pid", .{}),
    );

    const duplicate_start = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(duplicate_start.stdout);
    defer allocator.free(duplicate_start.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(duplicate_start.term));
    try tmp.dir.deleteFile(compat.io(), lock_path);
    try tmp.dir.rename(old_lock_path, tmp.dir, lock_path, compat.io());
    const restored_pid = try tmp.dir.createFile(compat.io(), "run/zc.pid", .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    try compat.fileWriteAll(restored_pid, tracked_pid_bytes);
    restored_pid.close(compat.io());
    try std.posix.kill(tracked_pid, std.posix.SIG.CONT);
    daemon_paused = false;

    const selected = try std.process.run(allocator, compat.io(), .{
        .argv = &.{
            zc_binary,
            "proxy",
            "select",
            "-g",
            "Proxy",
            "-p",
            "REJECT",
            "--json",
        },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(selected.stdout);
    defer allocator.free(selected.stderr);
    const selected_exit = try exitCode(selected.term);
    if (selected_exit != 0) {
        std.debug.print(
            "proxy select failed: stdout={s} stderr={s}\n",
            .{ selected.stdout, selected.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), selected_exit);
    var selected_envelope = try parseEnvelope(allocator, selected.stdout);
    defer selected_envelope.deinit();
    try std.testing.expect(
        selected_envelope.value.object.get("data").?.object.get("applied").?.bool,
    );
    const applied_descriptor_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        descriptor_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(applied_descriptor_bytes);
    var applied_descriptor = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        applied_descriptor_bytes,
        .{},
    );
    defer applied_descriptor.deinit();
    try std.testing.expectEqual(
        @as(i64, 1),
        applied_descriptor.value.object.get("generation").?.integer,
    );
    try std.testing.expect(
        applied_descriptor.value.object.get("ready").?.bool,
    );
    const descriptor_object = applied_descriptor.value.object;
    const metadata_free_body = "{\"name\":\"DIRECT\"}";
    const metadata_free_request = try std.fmt.allocPrint(
        allocator,
        "PUT /proxies/Proxy HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n\r\n{s}",
        .{ metadata_free_body.len, metadata_free_body },
    );
    defer allocator.free(metadata_free_request);
    const metadata_free_connection = try connectController(controller_port);
    defer metadata_free_connection.close();
    try metadata_free_connection.writeAll(metadata_free_request);
    var metadata_free_response_buffer: [4096]u8 = undefined;
    const metadata_free_response = try readResponseWithin(
        metadata_free_connection,
        &metadata_free_response_buffer,
        1_000,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, metadata_free_response, "HTTP/1.1 409 ") != null,
    );
    const partial_metadata_body = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"DIRECT\",\"instance_nonce\":\"{s}\"}}",
        .{descriptor_object.get("nonce").?.string},
    );
    defer allocator.free(partial_metadata_body);
    const partial_metadata_request = try std.fmt.allocPrint(
        allocator,
        "PUT /proxies/Proxy HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n\r\n{s}",
        .{ partial_metadata_body.len, partial_metadata_body },
    );
    defer allocator.free(partial_metadata_request);
    const partial_metadata_connection = try connectController(controller_port);
    defer partial_metadata_connection.close();
    try partial_metadata_connection.writeAll(partial_metadata_request);
    var partial_metadata_response_buffer: [4096]u8 = undefined;
    const partial_metadata_response = try readResponseWithin(
        partial_metadata_connection,
        &partial_metadata_response_buffer,
        1_000,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, partial_metadata_response, "HTTP/1.1 400 ") != null,
    );

    const stale_body = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"DIRECT\",\"instance_nonce\":\"{s}\",\"identity_key\":\"{s}\",\"identity_revision\":\"{s}\",\"generation\":1}}",
        .{
            descriptor_object.get("nonce").?.string,
            descriptor_object.get("identity").?.object.get("key").?.string,
            descriptor_object.get("identity").?.object.get("revision").?.string,
        },
    );
    defer allocator.free(stale_body);
    const stale_request = try std.fmt.allocPrint(
        allocator,
        "PUT /proxies/Proxy HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n\r\n{s}",
        .{ stale_body.len, stale_body },
    );
    defer allocator.free(stale_request);
    const stale_connection = try connectController(controller_port);
    defer stale_connection.close();
    try stale_connection.writeAll(stale_request);
    var stale_response_buffer: [4096]u8 = undefined;
    const stale_response = try readResponseWithin(
        stale_connection,
        &stale_response_buffer,
        1_000,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, stale_response, "HTTP/1.1 409 ") != null,
    );

    const managed_identity: config_identity.ManagedIdentity = .{
        .key = descriptor_object.get("identity").?.object.get("key").?.string,
        .revision = try config_identity.Revision.parseHex(
            descriptor_object.get("identity").?.object.get("revision").?.string,
        ),
    };
    const state_root = try tmp.dir.openDir(
        compat.io(),
        "home/.config/zc",
        .{},
    );
    defer state_root.close(compat.io());
    const desired_state = selection_state.State.init(allocator, state_root);
    const generation_two = try desired_state.persist(
        managed_identity,
        "Proxy",
        "DIRECT",
    );
    try std.testing.expectEqual(@as(?u64, 2), generation_two.generation);
    const generation_three = try desired_state.persist(
        managed_identity,
        "Proxy",
        "REJECT",
    );
    try std.testing.expectEqual(@as(?u64, 3), generation_three.generation);

    const jumped = try std.process.run(allocator, compat.io(), .{
        .argv = &.{
            zc_binary,
            "proxy",
            "select",
            "-g",
            "Proxy",
            "-p",
            "DIRECT",
            "--json",
        },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(jumped.stdout);
    defer allocator.free(jumped.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(jumped.term));
    var jumped_envelope = try parseEnvelope(allocator, jumped.stdout);
    defer jumped_envelope.deinit();
    try std.testing.expect(
        jumped_envelope.value.object.get("data").?.object.get("applied").?.bool,
    );
    const jumped_descriptor_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        descriptor_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(jumped_descriptor_bytes);
    var jumped_descriptor = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        jumped_descriptor_bytes,
        .{},
    );
    defer jumped_descriptor.deinit();
    try std.testing.expectEqual(
        @as(i64, 4),
        jumped_descriptor.value.object.get("generation").?.integer,
    );

    const oversized_log = try tmp.dir.openFile(
        compat.io(),
        "run/zc.log",
        .{ .mode = .read_write },
    );
    const oversized_log_inode = (try oversized_log.stat(compat.io())).inode;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.ftruncate(
            oversized_log.handle,
            @intCast(daemon.daemon_log_max_bytes + 1),
        ),
    );
    oversized_log.close(compat.io());
    var log_rotated = false;
    const rotation_deadline = compat.monotonicMilliTimestamp() + 2_000;
    while (compat.monotonicMilliTimestamp() < rotation_deadline) {
        const current_log = try tmp.dir.statFile(
            compat.io(),
            "run/zc.log",
            .{ .follow_symlinks = false },
        );
        if (current_log.inode != oversized_log_inode) {
            log_rotated = true;
            break;
        }
        compat.sleepNs(1 * std.time.ns_per_ms);
    }
    try std.testing.expect(log_rotated);

    try tmp.dir.rename(
        "run/zc.log",
        tmp.dir,
        "run/zc.log.old",
        compat.io(),
    );
    var log_recreated = false;
    var log_attempt: u8 = 0;
    while (log_attempt < 20) : (log_attempt += 1) {
        if (tmp.dir.access(compat.io(), "run/zc.log", .{})) |_| {
            log_recreated = true;
            break;
        } else |_| {}
        compat.sleepNs(50 * std.time.ns_per_ms);
    }
    try std.testing.expect(log_recreated);

    const stopped = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "stop", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(15),
        } },
    });
    defer allocator.free(stopped.stdout);
    defer allocator.free(stopped.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(stopped.term));
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "run/zc.pid", .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), descriptor_path, .{}),
    );

    var follower = try std.process.spawn(compat.io(), .{
        .argv = &.{ zc_binary, "log", "-f", "-n", "1" },
        .environ_map = &environment,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer follower.kill(compat.io());
    const follower_stdout = follower.stdout orelse
        return error.TestUnexpectedResult;
    try compat.setNonBlock(follower_stdout.handle);
    compat.sleepNs(100 * std.time.ns_per_ms);
    try tmp.dir.rename(
        "run/zc.log",
        tmp.dir,
        "run/zc.log.gap-old",
        compat.io(),
    );
    const old_log = try tmp.dir.openFile(
        compat.io(),
        "run/zc.log.gap-old",
        .{ .mode = .read_write },
    );
    try compat.fileSeekTo(old_log, (try old_log.stat(compat.io())).size);
    try compat.fileWriteAll(old_log, "old-after-rename\n");
    old_log.close(compat.io());
    compat.sleepNs(700 * std.time.ns_per_ms);
    const new_log = try tmp.dir.createFile(compat.io(), "run/zc.log", .{});
    try new_log.setPermissions(
        compat.io(),
        std.Io.File.Permissions.fromMode(0o600),
    );
    try compat.fileWriteAll(new_log, "new-after-gap\n");
    new_log.close(compat.io());

    var followed = std.ArrayList(u8).empty;
    defer followed.deinit(allocator);
    const follow_deadline = compat.monotonicMilliTimestamp() + 2_000;
    var read_buffer: [1024]u8 = undefined;
    while (compat.monotonicMilliTimestamp() < follow_deadline) {
        const count = compat.posixRead(
            follower_stdout.handle,
            &read_buffer,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                compat.sleepNs(25 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (count == 0) break;
        try followed.appendSlice(allocator, read_buffer[0..count]);
        if (std.mem.indexOf(u8, followed.items, "new-after-gap") != null) break;
    }
    try std.testing.expect(
        std.mem.indexOf(u8, followed.items, "old-after-rename") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, followed.items, "new-after-gap") != null,
    );

    try tmp.dir.rename("run", tmp.dir, "run.previous", compat.io());
    compat.sleepNs(700 * std.time.ns_per_ms);
    try tmp.dir.createDir(compat.io(), "run", .default_dir);
    const replacement_runtime = try tmp.dir.openDir(compat.io(), "run", .{});
    try compat.setDirPermissions(
        replacement_runtime,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const replacement_runtime_log = try replacement_runtime.createFile(
        compat.io(),
        "zc.log",
        .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
    );
    try compat.fileWriteAll(replacement_runtime_log, "new-runtime-dir\n");
    replacement_runtime_log.close(compat.io());
    replacement_runtime.close(compat.io());
    const runtime_reopen_deadline = compat.monotonicMilliTimestamp() + 2_000;
    while (compat.monotonicMilliTimestamp() < runtime_reopen_deadline) {
        const count = compat.posixRead(
            follower_stdout.handle,
            &read_buffer,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                compat.sleepNs(25 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (count == 0) break;
        try followed.appendSlice(allocator, read_buffer[0..count]);
        if (std.mem.indexOf(u8, followed.items, "new-runtime-dir") != null) break;
    }
    try std.testing.expect(
        std.mem.indexOf(u8, followed.items, "new-runtime-dir") != null,
    );
    follower.kill(compat.io());

    try tmp.dir.deleteFile(compat.io(), "run/zc.log");
    var initial_missing_follower = try std.process.spawn(compat.io(), .{
        .argv = &.{ zc_binary, "log", "-f", "-n", "1" },
        .environ_map = &environment,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer initial_missing_follower.kill(compat.io());
    const initial_missing_stdout = initial_missing_follower.stdout orelse
        return error.TestUnexpectedResult;
    try compat.setNonBlock(initial_missing_stdout.handle);
    compat.sleepNs(100 * std.time.ns_per_ms);
    try tmp.dir.rename("run", tmp.dir, "run.initial-old", compat.io());
    compat.sleepNs(700 * std.time.ns_per_ms);
    try tmp.dir.createDir(compat.io(), "run", .default_dir);
    const initial_replacement_runtime = try tmp.dir.openDir(
        compat.io(),
        "run",
        .{},
    );
    try compat.setDirPermissions(
        initial_replacement_runtime,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const initial_replacement_log = try initial_replacement_runtime.createFile(
        compat.io(),
        "zc.log",
        .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
    );
    try compat.fileWriteAll(initial_replacement_log, "initial-log-appeared\n");
    initial_replacement_log.close(compat.io());
    initial_replacement_runtime.close(compat.io());
    var initial_followed = std.ArrayList(u8).empty;
    defer initial_followed.deinit(allocator);
    const initial_follow_deadline = compat.monotonicMilliTimestamp() + 2_000;
    while (compat.monotonicMilliTimestamp() < initial_follow_deadline) {
        const count = compat.posixRead(
            initial_missing_stdout.handle,
            &read_buffer,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                compat.sleepNs(25 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (count == 0) break;
        try initial_followed.appendSlice(allocator, read_buffer[0..count]);
        if (std.mem.indexOf(
            u8,
            initial_followed.items,
            "initial-log-appeared",
        ) != null) break;
    }
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            initial_followed.items,
            "initial-log-appeared",
        ) != null,
    );
    initial_missing_follower.kill(compat.io());

    const no_controller_port = try reserveClosedPort();
    const no_controller_source = try std.fmt.allocPrint(allocator,
        \\mixed-port: {d}
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\rules:
        \\  - MATCH,DIRECT
        \\
    , .{no_controller_port});
    defer allocator.free(no_controller_source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "config.yaml",
        .data = no_controller_source,
    });
    const no_controller_start = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(15),
        } },
    });
    defer allocator.free(no_controller_start.stdout);
    defer allocator.free(no_controller_start.stderr);
    try std.testing.expectEqual(
        @as(u8, 0),
        try exitCode(no_controller_start.term),
    );
    const no_controller = try connectController(no_controller_port);
    no_controller.close();
    const descriptor_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        descriptor_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(descriptor_bytes);
    var parsed_descriptor = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        descriptor_bytes,
        .{},
    );
    defer parsed_descriptor.deinit();
    try std.testing.expect(
        parsed_descriptor.value.object.get("endpoint").? == .null,
    );
    const replaced_runtime_pid: i32 = @intCast(
        parsed_descriptor.value.object.get("pid").?.integer,
    );
    try tmp.dir.rename(
        "run",
        tmp.dir,
        "run.daemon-replaced",
        compat.io(),
    );
    compat.sleepNs(700 * std.time.ns_per_ms);
    try tmp.dir.createDir(compat.io(), "run", .default_dir);
    const recreated_runtime = try tmp.dir.openDir(compat.io(), "run", .{});
    try compat.setDirPermissions(
        recreated_runtime,
        std.Io.File.Permissions.fromMode(0o700),
    );
    recreated_runtime.close(compat.io());
    var exited = false;
    var exit_attempt: u8 = 0;
    while (exit_attempt < 40) : (exit_attempt += 1) {
        std.posix.kill(replaced_runtime_pid, @enumFromInt(0)) catch {
            exited = true;
            break;
        };
        compat.sleepNs(25 * std.time.ns_per_ms);
    }
    try std.testing.expect(exited);
    const replacement_start = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(15),
        } },
    });
    defer allocator.free(replacement_start.stdout);
    defer allocator.free(replacement_start.stderr);
    try std.testing.expectEqual(
        @as(u8, 0),
        try exitCode(replacement_start.term),
    );
    const final_stop = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "stop", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(15),
        } },
    });
    defer allocator.free(final_stop.stdout);
    defer allocator.free(final_stop.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(final_stop.term));

    try tmp.dir.deleteFile(compat.io(), "run/zc.log");
    try tmp.dir.createDir(compat.io(), "run/zc.log", .default_dir);
    const bootstrap_failure = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(bootstrap_failure.stdout);
    defer allocator.free(bootstrap_failure.stderr);
    try std.testing.expectEqual(
        @as(u8, 1),
        try exitCode(bootstrap_failure.term),
    );
    var bootstrap_envelope = try parseEnvelope(
        allocator,
        bootstrap_failure.stdout,
    );
    defer bootstrap_envelope.deinit();
    try expectErrorEnvelope(bootstrap_envelope.value, "start", "START_FAILED");
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, bootstrap_failure.stdout, "{\"ok\":"),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "run/zc.pid", .{}),
    );
    const restart_bootstrap_failure = try std.process.run(
        allocator,
        compat.io(),
        .{
            .argv = &.{ zc_binary, "restart", "-c", config_path, "--json" },
            .environ_map = &environment,
            .stdout_limit = .limited(max_output),
            .stderr_limit = .limited(max_output),
            .timeout = .{ .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromSeconds(5),
            } },
        },
    );
    defer allocator.free(restart_bootstrap_failure.stdout);
    defer allocator.free(restart_bootstrap_failure.stderr);
    try std.testing.expectEqual(
        @as(u8, 1),
        try exitCode(restart_bootstrap_failure.term),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            restart_bootstrap_failure.stdout,
            "{\"ok\":",
        ),
    );
    try tmp.dir.deleteTree(compat.io(), "run/zc.log");

    const descriptor_lock_path = try std.fmt.bufPrint(
        &descriptor_path_buffer,
        "run/{s}",
        .{runtime_descriptor.lock_name},
    );
    const held_descriptor_lock = try tmp.dir.createFile(
        compat.io(),
        descriptor_lock_path,
        .{ .read = true, .truncate = false, .lock = .exclusive },
    );
    defer held_descriptor_lock.close(compat.io());
    const rejected_publish = try std.process.run(allocator, compat.io(), .{
        .argv = &.{
            zc_binary,
            "start",
            "--foreground",
            "-c",
            config_path,
            "--json",
        },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(rejected_publish.stdout);
    defer allocator.free(rejected_publish.stderr);
    try std.testing.expectEqual(
        @as(u8, 1),
        try exitCode(rejected_publish.term),
    );
    var rejected_envelope = try parseEnvelope(
        allocator,
        rejected_publish.stdout,
    );
    defer rejected_envelope.deinit();
    try expectErrorEnvelope(
        rejected_envelope.value,
        "start",
        "START_RUNTIME_PUBLISH_FAILED",
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "run/zc.pid", .{}),
    );

    const rejected_background = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(rejected_background.stdout);
    defer allocator.free(rejected_background.stderr);
    const rejected_background_exit = try exitCode(rejected_background.term);
    if (std.mem.indexOf(u8, rejected_background.stdout, "START_RUNTIME_PUBLISH_FAILED") == null) {
        std.debug.print(
            "background publish rejection: stdout={s} stderr={s}\n",
            .{ rejected_background.stdout, rejected_background.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 1), rejected_background_exit);
    var background_envelope = try parseEnvelope(
        allocator,
        rejected_background.stdout,
    );
    defer background_envelope.deinit();
    try expectErrorEnvelope(
        background_envelope.value,
        "start",
        "START_RUNTIME_PUBLISH_FAILED",
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "run/zc.pid", .{}),
    );
}

test "integration: minimal API isolates idle clients and frames PUT bodies" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home/.config");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );

    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_path = try compat.fs.path.join(allocator, &.{ root, "config.yaml" });
    defer allocator.free(config_path);

    const mixed_port = try reserveClosedPort();
    var controller_port = try reserveClosedPort();
    while (controller_port == mixed_port) controller_port = try reserveClosedPort();
    const source = try std.fmt.allocPrint(allocator,
        \\mixed-port: {d}
        \\external-controller: 127.0.0.1:{d}
        \\secret: test-secret
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\proxy-groups:
        \\  - name: Proxy
        \\    type: select
        \\    proxies:
        \\      - DIRECT
        \\rules:
        \\  - MATCH,Proxy
        \\
    , .{ mixed_port, controller_port });
    defer allocator.free(source);
    const file = try tmp.dir.createFile(compat.io(), "config.yaml", .{});
    defer file.close(compat.io());
    try compat.fileWriteAll(file, source);
    const sentinel = try tmp.dir.createFile(compat.io(), "sentinel", .{});
    try compat.fileWriteAll(sentinel, "unchanged");
    sentinel.close(compat.io());
    tmp.dir.symLink(compat.io(), "../sentinel", "run/zc.pid", .{}) catch
        return error.SkipZigTest;

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);

    const rejected = try std.process.run(allocator, compat.io(), .{
        .argv = &.{
            zc_binary,
            "start",
            "--foreground",
            "-c",
            config_path,
            "--json",
        },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(1),
        } },
    });
    defer allocator.free(rejected.stdout);
    defer allocator.free(rejected.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(rejected.term));
    try std.testing.expect(
        std.mem.indexOf(u8, rejected.stdout, "START_PREFLIGHT_FAILED") != null,
    );
    try tmp.dir.deleteFile(compat.io(), "run/zc.pid");

    var child = try std.process.spawn(compat.io(), .{
        .argv = &.{ zc_binary, "start", "--foreground", "-c", config_path },
        .environ_map = &environment,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(compat.io());
    try waitForController(controller_port);
    const sentinel_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        "sentinel",
        allocator,
        .limited(32),
    );
    defer allocator.free(sentinel_bytes);
    try std.testing.expectEqualStrings("unchanged", sentinel_bytes);

    const idle = try connectController(controller_port);
    defer idle.close();
    {
        const active = try connectController(controller_port);
        defer active.close();
        try active.writeAll("GET /version HTTP/1.1\r\nHost: local\r\n\r\n");
        var response_buffer: [4096]u8 = undefined;
        const response = try readResponseWithin(active, &response_buffer, 1_000);
        try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
        try std.testing.expect(
            std.mem.indexOf(u8, response, "Connection: close\r\n") != null,
        );
    }

    {
        const headerless = try connectController(controller_port);
        defer headerless.close();
        try headerless.writeAll("GET /version HTTP/1.0\r\n\r\n");
        var response_buffer: [4096]u8 = undefined;
        const response = try readResponseWithin(headerless, &response_buffer, 1_000);
        try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    }

    {
        const body = "{\"name\":\"DIRECT\"}";
        const invalid_lengths = [_][]const u8{
            "Content-Length: +17",
            "Content-Length: 1_7",
            "Content-Length : 17",
            " Content-Length: 17",
            "\tContent-Length: 17",
            "Content-Length: 17\r\n" ++
                "X-Ignored: value\nContent-Length: 0",
            "Content-Length: 17\r\n" ++
                "X-Ignored: value\nTransfer-Encoding: chunked",
            "Content-Length: 65537\r\n" ++
                "X-Ignored: value\nTransfer-Encoding: chunked",
            "Transfer-Encoding: chunked\r\n" ++
                "X-Ignored: value\rContent-Length: 0",
        };
        for (invalid_lengths) |length_header| {
            const invalid = try connectController(controller_port);
            defer invalid.close();
            const request = try std.fmt.allocPrint(
                allocator,
                "PUT /proxies/Proxy HTTP/1.1\r\n" ++
                    "Host: local\r\n{s}\r\n\r\n{s}",
                .{ length_header, body },
            );
            defer allocator.free(request);
            try invalid.writeAll(request);
            var response_buffer: [4096]u8 = undefined;
            const response = try readResponseWithin(
                invalid,
                &response_buffer,
                1_000,
            );
            try std.testing.expect(
                std.mem.indexOf(u8, response, "400 Bad Request") != null,
            );
        }
    }

    {
        const body = "{\"name\":\"DIRECT\"}";
        const unauthorized = try connectController(controller_port);
        defer unauthorized.close();
        const unauthorized_request = try std.fmt.allocPrint(
            allocator,
            "PUT /proxies/Proxy HTTP/1.1\r\n" ++
                "Host: local\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ body.len, body },
        );
        defer allocator.free(unauthorized_request);
        try unauthorized.writeAll(unauthorized_request);
        var unauthorized_buffer: [4096]u8 = undefined;
        const unauthorized_response = try readResponseWithin(
            unauthorized,
            &unauthorized_buffer,
            1_000,
        );
        if (std.mem.indexOf(u8, unauthorized_response, "401 Unauthorized") == null) {
            std.debug.print("unauthorized response: {s}\n", .{unauthorized_response});
            return error.TestUnexpectedResult;
        }

        const header = try std.fmt.allocPrint(
            allocator,
            "PUT /proxies/Proxy HTTP/1.1\r\n" ++
                "Host: local\r\n" ++
                "Authorization: Bearer test-secret\r\n" ++
                "Content-Length: {d}\r\n\r\n",
            .{body.len},
        );
        defer allocator.free(header);
        const fragmented = try connectController(controller_port);
        defer fragmented.close();
        try fragmented.writeAll(header);
        compat.sleepNs(20 * std.time.ns_per_ms);
        try fragmented.writeAll(body);
        var response_buffer: [4096]u8 = undefined;
        const response = try readResponseWithin(fragmented, &response_buffer, 1_000);
        try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    }

    {
        const oversized = try connectController(controller_port);
        defer oversized.close();
        try oversized.writeAll(
            "PUT / HTTP/1.1\r\nContent-Length: 65537\r\n\r\n",
        );
        var response_buffer: [4096]u8 = undefined;
        const response = try readResponseWithin(oversized, &response_buffer, 1_000);
        try std.testing.expect(
            std.mem.indexOf(u8, response, "413 Payload Too Large") != null,
        );
    }

    var timeout_buffer: [4096]u8 = undefined;
    const timeout_response = try readResponseWithin(idle, &timeout_buffer, 4_000);
    try std.testing.expect(
        std.mem.indexOf(u8, timeout_response, "408 Request Timeout") != null,
    );
}
