const std = @import("std");
const compat = @import("compat.zig");
const yaml = @import("util/yaml.zig");
const meta = @import("meta.zig");
const cli_output = @import("cli/output.zig");
const config_catalog = @import("config_catalog.zig");

pub const ProxyType = enum {
    direct,
    reject,
    http,
    socks5,
    ss, // Shadowsocks
    vmess, // VMess
    trojan, // Trojan
    vless, // VLESS
    anytls, // AnyTLS
};

pub const Proxy = struct {
    name: []const u8,
    proxy_type: ProxyType,
    server: []const u8,
    port: u16,
    // Protocol-specific fields
    password: ?[]const u8 = null,
    cipher: ?[]const u8 = null, // SS
    uuid: ?[]const u8 = null, // VMess/VLESS
    alter_id: u16 = 0, // VMess
    tls: bool = false,
    skip_cert_verify: bool = false,
    udp: bool = false, // UDP relay (anytls-only for now; see config_validator)
    sni: ?[]const u8 = null,
    ws: bool = false, // WebSocket
    ws_path: ?[]const u8 = null,
    ws_host: ?[]const u8 = null,
    // Obfs plugin for Shadowsocks
    plugin: ?[]const u8 = null,
    plugin_opts: ?[]const u8 = null,
    obfs_mode: ?[]const u8 = null, // http or tls
    obfs_host: ?[]const u8 = null, // host header for obfs

    pub fn deinit(self: *Proxy, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.server);
        if (self.password) |p| allocator.free(p);
        if (self.cipher) |c| allocator.free(c);
        if (self.uuid) |u| allocator.free(u);
        if (self.sni) |s| allocator.free(s);
        if (self.ws_path) |p| allocator.free(p);
        if (self.ws_host) |h| allocator.free(h);
        if (self.plugin) |p| allocator.free(p);
        if (self.plugin_opts) |p| allocator.free(p);
        if (self.obfs_mode) |m| allocator.free(m);
        if (self.obfs_host) |h| allocator.free(h);
    }
};

pub const RuleType = enum {
    domain,
    domain_suffix,
    domain_keyword,
    ip_cidr,
    ip_cidr6,
    geoip,
    rule_set,
    src_ip_cidr,
    dst_port,
    src_port,
    process_name,
    final, // MATCH
};

pub const Rule = struct {
    rule_type: RuleType,
    payload: []const u8,
    target: []const u8, // Proxy name or DIRECT/REJECT
    no_resolve: bool = false,

    pub fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        allocator.free(self.target);
    }
};

pub const RuleProviderBehavior = enum {
    domain,
    ipcidr,
    classical,
};

pub const RuleProviderSyncPolicy = enum {
    eager,
    missing_only,
};

pub const RuleProvider = struct {
    name: []const u8,
    provider_type: []const u8,
    behavior: RuleProviderBehavior,
    url: ?[]const u8 = null,
    path: []const u8,
    interval: u32 = 86400,
    entries: std.ArrayList([]const u8),

    pub fn deinit(self: *RuleProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.provider_type);
        if (self.url) |u| allocator.free(u);
        allocator.free(self.path);
        self.clearEntries(allocator);
        self.entries.deinit(allocator);
    }

    pub fn clearEntries(self: *RuleProvider, allocator: std.mem.Allocator) void {
        for (self.entries.items) |item| allocator.free(item);
        self.entries.clearAndFree(allocator);
    }
};

pub const ProxyGroupType = enum {
    select,
    url_test,
    fallback,
    load_balance,
    relay,
};

pub const ProxyGroup = struct {
    name: []const u8,
    group_type: ProxyGroupType,
    proxies: std.ArrayList([]const u8),
    url: ?[]const u8 = null,
    interval: u32 = 300,
    tolerance: u16 = 100,
    lazy: bool = true,

    pub fn deinit(self: *ProxyGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.proxies.items) |proxy| {
            allocator.free(proxy);
        }
        self.proxies.deinit(allocator);
        if (self.url) |u| allocator.free(u);
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    port: u16 = 0,
    socks_port: u16 = 0,
    mixed_port: u16 = 0,
    redir_port: u16 = 0,
    tproxy_port: u16 = 0,
    allow_lan: bool = false,
    bind_address: []const u8 = "*",
    mode: []const u8 = "rule",
    log_level: []const u8 = "info",
    ipv6: bool = true,
    external_controller: ?[]const u8 = null,
    external_ui: ?[]const u8 = null,
    secret: ?[]const u8 = null,

    // AnyTLS idle session pool tunables (§15), in SECONDS. Defaults apply when
    // absent from the YAML. config_validator clamps the two sub-5s intervals to
    // 30s independently; min_idle_session is unclamped.
    idle_session_check_interval: i64 = 30,
    idle_session_timeout: i64 = 30,
    min_idle_session: u32 = 0,

    proxies: std.ArrayList(Proxy),
    proxy_groups: std.ArrayList(ProxyGroup),
    rule_providers: std.ArrayList(RuleProvider) = .empty,
    rules: std.ArrayList(Rule),

    pub fn deinit(self: *Config) void {
        for (self.proxies.items) |*proxy| {
            proxy.deinit(self.allocator);
        }
        self.proxies.deinit(self.allocator);

        for (self.proxy_groups.items) |*group| {
            group.deinit(self.allocator);
        }
        self.proxy_groups.deinit(self.allocator);

        for (self.rule_providers.items) |*provider| {
            provider.deinit(self.allocator);
        }
        self.rule_providers.deinit(self.allocator);

        for (self.rules.items) |*rule| {
            rule.deinit(self.allocator);
        }
        self.rules.deinit(self.allocator);

        self.allocator.free(self.mode);
        self.allocator.free(self.log_level);
        self.allocator.free(self.bind_address);
        if (self.external_controller) |ec| self.allocator.free(ec);
        if (self.external_ui) |ui| self.allocator.free(ui);
        if (self.secret) |s| self.allocator.free(s);
    }
};

/// 从文件加载配置
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try compat.fs.cwd().openFile(path, .{});
    defer file.close(compat.io());

    const content = try compat.fileReadToEndAlloc(file, allocator, 1024 * 1024);
    defer allocator.free(content);

    return try parse(allocator, content);
}

/// Loads one strict managed YAML document from disk.
pub fn loadDocument(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try compat.fs.cwd().openFile(path, .{});
    defer file.close(compat.io());
    const content = try compat.fileReadToEndAlloc(file, allocator, 16 * 1024 * 1024);
    defer allocator.free(content);
    return parseDocument(allocator, content);
}

/// 从 YAML 字符串解析配置
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Config {
    var root = try yaml.parse(allocator, content);
    defer root.deinit(allocator);
    return parseRoot(allocator, &root, false);
}

/// Parses one complete managed configuration document.
/// This additive entry point rejects duplicate keys and malformed tails.
pub fn parseDocument(allocator: std.mem.Allocator, content: []const u8) !Config {
    var root = try yaml.parseDocument(allocator, content);
    defer root.deinit(allocator);
    return parseRoot(allocator, &root, true);
}

fn replaceOwnedString(
    allocator: std.mem.Allocator,
    destination: *[]const u8,
    source: []const u8,
) !void {
    const replacement = try allocator.dupe(u8, source);
    const previous = destination.*;
    destination.* = replacement;
    allocator.free(previous);
}

fn parseRoot(
    allocator: std.mem.Allocator,
    root: *yaml.YamlValue,
    managed: bool,
) !Config {
    const default_mode = try allocator.dupe(u8, "rule");
    var mode_owned = true;
    errdefer if (mode_owned) allocator.free(default_mode);
    const default_log_level = try allocator.dupe(u8, "info");
    var log_level_owned = true;
    errdefer if (log_level_owned) allocator.free(default_log_level);
    const default_bind_address = try allocator.dupe(u8, "*");
    var bind_address_owned = true;
    errdefer if (bind_address_owned) allocator.free(default_bind_address);

    var config = Config{
        .allocator = allocator,
        .mode = default_mode,
        .log_level = default_log_level,
        .bind_address = default_bind_address,
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(ProxyGroup).empty,
        .rule_providers = std.ArrayList(RuleProvider).empty,
        .rules = std.ArrayList(Rule).empty,
    };
    mode_owned = false;
    log_level_owned = false;
    bind_address_owned = false;
    errdefer config.deinit();

    if (root.* != .map) {
        return error.InvalidConfig;
    }

    // 解析基础配置
    if (root.map.get("port")) |v| {
        if (v != .integer or v.integer < 0 or v.integer > 65535) {
            if (managed) return error.InvalidConfig;
        } else {
            config.port = @intCast(v.integer);
        }
    }
    if (root.map.get("socks-port")) |v| {
        if (v != .integer or v.integer < 0 or v.integer > 65535) {
            if (managed) return error.InvalidConfig;
        } else {
            config.socks_port = @intCast(v.integer);
        }
    }
    if (root.map.get("mixed-port")) |v| {
        if (v != .integer or v.integer < 0 or v.integer > 65535) {
            if (managed) return error.InvalidConfig;
        } else {
            config.mixed_port = @intCast(v.integer);
        }
    }
    if (managed) {
        if (root.map.get("redir-port")) |v| {
            if (v != .integer or v.integer < 0 or v.integer > 65535) return error.InvalidConfig;
            config.redir_port = @intCast(v.integer);
        }
        if (root.map.get("tproxy-port")) |v| {
            if (v != .integer or v.integer < 0 or v.integer > 65535) return error.InvalidConfig;
            config.tproxy_port = @intCast(v.integer);
        }
    }
    if (root.map.get("allow-lan")) |v| {
        if (v == .boolean) {
            config.allow_lan = v.boolean;
        } else if (managed) return error.InvalidConfig;
    }
    if (managed) {
        if (root.map.get("ipv6")) |v| {
            if (v != .boolean) return error.InvalidConfig;
            config.ipv6 = v.boolean;
        }
    }
    if (root.map.get("bind-address")) |v| {
        if (v == .string) {
            try replaceOwnedString(allocator, &config.bind_address, v.string);
        } else if (managed) return error.InvalidConfig;
    }
    if (root.map.get("mode")) |v| {
        if (v == .string) {
            try replaceOwnedString(allocator, &config.mode, v.string);
        } else if (managed) return error.InvalidConfig;
    }
    if (root.map.get("log-level")) |v| {
        if (v == .string) {
            try replaceOwnedString(allocator, &config.log_level, v.string);
        } else if (managed) return error.InvalidConfig;
    }
    if (root.map.get("external-controller")) |v| switch (v) {
        .string => config.external_controller = try allocator.dupe(u8, v.string),
        .null => {},
        else => if (managed) return error.InvalidConfig,
    };
    if (managed) {
        if (root.map.get("external-ui")) |v| switch (v) {
            .string => config.external_ui = try allocator.dupe(u8, v.string),
            .null => {},
            else => return error.InvalidConfig,
        };
    }
    if (root.map.get("secret")) |v| switch (v) {
        .string => config.secret = try allocator.dupe(u8, v.string),
        .null => {},
        else => return error.InvalidConfig,
    };

    // AnyTLS idle session pool tunables (§15). Optional; defaults stay when
    // absent. Stored raw (seconds); config_validator clamps the two intervals.
    if (root.map.get("idle-session-check-interval")) |v| {
        if (v == .integer) {
            config.idle_session_check_interval = v.integer;
        } else if (managed) return error.InvalidConfig;
    }
    if (root.map.get("idle-session-timeout")) |v| {
        if (v == .integer) {
            config.idle_session_timeout = v.integer;
        } else if (managed) return error.InvalidConfig;
    }
    if (root.map.get("min-idle-session")) |v| {
        if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(u32)) {
            config.min_idle_session = @intCast(v.integer);
        } else if (managed) return error.InvalidConfig;
    }

    // 解析代理列表
    if (root.map.get("proxies")) |proxies| {
        if (proxies != .array) {
            if (managed) return error.InvalidConfig;
        } else {
            for (proxies.array.items) |*item| {
                if (item.* != .map) {
                    if (managed) return error.InvalidConfig;
                    continue;
                }
                // 检查是否是代理组类型（select, url-test等）
                if (isProxyGroupType(item.map)) {
                    var group = try parseProxyGroup(allocator, item.map, managed);
                    config.proxy_groups.append(allocator, group) catch |err| {
                        group.deinit(allocator);
                        return err;
                    };
                } else if (isSubscriptionInfoNode(item.map)) {
                    // Skip airport quota/expiry pseudo-nodes (see isSubscriptionInfoNode).
                    continue;
                } else {
                    var proxy = try parseProxy(allocator, item.map, managed);
                    config.proxies.append(allocator, proxy) catch |err| {
                        proxy.deinit(allocator);
                        return err;
                    };
                }
            }
        }
    }

    // 解析代理组
    if (root.map.get("proxy-groups")) |groups| {
        if (groups != .array) {
            if (managed) return error.InvalidConfig;
        } else {
            for (groups.array.items) |*item| {
                if (item.* != .map) {
                    if (managed) return error.InvalidConfig;
                    continue;
                }
                var group = try parseProxyGroup(allocator, item.map, managed);
                config.proxy_groups.append(allocator, group) catch |err| {
                    group.deinit(allocator);
                    return err;
                };
            }
        }
    }

    if (root.map.get("rule-providers")) |providers| {
        if (providers != .map) {
            if (managed) return error.InvalidConfig;
        } else {
            var it = providers.map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .map) return error.InvalidConfig;
                var provider = try parseRuleProvider(
                    allocator,
                    entry.key_ptr.*,
                    entry.value_ptr.*.map,
                    managed,
                );
                config.rule_providers.append(allocator, provider) catch |err| {
                    provider.deinit(allocator);
                    return err;
                };
            }
        }
    }

    var legacy_direct_fallback_allowed = false;
    if (root.map.get("rules")) |rules| {
        if (rules != .array) return error.InvalidConfig;
        for (rules.array.items) |*item| {
            if (item.* != .string) return error.InvalidConfig;
            var rule = try parseRule(allocator, item.string);
            config.rules.append(allocator, rule) catch |err| {
                rule.deinit(allocator);
                return err;
            };
        }
    } else {
        legacy_direct_fallback_allowed = true;
    }

    var final_count: u8 = 0;
    for (config.rules.items, 0..) |rule, index| {
        if (rule.rule_type != .final) continue;
        if (final_count == 1) return error.InvalidConfig;
        final_count += 1;
        if (index + 1 != config.rules.items.len) {
            return error.InvalidConfig;
        }
    }
    if (final_count == 0) {
        const implicit_target = if (!managed and
            legacy_direct_fallback_allowed)
            "DIRECT"
        else
            "REJECT";
        try appendImplicitFinalRule(
            allocator,
            &config.rules,
            implicit_target,
        );
    }

    return config;
}

fn appendImplicitFinalRule(
    allocator: std.mem.Allocator,
    rules: *std.ArrayList(Rule),
    target_name: []const u8,
) !void {
    const payload = try allocator.dupe(u8, "");
    errdefer allocator.free(payload);
    const target = try allocator.dupe(u8, target_name);
    errdefer allocator.free(target);
    try rules.append(allocator, .{
        .rule_type = .final,
        .payload = payload,
        .target = target,
    });
}

/// Clash airport subscriptions inject pseudo "nodes" that aren't dialable
/// servers — they exist only to surface quota/expiry in a client's proxy
/// selector (e.g. "Traffic: 167.74 GB | 400 GB", "Expire: 2026-07-20",
/// "剩余流量：…", "套餐到期：…"). They carry a real `type`, so they would
/// otherwise parse as genuine proxies, flood validation warnings, and waste a
/// dial/latency probe on a junk server.
fn isSubscriptionInfoNode(map: std.StringHashMap(yaml.YamlValue)) bool {
    const nm = map.get("name") orelse return false;
    if (nm != .string) return false;
    return isSubscriptionInfoNodeName(nm.string);
}

