const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const http = std.http;
const outbound = @import("outbound/manager.zig");
const ProxyStream = outbound.ProxyStream;
const Engine = @import("../rule/engine.zig").Engine;
const OutboundManager = outbound.OutboundManager;
const aead = @import("../crypto/aead.zig");
const ss = @import("outbound/shadowsocks.zig");
const socket_options = @import("../socket_options.zig");

// macOS reserves 16MiB of virtual stack per pthread by default. The mixed
// proxy creates one detached worker per accepted connection, so the default
// stack size makes a small number of stale/idle tunnels look like hundreds of
// megabytes in Activity Monitor. Keep the worker stack explicit and bounded.
const connection_task_stack_size: usize = 512 * 1024;

// Use a heartbeat instead of an infinite poll so relays that miss EOF/HUP on
// macOS can still be reaped. The idle budget is intentionally much larger than
// the old 30s timeout that broke long-lived tunnels/WebSockets.
const relay_poll_timeout_ms: i32 = 30 * 1000;
const relay_idle_reap_ms: i64 = 15 * 60 * 1000;
const accept_retry_backoff_ms: u64 = 200;

/// 混合端口（HTTP + SOCKS5）
pub fn start(allocator: std.mem.Allocator, bind_address: []const u8, port: u16, engine: *Engine, manager: *OutboundManager) !void {
    const listen_ip = if (std.mem.eql(u8, bind_address, "*")) "0.0.0.0" else bind_address;
    const address = try net.Address.parseIp4(listen_ip, port);
    var server = try address.listen(.{
        .reuse_address = false,
    });
    defer server.deinit();

    std.debug.print("Mixed proxy (HTTP+SOCKS5) listening on port {}\n", .{port});

    while (true) {
        const conn = server.accept() catch |err| {
            if (shouldRetryAcceptError(err)) {
                std.debug.print("Mixed accept resource pressure: {}, retrying\n", .{err});
                compat.sleepNs(accept_retry_backoff_ms * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        socket_options.configureConnectedStream(conn.stream) catch |err| {
            std.debug.print("Mixed accepted socket setup error: {}\n", .{err});
            conn.stream.close();
            continue;
        };
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

    const thread = try std.Thread.spawn(.{ .stack_size = connection_task_stack_size }, connectionTaskMain, .{task});
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
            const domain_len: usize = buf[4];
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
    // Read a full HTTP header block. CONNECT headers may arrive fragmented across
    // multiple TCP reads; tunneling before seeing \r\n\r\n can leak the remaining
    // proxy headers into the upstream TLS stream.
    var buf: [4096]u8 = undefined;
    buf[0] = first_byte;
    var total: usize = 1;

    while (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") == null) {
        if (total == buf.len) return error.HttpHeaderTooLarge;
        const n = try conn.stream.read(buf[total..]);
        if (n == 0) return error.UnexpectedEof;
        total += n;
    }
    const request = buf[0..total];

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

const ForwardScheme = enum {
    http,
    https,
};

const ForwardRequest = struct {
    method_text: []const u8,
    method: http.Method,
    version_text: []const u8,
    host: []const u8,
    port: u16,
    scheme: ForwardScheme,
    origin_target: []const u8,
    header_end: usize,
    content_length: usize,
    absolute_form: bool,

    fn deinit(self: *ForwardRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.origin_target);
    }
};

const HttpsForwardStream = struct {
    allocator: std.mem.Allocator,
    inner: ProxyStream,
    ca_bundle: ?std.crypto.Certificate.Bundle = null,
    tls_client: std.crypto.tls.Client = undefined,
    tls_read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    upstream_reader: UpstreamReader = undefined,
    upstream_writer: UpstreamWriter = undefined,

    const UpstreamReader = struct {
        parent: *HttpsForwardStream,
        interface: std.Io.Reader,

        fn init(parent: *HttpsForwardStream, buffer: []u8) UpstreamReader {
            return .{
                .parent = parent,
                .interface = .{
                    .vtable = &.{ .stream = stream },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *UpstreamReader = @alignCast(@fieldParentPtr("interface", io_r));
            var buf: [4096]u8 = undefined;
            const n = self.parent.inner.read(&buf) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            return try w.write(buf[0..n]);
        }
    };

    const UpstreamWriter = struct {
        parent: *HttpsForwardStream,
        interface: std.Io.Writer,

        fn init(parent: *HttpsForwardStream, buffer: []u8) UpstreamWriter {
            return .{
                .parent = parent,
                .interface = .{
                    .vtable = &.{ .drain = drain },
                    .buffer = buffer,
                },
            };
        }

        fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *UpstreamWriter = @alignCast(@fieldParentPtr("interface", io_w));
            var total: usize = 0;

            const buffered = io_w.buffered();
            if (buffered.len > 0) {
                self.parent.inner.write(buffered) catch return error.WriteFailed;
                _ = io_w.consume(buffered.len);
                total += buffered.len;
            }

            if (data.len == 0) return total;

            for (data[0 .. data.len - 1]) |chunk| {
                if (chunk.len == 0) continue;
                self.parent.inner.write(chunk) catch return error.WriteFailed;
                total += chunk.len;
            }

            const last = data[data.len - 1];
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                if (last.len == 0) continue;
                self.parent.inner.write(last) catch return error.WriteFailed;
                total += last.len;
            }

            return total;
        }
    };

    fn init(self: *HttpsForwardStream, allocator: std.mem.Allocator, inner: ProxyStream, host: []const u8) !void {
        self.* = .{
            .allocator = allocator,
            .inner = inner,
        };
        errdefer self.inner.close();

        self.upstream_reader = UpstreamReader.init(self, &self.tls_read_buffer);
        self.upstream_writer = UpstreamWriter.init(self, &self.tls_write_buffer);

        self.ca_bundle = std.crypto.Certificate.Bundle.empty;
        if (self.ca_bundle) |*bundle| {
            try bundle.rescan(allocator, compat.io(), std.Io.Timestamp.now(compat.io(), .real));
        }
        errdefer if (self.ca_bundle) |*bundle| bundle.deinit(allocator);

        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        compat.randomBytes(&entropy);
        var ca_lock: std.Io.RwLock = .init;
        const now = std.Io.Timestamp.now(compat.io(), .real);

        self.tls_client = try std.crypto.tls.Client.init(
            &self.upstream_reader.interface,
            &self.upstream_writer.interface,
            .{
                .host = .{ .explicit = host },
                .ca = .{ .bundle = .{
                    .gpa = allocator,
                    .io = compat.io(),
                    .lock = &ca_lock,
                    .bundle = &self.ca_bundle.?,
                } },
                .allow_truncation_attacks = true,
                .read_buffer = &self.tls_read_buffer,
                .write_buffer = &self.tls_write_buffer,
                .entropy = &entropy,
                .realtime_now = now,
            },
        );
    }

    fn deinit(self: *HttpsForwardStream) void {
        _ = self.tls_client.end() catch {};
        if (self.ca_bundle) |*bundle| bundle.deinit(self.allocator);
        self.inner.close();
    }

    fn writeAll(self: *HttpsForwardStream, data: []const u8) !void {
        try self.tls_client.writer.writeAll(data);
        try self.tls_client.writer.flush();
    }

    fn read(self: *HttpsForwardStream, buf: []u8) !usize {
        return try self.tls_client.reader.readSliceShort(buf);
    }
};

fn parseForwardRequest(allocator: std.mem.Allocator, request: []const u8) !ForwardRequest {
    const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return error.InvalidRequest;
    const request_head = request[0..header_end];
    const first_line_end = std.mem.indexOf(u8, request_head, "\r\n") orelse request_head.len;
    const first_line = request_head[0..first_line_end];

    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method_text = parts.next() orelse return error.InvalidRequest;
    const target_text = parts.next() orelse return error.InvalidRequest;
    const version_text = parts.next() orelse return error.InvalidRequest;
    const method = std.meta.stringToEnum(http.Method, method_text) orelse return error.UnsupportedHttpMethod;

    var host_header: ?[]const u8 = null;
    var content_length: usize = 0;
    var lines = std.mem.splitSequence(u8, request_head[first_line_end..], "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "host")) {
            host_header = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch 0;
        }
    }

    if (std.mem.indexOf(u8, target_text, "://")) |_| {
        const uri = try std.Uri.parse(target_text);
        var host_buf: [255]u8 = undefined;
        const host = try allocator.dupe(u8, (try uri.getHost(&host_buf)).bytes);
        const scheme: ForwardScheme = if (std.mem.eql(u8, uri.scheme, "https"))
            .https
        else if (std.mem.eql(u8, uri.scheme, "http"))
            .http
        else
            return error.UnsupportedUriScheme;
        const port: u16 = uri.port orelse switch (scheme) {
            .http => 80,
            .https => 443,
        };
        const origin_target = try buildOriginTarget(allocator, uri);
        return .{
            .method_text = method_text,
            .method = method,
            .version_text = version_text,
            .host = host,
            .port = port,
            .scheme = scheme,
            .origin_target = origin_target,
            .header_end = header_end,
            .content_length = content_length,
            .absolute_form = true,
        };
    }

    const host_value = host_header orelse return error.NoHost;
    const host = try normalizeHostValue(allocator, host_value, false);
    const parsed_port = parsePortFromHostValue(host_value);
    const port = parsed_port orelse 80;
    return .{
        .method_text = method_text,
        .method = method,
        .version_text = version_text,
        .host = host,
        .port = port,
        .scheme = .http,
        .origin_target = try allocator.dupe(u8, target_text),
        .header_end = header_end,
        .content_length = content_length,
        .absolute_form = false,
    };
}

fn buildOriginTarget(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (uri.path.isEmpty()) {
        try out.append(allocator, '/');
    } else {
        try out.print(allocator, "{f}", .{std.fmt.alt(uri.path, .formatRaw)});
    }

    if (uri.query) |query| {
        try out.append(allocator, '?');
        try out.print(allocator, "{f}", .{std.fmt.alt(query, .formatRaw)});
    }

    return out.toOwnedSlice(allocator);
}

fn parsePortFromHostValue(host_value: []const u8) ?u16 {
    if (std.mem.lastIndexOfScalar(u8, host_value, ':')) |colon| {
        const maybe_port = host_value[colon + 1 ..];
        return std.fmt.parseInt(u16, maybe_port, 10) catch null;
    }
    return null;
}

fn normalizeHostValue(allocator: std.mem.Allocator, host_value: []const u8, keep_port: bool) ![]const u8 {
    if (keep_port) return try allocator.dupe(u8, host_value);
    if (std.mem.lastIndexOfScalar(u8, host_value, ':')) |colon| {
        if (std.fmt.parseInt(u16, host_value[colon + 1 ..], 10)) |_| {
            return try allocator.dupe(u8, host_value[0..colon]);
        } else |_| {}
    }
    return try allocator.dupe(u8, host_value);
}

fn buildForwardRequestHead(allocator: std.mem.Allocator, request_head: []const u8, forward: *const ForwardRequest, force_connection_close: bool) ![]u8 {
    const first_line_end = std.mem.indexOf(u8, request_head, "\r\n") orelse request_head.len;
    const header_lines = if (first_line_end + 2 <= request_head.len) request_head[first_line_end + 2 ..] else request_head[request_head.len..];

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "{s} {s} {s}\r\n", .{
        forward.method_text,
        forward.origin_target,
        forward.version_text,
    });

    var lines = std.mem.splitSequence(u8, header_lines, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            try out.print(allocator, "{s}\r\n", .{line});
            continue;
        };
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(name, "proxy-connection")) continue;
        if (force_connection_close and (std.ascii.eqlIgnoreCase(name, "connection") or std.ascii.eqlIgnoreCase(name, "keep-alive"))) continue;
        try out.print(allocator, "{s}\r\n", .{line});
    }

    if (force_connection_close) {
        try out.appendSlice(allocator, "Connection: close\r\n");
    }
    try out.appendSlice(allocator, "\r\n");
    return out.toOwnedSlice(allocator);
}

