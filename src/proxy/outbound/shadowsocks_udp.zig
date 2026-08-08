const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../../compat.zig");
const aead = @import("../../crypto/aead.zig");
const socks_address = @import("../../protocol/socks_address.zig");

const receive_wire_size_max: usize = 65_536;

comptime {
    std.debug.assert(aead.AeadDatagram.wire_size_max == 65_507);
    std.debug.assert(receive_wire_size_max > aead.AeadDatagram.wire_size_max);
}

pub const DropReason = enum {
    wire_too_large,
    network_condition,
    invalid_packet,
    authentication_failed,
    invalid_address,
};

pub const Datagram = struct {
    source: socks_address.Parsed,
    payload: []const u8,
};

pub const ReceiveResult = union(enum) {
    datagram: Datagram,
    would_block,
    dropped: DropReason,
};

const ReceiveWireLengthClassification = enum {
    accepted,
    wire_too_large,
};

fn classifyReceiveWireLength(wire_len: usize) ReceiveWireLengthClassification {
    return if (wire_len > aead.AeadDatagram.wire_size_max)
        .wire_too_large
    else
        .accepted;
}

const ReceiveErrorClassification = union(enum) {
    would_block,
    dropped: DropReason,
    fatal: anyerror,
};

fn classifyReceiveError(err: anyerror) ReceiveErrorClassification {
    return switch (err) {
        error.WouldBlock => .would_block,
        error.DatagramTooLarge => .{ .dropped = .wire_too_large },
        error.PacketDropped => .{ .dropped = .network_condition },
        else => .{ .fatal = err },
    };
}

const TestState = if (builtin.is_test) struct {
    var fail_after_connect: std.atomic.Value(bool) = .init(false);

    fn takePostConnectFailure() bool {
        return fail_after_connect.swap(false, .acq_rel);
    }
} else struct {};

/// Deterministic test seams. The production declaration is an empty namespace:
/// it contains neither callable hooks nor fault-injection state.
pub const testing = if (builtin.is_test) struct {
    pub const WireLengthClassification = ReceiveWireLengthClassification;
    pub const SocketReceiveErrorClassification = ReceiveErrorClassification;

    pub fn injectPostConnectFailureOnce() void {
        const was_armed = TestState.fail_after_connect.swap(true, .acq_rel);
        std.debug.assert(!was_armed);
    }

    pub fn clearPostConnectFailure() void {
        TestState.fail_after_connect.store(false, .release);
    }

    pub fn classifyWireLength(wire_len: usize) WireLengthClassification {
        return classifyReceiveWireLength(wire_len);
    }

    pub fn classifySocketReceiveError(
        err: anyerror,
    ) SocketReceiveErrorClassification {
        return classifyReceiveError(err);
    }
} else struct {};

