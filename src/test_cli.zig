const std = @import("std");
const config = @import("config.zig");

/// 测试目标网站列表
const TEST_TARGETS = [_]struct {
    name: []const u8,
    url: []const u8,
}{
    .{ .name = "IP/Location", .url = "http://ip-api.com/json" },
    .{ .name = "Google", .url = "http://www.google.com/generate_204" },
    .{ .name = "YouTube", .url = "http://www.youtube.com/generate_204" },
    .{ .name = "Netflix", .url = "http://www.netflix.com" },
    .{ .name = "OpenAI", .url = "http://chat.openai.com" },
    .{ .name = "GitHub", .url = "http://github.com" },
    .{ .name = "Cloudflare", .url = "http://1.1.1.1" },
};

const ProxyType = enum {
    http,
    socks5,
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

/// 网络连接性测试
pub fn testProxyJson(allocator: std.mem.Allocator, cfg: *const config.Config, proxy_name: ?[]const u8) !void {
    _ = proxy_name;
    const effective = selectEffectivePorts(cfg);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"ok\":true,\"data\":{\"action\":\"proxy_test\",\"ports\":[");

    var first = true;
    if (effective.mixed) |p| {
        const listening = try isLocalPortListening(allocator, p);
        try out.writer(allocator).print("{{\"label\":\"mixed\",\"port\":{d},\"listening\":{s}}}", .{ p, if (listening) "true" else "false" });
        first = false;
    }
    if (effective.http) |p| {
        if (!first) try out.appendSlice(allocator, ",");
        const listening = try isLocalPortListening(allocator, p);
        try out.writer(allocator).print("{{\"label\":\"http\",\"port\":{d},\"listening\":{s}}}", .{ p, if (listening) "true" else "false" });
        first = false;
    }
    if (effective.socks) |p| {
        if (!first) try out.appendSlice(allocator, ",");
        const listening = try isLocalPortListening(allocator, p);
        try out.writer(allocator).print("{{\"label\":\"socks\",\"port\":{d},\"listening\":{s}}}", .{ p, if (listening) "true" else "false" });
    }

    try out.appendSlice(allocator, "]}}\n");
    std.debug.print("{s}", .{out.items});
}

pub fn testProxy(allocator: std.mem.Allocator, cfg: *const config.Config, proxy_name: ?[]const u8) !void {
    _ = proxy_name;

    std.debug.print("Network Connectivity Test\n", .{});
    std.debug.print("{s:-^60}\n", .{""});

    const effective = selectEffectivePorts(cfg);
    try printEffectivePortsSummary(effective);

    if (effective.mixed) |mixed_port| {
        std.debug.print("\nTesting via Mixed Proxy (127.0.0.1:{d}):\n", .{mixed_port});
        if (try isLocalPortListening(allocator, mixed_port)) {
            try testViaProxy(allocator, mixed_port, .http);
        } else {
            printPortNotListeningHint(mixed_port);
        }
        std.debug.print("\n", .{});
        return;
    }

    if (effective.http) |http_port| {
        std.debug.print("\nTesting via HTTP Proxy (127.0.0.1:{d}):\n", .{http_port});
        if (try isLocalPortListening(allocator, http_port)) {
            try testViaProxy(allocator, http_port, .http);
        } else {
            printPortNotListeningHint(http_port);
        }
    }

    if (effective.socks) |socks_port| {
        std.debug.print("\nTesting via SOCKS5 Proxy (127.0.0.1:{d}):\n", .{socks_port});
        if (try isLocalPortListening(allocator, socks_port)) {
            try testViaProxy(allocator, socks_port, .socks5);
        } else {
            printPortNotListeningHint(socks_port);
        }
    }

    std.debug.print("\n", .{});
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

fn printPortNotListeningHint(port: u16) void {
    std.debug.print("  Proxy not listening on 127.0.0.1:{d}.\n", .{port});
    std.debug.print("  Suggested fix: {s}\n", .{notListeningSuggestedCommand()});
}

fn notListeningSuggestedCommand() []const u8 {
    return "zc start -c <config>";
}

fn isLocalPortListening(allocator: std.mem.Allocator, port: u16) !bool {
    const stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch return false;
    stream.close();
    return true;
}

/// 通过代理测试连接
fn testViaProxy(allocator: std.mem.Allocator, port: u16, proxy_type: ProxyType) !void {
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
    } else {
        std.debug.print("Failed to get IP/Location\n", .{});
    }

    std.debug.print("\n  Latency Test:\n", .{});
    std.debug.print("  {s:-^50}\n", .{""});

    for (TEST_TARGETS[1..]) |target| {
        std.debug.print("  {s:12} ", .{target.name});

        const latency = try testUrlLatency(allocator, target.url, proxy_url);

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
    const output = runCurl(allocator, proxy_url, "http://ip-api.com/json", false);
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

fn testUrlLatency(allocator: std.mem.Allocator, url: []const u8, proxy_url: []const u8) !union(enum) {
    ok: u64,
    failed: FailureReason,
} {
    const start_time = std.time.milliTimestamp();
    const curl_result = runCurl(allocator, proxy_url, url, true);
    const end_time = std.time.milliTimestamp();

    return switch (curl_result) {
        .ok => |out| blk: {
            allocator.free(out);
            break :blk .{ .ok = @intCast(end_time - start_time) };
        },
        .failed => |reason| .{ .failed = reason },
    };
}

fn runCurl(allocator: std.mem.Allocator, proxy_url: []const u8, url: []const u8, ignore_body: bool) CurlResult {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);

    args.appendSlice(allocator, &.{ "curl", "--silent", "--show-error", "--max-time", "6", "-x", proxy_url, "-w", "%{http_code}" }) catch {
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

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
    }) catch {
        return .{ .failed = .unknown };
    };
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) {
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
    const exit_code: u8 = if (result.term == .Exited) result.term.Exited else 255;
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

test "not listening hint includes executable command" {
    try std.testing.expectEqualStrings("zc start -c <config>", notListeningSuggestedCommand());
}
