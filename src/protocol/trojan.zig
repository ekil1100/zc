const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const crypto = std.crypto;
const tls = std.crypto.tls;
const TLSClient = @import("TLSClient.zig");
const Certificate = std.crypto.Certificate;
const socket_options = @import("../socket_options.zig");
const tls_server_name = @import("tls_server_name.zig");

/// Trojan 命令类型
pub const Command = enum(u8) {
    connect = 0x01,
    udp_associate = 0x03,
};

pub const CertificateStore = struct {
    allocator: std.mem.Allocator,
    bundle: Certificate.Bundle,
    lock: std.Io.RwLock,
    reference_mutex: std.Io.Mutex,
    reference_count: u32,

    pub fn create(allocator: std.mem.Allocator) !*CertificateStore {
        const store = try allocator.create(CertificateStore);
        errdefer allocator.destroy(store);
        store.* = .{
            .allocator = allocator,
            .bundle = .empty,
            .lock = .init,
            .reference_mutex = .init,
            .reference_count = 1,
        };
        errdefer store.bundle.deinit(allocator);
        try store.bundle.rescan(
            allocator,
            compat.io(),
            std.Io.Timestamp.now(compat.io(), .real),
        );
        return store;
    }

    pub fn acquire(store: *CertificateStore) *CertificateStore {
        std.Io.Threaded.mutexLock(&store.reference_mutex);
        defer std.Io.Threaded.mutexUnlock(&store.reference_mutex);
        std.debug.assert(store.reference_count > 0);
        std.debug.assert(store.reference_count < std.math.maxInt(u32));
        store.reference_count += 1;
        return store;
    }

    pub fn release(store: *CertificateStore) void {
        std.Io.Threaded.mutexLock(&store.reference_mutex);
        std.debug.assert(store.reference_count > 0);
        store.reference_count -= 1;
        const finalize = store.reference_count == 0;
        std.Io.Threaded.mutexUnlock(&store.reference_mutex);
        if (finalize) {
            store.bundle.deinit(store.allocator);
            store.allocator.destroy(store);
        }
    }
};

/// Configuration borrowed for the lifetime of one Trojan client.
pub const Config = struct {
    password: []const u8,
    address: []const u8,
    port: u16,
    sni: ?[]const u8 = null,
    skip_cert_verify: bool = false,
    certificate_store: ?*CertificateStore = null,
};

