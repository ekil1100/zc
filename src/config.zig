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
    cipher: ?[]const u8 = null, // For Shadowsocks
    uuid: ?[]const u8 = null, // For VMess/VLESS
    alter_id: ?u16 = null, // For VMess
    tls: bool = false,
    sni: ?[]const u8 = null,
    ws_opts: ?WsOptions = null, // WebSocket options
    obfs: ?[]const u8 = null, // Obfuscation type
    obfs_host: ?[]const u8 = null, // host header for obfs

    pub const WsOptions = struct {
        path: ?[]const u8 = null,
        headers: ?std.StringHashMap([]const u8) = null,
    };
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
    proxies: []const []const u8,
    url: ?[]const u8 = null, // For url-test/fallback
    interval: ?u32 = null, // seconds
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
    match, // FINAL
};

pub const Rule = struct {
    rule_type: RuleType,
    value: []const u8,
    action: []const u8, // Proxy group name or DIRECT/REJECT
    no_resolve: bool = false,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    port: u16 = 7890,
    socks_port: u16 = 7891,
    mixed_port: ?u16 = null,
    allow_lan: bool = false,
    bind_address: []const u8 = "127.0.0.1",
    mode: []const u8 = "rule",
    log_level: []const u8 = "info",
    external_controller: ?[]const u8 = null,
    proxies: std.ArrayList(Proxy),
    proxy_groups: std.ArrayList(ProxyGroup),
    rules: std.ArrayList(Rule),

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
            .proxies = std.ArrayList(Proxy).init(allocator),
            .proxy_groups = std.ArrayList(ProxyGroup).init(allocator),
            .rules = std.ArrayList(Rule).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.proxies.deinit();
        self.proxy_groups.deinit();
        self.rules.deinit();
    }

    /// 从 YAML 文件解析配置
    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(content);
        return try fromYaml(allocator, content);
    }

    /// 从 YAML 内容解析配置
    pub fn fromYaml(allocator: std.mem.Allocator, content: []const u8) !Config {
        var config = Config.init(allocator);
        errdefer config.deinit();

        // 使用 YAML 解析器
        var doc = try yaml.parse(allocator, content);
        defer doc.deinit();

        // 解析基本配置
        if (doc.get("port")) |port_val| {
            config.port = @intCast(port_val.asInt() orelse 7890);
        }
        if (doc.get("socks-port")) |socks_val| {
            config.socks_port = @intCast(socks_val.asInt() orelse 7891);
        }
        if (doc.get("mixed-port")) |mixed_val| {
            config.mixed_port = @intCast(mixed_val.asInt() orelse 0);
        }

        // 解析代理节点
        if (doc.get("proxies")) |proxies_val| {
            if (proxies_val.asArray()) |arr| {
                for (arr.items) |proxy_val| {
                    const proxy = try parseProxy(allocator, proxy_val);
                    try config.proxies.append(proxy);
                }
            }
        }

        // 解析代理组
        if (doc.get("proxy-groups")) |groups_val| {
            if (groups_val.asArray()) |arr| {
                for (arr.items, 0..) |group_val, i| {
                    _ = i;
                    const group = try parseProxyGroup(allocator, group_val);
                    try config.proxy_groups.append(group);
                }
            }
        }

        // 解析规则
        if (doc.get("rules")) |rules_val| {
            if (rules_val.asArray()) |arr| {
                for (arr.items) |rule_val| {
                    const rule = try parseRule(allocator, rule_val);
                    try config.rules.append(rule);
                }
            }
        }

        return config;
    }

    /// 从文件加载配置
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        return try Config.fromYaml(allocator, content);
    }

    /// 加载默认配置
    pub fn loadDefault(allocator: std.mem.Allocator) !Config {
        const config_path = try getCurrentConfigPath(allocator) orelse {
            return error.NoConfigFile;
        };
        defer allocator.free(config_path);
        return try Config.load(allocator, config_path);
    }

    fn parseProxy(allocator: std.mem.Allocator, val: yaml.Value) !Proxy {
        var proxy = Proxy{
            .name = undefined,
            .proxy_type = .direct,
            .server = undefined,
            .port = 0,
        };

        if (val.get("name")) |name_val| {
            proxy.name = try allocator.dupe(u8, name_val.asString() orelse "");
        }

        if (val.get("type")) |type_val| {
            const type_str = type_val.asString() orelse "";
            proxy.proxy_type = parseProxyType(type_str);
        }

        if (val.get("server")) |server_val| {
            proxy.server = try allocator.dupe(u8, server_val.asString() orelse "");
        }

        if (val.get("port")) |port_val| {
            proxy.port = @intCast(port_val.asInt() orelse 0);
        }

        // 解析协议特定字段
        if (val.get("password")) |pass_val| {
            proxy.password = try allocator.dupe(u8, pass_val.asString() orelse "");
        }

        if (val.get("uuid")) |uuid_val| {
            proxy.uuid = try allocator.dupe(u8, uuid_val.asString() orelse "");
        }

        if (val.get("tls")) |tls_val| {
            proxy.tls = tls_val.asBool() orelse false;
        }

        return proxy;
    }

    fn parseProxyType(type_str: []const u8) ProxyType {
        if (std.mem.eql(u8, type_str, "direct")) return .direct;
        if (std.mem.eql(u8, type_str, "reject")) return .reject;
        if (std.mem.eql(u8, type_str, "http")) return .http;
        if (std.mem.eql(u8, type_str, "socks5")) return .socks5;
        if (std.mem.eql(u8, type_str, "ss")) return .ss;
        if (std.mem.eql(u8, type_str, "vmess")) return .vmess;
        if (std.mem.eql(u8, type_str, "trojan")) return .trojan;
        if (std.mem.eql(u8, type_str, "vless")) return .vless;
        return .direct;
    }

    fn parseProxyGroup(allocator: std.mem.Allocator, val: yaml.Value) !ProxyGroup {
        var group = ProxyGroup{
            .name = undefined,
            .group_type = .select,
            .proxies = &.{},
        };

        if (val.get("name")) |name_val| {
            group.name = try allocator.dupe(u8, name_val.asString() orelse "");
        }

        if (val.get("type")) |type_val| {
            const type_str = type_val.asString() orelse "";
            group.group_type = parseProxyGroupType(type_str);
        }

        if (val.get("proxies")) |proxies_val| {
            if (proxies_val.asArray()) |arr| {
                var proxies = try allocator.alloc([]const u8, arr.items.len);
                for (arr.items, 0..) |proxy_val, i| {
                    proxies[i] = try allocator.dupe(u8, proxy_val.asString() orelse "");
                }
                group.proxies = proxies;
            }
        }

        return group;
    }

    fn parseProxyGroupType(type_str: []const u8) ProxyGroupType {
        if (std.mem.eql(u8, type_str, "select")) return .select;
        if (std.mem.eql(u8, type_str, "url-test")) return .url_test;
        if (std.mem.eql(u8, type_str, "fallback")) return .fallback;
        if (std.mem.eql(u8, type_str, "load-balance")) return .load_balance;
        if (std.mem.eql(u8, type_str, "relay")) return .relay;
        return .select;
    }

    fn parseRule(allocator: std.mem.Allocator, val: yaml.Value) !Rule {
        var rule = Rule{
            .rule_type = .match,
            .value = "",
            .action = "DIRECT",
        };

        const rule_str = val.asString() orelse "";
        // 解析规则字符串格式: "TYPE,VALUE,ACTION"
        var parts = std.mem.split(u8, rule_str, ",");
        
        if (parts.next()) |type_str| {
            rule.rule_type = parseRuleType(type_str);
        }
        if (parts.next()) |value_str| {
            rule.value = try allocator.dupe(u8, value_str);
        }
        if (parts.next()) |action_str| {
            rule.action = try allocator.dupe(u8, action_str);
        }

        return rule;
    }

    fn parseRuleType(type_str: []const u8) RuleType {
        if (std.mem.eql(u8, type_str, "DOMAIN")) return .domain;
        if (std.mem.eql(u8, type_str, "DOMAIN-SUFFIX")) return .domain_suffix;
        if (std.mem.eql(u8, type_str, "DOMAIN-KEYWORD")) return .domain_keyword;
        if (std.mem.eql(u8, type_str, "IP-CIDR")) return .ip_cidr;
        if (std.mem.eql(u8, type_str, "IP-CIDR6")) return .ip_cidr6;
        if (std.mem.eql(u8, type_str, "GEOIP")) return .geoip;
        if (std.mem.eql(u8, type_str, "SRC-IP-CIDR")) return .src_ip_cidr;
        if (std.mem.eql(u8, type_str, "DST-PORT")) return .dst_port;
        if (std.mem.eql(u8, type_str, "SRC-PORT")) return .src_port;
        if (std.mem.eql(u8, type_str, "PROCESS-NAME")) return .process_name;
        if (std.mem.eql(u8, type_str, "MATCH")) return .match;
        return .match;
    }
};

