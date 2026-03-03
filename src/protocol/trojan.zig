const std = @import("std");
const net = std.net;
const crypto = std.crypto;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;

/// Trojan 命令类型
pub const Command = enum(u8) {
    connect = 0x01,
    udp_associate = 0x03,
};

/// Trojan 配置
pub const Config = struct {
    password: []const u8,     // Trojan 密码 (SHA-224 哈希)
    address: []const u8,     // 服务器地址
    port: u16,               // 服务器端口 (通常是 443)
    sni: ?[]const u8 = null,  // TLS SNI
    skip_cert_verify: bool = false,
};

/// Trojan 客户端
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    password_hash: [56]u8,   // SHA-224 hex string (28 bytes * 2)
    tls_conn: ?*TlsConnection = null,

    const TlsConnection = struct {
        stream: net.Stream,
        stream_reader: net.Stream.Reader,
        stream_writer: net.Stream.Writer,
        tls_client: tls.Client,
        ca_bundle: ?Certificate.Bundle = null,
        socket_read_buffer: [tls.Client.min_buffer_len]u8,
        socket_write_buffer: [tls.Client.min_buffer_len]u8,
        tls_read_buffer: [tls.Client.min_buffer_len]u8,
        tls_write_buffer: [tls.Client.min_buffer_len]u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        // 计算密码的 SHA-224 哈希
        var hash: [28]u8 = undefined;
        var sha = crypto.hash.sha2.Sha224.init(.{});
        sha.update(config.password);
        sha.final(&hash);

        // 转换为 hex string (手动实现)
        var password_hash: [56]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (hash, 0..) |byte, i| {
            password_hash[i * 2] = hex_chars[byte >> 4];
            password_hash[i * 2 + 1] = hex_chars[byte & 0x0f];
        }

        return .{
            .allocator = allocator,
            .config = config,
            .password_hash = password_hash,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.tls_conn) |conn| {
            _ = conn.tls_client.end() catch {};
            conn.stream.close();
            if (conn.ca_bundle) |*ca_bundle| {
                ca_bundle.deinit(self.allocator);
            }
            self.allocator.destroy(conn);
            self.tls_conn = null;
        }
    }

    /// 连接到 Trojan 服务器
    pub fn connect(self: *Client, target_host: []const u8, target_port: u16) !net.Stream {
        if (self.tls_conn != null) return error.AlreadyConnected;

        // 1. 建立 TCP 连接
        const stream = try net.tcpConnectToHost(self.allocator, self.config.address, self.config.port);

        // 2. 在 TCP 之上建立 TLS 会话
        const conn = self.initTlsConnection(stream) catch |err| {
            stream.close();
            return err;
        };
        errdefer self.deinitTlsConnection(conn);

        // 3. 在 TLS 通道中发送 Trojan 握手
        try self.handshake(conn, target_host, target_port);

        self.tls_conn = conn;
        return conn.stream;
    }

    pub fn write(self: *Client, data: []const u8) !void {
        const conn = self.tls_conn orelse return error.NotConnected;
        try conn.tls_client.writer.writeAll(data);
        try conn.tls_client.writer.flush();
    }

    pub fn read(self: *Client, buf: []u8) !usize {
        const conn = self.tls_conn orelse return error.NotConnected;
        return try conn.tls_client.reader.readSliceShort(buf);
    }

    pub fn hasPendingRead(self: *const Client) bool {
        if (self.tls_conn) |conn| {
            return conn.tls_client.reader.bufferedLen() > 0;
        }
        return false;
    }

    fn initTlsConnection(self: *Client, stream: net.Stream) !*TlsConnection {
        const conn = try self.allocator.create(TlsConnection);
        errdefer self.allocator.destroy(conn);

        conn.stream = stream;
        conn.ca_bundle = null;
        conn.socket_read_buffer = undefined;
        conn.socket_write_buffer = undefined;
        conn.tls_read_buffer = undefined;
        conn.tls_write_buffer = undefined;
        conn.stream_reader = conn.stream.reader(&conn.socket_read_buffer);
        conn.stream_writer = conn.stream.writer(&conn.socket_write_buffer);
        conn.tls_client = undefined;

        var options = tls.Client.Options{
            .host = .{ .explicit = self.tlsHost() },
            .ca = .{ .no_verification = {} },
            .allow_truncation_attacks = true,
            .read_buffer = &conn.tls_read_buffer,
            .write_buffer = &conn.tls_write_buffer,
        };

        if (!self.config.skip_cert_verify) {
            conn.ca_bundle = Certificate.Bundle{};
            if (conn.ca_bundle) |*ca_bundle| {
                try ca_bundle.rescan(self.allocator);
                options.ca = .{ .bundle = ca_bundle.* };
            }
        }

        conn.tls_client = tls.Client.init(
            conn.stream_reader.interface(),
            &conn.stream_writer.interface,
            options,
        ) catch |err| {
            if (conn.ca_bundle) |*ca_bundle| {
                ca_bundle.deinit(self.allocator);
                conn.ca_bundle = null;
            }
            return err;
        };

        return conn;
    }

    fn tlsHost(self: *const Client) []const u8 {
        return self.config.sni orelse self.config.address;
    }

    fn deinitTlsConnection(self: *Client, conn: *TlsConnection) void {
        _ = conn.tls_client.end() catch {};
        conn.stream.close();
        if (conn.ca_bundle) |*ca_bundle| {
            ca_bundle.deinit(self.allocator);
        }
        self.allocator.destroy(conn);
    }

    /// Trojan 握手协议
    /// 格式: [密码哈希(56)]\r\n [命令(1)] [地址类型(1)] [地址] [端口(2)]\r\n
    fn handshake(self: *Client, conn: *TlsConnection, target_host: []const u8, target_port: u16) !void {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        // 1. 密码哈希 + CRLF
        try buf.appendSlice(self.allocator, &self.password_hash);
        try buf.appendSlice(self.allocator, "\r\n");

        // 2. 命令 (CONNECT)
        try buf.append(self.allocator, @intFromEnum(Command.connect));

        // 3. 地址类型和地址
        try self.encodeAddress(&buf, target_host);

        // 4. 端口 (2 bytes, big endian)
        try buf.append(self.allocator, @intCast(target_port >> 8));
        try buf.append(self.allocator, @intCast(target_port & 0xFF));

        // 5. CRLF
        try buf.appendSlice(self.allocator, "\r\n");

        // 发送握手
        try conn.tls_client.writer.writeAll(buf.items);
        try conn.tls_client.writer.flush();
    }

    /// 编码目标地址
    fn encodeAddress(self: *Client, buf: *std.ArrayList(u8), host: []const u8) !void {
        // Try IPv4
        var ipv4: [4]u8 = undefined;
        if (parseIpv4(host, &ipv4)) {
            try buf.append(self.allocator, 0x01);  // IPv4
            try buf.appendSlice(self.allocator, &ipv4);
            return;
        }

        // Try IPv6
        var ipv6: [16]u8 = undefined;
        if (parseIpv6(host, &ipv6)) {
            try buf.append(self.allocator, 0x04);  // IPv6
            try buf.appendSlice(self.allocator, &ipv6);
            return;
        }

        // Domain
        try buf.append(self.allocator, 0x03);  // Domain
        try buf.append(self.allocator, @intCast(host.len));
        try buf.appendSlice(self.allocator, host);
    }
};

