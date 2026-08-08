const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const yaml = @import("util/yaml.zig");
const meta = @import("meta.zig");
const cli_output = @import("cli/output.zig");
const config_catalog = @import("config_catalog.zig");
const legacy_write_lock = @import("legacy_write_lock.zig");

/// Complete config sources are accepted up to this size. Every file-backed
/// config reader must probe past the boundary rather than silently truncating.
pub const config_source_bytes_max: usize = 16 * 1024 * 1024;

/// Global decoded-YAML budget shared by every mapping and sequence in a
/// document, including unknown compatibility extensions.
pub const yaml_collection_entry_count_max: usize =
    yaml.collection_entry_count_max;
/// Fixed rule-provider and expanded-rule resource contract. Provider entry
/// bytes count the normalized entry bytes retained by `RuleProvider.entries`;
/// expanded rule bytes count the owned payload plus target bytes for every
/// output rule. Classical provider preflight conservatively charges the full
/// normalized entry length as payload bytes.
pub const rule_provider_count_max: usize = 4096;
pub const rule_provider_entry_count_max: usize =
    yaml_collection_entry_count_max;
pub const rule_provider_aggregate_entry_count_max: usize = 262_144;
pub const rule_provider_aggregate_bytes_max: usize = 64 * 1024 * 1024;
/// Raw provider source bytes read or downloaded by one synchronization/load
/// pass. This is independent of the normalized-entry byte budget: comments and
/// low-normalization YAML still consume it.
pub const rule_provider_aggregate_source_bytes_max: usize = 64 * 1024 * 1024;
pub const expanded_rule_count_max: usize = 262_144;
pub const expanded_rule_bytes_max: usize = 64 * 1024 * 1024;

comptime {
    std.debug.assert(
        rule_provider_entry_count_max ==
            rule_provider_aggregate_entry_count_max,
    );
}

/// Fixed resource contract for parsed and manually constructed configurations.
/// The separate limits cover mainstream subscriptions with substantial headroom
/// over the observed 90-node production profile. `proxy_entry_count_max` bounds
/// the compatibility `proxies:` array, which may mix proxies and proxy groups.
pub const proxy_count_max: usize = 4096;
pub const proxy_group_count_max: usize = 1024;
pub const proxy_entry_count_max: usize = std.math.add(
    usize,
    proxy_count_max,
    proxy_group_count_max,
) catch @compileError("proxy resource limits must fit in usize");
pub const proxy_group_member_count_max: usize = std.math.add(
    usize,
    proxy_entry_count_max,
    2,
) catch @compileError("proxy group member limit must fit in usize");
pub const persisted_selection_count_max: usize =
    config_catalog.persisted_selection_count_max;
comptime {
    std.debug.assert(persisted_selection_count_max == proxy_group_count_max);
}

pub const ProxyResourceLimitError = error{
    ProxyCountLimitExceeded,
    ProxyGroupCountLimitExceeded,
    ProxyEntryCountLimitExceeded,
    ProxyGroupMemberCountLimitExceeded,
    PersistedSelectionCountLimitExceeded,
};

pub const RuleResourceLimitError = error{
    RuleProviderCountLimitExceeded,
    RuleProviderAggregateEntryCountLimitExceeded,
    RuleProviderAggregateBytesLimitExceeded,
    RuleProviderAggregateSourceBytesLimitExceeded,
    ExpandedRuleCountLimitExceeded,
    ExpandedRuleBytesLimitExceeded,
};

pub const ConfigResourceLimitError =
    ProxyResourceLimitError || RuleResourceLimitError;

/// Rejects Config list lengths before callers perform any table traversal.
pub fn requireProxyResourceLimits(
    proxy_count: usize,
    proxy_group_count: usize,
) ProxyResourceLimitError!void {
    if (proxy_count > proxy_count_max) return error.ProxyCountLimitExceeded;
    if (proxy_group_count > proxy_group_count_max) {
        return error.ProxyGroupCountLimitExceeded;
    }
    const proxy_entry_count = std.math.add(
        usize,
        proxy_count,
        proxy_group_count,
    ) catch return error.ProxyEntryCountLimitExceeded;
    if (proxy_entry_count > proxy_entry_count_max) {
        return error.ProxyEntryCountLimitExceeded;
    }
}

/// Rejects an oversized compatibility mixed array before classifying entries.
pub fn requireProxyEntryLimit(entry_count: usize) ProxyResourceLimitError!void {
    if (entry_count > proxy_entry_count_max) {
        return error.ProxyEntryCountLimitExceeded;
    }
}

pub fn requireProxyGroupMemberLimit(
    member_count: usize,
) ProxyResourceLimitError!void {
    if (member_count > proxy_group_member_count_max) {
        return error.ProxyGroupMemberCountLimitExceeded;
    }
}

pub fn requirePersistedSelectionLimit(
    selection_count: usize,
) ProxyResourceLimitError!void {
    return config_catalog.requirePersistedSelectionLimit(selection_count);
}

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

pub const PluginOptionsState = enum {
    absent,
    map,
    malformed,
};

pub const ProxySemanticState = enum {
    valid,
    malformed,
};

pub fn isReservedProxyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "DIRECT") or
        std.mem.eql(u8, name, "REJECT");
}

pub fn hasPluginMetadata(proxy: *const Proxy) bool {
    return proxy.semantic_state == .malformed or
        proxy.plugin != null or
        proxy.plugin_options_state != .absent or
        proxy.obfs_mode != null or
        proxy.obfs_host != null;
}

pub const Proxy = struct {
    name: []const u8,
    proxy_type: ProxyType,
    semantic_state: ProxySemanticState = .valid,
    server: []const u8,
    port: u16,
    // Protocol-specific fields
    password: ?[]const u8 = null,
    cipher: ?[]const u8 = null, // SS
    uuid: ?[]const u8 = null, // VMess/VLESS
    alter_id: u16 = 0, // VMess
    tls: bool = false,
    skip_cert_verify: bool = false,
    udp: bool = false, // Enables classic Shadowsocks UDP on mixed ingress.
    sni: ?[]const u8 = null,
    ws: bool = false, // WebSocket
    ws_path: ?[]const u8 = null,
    ws_host: ?[]const u8 = null,
    // Built-in simple-obfs metadata for Shadowsocks. The parser normalizes
    // plugin-opts/plugin_opts maps into these fields; malformed legacy input is
    // retained as a fail-closed state rather than silently becoming plain SS.
    plugin: ?[]const u8 = null,
    plugin_options_state: PluginOptionsState = .absent,
    obfs_mode: ?[]const u8 = null,
    obfs_host: ?[]const u8 = null,

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

fn addExpandedRuleCount(total: usize, increment: usize) RuleResourceLimitError!usize {
    const next = std.math.add(usize, total, increment) catch
        return error.ExpandedRuleCountLimitExceeded;
    if (next > expanded_rule_count_max) {
        return error.ExpandedRuleCountLimitExceeded;
    }
    return next;
}

fn addExpandedRuleBytes(total: usize, increment: usize) RuleResourceLimitError!usize {
    const next = std.math.add(usize, total, increment) catch
        return error.ExpandedRuleBytesLimitExceeded;
    if (next > expanded_rule_bytes_max) {
        return error.ExpandedRuleBytesLimitExceeded;
    }
    return next;
}

fn ownedRuleBytes(rule: Rule) RuleResourceLimitError!usize {
    return std.math.add(usize, rule.payload.len, rule.target.len) catch
        return error.ExpandedRuleBytesLimitExceeded;
}

/// Rejects every bounded Config collection before callers enter nested loops,
/// allocate indexes, consult providers, or construct runtime state. This is the
/// common fail-first gate for parsed and manually assembled Config values.
pub fn requireConfigResourceLimits(
    config: *const Config,
) ConfigResourceLimitError!void {
    try requireProxyResourceLimits(
        config.proxies.items.len,
        config.proxy_groups.items.len,
    );
    for (config.proxy_groups.items) |group| {
        try requireProxyGroupMemberLimit(group.proxies.items.len);
    }

    if (config.rule_providers.items.len > rule_provider_count_max) {
        return error.RuleProviderCountLimitExceeded;
    }

    var entry_count: usize = 0;
    var entry_bytes: usize = 0;
    for (config.rule_providers.items) |provider| {
        if (provider.entries.items.len > rule_provider_entry_count_max) {
            return error.RuleProviderAggregateEntryCountLimitExceeded;
        }
        entry_count = std.math.add(
            usize,
            entry_count,
            provider.entries.items.len,
        ) catch return error.RuleProviderAggregateEntryCountLimitExceeded;
        if (entry_count > rule_provider_aggregate_entry_count_max) {
            return error.RuleProviderAggregateEntryCountLimitExceeded;
        }
        for (provider.entries.items) |entry| {
            entry_bytes = std.math.add(
                usize,
                entry_bytes,
                entry.len,
            ) catch return error.RuleProviderAggregateBytesLimitExceeded;
            if (entry_bytes > rule_provider_aggregate_bytes_max) {
                return error.RuleProviderAggregateBytesLimitExceeded;
            }
        }
    }

    var rule_count: usize = 0;
    var rule_bytes: usize = 0;
    for (config.rules.items) |rule| {
        rule_count = try addExpandedRuleCount(rule_count, 1);
        rule_bytes = try addExpandedRuleBytes(
            rule_bytes,
            try ownedRuleBytes(rule),
        );
    }
}

fn readConfigSource(
    allocator: std.mem.Allocator,
    file: std.Io.File,
) ![]u8 {
    return compat.fileReadBoundedAlloc(
        file,
        allocator,
        config_source_bytes_max,
    ) catch |err| switch (err) {
        error.FileTooLarge => error.ConfigTooLarge,
        else => err,
    };
}

/// Loads one strict runtime YAML document from disk.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try compat.fs.cwd().openFile(path, .{});
    defer file.close(compat.io());

    const content = try readConfigSource(allocator, file);
    defer allocator.free(content);

    return parseDocument(allocator, content);
}

/// Loads one strict managed YAML document from disk.
pub fn loadDocument(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try compat.fs.cwd().openFile(path, .{});
    defer file.close(compat.io());
    const content = try readConfigSource(allocator, file);
    defer allocator.free(content);
    return parseDocument(allocator, content);
}

const ParseMode = enum {
    legacy,
    runtime,
    catalog_capture,

    fn strict(self: ParseMode) bool {
        return self != .legacy;
    }
};

/// Lenient parser retained only for explicit legacy inspection and tests.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Config {
    var root = try yaml.parse(allocator, content);
    defer root.deinit(allocator);
    return parseRoot(allocator, &root, .legacy);
}

/// Parses one complete runtime configuration document.
/// This entry point rejects duplicate keys, malformed tails, and malformed
/// simple-obfs structures.
pub fn parseDocument(allocator: std.mem.Allocator, content: []const u8) !Config {
    var root = try yaml.parseDocument(allocator, content);
    defer root.deinit(allocator);
    return parseRoot(allocator, &root, .runtime);
}

/// Parses a complete document only for immutable catalog capture. YAML syntax
/// and duplicate keys stay strict, while unsafe simple-obfs metadata is retained
/// as an explicitly malformed proxy that runtime paths must reject.
pub fn parseCatalogDocument(
    allocator: std.mem.Allocator,
    content: []const u8,
) !Config {
    var root = try yaml.parseDocument(allocator, content);
    defer root.deinit(allocator);
    return parseRoot(allocator, &root, .catalog_capture);
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

fn requireParsedProxyResources(root: *const yaml.YamlValue) !void {
    std.debug.assert(root.* == .map);
    var proxy_count: usize = 0;
    var proxy_group_count: usize = 0;

    if (root.map.get("proxies")) |entries| {
        if (entries == .array) {
            try requireProxyEntryLimit(entries.array.items.len);
            for (entries.array.items) |*item| {
                if (item.* != .map) continue;
                if (isProxyGroupType(item.map)) {
                    proxy_group_count = std.math.add(
                        usize,
                        proxy_group_count,
                        1,
                    ) catch return error.ProxyGroupCountLimitExceeded;
                    if (proxy_group_count > proxy_group_count_max) {
                        return error.ProxyGroupCountLimitExceeded;
                    }
                } else if (!isSubscriptionInfoNode(item.map)) {
                    proxy_count = std.math.add(
                        usize,
                        proxy_count,
                        1,
                    ) catch return error.ProxyCountLimitExceeded;
                    if (proxy_count > proxy_count_max) {
                        return error.ProxyCountLimitExceeded;
                    }
                }
            }
        }
    }

    if (root.map.get("proxy-groups")) |groups| {
        if (groups == .array) {
            if (groups.array.items.len > proxy_group_count_max) {
                return error.ProxyGroupCountLimitExceeded;
            }
            proxy_group_count = std.math.add(
                usize,
                proxy_group_count,
                groups.array.items.len,
            ) catch return error.ProxyGroupCountLimitExceeded;
        }
    }

    try requireProxyResourceLimits(proxy_count, proxy_group_count);
}

fn requireParsedRuleResources(
    root: *const yaml.YamlValue,
    parse_mode: ParseMode,
) !void {
    std.debug.assert(root.* == .map);

    if (root.map.get("rule-providers")) |providers| {
        if (providers == .map and
            providers.map.count() > rule_provider_count_max)
        {
            return error.RuleProviderCountLimitExceeded;
        }
    }

    var rule_count: usize = 0;
    var rule_bytes: usize = 0;
    var final_count: u8 = 0;
    if (root.map.get("rules")) |rules| {
        if (rules != .array) return error.InvalidConfig;
        for (rules.array.items, 0..) |item, index| {
            if (item != .string) return error.InvalidConfig;
            const inspected = try inspectRule(item.string);
            rule_count = try addExpandedRuleCount(rule_count, 1);
            const bytes = std.math.add(
                usize,
                inspected.payload.len,
                inspected.target.len,
            ) catch return error.ExpandedRuleBytesLimitExceeded;
            rule_bytes = try addExpandedRuleBytes(rule_bytes, bytes);
            if (inspected.rule_type != .final) continue;
            if (final_count == 1 or index + 1 != rules.array.items.len) {
                return error.InvalidConfig;
            }
            final_count += 1;
        }
    }

    if (final_count == 0) {
        const implicit_target = if (root.map.get("rules") == null and
            !parse_mode.strict())
            "DIRECT"
        else
            "REJECT";
        rule_count = try addExpandedRuleCount(rule_count, 1);
        rule_bytes = try addExpandedRuleBytes(
            rule_bytes,
            implicit_target.len,
        );
    }
}

fn parseRoot(
    allocator: std.mem.Allocator,
    root: *yaml.YamlValue,
    parse_mode: ParseMode,
) !Config {
    const managed = parse_mode.strict();
    if (root.* != .map) return error.InvalidConfig;
    try requireParsedProxyResources(root);
    // Provider/rule collection sizes and owned rule bytes are inspected before
    // allocating even the Config defaults, provider declarations, or rules.
    try requireParsedRuleResources(root, parse_mode);

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
                    if (config.proxy_groups.items.len >= proxy_group_count_max) {
                        return error.ProxyGroupCountLimitExceeded;
                    }
                    var group = try parseProxyGroup(allocator, item.map, managed);
                    config.proxy_groups.append(allocator, group) catch |err| {
                        group.deinit(allocator);
                        return err;
                    };
                } else if (isSubscriptionInfoNode(item.map)) {
                    // Skip airport quota/expiry pseudo-nodes (see isSubscriptionInfoNode).
                    continue;
                } else {
                    if (config.proxies.items.len >= proxy_count_max) {
                        return error.ProxyCountLimitExceeded;
                    }
                    var proxy = try parseProxy(allocator, item.map, parse_mode);
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
                if (config.proxy_groups.items.len >= proxy_group_count_max) {
                    return error.ProxyGroupCountLimitExceeded;
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
            if (providers.map.count() > rule_provider_count_max) {
                return error.RuleProviderCountLimitExceeded;
            }
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
        if (rules.array.items.len > expanded_rule_count_max) {
            return error.ExpandedRuleCountLimitExceeded;
        }
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
    parse_mode: ParseMode,
) !Proxy {
    const managed = parse_mode.strict();
    const catalog_capture = parse_mode == .catalog_capture;
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

    // Shadowsocks plugin declaration and its two Clash spelling aliases are
    // parsed independently. This preserves inconsistent derived fields for the
    // shared runtime classifier to reject instead of silently downgrading them.
    if (map.get("plugin")) |v| {
        if (v == .string) {
            proxy.plugin = try allocator.dupe(u8, v.string);
        } else if (catalog_capture) {
            proxy.semantic_state = .malformed;
        } else {
            return error.InvalidProxyFormat;
        }
    }

    const hyphen_options = map.get("plugin-opts");
    const underscore_options = map.get("plugin_opts");
    if (hyphen_options != null and underscore_options != null) {
        if (parse_mode == .runtime) return error.AmbiguousPluginOptions;
        proxy.plugin_options_state = .malformed;
        try parsePluginOptions(
            allocator,
            &proxy,
            hyphen_options.?,
            false,
            true,
        );
    } else if (hyphen_options orelse underscore_options) |options| {
        try parsePluginOptions(
            allocator,
            &proxy,
            options,
            parse_mode == .runtime,
            false,
        );
    }

    if (catalog_capture) {
        if (ptype == .ss) {
            if (pluginMetadataMalformed(&proxy)) {
                proxy.semantic_state = .malformed;
            }
        } else if (hasPluginMetadata(&proxy)) {
            proxy.semantic_state = .malformed;
        }
    }
    return proxy;
}

fn parsePluginOptions(
    allocator: std.mem.Allocator,
    proxy: *Proxy,
    options: yaml.YamlValue,
    reject_malformed: bool,
    force_malformed: bool,
) !void {
    if (options != .map) {
        proxy.plugin_options_state = .malformed;
        if (reject_malformed) return error.InvalidPluginOptions;
        return;
    }

    var malformed = force_malformed;
    var iterator = options.map.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const known = std.mem.eql(u8, key, "mode") or
            std.mem.eql(u8, key, "host");
        if (!known or value != .string) malformed = true;
    }

    if (options.map.get("mode")) |mode| {
        if (mode == .string) {
            proxy.obfs_mode = try allocator.dupe(u8, mode.string);
        }
    }
    if (options.map.get("host")) |host| {
        if (host == .string) {
            proxy.obfs_host = try allocator.dupe(u8, host.string);
        }
    }

    proxy.plugin_options_state = if (malformed) .malformed else .map;
    if (reject_malformed and malformed) return error.InvalidPluginOptions;
}

fn pluginMetadataMalformed(proxy: *const Proxy) bool {
    const plugin = proxy.plugin orelse {
        return proxy.plugin_options_state != .absent or
            proxy.obfs_mode != null or
            proxy.obfs_host != null;
    };
    if (!std.mem.eql(u8, plugin, "obfs") and
        !std.mem.eql(u8, plugin, "obfs-local"))
    {
        return true;
    }
    if (proxy.plugin_options_state != .map) return true;
    const mode = proxy.obfs_mode orelse return true;
    if (!std.mem.eql(u8, mode, "http")) return true;
    const host = proxy.obfs_host orelse return true;
    if (host.len == 0 or host.len > 255) return true;
    for (host) |byte| {
        if (byte == '\r' or byte == '\n' or byte == 0) return true;
    }
    return proxy.semantic_state == .malformed;
}

test "managed parser normalizes both plugin option map aliases" {
    const allocator = std.testing.allocator;
    const documents = [_][]const u8{
        \\mixed-port: 7890
        \\proxies:
        \\  - name: mihomo-obfs
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts:
        \\      mode: http
        \\      host: cdn.example.com
        \\rules:
        \\  - MATCH,mihomo-obfs
        ,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: sip003-obfs
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs-local
        \\    plugin_opts:
        \\      mode: http
        \\      host: edge.example.com
        \\rules:
        \\  - MATCH,sip003-obfs
        ,
    };

    for (documents, 0..) |document, index| {
        var cfg = try parseDocument(allocator, document);
        defer cfg.deinit();
        const proxy = cfg.proxies.items[0];
        try std.testing.expectEqual(PluginOptionsState.map, proxy.plugin_options_state);
        try std.testing.expectEqualStrings("http", proxy.obfs_mode.?);
        try std.testing.expectEqualStrings(
            if (index == 0) "cdn.example.com" else "edge.example.com",
            proxy.obfs_host.?,
        );
    }
}

test "managed parser explicitly rejects malformed plugin options" {
    const allocator = std.testing.allocator;
    const scalar =
        \\mixed-port: 7890
        \\proxies:
        \\  - name: scalar
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs-local
        \\    plugin-opts: "obfs=http;obfs-host=example.com"
    ;
    try std.testing.expectError(
        error.InvalidPluginOptions,
        parseDocument(allocator, scalar),
    );

    const unknown_key =
        \\mixed-port: 7890
        \\proxies:
        \\  - name: unknown
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts:
        \\      mode: http
        \\      host: example.com
        \\      extra: forbidden
    ;
    try std.testing.expectError(
        error.InvalidPluginOptions,
        parseDocument(allocator, unknown_key),
    );

    const aliases =
        \\mixed-port: 7890
        \\proxies:
        \\  - name: aliases
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: { mode: http, host: example.com }
        \\    plugin_opts: { mode: http, host: example.com }
    ;
    try std.testing.expectError(
        error.AmbiguousPluginOptions,
        parseDocument(allocator, aliases),
    );
}

test "runtime file load rejects duplicate simple-obfs plugin fields" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        name: []const u8,
        document: []const u8,
    }{
        .{
            .name = "duplicate-plugin.yaml",
            .document =
            \\proxies:
            \\  - name: duplicate-plugin
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: unknown
            \\    plugin: obfs
            \\    plugin-opts: { mode: http, host: example.com }
            ,
        },
        .{
            .name = "duplicate-plugin-opts.yaml",
            .document =
            \\proxies:
            \\  - name: duplicate-options
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts: { mode: tls, host: example.com }
            \\    plugin-opts: { mode: http, host: example.com }
            ,
        },
        .{
            .name = "duplicate-mode.yaml",
            .document =
            \\proxies:
            \\  - name: duplicate-mode
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts:
            \\      mode: tls
            \\      mode: http
            \\      host: example.com
            ,
        },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (cases) |case| {
        {
            const file = try tmp.dir.createFile(compat.io(), case.name, .{});
            defer file.close(compat.io());
            try compat.fileWriteAll(file, case.document);
        }
        const path = try tmp.dir.realPathFileAlloc(compat.io(), case.name, allocator);
        defer allocator.free(path);
        try std.testing.expectError(error.DuplicateKey, load(allocator, path));
    }
}

