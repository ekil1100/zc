const std = @import("std");

/// HKDF-SHA1 for Shadowsocks AEAD subkey derivation
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HkdfSha1 = std.crypto.kdf.hkdf.Hkdf(HmacSha1);

/// Shadowsocks AEAD 加密支持
/// 支持：AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305
pub const CipherType = enum {
    aes_128_gcm,
    aes_256_gcm,
    chacha20_poly1305,
    chacha20_ietf_poly1305,

    pub fn keyLen(self: CipherType) usize {
        return switch (self) {
            .aes_128_gcm => 16,
            .aes_256_gcm, .chacha20_poly1305, .chacha20_ietf_poly1305 => 32,
        };
    }

    /// Salt length equals key length in Shadowsocks AEAD
    pub fn saltLen(self: CipherType) usize {
        return self.keyLen();
    }
};

/// Shadowsocks 流封装（AEAD Chunk）
pub const AeadStream = struct {
    cipher: AeadCipher,
    enc_nonce: [12]u8 = std.mem.zeroes([12]u8),
    dec_nonce: [12]u8 = std.mem.zeroes([12]u8),

    pub const AeadCipher = union(enum) {
        aes_128_gcm: [16]u8,
        aes_256_gcm: [32]u8,
        chacha20_poly1305: [32]u8,

        pub fn fromPassword(cipher_type: CipherType, password: []const u8) !AeadCipher {
            // 使用 EVP_BytesToKey (MD5) - Shadowsocks 标准
            switch (cipher_type) {
                .aes_128_gcm => {
                    const key = evpBytesToKeyMd5(password, 16);
                    return .{ .aes_128_gcm = key };
                },
                .aes_256_gcm => {
                    const key = evpBytesToKeyMd5(password, 32);
                    return .{ .aes_256_gcm = key };
                },
                .chacha20_poly1305, .chacha20_ietf_poly1305 => {
                    const key = evpBytesToKeyMd5(password, 32);
                    return .{ .chacha20_poly1305 = key };
                },
            }
        }

        /// Derive per-session subkey using HKDF-SHA1(salt, master_key, "ss-subkey")
        pub fn init(cipher_type: CipherType, password: []const u8, salt: []const u8) !AeadCipher {
            // Step 1: Master key from password via EVP_BytesToKey
            const klen = cipher_type.keyLen();
            const master_key = evpBytesToKeyMd5(password, klen);

            // Step 2: Derive per-session subkey via HKDF-SHA1
            const prk = HkdfSha1.extract(salt, master_key[0..klen]);
            var session_key: [32]u8 = undefined;
            HkdfSha1.expand(session_key[0..klen], "ss-subkey", prk);

            return switch (cipher_type) {
                .aes_128_gcm => .{ .aes_128_gcm = session_key[0..16].* },
                .aes_256_gcm => .{ .aes_256_gcm = session_key[0..32].* },
                .chacha20_poly1305, .chacha20_ietf_poly1305 => .{ .chacha20_poly1305 = session_key[0..32].* },
            };
        }

        pub fn tagLen(self: AeadCipher) usize {
            _ = self;
            return 16;
        }

        pub fn encrypt(self: AeadCipher, nonce: [12]u8, plaintext: []const u8, ciphertext: []u8, tag: []u8) void {
            switch (self) {
                .aes_128_gcm => |key| {
                    std.crypto.aead.aes_gcm.Aes128Gcm.encrypt(ciphertext, tag[0..16], plaintext, &[_]u8{}, nonce, key);
                },
                .aes_256_gcm => |key| {
                    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(ciphertext, tag[0..16], plaintext, &[_]u8{}, nonce, key);
                },
                .chacha20_poly1305 => |key| {
                    std.crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(ciphertext, tag[0..16], plaintext, &[_]u8{}, nonce, key);
                },
            }
        }

        pub fn decrypt(self: AeadCipher, nonce: [12]u8, ciphertext: []const u8, tag: []const u8, plaintext: []u8) !void {
            switch (self) {
                .aes_128_gcm => |key| {
                    var tag_arr: [16]u8 = undefined;
                    @memcpy(&tag_arr, tag[0..16]);
                    try std.crypto.aead.aes_gcm.Aes128Gcm.decrypt(plaintext, ciphertext, tag_arr, &[_]u8{}, nonce, key);
                },
                .aes_256_gcm => |key| {
                    var tag_arr: [16]u8 = undefined;
                    @memcpy(&tag_arr, tag[0..16]);
                    try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(plaintext, ciphertext, tag_arr, &[_]u8{}, nonce, key);
                },
                .chacha20_poly1305 => |key| {
                    var tag_arr: [16]u8 = undefined;
                    @memcpy(&tag_arr, tag[0..16]);
                    try std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(plaintext, ciphertext, tag_arr, &[_]u8{}, nonce, key);
                },
            }
        }
    };

    /// Initialize with HKDF-derived per-session subkey (for actual connections)
    pub fn init(cipher_type: CipherType, password: []const u8, salt: []const u8) !AeadStream {
        const cipher = try AeadCipher.init(cipher_type, password, salt);
        return .{
            .cipher = cipher,
        };
    }

    /// 加密一块数据（Shadowsocks AEAD chunk）
    /// chunk 格式: [len (2 bytes encrypted + 16 byte tag)][payload (n bytes encrypted + 16 byte tag)]
    pub fn encryptChunk(self: *AeadStream, payload: []const u8, out: []u8) !usize {
        const tag_len = self.cipher.tagLen();

        // 加密长度 (2 bytes)
        const len_bytes = [2]u8{
            @intCast(payload.len >> 8),
            @intCast(payload.len & 0xFF),
        };

        self.cipher.encrypt(self.enc_nonce, &len_bytes, out[0..2], out[2 .. 2 + tag_len]);
        incrementNonce(&self.enc_nonce);

        // 加密 payload
        const payload_out = out[2 + tag_len ..];
        self.cipher.encrypt(self.enc_nonce, payload, payload_out[0..payload.len], payload_out[payload.len .. payload.len + tag_len]);
        incrementNonce(&self.enc_nonce);

        return 2 + tag_len + payload.len + tag_len;
    }

    /// 解密长度头
    pub fn decryptLen(self: *AeadStream, enc_len: []const u8) !u16 {
        const tag_len = self.cipher.tagLen();
        if (enc_len.len != 2 + tag_len) return error.InvalidLength;

        var len_bytes: [2]u8 = undefined;
        try self.cipher.decrypt(self.dec_nonce, enc_len[0..2], enc_len[2 .. 2 + tag_len], &len_bytes);
        incrementNonce(&self.dec_nonce);

        return (@as(u16, len_bytes[0]) << 8) | len_bytes[1];
    }

    /// 解密 payload
    pub fn decryptPayload(self: *AeadStream, enc_payload: []const u8, out: []u8) !void {
        const tag_len = self.cipher.tagLen();
        if (enc_payload.len < tag_len) return error.InvalidLength;

        const payload_len = enc_payload.len - tag_len;
        try self.cipher.decrypt(self.dec_nonce, enc_payload[0..payload_len], enc_payload[payload_len..], out[0..payload_len]);
        incrementNonce(&self.dec_nonce);
    }

    fn incrementNonce(nonce: *[12]u8) void {
        var i: usize = 0;
        while (i < 12) : (i += 1) {
            nonce[i] +%= 1;
            if (nonce[i] != 0) break;
        }
    }
};