fn isSubscriptionInfoNodeName(name: []const u8) bool {
    // A banner has the shape "<label><colon><value>" (e.g. "Traffic: 167 GB",
    // "剩余流量：232 GB"). Match the label as a prefix AND require a colon
    // separator (half- or full-width) immediately after it, so a real node whose
    // name merely BEGINS with a label word — "剩余流量优化节点",
    // "Traffic-Singapore-01" — is not mistaken for a banner.
    const labels = [_][]const u8{
        "Traffic", "Expire",
        "剩余流量",
        "套餐到期",
        "距离下次重置",
        "过期时间",
        "到期时间",
    };
    for (labels) |label| {
        if (label.len > name.len) continue;
        if (!std.mem.eql(u8, name[0..label.len], label)) continue;
        const rest = name[label.len..];
        if (std.mem.startsWith(u8, rest, ":") or std.mem.startsWith(u8, rest, "：")) return true;
    }
    return false;
}

test "isSubscriptionInfoNodeName matches quota/expiry banners, not real nodes" {
    const t = std.testing;
    try t.expect(isSubscriptionInfoNodeName("Traffic: 167.74 GB | 400 GB"));
    try t.expect(isSubscriptionInfoNodeName("Expire: 2026-07-20"));
    try t.expect(isSubscriptionInfoNodeName("剩余流量：232 GB"));
    try t.expect(isSubscriptionInfoNodeName("套餐到期：2026-07-20"));
    // Real proxy names must NOT be filtered.
    try t.expect(!isSubscriptionInfoNodeName("🇸🇬 新加坡高级 IEPL 专线 1"));
    try t.expect(!isSubscriptionInfoNodeName("🇭🇰 香港实验性 IEPL 专线 1"));
    try t.expect(!isSubscriptionInfoNodeName("US-Premium-01"));
    // Would have been false positives with substring matching (§22 review fix).
    try t.expect(!isSubscriptionInfoNodeName("Traffic-Singapore-01"));
    try t.expect(!isSubscriptionInfoNodeName("剩余流量优化节点"));
}

fn parseProxy(
    allocator: std.mem.Allocator,
    map: std.StringHashMap(yaml.YamlValue),
    managed: bool,
) !Proxy {
    const name = map.get("name") orelse return error.MissingProxyName;
    const proxy_type = map.get("type") orelse return error.MissingProxyType;

    if (name != .string or proxy_type != .string) {
        return error.InvalidProxyFormat;
    }

    const ptype = parseProxyType(proxy_type.string) orelse return error.UnknownProxyType;

    // DIRECT 和 REJECT 不需要 server 和 port
    const needs_server = ptype != .direct and ptype != .reject;

    var ownership_transferred = false;
    const name_dup = try allocator.dupe(u8, name.string);
    errdefer if (!ownership_transferred) allocator.free(name_dup);

    var server_dup: []const u8 = "";
    var server_allocated = false;
    errdefer if (!ownership_transferred and server_allocated) allocator.free(server_dup);
    var port_val: u16 = 0;
    if (needs_server) {
        const server = map.get("server") orelse return error.MissingProxyServer;
        if (server != .string) return error.InvalidProxyFormat;
        server_dup = try allocator.dupe(u8, server.string);
        server_allocated = true;

        const port = map.get("port") orelse return error.MissingProxyPort;
        if (port != .integer) return error.InvalidProxyFormat;
        if (port.integer <= 0 or port.integer > 65535) return error.InvalidProxyPort;
        port_val = @intCast(port.integer);
    }

    var proxy = Proxy{
        .name = name_dup,
        .proxy_type = ptype,
        .server = server_dup,
        .port = port_val,
    };
    ownership_transferred = true;
    errdefer proxy.deinit(allocator);

    // 协议特定字段
    if (map.get("password")) |v| {
        if (v == .string) {
            proxy.password = try allocator.dupe(u8, v.string);
        } else if (managed) return error.InvalidProxyFormat;
    }
    if (map.get("cipher")) |v| {
        if (v == .string) {
            proxy.cipher = try allocator.dupe(u8, v.string);
        } else if (managed) return error.InvalidProxyFormat;
    }
    if (map.get("uuid")) |v| {
        if (v == .string) {
            proxy.uuid = try allocator.dupe(u8, v.string);
        } else if (managed) return error.InvalidProxyFormat;
    }
    if (map.get("alterId")) |v| {
        if (v == .integer) {
            if (v.integer < 0 or v.integer > std.math.maxInt(u16)) return error.InvalidAlterId;
            proxy.alter_id = @intCast(v.integer);
        } else if (managed) return error.InvalidProxyFormat;
    }
    if (map.get("tls")) |v| {
        if (v == .boolean) {
            proxy.tls = v.boolean;
        } else if (managed) return error.InvalidProxyFormat;
    }
    if (map.get("skip-cert-verify")) |v| {
        if (v == .boolean) {
            proxy.skip_cert_verify = v.boolean;
        } else if (managed) return error.InvalidProxyFormat;
    }
    if (map.get("udp")) |v| {
        if (v == .boolean) {
            proxy.udp = v.boolean;
        } else if (managed) return error.InvalidProxyFormat;
    }
    if (map.get("sni")) |v| {
        if (v == .string) {
            proxy.sni = try allocator.dupe(u8, v.string);
        } else if (managed) return error.InvalidProxyFormat;
    }
    if (map.get("ws-opts")) |v| {
        if (v == .map) {
            proxy.ws = true;
            if (v.map.get("path")) |p| {
                if (p == .string) {
                    proxy.ws_path = try allocator.dupe(u8, p.string);
                } else if (managed) return error.InvalidProxyFormat;
            }
            if (v.map.get("headers")) |h| {
                if (h == .map) {
                    if (h.map.get("Host")) |host| {
                        if (host == .string) {
                            proxy.ws_host = try allocator.dupe(u8, host.string);
                        } else if (managed) return error.InvalidProxyFormat;
                    }
                } else if (managed) return error.InvalidProxyFormat;
            }
        } else if (managed) return error.InvalidProxyFormat;
    }

    // VLESS 必填字段校验
    if (ptype == .vless and (proxy.uuid == null or proxy.uuid.?.len == 0)) {
        return error.MissingProxyUuid;
    }

    // Obfs plugin for Shadowsocks
    if (map.get("plugin")) |v| {
        if (v == .string) {
            proxy.plugin = try allocator.dupe(u8, v.string);
            // Parse simple-obfs mode
            if (std.mem.eql(u8, v.string, "obfs")) {
                // Check for plugin-opts (with hyphen)
                if (map.get("plugin-opts")) |opts| {
                    if (opts == .map) {
                        // Try with hyphen
                        if (opts.map.get("mode")) |mode| {
                            if (mode == .string) proxy.obfs_mode = try allocator.dupe(u8, mode.string);
                        }
                        // Try with underscore
                        if (opts.map.get("host")) |host| {
                            if (host == .string) proxy.obfs_host = try allocator.dupe(u8, host.string);
                        }
                    }
                } else if (map.get("plugin_opts")) |opts| {
                    // Try with underscore
                    if (opts == .map) {
                        if (opts.map.get("mode")) |mode| {
                            if (mode == .string) proxy.obfs_mode = try allocator.dupe(u8, mode.string);
                        }
                        if (opts.map.get("host")) |host| {
                            if (host == .string) proxy.obfs_host = try allocator.dupe(u8, host.string);
                        }
                    }
                }
            }
        } else return error.InvalidProxyFormat;
    }

    return proxy;
}

fn parseProxyGroup(
    allocator: std.mem.Allocator,
    map: std.StringHashMap(yaml.YamlValue),
    managed: bool,
) !ProxyGroup {
    const name = map.get("name") orelse return error.MissingGroupName;
    const gtype = map.get("type") orelse return error.MissingGroupType;

    if (name != .string or gtype != .string) {
        return error.InvalidGroupFormat;
    }

    const group_type = parseGroupType(gtype.string) orelse return error.UnknownGroupType;

    var group = ProxyGroup{
        .name = try allocator.dupe(u8, name.string),
        .group_type = group_type,
        .proxies = std.ArrayList([]const u8).empty,
    };
    errdefer group.deinit(allocator);

    if (map.get("proxies")) |proxies| {
        if (proxies == .array) {
            for (proxies.array.items) |*item| {
                if (item.* != .string) {
                    if (managed) return error.InvalidGroupFormat;
                    continue;
                }
                // Skip dangling references to dropped info-nodes.
                if (isSubscriptionInfoNodeName(item.string)) {
                    std.log.scoped(.config).info("proxy-group '{s}': skipping subscription info-node reference '{s}'", .{ name.string, item.string });
                    continue;
                }
                const proxy_name = try allocator.dupe(u8, item.string);
                errdefer allocator.free(proxy_name);
                try group.proxies.append(allocator, proxy_name);
            }
        } else if (managed) return error.InvalidGroupFormat;
    }

    if (map.get("url")) |v| {
        if (v == .string) {
            group.url = try allocator.dupe(u8, v.string);
        } else if (managed) return error.InvalidGroupFormat;
    }
    if (map.get("interval")) |v| {
        if (v == .integer) {
            if (v.integer < 0 or v.integer > std.math.maxInt(u32)) return error.InvalidGroupInterval;
            group.interval = @intCast(v.integer);
        } else if (managed) return error.InvalidGroupFormat;
    }
    if (map.get("tolerance")) |v| {
        if (v == .integer) {
            if (v.integer < 0 or v.integer > std.math.maxInt(u16)) return error.InvalidGroupTolerance;
            group.tolerance = @intCast(v.integer);
        } else if (managed) return error.InvalidGroupFormat;
    }
    if (map.get("lazy")) |v| {
        if (v == .boolean) {
            group.lazy = v.boolean;
        } else if (managed) return error.InvalidGroupFormat;
    }

    return group;
}

fn parseRuleProvider(
    allocator: std.mem.Allocator,
    name: []const u8,
    map: std.StringHashMap(yaml.YamlValue),
    managed: bool,
) !RuleProvider {
    const type_val = map.get("type") orelse return error.MissingRuleProviderType;
    const behavior_val = map.get("behavior") orelse return error.MissingRuleProviderBehavior;
    const path_val = map.get("path") orelse return error.MissingRuleProviderPath;

    if (type_val != .string or behavior_val != .string or path_val != .string) {
        return error.InvalidRuleProviderFormat;
    }

    const behavior = parseRuleProviderBehavior(behavior_val.string) orelse
        return error.InvalidRuleProviderBehavior;
    var url: ?[]const u8 = null;
    if (map.get("url")) |value| switch (value) {
        .string => url = value.string,
        .null => if (!managed) return error.InvalidRuleProviderFormat,
        else => return error.InvalidRuleProviderFormat,
    };
    var interval: u32 = 86400;
    if (map.get("interval")) |value| {
        if (value != .integer or value.integer <= 0 or value.integer > std.math.maxInt(u32)) {
            return error.InvalidRuleProviderFormat;
        }
        interval = @intCast(value.integer);
    }
    if (managed) {
        if ((!std.mem.eql(u8, type_val.string, "http") and
            !std.mem.eql(u8, type_val.string, "file")) or path_val.string.len == 0)
        {
            return error.InvalidRuleProviderFormat;
        }
        if (url) |remote_url| {
            if (!isHttpUrl(remote_url)) return error.InvalidRuleProviderFormat;
        }
    }

    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const type_copy = try allocator.dupe(u8, type_val.string);
    errdefer allocator.free(type_copy);
    const path_copy = try allocator.dupe(u8, path_val.string);
    errdefer allocator.free(path_copy);
    const url_copy = if (url) |remote_url| try allocator.dupe(u8, remote_url) else null;
    errdefer if (url_copy) |value| allocator.free(value);

    return .{
        .name = name_copy,
        .provider_type = type_copy,
        .behavior = behavior,
        .path = path_copy,
        .url = url_copy,
        .interval = interval,
        .entries = std.ArrayList([]const u8).empty,
    };
}

fn isHttpUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        return false;
    }
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buffer) catch return false;
    return host.bytes.len != 0;
}

fn parseRule(allocator: std.mem.Allocator, rule_str: []const u8) !Rule {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, rule_str, " \t\r\n");

    // Parse rule format: TYPE,PARAM,TARGET[,no-resolve] or TYPE,TARGET (for MATCH)
    var parts = std.mem.splitScalar(u8, trimmed, ',');

    const type_str = parts.next() orelse return error.InvalidRule;

    // MATCH rule has no payload: MATCH,TARGET
    // Other rules have payload: TYPE,PAYLOAD,TARGET
    const payload: []const u8 = blk: {
        if (std.mem.eql(u8, type_str, "MATCH")) {
            break :blk "";
        } else {
            break :blk parts.next() orelse return error.InvalidRule;
        }
    };

    const target = parts.next() orelse return error.InvalidRule;

    var no_resolve = false;
    while (parts.next()) |opt| {
        if (std.mem.eql(u8, std.mem.trim(u8, opt, " \t"), "no-resolve")) {
            no_resolve = true;
        }
    }

    const rule_type = parseRuleType(type_str) orelse return error.UnknownRuleType;

    const payload_copy = try allocator.dupe(u8, std.mem.trim(u8, payload, " \t"));
    errdefer allocator.free(payload_copy);
    const target_copy = try allocator.dupe(u8, std.mem.trim(u8, target, " \t"));
    return .{
        .rule_type = rule_type,
        .payload = payload_copy,
        .target = target_copy,
        .no_resolve = no_resolve,
    };
}

fn parseProxyType(s: []const u8) ?ProxyType {
    if (std.mem.eql(u8, s, "direct")) return .direct;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    if (std.mem.eql(u8, s, "http")) return .http;
    if (std.mem.eql(u8, s, "socks5")) return .socks5;
    if (std.mem.eql(u8, s, "ss")) return .ss;
    if (std.mem.eql(u8, s, "vmess")) return .vmess;
    if (std.mem.eql(u8, s, "trojan")) return .trojan;
    if (std.mem.eql(u8, s, "vless")) return .vless;
    if (std.mem.eql(u8, s, "anytls")) return .anytls;
    return null;
}

fn parseGroupType(s: []const u8) ?ProxyGroupType {
    if (std.mem.eql(u8, s, "select")) return .select;
    if (std.mem.eql(u8, s, "url-test")) return .url_test;
    if (std.mem.eql(u8, s, "fallback")) return .fallback;
    if (std.mem.eql(u8, s, "load-balance")) return .load_balance;
    if (std.mem.eql(u8, s, "relay")) return .relay;
    return null;
}

/// 检查一个 YAML map 是否是代理组类型
fn isProxyGroupType(map: std.StringHashMap(yaml.YamlValue)) bool {
    if (map.get("type")) |type_val| {
        if (type_val == .string) {
            return parseGroupType(type_val.string) != null;
        }
    }
    return false;
}

fn parseRuleType(s: []const u8) ?RuleType {
    if (std.mem.eql(u8, s, "DOMAIN")) return .domain;
    if (std.mem.eql(u8, s, "DOMAIN-SUFFIX")) return .domain_suffix;
    if (std.mem.eql(u8, s, "DOMAIN-KEYWORD")) return .domain_keyword;
    if (std.mem.eql(u8, s, "IP-CIDR")) return .ip_cidr;
    if (std.mem.eql(u8, s, "IP-CIDR6")) return .ip_cidr6;
    if (std.mem.eql(u8, s, "GEOIP")) return .geoip;
    if (std.mem.eql(u8, s, "RULE-SET")) return .rule_set;
    if (std.mem.eql(u8, s, "SRC-IP-CIDR")) return .src_ip_cidr;
    if (std.mem.eql(u8, s, "DST-PORT")) return .dst_port;
    if (std.mem.eql(u8, s, "SRC-PORT")) return .src_port;
    if (std.mem.eql(u8, s, "PROCESS-NAME")) return .process_name;
    if (std.mem.eql(u8, s, "MATCH")) return .final;
    return null;
}

