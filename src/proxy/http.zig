const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const Engine = @import("../rule/engine.zig").Engine;
const outbound = @import("outbound/manager.zig");
const OutboundManager = outbound.OutboundManager;
const ProxyStream = outbound.ProxyStream;
const socket_options = @import("../socket_options.zig");

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

    std.debug.print("HTTP proxy listening on port {}\n", .{port});
    if (ready_count) |count| _ = count.fetchAdd(1, .release);
    if (accept_gate) |gate| {
        while (!gate.load(.acquire)) {
            compat.sleepNs(1 * std.time.ns_per_ms);
        }
    }

    while (true) {
        const conn = try server.accept();
        socket_options.configureConnectedStream(conn.stream) catch |err| {
            std.debug.print("HTTP accepted socket setup error: {}\n", .{err});
            conn.stream.close();
            continue;
        };

        handleConnection(allocator, conn, engine, manager) catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
            conn.stream.close();
        };
    }
}

fn handleConnection(_: std.mem.Allocator, conn: net.Server.Connection, engine: *Engine, manager: *OutboundManager) !void {
    defer conn.stream.close();

    var buf: [4096]u8 = undefined;
    const n = try conn.stream.read(&buf);
    if (n == 0) return;

    const request = buf[0..n];

    const method_end = std.mem.indexOf(u8, request, " ");
    if (method_end == null) return error.InvalidRequest;

    const method = request[0..method_end.?];

    if (std.mem.eql(u8, method, "CONNECT")) {
        try handleConnect(conn, request, engine, manager);
    } else {
        try handleHttp(conn, request, engine, manager);
    }
}

fn handleConnect(conn: net.Server.Connection, request: []const u8, engine: *Engine, manager: *OutboundManager) !void {
    const parts = std.mem.splitScalar(u8, request, ' ');
    var part_iter = parts;
    _ = part_iter.next();
    const target = part_iter.next();

    if (target == null) return error.InvalidRequest;

    const host_port = target.?;
    const colon_pos = std.mem.lastIndexOf(u8, host_port, ":");
    if (colon_pos == null) return error.InvalidHost;

    const host = host_port[0..colon_pos.?];
    const port_str = host_port[colon_pos.? + 1 ..];
    const port = try std.fmt.parseInt(u16, port_str, 10);

    std.debug.print("[HTTP] CONNECT {s}:{d}\n", .{ host, port });

    const proxy_name = engine.match(host, true) orelse "DIRECT";
    std.debug.print("[HTTP] Rule matched: {s}\n", .{proxy_name});

    var target_stream = manager.connect(proxy_name, host, port) catch |err| {
        std.debug.print("[HTTP] Connection failed: {}\n", .{err});
        try conn.stream.writeAll("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
    };
    defer target_stream.close();

    try conn.stream.writeAll("HTTP/1.1 200 Connection established\r\n\r\n");
    try relayHttp(conn.stream, &target_stream);
}

fn handleHttp(conn: net.Server.Connection, request: []const u8, engine: *Engine, manager: *OutboundManager) !void {
    const host = try extractHost(request);
    const uri = try extractUri(request);

    std.debug.print("[HTTP] {s} {s} (Host: {s})\n", .{ request[0..std.mem.indexOf(u8, request, " ").?], uri, host });

    const proxy_name = engine.match(host, true) orelse "DIRECT";
    std.debug.print("[HTTP] Rule matched: {s}\n", .{proxy_name});

    // Parse port from host (default 80)
    var port: u16 = 80;
    const host_to_connect = blk: {
        if (std.mem.indexOf(u8, host, ":")) |colon| {
            port = try std.fmt.parseInt(u16, host[colon + 1 ..], 10);
            break :blk host[0..colon];
        }
        break :blk host;
    };

    var target_stream = manager.connect(proxy_name, host_to_connect, port) catch |err| {
        std.debug.print("[HTTP] Connection failed: {}\n", .{err});
        try conn.stream.writeAll("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
    };
    defer target_stream.close();

    // Forward the request
    try target_stream.write(request);

    // Relay response back
    try relayHttp(conn.stream, &target_stream);
}

fn extractHost(request: []const u8) ![]const u8 {
    const host_prefix = "Host: ";
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, host_prefix)) {
            return std.mem.trim(u8, line[host_prefix.len..], " \t\r\n");
        }
    }
    return error.HostNotFound;
}

fn extractUri(request: []const u8) ![]const u8 {
    const first_space = std.mem.indexOf(u8, request, " ") orelse return error.InvalidRequest;
    const second_space = std.mem.indexOf(u8, request[first_space + 1 ..], " ") orelse return error.InvalidRequest;
    return request[first_space + 1 .. first_space + 1 + second_space];
}

fn relayHttp(client_stream: net.Stream, target_stream: *ProxyStream) !void {
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
