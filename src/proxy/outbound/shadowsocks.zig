const std = @import("std");
const compat = @import("../../compat.zig");
const net = compat.net;
const aead = @import("../../crypto/aead.zig");
const socket_options = @import("../../socket_options.zig");
pub const Address = aead.Address;
pub const connect_retry_attempts: usize = 3;
const retry_backoff_ms = [_]u64{ 200, 500, 1000 };

/// Scratch size for a single upstream socket read. One read pulls up to this
/// many ciphertext bytes into the reassembly buffer; large enough to usually
/// capture a whole 0x3FFF-payload AEAD frame (~16 KB + tags) in one syscall.
const socket_read_chunk: usize = 32 * 1024;

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
        // Close the freshly-opened socket if any handshake step below fails;
        // ownership transfers to self.stream only on the success path.
        var handshake_ok = false;
        errdefer if (!handshake_ok) stream.close();
        std.debug.print("[SS] TCP connected\n", .{});

        // 3. Generate client salt (size = key length per SS AEAD spec)
        const salt_len = self.cipher_type.saltLen();
        var salt_buf: [32]u8 = undefined;
        const salt = salt_buf[0..salt_len];
        compat.randomBytes(salt);

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
        handshake_ok = true;
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

            socket_options.configureConnectedStream(stream) catch |err| {
                stream.close();
                last_err = err;
                std.debug.print("[SS] Upstream socket sigpipe setup failed: server={s}:{d} attempt={d}/{d} err={}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts, err });
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
        const header = try std.fmt.allocPrint(self.allocator, "GET / HTTP/1.1\r\n" ++
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

        const max_chunk = aead.chunk_payload_size_max;
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

        // Assemble AEAD frames from buffered ciphertext, doing AT MOST ONE socket
        // read per call. If a complete frame is not yet buffered after that read,
        // return error.WouldBlock so the single-threaded poll relay can service
        // the other direction instead of blocking here waiting for the rest of a
        // frame that straddles TCP segments — that head-of-line block was the
        // SSE/large-download stall. Partial frame bytes survive in read_leftover
        // until the next readable event re-enters this function.
        //
        // A zero-length AEAD chunk is a valid authenticated chunk carrying no
        // data; returning 0 would be misread as EOF by the relay, so we consume
        // and verify its tag, then continue to the next chunk.
        var did_socket_read = false;
        while (true) {
            if (try self.takeBufferedFrame(ctx, tag_len, buf)) |n| {
                if (n == 0) continue; // empty chunk consumed; not EOF
                return n;
            }

            // No complete frame buffered. Read once, then retry assembly; if it
            // is still incomplete, yield to the poll loop rather than blocking.
            if (did_socket_read) return error.WouldBlock;

            var scratch: [socket_read_chunk]u8 = undefined;
            const got = stream.read(&scratch) catch |err| {
                // SO_RCVTIMEO surfaces as WouldBlock: no data right now. Any
                // bytes already buffered stay put; yield to the poll loop.
                if (err == error.WouldBlock) return error.WouldBlock;
                return err;
            };
            if (got == 0) return error.ConnectionClosed; // upstream EOF
            try self.appendLeftover(scratch[0..got]);
            did_socket_read = true;
        }
    }

    /// Try to extract one complete AEAD frame from the buffered ciphertext.
    /// Returns null if a full frame is not yet buffered (caller must read more),
    /// 0 if an authenticated empty chunk was consumed (skip it, not EOF), or the
    /// number of plaintext bytes written into `buf`. Surplus plaintext from an
    /// oversized chunk is stashed in read_payload_leftover.
    fn takeBufferedFrame(self: *ShadowsocksClient, ctx: *aead.AeadStream, tag_len: usize, buf: []u8) !?usize {
        const leftover = self.read_leftover orelse return null;
        const len_hdr_len = 2 + tag_len;
        if (leftover.len < len_hdr_len) return null;

        // Peek the length on a COPY so a partial frame does not advance the real
        // decrypt nonce (which would desync the AEAD stream).
        var preview = ctx.*;
        const payload_len = try preview.decryptLen(leftover[0..len_hdr_len]);
        const frame_len = len_hdr_len + @as(usize, payload_len) + tag_len;
        if (leftover.len < frame_len) return null; // whole frame not here yet

        // Commit: advance the real context and decrypt this frame.
        _ = try ctx.decryptLen(leftover[0..len_hdr_len]);
        const enc_payload = leftover[len_hdr_len..frame_len];

        var result: usize = undefined;
        if (payload_len == 0) {
            try ctx.decryptPayload(enc_payload, buf[0..0]);
            result = 0;
        } else if (payload_len <= buf.len) {
            try ctx.decryptPayload(enc_payload, buf[0..payload_len]);
            result = payload_len;
        } else {
            // Oversized chunk: decrypt into temp, return a prefix, save the rest.
            const tmp = try self.allocator.alloc(u8, payload_len);
            defer self.allocator.free(tmp);
            try ctx.decryptPayload(enc_payload, tmp);
            @memcpy(buf, tmp[0..buf.len]);
            self.read_payload_leftover = try self.allocator.dupe(u8, tmp[buf.len..]);
            result = buf.len;
        }

        try self.consumeLeftoverFront(frame_len);
        return result;
    }

    /// Append freshly-read ciphertext to the reassembly buffer.
    fn appendLeftover(self: *ShadowsocksClient, data: []const u8) !void {
        if (self.read_leftover) |old| {
            const combined = try self.allocator.alloc(u8, old.len + data.len);
            @memcpy(combined[0..old.len], old);
            @memcpy(combined[old.len..], data);
            self.allocator.free(old);
            self.read_leftover = combined;
        } else {
            self.read_leftover = try self.allocator.dupe(u8, data);
        }
    }

    /// Drop the first `n` bytes of the reassembly buffer (a consumed frame).
    fn consumeLeftoverFront(self: *ShadowsocksClient, n: usize) !void {
        const leftover = self.read_leftover orelse return;
        if (n >= leftover.len) {
            self.allocator.free(leftover);
            self.read_leftover = null;
            return;
        }
        const remaining = try self.allocator.dupe(u8, leftover[n..]);
        self.allocator.free(leftover);
        self.read_leftover = remaining;
    }

    pub fn hasPendingRead(self: *const ShadowsocksClient) bool {
        if (self.read_payload_leftover != null) return true;
        return self.hasBufferedEncryptedChunk();
    }

    fn hasBufferedEncryptedChunk(self: *const ShadowsocksClient) bool {
        const leftover = self.read_leftover orelse return false;
        const dec_ctx = self.dec_ctx orelse return false;
        const tag_len = dec_ctx.cipher.tagLen();
        const len_hdr_len = 2 + tag_len;
        if (leftover.len < len_hdr_len) return false;

        var preview_ctx = dec_ctx;
        const payload_len = preview_ctx.decryptLen(leftover[0..len_hdr_len]) catch return false;
        return leftover.len >= len_hdr_len + @as(usize, payload_len) + tag_len;
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
};

fn sleepBeforeRetry(attempt_index: usize, max_attempts: usize) void {
    if (attempt_index + 1 >= max_attempts) return;
    compat.sleepNs(ShadowsocksClient.retryBackoffMs(attempt_index) * std.time.ns_per_ms);
}

test "Shadowsocks client init" {
    const allocator = std.testing.allocator;
    var client = try ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");
    defer client.deinit();
}

test "hasPendingRead should be false when encrypted leftover is incomplete" {
    const allocator = std.testing.allocator;
    var client = try ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");
    defer client.deinit();

    client.read_leftover = try allocator.dupe(u8, "x");
    try std.testing.expect(!client.hasPendingRead());
}

test "hasPendingRead should be true when encrypted leftover contains a full chunk" {
    const allocator = std.testing.allocator;
    var client = try ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");
    defer client.deinit();

    const salt = [_]u8{0} ** 16;
    var enc_ctx = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);
    client.dec_ctx = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);

    var encrypted: [256]u8 = undefined;
    const enc_len = try enc_ctx.encryptChunk("hello", &encrypted);
    client.read_leftover = try allocator.dupe(u8, encrypted[0..enc_len]);

    try std.testing.expect(client.hasPendingRead());
}

