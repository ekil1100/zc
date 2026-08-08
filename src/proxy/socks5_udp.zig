//! Bounded RFC 1928 UDP codec, association state, and classic relay wiring.
//!
//! The relay owns one client socket and one optional Shadowsocks UDP session;
//! it deliberately provides neither fragment reassembly nor an application queue.

const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const socks_address = @import("../protocol/socks_address.zig");
const Engine = @import("../rule/engine.zig").Engine;
const outbound = @import("outbound/manager.zig");
const OutboundManager = outbound.OutboundManager;
const shadowsocks_udp = @import("outbound/shadowsocks_udp.zig");

const reserved_size: usize = 2;
const header_size: usize = reserved_size + 1;
const session_open_timeout_ms: i64 = 10_000;

const socks_version: u8 = 0x05;
const reply_succeeded: u8 = 0x00;
const reply_general_failure: u8 = 0x01;
const address_type_ipv4: u8 = 0x01;

pub const wire_size_max: usize = 65_507;
pub const idle_timeout_ms: i64 = 300_000;

comptime {
    std.debug.assert(wire_size_max == std.math.maxInt(u16) - 20 - 8);
    std.debug.assert(header_size + socks_address.encoded_size_max < wire_size_max);
    std.debug.assert(idle_timeout_ms == 5 * 60 * 1_000);
    std.debug.assert(session_open_timeout_ms == 10_000);
    std.debug.assert(2 * wire_size_max < 1024 * 1024);
}

pub const ParseError = socks_address.ParseError || error{
    DatagramTooLarge,
    TruncatedHeader,
    ReservedNotZero,
    FragmentationNotSupported,
};

/// Datagram is an allocation-free view of one RFC 1928 UDP request or response.
pub const Datagram = struct {
    address: socks_address.Parsed,
    payload: []const u8,
};

/// Parses one complete SOCKS5 UDP datagram without accepting reserved extensions.
pub fn parse(input: []const u8) ParseError!Datagram {
    if (input.len > wire_size_max) return error.DatagramTooLarge;
    if (input.len < reserved_size) return error.TruncatedHeader;
    if (input[0] != 0) return error.ReservedNotZero;
    if (input[1] != 0) return error.ReservedNotZero;
    if (input.len < header_size) return error.TruncatedHeader;
    if (input[reserved_size] != 0) return error.FragmentationNotSupported;

    const address = try socks_address.parse(input[header_size..]);
    const payload_start = std.math.add(usize, header_size, address.consumed) catch
        return error.LengthOverflow;
    if (input.len < payload_start) return error.LengthOverflow;

    return .{
        .address = address,
        .payload = input[payload_start..],
    };
}

pub const BuildError = error{
    InvalidSourceAddress,
    LengthOverflow,
    DatagramTooLarge,
    OutputTooSmall,
    InputAliasesOutput,
};

/// Builds one relay response after revalidating the complete source address.
/// The actual output write range must be disjoint from source.raw and payload;
/// aliasing returns error.InputAliasesOutput without modifying any output byte.
pub fn buildRelayResponse(
    output: []u8,
    source: socks_address.Parsed,
    payload: []const u8,
) BuildError!usize {
    const validated_source = validateSource(source) catch
        return error.InvalidSourceAddress;
    const payload_start = std.math.add(
        usize,
        header_size,
        validated_source.raw.len,
    ) catch return error.LengthOverflow;
    const output_size = std.math.add(usize, payload_start, payload.len) catch
        return error.LengthOverflow;

    if (output_size > wire_size_max) return error.DatagramTooLarge;
    if (output.len < output_size) return error.OutputTooSmall;

    const written_output = output[0..output_size];
    if (checkedSlicesOverlap(written_output, source.raw) or
        checkedSlicesOverlap(written_output, payload))
    {
        return error.InputAliasesOutput;
    }

    @memset(output[0..header_size], 0);
    @memcpy(output[header_size..payload_start], validated_source.raw);
    @memcpy(output[payload_start..output_size], payload);
    return output_size;
}

fn checkedSlicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;

    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn validateSource(source: socks_address.Parsed) error{InvalidSourceAddress}!socks_address.Parsed {
    if (source.consumed != source.raw.len) return error.InvalidSourceAddress;
    const reparsed = socks_address.parse(source.raw) catch
        return error.InvalidSourceAddress;
    if (reparsed.consumed != source.raw.len) return error.InvalidSourceAddress;
    if (!parsedAddressEqual(source, reparsed)) return error.InvalidSourceAddress;
    return reparsed;
}

fn parsedAddressEqual(a: socks_address.Parsed, b: socks_address.Parsed) bool {
    if (a.consumed != b.consumed) return false;
    if (a.port != b.port) return false;
    if (!std.mem.eql(u8, a.raw, b.raw)) return false;

    return switch (a.host) {
        .ipv4 => |a_host| switch (b.host) {
            .ipv4 => |b_host| std.mem.eql(u8, &a_host, &b_host),
            else => false,
        },
        .domain => |a_host| switch (b.host) {
            .domain => |b_host| std.mem.eql(u8, a_host, b_host),
            else => false,
        },
        .ipv6 => |a_host| switch (b.host) {
            .ipv6 => |b_host| std.mem.eql(u8, &a_host, &b_host),
            else => false,
        },
    };
}

pub const ClientEndpoint = struct {
    ip: [4]u8,
    port: u16,
};

pub const AssociationError = ParseError || error{
    ClientIpMismatch,
    SourcePortZero,
    ClientPortMismatch,
};

/// Association validates and pins one client endpoint without owning I/O resources.
pub const Association = struct {
    control_peer_ip: [4]u8,
    client_port: ?u16,
    activity_at_ms: i64,

    /// Initializes activity from an elapsed awake-clock timestamp in milliseconds.
    pub fn init(control_peer_ip: [4]u8, now_ms: i64) Association {
        return .{
            .control_peer_ip = control_peer_ip,
            .client_port = null,
            .activity_at_ms = now_ms,
        };
    }

    /// Returns the learned endpoint only after a valid first datagram pins its port.
    pub fn clientEndpoint(self: *const Association) ?ClientEndpoint {
        const port = self.client_port orelse return null;
        return .{ .ip = self.control_peer_ip, .port = port };
    }

    /// Validates one client datagram and pins the first eligible sender port.
    pub fn acceptDatagram(
        self: *Association,
        sender: ClientEndpoint,
        input: []const u8,
    ) AssociationError!Datagram {
        if (!std.mem.eql(u8, &self.control_peer_ip, &sender.ip)) {
            return error.ClientIpMismatch;
        }
        if (sender.port == 0) return error.SourcePortZero;
        if (self.client_port) |client_port| {
            if (sender.port != client_port) return error.ClientPortMismatch;
        }

        const datagram = try parse(input);
        if (self.client_port == null) self.client_port = sender.port;
        return datagram;
    }

    /// Records completed forwarding; mere receipt or validation never calls this implicitly.
    pub fn markForwardedAt(self: *Association, now_ms: i64) void {
        std.debug.assert(now_ms >= self.activity_at_ms);
        self.activity_at_ms = now_ms;
    }

    /// Computes the five-minute deadline with saturation at the signed clock maximum.
    pub fn idleDeadline(self: *const Association) i64 {
        return std.math.add(i64, self.activity_at_ms, idle_timeout_ms) catch
            std.math.maxInt(i64);
    }

    /// Uses an inclusive deadline against caller-supplied elapsed awake-clock time.
    pub fn isExpiredAt(self: *const Association, now_ms: i64) bool {
        return now_ms >= self.idleDeadline();
    }
};

