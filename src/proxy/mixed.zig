const std = @import("std");
const net = std.net;
const outbound = @import("outbound/manager.zig");
const ProxyStream = outbound.ProxyStream;
const Engine = @import("../rule/engine.zig").Engine;
const OutboundManager = outbound.OutboundManager;

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

        // 为每个连接创建独立任务
        const conn_allocator = allocator;
        handleConnection(conn_allocator, conn, engine, manager) catch |err| {
            std.debug.print("Mixed connection error: {}\n", .{err});
            conn.stream.close();
        };
    }
}

fn handleConnection(allocator: std.mem.Allocator, conn: net.Server.Connection, engine: *Engine, manager: *OutboundManager) !void {
    // 读取第一个字节来判断协议类型
    var first_byte: [1]u8 = undefined;
    const n = try conn.stream.read(&first_byte);
    if (n == 0) {
        conn.stream.close();
        return;
    }

    // 判断协议类型
    if (first_byte[0] == 0x05) {
        // SOCKS5 协议
        std.debug.print("[Mixed] Detected SOCKS5 connection\n", .{});
        try handleSocks5(allocator, conn, first_byte[0], engine, manager);
    } else if (first_byte[0] == 0x04) {
        // SOCKS4 协议（暂不支持，按 SOCKS5 处理）
        std.debug.print("[Mixed] Detected SOCKS4 connection (not supported)\n", .{});
        conn.stream.close();
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
        conn.stream.close();
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
            conn.stream.close();
            return;
        },
    };

    const proxy_name = engine.matchCtx(.{
        .target_host = target_host,
        .target_port = target_port,
        .is_domain = atyp == 0x03,
    }) orelse "DIRECT";

    std.debug.print("[Mixed] Rule matched: target={s}:{d} -> proxy={s}\n", .{ target_host, target_port, proxy_name });

    var target_stream = manager.connect(proxy_name, target_host, target_port) catch {
        try conn.stream.writeAll(&.{ 0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
        conn.stream.close();
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
    if (n == 0) {
        conn.stream.close();
        return;
    }
    const request = buf[0 .. n + 1];

    // 查找 HTTP 方法
    const method_end = std.mem.indexOf(u8, request, " ");
    if (method_end == null) {
        conn.stream.close();
        return;
    }
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

    if (target == null) {
        conn.stream.close();
        return;
    }

    const host_port = target.?;
    const colon_pos = std.mem.lastIndexOf(u8, host_port, ":");
    if (colon_pos == null) {
        conn.stream.close();
        return;
    }

    const host = host_port[0..colon_pos.?];
    const port_str = host_port[colon_pos.? + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        conn.stream.close();
        return;
    };

    std.debug.print("[Mixed] CONNECT {s}:{d}\n", .{ host, port });

    // 通过 outbound manager 连接
    const proxy_name = engine.match(host, true) orelse "DIRECT";
    var target_stream = manager.connect(proxy_name, host, port) catch |err| {
        std.debug.print("[Mixed] Connection failed: {}\n", .{err});
        _ = try conn.stream.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        conn.stream.close();
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
        conn.stream.close();
        return;
    };
    const port: u16 = 80;

    std.debug.print("[Mixed] HTTP {s}:{d}\n", .{ host, port });

    // 连接目标
    const proxy_name = engine.match(host, true) orelse "DIRECT";
    var target_stream = manager.connect(proxy_name, host, port) catch |err| {
        std.debug.print("[Mixed] Connection failed: {}\n", .{err});
        _ = try conn.stream.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        conn.stream.close();
        return;
    };
    defer target_stream.close();

    // 转发请求
    try target_stream.write(request);

    // 双向转发（使用 poll 避免阻塞）
    try relay(conn.stream, &target_stream);
    _ = allocator;
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
    std.debug.print("[Relay] Starting relay\n", .{});
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = client_stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = target_stream.base_stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var buf: [8192]u8 = undefined;

    while (true) {
        _ = try std.posix.poll(&poll_fds, -1);

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const n = try std.posix.read(client_stream.handle, &buf);
            std.debug.print("[Relay] Client -> Proxy: {} bytes\n", .{n});
            if (n == 0) break;
            try target_stream.write(buf[0..n]);
        }

        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            const n = try target_stream.read(&buf);
            std.debug.print("[Relay] Proxy -> Client: {} bytes\n", .{n});
            if (n == 0) break;
            var written: usize = 0;
            while (written < n) {
                written += try std.posix.write(client_stream.handle, buf[written..n]);
            }
        }

        if ((poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0 or
            (poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0)
        {
            std.debug.print("[Relay] Poll error/hup\n", .{});
            break;
        }
    }
    std.debug.print("[Relay] Done\n", .{});
}