fn handleHttpConnect(_: std.mem.Allocator, conn: net.Server.Connection, request: []const u8, engine: *Engine, manager: *OutboundManager) !void {
    // 解析 CONNECT 请求
    const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse request.len;
    const request_head = request[0..header_end];
    const request_tail = if (header_end + 4 <= request.len) request[header_end + 4 ..] else request[request.len..];

    const parts = std.mem.splitScalar(u8, request_head, ' ');
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
        try conn.stream.writeAll("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
    };
    defer target_stream.close();

    // 发送成功响应
    try conn.stream.writeAll("HTTP/1.1 200 Connection established\r\n\r\n");

    // Some clients pipeline initial TLS bytes with CONNECT headers in the same TCP packet.
    // Forward any already-buffered tunnel payload instead of dropping it.
    if (request_tail.len > 0) {
        try target_stream.write(request_tail);
    }

    // 双向转发
    try relay(conn.stream, &target_stream);
}

fn handleHttpRequest(allocator: std.mem.Allocator, conn: net.Server.Connection, request: []const u8, engine: *Engine, manager: *OutboundManager) !void {
    var forward = parseForwardRequest(allocator, request) catch |err| {
        logHttpRequestParseError(request, err);
        return;
    };
    defer forward.deinit(allocator);

    std.debug.print(
        "[Mixed] HTTP parsed: method={s} scheme={s} host={s} port={d} absolute_form={} target={s}\n",
        .{
            forward.method_text,
            schemeLabel(forward.scheme),
            forward.host,
            forward.port,
            forward.absolute_form,
            forward.origin_target,
        },
    );

    if (forward.absolute_form and forward.scheme == .https) {
        try handleHttpsForwardRequest(allocator, conn, request, &forward, engine, manager);
        return;
    }

    std.debug.print("[Mixed] HTTP {s}:{d}\n", .{ forward.host, forward.port });

    const proxy_name = engine.match(forward.host, true) orelse "DIRECT";
    std.debug.print("[Mixed] HTTP route: {s}:{d} -> {s}\n", .{ forward.host, forward.port, proxy_name });
    var target_stream = manager.connect(proxy_name, forward.host, forward.port) catch |err| {
        logConnectionFailure(forward.host, forward.port, proxy_name, err);
        try conn.stream.writeAll("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
    };
    defer target_stream.close();

    const rewritten_head = try buildForwardRequestHead(allocator, request[0..forward.header_end], &forward, false);
    defer allocator.free(rewritten_head);

    try target_stream.write(rewritten_head);
    const request_tail = if (forward.header_end + 4 <= request.len) request[forward.header_end + 4 ..] else request[request.len..];
    if (request_tail.len > 0) {
        try target_stream.write(request_tail);
    }

    try relay(conn.stream, &target_stream);
}

fn handleHttpsForwardRequest(
    allocator: std.mem.Allocator,
    conn: net.Server.Connection,
    request: []const u8,
    forward: *const ForwardRequest,
    engine: *Engine,
    manager: *OutboundManager,
) !void {
    std.debug.print("[Mixed] HTTPS forward {s}:{d}\n", .{ forward.host, forward.port });

    const proxy_name = engine.match(forward.host, true) orelse "DIRECT";
    std.debug.print("[Mixed] HTTPS forward route: {s}:{d} -> {s}\n", .{ forward.host, forward.port, proxy_name });

    var target_stream = manager.connect(proxy_name, forward.host, forward.port) catch |err| {
        logConnectionFailure(forward.host, forward.port, proxy_name, err);
        try conn.stream.writeAll("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
    };
    if (target_stream.owned_ss_client == null and target_stream.owned_trojan_client == null) {
        defer target_stream.close();
        try handleDirectHttpsForwardStream(allocator, conn, request, forward, &target_stream);
        return;
    }
    errdefer target_stream.close();

    var tls_stream: HttpsForwardStream = undefined;
    tls_stream.init(allocator, target_stream.move(), forward.host) catch |err| {
        std.debug.print("[Mixed] HTTPS forward failed: stage=tls_init target={s}:{d} proxy={s} err={}\n", .{
            forward.host,
            forward.port,
            proxy_name,
            err,
        });
        try conn.stream.writeAll("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
    };
    defer tls_stream.deinit();
    std.debug.print("[Mixed] HTTPS forward tls ready: target={s}:{d}\n", .{ forward.host, forward.port });

    const request_head = try buildForwardRequestHead(allocator, request[0..forward.header_end], forward, true);
    defer allocator.free(request_head);

    const body = try readRequestBody(allocator, conn.stream, request, forward);
    defer allocator.free(body);

    tls_stream.writeAll(request_head) catch |err| {
        std.debug.print("[Mixed] HTTPS forward failed: stage=request_head_write target={s}:{d} err={}\n", .{
            forward.host,
            forward.port,
            err,
        });
        return err;
    };
    if (body.len > 0) {
        tls_stream.writeAll(body) catch |err| {
            std.debug.print("[Mixed] HTTPS forward failed: stage=request_body_write target={s}:{d} len={} err={}\n", .{
                forward.host,
                forward.port,
                body.len,
                err,
            });
            return err;
        };
    }
    std.debug.print("[Mixed] HTTPS forward request sent: target={s}:{d} body_len={}\n", .{ forward.host, forward.port, body.len });

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = tls_stream.read(&buf) catch |err| {
            std.debug.print("[Mixed] HTTPS forward failed: stage=response_read target={s}:{d} err={}\n", .{
                forward.host,
                forward.port,
                err,
            });
            return err;
        };
        if (n == 0) break;
        try conn.stream.writeAll(buf[0..n]);
    }
}

fn handleDirectHttpsForwardStream(
    allocator: std.mem.Allocator,
    conn: net.Server.Connection,
    request: []const u8,
    forward: *const ForwardRequest,
    target_stream: *ProxyStream,
) !void {
    var ca_bundle: std.crypto.Certificate.Bundle = .empty;
    const now = std.Io.Timestamp.now(compat.io(), .real);
    try ca_bundle.rescan(allocator, compat.io(), now);
    defer ca_bundle.deinit(allocator);
    var ca_lock: std.Io.RwLock = .init;

    var tls_read_buffer: [std.crypto.tls.Client.min_buffer_len + 8192]u8 = undefined;
    var tls_write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var socket_write_buffer: [1024]u8 = undefined;
    var socket_read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;

    var socket_writer = target_stream.base_stream.writer(&tls_write_buffer);
    var socket_reader = target_stream.base_stream.reader(&socket_read_buffer);
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    compat.randomBytes(&entropy);
    var tls_client = try std.crypto.tls.Client.init(
        &socket_reader.interface,
        &socket_writer.interface,
        .{
            .host = .{ .explicit = forward.host },
            .ca = .{ .bundle = .{
                .gpa = allocator,
                .io = compat.io(),
                .lock = &ca_lock,
                .bundle = &ca_bundle,
            } },
            .read_buffer = &tls_read_buffer,
            .write_buffer = &socket_write_buffer,
            .allow_truncation_attacks = true,
            .entropy = &entropy,
            .realtime_now = now,
        },
    );
    defer _ = tls_client.end() catch {};

    std.debug.print("[Mixed] HTTPS forward tls ready: target={s}:{d} mode=direct\n", .{ forward.host, forward.port });

    const request_head = try buildForwardRequestHead(allocator, request[0..forward.header_end], forward, true);
    defer allocator.free(request_head);

    const body = try readRequestBody(allocator, conn.stream, request, forward);
    defer allocator.free(body);

    tls_client.writer.writeAll(request_head) catch |err| {
        std.debug.print("[Mixed] HTTPS forward failed: stage=request_head_write target={s}:{d} mode=direct err={} stream_err={any}\n", .{
            forward.host,
            forward.port,
            err,
            socket_writer.err,
        });
        return err;
    };
    if (body.len > 0) {
        tls_client.writer.writeAll(body) catch |err| {
            std.debug.print("[Mixed] HTTPS forward failed: stage=request_body_write target={s}:{d} mode=direct len={} err={} stream_err={any}\n", .{
                forward.host,
                forward.port,
                body.len,
                err,
                socket_writer.err,
            });
            return err;
        };
    }
    tls_client.writer.flush() catch |err| {
        std.debug.print("[Mixed] HTTPS forward failed: stage=request_flush target={s}:{d} mode=direct err={} stream_err={any}\n", .{
            forward.host,
            forward.port,
            err,
            socket_writer.err,
        });
        return err;
    };
    socket_writer.interface.flush() catch |err| {
        std.debug.print("[Mixed] HTTPS forward failed: stage=socket_flush target={s}:{d} mode=direct err={} stream_err={any}\n", .{
            forward.host,
            forward.port,
            err,
            socket_writer.err,
        });
        return err;
    };
    std.debug.print("[Mixed] HTTPS forward request sent: target={s}:{d} body_len={} mode=direct\n", .{ forward.host, forward.port, body.len });

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = tls_client.reader.readSliceShort(&buf) catch |err| {
            std.debug.print("[Mixed] HTTPS forward failed: stage=response_read target={s}:{d} mode=direct err={}\n", .{
                forward.host,
                forward.port,
                err,
            });
            return err;
        };
        if (n == 0) break;
        try conn.stream.writeAll(buf[0..n]);
    }
}

fn readRequestBody(allocator: std.mem.Allocator, client_stream: net.Stream, request: []const u8, forward: *const ForwardRequest) ![]u8 {
    if (forward.content_length == 0) {
        return try allocator.alloc(u8, 0);
    }

    const initial_body = if (forward.header_end + 4 <= request.len) request[forward.header_end + 4 ..] else request[request.len..];
    const body = try allocator.alloc(u8, forward.content_length);
    const copied = @min(initial_body.len, body.len);
    @memcpy(body[0..copied], initial_body[0..copied]);

    var filled = copied;
    while (filled < body.len) {
        const n = try client_stream.read(body[filled..]);
        if (n == 0) return error.UnexpectedEof;
        filled += n;
    }
    return body;
}

fn schemeLabel(scheme: ForwardScheme) []const u8 {
    return switch (scheme) {
        .http => "http",
        .https => "https",
    };
}

fn logHttpRequestParseError(request: []const u8, err: anyerror) void {
    const header_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
    const first_line = request[0..header_end];
    std.debug.print("[Mixed] HTTP parse failed: err={} first_line={s}\n", .{ err, first_line });
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
    var buf: [8192]u8 = undefined;
    var up_bytes: usize = 0;
    var down_bytes: usize = 0;
    var last_report_ms = compat.milliTimestamp();
    var last_activity_ms = last_report_ms;
    var client_read_open = true;
    var target_read_open = true;
    var client_write_shutdown = false;
    var target_write_shutdown = false;

    while (true) {
        // Important: encrypted upstream may still have decrypted leftover bytes in memory
        // even when socket has no new readable event.
        try drainTargetPending(
            client_stream,
            target_stream,
            &buf,
            &down_bytes,
            &client_read_open,
            &target_read_open,
            &client_write_shutdown,
            &target_write_shutdown,
            &last_activity_ms,
        );

        if (!client_read_open and !target_read_open and !target_stream.hasPendingRead()) {
            break;
        }

        var poll_fds = [_]std.posix.pollfd{
            .{
                .fd = client_stream.handle,
                .events = if (client_read_open) std.posix.POLL.IN else 0,
                .revents = 0,
            },
            .{
                .fd = target_stream.getHandle(),
                .events = if (target_read_open) std.posix.POLL.IN else 0,
                .revents = 0,
            },
        };

        _ = try std.posix.poll(&poll_fds, relay_poll_timeout_ms);

        if (client_read_open and (poll_fds[0].revents & std.posix.POLL.IN != 0)) {
            const n = compat.posixRead(client_stream.handle, &buf) catch |err| {
                if (clientReadClosedBy(err)) {
                    relayLog("client read closed: {}", .{err});
                    closeClientReadSide(&client_read_open, target_stream, &target_write_shutdown);
                    continue;
                }
                return err;
            };
            if (n == 0) {
                closeClientReadSide(&client_read_open, target_stream, &target_write_shutdown);
            } else {
                const forwarded = try writeTargetChunk(
                    target_stream,
                    buf[0..n],
                    client_stream,
                    &client_read_open,
                    &target_read_open,
                    &client_write_shutdown,
                    &target_write_shutdown,
                );
                if (!forwarded) continue;
                up_bytes += n;
                last_activity_ms = compat.milliTimestamp();
            }
        }

        if (target_read_open and (poll_fds[1].revents & std.posix.POLL.IN != 0)) {
            const n = target_stream.read(&buf) catch |err| {
                if (targetReadClosedBy(err)) {
                    closeTargetReadSide(&target_read_open, client_stream, &client_write_shutdown);
                    continue;
                }
                return err;
            };
            if (n == 0) {
                closeTargetReadSide(&target_read_open, client_stream, &client_write_shutdown);
            } else {
                const delivered = try writeClientChunk(
                    client_stream,
                    buf[0..n],
                    target_stream,
                    &client_read_open,
                    &target_read_open,
                    &client_write_shutdown,
                    &target_write_shutdown,
                );
                if (!delivered) continue;
                down_bytes += n;
                last_activity_ms = compat.milliTimestamp();
            }
        }

        const now_ms = compat.milliTimestamp();
        if (now_ms - last_report_ms >= 1000) {
            relayFlushStats(&up_bytes, &down_bytes, false);
            last_report_ms = now_ms;
        }

        if (shouldReapIdleRelay(now_ms, last_activity_ms, relay_idle_reap_ms)) {
            relayLog("idle reap after {}ms without traffic", .{now_ms - last_activity_ms});
            break;
        }

        if (client_read_open and
            (poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0 and
            (poll_fds[0].revents & std.posix.POLL.IN) == 0)
        {
            relayLog("Client poll error/hup", .{});
            closeClientReadSide(&client_read_open, target_stream, &target_write_shutdown);
        }

        if (target_read_open and
            (poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0 and
            (poll_fds[1].revents & std.posix.POLL.IN) == 0 and
            !target_stream.hasPendingRead())
        {
            relayLog("Target poll error/hup", .{});
            closeTargetReadSide(&target_read_open, client_stream, &client_write_shutdown);
        }
    }
    relayFlushStats(&up_bytes, &down_bytes, true);
    relayLog("Done", .{});
}

fn closeClientReadSide(client_read_open: *bool, target_stream: *ProxyStream, target_write_shutdown: *bool) void {
    if (!client_read_open.*) return;
    client_read_open.* = false;
    shutdownTargetWrite(target_stream, target_write_shutdown);
}

fn closeTargetReadSide(target_read_open: *bool, client_stream: net.Stream, client_write_shutdown: *bool) void {
    if (!target_read_open.*) return;
    target_read_open.* = false;
    shutdownClientWrite(client_stream, client_write_shutdown);
}

fn shutdownClientWrite(stream: net.Stream, already_shutdown: *bool) void {
    if (already_shutdown.*) return;
    already_shutdown.* = true;
    compat.shutdownWrite(stream.handle) catch |err| {
        relayLog("client shutdown(send) ignored: {}", .{err});
    };
}

fn shutdownTargetWrite(target_stream: *ProxyStream, already_shutdown: *bool) void {
    if (already_shutdown.*) return;
    already_shutdown.* = true;
    compat.shutdownWrite(target_stream.getHandle()) catch |err| {
        relayLog("target shutdown(send) ignored: {}", .{err});
    };
}

fn drainTargetPending(
    client_stream: net.Stream,
    target_stream: *ProxyStream,
    buf: []u8,
    down_bytes: *usize,
    client_read_open: *bool,
    target_read_open: *bool,
    client_write_shutdown: *bool,
    target_write_shutdown: *bool,
    last_activity_ms: *i64,
) !void {
    while (target_stream.hasPendingRead()) {
        const n = target_stream.read(buf) catch |err| {
            if (targetReadClosedBy(err)) {
                closeTargetReadSide(target_read_open, client_stream, client_write_shutdown);
                return;
            }
            return err;
        };
        if (n == 0) break;
        const delivered = try writeClientChunk(
            client_stream,
            buf[0..n],
            target_stream,
            client_read_open,
            target_read_open,
            client_write_shutdown,
            target_write_shutdown,
        );
        if (!delivered) return;
        down_bytes.* += n;
        last_activity_ms.* = compat.milliTimestamp();
    }
}

fn writeClientChunk(
    client_stream: net.Stream,
    data: []const u8,
    target_stream: *ProxyStream,
    client_read_open: *bool,
    target_read_open: *bool,
    client_write_shutdown: *bool,
    target_write_shutdown: *bool,
) !bool {
    var written: usize = 0;
    while (written < data.len) {
        written += compat.posixWrite(client_stream.handle, data[written..]) catch |err| {
            if (clientWriteClosedBy(err)) {
                relayLog("client write closed: {}", .{err});
                closeClientReadSide(client_read_open, target_stream, target_write_shutdown);
                closeTargetReadSide(target_read_open, client_stream, client_write_shutdown);
                return false;
            }
            return err;
        };
    }
    return true;
}

fn writeTargetChunk(
    target_stream: *ProxyStream,
    data: []const u8,
    client_stream: net.Stream,
    client_read_open: *bool,
    target_read_open: *bool,
    client_write_shutdown: *bool,
    target_write_shutdown: *bool,
) !bool {
    target_stream.write(data) catch |err| {
        if (targetWriteClosedBy(err)) {
            relayLog("target write closed: {}", .{err});
            closeClientReadSide(client_read_open, target_stream, target_write_shutdown);
            closeTargetReadSide(target_read_open, client_stream, client_write_shutdown);
            return false;
        }
        return err;
    };
    return true;
}

fn relayFlushStats(up_bytes: *usize, down_bytes: *usize, force: bool) void {
    if (up_bytes.* == 0 and down_bytes.* == 0 and !force) return;
    relayLog("window traffic: up={}B down={}B", .{ up_bytes.*, down_bytes.* });
    up_bytes.* = 0;
    down_bytes.* = 0;
}

fn shouldReapIdleRelay(now_ms: i64, last_activity_ms: i64, idle_reap_ms: i64) bool {
    return now_ms - last_activity_ms >= idle_reap_ms;
}

fn shouldRetryAcceptError(err: anyerror) bool {
    return switch (err) {
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => true,
        else => false,
    };
}

test "mixed connection worker uses bounded stack" {
    try std.testing.expect(connection_task_stack_size <= 1024 * 1024);
}

test "mixed accept retries transient fd exhaustion" {
    try std.testing.expect(shouldRetryAcceptError(error.ProcessFdQuotaExceeded));
    try std.testing.expect(!shouldRetryAcceptError(error.ConnectionRefused));
}

test "relay idle reap uses long finite timeout" {
    try std.testing.expect(relay_poll_timeout_ms > 0);
    try std.testing.expect(relay_idle_reap_ms >= 10 * 60 * 1000);
    try std.testing.expect(!shouldReapIdleRelay(10_000, 0, relay_idle_reap_ms));
    try std.testing.expect(shouldReapIdleRelay(relay_idle_reap_ms, 0, relay_idle_reap_ms));
}

test "relay drains SS pending leftover without poll event" {
    const allocator = std.testing.allocator;

    const client_pair = try makeTcpStreamPair();
    defer client_pair.left.close();
    errdefer client_pair.right.close();
    const target_pair = try makeTcpStreamPair();
    errdefer target_pair.right.close();

    const client_stream = client_pair.left;
    const peer_stream = client_pair.right;
    const target_base = target_pair.left;
    const target_peer = target_pair.right;

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
    const n = try compat.posixRead(peer_stream.handle, &out);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", out[0..n]);

    peer_stream.close();
    target_peer.close();
    relay_thread.join();
}

test "relay drains SS encrypted leftover without poll event" {
    const allocator = std.testing.allocator;

    const client_pair = try makeTcpStreamPair();
    defer client_pair.left.close();
    errdefer client_pair.right.close();
    const target_pair = try makeTcpStreamPair();
    errdefer target_pair.right.close();

    const client_stream = client_pair.left;
    const peer_stream = client_pair.right;
    const target_base = target_pair.left;
    const target_peer = target_pair.right;

    const ss_client = try allocator.create(ss.ShadowsocksClient);
    errdefer allocator.destroy(ss_client);
    ss_client.* = try ss.ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");
    ss_client.stream = target_base;

    const salt = [_]u8{0} ** 16;
    var enc_ctx = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);
    ss_client.dec_ctx = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);

    var encrypted: [256]u8 = undefined;
    const enc_len = try enc_ctx.encryptChunk("hello", &encrypted);
    ss_client.read_leftover = try allocator.dupe(u8, encrypted[0..enc_len]);

    var target_stream = ProxyStream.initShadowsocks(allocator, target_base, ss_client);
    defer target_stream.close();

    var relay_thread = try std.Thread.spawn(.{}, struct {
        fn run(cs: net.Stream, ts: *ProxyStream) void {
            _ = relay(cs, ts) catch {};
        }
    }.run, .{ client_stream, &target_stream });

    var out: [5]u8 = undefined;
    const n = try compat.posixRead(peer_stream.handle, &out);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", out[0..n]);

    peer_stream.close();
    target_peer.close();
    relay_thread.join();
}

test "mixed relay keeps long-lived tunnels open past short idle gaps" {
    try std.testing.expect(relay_idle_reap_ms > 30 * 1000);
}

test "relay forwards traffic in both directions (direct stream)" {
    const client_pair = try makeTcpStreamPair();
    defer client_pair.left.close();
    const target_pair = try makeTcpStreamPair();

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

    try writeAllFd(client_peer.handle, "ping");
    var buf: [4]u8 = undefined;
    const n1 = try compat.posixRead(target_peer.handle, &buf);
    try std.testing.expectEqual(@as(usize, 4), n1);
    try std.testing.expectEqualStrings("ping", buf[0..n1]);

    try writeAllFd(target_peer.handle, "pong");
    var buf2: [4]u8 = undefined;
    const n2 = try compat.posixRead(client_peer.handle, &buf2);
    try std.testing.expectEqual(@as(usize, 4), n2);
    try std.testing.expectEqualStrings("pong", buf2[0..n2]);

    client_peer.close();
    target_peer.close();
    relay_thread.join();
}

test "relay preserves upstream response after client half-closes its write side" {
    const client_pair = try makeTcpStreamPair();
    defer client_pair.left.close();
    defer client_pair.right.close();
    const target_pair = try makeTcpStreamPair();

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
    defer relay_thread.join();

    var upstream_thread = try std.Thread.spawn(.{}, struct {
        fn run(peer: net.Stream) void {
            defer peer.close();

            var buf: [4]u8 = undefined;
            const n = compat.posixRead(peer.handle, &buf) catch return;
            std.testing.expectEqual(@as(usize, 4), n) catch return;
            std.testing.expectEqualStrings("ping", buf[0..n]) catch return;

            compat.sleepNs(150 * std.time.ns_per_ms);
            writeAllFd(peer.handle, "pong") catch return;
        }
    }.run, .{target_peer});
    defer upstream_thread.join();

    try writeAllFd(client_peer.handle, "ping");
    try compat.shutdownWrite(client_peer.handle);

    try setReadTimeoutMs(client_peer.handle, 1000);
    var resp: [4]u8 = undefined;
    const n = try compat.posixRead(client_peer.handle, &resp);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("pong", resp[0..n]);
}

test "relay should treat client reset during downstream write as graceful close" {
    const client_pair = try makeTcpStreamPair();
    defer client_pair.left.close();
    const target_pair = try makeTcpStreamPair();

    const client_stream = client_pair.left;
    const client_peer = client_pair.right;
    const target_stream = target_pair.left;
    const target_peer = target_pair.right;

    var proxy_stream = ProxyStream.initDirect(target_stream);
    defer proxy_stream.close();

    var upstream_thread = try std.Thread.spawn(.{}, struct {
        fn run(peer: net.Stream) void {
            defer peer.close();

            var buf: [4]u8 = undefined;
            const n = compat.posixRead(peer.handle, &buf) catch return;
            std.testing.expectEqual(@as(usize, 4), n) catch return;
            std.testing.expectEqualStrings("ping", buf[0..n]) catch return;

            compat.sleepNs(100 * std.time.ns_per_ms);
            writeAllFd(peer.handle, "pong") catch return;
        }
    }.run, .{target_peer});
    defer upstream_thread.join();

    try writeAllFd(client_peer.handle, "ping");
    try setResetOnClose(client_peer.handle);
    client_peer.close();

    try relay(client_stream, &proxy_stream);
}

test "relay should treat target reset before upstream write as graceful close" {
    const client_pair = try makeTcpStreamPair();
    defer client_pair.left.close();
    const target_pair = try makeTcpStreamPair();

    const client_stream = client_pair.left;
    const client_peer = client_pair.right;
    const target_stream = target_pair.left;
    const target_peer = target_pair.right;

    var proxy_stream = ProxyStream.initDirect(target_stream);
    defer proxy_stream.close();

    try setResetOnClose(target_peer.handle);
    target_peer.close();

    var sender_thread = try std.Thread.spawn(.{}, struct {
        fn run(peer: net.Stream) void {
            defer peer.close();
            writeAllFd(peer.handle, "ping") catch return;
        }
    }.run, .{client_peer});
    defer sender_thread.join();

    try relay(client_stream, &proxy_stream);
}

test "handleConnection should preserve CONNECT payload buffered after headers" {
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

    var upstream_thread = try std.Thread.spawn(.{}, struct {
        fn run(server: *net.Server) void {
            const conn = server.accept() catch return;
            defer conn.stream.close();

            var buf: [4]u8 = undefined;
            const n = conn.stream.read(&buf) catch return;
            std.testing.expectEqual(@as(usize, 4), n) catch return;
            std.testing.expectEqualStrings("ping", buf[0..n]) catch return;
        }
    }.run, .{&upstream_server});
    defer upstream_thread.join();

    const target_port = upstream_server.listen_address.getPort();
    const req = try std.fmt.allocPrint(
        allocator,
        "CONNECT 127.0.0.1:{d} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n\r\nping",
        .{ target_port, target_port },
    );
    defer allocator.free(req);

    const mixed_pair = try makeTcpStreamPair();

    const mixed_conn = net.Server.Connection{
        .stream = mixed_pair.left,
        .address = try net.Address.parseIp4("127.0.0.1", 12345),
    };
    const mixed_client = mixed_pair.right;

    var relay_thread = try std.Thread.spawn(.{}, struct {
        fn run(alloc: std.mem.Allocator, conn: net.Server.Connection, eng: *Engine, mgr: *OutboundManager) void {
            handleConnection(alloc, conn, eng, mgr) catch {};
        }
    }.run, .{ allocator, mixed_conn, &engine, &manager });
    defer relay_thread.join();

    try mixed_client.writeAll(req);
    try setReadTimeoutMs(mixed_client.handle, 1000);

    var resp_buf: [1024]u8 = undefined;
    const resp_n = try mixed_client.read(&resp_buf);
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..resp_n], "200 Connection established") != null);
    mixed_client.close();
}

