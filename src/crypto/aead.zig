const std = @import("std");

/// HKDF-SHA1 for Shadowsocks AEAD subkey derivation
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HkdfSha1 = std.crypto.kdf.hkdf.Hkdf(HmacSha1);

pub const chunk_payload_size_max: usize = 0x3fff;

comptime {
    std.debug.assert(chunk_payload_size_max == std.math.maxInt(u14));
}

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

/// Owned opaque Shadowsocks 2017 AEAD datagram cryptography. Creation owns
/// exactly one allocation; sealing and opening remain allocation-free.
pub const AeadDatagram = opaque {
    const Impl = struct {
        allocator: std.mem.Allocator,
        cipher: CipherType,
        master_key: [32]u8,
    };

    const nonce = [_]u8{0} ** nonce_size;

    pub const wire_size_max: usize = 65_507;
    pub const tag_size: usize = 16;
    pub const nonce_size: usize = 12;

    pub const Error = error{
        DatagramTooLarge,
        OutputTooSmall,
        InvalidPacket,
        AuthenticationFailed,
        EntropyUnavailable,
        Canceled,
    };

    comptime {
        std.debug.assert(wire_size_max < std.math.maxInt(u16));
        std.debug.assert(tag_size == 16);
        std.debug.assert(nonce_size == 12);
    }

    fn impl(self: *AeadDatagram) *Impl {
        return @ptrCast(@alignCast(self));
    }

    fn constImpl(self: *const AeadDatagram) *const Impl {
        return @ptrCast(@alignCast(self));
    }

    pub fn create(
        allocator: std.mem.Allocator,
        cipher: CipherType,
        password: []const u8,
    ) std.mem.Allocator.Error!*AeadDatagram {
        const value = try allocator.create(Impl);
        value.* = .{
            .allocator = allocator,
            .cipher = cipher,
            .master_key = deriveMasterKey(cipher, password),
        };
        return @ptrCast(value);
    }

    pub fn destroy(self: *AeadDatagram) void {
        const value = self.impl();
        const allocator = value.allocator;
        std.crypto.secureZero(u8, &value.master_key);
        allocator.destroy(value);
    }

    /// Seals one independent datagram using fresh operating-system entropy.
    /// `output` may alias `plaintext`; the returned slice contains the complete wire packet.
    pub fn seal(
        self: *const AeadDatagram,
        io: std.Io,
        plaintext: []const u8,
        output: []u8,
    ) Error![]u8 {
        const wire_len = try self.sealedLength(plaintext.len);
        if (output.len < wire_len) return error.OutputTooSmall;

        var salt_buffer: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &salt_buffer);
        const salt_len = self.constImpl().cipher.saltLen();
        if (salt_len > salt_buffer.len) return error.InvalidPacket;
        const salt = salt_buffer[0..salt_len];
        try std.Io.randomSecure(io, salt);
        return self.sealWithSalt(plaintext, salt, output);
    }

    /// Opens one complete wire packet and reports authentication failure distinctly.
    /// `output` may alias `wire`; the returned slice contains only authenticated plaintext.
    pub fn open(
        self: *const AeadDatagram,
        wire: []const u8,
        output: []u8,
    ) Error![]u8 {
        if (wire.len > wire_size_max) return error.DatagramTooLarge;

        const salt_len = self.constImpl().cipher.saltLen();
        const overhead_len = std.math.add(usize, salt_len, tag_size) catch
            return error.InvalidPacket;
        if (wire.len < overhead_len) return error.InvalidPacket;
        const plaintext_len = wire.len - overhead_len;
        if (output.len < plaintext_len) return error.OutputTooSmall;

        const tag_start = wire.len - tag_size;
        const ciphertext_start = salt_len;
        const salt = wire[0..salt_len];
        const ciphertext = wire[ciphertext_start..tag_start];
        var tag: [tag_size]u8 = undefined;
        @memcpy(&tag, wire[tag_start..wire.len]);

        var subkey = self.deriveSubkey(salt);
        defer std.crypto.secureZero(u8, &subkey);
        const plaintext = output[0..plaintext_len];
        copyAliased(plaintext, ciphertext);
        try self.decrypt(plaintext, tag, subkey);
        return plaintext;
    }

    fn sealedLength(self: *const AeadDatagram, plaintext_len: usize) Error!usize {
        const salted_len = std.math.add(
            usize,
            self.constImpl().cipher.saltLen(),
            plaintext_len,
        ) catch return error.DatagramTooLarge;
        const wire_len = std.math.add(usize, salted_len, tag_size) catch
            return error.DatagramTooLarge;
        if (wire_len > wire_size_max) return error.DatagramTooLarge;
        return wire_len;
    }

    fn sealWithSalt(
        self: *const AeadDatagram,
        plaintext: []const u8,
        salt: []const u8,
        output: []u8,
    ) Error![]u8 {
        const salt_len = self.constImpl().cipher.saltLen();
        if (salt.len != salt_len) return error.InvalidPacket;
        const wire_len = try self.sealedLength(plaintext.len);
        if (output.len < wire_len) return error.OutputTooSmall;

        const ciphertext_start = salt_len;
        const ciphertext_end = std.math.add(
            usize,
            ciphertext_start,
            plaintext.len,
        ) catch return error.DatagramTooLarge;
        const tag_end = std.math.add(usize, ciphertext_end, tag_size) catch
            return error.DatagramTooLarge;
        if (tag_end != wire_len) return error.DatagramTooLarge;

        const ciphertext = output[ciphertext_start..ciphertext_end];
        copyAliased(ciphertext, plaintext);
        @memcpy(output[0..salt_len], salt);

        var subkey = self.deriveSubkey(salt);
        defer std.crypto.secureZero(u8, &subkey);
        const tag: *[tag_size]u8 = output[ciphertext_end..tag_end][0..tag_size];
        self.encrypt(ciphertext, tag, subkey);
        return output[0..wire_len];
    }

    fn deriveSubkey(self: *const AeadDatagram, salt: []const u8) [32]u8 {
        const value = self.constImpl();
        const key_len = value.cipher.keyLen();
        var prk = HkdfSha1.extract(salt, value.master_key[0..key_len]);
        defer std.crypto.secureZero(u8, &prk);
        var subkey = [_]u8{0} ** 32;
        HkdfSha1.expand(subkey[0..key_len], "ss-subkey", prk);
        return subkey;
    }

    fn encrypt(
        self: *const AeadDatagram,
        text: []u8,
        tag: *[tag_size]u8,
        subkey: [32]u8,
    ) void {
        switch (self.constImpl().cipher) {
            .aes_128_gcm => std.crypto.aead.aes_gcm.Aes128Gcm.encrypt(
                text,
                tag,
                text,
                "",
                nonce,
                subkey[0..16].*,
            ),
            .aes_256_gcm => std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(
                text,
                tag,
                text,
                "",
                nonce,
                subkey,
            ),
            .chacha20_poly1305, .chacha20_ietf_poly1305 => {
                const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
                ChaCha20Poly1305.encrypt(
                    text,
                    tag,
                    text,
                    "",
                    nonce,
                    subkey,
                );
            },
        }
    }

    fn decrypt(
        self: *const AeadDatagram,
        text: []u8,
        tag: [tag_size]u8,
        subkey: [32]u8,
    ) Error!void {
        switch (self.constImpl().cipher) {
            .aes_128_gcm => std.crypto.aead.aes_gcm.Aes128Gcm.decrypt(
                text,
                text,
                tag,
                "",
                nonce,
                subkey[0..16].*,
            ) catch return error.AuthenticationFailed,
            .aes_256_gcm => std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(
                text,
                text,
                tag,
                "",
                nonce,
                subkey,
            ) catch return error.AuthenticationFailed,
            .chacha20_poly1305, .chacha20_ietf_poly1305 => {
                const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
                ChaCha20Poly1305.decrypt(
                    text,
                    text,
                    tag,
                    "",
                    nonce,
                    subkey,
                ) catch return error.AuthenticationFailed;
            },
        }
    }
};

