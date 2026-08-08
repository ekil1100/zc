const std = @import("std");
const config_mod = @import("config.zig");
const compat = @import("compat.zig");
const controller_endpoint = @import("controller_endpoint.zig");
const controller_auth = @import("controller_auth.zig");
const runtime_capability = @import("runtime_capability.zig");
const Config = @import("config.zig").Config;
const RuleType = @import("config.zig").RuleType;

/// Validation retains at most this many errors and warnings combined.
pub const validation_diagnostic_count_max: usize = 256;
/// Each retained diagnostic owns at most this many rendered bytes.
pub const validation_diagnostic_bytes_max: usize = 512;

const diagnostic_error_too_long =
    "Validation error detail omitted: diagnostic exceeded the byte limit";
const diagnostic_warning_too_long =
    "Validation warning detail omitted: diagnostic exceeded the byte limit";
comptime {
    std.debug.assert(validation_diagnostic_count_max > 0);
    std.debug.assert(diagnostic_error_too_long.len <= validation_diagnostic_bytes_max);
    std.debug.assert(diagnostic_warning_too_long.len <= validation_diagnostic_bytes_max);
}

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
    diagnostics_truncated: bool,
    has_errors: bool,

    const DiagnosticKind = enum {
        err,
        warning,

        fn oversizedMessage(kind: DiagnosticKind) []const u8 {
            return switch (kind) {
                .err => diagnostic_error_too_long,
                .warning => diagnostic_warning_too_long,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(ValidationError).empty,
            .warnings = std.ArrayList(ValidationError).empty,
            .diagnostics_truncated = false,
            .has_errors = false,
        };
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
        return !self.has_errors;
    }

    fn addError(
        self: *ValidationResult,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        self.has_errors = true;
        try self.addDiagnostic(&self.errors, .err, fmt, args);
    }

    fn addWarning(
        self: *ValidationResult,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.addDiagnostic(&self.warnings, .warning, fmt, args);
    }

    fn addDiagnostic(
        self: *ValidationResult,
        destination: *std.ArrayList(ValidationError),
        kind: DiagnosticKind,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const diagnostic_count = self.errors.items.len +
            self.warnings.items.len;
        if (diagnostic_count >= validation_diagnostic_count_max) {
            self.diagnostics_truncated = true;
            return;
        }

        var buffer: [validation_diagnostic_bytes_max]u8 = undefined;
        const rendered: []const u8 = std.fmt.bufPrint(
            &buffer,
            fmt,
            args,
        ) catch blk: {
            self.diagnostics_truncated = true;
            break :blk kind.oversizedMessage();
        };
        const message = try self.allocator.dupe(u8, rendered);
        errdefer self.allocator.free(message);
        try destination.append(self.allocator, .{ .message = message });
    }
};

const CapabilityValidationMode = runtime_capability.Mode;

/// 校验配置
pub fn validate(allocator: std.mem.Allocator, config: *Config) !ValidationResult {
    return validateConfig(allocator, config, .runtime);
}

/// Validates an immutable raw catalog capture without turning a marked plugin
/// incompatibility into permission to skip unrelated offline checks.
pub fn validateCatalogCapture(
    allocator: std.mem.Allocator,
    config: *Config,
) !ValidationResult {
    return validateConfig(allocator, config, .catalog_capture);
}

