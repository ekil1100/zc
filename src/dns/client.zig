const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const protocol = @import("protocol.zig");

/// DNS 客户端配置
pub const DnsConfig = struct {
    /// 主 DNS 服务器
    primary: []const u8 = "8.8.8.8",
    /// 备用 DNS 服务器
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
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.addresses.deinit(self.allocator);
        }
        self.cache.deinit();
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
                    const result = try self.allocator.alloc(net.Address, entry.addresses.items.len);
                    @memcpy(result, entry.addresses.items);
                    return result;
                }
                // Expired, remove
                _ = self.cache.remove(domain);
            }
        }

        // Query DNS
        const addresses = try self.queryDns(domain);
        errdefer self.allocator.free(addresses);

        // Add to cache
        if (self.config.enable_cache) {
            self.cache_mutex.lockUncancelable(compat.io());
            defer self.cache_mutex.unlock(compat.io());

            var entry = CacheEntry{
                .addresses = std.ArrayList(net.Address).empty,
                .expires_at = compat.timestamp() + self.config.cache_ttl,
            };
            try entry.addresses.appendSlice(self.allocator, addresses);
            try self.cache.put(try self.allocator.dupe(u8, domain), entry);
        }

        return addresses;
    }

    /// 查询 DNS 服务器
    fn queryDns(self: *DnsClient, domain: []const u8) ![]net.Address {
        // Try primary
        const result = self.queryServer(self.config.primary, domain) catch |err| {
            std.debug.print("Primary DNS query failed: {}\n", .{err});
            
            // Try secondary if available
            if (self.config.secondary) |secondary| {
                return try self.queryServer(secondary, domain);
            }
            return err;
        };

        return result;
    }

    fn queryServer(self: *DnsClient, server: []const u8, domain: []const u8) ![]net.Address {
        if (self.config.use_tcp) {
            return try self.queryTcp(server, domain);
        } else {
            return try self.queryUdp(server, domain);
        }
    }

    /// 读取确切数量的字节（处理短读取）
    fn readFull(sock: std.posix.fd_t, buf: []u8) !void {
        var read: usize = 0;
        while (read < buf.len) {
            const n = try compat.posixRead(sock, buf[read..]);
            if (n == 0) return error.UnexpectedEof;
            read += n;
        }
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
        if (!std.ascii.eqlIgnoreCase(q.name, domain)) return error.DnsQuestionMismatch;
    }

    /// UDP DNS 查询
    fn queryUdp(self: *DnsClient, server: []const u8, domain: []const u8) ![]net.Address {
        var addrs = try net.getAddressList(self.allocator, server, self.config.port);
        defer addrs.deinit();

        if (addrs.addrs.len == 0) return error.HostNotFound;

        const sock = try compat.udpSocket4();
        defer compat.posixClose(sock);

        // Set timeout
        const timeout = std.posix.timeval{
            .sec = @intCast(self.config.timeout_ms / 1000),
            .usec = @intCast((self.config.timeout_ms % 1000) * 1000),
        };
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));

        // Build query
        var query = try protocol.createAQuery(self.allocator, domain);
        defer query.deinit();

        const query_data = try query.encode(self.allocator);
        defer self.allocator.free(query_data);

        // Send query
        const addr = net.Address.initIp4(
            @as(*const [4]u8, @ptrCast(&addrs.addrs[0].in.sa.addr)).*,
            self.config.port
        );
        _ = try compat.posixSendTo(sock, query_data, 0, @ptrCast(&addr.in.sa), @sizeOf(@TypeOf(addr.in.sa)));

        // Receive response
        var resp_buf: [512]u8 = undefined;
        const recv_len = try compat.posixRecv(sock, &resp_buf, 0);

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

        for (response.answers.items) |rr| {
            if (rr.rtype == 1 and rr.rclass == 1 and rr.rdata.len == 4) { // A record
                const ip = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(rr.rdata[0..4].ptr)), .big);
                try addresses.append(self.allocator, net.Address{ .in = .{
                    .sa = .{
                        .family = std.posix.AF.INET,
                        .port = 0,
                        .addr = ip,
                        .zero = undefined,
                    },
                } });
            }
        }

        if (addresses.items.len == 0) {
            return error.NoAddresses;
        }

        const result = try self.allocator.alloc(net.Address, addresses.items.len);
        @memcpy(result, addresses.items);
        return result;
    }

    /// TCP DNS 查询
    fn queryTcp(self: *DnsClient, server: []const u8, domain: []const u8) ![]net.Address {
        var stream = try net.tcpConnectToHost(self.allocator, server, self.config.port);
        defer stream.close();

        const sock = stream.handle;

        // Build query
        var query = try protocol.createAQuery(self.allocator, domain);
        defer query.deinit();

        const query_data = try query.encode(self.allocator);
        defer self.allocator.free(query_data);

        // Send length-prefixed message
        const len = @as(u16, @intCast(query_data.len));
        const len_bytes = [_]u8{@intCast(len >> 8), @intCast(len & 0xFF)};
        _ = try compat.posixWrite(sock, &len_bytes);
        _ = try compat.posixWrite(sock, query_data);

        // Read length (fully, handling short reads)
        var len_buf: [2]u8 = undefined;
        try readFull(sock, &len_buf);
        const resp_len = (@as(u16, len_buf[0]) << 8) | len_buf[1];

        // Read response (fully, handling short reads)
        const resp_data = try self.allocator.alloc(u8, resp_len);
        defer self.allocator.free(resp_data);
        try readFull(sock, resp_data);

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

        for (response.answers.items) |rr| {
            if (rr.rtype == 1 and rr.rclass == 1 and rr.rdata.len == 4) {
                const ip = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(rr.rdata[0..4].ptr)), .big);
                try addresses.append(self.allocator, net.Address{ .in = .{
                    .sa = .{
                        .family = std.posix.AF.INET,
                        .port = 0,
                        .addr = ip,
                        .zero = undefined,
                    },
                } });
            }
        }

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