/// EVP_BytesToKey using MD5 (Shadowsocks standard)
fn evpBytesToKeyMd5(password: []const u8, key_len: usize) [32]u8 {
    var key: [32]u8 = undefined;
    var derived: [16]u8 = undefined;

    var offset: usize = 0;
    var count: usize = 0;

    while (offset < key_len) {
        var md5 = std.crypto.hash.Md5.init(.{});
        if (count > 0) {
            md5.update(derived[0..16]);
        }
        md5.update(password);
        md5.final(&derived);

        const copy_len = @min(16, key_len - offset);
        @memcpy(key[offset .. offset + copy_len], derived[0..copy_len]);
        offset += copy_len;
        count += 1;
    }

    return key;
}

/// 从字符串解析 cipher 类型
pub fn parseCipherType(s: []const u8) ?CipherType {
    if (std.mem.eql(u8, s, "aes-128-gcm")) return .aes_128_gcm;
    if (std.mem.eql(u8, s, "aes-256-gcm")) return .aes_256_gcm;
    if (std.mem.eql(u8, s, "chacha20-poly1305")) return .chacha20_poly1305;
    if (std.mem.eql(u8, s, "chacha20-ietf-poly1305")) return .chacha20_ietf_poly1305;
    return null;
}

/// Shadowsocks 地址编码
pub const Address = struct {
    host: []const u8,
    port: u16,

    pub fn encode(self: Address, buf: []u8) !usize {
        // Try to parse as IPv4 first
        if (std.net.Address.parseIp4(self.host, self.port)) |parsed| {
            const ip_bytes = std.mem.asBytes(&parsed.in.sa.addr);
            buf[0] = 0x01;
            @memcpy(buf[1..5], ip_bytes);
            buf[5] = @intCast(self.port >> 8);
            buf[6] = @intCast(self.port & 0xFF);
            return 7;
        } else |_| {}

        // Try IPv6
        if (std.net.Address.parseIp6(self.host, self.port)) |parsed| {
            buf[0] = 0x04;
            const bytes = std.mem.asBytes(&parsed.in6.sa.addr);
            @memcpy(buf[1..17], bytes);
            buf[17] = @intCast(self.port >> 8);
            buf[18] = @intCast(self.port & 0xFF);
            return 19;
        } else |_| {}

        // Domain
        buf[0] = 0x03;
        buf[1] = @intCast(self.host.len);
        @memcpy(buf[2 .. 2 + self.host.len], self.host);
        buf[2 + self.host.len] = @intCast(self.port >> 8);
        buf[2 + self.host.len + 1] = @intCast(self.port & 0xFF);
        return 2 + self.host.len + 2;
    }
};

test "evp bytes to key md5" {
    const key = evpBytesToKeyMd5("password", 16);
    _ = key;
}

test "chacha20-poly1305 encrypt/decrypt" {
    const password = "C7a6kndb";
    var salt: [32]u8 = undefined;
    std.crypto.random.bytes(&salt);

    var stream = try AeadStream.init(.chacha20_poly1305, password, &salt);

    const plaintext = "Hello, Shadowsocks!";
    var encrypted: [100]u8 = undefined;

    const enc_len = try stream.encryptChunk(plaintext, &encrypted);

    // Decrypt
    const tag_len = 16;
    const enc_len_hdr = encrypted[0 .. 2 + tag_len];
    const payload_len = try stream.decryptLen(enc_len_hdr);
    try std.testing.expectEqual(plaintext.len, payload_len);

    const enc_payload = encrypted[2 + tag_len .. enc_len];
    var decrypted: [100]u8 = undefined;
    try stream.decryptPayload(enc_payload, &decrypted);

    try std.testing.expectEqualStrings(plaintext, decrypted[0..payload_len]);
}