fn parseRuleProviderBehavior(s: []const u8) ?RuleProviderBehavior {
    if (std.mem.eql(u8, s, "domain")) return .domain;
    if (std.mem.eql(u8, s, "ipcidr")) return .ipcidr;
    if (std.mem.eql(u8, s, "classical")) return .classical;
    return null;
}

fn absolutePathExists(path: []const u8) !bool {
    compat.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn cwdPathExists(path: []const u8) !bool {
    compat.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn activeConfigPathInDirectory(
    allocator: std.mem.Allocator,
    configs_directory: []const u8,
    active_key: []const u8,
) ![]u8 {
    if (!config_catalog.isManagedKey(active_key)) {
        return error.InvalidConfigKey;
    }
    const yaml_name = try std.fmt.allocPrint(
        allocator,
        "{s}.yaml",
        .{active_key},
    );
    defer allocator.free(yaml_name);
    const path = try compat.fs.path.join(
        allocator,
        &.{ configs_directory, yaml_name },
    );
    errdefer allocator.free(path);
    if (!try absolutePathExists(path)) return error.ActiveConfigMissing;
    return path;
}

/// 查找默认配置文件路径
/// 通过 meta.json 的 active 字段确定当前配置，路径在 configs/ 子目录
/// 回退：~/.config/zc/config.yaml > ~/.zc/config.yaml > ./config.yaml
fn getDefaultConfigPath(allocator: std.mem.Allocator) !?[]const u8 {
    // 1. 尝试从 meta.json 的 active 字段加载
    if (try meta.getConfigsDir(allocator)) |configs_dir| {
        defer allocator.free(configs_dir);

        var meta_data = try meta.load(allocator);
        defer meta_data.deinit();

        if (meta_data.active) |active_key| {
            return try activeConfigPathInDirectory(
                allocator,
                configs_dir,
                active_key,
            );
        }

        // 1b. 尝试 configs/ 目录下的 config.yaml
        const configs_default = try compat.fs.path.join(
            allocator,
            &.{ configs_dir, "config.yaml" },
        );
        if (try absolutePathExists(configs_default)) return configs_default;
        allocator.free(configs_default);
    }

    // 2. 回退到旧路径
    const home = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    // 旧的 config.yaml（符号链接或直接文件）
    const old_config = try compat.fs.path.join(
        allocator,
        &.{ home, ".config/zc/config.yaml" },
    );
    if (try absolutePathExists(old_config)) return old_config;
    allocator.free(old_config);

    const old_config2 = try compat.fs.path.join(
        allocator,
        &.{ home, ".zc/config.yaml" },
    );
    if (try absolutePathExists(old_config2)) return old_config2;
    allocator.free(old_config2);

    // 检查当前目录的 config.yaml
    if (!try cwdPathExists("config.yaml")) return null;
    return try allocator.dupe(u8, "config.yaml");
}

/// 默认配置（先尝试从文件读取，失败则用内置配置）
pub fn loadDefault(allocator: std.mem.Allocator) !Config {
    return try loadDefaultWithLogging(allocator, true);
}

/// 默认配置静默加载，用于已经有结构化输出契约的命令路径
pub fn loadDefaultQuiet(allocator: std.mem.Allocator) !Config {
    return try loadDefaultWithLogging(allocator, false);
}

pub fn loadDefaultManaged(allocator: std.mem.Allocator, log_selection: bool) !Config {
    if (try getDefaultConfigPath(allocator)) |path| {
        defer allocator.free(path);
        if (log_selection) std.debug.print("Loading config from: {s}\n", .{path});
        if (try inferConfigKeyFromPath(allocator, path)) |key| {
            allocator.free(key);
            return loadDocument(allocator, path);
        }
        return load(allocator, path);
    }
    return loadDefaultWithLogging(allocator, log_selection);
}

fn loadDefaultWithLogging(allocator: std.mem.Allocator, log_selection: bool) !Config {
    // 尝试查找默认配置文件
    if (try getDefaultConfigPath(allocator)) |path| {
        defer allocator.free(path);
        if (log_selection) {
            std.debug.print("Loading config from: {s}\n", .{path});
        }
        return try load(allocator, path);
    }

    // 使用内置默认配置
    if (log_selection) {
        std.debug.print("No config file found, using built-in defaults\n", .{});
    }
    const yaml_config =
        \\mixed-port: 7899
        \\mode: rule
        \\log-level: info
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\    server: ""
        \\    port: 0
        \\  - name: REJECT
        \\    type: reject
        \\    server: ""
        \\    port: 0
        \\rules:
        \\  - MATCH,DIRECT
    ;
    return try parse(allocator, yaml_config);
}

pub fn prepareRuleProvidersForRuntime(
    allocator: std.mem.Allocator,
    cfg: *Config,
    config_path: ?[]const u8,
) !void {
    try prepareRuleProvidersForRuntimeWithPolicy(allocator, cfg, config_path, .eager);
}

pub fn prepareRuleProvidersForRuntimeWithPolicy(
    allocator: std.mem.Allocator,
    cfg: *Config,
    config_path: ?[]const u8,
    sync_policy: RuleProviderSyncPolicy,
) !void {
    try syncRuleProviderFilesIfNeeded(allocator, cfg, config_path, sync_policy);
    try loadRuleProviderEntries(allocator, cfg, config_path);
    try expandRuleSetRules(allocator, cfg);
    clearRuleProviderEntries(allocator, cfg);
}

/// Prepares captured local rule providers without filesystem or network access.
/// Remote providers remain declarations and their RULE-SET rules stay unexpanded.
pub fn prepareRuleProvidersOffline(
    allocator: std.mem.Allocator,
    cfg: *Config,
    resolver: anytype,
) !void {
    defer clearRuleProviderEntries(allocator, cfg);
    try loadRuleProviderEntriesOffline(allocator, cfg, resolver);
    try validateOfflineProviderEntries(allocator, cfg);
    try expandLocalRuleSetRules(allocator, cfg);
}

fn clearRuleProviderEntries(allocator: std.mem.Allocator, cfg: *Config) void {
    for (cfg.rule_providers.items) |*provider| {
        provider.clearEntries(allocator);
    }
}

fn syncRuleProviderFilesIfNeeded(
    allocator: std.mem.Allocator,
    cfg: *Config,
    config_path: ?[]const u8,
    sync_policy: RuleProviderSyncPolicy,
) !void {
    for (cfg.rule_providers.items) |*provider| {
        const resolved_path = try resolveRuleProviderPath(allocator, provider.path, config_path);
        defer allocator.free(resolved_path);

        const file = compat.fs.openFileAbsolute(resolved_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (provider.url) |url| {
                    try downloadRuleProviderFile(
                        allocator,
                        provider,
                        url,
                        resolved_path,
                        true,
                    );
                    continue;
                }
                return error.RuleProviderFileNotFound;
            },
            else => return err,
        };
        defer file.close(compat.io());
        const stat = try file.stat(compat.io());

        if (provider.url) |url| {
            if (sync_policy == .eager and isRuleProviderRefreshDue(stat.mtime.nanoseconds, provider.interval)) {
                downloadRuleProviderFile(
                    allocator,
                    provider,
                    url,
                    resolved_path,
                    false,
                ) catch |err| {
                    std.debug.print(
                        "rule-provider refresh failed (using cached file): name={s} url={s} path={s} error={s}\n",
                        .{ provider.name, url, resolved_path, @errorName(err) },
                    );
                };
            }
        }
    }
}

fn downloadRuleProviderFile(
    allocator: std.mem.Allocator,
    provider: *const RuleProvider,
    url: []const u8,
    resolved_path: []const u8,
    required: bool,
) !void {
    const provider_name = provider.name;
    const result = fetchConfig(allocator, url) catch |err| {
        std.debug.print(
            "rule-provider download failed: name={s} url={s} path={s} error={s}\n",
            .{ provider_name, url, resolved_path, @errorName(err) },
        );
        return error.RuleProviderDownloadFailed;
    };
    defer allocator.free(result.body);

    if (result.status != .ok) {
        std.debug.print(
            "rule-provider download failed: name={s} url={s} path={s} status={d}\n",
            .{ provider_name, url, resolved_path, @intFromEnum(result.status) },
        );
        return error.RuleProviderDownloadFailed;
    }

    const publish_outcome = installDownloadedRuleProvider(
        allocator,
        provider,
        resolved_path,
        result.body,
    ) catch |err| {
        std.debug.print(
            "rule-provider download failed: name={s} url={s} path={s} " ++
                "install_error={s}\n",
            .{ provider_name, url, resolved_path, @errorName(err) },
        );
        return error.RuleProviderDownloadFailed;
    };
    if (publish_outcome == .durability_uncertain) {
        std.debug.print(
            "rule-provider visible but durability uncertain: name={s} " ++
                "path={s} error={s}\n",
            .{
                provider_name,
                resolved_path,
                @errorName(publish_outcome.durability_uncertain),
            },
        );
    }

    if (required) {
        std.debug.print("rule-provider downloaded: name={s} path={s}\n", .{ provider_name, resolved_path });
    } else {
        std.debug.print("rule-provider refreshed: name={s} path={s}\n", .{ provider_name, resolved_path });
    }
}

const RuleProviderPublishOutcome = union(enum) {
    committed,
    durability_uncertain: anyerror,
};

fn installDownloadedRuleProvider(
    allocator: std.mem.Allocator,
    provider: *const RuleProvider,
    resolved_path: []const u8,
    content: []const u8,
) !RuleProviderPublishOutcome {
    try validateDownloadedRuleProvider(allocator, provider, content);
    return publishRuleProviderFile(resolved_path, content);
}

fn validateDownloadedRuleProvider(
    allocator: std.mem.Allocator,
    provider: *const RuleProvider,
    content: []const u8,
) !void {
    var candidate = RuleProvider{
        .name = provider.name,
        .provider_type = provider.provider_type,
        .behavior = provider.behavior,
        .url = provider.url,
        .path = provider.path,
        .interval = provider.interval,
        .entries = .empty,
    };
    defer {
        candidate.clearEntries(allocator);
        candidate.entries.deinit(allocator);
    }
    try appendRuleProviderEntriesOffline(allocator, &candidate, content);
    try validateRuleProviderEntries(allocator, &candidate);
}

fn publishRuleProviderFile(
    resolved_path: []const u8,
    content: []const u8,
) !RuleProviderPublishOutcome {
    const parent_path = compat.fs.path.dirname(resolved_path) orelse
        return error.InvalidRuleProviderPath;
    try compat.fs.cwd().makePath(parent_path);
    const parent = try compat.fs.openDirAbsolute(parent_path, .{});
    defer parent.close(compat.io());
    const parent_file = try parent.openFile(
        compat.io(),
        ".",
        .{ .allow_directory = true },
    );
    defer parent_file.close(compat.io());
    const permissions = std.Io.File.Permissions.fromMode(0o600);
    var atomic = try parent.createFileAtomic(
        compat.io(),
        compat.fs.path.basename(resolved_path),
        .{ .replace = true, .permissions = permissions },
    );
    defer atomic.deinit(compat.io());
    try atomic.file.setPermissions(compat.io(), permissions);
    try compat.fileWriteAll(atomic.file, content);
    try atomic.file.sync(compat.io());
    try atomic.replace(compat.io());
    parent_file.sync(compat.io()) catch |err|
        return .{ .durability_uncertain = err };
    return .committed;
}

fn isRuleProviderRefreshDue(mtime: i128, interval_seconds: u32) bool {
    if (interval_seconds == 0) return true;
    const now_sec = compat.timestamp();
    const mtime_sec = statTimestampToSeconds(mtime);
    if (mtime_sec <= 0) return true;
    return now_sec - mtime_sec >= @as(i64, @intCast(interval_seconds));
}

fn statTimestampToSeconds(raw: i128) i64 {
    const sec_threshold: i128 = 10_000_000_000;
    if (raw >= sec_threshold or raw <= -sec_threshold) {
        return @intCast(@divTrunc(raw, std.time.ns_per_s));
    }
    return @intCast(raw);
}

fn loadRuleProviderEntries(
    allocator: std.mem.Allocator,
    cfg: *Config,
    config_path: ?[]const u8,
) !void {
    for (cfg.rule_providers.items) |*provider| {
        provider.clearEntries(allocator);
        const resolved_path = try resolveRuleProviderPath(allocator, provider.path, config_path);
        defer allocator.free(resolved_path);

        const file = compat.fs.openFileAbsolute(resolved_path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => return error.RuleProviderFileNotFound,
                else => return err,
            }
        };
        defer file.close(compat.io());

        const content = try compat.fileReadToEndAlloc(
            file,
            allocator,
            legacy_config_bytes_max + 1,
        );
        defer allocator.free(content);
        if (content.len > legacy_config_bytes_max) {
            return error.RuleProviderFileTooLarge;
        }

        try appendRuleProviderEntriesOffline(allocator, provider, content);
        try validateRuleProviderEntries(allocator, provider);
    }
}

fn loadRuleProviderEntriesOffline(
    allocator: std.mem.Allocator,
    cfg: *Config,
    resolver: anytype,
) !void {
    for (cfg.rule_providers.items) |*provider| {
        provider.clearEntries(allocator);
        if (provider.url != null) continue;
        const content = try resolver.resolveLocal(provider.path);
        try appendRuleProviderEntriesOffline(allocator, provider, content);
    }
}

fn appendRuleProviderEntriesLegacy(
    allocator: std.mem.Allocator,
    provider: *RuleProvider,
    content: []const u8,
) !void {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const normalized = normalizeRuleProviderLine(raw_line) orelse continue;
        try appendRuleProviderEntry(allocator, provider, normalized);
    }
}

fn appendRuleProviderEntriesOffline(
    allocator: std.mem.Allocator,
    provider: *RuleProvider,
    content: []const u8,
) !void {
    const inspected = if (std.mem.startsWith(u8, content, "\xEF\xBB\xBF")) content[3..] else content;
    if (provider.behavior == .classical and looksLikeRawClassicalProvider(inspected)) {
        return appendRuleProviderEntriesLegacy(allocator, provider, inspected);
    }
    var document = yaml.parseDocument(allocator, inspected) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            if (looksLikeProviderDocument(inspected)) return error.InvalidRuleProviderDocument;
            return appendRuleProviderEntriesLegacy(allocator, provider, inspected);
        },
    };
    defer document.deinit(allocator);

    if (document != .map) {
        if (document == .array) return error.InvalidRuleProviderDocument;
        return appendRuleProviderEntriesLegacy(allocator, provider, inspected);
    }
    const payload = document.map.get("payload") orelse return error.InvalidRuleProviderDocument;
    if (payload != .array) return error.InvalidRuleProviderDocument;
    for (payload.array.items) |item| {
        if (item != .string) return error.InvalidRuleProviderDocument;
        try appendRuleProviderEntry(allocator, provider, item.string);
    }
}

fn looksLikeRawClassicalProvider(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const comma = std.mem.indexOfScalar(u8, trimmed, ',') orelse return false;
        return parseRuleType(std.mem.trim(u8, trimmed[0..comma], " \t")) != null;
    }
    return false;
}

fn looksLikeProviderDocument(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "...")) return true;
        if (trimmed[0] == '{' or hasBlockMappingIndicator(trimmed)) return true;
    }
    return false;
}

fn hasBlockMappingIndicator(line: []const u8) bool {
    for (line, 0..) |byte, index| {
        if (byte != ':') continue;
        const next = index + 1;
        if (next == line.len or line[next] == ' ' or line[next] == '\t') return true;
    }
    return false;
}

fn appendRuleProviderEntry(
    allocator: std.mem.Allocator,
    provider: *RuleProvider,
    entry_text: []const u8,
) !void {
    const entry = try allocator.dupe(u8, entry_text);
    errdefer allocator.free(entry);
    try provider.entries.append(allocator, entry);
}