fn buildAssociateReply(endpoint: compat.UdpEndpoint4) [10]u8 {
    return .{
        socks_version,
        reply_succeeded,
        0,
        address_type_ipv4,
        endpoint.ip[0],
        endpoint.ip[1],
        endpoint.ip[2],
        endpoint.ip[3],
        @intCast(endpoint.port >> 8),
        @intCast(endpoint.port & 0xff),
    };
}

fn buildFailureReply(rep: u8) [10]u8 {
    return .{
        socks_version,
        rep,
        0,
        address_type_ipv4,
        0,
        0,
        0,
        0,
        0,
        0,
    };
}

const ClientSocket = struct {
    fd: std.posix.fd_t,
    endpoint: compat.UdpEndpoint4,
};

const SystemAssociationOps = struct {
    fn getName(_: *@This(), fd: std.posix.fd_t) !compat.UdpEndpoint4 {
        return compat.socketGetName4(fd);
    }

    fn bind(
        _: *@This(),
        ip: [4]u8,
        port: u16,
    ) !std.posix.fd_t {
        return compat.udpBind4(ip, port);
    }

    fn setNonBlocking(_: *@This(), fd: std.posix.fd_t) !void {
        try compat.setNonBlock(fd);
    }

    fn close(_: *@This(), fd: std.posix.fd_t) void {
        compat.posixClose(fd);
    }
};

const ManagerOpener = struct {
    const Session = shadowsocks_udp.Session;

    manager: *OutboundManager,

    fn open(
        self: *@This(),
        proxy_name: []const u8,
        absolute_deadline_ms: i64,
        cancel_fd: std.posix.fd_t,
    ) !*Session {
        return self.manager.connectUdp(
            proxy_name,
            absolute_deadline_ms,
            cancel_fd,
        );
    }
};

/// Owns one classic SOCKS5 UDP association for the lifetime of its TCP control
/// connection. The caller retains ownership of the control stream.
pub fn handleAssociate(
    conn: net.Server.Connection,
    engine: *Engine,
    manager: *OutboundManager,
) !void {
    var ops = SystemAssociationOps{};
    var opener = ManagerOpener{ .manager = manager };
    return handleAssociateUsing(
        SystemAssociationOps,
        &ops,
        ManagerOpener,
        &opener,
        conn,
        engine,
    );
}

fn setupClientSocketUsing(
    comptime Ops: type,
    ops: *Ops,
    control_fd: std.posix.fd_t,
) !ClientSocket {
    const control_local = try ops.getName(control_fd);
    const fd = try ops.bind(control_local.ip, 0);
    errdefer ops.close(fd);
    try ops.setNonBlocking(fd);
    const endpoint = try ops.getName(fd);
    if (!std.mem.eql(u8, &endpoint.ip, &control_local.ip)) {
        return error.BoundAddressMismatch;
    }
    if (endpoint.port == 0) return error.BoundPortZero;
    return .{ .fd = fd, .endpoint = endpoint };
}

fn handleAssociateUsing(
    comptime Ops: type,
    ops: *Ops,
    comptime Opener: type,
    opener: *Opener,
    conn: net.Server.Connection,
    engine: *Engine,
) !void {
    const control_peer = controlPeerEndpoint(conn.address) catch {
        try conn.stream.writeAll(&buildFailureReply(reply_general_failure));
        return;
    };
    const client_socket = setupClientSocketUsing(
        Ops,
        ops,
        conn.stream.handle,
    ) catch {
        try conn.stream.writeAll(&buildFailureReply(reply_general_failure));
        return;
    };
    defer ops.close(client_socket.fd);

    try conn.stream.writeAll(&buildAssociateReply(client_socket.endpoint));
    var association = Association.init(
        control_peer.ip,
        compat.monotonicMilliTimestamp(),
    );
    try relayUsing(
        Opener,
        opener,
        conn.stream,
        client_socket.fd,
        engine,
        &association,
    );
}

fn controlPeerEndpoint(address: net.Address) !compat.UdpEndpoint4 {
    return switch (address) {
        .in => |value| compat.sockaddrInToUdpEndpoint4(value.sa),
        .in6 => error.UnexpectedAddressFamily,
    };
}