/// Owns one Trojan transport connection and its authentication state.
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    password_hash: [56]u8, // SHA-224 hex string (28 bytes * 2)
    tls_conn: ?*TLSConnection = null,
    write_closed: bool = false,
    close_notify_sent: bool = false,
    failed: bool = false,

    pub const RecordReadResult = union(enum) {
        data_byte_count: usize,
        control,
        would_block,
        eof,
    };

    const TLSConnection = struct {
        stream: net.Stream,
        stream_reader: net.Stream.Reader,
        stream_writer: net.Stream.Writer,
        tls_client: TLSClient,
        allow_truncation_attacks: bool,
        socket_read_buffer: [TLSClient.min_buffer_len]u8,
        socket_write_buffer: [TLSClient.min_buffer_len]u8,
        tls_read_buffer: [TLSClient.min_buffer_len]u8,
        tls_write_buffer: [TLSClient.min_buffer_len]u8,
    };

    const ConnectStreamOptions = struct {
        target_host: []const u8,
        target_port: u16,
        command: Command,
        allow_truncation_attacks: bool,
        close_stream_on_error: bool,
    };

    const UDPConnectTask = struct {
        client: *Client,
        stream: net.Stream,
        done: *compat.Notifier,
        error_value: ?anyerror = null,
        succeeded: bool = false,

        fn run(self: *UDPConnectTask) void {
            const connected_stream = self.client.connectStreamImpl(
                self.stream,
                .{
                    .target_host = "0.0.0.0",
                    .target_port = 0,
                    .command = .udp_associate,
                    .allow_truncation_attacks = false,
                    .close_stream_on_error = false,
                },
            ) catch |err| {
                self.error_value = err;
                self.done.signal();
                return;
            };
            std.debug.assert(connected_stream.handle == self.stream.handle);
            self.succeeded = true;
            self.done.signal();
        }
    };

    const WriteErrorSources = struct {
        tls_error: ?anyerror,
        transport_error: ?anyerror,
    };
    const ReadErrorSources = struct {
        tls_error: ?anyerror,
        transport_error: ?anyerror,
    };
    const HostOptions = @FieldType(TLSClient.Options, "host");
    const ConnectWaitResult = struct {
        completed: bool,
        canceled: bool,
        timed_out: bool,
    };

    pub fn init(
        target: *Client,
        allocator: std.mem.Allocator,
        config: Config,
    ) !void {
        tls_server_name.validateServer(config.address) catch {
            return error.InvalidServerName;
        };
        if (config.sni) |sni| {
            tls_server_name.validateSNI(sni) catch return error.InvalidSNI;
        } else if (!config.skip_cert_verify) {
            const server_host = tls_server_name.stripRootDot(config.address);
            if (tls_server_name.isIPLiteral(server_host)) {
                return error.SNIRequiredForVerifiedIP;
            }
        }

        target.allocator = allocator;
        target.config = config;
        if (config.certificate_store) |store| {
            target.config.certificate_store = store.acquire();
        }
        target.tls_conn = null;
        target.write_closed = false;
        target.close_notify_sent = false;
        target.failed = false;

        // Trojan authenticates with the lowercase SHA-224 hex form, not the
        // raw password bytes.
        var hash: [28]u8 = undefined;
        var sha = crypto.hash.sha2.Sha224.init(.{});
        sha.update(config.password);
        sha.final(&hash);

        // Writing into caller-owned storage avoids copying authentication
        // material through a temporary Client value.
        const hex_chars = "0123456789abcdef";
        for (hash, 0..) |byte, i| {
            target.password_hash[i * 2] = hex_chars[byte >> 4];
            target.password_hash[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
    }

    pub fn deinit(self: *Client) void {
        if (self.tls_conn) |conn| {
            self.closeTLSConnection(conn, !self.failed);
            self.tls_conn = null;
        }
        std.crypto.secureZero(u8, &self.password_hash);
        self.releaseCertificateStore();
    }

    /// Aborts without close_notify; callers may first shutdown a socket that
    /// another thread owns to unblock and join that owner.
    pub fn abort(self: *Client) void {
        if (self.tls_conn) |conn| {
            self.closeTLSConnection(conn, false);
            self.tls_conn = null;
        }
        std.crypto.secureZero(u8, &self.password_hash);
        self.releaseCertificateStore();
    }

    fn releaseCertificateStore(self: *Client) void {
        if (self.config.certificate_store) |store| {
            self.config.certificate_store = null;
            store.release();
        }
    }

    /// Connects one Trojan TCP byte stream.
    pub fn connect(
        self: *Client,
        target_host: []const u8,
        target_port: u16,
    ) !net.Stream {
        if (self.tls_conn != null) return error.AlreadyConnected;
        const stream = try net.tcpConnectToHost(
            self.allocator,
            self.config.address,
            self.config.port,
        );
        return self.connectStream(
            stream,
            target_host,
            target_port,
            .connect,
            true,
        );
    }

    /// Opens one Trojan UDP ASSOCIATE stream. DNS, TCP candidates, and TLS share
    /// one absolute deadline and observe cancel_fd while in flight. TLS itself
    /// remains subject to the documented partial-record blocking limit.
    pub fn connectUDP(
        self: *Client,
        absolute_deadline_ms: i64,
        cancel_fd: ?std.posix.fd_t,
    ) !net.Stream {
        if (self.tls_conn != null) return error.AlreadyConnected;
        try compat.checkCancelFD(cancel_fd);
        const remaining_ms = try deadlineRemainingMs(absolute_deadline_ms);
        var addresses = compat.net.getAddressListWithTimeoutCancelFD(
            self.allocator,
            self.config.address,
            self.config.port,
            remaining_ms,
            cancel_fd,
        ) catch |err| {
            try compat.checkCancelFD(cancel_fd);
            if (err == error.AddressResolutionTimeout) {
                return error.DeadlineExceeded;
            }
            if (deadlineExpired(absolute_deadline_ms)) {
                return error.DeadlineExceeded;
            }
            return err;
        };
        defer addresses.deinit();
        if (addresses.addrs.len == 0) {
            try compat.checkCancelFD(cancel_fd);
            if (deadlineExpired(absolute_deadline_ms)) {
                return error.DeadlineExceeded;
            }
            return error.UnknownHostName;
        }

        std.debug.assert(
            addresses.addrs.len <= compat.net.address_result_count_max,
        );
        var last_error: anyerror = error.ConnectFailed;
        for (0..compat.net.address_result_count_max) |address_index| {
            if (address_index == addresses.addrs.len) break;
            const address = addresses.addrs[address_index];
            try compat.checkCancelFD(cancel_fd);
            const stream = compat.net.tcpConnectToAddressWithDeadlineCancelFD(
                address,
                absolute_deadline_ms,
                cancel_fd,
            ) catch |err| {
                try compat.checkCancelFD(cancel_fd);
                if (err == error.Timeout) return error.DeadlineExceeded;
                if (deadlineExpired(absolute_deadline_ms)) {
                    return error.DeadlineExceeded;
                }
                last_error = err;
                continue;
            };
            return self.connectStreamCancelable(
                stream,
                absolute_deadline_ms,
                cancel_fd,
            );
        }
        try compat.checkCancelFD(cancel_fd);
        if (deadlineExpired(absolute_deadline_ms)) {
            return error.DeadlineExceeded;
        }
        return last_error;
    }

    fn waitForConnectTask(
        done: *compat.Notifier,
        cancel_fd: ?std.posix.fd_t,
        absolute_deadline_ms: i64,
    ) !ConnectWaitResult {
        var descriptors = [_]std.posix.pollfd{
            .{
                .fd = done.handle(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = cancel_fd orelse -1,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        const descriptor_count: usize = if (cancel_fd == null) 1 else 2;
        const ready_count = try compat.pollAbsolute(
            descriptors[0..descriptor_count],
            absolute_deadline_ms,
        );
        var canceled = false;
        if (descriptor_count == 2) {
            const cancel_events = descriptors[1].revents;
            canceled = cancel_events & (std.posix.POLL.IN |
                std.posix.POLL.HUP |
                std.posix.POLL.ERR |
                std.posix.POLL.NVAL) != 0;
        }
        const completion_events = descriptors[0].revents;
        const completed = completion_events & (std.posix.POLL.IN |
            std.posix.POLL.HUP |
            std.posix.POLL.ERR |
            std.posix.POLL.NVAL) != 0;
        return .{
            .completed = completed,
            .canceled = canceled,
            .timed_out = ready_count == 0,
        };
    }

    fn shutdownConnectSocketOrPanic(stream: net.Stream) void {
        compat.shutdownReadWrite(stream.handle) catch |err| {
            std.debug.panic(
                "socket shutdown before TLS join failed: {s}",
                .{@errorName(err)},
            );
        };
    }

    fn closeRejectedConnect(
        self: *Client,
        stream: net.Stream,
        task: *const UDPConnectTask,
    ) void {
        if (task.succeeded) {
            self.abort();
        } else {
            stream.close();
        }
    }

    fn connectStreamCancelable(
        self: *Client,
        stream: net.Stream,
        absolute_deadline_ms: i64,
        cancel_fd: ?std.posix.fd_t,
    ) !net.Stream {
        compat.checkCancelFD(cancel_fd) catch |err| {
            stream.close();
            return err;
        };
        if (deadlineExpired(absolute_deadline_ms)) {
            stream.close();
            return error.DeadlineExceeded;
        }

        var done = compat.Notifier.init() catch |err| {
            stream.close();
            return err;
        };
        defer done.deinit();
        var task = UDPConnectTask{
            .client = self,
            .stream = stream,
            .done = &done,
        };
        var thread = std.Thread.spawn(
            .{
                .stack_size = 512 * 1024,
                .allocator = null,
            },
            UDPConnectTask.run,
            .{&task},
        ) catch |err| {
            stream.close();
            return err;
        };
        var joined = false;
        defer if (!joined) {
            shutdownConnectSocketOrPanic(stream);
            thread.join();
            self.closeRejectedConnect(stream, &task);
        };

        const wait_result = try waitForConnectTask(
            &done,
            cancel_fd,
            absolute_deadline_ms,
        );
        const interrupted = if (wait_result.timed_out)
            true
        else
            wait_result.canceled;
        if (interrupted) {
            if (!wait_result.completed) shutdownConnectSocketOrPanic(stream);
            thread.join();
            joined = true;
            self.closeRejectedConnect(stream, &task);
            try compat.checkCancelFD(cancel_fd);
            if (wait_result.canceled) return error.Canceled;
            return error.DeadlineExceeded;
        }

        std.debug.assert(wait_result.completed);
        thread.join();
        joined = true;
        done.drain();
        compat.checkCancelFD(cancel_fd) catch |err| {
            self.closeRejectedConnect(stream, &task);
            return err;
        };
        if (deadlineExpired(absolute_deadline_ms)) {
            self.closeRejectedConnect(stream, &task);
            return error.DeadlineExceeded;
        }
        if (task.error_value) |err| {
            stream.close();
            return err;
        }
        std.debug.assert(task.succeeded);
        return self.tls_conn.?.stream;
    }

    fn connectStream(
        self: *Client,
        stream: net.Stream,
        target_host: []const u8,
        target_port: u16,
        command: Command,
        allow_truncation_attacks: bool,
    ) !net.Stream {
        return self.connectStreamImpl(
            stream,
            .{
                .target_host = target_host,
                .target_port = target_port,
                .command = command,
                .allow_truncation_attacks = allow_truncation_attacks,
                .close_stream_on_error = true,
            },
        );
    }

    fn connectStreamImpl(
        self: *Client,
        stream: net.Stream,
        options: ConnectStreamOptions,
    ) !net.Stream {
        if (self.tls_conn != null) return error.AlreadyConnected;
        socket_options.configureUpstreamProxySocket(stream.handle) catch |err| {
            if (options.close_stream_on_error) stream.close();
            return err;
        };

        const conn = self.initTLSConnection(
            stream,
            options.allow_truncation_attacks,
        ) catch |err| {
            if (options.close_stream_on_error) stream.close();
            return err;
        };
        self.handshake(
            conn,
            options.command,
            options.target_host,
            options.target_port,
        ) catch |err| {
            const surfaced_error = surfaceWriteError(conn, err);
            self.failed = true;
            if (options.close_stream_on_error) {
                self.deinitTLSConnection(conn);
            } else {
                std.crypto.secureZero(u8, std.mem.asBytes(conn));
                self.allocator.destroy(conn);
            }
            return surfaced_error;
        };

        self.tls_conn = conn;
        return conn.stream;
    }

    pub fn write(self: *Client, data: []const u8) !void {
        if (self.write_closed) return error.StreamClosed;
        const conn = self.tls_conn orelse return error.NotConnected;
        conn.tls_client.writer.writeAll(data) catch |err| {
            self.failed = true;
            return surfaceWriteError(conn, err);
        };
        flushTLSAndSocket(conn) catch |err| {
            self.failed = true;
            return surfaceWriteError(conn, err);
        };
    }

    pub fn shutdownWrite(self: *Client) !void {
        if (self.write_closed) return;
        if (self.failed) return error.StreamClosed;
        const conn = self.tls_conn orelse return error.NotConnected;
        self.write_closed = true;
        TLSClient.end(&conn.tls_client) catch |err| {
            self.failed = true;
            return surfaceWriteError(conn, err);
        };
        self.close_notify_sent = true;
        conn.stream_writer.interface.flush() catch |err| {
            self.failed = true;
            return surfaceWriteError(conn, err);
        };
    }

    pub fn read(self: *Client, buf: []u8) !usize {
        const conn = self.tls_conn orelse return error.NotConnected;
        const result = self.readOneRecord(buf) catch |err| {
            // Residual M1 exposure: an unframed Trojan TCP stream cannot
            // distinguish an injected truncation from a legitimate close.
            if (conn.allow_truncation_attacks) {
                if (isTruncationEOF(err, conn.tls_client.read_error)) {
                    return 0;
                }
            }
            return err;
        };
        return switch (result) {
            .data_byte_count => |read_byte_count| read_byte_count,
            .control, .would_block => error.WouldBlock,
            .eof => 0,
        };
    }

    pub fn readBlocking(self: *Client, buf: []u8) !usize {
        const conn = self.tls_conn orelse return error.NotConnected;
        return readTLSApplicationData(&conn.tls_client.reader, buf) catch |err| {
            self.failed = true;
            const surfaced_error = surfaceReadError(conn, err);
            if (conn.allow_truncation_attacks) {
                if (isTruncationEOF(
                    surfaced_error,
                    conn.tls_client.read_error,
                )) {
                    return 0;
                }
            }
            return surfaced_error;
        };
    }

    fn surfaceWriteError(conn: *const TLSConnection, err: anyerror) anyerror {
        return selectWriteError(err, .{
            .tls_error = conn.tls_client.write_error,
            .transport_error = conn.stream_writer.err,
        });
    }

    fn surfaceTLSInitError(
        conn: *const TLSConnection,
        err: anyerror,
    ) anyerror {
        if (err == error.WriteFailed) {
            return conn.stream_writer.err orelse err;
        }
        if (err == error.ReadFailed) {
            return conn.stream_reader.err orelse err;
        }
        return err;
    }

    fn selectWriteError(
        err: anyerror,
        sources: WriteErrorSources,
    ) anyerror {
        if (err != error.WriteFailed) return err;
        if (sources.tls_error != null) return err;
        return sources.transport_error orelse err;
    }

    fn surfaceReadError(conn: *const TLSConnection, err: anyerror) anyerror {
        return selectReadError(err, .{
            .tls_error = conn.tls_client.read_error,
            .transport_error = conn.stream_reader.err,
        });
    }

    fn selectReadError(
        err: anyerror,
        sources: ReadErrorSources,
    ) anyerror {
        if (err != error.ReadFailed) return err;
        if (sources.tls_error != null) return err;
        return sources.transport_error orelse err;
    }

    /// Pure M1 decision: should a readTLSApplicationData failure be treated as a
    /// clean EOF (return 0) or propagated? Only an unframed TLS truncation —
    /// surfaced as `error.ReadFailed` with `read_error == TLSConnectionTruncated` —
    /// maps to EOF; any other failure (bad record MAC, alert, or a ReadFailed with
    /// no recorded tls read_error) propagates. Extracting this keeps the
    /// security-relevant discrimination in one tested place: an accidental
    /// inversion (swallowing a fatal alert as EOF, or propagating a benign
    /// truncation) fails a unit test instead of slipping through to the relay.
    fn isTruncationEOF(err: anyerror, read_error: ?anyerror) bool {
        if (err != error.ReadFailed) return false;
        const tls_err = read_error orelse return false;
        return tls_err == error.TLSConnectionTruncated;
    }

    pub fn readOneRecord(
        self: *Client,
        buf: []u8,
    ) !RecordReadResult {
        const conn = self.tls_conn orelse return error.NotConnected;
        const event = conn.tls_client.readOneRecord() catch |err| {
            self.failed = true;
            return surfaceReadError(conn, err);
        };
        return switch (event) {
            .application_data => blk: {
                const buffered = conn.tls_client.reader.buffered();
                std.debug.assert(buffered.len > 0);
                const read_byte_count = @min(buf.len, buffered.len);
                @memcpy(buf[0..read_byte_count], buffered[0..read_byte_count]);
                conn.tls_client.reader.seek += read_byte_count;
                break :blk .{ .data_byte_count = read_byte_count };
            },
            .control => .control,
            .need_more => .would_block,
            .eof => .eof,
        };
    }

    pub fn hasPendingRead(self: *const Client) bool {
        if (self.tls_conn) |conn| {
            if (conn.tls_client.reader.bufferedLen() > 0) return true;
            return hasCompleteTLSRecord(
                conn.stream_reader.interface.buffered(),
            );
        }
        return false;
    }

    pub fn pollHandle(self: *const Client) std.posix.fd_t {
        const conn = self.tls_conn orelse return -1;
        return conn.stream.handle;
    }

    fn hasCompleteTLSRecord(buffered: []const u8) bool {
        const header_size: usize = 5;
        if (buffered.len < header_size) return false;
        const payload_size = std.mem.readInt(u16, buffered[3..5], .big);
        if (payload_size > tls.max_ciphertext_len) return true;
        return buffered.len >= header_size + payload_size;
    }

    /// Diagnostic: the most recent underlying std.crypto.tls read error, if any.
    /// A relay teardown surfaces only `error.ReadFailed`; this exposes the real
    /// cause so logs can tell a benign `TLSConnectionTruncated` (upstream dropped
    /// the TCP mid-record without close_notify — the suspected brew-download
    /// failure) apart from a genuinely fatal `TlsBadRecordMac`/`TlsAlert`.
    pub fn lastReadError(self: *const Client) ?anyerror {
        if (self.tls_conn) |conn| {
            if (conn.tls_client.read_error) |read_error| return read_error;
            if (conn.stream_reader.err) |transport_error| return transport_error;
        }
        return null;
    }

    fn initTLSConnection(
        self: *Client,
        stream: net.Stream,
        allow_truncation_attacks: bool,
    ) !*TLSConnection {
        const conn = try self.allocator.create(TLSConnection);
        errdefer self.allocator.destroy(conn);

        conn.stream = stream;
        conn.socket_read_buffer = undefined;
        conn.socket_write_buffer = undefined;
        conn.tls_read_buffer = undefined;
        conn.tls_write_buffer = undefined;
        conn.stream_reader = conn.stream.reader(&conn.socket_read_buffer);
        conn.stream_writer = conn.stream.writer(&conn.socket_write_buffer);
        conn.tls_client = undefined;

        var entropy: [TLSClient.Options.entropy_len]u8 = undefined;
        compat.randomBytes(&entropy);
        defer std.crypto.secureZero(u8, &entropy);
        const now = std.Io.Timestamp.now(compat.io(), .real);
        var options = TLSClient.Options{
            .host = self.hostOption(),
            .server_name = self.serverName(),
            .ca = .{ .no_verification = {} },
            .read_buffer = &conn.tls_read_buffer,
            .write_buffer = &conn.tls_write_buffer,
            .entropy = &entropy,
            .realtime_now = now,
            .ssl_key_log = null,
            .alert = null,
        };

        if (!self.config.skip_cert_verify) {
            const store = self.config.certificate_store orelse
                return error.CertificateStoreRequired;
            options.ca = .{ .bundle = .{
                .gpa = self.allocator,
                .io = compat.io(),
                .lock = &store.lock,
                .bundle = &store.bundle,
            } };
        }

        TLSClient.init(
            &conn.tls_client,
            &conn.stream_reader.interface,
            &conn.stream_writer.interface,
            options,
        ) catch |err| return surfaceTLSInitError(conn, err);
        // TCP preserves the accepted M1 truncation tradeoff. UDP frames reject
        // truncation, while both paths retain the underlying TLS diagnostic.
        conn.allow_truncation_attacks = allow_truncation_attacks;

        return conn;
    }

    fn certificateHost(self: *const Client) []const u8 {
        if (self.config.sni) |sni| return sni;
        return tls_server_name.stripRootDot(self.config.address);
    }

    fn hostOption(self: *const Client) HostOptions {
        return if (self.config.skip_cert_verify)
            .{ .no_verification = {} }
        else
            .{ .explicit = self.certificateHost() };
    }

    fn serverName(self: *const Client) ?[]const u8 {
        if (self.config.sni) |sni| return sni;
        const certificate_host = self.certificateHost();
        if (tls_server_name.isIPLiteral(certificate_host)) return null;
        return certificate_host;
    }

    fn closeTLSConnection(
        self: *Client,
        conn: *TLSConnection,
        send_close_notify: bool,
    ) void {
        if (send_close_notify) {
            if (!self.close_notify_sent) {
                if (conn.tls_client.end()) |_| {
                    self.close_notify_sent = true;
                    conn.stream_writer.interface.flush() catch |err| {
                        std.log.debug(
                            "Trojan TLS close_notify flush failed: {s}",
                            .{@errorName(err)},
                        );
                    };
                } else |err| {
                    std.log.debug(
                        "Trojan TLS close_notify encoding failed: {s}",
                        .{@errorName(err)},
                    );
                }
            }
        }
        conn.stream.close();
        std.crypto.secureZero(u8, std.mem.asBytes(conn));
        self.allocator.destroy(conn);
    }

    fn deinitTLSConnection(self: *Client, conn: *TLSConnection) void {
        self.closeTLSConnection(conn, !self.failed);
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
    fn handshake(
        self: *Client,
        conn: *TLSConnection,
        command: Command,
        target_host: []const u8,
        target_port: u16,
    ) !void {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try self.buildRequest(&buf, command, target_host, target_port);

        // Flush the request onto the wire before connect() returns. The relay
        // only read()s the target once poll() reports it readable, and a
        // server-speaks-first peer sends nothing until it has received our
        // request — so deferring this flush to the first write()/read() can
        // deadlock that peer (the request it is waiting for is never sent).
        // Sending eagerly costs the request its own small TLS record (we no
        // longer coalesce it with the first payload), which is the correct
        // trade for not hanging server-first tunnels.
        try conn.tls_client.writer.writeAll(buf.items);
        try flushTLSAndSocket(conn);
    }

    fn flushTLSAndSocket(conn: *TLSConnection) !void {
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
    fn readTLSApplicationData(reader: *std.Io.Reader, out: []u8) !usize {
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

fn deadlineExpired(absolute_deadline_ms: i64) bool {
    return compat.monotonicMilliTimestamp() >= absolute_deadline_ms;
}

fn deadlineRemainingMs(absolute_deadline_ms: i64) !u32 {
    const now_ms = compat.monotonicMilliTimestamp();
    if (now_ms >= absolute_deadline_ms) return error.DeadlineExceeded;
    const remaining_ms = std.math.sub(
        i64,
        absolute_deadline_ms,
        now_ms,
    ) catch return error.DeadlineExceeded;
    return @intCast(@min(
        remaining_ms,
        @as(i64, std.math.maxInt(u32)),
    ));
}

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

/// 测试
const testing = std.testing;

test "Trojan password hash" {
    const allocator = testing.allocator;

    // The wire-critical password_hash is the lowercase-hex SHA-224 of the
    // password. Pin the EXACT digest (verified out-of-band with sha224sum), not
    // just its 56-byte length: a fabricated/placeholder hash would silently send
    // the wrong credential. "password123" mixes hex nibbles both >9 (d,9,b,e,f)
    // and <9 (3,4,0,1,2,5), exercising both arms of the init() hex loop.
    var client: Client = undefined;
    try Client.init(&client, allocator, .{
        .password = "password123",
        .address = "127.0.0.1",
        .port = 443,
        .skip_cert_verify = true,
    });
    try testing.expectEqualStrings(
        "3d45597256050bb1e93bd9c10aee4c8716f8774f5a48c995bf0cf860",
        &client.password_hash,
    );

    // Second vector, independently verified, re-exercises the hex loop.
    var client2: Client = undefined;
    try Client.init(&client2, allocator, .{
        .password = "Test",
        .address = "127.0.0.1",
        .port = 443,
        .skip_cert_verify = true,
    });
    try testing.expectEqualStrings(
        "3606346815fd4d491a92649905a40da025d8cf15f095136b19f37923",
        &client2.password_hash,
    );
}

test "Trojan certificate store survives owner release while a client lease exists" {
    // Simulate manager teardown before an active handshake releases its lease,
    // and let the final lease perform the only bundle destruction.
    const allocator = testing.allocator;
    const store = try allocator.create(CertificateStore);
    store.* = .{
        .allocator = allocator,
        .bundle = .empty,
        .lock = .init,
        .reference_mutex = .init,
        .reference_count = 1,
    };
    const client_lease = store.acquire();
    store.release();
    try testing.expectEqual(
        @as(u32, 1),
        client_lease.reference_count,
    );
    client_lease.release();
}

test "Trojan client deinit clears the authentication hash" {
    // Drive the Trojan client or wire seam with focused input and inspect the observable result.
    var client: Client = undefined;
    try Client.init(&client, testing.allocator, .{
        .password = "secret",
        .address = "edge.example.com",
        .port = 443,
    });
    client.deinit();
    try testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** 56),
        &client.password_hash,
    );
}

test "Trojan client rejects unsafe TLS names before hashing or dialing" {
    // Initialize focused endpoint identities and verify rejection occurs before
    // authentication hashing or network access.
    const allocator = testing.allocator;
    var invalid_server_name_client: Client = undefined;
    try testing.expectError(error.InvalidServerName, Client.init(
        &invalid_server_name_client,
        allocator,
        .{
            .password = "test",
            .address = "a" ** (tls_server_name.bytes_max + 1),
            .port = 443,
        },
    ));
    var numeric_root_client: Client = undefined;
    try testing.expectError(error.InvalidServerName, Client.init(
        &numeric_root_client,
        allocator,
        .{
            .password = "test",
            .address = "127.0.0.1.",
            .port = 443,
            .skip_cert_verify = true,
        },
    ));
    var invalid_sni_client: Client = undefined;
    try testing.expectError(error.InvalidSNI, Client.init(
        &invalid_sni_client,
        allocator,
        .{
            .password = "test",
            .address = "edge.example.com",
            .port = 443,
            .sni = "bad\nname",
        },
    ));
}

test "Trojan UDP TLS handshake cancellation closes the upstream stream" {
    // Drive the Trojan client or wire seam with focused input and inspect the observable result.
    const allocator = testing.allocator;
    const listen_address = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try net.listenReuseAddr(listen_address);
    var server_open = true;
    defer if (server_open) server.deinit();
    var accepted = try compat.Notifier.init();
    defer accepted.deinit();

    const ServerContext = struct {
        server: *net.ReuseAddrListener,
        accepted: *compat.Notifier,
        eof: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            const connection = self.server.accept() catch |err| {
                self.failure = err;
                self.accepted.signal();
                return;
            };
            defer connection.stream.close();
            self.accepted.signal();
            const deadline_ms = compat.monotonicMilliTimestamp() + 5_000;
            var buffer: [4096]u8 = undefined;
            const read_attempt_count_max: u16 = 256;
            for (0..read_attempt_count_max) |_| {
                var descriptors = [_]std.posix.pollfd{.{
                    .fd = connection.stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ready = compat.pollAbsolute(
                    &descriptors,
                    deadline_ms,
                ) catch |err| {
                    self.failure = err;
                    return;
                };
                if (ready == 0) {
                    self.failure = error.TestServerTimeout;
                    return;
                }
                const count = connection.stream.read(&buffer) catch |err| {
                    self.failure = err;
                    return;
                };
                if (count == 0) {
                    self.eof.store(true, .release);
                    return;
                }
            }
            self.failure = error.TestReadIterationLimitExceeded;
        }
    };
    var server_context = ServerContext{
        .server = &server,
        .accepted = &accepted,
    };
    const server_thread = try std.Thread.spawn(
        .{
            .stack_size = std.Thread.SpawnConfig.default_stack_size,
            .allocator = null,
        },
        ServerContext.run,
        .{&server_context},
    );
    var server_joined = false;
    defer if (!server_joined) {
        if (server_open) {
            server.deinit();
            server_open = false;
        }
        server_thread.join();
    };

    var cancel_fds: [2]c_int = undefined;
    if (std.c.socketpair(
        std.c.AF.UNIX,
        std.c.SOCK.STREAM,
        0,
        &cancel_fds,
    ) != 0) {
        return error.SocketPairFailed;
    }
    defer {
        std.debug.assert(std.c.close(cancel_fds[0]) == 0);
    }
    defer {
        std.debug.assert(std.c.close(cancel_fds[1]) == 0);
    }

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "secret",
        .address = "127.0.0.1",
        .port = server.listen_address.getPort(),
        .skip_cert_verify = true,
    });
    defer client.deinit();
    const ClientContext = struct {
        client: *Client,
        cancel_fd: std.posix.fd_t,
        error_value: ?anyerror = null,
        succeeded: bool = false,

        fn run(self: *@This()) void {
            const stream = self.client.connectUDP(
                compat.monotonicMilliTimestamp() + 5_000,
                self.cancel_fd,
            ) catch |err| {
                self.error_value = err;
                return;
            };
            std.debug.assert(stream.handle == self.client.pollHandle());
            self.succeeded = true;
        }
    };
    var client_context = ClientContext{
        .client = &client,
        .cancel_fd = cancel_fds[0],
    };
    const client_thread = try std.Thread.spawn(
        .{
            .stack_size = std.Thread.SpawnConfig.default_stack_size,
            .allocator = null,
        },
        ClientContext.run,
        .{&client_context},
    );
    var client_joined = false;
    defer if (!client_joined) {
        compat.shutdownReadWrite(cancel_fds[1]) catch |err| {
            std.debug.panic(
                "test cancellation shutdown failed: {s}",
                .{@errorName(err)},
            );
        };
        client_thread.join();
    };

    var accepted_descriptors = [_]std.posix.pollfd{.{
        .fd = accepted.handle(),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const accepted_ready = try compat.pollAbsolute(
        &accepted_descriptors,
        compat.monotonicMilliTimestamp() + 2_000,
    );
    try testing.expectEqual(@as(usize, 1), accepted_ready);
    const cancel_byte = [_]u8{1};
    try testing.expectEqual(
        @as(isize, 1),
        std.c.write(cancel_fds[1], &cancel_byte, cancel_byte.len),
    );

    client_thread.join();
    client_joined = true;
    server_thread.join();
    server_joined = true;
    try testing.expect(!client_context.succeeded);
    try testing.expectEqual(error.Canceled, client_context.error_value.?);
    try testing.expect(server_context.failure == null);
    try testing.expect(server_context.eof.load(.acquire));
}

test "Trojan connect rejects an already-connected client" {
    const allocator = testing.allocator;

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
        .skip_cert_verify = true,
    });

    // Simulate a client that has already established a TLS session: the guard at
    // the top of connect() (`if (self.tls_conn != null) return error.AlreadyConnected`)
    // must fire BEFORE touching any field, so this stub never needs valid buffers.
    const stub = try testing.allocator.create(Client.TLSConnection);
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

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
        .skip_cert_verify = true,
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

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
        .skip_cert_verify = true,
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

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
        .sni = "m.ctrip.com",
    });

    try testing.expectEqualStrings("m.ctrip.com", client.certificateHost());
}

test "Trojan TLS host falls back to server address when sni is absent" {
    const allocator = testing.allocator;

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
    });

    try testing.expectEqualStrings("server.example.com", client.certificateHost());
}

test "Trojan strips a DNS root dot from derived SNI and identity" {
    // Drive the Trojan client or wire seam with focused input and inspect the observable result.
    var client: Client = undefined;
    try Client.init(&client, testing.allocator, .{
        .password = "test",
        .address = "edge.example.com.",
        .port = 443,
    });
    try testing.expectEqualStrings("edge.example.com", client.certificateHost());
    try testing.expectEqualStrings(
        "edge.example.com",
        client.serverName().?,
    );
}

test "Trojan omits SNI for unverified IP-literal server" {
    // Drive the Trojan client or wire seam with focused input and inspect the observable result.
    const allocator = testing.allocator;

    var v4: Client = undefined;

    try Client.init(&v4, allocator, .{
        .password = "test",
        .address = "192.168.1.2",
        .port = 443,
        .skip_cert_verify = true,
    });
    try testing.expect(v4.serverName() == null);

    var v6: Client = undefined;

    try Client.init(&v6, allocator, .{
        .password = "test",
        .address = "2001:db8::1",
        .port = 443,
        .skip_cert_verify = true,
    });
    try testing.expect(v6.serverName() == null);
}

test "Trojan sends SNI for hostname server" {
    // Drive the Trojan client or wire seam with focused input and inspect the observable result.
    const allocator = testing.allocator;

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
    });

    try testing.expectEqualStrings(
        "server.example.com",
        client.serverName().?,
    );
}

