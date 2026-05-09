const std = @import("std");
const compat = @import("compat.zig");
const config = @import("config.zig");
const daemon = @import("daemon.zig");
const runtime_selection = @import("runtime_selection.zig");

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

/// 网络连接性测试
pub fn testProxyJson(allocator: std.mem.Allocator, cfg: *const config.Config, proxy_name: ?[]const u8, config_key: ?[]const u8) !void {
    _ = proxy_name;
    const effective = selectEffectivePorts(cfg);
    const daemon_state = detectDaemonState(allocator);
    const selected_proxies = try runtime_selection.collectSelectedProxies(allocator, cfg, config_key);
    defer runtime_selection.deinitSelectedProxies(allocator, selected_proxies);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"ok\":true,\"data\":{\"action\":\"proxy_test\",\"daemon_state\":\"");
    try out.appendSlice(allocator, daemonStateText(daemon_state));
    try out.appendSlice(allocator, "\",\"selected_proxies\":");
    try runtime_selection.appendSelectedProxiesJson(&out, allocator, selected_proxies);
    try out.appendSlice(allocator, ",\"ports\":[");

    var first = true;
    if (effective.mixed) |p| {
        const listening = try isLocalPortListening(allocator, p);
        try out.print(allocator, "{{\"label\":\"mixed\",\"port\":{d},\"listening\":{s}}}", .{ p, if (listening) "true" else "false" });
        first = false;
    }
    if (effective.http) |p| {
        if (!first) try out.appendSlice(allocator, ",");
        const listening = try isLocalPortListening(allocator, p);
        try out.print(allocator, "{{\"label\":\"http\",\"port\":{d},\"listening\":{s}}}", .{ p, if (listening) "true" else "false" });
        first = false;
    }
    if (effective.socks) |p| {
        if (!first) try out.appendSlice(allocator, ",");
        const listening = try isLocalPortListening(allocator, p);
        try out.print(allocator, "{{\"label\":\"socks\",\"port\":{d},\"listening\":{s}}}", .{ p, if (listening) "true" else "false" });
    }

    try out.appendSlice(allocator, "]}}\n");
    try compat.writeStdoutAll(out.items);
}

