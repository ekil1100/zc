const std = @import("std");
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
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
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
    if (std.mem.eql(u8, s, "SRC-IP-CIDR")) return .src_ip_cidr;
    if (std.mem.eql(u8, s, "DST-PORT")) return .dst_port;
    if (std.mem.eql(u8, s, "SRC-PORT")) return .src_port;
    if (std.mem.eql(u8, s, "PROCESS-NAME")) return .process_name;
    if (std.mem.eql(u8, s, "MATCH")) return .final;
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
            const full_path = try std.fs.path.join(allocator, &.{ configs_dir, yaml_name });
            if (std.fs.accessAbsolute(full_path, .{})) |_| {
                return full_path;
            } else |_| {
                allocator.free(full_path);
            }
        }

        // 1b. 尝试 configs/ 目录下的 config.yaml
        const configs_default = try std.fs.path.join(allocator, &.{ configs_dir, "config.yaml" });
        if (std.fs.accessAbsolute(configs_default, .{})) |_| {
            return configs_default;
        } else |_| {
            allocator.free(configs_default);
        }
    }

    // 2. 回退到旧路径
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    // 旧的 config.yaml（符号链接或直接文件）
    const old_config = try std.fs.path.join(allocator, &.{ home, ".config/zc/config.yaml" });
    if (std.fs.accessAbsolute(old_config, .{})) |_| {
        return old_config;
    } else |_| {
        allocator.free(old_config);
    }

    const old_config2 = try std.fs.path.join(allocator, &.{ home, ".zc/config.yaml" });
    if (std.fs.accessAbsolute(old_config2, .{})) |_| {
        return old_config2;
    } else |_| {
        allocator.free(old_config2);
    }

    // 检查当前目录的 config.yaml
    std.fs.cwd().access("config.yaml", .{}) catch return null;
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

/// 获取默认配置目录路径 (~/.config/zc)
pub fn getDefaultConfigDir(allocator: std.mem.Allocator) !?[]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".config/zc" });
}


/// 下载结果结构体
pub const DownloadResult = struct {
    status: std.http.Status,
    body: []const u8,
};

/// fetchConfig 内部函数：执行 HTTP 请求获取配置内容
/// 可独立测试，验证 User-Agent 等头部设置
pub fn fetchConfig(allocator: std.mem.Allocator, url: []const u8) !DownloadResult {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_writer.writer,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "clash" },
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

    const config_path = try std.fs.path.join(allocator, &.{ configs_dir, yaml_filename });
    defer allocator.free(config_path);

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();
    try file.writeAll(fetch_result.body);

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

    const config_path = try std.fs.path.join(allocator, &.{ configs_dir, yaml_filename });
    defer allocator.free(config_path);

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();
    try file.writeAll(fetch_result.body);

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

        const file_path = try std.fs.path.join(allocator, &.{ configs_dir, yaml_name });
        defer allocator.free(file_path);

        std.fs.accessAbsolute(file_path, .{}) catch {
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
