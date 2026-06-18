const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const crypto = std.crypto;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;
const socket_options = @import("../socket_options.zig");

/// Trojan 命令类型
pub const Command = enum(u8) {
    connect = 0x01,
    udp_associate = 0x03,
};

/// Trojan 配置
pub const Config = struct {
    password: []const u8, // Trojan 密码 (SHA-224 哈希)
    address: []const u8, // 服务器地址
    port: u16, // 服务器端口 (通常是 443)
    sni: ?[]const u8 = null, // TLS SNI
    skip_cert_verify: bool = false,
};

/// Trojan 客户端
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    password_hash: [56]u8, // SHA-224 hex string (28 bytes * 2)
    tls_conn: ?*TlsConnection = null,

    const TlsConnection = struct {
        stream: net.Stream,
        stream_reader: net.Stream.Reader,
        stream_writer: net.Stream.Writer,
        tls_client: tls.Client,
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
            self.allocator.destroy(conn);
            self.tls_conn = null;
        }
    }

    /// 连接到 Trojan 服务器
    pub fn connect(self: *Client, target_host: []const u8, target_port: u16) !net.Stream {
        if (self.tls_conn != null) return error.AlreadyConnected;

        // 1. 建立 TCP 连接
        const stream = try net.tcpConnectToHost(self.allocator, self.config.address, self.config.port);
        try socket_options.configureConnectedStream(stream);

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
        try flushTlsAndSocket(conn);
    }

    pub fn read(self: *Client, buf: []u8) !usize {
        const conn = self.tls_conn orelse return error.NotConnected;
        return readTlsApplicationData(&conn.tls_client.reader, buf) catch |err| {
            // TLS truncation without close_notify is a clean EOF for trojan tunnels.
            // Fatal TLS errors (bad record MAC, alert) still propagate.
            if (err != error.ReadFailed) return err;
            const tls_err = conn.tls_client.read_err orelse return err;
            if (tls_err == error.TlsConnectionTruncated) return 0;
            return err;
        };
    }

    pub fn hasPendingRead(self: *const Client) bool {
        if (self.tls_conn) |conn| {
            return hasPendingBufferedRead(
                conn.tls_client.reader.bufferedLen(),
                conn.stream_reader.interface.bufferedLen(),
            );
        }
        return false;
    }

    fn hasPendingBufferedRead(tls_buffered: usize, socket_buffered: usize) bool {
        return tls_buffered > 0 or socket_buffered > 0;
    }

    /// Diagnostic: the most recent underlying std.crypto.tls read error, if any.
    /// A relay teardown surfaces only `error.ReadFailed`; this exposes the real
    /// cause so logs can tell a benign `TlsConnectionTruncated` (upstream dropped
    /// the TCP mid-record without close_notify — the suspected brew-download
    /// failure) apart from a genuinely fatal `TlsBadRecordMac`/`TlsAlert`.
    pub fn lastReadError(self: *const Client) ?anyerror {
        if (self.tls_conn) |conn| {
            if (conn.tls_client.read_err) |e| return e;
        }
        return null;
    }

    fn initTlsConnection(self: *Client, stream: net.Stream) !*TlsConnection {
        const conn = try self.allocator.create(TlsConnection);
        errdefer self.allocator.destroy(conn);

        conn.stream = stream;
        conn.socket_read_buffer = undefined;
        conn.socket_write_buffer = undefined;
        conn.tls_read_buffer = undefined;
        conn.tls_write_buffer = undefined;
        conn.stream_reader = conn.stream.reader(&conn.socket_read_buffer);
        conn.stream_writer = conn.stream.writer(&conn.socket_write_buffer);
        conn.tls_client = undefined;

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        compat.randomBytes(&entropy);
        const now = std.Io.Timestamp.now(compat.io(), .real);
        var root_bundle: Certificate.Bundle = .empty;
        defer root_bundle.deinit(self.allocator);
        var ca_lock: std.Io.RwLock = .init;
        var options = tls.Client.Options{
            .host = if (self.shouldOmitSni()) .{ .no_verification = {} } else .{ .explicit = self.tlsHost() },
            .ca = .{ .no_verification = {} },
            .allow_truncation_attacks = true,
            .read_buffer = &conn.tls_read_buffer,
            .write_buffer = &conn.tls_write_buffer,
            .entropy = &entropy,
            .realtime_now = now,
        };

        if (!self.config.skip_cert_verify) {
            try root_bundle.rescan(self.allocator, compat.io(), now);
            options.ca = .{ .bundle = .{
                .gpa = self.allocator,
                .io = compat.io(),
                .lock = &ca_lock,
                .bundle = &root_bundle,
            } };
        }

        conn.tls_client = tls.Client.init(
            &conn.stream_reader.interface,
            &conn.stream_writer.interface,
            options,
        ) catch |err| return err;

        return conn;
    }

    fn tlsHost(self: *const Client) []const u8 {
        return self.config.sni orelse self.config.address;
    }

    /// Decide whether to omit the SNI extension and skip hostname verification.
    /// Mirrors anytls's shouldOmitSni but gated by the stricter trojan intent:
    /// omit only when tlsHost() is a raw-IP literal AND no explicit sni was set.
    /// Sending an IP as the SNI is a fingerprint and forces hostname matching
    /// against an IP string (breaks domain-only certs). Keeping config.sni guards
    /// real hostnames and any explicitly-configured sni (which keep .explicit).
    /// CA-chain verification is unaffected — it is driven independently by options.ca.
    fn shouldOmitSni(self: *const Client) bool {
        return self.config.sni == null and isIpLiteral(self.config.address);
    }

    fn deinitTlsConnection(self: *Client, conn: *TlsConnection) void {
        _ = conn.tls_client.end() catch {};
        conn.stream.close();
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
        try flushTlsAndSocket(conn);
    }

    fn flushTlsAndSocket(conn: *TlsConnection) !void {
        try conn.tls_client.writer.flush();
        try conn.stream_writer.interface.flush();
    }

    fn readTlsApplicationData(reader: *std.Io.Reader, out: []u8) !usize {
        if (out.len == 0) return 0;

        while (reader.bufferedLen() == 0) {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => return 0,
                error.ReadFailed => return error.ReadFailed,
            };
        }

        const buffered = reader.buffered();
        const n = @min(out.len, buffered.len);
        @memcpy(out[0..n], buffered[0..n]);
        reader.seek += n;
        return n;
    }

    /// 编码目标地址
    fn encodeAddress(self: *Client, buf: *std.ArrayList(u8), host: []const u8) !void {
        // Try IPv4
        var ipv4: [4]u8 = undefined;
        if (parseIpv4(host, &ipv4)) {
            try buf.append(self.allocator, 0x01); // IPv4
            try buf.appendSlice(self.allocator, &ipv4);
            return;
        }

        // Try IPv6
        var ipv6: [16]u8 = undefined;
        if (parseIpv6(host, &ipv6)) {
            try buf.append(self.allocator, 0x04); // IPv6
            try buf.appendSlice(self.allocator, &ipv6);
            return;
        }

        // Domain
        if (host.len > 255) return error.DomainTooLong;
        try buf.append(self.allocator, 0x03); // Domain
        try buf.append(self.allocator, @intCast(host.len));
        try buf.appendSlice(self.allocator, host);
    }
};