test "read skips a zero-length AEAD chunk instead of reporting false EOF" {
    const allocator = std.testing.allocator;
    var client = try ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");
    defer client.deinit();

    const salt = [_]u8{0} ** 16;
    var enc_ctx = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);
    client.dec_ctx = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);

    // Build wire bytes: an empty chunk followed by a real "hello" chunk.
    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(allocator);

    var enc_empty: [64]u8 = undefined;
    const empty_len = try enc_ctx.encryptChunk("", &enc_empty);
    try wire.appendSlice(allocator, enc_empty[0..empty_len]);

    var enc_hello: [64]u8 = undefined;
    const hello_len = try enc_ctx.encryptChunk("hello", &enc_hello);
    try wire.appendSlice(allocator, enc_hello[0..hello_len]);

    // Feed the full wire via the buffered-leftover path so read() never touches a socket.
    client.read_leftover = try allocator.dupe(u8, wire.items);
    // read() requires a non-null stream handle; it is never actually read here
    // because all bytes are satisfied from read_leftover.
    client.stream = net.Stream{ .handle = 0 };
    defer client.stream = null; // avoid deinit closing fd 0

    var out: [32]u8 = undefined;
    const n = try client.read(&out);

    // With the bug, read() returns 0 (false EOF) after the empty chunk.
    // With the fix, the empty chunk is skipped and "hello" is returned.
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}

const WriteTestContext = struct {
    client: *ShadowsocksClient,
    payload: []const u8,
    failure: ?anyerror = null,

    fn run(context: *WriteTestContext) void {
        context.client.write(context.payload) catch |err| {
            context.failure = err;
            _ = compat.shutdownWrite(context.client.stream.?.handle) catch {};
            return;
        };
        compat.shutdownWrite(context.client.stream.?.handle) catch |err| {
            context.failure = err;
        };
    }
};