/// One allocation-owned classic Shadowsocks UDP association. The returned
/// address and payload views remain valid only until the next receive call.
pub const Session = opaque {
    const Impl = struct {
        allocator: std.mem.Allocator,
        fd: std.posix.fd_t,
        crypto: *aead.AeadDatagram,
        salt_len: usize,
        send_plaintext: [aead.AeadDatagram.wire_size_max]u8,
        send_wire: [aead.AeadDatagram.wire_size_max]u8,
        receive_wire: [receive_wire_size_max]u8,
        receive_plaintext: [aead.AeadDatagram.wire_size_max]u8,
    };

    fn impl(self: *Session) *Impl {
        return @ptrCast(@alignCast(self));
    }

    /// Allocates every owned object before opening a socket, then resolves and
    /// tries each server address against the same absolute awake-clock deadline.
    /// cancel_fd is borrowed and is never closed by the Session.
    pub fn create(
        allocator: std.mem.Allocator,
        server: []const u8,
        port: u16,
        password: []const u8,
        cipher: aead.CipherType,
        absolute_deadline_ms: i64,
        cancel_fd: ?std.posix.fd_t,
    ) !*Session {
        // A preclosed control fd must not allocate even for a numeric server.
        try compat.checkCancelFd(cancel_fd);

        const value = try allocator.create(Impl);
        errdefer allocator.destroy(value);

        const crypto = try aead.AeadDatagram.create(allocator, cipher, password);
        errdefer crypto.destroy();

        const dns_timeout_ms = try deadlineRemainingMs(absolute_deadline_ms);
        var addresses = compat.net.getAddressListWithTimeoutCancelFd(
            allocator,
            server,
            port,
            dns_timeout_ms,
            cancel_fd,
        ) catch |err| {
            // Cancellation is control flow and must never be rewritten as a
            // timeout merely because both boundaries became ready together.
            try compat.checkCancelFd(cancel_fd);
            if (err == error.Canceled) return err;
            if (err == error.AddressResolutionTimeout) {
                return error.DeadlineExceeded;
            }
            if (deadlineExpired(absolute_deadline_ms)) {
                return error.DeadlineExceeded;
            }
            return err;
        };
        defer addresses.deinit();

        try compat.checkCancelFd(cancel_fd);
        if (deadlineExpired(absolute_deadline_ms)) {
            return error.DeadlineExceeded;
        }
        if (addresses.addrs.len == 0) return error.UnknownHostName;

        var last_error: anyerror = error.ConnectFailed;
        for (addresses.addrs) |address| {
            try compat.checkCancelFd(cancel_fd);
            if (deadlineExpired(absolute_deadline_ms)) {
                return error.DeadlineExceeded;
            }
            const fd = compat.net.udpConnectToAddressAbsolute(
                address,
                absolute_deadline_ms,
            ) catch |err| {
                // Recheck after every attempted connect so control closure wins
                // over a simultaneous per-address network failure.
                try compat.checkCancelFd(cancel_fd);
                if (err == error.DeadlineExceeded) return err;
                last_error = err;
                continue;
            };
            errdefer compat.posixClose(fd);
            try compat.checkCancelFd(cancel_fd);

            value.allocator = allocator;
            value.fd = fd;
            value.crypto = crypto;
            value.salt_len = cipher.saltLen();

            if (comptime builtin.is_test) {
                if (TestState.takePostConnectFailure()) {
                    return error.InjectedPostConnectFailure;
                }
            }
            return @ptrCast(value);
        }
        try compat.checkCancelFd(cancel_fd);
        return last_error;
    }

    /// Closes and wipes all session state. Calling destroy more than once is a
    /// caller ownership violation, as with allocator.destroy.
    pub fn destroy(self: *Session) void {
        const value = self.impl();
        const allocator = value.allocator;
        const fd = value.fd;
        const crypto = value.crypto;

        compat.posixClose(fd);
        crypto.destroy();
        std.crypto.secureZero(u8, std.mem.asBytes(value));
        allocator.destroy(value);
    }

    pub fn pollHandle(self: *Session) std.posix.fd_t {
        return self.impl().fd;
    }

    /// Seals and atomically sends one address-prefixed classic AEAD datagram.
    /// Every structural and size check completes before copying or requesting
    /// entropy, so rejected packets cannot touch the socket.
    pub fn send(
        self: *Session,
        destination: socks_address.Parsed,
        payload: []const u8,
    ) !void {
        if (!parsedAddressIsExact(destination)) return error.InvalidAddress;

        const value = self.impl();
        const plaintext_len = std.math.add(
            usize,
            destination.raw.len,
            payload.len,
        ) catch return error.DatagramTooLarge;
        const salted_len = std.math.add(
            usize,
            value.salt_len,
            plaintext_len,
        ) catch return error.DatagramTooLarge;
        const wire_len = std.math.add(
            usize,
            salted_len,
            aead.AeadDatagram.tag_size,
        ) catch return error.DatagramTooLarge;
        if (wire_len > aead.AeadDatagram.wire_size_max) {
            return error.DatagramTooLarge;
        }

        @memcpy(
            value.send_plaintext[0..destination.raw.len],
            destination.raw,
        );
        @memcpy(
            value.send_plaintext[destination.raw.len..plaintext_len],
            payload,
        );
        const wire = try value.crypto.seal(
            compat.io(),
            value.send_plaintext[0..plaintext_len],
            value.send_wire[0..wire_len],
        );
        std.debug.assert(wire.len == wire_len);
        try compat.udpConnectedSend(value.fd, wire);
    }

    /// Receives at most one packet. Authentication and address failures are
    /// packet-scoped drops; only descriptor-level failures escape as errors.
    pub fn receive(self: *Session) !ReceiveResult {
        const value = self.impl();
        const wire_len = compat.udpConnectedReceive(
            value.fd,
            &value.receive_wire,
        ) catch |err| switch (classifyReceiveError(err)) {
            .would_block => return .would_block,
            .dropped => |reason| return .{ .dropped = reason },
            .fatal => |fatal| return fatal,
        };
        switch (classifyReceiveWireLength(wire_len)) {
            .accepted => {},
            .wire_too_large => return .{ .dropped = .wire_too_large },
        }

        const plaintext = value.crypto.open(
            value.receive_wire[0..wire_len],
            &value.receive_plaintext,
        ) catch |err| switch (err) {
            error.AuthenticationFailed => {
                return .{ .dropped = .authentication_failed };
            },
            error.InvalidPacket, error.OutputTooSmall => {
                return .{ .dropped = .invalid_packet };
            },
            error.DatagramTooLarge => return .{ .dropped = .wire_too_large },
            else => |fatal| return fatal,
        };
        const source = socks_address.parse(plaintext) catch {
            return .{ .dropped = .invalid_address };
        };
        std.debug.assert(source.consumed <= plaintext.len);
        return .{ .datagram = .{
            .source = source,
            .payload = plaintext[source.consumed..],
        } };
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

fn parsedAddressIsExact(destination: socks_address.Parsed) bool {
    if (destination.raw.len == 0) return false;
    if (destination.raw.len > socks_address.encoded_size_max) return false;
    if (destination.consumed != destination.raw.len) return false;

    const reparsed = socks_address.parse(destination.raw) catch return false;
    if (reparsed.consumed != destination.raw.len) return false;
    if (reparsed.port != destination.port) return false;
    return switch (reparsed.host) {
        .ipv4 => |host| switch (destination.host) {
            .ipv4 => |expected| std.mem.eql(u8, &host, &expected),
            else => false,
        },
        .domain => |host| switch (destination.host) {
            .domain => |expected| std.mem.eql(u8, host, expected),
            else => false,
        },
        .ipv6 => |host| switch (destination.host) {
            .ipv6 => |expected| std.mem.eql(u8, &host, &expected),
            else => false,
        },
    };
}