test "handleConnection should wait for full CONNECT headers before tunneling" {
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

    var upstream_thread = try std.Thread.spawn(.{}, struct {
        fn run(server: *net.Server) void {
            const conn = server.accept() catch return;
            defer conn.stream.close();

            var buf: [4]u8 = undefined;
            const n = conn.stream.read(&buf) catch return;
            std.testing.expectEqual(@as(usize, 4), n) catch return;
            std.testing.expectEqualStrings("ping", buf[0..n]) catch return;
        }
    }.run, .{&upstream_server});
    defer upstream_thread.join();

    const target_port = upstream_server.listen_address.getPort();
    const part1 = try std.fmt.allocPrint(
        allocator,
        "CONNECT 127.0.0.1:{d} HTTP/1.1\r\nHost: 127.0.0.1:{d}",
        .{ target_port, target_port },
    );
    defer allocator.free(part1);
    const part2 = "\r\n\r\nping";

    const mixed_pair = try makeTcpStreamPair();

    const mixed_conn = net.Server.Connection{
        .stream = mixed_pair.left,
        .address = try net.Address.parseIp4("127.0.0.1", 12345),
    };
    const mixed_client = mixed_pair.right;

    var relay_thread = try std.Thread.spawn(.{}, struct {
        fn run(alloc: std.mem.Allocator, conn: net.Server.Connection, eng: *Engine, mgr: *OutboundManager) void {
            handleConnection(alloc, conn, eng, mgr) catch {};
        }
    }.run, .{ allocator, mixed_conn, &engine, &manager });
    defer relay_thread.join();

    try mixed_client.writeAll(part1);
    compat.sleepNs(100 * std.time.ns_per_ms);
    try mixed_client.writeAll(part2);
    try setReadTimeoutMs(mixed_client.handle, 1000);

    var resp_buf: [1024]u8 = undefined;
    const resp_n = try mixed_client.read(&resp_buf);
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..resp_n], "200 Connection established") != null);
    mixed_client.close();
}

