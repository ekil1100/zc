const std = @import("std");
const yaml = @import("util/yaml.zig");

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
    port: u16 = 7899,
    socks_port: u16 = 7891,
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
                // Check for plugin-opts
                if (map.get("plugin-opts")) |opts| {
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
/// 优先级：~/.config/zc/config.yaml > ~/.zc/config.yaml > ./config.yaml
fn getDefaultConfigPath(allocator: std.mem.Allocator) !?[]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    const paths = [_][]const u8{
        "/.config/zc/config.yaml",
        "/.zc/config.yaml",
    };

    for (paths) |rel_path| {
        const full_path = try std.fs.path.join(allocator, &.{ home, rel_path[1..] });
        std.fs.accessAbsolute(full_path, .{}) catch continue;
        return full_path;
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
        \\port: 7899
        \\socks-port: 7891
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

/// 从 URL 提取域名
fn extractDomainFromUrl(allocator: std.mem.Allocator, url: []const u8) !?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;

    const host_component = uri.host orelse return null;

    // 获取 host 字符串
    const host = switch (host_component) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };

    if (host.len == 0) return null;

    // 分配内存复制 host
    var host_copy = try allocator.alloc(u8, host.len);
    @memcpy(host_copy, host);

    // 移除端口号（如果有）
    if (std.mem.indexOfScalar(u8, host_copy, ':')) |colon_pos| {
        host_copy = try allocator.realloc(host_copy, colon_pos);
        host_copy[colon_pos] = 0;
        host_copy = host_copy[0..colon_pos];
    }

    return host_copy;
}

/// 从 URL 生成配置文件名（使用域名）
fn generateConfigFilenameFromUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // 尝试提取域名
    if (try extractDomainFromUrl(allocator, url)) |domain| {
        return domain;
    }

    // 如果提取失败，回退到时间戳
    return try generateConfigFilename(allocator);
}

/// 生成基于时间戳的配置文件名
fn generateConfigFilename(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
    return std.fmt.allocPrint(allocator, "config_{d}", .{timestamp});
}

/// 下载配置文件从 URL 并保存到默认位置
/// name: 可选的自定义文件名，为 null 则从 URL 提取域名作为文件名
/// 返回: 实际使用的文件名（需要调用者释放内存），出错返回 null
pub fn downloadConfig(allocator: std.mem.Allocator, url: []const u8, name: ?[]const u8) !?[]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // 使用 Allocating Writer
    var response_writer = std.Io.Writer.Allocating.init(allocator);
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

    if (result.status != .ok) {
        std.debug.print("Failed to download config: HTTP {d}\n", .{@intFromEnum(result.status)});
        return error.DownloadFailed;
    }

    // 获取默认配置路径
    const config_dir = try getDefaultConfigDir(allocator) orelse {
        std.debug.print("Could not determine config directory\n", .{});
        return error.NoConfigDir;
    };
    defer allocator.free(config_dir);

    // 创建目录
    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Failed to create directory: {s}\n", .{@errorName(err)});
            return err;
        }
    };

    // 确定文件名：使用提供的名字或从 URL 生成
    const filename = if (name) |n|
        try allocator.dupe(u8, n)
    else
        try generateConfigFilenameFromUrl(allocator, url);

    // 确保文件名以 .yaml 结尾
    const final_filename = if (std.mem.endsWith(u8, filename, ".yaml"))
        filename
    else blk: {
        const with_ext = try std.fmt.allocPrint(allocator, "{s}.yaml", .{filename});
        allocator.free(filename);
        break :blk with_ext;
    };

    const config_path = try std.fs.path.join(allocator, &.{ config_dir, final_filename });
    defer allocator.free(config_path);

    // 写入文件
    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();
    try file.writeAll(response_writer.written());

    std.debug.print("Config downloaded to: {s}\n", .{config_path});
    std.debug.print("Use 'zc config use {s}' to activate it\n", .{final_filename});

    return final_filename;
}

