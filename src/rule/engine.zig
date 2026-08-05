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

/// 端口范围
const PortRange = struct {
    start: u16,
    end: u16,

    fn contains(self: PortRange, port: u16) bool {
        return port >= self.start and port <= self.end;
    }
};

/// RuleEngine matches requests against rules and returns the target proxy
pub const Engine = struct {
    allocator: std.mem.Allocator,
    rules: *const std.ArrayList(Rule),
    dns_client: ?dns.DnsClient,

    ip_cidrs: std.ArrayList(IpCidr),
    ip_cidr6s: std.ArrayList(IpCidr6),
    src_ip_cidrs: std.ArrayList(IpCidr),
    dst_port_ranges: std.ArrayList(PortRange),
    src_port_ranges: std.ArrayList(PortRange),

    pub fn init(allocator: std.mem.Allocator, rules: *const std.ArrayList(Rule)) !Engine {
        return initWithDns(allocator, rules, .{});
    }

    pub fn initWithDns(allocator: std.mem.Allocator, rules: *const std.ArrayList(Rule), dns_config: ?dns.DnsConfig) !Engine {
        var engine = Engine{
            .allocator = allocator,
            .rules = rules,
            .dns_client = if (dns_config) |cfg| dns.DnsClient.init(allocator, cfg) else null,
            .ip_cidrs = std.ArrayList(IpCidr).empty,
            .ip_cidr6s = std.ArrayList(IpCidr6).empty,
            .src_ip_cidrs = std.ArrayList(IpCidr).empty,
            .dst_port_ranges = std.ArrayList(PortRange).empty,
            .src_port_ranges = std.ArrayList(PortRange).empty,
        };
        errdefer engine.deinit();

        // Preprocess rules for fast matching
        for (rules.items) |rule| {
            switch (rule.rule_type) {
                .domain, .domain_suffix, .domain_keyword => {},
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
                .geoip => {},
                .rule_set => {},
                .dst_port => {
                    const range = try parsePortRange(rule.payload);
                    try engine.dst_port_ranges.append(allocator, range);
                },
                .src_port => {
                    const range = try parsePortRange(rule.payload);
                    try engine.src_port_ranges.append(allocator, range);
                },
                .process_name => {},
                .final => {},
            }
        }

        return engine;
    }

    pub fn deinit(self: *Engine) void {
        if (self.dns_client) |*client| {
            client.deinit();
        }
        self.ip_cidrs.deinit(self.allocator);
        self.ip_cidr6s.deinit(self.allocator);
        self.src_ip_cidrs.deinit(self.allocator);
        self.dst_port_ranges.deinit(self.allocator);
        self.src_port_ranges.deinit(self.allocator);
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
        var ip_cidr_index: usize = 0;
        var ip_cidr6_index: usize = 0;
        var src_ip_cidr_index: usize = 0;
        var dst_port_index: usize = 0;
        var src_port_index: usize = 0;

        var source_ipv4_parsed = false;
        var source_ipv4: ?u32 = null;
        var target_ipv4_parsed = false;
        var target_ipv4: ?u32 = null;
        var target_ipv6_parsed = false;
        var target_ipv6: ?[16]u8 = null;
        var resolution_attempted = false;
        var resolved_addresses: ?[]compat.net.Address = null;
        defer if (resolved_addresses) |addresses| self.allocator.free(addresses);

        if (ctx.is_domain) {
            parseTargetIpv4Once(
                ctx.target_host,
                &target_ipv4_parsed,
                &target_ipv4,
            );
            parseTargetIpv6Once(
                ctx.target_host,
                &target_ipv6_parsed,
                &target_ipv6,
            );
        }
        const target_is_domain = ctx.is_domain and
            target_ipv4 == null and target_ipv6 == null;

        for (self.rules.items) |rule| {
            switch (rule.rule_type) {
                .process_name => {
                    if (ctx.process_name) |process_name| {
                        if (std.mem.eql(u8, process_name, rule.payload)) {
                            return rule.target;
                        }
                    }
                },
                .src_ip_cidr => {
                    std.debug.assert(src_ip_cidr_index < self.src_ip_cidrs.items.len);
                    const cidr = self.src_ip_cidrs.items[src_ip_cidr_index];
                    src_ip_cidr_index += 1;
                    if (!source_ipv4_parsed) {
                        source_ipv4_parsed = true;
                        if (ctx.source_ip) |source_ip| {
                            if (compat.net.Address.parseIp4(source_ip, 0)) |address| {
                                source_ipv4 = address.in.sa.addr;
                            } else |_| {}
                        }
                    }
                    if (source_ipv4) |ip| {
                        if (cidr.contains(ip)) return rule.target;
                    }
                },
                .src_port => {
                    std.debug.assert(src_port_index < self.src_port_ranges.items.len);
                    const range = self.src_port_ranges.items[src_port_index];
                    src_port_index += 1;
                    if (ctx.source_port) |port| {
                        if (range.contains(port)) return rule.target;
                    }
                },
                .dst_port => {
                    std.debug.assert(dst_port_index < self.dst_port_ranges.items.len);
                    const range = self.dst_port_ranges.items[dst_port_index];
                    dst_port_index += 1;
                    if (ctx.target_port != 0 and range.contains(ctx.target_port)) {
                        return rule.target;
                    }
                },
                .domain => {
                    if (target_is_domain and
                        domainsEqual(ctx.target_host, rule.payload))
                    {
                        return rule.target;
                    }
                },
                .domain_suffix => {
                    if (target_is_domain and
                        domainMatchesSuffix(ctx.target_host, rule.payload))
                    {
                        return rule.target;
                    }
                },
                .domain_keyword => {
                    if (target_is_domain and
                        domainContainsKeyword(ctx.target_host, rule.payload))
                    {
                        return rule.target;
                    }
                },
                .geoip => {
                    if (target_is_domain) {
                        if (rule.no_resolve) continue;
                        resolveTargetOnce(
                            self,
                            ctx.target_host,
                            &resolution_attempted,
                            &resolved_addresses,
                        );
                        if (resolved_addresses) |addresses| {
                            for (addresses) |address| {
                                if (address != .in) continue;
                                const country = self.matchGeoIp(address.in.sa.addr) orelse
                                    continue;
                                if (std.mem.eql(u8, country, rule.payload)) {
                                    return rule.target;
                                }
                            }
                        }
                    } else {
                        parseTargetIpv4Once(
                            ctx.target_host,
                            &target_ipv4_parsed,
                            &target_ipv4,
                        );
                        if (target_ipv4) |ip| {
                            const country = self.matchGeoIp(ip) orelse continue;
                            if (std.mem.eql(u8, country, rule.payload)) {
                                return rule.target;
                            }
                        }
                    }
                },
                .ip_cidr => {
                    std.debug.assert(ip_cidr_index < self.ip_cidrs.items.len);
                    const cidr = self.ip_cidrs.items[ip_cidr_index];
                    ip_cidr_index += 1;
                    if (target_is_domain) {
                        if (rule.no_resolve) continue;
                        resolveTargetOnce(
                            self,
                            ctx.target_host,
                            &resolution_attempted,
                            &resolved_addresses,
                        );
                        if (resolved_addresses) |addresses| {
                            for (addresses) |address| {
                                if (address == .in and cidr.contains(address.in.sa.addr)) {
                                    return rule.target;
                                }
                            }
                        }
                    } else {
                        parseTargetIpv4Once(
                            ctx.target_host,
                            &target_ipv4_parsed,
                            &target_ipv4,
                        );
                        if (target_ipv4) |ip| {
                            if (cidr.contains(ip)) return rule.target;
                        }
                    }
                },
                .ip_cidr6 => {
                    std.debug.assert(ip_cidr6_index < self.ip_cidr6s.items.len);
                    const cidr = self.ip_cidr6s.items[ip_cidr6_index];
                    ip_cidr6_index += 1;
                    if (target_is_domain) {
                        if (rule.no_resolve) continue;
                        resolveTargetOnce(
                            self,
                            ctx.target_host,
                            &resolution_attempted,
                            &resolved_addresses,
                        );
                        if (resolved_addresses) |addresses| {
                            for (addresses) |address| {
                                if (address != .in6) continue;
                                var ip: [16]u8 = undefined;
                                @memcpy(&ip, &address.in6.sa.addr);
                                if (cidr.contains(ip)) return rule.target;
                            }
                        }
                    } else {
                        parseTargetIpv6Once(
                            ctx.target_host,
                            &target_ipv6_parsed,
                            &target_ipv6,
                        );
                        if (target_ipv6) |ip| {
                            if (cidr.contains(ip)) return rule.target;
                        }
                    }
                },
                .final => return rule.target,
                .rule_set => {},
            }
        }
        return null;
    }

    fn resolveTargetOnce(
        self: *Engine,
        host: []const u8,
        attempted: *bool,
        addresses: *?[]compat.net.Address,
    ) void {
        if (attempted.*) return;
        attempted.* = true;
        if (self.dns_client) |*client| {
            addresses.* = client.resolve(host) catch null;
        }
    }

    fn parseTargetIpv4Once(
        host: []const u8,
        attempted: *bool,
        result: *?u32,
    ) void {
        if (attempted.*) return;
        attempted.* = true;
        if (compat.net.Address.parseIp4(host, 0)) |address| {
            result.* = address.in.sa.addr;
        } else |_| {}
    }

    fn parseTargetIpv6Once(
        host: []const u8,
        attempted: *bool,
        result: *?[16]u8,
    ) void {
        if (attempted.*) return;
        attempted.* = true;
        if (compat.net.Address.parseIp6(host, 0)) |address| {
            var ip: [16]u8 = undefined;
            @memcpy(&ip, &address.in6.sa.addr);
            result.* = ip;
        } else |_| {}
    }

    fn canonicalDomain(domain: []const u8) []const u8 {
        if (domain.len > 0 and domain[domain.len - 1] == '.') {
            return domain[0 .. domain.len - 1];
        }
        return domain;
    }

    fn domainsEqual(left_raw: []const u8, right_raw: []const u8) bool {
        return std.ascii.eqlIgnoreCase(
            canonicalDomain(left_raw),
            canonicalDomain(right_raw),
        );
    }

    fn domainMatchesSuffix(domain_raw: []const u8, suffix_raw: []const u8) bool {
        const domain = canonicalDomain(domain_raw);
        const suffix = canonicalDomain(suffix_raw);
        if (std.ascii.eqlIgnoreCase(domain, suffix)) return true;
        if (domain.len <= suffix.len) return false;
        const start = domain.len - suffix.len;
        return domain[start - 1] == '.' and
            std.ascii.eqlIgnoreCase(domain[start..], suffix);
    }

    fn domainContainsKeyword(domain_raw: []const u8, keyword_raw: []const u8) bool {
        const domain = canonicalDomain(domain_raw);
        const keyword = canonicalDomain(keyword_raw);
        if (keyword.len == 0 or keyword.len > domain.len) return false;
        for (0..domain.len - keyword.len + 1) |start| {
            if (std.ascii.eqlIgnoreCase(
                domain[start .. start + keyword.len],
                keyword,
            )) return true;
        }
        return false;
    }

    fn matchGeoIp(self: *Engine, network_order_ip: u32) ?[]const u8 {
        _ = self;
        return geoip.SimpleGeoIp.lookup(
            std.mem.bigToNative(u32, network_order_ip),
        );
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

    // `ip` is in network byte order (big-endian). Build the host-bit mask in
    // logical (big-endian) order, then convert to the native representation so
    // that masking `ip & mask` operates on the correct (high-order) bits.
    const host_order_mask: u32 = if (prefix_len == 0)
        0
    else if (prefix_len == 32)
        0xFFFFFFFF
    else
        @as(u32, 0xFFFFFFFF) << @intCast(32 - prefix_len);
    const mask: u32 = std.mem.nativeToBig(u32, host_order_mask);

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

fn parsePortRange(payload: []const u8) !PortRange {
    // 支持格式: "80", "80-443", "8080,8081" (取第一个)
    if (std.mem.indexOf(u8, payload, ",")) |comma| {
        return parsePortRange(payload[0..comma]);
    }

    if (std.mem.indexOf(u8, payload, "-")) |dash| {
        return .{
            .start = try std.fmt.parseInt(u16, payload[0..dash], 10),
            .end = try std.fmt.parseInt(u16, payload[dash + 1 ..], 10),
        };
    }

    const port = try std.fmt.parseInt(u16, payload, 10);
    return .{ .start = port, .end = port };
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

test "domain suffix rules preserve first-match order" {
    const allocator = std.testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer deinitTestRules(allocator, &rules);
    try appendTestRule(allocator, &rules, .domain_suffix, "example.com", "DIRECT");
    try appendTestRule(allocator, &rules, .domain_suffix, "b.example.com", "PROXY");
    try appendTestRule(allocator, &rules, .final, "", "DIRECT");

    var engine = try Engine.init(allocator, &rules);
    defer engine.deinit();

    try std.testing.expectEqualStrings("DIRECT", engine.match("a.b.example.com", true).?);
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