fn validateOfflineProviderEntries(allocator: std.mem.Allocator, cfg: *const Config) !void {
    for (cfg.rule_providers.items) |provider| {
        if (provider.url != null) continue;
        try validateRuleProviderEntries(allocator, &provider);
    }
}

fn validateRuleProviderEntries(
    allocator: std.mem.Allocator,
    provider: *const RuleProvider,
) !void {
    for (provider.entries.items) |entry| switch (provider.behavior) {
        .classical => {
            var parsed = try parseClassicalProviderEntry(
                allocator,
                entry,
                "DIRECT",
            );
            defer parsed.deinit(allocator);
            if (!isValidClassicalProviderRule(parsed)) {
                return error.InvalidRuleProviderEntry;
            }
        },
        .domain => {
            const domain = normalizeDomainProviderEntry(entry) orelse
                return error.InvalidRuleProviderEntry;
            if (domain.len == 0 or
                std.mem.indexOfAny(u8, domain, " \t\r\n,") != null)
            {
                return error.InvalidRuleProviderEntry;
            }
        },
        .ipcidr => {
            const cidr = normalizeIpCidrProviderEntry(entry) orelse
                return error.InvalidRuleProviderEntry;
            if (!isValidRuleProviderCidr(cidr)) {
                return error.InvalidRuleProviderEntry;
            }
        },
    };
}

fn isValidClassicalProviderRule(rule: Rule) bool {
    return switch (rule.rule_type) {
        .ip_cidr, .src_ip_cidr => isValidRuleProviderCidrFamily(rule.payload, false),
        .ip_cidr6 => isValidRuleProviderCidrFamily(rule.payload, true),
        .dst_port, .src_port => isValidRuleProviderPortRange(rule.payload),
        .rule_set => false,
        .final => rule.payload.len == 0,
        else => rule.payload.len != 0,
    };
}

fn isValidRuleProviderCidr(cidr: []const u8) bool {
    return isValidRuleProviderCidrFamily(
        cidr,
        std.mem.indexOfScalar(u8, cidr, ':') != null,
    );
}

fn isValidRuleProviderCidrFamily(cidr: []const u8, ipv6: bool) bool {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return false;
    if (std.mem.indexOfScalarPos(u8, cidr, slash + 1, '/') != null) return false;
    const ip = cidr[0..slash];
    const mask_text = cidr[slash + 1 ..];
    if (ip.len == 0 or mask_text.len == 0) return false;
    const mask = std.fmt.parseInt(u8, mask_text, 10) catch return false;

    if (ipv6) {
        if (mask > 128 or std.mem.indexOfScalar(u8, ip, ':') == null) return false;
        _ = compat.net.Address.parseIp6(ip, 0) catch return false;
        return true;
    }
    if (mask > 32 or std.mem.indexOfScalar(u8, ip, ':') != null) return false;
    _ = compat.net.Address.parseIp4(ip, 0) catch return false;
    return true;
}

fn isValidRuleProviderPortRange(payload: []const u8) bool {
    var items = std.mem.splitScalar(u8, payload, ',');
    var seen = false;
    while (items.next()) |item_raw| {
        const item = std.mem.trim(u8, item_raw, " \t");
        if (item.len == 0) return false;
        seen = true;
        if (std.mem.indexOfScalar(u8, item, '-')) |dash| {
            if (std.mem.indexOfScalarPos(u8, item, dash + 1, '-') != null) return false;
            const start = std.fmt.parseInt(u16, item[0..dash], 10) catch return false;
            const end = std.fmt.parseInt(u16, item[dash + 1 ..], 10) catch return false;
            if (start == 0 or end == 0 or start > end) return false;
        } else {
            const port = std.fmt.parseInt(u16, item, 10) catch return false;
            if (port == 0) return false;
        }
    }
    return seen;
}

fn normalizeRuleProviderLine(raw_line: []const u8) ?[]const u8 {
    var line = std.mem.trim(u8, raw_line, " \t\r");
    if (line.len == 0) return null;
    if (line[0] == '#') return null;

    // Support Clash rule-provider YAML wrapper format:
    // payload:
    //   - RULE,...
    if (std.mem.eql(u8, line, "payload:")) return null;
    if (line[0] == '-') {
        line = std.mem.trim(u8, line[1..], " \t");
        if (line.len == 0) return null;
    }

    // Some providers use YAML string literals in payload arrays:
    //   - '1.1.1.0/24'
    //   - "DOMAIN-SUFFIX,example.com"
    line = stripMatchingQuotes(line);

    return line;
}

fn stripMatchingQuotes(s: []const u8) []const u8 {
    if (s.len < 2) return s;
    const first = s[0];
    const last = s[s.len - 1];
    if ((first == '\'' and last == '\'') or (first == '"' and last == '"')) {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn expandRuleSetRules(allocator: std.mem.Allocator, cfg: *Config) !void {
    var expanded = std.ArrayList(Rule).empty;
    errdefer {
        for (expanded.items) |*r| r.deinit(allocator);
        expanded.deinit(allocator);
    }

    for (cfg.rules.items) |rule| {
        if (rule.rule_type != .rule_set) {
            try appendClonedRule(allocator, &expanded, rule);
            continue;
        }

        const provider = findRuleProvider(cfg, rule.payload) orelse return error.RuleProviderNotFound;
        try appendRulesFromProvider(allocator, &expanded, provider, rule.target, rule.no_resolve);
    }

    try validateExpandedFinalRule(expanded.items);
    for (cfg.rules.items) |*r| r.deinit(allocator);
    cfg.rules.deinit(allocator);
    cfg.rules = expanded;
}

fn expandLocalRuleSetRules(allocator: std.mem.Allocator, cfg: *Config) !void {
    var expanded = std.ArrayList(Rule).empty;
    errdefer {
        for (expanded.items) |*rule| rule.deinit(allocator);
        expanded.deinit(allocator);
    }

    for (cfg.rules.items) |rule| {
        if (rule.rule_type != .rule_set) {
            try appendClonedRule(allocator, &expanded, rule);
            continue;
        }

        const provider = findRuleProvider(cfg, rule.payload) orelse return error.RuleProviderNotFound;
        if (provider.url != null) {
            try appendClonedRule(allocator, &expanded, rule);
            continue;
        }
        try appendRulesFromProvider(allocator, &expanded, provider, rule.target, rule.no_resolve);
    }

    try validateExpandedFinalRule(expanded.items);
    for (cfg.rules.items) |*rule| rule.deinit(allocator);
    cfg.rules.deinit(allocator);
    cfg.rules = expanded;
}

fn validateExpandedFinalRule(rules: []const Rule) !void {
    var final_count: u8 = 0;
    for (rules, 0..) |rule, index| {
        if (rule.rule_type != .final) continue;
        if (final_count == 1) return error.InvalidConfig;
        final_count += 1;
        if (index + 1 != rules.len) return error.InvalidConfig;
    }
    if (final_count != 1) return error.InvalidConfig;
}

fn appendRulesFromProvider(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Rule),
    provider: *const RuleProvider,
    target: []const u8,
    inherit_no_resolve: bool,
) !void {
    switch (provider.behavior) {
        .domain => {
            for (provider.entries.items) |entry| {
                const payload = normalizeDomainProviderEntry(entry) orelse continue;
                var rule = try makeOwnedRule(
                    allocator,
                    .domain_suffix,
                    payload,
                    target,
                    inherit_no_resolve,
                );
                errdefer rule.deinit(allocator);
                try out.append(allocator, rule);
            }
        },
        .ipcidr => {
            for (provider.entries.items) |entry| {
                const payload = normalizeIpCidrProviderEntry(entry) orelse continue;
                const rule_type: RuleType = if (std.mem.indexOfScalar(u8, payload, ':') != null) .ip_cidr6 else .ip_cidr;
                var rule = try makeOwnedRule(
                    allocator,
                    rule_type,
                    payload,
                    target,
                    inherit_no_resolve,
                );
                errdefer rule.deinit(allocator);
                try out.append(allocator, rule);
            }
        },
        .classical => {
            for (provider.entries.items) |entry| {
                var rule = try parseClassicalProviderEntry(allocator, entry, target);
                if (inherit_no_resolve) rule.no_resolve = true;
                errdefer rule.deinit(allocator);
                try out.append(allocator, rule);
            }
        },
    }
}

fn makeOwnedRule(
    allocator: std.mem.Allocator,
    rule_type: RuleType,
    payload: []const u8,
    target: []const u8,
    no_resolve: bool,
) !Rule {
    const payload_copy = try allocator.dupe(u8, payload);
    errdefer allocator.free(payload_copy);
    const target_copy = try allocator.dupe(u8, target);
    return .{
        .rule_type = rule_type,
        .payload = payload_copy,
        .target = target_copy,
        .no_resolve = no_resolve,
    };
}

fn parseClassicalProviderEntry(
    allocator: std.mem.Allocator,
    entry: []const u8,
    default_target: []const u8,
) !Rule {
    const trimmed = std.mem.trim(u8, entry, " \t\r");
    if (trimmed.len == 0) return error.InvalidRuleProviderEntry;

    var parts_it = std.mem.splitScalar(u8, trimmed, ',');
    const type_raw = parts_it.next() orelse return error.InvalidRuleProviderEntry;
    const type_str = std.mem.trim(u8, type_raw, " \t");
    const rule_type = parseRuleType(type_str) orelse return error.UnknownRuleType;

    var payload: []const u8 = "";
    if (rule_type != .final) {
        const payload_raw = parts_it.next() orelse return error.InvalidRuleProviderEntry;
        payload = std.mem.trim(u8, payload_raw, " \t");
        if (payload.len == 0) return error.InvalidRuleProviderEntry;
    }

    var no_resolve = false;
    while (parts_it.next()) |opt_raw| {
        const opt = std.mem.trim(u8, opt_raw, " \t");
        if (opt.len == 0) continue;
        if (std.mem.eql(u8, opt, "no-resolve")) {
            no_resolve = true;
            continue;
        }
        return error.InvalidRuleProviderEntry;
    }

    return makeOwnedRule(allocator, rule_type, payload, default_target, no_resolve);
}

fn normalizeDomainProviderEntry(entry: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, entry, " \t\r");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "DOMAIN-SUFFIX,")) {
        return std.mem.trim(u8, trimmed["DOMAIN-SUFFIX,".len..], " \t");
    }
    if (std.mem.startsWith(u8, trimmed, "DOMAIN,")) {
        return std.mem.trim(u8, trimmed["DOMAIN,".len..], " \t");
    }
    if (std.mem.startsWith(u8, trimmed, "+.")) return trimmed[2..];
    if (trimmed[0] == '.') return trimmed[1..];
    return trimmed;
}

fn normalizeIpCidrProviderEntry(entry: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, entry, " \t\r");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "IP-CIDR,")) {
        return std.mem.trim(u8, trimmed["IP-CIDR,".len..], " \t");
    }
    if (std.mem.startsWith(u8, trimmed, "IP-CIDR6,")) {
        return std.mem.trim(u8, trimmed["IP-CIDR6,".len..], " \t");
    }
    return trimmed;
}

fn resolveRuleProviderPath(
    allocator: std.mem.Allocator,
    provider_path: []const u8,
    config_path: ?[]const u8,
) ![]u8 {
    if (compat.fs.path.isAbsolute(provider_path)) {
        return try compat.fs.path.resolve(allocator, &.{provider_path});
    }

    if (config_path) |cfg_path| {
        const dir = compat.fs.path.dirname(cfg_path) orelse ".";
        return try compat.fs.path.resolve(allocator, &.{ dir, provider_path });
    }

    const cwd = try std.process.currentPathAlloc(compat.io(), allocator);
    defer allocator.free(cwd);
    return try compat.fs.path.resolve(allocator, &.{ cwd, provider_path });
}

fn findRuleProvider(cfg: *const Config, name: []const u8) ?*const RuleProvider {
    for (cfg.rule_providers.items) |*provider| {
        if (std.mem.eql(u8, provider.name, name)) return provider;
    }
    return null;
}

fn appendClonedRule(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Rule),
    source: Rule,
) !void {
    var cloned = try cloneRule(allocator, source);
    errdefer cloned.deinit(allocator);
    try out.append(allocator, cloned);
}

fn cloneRule(allocator: std.mem.Allocator, rule: Rule) !Rule {
    const payload = try allocator.dupe(u8, rule.payload);
    errdefer allocator.free(payload);
    const target = try allocator.dupe(u8, rule.target);
    return .{
        .rule_type = rule.rule_type,
        .payload = payload,
        .target = target,
        .no_resolve = rule.no_resolve,
    };
}

/// 获取默认配置目录路径 (~/.config/zc)
pub fn getDefaultConfigDir(allocator: std.mem.Allocator) !?[]const u8 {
    const home = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);
    return try compat.fs.path.join(allocator, &.{ home, ".config/zc" });
}

/// 下载结果结构体
pub const DownloadResult = struct {
    status: std.http.Status,
    body: []const u8,
};

const FetchConfigOptions = struct {
    body_bytes_max: usize = legacy_config_bytes_max,
    deadline_ms: u32 = 30_000,

    fn validate(self: FetchConfigOptions) !void {
        if (self.body_bytes_max > legacy_config_bytes_max) {
            return error.LimitsExceedContract;
        }
        if (self.deadline_ms == 0 or self.deadline_ms > 60_000) {
            return error.InvalidDownloadDeadline;
        }
    }
};

const FetchConfigEvent = union(enum) {
    response: anyerror!DownloadResult,
    deadline,
};

pub fn fetchConfig(
    allocator: std.mem.Allocator,
    url: []const u8,
) !DownloadResult {
    return fetchConfigWithOptions(allocator, url, .{});
}

fn fetchConfigWithOptions(
    allocator: std.mem.Allocator,
    url: []const u8,
    options: FetchConfigOptions,
) !DownloadResult {
    try options.validate();
    var event_buffer: [1]FetchConfigEvent = undefined;
    var events: std.Io.Queue(FetchConfigEvent) = .init(&event_buffer);
    var fetch_future = compat.io().async(
        fetchConfigWorker,
        .{ allocator, url, options, &events },
    );
    var deadline_future = compat.io().async(
        fetchConfigDeadlineWorker,
        .{ options.deadline_ms, &events },
    );

    const event = events.getOne(compat.io()) catch |err| {
        events.close(compat.io());
        fetch_future.cancel(compat.io());
        deadline_future.cancel(compat.io());
        drainFetchConfigEvents(allocator, &events, event_buffer.len);
        return err;
    };
    events.close(compat.io());
    fetch_future.cancel(compat.io());
    deadline_future.cancel(compat.io());
    drainFetchConfigEvents(allocator, &events, event_buffer.len);
    return switch (event) {
        .response => |response| response,
        .deadline => error.DownloadTimeout,
    };
}

fn drainFetchConfigEvents(
    allocator: std.mem.Allocator,
    events: *std.Io.Queue(FetchConfigEvent),
    event_count_max: usize,
) void {
    var event_count: usize = 0;
    while (event_count < event_count_max) : (event_count += 1) {
        const event = events.getOneUncancelable(compat.io()) catch |err| switch (err) {
            error.Closed => return,
        };
        switch (event) {
            .response => |response| {
                if (response) |value| allocator.free(value.body) else |_| {}
            },
            .deadline => {},
        }
    }
}

fn fetchConfigWorker(
    allocator: std.mem.Allocator,
    url: []const u8,
    options: FetchConfigOptions,
    events: *std.Io.Queue(FetchConfigEvent),
) void {
    const response = fetchConfigHTTP(allocator, url, options);
    events.putOne(compat.io(), .{ .response = response }) catch {
        if (response) |value| allocator.free(value.body) else |_| {}
    };
}

fn fetchConfigDeadlineWorker(
    deadline_ms: u32,
    events: *std.Io.Queue(FetchConfigEvent),
) void {
    std.Io.sleep(
        compat.io(),
        .fromMilliseconds(deadline_ms),
        .awake,
    ) catch return;
    events.putOne(compat.io(), .deadline) catch {};
}

