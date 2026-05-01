const std = @import("std");
const compat = @import("../compat.zig");
const Rule = @import("../config.zig").Rule;
const RuleType = @import("../config.zig").RuleType;
const dns = @import("../dns.zig");
const geoip = @import("../geoip.zig");

const log = std.log.scoped(.rule_engine);

/// 规则匹配上下文
pub const MatchContext = struct {
    target_host: []const u8,
    target_port: u16 = 0,
    is_domain: bool = true,
    process_name: ?[]const u8 = null,
    source_ip: ?[]const u8 = null,
    source_port: ?u16 = null,
};

/// GeoIP 条目
const GeoIpEntry = struct {
    cidr: IpCidr,
    country_code: []const u8,
};

/// 端口范围
const PortRange = struct {
    start: u16,
    end: u16,
    target: []const u8,

    fn contains(self: PortRange, port: u16) bool {
        return port >= self.start and port <= self.end;
    }
};

/// RuleEngine matches requests against rules and returns the target proxy
pub const Engine = struct {
    allocator: std.mem.Allocator,
    rules: *const std.ArrayList(Rule),
    dns_client: ?dns.DnsClient,

    // Domain rules
    domain_set: std.StringHashMap(void),
    domain_suffix_set: std.StringHashMap(void),
    domain_keywords: std.ArrayList([]const u8),

    // IP rules
    ip_cidrs: std.ArrayList(IpCidr),
    ip_cidr6s: std.ArrayList(IpCidr6),
    src_ip_cidrs: std.ArrayList(IpCidr),
    geoip_entries: std.ArrayList(GeoIpEntry),
    geoip_enabled: bool,

    // Port rules
    dst_port_ranges: std.ArrayList(PortRange),
    src_port_ranges: std.ArrayList(PortRange),

    // Process rules
    process_names: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, rules: *const std.ArrayList(Rule)) !Engine {
        return try initWithDns(allocator, rules, null);
    }

    pub fn initWithDns(allocator: std.mem.Allocator, rules: *const std.ArrayList(Rule), dns_config: ?dns.DnsConfig) !Engine {
        var engine = Engine{
            .allocator = allocator,
            .rules = rules,
            .dns_client = if (dns_config) |cfg| dns.DnsClient.init(allocator, cfg) else null,
            .domain_set = std.StringHashMap(void).init(allocator),
            .domain_suffix_set = std.StringHashMap(void).init(allocator),
            .domain_keywords = std.ArrayList([]const u8).empty,
            .ip_cidrs = std.ArrayList(IpCidr).empty,
            .ip_cidr6s = std.ArrayList(IpCidr6).empty,
            .src_ip_cidrs = std.ArrayList(IpCidr).empty,
            .geoip_entries = std.ArrayList(GeoIpEntry).empty,
            .geoip_enabled = false,
            .dst_port_ranges = std.ArrayList(PortRange).empty,
            .src_port_ranges = std.ArrayList(PortRange).empty,
            .process_names = std.StringHashMap(void).init(allocator),
        };

        // Preprocess rules for fast matching
        for (rules.items) |rule| {
            switch (rule.rule_type) {
                .domain => {
                    try engine.domain_set.put(rule.payload, {});
                },
                .domain_suffix => {
                    try engine.addDomainSuffix(rule.payload);
                },
                .domain_keyword => {
                    try engine.domain_keywords.append(allocator, rule.payload);
                },
                .ip_cidr => {
                    const cidr = try parseCidr(rule.payload);
                    try engine.ip_cidrs.append(allocator, cidr);
                },
                .ip_cidr6 => {
                    const cidr6 = try parseCidr6(rule.payload);
                    try engine.ip_cidr6s.append(allocator, cidr6);
                },
                .src_ip_cidr => {
                    const cidr = try parseCidr(rule.payload);
                    try engine.src_ip_cidrs.append(allocator, cidr);
                },
                .geoip => {
                    // GeoIP 条目格式: GEOIP,CN,DIRECT
                    // payload 是国家代码，需要在运行时查询
                    engine.geoip_enabled = true;
                },
                .rule_set => {},
                .dst_port => {
                    const range = try parsePortRange(rule.payload, rule.target);
                    try engine.dst_port_ranges.append(allocator, range);
                },
                .src_port => {
                    const range = try parsePortRange(rule.payload, rule.target);
                    try engine.src_port_ranges.append(allocator, range);
                },
                .process_name => {
                    try engine.process_names.put(rule.payload, {});
                },
                .final => {},
            }
        }

        return engine;
    }

    pub fn deinit(self: *Engine) void {
        if (self.dns_client) |*client| {
            client.deinit();
        }
        self.domain_set.deinit();
        self.domain_suffix_set.deinit();
        self.domain_keywords.deinit(self.allocator);
        self.ip_cidrs.deinit(self.allocator);
        self.ip_cidr6s.deinit(self.allocator);
        self.src_ip_cidrs.deinit(self.allocator);
        self.geoip_entries.deinit(self.allocator);
        self.dst_port_ranges.deinit(self.allocator);
        self.src_port_ranges.deinit(self.allocator);
        self.process_names.deinit();
    }

    /// Match a request and return the target proxy name
    /// 简化版 match，兼容旧代码 (host, is_domain)
    pub fn match(self: *Engine, host: []const u8, is_domain: bool) ?[]const u8 {
        return self.matchCtx(.{
            .target_host = host,
            .is_domain = is_domain,
        });
    }

    pub fn matchCtx(self: *Engine, ctx: MatchContext) ?[]const u8 {
        std.debug.print("[Engine] Matching: host={s}, port={d}, is_domain={}\n", .{ ctx.target_host, ctx.target_port, ctx.is_domain });
        std.debug.print("[Engine] DNS client present: {}\n", .{self.dns_client != null});

        // 1. PROCESS-NAME (最高优先级之一)
        if (ctx.process_name) |proc| {
            if (self.process_names.contains(proc)) {
                return self.findRuleTarget(.process_name, proc);
            }
        }

        // 2. SRC-IP-CIDR (如果提供了源 IP)
        if (ctx.source_ip) |src_ip| {
            if (self.matchSrcIpCidr(src_ip)) |target| {
                return target;
            }
        }

        // 3. SRC-PORT (如果提供了源端口)
        if (ctx.source_port) |src_port| {
            for (self.src_port_ranges.items) |range| {
                if (range.contains(src_port)) {
                    return range.target;
                }
            }
        }

        // 4. DST-PORT (目标端口)
        if (ctx.target_port > 0) {
            for (self.dst_port_ranges.items) |range| {
                if (range.contains(ctx.target_port)) {
                    return range.target;
                }
            }
        }

        // 5. DOMAIN rules (如果是域名)
        if (ctx.is_domain) {
            const host = ctx.target_host;

            std.debug.print("[Engine] Checking domain rules for {s}\n", .{host});
            std.debug.print("[Engine] domain_set count: {}\n", .{self.domain_set.count()});

            // 5.1 DOMAIN - 精确匹配
            if (self.domain_set.contains(host)) {
                std.debug.print("[Engine] Domain exact match: {s}\n", .{host});
                return self.findRuleTarget(.domain, host);
            }

            // 5.2 DOMAIN-SUFFIX - 后缀匹配
            if (self.matchDomainSuffix(host)) {
                std.debug.print("[Engine] Domain suffix match: {s}\n", .{host});
                const suffix = self.findMatchingSuffix(host) orelse host;
                return self.findRuleTarget(.domain_suffix, suffix);
            }

            // 5.3 DOMAIN-KEYWORD - 关键词匹配
            for (self.domain_keywords.items) |keyword| {
                if (std.mem.indexOf(u8, host, keyword) != null) {
                    std.debug.print("[Engine] Domain keyword match: {s}\n", .{keyword});
                    return self.findRuleTarget(.domain_keyword, keyword);
                }
            }

            // 5.4 GEOIP (需要 DNS 解析)
            // 检查是否有 no-resolve 标记的规则优先
            for (self.rules.items) |rule| {
                if (rule.rule_type == .geoip and !rule.no_resolve) {
                    // 需要解析后检查
                }
            }

            // 5.5 IP-CIDR (DNS 解析后检查，除非 no-resolve)
            if (self.dns_client) |*client| {
                std.debug.print("[Engine] DNS client available, resolving {s}\n", .{host});
                const addresses = client.resolve(host) catch {
                    // DNS 失败，继续检查 no-resolve 规则
                    std.debug.print("[Engine] DNS resolve failed\n", .{});
                    return self.matchNoResolveRules(ctx);
                };
                defer self.allocator.free(addresses);
                std.debug.print("[Engine] DNS resolved to {} addresses\n", .{addresses.len});

                for (addresses) |addr| {
                    // IPv4
                    if (addr == .in) {
                        const ip = addr.in.sa.addr;

                        std.debug.print("[Engine] IPv4: {}.{}.{}.{}\n", .{ (ip >> 0) & 0xFF, (ip >> 8) & 0xFF, (ip >> 16) & 0xFF, (ip >> 24) & 0xFF });

                        // GEOIP 检查
                        if (self.geoip_enabled) {
                            if (self.matchGeoIp(ip)) |country| {
                                std.debug.print("[Engine] GEOIP match: {s}\n", .{country});
                                if (self.findRuleTarget(.geoip, country)) |target| {
                                    return target;
                                }
                            }
                        }

                        // IP-CIDR 检查
                        for (self.ip_cidrs.items) |cidr| {
                            if (cidr.contains(ip)) {
                                return self.findRuleTarget(.ip_cidr, cidr.original);
                            }
                        }
                    }
                    // IPv6
                    else if (addr == .in6) {
                        var ip6: [16]u8 = undefined;
                        @memcpy(&ip6, &addr.in6.sa.addr);

                        // IP-CIDR6 检查
                        for (self.ip_cidr6s.items) |cidr6| {
                            if (cidr6.contains(ip6)) {
                                return self.findRuleTarget(.ip_cidr6, cidr6.original);
                            }
                        }

                        // TODO: IPv6 GEOIP (needs full GeoIP database support)
                        // For now, fallback to no match
                    }
                }
            } else {
                // 没有 DNS 客户端，只检查 no-resolve 规则
                const no_resolve_result = self.matchNoResolveRules(ctx);
                if (no_resolve_result) |target| {
                    return target;
                }
                // Fall through to MATCH rule
            }
        } else {
            // 6. 直接是 IP 地址
            if (compat.net.Address.parseIp4(ctx.target_host, 0)) |addr| {
                const ip = addr.in.sa.addr;

                // GEOIP
                if (self.geoip_enabled) {
                    if (self.matchGeoIp(ip)) |country| {
                        if (self.findRuleTarget(.geoip, country)) |target| {
                            return target;
                        }
                    }
                }

                // IP-CIDR
                for (self.ip_cidrs.items) |cidr| {
                    if (cidr.contains(ip)) {
                        return self.findRuleTarget(.ip_cidr, cidr.original);
                    }
                }
            } else |_| {
                // IPv6?
                if (compat.net.Address.parseIp6(ctx.target_host, 0)) |addr6| {
                    var ip6: [16]u8 = undefined;
                    @memcpy(&ip6, &addr6.in6.sa.addr);

                    // IP-CIDR6 检查
                    for (self.ip_cidr6s.items) |cidr6| {
                        if (cidr6.contains(ip6)) {
                            return self.findRuleTarget(.ip_cidr6, cidr6.original);
                        }
                    }

                    // TODO: IPv6 GEOIP (needs full GeoIP database support)
                } else |_| {}
            }
        }

        // Final rule (MATCH)
        std.debug.print("[Engine] Reached final rule, calling findRuleTarget\n", .{});
        return self.findRuleTarget(.final, "");
    }

    /// 只匹配标记了 no-resolve 的规则
    fn matchNoResolveRules(self: *Engine, ctx: MatchContext) ?[]const u8 {
        for (self.rules.items) |rule| {
            if (!rule.no_resolve) continue;

            switch (rule.rule_type) {
                .domain => {
                    if (std.mem.eql(u8, rule.payload, ctx.target_host)) {
                        return rule.target;
                    }
                },
                .domain_suffix => {
                    if (std.mem.endsWith(u8, ctx.target_host, rule.payload)) {
                        return rule.target;
                    }
                },
                .domain_keyword => {
                    if (std.mem.indexOf(u8, ctx.target_host, rule.payload) != null) {
                        return rule.target;
                    }
                },
                .geoip => {
                    // no-resolve 的 GEOIP 规则不匹配（因为没有 IP）
                },
                .rule_set => {},
                else => {},
            }
        }
        return null;
    }

    fn matchSrcIpCidr(self: *Engine, src_ip: []const u8) ?[]const u8 {
        if (compat.net.Address.parseIp4(src_ip, 0)) |addr| {
            const ip = addr.in.sa.addr;
            for (self.src_ip_cidrs.items) |cidr| {
                if (cidr.contains(ip)) {
                    return self.findRuleTarget(.src_ip_cidr, cidr.original);
                }
            }
        } else |_| {}
        return null;
    }

    fn matchGeoIp(self: *Engine, ip: u32) ?[]const u8 {
        _ = self;
        return geoip.SimpleGeoIp.lookup(ip);
    }

    fn findRuleTarget(self: *const Engine, rule_type: RuleType, payload: []const u8) ?[]const u8 {
        std.debug.print("[Engine] findRuleTarget: type={}, payload={s}\n", .{ rule_type, payload });
        for (self.rules.items) |rule| {
            if (rule.rule_type == rule_type) {
                if (rule_type == .final or std.mem.eql(u8, rule.payload, payload)) {
                    std.debug.print("[Engine] findRuleTarget found: {s}\n", .{rule.target});
                    return rule.target;
                }
            }
        }
        if (rule_type == .final) {
            std.debug.print("[Engine] findRuleTarget: searching for final rule again\n", .{});
            for (self.rules.items) |rule| {
                if (rule.rule_type == .final) {
                    std.debug.print("[Engine] findRuleTarget found final: {s}\n", .{rule.target});
                    return rule.target;
                }
            }
        }
        std.debug.print("[Engine] findRuleTarget: not found\n", .{});
        return null;
    }

    // ============ Domain Suffix Index ============

    fn addDomainSuffix(self: *Engine, suffix: []const u8) !void {
        try self.domain_suffix_set.put(suffix, {});
    }

    fn matchDomainSuffix(self: *const Engine, domain: []const u8) bool {
        return self.findMatchingSuffix(domain) != null;
    }

    fn findMatchingSuffix(self: *const Engine, domain: []const u8) ?[]const u8 {
        var start: usize = 0;
        while (start < domain.len) {
            const candidate = domain[start..];
            if (self.domain_suffix_set.contains(candidate)) return candidate;

            const dot = std.mem.indexOfScalar(u8, candidate, '.') orelse break;
            start += dot + 1;
        }
        return null;
    }
};

