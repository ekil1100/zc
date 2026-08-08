const std = @import("std");
const compat = @import("../../compat.zig");
const net = compat.net;
const aead = @import("../../crypto/aead.zig");
const socks_address = @import("../../protocol/socks_address.zig");
const socket_options = @import("../../socket_options.zig");
const simple_obfs_http = @import("simple_obfs_http.zig");
pub const connect_retry_attempts: usize = 3;
pub const upstream_connect_timeout_ms: u32 = 10_000;
const retry_backoff_ms = [_]u64{ 200, 500, 1000 };

const UpstreamConnectDeadline = struct {
    expires_ms: i64,

    fn initAt(now_ms: i64, timeout_ms: u32) UpstreamConnectDeadline {
        return .{
            .expires_ms = std.math.add(
                i64,
                now_ms,
                @intCast(timeout_ms),
            ) catch std.math.maxInt(i64),
        };
    }

    fn expiredAt(self: UpstreamConnectDeadline, now_ms: i64) bool {
        return now_ms >= self.expires_ms;
    }

    fn remainingMsAt(
        self: UpstreamConnectDeadline,
        now_ms: i64,
    ) !u32 {
        if (self.expiredAt(now_ms)) {
            return error.UpstreamConnectDeadlineExceeded;
        }
        const remaining_ms = self.expires_ms - now_ms;
        return @intCast(@min(
            remaining_ms,
            @as(i64, std.math.maxInt(u32)),
        ));
    }
};

/// Scratch size for a single upstream socket read. One read pulls up to this
/// many ciphertext bytes into the reassembly buffer; large enough to usually
/// capture a whole 0x3FFF-payload AEAD frame (~16 KB + tags) in one syscall.
const socket_read_chunk: usize = 32 * 1024;
const default_socket_timeout_ms: u32 = 15_000;
const blocking_poll_timeout_ms: i32 = 15_000;

