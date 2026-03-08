const std = @import("std");
const socket_options = @import("../socket_options.zig");
const net = std.net;
const crypto = std.crypto;
const base64 = std.base64;
const TlsStream = @import("tls.zig").TlsStream;

/// 通用流接口（支持普通 TCP 和 TLS）
pub const Stream = union(enum) {
    plain: net.Stream,
    tls: TlsStream,

    pub fn read(self: Stream, buf: []u8) !usize {
        return switch (self) {
            .plain => |s| try s.read(buf),
            .tls => |*s| try s.read(buf),
        };
    }

    pub fn readAll(self: Stream, buf: []u8) !void {
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const n = try self.read(buf[total_read..]);
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }
    }

    pub fn write(self: Stream, data: []const u8) !void {
        switch (self) {
            .plain => |s| try s.writeAll(data),
            .tls => |*s| try s.write(data),
        }
    }

    pub fn writeAll(self: Stream, data: []const u8) !void {
        try self.write(data);
    }

    pub fn close(self: Stream) void {
        switch (self) {
            .plain => |s| s.close(),
            .tls => |*s| s.close(),
        }
    }
};

/// WebSocket 配置
pub const WsConfig = struct {
    path: []const u8 = "/",
    host: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
};

/// WebSocket 客户端
pub const WebSocket = struct {
    allocator: std.mem.Allocator,
    stream: Stream,
    connected: bool,
    mask_key: [4]u8,

    pub fn init(allocator: std.mem.Allocator, stream: Stream) WebSocket {
        return .{
            .allocator = allocator,
            .stream = stream,
            .connected = false,
            .mask_key = undefined,
        };
    }

    /// 连接到 WebSocket 服务器
    pub fn connect(self: *WebSocket, host: []const u8, port: u16, path: []const u8, ws_host: ?[]const u8) !void {
        // 构建 HTTP Upgrade 请求
        var request = std.ArrayList(u8).empty;
        defer request.deinit(self.allocator);

        // 生成 Sec-WebSocket-Key
        var key_bytes: [16]u8 = undefined;
        crypto.random.bytes(&key_bytes);
        var key_b64: [24]u8 = undefined;
        _ = base64.standard.Encoder.encode(&key_b64, &key_bytes);

        // 构建请求
        try request.writer(self.allocator).print(
            "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
            .{
                path,
                ws_host orelse host,
                key_b64,
            }
        );

        // 发送请求
        try self.stream.writeAll(request.items);

        // 读取响应
        var buf: [1024]u8 = undefined;
        const n = try self.stream.read(&buf);
        const response = buf[0..n];

        // 检查响应
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) {
            return error.WebSocketHandshakeFailed;
        }

        self.connected = true;
        std.debug.print("[WebSocket] Connected to {s}:{d}{s}\n", .{ host, port, path });
    }

    /// 发送文本帧
    pub fn sendText(self: *WebSocket, text: []const u8) !void {
        try self.sendFrame(0x01, 0x81, text); // FIN=1, opcode=1 (text), MASK=1
    }

    /// 发送二进制帧
    pub fn sendBinary(self: *WebSocket, data: []const u8) !void {
        try self.sendFrame(0x01, 0x82, data); // FIN=1, opcode=2 (binary), MASK=1
    }

    fn sendFrame(self: *WebSocket, fin: u8, opcode: u8, payload: []const u8) !void {
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(self.allocator);

        // 第一个字节: FIN + RSV + Opcode
        try frame.append(self.allocator, (fin << 7) | opcode);

        // 第二个字节: MASK + Payload length
        const mask_bit: u8 = 0x80; // 客户端必须设置 mask
        if (payload.len < 126) {
            try frame.append(self.allocator, mask_bit | @as(u8, @intCast(payload.len)));
        } else if (payload.len < 65536) {
            try frame.append(self.allocator, mask_bit | 126);
            try frame.append(self.allocator, @intCast(payload.len >> 8));
            try frame.append(self.allocator, @intCast(payload.len & 0xFF));
        } else {
            try frame.append(self.allocator, mask_bit | 127);
            try frame.append(self.allocator, 0);
            try frame.append(self.allocator, 0);
            try frame.append(self.allocator, 0);
            try frame.append(self.allocator, 0);
            try frame.append(self.allocator, @intCast((payload.len >> 24) & 0xFF));
            try frame.append(self.allocator, @intCast((payload.len >> 16) & 0xFF));
            try frame.append(self.allocator, @intCast((payload.len >> 8) & 0xFF));
            try frame.append(self.allocator, @intCast(payload.len & 0xFF));
        }

        // Masking key
        var mask: [4]u8 = undefined;
        crypto.random.bytes(&mask);
        try frame.appendSlice(self.allocator, &mask);

        // Masked payload
        for (payload, 0..) |byte, i| {
            try frame.append(self.allocator, byte ^ mask[i % 4]);
        }

        try self.stream.writeAll(frame.items);
    }

    /// 接收帧
    pub fn recv(self: *WebSocket, buf: []u8) !usize {
        if (!self.connected) return error.NotConnected;

        // 读取帧头
        var header: [2]u8 = undefined;
        _ = try self.stream.readAll(&header);

        const fin = (header[0] >> 7) == 1;
        const opcode = header[0] & 0x0F;
        const masked = (header[1] >> 7) == 1;
        var payload_len: usize = @intCast(header[1] & 0x7F);

        // 扩展长度
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            _ = try self.stream.readAll(&ext);
            payload_len = (@as(usize, ext[0]) << 8) | ext[1];
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            _ = try self.stream.readAll(&ext);
            payload_len = (@as(usize, ext[4]) << 24) | (@as(usize, ext[5]) << 16) |
                         (@as(usize, ext[6]) << 8) | ext[7];
        }

        // 读取 masking key (如果服务器发送了)
        var mask: [4]u8 = undefined;
        if (masked) {
            _ = try self.stream.readAll(&mask);
        }

        // 读取 payload
        if (payload_len > buf.len) {
            return error.BufferTooSmall;
        }

        _ = try self.stream.readAll(buf[0..payload_len]);

        // Unmask
        if (masked) {
            for (0..payload_len) |i| {
                buf[i] ^= mask[i % 4];
            }
        }

        // 处理控制帧
        if (opcode == 0x08) { // Close
            self.connected = false;
            return error.ConnectionClosed;
        } else if (opcode == 0x09) { // Ping
            // 发送 Pong
            try self.sendPong(buf[0..payload_len]);
            return self.recv(buf); // 继续接收
        }

        _ = fin;
        return payload_len;
    }

    fn sendPong(self: *WebSocket, data: []const u8) !void {
        try self.sendFrame(0x01, 0x0A, data); // FIN=1, opcode=10 (pong)
    }

    /// 关闭连接
    pub fn close(self: *WebSocket) void {
        if (self.connected) {
            // 发送 Close 帧
            _ = self.sendFrame(0x01, 0x08, ""); // FIN=1, opcode=8 (close)
            self.connected = false;
        }
        self.stream.close();
    }
};

/// WebSocket + TLS 连接
pub fn connectWs(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8, use_tls: bool, ws_host: ?[]const u8) !WebSocket {
    const stream = try net.tcpConnectToHost(allocator, host, port);
    errdefer stream.close();
    try socket_options.configureConnectedStream(stream);

    var ws: WebSocket = undefined;

    if (use_tls) {
        // TLS 连接
        var tls_stream = try TlsStream.init(allocator, stream, ws_host orelse host);
        ws = WebSocket.init(allocator, .{ .tls = tls_stream });
    } else {
        // 普通 TCP 连接
        ws = WebSocket.init(allocator, .{ .plain = stream });
    }

    try ws.connect(host, port, path, ws_host);
    return ws;
}

const net = std.net;