// ============ Data Structures ============

// IPv4 CIDR
const IpCidr = struct {
    prefix: u32,
    mask: u32,
    original: []const u8,

    fn contains(self: IpCidr, ip: u32) bool {
        return (ip & self.mask) == self.prefix;
    }
};

// IPv6 CIDR
const IpCidr6 = struct {
    prefix: [16]u8,
    prefix_len: u8,
    original: []const u8,

    fn contains(self: IpCidr6, ip: [16]u8) bool {
        const full_bytes = self.prefix_len / 8;
        const remaining_bits = self.prefix_len % 8;

        for (0..full_bytes) |i| {
            if (ip[i] != self.prefix[i]) return false;
        }

        if (remaining_bits > 0 and full_bytes < 16) {
            const mask: u8 = @as(u8, 0xFF) << @intCast(8 - remaining_bits);
            if ((ip[full_bytes] & mask) != (self.prefix[full_bytes] & mask)) return false;
        }

        return true;
    }
};

// ============ Parsing Functions ============

fn parseCidr(s: []const u8) !IpCidr {
    const slash_pos = std.mem.indexOf(u8, s, "/");
    if (slash_pos == null) return error.InvalidCidr;

    const ip_str = s[0..slash_pos.?];
    const prefix_len = try std.fmt.parseInt(u8, s[slash_pos.? + 1 ..], 10);

    const addr = try compat.net.Address.parseIp4(ip_str, 0);
    const ip = addr.in.sa.addr;

    if (prefix_len > 32) return error.InvalidPrefix;

    const mask: u32 = if (prefix_len == 0) 0 else if (prefix_len == 32) 0xFFFFFFFF else ~(@as(u32, 0) >> @intCast(prefix_len));

    return IpCidr{
        .prefix = ip & mask,
        .mask = mask,
        .original = s,
    };
}