fn fetchConfigHTTP(
    allocator: std.mem.Allocator,
    url: []const u8,
    options: FetchConfigOptions,
) !DownloadResult {
    var client = std.http.Client{ .allocator = allocator, .io = compat.io() };
    defer client.deinit();

    var proxy_arena = try initDefaultProxyEnv(allocator, &client);
    defer proxy_arena.deinit();

    const storage_size = options.body_bytes_max + 1;
    const response_storage = try allocator.alloc(u8, storage_size);
    var response_storage_owned = true;
    defer if (response_storage_owned) allocator.free(response_storage);
    var response_writer: std.Io.Writer = .fixed(response_storage);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_writer,
        .headers = .{
            .user_agent = .{ .override = "clash" },
            .accept_encoding = .{ .override = "identity" },
        },
    }) catch |err| {
        if (err == error.WriteFailed and
            response_writer.buffered().len == storage_size)
        {
            return error.ConfigTooLarge;
        }
        if (shouldUseCurlFallback(url)) {
            if (fetchConfigWithCurl(allocator, url, options)) |fallback| {
                return fallback;
            } else |fallback_error| switch (fallback_error) {
                error.ConfigTooLarge, error.DownloadTimeout => return fallback_error,
                else => {},
            }
        }
        std.debug.print("Failed to download config: {s}\n", .{@errorName(err)});
        return err;
    };

    if (response_writer.buffered().len > options.body_bytes_max) {
        return error.ConfigTooLarge;
    }
    if (result.status == .bad_request and shouldUseCurlFallback(url)) {
        if (fetchConfigWithCurl(allocator, url, options)) |fallback| {
            return fallback;
        } else |fallback_error| switch (fallback_error) {
            error.ConfigTooLarge, error.DownloadTimeout => return fallback_error,
            else => {},
        }
    }

    const body = try allocator.realloc(
        response_storage,
        response_writer.buffered().len,
    );
    response_storage_owned = false;
    return .{ .status = result.status, .body = body };
}

fn initDefaultProxyEnv(allocator: std.mem.Allocator, client: *std.http.Client) !std.heap.ArenaAllocator {
    var proxy_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer proxy_arena.deinit();
    if (compat.environMap()) |environ_map| {
        try client.initDefaultProxies(proxy_arena.allocator(), environ_map);
    }
    return proxy_arena;
}

fn shouldUseCurlFallback(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "https")) return false;
    const environ_map = compat.environMap() orelse return false;
    return hasEnv(environ_map, "https_proxy") or
        hasEnv(environ_map, "HTTPS_PROXY") or
        hasEnv(environ_map, "all_proxy") or
        hasEnv(environ_map, "ALL_PROXY");
}

fn hasEnv(environ_map: *const std.process.Environ.Map, key: []const u8) bool {
    const value = environ_map.get(key) orelse return false;
    return value.len > 0;
}

fn fetchConfigWithCurl(
    allocator: std.mem.Allocator,
    url: []const u8,
    options: FetchConfigOptions,
) !DownloadResult {
    var deadline_seconds_buffer: [16]u8 = undefined;
    const deadline_seconds = try std.fmt.bufPrint(
        &deadline_seconds_buffer,
        "{d}",
        .{@max(1, (options.deadline_ms + 999) / 1000)},
    );
    var body_bytes_max_buffer: [32]u8 = undefined;
    const body_bytes_max = try std.fmt.bufPrint(
        &body_bytes_max_buffer,
        "{d}",
        .{options.body_bytes_max},
    );
    const result = std.process.run(allocator, compat.io(), .{
        .argv = &.{
            "curl",
            "--location",
            "--silent",
            "--show-error",
            "--max-time",
            deadline_seconds,
            "--max-filesize",
            body_bytes_max,
            "--user-agent",
            "clash",
            "--header",
            "accept-encoding: identity",
            "--write-out",
            "\n%{http_code}",
            url,
        },
        .stdout_limit = .limited(options.body_bytes_max + 4),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(options.deadline_ms),
        } },
    }) catch |err| switch (err) {
        error.StreamTooLong => return error.ConfigTooLarge,
        error.Timeout => return error.DownloadTimeout,
        else => return err,
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {},
            28 => return error.DownloadTimeout,
            63 => return error.ConfigTooLarge,
            else => return error.DownloadFailed,
        },
        else => return error.DownloadFailed,
    }

    const parsed = try parseCurlFetchResult(allocator, result.stdout);
    return parsed;
}

fn parseCurlFetchResult(allocator: std.mem.Allocator, stdout: []const u8) !DownloadResult {
    if (stdout.len < 4 or stdout[stdout.len - 4] != '\n') return error.DownloadFailed;
    const status_text = stdout[stdout.len - 3 ..];
    const status_code = std.fmt.parseInt(u16, status_text, 10) catch return error.DownloadFailed;
    const body = try allocator.dupe(u8, stdout[0 .. stdout.len - 4]);
    return .{
        .status = @enumFromInt(status_code),
        .body = body,
    };
}

/// 归一化配置 key：剥掉一个尾部 `.yaml` 后缀（`smoke.yaml` -> `smoke`）。
/// download/use/update/订阅查询必须共用同一套归一化，否则
/// `config download -n smoke.yaml` 之后 `config use smoke.yaml` 会因
/// key 不一致而 CONFIG_NOT_FOUND（store 不剥、lookup 剥）。
pub fn normalizeConfigKey(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".yaml") and name.len > ".yaml".len) {
        return name[0 .. name.len - ".yaml".len];
    }
    return name;
}

fn normalizeManagedConfigKey(name: []const u8) ![]const u8 {
    const key = normalizeConfigKey(name);
    if (!config_catalog.isManagedKey(key)) return error.InvalidConfigKey;
    return key;
}

/// 下载结果（key/path 均为 caller 所有）。
pub const DownloadOutcome = struct {
    key: []const u8,
    path: []const u8,
    /// 是否被设为默认（active）配置。
    set_default: bool,

    pub fn deinit(self: *DownloadOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.path);
    }
};

const legacy_config_bytes_max: usize = 16 * 1024 * 1024;

const ConfigFilePublishOutcome = union(enum) {
    committed,
    durability_uncertain: anyerror,
};

