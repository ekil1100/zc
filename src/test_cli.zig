const std = @import("std");
const compat = @import("compat.zig");
const config = @import("config.zig");
const daemon = @import("daemon.zig");
const runtime_selection = @import("runtime_selection.zig");
const cli_output = @import("cli/output.zig");

const TestTarget = struct {
    name: []const u8,
    url: []const u8,
};

/// 测试目标网站列表
const TEST_TARGETS = [_]TestTarget{
    .{ .name = "IP/Location", .url = "http://ip-api.com/json" },
    .{ .name = "Google", .url = "http://www.google.com/generate_204" },
    .{ .name = "YouTube", .url = "http://www.youtube.com/generate_204" },
    .{ .name = "Netflix", .url = "http://www.netflix.com" },
    .{ .name = "OpenAI", .url = "http://chat.openai.com" },
    .{ .name = "GitHub", .url = "http://github.com" },
    .{ .name = "Cloudflare", .url = "http://1.1.1.1" },
};

const CURL_CONNECT_TIMEOUT_SECONDS = "5";
const CURL_GEO_MAX_TIME_SECONDS = "90";
const CURL_LATENCY_MAX_TIME_SECONDS = "5";

const ProxyType = enum {
    http,
    socks5,
};

const TestStats = struct {
    attempted: usize = 0,
    succeeded: usize = 0,
};

const DaemonState = enum {
    running,
    stopped,
    unknown,
};

const EffectivePorts = struct {
    mixed: ?u16,
    http: ?u16,
    socks: ?u16,
};

const FailureReason = enum {
    dns,
    tcp_connect,
    tls_handshake,
    auth_or_proxy_response,
    timeout,
    unknown,
};

const CurlResult = union(enum) {
    ok: []u8,
    failed: FailureReason,
};

const LatencyResult = union(enum) {
    ok: u64,
    failed: FailureReason,
};

const LatencyProbeFn = *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!LatencyResult;

const LatencyWorkerSlot = struct {
    result: LatencyResult = .{ .failed = .unknown },
    err: ?anyerror = null,
    order: std.atomic.Value(usize) = std.atomic.Value(usize).init(std.math.maxInt(usize)),
};

const LatencyResultHandlerFn = *const fn (*anyopaque, TestTarget, LatencyResult) anyerror!void;

/// 单项检查结果（CHECKS_FAILED 的 data.checks 元素）。
pub const Check = struct {
    name: []const u8,
    ok: bool,
    detail: []const u8,
};

/// data.ports 元素（冻结字段名 label/port/listening）。
pub const PortStatus = struct {
    label: []const u8,
    port: u16,
    listening: bool,
};

/// data.targets 元素：单个连通性探测目标的结果。
/// emit_null_optional_fields=false：latency_ms/reason/ip 仅在有值时出现。
pub const TargetResult = struct {
    name: []const u8,
    ok: bool,
    latency_ms: ?u64 = null,
    reason: ?[]const u8 = null,
    ip: ?[]const u8 = null,
};

/// 探测过程的统一收集器：JSON/text 跑完全相同的探测（决策 D3），
/// text 模式边收集边渲染（payload 走 stdout），JSON 模式静默收集、
/// 最后输出单个 envelope。
const ProbeSink = struct {
    out: *cli_output.Output,
    arena: std.mem.Allocator,
    targets: std.ArrayList(TargetResult) = std.ArrayList(TargetResult).empty,

    fn record(self: *ProbeSink, result: TargetResult) !void {
        try self.targets.append(self.arena, result);
    }
};