fn parseCidr6(s: []const u8) !IpCidr6 {
    const slash_pos = std.mem.indexOf(u8, s, "/");
    if (slash_pos == null) return error.InvalidCidr;

    const ip_str = s[0..slash_pos.?];
    const prefix_len = try std.fmt.parseInt(u8, s[slash_pos.? + 1 ..], 10);

    if (prefix_len > 128) return error.InvalidPrefix;

    const addr = try compat.net.Address.parseIp6(ip_str, 0);

    var prefix: [16]u8 = undefined;
    @memcpy(&prefix, &addr.in6.sa.addr);

    // Apply mask to prefix
    const full_bytes = prefix_len / 8;
    const remaining_bits = prefix_len % 8;

    if (remaining_bits > 0 and full_bytes < 16) {
        const mask: u8 = @as(u8, 0xFF) << @intCast(8 - remaining_bits);
        prefix[full_bytes] &= mask;
    }

    const clear_start = if (remaining_bits > 0) full_bytes + 1 else full_bytes;
    if (clear_start < 16) {
        for (clear_start..16) |i| {
            prefix[i] = 0;
        }
    }

    return IpCidr6{
        .prefix = prefix,
        .prefix_len = prefix_len,
        .original = s,
    };
}

fn parsePortRange(payload: []const u8, target: []const u8) !PortRange {
    // 支持格式: "80", "80-443", "8080,8081" (取第一个)
    if (std.mem.indexOf(u8, payload, ",")) |comma| {
        // 多端口，取第一个
        const first = payload[0..comma];
        return try parsePortRange(first, target);
    }

    if (std.mem.indexOf(u8, payload, "-")) |dash| {
        // 范围
        const start = try std.fmt.parseInt(u16, payload[0..dash], 10);
        const end = try std.fmt.parseInt(u16, payload[dash + 1 ..], 10);
        return PortRange{
            .start = start,
            .end = end,
            .target = target,
        };
    }

    // 单个端口
    const port = try std.fmt.parseInt(u16, payload, 10);
    return PortRange{
        .start = port,
        .end = port,
        .target = target,
    };
}