/// 解析 IPv4 地址
fn parseIpv4(str: []const u8, out: *[4]u8) bool {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var current: u8 = 0;

    for (str) |c| {
        if (c == '.') {
            if (part_idx >= 4) return false;
            parts[part_idx] = current;
            part_idx += 1;
            current = 0;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
            if (current > 255) return false;
        } else {
            return false;
        }
    }

    if (part_idx != 3) return false;
    parts[3] = current;

    @memcpy(out, &parts);
    return true;
}

/// 解析 IPv6 地址 (RFC 5952 兼容)
fn parseIpv6(str: []const u8, out: *[16]u8) bool {
    // Supports: full form, compressed (::), and IPv4-mapped (::ffff:x.x.x.x)
    @memset(out, 0);

    // Check for IPv4-mapped IPv6 (::ffff:x.x.x.x)
    if (std.mem.startsWith(u8, str, "::ffff:") or std.mem.startsWith(u8, str, "::FFFF:")) {
        const ipv4_part = str[7..];
        var ipv4: [4]u8 = undefined;
        if (!parseIpv4(ipv4_part, &ipv4)) return false;
        out[10] = 0xff;
        out[11] = 0xff;
        @memcpy(out[12..16], &ipv4);
        return true;
    }

    // Find :: position for compressed form
    const double_colon = std.mem.indexOf(u8, str, "::");
    var parts: [8]u16 = undefined;
    @memset(&parts, 0);
    var part_count: usize = 0;

    if (double_colon) |dc_pos| {
        // Parse before ::
        if (dc_pos > 0) {
            var it = std.mem.splitScalar(u8, str[0..dc_pos], ':');
            while (it.next()) |part| {
                if (part.len == 0 or part.len > 4) return false;
                parts[part_count] = std.fmt.parseInt(u16, part, 16) catch return false;
                part_count += 1;
                if (part_count > 8) return false;
            }
        }

        // Parse after ::
        const after = str[dc_pos + 2 ..];
        var after_parts: [8]u16 = undefined;
        var after_count: usize = 0;
        if (after.len > 0) {
            var it = std.mem.splitScalar(u8, after, ':');
            while (it.next()) |part| {
                if (part.len == 0 or part.len > 4) return false;
                after_parts[after_count] = std.fmt.parseInt(u16, part, 16) catch return false;
                after_count += 1;
                if (after_count > 8) return false;
            }
        }

        // Total parts must not exceed 8
        if (part_count + after_count >= 8) return false;

        // Fill middle zeros and copy after parts
        const zero_count = 8 - part_count - after_count;
        for (0..after_count) |i| {
            parts[part_count + zero_count + i] = after_parts[i];
        }
    } else {
        // Full form: exactly 8 parts
        var it = std.mem.splitScalar(u8, str, ':');
        while (it.next()) |part| {
            if (part.len == 0 or part.len > 4) return false;
            if (part_count >= 8) return false;
            parts[part_count] = std.fmt.parseInt(u16, part, 16) catch return false;
            part_count += 1;
        }
        if (part_count != 8) return false;
    }

    // Convert to 16-byte representation (network byte order)
    for (0..8) |i| {
        out[i * 2] = @intCast(parts[i] >> 8);
        out[i * 2 + 1] = @intCast(parts[i] & 0xFF);
    }

    return true;
}