test "legacy parser marks malformed plugin options for runtime rejection" {
    const allocator = std.testing.allocator;
    var cfg = try parse(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: legacy
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts:
        \\      mode: http
        \\      host: example.com
        \\      ignored-before: value
    );
    defer cfg.deinit();
    try std.testing.expectEqual(
        PluginOptionsState.malformed,
        cfg.proxies.items[0].plugin_options_state,
    );
    try std.testing.expectEqualStrings(
        "http",
        cfg.proxies.items[0].obfs_mode.?,
    );
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
    if (map.get("proxies")) |proxies| {
        if (proxies == .array) {
            try requireProxyGroupMemberLimit(proxies.array.items.len);
        }
    }

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

const ParsedRuleView = struct {
    rule_type: RuleType,
    payload: []const u8,
    target: []const u8,
    no_resolve: bool,
};

fn inspectRule(rule_str: []const u8) !ParsedRuleView {
    const trimmed = std.mem.trim(u8, rule_str, " \t\r\n");
    var parts = std.mem.splitScalar(u8, trimmed, ',');
    const type_str = parts.next() orelse return error.InvalidRule;
    const payload = if (std.mem.eql(u8, type_str, "MATCH"))
        ""
    else
        parts.next() orelse return error.InvalidRule;
    const target = parts.next() orelse return error.InvalidRule;

    var no_resolve = false;
    while (parts.next()) |opt| {
        if (std.mem.eql(u8, std.mem.trim(u8, opt, " \t"), "no-resolve")) {
            no_resolve = true;
        }
    }

    return .{
        .rule_type = parseRuleType(type_str) orelse return error.UnknownRuleType,
        .payload = std.mem.trim(u8, payload, " \t"),
        .target = std.mem.trim(u8, target, " \t"),
        .no_resolve = no_resolve,
    };
}

fn parseRule(allocator: std.mem.Allocator, rule_str: []const u8) !Rule {
    const inspected = try inspectRule(rule_str);
    const payload_copy = try allocator.dupe(u8, inspected.payload);
    errdefer allocator.free(payload_copy);
    const target_copy = try allocator.dupe(u8, inspected.target);
    return .{
        .rule_type = inspected.rule_type,
        .payload = payload_copy,
        .target = target_copy,
        .no_resolve = inspected.no_resolve,
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
    return loadBuiltinDefault(allocator);
}

/// Loads the same built-in document used by the no-file fallback, without
/// consulting process environment or filesystem configuration.
pub fn loadBuiltinDefault(allocator: std.mem.Allocator) !Config {
    const yaml_config =
        \\mixed-port: 7899
        \\mode: rule
        \\log-level: info
        \\proxies: []
        \\rules:
        \\  - MATCH,DIRECT
    ;
    return parseDocument(allocator, yaml_config);
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
    // Reject manual Config excess before filesystem lookup, refresh, or dial
    // preparation. Loading then applies one aggregate budget to all providers.
    try requireConfigResourceLimits(cfg);
    try syncRuleProviderFilesIfNeeded(allocator, cfg, config_path, sync_policy);
    try loadRuleProviderEntries(allocator, cfg, config_path);
    defer clearRuleProviderEntries(allocator, cfg);
    try expandRuleSetRules(allocator, cfg);
}

/// Prepares captured local rule providers without filesystem or network access.
/// Remote providers remain declarations and their RULE-SET rules stay unexpanded.
pub fn prepareRuleProvidersOffline(
    allocator: std.mem.Allocator,
    cfg: *Config,
    resolver: anytype,
) !void {
    // This is also the catalog/legacy admission boundary, so manual Config
    // excess must fail before consulting captured assets.
    try requireConfigResourceLimits(cfg);
    defer clearRuleProviderEntries(allocator, cfg);
    try loadRuleProviderEntriesOffline(allocator, cfg, resolver);
    try validateOfflineProviderEntries(allocator, cfg);
    try expandLocalRuleSetRules(allocator, cfg);
}

/// Managed offline preparation expands every captured local provider. Any
/// RULE-SET that remains therefore depends on deferred remote content and is
/// not a runnable exact revision.
pub fn requireManagedRuleProvidersResolved(cfg: *const Config) !void {
    for (cfg.rules.items) |rule| {
        if (rule.rule_type == .rule_set) {
            return error.ManagedRemoteRuleProviderUnsupported;
        }
    }
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
    return syncRuleProviderFilesIfNeededWithLimits(
        allocator,
        cfg,
        config_path,
        sync_policy,
        .fixed,
    );
}

fn syncRuleProviderFilesIfNeededWithLimits(
    allocator: std.mem.Allocator,
    cfg: *Config,
    config_path: ?[]const u8,
    sync_policy: RuleProviderSyncPolicy,
    limits: RuleProviderSyncLimits,
) !void {
    var budget = RuleProviderSyncBudget.init(limits);
    for (cfg.rule_providers.items) |*provider| {
        const resolved_path = try resolveRuleProviderPath(
            allocator,
            provider.path,
            config_path,
        );
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
                        &budget,
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
            if (sync_policy == .eager and
                isRuleProviderRefreshDue(
                    stat.mtime.nanoseconds,
                    provider.interval,
                ))
            {
                downloadRuleProviderFile(
                    allocator,
                    provider,
                    url,
                    resolved_path,
                    false,
                    &budget,
                ) catch |err| switch (err) {
                    // Only an ordinary fetch/status failure may select stale
                    // cache. Candidate parse, allocation, resource-limit, and
                    // publication errors remain authoritative.
                    error.RuleProviderDownloadFailed => {
                        std.debug.print(
                            "rule-provider refresh failed (using cached file): name={s} url={s} path={s} error={s}\n",
                            .{ provider.name, url, resolved_path, @errorName(err) },
                        );
                        try validateCachedRuleProviderFile(
                            allocator,
                            provider,
                            file,
                            &budget,
                        );
                    },
                    else => |resource_or_candidate_error| return resource_or_candidate_error,
                };
                continue;
            }
        }
        try validateCachedRuleProviderFile(
            allocator,
            provider,
            file,
            &budget,
        );
    }
}

fn validateCachedRuleProviderFile(
    allocator: std.mem.Allocator,
    provider: *const RuleProvider,
    file: std.Io.File,
    budget: *RuleProviderSyncBudget,
) !void {
    var transaction = budget.*;
    const content = try readRuleProviderSource(
        allocator,
        file,
        &transaction.source,
    );
    defer allocator.free(content);
    try validateRuleProviderCandidateWithBudget(
        allocator,
        provider,
        content,
        &transaction.entries,
    );
    budget.* = transaction;
}

const SystemRuleProviderFetcher = struct {
    fn fetch(
        _: *@This(),
        allocator: std.mem.Allocator,
        url: []const u8,
        options: FetchConfigOptions,
    ) !DownloadResult {
        return fetchConfigWithOptions(allocator, url, options);
    }
};

fn downloadRuleProviderFile(
    allocator: std.mem.Allocator,
    provider: *const RuleProvider,
    url: []const u8,
    resolved_path: []const u8,
    required: bool,
    budget: *RuleProviderSyncBudget,
) !void {
    var fetcher = SystemRuleProviderFetcher{};
    return downloadRuleProviderFileUsing(
        SystemRuleProviderFetcher,
        &fetcher,
        allocator,
        provider,
        url,
        resolved_path,
        required,
        budget,
    );
}

fn downloadRuleProviderFileUsing(
    comptime Fetcher: type,
    fetcher: *Fetcher,
    allocator: std.mem.Allocator,
    provider: *const RuleProvider,
    url: []const u8,
    resolved_path: []const u8,
    required: bool,
    budget: *RuleProviderSyncBudget,
) !void {
    const provider_name = provider.name;
    const body_bytes_max = try budget.source.downloadBodyBytesMax();
    var failure_accounting = FetchFailureAccounting{};
    const result = Fetcher.fetch(fetcher, allocator, url, .{
        .body_bytes_max = body_bytes_max,
        // std HTTP and curl share this one advertised remainder. The fetch
        // layer reports exact consumption when possible and conservatively
        // closes the window when a failed attempt cannot be measured.
        .failure_accounting = &failure_accounting,
    }) catch |err| {
        std.debug.print(
            "rule-provider download failed: name={s} url={s} path={s} error={s}\n",
            .{ provider_name, url, resolved_path, @errorName(err) },
        );
        try budget.source.consume(if (failure_accounting.exact)
            failure_accounting.source_bytes_consumed
        else
            body_bytes_max);
        // Cancellation is authoritative control flow. Account the bytes already
        // consumed, then preserve it before translating ordinary fetch failures
        // into the stale-cache-eligible provider error.
        if (err == error.Canceled) return err;
        if (err == error.ConfigTooLarge) {
            return budget.source.bodyLimitError(body_bytes_max);
        }
        if (isFetchResourceError(err)) return err;
        return error.RuleProviderDownloadFailed;
    };
    defer allocator.free(result.body);

    if (result.status != .ok) {
        // A completed non-success response and any preceding fallback attempt
        // are still downloaded source traffic.
        try budget.source.consume(result.total_source_bytes_consumed);
        std.debug.print(
            "rule-provider download failed: name={s} url={s} path={s} status={d}\n",
            .{ provider_name, url, resolved_path, @intFromEnum(result.status) },
        );
        return error.RuleProviderDownloadFailed;
    }

    const publish_outcome = try installDownloadedRuleProviderWithBudget(
        allocator,
        provider,
        resolved_path,
        result.body,
        result.total_source_bytes_consumed,
        budget,
    );
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

fn isFetchResourceError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.ThreadQuotaExceeded,
        error.LockedMemoryLimitExceeded,
        error.StreamTooLong,
        error.AddressResolutionResultLimitExceeded,
        error.LimitsExceedContract,
        error.InvalidDownloadDeadline,
        => true,
        else => false,
    };
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
    var budget = RuleProviderSyncBudget.init(.fixed);
    return installDownloadedRuleProviderWithBudget(
        allocator,
        provider,
        resolved_path,
        content,
        content.len,
        &budget,
    );
}

fn installDownloadedRuleProviderWithBudget(
    allocator: std.mem.Allocator,
    provider: *const RuleProvider,
    resolved_path: []const u8,
    content: []const u8,
    source_bytes_consumed: usize,
    budget: *RuleProviderSyncBudget,
) !RuleProviderPublishOutcome {
    if (content.len > config_source_bytes_max) {
        return error.RuleProviderFileTooLarge;
    }
    if (source_bytes_consumed < content.len) return error.DownloadFailed;
    var transaction = budget.*;
    // This total already includes the candidate body. Do not charge
    // `content.len` again after a std->curl fallback.
    try transaction.source.consume(source_bytes_consumed);
    try validateRuleProviderCandidateWithBudget(
        allocator,
        provider,
        content,
        &transaction.entries,
    );
    const outcome = try publishRuleProviderFile(resolved_path, content);
    // Publication (including visible-but-not-durable) is the commit point for
    // both raw source and normalized candidate reservations.
    budget.* = transaction;
    return outcome;
}

fn validateDownloadedRuleProvider(
    allocator: std.mem.Allocator,
    provider: *const RuleProvider,
    content: []const u8,
) !void {
    if (content.len > config_source_bytes_max) {
        return error.RuleProviderFileTooLarge;
    }
    var budget = RuleProviderEntryBudget.init(.fixed);
    return validateRuleProviderCandidateWithBudget(
        allocator,
        provider,
        content,
        &budget,
    );
}

fn validateRuleProviderCandidateWithBudget(
    allocator: std.mem.Allocator,
    provider: *const RuleProvider,
    content: []const u8,
    budget: *RuleProviderEntryBudget,
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
    try appendRuleProviderEntriesOfflineWithBudget(
        allocator,
        &candidate,
        content,
        budget,
    );
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

const RuleProviderSourceBudget = struct {
    limit: usize,
    consumed: usize = 0,

    fn init(limit: usize) RuleProviderSourceBudget {
        std.debug.assert(limit <= rule_provider_aggregate_source_bytes_max);
        return .{ .limit = limit };
    }

    fn remaining(self: *const RuleProviderSourceBudget) usize {
        std.debug.assert(self.consumed <= self.limit);
        return self.limit - self.consumed;
    }

    fn consume(
        self: *RuleProviderSourceBudget,
        byte_count: usize,
    ) RuleResourceLimitError!void {
        const next = std.math.add(usize, self.consumed, byte_count) catch
            return error.RuleProviderAggregateSourceBytesLimitExceeded;
        if (next > self.limit) {
            return error.RuleProviderAggregateSourceBytesLimitExceeded;
        }
        self.consumed = next;
    }

    /// Zero remaining bytes is a hard "do not issue another request" state.
    /// Cached empty files can still be probed locally by `readRuleProviderSource`.
    fn downloadBodyBytesMax(
        self: *const RuleProviderSourceBudget,
    ) RuleResourceLimitError!usize {
        const available = self.remaining();
        if (available == 0) {
            return error.RuleProviderAggregateSourceBytesLimitExceeded;
        }
        return @min(config_source_bytes_max, available);
    }

    fn bodyLimitError(
        self: *const RuleProviderSourceBudget,
        advertised_max: usize,
    ) anyerror {
        _ = self;
        if (advertised_max < config_source_bytes_max) {
            return error.RuleProviderAggregateSourceBytesLimitExceeded;
        }
        return error.RuleProviderFileTooLarge;
    }
};

const RuleProviderBudgetLimits = struct {
    per_provider_entry_count_max: usize,
    aggregate_entry_count_max: usize,
    aggregate_bytes_max: usize,

    const fixed: RuleProviderBudgetLimits = .{
        .per_provider_entry_count_max = rule_provider_entry_count_max,
        .aggregate_entry_count_max = rule_provider_aggregate_entry_count_max,
        .aggregate_bytes_max = rule_provider_aggregate_bytes_max,
    };

    fn validate(self: RuleProviderBudgetLimits) void {
        std.debug.assert(
            self.per_provider_entry_count_max <= rule_provider_entry_count_max,
        );
        std.debug.assert(
            self.aggregate_entry_count_max <=
                rule_provider_aggregate_entry_count_max,
        );
        std.debug.assert(
            self.aggregate_bytes_max <= rule_provider_aggregate_bytes_max,
        );
    }
};

const RuleProviderSyncLimits = struct {
    aggregate_source_bytes_max: usize,
    entries: RuleProviderBudgetLimits,

    const fixed: RuleProviderSyncLimits = .{
        .aggregate_source_bytes_max = rule_provider_aggregate_source_bytes_max,
        .entries = .fixed,
    };

    fn validate(self: RuleProviderSyncLimits) void {
        std.debug.assert(
            self.aggregate_source_bytes_max <=
                rule_provider_aggregate_source_bytes_max,
        );
        self.entries.validate();
    }
};

const RuleProviderSyncBudget = struct {
    source: RuleProviderSourceBudget,
    entries: RuleProviderEntryBudget,

    fn init(limits: RuleProviderSyncLimits) RuleProviderSyncBudget {
        limits.validate();
        return .{
            .source = .init(limits.aggregate_source_bytes_max),
            .entries = .init(limits.entries),
        };
    }
};

const RuleProviderBudgetReservation = struct {
    aggregate_entry_count: usize,
    aggregate_bytes: usize,
};

const RuleProviderEntryBudget = struct {
    limits: RuleProviderBudgetLimits,
    aggregate_entry_count: usize = 0,
    aggregate_bytes: usize = 0,

    fn init(limits: RuleProviderBudgetLimits) RuleProviderEntryBudget {
        limits.validate();
        return .{ .limits = limits };
    }

    fn check(
        self: *const RuleProviderEntryBudget,
        provider: *const RuleProvider,
        entry_len: usize,
    ) RuleResourceLimitError!RuleProviderBudgetReservation {
        const provider_count = std.math.add(
            usize,
            provider.entries.items.len,
            1,
        ) catch return error.RuleProviderAggregateEntryCountLimitExceeded;
        if (provider_count > self.limits.per_provider_entry_count_max) {
            return error.RuleProviderAggregateEntryCountLimitExceeded;
        }

        const aggregate_entry_count = std.math.add(
            usize,
            self.aggregate_entry_count,
            1,
        ) catch return error.RuleProviderAggregateEntryCountLimitExceeded;
        if (aggregate_entry_count > self.limits.aggregate_entry_count_max) {
            return error.RuleProviderAggregateEntryCountLimitExceeded;
        }

        const aggregate_bytes = std.math.add(
            usize,
            self.aggregate_bytes,
            entry_len,
        ) catch return error.RuleProviderAggregateBytesLimitExceeded;
        if (aggregate_bytes > self.limits.aggregate_bytes_max) {
            return error.RuleProviderAggregateBytesLimitExceeded;
        }
        return .{
            .aggregate_entry_count = aggregate_entry_count,
            .aggregate_bytes = aggregate_bytes,
        };
    }

    fn commit(
        self: *RuleProviderEntryBudget,
        reservation: RuleProviderBudgetReservation,
    ) void {
        self.aggregate_entry_count = reservation.aggregate_entry_count;
        self.aggregate_bytes = reservation.aggregate_bytes;
    }
};

fn readRuleProviderSource(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    budget: *RuleProviderSourceBudget,
) ![]u8 {
    const body_bytes_max = @min(
        config_source_bytes_max,
        budget.remaining(),
    );
    const probe_bytes_max = std.math.add(
        usize,
        body_bytes_max,
        1,
    ) catch return error.RuleProviderAggregateSourceBytesLimitExceeded;
    const content = try compat.fileReadToEndAlloc(
        file,
        allocator,
        probe_bytes_max,
    );
    errdefer allocator.free(content);
    if (content.len > body_bytes_max) {
        return budget.bodyLimitError(body_bytes_max);
    }
    try budget.consume(content.len);
    return content;
}

fn loadRuleProviderEntries(
    allocator: std.mem.Allocator,
    cfg: *Config,
    config_path: ?[]const u8,
) !void {
    for (cfg.rule_providers.items) |*provider| provider.clearEntries(allocator);
    errdefer clearRuleProviderEntries(allocator, cfg);
    // This is an independent authoritative pass after sync. Both raw sources
    // and normalized entries are re-budgeted to close the publish/load TOCTOU
    // window.
    var source_budget = RuleProviderSourceBudget.init(
        rule_provider_aggregate_source_bytes_max,
    );
    var entry_budget = RuleProviderEntryBudget.init(.fixed);

    for (cfg.rule_providers.items) |*provider| {
        const resolved_path = try resolveRuleProviderPath(allocator, provider.path, config_path);
        defer allocator.free(resolved_path);

        const file = compat.fs.openFileAbsolute(resolved_path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => return error.RuleProviderFileNotFound,
                else => return err,
            }
        };
        defer file.close(compat.io());

        const content = try readRuleProviderSource(
            allocator,
            file,
            &source_budget,
        );
        defer allocator.free(content);

        try appendRuleProviderEntriesOfflineWithBudget(
            allocator,
            provider,
            content,
            &entry_budget,
        );
        try validateRuleProviderEntries(allocator, provider);
    }
}