/// 网络连接性测试（`zc test` / `zc proxy test` / `zc profile test` 共用）。
/// 决策 D3：两种模式跑相同探测；任何检查失败 -> error.code=CHECKS_FAILED
/// + data 携带逐项结果（JSON）/ stderr 错误块（text），返回 false，
/// 由调用方以非零码退出。返回 true = 全部检查通过（已输出成功 envelope）。
pub fn runConnectivityTest(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    config_key: ?[]const u8,
    out: *cli_output.Output,
) !bool {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const effective = selectEffectivePorts(cfg);
    const daemon_state = detectDaemonState(allocator);
    const selected_proxies = try runtime_selection.collectSelectedProxies(allocator, cfg, config_key);
    defer runtime_selection.deinitSelectedProxies(allocator, selected_proxies);

    const text_mode = out.mode == .text;
    if (text_mode) {
        try out.print("Network Connectivity Test\n", .{});
        try out.print("{s:-^60}\n", .{""});
        try printEffectivePortsSummary(out, effective);
        try printSelectedProxiesText(out, allocator, selected_proxies);
    }

    // 端口检查：每个生效端口一项（冻结 data 字段 ports 仍保留原始事实）。
    var ports = std.ArrayList(PortStatus).empty;
    var checks = std.ArrayList(Check).empty;
    const PortPlan = struct { label: []const u8, port: u16, proxy_type: ProxyType };
    var plan_buf: [2]PortPlan = undefined;
    var plan_len: usize = 0;
    if (effective.mixed) |p| {
        plan_buf[plan_len] = .{ .label = "mixed", .port = p, .proxy_type = .http };
        plan_len += 1;
    } else {
        if (effective.http) |p| {
            plan_buf[plan_len] = .{ .label = "http", .port = p, .proxy_type = .http };
            plan_len += 1;
        }
        if (effective.socks) |p| {
            plan_buf[plan_len] = .{ .label = "socks", .port = p, .proxy_type = .socks5 };
            plan_len += 1;
        }
    }

    var sink = ProbeSink{ .out = out, .arena = arena };
    var totals: TestStats = .{};
    var any_listening = false;

    if (plan_len == 0) {
        try checks.append(arena, .{ .name = "ports", .ok = false, .detail = "no proxy ports configured" });
    }

    for (plan_buf[0..plan_len]) |entry| {
        const listening = try isLocalPortListening(allocator, entry.port);
        try ports.append(arena, .{ .label = entry.label, .port = entry.port, .listening = listening });
        try checks.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "port:{s}", .{entry.label}),
            .ok = listening,
            .detail = try std.fmt.allocPrint(arena, "127.0.0.1:{d} {s}", .{
                entry.port,
                if (listening) "listening" else "not listening",
            }),
        });

        if (text_mode) {
            try out.print("\nTesting via {s} Proxy (127.0.0.1:{d}):\n", .{ proxyLabelTitle(entry.label), entry.port });
        }
        if (!listening) {
            if (text_mode) printPortNotListeningHint(out, entry.port, daemon_state);
            continue;
        }
        any_listening = true;
        totals = mergeStats(totals, try testViaProxy(allocator, entry.port, entry.proxy_type, &sink));
    }

    // 连通性检查：只有在至少一个端口可用时才有意义（同 text 旧语义：
    // attempted=0 也是失败）。
    if (any_listening) {
        try checks.append(arena, .{
            .name = "connectivity",
            .ok = connectivitySucceeded(totals),
            .detail = try std.fmt.allocPrint(arena, "{d}/{d} targets reachable", .{ totals.succeeded, totals.attempted }),
        });
    }

    var failed: usize = 0;
    for (checks.items) |check| {
        if (!check.ok) failed += 1;
    }

    // 冻结字段：action=proxy_test、daemon_state、ports、selected_proxies。
    const data = .{
        .action = "proxy_test",
        .daemon_state = daemonStateText(daemon_state),
        .selected_proxies = selected_proxies,
        .ports = ports.items,
        .checks = checks.items,
        .targets = sink.targets.items,
    };

    if (text_mode) try out.print("\n", .{});
    // 文本报告（stdout）必须在 success/fail 之前落盘：text 模式的 fail 只
    // flush stderr，不 flush 会把整份报告留在缓冲里丢掉。
    try out.flush();

    if (failed == 0) {
        try out.success(data);
        return true;
    }

    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{d} connectivity check(s) failed", .{failed}) catch "connectivity checks failed";
    var hint_buf: [128]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_buf, "check selected proxy, route rules, or upstream availability; suggested: {s}", .{
        notListeningSuggestedCommand(daemon_state),
    }) catch "run `zc status` and `zc log --no-follow`";
    try out.failWithData("CHECKS_FAILED", msg, hint, data);
    return false;
}

fn proxyLabelTitle(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "mixed")) return "Mixed";
    if (std.mem.eql(u8, label, "http")) return "HTTP";
    return "SOCKS5";
}

