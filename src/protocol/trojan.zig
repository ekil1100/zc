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
    /// Defined-but-unwired: this client is CONNECT-only. handshake() always
    /// sends Command.connect (see buildRequest call below); Trojan UDP ASSOCIATE
    /// is not implemented, and config_validator rejects udp:true for trojan.
    /// The variant is kept (no other references) to mirror the protocol spec.
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
        // handshake() already flushed the Trojan request, so the server has it
        // before we ever block here — a server-speaks-first peer is not stalled.
        return readTlsApplicationData(&conn.tls_client.reader, buf) catch |err| {
            // TLS truncation without close_notify is a clean EOF for trojan tunnels.
            // Fatal TLS errors (bad record MAC, alert) still propagate.
            //
            // Residual M1 exposure: a trojan tunnel carries an UNFRAMED byte stream,
            // so at the byte level this read CANNOT distinguish a malicious on-path
            // truncation (attacker injects FIN/RST mid-record) from a legitimate
            // close — both surface here as a clean 0-length EOF. This is a deliberate
            // tradeoff: see initTlsConnection's `.allow_truncation_attacks = true`
            // note for why we accept it (the brew-download mid-record-drop case).
            // The abnormal close is NOT lost, though: the underlying TlsConnectionTruncated
            // stays observable out-of-band via lastReadError() here and
            // ProxyStream.lastTlsReadError() in the relay, which logs it as an
            // "upstream-truncated (graceful half-close)" breadcrumb. Contrast anytls:
            // its framed payloads let it reject a short final frame, which an
            // unframed trojan tunnel structurally cannot do.
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
            // Deliberate (M1): tell std.crypto.tls NOT to raise TlsConnectionTruncated
            // as fatal when the peer drops the TCP mid-record without close_notify.
            // This accepts a residual on-path truncation exposure — an attacker who
            // can inject FIN/RST truncates an unframed trojan tunnel and it reads as a
            // clean EOF (see read()) — in exchange for tolerating benign mid-record
            // drops, the brew-download truncation case the recent commits targeted.
            // The abnormal close is NOT swallowed silently: it stays visible via
            // read_err / lastReadError() / ProxyStream.lastTlsReadError(). Contrast
            // anytls's framed model, which can reject a short final frame; an unframed
            // trojan tunnel cannot. Do NOT flip this flag — that regresses the case above.
            .allow_truncation_attacks = true,
            .read_buffer = &conn.tls_read_buffer,
            .write_buffer = &conn.tls_write_buffer,
            .entropy = &entropy,
            .realtime_now = now,
        };

        // Build the verifying CA value (rescanning the real root bundle) only when
        // verification is enabled; the pure `caOption` seam then selects between it
        // and `.no_verification` so the branch is testable in isolation.
        var ca_value: CaOptions = .{ .no_verification = {} };
        if (!self.config.skip_cert_verify) {
            try root_bundle.rescan(self.allocator, compat.io(), now);
            ca_value = .{ .bundle = .{
                .gpa = self.allocator,
                .io = compat.io(),
                .lock = &ca_lock,
                .bundle = &root_bundle,
            } };
        }
        options.ca = caOption(self.config.skip_cert_verify, ca_value);

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

    /// The anonymous `union(enum)` of `tls.Client.Options.ca` — there is no public
    /// type name for it, so it must be referenced via `@FieldType`.
    const CaOptions = @FieldType(tls.Client.Options, "ca");

    /// Pure CA-options decision: when `skip_cert_verify` is set, return
    /// `.no_verification`; otherwise return the caller-built `bundle` value
    /// (which carries the live allocator/io/lock/bundle pointers).
    /// Extracting this branch makes an accidental inversion — silently disabling
    /// TLS verification — fail a test instead of slipping through unnoticed.
    fn caOption(skip_cert_verify: bool, bundle: CaOptions) CaOptions {
        return if (skip_cert_verify) .{ .no_verification = {} } else bundle;
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

    /// Build the exact Trojan request wire frame into a caller-supplied buffer.
    /// 格式: [密码哈希(56)]\r\n [命令(1)] [地址类型(1)] [地址] [端口(2)]\r\n
    /// Pure in the required sense: no TLS/socket I/O — it only appends bytes into
    /// `buf`, so the security-critical frame layout is testable in isolation.
    fn buildRequest(self: *Client, buf: *std.ArrayList(u8), cmd: Command, host: []const u8, port: u16) !void {
        // 1. 密码哈希 + CRLF
        try buf.appendSlice(self.allocator, &self.password_hash);
        try buf.appendSlice(self.allocator, "\r\n");

        // 2. 命令
        try buf.append(self.allocator, @intFromEnum(cmd));

        // 3. 地址类型和地址
        try self.encodeAddress(buf, host);

        // 4. 端口 (2 bytes, big endian)
        try buf.append(self.allocator, @intCast(port >> 8));
        try buf.append(self.allocator, @intCast(port & 0xFF));

        // 5. CRLF
        try buf.appendSlice(self.allocator, "\r\n");
    }

    /// Trojan 握手协议
    /// 格式: [密码哈希(56)]\r\n [命令(1)] [地址类型(1)] [地址] [端口(2)]\r\n
    fn handshake(self: *Client, conn: *TlsConnection, target_host: []const u8, target_port: u16) !void {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try self.buildRequest(&buf, .connect, target_host, target_port);

        // Flush the request onto the wire before connect() returns. The relay
        // only read()s the target once poll() reports it readable, and a
        // server-speaks-first peer sends nothing until it has received our
        // request — so deferring this flush to the first write()/read() can
        // deadlock that peer (the request it is waiting for is never sent).
        // Sending eagerly costs the request its own small TLS record (we no
        // longer coalesce it with the first payload), which is the correct
        // trade for not hanging server-first tunnels.
        try conn.tls_client.writer.writeAll(buf.items);
        try flushTlsAndSocket(conn);
    }

    fn flushTlsAndSocket(conn: *TlsConnection) !void {
        try conn.tls_client.writer.flush();
        try conn.stream_writer.interface.flush();
    }

    // M5 (accepted blocking-trojan-path limitation): the relay polls the trojan
    // handle for POLL.IN and only calls read() — hence this helper — once it is
    // ready. But poll() guarantees only that at least one byte of CIPHERTEXT is
    // available; a single TLS record can span multiple TCP segments. The fillMore()
    // below is a BLOCKING socket read, so it can block waiting for the rest of an
    // in-flight record even though the handle polled ready. While the relay thread
    // is parked here it cannot service the opposite (client->target) direction —
    // that direction stalls until this inbound record completes. A non-blocking
    // rearchitecture is performance-gated per AGENTS.md, so we document rather than
    // rewrite, mirroring anytls's recorded "mid-frame blocking read" residual risk
    // (docs/anytls/session-multiplexing-design.md §18.1).
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
                // Bound BEFORE the indexed store: `parts` is [8]u16, so a 9th
                // group must be rejected without writing parts[8] (an OOB write
                // that panics in safe builds, corrupts the stack otherwise).
                if (part_count >= 8) return false;
                parts[part_count] = parseHextet(part) orelse return false;
                part_count += 1;
            }
        }

        // Parse after ::
        const after = str[dc_pos + 2 ..];
        var after_parts: [8]u16 = undefined;
        var after_count: usize = 0;
        if (after.len > 0) {
            var it = std.mem.splitScalar(u8, after, ':');
            while (it.next()) |part| {
                // Same OOB guard as the before-:: loop: reject the 9th group
                // before it can write after_parts[8].
                if (after_count >= 8) return false;
                after_parts[after_count] = parseHextet(part) orelse return false;
                after_count += 1;
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
            if (part_count >= 8) return false;
            parts[part_count] = parseHextet(part) orelse return false;
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

/// Parse one IPv6 hextet: 1–4 pure hex digits, no sign. std.fmt.parseInt accepts
/// a leading '+'/'-' (e.g. "+ff", "-0"), which would let "2001:+db8::1" or "::-0"
/// masquerade as IP literals — inconsistent with the strict parseIpv4 and the rule
/// engine's IPv6 parser. Reject any non-hex-digit byte first, then parse.
fn parseHextet(part: []const u8) ?u16 {
    if (part.len == 0 or part.len > 4) return null;
    for (part) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_hex) return null;
    }
    return std.fmt.parseInt(u16, part, 16) catch null;
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

    // The wire-critical password_hash is the lowercase-hex SHA-224 of the
    // password. Pin the EXACT digest (verified out-of-band with sha224sum), not
    // just its 56-byte length: a fabricated/placeholder hash would silently send
    // the wrong credential. "password123" mixes hex nibbles both >9 (d,9,b,e,f)
    // and <9 (3,4,0,1,2,5), exercising both arms of the init() hex loop.
    const client = try Client.init(allocator, .{
        .password = "password123",
        .address = "127.0.0.1",
        .port = 443,
    });
    try testing.expectEqualStrings(
        "3d45597256050bb1e93bd9c10aee4c8716f8774f5a48c995bf0cf860",
        &client.password_hash,
    );

    // Second vector, independently verified, re-exercises the hex loop.
    const client2 = try Client.init(allocator, .{
        .password = "Test",
        .address = "127.0.0.1",
        .port = 443,
    });
    try testing.expectEqualStrings(
        "3606346815fd4d491a92649905a40da025d8cf15f095136b19f37923",
        &client2.password_hash,
    );
}