fn loadRuleProviderEntriesOffline(
    allocator: std.mem.Allocator,
    cfg: *Config,
    resolver: anytype,
) !void {
    return loadRuleProviderEntriesOfflineWithLimits(
        allocator,
        cfg,
        resolver,
        .fixed,
    );
}

fn loadRuleProviderEntriesOfflineWithLimits(
    allocator: std.mem.Allocator,
    cfg: *Config,
    resolver: anytype,
    limits: RuleProviderBudgetLimits,
) !void {
    for (cfg.rule_providers.items) |*provider| provider.clearEntries(allocator);
    var source_budget = RuleProviderSourceBudget.init(
        rule_provider_aggregate_source_bytes_max,
    );
    var entry_budget = RuleProviderEntryBudget.init(limits);

    for (cfg.rule_providers.items) |*provider| {
        if (provider.url != null) continue;
        const content = try resolver.resolveLocal(provider.path);
        if (content.len > config_source_bytes_max) {
            return error.RuleProviderFileTooLarge;
        }
        try source_budget.consume(content.len);
        try appendRuleProviderEntriesOfflineWithBudget(
            allocator,
            provider,
            content,
            &entry_budget,
        );
    }
}

fn appendRuleProviderEntriesLegacy(
    allocator: std.mem.Allocator,
    provider: *RuleProvider,
    content: []const u8,
    budget: *RuleProviderEntryBudget,
) !void {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const normalized = normalizeRuleProviderLine(raw_line) orelse continue;
        try appendRuleProviderEntry(
            allocator,
            provider,
            normalized,
            budget,
        );
    }
}

/// Validates a downloaded single-provider candidate against the same fixed
/// aggregate contract used by multi-provider runtime/offline loading.
fn appendRuleProviderEntriesOffline(
    allocator: std.mem.Allocator,
    provider: *RuleProvider,
    content: []const u8,
) !void {
    var budget = RuleProviderEntryBudget.init(.fixed);
    return appendRuleProviderEntriesOfflineWithBudget(
        allocator,
        provider,
        content,
        &budget,
    );
}

/// Private bounded seam keeps exact/max+1 tests small; it can only tighten the
/// immutable production contract.
fn appendRuleProviderEntriesOfflineWithLimits(
    allocator: std.mem.Allocator,
    provider: *RuleProvider,
    content: []const u8,
    limits: RuleProviderBudgetLimits,
) !void {
    var budget = RuleProviderEntryBudget.init(limits);
    return appendRuleProviderEntriesOfflineWithBudget(
        allocator,
        provider,
        content,
        &budget,
    );
}