/// Shadowsocks 出站连接（AEAD 加密版）
pub const ShadowsocksClient = struct {
    allocator: std.mem.Allocator,
    server: []const u8,
    port: u16,
    password: []const u8,
    cipher_type: aead.CipherType,

    // Built-in simple-obfs HTTP transport. External plugins remain disabled.
    obfs: ?simple_obfs_http.Client = null,

    // Session state
    stream: ?net.Stream = null,
    enc_ctx: ?aead.AeadStream = null, // encrypt (client salt derived)
    dec_ctx: ?aead.AeadStream = null, // decrypt (server salt derived)

    // Leftover data after stripping HTTP headers / server salt
    read_leftover: ?[]u8 = null,

    // Decrypted payload leftover when a chunk exceeds caller's buffer
    read_payload_leftover: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, server: []const u8, port: u16, password: []const u8, cipher: []const u8) !ShadowsocksClient {
        const cipher_type = aead.parseCipherType(cipher) orelse return error.UnsupportedCipher;
        const owned_server = try allocator.dupe(u8, server);
        errdefer allocator.free(owned_server);
        const owned_password = try allocator.dupe(u8, password);
        return ShadowsocksClient{
            .allocator = allocator,
            .server = owned_server,
            .port = port,
            .password = owned_password,
            .cipher_type = cipher_type,
        };
    }

    pub fn initWithObfs(
        allocator: std.mem.Allocator,
        server: []const u8,
        port: u16,
        password: []const u8,
        cipher: []const u8,
        http_config: simple_obfs_http.Config,
    ) !ShadowsocksClient {
        var client = try init(allocator, server, port, password, cipher);
        errdefer client.deinit();
        client.obfs = try simple_obfs_http.Client.init(http_config);
        return client;
    }

    pub fn deinit(self: *ShadowsocksClient) void {
        self.allocator.free(self.server);
        self.allocator.free(self.password);
        if (self.read_leftover) |lo| self.allocator.free(lo);
        if (self.read_payload_leftover) |lo| self.allocator.free(lo);
        if (self.stream) |s| s.close();
    }

    /// 连接到 Shadowsocks 服务器并发送目标地址
    pub fn connect(
        self: *ShadowsocksClient,
        target: socks_address.Address,
    ) !net.Stream {
        std.debug.print("[SS] Connecting to {s}:{d} via SS\n", .{ self.server, self.port });

        // DNS, every retry backoff, and every TCP connect share this one
        // monotonic deadline. No phase or retry can reopen the time budget.
        var upstream_ops = SystemUpstreamOps{};
        const upstream_deadline = UpstreamConnectDeadline.initAt(
            upstream_ops.now(),
            upstream_connect_timeout_ms,
        );

        // 1. DNS resolve (with retry/backoff)
        const upstream_addr = try self.resolveUpstreamAddressWithRetryUsing(
            upstream_deadline,
            SystemUpstreamOps,
            &upstream_ops,
        );

        // 2. TCP connect (with retry/backoff)
        var stream = try self.connectUpstreamWithRetryUsing(
            upstream_addr,
            upstream_deadline,
            SystemUpstreamOps,
            &upstream_ops,
        );
        // Close the freshly-opened socket if any handshake step below fails;
        // ownership transfers to self.stream only on the success path.
        var handshake_ok = false;
        errdefer if (!handshake_ok) stream.close();
        std.debug.print("[SS] TCP connected\n", .{});

        // 3. Generate client salt (size = key length per SS AEAD spec)
        const salt_len = self.cipher_type.saltLen();
        var salt_buf: [32]u8 = undefined;
        const salt = salt_buf[0..salt_len];
        try std.Io.randomSecure(compat.io(), salt);

        // 4. Init encryption context with HKDF-derived session key
        self.enc_ctx = try aead.AeadStream.init(self.cipher_type, self.password, salt);

        // 5. Encode target address
        var addr_buf: [socks_address.encoded_size_max]u8 = undefined;
        const addr_len = try target.encode(&addr_buf);

        // 6. Encrypt target address as first AEAD chunk
        var enc_buf: [300]u8 = undefined;
        const enc_len = try self.enc_ctx.?.encryptChunk(addr_buf[0..addr_len], &enc_buf);

        // 7. Send data (with or without the one-shot HTTP obfs header).
        if (self.obfs != null) {
            try self.sendInitialPayload(&stream, salt, enc_buf[0..enc_len]);
        } else {
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

    fn resolveUpstreamAddressWithRetryUsing(
        self: *ShadowsocksClient,
        deadline: UpstreamConnectDeadline,
        comptime Ops: type,
        ops: *Ops,
    ) !net.Address {
        var last_err: anyerror = error.UpstreamDnsResolveFailed;

        var attempt: usize = 0;
        while (attempt < connect_retry_attempts) : (attempt += 1) {
            const remaining_ms = deadline.remainingMsAt(ops.now()) catch
                return error.UpstreamConnectDeadlineExceeded;
            var addr_list = ops.resolve(
                self.allocator,
                self.server,
                self.port,
                remaining_ms,
            ) catch |err| {
                if (err == error.AddressResolutionTimeout or
                    deadline.expiredAt(ops.now()))
                {
                    return error.UpstreamConnectDeadlineExceeded;
                }
                last_err = err;
                std.debug.print("[SS] Upstream DNS resolve failed: server={s}:{d} attempt={d}/{d} err={}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts, err });
                try sleepBeforeRetryWithinDeadline(
                    deadline,
                    attempt,
                    connect_retry_attempts,
                    Ops,
                    ops,
                );
                continue;
            };
            defer addr_list.deinit();

            _ = deadline.remainingMsAt(ops.now()) catch
                return error.UpstreamConnectDeadlineExceeded;
            if (addr_list.addrs.len == 0) {
                last_err = error.HostNotFound;
                std.debug.print("[SS] Upstream DNS resolve returned no address: server={s}:{d} attempt={d}/{d}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts });
                try sleepBeforeRetryWithinDeadline(
                    deadline,
                    attempt,
                    connect_retry_attempts,
                    Ops,
                    ops,
                );
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

    fn connectUpstreamWithRetryUsing(
        self: *ShadowsocksClient,
        addr: net.Address,
        deadline: UpstreamConnectDeadline,
        comptime Ops: type,
        ops: *Ops,
    ) !net.Stream {
        var last_err: anyerror = error.UpstreamTcpConnectFailed;

        var attempt: usize = 0;
        while (attempt < connect_retry_attempts) : (attempt += 1) {
            const remaining_ms = deadline.remainingMsAt(ops.now()) catch
                return error.UpstreamConnectDeadlineExceeded;
            var stream = ops.connect(addr, remaining_ms) catch |err| {
                if (deadline.expiredAt(ops.now())) {
                    return error.UpstreamConnectDeadlineExceeded;
                }
                last_err = err;
                std.debug.print("[SS] Upstream TCP connect failed: server={s}:{d} attempt={d}/{d} err={}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts, err });
                try sleepBeforeRetryWithinDeadline(
                    deadline,
                    attempt,
                    connect_retry_attempts,
                    Ops,
                    ops,
                );
                continue;
            };

            _ = deadline.remainingMsAt(ops.now()) catch {
                stream.close();
                return error.UpstreamConnectDeadlineExceeded;
            };
            ops.configure(self, stream) catch |err| {
                stream.close();
                if (deadline.expiredAt(ops.now())) {
                    return error.UpstreamConnectDeadlineExceeded;
                }
                last_err = err;
                std.debug.print("[SS] Upstream socket setup failed: server={s}:{d} attempt={d}/{d} err={}\n", .{ self.server, self.port, attempt + 1, connect_retry_attempts, err });
                try sleepBeforeRetryWithinDeadline(
                    deadline,
                    attempt,
                    connect_retry_attempts,
                    Ops,
                    ops,
                );
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

    /// Send the first Shadowsocks payload as salt || encrypted target.
    fn sendInitialPayload(
        self: *ShadowsocksClient,
        stream: *net.Stream,
        salt: []const u8,
        encrypted_target: []const u8,
    ) !void {
        var payload: [32 + 300]u8 = undefined;
        const payload_len = std.math.add(
            usize,
            salt.len,
            encrypted_target.len,
        ) catch return error.LengthOverflow;
        if (payload_len > payload.len) return error.InitialPayloadTooLarge;
        @memcpy(payload[0..salt.len], salt);
        @memcpy(payload[salt.len..payload_len], encrypted_target);
        try self.obfs.?.write(stream, payload[0..payload_len]);
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
            if (self.obfs) |*http_obfs| {
                try http_obfs.write(&stream, enc_buf[0..enc_len]);
            } else {
                try stream.writeAll(enc_buf[0..enc_len]);
            }

            offset += chunk_len;
        }
    }

    /// 接收并解密数据
    pub fn read(self: *ShadowsocksClient, buf: []u8) !usize {
        if (try self.takePayloadLeftover(buf)) |count| return count;
        var stream = self.stream orelse return error.NotConnected;
        return self.readFromStream(&stream, buf) catch |err| {
            if (err == error.NeedMoreData) return error.WouldBlock;
            return err;
        };
    }

    fn readFromStream(
        self: *ShadowsocksClient,
        stream: anytype,
        buf: []u8,
    ) !usize {
        if (try self.takePayloadLeftover(buf)) |count| return count;

        // Lazy init: strip the optional obfs header and consume the server salt.
        // Carry the read accounting into frame assembly so one top-level read()
        // never performs a second transport read after init already consumed one.
        var did_socket_read = false;
        if (self.dec_ctx == null) {
            did_socket_read = try self.initDecryptContext(stream);
        }

        var ctx = &self.dec_ctx.?;
        const tag_len = ctx.cipher.tagLen();

        // Assemble AEAD frames from buffered ciphertext, doing AT MOST ONE socket
        // read per call. If a complete frame is not yet buffered after that read,
        // return internal NeedMoreData; public read maps it to WouldBlock so the
        // single-threaded poll relay can service the other direction instead of
        // frame that straddles TCP segments. Partial bytes remain in read_leftover.
        //
        // A zero-length AEAD chunk is valid authenticated data. Consume it and
        // continue rather than returning 0, which the relay would treat as EOF.
        while (true) {
            if (try self.takeBufferedFrame(ctx, tag_len, buf)) |n| {
                if (n == 0) continue;
                return n;
            }

            if (did_socket_read) return error.NeedMoreData;

            var scratch: [socket_read_chunk]u8 = undefined;
            const got = stream.read(&scratch) catch |err| {
                if (err == error.WouldBlock) return error.WouldBlock;
                return err;
            };
            if (got == 0) return error.ConnectionClosed;
            try self.appendLeftover(scratch[0..got]);
            did_socket_read = true;
        }
    }

    fn takePayloadLeftover(
        self: *ShadowsocksClient,
        buf: []u8,
    ) !?usize {
        const leftover = self.read_payload_leftover orelse return null;
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

    /// Blocking facade for the HTTPS-forward reader. Synthetic WouldBlock from
    /// split salts/frames is resumed after polling the socket; an armed obfs
    /// response deadline bounds both the poll and the overall header wait.
    pub fn readBlocking(self: *ShadowsocksClient, buf: []u8) !usize {
        if (try self.takePayloadLeftover(buf)) |count| return count;
        var stream = self.stream orelse return error.NotConnected;
        while (true) {
            const before_poll_ms = compat.monotonicMilliTimestamp();
            try self.checkResponseDeadlineAt(before_poll_ms);

            if (!self.hasPendingRead()) {
                var poll_fds = [_]std.posix.pollfd{.{
                    .fd = stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const timeout_ms = self.responseDeadlineRemainingMsAt(
                    before_poll_ms,
                ) orelse blocking_poll_timeout_ms;
                const poll_deadline_ms = std.math.add(
                    i64,
                    before_poll_ms,
                    timeout_ms,
                ) catch std.math.maxInt(i64);
                const ready = try compat.pollUntil(
                    &poll_fds,
                    poll_deadline_ms,
                );
                try self.checkResponseDeadlineAt(
                    compat.monotonicMilliTimestamp(),
                );
                if (ready == 0) return error.WouldBlock;

                const revents = poll_fds[0].revents;
                if ((revents & std.posix.POLL.IN) == 0) {
                    if ((revents & std.posix.POLL.NVAL) != 0) {
                        return error.InvalidDescriptor;
                    }
                    if ((revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
                        return error.ConnectionClosed;
                    }
                    return error.WouldBlock;
                }
            }

            return self.readFromStream(&stream, buf) catch |err| {
                if (err == error.NeedMoreData) continue;
                return err;
            };
        }
    }

    pub fn responseDeadlineRemainingMsAt(
        self: *const ShadowsocksClient,
        now_ms: i64,
    ) ?i32 {
        if (self.obfs) |*http_obfs| {
            return http_obfs.responseDeadlineRemainingMsAt(now_ms);
        }
        return null;
    }

    pub fn checkResponseDeadlineAt(
        self: *const ShadowsocksClient,
        now_ms: i64,
    ) !void {
        if (self.obfs) |*http_obfs| {
            try http_obfs.checkResponseDeadlineAt(now_ms);
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
            const combined_len = std.math.add(usize, old.len, data.len) catch {
                return error.LengthOverflow;
            };
            const combined = try self.allocator.alloc(u8, combined_len);
            @memcpy(combined[0..old.len], old);
            @memcpy(combined[old.len..combined_len], data);
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
        if (self.obfs) |*http_obfs| {
            if (http_obfs.hasPendingRead()) return true;
        }
        if (self.dec_ctx == null) {
            const leftover = self.read_leftover orelse return false;
            return leftover.len >= self.cipher_type.saltLen();
        }
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

    /// Initialize decryption context from persistent raw transport bytes.
    /// Returns true when this call consumed one transport read operation.
    fn initDecryptContext(
        self: *ShadowsocksClient,
        stream: anytype,
    ) !bool {
        const salt_len = self.cipher_type.saltLen();
        const buffered_len = if (self.read_leftover) |leftover| leftover.len else 0;
        var did_transport_read = false;
        if (buffered_len < salt_len) {
            var scratch: [socket_read_chunk]u8 = undefined;
            const read_count = if (self.obfs) |*http_obfs|
                try http_obfs.read(stream, &scratch)
            else
                try stream.read(&scratch);
            did_transport_read = true;
            if (read_count == 0) return error.ConnectionClosed;
            try self.appendLeftover(scratch[0..read_count]);
        }

        const leftover = self.read_leftover orelse return error.NeedMoreData;
        if (leftover.len < salt_len) return error.NeedMoreData;

        const context = try aead.AeadStream.init(
            self.cipher_type,
            self.password,
            leftover[0..salt_len],
        );
        try self.consumeLeftoverFront(salt_len);
        self.dec_ctx = context;
        return did_transport_read;
    }
};

const SystemUpstreamOps = struct {
    fn now(_: *@This()) i64 {
        return compat.monotonicMilliTimestamp();
    }

    fn resolve(
        _: *@This(),
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        timeout_ms: u32,
    ) !net.AddressList {
        return net.getAddressListWithTimeout(
            allocator,
            host,
            port,
            timeout_ms,
        );
    }

    fn connect(
        _: *@This(),
        address: net.Address,
        timeout_ms: u32,
    ) !net.Stream {
        return net.tcpConnectToAddressWithTimeout(address, timeout_ms);
    }

    fn configure(
        _: *@This(),
        client: *ShadowsocksClient,
        stream: net.Stream,
    ) !void {
        try socket_options.configureConnectedStream(stream);
        const timeout_ms: u32 = if (client.obfs) |*http_obfs|
            @intCast(http_obfs.responseTimeoutMs())
        else
            default_socket_timeout_ms;
        try ShadowsocksClient.setSocketTimeouts(stream.handle, timeout_ms);
    }

    fn sleep(_: *@This(), delay_ms: u32) !void {
        try std.Io.sleep(
            compat.io(),
            .fromMilliseconds(delay_ms),
            .awake,
        );
    }
};

fn sleepBeforeRetryWithinDeadline(
    deadline: UpstreamConnectDeadline,
    attempt_index: usize,
    max_attempts: usize,
    comptime Ops: type,
    ops: *Ops,
) !void {
    if (attempt_index + 1 >= max_attempts) return;

    const remaining_ms = deadline.remainingMsAt(ops.now()) catch
        return error.UpstreamConnectDeadlineExceeded;
    const requested_ms: u32 = @intCast(@min(
        ShadowsocksClient.retryBackoffMs(attempt_index),
        @as(u64, std.math.maxInt(u32)),
    ));
    const delay_ms = @min(requested_ms, remaining_ms);
    ops.sleep(delay_ms) catch |err| {
        if (deadline.expiredAt(ops.now())) {
            return error.UpstreamConnectDeadlineExceeded;
        }
        return err;
    };
    _ = deadline.remainingMsAt(ops.now()) catch
        return error.UpstreamConnectDeadlineExceeded;
}

test "DNS retry backoff cannot extend the absolute upstream deadline" {
    const DnsFailureOps = struct {
        now_ms: i64 = 1_000,
        resolve_calls: usize = 0,
        resolve_timeouts: [connect_retry_attempts]u32 = @splat(0),
        sleep_calls: usize = 0,
        sleeps_ms: [connect_retry_attempts]u32 = @splat(0),

        fn now(self: *@This()) i64 {
            return self.now_ms;
        }

        fn resolve(
            self: *@This(),
            _: std.mem.Allocator,
            _: []const u8,
            _: u16,
            timeout_ms: u32,
        ) !net.AddressList {
            self.resolve_timeouts[self.resolve_calls] = timeout_ms;
            self.resolve_calls += 1;
            return error.InjectedDnsFailure;
        }

        fn sleep(self: *@This(), delay_ms: u32) !void {
            self.sleeps_ms[self.sleep_calls] = delay_ms;
            self.sleep_calls += 1;
            self.now_ms += delay_ms;
        }
    };

    var client = try ShadowsocksClient.init(
        std.testing.allocator,
        "upstream.invalid",
        8388,
        "password",
        "aes-128-gcm",
    );
    defer client.deinit();
    var ops = DnsFailureOps{};
    const deadline = UpstreamConnectDeadline.initAt(ops.now(), 250);

    try std.testing.expectError(
        error.UpstreamConnectDeadlineExceeded,
        client.resolveUpstreamAddressWithRetryUsing(
            deadline,
            DnsFailureOps,
            &ops,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), ops.resolve_calls);
    try std.testing.expectEqual(@as(usize, 2), ops.sleep_calls);
    try std.testing.expectEqual(@as(u32, 250), ops.resolve_timeouts[0]);
    try std.testing.expectEqual(@as(u32, 50), ops.resolve_timeouts[1]);
    try std.testing.expectEqual(@as(u32, 200), ops.sleeps_ms[0]);
    try std.testing.expectEqual(@as(u32, 50), ops.sleeps_ms[1]);
    try std.testing.expectEqual(deadline.expires_ms, ops.now());
}

test "TCP retries receive only remaining absolute-deadline time" {
    const ConnectTimeoutOps = struct {
        now_ms: i64 = 2_000,
        connect_calls: usize = 0,
        connect_timeouts: [connect_retry_attempts]u32 = @splat(0),
        sleep_calls: usize = 0,

        fn now(self: *@This()) i64 {
            return self.now_ms;
        }

        fn connect(
            self: *@This(),
            _: net.Address,
            timeout_ms: u32,
        ) !net.Stream {
            self.connect_timeouts[self.connect_calls] = timeout_ms;
            self.connect_calls += 1;
            if (self.connect_calls == 1) {
                self.now_ms += 20;
                return error.InjectedConnectFailure;
            }

            // Model an OS connector which never completes before its supplied
            // timeout. Advancing exactly that amount must surface the shared,
            // typed absolute deadline rather than start another retry window.
            self.now_ms += timeout_ms;
            return error.InjectedConnectTimeout;
        }

        fn configure(
            _: *@This(),
            _: *ShadowsocksClient,
            _: net.Stream,
        ) !void {
            return error.UnexpectedConfigure;
        }

        fn sleep(self: *@This(), delay_ms: u32) !void {
            self.sleep_calls += 1;
            self.now_ms += delay_ms;
        }
    };

    var client = try ShadowsocksClient.init(
        std.testing.allocator,
        "127.0.0.1",
        8388,
        "password",
        "aes-128-gcm",
    );
    defer client.deinit();
    var ops = ConnectTimeoutOps{};
    const deadline = UpstreamConnectDeadline.initAt(ops.now(), 260);
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 8388);

    try std.testing.expectError(
        error.UpstreamConnectDeadlineExceeded,
        client.connectUpstreamWithRetryUsing(
            address,
            deadline,
            ConnectTimeoutOps,
            &ops,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), ops.connect_calls);
    try std.testing.expectEqual(@as(usize, 1), ops.sleep_calls);
    try std.testing.expectEqual(@as(u32, 260), ops.connect_timeouts[0]);
    try std.testing.expectEqual(@as(u32, 40), ops.connect_timeouts[1]);
    try std.testing.expectEqual(deadline.expires_ms, ops.now());
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
    while (off < data.len) off += try compat.posixSocketWrite(fd, data[off..]);
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

test "HTTP obfs integration sends salt and encrypted target as the first body" {
    const allocator = std.testing.allocator;
    var client = try ShadowsocksClient.initWithObfs(
        allocator,
        "127.0.0.1",
        8388,
        "password",
        "aes-128-gcm",
        simple_obfs_http.Config{
            .host = "www.example.com",
            .server_port = 8388,
        },
    );
    defer client.deinit();

    const fds = try makeSocketPair();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var stream = net.Stream{ .handle = fds[0] };

    const salt = "0123456789abcdef";
    const encrypted_target = "encrypted-target";
    try client.sendInitialPayload(&stream, salt, encrypted_target);

    var wire: [simple_obfs_http.request_header_max + salt.len + encrypted_target.len]u8 = undefined;
    var wire_len: usize = 0;
    while (true) {
        wire_len += try compat.posixRead(fds[1], wire[wire_len..]);
        if (std.mem.indexOf(u8, wire[0..wire_len], "\r\n\r\n")) |header_end| {
            const payload_start = header_end + 4;
            if (wire_len == payload_start + salt.len + encrypted_target.len) break;
        }
    }

    try std.testing.expect(std.mem.indexOf(u8, wire[0..wire_len], "Content-Length: 32\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, wire[0..wire_len], salt ++ encrypted_target));
}

test "HTTP obfs integration resumes a split response without losing SS bytes" {
    const allocator = std.testing.allocator;
    var client = try ShadowsocksClient.initWithObfs(
        allocator,
        "127.0.0.1",
        8388,
        "password",
        "aes-128-gcm",
        simple_obfs_http.Config{
            .host = "www.example.com",
            .server_port = 8388,
        },
    );
    defer client.deinit();

    const fds = try makeSocketPair();
    defer _ = std.c.close(fds[1]);
    client.stream = net.Stream{ .handle = fds[0] };
    try ShadowsocksClient.setSocketTimeouts(fds[0], 100);

    const server_salt = [_]u8{0} ** 16;
    var server_encrypt = try aead.AeadStream.init(
        .aes_128_gcm,
        "password",
        &server_salt,
    );
    var frame: [64]u8 = undefined;
    const frame_len = try server_encrypt.encryptChunk("hello", &frame);
    const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "\r\n";

    // The first call consumes an incomplete header and must retain it on WouldBlock.
    try writeAllFd(fds[1], response[0..17]);
    var output: [32]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, client.read(&output));

    var remainder: [response.len - 17 + server_salt.len + frame.len]u8 = undefined;
    var remainder_len: usize = 0;
    @memcpy(remainder[remainder_len .. remainder_len + response.len - 17], response[17..]);
    remainder_len += response.len - 17;
    @memcpy(remainder[remainder_len .. remainder_len + server_salt.len], &server_salt);
    remainder_len += server_salt.len;
    @memcpy(remainder[remainder_len .. remainder_len + frame_len], frame[0..frame_len]);
    remainder_len += frame_len;
    try writeAllFd(fds[1], remainder[0..remainder_len]);

    const count = try client.read(&output);
    try std.testing.expectEqualStrings("hello", output[0..count]);
}

const OneReadStream = struct {
    input: []const u8,
    reads: usize = 0,

    pub fn read(self: *OneReadStream, output: []u8) !usize {
        self.reads += 1;
        if (self.reads > 1) return error.UnexpectedSecondRead;
        const count = @min(output.len, self.input.len);
        @memcpy(output[0..count], self.input[0..count]);
        return count;
    }
};

test "HTTP obfs read does not read twice after init consumed a partial frame" {
    const allocator = std.testing.allocator;
    var client = try ShadowsocksClient.initWithObfs(
        allocator,
        "127.0.0.1",
        8388,
        "password",
        "aes-128-gcm",
        simple_obfs_http.Config{
            .host = "www.example.com",
            .server_port = 8388,
        },
    );
    defer client.deinit();

    const salt = [_]u8{0} ** 16;
    var encrypt = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);
    var frame: [64]u8 = undefined;
    _ = try encrypt.encryptChunk("hello", &frame);
    const response = "HTTP/1.1 101 Switching Protocols\r\n\r\n";
    var wire: [response.len + salt.len + 10]u8 = undefined;
    @memcpy(wire[0..response.len], response);
    @memcpy(wire[response.len .. response.len + salt.len], &salt);
    @memcpy(wire[response.len + salt.len ..], frame[0..10]);

    var stream = OneReadStream{ .input = &wire };
    var output: [32]u8 = undefined;
    try std.testing.expectError(
        error.NeedMoreData,
        client.readFromStream(&stream, &output),
    );
    try std.testing.expectEqual(@as(usize, 1), stream.reads);
}