/// 获取默认配置目录
pub fn getDefaultConfigDir(allocator: std.mem.Allocator) !?[]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        return null;
    };
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".config", "zc" });
}

/// 获取当前使用的配置文件路径
pub fn getCurrentConfigPath(allocator: std.mem.Allocator) !?[]const u8 {
    const config_dir = try getDefaultConfigDir(allocator) orelse return null;
    defer allocator.free(config_dir);
    return try std.fs.path.join(allocator, &.{ config_dir, "config.yaml" });
}

/// 验证配置文件格式
pub fn validateConfig(allocator: std.mem.Allocator, path: []const u8) !bool {
    _ = allocator;
    // Check if file exists and is readable
    std.fs.accessAbsolute(path, .{}) catch return false;
    // TODO: Parse and validate YAML structure
    return true;
}

/// 生成配置文件名从 URL
fn generateConfigFilenameFromUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // Extract domain from URL
    const start = if (std.mem.indexOf(u8, url, "://")) |i| i + 3 else 0;
    const end = std.mem.indexOf(u8, url[start..], "/") orelse url.len - start;
    const domain = url[start..start + end];
    
    // Clean domain name for filename
    const clean = try allocator.dupe(u8, domain);
    for (clean) |*c| {
        if (c.* == ':' or c.* == '/' or c.* == '?' or c.* == '&' or c.* == '=') {
            c.* = '_';
        }
    }
    return clean;
}