test "Trojan keeps explicit sni even when address is an IP" {
    const allocator = testing.allocator;

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "8.8.8.8",
        .port = 443,
        .sni = "m.ctrip.com",
    });

    try testing.expectEqualStrings("m.ctrip.com", client.serverName().?);
    try testing.expectEqualStrings("m.ctrip.com", client.certificateHost());
}

test "Trojan skip-cert-verify keeps SNI while disabling identity checks" {
    // Drive the Trojan client or wire seam with focused input and inspect the observable result.
    var client: Client = undefined;
    try Client.init(&client, testing.allocator, .{
        .password = "test",
        .address = "192.0.2.1",
        .port = 443,
        .sni = "mismatch.example.com",
        .skip_cert_verify = true,
    });
    try testing.expectEqual(
        std.meta.Tag(Client.HostOptions).no_verification,
        std.meta.activeTag(client.hostOption()),
    );
    try testing.expectEqualStrings(
        "mismatch.example.com",
        client.serverName().?,
    );
}

test "Trojan requires sni when verifying an IP-literal server" {
    // Drive the Trojan client or wire seam with focused input and inspect the observable result.
    var client: Client = undefined;
    try testing.expectError(
        error.SNIRequiredForVerifiedIP,
        Client.init(&client, testing.allocator, .{
            .password = "test",
            .address = "8.8.8.8",
            .port = 443,
        }),
    );
}