fn appendTestRule(
    allocator: std.mem.Allocator,
    rules: *std.ArrayList(Rule),
    rule_type: RuleType,
    payload: []const u8,
    target: []const u8,
) !void {
    try rules.append(allocator, .{
        .rule_type = rule_type,
        .payload = try allocator.dupe(u8, payload),
        .target = try allocator.dupe(u8, target),
    });
}

fn deinitTestRules(allocator: std.mem.Allocator, rules: *std.ArrayList(Rule)) void {
    for (rules.items) |*rule| rule.deinit(allocator);
    rules.deinit(allocator);
}

test "domain suffix index stores one hash entry per suffix rule" {
    const allocator = std.testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer deinitTestRules(allocator, &rules);
    try appendTestRule(allocator, &rules, .domain_suffix, "example.com", "DIRECT");
    try appendTestRule(allocator, &rules, .domain_suffix, "b.example.com", "PROXY");
    try appendTestRule(allocator, &rules, .final, "", "DIRECT");

    var engine = try Engine.init(allocator, &rules);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 2), engine.domain_suffix_set.count());
    try std.testing.expect(engine.matchDomainSuffix("a.b.example.com"));
    try std.testing.expectEqualStrings("b.example.com", engine.findMatchingSuffix("a.b.example.com").?);
}

test "domain suffix matching honors label boundaries" {
    const allocator = std.testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer deinitTestRules(allocator, &rules);
    try appendTestRule(allocator, &rules, .domain_suffix, "example.com", "DIRECT");
    try appendTestRule(allocator, &rules, .final, "", "PROXY");

    var engine = try Engine.init(allocator, &rules);
    defer engine.deinit();

    try std.testing.expectEqualStrings("DIRECT", engine.match("www.example.com", true).?);
    try std.testing.expectEqualStrings("DIRECT", engine.match("example.com", true).?);
    try std.testing.expectEqualStrings("PROXY", engine.match("badexample.com", true).?);
}

// ============ Simplified Match Interface ============
