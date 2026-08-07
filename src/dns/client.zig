const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const protocol = @import("protocol.zig");

/// DNS 客户端配置
pub const DnsConfig = struct {
    /// 主 DNS 服务器（IPv4 literal）；null 使用系统 resolver。
    primary: ?[]const u8 = null,
    /// 备用 DNS 服务器（IPv4 literal）
    secondary: ?[]const u8 = null,
    /// DNS 端口
    port: u16 = 53,
    /// 超时时间（毫秒）
    timeout_ms: u32 = 5000,
    /// 是否使用 TCP
    use_tcp: bool = false,
    /// 是否启用缓存
    enable_cache: bool = true,
    /// 缓存 TTL（秒）
    cache_ttl: u32 = 300,
    /// 是否启用 DoH
    doh_enabled: bool = false,
    /// DoH URL
    doh_url: ?[]const u8 = null,
    /// 是否启用 DoT
    dot_enabled: bool = false,
    /// DoT 服务器
    dot_server: ?[]const u8 = null,
};

/// DNS 缓存条目
const max_cache_entries: usize = 256;

const CacheEntry = struct {
    addresses: std.ArrayList(net.Address),
    expires_at: i64,
};

/// DNS 客户端
pub const DnsClient = struct {
    allocator: std.mem.Allocator,
    config: DnsConfig,
    cache: std.StringHashMap(CacheEntry),
    cache_mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: DnsConfig) DnsClient {
        return .{
            .allocator = allocator,
            .config = config,
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .cache_mutex = .init,
        };
    }

    pub fn deinit(self: *DnsClient) void {
        self.clearCacheLocked();
        self.cache.deinit();
    }

    fn clearCacheLocked(self: *DnsClient) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.addresses.deinit(self.allocator);
        }
        self.cache.clearRetainingCapacity();
    }

    fn removeCacheEntryLocked(self: *DnsClient, domain: []const u8) void {
        if (self.cache.fetchRemove(domain)) |removed| {
            self.allocator.free(removed.key);
            var entry = removed.value;
            entry.addresses.deinit(self.allocator);
        }
    }

    /// 解析域名
    pub fn resolve(self: *DnsClient, domain: []const u8) ![]net.Address {
        // Check cache
        if (self.config.enable_cache) {
            self.cache_mutex.lockUncancelable(compat.io());
            defer self.cache_mutex.unlock(compat.io());

            if (self.cache.get(domain)) |entry| {
                const now = compat.timestamp();
                if (entry.expires_at > now) {
                    const result = try self.allocator.alloc(
                        net.Address,
                        entry.addresses.items.len,
                    );
                    @memcpy(result, entry.addresses.items);
                    return result;
                }
                self.removeCacheEntryLocked(domain);
            }
        }

        // Query DNS
        const addresses = try self.queryDns(domain);
        errdefer self.allocator.free(addresses);

        // Add to cache. Another worker may have filled the same key while the
        // network query was in flight; never replace an owned entry blindly.
        if (self.config.enable_cache) {
            self.cache_mutex.lockUncancelable(compat.io());
            defer self.cache_mutex.unlock(compat.io());

            const now = compat.timestamp();
            if (self.cache.get(domain)) |entry| {
                if (entry.expires_at > now) return addresses;
                self.removeCacheEntryLocked(domain);
            }
            if (self.cache.count() >= max_cache_entries) {
                self.clearCacheLocked();
            }

            const key = try self.allocator.dupe(u8, domain);
            errdefer self.allocator.free(key);
            var entry = CacheEntry{
                .addresses = std.ArrayList(net.Address).empty,
                .expires_at = now + self.config.cache_ttl,
            };
            errdefer entry.addresses.deinit(self.allocator);
            try entry.addresses.appendSlice(self.allocator, addresses);
            try self.cache.putNoClobber(key, entry);
        }

        return addresses;
    }

    /// 查询 DNS 服务器
    fn queryDns(self: *DnsClient, domain: []const u8) ![]net.Address {
        if (self.config.primary == null) {
            var system_addresses = try net.getAddressList(
                self.allocator,
                domain,
                0,
            );
            errdefer system_addresses.deinit();
            if (system_addresses.addrs.len == 0) return error.NoAddresses;
            return system_addresses.addrs;
        }

        var addresses = std.ArrayList(net.Address).empty;
        defer addresses.deinit(self.allocator);
        var first_error: ?anyerror = null;
        const deadline_ms = compat.monotonicMilliTimestamp() +
            self.config.timeout_ms;

        for ([_]protocol.QueryType{ .a, .aaaa }) |query_type| {
            const batch = self.queryType(domain, query_type, deadline_ms) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            addresses.appendSlice(self.allocator, batch) catch |err| {
                self.allocator.free(batch);
                return err;
            };
            self.allocator.free(batch);
        }
        if (addresses.items.len == 0) return first_error orelse error.NoAddresses;
        return addresses.toOwnedSlice(self.allocator);
    }

    fn queryType(
        self: *DnsClient,
        domain: []const u8,
        query_type: protocol.QueryType,
        deadline_ms: i64,
    ) ![]net.Address {
        return self.queryServer(
            self.config.primary.?,
            domain,
            query_type,
            deadline_ms,
        ) catch |err| {
            std.debug.print("Primary DNS query failed: {}\n", .{err});
            if (self.config.secondary) |secondary| {
                return self.queryServer(
                    secondary,
                    domain,
                    query_type,
                    deadline_ms,
                );
            }
            return err;
        };
    }

    fn queryServer(
        self: *DnsClient,
        server: []const u8,
        domain: []const u8,
        query_type: protocol.QueryType,
        deadline_ms: i64,
    ) ![]net.Address {
        if (self.config.use_tcp) {
            return self.queryTcp(server, domain, query_type, deadline_ms);
        }
        return self.queryUdp(server, domain, query_type, deadline_ms);
    }

    fn remainingTimeoutMs(deadline_ms: i64) !u32 {
        const remaining = deadline_ms - compat.monotonicMilliTimestamp();
        if (remaining <= 0) return error.Timeout;
        return @intCast(@min(remaining, std.math.maxInt(u32)));
    }

    /// 读取确切数量的字节（处理短读取）
    fn setSocketTimeout(
        sock: std.posix.fd_t,
        option: u32,
        deadline_ms: i64,
    ) !void {
        const timeout_ms = try remainingTimeoutMs(deadline_ms);
        const timeout = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        try std.posix.setsockopt(
            sock,
            std.posix.SOL.SOCKET,
            option,
            std.mem.asBytes(&timeout),
        );
    }

    fn readFull(sock: std.posix.fd_t, buf: []u8, deadline_ms: i64) !void {
        var read: usize = 0;
        while (read < buf.len) {
            try setSocketTimeout(sock, std.posix.SO.RCVTIMEO, deadline_ms);
            const n = try compat.posixRead(sock, buf[read..]);
            if (n == 0) return error.UnexpectedEof;
            read += n;
        }
    }

    fn writeFull(
        sock: std.posix.fd_t,
        buf: []const u8,
        deadline_ms: i64,
    ) !void {
        var written: usize = 0;
        while (written < buf.len) {
            try setSocketTimeout(sock, std.posix.SO.SNDTIMEO, deadline_ms);
            written += try compat.posixSocketWrite(sock, buf[written..]);
        }
    }

    fn dnsNamesEqual(left_raw: []const u8, right_raw: []const u8) bool {
        const left = if (left_raw.len > 0 and left_raw[left_raw.len - 1] == '.')
            left_raw[0 .. left_raw.len - 1]
        else
            left_raw;
        const right = if (right_raw.len > 0 and right_raw[right_raw.len - 1] == '.')
            right_raw[0 .. right_raw.len - 1]
        else
            right_raw;
        return std.ascii.eqlIgnoreCase(left, right);
    }

    /// 校验 DNS 响应是否与查询匹配，防止缓存投毒
    fn validateResponse(query: *const protocol.Message, response: *const protocol.Message, domain: []const u8) !void {
        // 必须是响应消息
        if (!response.isResponse()) return error.NotAResponse;
        // 事务 ID 必须匹配（防止离/在路径欺骗）
        if (response.id != query.id) return error.DnsIdMismatch;
        // 问题段必须回显我们询问的名称与类型
        if (response.questions.items.len == 0) return error.DnsQuestionMismatch;
        if (query.questions.items.len == 0) return error.DnsQuestionMismatch;
        const q = response.questions.items[0];
        if (q.qtype != query.questions.items[0].qtype) return error.DnsQuestionMismatch;
        if (!dnsNamesEqual(q.name, domain)) return error.DnsQuestionMismatch;
    }

    fn appendResponseAddresses(
        self: *DnsClient,
        addresses: *std.ArrayList(net.Address),
        response: *const protocol.Message,
    ) !void {
        for (response.answers.items) |record| {
            if (record.rclass != 1) continue;
            if (record.rtype == @intFromEnum(protocol.QueryType.a) and
                record.rdata.len == 4)
            {
                try addresses.append(
                    self.allocator,
                    net.Address.initIp4(record.rdata[0..4].*, 0),
                );
            } else if (record.rtype == @intFromEnum(protocol.QueryType.aaaa) and
                record.rdata.len == 16)
            {
                try addresses.append(
                    self.allocator,
                    net.Address.initIp6(record.rdata[0..16].*, 0),
                );
            }
        }
    }

    /// UDP DNS 查询
    fn queryUdp(
        self: *DnsClient,
        server: []const u8,
        domain: []const u8,
        query_type: protocol.QueryType,
        deadline_ms: i64,
    ) ![]net.Address {
        const addr = try net.Address.parseIp4(server, self.config.port);
        const sock = try compat.udpSocket4();
        defer compat.posixClose(sock);

        // Set timeout
        const timeout_ms = try remainingTimeoutMs(deadline_ms);
        const timeout = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));

        // Build query
        var query = try protocol.createQuery(self.allocator, domain, query_type);
        defer query.deinit();

        const query_data = try query.encode(self.allocator);
        defer self.allocator.free(query_data);

        // Send query
        _ = try compat.posixSendTo(
            sock,
            query_data,
            0,
            @ptrCast(&addr.in.sa),
            @sizeOf(@TypeOf(addr.in.sa)),
        );

        // Receive only from the configured resolver. A matching transaction ID
        // is not a substitute for authenticating the UDP source endpoint.
        var resp_buf: [4096]u8 = undefined;
        const received = try compat.udpRecvFrom(sock, &resp_buf);
        if (received.addr.family != addr.in.sa.family or
            received.addr.port != addr.in.sa.port or
            received.addr.addr != addr.in.sa.addr)
        {
            return error.UnexpectedDnsPeer;
        }
        const recv_len = received.n;
        if (recv_len >= 4 and (resp_buf[2] & 0x02) != 0) {
            return self.queryTcp(server, domain, query_type, deadline_ms);
        }

        // Parse response
        var response = protocol.Message.init(self.allocator);
        defer response.deinit();
        try response.decode(resp_buf[0..recv_len]);

        // Validate response matches our query (anti cache-poisoning)
        try validateResponse(&query, &response, domain);

        // Check response
        if (response.getResponseCode() != .no_error) {
            return error.DnsError;
        }

        // Extract addresses
        var addresses = std.ArrayList(net.Address).empty;
        defer addresses.deinit(self.allocator);

        try self.appendResponseAddresses(&addresses, &response);

        if (addresses.items.len == 0) {
            return error.NoAddresses;
        }

        const result = try self.allocator.alloc(net.Address, addresses.items.len);
        @memcpy(result, addresses.items);
        return result;
    }

    /// TCP DNS 查询
    fn queryTcp(
        self: *DnsClient,
        server: []const u8,
        domain: []const u8,
        query_type: protocol.QueryType,
        deadline_ms: i64,
    ) ![]net.Address {
        const address = try net.Address.parseIp4(server, self.config.port);
        const stream = try net.tcpConnectToAddressWithTimeout(
            address,
            try remainingTimeoutMs(deadline_ms),
        );
        defer stream.close();

        const sock = stream.handle;

        // Build query
        var query = try protocol.createQuery(self.allocator, domain, query_type);
        defer query.deinit();

        const query_data = try query.encode(self.allocator);
        defer self.allocator.free(query_data);

        // Send length-prefixed message
        const len = @as(u16, @intCast(query_data.len));
        const len_bytes = [_]u8{ @intCast(len >> 8), @intCast(len & 0xFF) };
        try writeFull(sock, &len_bytes, deadline_ms);
        try writeFull(sock, query_data, deadline_ms);

        // Read length (fully, handling short reads)
        var len_buf: [2]u8 = undefined;
        try readFull(sock, &len_buf, deadline_ms);
        const resp_len = (@as(u16, len_buf[0]) << 8) | len_buf[1];

        // Read response (fully, handling short reads)
        const resp_data = try self.allocator.alloc(u8, resp_len);
        defer self.allocator.free(resp_data);
        try readFull(sock, resp_data, deadline_ms);

        // Parse response
        var response = protocol.Message.init(self.allocator);
        defer response.deinit();
        try response.decode(resp_data);

        // Validate response matches our query (anti cache-poisoning)
        try validateResponse(&query, &response, domain);

        if (response.getResponseCode() != .no_error) {
            return error.DnsError;
        }

        // Extract addresses
        var addresses = std.ArrayList(net.Address).empty;
        defer addresses.deinit(self.allocator);

        try self.appendResponseAddresses(&addresses, &response);

        if (addresses.items.len == 0) {
            return error.NoAddresses;
        }

        const result = try self.allocator.alloc(net.Address, addresses.items.len);
        @memcpy(result, addresses.items);
        return result;
    }

    /// 清除过期缓存
    pub fn cleanupCache(self: *DnsClient) void {
        self.cache_mutex.lockUncancelable(compat.io());
        defer self.cache_mutex.unlock(compat.io());

        const now = compat.timestamp();
        var iter = self.cache.iterator();
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        while (iter.next()) |entry| {
            if (entry.value_ptr.expires_at <= now) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.cache.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                var value = kv.value;
                value.addresses.deinit(self.allocator);
            }
        }
    }
};

