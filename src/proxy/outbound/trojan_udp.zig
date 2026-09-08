const std = @import("std");
const compat = @import("../../compat.zig");
const socks_address = @import("../../protocol/socks_address.zig");
const trojan = @import("../../protocol/trojan.zig");
const codec = @import("../../protocol/trojan_udp.zig");

const domain_resolution_timeout_ms: i64 = 5_000;
const receive_queue_capacity: u8 = 2;
const send_queue_capacity: u8 = 2;
const io_stack_size_bytes: usize = 256 * 1024;
const resolved_address_size_max: usize = 19;
const resolved_domain_size_max: usize = 255;
const io_event_loop_is_intentionally_unbounded = true;

comptime {
    std.debug.assert(io_event_loop_is_intentionally_unbounded);
    std.debug.assert(socks_address.encoded_size_max <= std.math.maxInt(u16));
    std.debug.assert(codec.payload_size_max <= std.math.maxInt(u16));
    std.debug.assert(codec.frame_size_max <= std.math.maxInt(u32));
    std.debug.assert(resolved_address_size_max <= std.math.maxInt(u8));
    std.debug.assert(resolved_domain_size_max <= std.math.maxInt(u8));
}

pub const Datagram = struct {
    source: socks_address.Parsed,
    payload: []const u8,
};

pub const ReceiveResult = union(enum) {
    datagram: Datagram,
    would_block,
    eof,
};

const ReceiveSlot = struct {
    address: [socks_address.encoded_size_max]u8,
    address_byte_count: u16,
    payload: [codec.payload_size_max]u8,
    payload_byte_count: u16,
};

const SendSlot = struct {
    frame: [codec.frame_size_max]u8,
    frame_byte_count: u32,
};