fn validateConfig(
    allocator: std.mem.Allocator,
    config: *Config,
    capability_mode: CapabilityValidationMode,
) !ValidationResult {
    try config_mod.requireConfigResourceLimits(config);
    var result = ValidationResult.init(allocator);
    errdefer result.deinit();

    try validateV1Capabilities(config, &result, capability_mode);

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

pub fn validateRuntimeCapabilities(
    allocator: std.mem.Allocator,
    config: *const Config,
) !ValidationResult {
    try config_mod.requireConfigResourceLimits(config);
    var result = ValidationResult.init(allocator);
    errdefer result.deinit();
    try validateV1Capabilities(config, &result, .runtime);
    return result;
}

fn validateV1Capabilities(
    config: *const Config,
    result: *ValidationResult,
    mode: CapabilityValidationMode,
) !void {
    const globals = runtime_capability.assessGlobals(config);
    for (globals.items()) |failure| {
        try addGlobalCapabilityError(result, failure);
    }

    for (config.proxies.items) |*proxy| {
        const assessment = runtime_capability.assessProxy(proxy);
        for (assessment.items()) |failure| {
            if (!runtime_capability.reportsProxyFailure(
                mode,
                proxy,
                failure,
            )) continue;
            try addProxyCapabilityError(result, proxy, failure);
        }
    }

    for (config.proxy_groups.items) |*group| {
        const assessment = runtime_capability.assessProxyGroup(group);
        for (assessment.items()) |failure| {
            try addProxyGroupCapabilityError(result, group, failure);
        }
    }
}

fn addGlobalCapabilityError(
    result: *ValidationResult,
    failure: runtime_capability.Failure,
) !void {
    switch (failure) {
        .global_port => try result.addError(
            "port is not supported in zc v1.0; use mixed-port",
            .{},
        ),
        .global_socks_port => try result.addError(
            "socks-port is not supported in zc v1.0; use mixed-port",
            .{},
        ),
        else => unreachable,
    }
}

fn addProxyCapabilityError(
    result: *ValidationResult,
    proxy: *const config_mod.Proxy,
    failure: runtime_capability.Failure,
) !void {
    switch (failure) {
        .reserved_proxy_name => try result.addError(
            "Proxy '{s}': reserved proxy name cannot be declared by users",
            .{proxy.name},
        ),
        .plugin_metadata_requires_shadowsocks => try result.addError(
            "Proxy '{s}': plugin metadata is only supported for type 'ss'",
            .{proxy.name},
        ),
        .unsupported_proxy_type => |proxy_type| try result.addError(
            "Proxy '{s}': type '{s}' is not supported in zc v1.0; " ++
                "supported types: direct, reject, ss, trojan",
            .{ proxy.name, @tagName(proxy_type) },
        ),
        .shadowsocks => |ss_failure| try addShadowsocksCapabilityError(
            result,
            proxy,
            ss_failure,
        ),
        .unsupported_shadowsocks_cipher => |cipher| try result.addError(
            "Proxy '{s}': Shadowsocks cipher '{s}' is not supported in " ++
                "zc v1.0",
            .{ proxy.name, cipher },
        ),
        .websocket_not_supported => |proxy_type| try result.addError(
            "Proxy '{s}': ws-opts is not supported for type '{s}' in " ++
                "zc v1.0",
            .{ proxy.name, @tagName(proxy_type) },
        ),
        .trojan_udp_not_supported => try result.addError(
            "Proxy '{s}': udp:true is not supported for type 'trojan' in " ++
                "zc v1.0",
            .{proxy.name},
        ),
        else => unreachable,
    }
}

fn addProxyGroupCapabilityError(
    result: *ValidationResult,
    group: *const config_mod.ProxyGroup,
    failure: runtime_capability.Failure,
) !void {
    switch (failure) {
        .reserved_proxy_group_name => try result.addError(
            "Proxy group '{s}': reserved proxy group name cannot be " ++
                "declared by users",
            .{group.name},
        ),
        .unsupported_proxy_group_type => |group_type| try result.addError(
            "Proxy group '{s}': type '{s}' is not supported in zc v1.0; " ++
                "supported type: select",
            .{ group.name, @tagName(group_type) },
        ),
        else => unreachable,
    }
}

fn addShadowsocksCapabilityError(
    result: *ValidationResult,
    proxy: *const config_mod.Proxy,
    failure: runtime_capability.ShadowsocksFailure,
) !void {
    switch (failure) {
        .tls_not_supported => try result.addError(
            "Proxy '{s}': tls:true is not supported for type 'ss' in zc v1.0",
            .{proxy.name},
        ),
        .inconsistent_plugin_fields => try result.addError(
            "Proxy '{s}': Shadowsocks plugin options do not match a plugin " ++
                "declaration",
            .{proxy.name},
        ),
        .unsupported_plugin => try result.addError(
            "Proxy '{s}': Shadowsocks plugin '{s}' is not supported; " ++
                "supported plugins: obfs, obfs-local (HTTP mode only)",
            .{ proxy.name, proxy.plugin orelse "" },
        ),
        .missing_plugin_options => try result.addError(
            "Proxy '{s}': simple-obfs requires an explicit plugin-opts map",
            .{proxy.name},
        ),
        .malformed_plugin_options => try result.addError(
            "Proxy '{s}': simple-obfs plugin options are malformed",
            .{proxy.name},
        ),
        .missing_obfs_mode => try result.addError(
            "Proxy '{s}': simple-obfs requires explicit mode: http",
            .{proxy.name},
        ),
        .unsupported_obfs_mode => try result.addError(
            "Proxy '{s}': simple-obfs mode '{s}' is not supported; " ++
                "supported mode: http",
            .{ proxy.name, proxy.obfs_mode orelse "" },
        ),
        .missing_obfs_host => try result.addError(
            "Proxy '{s}': simple-obfs requires a non-empty host",
            .{proxy.name},
        ),
        .invalid_obfs_host => try result.addError(
            "Proxy '{s}': simple-obfs host contains CR, LF, or NUL",
            .{proxy.name},
        ),
        .obfs_host_too_long => try result.addError(
            "Proxy '{s}': simple-obfs host exceeds 255 bytes",
            .{proxy.name},
        ),
    }
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

    // v1 exposes the controller only on an explicit IPv4 loopback endpoint.
    if (config.external_controller) |value| {
        _ = controller_endpoint.parse(value) catch {
            try result.addError(
                "Invalid external-controller '{s}' (expected 127.0.0.1:PORT)",
                .{value},
            );
        };
    }
    if (config.secret) |secret| {
        if (secret.len != 0 and !controller_auth.isValidSecret(secret)) {
            try result.addError(
                "Invalid controller secret (use at most {d} characters from " ++
                    "A-Z, a-z, 0-9, '-', '.', '_' or '~')",
                .{controller_auth.max_secret_bytes},
            );
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
                // Disabling cert verification is a real security downgrade;
                // keep it visible even when another capability check rejects the
                // same proxy.
                if (proxy.skip_cert_verify) {
                    try result.addWarning("Trojan proxy '{s}': skip-cert-verify=true disables TLS certificate verification", .{proxy.name});
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
            .ip_cidr, .src_ip_cidr => {
                if (!isValidCIDR(rule.payload, false)) {
                    try result.addError("Rule #{d}: invalid IPv4 CIDR format '{s}'", .{ i + 1, rule.payload });
                }
            },
            .ip_cidr6 => {
                if (!isValidCIDR(rule.payload, true)) {
                    try result.addError("Rule #{d}: invalid IPv6 CIDR format '{s}'", .{ i + 1, rule.payload });
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

fn isValidCIDR(cidr: []const u8, ipv6: bool) bool {
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
            if (range_it.next() != null) return false;
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

    if (result.diagnostics_truncated) {
        std.debug.print(
            "\n... Additional validation diagnostic details were omitted " ++
                "(max {d} entries, {d} bytes each).\n",
            .{
                validation_diagnostic_count_max,
                validation_diagnostic_bytes_max,
            },
        );
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
    \\  - name: direct-node
    \\    type: direct
    \\    server: ""
    \\    port: 0
;

const ResourceValidationPath = enum {
    runtime_config,
    runtime_capabilities,
    catalog_capture,
};

fn validateResourcePath(
    path: ResourceValidationPath,
    allocator: std.mem.Allocator,
    config: *Config,
) !ValidationResult {
    return switch (path) {
        .runtime_config => validate(allocator, config),
        .runtime_capabilities => validateRuntimeCapabilities(allocator, config),
        .catalog_capture => validateCatalogCapture(allocator, config),
    };
}

fn expectResourceValidationError(
    expected: anyerror,
    result: anyerror!ValidationResult,
) !void {
    if (result) |value| {
        var validation = value;
        validation.deinit();
        return error.TestExpectedError;
    } else |actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

fn makeManualResourceValidationConfig(
    proxies: []config_mod.Proxy,
    groups: []config_mod.ProxyGroup,
) Config {
    return .{
        .allocator = std.testing.allocator,
        .mode = "must-not-scan",
        .log_level = "must-not-scan",
        .bind_address = "must-not-scan",
        .proxies = .{ .items = proxies, .capacity = proxies.len },
        .proxy_groups = .{ .items = groups, .capacity = groups.len },
        .rules = .empty,
    };
}

test "manual config resource maxima plus one stop every validator before scans" {
    const allocator = std.testing.allocator;
    const proxy_storage = try allocator.alloc(config_mod.Proxy, 4097);
    defer allocator.free(proxy_storage);
    for (proxy_storage) |*proxy| {
        proxy.* = .{
            .name = "DIRECT",
            .proxy_type = .http,
            .server = "",
            .port = 0,
        };
    }
    const group_storage = try allocator.alloc(config_mod.ProxyGroup, 1025);
    defer allocator.free(group_storage);
    for (group_storage) |*group| {
        group.* = .{
            .name = "DIRECT",
            .group_type = .url_test,
            .proxies = .empty,
        };
    }

    for ([_]ResourceValidationPath{
        .runtime_config,
        .runtime_capabilities,
        .catalog_capture,
    }) |path| {
        var proxy_config = makeManualResourceValidationConfig(
            proxy_storage,
            group_storage[0..0],
        );
        var proxy_failing = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = 0,
        });
        try expectResourceValidationError(
            error.ProxyCountLimitExceeded,
            validateResourcePath(path, proxy_failing.allocator(), &proxy_config),
        );
        try std.testing.expectEqual(@as(usize, 0), proxy_failing.allocations);
        try std.testing.expect(!proxy_failing.has_induced_failure);

        var group_config = makeManualResourceValidationConfig(
            proxy_storage[0..0],
            group_storage,
        );
        var group_failing = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = 0,
        });
        try expectResourceValidationError(
            error.ProxyGroupCountLimitExceeded,
            validateResourcePath(path, group_failing.allocator(), &group_config),
        );
        try std.testing.expectEqual(@as(usize, 0), group_failing.allocations);
        try std.testing.expect(!group_failing.has_induced_failure);
    }
}

test "manual proxy group member overflow stops every validator before allocation" {
    const allocator = std.testing.allocator;
    const member_storage = try allocator.alloc(
        []const u8,
        config_mod.proxy_group_member_count_max + 1,
    );
    defer allocator.free(member_storage);
    @memset(member_storage, "DIRECT");
    var groups = [_]config_mod.ProxyGroup{.{
        .name = "bounded",
        .group_type = .select,
        .proxies = .{
            .items = member_storage,
            .capacity = member_storage.len,
        },
    }};

    for ([_]ResourceValidationPath{
        .runtime_config,
        .runtime_capabilities,
        .catalog_capture,
    }) |path| {
        var manual = makeManualResourceValidationConfig(&.{}, &groups);
        var failing = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = 0,
        });
        try expectResourceValidationError(
            error.ProxyGroupMemberCountLimitExceeded,
            validateResourcePath(path, failing.allocator(), &manual),
        );
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expect(!failing.has_induced_failure);
    }
}

test "diagnostic storage cap preserves invalid status after warnings fill it" {
    // Fill the shared storage with warnings, then prove an omitted error still
    // controls validity without allocating a 257th diagnostic.
    var result = ValidationResult.init(std.testing.allocator);
    defer result.deinit();

    for (0..validation_diagnostic_count_max) |index| {
        try result.addWarning("warning {d}", .{index});
    }
    try result.addError("error omitted after warnings", .{});

    try std.testing.expectEqual(
        validation_diagnostic_count_max,
        result.errors.items.len + result.warnings.items.len,
    );
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expect(result.diagnostics_truncated);
    try std.testing.expect(!result.isValid());
}

test "long group diagnostics stay bounded at maximum member count" {
    // A 64 KiB group name repeated across 5122 missing-member messages would
    // amplify to hundreds of MiB without both caps. The validator must finish
    // inside 2 MiB and leave no allocation reported by the bounded debug layer.
    const allocator = std.testing.allocator;
    const group_name = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(group_name);
    @memset(group_name, 'g');

    const members = try allocator.alloc(
        []const u8,
        config_mod.proxy_group_member_count_max,
    );
    defer allocator.free(members);
    @memset(members, "undefined-member");
    var groups = [_]config_mod.ProxyGroup{.{
        .name = group_name,
        .group_type = .select,
        .proxies = .{
            .items = members,
            .capacity = members.len,
        },
    }};
    var manual = makeManualResourceValidationConfig(&.{}, &groups);

    const memory = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    const BoundedDiagnosticAllocator = std.heap.DebugAllocator(.{
        .backing_allocator_zeroes = false,
        .page_size = 4096,
        .stack_trace_frames = 0,
        .thread_safe = false,
    });
    var diagnostic_allocator: BoundedDiagnosticAllocator = .{
        .backing_allocator = fixed.allocator(),
    };
    {
        var result = try validate(diagnostic_allocator.allocator(), &manual);
        defer result.deinit();

        try std.testing.expect(!result.isValid());
        try std.testing.expect(result.diagnostics_truncated);
        try std.testing.expectEqual(
            validation_diagnostic_count_max,
            result.errors.items.len + result.warnings.items.len,
        );
        var oversized_detail_omitted = false;
        for (result.errors.items) |diagnostic| {
            try std.testing.expect(
                diagnostic.message.len <= validation_diagnostic_bytes_max,
            );
            if (std.mem.eql(
                u8,
                diagnostic.message,
                diagnostic_error_too_long,
            )) {
                oversized_detail_omitted = true;
            }
        }
        try std.testing.expect(oversized_detail_omitted);
        for (result.warnings.items) |diagnostic| {
            try std.testing.expect(
                diagnostic.message.len <= validation_diagnostic_bytes_max,
            );
        }
    }
    try std.testing.expectEqual(
        std.heap.Check.ok,
        diagnostic_allocator.deinit(),
    );
}

test "validator rejects reserved declarations but preserves policy literals" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "DIRECT", "REJECT" }) |reserved_name| {
        const document = try std.fmt.allocPrint(
            allocator,
            "mixed-port: 7890\nproxies:\n  - name: {s}\n    type: direct\nrules:\n  - MATCH,{s}\n",
            .{ reserved_name, reserved_name },
        );
        defer allocator.free(document);
        var cfg = try config_mod.parseDocument(allocator, document);
        defer cfg.deinit();

        var result = try validate(allocator, &cfg);
        defer result.deinit();
        try std.testing.expect(!result.isValid());
        try std.testing.expect(hasErrorContaining(&result, "reserved proxy name"));
        var runtime_result = try validateRuntimeCapabilities(allocator, &cfg);
        defer runtime_result.deinit();
        try std.testing.expect(!runtime_result.isValid());
        try std.testing.expect(
            hasErrorContaining(&runtime_result, "reserved proxy name"),
        );
    }

    for ([_][]const u8{ "DIRECT", "REJECT" }) |reserved_name| {
        const document = try std.fmt.allocPrint(
            allocator,
            "mixed-port: 7890\nproxies: []\nproxy-groups:\n  - name: {s}\n    type: select\n    proxies: [DIRECT]\nrules:\n  - MATCH,{s}\n",
            .{ reserved_name, reserved_name },
        );
        defer allocator.free(document);
        var cfg = try config_mod.parseDocument(allocator, document);
        defer cfg.deinit();

        var result = try validateRuntimeCapabilities(allocator, &cfg);
        defer result.deinit();
        try std.testing.expect(!result.isValid());
        try std.testing.expect(
            hasErrorContaining(&result, "reserved proxy group name"),
        );
    }

    var literals = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies: []
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
        \\rules:
        \\  - DOMAIN,example.com,DIRECT
        \\  - MATCH,REJECT
    );
    defer literals.deinit();
    var literal_result = try validate(allocator, &literals);
    defer literal_result.deinit();
    try std.testing.expect(literal_result.isValid());
}

