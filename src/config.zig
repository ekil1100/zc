const std = @import("std");
const compat = @import("compat.zig");
const yaml = @import("util/yaml.zig");
const meta = @import("meta.zig");

pub const ProxyType = enum {
    direct,
    reject,
    http,
    socks5,
    ss, // Shadowsocks
    vmess, // VMess
    trojan, // Trojan
    vless, // VLESS
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

/// 从 YAML 字符串解析配置
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Config {
    var root = try yaml.parse(allocator, content);
    defer root.deinit(allocator);

    var config = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(ProxyGroup).empty,
        .rule_providers = std.ArrayList(RuleProvider).empty,
        .rules = std.ArrayList(Rule).empty,
    };
    errdefer config.deinit();

    if (root != .map) {
        return error.InvalidConfig;
    }

    // 解析基础配置
    if (root.map.get("port")) |v| {
        if (v == .integer) {
            const port = v.integer;
            if (port > 0 and port <= 65535) {
                config.port = @intCast(port);
            }
        }
    }
    if (root.map.get("socks-port")) |v| {
        if (v == .integer) {
            const port = v.integer;
            if (port > 0 and port <= 65535) {
                config.socks_port = @intCast(port);
            }
        }
    }
    if (root.map.get("mixed-port")) |v| {
        if (v == .integer) {
            const port = v.integer;
            if (port > 0 and port <= 65535) {
                config.mixed_port = @intCast(port);
            }
        }
    }
    if (root.map.get("allow-lan")) |v| {
        if (v == .boolean) config.allow_lan = v.boolean;
    }
    if (root.map.get("bind-address")) |v| {
        if (v == .string) {
            allocator.free(config.bind_address);
            config.bind_address = try allocator.dupe(u8, v.string);
        }
    }
    if (root.map.get("mode")) |v| {
        if (v == .string) {
            allocator.free(config.mode);
            config.mode = try allocator.dupe(u8, v.string);
        }
    }
    if (root.map.get("log-level")) |v| {
        if (v == .string) {
            allocator.free(config.log_level);
            config.log_level = try allocator.dupe(u8, v.string);
        }
    }
    if (root.map.get("external-controller")) |v| {
        if (v == .string) config.external_controller = try allocator.dupe(u8, v.string);
    }

    // 解析代理列表
    if (root.map.get("proxies")) |proxies| {
        if (proxies == .array) {
            for (proxies.array.items) |*item| {
                if (item.* == .map) {
                    // 检查是否是代理组类型（select, url-test等）
                    if (isProxyGroupType(item.map)) {
                        const group = try parseProxyGroup(allocator, item.map);
                        try config.proxy_groups.append(allocator, group);
                    } else {
                        const proxy = try parseProxy(allocator, item.map);
                        try config.proxies.append(allocator, proxy);
                    }
                }
            }
        }
    }

    // 解析代理组
    if (root.map.get("proxy-groups")) |groups| {
        if (groups == .array) {
            for (groups.array.items) |*item| {
                if (item.* == .map) {
                    const group = try parseProxyGroup(allocator, item.map);
                    try config.proxy_groups.append(allocator, group);
                }
            }
        }
    }

    if (root.map.get("rule-providers")) |providers| {
        if (providers == .map) {
            var it = providers.map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .map) return error.InvalidConfig;
                const provider = try parseRuleProvider(allocator, entry.key_ptr.*, entry.value_ptr.*.map);
                try config.rule_providers.append(allocator, provider);
            }
        }
    }

    // 解析规则
    if (root.map.get("rules")) |rules| {
        if (rules == .array) {
            for (rules.array.items) |*item| {
                if (item.* == .string) {
                    const rule = try parseRule(allocator, item.string);
                    try config.rules.append(allocator, rule);
                }
            }
        }
    }

    // 如果没有规则，添加默认 MATCH 规则
    if (config.rules.items.len == 0) {
        try config.rules.append(allocator, .{
            .rule_type = .final,
            .payload = try allocator.dupe(u8, ""),
            .target = try allocator.dupe(u8, "DIRECT"),
        });
    }

    return config;
}