/// 从时间戳生成配置文件名
fn generateConfigFilenameFromTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
    return std.fmt.allocPrint(allocator, "config_{d}", .{timestamp});
}

/// 下载配置文件从 URL 并保存到默认位置
/// name: 可选的自定义文件名，为 null 则从 URL 提取域名作为文件名
/// 返回: 实际使用的文件名（需要调用者释放内存），出错返回 null
pub fn downloadConfig(allocator: std.mem.Allocator, url: []const u8, name: ?[]const u8) !?[]const u8 {
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

    // 使用 curl 下载配置文件
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",
            "-fsSL",
            "-H", "User-Agent: clash",
            "-H", "Accept: */*",
            "-o", config_path,
            url,
        },
    }) catch |err| {
        std.debug.print("Failed to download config: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Failed to download config: curl exited with code {d}\n", .{result.term.Exited});
        std.debug.print("Error: {s}\n", .{result.stderr});
        return error.DownloadFailed;
    }

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

    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;

        const is_active = if (active_target) |target|
            std.mem.eql(u8, entry.name, std.fs.path.basename(target))
        else
            false;

        if (is_active) {
            std.debug.print("  * {s} (active)\n", .{entry.name});
        } else {
            std.debug.print("    {s}\n", .{entry.name});
        }
        count += 1;
    }

    if (count == 0) {
        std.debug.print("  (no configs found)\n", .{});
    }
}

/// 切换到指定的配置文件
pub fn switchConfig(allocator: std.mem.Allocator, filename: []const u8) !void {
    const config_dir = try getDefaultConfigDir(allocator) orelse {
        std.debug.print("Could not determine config directory\n", .{});
        return error.NoConfigDir;
    };
    defer allocator.free(config_dir);

    // 确保文件名以 .yaml 结尾
    const target_name = if (std.mem.endsWith(u8, filename, ".yaml"))
        filename
    else
        try std.fmt.allocPrint(allocator, "{s}.yaml", .{filename});
    defer if (!std.mem.endsWith(u8, filename, ".yaml")) allocator.free(target_name);

    // 检查目标文件是否存在
    const target_path = try std.fs.path.join(allocator, &.{ config_dir, target_name });
    defer allocator.free(target_path);

    std.fs.accessAbsolute(target_path, .{}) catch {
        std.debug.print("Config not found: {s}\nUse 'zc --list-configs' to see available configs\n", .{target_path});
        return error.ConfigNotFound;
    };

    // 创建符号链接
    const link_path = try std.fs.path.join(allocator, &.{ config_dir, "config.yaml" });
    defer allocator.free(link_path);

    // 如果已存在，删除旧的符号链接
    std.fs.deleteFileAbsolute(link_path) catch {};

    // 创建新的符号链接（使用相对路径）
    try std.fs.symLinkAbsolute(target_path, link_path, .{});

    std.debug.print("Switched to config: {s}\n", .{target_name});
}

/// 显示当前配置信息
pub fn showCurrentConfig(allocator: std.mem.Allocator) !void {
    const config_path = try getCurrentConfigPath(allocator) orelse {
        std.debug.print("Could not determine config path\n", .{});
        return error.NoConfigDir;
    };
    defer allocator.free(config_path);

    // 检查是否为符号链接
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.readLinkAbsolute(config_path, &buf) catch {
        // 不是符号链接，可能是直接文件
        std.debug.print("Current config: {s} (direct file)\n", .{config_path});
        return;
    };

    std.debug.print("Current config: {s} -> {s}\n", .{ config_path, std.fs.path.basename(target) });
}
