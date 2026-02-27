const std = @import("std");
const net = std.net;
const aead = @import("../../crypto/aead.zig");
pub const Address = aead.Address;
pub const connect_retry_attempts: usize = 3;
const retry_backoff_ms = [_]u64{ 200, 500, 1000 };

/// Shadowsocks Obfs configuration
pub const ObfsConfig = struct {
    mode: []const u8, // "http" or "tls"
    host: []const u8,
};

/// Shadowsocks 出站连接（AEAD 加密版）
pub const ShadowsocksClient = struct {
    allocator: std.mem.Allocator,
    server: []const u8,
    port: u16,
    password: []const u8,
    cipher_type: aead.CipherType,

    // Obfs plugin
    obfs: ?ObfsConfig = null,

    // Session state
    stream: ?net.Stream = null,
    enc_ctx: ?aead.AeadStream = null, // encrypt (client salt derived)
    dec_ctx: ?aead.AeadStream = null, // decrypt (server salt derived)

    // Obfs: need to strip HTTP response headers on first read
    obfs_first_response: bool = true,

    // Leftover data after stripping HTTP headers / server salt
    read_leftover: ?[]u8 = null,

    // Decrypted payload leftover when a chunk exceeds caller's buffer
    read_payload_leftover: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, server: []const u8, port: u16, password: []const u8, cipher: []const u8) !ShadowsocksClient {
        const cipher_type = aead.parseCipherType(cipher) orelse return error.UnsupportedCipher;
        return ShadowsocksClient{
            .allocator = allocator,
            .server = try allocator.dupe(u8, server),
            .port = port,
            .password = try allocator.dupe(u8, password),
            .cipher_type = cipher_type,
        };
    }

    pub fn initWithObfs(allocator: std.mem.Allocator, server: []const u8, port: u16, password: []const u8, cipher: []const u8, obfs_mode: []const u8, obfs_host: []const u8) !ShadowsocksClient {
        var client = try init(allocator, server, port, password, cipher);
        client.obfs = ObfsConfig{
            .mode = try allocator.dupe(u8, obfs_mode),
            .host = try allocator.dupe(u8, obfs_host),
        };
        return client;
    }

    pub fn deinit(self: *ShadowsocksClient) void {
        self.allocator.free(self.server);
        self.allocator.free(self.password);
        if (self.obfs) |o| {
            self.allocator.free(o.mode);
            self.allocator.free(o.host);
        }
        if (self.read_leftover) |lo| self.allocator.free(lo);
        if (self.read_payload_leftover) |lo| self.allocator.free(lo);
        if (self.stream) |s| s.close();
    }

    /// 连接到 Shadowsocks 服务器并发送目标地址
    pub fn connect(self: *ShadowsocksClient, target: Address) !net.Stream {
        std.debug.print("[SS] Connecting to {s}:{d} via SS\n", .{ self.server, self.port });

        // 1. DNS resolve (with retry/backoff)
        const upstream_addr = try self.resolveUpstreamAddressWithRetry();

        // 2. TCP connect (with retry/backoff)
        var stream = try self.connectUpstreamWithRetry(upstream_addr);
        std.debug.print("[SS] TCP connected\n", .{});

        // 3. Generate client salt (size = key length per SS AEAD spec)
        const salt_len = self.cipher_type.saltLen();
        var salt_buf: [32]u8 = undefined;
        const salt = salt_buf[0..salt_len];
        std.crypto.random.bytes(salt);

        std.debug.print("[SS] Client salt ({} bytes): ", .{salt_len});
        for (salt) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});

        // 4. Init encryption context with HKDF-derived session key
        self.enc_ctx = try aead.AeadStream.init(self.cipher_type, self.password, salt);

        // 5. Encode target address
        var addr_buf: [260]u8 = undefined;
        const addr_len = try target.encode(&addr_buf);

        // 6. Encrypt target address as first AEAD chunk
        var enc_buf: [300]u8 = undefined;
        const enc_len = try self.enc_ctx.?.encryptChunk(addr_buf[0..addr_len], &enc_buf);

        // 7. Send data (with or without obfs wrapping)
        if (self.obfs) |obfs_cfg| {
            if (std.mem.eql(u8, obfs_cfg.mode, "http")) {
                // simple-obfs HTTP: combine HTTP headers + salt + encrypted data
                try self.sendWithHttpObfs(&stream, obfs_cfg.host, salt, enc_buf[0..enc_len]);
                self.obfs_first_response = true;
            } else {
                return error.UnsupportedObfsMode;
            }
        } else {
            // No obfs: send salt + encrypted data directly
            try stream.writeAll(salt);
            try stream.writeAll(enc_buf[0..enc_len]);
        }

        std.debug.print("[SS] Handshake sent, target: {s}:{d}\n", .{ target.host, target.port });

        self.stream = stream;
        // dec_ctx will be initialized lazily on first read (needs server salt)
        self.dec_ctx = null;
        self.read_leftover = null;
        return stream;
    }

    pub fn retryBackoffMs(attempt_index: usize) u64 {
        if (attempt_index >= retry_backoff_ms.len) return retry_backoff_ms[retry_backoff_ms.len - 1];
        return retry_backoff_ms[attempt_index];
    }

    fn resolveUpstreamAddressWithRetry(self: *ShadowsocksClient) !net.Address {
        var last_err: anyerror = error.UpstreamDnsResolveFailed;

        var attempt: usize = 0;
        while (attempt < connect_retry_attempts) : (attempt += 1) {
            var addr_list = net.getAddressList(self.allocator, self.server, self.port) catch |err| {
                last_err = err;
                std.debug.print("[SS] Upstream DNS resolve failed: server={s}:{d} attempt={d}/{d} err={}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts, err });
                sleepBeforeRetry(attempt, connect_retry_attempts);
                continue;
            };
            defer addr_list.deinit();

            if (addr_list.addrs.len == 0) {
                last_err = error.HostNotFound;
                std.debug.print("[SS] Upstream DNS resolve returned no address: server={s}:{d} attempt={d}/{d}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts });
                sleepBeforeRetry(attempt, connect_retry_attempts);
                continue;
            }
            if (attempt > 0) {
                std.debug.print("[SS] Upstream DNS resolve recovered: server={s}:{d} attempt={d}/{d}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts });
            }
            return addr_list.addrs[0];
        }

        std.debug.print("[SS] Upstream DNS resolve failed after retries: server={s}:{d} attempts={d} last_err={}\n", .{ self.server, self.port, connect_retry_attempts, last_err });
        return error.UpstreamDnsResolveFailed;
    }

    fn connectUpstreamWithRetry(self: *ShadowsocksClient, addr: net.Address) !net.Stream {
        var last_err: anyerror = error.UpstreamTcpConnectFailed;

        var attempt: usize = 0;
        while (attempt < connect_retry_attempts) : (attempt += 1) {
            var stream = net.tcpConnectToAddress(addr) catch |err| {
                last_err = err;
                std.debug.print("[SS] Upstream TCP connect failed: server={s}:{d} attempt={d}/{d} err={}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts, err });
                sleepBeforeRetry(attempt, connect_retry_attempts);
                continue;
            };

            setSocketTimeouts(stream.handle, 15_000) catch |err| {
                stream.close();
                last_err = err;
                std.debug.print("[SS] Upstream socket timeout setup failed: server={s}:{d} attempt={d}/{d} err={}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts, err });
                sleepBeforeRetry(attempt, connect_retry_attempts);
                continue;
            };

            if (attempt > 0) {
                std.debug.print("[SS] Upstream TCP connect recovered: server={s}:{d} attempt={d}/{d}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts });
            }
            return stream;
        }

        std.debug.print("[SS] Upstream TCP connect failed after retries: server={s}:{d} attempts={d} last_err={}\n", .{ self.server, self.port, connect_retry_attempts, last_err });
        return error.UpstreamTcpConnectFailed;
    }

    fn setSocketTimeouts(fd: std.posix.fd_t, timeout_ms: u32) !void {
        const tv = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
    }

    /// Send initial SS data wrapped in HTTP obfs request
    fn sendWithHttpObfs(self: *ShadowsocksClient, stream: *net.Stream, host: []const u8, salt: []const u8, enc_data: []const u8) !void {
        // Build HTTP GET request headers
        const header = try std.fmt.allocPrint(self.allocator,
            "GET / HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\r\n" ++
            "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n" ++
            "Accept-Language: en-US,en;q=0.8\r\n" ++
            "Accept-Encoding: gzip, deflate\r\n" ++
            "DNT: 1\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n", .{host});
        defer self.allocator.free(header);

        // Combine: HTTP headers + salt + encrypted data → one TCP write
        const total_len = header.len + salt.len + enc_data.len;
        const packet = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(packet);

        @memcpy(packet[0..header.len], header);
        @memcpy(packet[header.len .. header.len + salt.len], salt);
        @memcpy(packet[header.len + salt.len ..], enc_data);

        std.debug.print("[SS] Sending obfs HTTP ({} hdr + {} salt + {} enc = {} total)\n", .{ header.len, salt.len, enc_data.len, total_len });
        try stream.writeAll(packet);
    }

    /// 加密并发送数据 (subsequent data after handshake - no obfs wrapping)
    pub fn write(self: *ShadowsocksClient, data: []const u8) !void {
        const stream = self.stream orelse return error.NotConnected;
        var ctx = &self.enc_ctx.?;

        const max_chunk = 16384;
        var offset: usize = 0;

        while (offset < data.len) {
            const chunk_len = @min(max_chunk, data.len - offset);
            const chunk = data[offset .. offset + chunk_len];

            var enc_buf: [max_chunk + 50]u8 = undefined;
            const enc_len = try ctx.encryptChunk(chunk, &enc_buf);
            try stream.writeAll(enc_buf[0..enc_len]);

            offset += chunk_len;
        }
    }

    /// 接收并解密数据
    pub fn read(self: *ShadowsocksClient, buf: []u8) !usize {
        // First, drain any leftover decrypted payload from a previous oversized chunk
        if (self.read_payload_leftover) |leftover| {
            const copy_len = @min(leftover.len, buf.len);
            @memcpy(buf[0..copy_len], leftover[0..copy_len]);
            if (copy_len < leftover.len) {
                const remaining = try self.allocator.dupe(u8, leftover[copy_len..]);
                self.allocator.free(leftover);
                self.read_payload_leftover = remaining;
            } else {
                self.allocator.free(leftover);
                self.read_payload_leftover = null;
            }
            return copy_len;
        }

        const stream = self.stream orelse return error.NotConnected;

        // Lazy init: on first read, strip obfs headers + read server salt → init dec_ctx
        if (self.dec_ctx == null) {
            try self.initDecryptContext(stream);
        }

        var ctx = &self.dec_ctx.?;
        const tag_len = ctx.cipher.tagLen();

        // Read length header (2 + 16 = 18 bytes)
        var len_hdr: [18]u8 = undefined;
        try self.readExactBuffered(stream, &len_hdr);

        const payload_len = try ctx.decryptLen(&len_hdr);

        // Read encrypted payload + tag
        const enc_payload_len = payload_len + tag_len;
        const enc_payload = try self.allocator.alloc(u8, enc_payload_len);
        defer self.allocator.free(enc_payload);

        try self.readExactBuffered(stream, enc_payload);

        if (payload_len <= buf.len) {
            // Fast path: caller buffer is large enough
            try ctx.decryptPayload(enc_payload, buf[0..payload_len]);
            return payload_len;
        } else {
            // Oversized chunk: decrypt into temp buffer, return partial, save rest
            const tmp = try self.allocator.alloc(u8, payload_len);
            defer self.allocator.free(tmp);

            try ctx.decryptPayload(enc_payload, tmp);

            @memcpy(buf, tmp[0..buf.len]);
            self.read_payload_leftover = try self.allocator.dupe(u8, tmp[buf.len..]);
            return buf.len;
        }
    }

    pub fn hasPendingRead(self: *const ShadowsocksClient) bool {
        return self.read_payload_leftover != null or self.read_leftover != null;
    }

    /// Initialize decryption context: strip obfs HTTP response + read server salt
    fn initDecryptContext(self: *ShadowsocksClient, stream: net.Stream) !void {
        const salt_len = self.cipher_type.saltLen();

        if (self.obfs != null and self.obfs_first_response) {
            self.obfs_first_response = false;

            // Read server's HTTP response, find \r\n\r\n, strip headers
            var response_buf: [4096]u8 = undefined;
            var total_read: usize = 0;

            while (total_read < response_buf.len) {
                const n = try stream.read(response_buf[total_read..]);
                if (n == 0) return error.ConnectionClosed;
                total_read += n;

                if (std.mem.indexOf(u8, response_buf[0..total_read], "\r\n\r\n")) |header_end| {
                    const data_start = header_end + 4;
                    const remaining = response_buf[data_start..total_read];

                    std.debug.print("[SS] Stripped obfs response ({} hdr bytes), {} data bytes remaining\n", .{ data_start, remaining.len });

                    // remaining = server_salt + (possibly) encrypted chunks
                    if (remaining.len >= salt_len) {
                        self.dec_ctx = try aead.AeadStream.init(self.cipher_type, self.password, remaining[0..salt_len]);
                        // Save any leftover after salt
                        if (remaining.len > salt_len) {
                            self.read_leftover = try self.allocator.dupe(u8, remaining[salt_len..]);
                        }
                    } else {
                        // Partial salt in remaining, need more data
                        var salt_full: [32]u8 = undefined;
                        @memcpy(salt_full[0..remaining.len], remaining);
                        var got = remaining.len;
                        while (got < salt_len) {
                            const rn = try stream.read(salt_full[got..salt_len]);
                            if (rn == 0) return error.ConnectionClosed;
                            got += rn;
                        }
                        self.dec_ctx = try aead.AeadStream.init(self.cipher_type, self.password, salt_full[0..salt_len]);
                    }
                    return;
                }
            }
            return error.ObfsResponseTooLarge;
        } else {
            // No obfs: read server salt directly from stream
            var salt_buf: [32]u8 = undefined;
            var got: usize = 0;
            while (got < salt_len) {
                const n = try stream.read(salt_buf[got..salt_len]);
                if (n == 0) return error.ConnectionClosed;
                got += n;
            }
            std.debug.print("[SS] Read server salt ({} bytes)\n", .{salt_len});
            self.dec_ctx = try aead.AeadStream.init(self.cipher_type, self.password, salt_buf[0..salt_len]);
        }
    }

    /// Read exactly `buf.len` bytes, consuming leftover data first, then from stream
    fn readExactBuffered(self: *ShadowsocksClient, stream: net.Stream, buf: []u8) !void {
        var offset: usize = 0;

        // Consume from leftover first
        if (self.read_leftover) |leftover| {
            const copy_len = @min(leftover.len, buf.len);
            @memcpy(buf[0..copy_len], leftover[0..copy_len]);
            offset = copy_len;

            if (copy_len < leftover.len) {
                const remaining = try self.allocator.dupe(u8, leftover[copy_len..]);
                self.allocator.free(leftover);
                self.read_leftover = remaining;
            } else {
                self.allocator.free(leftover);
                self.read_leftover = null;
            }
        }

        // Read the rest from stream
        while (offset < buf.len) {
            const n = try stream.read(buf[offset..]);
            if (n == 0) return error.ConnectionClosed;
            offset += n;
        }
    }
};

fn sleepBeforeRetry(attempt_index: usize, max_attempts: usize) void {
    if (attempt_index + 1 >= max_attempts) return;
    std.Thread.sleep(ShadowsocksClient.retryBackoffMs(attempt_index) * std.time.ns_per_ms);
}

test "Shadowsocks client init" {
    const allocator = std.testing.allocator;
    var client = try ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");
    defer client.deinit();
}