/// 列出所有可用的配置文件
pub fn listConfigs(allocator: std.mem.Allocator) !void {
    const config_dir = try getDefaultConfigDir(allocator) orelse {
        std.debug.print("Could not determine config directory\n", .{});
        return error.NoConfigDir;
    };
    defer allocator.free(config_dir);

    var dir = std.fs.openDirAbsolute(config_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No configs directory found at: {s}\n", .{config_dir});
            return;
        }
        return err;
    };
    defer dir.close();

    // 检查是否存在 config.yaml (active config)
    const active_path = try std.fs.path.join(allocator, &.{ config_dir, "config.yaml" });
    defer allocator.free(active_path);

    const has_active = if (std.fs.accessAbsolute(active_path, .{})) |_| true else |_| false;
    var active_target_buf: [std.fs.max_path_bytes]u8 = undefined;
    var active_target: ?[]const u8 = null;

    // 如果 config.yaml 是符号链接，读取目标
    if (has_active) {
        active_target = std.fs.readLinkAbsolute(active_path, &active_target_buf) catch null;
    }

    std.debug.print("Available configs in {s}:\n\n", .{config_dir});

    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".yaml")) {
            count += 1;
            const is_active = blk: {
                if (active_target) |target| {
                    // 检查 entry.name 是否匹配 target 的文件名
                    break :blk std.mem.eql(u8, entry.name, std.fs.path.basename(target));
                }
                break :blk false;
            };

            if (is_active) {
                std.debug.print("  * {s} (active)\n", .{entry.name});
            } else {
                std.debug.print("    {s}\n", .{entry.name});
            }
        }
    }

    if (count == 0) {
        std.debug.print("  (no config files found)\n", .{});
    } else {
        std.debug.print("\nUse 'zc config use <filename>' to switch config\n", .{});
    }
}

/// 获取当前激活的配置文件路径
fn getActiveConfig(allocator: std.mem.Allocator) !?[]const u8 {
    const config_dir = try getDefaultConfigDir(allocator) orelse return null;
    defer allocator.free(config_dir);

    const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config.yaml" });

    // 检查文件是否存在
    std.fs.accessAbsolute(config_path, .{}) catch return null;
    return config_path;
}

/// 切换配置文件（创建符号链接或复制文件）
pub fn switchConfig(allocator: std.mem.Allocator, filename: []const u8) !void {
    const config_dir = try getDefaultConfigDir(allocator) orelse {
        std.debug.print("Could not determine config directory\n", .{});
        return error.NoConfigDir;
    };
    defer allocator.free(config_dir);

    // 验证源文件存在
    const source_path = try std.fs.path.join(allocator, &.{ config_dir, filename });
    defer allocator.free(source_path);

    std.fs.accessAbsolute(source_path, .{}) catch {
        std.debug.print("Config not found: {s}\n", .{source_path});
        std.debug.print("Use 'zc --list-configs' to see available configs\n", .{});
        return error.ConfigNotFound;
    };

    const link_path = try std.fs.path.join(allocator, &.{ config_dir, "config.yaml" });
    defer allocator.free(link_path);

    // 删除旧的符号链接或文件
    std.fs.deleteFileAbsolute(link_path) catch {};

    // 尝试创建符号链接，如果失败则复制文件
    std.fs.symLinkAbsolute(source_path, link_path, .{}) catch |err| {
        // 如果符号链接失败（比如在某些系统上需要权限），则复制文件
        if (err == error.AccessDenied or err == error.NotSupported or err == error.InvalidArgument) {
            try std.fs.copyFileAbsolute(source_path, link_path, .{});
        } else {
            std.debug.print("Failed to create symlink: {s}, copying file instead\n", .{@errorName(err)});
            try std.fs.copyFileAbsolute(source_path, link_path, .{});
        }
    };

    std.debug.print("Switched to config: {s}\n", .{filename});
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