test "Trojan connect rejects an already-connected client" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
    });

    // Simulate a client that has already established a TLS session: the guard at
    // the top of connect() (`if (self.tls_conn != null) return error.AlreadyConnected`)
    // must fire BEFORE touching any field, so this stub never needs valid buffers.
    const stub = try testing.allocator.create(Client.TlsConnection);
    stub.* = undefined;
    client.tls_conn = stub;

    try testing.expectError(error.AlreadyConnected, client.connect("example.com", 80));

    // Teardown WITHOUT client.deinit(): deinit would close stub.stream (an
    // undefined fd) and destroy via the Client's allocator. Detach + destroy the
    // stub directly so testing.allocator stays leak-clean.
    client.tls_conn = null;
    testing.allocator.destroy(stub);
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

test "Trojan parseIpv6 negatives" {
    var out: [16]u8 = undefined;
    // 9 groups: the full-form loop trips `part_count >= 8` on the 9th group.
    try testing.expect(!parseIpv6("1:2:3:4:5:6:7:8:9", &out));
    // Two "::" — the split after the first "::" yields an empty part (len==0).
    try testing.expect(!parseIpv6("1::2::3", &out));
    // Non-hex group — parseInt(base 16) fails.
    try testing.expect(!parseIpv6("gggg::1", &out));
    // Group longer than 4 hex digits — `part.len > 4`.
    try testing.expect(!parseIpv6("12345::1", &out));
    // IPv4-mapped branch with an out-of-range octet — parseIpv4 rejects 999.
    try testing.expect(!parseIpv6("::ffff:999.0.0.1", &out));
}