fn readConfigFileIfPresent(
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    name: []const u8,
) !?[]u8 {
    const stat = directory.statFile(
        compat.io(),
        name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidConfigFile;
    const file = try directory.openFile(
        compat.io(),
        name,
        .{ .follow_symlinks = false },
    );
    defer file.close(compat.io());
    return try compat.fileReadToEndAlloc(
        file,
        allocator,
        legacy_config_bytes_max,
    );
}

fn publishConfigFile(
    directory: std.Io.Dir,
    name: []const u8,
    bytes: []const u8,
) !ConfigFilePublishOutcome {
    if (bytes.len > legacy_config_bytes_max) return error.ConfigTooLarge;
    const permissions = std.Io.File.Permissions.fromMode(0o600);
    var atomic = try directory.createFileAtomic(
        compat.io(),
        name,
        .{ .replace = true, .permissions = permissions },
    );
    defer atomic.deinit(compat.io());
    try atomic.file.setPermissions(compat.io(), permissions);
    try compat.fileWriteAll(atomic.file, bytes);
    try atomic.file.sync(compat.io());
    const parent = try directory.openFile(
        compat.io(),
        ".",
        .{ .allow_directory = true },
    );
    defer parent.close(compat.io());
    try atomic.replace(compat.io());
    parent.sync(compat.io()) catch |err|
        return .{ .durability_uncertain = err };
    return .committed;
}

fn rollbackConfigFile(
    directory: std.Io.Dir,
    name: []const u8,
    previous: ?[]const u8,
) !void {
    if (previous) |bytes| {
        switch (try publishConfigFile(directory, name, bytes)) {
            .committed => return,
            .durability_uncertain => return error.ConfigRollbackDurabilityUncertain,
        }
    }
    directory.deleteFile(compat.io(), name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const parent = try directory.openFile(
        compat.io(),
        ".",
        .{ .allow_directory = true },
    );
    defer parent.close(compat.io());
    parent.sync(compat.io()) catch
        return error.ConfigRollbackDurabilityUncertain;
}

/// 下载配置文件从 URL 并保存到 configs/ 目录
/// name: 可选的自定义 key，为 null 则生成 8 位随机 key
/// set_default: `-d`，下载后设为默认（active）；当前没有 active 时首个下载也会设为 active
/// 文本输出经 out 渲染（stdout）；JSON envelope 由调用方负责。
pub fn downloadConfig(
    allocator: std.mem.Allocator,
    url: []const u8,
    name: ?[]const u8,
    set_default: bool,
    out: *cli_output.Output,
) !DownloadOutcome {
    const normalized_name = if (name) |value|
        try normalizeManagedConfigKey(value)
    else
        null;

    const fetch_result = try fetchConfig(allocator, url);
    defer allocator.free(fetch_result.body);

    if (fetch_result.status != .ok) {
        try out.note("Failed to download config: HTTP {d}\n", .{@intFromEnum(fetch_result.status)});
        return error.DownloadFailed;
    }

    var meta_data = try meta.load(allocator);
    defer meta_data.deinit();

    // 确保 configs/ 目录存在
    try meta.ensureConfigsDir(allocator);

    const configs_dir = try meta.getConfigsDir(allocator) orelse {
        try out.note("Could not determine config directory\n", .{});
        return error.NoConfigDir;
    };
    defer allocator.free(configs_dir);

    // 确定 key（与 switchConfig/updateConfig 同一套归一化：`-n smoke.yaml` -> key "smoke"）
    const key = if (normalized_name) |value|
        try allocator.dupe(u8, value)
    else
        try meta.generateKey(allocator);
    errdefer allocator.free(key);
    std.debug.assert(config_catalog.isManagedKey(key));

    // 保存文件到 configs/{key}.yaml
    const yaml_filename = try std.fmt.allocPrint(allocator, "{s}.yaml", .{key});
    defer allocator.free(yaml_filename);

    const config_path = try compat.fs.path.join(allocator, &.{ configs_dir, yaml_filename });
    defer allocator.free(config_path);

    var cm = meta.ConfigMeta.init(allocator);
    cm.url = try allocator.dupe(u8, url);

    // 从 URL 参数中提取 filename 等
    var url_params = try meta.parseUrlParams(allocator, url);
    if (url_params.fetchRemove("filename")) |filename_entry| {
        cm.filename = filename_entry.value;
        allocator.free(filename_entry.key);
    }
    // 转移所有权：释放 init() 创建的空 HashMap，替换为解析结果
    cm.params.deinit();
    cm.params = url_params;

    // load() may have discovered an existing YAML before this replacement.
    // Reuse its key while replacing the associated metadata value.
    const gop = try meta_data.configs.getOrPut(key);
    if (gop.found_existing) {
        gop.value_ptr.deinit(allocator);
    } else {
        gop.key_ptr.* = try allocator.dupe(u8, key);
    }
    gop.value_ptr.* = cm;

    // 设为默认（active）：显式 `-d`，或当前还没有 active 配置。
    const make_active = set_default or meta_data.active == null;
    if (make_active) {
        if (meta_data.active) |old| allocator.free(old);
        meta_data.active = try allocator.dupe(u8, key);
    }

    const configs_directory = try compat.fs.openDirAbsolute(configs_dir, .{});
    defer configs_directory.close(compat.io());
    const previous_config = try readConfigFileIfPresent(
        allocator,
        configs_directory,
        yaml_filename,
    );
    defer if (previous_config) |bytes| allocator.free(bytes);
    switch (try publishConfigFile(
        configs_directory,
        yaml_filename,
        fetch_result.body,
    )) {
        .committed => {},
        .durability_uncertain => |err| try out.note(
            "Config is visible but directory sync failed: {s}\n",
            .{@errorName(err)},
        ),
    }
    meta.saveVisible(allocator, &meta_data) catch |save_error| {
        rollbackConfigFile(
            configs_directory,
            yaml_filename,
            previous_config,
        ) catch |rollback_error| return rollback_error;
        return save_error;
    };

    const display = meta.getDisplayName(&cm, key);
    if (out.mode == .text) {
        try out.print("Config downloaded: {s} (key: {s})\n", .{ display, key });
        try out.print("Config saved to: {s}\n", .{config_path});
        if (make_active) {
            try out.print("Config set as default: {s}\n", .{key});
        }
        try out.flush();
    }

    return .{
        .key = key,
        .path = try allocator.dupe(u8, config_path),
        .set_default = make_active,
    };
}

/// 获取当前激活的配置 key（从 meta.json）
pub fn getCurrentConfigName(allocator: std.mem.Allocator) !?[]const u8 {
    var meta_data = try meta.load(allocator);
    defer meta_data.deinit();
    const active = meta_data.active orelse return null;
    const configs_directory = try meta.getConfigsDir(allocator) orelse
        return error.NoConfigDir;
    defer allocator.free(configs_directory);
    const active_path = try activeConfigPathInDirectory(
        allocator,
        configs_directory,
        active,
    );
    allocator.free(active_path);
    return try allocator.dupe(u8, active);
}

/// 解析运行时配置 key：
/// 1) 显式路径只按自身推导；unmanaged 路径不得回退到 active
/// 2) 无显式路径时回退到 meta.active
/// 3) 再从默认配置路径推导
pub fn resolveRuntimeConfigKey(allocator: std.mem.Allocator, explicit_config_path: ?[]const u8) !?[]const u8 {
    if (explicit_config_path) |path| {
        return try inferConfigKeyFromPath(allocator, path);
    }

    if (try getCurrentConfigName(allocator)) |active| {
        return active;
    }

    if (try getDefaultConfigPath(allocator)) |default_path| {
        defer allocator.free(default_path);
        return try inferConfigKeyFromPath(allocator, default_path);
    }

    return null;
}

/// 获取运行时可用的持久化 override 脚本（按配置 key）
pub fn getPersistedOverrideScriptForRuntime(allocator: std.mem.Allocator, explicit_config_path: ?[]const u8) !?[]u8 {
    const key = if (explicit_config_path) |path|
        (try inferConfigKeyFromPath(allocator, path)) orelse return null
    else
        (try resolveRuntimeConfigKey(allocator, null)) orelse return null;
    defer allocator.free(key);

    var meta_data = try meta.load(allocator);
    defer meta_data.deinit();

    const cm = meta_data.configs.get(key) orelse return null;
    const script_path = cm.override_script orelse return null;
    return try allocator.dupe(u8, script_path);
}

/// 获取“当前配置”绑定的持久化 override 脚本
pub fn getPersistedOverrideScriptForCurrentConfig(allocator: std.mem.Allocator) !?[]u8 {
    return getPersistedOverrideScriptForRuntime(allocator, null);
}

/// 获取 override 脚本托管目录（~/.config/zc/override）
pub fn getOverrideScriptsDir(allocator: std.mem.Allocator) !?[]const u8 {
    const config_dir = try getDefaultConfigDir(allocator) orelse return null;
    defer allocator.free(config_dir);
    return try compat.fs.path.join(allocator, &.{ config_dir, "override" });
}

/// 为当前配置复制 override 脚本到托管目录，返回托管脚本绝对路径
pub fn copyOverrideScriptForCurrentConfig(allocator: std.mem.Allocator, script_path: []const u8) ![]u8 {
    const key = (try resolveRuntimeConfigKey(allocator, null)) orelse return error.NoActiveConfig;
    defer allocator.free(key);

    const abs_script = try toAbsoluteNormalizedPath(allocator, script_path);
    defer allocator.free(abs_script);

    var file = compat.fs.openFileAbsolute(abs_script, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    file.close(compat.io());

    const overrides_dir = (try getOverrideScriptsDir(allocator)) orelse return error.NoConfigDir;
    defer allocator.free(overrides_dir);

    compat.fs.cwd().makePath(overrides_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const managed_path = try makeManagedOverrideScriptPathForKey(allocator, key, abs_script, overrides_dir);
    errdefer allocator.free(managed_path);

    try compat.fs.copyFileAbsolute(abs_script, managed_path, .{});
    return managed_path;
}

/// 将已存在的脚本路径绑定为当前配置持久化 override
pub fn persistOverrideScriptPathForCurrentConfig(allocator: std.mem.Allocator, script_path: []const u8) !void {
    const key = (try resolveRuntimeConfigKey(allocator, null)) orelse return error.NoActiveConfig;
    defer allocator.free(key);

    const abs_script = try toAbsoluteNormalizedPath(allocator, script_path);
    defer allocator.free(abs_script);

    var file = compat.fs.openFileAbsolute(abs_script, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    file.close(compat.io());

    const overrides_dir = (try getOverrideScriptsDir(allocator)) orelse return error.NoConfigDir;
    defer allocator.free(overrides_dir);

    var meta_data = try meta.load(allocator);
    defer meta_data.deinit();

    const cm = try ensureConfigMetaEntry(allocator, &meta_data, key);
    if (cm.override_script) |old| {
        const should_delete = isManagedOverrideScriptPath(allocator, old, overrides_dir) catch false;
        if (should_delete and !std.mem.eql(u8, old, abs_script)) {
            compat.fs.deleteFileAbsolute(old) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }
    if (cm.override_script) |old| allocator.free(old);
    cm.override_script = try allocator.dupe(u8, abs_script);

    try meta.saveVisible(allocator, &meta_data);
}

/// 为“当前配置”设置持久化 override 脚本，返回托管脚本路径
pub fn setPersistedOverrideScriptForCurrentConfig(allocator: std.mem.Allocator, script_path: []const u8) ![]u8 {
    const managed_path = try copyOverrideScriptForCurrentConfig(allocator, script_path);
    errdefer {
        compat.fs.deleteFileAbsolute(managed_path) catch {};
        allocator.free(managed_path);
    }

    try persistOverrideScriptPathForCurrentConfig(allocator, managed_path);
    return managed_path;
}

/// 清除“当前配置”的持久化 override 脚本
pub fn clearPersistedOverrideScriptForCurrentConfig(allocator: std.mem.Allocator) !bool {
    const key = (try resolveRuntimeConfigKey(allocator, null)) orelse return error.NoActiveConfig;
    defer allocator.free(key);

    var meta_data = try meta.load(allocator);
    defer meta_data.deinit();

    const cm = meta_data.configs.getPtr(key) orelse return false;

    const overrides_dir = (try getOverrideScriptsDir(allocator)) orelse return error.NoConfigDir;
    defer allocator.free(overrides_dir);

    if (cm.override_script) |old| {
        const should_delete = isManagedOverrideScriptPath(allocator, old, overrides_dir) catch false;
        if (should_delete) {
            compat.fs.deleteFileAbsolute(old) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        allocator.free(old);
        cm.override_script = null;
        try meta.saveVisible(allocator, &meta_data);
        return true;
    }
    return false;
}

fn ensureConfigMetaEntry(allocator: std.mem.Allocator, meta_data: *meta.MetaData, key: []const u8) !*meta.ConfigMeta {
    if (!meta_data.configs.contains(key)) {
        const key_owned = try allocator.dupe(u8, key);
        errdefer allocator.free(key_owned);

        var cm = meta.ConfigMeta.init(allocator);
        errdefer cm.deinit(allocator);

        try meta_data.configs.put(key_owned, cm);
    }
    return meta_data.configs.getPtr(key).?;
}

fn makeManagedOverrideScriptPathForKey(
    allocator: std.mem.Allocator,
    key: []const u8,
    source_abs_path: []const u8,
    overrides_dir: []const u8,
) ![]u8 {
    const ext = compat.fs.path.extension(source_abs_path);
    const ts = compat.nanoTimestamp();
    const filename = try std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ key, ts, ext });
    defer allocator.free(filename);
    return try compat.fs.path.join(allocator, &.{ overrides_dir, filename });
}

fn isManagedOverrideScriptPath(
    allocator: std.mem.Allocator,
    script_path: []const u8,
    overrides_dir: []const u8,
) !bool {
    const resolved_script = try compat.fs.path.resolve(allocator, &.{script_path});
    defer allocator.free(resolved_script);
    const resolved_overrides = try compat.fs.path.resolve(allocator, &.{overrides_dir});
    defer allocator.free(resolved_overrides);
    return isPathWithinDir(resolved_script, resolved_overrides);
}

pub fn inferConfigKeyFromPath(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const configs_dir = try meta.getConfigsDir(allocator) orelse return null;
    defer allocator.free(configs_dir);

    return try inferConfigKeyFromPathWithConfigsDir(allocator, path, configs_dir);
}

fn inferConfigKeyFromPathWithConfigsDir(allocator: std.mem.Allocator, path: []const u8, configs_dir: []const u8) !?[]const u8 {
    const resolved_path = try toResolvedPathForKey(allocator, path);
    defer allocator.free(resolved_path);

    const resolved_configs_dir = try toResolvedPathForKey(allocator, configs_dir);
    defer allocator.free(resolved_configs_dir);

    if (!isPathWithinDir(resolved_path, resolved_configs_dir)) return null;

    const basename = compat.fs.path.basename(resolved_path);
    if (!std.mem.endsWith(u8, basename, ".yaml")) return null;
    if (basename.len <= ".yaml".len) return null;

    return try allocator.dupe(u8, basename[0 .. basename.len - ".yaml".len]);
}

fn isPathWithinDir(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len) return true;
    return path[dir.len] == compat.fs.path.sep;
}

fn toAbsoluteNormalizedPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (compat.fs.path.isAbsolute(path)) {
        return compat.fs.path.resolve(allocator, &.{path});
    }

    const cwd = try std.process.currentPathAlloc(compat.io(), allocator);
    defer allocator.free(cwd);
    return compat.fs.path.resolve(allocator, &.{ cwd, path });
}

fn toResolvedPathForKey(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const abs_path = try toAbsoluteNormalizedPath(allocator, path);
    defer allocator.free(abs_path);

    return compat.fs.realpathAlloc(allocator, abs_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try allocator.dupe(u8, abs_path),
    };
}

/// 获取订阅 URL（从 meta.json）
pub fn getSubscriptionUrl(allocator: std.mem.Allocator, config_name: []const u8) !?[]const u8 {
    // config_name 可能带 .yaml 后缀
    const key = try normalizeManagedConfigKey(config_name);

    var meta_data = try meta.load(allocator);
    defer meta_data.deinit();

    if (meta_data.configs.get(key)) |cm| {
        if (cm.url) |url| {
            return try allocator.dupe(u8, url);
        }
    }
    return null;
}

/// 更新配置文件（从 meta.json 中保存的订阅 URL）。
/// 进度文本走 out.note（stderr）；最终结果文本模式走 out.print（stdout）。
/// 没有订阅 URL 返回 error.NoSubscriptionUrl；成功返回 key（caller 释放）。
pub fn updateConfig(allocator: std.mem.Allocator, config_name: []const u8, out: *cli_output.Output) ![]const u8 {
    // config_name 可能带 .yaml 后缀
    const key = try normalizeManagedConfigKey(config_name);

    const url = (try getSubscriptionUrl(allocator, key)) orelse return error.NoSubscriptionUrl;
    defer allocator.free(url);

    try out.note("Updating from: {s}\n", .{url});

    // 重新下载但使用相同的 key
    const fetch_result = try fetchConfig(allocator, url);
    defer allocator.free(fetch_result.body);

    if (fetch_result.status != .ok) {
        try out.note("Failed to download config: HTTP {d}\n", .{@intFromEnum(fetch_result.status)});
        return error.DownloadFailed;
    }

    try meta.ensureConfigsDir(allocator);

    const configs_dir = try meta.getConfigsDir(allocator) orelse return error.NoConfigDir;
    defer allocator.free(configs_dir);

    const yaml_filename = try std.fmt.allocPrint(allocator, "{s}.yaml", .{key});
    defer allocator.free(yaml_filename);

    const config_path = try compat.fs.path.join(allocator, &.{ configs_dir, yaml_filename });
    defer allocator.free(config_path);

    const file = try compat.fs.createFileAbsolute(config_path, .{});
    defer file.close(compat.io());
    try compat.fileWriteAll(file, fetch_result.body);

    if (out.mode == .text) {
        try out.print("Config updated: {s}\n", .{config_path});
        try out.flush();
    } else {
        try out.note("Config updated: {s}\n", .{config_path});
    }

    return try allocator.dupe(u8, key);
}

/// 列出所有可用的配置文件。
/// 文本模式经 out.print 走 stdout；JSON 模式经 out.success 输出单个 envelope。
pub fn listConfigs(allocator: std.mem.Allocator, out: *cli_output.Output) !void {
    var meta_data = try meta.load(allocator);
    defer meta_data.deinit();

    const configs_dir = try meta.getConfigsDir(allocator) orelse return error.NoConfigDir;
    allocator.free(configs_dir);

    if (out.mode == .json) {
        const Entry = struct {
            name: []const u8,
            display: []const u8,
            active: bool,
        };
        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(allocator);

        var it = meta_data.configs.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const cm = entry.value_ptr;
            const is_active = if (meta_data.active) |active|
                std.mem.eql(u8, active, key)
            else
                false;
            try entries.append(allocator, .{
                .name = key,
                .display = meta.getDisplayName(cm, key),
                .active = is_active,
            });
        }

        try out.success(.{ .configs = entries.items, .active = meta_data.active });
        return;
    }

    try out.print("Available configs:\n\n", .{});

    var count: usize = 0;
    var it = meta_data.configs.iterator();
    while (it.next()) |entry| {
        count += 1;
        const key = entry.key_ptr.*;
        const cm = entry.value_ptr;
        const display = meta.getDisplayName(cm, key);
        const is_active = if (meta_data.active) |active|
            std.mem.eql(u8, active, key)
        else
            false;

        if (is_active) {
            try out.print("  * {s}", .{display});
        } else {
            try out.print("    {s}", .{display});
        }

        // 如果 display 不等于 key，显示 key
        if (!std.mem.eql(u8, display, key)) {
            try out.print(" ({s})", .{key});
        }

        if (is_active) {
            try out.print(" (active)", .{});
        }

        try out.print("\n", .{});
    }

    if (count == 0) {
        try out.print("  (no config files found)\n", .{});
    } else {
        try out.print("\nUse 'zc config use <key>' to switch config\n", .{});
    }
    try out.flush();
}

/// 切换配置文件（更新 meta.json 的 active 字段）。
/// 决策 D8：绝不自动 apply 到运行中的 daemon，文本模式提示下一步。
/// 找不到目标返回 error.ConfigNotFound（envelope 由调用方渲染）。
pub fn switchConfig(allocator: std.mem.Allocator, target: []const u8, out: *cli_output.Output) !void {
    // target 可能带 .yaml 后缀
    const key = try normalizeManagedConfigKey(target);

    var meta_data = try meta.load(allocator);
    defer meta_data.deinit();

    // 验证 key 存在于 meta 中
    if (!meta_data.configs.contains(key)) {
        // 尝试在 configs/ 目录中查找对应文件
        const configs_dir = try meta.getConfigsDir(allocator) orelse return error.ConfigNotFound;
        defer allocator.free(configs_dir);

        const yaml_name = try std.fmt.allocPrint(allocator, "{s}.yaml", .{key});
        defer allocator.free(yaml_name);

        const file_path = try compat.fs.path.join(allocator, &.{ configs_dir, yaml_name });
        defer allocator.free(file_path);

        compat.fs.accessAbsolute(file_path, .{}) catch return error.ConfigNotFound;

        // 文件存在但不在 meta 中，添加 entry
        const key_owned = try allocator.dupe(u8, key);
        const cm = meta.ConfigMeta.init(allocator);
        try meta_data.configs.put(key_owned, cm);
    }

    // 更新 active
    if (meta_data.active) |old| allocator.free(old);
    meta_data.active = try allocator.dupe(u8, key);

    try meta.saveVisible(allocator, &meta_data);

    if (out.mode == .text) {
        const display = if (meta_data.configs.getPtr(key)) |cm|
            meta.getDisplayName(cm, key)
        else
            key;
        try out.print("Switched to config: {s}\n", .{display});
        try out.print("Run `zc reload` (or `zc restart`) to apply it to a running daemon\n", .{});
        try out.flush();
    }
}

/// `config delete` 的结果（key 为 caller 所有，was_active 供 JSON 渲染）。
pub const DeleteOutcome = struct {
    key: []const u8,
    /// 删除的是当前 active 配置时为 true（调用方据此提示下一步）。
    was_active: bool,

    pub fn deinit(self: *DeleteOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

/// 删除配置：移除 configs/{key}.yaml、meta.json 中的 entry，以及该配置
/// 托管的持久化 override 脚本（仅当脚本位于托管 override 目录内 —— 用户
/// 自己路径在配置目录外的脚本绝不删）。
/// 找不到目标（既不在 meta 中，configs/ 下也没有对应文件）返回
/// error.ConfigNotFound（envelope 由调用方渲染）。
/// 删除当前 active 配置时清空 meta.active —— 运行中的 daemon 已把配置载入
/// 内存，不受影响，直到下次 reload/restart（届时回退到内置默认）。
pub fn deleteConfig(allocator: std.mem.Allocator, target: []const u8, out: *cli_output.Output) !DeleteOutcome {
    // target 可能带 .yaml 后缀（与 use/update/download 共用同一套归一化）。
    const key = try normalizeManagedConfigKey(target);

    const configs_dir = try meta.getConfigsDir(allocator) orelse return error.ConfigNotFound;
    defer allocator.free(configs_dir);

    const yaml_name = try std.fmt.allocPrint(allocator, "{s}.yaml", .{key});
    defer allocator.free(yaml_name);

    const file_path = try compat.fs.path.join(allocator, &.{ configs_dir, yaml_name });
    defer allocator.free(file_path);

    var meta_data = try meta.load(allocator);
    defer meta_data.deinit();

    const in_meta = meta_data.configs.contains(key);
    const file_exists = if (compat.fs.accessAbsolute(file_path, .{})) |_| true else |_| false;

    // 既无 meta entry 又无文件 —— 没有可删的东西。
    if (!in_meta and !file_exists) return error.ConfigNotFound;

    // 1) 删除托管的持久化 override 脚本（失败不阻断后续删除：脚本只是缓存，
    //    残留也不致命，而配置删除本身必须推进）。
    if (meta_data.configs.getPtr(key)) |cm| {
        if (cm.override_script) |script_path| {
            if (try getOverrideScriptsDir(allocator)) |overrides_dir| {
                defer allocator.free(overrides_dir);
                const managed = isManagedOverrideScriptPath(allocator, script_path, overrides_dir) catch false;
                if (managed) compat.fs.deleteFileAbsolute(script_path) catch {};
            }
        }
    }

    // 2) 删除 yaml 文件（删除前已被别的进程删掉则视为成功）。
    if (file_exists) {
        compat.fs.deleteFileAbsolute(file_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    // 3) 从 meta 移除 entry（key 与 value 都需释放，否则泄漏）。
    if (meta_data.configs.fetchRemove(key)) |kv| {
        allocator.free(kv.key);
        var removed = kv.value;
        removed.deinit(allocator);
    }

    // 4) 删的是 active？清空 active（避免悬空指针指向已删配置）。
    var was_active = false;
    if (meta_data.active) |active| {
        if (std.mem.eql(u8, active, key)) {
            was_active = true;
            allocator.free(active);
            meta_data.active = null;
        }
    }

    try meta.saveVisible(allocator, &meta_data);

    if (out.mode == .text) {
        try out.print("Deleted config: {s}\n", .{key});
        if (was_active) {
            try out.print("This was the active config; run `zc config use <name>` to pick another\n", .{});
        }
        try out.flush();
    }

    return .{ .key = try allocator.dupe(u8, key), .was_active = was_active };
}

test "managed config keeps final routing terminal and fail closed" {
    const allocator = std.testing.allocator;
    const base =
        \\mixed-port: 7890
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
    ;
    var fail_closed = try parseDocument(allocator, base);
    defer fail_closed.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        fail_closed.rules.items.len,
    );
    try std.testing.expectEqual(
        RuleType.final,
        fail_closed.rules.items[0].rule_type,
    );
    try std.testing.expectEqualStrings(
        "REJECT",
        fail_closed.rules.items[0].target,
    );
    var legacy_fail_closed = try parse(allocator,
        \\mixed-port: 7890
        \\rules:
        \\  - DOMAIN,example.com,DIRECT
    );
    defer legacy_fail_closed.deinit();
    try std.testing.expectEqual(
        RuleType.final,
        legacy_fail_closed.rules.items[1].rule_type,
    );
    try std.testing.expectEqualStrings(
        "REJECT",
        legacy_fail_closed.rules.items[1].target,
    );
    var legacy_empty = try parse(allocator,
        \\mixed-port: 7890
        \\rules: []
    );
    defer legacy_empty.deinit();
    try std.testing.expectEqual(
        RuleType.final,
        legacy_empty.rules.items[0].rule_type,
    );
    try std.testing.expectEqualStrings(
        "REJECT",
        legacy_empty.rules.items[0].target,
    );
    try std.testing.expectError(
        error.InvalidConfig,
        parse(allocator,
            \\mixed-port: 7890
            \\rules:
            \\  - 123
        ),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        parse(allocator,
            \\mixed-port: 7890
            \\rules: null
        ),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        parseDocument(allocator,
            \\mixed-port: 7890
            \\rules:
            \\  - MATCH,DIRECT
            \\  - MATCH,REJECT
        ),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        parseDocument(allocator,
            \\mixed-port: 7890
            \\rules:
            \\  - MATCH,DIRECT
            \\  - DOMAIN,example.com,REJECT
        ),
    );
    var valid = try parseDocument(allocator,
        \\mixed-port: 7890
        \\rules:
        \\  - DOMAIN,example.com,REJECT
        \\  - MATCH,DIRECT
    );
    valid.deinit();
}

test "config parsing" {
    const allocator = std.testing.allocator;

    const yaml_config =
        \\port: 1080
        \\proxies:
        \\  - name: Proxy1
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: test
        \\rules:
        \\  - DOMAIN,google.com,Proxy1
        \\  - MATCH,DIRECT
    ;

    var config = try parse(allocator, yaml_config);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 1080), config.port);
    try std.testing.expectEqual(@as(usize, 1), config.proxies.items.len);
    try std.testing.expectEqual(@as(usize, 2), config.rules.items.len);
}

test "config parsing supports rule-providers and rule-set" {
    const allocator = std.testing.allocator;

    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\    server: ""
        \\    port: 0
        \\rule-providers:
        \\  directset:
        \\    type: file
        \\    behavior: domain
        \\    path: /tmp/directset.txt
        \\    interval: 3600
        \\rules:
        \\  - RULE-SET,directset,DIRECT
        \\  - MATCH,DIRECT
    ;

    var cfg = try parse(allocator, yaml_config);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.rule_providers.items.len);
    try std.testing.expectEqualStrings("directset", cfg.rule_providers.items[0].name);
    try std.testing.expectEqual(@as(RuleType, .rule_set), cfg.rules.items[0].rule_type);
    try std.testing.expectEqualStrings("directset", cfg.rules.items[0].payload);
}

test "C6: idle session tunables default when absent" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\    server: ""
        \\    port: 0
    ;
    var cfg = try parse(allocator, yaml_config);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(i64, 30), cfg.idle_session_check_interval);
    try std.testing.expectEqual(@as(i64, 30), cfg.idle_session_timeout);
    try std.testing.expectEqual(@as(u32, 0), cfg.min_idle_session);
}