test "Trojan lastReadError is null before any TLS connection" {
    const allocator = testing.allocator;
    var client: Client = undefined;
    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
        .skip_cert_verify = true,
    });
    // tls_conn stays null until connect() dials, so there is no underlying
    // read_error to surface. This pins the breadcrumb the M1/M5 docs lean on:
    // a regression that always returned a non-null/garbage error would fail here.
    try testing.expectEqual(@as(?anyerror, null), client.lastReadError());
}

test "Trojan hasPendingRead returns false when not connected" {
    const allocator = testing.allocator;

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
    });

    try testing.expect(!client.hasPendingRead());
}

test "Trojan socket readiness requires one complete TLS record" {
    // Drive the Trojan client or wire seam with focused input and inspect the observable result.
    try testing.expect(!Client.hasCompleteTLSRecord(""));
    try testing.expect(!Client.hasCompleteTLSRecord("\x17\x03\x03\x00"));
    try testing.expect(!Client.hasCompleteTLSRecord(
        "\x17\x03\x03\x00\x03ab",
    ));
    try testing.expect(Client.hasCompleteTLSRecord(
        "\x17\x03\x03\x00\x03abc",
    ));
    try testing.expect(Client.hasCompleteTLSRecord(
        "\x17\x03\x03\xff\xff",
    ));
}