fn appendRuleProviderEntriesOfflineWithBudget(
    allocator: std.mem.Allocator,
    provider: *RuleProvider,
    content: []const u8,
    budget: *RuleProviderEntryBudget,
) !void {
    const inspected = if (std.mem.startsWith(u8, content, "\xEF\xBB\xBF")) content[3..] else content;
    if (provider.behavior == .classical and looksLikeRawClassicalProvider(inspected)) {
        return appendRuleProviderEntriesLegacy(
            allocator,
            provider,
            inspected,
            budget,
        );
    }
    var document = yaml.parseDocument(allocator, inspected) catch |err| switch (err) {
        // Only syntax incompatibility is eligible for the legacy line parser.
        // Duplicate-key and resource-boundary errors remain authoritative.
        error.InvalidYamlDocument => {
            if (looksLikeProviderDocument(inspected)) return error.InvalidRuleProviderDocument;
            return appendRuleProviderEntriesLegacy(
                allocator,
                provider,
                inspected,
                budget,
            );
        },
        else => return err,
    };
    defer document.deinit(allocator);

    if (document != .map) {
        if (document == .array) return error.InvalidRuleProviderDocument;
        return appendRuleProviderEntriesLegacy(
            allocator,
            provider,
            inspected,
            budget,
        );
    }
    const payload = document.map.get("payload") orelse return error.InvalidRuleProviderDocument;
    if (payload != .array) return error.InvalidRuleProviderDocument;
    for (payload.array.items) |item| {
        if (item != .string) return error.InvalidRuleProviderDocument;
        try appendRuleProviderEntry(
            allocator,
            provider,
            item.string,
            budget,
        );
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
    budget: *RuleProviderEntryBudget,
) !void {
    // All count/byte arithmetic happens before either the entry clone or the
    // ArrayList growth. A failed allocator operation does not consume budget.
    const reservation = try budget.check(provider, entry_text.len);
    const entry = try allocator.dupe(u8, entry_text);
    errdefer allocator.free(entry);
    try provider.entries.append(allocator, entry);
    budget.commit(reservation);
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

const RuleExpansionLimits = struct {
    rule_count_max: usize,
    rule_bytes_max: usize,

    const fixed: RuleExpansionLimits = .{
        .rule_count_max = expanded_rule_count_max,
        .rule_bytes_max = expanded_rule_bytes_max,
    };

    fn validate(self: RuleExpansionLimits) void {
        std.debug.assert(self.rule_count_max <= expanded_rule_count_max);
        std.debug.assert(self.rule_bytes_max <= expanded_rule_bytes_max);
    }
};

/// Test builds can count bounded index construction, preflight hash lookups,
/// and the single output reservation. Production instantiates this as `void`.
const ExpansionTestProbe = if (builtin.is_test) struct {
    provider_index_inserts: usize = 0,
    preflight_provider_lookups: usize = 0,
    output_reserve_attempts: usize = 0,
} else void;
const ExpansionProbeStorage = if (builtin.is_test) ?*ExpansionTestProbe else void;

fn noExpansionProbe() ExpansionProbeStorage {
    return if (builtin.is_test) null else {};
}

const IndexedRuleProvider = struct {
    provider: *const RuleProvider,
    entry_bytes: usize,
};
const RuleProviderIndex = std.StringHashMap(IndexedRuleProvider);

fn buildRuleProviderIndex(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    probe: ExpansionProbeStorage,
) !RuleProviderIndex {
    var index = RuleProviderIndex.init(allocator);
    errdefer index.deinit();
    try index.ensureTotalCapacity(@intCast(cfg.rule_providers.items.len));

    for (cfg.rule_providers.items) |*provider| {
        var entry_bytes: usize = 0;
        for (provider.entries.items) |entry| {
            entry_bytes = std.math.add(usize, entry_bytes, entry.len) catch
                return error.RuleProviderAggregateBytesLimitExceeded;
            if (entry_bytes > rule_provider_aggregate_bytes_max) {
                return error.RuleProviderAggregateBytesLimitExceeded;
            }
        }
        const slot = try index.getOrPut(provider.name);
        if (slot.found_existing) return error.DuplicateRuleProviderName;
        slot.value_ptr.* = .{
            .provider = provider,
            .entry_bytes = entry_bytes,
        };
        if (builtin.is_test) {
            if (probe) |actual| actual.provider_index_inserts += 1;
        }
    }
    return index;
}

const RuleExpansionPlan = struct {
    rule_count: usize = 0,
    rule_bytes: usize = 0,
};

fn addPlannedRuleCount(
    current: usize,
    increment: usize,
    limits: RuleExpansionLimits,
) RuleResourceLimitError!usize {
    const next = std.math.add(usize, current, increment) catch
        return error.ExpandedRuleCountLimitExceeded;
    if (next > limits.rule_count_max) {
        return error.ExpandedRuleCountLimitExceeded;
    }
    return next;
}

fn addPlannedRuleBytes(
    current: usize,
    increment: usize,
    limits: RuleExpansionLimits,
) RuleResourceLimitError!usize {
    const next = std.math.add(usize, current, increment) catch
        return error.ExpandedRuleBytesLimitExceeded;
    if (next > limits.rule_bytes_max) {
        return error.ExpandedRuleBytesLimitExceeded;
    }
    return next;
}

fn planRuleExpansion(
    cfg: *const Config,
    provider_index: *const RuleProviderIndex,
    local_only: bool,
    limits: RuleExpansionLimits,
    probe: ExpansionProbeStorage,
) !RuleExpansionPlan {
    limits.validate();
    var plan = RuleExpansionPlan{};
    for (cfg.rules.items) |rule| {
        if (rule.rule_type != .rule_set) {
            plan.rule_count = try addPlannedRuleCount(
                plan.rule_count,
                1,
                limits,
            );
            plan.rule_bytes = try addPlannedRuleBytes(
                plan.rule_bytes,
                try ownedRuleBytes(rule),
                limits,
            );
            continue;
        }

        if (builtin.is_test) {
            if (probe) |actual| actual.preflight_provider_lookups += 1;
        }
        const indexed = provider_index.get(rule.payload) orelse
            return error.RuleProviderNotFound;
        if (local_only and indexed.provider.url != null) {
            plan.rule_count = try addPlannedRuleCount(
                plan.rule_count,
                1,
                limits,
            );
            plan.rule_bytes = try addPlannedRuleBytes(
                plan.rule_bytes,
                try ownedRuleBytes(rule),
                limits,
            );
            continue;
        }

        const entry_count = indexed.provider.entries.items.len;
        plan.rule_count = try addPlannedRuleCount(
            plan.rule_count,
            entry_count,
            limits,
        );
        const target_bytes = std.math.mul(
            usize,
            rule.target.len,
            entry_count,
        ) catch return error.ExpandedRuleBytesLimitExceeded;
        const owned_bytes = std.math.add(
            usize,
            indexed.entry_bytes,
            target_bytes,
        ) catch return error.ExpandedRuleBytesLimitExceeded;
        plan.rule_bytes = try addPlannedRuleBytes(
            plan.rule_bytes,
            owned_bytes,
            limits,
        );
    }
    return plan;
}

fn expandRuleSetRules(allocator: std.mem.Allocator, cfg: *Config) !void {
    return expandRuleSetRulesWithLimits(
        allocator,
        cfg,
        false,
        .fixed,
        noExpansionProbe(),
    );
}

fn expandLocalRuleSetRules(allocator: std.mem.Allocator, cfg: *Config) !void {
    return expandRuleSetRulesWithLimits(
        allocator,
        cfg,
        true,
        .fixed,
        noExpansionProbe(),
    );
}

fn expandRuleSetRulesWithLimits(
    allocator: std.mem.Allocator,
    cfg: *Config,
    local_only: bool,
    limits: RuleExpansionLimits,
    probe: ExpansionProbeStorage,
) !void {
    // Existing manual entries/rules are bounded before index allocation. The
    // index owns only its table; names remain borrowed from the immutable Config.
    try requireConfigResourceLimits(cfg);
    var provider_index = try buildRuleProviderIndex(allocator, cfg, probe);
    defer provider_index.deinit();
    const plan = try planRuleExpansion(
        cfg,
        &provider_index,
        local_only,
        limits,
        probe,
    );

    var expanded = std.ArrayList(Rule).empty;
    errdefer {
        for (expanded.items) |*rule| rule.deinit(allocator);
        expanded.deinit(allocator);
    }
    if (builtin.is_test) {
        if (probe) |actual| actual.output_reserve_attempts += 1;
    }
    try expanded.ensureTotalCapacity(allocator, plan.rule_count);

    for (cfg.rules.items) |rule| {
        if (rule.rule_type != .rule_set) {
            try appendClonedRule(allocator, &expanded, rule);
            continue;
        }
        const indexed = provider_index.get(rule.payload) orelse unreachable;
        if (local_only and indexed.provider.url != null) {
            try appendClonedRule(allocator, &expanded, rule);
            continue;
        }
        try appendRulesFromProvider(
            allocator,
            &expanded,
            indexed.provider,
            rule.target,
            rule.no_resolve,
        );
    }
    std.debug.assert(expanded.items.len == plan.rule_count);

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
                const rule = try makeOwnedRule(
                    allocator,
                    .domain_suffix,
                    payload,
                    target,
                    inherit_no_resolve,
                );
                out.appendAssumeCapacity(rule);
            }
        },
        .ipcidr => {
            for (provider.entries.items) |entry| {
                const payload = normalizeIpCidrProviderEntry(entry) orelse continue;
                const rule_type: RuleType = if (std.mem.indexOfScalar(u8, payload, ':') != null) .ip_cidr6 else .ip_cidr;
                const rule = try makeOwnedRule(
                    allocator,
                    rule_type,
                    payload,
                    target,
                    inherit_no_resolve,
                );
                out.appendAssumeCapacity(rule);
            }
        },
        .classical => {
            for (provider.entries.items) |entry| {
                var rule = try parseClassicalProviderEntry(allocator, entry, target);
                if (inherit_no_resolve) rule.no_resolve = true;
                out.appendAssumeCapacity(rule);
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

fn appendClonedRule(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Rule),
    source: Rule,
) !void {
    const cloned = try cloneRule(allocator, source);
    out.appendAssumeCapacity(cloned);
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
    /// Aggregate response-body bytes consumed by every transport attempt that
    /// led to this result. `body` itself is counted exactly once within this
    /// total, even when a failed std HTTP response preceded curl fallback.
    total_source_bytes_consumed: usize,
};

const FetchFailureAccounting = struct {
    /// Conservative upper bound when `exact` is false.
    source_bytes_consumed: usize = 0,
    exact: bool = false,
};

const FetchConfigOptions = struct {
    body_bytes_max: usize = config_source_bytes_max,
    deadline_ms: u32 = 30_000,
    allow_curl_fallback: bool = true,
    failure_accounting: ?*FetchFailureAccounting = null,

    fn validate(self: FetchConfigOptions) !void {
        // Zero means the caller's aggregate budget is exhausted: fail before
        // creating a client/task or issuing a request. In particular it is
        // never forwarded to curl, where --max-filesize 0 means unlimited.
        if (self.body_bytes_max == 0) return error.ConfigTooLarge;
        if (self.body_bytes_max > config_source_bytes_max) {
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
    if (options.failure_accounting) |accounting| accounting.* = .{};
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
    var transports = SystemFetchTransports{};
    return fetchConfigHTTPUsing(
        SystemFetchTransports,
        &transports,
        allocator,
        url,
        options,
        options.allow_curl_fallback and shouldUseCurlFallback(url),
    );
}

const FetchAttemptAccounting = struct {
    source_bytes_consumed: usize = 0,
    exact: bool = true,
};

const SystemFetchTransports = struct {
    fn fetchPrimary(
        _: *@This(),
        allocator: std.mem.Allocator,
        url: []const u8,
        options: FetchConfigOptions,
        accounting: *FetchAttemptAccounting,
    ) !DownloadResult {
        return fetchConfigWithStdHttp(
            allocator,
            url,
            options,
            accounting,
        );
    }

    fn fetchFallback(
        _: *@This(),
        allocator: std.mem.Allocator,
        url: []const u8,
        options: FetchConfigOptions,
        accounting: *FetchAttemptAccounting,
    ) !DownloadResult {
        return fetchConfigWithCurl(
            allocator,
            url,
            options,
            accounting,
        );
    }
};

fn reportFetchFailure(
    options: FetchConfigOptions,
    err: anyerror,
    source_bytes_consumed: usize,
    exact: bool,
) anyerror {
    if (options.failure_accounting) |accounting| accounting.* = .{
        .source_bytes_consumed = source_bytes_consumed,
        .exact = exact,
    };
    return err;
}

fn failedAttemptCharge(
    accounting: FetchAttemptAccounting,
    advertised_max: usize,
) struct { bytes: usize, exact: bool } {
    if (!accounting.exact or
        accounting.source_bytes_consumed > advertised_max)
    {
        return .{ .bytes = advertised_max, .exact = false };
    }
    return .{
        .bytes = accounting.source_bytes_consumed,
        .exact = true,
    };
}

fn validateAttemptResult(
    result: DownloadResult,
    advertised_max: usize,
) !usize {
    if (result.total_source_bytes_consumed < result.body.len) {
        return error.DownloadFailed;
    }
    if (result.total_source_bytes_consumed > advertised_max) {
        return error.ConfigTooLarge;
    }
    return result.total_source_bytes_consumed;
}

fn withFetchBodyLimit(
    options: FetchConfigOptions,
    body_bytes_max: usize,
) FetchConfigOptions {
    var limited = options;
    limited.body_bytes_max = body_bytes_max;
    limited.allow_curl_fallback = false;
    limited.failure_accounting = null;
    return limited;
}

/// Runs std HTTP and the proxy-compatible curl fallback inside one response
/// body window. A failed or HTTP-400 primary attempt reduces the fallback cap;
/// an attempt whose consumption cannot be bounded exactly consumes all of its
/// advertised remainder and therefore cannot amplify traffic with a retry.
fn fetchConfigHTTPUsing(
    comptime Transports: type,
    transports: *Transports,
    allocator: std.mem.Allocator,
    url: []const u8,
    options: FetchConfigOptions,
    curl_fallback_enabled: bool,
) !DownloadResult {
    var primary_accounting = FetchAttemptAccounting{};
    var primary = Transports.fetchPrimary(
        transports,
        allocator,
        url,
        withFetchBodyLimit(options, options.body_bytes_max),
        &primary_accounting,
    ) catch |primary_error| {
        const primary_charge = failedAttemptCharge(
            primary_accounting,
            options.body_bytes_max,
        );
        // Cancellation is a control-flow result, never a transport failure.
        // In particular, the deadline future cancels this worker; starting
        // curl after that point would outlive the caller's aggregate deadline.
        if (primary_error == error.Canceled) {
            return reportFetchFailure(
                options,
                primary_error,
                primary_charge.bytes,
                primary_charge.exact,
            );
        }
        if (primary_error == error.ConfigTooLarge or
            primary_error == error.DownloadTimeout or
            isFetchResourceError(primary_error) or
            !curl_fallback_enabled or
            primary_charge.bytes == options.body_bytes_max)
        {
            if (primary_error != error.ConfigTooLarge and
                primary_error != error.DownloadTimeout and
                !isFetchResourceError(primary_error))
            {
                std.debug.print(
                    "Failed to download config: {s}\n",
                    .{@errorName(primary_error)},
                );
            }
            return reportFetchFailure(
                options,
                primary_error,
                primary_charge.bytes,
                primary_charge.exact,
            );
        }

        const remaining = options.body_bytes_max - primary_charge.bytes;
        std.Io.checkCancel(compat.io()) catch |cancel_error| {
            return reportFetchFailure(
                options,
                cancel_error,
                primary_charge.bytes,
                primary_charge.exact,
            );
        };
        var fallback_accounting = FetchAttemptAccounting{};
        var fallback = Transports.fetchFallback(
            transports,
            allocator,
            url,
            withFetchBodyLimit(options, remaining),
            &fallback_accounting,
        ) catch |fallback_error| {
            const fallback_charge = failedAttemptCharge(
                fallback_accounting,
                remaining,
            );
            const total = primary_charge.bytes + fallback_charge.bytes;
            const exact = primary_charge.exact and fallback_charge.exact;
            if (fallback_error == error.Canceled) {
                return reportFetchFailure(
                    options,
                    fallback_error,
                    total,
                    exact,
                );
            }
            if (fallback_error == error.ConfigTooLarge or
                fallback_error == error.DownloadTimeout or
                isFetchResourceError(fallback_error))
            {
                return reportFetchFailure(
                    options,
                    fallback_error,
                    total,
                    exact,
                );
            }
            std.debug.print(
                "Failed to download config: {s}\n",
                .{@errorName(primary_error)},
            );
            return reportFetchFailure(
                options,
                primary_error,
                total,
                exact,
            );
        };
        const fallback_bytes = validateAttemptResult(
            fallback,
            remaining,
        ) catch |err| {
            allocator.free(fallback.body);
            return reportFetchFailure(
                options,
                err,
                options.body_bytes_max,
                false,
            );
        };
        fallback.total_source_bytes_consumed =
            primary_charge.bytes + fallback_bytes;
        return fallback;
    };

    const primary_bytes = validateAttemptResult(
        primary,
        options.body_bytes_max,
    ) catch |err| {
        allocator.free(primary.body);
        return reportFetchFailure(
            options,
            err,
            options.body_bytes_max,
            false,
        );
    };
    primary.total_source_bytes_consumed = primary_bytes;
    if (primary.status != .bad_request or
        !curl_fallback_enabled or
        primary_bytes == options.body_bytes_max)
    {
        return primary;
    }

    const remaining = options.body_bytes_max - primary_bytes;
    std.Io.checkCancel(compat.io()) catch |cancel_error| {
        allocator.free(primary.body);
        return reportFetchFailure(
            options,
            cancel_error,
            primary_bytes,
            true,
        );
    };
    var fallback_accounting = FetchAttemptAccounting{};
    var fallback = Transports.fetchFallback(
        transports,
        allocator,
        url,
        withFetchBodyLimit(options, remaining),
        &fallback_accounting,
    ) catch |fallback_error| {
        const fallback_charge = failedAttemptCharge(
            fallback_accounting,
            remaining,
        );
        const total = primary_bytes + fallback_charge.bytes;
        if (fallback_error == error.Canceled) {
            allocator.free(primary.body);
            return reportFetchFailure(
                options,
                fallback_error,
                total,
                fallback_charge.exact,
            );
        }
        if (fallback_error == error.ConfigTooLarge or
            fallback_error == error.DownloadTimeout or
            isFetchResourceError(fallback_error))
        {
            allocator.free(primary.body);
            return reportFetchFailure(
                options,
                fallback_error,
                total,
                fallback_charge.exact,
            );
        }
        // Preserve the historical ordinary-config behavior: if curl itself is
        // unavailable or fails ordinarily, return the completed std HTTP 400.
        primary.total_source_bytes_consumed = total;
        return primary;
    };
    const fallback_bytes = validateAttemptResult(
        fallback,
        remaining,
    ) catch |err| {
        allocator.free(primary.body);
        allocator.free(fallback.body);
        return reportFetchFailure(
            options,
            err,
            options.body_bytes_max,
            false,
        );
    };
    allocator.free(primary.body);
    fallback.total_source_bytes_consumed = primary_bytes + fallback_bytes;
    return fallback;
}

const config_http_redirect_count_max: usize = 3;
const config_http_redirect_storage_bytes_max: usize = 8 * 1024;

const ConfigStdHttpResponse = struct {
    status: std.http.Status,
    location_len: ?usize,
};

fn isConfigHttpRedirect(status: std.http.Status) bool {
    // `Request.receiveHead` deliberately treats 304 as a final response even
    // though it belongs to the 3xx status class. Preserve that fetch behavior.
    return status.class() == .redirect and status != .not_modified;
}

fn configHttpWriteError(request: *const std.http.Client.Request) anyerror {
    const connection = request.connection orelse return error.WriteFailed;
    return connection.stream_writer.err orelse error.WriteFailed;
}

fn configHttpReadError(request: *const std.http.Client.Request) anyerror {
    const connection = request.connection orelse return error.ReadFailed;
    return connection.getReadError() orelse error.ReadFailed;
}

fn configHttpBodyReadError(
    response: *const std.http.Client.Response,
    content_encoding: std.http.ContentEncoding,
    decompress: *const std.http.Decompress,
) anyerror {
    if (response.bodyErr()) |err| return err;

    // For a close-delimited identity response, bodyReaderDecompressing returns
    // the underlying reader without initializing `decompress`. Never inspect
    // that union in the identity case. Compressed responses still expose their
    // concrete protocol diagnostic before we fall through to the socket error.
    switch (content_encoding) {
        .identity => {},
        .deflate, .gzip => if (decompress.flate.err) |err| {
            if (err != error.ReadFailed) return err;
        },
        .zstd => if (decompress.zstd.err) |err| {
            if (err != error.ReadFailed) return err;
        },
        .compress => {},
    }
    return configHttpReadError(response.request);
}

/// Issues one GET with redirect handling disabled and streams this response's
/// decoded body into the caller's aggregate fixed writer. Redirect Location is
/// copied before `readerDecompressing` invalidates all response-head strings.
fn fetchConfigStdHttpResponse(
    client: *std.http.Client,
    uri: std.Uri,
    response_writer: *std.Io.Writer,
    location_storage: ?[]u8,
    accounting_exact: *bool,
) !ConfigStdHttpResponse {
    var request = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .user_agent = .{ .override = "clash" },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer request.deinit();
    // Request.deinit otherwise drains an unread remainder in an attempt to
    // reuse the connection. On every error (especially ConfigTooLarge and
    // cancellation), close instead: no unaccounted bytes may be consumed after
    // the aggregate writer has stopped accepting input.
    errdefer {
        if (request.connection) |connection| connection.closing = true;
    }

    request.sendBodiless() catch |err| switch (err) {
        error.WriteFailed => return configHttpWriteError(&request),
    };
    var response = request.receiveHead(&.{}) catch |err| {
        // receiveHead first advances the HTTP reader to received_head, then
        // parses and validates the head. A parse/encoding error at that point
        // may already have body bytes in the connection buffer, so an exact
        // zero-byte charge would incorrectly permit a full-size fallback.
        // Failures before a complete head leave the reader ready and remain
        // exactly accounted, preserving proxy/curl fallback for connect and
        // genuinely head-truncated failures.
        switch (request.reader.state) {
            .received_head,
            .body_none,
            .body_remaining_content_length,
            .body_remaining_chunk_len,
            .closing,
            => accounting_exact.* = false,
            .ready => {},
        }
        switch (err) {
            error.ReadFailed => return configHttpReadError(&request),
            else => |other| return other,
        }
    };

    // Until this body's reader reaches its end, bytes already buffered by the
    // HTTP/TLS layers make exact failure accounting unknowable.
    accounting_exact.* = false;
    const status = response.head.status;
    const content_encoding = response.head.content_encoding;
    var location_len: ?usize = null;
    var redirect_error: ?anyerror = null;
    if (isConfigHttpRedirect(status)) {
        if (location_storage) |storage| {
            if (response.head.location) |location| {
                if (location.len > storage.len) {
                    redirect_error = error.HttpRedirectLocationOversize;
                } else {
                    @memcpy(storage[0..location.len], location);
                    location_len = location.len;
                }
            } else {
                redirect_error = error.HttpRedirectLocationMissing;
            }
        }
    }

    const decompress_buffer: []u8 = switch (content_encoding) {
        .identity => &.{},
        .zstd => try client.allocator.alloc(
            u8,
            std.compress.zstd.default_window_len,
        ),
        .deflate, .gzip => try client.allocator.alloc(
            u8,
            std.compress.flate.max_window_len,
        ),
        // receiveHead can return 204/304 before validating the encoding;
        // match Client.fetch rather than treating that server input as
        // unreachable.
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (content_encoding != .identity) {
        client.allocator.free(decompress_buffer);
    };

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(
        &transfer_buffer,
        &decompress,
        decompress_buffer,
    );
    _ = reader.streamRemaining(response_writer) catch |err| switch (err) {
        error.WriteFailed => return error.ConfigTooLarge,
        error.ReadFailed => return configHttpBodyReadError(
            &response,
            content_encoding,
            &decompress,
        ),
    };
    accounting_exact.* = true;

    if (redirect_error) |err| return err;
    return .{ .status = status, .location_len = location_len };
}

fn resolveConfigHttpRedirect(
    base: std.Uri,
    location_len: usize,
    storage: []u8,
) !std.Uri {
    var auxiliary = storage;
    return base.resolveInPlace(location_len, &auxiliary) catch |err| switch (err) {
        error.UnexpectedCharacter,
        error.InvalidFormat,
        error.InvalidPort,
        error.InvalidHostName,
        => error.HttpRedirectLocationInvalid,
        error.NoSpaceLeft => error.HttpRedirectLocationOversize,
    };
}

fn fetchConfigWithStdHttp(
    allocator: std.mem.Allocator,
    url: []const u8,
    options: FetchConfigOptions,
    accounting: *FetchAttemptAccounting,
) !DownloadResult {
    accounting.* = .{};
    var current_uri = try std.Uri.parse(url);
    var client = std.http.Client{
        .allocator = allocator,
        .io = compat.io(),
        .read_buffer_size = config_http_redirect_storage_bytes_max,
    };
    defer client.deinit();

    var proxy_arena = try initDefaultProxyEnv(allocator, &client);
    defer proxy_arena.deinit();

    const response_storage = try allocator.alloc(u8, options.body_bytes_max);
    var response_storage_owned = true;
    defer if (response_storage_owned) allocator.free(response_storage);
    var response_writer: std.Io.Writer = .fixed(response_storage);

    // A different immutable backing buffer is retained for every followed URI.
    // A resolved URI can continue to reference components of any earlier base,
    // so ping-pong reuse would be unsound for mixed relative/absolute chains.
    var redirect_storage: [config_http_redirect_count_max][config_http_redirect_storage_bytes_max]u8 = undefined;
    var redirects_followed: usize = 0;

    while (true) {
        const final_body_start = response_writer.buffered().len;
        const location_storage: ?[]u8 = if (redirects_followed < config_http_redirect_count_max) &redirect_storage[redirects_followed] else null;
        const response = fetchConfigStdHttpResponse(
            &client,
            current_uri,
            &response_writer,
            location_storage,
            &accounting.exact,
        ) catch |err| {
            accounting.source_bytes_consumed = response_writer.buffered().len;
            if (err == error.ConfigTooLarge) accounting.exact = false;
            return err;
        };
        accounting.source_bytes_consumed = response_writer.buffered().len;

        if (!isConfigHttpRedirect(response.status)) {
            const total_source_bytes = response_writer.buffered().len;
            const final_body_len = std.math.sub(
                usize,
                total_source_bytes,
                final_body_start,
            ) catch return error.DownloadFailed;
            std.mem.copyForwards(
                u8,
                response_storage[0..final_body_len],
                response_storage[final_body_start..total_source_bytes],
            );
            const body = try allocator.realloc(
                response_storage,
                final_body_len,
            );
            response_storage_owned = false;
            return .{
                .status = response.status,
                .body = body,
                .total_source_bytes_consumed = total_source_bytes,
            };
        }

        // Match std.http.Client's default redirect budget: three redirects may
        // be followed, while the fourth response body is still accounted and
        // then reported as the stable public HTTP error.
        if (redirects_followed == config_http_redirect_count_max) {
            return error.TooManyHttpRedirects;
        }
        const location_len = response.location_len orelse
            return error.HttpRedirectLocationMissing;
        current_uri = try resolveConfigHttpRedirect(
            current_uri,
            location_len,
            &redirect_storage[redirects_followed],
        );
        redirects_followed = std.math.add(
            usize,
            redirects_followed,
            1,
        ) catch unreachable;
    }
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
    accounting: *FetchAttemptAccounting,
) !DownloadResult {
    accounting.* = .{};
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
        error.StreamTooLong => {
            accounting.* = .{
                .source_bytes_consumed = options.body_bytes_max,
                .exact = false,
            };
            return error.ConfigTooLarge;
        },
        error.Timeout => {
            accounting.exact = false;
            return error.DownloadTimeout;
        },
        error.FileNotFound => return err,
        else => {
            accounting.exact = false;
            return err;
        },
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (curlBodyLength(result.stdout)) |body_len| {
        accounting.source_bytes_consumed = @min(
            body_len,
            options.body_bytes_max,
        );
    } else {
        accounting.* = .{
            .source_bytes_consumed = @min(
                result.stdout.len,
                options.body_bytes_max,
            ),
            .exact = result.stdout.len == 0,
        };
    }

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
    accounting.* = .{
        .source_bytes_consumed = parsed.body.len,
        .exact = true,
    };
    return parsed;
}

fn curlBodyLength(stdout: []const u8) ?usize {
    if (stdout.len < 4 or stdout[stdout.len - 4] != '\n') return null;
    _ = std.fmt.parseInt(u16, stdout[stdout.len - 3 ..], 10) catch
        return null;
    return stdout.len - 4;
}

fn parseCurlFetchResult(allocator: std.mem.Allocator, stdout: []const u8) !DownloadResult {
    const body_len = curlBodyLength(stdout) orelse return error.DownloadFailed;
    const status_text = stdout[stdout.len - 3 ..];
    const status_code = std.fmt.parseInt(u16, status_text, 10) catch
        return error.DownloadFailed;
    const body = try allocator.dupe(u8, stdout[0..body_len]);
    return .{
        .status = @enumFromInt(status_code),
        .body = body,
        .total_source_bytes_consumed = body.len,
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

pub fn normalizeManagedConfigKey(name: []const u8) ![]const u8 {
    const key = normalizeConfigKey(name);
    if (!config_catalog.isManagedKey(key)) return error.InvalidConfigKey;
    return key;
}

pub fn normalizePortableManagedConfigKey(name: []const u8) ![]const u8 {
    const key = normalizeConfigKey(name);
    if (!config_catalog.isPortableManagedKey(key)) {
        return error.InvalidConfigKey;
    }
    return key;
}

/// 下载结果（key/path 均为 caller 所有）。
pub fn acquireLegacyWriteGuard(
    allocator: std.mem.Allocator,
) !legacy_write_lock.Guard {
    const root_path = try getDefaultConfigDir(allocator) orelse
        return error.NoConfigDir;
    defer allocator.free(root_path);
    if (!compat.fs.path.isAbsolute(root_path)) return error.NoConfigDir;
    try compat.fs.cwd().makePath(root_path);
    const root = try compat.fs.openDirAbsolute(root_path, .{
        .follow_symlinks = false,
    });
    defer root.close(compat.io());
    var guard = try legacy_write_lock.acquire(root);
    errdefer guard.deinit();
    try legacy_write_lock.rejectCatalogAuthority(root);
    return guard;
}

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
    return try readConfigSource(allocator, file);
}

fn publishConfigFile(
    directory: std.Io.Dir,
    name: []const u8,
    bytes: []const u8,
) !ConfigFilePublishOutcome {
    if (bytes.len > config_source_bytes_max) return error.ConfigTooLarge;
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
        try normalizePortableManagedConfigKey(value)
    else
        null;
    var legacy_guard = try acquireLegacyWriteGuard(allocator);
    defer legacy_guard.deinit();

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
fn copyOverrideScriptForCurrentConfig(allocator: std.mem.Allocator, script_path: []const u8) ![]u8 {
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
fn persistOverrideScriptPathForCurrentConfig(allocator: std.mem.Allocator, script_path: []const u8) !void {
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
    var legacy_guard = try acquireLegacyWriteGuard(allocator);
    defer legacy_guard.deinit();
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
    var legacy_guard = try acquireLegacyWriteGuard(allocator);
    defer legacy_guard.deinit();
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

    const parent = compat.fs.path.dirname(resolved_path) orelse return null;
    if (!std.mem.eql(u8, parent, resolved_configs_dir)) return null;

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
    var legacy_guard = try acquireLegacyWriteGuard(allocator);
    defer legacy_guard.deinit();

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
    var legacy_guard = try acquireLegacyWriteGuard(allocator);
    defer legacy_guard.deinit();

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
    var legacy_guard = try acquireLegacyWriteGuard(allocator);
    defer legacy_guard.deinit();

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

fn testRuleProvider(behavior: RuleProviderBehavior) RuleProvider {
    return .{
        .name = "test",
        .provider_type = "file",
        .behavior = behavior,
        .path = "rules.txt",
        .entries = .empty,
    };
}

fn deinitTestRuleProviderEntries(
    allocator: std.mem.Allocator,
    provider: *RuleProvider,
) void {
    provider.clearEntries(allocator);
    provider.entries.deinit(allocator);
}

fn testRuleProviderSyncLimits(
    source_bytes_max: usize,
    entry_count_max: usize,
    entry_bytes_max: usize,
) RuleProviderSyncLimits {
    return .{
        .aggregate_source_bytes_max = source_bytes_max,
        .entries = .{
            .per_provider_entry_count_max = entry_count_max,
            .aggregate_entry_count_max = entry_count_max,
            .aggregate_bytes_max = entry_bytes_max,
        },
    };
}

fn parseTwoCachedProviderConfig(
    allocator: std.mem.Allocator,
    first_path: []const u8,
    second_path: []const u8,
) !Config {
    const source = try std.fmt.allocPrint(allocator,
        \\rule-providers:
        \\  first:
        \\    type: file
        \\    behavior: domain
        \\    path: {s}
        \\  second:
        \\    type: file
        \\    behavior: domain
        \\    path: {s}
        \\rules:
        \\  - MATCH,DIRECT
    , .{ first_path, second_path });
    defer allocator.free(source);
    return parseDocument(allocator, source);
}

fn parseCachedThenRefreshProviderConfig(
    allocator: std.mem.Allocator,
    first_path: []const u8,
    refresh_path: []const u8,
    url: []const u8,
) !Config {
    const source = try std.fmt.allocPrint(allocator,
        \\rule-providers:
        \\  first:
        \\    type: file
        \\    behavior: domain
        \\    path: {s}
        \\  refresh:
        \\    type: file
        \\    behavior: domain
        \\    path: {s}
        \\    url: {s}
        \\    interval: 1
        \\rules:
        \\  - MATCH,DIRECT
    , .{ first_path, refresh_path, url });
    defer allocator.free(source);
    return parseDocument(allocator, source);
}

fn parseRefreshProviderConfig(
    allocator: std.mem.Allocator,
    cached_path: []const u8,
    url: []const u8,
) !Config {
    const source = try std.fmt.allocPrint(allocator,
        \\rule-providers:
        \\  refresh:
        \\    type: file
        \\    behavior: domain
        \\    path: {s}
        \\    url: {s}
        \\    interval: 1
        \\rules:
        \\  - MATCH,DIRECT
    , .{ cached_path, url });
    defer allocator.free(source);
    return parseDocument(allocator, source);
}

fn serveSingleRuleProviderResponse(
    server: *compat.net.Server,
    hits: *std.atomic.Value(u32),
    status: []const u8,
    body: []const u8,
) void {
    var connection = server.accept() catch return;
    defer connection.stream.close();
    _ = hits.fetchAdd(1, .monotonic);
    var request_buffer: [1024]u8 = undefined;
    _ = connection.stream.read(&request_buffer) catch return;
    var header_buffer: [256]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buffer,
        "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, body.len },
    ) catch return;
    connection.stream.writeAll(header) catch return;
    connection.stream.writeAll(body) catch {};
}

fn repeatedRuleProviderLines(
    allocator: std.mem.Allocator,
    line: []const u8,
    count: usize,
) ![]u8 {
    var content = std.ArrayList(u8).empty;
    errdefer content.deinit(allocator);
    const capacity = std.math.mul(usize, line.len, count) catch
        return error.OutOfMemory;
    try content.ensureTotalCapacity(allocator, capacity);
    for (0..count) |_| content.appendSliceAssumeCapacity(line);
    return content.toOwnedSlice(allocator);
}

test "sync shares exact raw and normalized budgets across cached providers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const first = try tmp.dir.createFile(compat.io(), "first.txt", .{});
        defer first.close(compat.io());
        try compat.fileWriteAll(first, "a\n");
    }
    {
        const second = try tmp.dir.createFile(compat.io(), "second.txt", .{});
        defer second.close(compat.io());
        try compat.fileWriteAll(second, "b\n");
    }
    const first_path = try testTmpPathAlloc(allocator, &tmp, "first.txt");
    defer allocator.free(first_path);
    const second_path = try testTmpPathAlloc(allocator, &tmp, "second.txt");
    defer allocator.free(second_path);
    const exact_limits = testRuleProviderSyncLimits(4, 2, 2);

    var exact = try parseTwoCachedProviderConfig(
        allocator,
        first_path,
        second_path,
    );
    defer exact.deinit();
    try syncRuleProviderFilesIfNeededWithLimits(
        allocator,
        &exact,
        null,
        .missing_only,
        exact_limits,
    );

    {
        const second = try tmp.dir.createFile(compat.io(), "second.txt", .{
            .truncate = true,
        });
        defer second.close(compat.io());
        try compat.fileWriteAll(second, "bb\n");
    }
    var raw_overflow = try parseTwoCachedProviderConfig(
        allocator,
        first_path,
        second_path,
    );
    defer raw_overflow.deinit();
    try std.testing.expectError(
        error.RuleProviderAggregateSourceBytesLimitExceeded,
        syncRuleProviderFilesIfNeededWithLimits(
            allocator,
            &raw_overflow,
            null,
            .missing_only,
            exact_limits,
        ),
    );

    const normalized_limits = testRuleProviderSyncLimits(64, 2, 2);
    var byte_overflow = try parseTwoCachedProviderConfig(
        allocator,
        first_path,
        second_path,
    );
    defer byte_overflow.deinit();
    try std.testing.expectError(
        error.RuleProviderAggregateBytesLimitExceeded,
        syncRuleProviderFilesIfNeededWithLimits(
            allocator,
            &byte_overflow,
            null,
            .missing_only,
            normalized_limits,
        ),
    );

    {
        const second = try tmp.dir.createFile(compat.io(), "second.txt", .{
            .truncate = true,
        });
        defer second.close(compat.io());
        try compat.fileWriteAll(second, "b\nc\n");
    }
    var count_overflow = try parseTwoCachedProviderConfig(
        allocator,
        first_path,
        second_path,
    );
    defer count_overflow.deinit();
    try std.testing.expectError(
        error.RuleProviderAggregateEntryCountLimitExceeded,
        syncRuleProviderFilesIfNeededWithLimits(
            allocator,
            &count_overflow,
            null,
            .missing_only,
            testRuleProviderSyncLimits(64, 2, 64),
        ),
    );
}

test "sync raw budget counts comment amplification with no normalized entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const first = try tmp.dir.createFile(compat.io(), "first.txt", .{});
        defer first.close(compat.io());
        try compat.fileWriteAll(first, "#123456\n");
    }
    {
        const second = try tmp.dir.createFile(compat.io(), "second.txt", .{});
        defer second.close(compat.io());
        try compat.fileWriteAll(second, "#123456\n");
    }
    const first_path = try testTmpPathAlloc(allocator, &tmp, "first.txt");
    defer allocator.free(first_path);
    const second_path = try testTmpPathAlloc(allocator, &tmp, "second.txt");
    defer allocator.free(second_path);

    var exact = try parseTwoCachedProviderConfig(
        allocator,
        first_path,
        second_path,
    );
    defer exact.deinit();
    const limits = testRuleProviderSyncLimits(16, 1, 1);
    try syncRuleProviderFilesIfNeededWithLimits(
        allocator,
        &exact,
        null,
        .missing_only,
        limits,
    );

    {
        const second = try tmp.dir.createFile(compat.io(), "second.txt", .{
            .truncate = true,
        });
        defer second.close(compat.io());
        try compat.fileWriteAll(second, "#1234567\n");
    }
    var overflow = try parseTwoCachedProviderConfig(
        allocator,
        first_path,
        second_path,
    );
    defer overflow.deinit();
    try std.testing.expectError(
        error.RuleProviderAggregateSourceBytesLimitExceeded,
        syncRuleProviderFilesIfNeededWithLimits(
            allocator,
            &overflow,
            null,
            .missing_only,
            limits,
        ),
    );
}

test "downloaded candidates commit shared budgets only after atomic publish" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const first = try tmp.dir.createFile(compat.io(), "first.txt", .{});
        defer first.close(compat.io());
        try compat.fileWriteAll(first, "old-first.example\n");
    }
    {
        const second = try tmp.dir.createFile(compat.io(), "second.txt", .{});
        defer second.close(compat.io());
        try compat.fileWriteAll(second, "old-second.example\n");
    }
    const first_path = try testTmpPathAlloc(allocator, &tmp, "first.txt");
    defer allocator.free(first_path);
    const second_path = try testTmpPathAlloc(allocator, &tmp, "second.txt");
    defer allocator.free(second_path);
    var first_provider = testRuleProvider(.domain);
    first_provider.name = "first";
    first_provider.path = first_path;
    var second_provider = testRuleProvider(.domain);
    second_provider.name = "second";
    second_provider.path = second_path;

    var exact_budget = RuleProviderSyncBudget.init(
        testRuleProviderSyncLimits(4, 2, 2),
    );
    _ = try installDownloadedRuleProviderWithBudget(
        allocator,
        &first_provider,
        first_path,
        "a\n",
        "a\n".len,
        &exact_budget,
    );
    _ = try installDownloadedRuleProviderWithBudget(
        allocator,
        &second_provider,
        second_path,
        "b\n",
        "b\n".len,
        &exact_budget,
    );
    try std.testing.expectEqual(@as(usize, 4), exact_budget.source.consumed);
    try std.testing.expectEqual(
        @as(usize, 2),
        exact_budget.entries.aggregate_entry_count,
    );

    {
        const second = try tmp.dir.createFile(compat.io(), "second.txt", .{
            .truncate = true,
        });
        defer second.close(compat.io());
        try compat.fileWriteAll(second, "preserved.example\n");
    }
    var raw_overflow_budget = RuleProviderSyncBudget.init(
        testRuleProviderSyncLimits(4, 4, 64),
    );
    _ = try installDownloadedRuleProviderWithBudget(
        allocator,
        &first_provider,
        first_path,
        "a\n",
        "a\n".len,
        &raw_overflow_budget,
    );
    try std.testing.expectError(
        error.RuleProviderAggregateSourceBytesLimitExceeded,
        installDownloadedRuleProviderWithBudget(
            allocator,
            &second_provider,
            second_path,
            "bb\n",
            "bb\n".len,
            &raw_overflow_budget,
        ),
    );
    const raw_preserved = try tmp.dir.readFileAlloc(
        compat.io(),
        "second.txt",
        allocator,
        .limited(64),
    );
    defer allocator.free(raw_preserved);
    try std.testing.expectEqualStrings("preserved.example\n", raw_preserved);

    var normalized_overflow_budget = RuleProviderSyncBudget.init(
        testRuleProviderSyncLimits(6, 2, 2),
    );
    _ = try installDownloadedRuleProviderWithBudget(
        allocator,
        &first_provider,
        first_path,
        "a\n",
        "a\n".len,
        &normalized_overflow_budget,
    );
    try std.testing.expectError(
        error.RuleProviderAggregateBytesLimitExceeded,
        installDownloadedRuleProviderWithBudget(
            allocator,
            &second_provider,
            second_path,
            "bb\n",
            "bb\n".len,
            &normalized_overflow_budget,
        ),
    );
    const normalized_preserved = try tmp.dir.readFileAlloc(
        compat.io(),
        "second.txt",
        allocator,
        .limited(64),
    );
    defer allocator.free(normalized_preserved);
    try std.testing.expectEqualStrings(
        "preserved.example\n",
        normalized_preserved,
    );
}

fn downloadedCandidateAllocationFixture(allocator: std.mem.Allocator) !void {
    const provider = testRuleProvider(.domain);
    try validateDownloadedRuleProvider(
        allocator,
        &provider,
        "payload:\n  - one.example\n  - two.example\n",
    );
}

test "downloaded candidate validation cleans every failing allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        downloadedCandidateAllocationFixture,
        .{},
    );
}