test "relay treats target ConnectionClosed as a graceful half-close" {
    try std.testing.expect(targetReadClosedBy(error.ConnectionClosed));
    try std.testing.expect(targetReadClosedBy(error.NotOpenForReading));
}

test "relay treats client-side reset errors as graceful close" {
    try std.testing.expect(clientReadClosedBy(error.ConnectionResetByPeer));
    try std.testing.expect(clientWriteClosedBy(error.BrokenPipe));
    try std.testing.expect(!clientWriteClosedBy(error.NotOpenForReading));
}

test "relay treats target-side reset errors as graceful close" {
    try std.testing.expect(targetWriteClosedBy(error.ConnectionResetByPeer));
    try std.testing.expect(targetWriteClosedBy(error.BrokenPipe));
    try std.testing.expect(!targetWriteClosedBy(error.NotOpenForReading));
}

test "parseForwardRequest accepts lowercase host and absolute https target" {
    const allocator = std.testing.allocator;
    const request =
        "POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal HTTP/1.1\r\n" ++
        "host: open.feishu.cn\r\n" ++
        "Content-Length: 81\r\n" ++
        "\r\n";

    var parsed = try parseForwardRequest(allocator, request);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(http.Method.POST, parsed.method);
    try std.testing.expectEqualStrings("open.feishu.cn", parsed.host);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqual(ForwardScheme.https, parsed.scheme);
    try std.testing.expectEqual(@as(usize, 81), parsed.content_length);
    try std.testing.expect(parsed.absolute_form);
    try std.testing.expectEqualStrings("/open-apis/auth/v3/tenant_access_token/internal", parsed.origin_target);
}