test "write splits 0x4000 bytes at the Shadowsocks AEAD limit" {
    // The sender and receiver must enforce the same 0x3fff wire payload cap.
    const allocator = std.testing.allocator;
    const fds = try makeSocketPair();
    defer _ = std.c.close(fds[1]);

    var client = try ShadowsocksClient.init(
        allocator,
        "127.0.0.1",
        8388,
        "password",
        "aes-128-gcm",
    );
    defer client.deinit();
    client.stream = net.Stream{ .handle = fds[0] };

    const salt = [_]u8{0} ** 16;
    client.enc_ctx = try aead.AeadStream.init(
        .aes_128_gcm,
        "password",
        &salt,
    );
    var decoder = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);

    const payload = [_]u8{0x5a} ** 0x4000;
    var context = WriteTestContext{ .client = &client, .payload = &payload };
    const thread = try std.Thread.spawn(
        .{},
        WriteTestContext.run,
        .{&context},
    );

    const tag_size = 16;
    const frame_overhead = 2 + tag_size + tag_size;
    var wire: [payload.len + 2 * frame_overhead]u8 = undefined;
    const wire_size = try readToEndFd(fds[1], &wire);
    thread.join();
    if (context.failure) |err| return err;
    try std.testing.expectEqual(wire.len, wire_size);

    const header_size = 2 + tag_size;
    const first_size = try decoder.decryptLen(wire[0..header_size]);
    try std.testing.expectEqual(@as(u16, 0x3fff), first_size);
    const first_end = header_size + first_size + tag_size;
    var first_plaintext: [0x3fff]u8 = undefined;
    try decoder.decryptPayload(
        wire[header_size..first_end],
        &first_plaintext,
    );

    const second_header_end = first_end + header_size;
    const second_size = try decoder.decryptLen(
        wire[first_end..second_header_end],
    );
    try std.testing.expectEqual(@as(u16, 1), second_size);
}

fn writeAllFd(fd: std.posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) off += try compat.posixWrite(fd, data[off..]);
}

fn readToEndFd(fd: std.posix.fd_t, data: []u8) !usize {
    var offset: usize = 0;
    while (offset < data.len) {
        const read_count = try compat.posixRead(fd, data[offset..]);
        if (read_count == 0) break;
        offset += read_count;
    }
    return offset;
}

fn makeSocketPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(
        @as(c_uint, @intCast(std.posix.AF.UNIX)),
        @as(c_uint, @intCast(std.posix.SOCK.STREAM)),
        0,
        &fds,
    );
    if (rc != 0) return error.SocketPairFailed;
    return fds;
}

test "read yields WouldBlock on a partial frame, then assembles it across reads" {
    // Regression: a download frame straddling TCP segments must NOT block the
    // single-threaded relay. read() does one socket read; if the frame is still
    // incomplete it returns WouldBlock (relay re-polls) and resumes next call.
    const allocator = std.testing.allocator;
    const fds = try makeSocketPair();
    defer _ = std.c.close(fds[1]); // fds[0] is owned/closed by client.deinit()

    var client = try ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");
    defer client.deinit();

    const salt = [_]u8{0} ** 16;
    var enc_ctx = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);
    client.dec_ctx = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);
    client.stream = net.Stream{ .handle = fds[0] };
    // Short SO_RCVTIMEO so a read with no data surfaces WouldBlock promptly.
    try ShadowsocksClient.setSocketTimeouts(fds[0], 100);

    var frame: [64]u8 = undefined;
    const flen = try enc_ctx.encryptChunk("hello", &frame);

    // Feed only a partial length header first (10 < 18-byte header).
    try writeAllFd(fds[1], frame[0..10]);

    var out: [64]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, client.read(&out));

    // Feed the rest; the frame now completes and decrypts.
    try writeAllFd(fds[1], frame[10..flen]);
    const n = try client.read(&out);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}

test "read drains multiple frames buffered from one socket read" {
    // Regression: one socket read can pull more than one AEAD frame; the extra
    // frame must be reported via hasPendingRead and returned without waiting for
    // another socket-readable event (else it would stall behind poll).
    const allocator = std.testing.allocator;
    const fds = try makeSocketPair();
    defer _ = std.c.close(fds[1]);

    var client = try ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");
    defer client.deinit();

    const salt = [_]u8{0} ** 16;
    var enc_ctx = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);
    client.dec_ctx = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);
    client.stream = net.Stream{ .handle = fds[0] };
    try ShadowsocksClient.setSocketTimeouts(fds[0], 100);

    var f1: [64]u8 = undefined;
    var f2: [64]u8 = undefined;
    const l1 = try enc_ctx.encryptChunk("hello", &f1);
    const l2 = try enc_ctx.encryptChunk("world", &f2);

    var both = std.ArrayList(u8).empty;
    defer both.deinit(allocator);
    try both.appendSlice(allocator, f1[0..l1]);
    try both.appendSlice(allocator, f2[0..l2]);
    try writeAllFd(fds[1], both.items);

    var out: [64]u8 = undefined;
    const n1 = try client.read(&out);
    try std.testing.expectEqualStrings("hello", out[0..n1]);

    try std.testing.expect(client.hasPendingRead());
    const n2 = try client.read(&out);
    try std.testing.expectEqualStrings("world", out[0..n2]);
}