fn selectEffectivePorts(cfg: *const config.Config) EffectivePorts {
    if (cfg.mixed_port > 0) {
        return .{ .mixed = cfg.mixed_port, .http = null, .socks = null };
    }

    return .{
        .mixed = null,
        .http = if (cfg.port > 0) cfg.port else null,
        .socks = if (cfg.socks_port > 0) cfg.socks_port else null,
    };
}

fn printEffectivePortsSummary(out: *cli_output.Output, effective: EffectivePorts) !void {
    try out.print("Effective ports: ", .{});
    if (effective.mixed) |p| {
        try out.print("mixed=127.0.0.1:{d}\n", .{p});
        return;
    }

    var printed = false;
    if (effective.http) |p| {
        try out.print("http=127.0.0.1:{d}", .{p});
        printed = true;
    }
    if (effective.socks) |p| {
        if (printed) try out.print(", ", .{});
        try out.print("socks=127.0.0.1:{d}", .{p});
        printed = true;
    }
    if (!printed) {
        try out.print("none\n", .{});
    } else {
        try out.print("\n", .{});
    }
}

fn printSelectedProxiesText(
    out: *cli_output.Output,
    allocator: std.mem.Allocator,
    selections: []const runtime_selection.SelectedProxy,
) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try runtime_selection.appendSelectedProxiesText(&buf, allocator, selections);
    try out.print("{s}", .{buf.items});
}

fn detectDaemonState(allocator: std.mem.Allocator) DaemonState {
    const running = daemon.isRunning(allocator) catch return .unknown;
    return if (running) .running else .stopped;
}

fn daemonStateText(state: DaemonState) []const u8 {
    return switch (state) {
        .running => "running",
        .stopped => "stopped",
        .unknown => "unknown",
    };
}

fn printPortNotListeningHint(out: *cli_output.Output, port: u16, daemon_state: DaemonState) void {
    out.print("  Proxy not listening on 127.0.0.1:{d}.\n", .{port}) catch {};
    out.print("{s}", .{notListeningDaemonLine(daemon_state)}) catch {};
    out.print("  Suggested fix: {s}\n", .{notListeningSuggestedCommand(daemon_state)}) catch {};
}

fn notListeningDaemonLine(daemon_state: DaemonState) []const u8 {
    return switch (daemon_state) {
        .running => "  zc daemon appears to be running, but this configured proxy port is not listening.\n",
        .stopped => "  zc daemon is stopped.\n",
        .unknown => "  zc daemon state is unknown; run `zc status` for details.\n",
    };
}

fn notListeningSuggestedCommand(daemon_state: DaemonState) []const u8 {
    return switch (daemon_state) {
        .running => "zc status && zc log --no-follow",
        .stopped => "zc start -c <config>",
        .unknown => "zc status",
    };
}

fn isLocalPortListening(allocator: std.mem.Allocator, port: u16) !bool {
    const stream = compat.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch return false;
    stream.close();
    return true;
}

/// 通过代理测试连接：geo 探测 + 并发延迟探测，结果统一进 sink
/// （text 模式同时渲染，JSON 模式只收集 —— 两种模式探测完全一致）。
fn testViaProxy(allocator: std.mem.Allocator, port: u16, proxy_type: ProxyType, sink: *ProbeSink) !TestStats {
    const proxy_url = switch (proxy_type) {
        .http => try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port}),
        .socks5 => try std.fmt.allocPrint(allocator, "socks5://127.0.0.1:{d}", .{port}),
    };
    defer allocator.free(proxy_url);

    const text_mode = sink.out.mode == .text;
    if (text_mode) try sink.out.print("  Current IP/Location: ", .{});
    const ip_geo = try getIpGeoInfo(allocator, proxy_url);
    defer if (ip_geo) |info| {
        allocator.free(info.ip);
        if (info.city) |c| allocator.free(c);
        if (info.region) |r| allocator.free(r);
        if (info.country) |c| allocator.free(c);
        allocator.destroy(info);
    };

    var stats: TestStats = .{};
    stats.attempted += 1;

    if (ip_geo) |info| {
        try sink.record(.{
            .name = TEST_TARGETS[0].name,
            .ok = true,
            .ip = try sink.arena.dupe(u8, info.ip),
        });
        if (text_mode) {
            try sink.out.print("{s}", .{info.ip});
            if (info.city) |city| {
                try sink.out.print(" ({s}", .{city});
                if (info.region) |region| {
                    try sink.out.print(", {s}", .{region});
                }
                if (info.country) |country| {
                    try sink.out.print(", {s}", .{country});
                }
                try sink.out.print(")", .{});
            }
            try sink.out.print("\n", .{});
        }
        stats.succeeded += 1;
    } else {
        try sink.record(.{ .name = TEST_TARGETS[0].name, .ok = false, .reason = "no response" });
        if (text_mode) try sink.out.print("Failed to get IP/Location\n", .{});
    }

    if (text_mode) {
        try sink.out.print("\n  Latency Test:\n", .{});
        try sink.out.print("  {s:-^50}\n", .{""});
    }

    var probe_ctx: u8 = 0;
    stats = mergeStats(stats, try runLatencyTestsInCompletionOrder(
        allocator,
        TEST_TARGETS[1..],
        proxy_url,
        &probe_ctx,
        defaultLatencyProbe,
        sink,
        sinkLatencyResult,
    ));

    return stats;
}