test "parseForwardRequest owns absolute-form host memory" {
    const allocator = std.testing.allocator;
    const request = try allocator.dupe(
        u8,
        "POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal HTTP/1.1\r\n" ++
            "host: open.feishu.cn\r\n" ++
            "Content-Length: 81\r\n" ++
            "\r\n",
    );
    defer allocator.free(request);

    var parsed = try parseForwardRequest(allocator, request);
    defer parsed.deinit(allocator);

    const req_start = @intFromPtr(request.ptr);
    const req_end = req_start + request.len;
    const host_ptr = @intFromPtr(parsed.host.ptr);
    try std.testing.expect(host_ptr < req_start or host_ptr >= req_end);
}

test "buildForwardRequestHead rewrites absolute-form request line and forces connection close" {
    const allocator = std.testing.allocator;
    const request =
        "POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal HTTP/1.1\r\n" ++
        "host: open.feishu.cn\r\n" ++
        "Proxy-Connection: close\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 81\r\n" ++
        "\r\n";

    var parsed = try parseForwardRequest(allocator, request);
    defer parsed.deinit(allocator);

    const rewritten = try buildForwardRequestHead(allocator, request[0..parsed.header_end], &parsed, true);
    defer allocator.free(rewritten);

    try std.testing.expect(std.mem.startsWith(u8, rewritten, "POST /open-apis/auth/v3/tenant_access_token/internal HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "host: open.feishu.cn\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Content-Length: 81\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Proxy-Connection:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Connection: keep-alive") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Connection: close\r\n") != null);
}