fn relayUsing(
    comptime Opener: type,
    opener: *Opener,
    control: net.Stream,
    client_fd: std.posix.fd_t,
    engine: *Engine,
    association: *Association,
) !void {
    var client_buffer: [wire_size_max]u8 = undefined;
    var response_buffer: [wire_size_max]u8 = undefined;
    var control_buffer: [1]u8 = undefined;
    var target_buffer: [64]u8 = undefined;
    var session: ?*Opener.Session = null;
    defer if (session) |value| value.destroy();

    while (true) {
        var descriptor_count: usize = 2;
        var descriptors = [_]std.posix.pollfd{
            .{
                .fd = control.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = client_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = -1,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        if (session) |value| {
            descriptors[2].fd = value.pollHandle();
            descriptor_count = 3;
        }

        const ready = try compat.pollAbsolute(
            descriptors[0..descriptor_count],
            association.idleDeadline(),
        );
        if (ready == 0) return;

        const control_events = descriptors[0].revents;
        if (control_events & (std.posix.POLL.HUP |
            std.posix.POLL.ERR |
            std.posix.POLL.NVAL) != 0) return;
        if (control_events & std.posix.POLL.IN != 0) {
            const count = control.read(&control_buffer) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (count == 0) return;
            return;
        }

        const client_events = descriptors[1].revents;
        if (client_events & std.posix.POLL.NVAL != 0) {
            return error.InvalidClientSocket;
        }
        if (client_events & std.posix.POLL.HUP != 0) {
            return error.ClientSocketClosed;
        }
        if (client_events & (std.posix.POLL.IN | std.posix.POLL.ERR) != 0) {
            const received = compat.udpRecvFrom(
                client_fd,
                &client_buffer,
            ) catch |err| switch (classifyPacketIoError(err)) {
                .drop => null,
                .fatal => |fatal| return fatal,
            };
            if (received) |packet| {
                const sender = compat.sockaddrInToUdpEndpoint4(
                    packet.addr,
                ) catch null;
                if (sender) |endpoint| {
                    const datagram = association.acceptDatagram(
                        .{ .ip = endpoint.ip, .port = endpoint.port },
                        client_buffer[0..packet.n],
                    ) catch null;
                    if (datagram) |accepted| {
                        if (session == null) {
                            const selected = try formatTarget(
                                accepted.address,
                                &target_buffer,
                            );
                            const proxy_name = engine.matchCtx(.{
                                .target_host = selected.host,
                                .target_port = accepted.address.port,
                                .is_domain = selected.is_domain,
                            }) orelse "DIRECT";
                            const deadline_ms = deadlineAfter(
                                compat.monotonicMilliTimestamp(),
                                session_open_timeout_ms,
                            );
                            const opened = opener.open(
                                proxy_name,
                                deadline_ms,
                                control.handle,
                            ) catch return;
                            compat.checkCancelFd(control.handle) catch |err| {
                                opened.destroy();
                                if (err == error.Canceled) return;
                                return err;
                            };
                            session = opened;
                        }

                        const forwarded = if (session.?.send(
                            accepted.address,
                            accepted.payload,
                        )) true else |err| switch (classifyPacketIoError(err)) {
                            .drop => false,
                            .fatal => |fatal| return fatal,
                        };
                        if (forwarded) {
                            association.markForwardedAt(
                                compat.monotonicMilliTimestamp(),
                            );
                        }
                    }
                }
            }
        }

        if (session) |value| {
            if (descriptor_count == 3) {
                const session_events = descriptors[2].revents;
                if (session_events & std.posix.POLL.NVAL != 0) {
                    return error.InvalidSessionSocket;
                }
                if (session_events & std.posix.POLL.HUP != 0) {
                    return error.SessionSocketClosed;
                }
                if (session_events & (std.posix.POLL.IN |
                    std.posix.POLL.ERR) != 0)
                {
                    const result = try value.receive();
                    switch (result) {
                        .would_block, .dropped => {},
                        .datagram => |datagram| {
                            const client = association.clientEndpoint() orelse
                                continue;
                            const response_len = buildRelayResponse(
                                &response_buffer,
                                datagram.source,
                                datagram.payload,
                            ) catch continue;
                            compat.udpSendTo4(
                                client_fd,
                                response_buffer[0..response_len],
                                .{ .ip = client.ip, .port = client.port },
                            ) catch |err| switch (classifyPacketIoError(err)) {
                                .drop => continue,
                                .fatal => |fatal| return fatal,
                            };
                            association.markForwardedAt(
                                compat.monotonicMilliTimestamp(),
                            );
                        },
                    }
                }
            }
        }
    }
}

const PacketIoClassification = union(enum) {
    drop,
    fatal: anyerror,
};

fn classifyPacketIoError(err: anyerror) PacketIoClassification {
    return switch (err) {
        error.WouldBlock,
        error.PacketDropped,
        error.DatagramTooLarge,
        => .drop,
        else => .{ .fatal = err },
    };
}

const FormattedTarget = struct {
    host: []const u8,
    is_domain: bool,
};

fn formatTarget(
    address: socks_address.Parsed,
    buffer: []u8,
) !FormattedTarget {
    return switch (address.host) {
        .ipv4 => |ip| .{
            .host = try std.fmt.bufPrint(
                buffer,
                "{d}.{d}.{d}.{d}",
                .{ ip[0], ip[1], ip[2], ip[3] },
            ),
            .is_domain = false,
        },
        .domain => |domain| .{
            .host = domain,
            .is_domain = true,
        },
        .ipv6 => |ip| .{
            .host = try std.fmt.bufPrint(
                buffer,
                "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}",
                .{
                    std.mem.readInt(u16, ip[0..2], .big),
                    std.mem.readInt(u16, ip[2..4], .big),
                    std.mem.readInt(u16, ip[4..6], .big),
                    std.mem.readInt(u16, ip[6..8], .big),
                    std.mem.readInt(u16, ip[8..10], .big),
                    std.mem.readInt(u16, ip[10..12], .big),
                    std.mem.readInt(u16, ip[12..14], .big),
                    std.mem.readInt(u16, ip[14..16], .big),
                },
            ),
            .is_domain = false,
        },
    };
}

fn deadlineAfter(now_ms: i64, duration_ms: i64) i64 {
    std.debug.assert(duration_ms >= 0);
    return std.math.add(i64, now_ms, duration_ms) catch
        std.math.maxInt(i64);
}

const TestControlPair = struct {
    accepted: net.Server.Connection,
    client: net.Stream,
};

const RelayTrackingOps = struct {
    bound_fd: std.atomic.Value(std.posix.fd_t) = .init(-1),
    close_count: std.atomic.Value(u32) = .init(0),

    fn getName(_: *@This(), fd: std.posix.fd_t) !compat.UdpEndpoint4 {
        return compat.socketGetName4(fd);
    }

    fn bind(
        self: *@This(),
        ip: [4]u8,
        port: u16,
    ) !std.posix.fd_t {
        const fd = try compat.udpBind4(ip, port);
        const previous = self.bound_fd.swap(fd, .acq_rel);
        std.debug.assert(previous == -1);
        return fd;
    }

    fn setNonBlocking(_: *@This(), fd: std.posix.fd_t) !void {
        try compat.setNonBlock(fd);
    }

    fn close(self: *@This(), fd: std.posix.fd_t) void {
        compat.posixClose(fd);
        _ = self.close_count.fetchAdd(1, .acq_rel);
    }
};

const LoopbackSessionOpener = struct {
    const Session = shadowsocks_udp.Session;

    allocator: std.mem.Allocator,
    server_port: u16,
    open_count: std.atomic.Value(u32) = .init(0),
    session_fd: std.atomic.Value(std.posix.fd_t) = .init(-1),
    matched_expected_proxy: std.atomic.Value(bool) = .init(false),

    fn open(
        self: *@This(),
        proxy_name: []const u8,
        absolute_deadline_ms: i64,
        cancel_fd: std.posix.fd_t,
    ) !*Session {
        _ = self.open_count.fetchAdd(1, .acq_rel);
        if (!std.mem.eql(u8, proxy_name, "udp-proxy")) {
            return error.TestUnexpectedProxy;
        }
        self.matched_expected_proxy.store(true, .release);
        if (compat.monotonicMilliTimestamp() >= absolute_deadline_ms) {
            return error.TestExpiredOpenDeadline;
        }
        const session = try shadowsocks_udp.Session.create(
            self.allocator,
            "127.0.0.1",
            self.server_port,
            "associate-tracer-password",
            .aes_128_gcm,
            absolute_deadline_ms,
            cancel_fd,
        );
        const previous = self.session_fd.swap(
            session.pollHandle(),
            .acq_rel,
        );
        std.debug.assert(previous == -1);
        return session;
    }
};

const RelayThreadContext = struct {
    ops: *RelayTrackingOps,
    opener: *LoopbackSessionOpener,
    conn: net.Server.Connection,
    engine: *Engine,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) void {
        defer self.conn.stream.close();
        handleAssociateUsing(
            RelayTrackingOps,
            self.ops,
            LoopbackSessionOpener,
            self.opener,
            self.conn,
            self.engine,
        ) catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
};

const RelayFakeSession = struct {
    raw_send_count: *std.atomic.Value(u32),
    destroy_count: *std.atomic.Value(u32),

    fn destroy(self: *@This()) void {
        const previous = self.destroy_count.fetchAdd(1, .acq_rel);
        std.debug.assert(previous == 0);
    }

    fn pollHandle(_: *@This()) std.posix.fd_t {
        return -1;
    }

    fn send(
        self: *@This(),
        _: socks_address.Parsed,
        _: []const u8,
    ) !void {
        _ = self.raw_send_count.fetchAdd(1, .acq_rel);
    }

    fn receive(_: *@This()) !shadowsocks_udp.ReceiveResult {
        return .would_block;
    }
};

const CancelDuringOpenOpener = struct {
    const Session = RelayFakeSession;

    entered: *compat.Notifier,
    open_count: std.atomic.Value(u32) = .init(0),
    cancel_fd_seen: std.atomic.Value(std.posix.fd_t) = .init(-1),

    fn open(
        self: *@This(),
        _: []const u8,
        absolute_deadline_ms: i64,
        cancel_fd: std.posix.fd_t,
    ) !*Session {
        _ = self.open_count.fetchAdd(1, .acq_rel);
        self.cancel_fd_seen.store(cancel_fd, .release);
        self.entered.signal();

        var descriptors = [_]std.posix.pollfd{.{
            .fd = cancel_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try compat.pollAbsolute(
            &descriptors,
            absolute_deadline_ms,
        );
        if (ready == 0) return error.TestOpenDeadline;
        if (!try compat.cancelFdTriggered(cancel_fd)) {
            return error.TestUnexpectedControlEvent;
        }
        return error.Canceled;
    }
};

const OpenAfterCloseOpener = struct {
    const Session = RelayFakeSession;

    entered: *compat.Notifier,
    release: *compat.Notifier,
    session: *Session,
    open_count: std.atomic.Value(u32) = .init(0),
    cancel_fd_seen: std.atomic.Value(std.posix.fd_t) = .init(-1),
    control_was_closed: std.atomic.Value(bool) = .init(false),

    fn open(
        self: *@This(),
        _: []const u8,
        absolute_deadline_ms: i64,
        cancel_fd: std.posix.fd_t,
    ) !*Session {
        _ = self.open_count.fetchAdd(1, .acq_rel);
        self.cancel_fd_seen.store(cancel_fd, .release);
        self.entered.signal();

        var descriptors = [_]std.posix.pollfd{.{
            .fd = self.release.handle(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try compat.pollAbsolute(
            &descriptors,
            absolute_deadline_ms,
        );
        if (ready == 0) return error.TestOpenDeadline;
        self.release.drain();
        self.control_was_closed.store(
            try compat.cancelFdTriggered(cancel_fd),
            .release,
        );
        return self.session;
    }
};

fn RelayTestContext(comptime Opener: type) type {
    return struct {
        opener: *Opener,
        control: net.Stream,
        client_fd: std.posix.fd_t,
        engine: *Engine,
        association: Association,
        done: *compat.Notifier,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            defer self.control.close();
            relayUsing(
                Opener,
                self.opener,
                self.control,
                self.client_fd,
                self.engine,
                &self.association,
            ) catch |err| {
                self.failure = err;
            };
            self.done.signal();
        }
    };
}

fn makeTestControlPair() !TestControlPair {
    const address = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{});
    defer server.deinit();
    const client = try net.tcpConnectToAddress(server.listen_address);
    errdefer client.close();
    return .{
        .accepted = try server.accept(),
        .client = client,
    };
}

fn waitReadableTest(fd: std.posix.fd_t, deadline_ms: i64) !void {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try compat.pollAbsolute(&descriptors, deadline_ms);
    if (ready == 0) return error.TestTimeout;
    if (descriptors[0].revents & std.posix.POLL.NVAL != 0) {
        return error.TestInvalidSocket;
    }
    if (descriptors[0].revents & std.posix.POLL.ERR != 0) {
        return error.TestSocketFailure;
    }
    if (descriptors[0].revents & (std.posix.POLL.IN |
        std.posix.POLL.HUP) == 0) return error.TestSocketFailure;
}

fn readExactTest(
    fd: std.posix.fd_t,
    output: []u8,
    deadline_ms: i64,
) !void {
    var read_count: usize = 0;
    while (read_count < output.len) {
        try waitReadableTest(fd, deadline_ms);
        const count = try compat.posixRead(fd, output[read_count..]);
        if (count == 0) return error.TestUnexpectedEof;
        read_count += count;
    }
}

test "SOCKS5 UDP associate reply advertises the exact IPv4 endpoint" {
    const reply = buildAssociateReply(.{
        .ip = .{ 127, 0, 0, 9 },
        .port = 0x1234,
    });

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x05, 0x00, 0x00, 0x01, 127, 0, 0, 9, 0x12, 0x34 },
        &reply,
    );
}

test "SOCKS5 UDP associate bind failure replies before opening a session" {
    const BindFailOps = struct {
        fn getName(
            _: *@This(),
            _: std.posix.fd_t,
        ) !compat.UdpEndpoint4 {
            return .{ .ip = .{ 127, 0, 0, 1 }, .port = 1234 };
        }

        fn bind(_: *@This(), _: [4]u8, _: u16) !std.posix.fd_t {
            return error.InjectedBindFailure;
        }

        fn setNonBlocking(_: *@This(), _: std.posix.fd_t) !void {
            return error.TestUnexpectedSocketSetup;
        }

        fn close(_: *@This(), _: std.posix.fd_t) void {
            @panic("bind failure cannot own a descriptor");
        }
    };
    const UnusedOpener = struct {
        const Session = shadowsocks_udp.Session;

        fn open(
            _: *@This(),
            _: []const u8,
            _: i64,
            _: std.posix.fd_t,
        ) !*Session {
            return error.TestUnexpectedOpen;
        }
    };

    var rules = std.ArrayList(@import("../config.zig").Rule).empty;
    var engine = try Engine.init(std.testing.allocator, &rules);
    defer engine.deinit();
    const pair = try makeTestControlPair();
    defer pair.accepted.stream.close();
    defer pair.client.close();

    var ops = BindFailOps{};
    var opener = UnusedOpener{};
    try handleAssociateUsing(
        BindFailOps,
        &ops,
        UnusedOpener,
        &opener,
        pair.accepted,
        &engine,
    );

    var reply: [10]u8 = undefined;
    try readExactTest(
        pair.client.handle,
        &reply,
        deadlineAfter(compat.monotonicMilliTimestamp(), 2_000),
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0 },
        &reply,
    );
}

test "SOCKS5 UDP associate setup failure replies once and closes an opened fd" {
    const FailingOps = struct {
        close_count: usize = 0,

        fn getName(
            _: *@This(),
            _: std.posix.fd_t,
        ) !compat.UdpEndpoint4 {
            return .{ .ip = .{ 127, 0, 0, 1 }, .port = 1234 };
        }

        fn bind(_: *@This(), _: [4]u8, _: u16) !std.posix.fd_t {
            return 4242;
        }

        fn setNonBlocking(_: *@This(), _: std.posix.fd_t) !void {
            return error.InjectedSocketSetupFailure;
        }

        fn close(self: *@This(), _: std.posix.fd_t) void {
            self.close_count += 1;
        }
    };
    const UnusedOpener = struct {
        const Session = shadowsocks_udp.Session;

        fn open(
            _: *@This(),
            _: []const u8,
            _: i64,
            _: std.posix.fd_t,
        ) !*Session {
            return error.TestUnexpectedOpen;
        }
    };

    var rules = std.ArrayList(@import("../config.zig").Rule).empty;
    var engine = try Engine.init(std.testing.allocator, &rules);
    defer engine.deinit();
    const pair = try makeTestControlPair();
    defer pair.accepted.stream.close();
    defer pair.client.close();

    var ops = FailingOps{};
    var opener = UnusedOpener{};
    try handleAssociateUsing(
        FailingOps,
        &ops,
        UnusedOpener,
        &opener,
        pair.accepted,
        &engine,
    );

    var reply: [10]u8 = undefined;
    try readExactTest(
        pair.client.handle,
        &reply,
        deadlineAfter(compat.monotonicMilliTimestamp(), 2_000),
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0 },
        &reply,
    );
    try std.testing.expectEqual(@as(usize, 1), ops.close_count);
}

test "SOCKS5 UDP relay cancels an opener when control closes" {
    const loopback = [4]u8{ 127, 0, 0, 1 };
    var rules = std.ArrayList(@import("../config.zig").Rule).empty;
    var engine = try Engine.init(std.testing.allocator, &rules);
    defer engine.deinit();

    const pair = try makeTestControlPair();
    var accepted_owned = true;
    var control_client_open = true;
    defer {
        if (accepted_owned) pair.accepted.stream.close();
        if (control_client_open) pair.client.close();
    }

    const relay_fd = try compat.udpBind4(loopback, 0);
    defer compat.posixClose(relay_fd);
    try compat.setNonBlock(relay_fd);
    const relay_endpoint = try compat.socketGetName4(relay_fd);
    const sender_fd = try compat.udpBind4(loopback, 0);
    defer compat.posixClose(sender_fd);

    var entered = try compat.Notifier.init();
    defer entered.deinit();
    var done = try compat.Notifier.init();
    defer done.deinit();
    var raw_send_count: std.atomic.Value(u32) = .init(0);
    var destroy_count: std.atomic.Value(u32) = .init(0);
    var opener = CancelDuringOpenOpener{ .entered = &entered };
    const Context = RelayTestContext(CancelDuringOpenOpener);
    var context = Context{
        .opener = &opener,
        .control = pair.accepted.stream,
        .client_fd = relay_fd,
        .engine = &engine,
        .association = Association.init(
            loopback,
            compat.monotonicMilliTimestamp(),
        ),
        .done = &done,
    };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    accepted_owned = false;
    var thread_joined = false;
    defer {
        if (control_client_open) {
            pair.client.close();
            control_client_open = false;
        }
        if (!thread_joined) {
            _ = std.c.shutdown(context.control.handle, std.c.SHUT.RDWR);
            thread.join();
        }
    }

    try compat.udpSendTo4(
        sender_fd,
        "\x00\x00\x00\x01\x08\x08\x08\x08\x00\x35question",
        relay_endpoint,
    );
    const test_deadline_ms = deadlineAfter(
        compat.monotonicMilliTimestamp(),
        2_000,
    );
    try waitReadableTest(entered.handle(), test_deadline_ms);
    entered.drain();

    pair.client.close();
    control_client_open = false;
    try waitReadableTest(done.handle(), test_deadline_ms);
    done.drain();
    thread.join();
    thread_joined = true;

    try std.testing.expect(context.failure == null);
    try std.testing.expectEqual(
        @as(u32, 1),
        opener.open_count.load(.acquire),
    );
    try std.testing.expectEqual(
        context.control.handle,
        opener.cancel_fd_seen.load(.acquire),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        raw_send_count.load(.acquire),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        destroy_count.load(.acquire),
    );
}

test "SOCKS5 UDP relay destroys a successful open after control close race" {
    const loopback = [4]u8{ 127, 0, 0, 1 };
    var rules = std.ArrayList(@import("../config.zig").Rule).empty;
    var engine = try Engine.init(std.testing.allocator, &rules);
    defer engine.deinit();

    const pair = try makeTestControlPair();
    var accepted_owned = true;
    var control_client_open = true;
    defer {
        if (accepted_owned) pair.accepted.stream.close();
        if (control_client_open) pair.client.close();
    }

    const relay_fd = try compat.udpBind4(loopback, 0);
    defer compat.posixClose(relay_fd);
    try compat.setNonBlock(relay_fd);
    const relay_endpoint = try compat.socketGetName4(relay_fd);
    const sender_fd = try compat.udpBind4(loopback, 0);
    defer compat.posixClose(sender_fd);

    var entered = try compat.Notifier.init();
    defer entered.deinit();
    var release = try compat.Notifier.init();
    defer release.deinit();
    var done = try compat.Notifier.init();
    defer done.deinit();
    var raw_send_count: std.atomic.Value(u32) = .init(0);
    var destroy_count: std.atomic.Value(u32) = .init(0);
    var fake_session = RelayFakeSession{
        .raw_send_count = &raw_send_count,
        .destroy_count = &destroy_count,
    };
    var opener = OpenAfterCloseOpener{
        .entered = &entered,
        .release = &release,
        .session = &fake_session,
    };
    const Context = RelayTestContext(OpenAfterCloseOpener);
    var context = Context{
        .opener = &opener,
        .control = pair.accepted.stream,
        .client_fd = relay_fd,
        .engine = &engine,
        .association = Association.init(
            loopback,
            compat.monotonicMilliTimestamp(),
        ),
        .done = &done,
    };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    accepted_owned = false;
    var thread_joined = false;
    defer {
        // Active failure cleanup releases the opener before the bounded join.
        release.signal();
        if (control_client_open) {
            pair.client.close();
            control_client_open = false;
        }
        if (!thread_joined) {
            _ = std.c.shutdown(context.control.handle, std.c.SHUT.RDWR);
            thread.join();
        }
    }

    try compat.udpSendTo4(
        sender_fd,
        "\x00\x00\x00\x01\x08\x08\x04\x04\x00\x35race",
        relay_endpoint,
    );
    const test_deadline_ms = deadlineAfter(
        compat.monotonicMilliTimestamp(),
        2_000,
    );
    try waitReadableTest(entered.handle(), test_deadline_ms);
    entered.drain();

    pair.client.close();
    control_client_open = false;
    // Prove peer-close readiness before allowing open() to return success.
    try waitReadableTest(context.control.handle, test_deadline_ms);
    release.signal();
    try waitReadableTest(done.handle(), test_deadline_ms);
    done.drain();
    thread.join();
    thread_joined = true;

    try std.testing.expect(context.failure == null);
    try std.testing.expect(opener.control_was_closed.load(.acquire));
    try std.testing.expectEqual(
        @as(u32, 1),
        opener.open_count.load(.acquire),
    );
    try std.testing.expectEqual(
        context.control.handle,
        opener.cancel_fd_seen.load(.acquire),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        raw_send_count.load(.acquire),
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        destroy_count.load(.acquire),
    );
}

test "SOCKS5 UDP associate relays a domain through one real AEAD session" {
    const config = @import("../config.zig");
    const loopback = [4]u8{ 127, 0, 0, 1 };
    const test_deadline_ms: i64 = 2_000;

    const oracle_fd = try compat.udpBind4(loopback, 0);
    defer compat.posixClose(oracle_fd);
    try compat.setNonBlock(oracle_fd);
    const oracle_endpoint = try compat.socketGetName4(oracle_fd);
    const oracle_crypto = try @import("../crypto/aead.zig").AeadDatagram.create(
        std.testing.allocator,
        .aes_128_gcm,
        "associate-tracer-password",
    );
    defer oracle_crypto.destroy();

    var rule_storage = [_]config.Rule{
        .{
            .rule_type = .domain,
            .payload = "example.com",
            .target = "udp-proxy",
        },
        .{
            .rule_type = .final,
            .payload = "",
            .target = "unexpected-second-route",
        },
    };
    var rules = std.ArrayList(config.Rule){
        .items = &rule_storage,
        .capacity = rule_storage.len,
    };
    var engine = try Engine.init(std.testing.allocator, &rules);
    defer engine.deinit();

    const pair = try makeTestControlPair();
    var accepted_owned = true;
    errdefer if (accepted_owned) pair.accepted.stream.close();
    var control_open = true;
    errdefer if (control_open) pair.client.close();

    var tracking = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    var ops = RelayTrackingOps{};
    var opener = LoopbackSessionOpener{
        .allocator = tracking.allocator(),
        .server_port = oracle_endpoint.port,
    };
    var context = RelayThreadContext{
        .ops = &ops,
        .opener = &opener,
        .conn = pair.accepted,
        .engine = &engine,
    };
    const thread = try std.Thread.spawn(.{}, RelayThreadContext.run, .{&context});
    accepted_owned = false;
    var thread_joined = false;
    defer {
        if (control_open) pair.client.close();
        if (!thread_joined) {
            _ = std.c.shutdown(context.conn.stream.handle, std.c.SHUT.RDWR);
            thread.join();
        }
    }

    var associate_reply: [10]u8 = undefined;
    try readExactTest(
        pair.client.handle,
        &associate_reply,
        deadlineAfter(
            compat.monotonicMilliTimestamp(),
            test_deadline_ms,
        ),
    );
    try std.testing.expectEqual(@as(u8, reply_succeeded), associate_reply[1]);
    try std.testing.expectEqual(@as(u8, address_type_ipv4), associate_reply[3]);
    const relay_endpoint = compat.UdpEndpoint4{
        .ip = associate_reply[4..8].*,
        .port = std.mem.readInt(u16, associate_reply[8..10], .big),
    };
    try std.testing.expectEqual(loopback, relay_endpoint.ip);
    try std.testing.expect(relay_endpoint.port != 0);

    const client_fd = try compat.udpBind4(loopback, 0);
    defer compat.posixClose(client_fd);
    try compat.setNonBlock(client_fd);
    const destination_raw = "\x03\x0bexample.com\x00\x35";
    try compat.udpSendTo4(
        client_fd,
        "\x00\x00\x00" ++ destination_raw ++ "question",
        relay_endpoint,
    );

    try waitReadableTest(
        oracle_fd,
        deadlineAfter(
            compat.monotonicMilliTimestamp(),
            test_deadline_ms,
        ),
    );
    var oracle_wire: [65_536]u8 = undefined;
    const first_request = try compat.udpRecvFrom(oracle_fd, &oracle_wire);
    const session_peer = try compat.sockaddrInToUdpEndpoint4(
        first_request.addr,
    );
    var oracle_plaintext: [wire_size_max]u8 = undefined;
    const first_plaintext = try oracle_crypto.open(
        oracle_wire[0..first_request.n],
        &oracle_plaintext,
    );
    try std.testing.expectEqualStrings(
        destination_raw ++ "question",
        first_plaintext,
    );

    const source_raw = "\x03\x0borigin.test\x14\xe9";
    var response_wire_buffer: [256]u8 = undefined;
    const response_wire = try oracle_crypto.seal(
        std.testing.io,
        source_raw ++ "answer",
        &response_wire_buffer,
    );
    try compat.udpSendTo4(oracle_fd, response_wire, session_peer);

    try waitReadableTest(
        client_fd,
        deadlineAfter(
            compat.monotonicMilliTimestamp(),
            test_deadline_ms,
        ),
    );
    var client_response_buffer: [256]u8 = undefined;
    const client_response = try compat.udpRecvFrom(
        client_fd,
        &client_response_buffer,
    );
    const response_sender = try compat.sockaddrInToUdpEndpoint4(
        client_response.addr,
    );
    try std.testing.expectEqual(relay_endpoint, response_sender);
    const response = try parse(
        client_response_buffer[0..client_response.n],
    );
    try std.testing.expectEqualStrings(source_raw, response.address.raw);
    try std.testing.expectEqualStrings("origin.test", response.address.host.domain);
    try std.testing.expectEqual(@as(u16, 5353), response.address.port);
    try std.testing.expectEqualStrings("answer", response.payload);

    const second_destination = "\x01\x08\x08\x08\x08\x00\x35";
    try compat.udpSendTo4(
        client_fd,
        "\x00\x00\x00" ++ second_destination ++ "second",
        relay_endpoint,
    );
    try waitReadableTest(
        oracle_fd,
        deadlineAfter(
            compat.monotonicMilliTimestamp(),
            test_deadline_ms,
        ),
    );
    const second_request = try compat.udpRecvFrom(oracle_fd, &oracle_wire);
    const second_plaintext = try oracle_crypto.open(
        oracle_wire[0..second_request.n],
        &oracle_plaintext,
    );
    try std.testing.expectEqualStrings(
        second_destination ++ "second",
        second_plaintext,
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        opener.open_count.load(.acquire),
    );
    try std.testing.expect(opener.matched_expected_proxy.load(.acquire));

    pair.client.close();
    control_open = false;
    const close_deadline = deadlineAfter(
        compat.monotonicMilliTimestamp(),
        test_deadline_ms,
    );
    while (!context.done.load(.acquire) and
        compat.monotonicMilliTimestamp() < close_deadline)
    {
        compat.sleepNs(std.time.ns_per_ms);
    }
    if (!context.done.load(.acquire)) {
        _ = std.c.shutdown(context.conn.stream.handle, std.c.SHUT.RDWR);
    }
    thread.join();
    thread_joined = true;

    try std.testing.expect(context.done.load(.acquire));
    try std.testing.expect(context.failure == null);
    try std.testing.expectEqual(
        @as(u32, 1),
        ops.close_count.load(.acquire),
    );
    const client_relay_fd = ops.bound_fd.load(.acquire);
    const session_fd = opener.session_fd.load(.acquire);
    try std.testing.expect(client_relay_fd >= 0);
    try std.testing.expect(session_fd >= 0);
    try std.testing.expect(std.c.fcntl(
        client_relay_fd,
        std.posix.F.GETFD,
        @as(c_int, 0),
    ) < 0);
    try std.testing.expect(std.c.fcntl(
        session_fd,
        std.posix.F.GETFD,
        @as(c_int, 0),
    ) < 0);
    try std.testing.expect(tracking.allocations > 0);
    try std.testing.expectEqual(
        tracking.allocated_bytes,
        tracking.freed_bytes,
    );
    try std.testing.expectEqual(
        tracking.allocations,
        tracking.deallocations,
    );
}

test "SOCKS5 UDP parse borrows an IPv4 address and payload" {
    // This RFC 1928 vector fixes every field boundary and both borrowed views.
    const input: []const u8 =
        "\x00\x00\x00\x01\xc0\x00\x02\x01\x1f\x90hello";

    const datagram = try parse(input);
    try std.testing.expectEqualStrings(
        "\x01\xc0\x00\x02\x01\x1f\x90",
        datagram.address.raw,
    );
    try std.testing.expectEqualStrings("hello", datagram.payload);
    try std.testing.expectEqual(@as(u16, 8080), datagram.address.port);
    try std.testing.expectEqual(
        @intFromPtr(input.ptr) + header_size,
        @intFromPtr(datagram.address.raw.ptr),
    );
    switch (datagram.address.host) {
        .ipv4 => |host| try std.testing.expectEqual([4]u8{ 192, 0, 2, 1 }, host),
        else => return error.UnexpectedHostType,
    }
}

test "SOCKS5 UDP parse borrows a domain address and payload" {
    // The domain and payload views must point into the caller-owned datagram.
    const input: []const u8 =
        "\x00\x00\x00\x03\x0bexample.com\x00\x35query";

    const datagram = try parse(input);
    try std.testing.expectEqualStrings(
        "\x03\x0bexample.com\x00\x35",
        datagram.address.raw,
    );
    try std.testing.expectEqualStrings("query", datagram.payload);
    try std.testing.expectEqual(@as(u16, 53), datagram.address.port);
    switch (datagram.address.host) {
        .domain => |host| {
            try std.testing.expectEqualStrings("example.com", host);
            try std.testing.expectEqual(
                @intFromPtr(input.ptr) + header_size + 2,
                @intFromPtr(host.ptr),
            );
        },
        else => return error.UnexpectedHostType,
    }
}

test "SOCKS5 UDP parse borrows an IPv6 address and payload" {
    // The fixed vector catches ATYP width and network-order port mistakes.
    const input: []const u8 =
        "\x00\x00\x00\x04" ++
        "\x20\x01\x0d\xb8\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x01" ++
        "\x01\xbbresponse";

    const datagram = try parse(input);
    try std.testing.expectEqual(@as(usize, 19), datagram.address.raw.len);
    try std.testing.expectEqual(@as(u16, 443), datagram.address.port);
    try std.testing.expectEqualStrings("response", datagram.payload);
    switch (datagram.address.host) {
        .ipv6 => |host| try std.testing.expectEqual([16]u8{
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        }, host),
        else => return error.UnexpectedHostType,
    }
}

test "SOCKS5 UDP parse rejects either nonzero reserved byte" {
    // Both reserved octets are independently constrained to zero by RFC 1928.
    try std.testing.expectError(
        error.ReservedNotZero,
        parse("\x01\x00\x00\x01\x7f\x00\x00\x01\x00\x35"),
    );
    try std.testing.expectError(
        error.ReservedNotZero,
        parse("\x00\x01\x00\x01\x7f\x00\x00\x01\x00\x35"),
    );
}

test "SOCKS5 UDP parse rejects fragmentation" {
    // This slice deliberately has no reassembly queue, so every nonzero FRAG is rejected.
    try std.testing.expectError(
        error.FragmentationNotSupported,
        parse("\x00\x00\x01\x01\x7f\x00\x00\x01\x00\x35"),
    );
    try std.testing.expectError(
        error.FragmentationNotSupported,
        parse("\x00\x00\x80\x01\x7f\x00\x00\x01\x00\x35"),
    );
}

test "SOCKS5 UDP parse preserves typed address errors" {
    // Header truncation, unknown ATYP, empty domains, and address truncation stay distinct.
    try std.testing.expectError(error.TruncatedHeader, parse(""));
    try std.testing.expectError(error.TruncatedHeader, parse("\x00"));
    try std.testing.expectError(error.TruncatedHeader, parse("\x00\x00"));
    try std.testing.expectError(error.MissingAddressType, parse("\x00\x00\x00"));
    try std.testing.expectError(
        error.UnknownAddressType,
        parse("\x00\x00\x00\x02"),
    );
    try std.testing.expectError(
        error.EmptyDomain,
        parse("\x00\x00\x00\x03\x00\x00\x35"),
    );
    try std.testing.expectError(
        error.TruncatedHost,
        parse("\x00\x00\x00\x01\x7f\x00"),
    );
    try std.testing.expectError(
        error.TruncatedPort,
        parse("\x00\x00\x00\x04" ++ ("\x00" ** 16) ++ "\x01"),
    );
}

test "SOCKS5 UDP parse rejects oversized input before its malformed header" {
    // A wire-size violation wins even when attacker-controlled header bytes are also invalid.
    var input: [wire_size_max + 1]u8 = @splat(0xff);

    try std.testing.expectError(error.DatagramTooLarge, parse(&input));
}

test "SOCKS5 UDP parse accepts the exact wire maximum" {
    // The largest IPv4 UDP payload remains representable without allocation or truncation.
    var input: [wire_size_max]u8 = @splat(0xa5);
    @memcpy(input[0..10], "\x00\x00\x00\x01\xcb\x00\x71\x09\xff\xff");

    const datagram = try parse(&input);
    try std.testing.expectEqual(@as(usize, 7), datagram.address.raw.len);
    try std.testing.expectEqual(@as(usize, wire_size_max - 10), datagram.payload.len);
    try std.testing.expectEqual(@intFromPtr(&input[10]), @intFromPtr(datagram.payload.ptr));
}

test "SOCKS5 UDP build is atomic for exact short and larger output" {
    // Literal output is independent of the builder and exposes any partial short-buffer write.
    const source = try socks_address.parse("\x01\xc6\x33\x64\x07\x14\xe9");
    const expected = "\x00\x00\x00\x01\xc6\x33\x64\x07\x14\xe9reply";

    var exact: [expected.len]u8 = undefined;
    const exact_size = try buildRelayResponse(&exact, source, "reply");
    try std.testing.expectEqual(expected.len, exact_size);
    try std.testing.expectEqualStrings(expected, &exact);

    var short: [expected.len - 1]u8 = @splat(0xa5);
    const short_before = short;
    try std.testing.expectError(
        error.OutputTooSmall,
        buildRelayResponse(&short, source, "reply"),
    );
    try std.testing.expectEqualSlices(u8, &short_before, &short);

    var larger: [expected.len + 1]u8 = @splat(0xa5);
    const larger_size = try buildRelayResponse(&larger, source, "reply");
    try std.testing.expectEqual(expected.len, larger_size);
    try std.testing.expectEqualStrings(expected, larger[0..larger_size]);
    try std.testing.expectEqual(@as(u8, 0xa5), larger[larger_size]);
}

test "SOCKS5 UDP build rejects parsed input aliasing output atomically" {
    // Parsing and rebuilding the same backing storage must fail before any byte changes.
    var buffer = [_]u8{
        0x00, 0x00, 0x00, 0x01, 0xc6, 0x33, 0x64, 0x07,
        0x14, 0xe9, 'r',  'e',  'p',  'l',  'y',
    };
    const datagram = try parse(&buffer);
    const before = buffer;

    try std.testing.expectError(
        error.InputAliasesOutput,
        buildRelayResponse(&buffer, datagram.address, datagram.payload),
    );
    try std.testing.expectEqualSlices(u8, &before, &buffer);
}

test "SOCKS5 UDP build rejects a partially overlapping payload atomically" {
    // The payload intersects only the tail of the actual output write range.
    const source = try socks_address.parse("\x01\xc6\x33\x64\x07\x14\xe9");
    var buffer: [24]u8 = @splat(0xa5);
    @memcpy(buffer[12..17], "reply");
    const before = buffer;

    try std.testing.expectError(
        error.InputAliasesOutput,
        buildRelayResponse(buffer[0..15], source, buffer[12..17]),
    );
    try std.testing.expectEqualSlices(u8, &before, &buffer);
}

test "SOCKS5 UDP build accepts disjoint input and output" {
    // The no-alias contract must not reject ordinary independent buffers.
    const source = try socks_address.parse("\x01\xc6\x33\x64\x07\x14\xe9");
    var output: [16]u8 = @splat(0xa5);

    const output_size = try buildRelayResponse(&output, source, "reply");

    try std.testing.expectEqual(@as(usize, 15), output_size);
    try std.testing.expectEqualStrings(
        "\x00\x00\x00\x01\xc6\x33\x64\x07\x14\xe9reply",
        output[0..output_size],
    );
    try std.testing.expectEqual(@as(u8, 0xa5), output[output_size]);
}

test "SOCKS5 UDP build rejects an incomplete or non-unique source address" {
    // Revalidation prevents fabricated Parsed metadata from smuggling partial or trailing bytes.
    const encoded = "\x01\xc6\x33\x64\x07\x14\xe9";
    const source = try socks_address.parse(encoded);
    var output: [32]u8 = @splat(0xa5);

    var incomplete = source;
    incomplete.raw = encoded[0 .. encoded.len - 1];
    incomplete.consumed = incomplete.raw.len;
    try std.testing.expectError(
        error.InvalidSourceAddress,
        buildRelayResponse(&output, incomplete, "x"),
    );

    const duplicate = encoded ++ encoded;
    var non_unique = source;
    non_unique.raw = duplicate;
    non_unique.consumed = duplicate.len;
    try std.testing.expectError(
        error.InvalidSourceAddress,
        buildRelayResponse(&output, non_unique, "x"),
    );

    var inconsistent = source;
    inconsistent.port += 1;
    try std.testing.expectError(
        error.InvalidSourceAddress,
        buildRelayResponse(&output, inconsistent, "x"),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** output.len), &output);
}