fn deriveMasterKey(cipher: CipherType, password: []const u8) [32]u8 {
    return evpBytesToKeyMd5(password, cipher.keyLen());
}

fn copyAliased(destination: []u8, source: []const u8) void {
    if (destination.len == 0) return;
    if (@intFromPtr(destination.ptr) < @intFromPtr(source.ptr)) {
        std.mem.copyForwards(u8, destination, source);
    } else if (@intFromPtr(destination.ptr) > @intFromPtr(source.ptr)) {
        std.mem.copyBackwards(u8, destination, source);
    }
}

/// Shadowsocks 流封装（AEAD Chunk）
pub const AeadStream = struct {
    cipher: AeadCipher,
    enc_nonce: [12]u8 = std.mem.zeroes([12]u8),
    dec_nonce: [12]u8 = std.mem.zeroes([12]u8),

    pub const AeadCipher = union(enum) {
        aes_128_gcm: [16]u8,
        aes_256_gcm: [32]u8,
        chacha20_poly1305: [32]u8,

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

        const payload_len = (@as(u16, len_bytes[0]) << 8) | len_bytes[1];
        // Shadowsocks AEAD spec caps a single chunk payload at 0x3FFF (16383) bytes.
        // Reject larger declared lengths to prevent an upstream from amplifying memory.
        if (payload_len > chunk_payload_size_max) return error.ChunkTooLarge;
        return payload_len;
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
    var key = [_]u8{0} ** 32;
    var derived: [16]u8 = undefined;
    defer std.crypto.secureZero(u8, &derived);

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

fn decodeTestHex(comptime hex: []const u8) ![hex.len / 2]u8 {
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    return bytes;
}

test "EVP BytesToKey derives the independent MD5 password vector" {
    const key = evpBytesToKeyMd5("password", 32);
    const expected = try decodeTestHex(
        "5f4dcc3b5aa765d61d8327deb882cf992b95990a9151374abd8ff8c5a7a0fe08",
    );
    try std.testing.expectEqualSlices(u8, &expected, &key);
}

fn expectDatagramVector(
    comptime cipher_type: CipherType,
    comptime salt_hex: []const u8,
    comptime wire_hex: []const u8,
) !void {
    const plaintext = try decodeTestHex(
        "030b6578616d706c652e636f6d003568656c6c6f",
    );
    const salt = try decodeTestHex(salt_hex);
    const expected_wire = try decodeTestHex(wire_hex);
    try std.testing.expectEqual(cipher_type.saltLen(), salt.len);

    const datagram = try AeadDatagram.create(
        std.testing.allocator,
        cipher_type,
        "password",
    );
    defer datagram.destroy();
    var wire_buffer: [expected_wire.len]u8 = undefined;
    const wire = try datagram.sealWithSalt(&plaintext, &salt, &wire_buffer);
    try std.testing.expectEqualSlices(u8, &expected_wire, wire);

    var plaintext_buffer: [plaintext.len]u8 = undefined;
    const opened = try datagram.open(&expected_wire, &plaintext_buffer);
    try std.testing.expectEqualSlices(u8, &plaintext, opened);
}

test "AeadDatagram AES-128-GCM matches the literal wire vector" {
    // A literal external vector fixes EVP, HKDF, nonce, AAD, tag, and wire layout.
    try expectDatagramVector(
        .aes_128_gcm,
        "000102030405060708090a0b0c0d0e0f",
        "000102030405060708090a0b0c0d0e0f" ++
            "5f258e0c61142e2adf12b78447f4379ccad5b5fe1ca235e4cdd27f71ed4e3d816cc95508",
    );
}

test "AeadDatagram AES-256-GCM matches the literal wire vector" {
    // A separate literal catches accidental AES-128 key or salt sizing.
    try expectDatagramVector(
        .aes_256_gcm,
        "000102030405060708090a0b0c0d0e0f" ++
            "101112131415161718191a1b1c1d1e1f",
        "000102030405060708090a0b0c0d0e0f" ++
            "101112131415161718191a1b1c1d1e1f" ++
            "7daef6db84b74235355de16af464f6bc58495b60b70e884c594f6713a10d21f69fb5827d",
    );
}

test "AeadDatagram ChaCha20-IETF-Poly1305 matches the literal wire vector" {
    // A separate literal distinguishes the IETF nonce construction from legacy ChaCha.
    try expectDatagramVector(
        .chacha20_ietf_poly1305,
        "000102030405060708090a0b0c0d0e0f" ++
            "101112131415161718191a1b1c1d1e1f",
        "000102030405060708090a0b0c0d0e0f" ++
            "101112131415161718191a1b1c1d1e1f" ++
            "ae43eb899fd70234f3c8006c9c954de34230869295a6e490a7c06b49671a7dfa85b679c5",
    );
}

test "AeadDatagram rejects salt ciphertext and tag corruption" {
    // Each authenticated wire region is flipped independently against a literal packet.
    const expected_wire = try decodeTestHex(
        "000102030405060708090a0b0c0d0e0f" ++
            "5f258e0c61142e2adf12b78447f4379ccad5b5fe1ca235e4cdd27f71ed4e3d816cc95508",
    );
    const flip_indexes = [_]usize{ 0, 16, expected_wire.len - 1 };
    const datagram = try AeadDatagram.create(
        std.testing.allocator,
        .aes_128_gcm,
        "password",
    );
    defer datagram.destroy();

    for (flip_indexes) |flip_index| {
        var corrupted = expected_wire;
        corrupted[flip_index] ^= 0x01;
        var plaintext: [20]u8 = undefined;
        try std.testing.expectError(
            error.AuthenticationFailed,
            datagram.open(&corrupted, &plaintext),
        );
    }
}

test "AeadDatagram rejects truncated packets before authentication" {
    // Inputs shorter than salt plus tag cannot contain a complete AEAD packet.
    const wire = try decodeTestHex(
        "000102030405060708090a0b0c0d0e0f" ++
            "5f258e0c61142e2adf12b78447f4379ccad5b5fe1ca235e4cdd27f71ed4e3d816cc95508",
    );
    const datagram = try AeadDatagram.create(
        std.testing.allocator,
        .aes_128_gcm,
        "password",
    );
    defer datagram.destroy();
    var plaintext: [20]u8 = undefined;

    try std.testing.expectError(error.InvalidPacket, datagram.open(wire[0..0], &plaintext));
    try std.testing.expectError(
        error.InvalidPacket,
        datagram.open(wire[0 .. 16 + AeadDatagram.tag_size - 1], &plaintext),
    );
}

fn expectDatagramWireLimit(comptime cipher_type: CipherType) !void {
    const salt_len = comptime cipher_type.saltLen();
    const plaintext_len_max = comptime AeadDatagram.wire_size_max -
        salt_len - AeadDatagram.tag_size;
    var plaintext: [plaintext_len_max + 1]u8 = @splat(0x5a);
    var salt: [salt_len]u8 = undefined;
    for (&salt, 0..) |*byte, index| byte.* = @intCast(index);

    const datagram = try AeadDatagram.create(
        std.testing.allocator,
        cipher_type,
        "password",
    );
    defer datagram.destroy();
    var wire: [AeadDatagram.wire_size_max]u8 = undefined;
    const sealed = try datagram.sealWithSalt(
        plaintext[0..plaintext_len_max],
        &salt,
        &wire,
    );
    try std.testing.expectEqual(AeadDatagram.wire_size_max, sealed.len);

    var opened: [plaintext_len_max]u8 = undefined;
    const result = try datagram.open(sealed, &opened);
    try std.testing.expectEqualSlices(u8, plaintext[0..plaintext_len_max], result);
    try std.testing.expectError(
        error.DatagramTooLarge,
        datagram.sealWithSalt(&plaintext, &salt, &wire),
    );
}

test "AeadDatagram enforces the 65507-byte wire limit for both salt sizes" {
    // Exact-limit packets work while one extra plaintext byte is rejected pre-slice.
    try expectDatagramWireLimit(.aes_128_gcm);
    try expectDatagramWireLimit(.aes_256_gcm);

    const datagram = try AeadDatagram.create(
        std.testing.allocator,
        .aes_128_gcm,
        "password",
    );
    defer datagram.destroy();
    var oversized_wire: [AeadDatagram.wire_size_max + 1]u8 = @splat(0);
    var empty_output: [0]u8 = .{};
    try std.testing.expectError(
        error.DatagramTooLarge,
        datagram.open(&oversized_wire, &empty_output),
    );
    try std.testing.expectError(
        error.DatagramTooLarge,
        datagram.sealedLength(std.math.maxInt(usize)),
    );
}

test "AeadDatagram accepts exact output and rejects a one-byte-short buffer" {
    // Both directions validate caller capacity before slicing or cryptography.
    const plaintext = try decodeTestHex(
        "030b6578616d706c652e636f6d003568656c6c6f",
    );
    const salt = try decodeTestHex("000102030405060708090a0b0c0d0e0f");
    const wire = try decodeTestHex(
        "000102030405060708090a0b0c0d0e0f" ++
            "5f258e0c61142e2adf12b78447f4379ccad5b5fe1ca235e4cdd27f71ed4e3d816cc95508",
    );
    const datagram = try AeadDatagram.create(
        std.testing.allocator,
        .aes_128_gcm,
        "password",
    );
    defer datagram.destroy();

    var exact_wire: [wire.len]u8 = undefined;
    _ = try datagram.sealWithSalt(&plaintext, &salt, &exact_wire);
    var short_wire: [wire.len - 1]u8 = undefined;
    try std.testing.expectError(
        error.OutputTooSmall,
        datagram.sealWithSalt(&plaintext, &salt, &short_wire),
    );

    var exact_plaintext: [plaintext.len]u8 = undefined;
    _ = try datagram.open(&wire, &exact_plaintext);
    var short_plaintext: [plaintext.len - 1]u8 = undefined;
    try std.testing.expectError(
        error.OutputTooSmall,
        datagram.open(&wire, &short_plaintext),
    );
}

test "AeadDatagram supports wire-buffer aliases in both directions" {
    // Moving plaintext around the salt prefix keeps caller-owned in-place buffers valid.
    const plaintext = try decodeTestHex(
        "030b6578616d706c652e636f6d003568656c6c6f",
    );
    const salt = try decodeTestHex("000102030405060708090a0b0c0d0e0f");
    const expected_wire = try decodeTestHex(
        "000102030405060708090a0b0c0d0e0f" ++
            "5f258e0c61142e2adf12b78447f4379ccad5b5fe1ca235e4cdd27f71ed4e3d816cc95508",
    );
    const datagram = try AeadDatagram.create(
        std.testing.allocator,
        .aes_128_gcm,
        "password",
    );
    defer datagram.destroy();

    var seal_buffer: [expected_wire.len]u8 = undefined;
    @memcpy(seal_buffer[0..plaintext.len], &plaintext);
    const sealed = try datagram.sealWithSalt(
        seal_buffer[0..plaintext.len],
        &salt,
        &seal_buffer,
    );
    try std.testing.expectEqualSlices(u8, &expected_wire, sealed);

    var open_buffer = expected_wire;
    const opened = try datagram.open(&open_buffer, &open_buffer);
    try std.testing.expectEqualSlices(u8, &plaintext, opened);
}

test "AeadDatagram resets the nonce for every independent packet" {
    // Reusing a test salt must be deterministic and cannot inherit packet state.
    const plaintext = try decodeTestHex(
        "030b6578616d706c652e636f6d003568656c6c6f",
    );
    const salt = try decodeTestHex(
        "000102030405060708090a0b0c0d0e0f" ++
            "101112131415161718191a1b1c1d1e1f",
    );
    const datagram = try AeadDatagram.create(
        std.testing.allocator,
        .chacha20_ietf_poly1305,
        "password",
    );
    defer datagram.destroy();
    var first: [salt.len + plaintext.len + AeadDatagram.tag_size]u8 = undefined;
    var second: [first.len]u8 = undefined;

    const first_wire = try datagram.sealWithSalt(&plaintext, &salt, &first);
    const second_wire = try datagram.sealWithSalt(&plaintext, &salt, &second);
    try std.testing.expectEqualSlices(u8, first_wire, second_wire);
}

test "AeadDatagram legacy ChaCha name aliases the IETF wire" {
    // The accepted legacy configuration name must not select a legacy nonce format.
    const plaintext = try decodeTestHex(
        "030b6578616d706c652e636f6d003568656c6c6f",
    );
    const salt = try decodeTestHex(
        "000102030405060708090a0b0c0d0e0f" ++
            "101112131415161718191a1b1c1d1e1f",
    );
    const legacy = try AeadDatagram.create(
        std.testing.allocator,
        .chacha20_poly1305,
        "password",
    );
    defer legacy.destroy();
    const ietf = try AeadDatagram.create(
        std.testing.allocator,
        .chacha20_ietf_poly1305,
        "password",
    );
    defer ietf.destroy();
    var legacy_wire: [salt.len + plaintext.len + AeadDatagram.tag_size]u8 = undefined;
    var ietf_wire: [legacy_wire.len]u8 = undefined;

    const sealed_legacy = try legacy.sealWithSalt(&plaintext, &salt, &legacy_wire);
    const sealed_ietf = try ietf.sealWithSalt(&plaintext, &salt, &ietf_wire);
    try std.testing.expectEqualSlices(u8, sealed_ietf, sealed_legacy);
}

test "AeadDatagram public seal round trips with secure entropy" {
    // The production entry point obtains its own salt and emits an openable packet.
    const plaintext = "authenticated payload";
    const datagram = try AeadDatagram.create(
        std.testing.allocator,
        .aes_128_gcm,
        "password",
    );
    defer datagram.destroy();
    var wire_buffer: [16 + plaintext.len + AeadDatagram.tag_size]u8 = undefined;
    const wire = try datagram.seal(std.testing.io, plaintext, &wire_buffer);
    try std.testing.expectEqual(wire_buffer.len, wire.len);

    var plaintext_buffer: [plaintext.len]u8 = undefined;
    const opened = try datagram.open(wire, &plaintext_buffer);
    try std.testing.expectEqualStrings(plaintext, opened);
}

test "AeadDatagram public seal reports unavailable secure entropy" {
    // std.Io.failing has weak zero random bytes but no secure entropy source.
    const plaintext = "authenticated payload";
    const datagram = try AeadDatagram.create(
        std.testing.allocator,
        .aes_128_gcm,
        "password",
    );
    defer datagram.destroy();
    var output: [16 + plaintext.len + AeadDatagram.tag_size]u8 = @splat(0xa5);

    try std.testing.expectError(
        error.EntropyUnavailable,
        datagram.seal(std.Io.failing, plaintext, &output),
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0xa5} ** output.len),
        &output,
    );
}

