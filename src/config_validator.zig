const std = @import("std");
const config_mod = @import("config.zig");
const Config = @import("config.zig").Config;
const ProxyType = @import("config.zig").ProxyType;
const RuleType = @import("config.zig").RuleType;

/// 校验错误类型
pub const ValidationError = struct {
    message: []const u8,

    pub fn format(self: ValidationError, allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, self.message);
    }
};

/// 校验结果
pub const ValidationResult = struct {
    errors: std.ArrayList(ValidationError),
    warnings: std.ArrayList(ValidationError),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        var result: ValidationResult = undefined;
        result.allocator = allocator;
        result.errors = std.ArrayList(ValidationError).empty;
        result.warnings = std.ArrayList(ValidationError).empty;
        return result;
    }

    pub fn deinit(self: *ValidationResult) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        for (self.warnings.items) |warn| {
            self.allocator.free(warn.message);
        }
        self.errors.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
    }

    pub fn isValid(self: *const ValidationResult) bool {
        return self.errors.items.len == 0;
    }

    fn addError(self: *ValidationResult, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.errors.append(self.allocator, .{ .message = msg });
    }

    fn addWarning(self: *ValidationResult, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.warnings.append(self.allocator, .{ .message = msg });
    }
};

/// 校验配置
pub fn validate(allocator: std.mem.Allocator, config: *Config) !ValidationResult {
    var result = ValidationResult.init(allocator);
    errdefer result.deinit();

    // 校验基础配置
    try validateBasicConfig(config, &result);

    // Clamp AnyTLS idle session pool tunables (§15) — mutates config in place.
    try clampIdleSessionTunables(config, &result);

    // 校验代理节点
    try validateProxies(allocator, config, &result);

    // 校验代理组
    try validateProxyGroups(allocator, config, &result);

    // 校验规则
    try validateRules(allocator, config, &result);

    // 校验引用关系
    try validateReferences(allocator, config, &result);

    return result;
}

/// 校验基础配置
fn validateBasicConfig(config: *const Config, result: *ValidationResult) !void {
    // 校验端口
    if (config.port > 0 and !isValidPort(config.port)) {
        try result.addError("Invalid HTTP port: {d} (must be 1-65535)", .{config.port});
    }
    if (config.socks_port > 0 and !isValidPort(config.socks_port)) {
        try result.addError("Invalid SOCKS port: {d} (must be 1-65535)", .{config.socks_port});
    }
    if (config.mixed_port > 0 and !isValidPort(config.mixed_port)) {
        try result.addError("Invalid mixed port: {d} (must be 1-65535)", .{config.mixed_port});
    }

    // 检查端口冲突（mixed-port 开启时，覆盖 port/socks-port）
    if (config.mixed_port > 0) {
        if (config.port > 0) {
            try result.addWarning("mixed-port is set; HTTP port ({d}) will be ignored", .{config.port});
        }
        if (config.socks_port > 0) {
            try result.addWarning("mixed-port is set; SOCKS port ({d}) will be ignored", .{config.socks_port});
        }
    } else if (config.port > 0 and config.port == config.socks_port) {
        try result.addError("HTTP port ({d}) and SOCKS port ({d}) cannot be the same", .{ config.port, config.socks_port });
    }

    // 检查模式
    if (!std.mem.eql(u8, config.mode, "rule") and
        !std.mem.eql(u8, config.mode, "global") and
        !std.mem.eql(u8, config.mode, "direct"))
    {
        try result.addError("Invalid mode: '{s}' (must be 'rule', 'global', or 'direct')", .{config.mode});
    }

    // 检查日志级别
    if (!std.mem.eql(u8, config.log_level, "debug") and
        !std.mem.eql(u8, config.log_level, "info") and
        !std.mem.eql(u8, config.log_level, "warning") and
        !std.mem.eql(u8, config.log_level, "error") and
        !std.mem.eql(u8, config.log_level, "silent"))
    {
        try result.addError("Unknown log level: '{s}'", .{config.log_level});
    }

    if (!std.mem.eql(u8, config.bind_address, "*") and !isValidIPv4(config.bind_address)) {
        try result.addError("Invalid bind-address: '{s}' (use '*' or IPv4)", .{config.bind_address});
    }
    if (!config.allow_lan and !std.mem.eql(u8, config.bind_address, "*")) {
        try result.addWarning("allow-lan=false: bind-address '{s}' will be ignored, using 127.0.0.1", .{config.bind_address});
    }

    // external-controller 格式校验（host:port）
    if (config.external_controller) |ec| {
        const colon_pos = std.mem.lastIndexOf(u8, ec, ":") orelse {
            try result.addError("Invalid external-controller '{s}' (expected host:port)", .{ec});
            return;
        };
        const port_str = ec[colon_pos + 1 ..];
        const p = std.fmt.parseInt(u16, port_str, 10) catch {
            try result.addError("Invalid external-controller port in '{s}'", .{ec});
            return;
        };
        if (!isValidPort(p)) {
            try result.addError("Invalid external-controller port: {d} (must be 1-65535)", .{p});
        }
    }

    // 检查是否至少有一个监听端口
    if (config.port == 0 and config.socks_port == 0 and config.mixed_port == 0) {
        try result.addError("At least one port (port, socks-port, or mixed-port) must be configured", .{});
    }
}

