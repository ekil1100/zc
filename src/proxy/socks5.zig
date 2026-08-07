const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const Engine = @import("../rule/engine.zig").Engine;
const outbound = @import("outbound/manager.zig");
const OutboundManager = outbound.OutboundManager;
const ProxyStream = outbound.ProxyStream;
const socket_options = @import("../socket_options.zig");

const Socks5Version = 0x05;
const AuthMethods = struct {
    const NoAuth: u8 = 0x00;
    const Password: u8 = 0x02;
    const NoAcceptable: u8 = 0xFF;
};

const Command = struct {
    const Connect: u8 = 0x01;
};

const AddressType = struct {
    const Ipv4: u8 = 0x01;
    const Domain: u8 = 0x03;
    const Ipv6: u8 = 0x04;
};

const Reply = struct {
    const Success: u8 = 0x00;
    const GeneralFailure: u8 = 0x01;
    const ConnectionRefused: u8 = 0x05;
    const HostUnreachable: u8 = 0x04;
    const AddressNotSupported: u8 = 0x08;
};

pub fn start(
    allocator: std.mem.Allocator,
    bind_address: []const u8,
    port: u16,
    engine: *Engine,
    manager: *OutboundManager,
) !void {
    return startWithReady(
        allocator,
        bind_address,
        port,
        engine,
        manager,
        null,
        null,
    );
}

pub fn startWithReady(
    allocator: std.mem.Allocator,
    bind_address: []const u8,
    port: u16,
    engine: *Engine,
    manager: *OutboundManager,
    ready_count: ?*std.atomic.Value(u8),
    accept_gate: ?*std.atomic.Value(bool),
) !void {
    const listen_ip = if (std.mem.eql(u8, bind_address, "*")) "0.0.0.0" else bind_address;
    const address = try net.Address.parseIp4(listen_ip, port);
    // SO_REUSEADDR-only (see compat.net.listenReuseAddr): rebind past TIME_WAIT
    // on restart, but a second active listener still fails (no SO_REUSEPORT).
    var server = try net.listenReuseAddr(address);
    defer server.deinit();

    std.debug.print("SOCKS5 proxy listening on port {}\n", .{port});
    if (ready_count) |count| _ = count.fetchAdd(1, .release);
    if (accept_gate) |gate| {
        while (!gate.load(.acquire)) {
            compat.sleepNs(1 * std.time.ns_per_ms);
        }
    }

    while (true) {
        const conn = try server.accept();
        socket_options.configureConnectedStream(conn.stream) catch |err| {
            std.debug.print("SOCKS5 accepted socket setup error: {}\n", .{err});
            conn.stream.close();
            continue;
        };

        // Pass engine and manager to each connection handler
        const ctx = try allocator.create(ConnectionContext);
        ctx.* = .{
            .allocator = allocator,
            .engine = engine,
            .manager = manager,
        };

        const thread = try std.Thread.spawn(.{}, handleConnectionThread, .{ ctx, conn });
        thread.detach();
    }
}

const ConnectionContext = struct {
    allocator: std.mem.Allocator,
    engine: *Engine,
    manager: *OutboundManager,
};

fn handleConnectionThread(ctx: *ConnectionContext, conn: net.Server.Connection) !void {
    defer ctx.allocator.destroy(ctx);
    handleConnection(ctx.allocator, conn, ctx.engine, ctx.manager) catch |err| {
        std.debug.print("SOCKS5 connection error: {}\n", .{err});
        conn.stream.close();
    };
}