test "catalog validation exempts only explicitly marked plugin capability errors" {
    const allocator = std.testing.allocator;
    const malformed_proxy =
        \\  - name: recoverable
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: "obfs=http"
    ;
    const valid_document = try std.fmt.allocPrint(
        allocator,
        "mixed-port: 7890\nproxies:\n{s}\nrules:\n  - MATCH,recoverable\n",
        .{malformed_proxy},
    );
    defer allocator.free(valid_document);
    var valid = try config_mod.parseCatalogDocument(allocator, valid_document);
    defer valid.deinit();
    var valid_result = try validateCatalogCapture(allocator, &valid);
    defer valid_result.deinit();
    try std.testing.expect(valid_result.isValid());

    const cases = [_]struct {
        suffix: []const u8,
        needle: []const u8,
    }{
        .{
            .suffix =
            \\proxy-groups:
            \\  - name: REJECT
            \\    type: select
            \\    proxies: [recoverable]
            \\rules:
            \\  - MATCH,REJECT
            ,
            .needle = "reserved proxy group name",
        },
        .{
            .suffix =
            \\  - name: disabled
            \\    type: http
            \\    server: example.com
            \\    port: 8080
            \\rules:
            \\  - MATCH,recoverable
            ,
            .needle = "type 'http' is not supported",
        },
        .{
            .suffix =
            \\proxy-groups:
            \\  - name: automatic
            \\    type: url-test
            \\    proxies: [recoverable]
            \\    url: https://example.com/ping
            \\rules:
            \\  - MATCH,automatic
            ,
            .needle = "type 'url_test' is not supported",
        },
        .{
            .suffix =
            \\rules:
            \\  - MATCH,undefined-target
            ,
            .needle = "undefined target",
        },
        .{
            .suffix =
            \\mode: unsupported
            \\rules:
            \\  - MATCH,recoverable
            ,
            .needle = "Invalid mode",
        },
    };
    for (cases) |case| {
        const document = try std.fmt.allocPrint(
            allocator,
            "mixed-port: 7890\nproxies:\n{s}\n{s}\n",
            .{ malformed_proxy, case.suffix },
        );
        defer allocator.free(document);
        var cfg = try config_mod.parseCatalogDocument(allocator, document);
        defer cfg.deinit();
        var result = try validateCatalogCapture(allocator, &cfg);
        defer result.deinit();
        try std.testing.expect(!result.isValid());
        try std.testing.expect(hasErrorContaining(&result, case.needle));
    }

    var reserved = try config_mod.parseCatalogDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: DIRECT
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: "obfs=http"
        \\rules:
        \\  - MATCH,DIRECT
    );
    defer reserved.deinit();
    var reserved_result = try validateCatalogCapture(allocator, &reserved);
    defer reserved_result.deinit();
    try std.testing.expect(!reserved_result.isValid());
    try std.testing.expect(
        hasErrorContaining(&reserved_result, "reserved proxy name"),
    );

    var udp = try config_mod.parseCatalogDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: malformed-udp
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    udp: true
        \\    plugin: obfs
        \\    plugin-opts: "obfs=http"
        \\rules:
        \\  - MATCH,malformed-udp
    );
    defer udp.deinit();
    var udp_result = try validateCatalogCapture(allocator, &udp);
    defer udp_result.deinit();
    try std.testing.expect(udp_result.isValid());

    const non_plugin_cases = [_]struct {
        cipher: []const u8 = "aes-128-gcm",
        extra: []const u8,
        needle: []const u8,
    }{
        .{ .extra = "    tls: true\n", .needle = "tls:true" },
        .{
            .cipher = "aes-128-cfb",
            .extra = "",
            .needle = "cipher 'aes-128-cfb'",
        },
        .{
            .extra = "    ws-opts: { path: /ws }\n",
            .needle = "ws-opts",
        },
    };
    for (non_plugin_cases) |case| {
        const document = try std.fmt.allocPrint(
            allocator,
            "mixed-port: 7890\nproxies:\n" ++
                "  - name: malformed-extra\n" ++
                "    type: ss\n" ++
                "    server: example.com\n" ++
                "    port: 8388\n" ++
                "    cipher: {s}\n" ++
                "    password: secret\n" ++
                "    plugin: obfs\n" ++
                "    plugin-opts: \"obfs=http\"\n" ++
                "{s}rules:\n  - MATCH,malformed-extra\n",
            .{ case.cipher, case.extra },
        );
        defer allocator.free(document);
        var cfg = try config_mod.parseCatalogDocument(allocator, document);
        defer cfg.deinit();
        var result = try validateCatalogCapture(allocator, &cfg);
        defer result.deinit();
        try std.testing.expect(!result.isValid());
        try std.testing.expect(hasErrorContaining(&result, case.needle));
    }
}