test "Trojan parseIpv6 rejects sign-prefixed hextets (parity with strict parseIpv4)" {
    var out: [16]u8 = undefined;
    // std.fmt.parseInt(u16, "+ff"/"-0", 16) succeeds, so a bare parseInt would
    // accept these as IP literals. parseHextet rejects any non-hex-digit byte, so
    // a sign prefix is refused on every branch: before-::, after-::, and full form.
    try testing.expect(!parseIpv6("2001:+db8::1", &out)); // '+' before ::
    try testing.expect(!parseIpv6("::-0", &out)); // '-' after ::
    try testing.expect(!parseIpv6("2001:db8::-1", &out)); // '-' after ::
    try testing.expect(!parseIpv6("+2001:db8:0:0:0:0:0:1", &out)); // '+' full form
    // The unsigned forms these would-be-tricks shadow still parse correctly.
    try testing.expect(parseIpv6("2001:db8::1", &out));
    try testing.expect(parseIpv6("::1", &out));

    // parseHextet unit checks: pure hex only, 1–4 digits.
    try testing.expectEqual(@as(?u16, 0x00ff), parseHextet("ff"));
    try testing.expectEqual(@as(?u16, 0xabcd), parseHextet("ABCD"));
    try testing.expectEqual(@as(?u16, null), parseHextet("+ff"));
    try testing.expectEqual(@as(?u16, null), parseHextet("-0"));
    try testing.expectEqual(@as(?u16, null), parseHextet("")); // empty
    try testing.expectEqual(@as(?u16, null), parseHextet("12345")); // > 4 digits
    try testing.expectEqual(@as(?u16, null), parseHextet("g")); // non-hex
}