const testing = std.testing;

/// 构造一个用于测试的 DNS 响应消息
fn makeTestResponse(
    allocator: std.mem.Allocator,
    id: u16,
    flags: u16,
    qname: ?[]const u8,
    qtype: protocol.QueryType,
) !protocol.Message {
    var msg = protocol.Message.init(allocator);
    errdefer msg.deinit();
    msg.id = id;
    msg.flags = flags;
    if (qname) |n| {
        const name = try allocator.dupe(u8, n);
        try msg.questions.append(allocator, .{ .name = name, .qtype = qtype });
    }
    return msg;
}

fn appendTestAnswer(
    allocator: std.mem.Allocator,
    response: *protocol.Message,
    query_type: protocol.QueryType,
    data: []const u8,
) !void {
    const name = try allocator.dupe(u8, "example.com");
    errdefer allocator.free(name);
    const record_data = try allocator.dupe(u8, data);
    errdefer allocator.free(record_data);
    try response.answers.append(allocator, .{
        .name = name,
        .rtype = @intFromEnum(query_type),
        .rclass = 1,
        .ttl = 60,
        .rdata = record_data,
    });
}

test "response addresses preserve IPv4 and IPv6 network bytes" {
    const allocator = testing.allocator;
    var client = DnsClient.init(allocator, .{});
    defer client.deinit();
    var response = protocol.Message.init(allocator);
    defer response.deinit();

    const ipv4 = [_]u8{ 1, 2, 3, 4 };
    try appendTestAnswer(allocator, &response, .a, &ipv4);
    const ipv6 = [_]u8{ 0x20, 0x01, 0x0d, 0xb8 } ++ [_]u8{0} ** 12;
    try appendTestAnswer(allocator, &response, .aaaa, &ipv6);

    var addresses = std.ArrayList(net.Address).empty;
    defer addresses.deinit(allocator);
    try client.appendResponseAddresses(&addresses, &response);
    try testing.expectEqual(@as(usize, 2), addresses.items.len);
    try testing.expectEqualSlices(
        u8,
        &ipv4,
        std.mem.asBytes(&addresses.items[0].in.sa.addr),
    );
    try testing.expectEqualSlices(
        u8,
        &ipv6,
        &addresses.items[1].in6.sa.addr,
    );
}

