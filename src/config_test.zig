const std = @import("std");
const testing = std.testing;
const Config = @import("config.zig").Config;
const Proxy = @import("config.zig").Proxy;
const ProxyType = @import("config.zig").ProxyType;
const Rule = @import("config.zig").Rule;
const RuleType = @import("config.zig").RuleType;
const parseConfig = @import("config.zig").parse;
const parseConfigDocument = @import("config.zig").parseDocument;
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
        .direct, .reject, .http, .socks5, .ss, .vmess, .trojan, .vless, .anytls,
    };

    try testing.expectEqual(@as(usize, 9), types.len);
}

test "RuleType enum variants" {
    const types = [_]RuleType{
        .domain,   .domain_suffix, .domain_keyword, .ip_cidr,
        .ip_cidr6, .geoip,         .rule_set,       .src_ip_cidr,
        .dst_port, .src_port,      .process_name,   .final,
    };

    try testing.expectEqual(@as(usize, 12), types.len);
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

test "parse AnyTLS proxy" {
    const allocator = testing.allocator;
    const yaml =
        \\proxies:
        \\  - name: anytls-main
        \\    type: anytls
        \\    server: anytls.example.com
        \\    port: 443
        \\    password: "secret"
        \\    sni: edge.example.com
        \\    skip-cert-verify: true
        \\rules:
        \\  - MATCH,anytls-main
    ;

    var config = try parseConfig(allocator, yaml);
    defer config.deinit();

    try testing.expectEqual(@as(usize, 1), config.proxies.items.len);
    const proxy = config.proxies.items[0];
    try testing.expectEqual(ProxyType.anytls, proxy.proxy_type);
    try testing.expectEqualStrings("anytls-main", proxy.name);
    try testing.expectEqualStrings("anytls.example.com", proxy.server);
    try testing.expectEqual(@as(u16, 443), proxy.port);
    try testing.expectEqualStrings("secret", proxy.password.?);
    try testing.expectEqualStrings("edge.example.com", proxy.sni.?);
    try testing.expect(proxy.skip_cert_verify);
}

test "D4: proxy udp flag parses true, absent defaults false" {
    const allocator = testing.allocator;
    const yaml =
        \\proxies:
        \\  - name: anytls-udp
        \\    type: anytls
        \\    server: anytls.example.com
        \\    port: 443
        \\    password: "secret"
        \\    udp: true
        \\  - name: anytls-noudp
        \\    type: anytls
        \\    server: anytls.example.com
        \\    port: 443
        \\    password: "secret"
        \\rules:
        \\  - MATCH,anytls-udp
    ;

    var config = try parseConfig(allocator, yaml);
    defer config.deinit();

    try testing.expectEqual(@as(usize, 2), config.proxies.items.len);
    try testing.expect(config.proxies.items[0].udp);
    try testing.expect(!config.proxies.items[1].udp); // absent -> false
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

// Regression: parseProxy must reject out-of-range proxy port instead of
// panicking on an unchecked @intCast of the i64 YAML value to u16.
test "parseProxy rejects out-of-range port" {
    const allocator = testing.allocator;
    const yaml =
        \\proxies:
        \\  - name: bad
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 70000
        \\    cipher: aes-128-gcm
        \\    password: pw
    ;
    try testing.expectError(error.InvalidProxyPort, parseConfig(allocator, yaml));
}

test "parseProxy rejects negative port" {
    const allocator = testing.allocator;
    const yaml =
        \\proxies:
        \\  - name: bad
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: -1
        \\    cipher: aes-128-gcm
        \\    password: pw
    ;
    try testing.expectError(error.InvalidProxyPort, parseConfig(allocator, yaml));
}

// Regression: alterId beyond u16 must be rejected, not @intCast-truncated/panicked.
test "managed config document accepts explicit null provider URL" {
    const allocator = testing.allocator;
    const source =
        \\rule-providers:
        \\  local:
        \\    type: http
        \\    behavior: domain
        \\    path: rules.yaml
        \\    url: null
    ;

    var config = try parseConfigDocument(allocator, source);
    defer config.deinit();

    try testing.expectEqual(@as(usize, 1), config.rule_providers.items.len);
    try testing.expect(config.rule_providers.items[0].url == null);
}

test "managed config document rejects duplicate keys" {
    const allocator = testing.allocator;
    try testing.expectError(error.DuplicateKey, parseConfigDocument(allocator,
        \\port: 7890
        \\port: 7891
    ));
}

test "managed config document rejects known fields with invalid shapes" {
    const allocator = testing.allocator;
    const invalid_documents = [_][]const u8{
        "mixed-port: nope\n",
        "mixed-port: 70000\n",
        "allow-lan: yes\n",
        "ipv6: definitely-not-a-bool\n",
        "redir-port: nope\n",
        "tproxy-port: 70000\n",
        "external-ui: 42\n",
        "secret: false\n",
        "rules: definitely-not-a-list\n",
        "rules:\n  - 42\n",
        "proxies: definitely-not-a-list\n",
        "proxies:\n  - definitely-not-a-map\n",
        "proxy-groups: definitely-not-a-list\n",
        "rule-providers: definitely-not-a-map\n",
        "min-idle-session: -1\n",
    };
    for (invalid_documents) |document| {
        try testing.expectError(error.InvalidConfig, parseConfigDocument(allocator, document));
    }
    const invalid_providers = [_][]const u8{
        "rule-providers:\n  p:\n    type: ftp\n    behavior: domain\n    path: rules.yaml\n",
        "rule-providers:\n  p:\n    type: file\n    behavior: domain\n    path: \"\"\n",
        "rule-providers:\n  p:\n    type: http\n    behavior: domain\n    path: rules.yaml\n    url: ftp://example.test/rules\n",
        "rule-providers:\n  p:\n    type: http\n    behavior: domain\n    path: rules.yaml\n    url: http:///missing-host\n",
    };
    for (invalid_providers) |document| {
        try testing.expectError(error.InvalidRuleProviderFormat, parseConfigDocument(allocator, document));
    }

    var config = try parseConfigDocument(allocator,
        \\mixed-port: 7890
        \\redir-port: 7892
        \\tproxy-port: 7893
        \\ipv6: false
        \\external-ui: ui
        \\secret: token
        \\unknown-extension: accepted
    );
    defer config.deinit();
    try testing.expectEqual(@as(u16, 7890), config.mixed_port);
    try testing.expectEqual(@as(u16, 7892), config.redir_port);
    try testing.expectEqual(@as(u16, 7893), config.tproxy_port);
    try testing.expect(!config.ipv6);
    try testing.expectEqualStrings("ui", config.external_ui.?);
    try testing.expectEqualStrings("token", config.secret.?);
}

test "legacy parsing keeps controller authentication while ignoring managed-only fields" {
    const allocator = testing.allocator;
    var config = try parseConfig(allocator,
        \\redir-port: 7892
        \\tproxy-port: 7893
        \\ipv6: false
        \\external-ui: ui
        \\secret: token
    );
    defer config.deinit();

    try testing.expectEqual(@as(u16, 0), config.redir_port);
    try testing.expectEqual(@as(u16, 0), config.tproxy_port);
    try testing.expect(config.ipv6);
    try testing.expect(config.external_ui == null);
    try testing.expectEqualStrings("token", config.secret.?);
}

fn parseManagedAllocationFixture(allocator: std.mem.Allocator) !void {
    var config = try parseConfigDocument(allocator,
        \\mixed-port: 7890
        \\bind-address: 127.0.0.1
        \\mode: rule
        \\log-level: debug
        \\external-ui: ui
        \\secret: token
        \\proxies:
        \\  - name: proxy
        \\    type: ss
        \\    server: example.test
        \\    port: 443
        \\    cipher: aes-128-gcm
        \\    password: password
        \\proxy-groups:
        \\  - name: group
        \\    type: select
        \\    proxies: [proxy]
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.yaml
        \\rules:
        \\  - MATCH,group
    );
    config.deinit();
}

test "managed config parser releases every allocation failure path" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        parseManagedAllocationFixture,
        .{},
    );
}