test "SOCKS5 UDP build accepts the exact wire maximum" {
    // The checked total permits equality with the UDP wire limit and no byte more.
    const source_size: usize = 7;
    const source = try socks_address.parse("\x01\xcb\x00\x71\x09\xff\xff");
    const payload_size = wire_size_max - header_size - source_size;
    const payload = [_]u8{0x5a} ** payload_size;
    var output: [wire_size_max]u8 = undefined;

    try std.testing.expectEqual(source_size, source.raw.len);
    const output_size = try buildRelayResponse(&output, source, &payload);
    try std.testing.expectEqual(wire_size_max, output_size);
    try std.testing.expectEqualStrings("\x00\x00\x00", output[0..header_size]);
    try std.testing.expectEqualSlices(
        u8,
        source.raw,
        output[header_size .. header_size + source.raw.len],
    );
    try std.testing.expectEqual(@as(u8, 0x5a), output[wire_size_max - 1]);
}

test "SOCKS5 UDP build rejects one byte over the wire maximum" {
    // Oversized totals are rejected before the output sentinel can be modified.
    const source_size: usize = 7;
    const source = try socks_address.parse("\x01\xcb\x00\x71\x09\xff\xff");
    const payload_size = wire_size_max - header_size - source_size + 1;
    const payload = [_]u8{0x5a} ** payload_size;
    var output: [wire_size_max]u8 = @splat(0xa5);

    try std.testing.expectEqual(source_size, source.raw.len);
    try std.testing.expectError(
        error.DatagramTooLarge,
        buildRelayResponse(&output, source, &payload),
    );
    try std.testing.expectEqual(@as(u8, 0xa5), output[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), output[wire_size_max - 1]);
}