test "C6: idle session tunables parsed from YAML" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\idle-session-check-interval: 60
        \\idle-session-timeout: 45
        \\min-idle-session: 3
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\    server: ""
        \\    port: 0
    ;
    var cfg = try parse(allocator, yaml_config);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(i64, 60), cfg.idle_session_check_interval);
    try std.testing.expectEqual(@as(i64, 45), cfg.idle_session_timeout);
    try std.testing.expectEqual(@as(u32, 3), cfg.min_idle_session);
}

fn testTmpPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(compat.io(), allocator);
    defer allocator.free(cwd);
    return try compat.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], name });
}

test "rule-provider publication preserves the last valid cache" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const existing = try tmp.dir.createFile(compat.io(), "rules.yaml", .{});
    try compat.fileWriteAll(existing, "payload:\n  - old.example\n");
    existing.close(compat.io());
    const path = try testTmpPathAlloc(allocator, &tmp, "rules.yaml");
    defer allocator.free(path);
    const provider = RuleProvider{
        .name = "deny",
        .provider_type = "file",
        .behavior = .domain,
        .url = "https://example.invalid/rules.yaml",
        .path = path,
        .entries = .empty,
    };

    try std.testing.expectError(
        error.InvalidRuleProviderEntry,
        installDownloadedRuleProvider(
            allocator,
            &provider,
            path,
            "payload:\n  - bad domain\n",
        ),
    );
    const preserved = try tmp.dir.readFileAlloc(
        compat.io(),
        "rules.yaml",
        allocator,
        .limited(1024),
    );
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("payload:\n  - old.example\n", preserved);

    const replacement = "payload:\n  - new.example\n";
    _ = try installDownloadedRuleProvider(
        allocator,
        &provider,
        path,
        replacement,
    );
    const published = try tmp.dir.readFileAlloc(
        compat.io(),
        "rules.yaml",
        allocator,
        .limited(1024),
    );
    defer allocator.free(published);
    try std.testing.expectEqualStrings(replacement, published);
}

test "prepareRuleProvidersForRuntime expands rule-set rules" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(compat.io(), "direct.txt", .{});
        defer f.close(compat.io());
        try compat.fileWriteAll(f, "example.com\n");
    }

    const provider_abs = try testTmpPathAlloc(allocator, &tmp, "direct.txt");
    defer allocator.free(provider_abs);

    const yaml_config = try std.fmt.allocPrint(allocator,
        \\mixed-port: 7899
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\    server: ""
        \\    port: 0
        \\rule-providers:
        \\  directset:
        \\    type: file
        \\    behavior: domain
        \\    path: {s}
        \\    interval: 3600
        \\rules:
        \\  - RULE-SET,directset,DIRECT
        \\  - MATCH,DIRECT
    , .{provider_abs});
    defer allocator.free(yaml_config);

    var cfg = try parse(allocator, yaml_config);
    defer cfg.deinit();

    try prepareRuleProvidersForRuntime(allocator, &cfg, null);

    try std.testing.expectEqual(@as(usize, 2), cfg.rules.items.len);
    try std.testing.expectEqual(@as(RuleType, .domain_suffix), cfg.rules.items[0].rule_type);
    try std.testing.expectEqualStrings("example.com", cfg.rules.items[0].payload);
    try std.testing.expectEqualStrings("DIRECT", cfg.rules.items[0].target);
    try std.testing.expectEqual(@as(RuleType, .final), cfg.rules.items[1].rule_type);
    try std.testing.expectEqual(@as(usize, 0), cfg.rule_providers.items[0].entries.items.len);
}

test "prepareRuleProvidersForRuntime supports yaml payload style classical provider" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(compat.io(), "applications.txt", .{});
        defer f.close(compat.io());
        try compat.fileWriteAll(f,
            \\---
            \\payload:
            \\  - PROCESS-NAME,tailscale
            \\  - PROCESS-NAME,tailscaled
            \\
        );
    }

    const provider_abs = try testTmpPathAlloc(allocator, &tmp, "applications.txt");
    defer allocator.free(provider_abs);

    const yaml_config = try std.fmt.allocPrint(allocator,
        \\mixed-port: 7899
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\    server: ""
        \\    port: 0
        \\rule-providers:
        \\  applications:
        \\    type: file
        \\    behavior: classical
        \\    path: {s}
        \\    interval: 3600
        \\rules:
        \\  - RULE-SET,applications,DIRECT
        \\  - MATCH,DIRECT
    , .{provider_abs});
    defer allocator.free(yaml_config);

    var cfg = try parse(allocator, yaml_config);
    defer cfg.deinit();

    try prepareRuleProvidersForRuntime(allocator, &cfg, null);

    try std.testing.expectEqual(@as(usize, 3), cfg.rules.items.len);
    try std.testing.expectEqual(@as(RuleType, .process_name), cfg.rules.items[0].rule_type);
    try std.testing.expectEqualStrings("tailscale", cfg.rules.items[0].payload);
    try std.testing.expectEqual(@as(RuleType, .process_name), cfg.rules.items[1].rule_type);
    try std.testing.expectEqualStrings("tailscaled", cfg.rules.items[1].payload);
    try std.testing.expectEqual(@as(RuleType, .final), cfg.rules.items[2].rule_type);
    try std.testing.expectEqual(@as(usize, 0), cfg.rule_providers.items[0].entries.items.len);
}

test "prepareRuleProvidersForRuntime missing-only policy skips refresh for cached provider files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(compat.io(), "direct.txt", .{});
        defer f.close(compat.io());
        try compat.fileWriteAll(f, "example.com\n");
    }

    var provider_file = try tmp.dir.openFile(compat.io(), "direct.txt", .{ .mode = .read_write });
    defer provider_file.close(compat.io());
    const stale_ns = (@as(i128, @intCast(compat.timestamp())) - 10) * std.time.ns_per_s;
    try provider_file.setTimestamps(compat.io(), .{
        .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(stale_ns) } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(stale_ns) } },
    });

    var server = try compat.net.listenReuseAddr(try compat.net.Address.parseIp4("127.0.0.1", 0));
    var hits = std.atomic.Value(u32).init(0);
    var stop_flag = std.atomic.Value(bool).init(false);
    const response_body = "example.net\n";
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(http_server: *compat.net.ReuseAddrListener, request_hits: *std.atomic.Value(u32), stop: *std.atomic.Value(bool), body: []const u8) void {
            while (true) {
                if (stop.load(.seq_cst)) return;
                // Poll with a timeout instead of a bare blocking accept() so the
                // teardown can stop this thread by setting stop_flag. Closing the
                // listener fd does NOT reliably wake a blocked accept() on Linux
                // (it hangs, or races into EBADF) — the root of this test's flaky
                // full-suite deadlock. This test expects ZERO hits, so the accept
                // path normally never runs; an unexpected fetch still bumps hits.
                var fds = [_]std.posix.pollfd{.{
                    .fd = http_server.fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ready = std.posix.poll(&fds, 100) catch return;
                if (ready == 0) continue;
                var conn = http_server.accept() catch continue;
                defer conn.stream.close();
                _ = request_hits.fetchAdd(1, .monotonic);

                var req_buf: [1024]u8 = undefined;
                _ = conn.stream.read(&req_buf) catch {};

                var resp_buf: [256]u8 = undefined;
                const response = std.fmt.bufPrint(
                    &resp_buf,
                    "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                    .{ body.len, body },
                ) catch return;
                conn.stream.writeAll(response) catch {};
            }
        }
    }.run, .{ &server, &hits, &stop_flag, response_body });
    defer {
        stop_flag.store(true, .seq_cst);
        thread.join();
        server.deinit();
    }

    const provider_abs = try testTmpPathAlloc(allocator, &tmp, "direct.txt");
    defer allocator.free(provider_abs);
    const provider_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/direct.txt", .{server.listen_address.getPort()});
    defer allocator.free(provider_url);

    const yaml_config = try std.fmt.allocPrint(allocator,
        \\mixed-port: 7899
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\    server: ""
        \\    port: 0
        \\rule-providers:
        \\  directset:
        \\    type: file
        \\    behavior: domain
        \\    url: {s}
        \\    path: {s}
        \\    interval: 1
        \\rules:
        \\  - RULE-SET,directset,DIRECT
        \\  - MATCH,DIRECT
    , .{ provider_url, provider_abs });
    defer allocator.free(yaml_config);

    var cfg = try parse(allocator, yaml_config);
    defer cfg.deinit();

    try prepareRuleProvidersForRuntimeWithPolicy(allocator, &cfg, null, .missing_only);

    try std.testing.expectEqual(@as(u32, 0), hits.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), cfg.rules.items.len);
    try std.testing.expectEqual(@as(RuleType, .domain_suffix), cfg.rules.items[0].rule_type);
    try std.testing.expectEqualStrings("example.com", cfg.rules.items[0].payload);
    try std.testing.expectEqualStrings("DIRECT", cfg.rules.items[0].target);

    const cached = try tmp.dir.readFileAlloc(compat.io(), "direct.txt", allocator, .limited(1024));
    defer allocator.free(cached);
    try std.testing.expectEqualStrings("example.com\n", cached);
}

test "fetchConfig requests identity encoding to avoid compressed provider responses" {
    const allocator = std.testing.allocator;

    var server = try (try compat.net.Address.parseIp4("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer server.deinit();

    var request_bytes = std.ArrayList(u8).empty;
    defer request_bytes.deinit(allocator);

    const response_body = "ok\n";
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(http_server: *compat.net.Server, allocator_: std.mem.Allocator, request_capture: *std.ArrayList(u8), body: []const u8) void {
            var conn = http_server.accept() catch return;
            defer conn.stream.close();

            var req_buf: [512]u8 = undefined;
            while (std.mem.indexOf(u8, request_capture.items, "\r\n\r\n") == null) {
                const n = conn.stream.read(&req_buf) catch return;
                if (n == 0) return;
                request_capture.appendSlice(allocator_, req_buf[0..n]) catch return;
                if (request_capture.items.len > 4096) return;
            }
            var resp_buf: [256]u8 = undefined;
            const response = std.fmt.bufPrint(
                &resp_buf,
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ body.len, body },
            ) catch return;
            var write_buf: [1024]u8 = undefined;
            var writer = conn.stream.writer(&write_buf);
            writer.interface.writeAll(response) catch return;
            writer.interface.flush() catch return;
        }
    }.run, .{ &server, allocator, &request_bytes, response_body });
    defer thread.join();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/config.yaml", .{server.listen_address.getPort()});
    defer allocator.free(url);

    const result = try fetchConfig(allocator, url);
    defer allocator.free(result.body);

    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expectEqualStrings(response_body, result.body);
    try std.testing.expect(std.mem.indexOf(u8, request_bytes.items, "accept-encoding: identity\r\n") != null);
}

test "fetchConfig enforces the response body limit" {
    const allocator = std.testing.allocator;
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, struct {
        fn run(http_server: *compat.net.Server) void {
            var connection = http_server.accept() catch return;
            defer connection.stream.close();
            var request_buffer: [1024]u8 = undefined;
            _ = connection.stream.read(&request_buffer) catch return;
            const body = [_]u8{'x'} ** 64;
            var response_buffer: [256]u8 = undefined;
            const response = std.fmt.bufPrint(
                &response_buffer,
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ body.len, &body },
            ) catch return;
            connection.stream.writeAll(response) catch return;
        }
    }.run, .{&server});
    defer thread.join();
    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/large.yaml",
        .{server.listen_address.getPort()},
    );
    defer allocator.free(url);
    try std.testing.expectError(
        error.ConfigTooLarge,
        fetchConfigWithOptions(allocator, url, .{
            .body_bytes_max = 32,
            .deadline_ms = 1_000,
        }),
    );
}

test "fetchConfig enforces the total deadline" {
    const allocator = std.testing.allocator;
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, struct {
        fn run(http_server: *compat.net.Server) void {
            var connection = http_server.accept() catch return;
            defer connection.stream.close();
            compat.sleepNs(250 * std.time.ns_per_ms);
        }
    }.run, .{&server});
    defer thread.join();
    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/slow.yaml",
        .{server.listen_address.getPort()},
    );
    defer allocator.free(url);
    try std.testing.expectError(
        error.DownloadTimeout,
        fetchConfigWithOptions(allocator, url, .{
            .body_bytes_max = 1024,
            .deadline_ms = 25,
        }),
    );
}