fn mergeStats(a: TestStats, b: TestStats) TestStats {
    return .{
        .attempted = a.attempted + b.attempted,
        .succeeded = a.succeeded + b.succeeded,
    };
}

fn connectivitySucceeded(stats: TestStats) bool {
    return stats.attempted > 0 and stats.succeeded > 0;
}

/// IP 地理信息
const IpGeoInfo = struct {
    ip: []const u8,
    city: ?[]const u8,
    region: ?[]const u8,
    country: ?[]const u8,
};

/// 获取出口 IP 和地理位置信息
fn getIpGeoInfo(allocator: std.mem.Allocator, proxy_url: []const u8) !?*IpGeoInfo {
    // ip-api.com/json 返回 IP + 地理位置
    const output = runCurl(allocator, proxy_url, "http://ip-api.com/json", false, CURL_GEO_MAX_TIME_SECONDS);
    defer switch (output) {
        .ok => |ok| allocator.free(ok),
        .failed => {},
    };

    const body = switch (output) {
        .ok => |ok| ok,
        .failed => return null,
    };

    // ip-api.com 返回: {"query":"1.2.3.4","country":"XX","regionName":"XX","city":"XX",...}
    var info = try allocator.create(IpGeoInfo);
    info.ip = extractJsonField(allocator, body, "query") orelse try allocator.dupe(u8, "unknown");
    info.city = extractJsonField(allocator, body, "city");
    info.region = extractJsonField(allocator, body, "regionName");
    info.country = extractJsonField(allocator, body, "country");

    return info;
}

fn extractJsonField(allocator: std.mem.Allocator, json: []const u8, field: []const u8) ?[]const u8 {
    // 搜索 "field": 或 "field":（兼容有无空格的 JSON）
    const pattern = std.fmt.allocPrint(allocator, "\"{s}\":", .{field}) catch return null;
    defer allocator.free(pattern);

    if (std.mem.indexOf(u8, json, pattern)) |start| {
        var pos = start + pattern.len;
        // 跳过空格
        while (pos < json.len and json[pos] == ' ') pos += 1;
        // 期望引号开始
        if (pos < json.len and json[pos] == '"') {
            pos += 1;
            if (std.mem.indexOfScalar(u8, json[pos..], '"')) |end| {
                return allocator.dupe(u8, json[pos .. pos + end]) catch return null;
            }
        }
    }

    return null;
}

