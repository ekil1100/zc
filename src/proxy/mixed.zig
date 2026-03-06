const std = @import("std");
const net = std.net;
const outbound = @import("outbound/manager.zig");
const ProxyStream = outbound.ProxyStream;
const Engine = @import("../rule/engine.zig").Engine;
const OutboundManager = outbound.OutboundManager;
const ss = @import("outbound/shadowsocks.zig");
const relay_poll_timeout_ms: i32 = -1;

/// 混合端口（HTTP + SOCKS5）
pub fn start(allocator: std.mem.Allocator, bind_address: []const u8, port: u16, engine: *Engine, manager: *OutboundManager) !void {
    const listen_ip = if (std.mem.eql(u8, bind_address, "*")) "0.0.0.0" else bind_address;
    const address = try net.Address.parseIp4(listen_ip, port);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.debug.print("Mixed proxy (HTTP+SOCKS5) listening on port {}\n", .{port});

    while (true) {
        const conn = try server.accept();
        try spawnConnectionTask(allocator, conn, engine, manager);
    }
}

const ConnTask = struct {
    allocator: std.mem.Allocator,
    conn: net.Server.Connection,
    engine: *Engine,
    manager: *OutboundManager,
};

fn spawnConnectionTask(allocator: std.mem.Allocator, conn: net.Server.Connection, engine: *Engine, manager: *OutboundManager) !void {
    const task = try allocator.create(ConnTask);
    errdefer allocator.destroy(task);
    task.* = .{
        .allocator = allocator,
        .conn = conn,
        .engine = engine,
        .manager = manager,
    };

    const thread = try std.Thread.spawn(.{}, connectionTaskMain, .{task});
    thread.detach();
}

fn connectionTaskMain(task: *ConnTask) void {
    defer task.allocator.destroy(task);
    handleConnection(task.allocator, task.conn, task.engine, task.manager) catch |err| {
        std.debug.print("Mixed connection error: {}\n", .{err});
    };
}

fn handleConnection(allocator: std.mem.Allocator, conn: net.Server.Connection, engine: *Engine, manager: *OutboundManager) !void {
    defer conn.stream.close();

    // 读取第一个字节来判断协议类型
    var first_byte: [1]u8 = undefined;
    const n = try conn.stream.read(&first_byte);
    if (n == 0) return;

    // 判断协议类型
    if (first_byte[0] == 0x05) {
        // SOCKS5 协议
        std.debug.print("[Mixed] Detected SOCKS5 connection\n", .{});
        try handleSocks5(allocator, conn, first_byte[0], engine, manager);
    } else if (first_byte[0] == 0x04) {
        // SOCKS4 协议（暂不支持，按 SOCKS5 处理）
        std.debug.print("[Mixed] Detected SOCKS4 connection (not supported)\n", .{});
        return;
    } else {
        // HTTP/HTTPS 代理（第一个字节是可打印字符如 'C', 'G', 'P', 'H' 等）
        std.debug.print("[Mixed] Detected HTTP connection\n", .{});
        try handleHttp(allocator, conn, first_byte[0], engine, manager);
    }
}