test "Trojan parseIpv6 rejects >8 groups around :: without OOB write" {
    var out: [16]u8 = undefined;
    // Regression: the compressed-form loops used to store parts[part_count]
    // BEFORE checking the bound (and checked `> 8`, not `>= 8`), so a 9th group
    // on either side of "::" wrote one past the end of the [8]u16 backing array —
    // a panic in safe builds, a stack OOB write otherwise. `host` reaches here
    // straight from the relayed CONNECT target (encodeAddress -> parseIpv6), so
    // this was a peer-triggerable crash. All four must return false, never panic.
    try testing.expect(!parseIpv6("1:2:3:4:5:6:7:8:9::1", &out)); // 9 before ::
    try testing.expect(!parseIpv6("1:2:3:4:5:6:7:8:9::", &out)); // 9 before, empty after
    try testing.expect(!parseIpv6("::1:2:3:4:5:6:7:8:9", &out)); // 9 after ::
    try testing.expect(!parseIpv6("1::2:3:4:5:6:7:8:9", &out)); // 1 before, 9 after
    // The exact boundary still parses: 7 groups + "::" (one implied zero group).
    try testing.expect(parseIpv6("1:2:3:4:5:6:7::", &out));
    try testing.expectEqual(@as(u8, 0), out[14]);
    try testing.expectEqual(@as(u8, 0), out[15]);
}

test "Trojan encodeAddress domain and IPv6" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
    });

    // Domain branch: 0x03, length prefix, raw host bytes.
    var dbuf = std.ArrayList(u8).empty;
    defer dbuf.deinit(allocator);
    try client.encodeAddress(&dbuf, "example.com");
    try testing.expectEqual(@as(u8, 0x03), dbuf.items[0]);
    try testing.expectEqual(@as(u8, 11), dbuf.items[1]);
    try testing.expectEqualStrings("example.com", dbuf.items[2..][0..11]);
    try testing.expectEqual(@as(usize, 13), dbuf.items.len);

    // IPv6 branch: 0x04 + 16-byte parsed address; "::1" ends in 0x01.
    var v6buf = std.ArrayList(u8).empty;
    defer v6buf.deinit(allocator);
    try client.encodeAddress(&v6buf, "::1");
    try testing.expectEqual(@as(u8, 0x04), v6buf.items[0]);
    try testing.expectEqual(@as(usize, 17), v6buf.items.len);
    try testing.expectEqual(@as(u8, 0x01), v6buf.items[16]);
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

test "Trojan pending read flags buffered TLS or socket bytes" {
    // hasPendingBufferedRead is the pure decision behind hasPendingRead():
    // a relay must drain either buffer before yielding the connection.
    try testing.expect(Client.hasPendingBufferedRead(1, 0));
    try testing.expect(Client.hasPendingBufferedRead(0, 1));
    try testing.expect(Client.hasPendingBufferedRead(1, 1));
    try testing.expect(!Client.hasPendingBufferedRead(0, 0));
}

test "Trojan read uses TLS buffered short-read semantics" {
    // Drive readTlsApplicationData (the helper read() delegates to) against an
    // injectable fixed reader: it returns up to out.len buffered bytes per call
    // (a short read), advancing the reader, never blocking for a full fill.
    var r = std.Io.Reader.fixed("abcdef");

    var out: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try Client.readTlsApplicationData(&r, &out));
    try testing.expectEqualStrings("abcd", &out);

    // Second call returns the remainder even though the destination is larger.
    var rest: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try Client.readTlsApplicationData(&r, &rest));
    try testing.expectEqualStrings("ef", rest[0..2]);

    // Stream fully drained -> clean EOF (0), not an error.
    try testing.expectEqual(@as(usize, 0), try Client.readTlsApplicationData(&r, &rest));
}

test "Trojan readTlsApplicationData reports drained/empty stream as EOF" {
    // An empty fixed reader yields error.EndOfStream from fillMore, which
    // readTlsApplicationData translates into a clean 0-length read. This 0-return
    // is the mechanism read() relies on: when the underlying tls.Client surfaces
    // error.TlsConnectionTruncated (TCP dropped mid-record without close_notify),
    // read() maps it to EOF too. That TlsConnectionTruncated->0 translation needs
    // a live tls.Client and stays integration-only; the EOF semantics it builds on
    // are pinned here.
    var empty = std.Io.Reader.fixed("");
    var out: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try Client.readTlsApplicationData(&empty, &out));

    // Zero-length destination short-circuits without touching the reader.
    var r = std.Io.Reader.fixed("xyz");
    try testing.expectEqual(@as(usize, 0), try Client.readTlsApplicationData(&r, out[0..0]));
    // ...and the reader is left untouched: the next real read still sees "xyz".
    try testing.expectEqual(@as(usize, 3), try Client.readTlsApplicationData(&r, &out));
    try testing.expectEqualStrings("xyz", out[0..3]);
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