fn runLatencyTestsInCompletionOrder(
    allocator: std.mem.Allocator,
    targets: []const TestTarget,
    proxy_url: []const u8,
    probe_ctx: *anyopaque,
    probe: LatencyProbeFn,
    handler_ctx: *anyopaque,
    handler: LatencyResultHandlerFn,
) !TestStats {
    if (targets.len == 0) return .{};

    const slots = try allocator.alloc(LatencyWorkerSlot, targets.len);
    defer allocator.free(slots);
    for (slots) |*slot| slot.* = .{};

    const threads = try allocator.alloc(std.Thread, targets.len);
    defer allocator.free(threads);

    var completion_counter = std.atomic.Value(usize).init(0);

    var spawned: usize = 0;
    while (spawned < targets.len) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, latencyWorkerMain, .{
            &slots[spawned],
            &completion_counter,
            probe_ctx,
            targets[spawned],
            proxy_url,
            probe,
        }) catch |err| {
            for (threads[0..spawned]) |thread| thread.join();
            return err;
        };
    }

    var stats: TestStats = .{};
    var next_order: usize = 0;
    var first_err: ?anyerror = null;
    while (next_order < spawned) {
        if (findCompletedLatencySlot(slots[0..spawned], next_order)) |slot_index| {
            const slot = &slots[slot_index];
            stats.attempted += 1;
            switch (slot.result) {
                .ok => stats.succeeded += 1,
                .failed => {},
            }
            if (first_err == null) {
                if (slot.err) |err| {
                    first_err = err;
                } else {
                    handler(handler_ctx, targets[slot_index], slot.result) catch |err| {
                        first_err = err;
                    };
                }
            }
            next_order += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }

    for (threads[0..spawned]) |thread| thread.join();

    if (first_err) |err| return err;
    return stats;
}

fn findCompletedLatencySlot(slots: []const LatencyWorkerSlot, order: usize) ?usize {
    for (slots, 0..) |*slot, i| {
        if (slot.order.load(.acquire) == order) return i;
    }
    return null;
}

fn latencyWorkerMain(
    slot: *LatencyWorkerSlot,
    completion_counter: *std.atomic.Value(usize),
    probe_ctx: *anyopaque,
    target: TestTarget,
    proxy_url: []const u8,
    probe: LatencyProbeFn,
) void {
    slot.result = probe(probe_ctx, std.heap.smp_allocator, target.url, proxy_url) catch |err| {
        slot.err = err;
        markLatencyWorkerComplete(slot, completion_counter);
        return;
    };
    markLatencyWorkerComplete(slot, completion_counter);
}

fn markLatencyWorkerComplete(slot: *LatencyWorkerSlot, completion_counter: *std.atomic.Value(usize)) void {
    const order = completion_counter.fetchAdd(1, .acq_rel);
    slot.order.store(order, .release);
}

fn defaultLatencyProbe(_: *anyopaque, allocator: std.mem.Allocator, url: []const u8, proxy_url: []const u8) !LatencyResult {
    return testUrlLatency(allocator, url, proxy_url);
}

/// 完成顺序回调：记录结果，text 模式同时渲染一行。
fn sinkLatencyResult(ctx_ptr: *anyopaque, target: TestTarget, latency: LatencyResult) !void {
    const sink: *ProbeSink = @ptrCast(@alignCast(ctx_ptr));

    switch (latency) {
        .ok => |ms| try sink.record(.{ .name = target.name, .ok = true, .latency_ms = ms }),
        .failed => |reason| try sink.record(.{ .name = target.name, .ok = false, .reason = failureReasonText(reason) }),
    }

    if (sink.out.mode != .text) return;
    try sink.out.print("  {s:12} ", .{target.name});
    switch (latency) {
        .ok => |ms| {
            // 状态标记：emoji 只在启用色彩（TTY 且未禁色）时输出；管道/
            // 重定向场景退回纯 ASCII，避免污染脚本消费（工作项 5 的判断）。
            const marker = if (sink.out.color_out)
                (if (ms < 100) "🟢" else if (ms < 300) "🟡" else "🔴")
            else
                (if (ms < 300) "OK  " else "SLOW");
            try sink.out.print("{s} {d}ms\n", .{ marker, ms });
        },
        .failed => |reason| {
            const marker = if (sink.out.color_out) "⚫" else "FAIL";
            try sink.out.print("{s} {s}\n", .{ marker, failureReasonText(reason) });
        },
    }
}

fn testUrlLatency(allocator: std.mem.Allocator, url: []const u8, proxy_url: []const u8) !LatencyResult {
    const start_time = compat.milliTimestamp();
    const curl_result = runCurl(allocator, proxy_url, url, true, CURL_LATENCY_MAX_TIME_SECONDS);
    const end_time = compat.milliTimestamp();

    return switch (curl_result) {
        .ok => |out| blk: {
            allocator.free(out);
            break :blk .{ .ok = @intCast(end_time - start_time) };
        },
        .failed => |reason| .{ .failed = reason },
    };
}