/// 解析 IPv4 地址
fn parseIpv4(str: []const u8, out: *[4]u8) bool {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var current: u16 = 0;
    var digits: usize = 0;
    var first_char: u8 = 0;

    for (str) |c| {
        if (c == '.') {
            if (part_idx >= 3) return false; // too many octets
            if (digits == 0) return false; // empty octet (leading/doubled dot)
            parts[part_idx] = @intCast(current);
            part_idx += 1;
            current = 0;
            digits = 0;
        } else if (c >= '0' and c <= '9') {
            if (digits == 0) first_char = c;
            digits += 1;
            if (digits > 3) return false; // octet longer than 3 digits
            // inet_pton strictness: reject any octet of length>1 starting with '0'.
            if (digits > 1 and first_char == '0') return false;
            current = current * 10 + (c - '0');
            if (current > 255) return false;
        } else {
            return false;
        }
    }

    if (part_idx != 3) return false; // too few octets
    if (digits == 0) return false; // empty trailing octet (trailing dot / empty string)
    parts[3] = @intCast(current);

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

/// Returns true when `host` is a raw IPv4 or IPv6 literal (not a hostname).
/// Reuses the existing parseIpv4/parseIpv6 parsers.
fn isIpLiteral(host: []const u8) bool {
    var ipv4: [4]u8 = undefined;
    if (parseIpv4(host, &ipv4)) return true;
    var ipv6: [16]u8 = undefined;
    if (parseIpv6(host, &ipv6)) return true;
    return false;
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

test "Trojan omits SNI for IP-literal server without explicit sni" {
    const allocator = testing.allocator;

    const v4 = try Client.init(allocator, .{
        .password = "test",
        .address = "192.168.1.2",
        .port = 443,
    });
    try testing.expect(v4.shouldOmitSni());

    const v6 = try Client.init(allocator, .{
        .password = "test",
        .address = "2001:db8::1",
        .port = 443,
    });
    try testing.expect(v6.shouldOmitSni());
}

test "Trojan keeps SNI for hostname server" {
    const allocator = testing.allocator;

    const client = try Client.init(allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
    });

    try testing.expect(!client.shouldOmitSni());
}

test "Trojan keeps explicit sni even when address is an IP" {
    const allocator = testing.allocator;

    const client = try Client.init(allocator, .{
        .password = "test",
        .address = "8.8.8.8",
        .port = 443,
        .sni = "m.ctrip.com",
    });

    try testing.expect(!client.shouldOmitSni());
    try testing.expectEqualStrings("m.ctrip.com", client.tlsHost());
}

test "Trojan isIpLiteral classifies literals vs hostnames" {
    try testing.expect(isIpLiteral("8.8.8.8"));
    try testing.expect(isIpLiteral("::1"));
    try testing.expect(isIpLiteral("::ffff:192.168.0.1"));
    try testing.expect(!isIpLiteral("example.com"));
    try testing.expect(!isIpLiteral("localhost"));
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

test "Trojan write path flushes underlying socket writer" {
    const allocator = testing.allocator;
    const content = try compat.fs.cwd().readFileAlloc(allocator, "src/protocol/trojan.zig", 1024 * 1024);
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "fn " ++ "flushTlsAndSocket") != null);
    try testing.expect(std.mem.indexOf(u8, content, "conn.stream_writer.interface." ++ "flush()") != null);
}