test "Trojan caOption uses real bundle when verification is enabled" {
    var lock: std.Io.RwLock = .init;
    var empty_bundle: Certificate.Bundle = .empty;
    // Tag-only inspection: no rescan/allocation, so nothing to deinit.
    const dummy_bundle: Client.CaOptions = .{ .bundle = .{
        .gpa = testing.allocator,
        .io = compat.io(),
        .lock = &lock,
        .bundle = &empty_bundle,
    } };

    const result = Client.caOption(false, dummy_bundle);
    try testing.expectEqual(std.meta.Tag(Client.CaOptions).bundle, std.meta.activeTag(result));
}

test "Trojan caOption disables verification only when skip_cert_verify is set" {
    var lock: std.Io.RwLock = .init;
    var empty_bundle: Certificate.Bundle = .empty;
    const dummy_bundle: Client.CaOptions = .{ .bundle = .{
        .gpa = testing.allocator,
        .io = compat.io(),
        .lock = &lock,
        .bundle = &empty_bundle,
    } };

    const result = Client.caOption(true, dummy_bundle);
    try testing.expectEqual(std.meta.Tag(Client.CaOptions).no_verification, std.meta.activeTag(result));
}

test "Trojan buildRequest emits exact wire frame for IPv4 target" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try client.buildRequest(&buf, .connect, "192.168.1.1", 443);

    // password_hash(56)
    try testing.expectEqualSlices(u8, &client.password_hash, buf.items[0..56]);
    // CRLF
    try testing.expectEqualSlices(u8, "\r\n", buf.items[56..58]);
    // command CONNECT
    try testing.expectEqual(@as(u8, 0x01), buf.items[58]);
    // ATYP IPv4 + 4-byte address
    try testing.expectEqual(@as(u8, 0x01), buf.items[59]);
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, buf.items[60..64]);
    // port 443 big-endian
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0xBB }, buf.items[64..66]);
    // trailing CRLF
    try testing.expectEqualSlices(u8, "\r\n", buf.items[66..68]);
    try testing.expectEqual(@as(usize, 68), buf.items.len);
}

test "Trojan buildRequest emits exact wire frame for IPv6 target" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try client.buildRequest(&buf, .connect, "2001:db8::1", 8080);

    // password_hash(56) + CRLF + command
    try testing.expectEqualSlices(u8, &client.password_hash, buf.items[0..56]);
    try testing.expectEqualSlices(u8, "\r\n", buf.items[56..58]);
    try testing.expectEqual(@as(u8, 0x01), buf.items[58]);
    // ATYP IPv6 + 16-byte parsed address
    try testing.expectEqual(@as(u8, 0x04), buf.items[59]);
    var expected_ipv6: [16]u8 = undefined;
    try testing.expect(parseIpv6("2001:db8::1", &expected_ipv6));
    try testing.expectEqualSlices(u8, &expected_ipv6, buf.items[60..76]);
    // port 8080 big-endian
    try testing.expectEqualSlices(u8, &[_]u8{ 0x1F, 0x90 }, buf.items[76..78]);
    // trailing CRLF
    try testing.expectEqualSlices(u8, "\r\n", buf.items[78..80]);
    try testing.expectEqual(@as(usize, 80), buf.items.len);
}

test "Trojan buildRequest emits exact wire frame for domain target" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try client.buildRequest(&buf, .connect, "example.com", 80);

    // password_hash(56) + CRLF + command
    try testing.expectEqualSlices(u8, &client.password_hash, buf.items[0..56]);
    try testing.expectEqualSlices(u8, "\r\n", buf.items[56..58]);
    try testing.expectEqual(@as(u8, 0x01), buf.items[58]);
    // ATYP domain + length byte + host bytes
    try testing.expectEqual(@as(u8, 0x03), buf.items[59]);
    try testing.expectEqual(@as(u8, 0x0B), buf.items[60]);
    try testing.expectEqualSlices(u8, "example.com", buf.items[61..72]);
    // port 80 big-endian
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x50 }, buf.items[72..74]);
    // trailing CRLF
    try testing.expectEqualSlices(u8, "\r\n", buf.items[74..76]);
    try testing.expectEqual(@as(usize, 76), buf.items.len);
}