test "initDefaultProxyEnv configures standard proxy variables" {
    const allocator = std.testing.allocator;

    var env_map = try std.process.Environ.empty.createMap(allocator);
    defer env_map.deinit();
    try env_map.put("http_proxy", "http://127.0.0.1:18080");
    try env_map.put("https_proxy", "http://127.0.0.1:18443");
    compat.setEnvironMap(&env_map);
    defer compat.setEnvironMap(null);

    var client = std.http.Client{ .allocator = allocator, .io = compat.io() };
    defer client.deinit();

    var proxy_arena = try initDefaultProxyEnv(allocator, &client);
    defer proxy_arena.deinit();

    try std.testing.expect(client.http_proxy != null);
    try std.testing.expect(client.https_proxy != null);
    try std.testing.expectEqual(@as(u16, 18080), client.http_proxy.?.port);
    try std.testing.expectEqual(@as(u16, 18443), client.https_proxy.?.port);
    try std.testing.expect(client.http_proxy.?.supports_connect);
    try std.testing.expect(client.https_proxy.?.supports_connect);
}

test "shouldUseCurlFallback only enables https proxy downloads" {
    const allocator = std.testing.allocator;

    var env_map = try std.process.Environ.empty.createMap(allocator);
    defer env_map.deinit();
    compat.setEnvironMap(&env_map);
    defer compat.setEnvironMap(null);

    try std.testing.expect(!shouldUseCurlFallback("https://example.com/config.yaml"));

    try env_map.put("https_proxy", "http://127.0.0.1:7897");
    try std.testing.expect(shouldUseCurlFallback("https://example.com/config.yaml"));
    try std.testing.expect(!shouldUseCurlFallback("http://example.com/config.yaml"));
}

test "parseCurlFetchResult separates body from trailing status" {
    const allocator = std.testing.allocator;

    const result = try parseCurlFetchResult(allocator, "mixed-port: 7890\n\n200");
    defer allocator.free(result.body);

    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expectEqualStrings("mixed-port: 7890\n", result.body);
}

test "normalizeRuleProviderLine strips payload dash and quotes" {
    const a = normalizeRuleProviderLine("  - '1.2.3.0/24'  ").?;
    try std.testing.expectEqualStrings("1.2.3.0/24", a);

    const b = normalizeRuleProviderLine("  - \"DOMAIN-SUFFIX,example.com\"  ").?;
    try std.testing.expectEqualStrings("DOMAIN-SUFFIX,example.com", b);

    try std.testing.expect(normalizeRuleProviderLine("payload:") == null);
}

test "normalizeConfigKey strips exactly one .yaml suffix (download/use/update share it)" {
    try std.testing.expectEqualStrings("smoke", normalizeConfigKey("smoke.yaml"));
    try std.testing.expectEqualStrings("smoke", normalizeConfigKey("smoke"));
    // 只剥一层：`-n foo.yaml.yaml` 的 key 是 "foo.yaml"
    try std.testing.expectEqualStrings("foo.yaml", normalizeConfigKey("foo.yaml.yaml"));
    // 退化输入不产生空 key
    try std.testing.expectEqualStrings(".yaml", normalizeConfigKey(".yaml"));
}

test "switchConfig rejects a profile key that escapes the managed root" {
    // The public command seam must reject traversal before it probes any path.
    const allocator = std.testing.allocator;
    var stdout: std.Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    var output = cli_output.Output.init(
        .text,
        "config use",
        false,
        false,
        &stdout.writer,
        &stderr.writer,
    );

    try std.testing.expectError(
        error.InvalidConfigKey,
        switchConfig(allocator, "../escaped", &output),
    );
}

test "deleteConfig rejects a profile key that escapes the managed root" {
    // Deletion must validate the logical key before deriving a filesystem path.
    const allocator = std.testing.allocator;
    var stdout: std.Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    var output = cli_output.Output.init(
        .text,
        "config delete",
        false,
        false,
        &stdout.writer,
        &stderr.writer,
    );

    try std.testing.expectError(
        error.InvalidConfigKey,
        deleteConfig(allocator, "../escaped", &output),
    );
}

test "config file rollback restores the previous atomic value" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "profile.yaml",
        .data = "old\n",
    });
    const previous = (try readConfigFileIfPresent(
        allocator,
        tmp.dir,
        "profile.yaml",
    )).?;
    defer allocator.free(previous);
    try std.testing.expectEqual(
        ConfigFilePublishOutcome.committed,
        try publishConfigFile(tmp.dir, "profile.yaml", "new\n"),
    );
    try rollbackConfigFile(tmp.dir, "profile.yaml", previous);
    const restored = try tmp.dir.readFileAlloc(
        compat.io(),
        "profile.yaml",
        allocator,
        .limited(64),
    );
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("old\n", restored);
}

test "getSubscriptionUrl rejects an invalid managed profile key" {
    // Subscription lookup must share the same key contract as all writers.
    try std.testing.expectError(
        error.InvalidConfigKey,
        getSubscriptionUrl(std.testing.allocator, "bad/key"),
    );
}

test "downloadConfig validates the managed key before network access" {
    // An invalid logical key must win over any remote transport failure.
    const allocator = std.testing.allocator;
    var stdout: std.Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    var output = cli_output.Output.init(
        .text,
        "config download",
        false,
        false,
        &stdout.writer,
        &stderr.writer,
    );

    try std.testing.expectError(
        error.InvalidConfigKey,
        downloadConfig(
            allocator,
            "http://127.0.0.1:1/config.yaml",
            "../escaped",
            false,
            &output,
        ),
    );
}

test "resolveRuntimeConfigKey never aliases an unmanaged explicit path" {
    const allocator = std.testing.allocator;
    const key = try resolveRuntimeConfigKey(
        allocator,
        "testdata/config/minimal.yaml",
    );
    defer if (key) |value| allocator.free(value);
    try std.testing.expect(key == null);
}

test "resolveRuntimeConfigKey infers key from explicit configs path" {
    const allocator = std.testing.allocator;

    try meta.ensureConfigsDir(allocator);
    const configs_dir = (try meta.getConfigsDir(allocator)).?;
    defer allocator.free(configs_dir);

    const cfg_path = try compat.fs.path.join(allocator, &.{ configs_dir, "manual.yaml" });
    defer allocator.free(cfg_path);

    const key = (try resolveRuntimeConfigKey(allocator, cfg_path)).?;
    defer allocator.free(key);
    try std.testing.expectEqualStrings("manual", key);
}

test "inferConfigKeyFromPath resolves symlinked config path for non-download config" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var configs = try tmp.dir.createDirPathOpen(compat.io(), "configs", .{});
    defer configs.close(compat.io());

    {
        const f = try configs.createFile(compat.io(), "manual.yaml", .{});
        f.close(compat.io());
    }

    tmp.dir.symLink(compat.io(), "configs/manual.yaml", "config.yaml", .{}) catch return error.SkipZigTest;

    const cwd = try std.process.currentPathAlloc(compat.io(), allocator);
    defer allocator.free(cwd);

    const tmp_abs = try compat.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(tmp_abs);
    const configs_abs = try compat.fs.path.join(allocator, &.{ tmp_abs, "configs" });
    defer allocator.free(configs_abs);
    const link_abs = try compat.fs.path.join(allocator, &.{ tmp_abs, "config.yaml" });
    defer allocator.free(link_abs);

    const key = (try inferConfigKeyFromPathWithConfigsDir(allocator, link_abs, configs_abs)).?;
    defer allocator.free(key);
    try std.testing.expectEqualStrings("manual", key);
}

test "isRuleProviderRefreshDue supports second and nanosecond timestamps" {
    const now = compat.timestamp();

    const stale_sec = @as(i128, @intCast(now - 1000));
    try std.testing.expect(isRuleProviderRefreshDue(stale_sec, 300));

    const fresh_sec = @as(i128, @intCast(now - 10));
    try std.testing.expect(!isRuleProviderRefreshDue(fresh_sec, 300));

    const stale_ns = @as(i128, @intCast(now - 1000)) * std.time.ns_per_s;
    try std.testing.expect(isRuleProviderRefreshDue(stale_ns, 300));
}

test "makeManagedOverrideScriptPathForKey keeps source extension" {
    const allocator = std.testing.allocator;
    const path = try makeManagedOverrideScriptPathForKey(
        allocator,
        "abc123",
        "/tmp/source.lua",
        "/tmp/zc-override",
    );
    defer allocator.free(path);

    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/zc-override/abc123-"));
    try std.testing.expect(std.mem.endsWith(u8, path, ".lua"));
}

// 测试用：在隔离 HOME（build.zig 设为 .zig-cache/zc-test-home）的真实
// configs/ 目录里造一个配置文件并登记到 meta，返回绝对文件路径（caller free）。
fn testSeedConfig(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    try meta.ensureConfigsDir(allocator);
    const configs_dir = (try meta.getConfigsDir(allocator)).?;
    defer allocator.free(configs_dir);

    const yaml_name = try std.fmt.allocPrint(allocator, "{s}.yaml", .{key});
    defer allocator.free(yaml_name);
    const file_path = try compat.fs.path.join(allocator, &.{ configs_dir, yaml_name });
    errdefer allocator.free(file_path);

    const f = try compat.fs.createFileAbsolute(file_path, .{});
    defer f.close(compat.io());
    try compat.fileWriteAll(f, "mixed-port: 7899\n");
    return file_path;
}

fn testPathExists(file_path: []const u8) bool {
    return if (compat.fs.accessAbsolute(file_path, .{})) |_| true else |_| false;
}

test "deleteConfig removes file + meta entry and clears active when active" {
    const allocator = std.testing.allocator;

    const key = "zc-delete-unit-active";
    const file_path = try testSeedConfig(allocator, key);
    defer allocator.free(file_path);

    // 登记到 meta 并设为 active。
    {
        var md = meta.load(allocator) catch meta.MetaData.init(allocator);
        defer md.deinit();
        _ = try ensureConfigMetaEntry(allocator, &md, key);
        if (md.active) |old| allocator.free(old);
        md.active = try allocator.dupe(u8, key);
        try meta.saveVisible(allocator, &md);
    }

    var out_w: std.Io.Writer.Allocating = .init(allocator);
    defer out_w.deinit();
    var err_w: std.Io.Writer.Allocating = .init(allocator);
    defer err_w.deinit();
    var out = cli_output.Output.init(.text, "config delete", false, false, &out_w.writer, &err_w.writer);

    // 带 .yaml 后缀也应归一化命中。
    var outcome = try deleteConfig(allocator, "zc-delete-unit-active.yaml", &out);
    defer outcome.deinit(allocator);

    try std.testing.expectEqualStrings(key, outcome.key);
    try std.testing.expect(outcome.was_active);
    try std.testing.expect(!testPathExists(file_path));

    {
        var md = meta.load(allocator) catch meta.MetaData.init(allocator);
        defer md.deinit();
        try std.testing.expect(!md.configs.contains(key));
        try std.testing.expect(md.active == null);
    }

    // 再次删除（文件与 entry 都没了）-> ConfigNotFound。
    try std.testing.expectError(error.ConfigNotFound, deleteConfig(allocator, key, &out));
}

test "deleteConfig removes managed override script and leaves a different active untouched" {
    const allocator = std.testing.allocator;

    const key = "zc-delete-unit-ovr";
    const file_path = try testSeedConfig(allocator, key);
    defer allocator.free(file_path);

    // 造一个托管 override 脚本（位于托管 override 目录内）。
    const overrides_dir = (try getOverrideScriptsDir(allocator)).?;
    defer allocator.free(overrides_dir);
    compat.fs.cwd().makePath(overrides_dir) catch {};
    const script_path = try compat.fs.path.join(allocator, &.{ overrides_dir, "zc-delete-unit-ovr-1.lua" });
    defer allocator.free(script_path);
    {
        const f = try compat.fs.createFileAbsolute(script_path, .{});
        f.close(compat.io());
    }

    // 登记 entry（绑定托管脚本），并把 active 指向另一个配置。
    {
        var md = meta.load(allocator) catch meta.MetaData.init(allocator);
        defer md.deinit();
        const cm = try ensureConfigMetaEntry(allocator, &md, key);
        if (cm.override_script) |old| allocator.free(old);
        cm.override_script = try allocator.dupe(u8, script_path);
        if (md.active) |old| allocator.free(old);
        md.active = try allocator.dupe(u8, "zc-delete-unit-other");
        try meta.saveVisible(allocator, &md);
    }

    var out_w: std.Io.Writer.Allocating = .init(allocator);
    defer out_w.deinit();
    var err_w: std.Io.Writer.Allocating = .init(allocator);
    defer err_w.deinit();
    var out = cli_output.Output.init(.text, "config delete", false, false, &out_w.writer, &err_w.writer);

    var outcome = try deleteConfig(allocator, key, &out);
    defer outcome.deinit(allocator);

    try std.testing.expect(!outcome.was_active);
    try std.testing.expect(!testPathExists(file_path));
    try std.testing.expect(!testPathExists(script_path)); // 托管脚本随配置删除

    {
        var md = meta.load(allocator) catch meta.MetaData.init(allocator);
        defer md.deinit();
        try std.testing.expect(!md.configs.contains(key));
        try std.testing.expect(md.active != null);
        try std.testing.expectEqualStrings("zc-delete-unit-other", md.active.?);
    }

    // 清理 active，避免给后续测试留下悬空 active。
    {
        var md = meta.load(allocator) catch meta.MetaData.init(allocator);
        defer md.deinit();
        if (md.active) |old| allocator.free(old);
        md.active = null;
        meta.saveVisible(allocator, &md) catch {};
    }
}

test "deleteConfig handles orphan meta entry (no file) and orphan file (no meta entry)" {
    const allocator = std.testing.allocator;

    var out_w: std.Io.Writer.Allocating = .init(allocator);
    defer out_w.deinit();
    var err_w: std.Io.Writer.Allocating = .init(allocator);
    defer err_w.deinit();
    var out = cli_output.Output.init(.text, "config delete", false, false, &out_w.writer, &err_w.writer);

    // 分支 A：meta 中有 entry 但 configs/ 下没有文件（孤儿 entry）。
    // deleteConfig 仍应成功并移除 entry（不报 ConfigNotFound）。
    {
        const key = "zc-delete-orphan-meta";
        try meta.ensureConfigsDir(allocator);
        var md = meta.load(allocator) catch meta.MetaData.init(allocator);
        _ = try ensureConfigMetaEntry(allocator, &md, key);
        try meta.saveVisible(allocator, &md);
        md.deinit();

        var outcome = try deleteConfig(allocator, key, &out);
        defer outcome.deinit(allocator);
        try std.testing.expect(!outcome.was_active);

        var after = meta.load(allocator) catch meta.MetaData.init(allocator);
        defer after.deinit();
        try std.testing.expect(!after.configs.contains(key));
    }

    // 分支 B：configs/ 下有文件但 meta 中没有 entry（孤儿文件，例如手动放进去的）。
    // deleteConfig 应删掉文件并成功。注意 meta.load 的 syncFromDisk 会先为该
    // 文件补一个空 entry，所以这里同时覆盖了“文件存在”这一删除路径。
    {
        const key = "zc-delete-orphan-file";
        const file_path = try testSeedConfig(allocator, key);
        defer allocator.free(file_path);

        var outcome = try deleteConfig(allocator, key, &out);
        defer outcome.deinit(allocator);
        try std.testing.expect(!testPathExists(file_path));

        var after = meta.load(allocator) catch meta.MetaData.init(allocator);
        defer after.deinit();
        try std.testing.expect(!after.configs.contains(key));
    }
}