fn parseProxy(allocator: std.mem.Allocator, map: std.StringHashMap(yaml.YamlValue)) !Proxy {
    const name = map.get("name") orelse return error.MissingProxyName;
    const proxy_type = map.get("type") orelse return error.MissingProxyType;

    if (name != .string or proxy_type != .string) {
        return error.InvalidProxyFormat;
    }

    const ptype = parseProxyType(proxy_type.string) orelse return error.UnknownProxyType;

    // DIRECT 和 REJECT 不需要 server 和 port
    const needs_server = ptype != .direct and ptype != .reject;

    var proxy = Proxy{
        .name = try allocator.dupe(u8, name.string),
        .proxy_type = ptype,
        .server = if (needs_server) blk: {
            const server = map.get("server") orelse return error.MissingProxyServer;
            if (server != .string) return error.InvalidProxyFormat;
            break :blk try allocator.dupe(u8, server.string);
        } else "",
        .port = if (needs_server) blk: {
            const port = map.get("port") orelse return error.MissingProxyPort;
            if (port != .integer) return error.InvalidProxyFormat;
            break :blk @intCast(port.integer);
        } else 0,
    };

    // 协议特定字段
    if (map.get("password")) |v| {
        if (v == .string) proxy.password = try allocator.dupe(u8, v.string);
    }
    if (map.get("cipher")) |v| {
        if (v == .string) proxy.cipher = try allocator.dupe(u8, v.string);
    }
    if (map.get("uuid")) |v| {
        if (v == .string) proxy.uuid = try allocator.dupe(u8, v.string);
    }
    if (map.get("alterId")) |v| {
        if (v == .integer) proxy.alter_id = @intCast(v.integer);
    }
    if (map.get("tls")) |v| {
        if (v == .boolean) proxy.tls = v.boolean;
    }
    if (map.get("skip-cert-verify")) |v| {
        if (v == .boolean) proxy.skip_cert_verify = v.boolean;
    }
    if (map.get("sni")) |v| {
        if (v == .string) proxy.sni = try allocator.dupe(u8, v.string);
    }
    if (map.get("ws-opts")) |v| {
        if (v == .map) {
            proxy.ws = true;
            if (v.map.get("path")) |p| {
                if (p == .string) proxy.ws_path = try allocator.dupe(u8, p.string);
            }
            if (v.map.get("headers")) |h| {
                if (h == .map) {
                    if (h.map.get("Host")) |host| {
                        if (host == .string) proxy.ws_host = try allocator.dupe(u8, host.string);
                    }
                }
            }
        }
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
        }
    }

    return proxy;
}

fn parseProxyGroup(allocator: std.mem.Allocator, map: std.StringHashMap(yaml.YamlValue)) !ProxyGroup {
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

    if (map.get("proxies")) |proxies| {
        if (proxies == .array) {
            for (proxies.array.items) |*item| {
                if (item.* == .string) {
                    const p = try allocator.dupe(u8, item.string);
                    try group.proxies.append(allocator, p);
                }
            }
        }
    }

    if (map.get("url")) |v| {
        if (v == .string) group.url = try allocator.dupe(u8, v.string);
    }
    if (map.get("interval")) |v| {
        if (v == .integer) group.interval = @intCast(v.integer);
    }
    if (map.get("tolerance")) |v| {
        if (v == .integer) group.tolerance = @intCast(v.integer);
    }
    if (map.get("lazy")) |v| {
        if (v == .boolean) group.lazy = v.boolean;
    }

    return group;
}