test "v1 controller requires an explicit IPv4 loopback endpoint" {
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\external-controller: 0.0.0.0:9090
    );
    defer cfg.deinit();

    var result = try validate(allocator, &cfg);
    defer result.deinit();
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqual(@as(usize, 1), result.errors.items.len);
    try std.testing.expectEqualStrings(
        "Invalid external-controller '0.0.0.0:9090' " ++
            "(expected 127.0.0.1:PORT)",
        result.errors.items[0].message,
    );
}

test "controller secret must be a valid bearer token" {
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\external-controller: 127.0.0.1:9090
        \\secret: "line break"
    );
    defer cfg.deinit();

    var result = try validate(allocator, &cfg);
    defer result.deinit();
    try std.testing.expect(!result.isValid());
    try std.testing.expect(hasErrorContaining(&result, "controller secret"));
}

test "v1 capability gate rejects VMess before runtime" {
    // Validation must fail before an unsupported protocol can bind or dial.
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: vmess-node
        \\    type: vmess
        \\    server: example.com
        \\    port: 443
        \\    uuid: 12345678-1234-1234-1234-123456789abc
        \\rules:
        \\  - MATCH,vmess-node
    );
    defer cfg.deinit();

    var result = try validate(allocator, &cfg);
    defer result.deinit();
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqual(@as(usize, 1), result.errors.items.len);
    try std.testing.expectEqualStrings(
        "Proxy 'vmess-node': type 'vmess' is not supported in zc v1.0; " ++
            "supported types: direct, reject, ss, trojan",
        result.errors.items[0].message,
    );
}