fn handleSocks5(allocator: std.mem.Allocator, conn: net.Server.Connection, first_byte: u8, engine: *Engine, manager: *OutboundManager) !void {
    _ = allocator;

    var buf: [256]u8 = undefined;
    const n = try conn.stream.read(&buf);
    if (n < 2) return error.InvalidGreeting;

    const num_methods = buf[0];
    if (n < 1 + num_methods) return error.InvalidGreeting;

    var found_no_auth = false;
    for (0..num_methods) |i| {
        if (buf[1 + i] == 0x00) {
            found_no_auth = true;
            break;
        }
    }
    if (!found_no_auth) {
        try conn.stream.writeAll(&.{ first_byte, 0xFF });
        return;
    }

    try conn.stream.writeAll(&.{ first_byte, 0x00 });

    const req_n = try conn.stream.read(&buf);
    if (req_n < 7) return error.InvalidRequest;
    if (buf[0] != 0x05) return error.InvalidVersion;
    if (buf[1] != 0x01) return error.CommandNotSupported;

    const atyp = buf[3];
    var target_port: u16 = 0;
    var host_buf: [256]u8 = undefined;
    const target_host: []const u8 = switch (atyp) {
        0x01 => blk: { // IPv4
            if (req_n < 10) return error.InvalidRequest;
            target_port = (@as(u16, buf[8]) << 8) | buf[9];
            break :blk try std.fmt.bufPrint(&host_buf, "{}.{}.{}.{}", .{ buf[4], buf[5], buf[6], buf[7] });
        },
        0x03 => blk: { // Domain
            const domain_len = buf[4];
            if (req_n < 5 + domain_len + 2) return error.InvalidRequest;
            target_port = (@as(u16, buf[5 + domain_len]) << 8) | buf[5 + domain_len + 1];
            break :blk buf[5 .. 5 + domain_len];
        },
        else => {
            try conn.stream.writeAll(&.{ 0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
            return;
        },
    };

    const proxy_name = engine.matchCtx(.{
        .target_host = target_host,
        .target_port = target_port,
        .is_domain = atyp == 0x03,
    }) orelse "DIRECT";

    std.debug.print("[Mixed] Rule matched: target={s}:{d} -> proxy={s}\n", .{ target_host, target_port, proxy_name });

    var target_stream = manager.connect(proxy_name, target_host, target_port) catch |err| {
        logConnectionFailure(target_host, target_port, proxy_name, err);
        try conn.stream.writeAll(&.{ 0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
        return;
    };
    defer target_stream.close();

    try conn.stream.writeAll(&.{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
    try relay(conn.stream, &target_stream);
}

fn handleHttp(allocator: std.mem.Allocator, conn: net.Server.Connection, first_byte: u8, engine: *Engine, manager: *OutboundManager) !void {
    // 读取完整请求
    var buf: [4096]u8 = undefined;
    buf[0] = first_byte;
    const n = try conn.stream.read(buf[1..]);
    if (n == 0) return;
    const request = buf[0 .. n + 1];

    // 查找 HTTP 方法
    const method_end = std.mem.indexOf(u8, request, " ");
    if (method_end == null) return;
    const method = request[0..method_end.?];

    if (std.mem.eql(u8, method, "CONNECT")) {
        try handleHttpConnect(allocator, conn, request, engine, manager);
    } else {
        try handleHttpRequest(allocator, conn, request, engine, manager);
    }
}

fn handleHttpConnect(_: std.mem.Allocator, conn: net.Server.Connection, request: []const u8, engine: *Engine, manager: *OutboundManager) !void {
    // 解析 CONNECT 请求
    const parts = std.mem.splitScalar(u8, request, ' ');
    var part_iter = parts;
    _ = part_iter.next(); // "CONNECT"
    const target = part_iter.next();

    if (target == null) return;

    const host_port = target.?;
    const colon_pos = std.mem.lastIndexOf(u8, host_port, ":");
    if (colon_pos == null) return;

    const host = host_port[0..colon_pos.?];
    const port_str = host_port[colon_pos.? + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        return;
    };

    std.debug.print("[Mixed] CONNECT {s}:{d}\n", .{ host, port });

    // 通过 outbound manager 连接
    const proxy_name = engine.match(host, true) orelse "DIRECT";
    std.debug.print("[Mixed] CONNECT route: {s}:{d} -> {s}\n", .{ host, port, proxy_name });
    var target_stream = manager.connect(proxy_name, host, port) catch |err| {
        logConnectionFailure(host, port, proxy_name, err);
        _ = try conn.stream.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
    };
    defer target_stream.close();

    // 发送成功响应
    _ = try conn.stream.write("HTTP/1.1 200 Connection established\r\n\r\n");

    // 双向转发
    try relay(conn.stream, &target_stream);
}

fn handleHttpRequest(allocator: std.mem.Allocator, conn: net.Server.Connection, request: []const u8, engine: *Engine, manager: *OutboundManager) !void {
    // 解析目标 host
    const host = extractHost(request) catch {
        return;
    };
    const port: u16 = 80;

    std.debug.print("[Mixed] HTTP {s}:{d}\n", .{ host, port });

    // 连接目标
    const proxy_name = engine.match(host, true) orelse "DIRECT";
    std.debug.print("[Mixed] HTTP route: {s}:{d} -> {s}\n", .{ host, port, proxy_name });
    var target_stream = manager.connect(proxy_name, host, port) catch |err| {
        logConnectionFailure(host, port, proxy_name, err);
        _ = try conn.stream.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
    };
    defer target_stream.close();

    // 转发请求
    try target_stream.write(request);

    // 双向转发（使用 poll 避免阻塞）
    try relay(conn.stream, &target_stream);
    _ = allocator;
}

fn logConnectionFailure(target: []const u8, port: u16, proxy_name: []const u8, err: anyerror) void {
    switch (err) {
        error.UpstreamDnsResolveFailed => std.debug.print("[Mixed] Connection failed: kind=upstream_dns target={s}:{d} proxy={s} err={}\n", .{ target, port, proxy_name, err }),
        error.UpstreamTcpConnectFailed => std.debug.print("[Mixed] Connection failed: kind=upstream_connect target={s}:{d} proxy={s} err={}\n", .{ target, port, proxy_name, err }),
        error.TargetDnsResolveFailed => std.debug.print("[Mixed] Connection failed: kind=target_dns target={s}:{d} proxy={s} err={}\n", .{ target, port, proxy_name, err }),
        error.TargetTcpConnectFailed => std.debug.print("[Mixed] Connection failed: kind=target_connect target={s}:{d} proxy={s} err={}\n", .{ target, port, proxy_name, err }),
        else => std.debug.print("[Mixed] Connection failed: kind=other target={s}:{d} proxy={s} err={}\n", .{ target, port, proxy_name, err }),
    }
}

fn extractHost(request: []const u8) ![]const u8 {
    const host_prefix = "Host: ";
    const host_start = std.mem.indexOf(u8, request, host_prefix);
    if (host_start == null) return error.NoHost;

    const after_host = host_start.? + host_prefix.len;
    const host_end = std.mem.indexOf(u8, request[after_host..], "\r\n");
    if (host_end == null) return error.NoHost;

    return request[after_host .. after_host + host_end.?];
}

fn relay(client_stream: net.Stream, target_stream: *ProxyStream) !void {
    relayLog("Starting relay", .{});
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = client_stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = target_stream.base_stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var buf: [8192]u8 = undefined;
    var up_bytes: usize = 0;
    var down_bytes: usize = 0;
    var last_report_ms = std.time.milliTimestamp();

    while (true) {
        // Important: encrypted upstream may still have decrypted leftover bytes in memory
        // even when socket has no new readable event.
        try drainTargetPending(client_stream, target_stream, &buf, &down_bytes);

        _ = try std.posix.poll(&poll_fds, relay_poll_timeout_ms);

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const n = try std.posix.read(client_stream.handle, &buf);
            if (n == 0) break;
            try target_stream.write(buf[0..n]);
            up_bytes += n;
        }

        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            const n = try target_stream.read(&buf);
            if (n == 0) break;
            var written: usize = 0;
            while (written < n) {
                written += try std.posix.write(client_stream.handle, buf[written..n]);
            }
            down_bytes += n;
        }

        const now_ms = std.time.milliTimestamp();
        if (now_ms - last_report_ms >= 1000) {
            relayFlushStats(&up_bytes, &down_bytes, false);
            last_report_ms = now_ms;
        }

        if ((poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0 or
            (poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0)
        {
            relayFlushStats(&up_bytes, &down_bytes, true);
            relayLog("Poll error/hup", .{});
            break;
        }
    }
    relayFlushStats(&up_bytes, &down_bytes, true);
    relayLog("Done", .{});
}

fn drainTargetPending(client_stream: net.Stream, target_stream: *ProxyStream, buf: []u8, down_bytes: *usize) !void {
    while (target_stream.hasPendingRead()) {
        const n = try target_stream.read(buf);
        if (n == 0) break;
        var written: usize = 0;
        while (written < n) {
            written += try std.posix.write(client_stream.handle, buf[written..n]);
        }
        down_bytes.* += n;
    }
}

fn relayFlushStats(up_bytes: *usize, down_bytes: *usize, force: bool) void {
    if (up_bytes.* == 0 and down_bytes.* == 0 and !force) return;
    relayLog("window traffic: up={}B down={}B", .{ up_bytes.*, down_bytes.* });
    up_bytes.* = 0;
    down_bytes.* = 0;
}

test "relay drains SS pending leftover without poll event" {
    const allocator = std.testing.allocator;

    const client_pair = try makeTcpStreamPair();
    defer client_pair.left.close();
    defer client_pair.right.close();
    const target_pair = try makeTcpStreamPair();
    defer target_pair.right.close();

    const client_stream = client_pair.left;
    const peer_stream = client_pair.right;
    const target_base = target_pair.left;

    const ss_client = try allocator.create(ss.ShadowsocksClient);
    errdefer allocator.destroy(ss_client);
    ss_client.* = try ss.ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");
    ss_client.read_payload_leftover = try allocator.dupe(u8, "hello");

    var target_stream = ProxyStream.initShadowsocks(allocator, target_base, ss_client);
    defer target_stream.close();

    var relay_thread = try std.Thread.spawn(.{}, struct {
        fn run(cs: net.Stream, ts: *ProxyStream) void {
            _ = relay(cs, ts) catch {};
        }
    }.run, .{ client_stream, &target_stream });

    var out: [5]u8 = undefined;
    const n = try std.posix.read(peer_stream.handle, &out);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", out[0..n]);

    peer_stream.close();
    relay_thread.join();
}

test "mixed relay keeps idle tunnels open by default" {
    try std.testing.expectEqual(@as(i32, -1), relay_poll_timeout_ms);
}

test "relay forwards traffic in both directions (direct stream)" {
    const client_pair = try makeTcpStreamPair();
    defer client_pair.left.close();
    defer client_pair.right.close();
    const target_pair = try makeTcpStreamPair();
    defer target_pair.right.close();

    const client_stream = client_pair.left;
    const client_peer = client_pair.right;
    const target_stream = target_pair.left;
    const target_peer = target_pair.right;

    var proxy_stream = ProxyStream.initDirect(target_stream);
    defer proxy_stream.close();

    var relay_thread = try std.Thread.spawn(.{}, struct {
        fn run(cs: net.Stream, ts: *ProxyStream) void {
            _ = relay(cs, ts) catch {};
        }
    }.run, .{ client_stream, &proxy_stream });

    try std.posix.writeAll(client_peer.handle, "ping");
    var buf: [4]u8 = undefined;
    const n1 = try std.posix.read(target_peer.handle, &buf);
    try std.testing.expectEqual(@as(usize, 4), n1);
    try std.testing.expectEqualStrings("ping", buf[0..n1]);

    try std.posix.writeAll(target_peer.handle, "pong");
    var buf2: [4]u8 = undefined;
    const n2 = try std.posix.read(client_peer.handle, &buf2);
    try std.testing.expectEqual(@as(usize, 4), n2);
    try std.testing.expectEqualStrings("pong", buf2[0..n2]);

    client_peer.close();
    target_peer.close();
    relay_thread.join();
}

test "handleConnection should close client stream after successful HTTP relay" {
    const allocator = std.testing.allocator;

    var cfg = @import("../config.zig").Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(@import("../config.zig").Proxy).empty,
        .proxy_groups = std.ArrayList(@import("../config.zig").ProxyGroup).empty,
        .rules = std.ArrayList(@import("../config.zig").Rule).empty,
    };
    defer cfg.deinit();

    var manager = try outbound.OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    var engine = try Engine.init(allocator, &cfg.rules);
    defer engine.deinit();

    const upstream_addr = try net.Address.parseIp4("127.0.0.1", 0);
    var upstream_server = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream_server.deinit();

    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn run(server: *net.Server) void {
            const conn = server.accept() catch return;
            defer conn.stream.close();

            var buf: [1024]u8 = undefined;
            _ = conn.stream.read(&buf) catch return;
            _ = conn.stream.write("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n") catch return;
        }
    }.run, .{&upstream_server});
    defer upstream_thread.join();

    const target_port = upstream_server.listen_address.getPort();
    const req = try std.fmt.allocPrint(allocator, "GET / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{target_port});
    defer allocator.free(req);

    const mixed_pair = try makeTcpStreamPair();
    defer mixed_pair.left.close();
    defer mixed_pair.right.close();

    const mixed_conn = net.Server.Connection{
        .stream = mixed_pair.left,
        .address = try net.Address.parseIp4("127.0.0.1", 12345),
    };
    const mixed_client = mixed_pair.right;

    try mixed_client.writeAll(req);
    try handleConnection(allocator, mixed_conn, &engine, &manager);

    var resp_buf: [1024]u8 = undefined;
    _ = mixed_client.read(&resp_buf) catch 0;

    try setReadTimeoutMs(mixed_client.handle, 100);
    var one: [1]u8 = undefined;
    const n = mixed_client.read(&one) catch |err| switch (err) {
        error.WouldBlock => @as(usize, 1),
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 0), n);
}

fn setReadTimeoutMs(fd: std.posix.fd_t, timeout_ms: u32) !void {
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
}

const StreamPair = struct {
    left: net.Stream,
    right: net.Stream,
};

fn makeTcpStreamPair() !StreamPair {
    const addr = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const client = try net.tcpConnectToAddress(server.listen_address);
    const accepted = try server.accept();
    return .{
        .left = accepted.stream,
        .right = client,
    };
}

fn relayLog(comptime format: []const u8, args: anytype) void {
    const ts = std.time.timestamp();
    std.debug.print("[{d}] [Relay] ", .{ts});
    std.debug.print(format, args);
    std.debug.print("\n", .{});
}