test "Trojan read uses TLS buffered short-read semantics" {
    // Drive readTLSApplicationData (the helper read() delegates to) against an
    // injectable fixed reader: it returns up to out.len buffered bytes per call
    // (a short read), advancing the reader, never blocking for a full fill.
    var r = std.Io.Reader.fixed("abcdef");

    var out: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try Client.readTLSApplicationData(&r, &out));
    try testing.expectEqualStrings("abcd", &out);

    // Second call returns the remainder even though the destination is larger.
    var rest: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try Client.readTLSApplicationData(&r, &rest));
    try testing.expectEqualStrings("ef", rest[0..2]);

    // Stream fully drained -> clean EOF (0), not an error.
    try testing.expectEqual(@as(usize, 0), try Client.readTLSApplicationData(&r, &rest));
}

test "Trojan write errors surface transport failures when TLS has no detail" {
    // Simulate Writer error channels and verify a reset replaces only an
    // otherwise-unclassified WriteFailed error.
    try testing.expectEqual(
        error.ConnectionResetByPeer,
        Client.selectWriteError(error.WriteFailed, .{
            .tls_error = null,
            .transport_error = error.ConnectionResetByPeer,
        }),
    );
    try testing.expectEqual(
        error.WriteFailed,
        Client.selectWriteError(error.WriteFailed, .{
            .tls_error = error.TLSSequenceOverflow,
            .transport_error = error.ConnectionResetByPeer,
        }),
    );
}

