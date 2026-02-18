const std = @import("std");
const testing = std.testing;
const Config = @import("config.zig").Config;
const Proxy = @import("config.zig").Proxy;
const ProxyType = @import("config.zig").ProxyType;
const Rule = @import("config.zig").Rule;
const RuleType = @import("config.zig").RuleType;
const fetchConfig = @import("config.zig").fetchConfig;
const DownloadResult = @import("config.zig").DownloadResult;

// Verify DownloadResult struct exists and has correct fields
test "DownloadResult struct exists with correct fields" {
    const result = DownloadResult{
        .status = std.http.Status.ok,
        .body = "test",
    };
    try testing.expectEqual(std.http.Status.ok, result.status);
    try testing.expectEqualStrings("test", result.body);
}

// Test: fetchConfig function exists and is exported
test "fetchConfig function is exported" {
    // Just verify the function signature is accessible by calling it
    // This ensures the symbol exists at compile time
    _ = fetchConfig;
}

// Original tests from before

test "ProxyType enum variants" {
    const types = [_]ProxyType{
        .direct, .reject, .http, .socks5, .ss, .vmess, .trojan,
    };
    
    try testing.expectEqual(@as(usize, 7), types.len);
}

test "RuleType enum variants" {
    const types = [_]RuleType{
        .domain, .domain_suffix, .domain_keyword, .ip_cidr,
        .ip_cidr6, .geoip, .src_ip_cidr, .dst_port,
        .src_port, .process_name, .final,
    };
    
    try testing.expectEqual(@as(usize, 11), types.len);
}

test "Proxy struct default values" {
    const allocator = testing.allocator;
    
    var proxy = Proxy{
        .name = try allocator.dupe(u8, "TestProxy"),
        .proxy_type = .ss,
        .server = try allocator.dupe(u8, "127.0.0.1"),
        .port = 8388,
    };
    defer proxy.deinit(allocator);
    
    try testing.expectEqualStrings("TestProxy", proxy.name);
    try testing.expectEqualStrings("127.0.0.1", proxy.server);
    try testing.expectEqual(@as(u16, 8388), proxy.port);
    try testing.expectEqual(@as(?[]const u8, null), proxy.password);
    try testing.expectEqual(@as(u16, 0), proxy.alter_id);
    try testing.expect(!proxy.tls);
}

test "Proxy with all fields" {
    const allocator = testing.allocator;
    
    var proxy = Proxy{
        .name = try allocator.dupe(u8, "FullProxy"),
        .proxy_type = .vmess,
        .server = try allocator.dupe(u8, "vmess.example.com"),
        .port = 443,
        .password = try allocator.dupe(u8, "password"),
        .uuid = try allocator.dupe(u8, "uuid-uuid-uuid"),
        .alter_id = 0,
        .tls = true,
        .sni = try allocator.dupe(u8, "sni.example.com"),
        .ws = true,
        .ws_path = try allocator.dupe(u8, "/ws"),
    };
    defer proxy.deinit(allocator);
    
    try testing.expect(proxy.tls);
    try testing.expect(proxy.ws);
    try testing.expectEqualStrings("/ws", proxy.ws_path.?);
}

test "Rule struct" {
    const allocator = testing.allocator;
    
    var rule = Rule{
        .rule_type = .domain_suffix,
        .payload = try allocator.dupe(u8, "google.com"),
        .target = try allocator.dupe(u8, "PROXY"),
        .no_resolve = false,
    };
    defer rule.deinit(allocator);
    
    try testing.expectEqual(RuleType.domain_suffix, rule.rule_type);
    try testing.expectEqualStrings("google.com", rule.payload);
    try testing.expectEqualStrings("PROXY", rule.target);
    try testing.expect(!rule.no_resolve);
}

test "Rule with no_resolve" {
    const allocator = testing.allocator;
    
    var rule = Rule{
        .rule_type = .ip_cidr,
        .payload = try allocator.dupe(u8, "192.168.0.0/16"),
        .target = try allocator.dupe(u8, "DIRECT"),
        .no_resolve = true,
    };
    defer rule.deinit(allocator);
    
    try testing.expect(rule.no_resolve);
}

test "Config defaults" {
    const allocator = testing.allocator;
    
    var config = Config{
        .allocator = allocator,
        .port = 7890,
        .socks_port = 7891,
        .mixed_port = 0,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "127.0.0.1"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(@import("config.zig").ProxyGroup).empty,
        .rules = std.ArrayList(Rule).empty,
    };
    defer config.deinit();
    
    try testing.expectEqual(@as(u16, 7890), config.port);
    try testing.expectEqual(@as(u16, 7891), config.socks_port);
    try testing.expectEqualStrings("rule", config.mode);
    try testing.expectEqualStrings("info", config.log_level);
}

test "Config with external controller" {
    const allocator = testing.allocator;
    
    var config = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "127.0.0.1"),
        .external_controller = try allocator.dupe(u8, "127.0.0.1:9090"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(@import("config.zig").ProxyGroup).empty,
        .rules = std.ArrayList(Rule).empty,
    };
    defer config.deinit();
    
    try testing.expectEqualStrings("127.0.0.1:9090", config.external_controller.?);
}