test "v1 capability gate rejects an unimplemented Shadowsocks cipher" {
    // Capability checks must use the same cipher set as the runtime dialer.
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: legacy-ss
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-cfb
        \\    password: secret
        \\rules:
        \\  - MATCH,legacy-ss
    );
    defer cfg.deinit();

    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqual(@as(usize, 1), result.errors.items.len);
    try std.testing.expectEqualStrings(
        "Proxy 'legacy-ss': Shadowsocks cipher 'aes-128-cfb' is not " ++
            "supported in zc v1.0",
        result.errors.items[0].message,
    );
}

test "v1 capability gate rejects Shadowsocks plugins" {
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: plugin-ss
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: v2ray-plugin
        \\rules:
        \\  - MATCH,plugin-ss
    );
    defer cfg.deinit();

    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();
    try std.testing.expect(!result.isValid());
    try std.testing.expect(hasErrorContaining(&result, "plugins"));
    try std.testing.expectError(
        error.InvalidProxyFormat,
        config_mod.parse(allocator,
            \\mixed-port: 7890
            \\proxies:
            \\  - name: malformed-plugin
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: true
        ),
    );
}

test "runtime capability gate rejects plugin metadata on every non-Shadowsocks type" {
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: direct-plugin
        \\    type: direct
        \\    plugin: obfs
        \\  - name: reject-derived
        \\    type: reject
        \\    plugin-opts: { mode: http, host: example.com }
        \\  - name: trojan-underscore
        \\    type: trojan
        \\    server: example.com
        \\    port: 443
        \\    password: secret
        \\    plugin: obfs
        \\    plugin_opts: { mode: http, host: example.com }
        \\  - name: semantic-malformed
        \\    type: direct
        \\rules:
        \\  - MATCH,DIRECT
    );
    defer cfg.deinit();
    cfg.proxies.items[3].semantic_state = .malformed;

    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), result.errors.items.len);
    for (cfg.proxies.items) |proxy| {
        try std.testing.expect(hasErrorContaining(&result, proxy.name));
    }
    try std.testing.expect(
        hasErrorContaining(&result, "plugin metadata is only supported"),
    );
}