fn parseRuleProvider(
    allocator: std.mem.Allocator,
    name: []const u8,
    map: std.StringHashMap(yaml.YamlValue),
) !RuleProvider {
    const type_val = map.get("type") orelse return error.MissingRuleProviderType;
    const behavior_val = map.get("behavior") orelse return error.MissingRuleProviderBehavior;
    const path_val = map.get("path") orelse return error.MissingRuleProviderPath;

    if (type_val != .string or behavior_val != .string or path_val != .string) {
        return error.InvalidRuleProviderFormat;
    }

    var provider = RuleProvider{
        .name = try allocator.dupe(u8, name),
        .provider_type = try allocator.dupe(u8, type_val.string),
        .behavior = parseRuleProviderBehavior(behavior_val.string) orelse return error.InvalidRuleProviderBehavior,
        .path = try allocator.dupe(u8, path_val.string),
        .entries = std.ArrayList([]const u8).empty,
    };
    errdefer provider.deinit(allocator);

    if (map.get("url")) |v| {
        if (v != .string) return error.InvalidRuleProviderFormat;
        provider.url = try allocator.dupe(u8, v.string);
    }
    if (map.get("interval")) |v| {
        if (v != .integer) return error.InvalidRuleProviderFormat;
        if (v.integer <= 0) return error.InvalidRuleProviderFormat;
        provider.interval = @intCast(v.integer);
    }

    return provider;
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

    return Rule{
        .rule_type = rule_type,
        .payload = try allocator.dupe(u8, std.mem.trim(u8, payload, " \t")),
        .target = try allocator.dupe(u8, std.mem.trim(u8, target, " \t")),
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

/// 查找默认配置文件路径
/// 通过 meta.json 的 active 字段确定当前配置，路径在 configs/ 子目录
/// 回退：~/.config/zc/config.yaml > ~/.zc/config.yaml > ./config.yaml
fn getDefaultConfigPath(allocator: std.mem.Allocator) !?[]const u8 {
    // 1. 尝试从 meta.json 的 active 字段加载
    if (try meta.getConfigsDir(allocator)) |configs_dir| {
        defer allocator.free(configs_dir);

        var meta_data = meta.load(allocator) catch meta.MetaData.init(allocator);
        defer meta_data.deinit();

        if (meta_data.active) |active_key| {
            const yaml_name = try std.fmt.allocPrint(allocator, "{s}.yaml", .{active_key});
            defer allocator.free(yaml_name);
            const full_path = try compat.fs.path.join(allocator, &.{ configs_dir, yaml_name });
            if (compat.fs.accessAbsolute(full_path, .{})) |_| {
                return full_path;
            } else |_| {
                allocator.free(full_path);
            }
        }

        // 1b. 尝试 configs/ 目录下的 config.yaml
        const configs_default = try compat.fs.path.join(allocator, &.{ configs_dir, "config.yaml" });
        if (compat.fs.accessAbsolute(configs_default, .{})) |_| {
            return configs_default;
        } else |_| {
            allocator.free(configs_default);
        }
    }

    // 2. 回退到旧路径
    const home = compat.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    // 旧的 config.yaml（符号链接或直接文件）
    const old_config = try compat.fs.path.join(allocator, &.{ home, ".config/zc/config.yaml" });
    if (compat.fs.accessAbsolute(old_config, .{})) |_| {
        return old_config;
    } else |_| {
        allocator.free(old_config);
    }

    const old_config2 = try compat.fs.path.join(allocator, &.{ home, ".zc/config.yaml" });
    if (compat.fs.accessAbsolute(old_config2, .{})) |_| {
        return old_config2;
    } else |_| {
        allocator.free(old_config2);
    }

    // 检查当前目录的 config.yaml
    compat.fs.cwd().access("config.yaml", .{}) catch return null;
    return try allocator.dupe(u8, "config.yaml");
}

/// 默认配置（先尝试从文件读取，失败则用内置配置）
pub fn loadDefault(allocator: std.mem.Allocator) !Config {
    // 尝试查找默认配置文件
    if (try getDefaultConfigPath(allocator)) |path| {
        defer allocator.free(path);
        std.debug.print("Loading config from: {s}\n", .{path});
        return try load(allocator, path);
    }

    // 使用内置默认配置
    std.debug.print("No config file found, using built-in defaults\n", .{});
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
                    try downloadRuleProviderFile(allocator, provider.name, url, resolved_path, true);
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
                downloadRuleProviderFile(allocator, provider.name, url, resolved_path, false) catch |err| {
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
    provider_name: []const u8,
    url: []const u8,
    resolved_path: []const u8,
    required: bool,
) !void {
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

    const parent = compat.fs.path.dirname(resolved_path) orelse return error.RuleProviderDownloadFailed;
    compat.fs.cwd().makePath(parent) catch |err| {
        std.debug.print(
            "rule-provider download failed: name={s} url={s} path={s} mkdir_error={s}\n",
            .{ provider_name, url, resolved_path, @errorName(err) },
        );
        return error.RuleProviderDownloadFailed;
    };

    const file = compat.fs.createFileAbsolute(resolved_path, .{}) catch |err| {
        std.debug.print(
            "rule-provider download failed: name={s} url={s} path={s} file_error={s}\n",
            .{ provider_name, url, resolved_path, @errorName(err) },
        );
        return error.RuleProviderDownloadFailed;
    };
    defer file.close(compat.io());
    compat.fileWriteAll(file, result.body) catch |err| {
        std.debug.print(
            "rule-provider download failed: name={s} url={s} path={s} write_error={s}\n",
            .{ provider_name, url, resolved_path, @errorName(err) },
        );
        return error.RuleProviderDownloadFailed;
    };

    if (required) {
        std.debug.print("rule-provider downloaded: name={s} path={s}\n", .{ provider_name, resolved_path });
    } else {
        std.debug.print("rule-provider refreshed: name={s} path={s}\n", .{ provider_name, resolved_path });
    }
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

        const content = try compat.fileReadToEndAlloc(file, allocator, 8 * 1024 * 1024);
        defer allocator.free(content);

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |raw_line| {
            const normalized = normalizeRuleProviderLine(raw_line) orelse continue;
            try provider.entries.append(allocator, try allocator.dupe(u8, normalized));
        }
    }
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
            try expanded.append(allocator, try cloneRule(allocator, rule));
            continue;
        }

        const provider = findRuleProvider(cfg, rule.payload) orelse return error.RuleProviderNotFound;
        try appendRulesFromProvider(allocator, &expanded, provider, rule.target, rule.no_resolve);
    }

    for (cfg.rules.items) |*r| r.deinit(allocator);
    cfg.rules.deinit(allocator);
    cfg.rules = expanded;
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
                var rule = Rule{
                    .rule_type = .domain_suffix,
                    .payload = try allocator.dupe(u8, payload),
                    .target = try allocator.dupe(u8, target),
                    .no_resolve = inherit_no_resolve,
                };
                errdefer rule.deinit(allocator);
                try out.append(allocator, rule);
            }
        },
        .ipcidr => {
            for (provider.entries.items) |entry| {
                const payload = normalizeIpCidrProviderEntry(entry) orelse continue;
                const rule_type: RuleType = if (std.mem.indexOfScalar(u8, payload, ':') != null) .ip_cidr6 else .ip_cidr;
                var rule = Rule{
                    .rule_type = rule_type,
                    .payload = try allocator.dupe(u8, payload),
                    .target = try allocator.dupe(u8, target),
                    .no_resolve = inherit_no_resolve,
                };
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

    var target: []const u8 = default_target;
    var no_resolve = false;
    while (parts_it.next()) |opt_raw| {
        const opt = std.mem.trim(u8, opt_raw, " \t");
        if (opt.len == 0) continue;
        if (std.mem.eql(u8, opt, "no-resolve")) {
            no_resolve = true;
            continue;
        }
        target = opt;
    }

    return .{
        .rule_type = rule_type,
        .payload = try allocator.dupe(u8, payload),
        .target = try allocator.dupe(u8, target),
        .no_resolve = no_resolve,
    };
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

fn cloneRule(allocator: std.mem.Allocator, rule: Rule) !Rule {
    return .{
        .rule_type = rule.rule_type,
        .payload = try allocator.dupe(u8, rule.payload),
        .target = try allocator.dupe(u8, rule.target),
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

/// fetchConfig 内部函数：执行 HTTP 请求获取配置内容
/// 可独立测试，验证 User-Agent 等头部设置
pub fn fetchConfig(allocator: std.mem.Allocator, url: []const u8) !DownloadResult {
    var client = std.http.Client{ .allocator = allocator, .io = compat.io() };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_writer.writer,
        .headers = .{
            .user_agent = .{ .override = "clash" },
            .accept_encoding = .{ .override = "identity" },
        },
    }) catch |err| {
        std.debug.print("Failed to download config: {s}\n", .{@errorName(err)});
        return err;
    };

    const body = try allocator.dupe(u8, response_writer.written());

    return DownloadResult{
        .status = result.status,
        .body = body,
    };
}

/// 下载配置文件从 URL 并保存到 configs/ 目录
/// name: 可选的自定义 key，为 null 则生成 8 位随机 key
/// 返回: 配置 key（需要调用者释放内存），出错返回 null
pub fn downloadConfig(allocator: std.mem.Allocator, url: []const u8, name: ?[]const u8) !?[]const u8 {
    const fetch_result = try fetchConfig(allocator, url);
    defer allocator.free(fetch_result.body);

    if (fetch_result.status != .ok) {
        std.debug.print("Failed to download config: HTTP {d}\n", .{@intFromEnum(fetch_result.status)});
        return error.DownloadFailed;
    }

    // 确保 configs/ 目录存在
    try meta.ensureConfigsDir(allocator);

    const configs_dir = try meta.getConfigsDir(allocator) orelse {
        std.debug.print("Could not determine config directory\n", .{});
        return error.NoConfigDir;
    };
    defer allocator.free(configs_dir);

    // 确定 key
    const key = if (name) |n|
        try allocator.dupe(u8, n)
    else
        try meta.generateKey(allocator);

    // 保存文件到 configs/{key}.yaml
    const yaml_filename = try std.fmt.allocPrint(allocator, "{s}.yaml", .{key});
    defer allocator.free(yaml_filename);

    const config_path = try compat.fs.path.join(allocator, &.{ configs_dir, yaml_filename });
    defer allocator.free(config_path);

    const file = try compat.fs.createFileAbsolute(config_path, .{});
    defer file.close(compat.io());
    try compat.fileWriteAll(file, fetch_result.body);

    // 解析 URL 参数并写入 meta.json
    var meta_data = meta.load(allocator) catch meta.MetaData.init(allocator);
    defer meta_data.deinit();

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

    const key_owned = try allocator.dupe(u8, key);
    try meta_data.configs.put(key_owned, cm);

    // 设为活跃配置
    if (meta_data.active) |old| allocator.free(old);
    meta_data.active = try allocator.dupe(u8, key);

    try meta.save(allocator, &meta_data);

    const display = meta.getDisplayName(&cm, key);
    std.debug.print("Config downloaded: {s} (key: {s})\n", .{ display, key });
    std.debug.print("Config saved to: {s}\n", .{config_path});

    return key;
}

/// 获取当前激活的配置 key（从 meta.json）
pub fn getCurrentConfigName(allocator: std.mem.Allocator) !?[]const u8 {
    var meta_data = meta.load(allocator) catch return null;
    defer meta_data.deinit();

    if (meta_data.active) |active| {
        return try allocator.dupe(u8, active);
    }
    return null;
}

/// 解析运行时配置 key：
/// 1) 优先从显式配置路径推导（仅当位于 ~/.config/zc/configs 且为 *.yaml）
/// 2) 回退到 meta.active
/// 3) 回退到默认配置路径推导
pub fn resolveRuntimeConfigKey(allocator: std.mem.Allocator, explicit_config_path: ?[]const u8) !?[]const u8 {
    if (explicit_config_path) |path| {
        if (try inferConfigKeyFromPath(allocator, path)) |k| return k;
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

    var meta_data = meta.load(allocator) catch meta.MetaData.init(allocator);
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

    try meta.save(allocator, &meta_data);
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

    var meta_data = meta.load(allocator) catch meta.MetaData.init(allocator);
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
        try meta.save(allocator, &meta_data);
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

fn inferConfigKeyFromPath(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
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
    var meta_data = meta.load(allocator) catch return null;
    defer meta_data.deinit();

    // config_name 可能带 .yaml 后缀
    var key = config_name;
    if (std.mem.endsWith(u8, config_name, ".yaml")) {
        key = config_name[0 .. config_name.len - 5];
    }

    if (meta_data.configs.get(key)) |cm| {
        if (cm.url) |url| {
            return try allocator.dupe(u8, url);
        }
    }
    return null;
}

/// 更新配置文件（从 meta.json 中保存的订阅 URL）
pub fn updateConfig(allocator: std.mem.Allocator, config_name: []const u8) !?[]const u8 {
    // config_name 可能带 .yaml 后缀
    var key = config_name;
    if (std.mem.endsWith(u8, config_name, ".yaml")) {
        key = config_name[0 .. config_name.len - 5];
    }

    const url = try getSubscriptionUrl(allocator, key) orelse {
        std.debug.print("No subscription URL found for config: {s}\n", .{key});
        std.debug.print("Use 'zc config download <url>' to download a new config\n", .{});
        return null;
    };
    defer allocator.free(url);

    std.debug.print("Updating from: {s}\n", .{url});

    // 重新下载但使用相同的 key
    const fetch_result = try fetchConfig(allocator, url);
    defer allocator.free(fetch_result.body);

    if (fetch_result.status != .ok) {
        std.debug.print("Failed to download config: HTTP {d}\n", .{@intFromEnum(fetch_result.status)});
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

    std.debug.print("Config updated: {s}\n", .{config_path});

    return try allocator.dupe(u8, key);
}

/// 列出所有可用的配置文件
pub fn listConfigs(allocator: std.mem.Allocator) !void {
    var meta_data = meta.load(allocator) catch meta.MetaData.init(allocator);
    defer meta_data.deinit();

    const configs_dir = try meta.getConfigsDir(allocator) orelse {
        std.debug.print("Could not determine config directory\n", .{});
        return error.NoConfigDir;
    };
    defer allocator.free(configs_dir);

    std.debug.print("Available configs:\n\n", .{});

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
            std.debug.print("  * {s}", .{display});
        } else {
            std.debug.print("    {s}", .{display});
        }

        // 如果 display 不等于 key，显示 key
        if (!std.mem.eql(u8, display, key)) {
            std.debug.print(" ({s})", .{key});
        }

        if (is_active) {
            std.debug.print(" (active)", .{});
        }

        std.debug.print("\n", .{});
    }

    if (count == 0) {
        std.debug.print("  (no config files found)\n", .{});
    } else {
        std.debug.print("\nUse 'zc config use <key>' to switch config\n", .{});
    }
}

/// 切换配置文件（更新 meta.json 的 active 字段）
pub fn switchConfig(allocator: std.mem.Allocator, target: []const u8) !void {
    var meta_data = meta.load(allocator) catch meta.MetaData.init(allocator);
    defer meta_data.deinit();

    // target 可能带 .yaml 后缀
    var key = target;
    if (std.mem.endsWith(u8, target, ".yaml")) {
        key = target[0 .. target.len - 5];
    }

    // 验证 key 存在于 meta 中
    if (!meta_data.configs.contains(key)) {
        // 尝试在 configs/ 目录中查找对应文件
        const configs_dir = try meta.getConfigsDir(allocator) orelse {
            std.debug.print("Config not found: {s}\n", .{key});
            return error.ConfigNotFound;
        };
        defer allocator.free(configs_dir);

        const yaml_name = try std.fmt.allocPrint(allocator, "{s}.yaml", .{key});
        defer allocator.free(yaml_name);

        const file_path = try compat.fs.path.join(allocator, &.{ configs_dir, yaml_name });
        defer allocator.free(file_path);

        compat.fs.accessAbsolute(file_path, .{}) catch {
            std.debug.print("Config not found: {s}\n", .{key});
            std.debug.print("Use 'zc config ls' to see available configs\n", .{});
            return error.ConfigNotFound;
        };

        // 文件存在但不在 meta 中，添加 entry
        const key_owned = try allocator.dupe(u8, key);
        const cm = meta.ConfigMeta.init(allocator);
        try meta_data.configs.put(key_owned, cm);
    }

    // 更新 active
    if (meta_data.active) |old| allocator.free(old);
    meta_data.active = try allocator.dupe(u8, key);

    try meta.save(allocator, &meta_data);

    if (meta_data.configs.getPtr(key)) |cm| {
        const display = meta.getDisplayName(cm, key);
        std.debug.print("Switched to config: {s}\n", .{display});
    } else {
        std.debug.print("Switched to config: {s}\n", .{key});
    }
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

fn testTmpPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(compat.io(), allocator);
    defer allocator.free(cwd);
    return try compat.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], name });
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

    var server = try (try compat.net.Address.parseIp4("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    var hits = std.atomic.Value(u32).init(0);
    const response_body = "example.net\n";
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(http_server: *compat.net.Server, request_hits: *std.atomic.Value(u32), body: []const u8) void {
            while (true) {
                var conn = http_server.accept() catch return;
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
    }.run, .{ &server, &hits, response_body });
    defer {
        server.deinit();
        thread.join();
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

            var req_buf: [2048]u8 = undefined;
            const n = conn.stream.read(&req_buf) catch return;
            request_capture.appendSlice(allocator_, req_buf[0..n]) catch return;

            var resp_buf: [256]u8 = undefined;
            const response = std.fmt.bufPrint(
                &resp_buf,
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ body.len, body },
            ) catch return;
            conn.stream.writeAll(response) catch {};
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

test "normalizeRuleProviderLine strips payload dash and quotes" {
    const a = normalizeRuleProviderLine("  - '1.2.3.0/24'  ").?;
    try std.testing.expectEqualStrings("1.2.3.0/24", a);

    const b = normalizeRuleProviderLine("  - \"DOMAIN-SUFFIX,example.com\"  ").?;
    try std.testing.expectEqualStrings("DOMAIN-SUFFIX,example.com", b);

    try std.testing.expect(normalizeRuleProviderLine("payload:") == null);
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