test "AeadDatagram create and destroy own exactly one allocation" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        const datagram = try AeadDatagram.create(
            tracking.allocator(),
            .aes_256_gcm,
            "password",
        );
        defer datagram.destroy();
        try std.testing.expectEqual(@as(usize, 1), tracking.allocations);
        try std.testing.expectEqual(@as(usize, 0), tracking.deallocations);
    }
    try std.testing.expectEqual(@as(usize, 1), tracking.deallocations);
    try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        AeadDatagram.create(failing.allocator(), .aes_256_gcm, "password"),
    );
}

test "chacha20-poly1305 encrypt/decrypt" {
    const password = "C7a6kndb";
    const salt = [_]u8{0x6b} ** 32;

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

test "decryptLen rejects chunk length above Shadowsocks 0x3FFF cap" {
    const password = "C7a6kndb";
    const salt = [_]u8{0x4d} ** 32;

    // Build an encrypted length header declaring 0x4000 (> 0x3FFF) using the
    // same nonce/key the decryptor will use on its first chunk.
    var enc = try AeadStream.init(.chacha20_poly1305, password, &salt);
    var dec = try AeadStream.init(.chacha20_poly1305, password, &salt);

    const tag_len = enc.cipher.tagLen();
    const declared: u16 = 0x4000;
    const len_bytes = [2]u8{ @intCast(declared >> 8), @intCast(declared & 0xFF) };

    var hdr: [2 + 16]u8 = undefined;
    enc.cipher.encrypt(enc.enc_nonce, &len_bytes, hdr[0..2], hdr[2 .. 2 + tag_len]);

    try std.testing.expectError(error.ChunkTooLarge, dec.decryptLen(hdr[0 .. 2 + tag_len]));
}