fn handleConnection(_allocator: std.mem.Allocator, conn: net.Server.Connection, engine: *Engine, manager: *OutboundManager) !void {
    _ = _allocator;
    defer conn.stream.close();

    // 1. Greeting phase
    var buf: [256]u8 = undefined;
    const n = try conn.stream.read(&buf);
    if (n < 3) return error.InvalidGreeting;

    if (buf[0] != Socks5Version) return error.InvalidVersion;

    const num_methods = buf[1];
    if (n < 2 + num_methods) return error.InvalidGreeting;

    var found_no_auth = false;
    for (0..num_methods) |i| {
        if (buf[2 + i] == AuthMethods.NoAuth) {
            found_no_auth = true;
            break;
        }
    }

    if (!found_no_auth) {
        try conn.stream.writeAll(&.{ Socks5Version, AuthMethods.NoAcceptable });
        return error.NoAcceptableAuth;
    }

    try conn.stream.writeAll(&.{ Socks5Version, AuthMethods.NoAuth });

    // 2. Request phase
    const req_n = try conn.stream.read(&buf);
    if (req_n < 10) return error.InvalidRequest;

    if (buf[0] != Socks5Version) return error.InvalidVersion;

    const cmd = buf[1];
    const atyp = buf[3];

    if (cmd != Command.Connect) {
        try sendReply(conn.stream, Reply.GeneralFailure, 0, &[_]u8{0} ** 4, 0);
        return error.CommandNotSupported;
    }

    var target_host: []const u8 = undefined;
    var target_port: u16 = undefined;
    var host_buf: [256]u8 = undefined;

    switch (atyp) {
        AddressType.Ipv4 => {
            if (req_n < 10) return error.InvalidRequest;
            target_host = try std.fmt.bufPrint(&host_buf, "{}.{}.{}.{}", .{ buf[4], buf[5], buf[6], buf[7] });
            target_port = (@as(u16, buf[8]) << 8) | buf[9];
        },
        AddressType.Domain => {
            const domain_len: usize = buf[4];
            // Compute required length in usize to avoid u8 overflow when domain_len >= 249.
            if (!domainRequestFits(req_n, domain_len)) return error.InvalidRequest;
            target_host = buf[5 .. 5 + domain_len];
            target_port = (@as(u16, buf[5 + domain_len]) << 8) | buf[5 + domain_len + 1];
        },
        AddressType.Ipv6 => {
            try sendReply(conn.stream, Reply.AddressNotSupported, 0, &[_]u8{0} ** 4, 0);
            return error.Ipv6NotSupported;
        },
        else => return error.InvalidAddressType,
    }

    std.debug.print("[SOCKS5] CONNECT {s}:{d}\n", .{ target_host, target_port });

    // Apply rules from engine and connect via manager
    const proxy_name = engine.matchCtx(.{
        .target_host = target_host,
        .target_port = target_port,
        .is_domain = atyp == AddressType.Domain,
    }) orelse "DIRECT";
    std.debug.print("[SOCKS5] Rule matched: {s}\n", .{proxy_name});

    var target_stream = manager.connect(proxy_name, target_host, target_port) catch |err| {
        std.debug.print("[SOCKS5] Connection failed: {}\n", .{err});
        const reply_code = mapConnectErrorToReply(err);
        try sendReply(conn.stream, reply_code, 0, &[_]u8{0} ** 4, 0);
        return;
    };
    defer target_stream.close();

    const bind_addr = net.Address.parseIp4("0.0.0.0", 0) catch unreachable;
    const bind_port: u16 = 0;
    const addr_bytes = std.mem.asBytes(&bind_addr.in.sa.addr);
    try sendReply(conn.stream, Reply.Success, AddressType.Ipv4, addr_bytes[0..4], bind_port);

    try relaySocks5(conn.stream, &target_stream);
}

fn sendReply(stream: net.Stream, reply: u8, atyp: u8, addr: *const [4]u8, port: u16) !void {
    var resp: [10]u8 = undefined;
    resp[0] = Socks5Version;
    resp[1] = reply;
    resp[2] = 0x00;
    resp[3] = atyp;
    resp[4] = addr[0];
    resp[5] = addr[1];
    resp[6] = addr[2];
    resp[7] = addr[3];
    resp[8] = @intCast(port >> 8);
    resp[9] = @intCast(port & 0xFF);
    try stream.writeAll(&resp);
}