const test_client_ip = [4]u8{ 192, 0, 2, 44 };
const test_valid_datagram =
    "\x00\x00\x00\x01\xcb\x00\x71\x09\x00\x35query";

fn expectInvalidFirstDatagramDoesNotPin(
    expected_error: anyerror,
    input: []const u8,
) !void {
    var association = Association.init(test_client_ip, 1_000);
    const invalid_sender = ClientEndpoint{ .ip = test_client_ip, .port = 40_000 };
    const valid_sender = ClientEndpoint{ .ip = test_client_ip, .port = 40_001 };

    try std.testing.expectError(
        expected_error,
        association.acceptDatagram(invalid_sender, input),
    );
    try std.testing.expect(association.clientEndpoint() == null);

    _ = try association.acceptDatagram(valid_sender, test_valid_datagram);
    try std.testing.expectEqual(valid_sender, association.clientEndpoint().?);
    try std.testing.expectError(
        error.ClientPortMismatch,
        association.acceptDatagram(invalid_sender, test_valid_datagram),
    );
}

test "SOCKS5 UDP association does not pin malformed first datagrams" {
    // Every codec failure must leave the association available to the next valid sender port.
    try expectInvalidFirstDatagramDoesNotPin(
        error.ReservedNotZero,
        "\x01\x00\x00\x01\x7f\x00\x00\x01\x00\x35",
    );
    try expectInvalidFirstDatagramDoesNotPin(
        error.ReservedNotZero,
        "\x00\x01\x00\x01\x7f\x00\x00\x01\x00\x35",
    );
    try expectInvalidFirstDatagramDoesNotPin(
        error.FragmentationNotSupported,
        "\x00\x00\x01\x01\x7f\x00\x00\x01\x00\x35",
    );
    try expectInvalidFirstDatagramDoesNotPin(
        error.UnknownAddressType,
        "\x00\x00\x00\x02",
    );
    try expectInvalidFirstDatagramDoesNotPin(
        error.MissingAddressType,
        "\x00\x00\x00",
    );
    try expectInvalidFirstDatagramDoesNotPin(
        error.TruncatedPort,
        "\x00\x00\x00\x01\x7f\x00\x00\x01\x00",
    );

    const oversized = [_]u8{0} ** (wire_size_max + 1);
    try expectInvalidFirstDatagramDoesNotPin(error.DatagramTooLarge, &oversized);
}

