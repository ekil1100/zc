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
    return .{ .stdout = result.stdout, .stderr = result.stderr, .code = try exitCode(result.term) };
}

/// stdout 必须是恰好一行可解析的 JSON envelope。
fn parseEnvelope(allocator: std.mem.Allocator, stdout: []const u8) !std.json.Parsed(std.json.Value) {
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
    var run = try runCli(allocator, &.{ "test", "-c", ".zig-cache/itest-definitely-missing.yaml", "--json" });
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
    defer responder.stop(allocator);

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

    var json_run = try runCli(allocator, &.{ "doctor", "-c", ".zig-cache/itest-definitely-missing.yaml", "--json" });
    defer json_run.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), json_run.code);
    var parsed = try parseEnvelope(allocator, json_run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "doctor", "DIAG_DOCTOR_FAILED");

    // text 模式曾被 json-only guard 吞错（裸 Zig trace）；现在必须有错误块。
    var text_run = try runCli(allocator, &.{ "doctor", "-c", ".zig-cache/itest-definitely-missing.yaml" });
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

    fn stop(self: *HttpResponder, allocator: std.mem.Allocator) void {
        self.stop_flag.store(true, .seq_cst);
        // 自连接唤醒阻塞中的 accept。
        if (compat.net.tcpConnectToHost(allocator, "127.0.0.1", self.port())) |stream| {
            stream.close();
        } else |_| {}
        self.thread.join();
        self.listener.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn serveLoop(self: *HttpResponder) void {
        while (true) {
            const conn = self.listener.accept() catch return;
            if (self.stop_flag.load(.seq_cst)) {
                conn.stream.close();
                return;
            }
            var buf: [4096]u8 = undefined;
            _ = conn.stream.read(&buf) catch {};
            conn.stream.writeAll("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
            conn.stream.close();
        }
    }
};