fn runCurl(allocator: std.mem.Allocator, proxy_url: []const u8, url: []const u8, ignore_body: bool, max_time_seconds: []const u8) CurlResult {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);

    args.appendSlice(allocator, &.{ "curl", "--silent", "--show-error", "--connect-timeout", CURL_CONNECT_TIMEOUT_SECONDS, "--max-time", max_time_seconds, "-x", proxy_url, "-w", "%{http_code}" }) catch {
        return .{ .failed = .unknown };
    };
    if (ignore_body) {
        args.appendSlice(allocator, &.{ "--output", "/dev/null" }) catch {
            return .{ .failed = .unknown };
        };
    }
    args.append(allocator, url) catch {
        return .{ .failed = .unknown };
    };

    const result = compat.childRun(allocator, args.items, 1024 * 1024) catch {
        return .{ .failed = .unknown };
    };
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) {
        // 检查 HTTP 状态码
        const output = result.stdout;
        if (output.len >= 3) {
            const status_code = output[output.len - 3 ..];
            if (std.mem.eql(u8, status_code, "502") or std.mem.eql(u8, status_code, "000")) {
                return .{ .failed = .tcp_connect };
            }
        }
        return .{ .ok = output };
    }

    allocator.free(result.stdout);
    const exit_code: u8 = if (result.term == .exited) result.term.exited else 255;
    return .{ .failed = classifyCurlFailure(exit_code, result.stderr) };
}