/// Clamp the AnyTLS idle session pool tunables (§15). The two interval/timeout
/// values are clamped INDEPENDENTLY: any value <= 5 (seconds) is forced to the
/// 30s default and a warning is recorded. `min_idle_session` is NOT clamped.
/// Takes a mutable Config because it overrides the offending values in place;
/// callers run this BEFORE building a PoolConfig from the config.
pub fn clampIdleSessionTunables(config: *Config, result: *ValidationResult) !void {
    if (config.idle_session_check_interval <= 5) {
        try result.addWarning(
            "idle-session-check-interval={d}s is too low (<=5s); clamped to 30s",
            .{config.idle_session_check_interval},
        );
        config.idle_session_check_interval = 30;
    }
    if (config.idle_session_timeout <= 5) {
        try result.addWarning(
            "idle-session-timeout={d}s is too low (<=5s); clamped to 30s",
            .{config.idle_session_timeout},
        );
        config.idle_session_timeout = 30;
    }
    // min_idle_session is intentionally unclamped (§15).
}

/// 校验代理节点
fn validateProxies(allocator: std.mem.Allocator, config: *const Config, result: *ValidationResult) !void {
    var name_set = std.StringHashMap(void).init(allocator);
    defer name_set.deinit();

    // udp:true is anytls-only; subscriptions often set it on every node. Count
    // the offenders and emit a single rolled-up warning after the loop instead
    // of one line per proxy (which floods ~90 lines on a typical airport sub).
    var udp_ignored_count: usize = 0;
    var udp_ignored_first: []const u8 = "";

    for (config.proxies.items, 0..) |proxy, i| {
        // 检查名称是否为空
        if (proxy.name.len == 0) {
            try result.addError("Proxy #{d}: name cannot be empty", .{i + 1});
            continue;
        }

        // 检查名称是否重复
        if (name_set.contains(proxy.name)) {
            try result.addError("Duplicate proxy name: '{s}'", .{proxy.name});
        } else {
            try name_set.put(proxy.name, {});
        }

        // 根据代理类型校验
        switch (proxy.proxy_type) {
            .direct, .reject => {
                // 不需要额外校验
            },
            .http => {
                if (proxy.server.len == 0) {
                    try result.addError("HTTP proxy '{s}': server cannot be empty", .{proxy.name});
                }
                if (!isValidPort(proxy.port)) {
                    try result.addError("HTTP proxy '{s}': invalid port {d}", .{ proxy.name, proxy.port });
                }
            },
            .socks5 => {
                if (proxy.server.len == 0) {
                    try result.addError("SOCKS5 proxy '{s}': server cannot be empty", .{proxy.name});
                }
                if (!isValidPort(proxy.port)) {
                    try result.addError("SOCKS5 proxy '{s}': invalid port {d}", .{ proxy.name, proxy.port });
                }
            },
            .ss => {
                if (proxy.server.len == 0) {
                    try result.addError("Shadowsocks proxy '{s}': server cannot be empty", .{proxy.name});
                }
                if (!isValidPort(proxy.port)) {
                    try result.addError("Shadowsocks proxy '{s}': invalid port {d}", .{ proxy.name, proxy.port });
                }
                if (proxy.password == null or proxy.password.?.len == 0) {
                    try result.addError("Shadowsocks proxy '{s}': password is required", .{proxy.name});
                }
                if (proxy.cipher == null or proxy.cipher.?.len == 0) {
                    try result.addError("Shadowsocks proxy '{s}': cipher is required", .{proxy.name});
                } else {
                    // 检查加密方式
                    const valid_ciphers = [_][]const u8{ "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "aes-128-cfb", "aes-192-cfb", "aes-256-cfb", "chacha20-ietf-poly1305", "chacha20-poly1305", "rc4-md5", "none" };
                    var valid = false;
                    for (valid_ciphers) |cipher| {
                        if (std.mem.eql(u8, proxy.cipher.?, cipher)) {
                            valid = true;
                            break;
                        }
                    }
                    if (!valid) {
                        try result.addWarning("Shadowsocks proxy '{s}': unknown cipher '{s}'", .{ proxy.name, proxy.cipher.? });
                    }
                }
            },
            .vmess => {
                if (proxy.server.len == 0) {
                    try result.addError("VMess proxy '{s}': server cannot be empty", .{proxy.name});
                }
                if (!isValidPort(proxy.port)) {
                    try result.addError("VMess proxy '{s}': invalid port {d}", .{ proxy.name, proxy.port });
                }
                if (proxy.uuid == null or proxy.uuid.?.len == 0) {
                    try result.addError("VMess proxy '{s}': uuid is required", .{proxy.name});
                } else if (!isValidUUID(proxy.uuid.?)) {
                    try result.addError("VMess proxy '{s}': invalid uuid format", .{proxy.name});
                }
            },
            .trojan => {
                if (proxy.server.len == 0) {
                    try result.addError("Trojan proxy '{s}': server cannot be empty", .{proxy.name});
                }
                if (!isValidPort(proxy.port)) {
                    try result.addError("Trojan proxy '{s}': invalid port {d}", .{ proxy.name, proxy.port });
                }
                if (proxy.password == null or proxy.password.?.len == 0) {
                    try result.addError("Trojan proxy '{s}': password is required", .{proxy.name});
                }
                // Trojan client is CONNECT-only (handshake() always sends
                // Command.connect); UDP ASSOCIATE is unimplemented. Fail config
                // validation early instead of deferring to a connect-time
                // error.UdpNotSupportedByProxy. (The shared udp roll-up warning
                // below ALSO fires for trojan; the error dominates isValid().)
                if (proxy.udp) {
                    try result.addError("Trojan proxy '{s}': udp:true is not supported (Trojan UDP ASSOCIATE is not implemented)", .{proxy.name});
                }
            },
            .vless => {
                if (proxy.server.len == 0) {
                    try result.addError("VLESS proxy '{s}': server cannot be empty", .{proxy.name});
                }
                if (!isValidPort(proxy.port)) {
                    try result.addError("VLESS proxy '{s}': invalid port {d}", .{ proxy.name, proxy.port });
                }
                if (proxy.uuid == null or proxy.uuid.?.len == 0) {
                    try result.addError("VLESS proxy '{s}': uuid is required", .{proxy.name});
                } else if (!isValidUUID(proxy.uuid.?)) {
                    try result.addError("VLESS proxy '{s}': invalid uuid format", .{proxy.name});
                }
            },
            .anytls => {
                if (proxy.server.len == 0) {
                    try result.addError("AnyTLS proxy '{s}': server cannot be empty", .{proxy.name});
                }
                if (!isValidPort(proxy.port)) {
                    try result.addError("AnyTLS proxy '{s}': invalid port {d}", .{ proxy.name, proxy.port });
                }
                if (proxy.password == null or proxy.password.?.len == 0) {
                    try result.addError("AnyTLS proxy '{s}': password is required", .{proxy.name});
                }
            },
        }

        // udp:true is only honored for anytls proxies (UDP relay is anytls-only
        // for now). Tally — and ignore — when set on any other proxy type; the
        // rolled-up warning is emitted once after the loop.
        if (proxy.udp and proxy.proxy_type != .anytls) {
            if (udp_ignored_count == 0) udp_ignored_first = proxy.name;
            udp_ignored_count += 1;
        }
    }

    if (udp_ignored_count == 1) {
        try result.addWarning("Proxy '{s}': udp:true is only supported for anytls proxies; ignored", .{udp_ignored_first});
    } else if (udp_ignored_count > 1) {
        try result.addWarning("udp:true is set on {d} non-anytls proxies (e.g. '{s}'); anytls-only, ignored", .{ udp_ignored_count, udp_ignored_first });
    }
}

/// 校验代理组
fn validateProxyGroups(allocator: std.mem.Allocator, config: *const Config, result: *ValidationResult) !void {
    var name_set = std.StringHashMap(void).init(allocator);
    defer name_set.deinit();

    for (config.proxy_groups.items, 0..) |group, i| {
        // 检查名称是否为空
        if (group.name.len == 0) {
            try result.addError("Proxy group #{d}: name cannot be empty", .{i + 1});
            continue;
        }

        // 检查名称是否重复
        if (name_set.contains(group.name)) {
            try result.addError("Duplicate proxy group name: '{s}'", .{group.name});
        } else {
            try name_set.put(group.name, {});
        }

        // 检查节点列表
        if (group.proxies.items.len == 0) {
            try result.addError("Proxy group '{s}': proxy list cannot be empty", .{group.name});
        }

        // url-test 和 fallback 需要 URL
        if (group.group_type == .url_test or group.group_type == .fallback) {
            if (group.url == null or group.url.?.len == 0) {
                try result.addError("Proxy group '{s}' ({s}): url is required", .{ group.name, @tagName(group.group_type) });
            } else if (!isValidURL(group.url.?)) {
                try result.addWarning("Proxy group '{s}': url '{s}' may be invalid", .{ group.name, group.url.? });
            }
        }
    }
}

/// 校验规则
fn validateRules(allocator: std.mem.Allocator, config: *const Config, result: *ValidationResult) !void {
    _ = allocator;
    for (config.rules.items, 0..) |rule, i| {
        // 检查 payload
        if (rule.payload.len == 0 and rule.rule_type != .final) {
            try result.addError("Rule #{d}: payload cannot be empty", .{i + 1});
        }

        // 根据规则类型校验 payload
        switch (rule.rule_type) {
            .ip_cidr, .ip_cidr6, .src_ip_cidr => {
                if (!isValidCIDR(rule.payload)) {
                    try result.addError("Rule #{d}: invalid CIDR format '{s}'", .{ i + 1, rule.payload });
                }
            },
            .dst_port, .src_port => {
                if (!isValidPortRange(rule.payload)) {
                    try result.addError("Rule #{d}: invalid port range '{s}'", .{ i + 1, rule.payload });
                }
            },
            .rule_set => {
                if (rule.payload.len == 0) {
                    try result.addError("Rule #{d}: RULE-SET provider name cannot be empty", .{i + 1});
                }
            },
            else => {},
        }
    }
}

/// 校验引用关系
fn validateReferences(allocator: std.mem.Allocator, config: *const Config, result: *ValidationResult) !void {
    // 收集所有代理节点名称
    var proxy_names = std.StringHashMap(void).init(allocator);
    defer proxy_names.deinit();

    for (config.proxies.items) |proxy| {
        try proxy_names.put(proxy.name, {});
    }

    // 收集所有代理组名称
    var group_names = std.StringHashMap(void).init(allocator);
    defer group_names.deinit();

    for (config.proxy_groups.items) |group| {
        try group_names.put(group.name, {});
    }

    // 收集 rule-provider 名称
    var provider_names = std.StringHashMap(void).init(allocator);
    defer provider_names.deinit();

    for (config.rule_providers.items) |provider| {
        try provider_names.put(provider.name, {});
    }

    // 检查代理组中的引用（代理组可以引用其他代理组）
    for (config.proxy_groups.items) |group| {
        for (group.proxies.items) |proxy_name| {
            // 检查是否是代理节点
            const is_proxy = proxy_names.contains(proxy_name);
            // 检查是否是代理组
            const is_group = group_names.contains(proxy_name);

            const is_builtin = std.mem.eql(u8, proxy_name, "DIRECT") or std.mem.eql(u8, proxy_name, "REJECT");

            if (!is_proxy and !is_group and !is_builtin) {
                try result.addError("Proxy group '{s}': references undefined proxy or group '{s}'", .{ group.name, proxy_name });
            }
        }
    }

    // 检查规则中的引用（规则可以引用代理或代理组）
    for (config.rules.items, 0..) |rule, i| {
        if (rule.rule_type == .rule_set) {
            if (!provider_names.contains(rule.payload)) {
                try result.addError("Rule #{d}: references undefined rule-provider '{s}'", .{ i + 1, rule.payload });
            }
            if (!std.mem.eql(u8, rule.target, "DIRECT") and
                !std.mem.eql(u8, rule.target, "REJECT") and
                !proxy_names.contains(rule.target) and
                !group_names.contains(rule.target))
            {
                try result.addError("Rule #{d}: references undefined target '{s}'", .{ i + 1, rule.target });
            }
            continue;
        }

        const target = rule.target;
        if (!std.mem.eql(u8, target, "DIRECT") and
            !std.mem.eql(u8, target, "REJECT") and
            !proxy_names.contains(target) and
            !group_names.contains(target))
        {
            try result.addError("Rule #{d}: references undefined target '{s}'", .{ i + 1, target });
        }
    }

    // Clash 配置里代理组允许在列表中包含自身名称（常用于 UI 快捷入口），
    // 因此这里不再把“自引用”当作错误。
}

// ============ 辅助函数 ============

fn isValidPort(port: u16) bool {
    return port >= 1 and port <= 65535;
}

fn isValidUUID(uuid: []const u8) bool {
    // UUID 格式: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 字符)
    if (uuid.len != 36) return false;

    const expected_dashes = [_]usize{ 8, 13, 18, 23 };
    for (expected_dashes) |pos| {
        if (uuid[pos] != '-') return false;
    }

    // 检查十六进制字符
    for (uuid, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isHex(c)) return false;
    }

    return true;
}

