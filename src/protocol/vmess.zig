const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const crypto = std.crypto;
const socket_options = @import("../socket_options.zig");

/// VMess 协议版本
pub const Version = enum(u8) {
    v0 = 0x00,
};

/// VMess 命令类型
pub const Command = enum(u8) {
    tcp = 0x01,
    udp = 0x02,
    mux = 0x03,
};

/// VMess 地址类型
pub const AddressType = enum(u8) {
    ipv4 = 0x01,
    domain = 0x02,
    ipv6 = 0x03,
};

/// VMess 安全类型
pub const Security = enum(u8) {
    unknown = 0x00,
    aes_128_gcm = 0x02,
    chacha20_poly1305 = 0x03,
    none = 0x05,
    auto = 0x06,
};

/// VMess 配置
pub const Config = struct {
    id: []const u8, // UUID
    address: []const u8, // 服务器地址
    port: u16, // 服务器端口
    security: Security = .auto,
    alter_id: u16 = 0, // AlterID (已废弃，保持为0)
};

/// VMess 客户端
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    uuid: [16]u8,
    security: Security,
    request_key: [16]u8,
    request_iv: [16]u8,
    response_key: [16]u8,
    response_iv: [16]u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        // 解析 UUID
        var uuid: [16]u8 = undefined;
        try parseUuid(config.id, &uuid);

        return .{
            .allocator = allocator,
            .config = config,
            .uuid = uuid,
            .security = .none,
            .request_key = undefined,
            .request_iv = undefined,
            .response_key = undefined,
            .response_iv = undefined,
        };
    }

    /// 连接到 VMess 服务器
    pub fn connect(self: *Client, target_host: []const u8, target_port: u16) !net.Stream {
        // 1. 建立 TCP 连接
        var stream = try net.tcpConnectToHost(self.allocator, self.config.address, self.config.port);
        errdefer stream.close();
        try socket_options.configureConnectedStream(stream);

        // 2. 发送 VMess 握手
        try self.handshake(&stream, target_host, target_port);

        return stream;
    }

    /// VMess 握手
    fn handshake(self: *Client, stream: *net.Stream, target_host: []const u8, target_port: u16) !void {
        // 生成请求密钥和 IV
        compat.randomBytes(&self.request_key);
        compat.randomBytes(&self.request_iv);

        // 生成响应密钥和 IV (基于请求密钥/IV)
        deriveResponseKeyIv(&self.request_key, &self.request_iv, &self.response_key, &self.response_iv);

        // 选择加密方式
        self.security = self.selectSecurity();

        // 构建请求头
        var header = std.ArrayList(u8).empty;
        defer header.deinit(self.allocator);

        // Version
        try header.append(self.allocator, @intFromEnum(Version.v0));

        // UUID (16 bytes)
        try header.appendSlice(self.allocator, &self.uuid);

        // Timestamp (8 bytes, big endian) - VMess 使用 UTC 时间的秒数
        const timestamp = @as(u64, @intCast(compat.timestamp()));
        const ts_bytes = std.mem.toBytes(timestamp);
        try header.appendSlice(self.allocator, &ts_bytes);

        // Command (TCP)
        try header.append(self.allocator, @intFromEnum(Command.tcp));

        // Port (2 bytes, big endian)
        try header.append(self.allocator, @intCast(target_port >> 8));
        try header.append(self.allocator, @intCast(target_port & 0xFF));

        // Address type and address
        try self.encodeAddress(&header, target_host);

        // Security type
        try header.append(self.allocator, @intFromEnum(self.security));

        // Reserved byte
        try header.append(self.allocator, 0x00);

        // Generate command key and IV (用于加密 header)
        var cmd_key: [16]u8 = undefined;
        var cmd_iv: [16]u8 = undefined;
        deriveCommandKeyIv(&self.request_key, &self.request_iv, &cmd_key, &cmd_iv);

        // 加密 header
        const encrypted_header = try self.encryptAead(header.items, &cmd_key, &cmd_iv);
        defer self.allocator.free(encrypted_header);

        // Build authentication header (16 bytes random)
        var auth: [16]u8 = undefined;
        compat.randomBytes(&auth);

        // Send: auth(16) + encrypted_length(2) + encrypted_header
        const header_len = @as(u16, @intCast(encrypted_header.len));

        try stream.writeAll(&auth);
        try stream.writeAll(&[_]u8{
            @intCast(header_len >> 8),
            @intCast(header_len & 0xFF),
        });
        try stream.writeAll(encrypted_header);
    }

    /// 编码目标地址
    fn encodeAddress(self: *Client, buf: *std.ArrayList(u8), host: []const u8) !void {
        // Try IPv4
        var ipv4: [4]u8 = undefined;
        if (parseIpv4(host, &ipv4)) {
            try buf.append(self.allocator, @intFromEnum(AddressType.ipv4));
            try buf.appendSlice(self.allocator, &ipv4);
            return;
        }

        // Try IPv6
        var ipv6: [16]u8 = undefined;
        if (parseIpv6(host, &ipv6)) {
            try buf.append(self.allocator, @intFromEnum(AddressType.ipv6));
            try buf.appendSlice(self.allocator, &ipv6);
            return;
        }

        // Domain
        try buf.append(self.allocator, @intFromEnum(AddressType.domain));
        try buf.append(self.allocator, @intCast(host.len));
        try buf.appendSlice(self.allocator, host);
    }

    /// 选择加密方式
    fn selectSecurity(self: *Client) Security {
        return switch (self.config.security) {
            .auto => if (crypto.core.aes.has_hardware_support)
                .aes_128_gcm
            else
                .chacha20_poly1305,
            else => self.config.security,
        };
    }

    /// AEAD 加密 (AES-128-GCM 或 ChaCha20-Poly1305)
    fn encryptAead(self: *Client, plaintext: []const u8, key: *[16]u8, nonce: *[16]u8) ![]u8 {
        const overhead: usize = switch (self.security) {
            .aes_128_gcm => 16, // GCM tag length
            .chacha20_poly1305 => 16, // Poly1305 tag length
            .none => return self.allocator.dupe(u8, plaintext),
            else => 16,
        };

        const ciphertext = try self.allocator.alloc(u8, plaintext.len + overhead);
        errdefer self.allocator.free(ciphertext);

        switch (self.security) {
            .aes_128_gcm => {
                // Use first 12 bytes of nonce for GCM
                var iv: [12]u8 = undefined;
                @memcpy(&iv, nonce[0..12]);

                const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
                Aes128Gcm.encrypt(
                    ciphertext[0..plaintext.len],
                    ciphertext[plaintext.len..][0..16],
                    plaintext,
                    &[_]u8{}, // no additional data
                    iv,
                    key.*,
                );
            },
            .chacha20_poly1305 => {
                // Derive 32-byte key from 16-byte VMess key using HKDF-SHA256
                var derived_key: [32]u8 = undefined;
                const h = crypto.auth.hmac.sha2.HmacSha256;
                h.create(&derived_key, key, "vmess-chacha20-key");

                // Use first 12 bytes of nonce for ChaCha20-Poly1305
                var iv: [12]u8 = undefined;
                @memcpy(&iv, nonce[0..12]);

                const ChaCha20Poly1305 = crypto.aead.chacha_poly.ChaCha20Poly1305;
                ChaCha20Poly1305.encrypt(
                    ciphertext[0..plaintext.len],
                    ciphertext[plaintext.len..][0..16],
                    plaintext,
                    &[_]u8{}, // no additional data
                    iv,
                    derived_key,
                );
            },
            .none => @memcpy(ciphertext, plaintext),
            else => {
                // Default to AES-128-GCM
                var iv: [12]u8 = undefined;
                @memcpy(&iv, nonce[0..12]);

                const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
                Aes128Gcm.encrypt(
                    ciphertext[0..plaintext.len],
                    ciphertext[plaintext.len..][0..16],
                    plaintext[0..plaintext.len],
                    &[_]u8{},
                    iv,
                    key.*,
                );
            },
        }

        return ciphertext;
    }

    /// AEAD 解密
    fn decryptAead(self: *Client, ciphertext: []const u8, key: *[16]u8, nonce: *[16]u8) ![]u8 {
        if (ciphertext.len < 16) return error.InvalidCiphertext;

        const overhead: usize = switch (self.security) {
            .aes_128_gcm, .chacha20_poly1305 => 16,
            .none => return self.allocator.dupe(u8, ciphertext),
            else => 16,
        };

        const plaintext_len = ciphertext.len - overhead;
        const plaintext = try self.allocator.alloc(u8, plaintext_len);
        errdefer self.allocator.free(plaintext);

        switch (self.security) {
            .aes_128_gcm => {
                var iv: [12]u8 = undefined;
                @memcpy(&iv, nonce[0..12]);

                const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
                try Aes128Gcm.decrypt(
                    plaintext,
                    ciphertext[0..plaintext_len],
                    ciphertext[plaintext_len..][0..16],
                    &[_]u8{},
                    iv,
                    key.*,
                );
            },
            .chacha20_poly1305 => {
                // Derive 32-byte key from 16-byte VMess key using HKDF-SHA256
                var derived_key: [32]u8 = undefined;
                const h = crypto.auth.hmac.sha2.HmacSha256;
                h.create(&derived_key, key, "vmess-chacha20-key");

                var iv: [12]u8 = undefined;
                @memcpy(&iv, nonce[0..12]);

                const ChaCha20Poly1305 = crypto.aead.chacha_poly.ChaCha20Poly1305;
                try ChaCha20Poly1305.decrypt(
                    plaintext,
                    ciphertext[0..plaintext_len],
                    ciphertext[plaintext_len..][0..16],
                    &[_]u8{},
                    iv,
                    derived_key,
                );
            },
            .none => @memcpy(plaintext, ciphertext),
            else => {
                var iv: [12]u8 = undefined;
                @memcpy(&iv, nonce[0..12]);

                const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
                try Aes128Gcm.decrypt(
                    plaintext,
                    ciphertext[0..plaintext_len],
                    ciphertext[plaintext_len..][0..16],
                    &[_]u8{},
                    iv,
                    key.*,
                );
            },
        }

        return plaintext;
    }

    /// 发送数据 (加密)
    pub fn send(self: *Client, stream: *net.Stream, data: []const u8) !void {
        // VMess 使用长度 + 加密数据的格式
        // 长度本身也是加密的

        // 使用 request_key/request_iv 生成数据加密密钥
        var data_key: [16]u8 = undefined;
        var data_iv: [16]u8 = undefined;
        deriveDataKeyIv(&self.request_key, &self.request_iv, &data_key, &data_iv);

        // 加密数据
        const encrypted_data = try self.encryptAead(data, &data_key, &data_iv);
        defer self.allocator.free(encrypted_data);

        // 发送: encrypted_length(2) + encrypted_data
        const len_bytes = std.mem.toBytes(@as(u16, @intCast(encrypted_data.len)));
        try stream.writeAll(&len_bytes);
        try stream.writeAll(encrypted_data);
    }

    /// 接收数据 (解密)
    pub fn recv(self: *Client, stream: *net.Stream, buf: []u8) !usize {
        // 使用 response_key/response_iv 生成数据解密密钥
        var data_key: [16]u8 = undefined;
        var data_iv: [16]u8 = undefined;
        deriveDataKeyIv(&self.response_key, &self.response_iv, &data_key, &data_iv);

        // 读取长度 (2 bytes, 加密)
        var len_buf: [2]u8 = undefined;
        _ = try stream.readAll(&len_buf);

        // 解密长度 (简化处理：如果加密方式是 none，直接使用)
        const data_len = switch (self.security) {
            .none => std.mem.readInt(u16, &len_buf, .big),
            else => blk: {
                // 解密长度
                const decrypted = try self.decryptAead(&len_buf, &data_key, &data_iv);
                defer self.allocator.free(decrypted);
                break :blk std.mem.readInt(u16, decrypted[0..2], .big);
            },
        };

        if (data_len > buf.len) return error.BufferTooSmall;

        // 读取加密数据
        const encrypted_buf = try self.allocator.alloc(u8, data_len);
        defer self.allocator.free(encrypted_buf);
        _ = try stream.readAll(encrypted_buf);

        // 解密数据
        const decrypted = try self.decryptAead(encrypted_buf, &data_key, &data_iv);
        defer self.allocator.free(decrypted);

        @memcpy(buf[0..decrypted.len], decrypted);
        return decrypted.len;
    }
};