test "SOCKS5 UDP association pins the first valid matching sender" {
    // RFC 1928 binds the UDP association to the control peer IP and one learned port.
    var association = Association.init(test_client_ip, 1_000);
    const wrong_ip = ClientEndpoint{ .ip = .{ 198, 51, 100, 9 }, .port = 41_000 };
    const zero_port = ClientEndpoint{ .ip = test_client_ip, .port = 0 };
    const accepted = ClientEndpoint{ .ip = test_client_ip, .port = 42_000 };
    const other_port = ClientEndpoint{ .ip = test_client_ip, .port = 42_001 };

    try std.testing.expectError(
        error.ClientIpMismatch,
        association.acceptDatagram(wrong_ip, test_valid_datagram),
    );
    try std.testing.expect(association.clientEndpoint() == null);
    try std.testing.expectError(
        error.SourcePortZero,
        association.acceptDatagram(zero_port, test_valid_datagram),
    );
    try std.testing.expect(association.clientEndpoint() == null);

    _ = try association.acceptDatagram(accepted, test_valid_datagram);
    try std.testing.expectEqual(accepted, association.clientEndpoint().?);
    _ = try association.acceptDatagram(accepted, test_valid_datagram);
    try std.testing.expectError(
        error.ClientIpMismatch,
        association.acceptDatagram(wrong_ip, test_valid_datagram),
    );
    try std.testing.expectError(
        error.ClientPortMismatch,
        association.acceptDatagram(other_port, test_valid_datagram),
    );
}