test "rule-provider parser propagates YAML entry and nesting resource boundaries without legacy fallback" {
    const allocator = std.testing.allocator;
    const dashed = try repeatedRuleProviderLines(
        allocator,
        "- example.com\n",
        yaml_collection_entry_count_max + 1,
    );
    defer allocator.free(dashed);
    var dashed_provider = testRuleProvider(.domain);
    defer deinitTestRuleProviderEntries(allocator, &dashed_provider);
    try std.testing.expectError(
        error.YamlCollectionEntryLimitExceeded,
        appendRuleProviderEntriesOffline(allocator, &dashed_provider, dashed),
    );
    // A fallback would have appended entries before reaching the provider
    // limit; direct propagation leaves the candidate untouched.
    try std.testing.expectEqual(
        @as(usize, 0),
        dashed_provider.entries.items.len,
    );

    var nested = std.ArrayList(u8).empty;
    defer nested.deinit(allocator);
    for (0..130) |_| try nested.append(allocator, '[');
    try nested.appendSlice(allocator, "example.com");
    for (0..130) |_| try nested.append(allocator, ']');
    try nested.append(allocator, '\n');
    var nested_provider = testRuleProvider(.domain);
    defer deinitTestRuleProviderEntries(allocator, &nested_provider);
    try std.testing.expectError(
        error.YamlNestingTooDeep,
        appendRuleProviderEntriesOffline(
            allocator,
            &nested_provider,
            nested.items,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        nested_provider.entries.items.len,
    );
}

test "raw rule-provider aggregate entry limit accepts exact max and rejects max plus one" {
    const allocator = std.testing.allocator;
    const test_limit: usize = 3;
    const limits = RuleProviderBudgetLimits{
        .per_provider_entry_count_max = test_limit,
        .aggregate_entry_count_max = test_limit,
        .aggregate_bytes_max = rule_provider_aggregate_bytes_max,
    };
    const exact = try repeatedRuleProviderLines(
        allocator,
        "example.com\n",
        test_limit,
    );
    defer allocator.free(exact);
    var exact_provider = testRuleProvider(.domain);
    defer deinitTestRuleProviderEntries(allocator, &exact_provider);
    try appendRuleProviderEntriesOfflineWithLimits(
        allocator,
        &exact_provider,
        exact,
        limits,
    );
    try std.testing.expectEqual(
        test_limit,
        exact_provider.entries.items.len,
    );

    const overflow = try repeatedRuleProviderLines(
        allocator,
        "example.com\n",
        test_limit + 1,
    );
    defer allocator.free(overflow);
    var overflow_provider = testRuleProvider(.domain);
    defer deinitTestRuleProviderEntries(allocator, &overflow_provider);
    try std.testing.expectError(
        error.RuleProviderAggregateEntryCountLimitExceeded,
        appendRuleProviderEntriesOfflineWithLimits(
            allocator,
            &overflow_provider,
            overflow,
            limits,
        ),
    );
    try std.testing.expectEqual(
        test_limit,
        overflow_provider.entries.items.len,
    );

    var classical = testRuleProvider(.classical);
    defer deinitTestRuleProviderEntries(allocator, &classical);
    try appendRuleProviderEntriesOfflineWithLimits(
        allocator,
        &classical,
        "DOMAIN,example.com\nDOMAIN-SUFFIX,example.org\n",
        limits,
    );
    try std.testing.expectEqual(@as(usize, 2), classical.entries.items.len);
}

const AggregateBudgetResolver = struct {
    first: []const u8,
    second: []const u8,

    fn resolveLocal(
        self: *const AggregateBudgetResolver,
        path: []const u8,
    ) ![]const u8 {
        if (std.mem.eql(u8, path, "first.txt")) return self.first;
        if (std.mem.eql(u8, path, "second.txt")) return self.second;
        return error.AssetNotDeclared;
    }
};

fn parseAggregateBudgetConfig(allocator: std.mem.Allocator) !Config {
    return parseDocument(allocator,
        \\rule-providers:
        \\  first:
        \\    type: file
        \\    behavior: domain
        \\    path: first.txt
        \\  second:
        \\    type: file
        \\    behavior: domain
        \\    path: second.txt
        \\rules:
        \\  - MATCH,DIRECT
    );
}

fn makeRuleProviderCountDocument(
    allocator: std.mem.Allocator,
    provider_count: usize,
) ![]u8 {
    var source = std.ArrayList(u8).empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "rule-providers:\n");
    for (0..provider_count) |index| {
        var line_buffer: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "  provider-{d}: {{ type: file, behavior: domain, path: p{d}.txt }}\n",
            .{ index, index },
        );
        try source.appendSlice(allocator, line);
    }
    try source.appendSlice(allocator, "rules:\n  - MATCH,DIRECT\n");
    return source.toOwnedSlice(allocator);
}