fn isValidCIDR(cidr: []const u8) bool {
    // 简单检查：包含 / 且前后都有内容
    const slash_pos = std.mem.indexOf(u8, cidr, "/");
    if (slash_pos == null) return false;

    const ip_part = cidr[0..slash_pos.?];
    const mask_part = cidr[slash_pos.? + 1 ..];

    if (ip_part.len == 0 or mask_part.len == 0) return false;

    // 检查掩码是否是数字
    const mask = std.fmt.parseInt(u8, mask_part, 10) catch return false;

    // 检查是否是 IPv4 或 IPv6
    if (std.mem.indexOf(u8, ip_part, ".") != null) {
        // IPv4
        if (mask > 32) return false;
        // 简单检查四段 IP
        var parts_count: u8 = 0;
        var it = std.mem.splitScalar(u8, ip_part, '.');
        while (it.next()) |part| {
            if (part.len == 0) return false;
            const num = std.fmt.parseInt(u8, part, 10) catch return false;
            if (num > 255) return false;
            parts_count += 1;
        }
        return parts_count == 4;
    } else if (std.mem.indexOf(u8, ip_part, ":") != null) {
        // IPv6
        return mask <= 128;
    }

    return false;
}

fn isValidPortRange(range: []const u8) bool {
    // 支持格式: 80, 80-443, 80,443,8080
    var it = std.mem.splitAny(u8, range, ",");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.indexOf(u8, trimmed, "-") != null) {
            // 范围格式
            var range_it = std.mem.splitScalar(u8, trimmed, '-');
            const start = range_it.next() orelse return false;
            const end = range_it.next() orelse return false;
            const start_port = std.fmt.parseInt(u16, start, 10) catch return false;
            const end_port = std.fmt.parseInt(u16, end, 10) catch return false;
            if (start_port == 0 or end_port == 0 or start_port > end_port) return false;
        } else {
            // 单个端口
            const port = std.fmt.parseInt(u16, trimmed, 10) catch return false;
            if (port == 0) return false;
        }
    }
    return true;
}