pub fn testProxy(allocator: std.mem.Allocator, cfg: *const config.Config, proxy_name: ?[]const u8, config_key: ?[]const u8) !void {
    _ = proxy_name;
    const selected_proxies = try runtime_selection.collectSelectedProxies(allocator, cfg, config_key);
    defer runtime_selection.deinitSelectedProxies(allocator, selected_proxies);

    std.debug.print("Network Connectivity Test\n", .{});
    std.debug.print("{s:-^60}\n", .{""});

    const effective = selectEffectivePorts(cfg);
    const daemon_state = detectDaemonState(allocator);
    try printEffectivePortsSummary(effective);
    runtime_selection.printSelectedProxiesText(allocator, selected_proxies);
    var totals: TestStats = .{};

    if (effective.mixed) |mixed_port| {
        std.debug.print("\nTesting via Mixed Proxy (127.0.0.1:{d}):\n", .{mixed_port});
        if (try isLocalPortListening(allocator, mixed_port)) {
            totals = mergeStats(totals, try testViaProxy(allocator, mixed_port, .http));
        } else {
            printPortNotListeningHint(mixed_port, daemon_state);
            return error.ProxyTestFailed;
        }
        std.debug.print("\n", .{});
        try ensureConnectivitySucceeded(totals);
        return;
    }

    if (effective.http) |http_port| {
        std.debug.print("\nTesting via HTTP Proxy (127.0.0.1:{d}):\n", .{http_port});
        if (try isLocalPortListening(allocator, http_port)) {
            totals = mergeStats(totals, try testViaProxy(allocator, http_port, .http));
        } else {
            printPortNotListeningHint(http_port, daemon_state);
        }
    }

    if (effective.socks) |socks_port| {
        std.debug.print("\nTesting via SOCKS5 Proxy (127.0.0.1:{d}):\n", .{socks_port});
        if (try isLocalPortListening(allocator, socks_port)) {
            totals = mergeStats(totals, try testViaProxy(allocator, socks_port, .socks5));
        } else {
            printPortNotListeningHint(socks_port, daemon_state);
        }
    }

    std.debug.print("\n", .{});
    try ensureConnectivitySucceeded(totals);
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

fn printEffectivePortsSummary(effective: EffectivePorts) !void {
    std.debug.print("Effective ports: ", .{});
    if (effective.mixed) |p| {
        std.debug.print("mixed=127.0.0.1:{d}\n", .{p});
        return;
    }

    var printed = false;
    if (effective.http) |p| {
        std.debug.print("http=127.0.0.1:{d}", .{p});
        printed = true;
    }
    if (effective.socks) |p| {
        if (printed) std.debug.print(", ", .{});
        std.debug.print("socks=127.0.0.1:{d}", .{p});
        printed = true;
    }
    if (!printed) {
        std.debug.print("none\n", .{});
    } else {
        std.debug.print("\n", .{});
    }
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

fn printPortNotListeningHint(port: u16, daemon_state: DaemonState) void {
    std.debug.print("  Proxy not listening on 127.0.0.1:{d}.\n", .{port});
    std.debug.print("{s}", .{notListeningDaemonLine(daemon_state)});
    std.debug.print("  Suggested fix: {s}\n", .{notListeningSuggestedCommand(daemon_state)});
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

/// 通过代理测试连接
fn testViaProxy(allocator: std.mem.Allocator, port: u16, proxy_type: ProxyType) !TestStats {
    const proxy_url = switch (proxy_type) {
        .http => try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port}),
        .socks5 => try std.fmt.allocPrint(allocator, "socks5://127.0.0.1:{d}", .{port}),
    };
    defer allocator.free(proxy_url);

    std.debug.print("  Current IP/Location: ", .{});
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
        std.debug.print("{s}", .{info.ip});
        if (info.city) |city| {
            std.debug.print(" ({s}", .{city});
            if (info.region) |region| {
                std.debug.print(", {s}", .{region});
            }
            if (info.country) |country| {
                std.debug.print(", {s}", .{country});
            }
            std.debug.print(")", .{});
        }
        std.debug.print("\n", .{});
        stats.succeeded += 1;
    } else {
        std.debug.print("Failed to get IP/Location\n", .{});
    }

    std.debug.print("\n  Latency Test:\n", .{});
    std.debug.print("  {s:-^50}\n", .{""});

    var probe_ctx: u8 = 0;
    var print_ctx: u8 = 0;
    stats = mergeStats(stats, try runLatencyTestsInCompletionOrder(
        allocator,
        TEST_TARGETS[1..],
        proxy_url,
        &probe_ctx,
        defaultLatencyProbe,
        &print_ctx,
        printLatencyResult,
    ));

    return stats;
}

fn mergeStats(a: TestStats, b: TestStats) TestStats {
    return .{
        .attempted = a.attempted + b.attempted,
        .succeeded = a.succeeded + b.succeeded,
    };
}

fn ensureConnectivitySucceeded(stats: TestStats) !void {
    if (!connectivitySucceeded(stats)) {
        std.debug.print("  No connectivity target succeeded; check selected proxy, route rules, or upstream availability.\n", .{});
        return error.ProxyTestFailed;
    }
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

fn printLatencyResult(_: *anyopaque, target: TestTarget, latency: LatencyResult) !void {
    std.debug.print("  {s:12} ", .{target.name});

    switch (latency) {
        .ok => |ms| {
            const color = if (ms < 100) "🟢" else if (ms < 300) "🟡" else "🔴";
            std.debug.print("{s} {d}ms\n", .{ color, ms });
        },
        .failed => |reason| {
            std.debug.print("⚫ {s}\n", .{failureReasonText(reason)});
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