test "rule-provider declaration count accepts 4096 and rejects 4097 before Config allocation" {
    const allocator = std.testing.allocator;
    const exact_source = try makeRuleProviderCountDocument(
        allocator,
        rule_provider_count_max,
    );
    defer allocator.free(exact_source);
    var exact = try parseDocument(allocator, exact_source);
    defer exact.deinit();
    try std.testing.expectEqual(
        rule_provider_count_max,
        exact.rule_providers.items.len,
    );

    const overflow_source = try makeRuleProviderCountDocument(
        allocator,
        rule_provider_count_max + 1,
    );
    defer allocator.free(overflow_source);
    var root = try yaml.parseDocument(allocator, overflow_source);
    defer root.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.RuleProviderCountLimitExceeded,
        parseRoot(failing.allocator(), &root, .runtime),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "fixed provider and expanded-rule arithmetic accepts max and rejects max plus one" {
    var provider = testRuleProvider(.domain);
    var budget = RuleProviderEntryBudget.init(.fixed);
    budget.aggregate_entry_count =
        rule_provider_aggregate_entry_count_max - 1;
    budget.aggregate_bytes = rule_provider_aggregate_bytes_max;
    const exact_entry = try budget.check(&provider, 0);
    budget.commit(exact_entry);
    try std.testing.expectEqual(
        rule_provider_aggregate_entry_count_max,
        budget.aggregate_entry_count,
    );
    try std.testing.expectEqual(
        rule_provider_aggregate_bytes_max,
        budget.aggregate_bytes,
    );
    try std.testing.expectError(
        error.RuleProviderAggregateEntryCountLimitExceeded,
        budget.check(&provider, 0),
    );

    var byte_budget = RuleProviderEntryBudget.init(.fixed);
    byte_budget.aggregate_bytes = rule_provider_aggregate_bytes_max;
    try std.testing.expectError(
        error.RuleProviderAggregateBytesLimitExceeded,
        byte_budget.check(&provider, 1),
    );

    try std.testing.expectEqual(
        expanded_rule_count_max,
        try addExpandedRuleCount(expanded_rule_count_max - 1, 1),
    );
    try std.testing.expectError(
        error.ExpandedRuleCountLimitExceeded,
        addExpandedRuleCount(expanded_rule_count_max, 1),
    );
    try std.testing.expectEqual(
        expanded_rule_bytes_max,
        try addExpandedRuleBytes(expanded_rule_bytes_max - 1, 1),
    );
    try std.testing.expectError(
        error.ExpandedRuleBytesLimitExceeded,
        addExpandedRuleBytes(expanded_rule_bytes_max, 1),
    );
}

test "offline provider loading shares aggregate count and byte budgets" {
    const allocator = std.testing.allocator;
    const count_limits = RuleProviderBudgetLimits{
        .per_provider_entry_count_max = 3,
        .aggregate_entry_count_max = 3,
        .aggregate_bytes_max = 32,
    };

    var exact_count = try parseAggregateBudgetConfig(allocator);
    defer exact_count.deinit();
    try loadRuleProviderEntriesOfflineWithLimits(
        allocator,
        &exact_count,
        &AggregateBudgetResolver{
            .first = "a\nb\n",
            .second = "c\n",
        },
        count_limits,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        exact_count.rule_providers.items[0].entries.items.len +
            exact_count.rule_providers.items[1].entries.items.len,
    );

    var count_overflow = try parseAggregateBudgetConfig(allocator);
    defer count_overflow.deinit();
    try std.testing.expectError(
        error.RuleProviderAggregateEntryCountLimitExceeded,
        loadRuleProviderEntriesOfflineWithLimits(
            allocator,
            &count_overflow,
            &AggregateBudgetResolver{
                .first = "a\nb\n",
                .second = "c\nd\n",
            },
            count_limits,
        ),
    );

    const byte_limits = RuleProviderBudgetLimits{
        .per_provider_entry_count_max = 4,
        .aggregate_entry_count_max = 4,
        .aggregate_bytes_max = 4,
    };
    var exact_bytes = try parseAggregateBudgetConfig(allocator);
    defer exact_bytes.deinit();
    try loadRuleProviderEntriesOfflineWithLimits(
        allocator,
        &exact_bytes,
        &AggregateBudgetResolver{
            .first = "aa\n",
            .second = "bb\n",
        },
        byte_limits,
    );

    var byte_overflow = try parseAggregateBudgetConfig(allocator);
    defer byte_overflow.deinit();
    try std.testing.expectError(
        error.RuleProviderAggregateBytesLimitExceeded,
        loadRuleProviderEntriesOfflineWithLimits(
            allocator,
            &byte_overflow,
            &AggregateBudgetResolver{
                .first = "aa\n",
                .second = "bbb\n",
            },
            byte_limits,
        ),
    );
}

fn appendOwnedTestProviderEntry(
    allocator: std.mem.Allocator,
    provider: *RuleProvider,
    entry: []const u8,
) !void {
    const owned = try allocator.dupe(u8, entry);
    errdefer allocator.free(owned);
    try provider.entries.append(allocator, owned);
}

fn parseRepeatedProviderReferenceConfig(
    allocator: std.mem.Allocator,
) !Config {
    var cfg = try parseDocument(allocator,
        \\rule-providers:
        \\  shared:
        \\    type: file
        \\    behavior: domain
        \\    path: shared.txt
        \\rules:
        \\  - RULE-SET,shared,DIRECT
        \\  - RULE-SET,shared,REJECT
        \\  - MATCH,DIRECT
    );
    errdefer cfg.deinit();
    try appendOwnedTestProviderEntry(
        allocator,
        &cfg.rule_providers.items[0],
        "one.example",
    );
    try appendOwnedTestProviderEntry(
        allocator,
        &cfg.rule_providers.items[0],
        "two.example",
    );
    return cfg;
}

test "RULE-SET preflight multiplies repeated references and reserves once" {
    const allocator = std.testing.allocator;
    var exact = try parseRepeatedProviderReferenceConfig(allocator);
    defer exact.deinit();
    var exact_probe = ExpansionTestProbe{};
    try expandRuleSetRulesWithLimits(
        allocator,
        &exact,
        false,
        .{
            .rule_count_max = 5,
            .rule_bytes_max = expanded_rule_bytes_max,
        },
        &exact_probe,
    );
    try std.testing.expectEqual(@as(usize, 5), exact.rules.items.len);
    try std.testing.expectEqual(@as(usize, 1), exact_probe.output_reserve_attempts);

    var overflow = try parseRepeatedProviderReferenceConfig(allocator);
    defer overflow.deinit();
    var overflow_probe = ExpansionTestProbe{};
    try std.testing.expectError(
        error.ExpandedRuleCountLimitExceeded,
        expandRuleSetRulesWithLimits(
            allocator,
            &overflow,
            false,
            .{
                .rule_count_max = 4,
                .rule_bytes_max = expanded_rule_bytes_max,
            },
            &overflow_probe,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), overflow_probe.output_reserve_attempts);
    try std.testing.expectEqual(@as(usize, 3), overflow.rules.items.len);
}

fn parseMultipleProviderExpansionConfig(
    allocator: std.mem.Allocator,
) !Config {
    var cfg = try parseDocument(allocator,
        \\rule-providers:
        \\  first:
        \\    type: file
        \\    behavior: domain
        \\    path: first.txt
        \\  second:
        \\    type: file
        \\    behavior: domain
        \\    path: second.txt
        \\rules:
        \\  - RULE-SET,first,DIRECT
        \\  - RULE-SET,second,DIRECT
        \\  - MATCH,DIRECT
    );
    errdefer cfg.deinit();
    for (cfg.rule_providers.items) |*provider| {
        try appendOwnedTestProviderEntry(allocator, provider, "a.example");
        try appendOwnedTestProviderEntry(allocator, provider, "b.example");
    }
    return cfg;
}

test "RULE-SET preflight accumulates multiple providers before output" {
    const allocator = std.testing.allocator;
    var cfg = try parseMultipleProviderExpansionConfig(allocator);
    defer cfg.deinit();
    var probe = ExpansionTestProbe{};
    try std.testing.expectError(
        error.ExpandedRuleCountLimitExceeded,
        expandRuleSetRulesWithLimits(
            allocator,
            &cfg,
            false,
            .{
                .rule_count_max = 4,
                .rule_bytes_max = expanded_rule_bytes_max,
            },
            &probe,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.output_reserve_attempts);
}

fn parseTargetAmplificationConfig(allocator: std.mem.Allocator) !Config {
    var cfg = try parseDocument(allocator,
        \\rule-providers:
        \\  target-amplifier:
        \\    type: file
        \\    behavior: domain
        \\    path: target.txt
        \\rules:
        \\  - RULE-SET,target-amplifier,0123456789abcdef
        \\  - MATCH,DIRECT
    );
    errdefer cfg.deinit();
    for ([_][]const u8{ "a", "b", "c" }) |entry| {
        try appendOwnedTestProviderEntry(
            allocator,
            &cfg.rule_providers.items[0],
            entry,
        );
    }
    return cfg;
}

test "RULE-SET preflight bounds target byte amplification at exact and plus one" {
    const allocator = std.testing.allocator;
    // Three one-byte payloads + three 16-byte targets + MATCH/DIRECT (6).
    const exact_owned_bytes: usize = 57;
    var exact = try parseTargetAmplificationConfig(allocator);
    defer exact.deinit();
    try expandRuleSetRulesWithLimits(
        allocator,
        &exact,
        false,
        .{
            .rule_count_max = expanded_rule_count_max,
            .rule_bytes_max = exact_owned_bytes,
        },
        null,
    );
    try std.testing.expectEqual(@as(usize, 4), exact.rules.items.len);

    var overflow = try parseTargetAmplificationConfig(allocator);
    defer overflow.deinit();
    var probe = ExpansionTestProbe{};
    try std.testing.expectError(
        error.ExpandedRuleBytesLimitExceeded,
        expandRuleSetRulesWithLimits(
            allocator,
            &overflow,
            false,
            .{
                .rule_count_max = expanded_rule_count_max,
                .rule_bytes_max = exact_owned_bytes - 1,
            },
            &probe,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.output_reserve_attempts);
}

test "RULE-SET over-limit preflight does not reach output allocation" {
    const allocator = std.testing.allocator;

    var failing_cfg = try parseRepeatedProviderReferenceConfig(allocator);
    defer failing_cfg.deinit();
    var failing_probe = ExpansionTestProbe{};
    var failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 1,
    });
    try std.testing.expectError(
        error.ExpandedRuleCountLimitExceeded,
        expandRuleSetRulesWithLimits(
            failing.allocator(),
            &failing_cfg,
            false,
            .{
                .rule_count_max = 4,
                .rule_bytes_max = expanded_rule_bytes_max,
            },
            &failing_probe,
        ),
    );
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing_probe.output_reserve_attempts);

    var fixed_cfg = try parseRepeatedProviderReferenceConfig(allocator);
    defer fixed_cfg.deinit();
    var fixed_probe = ExpansionTestProbe{};
    var fixed_storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_storage);
    try std.testing.expectError(
        error.ExpandedRuleCountLimitExceeded,
        expandRuleSetRulesWithLimits(
            fixed.allocator(),
            &fixed_cfg,
            false,
            .{
                .rule_count_max = 4,
                .rule_bytes_max = expanded_rule_bytes_max,
            },
            &fixed_probe,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fixed_probe.output_reserve_attempts);
}

test "RULE-SET provider hash index rejects duplicate borrowed names" {
    const allocator = std.testing.allocator;
    var cfg = try parseMultipleProviderExpansionConfig(allocator);
    defer cfg.deinit();
    allocator.free(cfg.rule_providers.items[1].name);
    cfg.rule_providers.items[1].name = try allocator.dupe(
        u8,
        cfg.rule_providers.items[0].name,
    );
    var probe = ExpansionTestProbe{};
    try std.testing.expectError(
        error.DuplicateRuleProviderName,
        expandRuleSetRulesWithLimits(
            allocator,
            &cfg,
            false,
            .fixed,
            &probe,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.output_reserve_attempts);
}

test "RULE-SET provider index and reference lookups grow linearly" {
    const allocator = std.testing.allocator;
    const provider_count: usize = 64;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "rule-providers:\n");
    for (0..provider_count) |index| {
        var line_buffer: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "  p{d}: {{ type: file, behavior: domain, path: p{d}.txt }}\n",
            .{ index, index },
        );
        try source.appendSlice(allocator, line);
    }
    try source.appendSlice(allocator, "rules:\n");
    for (0..provider_count) |index| {
        var line_buffer: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "  - RULE-SET,p{d},DIRECT\n",
            .{index},
        );
        try source.appendSlice(allocator, line);
    }
    try source.appendSlice(allocator, "  - MATCH,DIRECT\n");

    var cfg = try parseDocument(allocator, source.items);
    defer cfg.deinit();
    for (cfg.rule_providers.items) |*provider| {
        try appendOwnedTestProviderEntry(allocator, provider, "x");
    }
    var probe = ExpansionTestProbe{};
    try expandRuleSetRulesWithLimits(
        allocator,
        &cfg,
        false,
        .fixed,
        &probe,
    );
    try std.testing.expectEqual(
        provider_count,
        probe.provider_index_inserts,
    );
    try std.testing.expectEqual(
        provider_count,
        probe.preflight_provider_lookups,
    );
    try std.testing.expectEqual(@as(usize, 1), probe.output_reserve_attempts);
    try std.testing.expectEqual(provider_count + 1, cfg.rules.items.len);
}

const TestOfflineRuleProviderResolver = struct {
    local_bytes: []const u8 = "",

    fn resolveLocal(
        self: *const TestOfflineRuleProviderResolver,
        _: []const u8,
    ) ![]const u8 {
        return self.local_bytes;
    }
};

test "managed rule-provider resolution gate rejects only a still-referenced remote provider" {
    const allocator = std.testing.allocator;
    const remote_source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  deferred:
        \\    type: http
        \\    behavior: domain
        \\    url: https://example.invalid/rules.yaml
        \\    path: deferred.yaml
        \\rules:
        \\  - RULE-SET,deferred,DIRECT
        \\  - MATCH,DIRECT
    ;
    var remote = try parseDocument(allocator, remote_source);
    defer remote.deinit();
    const empty_resolver = TestOfflineRuleProviderResolver{};
    try prepareRuleProvidersOffline(allocator, &remote, &empty_resolver);
    try std.testing.expectError(
        error.ManagedRemoteRuleProviderUnsupported,
        requireManagedRuleProvidersResolved(&remote),
    );

    var unused_remote = try parseDocument(allocator,
        \\mixed-port: 7890
        \\rule-providers:
        \\  unused:
        \\    type: http
        \\    behavior: domain
        \\    url: https://example.invalid/unused.yaml
        \\    path: unused.yaml
        \\rules:
        \\  - MATCH,DIRECT
    );
    defer unused_remote.deinit();
    try prepareRuleProvidersOffline(
        allocator,
        &unused_remote,
        &empty_resolver,
    );
    try requireManagedRuleProvidersResolved(&unused_remote);

    var local = try parseDocument(allocator,
        \\mixed-port: 7890
        \\rule-providers:
        \\  captured:
        \\    type: file
        \\    behavior: domain
        \\    path: captured.txt
        \\rules:
        \\  - RULE-SET,captured,DIRECT
        \\  - MATCH,DIRECT
    );
    defer local.deinit();
    const local_resolver = TestOfflineRuleProviderResolver{
        .local_bytes = "example.com\n",
    };
    try prepareRuleProvidersOffline(allocator, &local, &local_resolver);
    try requireManagedRuleProvidersResolved(&local);
    try std.testing.expectEqual(@as(RuleType, .domain_suffix), local.rules.items[0].rule_type);
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

test "sync passes the aggregate remaining byte cap to refresh fetch before publish" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const first = try tmp.dir.createFile(compat.io(), "first.txt", .{});
        defer first.close(compat.io());
        try compat.fileWriteAll(first, "a\n");
    }
    const preserved = "preserved.example\n";
    {
        const refresh = try tmp.dir.createFile(compat.io(), "refresh.txt", .{});
        defer refresh.close(compat.io());
        try compat.fileWriteAll(refresh, preserved);
    }
    const first_path = try testTmpPathAlloc(allocator, &tmp, "first.txt");
    defer allocator.free(first_path);
    const refresh_path = try testTmpPathAlloc(allocator, &tmp, "refresh.txt");
    defer allocator.free(refresh_path);

    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    var hits = std.atomic.Value(u32).init(0);
    const thread = try std.Thread.spawn(.{}, serveSingleRuleProviderResponse, .{
        &server,
        &hits,
        "200 OK",
        // The first cached source consumes two of eight bytes, so this
        // seven-byte response must trip the six-byte fetch cap.
        "1234567",
    });
    defer thread.join();
    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/refresh.txt",
        .{server.listen_address.getPort()},
    );
    defer allocator.free(url);
    var cfg = try parseCachedThenRefreshProviderConfig(
        allocator,
        first_path,
        refresh_path,
        url,
    );
    defer cfg.deinit();
    cfg.rule_providers.items[1].interval = 0;

    try std.testing.expectError(
        error.RuleProviderAggregateSourceBytesLimitExceeded,
        syncRuleProviderFilesIfNeededWithLimits(
            allocator,
            &cfg,
            null,
            .eager,
            testRuleProviderSyncLimits(8, 8, 64),
        ),
    );
    try std.testing.expectEqual(@as(u32, 1), hits.load(.monotonic));
    const after = try tmp.dir.readFileAlloc(
        compat.io(),
        "refresh.txt",
        allocator,
        .limited(64),
    );
    defer allocator.free(after);
    try std.testing.expectEqualStrings(preserved, after);
}

test "refresh normalized resource error does not fall back to stale cache" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const preserved = "cached.example\n";
    {
        const refresh = try tmp.dir.createFile(compat.io(), "refresh.txt", .{});
        defer refresh.close(compat.io());
        try compat.fileWriteAll(refresh, preserved);
    }
    const refresh_path = try testTmpPathAlloc(allocator, &tmp, "refresh.txt");
    defer allocator.free(refresh_path);
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    var hits = std.atomic.Value(u32).init(0);
    const thread = try std.Thread.spawn(.{}, serveSingleRuleProviderResponse, .{
        &server,
        &hits,
        "200 OK",
        "a\nb\n",
    });
    defer thread.join();
    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/refresh.txt",
        .{server.listen_address.getPort()},
    );
    defer allocator.free(url);
    var cfg = try parseRefreshProviderConfig(
        allocator,
        refresh_path,
        url,
    );
    defer cfg.deinit();
    cfg.rule_providers.items[0].interval = 0;

    try std.testing.expectError(
        error.RuleProviderAggregateEntryCountLimitExceeded,
        syncRuleProviderFilesIfNeededWithLimits(
            allocator,
            &cfg,
            null,
            .eager,
            testRuleProviderSyncLimits(64, 1, 64),
        ),
    );
    const after = try tmp.dir.readFileAlloc(
        compat.io(),
        "refresh.txt",
        allocator,
        .limited(64),
    );
    defer allocator.free(after);
    try std.testing.expectEqualStrings(preserved, after);
}

test "ordinary refresh status failure falls back and budgets cached source" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const preserved = "cached.example\n";
    {
        const refresh = try tmp.dir.createFile(compat.io(), "refresh.txt", .{});
        defer refresh.close(compat.io());
        try compat.fileWriteAll(refresh, preserved);
    }
    const refresh_path = try testTmpPathAlloc(allocator, &tmp, "refresh.txt");
    defer allocator.free(refresh_path);
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    var hits = std.atomic.Value(u32).init(0);
    const thread = try std.Thread.spawn(.{}, serveSingleRuleProviderResponse, .{
        &server,
        &hits,
        "503 Service Unavailable",
        "no\n",
    });
    defer thread.join();
    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/refresh.txt",
        .{server.listen_address.getPort()},
    );
    defer allocator.free(url);
    var cfg = try parseRefreshProviderConfig(
        allocator,
        refresh_path,
        url,
    );
    defer cfg.deinit();
    cfg.rule_providers.items[0].interval = 0;

    try syncRuleProviderFilesIfNeededWithLimits(
        allocator,
        &cfg,
        null,
        .eager,
        testRuleProviderSyncLimits(32, 2, 64),
    );
    try std.testing.expectEqual(@as(u32, 1), hits.load(.monotonic));
    const after = try tmp.dir.readFileAlloc(
        compat.io(),
        "refresh.txt",
        allocator,
        .limited(64),
    );
    defer allocator.free(after);
    try std.testing.expectEqualStrings(preserved, after);
}

const TestHttpScriptResponse = struct {
    expected_target: []const u8,
    status: []const u8,
    location: ?[]const u8 = null,
    body: []const u8,
};

const TestHttpScriptControl = struct {
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    hits: std.atomic.Value(usize) = .init(0),

    fn fail(self: *@This()) void {
        self.failed.store(true, .release);
    }
};

const test_http_script_deadline_ms: i64 = 3_000;
const test_http_script_poll_slice_ms: i32 = 20;

fn testHttpScriptWait(
    fd: std.posix.fd_t,
    requested: i16,
    control: *TestHttpScriptControl,
    deadline_ms: i64,
) !bool {
    while (!control.stop.load(.acquire)) {
        const now_ms = compat.monotonicMilliTimestamp();
        if (now_ms >= deadline_ms) return error.TestHttpScriptTimeout;
        const remaining = std.math.sub(
            i64,
            deadline_ms,
            now_ms,
        ) catch return error.TestHttpScriptTimeout;
        const timeout_ms: i32 = @intCast(@min(
            remaining,
            @as(i64, test_http_script_poll_slice_ms),
        ));
        var descriptors = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = requested,
            .revents = 0,
        }};
        const ready = std.c.poll(
            &descriptors,
            descriptors.len,
            timeout_ms,
        );
        if (ready < 0) switch (std.c.errno(ready)) {
            .INTR => continue,
            .NOMEM => return error.SystemResources,
            else => return error.TestHttpScriptPollFailed,
        };
        if (ready == 0) continue;
        const events = descriptors[0].revents;
        if (events & std.posix.POLL.NVAL != 0) {
            return error.TestHttpScriptInvalidSocket;
        }
        if (events &
            (requested | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)
        {
            return true;
        }
        return error.TestHttpScriptUnexpectedPollEvent;
    }
    return false;
}