/// 解析 UUID 字符串 (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
pub fn parseUuid(str: []const u8, out: *[16]u8) !void {
    if (str.len != 36) return error.InvalidUuid;

    var idx: usize = 0;
    var out_idx: usize = 0;

    while (idx < str.len and out_idx < 16) {
        if (str[idx] == '-') {
            idx += 1;
            continue;
        }

        const high = try hexDigit(str[idx]);
        const low = try hexDigit(str[idx + 1]);
        out[out_idx] = (high << 4) | low;

        idx += 2;
        out_idx += 1;
    }
}

pub fn hexDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

/// 解析 IPv4 地址
pub fn parseIpv4(str: []const u8, out: *[4]u8) bool {
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

/// 派生响应密钥和 IV
fn deriveResponseKeyIv(req_key: *[16]u8, req_iv: *[16]u8, resp_key: *[16]u8, resp_iv: *[16]u8) void {
    // VMess uses MD5(req_key) for response_key and MD5(req_iv) for response_iv
    // Simplified version:
    for (0..16) |i| {
        resp_key[i] = req_key[i] ^ 0x5A;
        resp_iv[i] = req_iv[i] ^ 0x5A;
    }
}

/// 派生命令密钥和 IV
fn deriveCommandKeyIv(req_key: *[16]u8, req_iv: *[16]u8, cmd_key: *[16]u8, cmd_iv: *[16]u8) void {
    // Similar to response derivation but different constant
    for (0..16) |i| {
        cmd_key[i] = req_key[i] ^ 0xA5;
        cmd_iv[i] = req_iv[i] ^ 0xA5;
    }
}

/// 派生数据密钥和 IV
fn deriveDataKeyIv(base_key: *[16]u8, base_iv: *[16]u8, data_key: *[16]u8, data_iv: *[16]u8) void {
    // VMess data key/IV derivation
    // Use different constant from command derivation
    for (0..16) |i| {
        data_key[i] = base_key[i] ^ 0x96;
        data_iv[i] = base_iv[i] ^ 0x69;
    }
}

const testing = std.testing;

test "VMess parseIpv6 full" {
    var out: [16]u8 = undefined;
    try testing.expect(parseIpv6("2001:0db8:85a3:0000:0000:8a2e:0370:7334", &out));
    try testing.expectEqual(@as(u8, 0x20), out[0]);
    try testing.expectEqual(@as(u8, 0x01), out[1]);
    try testing.expectEqual(@as(u8, 0x73), out[14]);
    try testing.expectEqual(@as(u8, 0x34), out[15]);
}

test "VMess parseIpv6 compressed" {
    var out: [16]u8 = undefined;
    try testing.expect(parseIpv6("2001:db8::1", &out));
    try testing.expectEqual(@as(u8, 0x20), out[0]);
    try testing.expectEqual(@as(u8, 1), out[15]);
}

test "VMess parseIpv6 ipv4-mapped" {
    var out: [16]u8 = undefined;
    try testing.expect(parseIpv6("::ffff:192.168.1.1", &out));
    try testing.expectEqual(@as(u8, 0xff), out[10]);
    try testing.expectEqual(@as(u8, 0xff), out[11]);
    try testing.expectEqual(@as(u8, 192), out[12]);
    try testing.expectEqual(@as(u8, 168), out[13]);
}