fn isValidURL(url: []const u8) bool {
    // 简单检查：以 http:// 或 https:// 开头
    return std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://");
}

fn isValidIPv4(ip: []const u8) bool {
    var it = std.mem.splitScalar(u8, ip, '.');
    var count: u8 = 0;
    while (it.next()) |part| {
        if (part.len == 0) return false;
        const n = std.fmt.parseInt(u8, part, 10) catch return false;
        _ = n;
        count += 1;
    }
    return count == 4;
}

/// 打印校验结果
pub fn printResult(result: *const ValidationResult) void {
    if (result.errors.items.len > 0) {
        std.debug.print("\n=== Configuration Errors ===\n", .{});
        for (result.errors.items, 1..) |err, i| {
            std.debug.print("  [{d}] {s}\n", .{ i, err.message });
        }
    }

    if (result.warnings.items.len > 0) {
        std.debug.print("\n=== Configuration Warnings ===\n", .{});
        for (result.warnings.items, 1..) |warn, i| {
            std.debug.print("  [{d}] {s}\n", .{ i, warn.message });
        }
    }

    if (result.isValid() and result.warnings.items.len == 0) {
        std.debug.print("\n✓ Configuration is valid\n", .{});
    } else if (result.isValid()) {
        std.debug.print("\n✓ Configuration is valid (with warnings)\n", .{});
    } else {
        std.debug.print("\n✗ Configuration is invalid\n", .{});
    }
}