test "Shadowsocks capability gate accepts only plain and explicit simple-obfs HTTP" {
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: plain
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\  - name: mihomo-http
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-256-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts:
        \\      mode: http
        \\      host: cdn.example.com
        \\  - name: sip003-http
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: chacha20-ietf-poly1305
        \\    password: secret
        \\    plugin: obfs-local
        \\    plugin_opts:
        \\      mode: http
        \\      host: edge.example.com
        \\rules:
        \\  - MATCH,plain
    );
    defer cfg.deinit();

    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();
    try std.testing.expect(result.isValid());
}

test "Shadowsocks capability gate explains every unsupported obfs shape" {
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: tls-mode
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: { mode: tls, host: example.com }
        \\  - name: unknown-mode
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: { mode: quic, host: example.com }
        \\  - name: unknown-plugin
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: v2ray-plugin
        \\  - name: missing-options
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\  - name: missing-host
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs-local
        \\    plugin-opts: { mode: http }
        \\  - name: injected-host
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: { mode: http, host: "safe\\r\\nInjected" }
        \\  - name: derived-without-plugin
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin-opts: { mode: http, host: example.com }
        \\  - name: ss-udp
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    udp: true
        \\rules:
        \\  - MATCH,REJECT
    );
    defer cfg.deinit();
    for (cfg.proxies.items) |*proxy| {
        if (!std.mem.eql(u8, proxy.name, "injected-host")) continue;
        allocator.free(proxy.obfs_host.?);
        proxy.obfs_host = try allocator.dupe(u8, "safe\r\nInjected");
    }

    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 7), result.errors.items.len);
    const expected = [_][]const u8{
        "mode 'tls'",
        "mode 'quic'",
        "v2ray-plugin",
        "explicit plugin-opts map",
        "non-empty host",
        "CR, LF, or NUL",
        "do not match a plugin declaration",
    };
    for (expected) |needle| {
        try std.testing.expect(hasErrorContaining(&result, needle));
    }
}

