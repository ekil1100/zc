const std = @import("std");
const testing = std.testing;
const compat = @import("compat.zig");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Proxy = @import("config.zig").Proxy;
const ProxyType = @import("config.zig").ProxyType;
const Rule = @import("config.zig").Rule;
const RuleType = @import("config.zig").RuleType;
const parseConfig = config_mod.parse;
const parseConfigDocument = config_mod.parseDocument;
const parseCatalogConfigDocument = config_mod.parseCatalogDocument;
const fetchConfig = config_mod.fetchConfig;
const loadConfig = config_mod.load;
const loadConfigDocument = config_mod.loadDocument;
const loadBuiltinDefault = config_mod.loadBuiltinDefault;
const DownloadResult = config_mod.DownloadResult;
const validateConfig = @import("config_validator.zig").validate;
const OutboundManager = @import("proxy/outbound/manager.zig").OutboundManager;

// Verify DownloadResult struct exists and has correct fields
test "DownloadResult struct exists with correct fields" {
    const result = DownloadResult{
        .status = std.http.Status.ok,
        .body = "test",
        .total_source_bytes_consumed = 4,
    };
    try testing.expectEqual(std.http.Status.ok, result.status);
    try testing.expectEqualStrings("test", result.body);
    try testing.expectEqual(@as(usize, 4), result.total_source_bytes_consumed);
}

// Test: fetchConfig function exists and is exported
test "fetchConfig function is exported" {
    // Just verify the function signature is accessible by calling it
    // This ensures the symbol exists at compile time
    _ = fetchConfig;
}

// Original tests from before

test "built-in fallback is a valid manager configuration without user proxies" {
    const allocator = testing.allocator;
    var config = try loadBuiltinDefault(allocator);
    defer config.deinit();

    try testing.expectEqual(@as(usize, 0), config.proxies.items.len);
    var validation = try validateConfig(allocator, &config);
    defer validation.deinit();
    try testing.expect(validation.isValid());

    const manager = try OutboundManager.init(allocator, &config);
    manager.deinit();
}

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

const ConfigParser = *const fn (std.mem.Allocator, []const u8) anyerror!Config;

const config_resource_parsers = [_]ConfigParser{
    parseConfig,
    parseConfigDocument,
    parseCatalogConfigDocument,
};

fn appendRepeatedConfigEntry(
    allocator: std.mem.Allocator,
    document: *std.ArrayList(u8),
    entry: []const u8,
    count: usize,
) !void {
    for (0..count) |_| try document.appendSlice(allocator, entry);
}

fn makeMixedProxyResourceDocument(
    allocator: std.mem.Allocator,
    proxy_count: usize,
    group_count: usize,
) ![]u8 {
    var document = std.ArrayList(u8).empty;
    errdefer document.deinit(allocator);
    try document.appendSlice(allocator, "proxies:\n");
    try appendRepeatedConfigEntry(
        allocator,
        &document,
        "  - { name: node, type: direct }\n",
        proxy_count,
    );
    try appendRepeatedConfigEntry(
        allocator,
        &document,
        "  - { name: group, type: select, proxies: [DIRECT] }\n",
        group_count,
    );
    return document.toOwnedSlice(allocator);
}

fn makeDedicatedGroupResourceDocument(
    allocator: std.mem.Allocator,
    group_count: usize,
) ![]u8 {
    var document = std.ArrayList(u8).empty;
    errdefer document.deinit(allocator);
    try document.appendSlice(allocator, "proxy-groups:\n");
    try appendRepeatedConfigEntry(
        allocator,
        &document,
        "  - { name: group, type: select, proxies: [DIRECT] }\n",
        group_count,
    );
    return document.toOwnedSlice(allocator);
}

fn makeSubscriptionBannerResourceDocument(
    allocator: std.mem.Allocator,
    entry_count: usize,
) ![]u8 {
    var document = std.ArrayList(u8).empty;
    errdefer document.deinit(allocator);
    try document.appendSlice(allocator, "proxies:\n");
    try appendRepeatedConfigEntry(
        allocator,
        &document,
        "  - { name: \"Traffic: quota\", type: direct }\n",
        entry_count,
    );
    return document.toOwnedSlice(allocator);
}

fn makeGroupMemberResourceDocument(
    allocator: std.mem.Allocator,
    member_count: usize,
) ![]u8 {
    var document = std.ArrayList(u8).empty;
    errdefer document.deinit(allocator);
    try document.appendSlice(
        allocator,
        "proxy-groups:\n  - name: bounded\n    type: select\n" ++
            "    proxies:\n",
    );
    try appendRepeatedConfigEntry(
        allocator,
        &document,
        "      - DIRECT\n",
        member_count,
    );
    return document.toOwnedSlice(allocator);
}

fn expectConfigParserError(expected: anyerror, result: anyerror!Config) !void {
    if (result) |value| {
        var config = value;
        config.deinit();
        return error.TestExpectedError;
    } else |actual| {
        try testing.expectEqual(expected, actual);
    }
}

test "config resource limits accept documented maxima in every parser" {
    const allocator = testing.allocator;
    const document = try makeMixedProxyResourceDocument(allocator, 4096, 1024);
    defer allocator.free(document);

    for (config_resource_parsers) |parser| {
        var config = try parser(allocator, document);
        defer config.deinit();
        try testing.expectEqual(@as(usize, 4096), config.proxies.items.len);
        try testing.expectEqual(@as(usize, 1024), config.proxy_groups.items.len);
    }
}