test "parseProxy rejects out-of-range alterId" {
    const allocator = testing.allocator;
    const yaml =
        \\proxies:
        \\  - name: bad
        \\    type: vmess
        \\    server: 127.0.0.1
        \\    port: 443
        \\    uuid: 00000000-0000-0000-0000-000000000000
        \\    alterId: 70000
    ;
    try testing.expectError(error.InvalidAlterId, parseConfig(allocator, yaml));
}

// Regression: proxy-group interval beyond u32 must be rejected.
test "parseProxyGroup rejects out-of-range interval" {
    const allocator = testing.allocator;
    const yaml =
        \\proxies:
        \\  - name: a
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: pw
        \\proxy-groups:
        \\  - name: g
        \\    type: url-test
        \\    proxies:
        \\      - a
        \\    interval: 99999999999
    ;
    try testing.expectError(error.InvalidGroupInterval, parseConfig(allocator, yaml));
}

// Regression: proxy-group tolerance beyond u16 must be rejected.
test "parseProxyGroup rejects out-of-range tolerance" {
    const allocator = testing.allocator;
    const yaml =
        \\proxies:
        \\  - name: a
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: pw
        \\proxy-groups:
        \\  - name: g
        \\    type: url-test
        \\    proxies:
        \\      - a
        \\    tolerance: 70000
    ;
    try testing.expectError(error.InvalidGroupTolerance, parseConfig(allocator, yaml));
}