test "SOCKS5 UDP association refreshes activity only after forwarding" {
    // Receiving valid or invalid client bytes is not proof that a datagram was forwarded.
    var association = Association.init(test_client_ip, 1_000);
    const sender = ClientEndpoint{ .ip = test_client_ip, .port = 42_000 };
    const initial_deadline = association.idleDeadline();

    try std.testing.expectError(
        error.ReservedNotZero,
        association.acceptDatagram(
            sender,
            "\x01\x00\x00\x01\x7f\x00\x00\x01\x00\x35",
        ),
    );
    try std.testing.expectEqual(initial_deadline, association.idleDeadline());
    _ = try association.acceptDatagram(sender, test_valid_datagram);
    try std.testing.expectEqual(initial_deadline, association.idleDeadline());

    association.markForwardedAt(2_000);
    const forwarded_deadline = association.idleDeadline();
    try std.testing.expectEqual(@as(i64, 302_000), forwarded_deadline);
    try std.testing.expectError(
        error.ReservedNotZero,
        association.acceptDatagram(
            sender,
            "\x01\x00\x00\x01\x7f\x00\x00\x01\x00\x35",
        ),
    );
    try std.testing.expectEqual(forwarded_deadline, association.idleDeadline());
}

test "SOCKS5 UDP association expires at the inclusive awake-clock deadline" {
    // The fixed five-minute idle budget is live one millisecond before its deadline.
    const association = Association.init(test_client_ip, 123);
    const deadline = association.idleDeadline();

    try std.testing.expectEqual(@as(i64, 300_123), deadline);
    try std.testing.expect(!association.isExpiredAt(deadline - 1));
    try std.testing.expect(association.isExpiredAt(deadline));
}

test "SOCKS5 UDP association saturates an overflowing idle deadline" {
    // Saturation keeps near-i64-max awake timestamps defined and preserves inclusive expiry.
    const started_at_ms = std.math.maxInt(i64) - 100;
    const association = Association.init(test_client_ip, started_at_ms);

    try std.testing.expectEqual(std.math.maxInt(i64), association.idleDeadline());
    try std.testing.expect(!association.isExpiredAt(std.math.maxInt(i64) - 1));
    try std.testing.expect(association.isExpiredAt(std.math.maxInt(i64)));
}