// ===========================================================================
// C6 — idle session pool tunable clamps (§15).
// ===========================================================================

const base_yaml =
    \\mixed-port: 7899
    \\proxies:
    \\  - name: DIRECT
    \\    type: direct
    \\    server: ""
    \\    port: 0
;

test "C6: validator clamps both sub-5s idle interval/timeout to 30 and warns" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\idle-session-check-interval: 3
        \\idle-session-timeout: 5
        \\min-idle-session: 2
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\    server: ""
        \\    port: 0
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();

    var result = try validate(allocator, &cfg);
    defer result.deinit();

    // Both clamped to 30; min_idle untouched.
    try std.testing.expectEqual(@as(i64, 30), cfg.idle_session_check_interval);
    try std.testing.expectEqual(@as(i64, 30), cfg.idle_session_timeout);
    try std.testing.expectEqual(@as(u32, 2), cfg.min_idle_session);
    // Two clamp warnings recorded; config remains valid (no errors from clamps).
    try std.testing.expect(result.warnings.items.len >= 2);
    try std.testing.expect(result.isValid());
}

test "C6: validator leaves valid idle values and min_idle untouched" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\idle-session-check-interval: 60
        \\idle-session-timeout: 45
        \\min-idle-session: 4
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\    server: ""
        \\    port: 0
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();

    var result = try validate(allocator, &cfg);
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 60), cfg.idle_session_check_interval);
    try std.testing.expectEqual(@as(i64, 45), cfg.idle_session_timeout);
    try std.testing.expectEqual(@as(u32, 4), cfg.min_idle_session);
}