test "legacy malformed plugin options remain runtime-rejected" {
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parse(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: legacy-malformed
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts:
        \\      mode: http
        \\      host: example.com
        \\      unknown: retained-in-raw-profile
    );
    defer cfg.deinit();
    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();
    try std.testing.expect(!result.isValid());
    try std.testing.expect(hasErrorContaining(&result, "malformed"));
}

test "v1 capability gate rejects non-select proxy groups" {
    // Parsed group strategies must not imply runtime scheduling support.
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: ss-node
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\proxy-groups:
        \\  - name: auto
        \\    type: url-test
        \\    proxies: [ss-node]
        \\    url: https://example.com/ping
        \\rules:
        \\  - MATCH,auto
    );
    defer cfg.deinit();

    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqualStrings(
        "Proxy group 'auto': type 'url_test' is not supported in zc v1.0; " ++
            "supported type: select",
        result.errors.items[0].message,
    );
}

test "v1 capability gate rejects ignored transports on supported proxies" {
    // Accepted fields must not silently degrade to a different wire transport.
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: ss-transport
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    tls: true
        \\    ws-opts:
        \\      path: /ws
    );
    defer cfg.deinit();

    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.errors.items.len);
    try std.testing.expect(hasErrorContaining(&result, "tls:true"));
    try std.testing.expect(hasErrorContaining(&result, "ws-opts"));
}

test "v1 capability gate rejects standalone inbound ports" {
    // v1 exposes one mixed listener and must not silently clear other listeners.
    const allocator = std.testing.allocator;
    var cfg = try config_mod.parseDocument(
        allocator,
        "port: 7890\nsocks-port: 7891\n",
    );
    defer cfg.deinit();

    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.errors.items.len);
    try std.testing.expect(hasErrorContaining(&result, "port"));
    try std.testing.expect(hasErrorContaining(&result, "socks-port"));
}

test "C6: validator clamps both sub-5s idle interval/timeout to 30 and warns" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\idle-session-check-interval: 3
        \\idle-session-timeout: 5
        \\min-idle-session: 2
        \\proxies:
        \\  - name: direct-node
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
        \\  - name: direct-node
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

test "v1 capability gate accepts classic Shadowsocks UDP ciphers and alias" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - { name: aes128, type: ss, server: 1.2.3.4, port: 8388, password: pw, cipher: aes-128-gcm, udp: true }
        \\  - { name: aes256, type: ss, server: 1.2.3.4, port: 8388, password: pw, cipher: aes-256-gcm, udp: true }
        \\  - { name: chacha, type: ss, server: 1.2.3.4, port: 8388, password: pw, cipher: chacha20-ietf-poly1305, udp: true }
        \\  - name: chacha-alias-obfs
        \\    type: ss
        \\    server: 1.2.3.4
        \\    port: 8388
        \\    password: pw
        \\    cipher: chacha20-poly1305
        \\    udp: true
        \\    plugin: obfs
        \\    plugin-opts: { mode: http, host: cdn.example.com }
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();

    try std.testing.expect(result.isValid());
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
}

test "v1 capability gate rejects every unverified proxy type" {
    // One document exercises the complete negative protocol space.
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - { name: http-node, type: http, server: example.com, port: 8080 }
        \\  - { name: socks-node, type: socks5, server: example.com, port: 1080 }
        \\  - { name: vmess-node, type: vmess, server: example.com, port: 443, uuid: 12345678-1234-1234-1234-123456789abc }
        \\  - { name: vless-node, type: vless, server: example.com, port: 443, uuid: 12345678-1234-1234-1234-123456789abc }
        \\  - { name: anytls-node, type: anytls, server: example.com, port: 443, password: secret }
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 5), result.errors.items.len);
    const names = [_][]const u8{
        "http-node",
        "socks-node",
        "vmess-node",
        "vless-node",
        "anytls-node",
    };
    for (names) |name| {
        try std.testing.expect(hasErrorContaining(&result, name));
    }
}