test "validateResponse accepts matching response" {
    const allocator = testing.allocator;
    var query = try protocol.createAQuery(allocator, "example.com");
    defer query.deinit();

    var response = try makeTestResponse(allocator, query.id, 0x8180, "example.com", .a);
    defer response.deinit();

    try DnsClient.validateResponse(&query, &response, "example.com");
}

test "validateResponse rejects mismatched transaction ID (spoofing)" {
    const allocator = testing.allocator;
    var query = try protocol.createAQuery(allocator, "example.com");
    defer query.deinit();

    // Attacker-injected response with a different/forged ID
    var response = try makeTestResponse(allocator, query.id +% 1, 0x8180, "example.com", .a);
    defer response.deinit();

    try testing.expectError(error.DnsIdMismatch, DnsClient.validateResponse(&query, &response, "example.com"));
}

test "validateResponse rejects non-response (QR bit clear)" {
    const allocator = testing.allocator;
    var query = try protocol.createAQuery(allocator, "example.com");
    defer query.deinit();

    // flags without the 0x8000 QR bit
    var response = try makeTestResponse(allocator, query.id, 0x0100, "example.com", .a);
    defer response.deinit();

    try testing.expectError(error.NotAResponse, DnsClient.validateResponse(&query, &response, "example.com"));
}