fn testHttpScriptReadRequest(
    connection: compat.net.Server.Connection,
    control: *TestHttpScriptControl,
    deadline_ms: i64,
    storage: []u8,
) ![]const u8 {
    var used: usize = 0;
    while (used < storage.len) {
        if (!try testHttpScriptWait(
            connection.stream.handle,
            std.posix.POLL.IN,
            control,
            deadline_ms,
        )) return error.TestHttpScriptStopped;
        const count = connection.stream.read(storage[used..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => |other| return other,
        };
        if (count == 0) return error.TestHttpScriptTruncatedRequest;
        used = std.math.add(usize, used, count) catch
            return error.TestHttpScriptRequestTooLarge;
        if (std.mem.indexOf(u8, storage[0..used], "\r\n\r\n") != null) {
            return storage[0..used];
        }
    }
    return error.TestHttpScriptRequestTooLarge;
}

fn testHttpScriptWriteAll(
    connection: compat.net.Server.Connection,
    control: *TestHttpScriptControl,
    deadline_ms: i64,
    bytes: []const u8,
) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (!try testHttpScriptWait(
            connection.stream.handle,
            std.posix.POLL.OUT,
            control,
            deadline_ms,
        )) return error.TestHttpScriptStopped;
        const count = connection.stream.write(bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => |other| return other,
        };
        if (count == 0) return error.TestHttpScriptWriteZero;
        offset = std.math.add(usize, offset, count) catch
            return error.TestHttpScriptResponseTooLarge;
    }
}

fn testHttpScriptRequestMatches(
    request: []const u8,
    expected_target: []const u8,
) bool {
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return false;
    var fields = std.mem.splitScalar(u8, request[0..line_end], ' ');
    const method = fields.next() orelse return false;
    const target = fields.next() orelse return false;
    const version = fields.next() orelse return false;
    if (fields.next() != null or
        !std.mem.eql(u8, method, "GET") or
        !std.mem.eql(u8, target, expected_target) or
        !std.mem.eql(u8, version, "HTTP/1.1"))
    {
        return false;
    }
    return std.ascii.indexOfIgnoreCase(
        request,
        "\r\naccept-encoding: identity\r\n",
    ) != null;
}

fn serveTestHttpScript(
    server: *compat.net.Server,
    script: []const TestHttpScriptResponse,
    control: *TestHttpScriptControl,
) void {
    const deadline_ms = std.math.add(
        i64,
        compat.monotonicMilliTimestamp(),
        test_http_script_deadline_ms,
    ) catch std.math.maxInt(i64);

    for (script) |scripted| {
        var connection = accept: while (!control.stop.load(.acquire)) {
            const ready = testHttpScriptWait(
                server.inner.socket.handle,
                std.posix.POLL.IN,
                control,
                deadline_ms,
            ) catch {
                control.fail();
                return;
            };
            if (!ready) return;
            break :accept server.accept() catch |err| switch (err) {
                error.WouldBlock, error.ConnectionAborted => continue :accept,
                else => {
                    control.fail();
                    return;
                },
            };
        } else return;
        defer connection.stream.close();
        compat.setNonBlock(connection.stream.handle) catch {
            control.fail();
            return;
        };

        var request_storage: [8 * 1024]u8 = undefined;
        const request = testHttpScriptReadRequest(
            connection,
            control,
            deadline_ms,
            &request_storage,
        ) catch |err| {
            if (err != error.TestHttpScriptStopped) control.fail();
            return;
        };
        _ = control.hits.fetchAdd(1, .acq_rel);
        if (!testHttpScriptRequestMatches(request, scripted.expected_target)) {
            control.fail();
            return;
        }

        var header_storage: [16 * 1024]u8 = undefined;
        const header = if (scripted.location) |location|
            std.fmt.bufPrint(
                &header_storage,
                "HTTP/1.1 {s}\r\nLocation: {s}\r\n" ++
                    "Content-Length: {d}\r\nConnection: close\r\n\r\n",
                .{ scripted.status, location, scripted.body.len },
            ) catch {
                control.fail();
                return;
            }
        else
            std.fmt.bufPrint(
                &header_storage,
                "HTTP/1.1 {s}\r\nContent-Length: {d}\r\n" ++
                    "Connection: close\r\n\r\n",
                .{ scripted.status, scripted.body.len },
            ) catch {
                control.fail();
                return;
            };
        testHttpScriptWriteAll(
            connection,
            control,
            deadline_ms,
            header,
        ) catch |err| {
            if (err != error.TestHttpScriptStopped) control.fail();
            return;
        };
        testHttpScriptWriteAll(
            connection,
            control,
            deadline_ms,
            scripted.body,
        ) catch |err| {
            if (err != error.TestHttpScriptStopped) control.fail();
            return;
        };
    }
}

fn stopAndJoinTestHttpScript(
    control: *TestHttpScriptControl,
    thread: std.Thread,
) void {
    control.stop.store(true, .release);
    thread.join();
}

const TestRawHttpCloseBehavior = enum {
    close,
    reset,
    hold_until_released,
};

const TestRawHttpControl = struct {
    release: std.atomic.Value(bool) = .init(false),
    response_written: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
};

fn testRawHttpSleep(milliseconds: i32) void {
    var no_descriptors: [0]std.posix.pollfd = .{};
    _ = std.posix.poll(&no_descriptors, milliseconds) catch {};
}

fn serveSingleRawHttpResponse(
    server: *compat.net.Server,
    response: []const u8,
    close_behavior: TestRawHttpCloseBehavior,
    control: *TestRawHttpControl,
) void {
    var connection = server.accept() catch {
        control.failed.store(true, .release);
        return;
    };
    defer connection.stream.close();

    var request_storage: [4 * 1024]u8 = undefined;
    var request_len: usize = 0;
    while (std.mem.indexOf(
        u8,
        request_storage[0..request_len],
        "\r\n\r\n",
    ) == null) {
        if (request_len == request_storage.len) {
            control.failed.store(true, .release);
            return;
        }
        const count = connection.stream.read(
            request_storage[request_len..],
        ) catch {
            control.failed.store(true, .release);
            return;
        };
        if (count == 0) {
            control.failed.store(true, .release);
            return;
        }
        request_len += count;
    }

    // Intentionally issue the complete scripted response in one socket write.
    // Several accounting tests depend on the head parser being able to prefetch
    // body bytes in the same underlying read.
    const written = connection.stream.write(response) catch {
        control.failed.store(true, .release);
        return;
    };
    if (written != response.len) {
        control.failed.store(true, .release);
        return;
    }
    control.response_written.store(true, .release);

    switch (close_behavior) {
        .close => {},
        .reset => {
            // Give the client time to parse the complete head and consume the
            // partial close-delimited body before surfacing a socket reset.
            testRawHttpSleep(75);
            const Linger = extern struct {
                enabled: i32,
                timeout_seconds: i32,
            };
            const linger = Linger{
                .enabled = 1,
                .timeout_seconds = 0,
            };
            std.posix.setsockopt(
                connection.stream.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.LINGER,
                std.mem.asBytes(&linger),
            ) catch {
                control.failed.store(true, .release);
            };
        },
        .hold_until_released => {
            while (!control.release.load(.acquire)) {
                testRawHttpSleep(5);
            }
        },
    }
}

const TestStdHttpPrimaryTransports = struct {
    primary_calls: usize = 0,
    fallback_calls: usize = 0,
    primary_limit: usize = 0,
    fallback_limit: usize = 0,

    fn fetchPrimary(
        self: *@This(),
        allocator: std.mem.Allocator,
        url: []const u8,
        options: FetchConfigOptions,
        accounting: *FetchAttemptAccounting,
    ) !DownloadResult {
        self.primary_calls += 1;
        self.primary_limit = options.body_bytes_max;
        return fetchConfigWithStdHttp(
            allocator,
            url,
            options,
            accounting,
        );
    }

    fn fetchFallback(
        self: *@This(),
        allocator: std.mem.Allocator,
        _: []const u8,
        options: FetchConfigOptions,
        accounting: *FetchAttemptAccounting,
    ) !DownloadResult {
        self.fallback_calls += 1;
        self.fallback_limit = options.body_bytes_max;
        const body = try allocator.dupe(u8, "fallback\n");
        accounting.* = .{
            .source_bytes_consumed = body.len,
            .exact = true,
        };
        return .{
            .status = .ok,
            .body = body,
            .total_source_bytes_consumed = body.len,
        };
    }
};

const TestFetchOutcome = union(enum) {
    response: struct {
        status: std.http.Status,
        body: []const u8,
        source_bytes_consumed: usize,
    },
    failure: struct {
        err: anyerror,
        source_bytes_consumed: usize,
        exact: bool,
    },
};

const TestFetchTransports = struct {
    primary: TestFetchOutcome,
    fallback: TestFetchOutcome,
    primary_calls: usize = 0,
    fallback_calls: usize = 0,
    primary_limit: usize = 0,
    fallback_limit: usize = 0,

    fn runOutcome(
        outcome: TestFetchOutcome,
        allocator: std.mem.Allocator,
        accounting: *FetchAttemptAccounting,
    ) !DownloadResult {
        return switch (outcome) {
            .failure => |failed| {
                accounting.* = .{
                    .source_bytes_consumed = failed.source_bytes_consumed,
                    .exact = failed.exact,
                };
                return failed.err;
            },
            .response => |response| {
                accounting.* = .{
                    .source_bytes_consumed = response.source_bytes_consumed,
                    .exact = true,
                };
                const body = try allocator.dupe(u8, response.body);
                return .{
                    .status = response.status,
                    .body = body,
                    .total_source_bytes_consumed = response.source_bytes_consumed,
                };
            },
        };
    }

    fn fetchPrimary(
        self: *@This(),
        allocator: std.mem.Allocator,
        _: []const u8,
        options: FetchConfigOptions,
        accounting: *FetchAttemptAccounting,
    ) !DownloadResult {
        self.primary_calls += 1;
        self.primary_limit = options.body_bytes_max;
        return runOutcome(self.primary, allocator, accounting);
    }

    fn fetchFallback(
        self: *@This(),
        allocator: std.mem.Allocator,
        _: []const u8,
        options: FetchConfigOptions,
        accounting: *FetchAttemptAccounting,
    ) !DownloadResult {
        self.fallback_calls += 1;
        self.fallback_limit = options.body_bytes_max;
        return runOutcome(self.fallback, allocator, accounting);
    }
};

fn testFetchFailure(
    err: anyerror,
    source_bytes_consumed: usize,
    exact: bool,
) TestFetchOutcome {
    return .{ .failure = .{
        .err = err,
        .source_bytes_consumed = source_bytes_consumed,
        .exact = exact,
    } };
}

fn testFetchResponse(
    status: std.http.Status,
    body: []const u8,
) TestFetchOutcome {
    return .{ .response = .{
        .status = status,
        .body = body,
        .source_bytes_consumed = body.len,
    } };
}

test "fetch fallback shares remaining cap after std failure and HTTP 400" {
    const allocator = std.testing.allocator;

    var failed_primary = TestFetchTransports{
        .primary = testFetchFailure(error.ConnectionResetByPeer, 3, true),
        .fallback = testFetchResponse(.ok, "curl\n"),
    };
    const failed_result = try fetchConfigHTTPUsing(
        TestFetchTransports,
        &failed_primary,
        allocator,
        "https://provider.invalid/rules.yaml",
        .{ .body_bytes_max = 10 },
        true,
    );
    defer allocator.free(failed_result.body);
    try std.testing.expectEqualStrings("curl\n", failed_result.body);
    try std.testing.expectEqual(@as(usize, 8), failed_result.total_source_bytes_consumed);
    try std.testing.expectEqual(@as(usize, 1), failed_primary.primary_calls);
    try std.testing.expectEqual(@as(usize, 1), failed_primary.fallback_calls);
    try std.testing.expectEqual(@as(usize, 10), failed_primary.primary_limit);
    try std.testing.expectEqual(@as(usize, 7), failed_primary.fallback_limit);

    var bad_request = TestFetchTransports{
        .primary = testFetchResponse(.bad_request, "bad"),
        .fallback = testFetchResponse(.ok, "ok"),
    };
    const retried_result = try fetchConfigHTTPUsing(
        TestFetchTransports,
        &bad_request,
        allocator,
        "https://provider.invalid/rules.yaml",
        .{ .body_bytes_max = 9 },
        true,
    );
    defer allocator.free(retried_result.body);
    try std.testing.expectEqual(std.http.Status.ok, retried_result.status);
    try std.testing.expectEqualStrings("ok", retried_result.body);
    try std.testing.expectEqual(@as(usize, 5), retried_result.total_source_bytes_consumed);
    try std.testing.expectEqual(@as(usize, 9), bad_request.primary_limit);
    try std.testing.expectEqual(@as(usize, 6), bad_request.fallback_limit);
}

test "fetch fallback conservatively closes its one aggregate window on unknown failure" {
    var accounting = FetchFailureAccounting{};
    var transports = TestFetchTransports{
        .primary = testFetchFailure(error.ConnectionResetByPeer, 2, true),
        .fallback = testFetchFailure(error.DownloadFailed, 1, false),
    };
    try std.testing.expectError(
        error.ConnectionResetByPeer,
        fetchConfigHTTPUsing(
            TestFetchTransports,
            &transports,
            std.testing.allocator,
            "https://provider.invalid/rules.yaml",
            .{
                .body_bytes_max = 10,
                .failure_accounting = &accounting,
            },
            true,
        ),
    );
    try std.testing.expectEqual(@as(usize, 10), accounting.source_bytes_consumed);
    try std.testing.expect(!accounting.exact);
    try std.testing.expectEqual(@as(usize, 10), transports.primary_limit);
    try std.testing.expectEqual(@as(usize, 8), transports.fallback_limit);
    try std.testing.expectEqual(
        transports.primary_limit,
        2 + transports.fallback_limit,
    );
}

test "fetch cancellation propagates without starting or masking a transport" {
    var primary_accounting = FetchFailureAccounting{};
    var primary_canceled = TestFetchTransports{
        .primary = testFetchFailure(error.Canceled, 2, true),
        .fallback = testFetchResponse(.ok, "must-not-run"),
    };
    try std.testing.expectError(
        error.Canceled,
        fetchConfigHTTPUsing(
            TestFetchTransports,
            &primary_canceled,
            std.testing.allocator,
            "https://provider.invalid/rules.yaml",
            .{
                .body_bytes_max = 10,
                .failure_accounting = &primary_accounting,
            },
            true,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), primary_canceled.primary_calls);
    try std.testing.expectEqual(@as(usize, 0), primary_canceled.fallback_calls);
    try std.testing.expectEqual(@as(usize, 2), primary_accounting.source_bytes_consumed);
    try std.testing.expect(primary_accounting.exact);

    var fallback_accounting = FetchFailureAccounting{};
    var fallback_canceled = TestFetchTransports{
        .primary = testFetchResponse(.bad_request, "old"),
        .fallback = testFetchFailure(error.Canceled, 2, true),
    };
    try std.testing.expectError(
        error.Canceled,
        fetchConfigHTTPUsing(
            TestFetchTransports,
            &fallback_canceled,
            std.testing.allocator,
            "https://provider.invalid/rules.yaml",
            .{
                .body_bytes_max = 10,
                .failure_accounting = &fallback_accounting,
            },
            true,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), fallback_canceled.primary_calls);
    try std.testing.expectEqual(@as(usize, 1), fallback_canceled.fallback_calls);
    try std.testing.expectEqual(@as(usize, 5), fallback_accounting.source_bytes_consumed);
    try std.testing.expect(fallback_accounting.exact);
}

test "close-delimited identity response times out without inspecting uninitialized decompressor" {
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\n" ++
        "Content-Encoding: identity\r\n" ++
        "Connection: close\r\n\r\n" ++
        "partial-body";
    var control = TestRawHttpControl{};
    const thread = try std.Thread.spawn(
        .{},
        serveSingleRawHttpResponse,
        .{
            &server,
            raw_response,
            TestRawHttpCloseBehavior.hold_until_released,
            &control,
        },
    );
    var joined = false;
    defer if (!joined) {
        control.release.store(true, .release);
        thread.join();
    };

    var url_storage: [160]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_storage,
        "http://127.0.0.1:{d}/close-delimited",
        .{server.listen_address.getPort()},
    );
    var accounting = FetchFailureAccounting{};
    try std.testing.expectError(
        error.DownloadTimeout,
        fetchConfigWithOptions(std.testing.allocator, url, .{
            .body_bytes_max = 64,
            .deadline_ms = 200,
            .allow_curl_fallback = false,
            .failure_accounting = &accounting,
        }),
    );

    control.release.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(control.response_written.load(.acquire));
    try std.testing.expect(!control.failed.load(.acquire));
    // Cancellation happens while transport buffering may contain unread body
    // bytes, so the public failure accounting conservatively closes the full
    // advertised window rather than claiming the copied prefix is exact.
    try std.testing.expectEqual(@as(usize, 64), accounting.source_bytes_consumed);
    try std.testing.expect(!accounting.exact);
}

test "close-delimited identity response preserves concrete reset read error" {
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\n" ++
        "Content-Encoding: identity\r\n" ++
        "Connection: close\r\n\r\n" ++
        "partial-body";
    var control = TestRawHttpControl{};
    const thread = try std.Thread.spawn(
        .{},
        serveSingleRawHttpResponse,
        .{
            &server,
            raw_response,
            TestRawHttpCloseBehavior.reset,
            &control,
        },
    );
    defer thread.join();

    var url_storage: [160]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_storage,
        "http://127.0.0.1:{d}/reset",
        .{server.listen_address.getPort()},
    );
    var accounting = FetchAttemptAccounting{};
    try std.testing.expectError(
        error.ConnectionResetByPeer,
        fetchConfigWithStdHttp(
            std.testing.allocator,
            url,
            .{
                .body_bytes_max = 64,
                .allow_curl_fallback = false,
            },
            &accounting,
        ),
    );
    try std.testing.expect(control.response_written.load(.acquire));
    try std.testing.expect(!control.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, "partial-body".len), accounting.source_bytes_consumed);
    try std.testing.expect(!accounting.exact);
}

test "complete unsupported encoding head closes accounting window before fallback" {
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\n" ++
        "Content-Encoding: compress\r\n" ++
        "Content-Length: 4\r\n" ++
        "Connection: close\r\n\r\n" ++
        "body";
    var control = TestRawHttpControl{};
    const thread = try std.Thread.spawn(
        .{},
        serveSingleRawHttpResponse,
        .{
            &server,
            raw_response,
            TestRawHttpCloseBehavior.close,
            &control,
        },
    );
    defer thread.join();

    var url_storage: [160]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_storage,
        "http://127.0.0.1:{d}/unsupported",
        .{server.listen_address.getPort()},
    );
    var transports = TestStdHttpPrimaryTransports{};
    var accounting = FetchFailureAccounting{};
    if (fetchConfigHTTPUsing(
        TestStdHttpPrimaryTransports,
        &transports,
        std.testing.allocator,
        url,
        .{
            .body_bytes_max = 32,
            .failure_accounting = &accounting,
        },
        true,
    )) |unexpected| {
        std.testing.allocator.free(unexpected.body);
        return error.TestExpectedUnsupportedContentEncoding;
    } else |err| {
        try std.testing.expectEqual(error.HttpContentEncodingUnsupported, err);
    }

    try std.testing.expect(control.response_written.load(.acquire));
    try std.testing.expect(!control.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), transports.primary_calls);
    try std.testing.expectEqual(@as(usize, 0), transports.fallback_calls);
    try std.testing.expectEqual(@as(usize, 32), transports.primary_limit);
    try std.testing.expectEqual(@as(usize, 32), accounting.source_bytes_consumed);
    try std.testing.expect(!accounting.exact);
}