fn targetReadClosedBy(err: anyerror) bool {
    return switch (err) {
        error.ConnectionClosed => true,
        error.ConnectionResetByPeer => true,
        error.BrokenPipe => true,
        error.NotOpenForReading => true,
        else => false,
    };
}

fn clientReadClosedBy(err: anyerror) bool {
    return switch (err) {
        error.ConnectionClosed => true,
        error.ConnectionResetByPeer => true,
        error.BrokenPipe => true,
        error.NotOpenForReading => true,
        else => false,
    };
}

fn clientWriteClosedBy(err: anyerror) bool {
    return switch (err) {
        error.ConnectionClosed => true,
        error.ConnectionResetByPeer => true,
        error.BrokenPipe => true,
        error.NotOpenForWriting => true,
        else => false,
    };
}

fn targetWriteClosedBy(err: anyerror) bool {
    return switch (err) {
        error.ConnectionClosed => true,
        error.ConnectionResetByPeer => true,
        error.BrokenPipe => true,
        error.NotOpenForWriting => true,
        else => false,
    };
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
    defer mixed_pair.right.close();

    const mixed_conn = net.Server.Connection{
        .stream = mixed_pair.left,
        .address = try net.Address.parseIp4("127.0.0.1", 12345),
    };
    const mixed_client = mixed_pair.right;

    try mixed_client.writeAll(req);
    try compat.shutdownWrite(mixed_client.handle);
    try setReadTimeoutMs(mixed_client.handle, 100);
    try handleConnection(allocator, mixed_conn, &engine, &manager);

    var resp_buf: [1024]u8 = undefined;
    _ = mixed_client.read(&resp_buf) catch 0;

    var one: [1]u8 = undefined;
    const n = mixed_client.read(&one) catch 0;
    try std.testing.expectEqual(@as(usize, 0), n);
}

fn setReadTimeoutMs(fd: std.posix.fd_t, timeout_ms: u32) !void {
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
}

fn setResetOnClose(fd: std.posix.fd_t) !void {
    const Linger = extern struct {
        l_onoff: i32,
        l_linger: i32,
    };
    const linger = Linger{
        .l_onoff = 1,
        .l_linger = 0,
    };
    try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger));
}

fn writeAllFd(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        written += try compat.posixWrite(fd, data[written..]);
    }
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
    const ts = compat.timestamp();
    std.debug.print("[{d}] [Relay] ", .{ts});
    std.debug.print(format, args);
    std.debug.print("\n", .{});
}