fn hasErrorContaining(result: *const ValidationResult, needle: []const u8) bool {
    for (result.errors.items) |e| {
        if (std.mem.indexOf(u8, e.message, needle) != null) return true;
    }
    return false;
}

test "v1 capability gate rejects Trojan udp" {
    // An unsupported transport declaration must fail before runtime traffic.
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
    var result = try validateRuntimeCapabilities(allocator, &cfg);
    defer result.deinit();

    try std.testing.expect(!result.isValid());
    try std.testing.expectEqual(@as(usize, 1), result.errors.items.len);
    try std.testing.expectEqualStrings(
        "Proxy 'trojan-udp': udp:true is not supported for type 'trojan' " ++
            "in zc v1.0",
        result.errors.items[0].message,
    );
}

test "trojan proxy without udp stays valid" {
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

    // Guards against the udp check firing on the default udp=false.
    try std.testing.expect(result.isValid());
    try std.testing.expect(!hasErrorContaining(&result, "udp:true is not supported"));
}

test "Trojan UDP subscriptions fail closed and retain TLS warnings" {
    // Every unsupported node is rejected while independent TLS risks stay visible.
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: HK-1
        \\    type: trojan
        \\    server: hk1.example.com
        \\    port: 443
        \\    password: secret
        \\    sni: m.ctrip.com
        \\    skip-cert-verify: true
        \\    udp: true
        \\  - name: JP-1
        \\    type: trojan
        \\    server: jp1.example.com
        \\    port: 443
        \\    password: secret
        \\    sni: m.ctrip.com
        \\    skip-cert-verify: true
        \\    udp: true
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validate(allocator, &cfg);
    defer result.deinit();

    try std.testing.expect(!result.isValid());
    try std.testing.expectEqual(@as(usize, 2), result.errors.items.len);
    try std.testing.expect(hasErrorContaining(&result, "HK-1"));
    try std.testing.expect(hasErrorContaining(&result, "JP-1"));
    try std.testing.expectEqual(@as(usize, 2), countTrojanCertWarnings(&result));
}

// Counts trojan skip-cert-verify warnings (substring-scoped, mirrors
// countUdpWarnings) so happy-path tests can assert "clean" precisely without
// depending on the total warning count.
fn countTrojanCertWarnings(result: *const ValidationResult) usize {
    var c: usize = 0;
    for (result.warnings.items) |w| {
        if (std.mem.indexOf(u8, w.message, "skip-cert-verify") != null) c += 1;
    }
    return c;
}

test "validator-hardening: trojan happy-path validates clean with no skip-cert warning" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: trojan-ok
        \\    type: trojan
        \\    server: edge.example.com
        \\    port: 443
        \\    password: secret
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validate(allocator, &cfg);
    defer result.deinit();

    try std.testing.expect(result.isValid());
    try std.testing.expectEqual(@as(usize, 0), countTrojanCertWarnings(&result));
}

test "validator-hardening: trojan empty server produces error" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: trojan-noserver
        \\    type: trojan
        \\    server: ""
        \\    port: 443
        \\    password: secret
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validate(allocator, &cfg);
    defer result.deinit();

    try std.testing.expect(!result.isValid());
    try std.testing.expect(hasErrorContaining(&result, "server cannot be empty"));
}

test "validator-hardening: trojan port 0 is rejected at parse time" {
    const allocator = std.testing.allocator;
    // The parser guards invalid ports before validation runs: a server-bearing
    // proxy with port 0 fails config_mod.parse with error.InvalidProxyPort, so
    // the validator's isValidPort branch is never reached via YAML. Assert the
    // actual rejection point (parse) rather than the unreachable validator arm.
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: trojan-badport
        \\    type: trojan
        \\    server: edge.example.com
        \\    port: 0
        \\    password: secret
    ;
    try std.testing.expectError(error.InvalidProxyPort, config_mod.parse(allocator, yaml_config));
}

test "validator-hardening: trojan missing password produces error" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: trojan-nopw
        \\    type: trojan
        \\    server: edge.example.com
        \\    port: 443
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validate(allocator, &cfg);
    defer result.deinit();

    try std.testing.expect(!result.isValid());
    try std.testing.expect(hasErrorContaining(&result, "password is required"));
}

test "validator-hardening: trojan skip-cert-verify=true emits one warning and stays valid" {
    const allocator = std.testing.allocator;
    const yaml_config =
        \\mixed-port: 7899
        \\proxies:
        \\  - name: trojan-skipcert
        \\    type: trojan
        \\    server: edge.example.com
        \\    port: 443
        \\    password: secret
        \\    skip-cert-verify: true
    ;
    var cfg = try config_mod.parse(allocator, yaml_config);
    defer cfg.deinit();
    var result = try validate(allocator, &cfg);
    defer result.deinit();

    // Warning, not error: config stays valid.
    try std.testing.expect(result.isValid());
    try std.testing.expectEqual(@as(usize, 1), countTrojanCertWarnings(&result));
}