test "C6: validator clamps defaults are valid (no clamp on the 30s default)" {
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parse(allocator, base_yaml);
    defer cfg.deinit();

    var result = try validate(allocator, &cfg);
    defer result.deinit();

    // The 30s defaults are > 5 -> untouched.
    try std.testing.expectEqual(@as(i64, 30), cfg.idle_session_check_interval);
    try std.testing.expectEqual(@as(i64, 30), cfg.idle_session_timeout);
}

fn countUdpWarnings(result: *const ValidationResult) usize {
    var c: usize = 0;
    for (result.warnings.items) |w| {
        if (std.mem.indexOf(u8, w.message, "udp:true") != null) c += 1;
    }
    return c;
}

test "D4: validator warns on non-anytls proxy with udp:true" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: ss-udp
        \\    type: ss
        \\    server: 1.2.3.4
        \\    port: 8388
        \\    password: pw
        \\    cipher: aes-256-gcm
        \\    udp: true
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validate(allocator, &cfg);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), countUdpWarnings(&result));
    try std.testing.expect(result.isValid()); // warning only, not an error
}

test "D4: validator does not warn on anytls proxy with udp:true" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: anytls-udp
        \\    type: anytls
        \\    server: edge.example.com
        \\    port: 443
        \\    password: secret
        \\    udp: true
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validate(allocator, &cfg);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), countUdpWarnings(&result));
}

fn hasErrorContaining(result: *const ValidationResult, needle: []const u8) bool {
    for (result.errors.items) |e| {
        if (std.mem.indexOf(u8, e.message, needle) != null) return true;
    }
    return false;
}

test "udp-reject: trojan proxy with udp:true produces a validation error and isValid()==false" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: trojan-udp
        \\    type: trojan
        \\    server: edge.example.com
        \\    port: 443
        \\    password: secret
        \\    udp: true
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validate(allocator, &cfg);
    defer result.deinit();

    // Trojan UDP ASSOCIATE is unimplemented: udp:true must be a hard error.
    try std.testing.expect(!result.isValid());
    try std.testing.expect(hasErrorContaining(&result, "udp:true is not supported"));
}

test "udp-reject: trojan proxy without udp stays valid" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: trojan-plain
        \\    type: trojan
        \\    server: edge.example.com
        \\    port: 443
        \\    password: secret
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validate(allocator, &cfg);
    defer result.deinit();

    // Guards against the new udp check firing on the default udp=false.
    try std.testing.expect(result.isValid());
    try std.testing.expect(!hasErrorContaining(&result, "udp:true is not supported"));
}