test "incomplete response head retains exact accounting and permits fallback" {
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain";
    var control = TestRawHttpControl{};
    const thread = try std.Thread.spawn(
        .{},
        serveSingleRawHttpResponse,
        .{
            &server,
            raw_response,
            TestRawHttpCloseBehavior.close,
            &control,
        },
    );
    defer thread.join();

    var url_storage: [160]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_storage,
        "http://127.0.0.1:{d}/truncated-head",
        .{server.listen_address.getPort()},
    );
    var transports = TestStdHttpPrimaryTransports{};
    const result = try fetchConfigHTTPUsing(
        TestStdHttpPrimaryTransports,
        &transports,
        std.testing.allocator,
        url,
        .{ .body_bytes_max = 32 },
        true,
    );
    defer std.testing.allocator.free(result.body);

    try std.testing.expect(control.response_written.load(.acquire));
    try std.testing.expect(!control.failed.load(.acquire));
    try std.testing.expectEqualStrings("fallback\n", result.body);
    try std.testing.expectEqual(@as(usize, "fallback\n".len), result.total_source_bytes_consumed);
    try std.testing.expectEqual(@as(usize, 1), transports.primary_calls);
    try std.testing.expectEqual(@as(usize, 1), transports.fallback_calls);
    try std.testing.expectEqual(@as(usize, 32), transports.primary_limit);
    try std.testing.expectEqual(@as(usize, 32), transports.fallback_limit);
}

fn fetchFallbackAllocationFixture(allocator: std.mem.Allocator) !void {
    var transports = TestFetchTransports{
        .primary = testFetchResponse(.bad_request, "bad"),
        .fallback = testFetchResponse(.ok, "fresh.example\n"),
    };
    const result = try fetchConfigHTTPUsing(
        TestFetchTransports,
        &transports,
        allocator,
        "https://provider.invalid/rules.yaml",
        .{ .body_bytes_max = 64 },
        true,
    );
    defer allocator.free(result.body);
    try std.testing.expectEqualStrings("fresh.example\n", result.body);
}

test "fetch fallback releases primary and fallback bodies on every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        fetchFallbackAllocationFixture,
        .{},
    );
}

test "std HTTP redirects share one exact body cap across relative and cross-host hops" {
    const allocator = std.testing.allocator;
    var first_server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer first_server.deinit();
    try compat.setNonBlock(first_server.inner.socket.handle);
    var final_server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer final_server.deinit();
    try compat.setNonBlock(final_server.inner.socket.handle);

    var absolute_location_storage: [160]u8 = undefined;
    const absolute_location = try std.fmt.bufPrint(
        &absolute_location_storage,
        "http://127.0.0.1:{d}/final",
        .{final_server.listen_address.getPort()},
    );
    const first_script = [_]TestHttpScriptResponse{
        .{
            .expected_target = "/base/start",
            .status = "302 Found",
            .location = "../middle",
            .body = "abc",
        },
        .{
            .expected_target = "/middle",
            .status = "302 Found",
            .location = absolute_location,
            .body = "de",
        },
    };
    const final_script = [_]TestHttpScriptResponse{.{
        .expected_target = "/final",
        .status = "200 OK",
        .body = "final\n",
    }};
    var first_control = TestHttpScriptControl{};
    var final_control = TestHttpScriptControl{};
    const final_thread = try std.Thread.spawn(
        .{},
        serveTestHttpScript,
        .{ &final_server, &final_script, &final_control },
    );
    var final_joined = false;
    defer if (!final_joined) {
        stopAndJoinTestHttpScript(&final_control, final_thread);
    };
    const first_thread = try std.Thread.spawn(
        .{},
        serveTestHttpScript,
        .{ &first_server, &first_script, &first_control },
    );
    var first_joined = false;
    defer if (!first_joined) {
        stopAndJoinTestHttpScript(&first_control, first_thread);
    };

    var url_storage: [160]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_storage,
        "http://127.0.0.1:{d}/base/start",
        .{first_server.listen_address.getPort()},
    );
    const expected_total = "abc".len + "de".len + "final\n".len;
    const result = try fetchConfigWithOptions(allocator, url, .{
        .body_bytes_max = expected_total,
        .deadline_ms = 1_000,
        .allow_curl_fallback = false,
    });
    defer allocator.free(result.body);

    stopAndJoinTestHttpScript(&first_control, first_thread);
    first_joined = true;
    stopAndJoinTestHttpScript(&final_control, final_thread);
    final_joined = true;
    try std.testing.expect(!first_control.failed.load(.acquire));
    try std.testing.expect(!final_control.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), first_control.hits.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), final_control.hits.load(.acquire));
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expectEqualStrings("final\n", result.body);
    try std.testing.expectEqual(expected_total, result.total_source_bytes_consumed);
}

test "oversized redirect body exhausts the cap before requesting its target" {
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    try compat.setNonBlock(server.inner.socket.handle);

    const oversized_body = [_]u8{'x'} ** 17;
    const script = [_]TestHttpScriptResponse{
        .{
            .expected_target = "/start",
            .status = "302 Found",
            .location = "/final",
            .body = &oversized_body,
        },
        .{
            .expected_target = "/final",
            .status = "200 OK",
            .body = "must-not-run",
        },
    };
    var control = TestHttpScriptControl{};
    const thread = try std.Thread.spawn(
        .{},
        serveTestHttpScript,
        .{ &server, &script, &control },
    );
    var joined = false;
    defer if (!joined) stopAndJoinTestHttpScript(&control, thread);

    var url_storage: [160]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_storage,
        "http://127.0.0.1:{d}/start",
        .{server.listen_address.getPort()},
    );
    var failure_accounting = FetchFailureAccounting{};
    try std.testing.expectError(
        error.ConfigTooLarge,
        fetchConfigWithOptions(std.testing.allocator, url, .{
            .body_bytes_max = 16,
            .deadline_ms = 1_000,
            .allow_curl_fallback = false,
            .failure_accounting = &failure_accounting,
        }),
    );

    stopAndJoinTestHttpScript(&control, thread);
    joined = true;
    try std.testing.expect(!control.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), control.hits.load(.acquire));
    try std.testing.expectEqual(@as(usize, 16), failure_accounting.source_bytes_consumed);
    try std.testing.expect(!failure_accounting.exact);
}

test "std HTTP redirect limit accounts the fourth redirect body and stops" {
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    try compat.setNonBlock(server.inner.socket.handle);

    const script = [_]TestHttpScriptResponse{
        .{ .expected_target = "/r0", .status = "302 Found", .location = "/r1", .body = "a" },
        .{ .expected_target = "/r1", .status = "302 Found", .location = "/r2", .body = "bb" },
        .{ .expected_target = "/r2", .status = "302 Found", .location = "/r3", .body = "ccc" },
        .{ .expected_target = "/r3", .status = "302 Found", .location = "/r4", .body = "dddd" },
        .{ .expected_target = "/r4", .status = "200 OK", .body = "must-not-run" },
    };
    var control = TestHttpScriptControl{};
    const thread = try std.Thread.spawn(
        .{},
        serveTestHttpScript,
        .{ &server, &script, &control },
    );
    var joined = false;
    defer if (!joined) stopAndJoinTestHttpScript(&control, thread);

    var url_storage: [160]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_storage,
        "http://127.0.0.1:{d}/r0",
        .{server.listen_address.getPort()},
    );
    var failure_accounting = FetchFailureAccounting{};
    try std.testing.expectError(
        error.TooManyHttpRedirects,
        fetchConfigWithOptions(std.testing.allocator, url, .{
            .body_bytes_max = 64,
            .deadline_ms = 1_000,
            .allow_curl_fallback = false,
            .failure_accounting = &failure_accounting,
        }),
    );

    stopAndJoinTestHttpScript(&control, thread);
    joined = true;
    try std.testing.expect(!control.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 4), control.hits.load(.acquire));
    try std.testing.expectEqual(@as(usize, 10), failure_accounting.source_bytes_consumed);
    try std.testing.expect(failure_accounting.exact);
}

test "config redirect resolution preserves stable invalid and oversize errors" {
    const base = try std.Uri.parse("http://example.test/base/");

    var invalid_storage: [config_http_redirect_storage_bytes_max]u8 = undefined;
    const invalid_location = "http://exa mple.test/final";
    @memcpy(invalid_storage[0..invalid_location.len], invalid_location);
    try std.testing.expectError(
        error.HttpRedirectLocationInvalid,
        resolveConfigHttpRedirect(
            base,
            invalid_location.len,
            &invalid_storage,
        ),
    );

    var oversize_storage: [config_http_redirect_storage_bytes_max]u8 = undefined;
    const oversize_location_len = oversize_storage.len - 1;
    @memset(oversize_storage[0..oversize_location_len], 'a');
    try std.testing.expectError(
        error.HttpRedirectLocationOversize,
        resolveConfigHttpRedirect(
            base,
            oversize_location_len,
            &oversize_storage,
        ),
    );
}

fn redirectAllocationFixture(allocator: std.mem.Allocator) !void {
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    try compat.setNonBlock(server.inner.socket.handle);

    const script = [_]TestHttpScriptResponse{
        .{
            .expected_target = "/start",
            .status = "302 Found",
            .location = "/final",
            .body = "old",
        },
        .{
            .expected_target = "/final",
            .status = "200 OK",
            .body = "fresh",
        },
    };
    var control = TestHttpScriptControl{};
    const thread = try std.Thread.spawn(
        .{},
        serveTestHttpScript,
        .{ &server, &script, &control },
    );
    var joined = false;
    defer if (!joined) stopAndJoinTestHttpScript(&control, thread);

    var url_storage: [160]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_storage,
        "http://127.0.0.1:{d}/start",
        .{server.listen_address.getPort()},
    );
    var accounting = FetchAttemptAccounting{};
    const result = try fetchConfigWithStdHttp(
        allocator,
        url,
        .{
            .body_bytes_max = 16,
            .deadline_ms = 1_000,
            .allow_curl_fallback = false,
        },
        &accounting,
    );
    defer allocator.free(result.body);

    stopAndJoinTestHttpScript(&control, thread);
    joined = true;
    try std.testing.expect(!control.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), control.hits.load(.acquire));
    try std.testing.expectEqualStrings("fresh", result.body);
    try std.testing.expectEqual(@as(usize, 8), result.total_source_bytes_consumed);
    try std.testing.expectEqual(@as(usize, 8), accounting.source_bytes_consumed);
    try std.testing.expect(accounting.exact);
}

test "std HTTP redirect cleanup survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        redirectAllocationFixture,
        .{},
    );
}

const TestRuleProviderFetcher = struct {
    transports: TestFetchTransports,

    fn fetch(
        self: *@This(),
        allocator: std.mem.Allocator,
        url: []const u8,
        options: FetchConfigOptions,
    ) !DownloadResult {
        return fetchConfigHTTPUsing(
            TestFetchTransports,
            &self.transports,
            allocator,
            url,
            options,
            true,
        );
    }
};

const TestCanceledRuleProviderFetcher = struct {
    calls: usize = 0,
    advertised_body_bytes_max: usize = 0,
    reported_source_bytes: usize,
    accounting_exact: bool,

    fn fetch(
        self: *@This(),
        _: std.mem.Allocator,
        _: []const u8,
        options: FetchConfigOptions,
    ) !DownloadResult {
        self.calls += 1;
        self.advertised_body_bytes_max = options.body_bytes_max;
        options.failure_accounting.?.* = .{
            .source_bytes_consumed = self.reported_source_bytes,
            .exact = self.accounting_exact,
        };
        return error.Canceled;
    }
};

test "provider cancellation remains authoritative after accounting and preserves stale cache" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const stale_path = try testTmpPathAlloc(allocator, &tmp, "stale.txt");
    defer allocator.free(stale_path);
    const preserved = "cached.example\n";
    {
        const stale = try tmp.dir.createFile(compat.io(), "stale.txt", .{});
        defer stale.close(compat.io());
        try compat.fileWriteAll(stale, preserved);
    }

    var provider = testRuleProvider(.domain);
    provider.name = "canceled";
    provider.path = stale_path;
    var fetcher = TestCanceledRuleProviderFetcher{
        .reported_source_bytes = 2,
        .accounting_exact = false,
    };
    var budget = RuleProviderSyncBudget.init(
        testRuleProviderSyncLimits(16, 4, 128),
    );
    try budget.source.consume(3);

    try std.testing.expectError(
        error.Canceled,
        downloadRuleProviderFileUsing(
            TestCanceledRuleProviderFetcher,
            &fetcher,
            allocator,
            &provider,
            "https://provider.invalid/stale.txt",
            stale_path,
            false,
            &budget,
        ),
    );

    // Unknown failed-attempt consumption conservatively spends the complete
    // advertised remainder before cancellation is returned. No stale-cache
    // validation or publication is allowed to run after that control signal.
    try std.testing.expectEqual(@as(usize, 1), fetcher.calls);
    try std.testing.expectEqual(@as(usize, 13), fetcher.advertised_body_bytes_max);
    try std.testing.expectEqual(@as(usize, 16), budget.source.consumed);
    try std.testing.expectEqual(@as(usize, 0), budget.entries.aggregate_entry_count);
    try std.testing.expectEqual(@as(usize, 0), budget.entries.aggregate_bytes);
    const after = try tmp.dir.readFileAlloc(
        compat.io(),
        "stale.txt",
        allocator,
        .limited(64),
    );
    defer allocator.free(after);
    try std.testing.expectEqualStrings(preserved, after);
}

test "provider missing and stale downloads keep curl fallback inside one source budget" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing_path = try testTmpPathAlloc(allocator, &tmp, "missing.txt");
    defer allocator.free(missing_path);
    const stale_path = try testTmpPathAlloc(allocator, &tmp, "stale.txt");
    defer allocator.free(stale_path);
    {
        const stale = try tmp.dir.createFile(compat.io(), "stale.txt", .{});
        defer stale.close(compat.io());
        try compat.fileWriteAll(stale, "preserved.example\n");
    }

    var provider = testRuleProvider(.domain);
    provider.name = "fallback";
    provider.path = missing_path;
    const missing_body = "missing-fresh.example\n";
    var missing_fetcher = TestRuleProviderFetcher{ .transports = .{
        .primary = testFetchFailure(error.ConnectionResetByPeer, 2, true),
        .fallback = testFetchResponse(.ok, missing_body),
    } };
    var missing_budget = RuleProviderSyncBudget.init(
        testRuleProviderSyncLimits(32, 4, 128),
    );
    try missing_budget.source.consume(3);
    try downloadRuleProviderFileUsing(
        TestRuleProviderFetcher,
        &missing_fetcher,
        allocator,
        &provider,
        "https://provider.invalid/missing.txt",
        missing_path,
        true,
        &missing_budget,
    );
    try std.testing.expectEqual(
        @as(usize, 3 + 2 + missing_body.len),
        missing_budget.source.consumed,
    );
    try std.testing.expectEqual(@as(usize, 29), missing_fetcher.transports.primary_limit);
    try std.testing.expectEqual(@as(usize, 27), missing_fetcher.transports.fallback_limit);
    const missing_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        "missing.txt",
        allocator,
        .limited(64),
    );
    defer allocator.free(missing_bytes);
    try std.testing.expectEqualStrings(missing_body, missing_bytes);

    provider.path = stale_path;
    const stale_body = "stale-fresh.example\n";
    var stale_fetcher = TestRuleProviderFetcher{ .transports = .{
        .primary = testFetchResponse(.bad_request, "bad"),
        .fallback = testFetchResponse(.ok, stale_body),
    } };
    var stale_budget = RuleProviderSyncBudget.init(
        testRuleProviderSyncLimits(32, 4, 128),
    );
    try downloadRuleProviderFileUsing(
        TestRuleProviderFetcher,
        &stale_fetcher,
        allocator,
        &provider,
        "https://provider.invalid/stale.txt",
        stale_path,
        false,
        &stale_budget,
    );
    // The final candidate is included in the transport total and is not
    // charged a second time during validation/publication.
    try std.testing.expectEqual(
        @as(usize, "bad".len + stale_body.len),
        stale_budget.source.consumed,
    );
    try std.testing.expectEqual(@as(usize, 32), stale_fetcher.transports.primary_limit);
    try std.testing.expectEqual(@as(usize, 29), stale_fetcher.transports.fallback_limit);
    const stale_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        "stale.txt",
        allocator,
        .limited(64),
    );
    defer allocator.free(stale_bytes);
    try std.testing.expectEqualStrings(stale_body, stale_bytes);
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

test "fetchConfig zero body budget fails before URL or network work" {
    try std.testing.expectError(
        error.ConfigTooLarge,
        fetchConfigWithOptions(
            std.testing.allocator,
            "not a valid URL",
            .{ .body_bytes_max = 0 },
        ),
    );
}

test "fetchConfig enforces the response body limit" {
    const allocator = std.testing.allocator;
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, struct {
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

test "fetchConfig accepts the exact response body limit" {
    const allocator = std.testing.allocator;
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    const body = [_]u8{'x'} ** 32;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(http_server: *compat.net.Server, response_body: []const u8) void {
            var connection = http_server.accept() catch return;
            defer connection.stream.close();
            var request_buffer: [1024]u8 = undefined;
            _ = connection.stream.read(&request_buffer) catch return;
            var response_buffer: [256]u8 = undefined;
            const response = std.fmt.bufPrint(
                &response_buffer,
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ response_body.len, response_body },
            ) catch return;
            connection.stream.writeAll(response) catch return;
        }
    }.run, .{ &server, &body });
    defer thread.join();
    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/exact.yaml",
        .{server.listen_address.getPort()},
    );
    defer allocator.free(url);
    const result = try fetchConfigWithOptions(allocator, url, .{
        .body_bytes_max = body.len,
        .deadline_ms = 1_000,
    });
    defer allocator.free(result.body);
    try std.testing.expectEqualSlices(u8, &body, result.body);
    try std.testing.expectEqual(
        body.len,
        result.total_source_bytes_consumed,
    );
}

test "fetchConfig enforces the total deadline" {
    const allocator = std.testing.allocator;
    var server = try (try compat.net.Address.parseIp4(
        "127.0.0.1",
        0,
    )).listen(.{ .reuse_address = true });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, struct {
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
    try std.testing.expectEqual(
        result.body.len,
        result.total_source_bytes_consumed,
    );
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

test "config replacement snapshot rejects an oversized existing source" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(compat.io(), "oversized.yaml", .{});
    try compat.fileSeekTo(file, config_source_bytes_max);
    try compat.fileWriteAll(file, "x");
    file.close(compat.io());

    try std.testing.expectError(
        error.ConfigTooLarge,
        readConfigFileIfPresent(allocator, tmp.dir, "oversized.yaml"),
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

test "inferConfigKeyFromPath rejects nested config descendants" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "configs/assets");
    const file = try tmp.dir.createFile(compat.io(), "configs/assets/home.yaml", .{});
    file.close(compat.io());
    const cwd = try std.process.currentPathAlloc(compat.io(), allocator);
    defer allocator.free(cwd);
    const root = try compat.fs.path.join(
        allocator,
        &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] },
    );
    defer allocator.free(root);
    const configs_path = try compat.fs.path.join(allocator, &.{ root, "configs" });
    defer allocator.free(configs_path);
    const nested_path = try compat.fs.path.join(
        allocator,
        &.{ configs_path, "assets", "home.yaml" },
    );
    defer allocator.free(nested_path);
    try std.testing.expect(
        try inferConfigKeyFromPathWithConfigsDir(
            allocator,
            nested_path,
            configs_path,
        ) == null,
    );
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