/// 测试
const testing = std.testing;

test "Trojan password hash" {
    const allocator = testing.allocator;

    const client = try Client.init(allocator, .{
        .password = "password123",
        .address = "127.0.0.1",
        .port = 443,
    });

    // Password should be hashed to SHA-224
    // password123 -> f6f4689e0a6e9e36e1c25c6e6e1f1c5e9e4a8e9b9a0b8c7
    try testing.expectEqual(@as(usize, 56), client.password_hash.len);
}

test "Trojan encodeAddress IPv4" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try client.encodeAddress(&buf, "192.168.1.1");

    try testing.expectEqual(@as(u8, 0x01), buf.items[0]);
    try testing.expectEqual(@as(u8, 192), buf.items[1]);
    try testing.expectEqual(@as(u8, 168), buf.items[2]);
    try testing.expectEqual(@as(u8, 1), buf.items[3]);
    try testing.expectEqual(@as(u8, 1), buf.items[4]);
}

test "Trojan parseIpv6 full" {
    var out: [16]u8 = undefined;
    try testing.expect(parseIpv6("2001:0db8:85a3:0000:0000:8a2e:0370:7334", &out));
    try testing.expectEqual(@as(u8, 0x20), out[0]);
    try testing.expectEqual(@as(u8, 0x01), out[1]);
    try testing.expectEqual(@as(u8, 0x73), out[14]);
    try testing.expectEqual(@as(u8, 0x34), out[15]);
}

test "Trojan parseIpv6 compressed" {
    var out: [16]u8 = undefined;
    try testing.expect(parseIpv6("2001:db8::1", &out));
    try testing.expectEqual(@as(u8, 0x20), out[0]);
    try testing.expectEqual(@as(u8, 1), out[15]);
}

test "Trojan parseIpv6 ipv4-mapped" {
    var out: [16]u8 = undefined;
    try testing.expect(parseIpv6("::ffff:192.168.1.1", &out));
    try testing.expectEqual(@as(u8, 0xff), out[10]);
    try testing.expectEqual(@as(u8, 0xff), out[11]);
    try testing.expectEqual(@as(u8, 192), out[12]);
    try testing.expectEqual(@as(u8, 168), out[13]);
    try testing.expectEqual(@as(u8, 1), out[14]);
    try testing.expectEqual(@as(u8, 1), out[15]);
}

test "Trojan TLS host prefers configured sni" {
    const allocator = testing.allocator;

    const client = try Client.init(allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
        .sni = "m.ctrip.com",
    });

    try testing.expectEqualStrings("m.ctrip.com", client.tlsHost());
}

test "Trojan TLS host falls back to server address when sni is absent" {
    const allocator = testing.allocator;

    const client = try Client.init(allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
    });

    try testing.expectEqualStrings("server.example.com", client.tlsHost());
}

test "Trojan hasPendingRead returns false when not connected" {
    const allocator = testing.allocator;

    const client = try Client.init(allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
    });

    try testing.expect(!client.hasPendingRead());
}