test "Trojan read errors surface transport failures when TLS has no detail" {
    // Simulate the nested Reader error channels and verify a transport reset
    // replaces only an otherwise-unclassified ReadFailed error.
    try testing.expectEqual(
        error.ConnectionResetByPeer,
        Client.selectReadError(error.ReadFailed, .{
            .tls_error = null,
            .transport_error = error.ConnectionResetByPeer,
        }),
    );
    try testing.expectEqual(
        error.ReadFailed,
        Client.selectReadError(error.ReadFailed, .{
            .tls_error = error.TlsBadRecordMac,
            .transport_error = error.ConnectionResetByPeer,
        }),
    );
}

test "Trojan isTruncationEOF maps only a TLS truncation to EOF" {
    // The M1 decision read()'s catch arm relies on: a truncation (ReadFailed with
    // read_error == TLSConnectionTruncated) is a clean EOF; everything else
    // propagates. Pinned so an inversion fails here instead of in the relay.
    try testing.expect(Client.isTruncationEOF(error.ReadFailed, error.TLSConnectionTruncated));
    // Fatal TLS errors must propagate, NOT be swallowed as EOF.
    try testing.expect(!Client.isTruncationEOF(error.ReadFailed, error.TlsBadRecordMac));
    try testing.expect(!Client.isTruncationEOF(error.ReadFailed, error.TlsAlert));
    // ReadFailed with no recorded tls read_error -> cannot prove truncation -> propagate.
    try testing.expect(!Client.isTruncationEOF(error.ReadFailed, null));
    // A non-ReadFailed error is never EOF, even if a truncation was also recorded.
    try testing.expect(!Client.isTruncationEOF(
        error.ConnectionResetByPeer,
        error.TLSConnectionTruncated,
    ));
    try testing.expect(!Client.isTruncationEOF(error.WouldBlock, null));
}