fn classifyCurlFailure(exit_code: u8, stderr: []const u8) FailureReason {
    switch (exit_code) {
        6 => return .dns,
        7 => return .tcp_connect,
        28 => return .timeout,
        35, 51, 58, 59, 60 => return .tls_handshake,
        5 => return .dns,
        56, 52 => return .auth_or_proxy_response,
        else => {},
    }

    if (containsAny(stderr, &.{ "Could not resolve host", "Name or service not known", "Could not resolve proxy" })) {
        return .dns;
    }
    if (containsAny(stderr, &.{ "Failed to connect", "Connection refused", "No route to host", "Connection reset" })) {
        return .tcp_connect;
    }
    if (containsAny(stderr, &.{ "SSL", "TLS", "handshake", "certificate" })) {
        return .tls_handshake;
    }
    if (containsAny(stderr, &.{ "407", "Proxy Authentication Required", "Received HTTP code", "Empty reply from server" })) {
        return .auth_or_proxy_response;
    }
    if (containsAny(stderr, &.{ "Operation timed out", "timed out" })) {
        return .timeout;
    }

    return .unknown;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn failureReasonText(reason: FailureReason) []const u8 {
    return switch (reason) {
        .dns => "DNS failure",
        .tcp_connect => "TCP connect failure",
        .tls_handshake => "TLS/handshake failure",
        .auth_or_proxy_response => "Auth/proxy response failure",
        .timeout => "Timeout",
        .unknown => "Unknown failure",
    };
}

test "selectEffectivePorts prefers mixed-port" {
    const allocator = std.testing.allocator;

    var cfg = config.Config{
        .allocator = allocator,
        .port = 7890,
        .socks_port = 7891,
        .mixed_port = 9999,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "127.0.0.1"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    const effective = selectEffectivePorts(&cfg);
    try std.testing.expectEqual(@as(?u16, 9999), effective.mixed);
    try std.testing.expectEqual(@as(?u16, null), effective.http);
    try std.testing.expectEqual(@as(?u16, null), effective.socks);
}

test "classifyCurlFailure core branches" {
    try std.testing.expectEqual(FailureReason.dns, classifyCurlFailure(6, "Could not resolve host"));
    try std.testing.expectEqual(FailureReason.tcp_connect, classifyCurlFailure(7, "Failed to connect"));
    try std.testing.expectEqual(FailureReason.tls_handshake, classifyCurlFailure(35, "SSL connect error"));
    try std.testing.expectEqual(FailureReason.auth_or_proxy_response, classifyCurlFailure(52, "Empty reply from server"));
    try std.testing.expectEqual(FailureReason.timeout, classifyCurlFailure(28, "Operation timed out"));
}

test "failureReasonText returns actionable categories" {
    try std.testing.expectEqualStrings("DNS failure", failureReasonText(.dns));
    try std.testing.expectEqualStrings("TCP connect failure", failureReasonText(.tcp_connect));
    try std.testing.expectEqualStrings("TLS/handshake failure", failureReasonText(.tls_handshake));
}

test "connectivitySucceeded fails when every target fails" {
    try std.testing.expect(!connectivitySucceeded(.{
        .attempted = 2,
        .succeeded = 0,
    }));
    try std.testing.expect(connectivitySucceeded(.{
        .attempted = 2,
        .succeeded = 1,
    }));
}

test "curl probe timeouts separate liveness from latency" {
    try std.testing.expectEqualStrings("5", CURL_CONNECT_TIMEOUT_SECONDS);
    try std.testing.expectEqualStrings("90", CURL_GEO_MAX_TIME_SECONDS);
    try std.testing.expectEqualStrings("5", CURL_LATENCY_MAX_TIME_SECONDS);
}

test "not listening diagnostic reports stopped daemon" {
    try std.testing.expectEqualStrings("  zc daemon is stopped.\n", notListeningDaemonLine(.stopped));
    try std.testing.expectEqualStrings("zc start -c <config>", notListeningSuggestedCommand(.stopped));
}

fn makeNoPortConfig(allocator: std.mem.Allocator) !config.Config {
    return config.Config{
        .allocator = allocator,
        .port = 0,
        .socks_port = 0,
        .mixed_port = 0,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "127.0.0.1"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
}

test "runConnectivityTest json: no configured ports -> CHECKS_FAILED envelope with data" {
    const allocator = std.testing.allocator;
    var cfg = try makeNoPortConfig(allocator);
    defer cfg.deinit();

    var out_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer out_alloc.deinit();
    var err_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer err_alloc.deinit();
    var out = cli_output.Output.init(.json, "test", false, false, &out_alloc.writer, &err_alloc.writer);

    try std.testing.expect(!try runConnectivityTest(allocator, &cfg, null, &out));

    const written = out_alloc.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\n"));
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, written, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(!root.get("ok").?.bool);
    try std.testing.expectEqualStrings("test", root.get("command").?.string);
    try std.testing.expectEqualStrings("CHECKS_FAILED", root.get("error").?.object.get("code").?.string);
    const data = root.get("data").?.object;
    try std.testing.expectEqualStrings("proxy_test", data.get("action").?.string);
    try std.testing.expect(data.get("daemon_state") != null);
    try std.testing.expectEqual(@as(usize, 0), data.get("ports").?.array.items.len);
    const checks = data.get("checks").?.array.items;
    try std.testing.expectEqualStrings("ports", checks[0].object.get("name").?.string);
    try std.testing.expect(!checks[0].object.get("ok").?.bool);
    // text 模式产物绝不能混进 JSON 模式的 stdout/stderr。
    try std.testing.expectEqualStrings("", err_alloc.written());
}

test "runConnectivityTest text: report on stdout, CHECKS_FAILED block on stderr" {
    const allocator = std.testing.allocator;
    var cfg = try makeNoPortConfig(allocator);
    defer cfg.deinit();

    var out_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer out_alloc.deinit();
    var err_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer err_alloc.deinit();
    var out = cli_output.Output.init(.text, "test", false, false, &out_alloc.writer, &err_alloc.writer);

    // 不手动 flush：runConnectivityTest 自己必须保证报告落盘。
    try std.testing.expect(!try runConnectivityTest(allocator, &cfg, null, &out));

    const stdout_text = out_alloc.written();
    try std.testing.expect(std.mem.indexOf(u8, stdout_text, "Network Connectivity Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_text, "Effective ports: none") != null);
    const stderr_text = err_alloc.written();
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "CHECKS_FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "hint:") != null);
}

test "runConnectivityTest json: not-listening port fails port check without external probes" {
    const allocator = std.testing.allocator;

    // 绑定再立刻释放一个临时端口，拿到一个几乎必然无人监听的端口号。
    const addr = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try compat.net.listenReuseAddr(addr);
    const free_port = listener.listen_address.getPort();
    listener.deinit();

    var cfg = try makeNoPortConfig(allocator);
    defer cfg.deinit();
    cfg.mixed_port = free_port;

    var out_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer out_alloc.deinit();
    var err_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer err_alloc.deinit();
    var out = cli_output.Output.init(.json, "proxy test", false, false, &out_alloc.writer, &err_alloc.writer);

    try std.testing.expect(!try runConnectivityTest(allocator, &cfg, null, &out));

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out_alloc.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("CHECKS_FAILED", root.get("error").?.object.get("code").?.string);
    const data = root.get("data").?.object;
    const ports = data.get("ports").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), ports.len);
    try std.testing.expectEqualStrings("mixed", ports[0].object.get("label").?.string);
    try std.testing.expect(!ports[0].object.get("listening").?.bool);
    // 端口都不通时不应跑外网探测：targets 为空。
    try std.testing.expectEqual(@as(usize, 0), data.get("targets").?.array.items.len);
}

test "latency probes print in completion order" {
    const targets = [_]TestTarget{
        .{ .name = "first", .url = "https://first.example" },
        .{ .name = "second", .url = "https://second.example" },
        .{ .name = "third", .url = "https://third.example" },
    };
    var ctx = TestLatencyProbeContext{
        .expected = targets.len,
    };
    var recorder = TestLatencyPrintRecorder{ .probe_ctx = &ctx };

    const stats = try runLatencyTestsInCompletionOrder(
        std.testing.allocator,
        targets[0..],
        "http://127.0.0.1:7890",
        &ctx,
        testConcurrentLatencyProbe,
        &recorder,
        recordLatencyResult,
    );

    try std.testing.expect(ctx.peak.load(.seq_cst) > 1);
    try std.testing.expectEqual(@as(usize, targets.len), stats.attempted);
    try std.testing.expectEqual(@as(usize, targets.len), stats.succeeded);
    try std.testing.expectEqual(@as(usize, targets.len), recorder.count);
    try std.testing.expectEqualStrings("third", recorder.names[0].?);
    try std.testing.expectEqualStrings("second", recorder.names[1].?);
    try std.testing.expectEqualStrings("first", recorder.names[2].?);
}

const TestLatencyProbeContext = struct {
    expected: usize,
    active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    peak: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    release_step: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn testConcurrentLatencyProbe(ctx_ptr: *anyopaque, _: std.mem.Allocator, url: []const u8, _: []const u8) !LatencyResult {
    const ctx: *TestLatencyProbeContext = @ptrCast(@alignCast(ctx_ptr));
    const active = ctx.active.fetchAdd(1, .seq_cst) + 1;
    recordPeak(&ctx.peak, active);
    defer _ = ctx.active.fetchSub(1, .seq_cst);

    var waits: usize = 0;
    while (ctx.active.load(.seq_cst) < ctx.expected and waits < 10000) : (waits += 1) {
        std.Thread.yield() catch {};
    }

    const step: u32 = if (std.mem.eql(u8, url, "https://third.example"))
        0
    else if (std.mem.eql(u8, url, "https://second.example"))
        1
    else if (std.mem.eql(u8, url, "https://first.example"))
        2
    else
        return .{ .failed = .unknown };

    while (ctx.release_step.load(.seq_cst) != step) {
        std.Thread.yield() catch {};
    }

    if (std.mem.eql(u8, url, "https://first.example")) return .{ .ok = 10 };
    if (std.mem.eql(u8, url, "https://second.example")) return .{ .ok = 20 };
    if (std.mem.eql(u8, url, "https://third.example")) return .{ .ok = 30 };
    return .{ .failed = .unknown };
}

const TestLatencyPrintRecorder = struct {
    probe_ctx: *TestLatencyProbeContext,
    names: [3]?[]const u8 = .{ null, null, null },
    count: usize = 0,
};

fn recordLatencyResult(ctx_ptr: *anyopaque, target: TestTarget, latency: LatencyResult) !void {
    const recorder: *TestLatencyPrintRecorder = @ptrCast(@alignCast(ctx_ptr));
    try std.testing.expect(recorder.count < recorder.names.len);
    switch (latency) {
        .ok => {},
        .failed => return error.UnexpectedFailure,
    }
    recorder.names[recorder.count] = target.name;
    recorder.count += 1;
    _ = recorder.probe_ctx.release_step.fetchAdd(1, .seq_cst);
}

fn recordPeak(peak: *std.atomic.Value(u32), value: u32) void {
    var current = peak.load(.seq_cst);
    while (value > current) {
        if (peak.cmpxchgWeak(current, value, .seq_cst, .seq_cst)) |actual| {
            current = actual;
        } else {
            return;
        }
    }
}