fn relaySocks5(client_stream: net.Stream, target_stream: *ProxyStream) !void {
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = client_stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = target_stream.getHandle(), .events = std.posix.POLL.IN, .revents = 0 },
    };

    var buf: [8192]u8 = undefined;

    while (true) {
        // A single outbound socket read may buffer more than one frame (e.g.
        // shadowsocks); drain what's already decryptable before polling so a
        // buffered frame never waits for the next socket-readable event.
        while (target_stream.hasPendingRead()) {
            const n = target_stream.read(&buf) catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };
            if (n == 0) return;
            var w: usize = 0;
            while (w < n) w += try compat.posixSocketWrite(client_stream.handle, buf[w..n]);
        }

        _ = try std.posix.poll(&poll_fds, -1);

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const n = try compat.posixRead(client_stream.handle, &buf);
            if (n == 0) break;
            try target_stream.write(buf[0..n]);
        }

        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            const n = target_stream.read(&buf) catch |err| {
                // Partial frame buffered: re-poll instead of tearing down.
                if (err == error.WouldBlock) continue;
                return err;
            };
            if (n == 0) break;
            var written: usize = 0;
            while (written < n) {
                written += try compat.posixSocketWrite(client_stream.handle, buf[written..n]);
            }
        }

        if ((poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0 or
            (poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0)
        {
            break;
        }
    }
}

/// Returns true if a SOCKS5 domain request of the given total bytes (`req_n`)
/// is long enough to hold the domain (`domain_len`) plus its 2-byte port.
/// The arithmetic must be done in a wide type: with `domain_len` as a u8,
/// `5 + domain_len + 2` overflows once domain_len >= 249 (panic in safe
/// builds, wraparound -> OOB read in ReleaseFast).
fn domainRequestFits(req_n: usize, domain_len: usize) bool {
    return req_n >= 5 + domain_len + 2;
}

fn mapConnectErrorToReply(err: anyerror) u8 {
    return switch (err) {
        error.ConnectionRejected => Reply.ConnectionRefused,
        error.ProxyNotFound,
        error.TargetDnsResolveFailed,
        error.UpstreamDnsResolveFailed,
        => Reply.HostUnreachable,
        error.TargetTcpConnectFailed,
        error.UpstreamTcpConnectFailed,
        => Reply.ConnectionRefused,
        else => Reply.GeneralFailure,
    };
}

test "mapConnectErrorToReply maps DNS errors to host unreachable" {
    try std.testing.expectEqual(@as(u8, Reply.HostUnreachable), mapConnectErrorToReply(error.TargetDnsResolveFailed));
    try std.testing.expectEqual(@as(u8, Reply.HostUnreachable), mapConnectErrorToReply(error.UpstreamDnsResolveFailed));
}

test "mapConnectErrorToReply maps connect errors to connection refused" {
    try std.testing.expectEqual(@as(u8, Reply.ConnectionRefused), mapConnectErrorToReply(error.TargetTcpConnectFailed));
    try std.testing.expectEqual(@as(u8, Reply.ConnectionRefused), mapConnectErrorToReply(error.UpstreamTcpConnectFailed));
}

test "mapConnectErrorToReply maps unknown errors to general failure" {
    try std.testing.expectEqual(@as(u8, Reply.GeneralFailure), mapConnectErrorToReply(error.NotImplemented));
}

test "domainRequestFits does not overflow for large domain lengths" {
    // domain_len drawn from an attacker-controlled u8 (0..255). With the old
    // u8 arithmetic, `5 + domain_len + 2` overflowed/wrapped for domain_len >= 249.
    // A maximal-length domain (255) needs 5 + 255 + 2 = 262 bytes total; a short
    // 6-byte request must NOT be accepted (the wraparound bug made it pass).
    const domain_len: u8 = 255;
    try std.testing.expect(!domainRequestFits(6, domain_len));
    try std.testing.expect(!domainRequestFits(261, domain_len));
    try std.testing.expect(domainRequestFits(262, domain_len));

    // Boundary just below the old overflow threshold still behaves correctly.
    try std.testing.expect(!domainRequestFits(255, @as(u8, 249)));
    try std.testing.expect(domainRequestFits(256, @as(u8, 249)));
}