test "Trojan readTLSApplicationData reports drained/empty stream as EOF" {
    // An empty fixed reader yields error.EndOfStream from fillMore, which
    // readTLSApplicationData translates into a clean 0-length read. This 0-return
    // is the mechanism read() relies on: when the underlying TLSClient surfaces
    // error.TLSConnectionTruncated (TCP dropped mid-record without close_notify),
    // read() maps it to EOF too. That TLSConnectionTruncated->0 translation needs
    // a live TLSClient and stays integration-only; the EOF semantics it builds on
    // are pinned here.
    var empty = std.Io.Reader.fixed("");
    var out: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try Client.readTLSApplicationData(&empty, &out));

    // Zero-length destination short-circuits without touching the reader.
    var r = std.Io.Reader.fixed("xyz");
    try testing.expectEqual(@as(usize, 0), try Client.readTLSApplicationData(&r, out[0..0]));
    // ...and the reader is left untouched: the next real read still sees "xyz".
    try testing.expectEqual(@as(usize, 3), try Client.readTLSApplicationData(&r, &out));
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

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
        .skip_cert_verify = true,
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

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "127.0.0.1",
        .port = 443,
        .skip_cert_verify = true,
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

test "Trojan buildRequest emits exact wire frame for IPv4 target" {
    const allocator = testing.allocator;

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
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

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
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

test "Trojan buildRequest emits UDP ASSOCIATE sentinel request" {
    // Drive the Trojan client or wire seam with focused input and inspect the observable result.
    const allocator = testing.allocator;
    var client: Client = undefined;
    try Client.init(&client, allocator, .{
        .password = "test",
        .address = "server.example.com",
        .port = 443,
    });
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try client.buildRequest(
        &buffer,
        .udp_associate,
        "0.0.0.0",
        0,
    );

    try testing.expectEqualSlices(
        u8,
        &client.password_hash,
        buffer.items[0..56],
    );
    try testing.expectEqualSlices(u8, "\r\n", buffer.items[56..58]);
    try testing.expectEqual(@as(u8, 0x03), buffer.items[58]);
    try testing.expectEqualSlices(
        u8,
        "\x01\x00\x00\x00\x00\x00\x00\r\n",
        buffer.items[59..68],
    );
    try testing.expectEqual(@as(usize, 68), buffer.items.len);
}

test "Trojan buildRequest emits exact wire frame for domain target" {
    const allocator = testing.allocator;

    var client: Client = undefined;

    try Client.init(&client, allocator, .{
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