test "validateResponse rejects wrong question name" {
    const allocator = testing.allocator;
    var query = try protocol.createAQuery(allocator, "example.com");
    defer query.deinit();

    var response = try makeTestResponse(allocator, query.id, 0x8180, "evil.com", .a);
    defer response.deinit();

    try testing.expectError(error.DnsQuestionMismatch, DnsClient.validateResponse(&query, &response, "example.com"));
}

test "validateResponse rejects missing question section" {
    const allocator = testing.allocator;
    var query = try protocol.createAQuery(allocator, "example.com");
    defer query.deinit();

    var response = try makeTestResponse(allocator, query.id, 0x8180, null, .a);
    defer response.deinit();

    try testing.expectError(error.DnsQuestionMismatch, DnsClient.validateResponse(&query, &response, "example.com"));
}

test "validateResponse matches question name case-insensitively" {
    const allocator = testing.allocator;
    var query = try protocol.createAQuery(allocator, "Example.COM");
    defer query.deinit();

    var response = try makeTestResponse(allocator, query.id, 0x8180, "example.com", .a);
    defer response.deinit();

    try DnsClient.validateResponse(&query, &response, "Example.COM");
}

test "validateResponse treats a trailing root label as equivalent" {
    const allocator = testing.allocator;
    var query = try protocol.createAQuery(allocator, "example.com.");
    defer query.deinit();

    var response = try makeTestResponse(
        allocator,
        query.id,
        0x8180,
        "example.com",
        .a,
    );
    defer response.deinit();

    try DnsClient.validateResponse(&query, &response, "example.com.");
}

test "cleanupCache evicts expired entries and frees memory" {
    const allocator = testing.allocator;
    var client = DnsClient.init(allocator, .{ .enable_cache = true });
    defer client.deinit();

    // Insert an already-expired entry.
    var entry = CacheEntry{
        .addresses = std.ArrayList(net.Address).empty,
        .expires_at = compat.timestamp() - 1000,
    };
    try entry.addresses.append(allocator, net.Address{ .in = .{ .sa = .{
        .family = std.posix.AF.INET,
        .port = 0,
        .addr = 0x0100007f,
        .zero = undefined,
    } } });
    try client.cache.put(try allocator.dupe(u8, "expired.example"), entry);

    // Insert a still-valid entry.
    const entry2 = CacheEntry{
        .addresses = std.ArrayList(net.Address).empty,
        .expires_at = compat.timestamp() + 1000,
    };
    try client.cache.put(try allocator.dupe(u8, "fresh.example"), entry2);

    try testing.expectEqual(@as(usize, 2), client.cache.count());

    client.cleanupCache();

    try testing.expectEqual(@as(usize, 1), client.cache.count());
    try testing.expect(client.cache.get("fresh.example") != null);
    try testing.expect(client.cache.get("expired.example") == null);
}