test "config resource limits reject documented maxima plus one in every parser" {
    const allocator = testing.allocator;
    const proxy_overflow = try makeMixedProxyResourceDocument(allocator, 4097, 0);
    defer allocator.free(proxy_overflow);
    const group_overflow = try makeDedicatedGroupResourceDocument(allocator, 1025);
    defer allocator.free(group_overflow);
    const mixed_entry_overflow = try makeSubscriptionBannerResourceDocument(allocator, 5121);
    defer allocator.free(mixed_entry_overflow);

    for (config_resource_parsers) |parser| {
        try expectConfigParserError(
            error.ProxyCountLimitExceeded,
            parser(allocator, proxy_overflow),
        );
        try expectConfigParserError(
            error.ProxyGroupCountLimitExceeded,
            parser(allocator, group_overflow),
        );
        try expectConfigParserError(
            error.ProxyEntryCountLimitExceeded,
            parser(allocator, mixed_entry_overflow),
        );
    }
}

test "proxy group member limit accepts max and rejects max plus one in every parser" {
    const allocator = testing.allocator;
    const maximum = try makeGroupMemberResourceDocument(
        allocator,
        config_mod.proxy_group_member_count_max,
    );
    defer allocator.free(maximum);
    const overflow = try makeGroupMemberResourceDocument(
        allocator,
        config_mod.proxy_group_member_count_max + 1,
    );
    defer allocator.free(overflow);

    for (config_resource_parsers) |parser| {
        var parsed = try parser(allocator, maximum);
        defer parsed.deinit();
        try testing.expectEqual(
            config_mod.proxy_group_member_count_max,
            parsed.proxy_groups.items[0].proxies.items.len,
        );
        try expectConfigParserError(
            error.ProxyGroupMemberCountLimitExceeded,
            parser(allocator, overflow),
        );
    }
}

test "public config parser bounds compact unknown YAML arrays before OOM" {
    const allocator = testing.allocator;
    try testing.expectEqual(
        @as(usize, 262_144),
        config_mod.yaml_collection_entry_count_max,
    );

    var source = std.ArrayList(u8).empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "unknown: [");
    for (0..config_mod.yaml_collection_entry_count_max) |index| {
        if (index != 0) try source.append(allocator, ',');
        try source.append(allocator, '0');
    }
    try source.appendSlice(allocator, "]\n");
    try testing.expect(source.items.len < 1024 * 1024);

    const parse_memory_ceiling = 18 * 1024 * 1024;
    const parse_memory = try allocator.alloc(u8, parse_memory_ceiling);
    defer allocator.free(parse_memory);
    var fixed = std.heap.FixedBufferAllocator.init(parse_memory);
    try testing.expectError(
        error.YamlCollectionEntryLimitExceeded,
        parseConfigDocument(fixed.allocator(), source.items),
    );
}

const ConfigFileLoader = *const fn (
    std.mem.Allocator,
    []const u8,
) anyerror!Config;

const config_file_loaders = [_]ConfigFileLoader{
    loadConfig,
    loadConfigDocument,
};

fn writePaddedConfigFile(
    directory: std.Io.Dir,
    name: []const u8,
    size: usize,
    tail: []const u8,
) !void {
    try testing.expect(size >= tail.len);
    const file = try directory.createFile(compat.io(), name, .{});
    defer file.close(compat.io());

    var comment: [4096]u8 = @splat('x');
    comment[0] = '#';
    comment[comment.len - 1] = '\n';
    var padding_bytes_remaining = size - tail.len;
    while (padding_bytes_remaining > 0) {
        const write_size = @min(comment.len, padding_bytes_remaining);
        if (write_size == 1) {
            try compat.fileWriteAll(file, "\n");
        } else {
            comment[write_size - 1] = '\n';
            try compat.fileWriteAll(file, comment[0..write_size]);
            comment[write_size - 1] = 'x';
        }
        padding_bytes_remaining -= write_size;
    }
    try compat.fileWriteAll(file, tail);
}

fn expectConfigFileLoaderError(
    expected: anyerror,
    loader: ConfigFileLoader,
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    if (loader(allocator, path)) |value| {
        var config = value;
        config.deinit();
        return error.TestExpectedError;
    } else |actual| {
        try testing.expectEqual(expected, actual);
    }
}

test "file loaders retain observable config after the first MiB" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const size = 1024 * 1024 + 4096;
    try writePaddedConfigFile(
        tmp.dir,
        "large-valid.yaml",
        size,
        "mixed-port: 4321\n",
    );
    const path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "large-valid.yaml",
        allocator,
    );
    defer allocator.free(path);

    for (config_file_loaders) |loader| {
        var loaded = try loader(allocator, path);
        defer loaded.deinit();
        try testing.expectEqual(@as(u16, 4321), loaded.mixed_port);
    }
}

test "file loaders accept exactly the public config source bound" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePaddedConfigFile(
        tmp.dir,
        "exact.yaml",
        config_mod.config_source_bytes_max,
        "mixed-port: 4322\n",
    );
    const path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "exact.yaml",
        allocator,
    );
    defer allocator.free(path);

    for (config_file_loaders) |loader| {
        var loaded = try loader(allocator, path);
        defer loaded.deinit();
        try testing.expectEqual(@as(u16, 4322), loaded.mixed_port);
    }
}

test "file loaders reject one byte beyond the public config source bound" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(compat.io(), "oversized.yaml", .{});
    try compat.fileSeekTo(file, config_mod.config_source_bytes_max);
    try compat.fileWriteAll(file, "x");
    file.close(compat.io());
    const path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "oversized.yaml",
        allocator,
    );
    defer allocator.free(path);

    for (config_file_loaders) |loader| {
        try expectConfigFileLoaderError(
            error.ConfigTooLarge,
            loader,
            allocator,
            path,
        );
    }
}