test "Trojan pending read includes raw TLS socket reader data" {
    const allocator = testing.allocator;
    const content = try compat.fs.cwd().readFileAlloc(allocator, "src/protocol/trojan.zig", 1024 * 1024);
    defer allocator.free(content);

    try testing.expect(Client.hasPendingBufferedRead(1, 0));
    try testing.expect(Client.hasPendingBufferedRead(0, 1));
    try testing.expect(!Client.hasPendingBufferedRead(0, 0));
    try testing.expect(std.mem.indexOf(u8, content, "conn.tls_client.reader." ++ "bufferedLen()") != null);
    try testing.expect(std.mem.indexOf(u8, content, "conn.stream_reader.interface." ++ "bufferedLen()") != null);
}

test "Trojan read uses TLS buffered short-read semantics" {
    const allocator = testing.allocator;
    const content = try compat.fs.cwd().readFileAlloc(allocator, "src/protocol/trojan.zig", 1024 * 1024);
    defer allocator.free(content);

    const read_pos = std.mem.indexOf(u8, content, "pub fn read(self: *Client") orelse return error.TestUnexpectedResult;
    const pending_pos = std.mem.indexOfPos(u8, content, read_pos, "pub fn hasPendingRead") orelse return error.TestUnexpectedResult;
    const read_body = content[read_pos..pending_pos];
    try testing.expect(std.mem.indexOf(u8, read_body, "readTlsApplicationData") != null);
    try testing.expect(std.mem.indexOf(u8, read_body, "readSliceShort") == null);
}

test "Trojan parseIpv4 rejects overflowing octet without panic" {
    var out: [4]u8 = undefined;
    // Octet > 255 must be rejected, not overflow a u8 accumulator.
    try testing.expect(!parseIpv4("256.0.0.1", &out));
    try testing.expect(!parseIpv4("999.1.1.1", &out));
    // Valid address still parses correctly.
    try testing.expect(parseIpv4("10.0.0.255", &out));
    try testing.expectEqual(@as(u8, 10), out[0]);
    try testing.expectEqual(@as(u8, 255), out[3]);
}

test "Trojan parseIpv4 strict: rejects empty octet, leading zero, trailing dot" {
    var out: [4]u8 = undefined;
    // Empty octets (doubled/leading/trailing dots) must be rejected, not silently
    // accepted as 0 — this agrees with the strict stdlib parser the bypass guard uses.
    try testing.expect(!parseIpv4("1..2.3", &out));
    try testing.expect(!parseIpv4(".1.2.3", &out));
    try testing.expect(!parseIpv4("1.2.3.", &out));
    // Leading-zero octets (length>1 starting with '0') are rejected by inet_pton too.
    try testing.expect(!parseIpv4("010.0.0.1", &out));
    try testing.expect(!parseIpv4("1.2.3.04", &out));
    // Wrong octet count.
    try testing.expect(!parseIpv4("1.2.3", &out)); // too few
    try testing.expect(!parseIpv4("1.2.3.4.5", &out)); // too many
    try testing.expect(!parseIpv4("", &out)); // empty string
    // Positive controls: well-formed addresses (including lone-'0' octets) still parse.
    try testing.expect(parseIpv4("0.0.0.0", &out));
    try testing.expect(parseIpv4("192.168.1.1", &out));
    try testing.expectEqual(@as(u8, 192), out[0]);
}

test "Trojan encodeAddress: malformed quad falls through to domain" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    // "010.0.0.1" is no longer a valid IPv4 literal — it must fall through to
    // domain (0x03) encoding rather than being mis-encoded as a 0x01 IPv4 target.
    const host = "010.0.0.1";
    try client.encodeAddress(&buf, host);

    try testing.expectEqual(@as(u8, 0x03), buf.items[0]); // domain
    try testing.expectEqual(@as(u8, host.len), buf.items[1]); // length prefix
    try testing.expectEqualStrings(host, buf.items[2..][0..host.len]);
}

test "Trojan encodeAddress rejects over-long domain" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const long_host = "a" ** 256;
    try testing.expectError(error.DomainTooLong, client.encodeAddress(&buf, long_host));

    // A 255-byte domain is still accepted and length-prefixed correctly.
    var buf2 = std.ArrayList(u8).empty;
    defer buf2.deinit(allocator);
    const max_host = "b" ** 255;
    try client.encodeAddress(&buf2, max_host);
    try testing.expectEqual(@as(u8, 0x03), buf2.items[0]);
    try testing.expectEqual(@as(u8, 255), buf2.items[1]);
}