const SessionImpl = struct {
    allocator: std.mem.Allocator,
    cancel_fd: ?std.posix.fd_t,
    client: trojan.Client,
    receive_ready: compat.Notifier,
    send_ready: compat.Notifier,
    io_thread: std.Thread,
    stopping: std.atomic.Value(bool),
    state_mutex: std.Io.Mutex,
    terminal_error: ?anyerror,
    eof: bool,
    receive_queue: [receive_queue_capacity]ReceiveSlot,
    receive_head_index: u8,
    receive_count: u8,
    send_queue: [send_queue_capacity]SendSlot,
    send_head_index: u8,
    send_count: u8,
    decoder: codec.Decoder,
    delivery_address: [socks_address.encoded_size_max]u8,
    delivery_payload: [codec.payload_size_max]u8,
    resolved_address: [resolved_address_size_max]u8,
    resolved_address_byte_count: u8,
    resolved_domain: [resolved_domain_size_max]u8,
    resolved_domain_byte_count: u8,
    resolved_port: u16,
    encode_buffer: [codec.frame_size_max]u8,
    io_write_buffer: [codec.frame_size_max]u8,

    comptime {
        std.debug.assert(@sizeOf(@This()) <= 640 * 1024);
    }

    fn lock(self: *SessionImpl) void {
        std.Io.Threaded.mutexLock(&self.state_mutex);
    }

    fn unlock(self: *SessionImpl) void {
        std.Io.Threaded.mutexUnlock(&self.state_mutex);
    }

    fn ioMain(self: *SessionImpl) void {
        while (!self.stopping.load(.acquire)) {
            if (self.client.hasPendingRead()) {
                if (!self.readIncoming()) return;
                if (!self.flushOutboundQuota()) return;
                continue;
            }

            var descriptors = [_]std.posix.pollfd{
                .{
                    .fd = self.client.pollHandle(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
                .{
                    .fd = self.send_ready.handle(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };
            const ready_count = compat.pollAbsolute(
                &descriptors,
                std.math.maxInt(i64),
            ) catch |err| {
                self.publishTerminal(err);
                return;
            };
            if (ready_count == 0) continue;
            if (self.stopping.load(.acquire)) return;

            const stream_events = descriptors[0].revents;
            if (stream_events & std.posix.POLL.NVAL != 0) {
                self.publishTerminal(error.InvalidSessionSocket);
                return;
            }
            if (stream_events & (std.posix.POLL.IN |
                std.posix.POLL.HUP |
                std.posix.POLL.ERR) != 0)
            {
                if (!self.readIncoming()) return;
            }
            if (self.stopping.load(.acquire)) return;

            const send_events = descriptors[1].revents;
            if (send_events & std.posix.POLL.NVAL != 0) {
                self.publishTerminal(error.InvalidNotifier);
                return;
            }
            if (send_events & (std.posix.POLL.IN |
                std.posix.POLL.HUP |
                std.posix.POLL.ERR) != 0)
            {
                if (!self.flushOutboundQuota()) return;
            }
        }
    }

    fn flushOutboundQuota(self: *SessionImpl) bool {
        self.send_ready.drain();
        const quota = self.outboundCount();
        for (0..quota) |_| {
            const frame = self.takeOutbound() orelse break;
            self.client.write(frame) catch |err| {
                self.publishTerminal(err);
                return false;
            };
            if (self.stopping.load(.acquire)) return false;
        }
        if (self.outboundCount() > 0) self.send_ready.signal();
        return true;
    }

    fn outboundCount(self: *SessionImpl) usize {
        self.lock();
        defer self.unlock();
        return @intCast(self.send_count);
    }

    fn readIncoming(self: *SessionImpl) bool {
        const writable = self.decoder.writable();
        if (writable.len == 0) {
            self.publishTerminal(error.DatagramTooLarge);
            return false;
        }
        const read_result = self.client.readOneRecord(writable) catch |err| {
            self.publishTerminal(err);
            return false;
        };
        const read_byte_count = switch (read_result) {
            .data_byte_count => |read_byte_count| read_byte_count,
            .control, .would_block => return true,
            .eof => {
                self.decoder.finish() catch |err| {
                    self.publishTerminal(err);
                    return false;
                };
                self.publishEOF();
                return false;
            },
        };
        std.debug.assert(read_byte_count > 0);
        self.decoder.commit(read_byte_count);

        for (0..codec.frame_size_max) |_| {
            if (self.stopping.load(.acquire)) return false;
            const decoded = self.decoder.next() catch |err| {
                self.publishTerminal(err);
                return false;
            };
            switch (decoded) {
                .need_more => return true,
                .datagram => |datagram| self.publishDatagram(
                    datagram.address,
                    datagram.payload,
                ),
            }
        }
        self.publishTerminal(error.DatagramIterationLimitExceeded);
        return false;
    }

    fn takeOutbound(self: *SessionImpl) ?[]const u8 {
        self.lock();
        defer self.unlock();
        if (self.send_count == 0) return null;
        std.debug.assert(self.send_head_index < send_queue_capacity);
        std.debug.assert(self.send_count <= send_queue_capacity);

        const send_head_index = self.send_head_index;
        const slot = &self.send_queue[@intCast(send_head_index)];
        const frame_byte_count: usize = @intCast(slot.frame_byte_count);
        std.debug.assert(frame_byte_count <= slot.frame.len);
        std.debug.assert(frame_byte_count <= self.io_write_buffer.len);
        @memcpy(
            self.io_write_buffer[0..frame_byte_count],
            slot.frame[0..frame_byte_count],
        );
        self.send_head_index =
            (send_head_index + 1) % send_queue_capacity;
        self.send_count -= 1;
        return self.io_write_buffer[0..frame_byte_count];
    }

    fn publishDatagram(
        self: *SessionImpl,
        source: socks_address.Parsed,
        payload: []const u8,
    ) void {
        std.debug.assert(source.raw.len <= socks_address.encoded_size_max);
        std.debug.assert(payload.len <= codec.payload_size_max);
        self.lock();
        defer self.unlock();
        if (self.receive_count == receive_queue_capacity) return;
        std.debug.assert(self.receive_head_index < receive_queue_capacity);
        std.debug.assert(self.receive_count < receive_queue_capacity);

        const receive_tail_index: u8 =
            (self.receive_head_index + self.receive_count) %
            receive_queue_capacity;
        const slot = &self.receive_queue[@intCast(receive_tail_index)];
        @memcpy(slot.address[0..source.raw.len], source.raw);
        slot.address_byte_count = @intCast(source.raw.len);
        @memcpy(slot.payload[0..payload.len], payload);
        slot.payload_byte_count = @intCast(payload.len);
        self.receive_count += 1;
        self.receive_ready.signal();
    }

    fn publishTerminal(self: *SessionImpl, err: anyerror) void {
        self.lock();
        defer self.unlock();
        if (self.terminal_error == null) {
            if (!self.eof) self.terminal_error = err;
        }
        self.receive_ready.signal();
    }

    fn publishEOF(self: *SessionImpl) void {
        self.lock();
        defer self.unlock();
        if (self.terminal_error == null) self.eof = true;
        self.receive_ready.signal();
    }

    fn enqueueOutbound(self: *SessionImpl, frame: []const u8) !void {
        std.debug.assert(frame.len <= codec.frame_size_max);
        self.lock();
        defer self.unlock();
        if (self.terminal_error) |err| return err;
        if (self.eof) return error.SessionClosed;
        if (self.stopping.load(.acquire)) return error.SessionClosed;
        if (self.send_count == send_queue_capacity) {
            return error.PacketDropped;
        }
        std.debug.assert(self.send_head_index < send_queue_capacity);
        std.debug.assert(self.send_count < send_queue_capacity);

        const send_tail_index: u8 =
            (self.send_head_index + self.send_count) % send_queue_capacity;
        const slot = &self.send_queue[@intCast(send_tail_index)];
        @memcpy(slot.frame[0..frame.len], frame);
        slot.frame_byte_count = @intCast(frame.len);
        self.send_count += 1;
        self.send_ready.signal();
    }

    fn cachedAddress(
        self: *const SessionImpl,
        domain: []const u8,
        port: u16,
    ) !?socks_address.Parsed {
        if (self.resolved_address_byte_count == 0) return null;
        if (self.resolved_port != port) return null;
        if (self.resolved_domain_byte_count != domain.len) return null;
        if (!std.mem.eql(
            u8,
            self.resolved_domain[0..self.resolved_domain_byte_count],
            domain,
        )) return null;
        return try socks_address.parse(
            self.resolved_address[0..self.resolved_address_byte_count],
        );
    }

    fn resolveDomain(
        self: *SessionImpl,
        domain: []const u8,
        port: u16,
    ) !socks_address.Parsed {
        if (try self.cachedAddress(domain, port)) |address| return address;

        try compat.checkCancelFD(self.cancel_fd);
        const now_ms = compat.monotonicMilliTimestamp();
        const deadline_ms = std.math.add(
            i64,
            now_ms,
            domain_resolution_timeout_ms,
        ) catch std.math.maxInt(i64);
        var addresses = compat.net.getAddressListWithTimeoutCancelFD(
            self.allocator,
            domain,
            port,
            @intCast(domain_resolution_timeout_ms),
            self.cancel_fd,
        ) catch |err| switch (err) {
            error.AddressResolutionTimeout => return error.DeadlineExceeded,
            else => return err,
        };
        defer addresses.deinit();
        if (addresses.addrs.len == 0) return error.UnknownHostName;

        std.debug.assert(
            addresses.addrs.len <= compat.net.address_result_count_max,
        );
        var selected_address = addresses.addrs[0];
        for (0..compat.net.address_result_count_max) |address_index| {
            if (address_index == addresses.addrs.len) break;
            const candidate = addresses.addrs[address_index];
            if (candidate == .in) {
                selected_address = candidate;
                break;
            }
        }

        var next_address: [resolved_address_size_max]u8 = undefined;
        const encoded = switch (selected_address) {
            .in => |address| blk: {
                next_address[0] = 0x01;
                @memcpy(
                    next_address[1..5],
                    std.mem.asBytes(&address.sa.addr)[0..4],
                );
                std.mem.writeInt(
                    u16,
                    next_address[5..7],
                    port,
                    .big,
                );
                break :blk next_address[0..7];
            },
            .in6 => |address| blk: {
                next_address[0] = 0x04;
                @memcpy(next_address[1..17], &address.sa.addr);
                std.mem.writeInt(
                    u16,
                    next_address[17..19],
                    port,
                    .big,
                );
                break :blk next_address[0..19];
            },
        };
        try compat.checkCancelFD(self.cancel_fd);
        if (compat.monotonicMilliTimestamp() >= deadline_ms) {
            return error.DeadlineExceeded;
        }
        std.debug.assert(domain.len <= self.resolved_domain.len);
        @memcpy(self.resolved_address[0..encoded.len], encoded);
        @memcpy(self.resolved_domain[0..domain.len], domain);
        self.resolved_domain_byte_count = @intCast(domain.len);
        self.resolved_address_byte_count = @intCast(encoded.len);
        self.resolved_port = port;
        return socks_address.parse(
            self.resolved_address[0..self.resolved_address_byte_count],
        );
    }
};

/// One allocation-owned Trojan UDP association over a dedicated TLS stream.
/// A single I/O thread owns the mutable TLS engine. The relay exchanges frames
/// through fixed queues, so control close can always shutdown and join blocked
/// TLS reads or writes without racing TLS 1.3 key updates.
pub const Session = opaque {
    fn impl(self: *Session) *SessionImpl {
        return @ptrCast(@alignCast(self));
    }

    pub fn create(
        allocator: std.mem.Allocator,
        config: trojan.Config,
        absolute_deadline_ms: i64,
        cancel_fd: ?std.posix.fd_t,
    ) !*Session {
        try compat.checkCancelFD(cancel_fd);
        const value = try allocator.create(SessionImpl);
        errdefer {
            std.crypto.secureZero(u8, std.mem.asBytes(value));
            allocator.destroy(value);
        }

        value.allocator = allocator;
        value.cancel_fd = cancel_fd;
        try trojan.Client.init(&value.client, allocator, config);
        // Creation failures are fatal/cancel paths. Never emit close_notify on
        // their potentially backpressured upstream socket.
        errdefer value.client.abort();
        value.receive_ready = try compat.Notifier.init();
        errdefer value.receive_ready.deinit();
        value.send_ready = try compat.Notifier.init();
        errdefer value.send_ready.deinit();
        value.stopping = .init(false);
        value.state_mutex = .init;
        value.terminal_error = null;
        value.eof = false;
        value.receive_queue = undefined;
        value.receive_head_index = 0;
        value.receive_count = 0;
        value.send_queue = undefined;
        value.send_head_index = 0;
        value.send_count = 0;
        value.decoder = .{};
        value.delivery_address = undefined;
        value.delivery_payload = undefined;
        value.resolved_address = undefined;
        value.resolved_address_byte_count = 0;
        value.resolved_domain = undefined;
        value.resolved_domain_byte_count = 0;
        value.resolved_port = 0;
        value.encode_buffer = undefined;
        value.io_write_buffer = undefined;

        const stream = try value.client.connectUDP(
            absolute_deadline_ms,
            cancel_fd,
        );
        std.debug.assert(stream.handle == value.client.pollHandle());
        try compat.checkCancelFD(cancel_fd);
        value.io_thread = try std.Thread.spawn(
            .{
                .stack_size = io_stack_size_bytes,
                .allocator = null,
            },
            SessionImpl.ioMain,
            .{value},
        );
        return @ptrCast(value);
    }

    pub fn destroy(self: *Session) void {
        const value = self.impl();
        const allocator = value.allocator;
        value.stopping.store(true, .release);
        value.lock();
        var clean_eof = value.eof;
        if (value.terminal_error != null) clean_eof = false;
        value.unlock();
        if (!clean_eof) {
            const fd = value.client.pollHandle();
            if (fd >= 0) {
                compat.shutdownReadWrite(fd) catch |err| {
                    std.debug.panic(
                        "socket shutdown before Trojan UDP join failed: {s}",
                        .{@errorName(err)},
                    );
                };
            }
        }
        value.send_ready.signal();
        value.io_thread.join();
        value.send_ready.deinit();
        value.receive_ready.deinit();
        if (clean_eof) {
            value.client.deinit();
        } else {
            value.client.abort();
        }
        std.crypto.secureZero(u8, std.mem.asBytes(value));
        allocator.destroy(value);
    }

    pub fn pollHandle(self: *Session) std.posix.fd_t {
        return self.impl().receive_ready.handle();
    }

    pub fn send(
        self: *Session,
        destination: socks_address.Parsed,
        payload: []const u8,
    ) !void {
        const value = self.impl();
        if (value.stopping.load(.acquire)) return error.SessionClosed;
        const frame_destination = switch (destination.host) {
            .domain => |domain| try value.resolveDomain(
                domain,
                destination.port,
            ),
            .ipv4, .ipv6 => destination,
        };
        const frame = try codec.encode(
            frame_destination,
            payload,
            &value.encode_buffer,
        );
        try value.enqueueOutbound(frame);
    }

    pub fn receive(self: *Session) !ReceiveResult {
        const value = self.impl();
        value.receive_ready.drain();
        value.lock();

        if (value.receive_count > 0) {
            std.debug.assert(value.receive_head_index < receive_queue_capacity);
            std.debug.assert(value.receive_count <= receive_queue_capacity);
            const receive_head_index = value.receive_head_index;
            const slot = &value.receive_queue[@intCast(receive_head_index)];
            const address_byte_count: usize =
                @intCast(slot.address_byte_count);
            const payload_byte_count: usize =
                @intCast(slot.payload_byte_count);
            std.debug.assert(address_byte_count <= slot.address.len);
            std.debug.assert(address_byte_count <= value.delivery_address.len);
            std.debug.assert(payload_byte_count <= slot.payload.len);
            std.debug.assert(payload_byte_count <= value.delivery_payload.len);
            @memcpy(
                value.delivery_address[0..address_byte_count],
                slot.address[0..address_byte_count],
            );
            @memcpy(
                value.delivery_payload[0..payload_byte_count],
                slot.payload[0..payload_byte_count],
            );
            value.receive_head_index =
                (receive_head_index + 1) % receive_queue_capacity;
            value.receive_count -= 1;
            var signal_again = value.receive_count > 0;
            if (!signal_again) signal_again = value.terminal_error != null;
            if (!signal_again) signal_again = value.eof;
            value.unlock();
            if (signal_again) value.receive_ready.signal();
            return .{ .datagram = .{
                .source = try socks_address.parse(
                    value.delivery_address[0..address_byte_count],
                ),
                .payload = value.delivery_payload[0..payload_byte_count],
            } };
        }
        if (value.terminal_error) |err| {
            value.unlock();
            return err;
        }
        if (value.eof) {
            value.unlock();
            return .eof;
        }
        value.unlock();
        return .would_block;
    }
};

test "Trojan UDP outbound queue is bounded and preserves order" {
    // Drive the bounded session queue and inspect ordering, capacity, and ownership behavior.
    var value: SessionImpl = undefined;
    value.send_ready = try compat.Notifier.init();
    defer value.send_ready.deinit();
    value.stopping = .init(false);
    value.state_mutex = .init;
    value.terminal_error = null;
    value.eof = false;
    value.send_queue = undefined;
    value.send_head_index = 0;
    value.send_count = 0;
    value.io_write_buffer = undefined;

    try value.enqueueOutbound("first");
    try value.enqueueOutbound("second");
    try std.testing.expectError(
        error.PacketDropped,
        value.enqueueOutbound("third"),
    );
    try std.testing.expectEqualStrings("first", value.takeOutbound().?);
    try std.testing.expectEqualStrings("second", value.takeOutbound().?);
    try std.testing.expect(value.takeOutbound() == null);
}

comptime {
    std.debug.assert(receive_queue_capacity > 0);
    std.debug.assert(receive_queue_capacity <= std.math.maxInt(u8));
    std.debug.assert(
        2 * (receive_queue_capacity - 1) <= std.math.maxInt(u8),
    );
    std.debug.assert(send_queue_capacity > 0);
    std.debug.assert(send_queue_capacity <= std.math.maxInt(u8));
    std.debug.assert(
        2 * (send_queue_capacity - 1) <= std.math.maxInt(u8),
    );
    std.debug.assert(io_stack_size_bytes <= 1024 * 1024);
}
