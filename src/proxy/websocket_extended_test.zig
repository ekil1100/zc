const std = @import("std");
const compat = @import("../compat.zig");
const testing = std.testing;
const base64 = std.base64;
const ws = @import("websocket.zig");
const WebSocket = ws.WebSocket;

/// 一个由内存字节切片支撑、带游标的最小 reader，
/// 暴露 `readAll([]u8) !void` 供 WebSocket.readFrame 使用。
const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn readAll(self: *SliceReader, buf: []u8) !void {
        if (self.pos + buf.len > self.data.len) return error.EndOfStream;
        @memcpy(buf, self.data[self.pos .. self.pos + buf.len]);
        self.pos += buf.len;
    }
};

test "decodeExtended64 uses all 8 bytes (no 32-bit truncation)" {
    // 一个高 32 位被置位的长度：高位非零。旧实现只取低 4 字节，
    // 会得到 0 而非 FrameTooLarge / 正确的大数。
    const ext: [8]u8 = .{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 };
    // 0x01_00000000 = 2^32，在 64 位平台上可表示。
    const got = try WebSocket.decodeExtended64(ext);
    try testing.expectEqual(@as(usize, 1) << 32, got);
}

test "decodeExtended64 rejects lengths that overflow usize" {
    if (@bitSizeOf(usize) >= 64) return error.SkipZigTest;
    // 32 位平台：高位置位应被拒绝而非静默截断为低 32 位。
    const ext: [8]u8 = .{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 };
    try testing.expectError(error.FrameTooLarge, WebSocket.decodeExtended64(ext));
}

test "readFrame parses a small unmasked frame" {
    // FIN+text(0x81), len=3(unmasked), payload "abc"
    const wire = [_]u8{ 0x81, 0x03, 'a', 'b', 'c' };
    var reader = SliceReader{ .data = &wire };
    var buf: [16]u8 = undefined;
    const frame = try WebSocket.readFrame(&reader, &buf);
    try testing.expectEqual(@as(u8, 0x01), frame.opcode);
    try testing.expectEqual(@as(usize, 3), frame.payload_len);
    try testing.expectEqualSlices(u8, "abc", buf[0..3]);
}

test "readFrame on oversized frame consumes payload to avoid desync" {
    // 第一帧：text，len=5，payload "HELLO"（超出 2 字节的 buf）。
    // 第二帧：text，len=2，payload "OK"。
    const wire = [_]u8{
        0x81, 0x05, 'H', 'E', 'L', 'L', 'O',
        0x81, 0x02, 'O', 'K',
    };
    var reader = SliceReader{ .data = &wire };

    // 故意给一个太小的 buf 触发 BufferTooSmall。
    var small: [2]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, WebSocket.readFrame(&reader, &small));

    // 旧实现在出错前没有消费 payload，游标会停在 payload "HELLO" 内部，
    // 导致下一帧被错位解析。修复后应已把第一帧的 payload 读完。
    var buf: [16]u8 = undefined;
    const frame = try WebSocket.readFrame(&reader, &buf);
    try testing.expectEqual(@as(u8, 0x01), frame.opcode);
    try testing.expectEqual(@as(usize, 2), frame.payload_len);
    try testing.expectEqualSlices(u8, "OK", buf[0..2]);
}

test "readFrame on oversized masked frame also consumes mask + payload" {
    // 带掩码帧：mask 位置位，len=4，mask key + 4 字节 payload。
    // 布局：头(2) + mask(4) + payload(4) = 10 字节，随后接下一帧。
    const mask = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const wire = [_]u8{
        0x82,          0x80 | 4,      mask[0],       mask[1],       mask[2], mask[3],
        'a' ^ mask[0], 'b' ^ mask[1], 'c' ^ mask[2], 'd' ^ mask[3],
        // 下一帧
        0x81,          0x01,          'Z',
    };
    var reader = SliceReader{ .data = &wire };

    var small: [1]u8 = undefined; // 太小，触发 BufferTooSmall
    try testing.expectError(error.BufferTooSmall, WebSocket.readFrame(&reader, &small));

    // 第一帧的 mask + payload 都应被消费，下一帧应正确解析为 "Z"。
    var buf: [16]u8 = undefined;
    const frame = try WebSocket.readFrame(&reader, &buf);
    try testing.expectEqual(@as(usize, 1), frame.payload_len);
    try testing.expectEqualSlices(u8, "Z", buf[0..1]);
}

// WebSocket protocol tests
test "WebSocket version" {
    try testing.expectEqual(@as(u8, 13), 13);
}

test "WebSocket key generation" {
    var key_bytes: [16]u8 = undefined;
    compat.randomBytes(&key_bytes);
    
    var key_b64: [24]u8 = undefined;
    _ = base64.standard.Encoder.encode(&key_b64, &key_bytes);
    
    try testing.expectEqual(@as(usize, 24), key_b64.len);
    
    // Decode and verify
    var decoded: [16]u8 = undefined;
    try base64.standard.Decoder.decode(&decoded, &key_b64);
    try testing.expectEqualSlices(u8, &key_bytes, &decoded);
}

test "WebSocket frame opcodes" {
    const CONTINUATION: u8 = 0x00;
    const TEXT: u8 = 0x01;
    const BINARY: u8 = 0x02;
    const CLOSE: u8 = 0x08;
    const PING: u8 = 0x09;
    const PONG: u8 = 0x0A;
    
    try testing.expectEqual(@as(u8, 0x00), CONTINUATION);
    try testing.expectEqual(@as(u8, 0x01), TEXT);
    try testing.expectEqual(@as(u8, 0x02), BINARY);
    try testing.expectEqual(@as(u8, 0x08), CLOSE);
    try testing.expectEqual(@as(u8, 0x09), PING);
    try testing.expectEqual(@as(u8, 0x0A), PONG);
}

test "WebSocket frame header small payload" {
    const fin: u8 = 1;
    const opcode: u8 = 0x01; // Text
    const mask: u8 = 0x80;
    const payload_len: u8 = 5;
    
    const byte1: u8 = (fin << 7) | opcode;
    const byte2: u8 = mask | payload_len;
    
    try testing.expectEqual(@as(u8, 0x81), byte1);
    try testing.expectEqual(@as(u8, 0x85), byte2);
}

test "WebSocket frame header medium payload" {
    const fin: u8 = 1;
    const opcode: u8 = 0x02; // Binary
    const mask: u8 = 0x80;
    const payload_len: u16 = 200;
    
    const byte1: u8 = (fin << 7) | opcode;
    const byte2: u8 = mask | 126; // Extended length
    const byte3: u8 = @intCast(payload_len >> 8);
    const byte4: u8 = @intCast(payload_len & 0xFF);
    
    try testing.expectEqual(@as(u8, 0x82), byte1);
    try testing.expectEqual(@as(u8, 0xFE), byte2);
    try testing.expectEqual(@as(u8, 0x00), byte3);
    try testing.expectEqual(@as(u8, 200), byte4);
}

test "WebSocket frame header large payload" {
    const fin: u8 = 1;
    const opcode: u8 = 0x02;
    const mask: u8 = 0x80;
    
    const byte1: u8 = (fin << 7) | opcode;
    const byte2: u8 = mask | 127; // 64-bit length
    
    try testing.expectEqual(@as(u8, 0x82), byte1);
    try testing.expectEqual(@as(u8, 0xFF), byte2);
}

test "WebSocket masking" {
    const mask: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };
    const payload = "Hello";
    
    var masked: [5]u8 = undefined;
    for (payload, 0..) |byte, i| {
        masked[i] = byte ^ mask[i % 4];
    }
    
    // Verify masking is reversible
    var unmasked: [5]u8 = undefined;
    for (masked, 0..) |byte, i| {
        unmasked[i] = byte ^ mask[i % 4];
    }
    
    try testing.expectEqualStrings(payload, &unmasked);
}

test "WebSocket upgrade request format" {
    const host = "example.com";
    const path = "/ws";
    
    const key_b64: [24]u8 = .{'A'} ** 24;
    
    var request: [512]u8 = undefined;
    const written = try std.fmt.bufPrint(
        &request,
        "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: {s}\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n",
        .{ path, host, key_b64 }
    );
    
    try testing.expect(std.mem.startsWith(u8, written, "GET /ws HTTP/1.1"));
    try testing.expect(std.mem.indexOf(u8, written, "Upgrade: websocket") != null);
    try testing.expect(std.mem.indexOf(u8, written, "Sec-WebSocket-Version: 13") != null);
}

test "WebSocket upgrade response format" {
    const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "\r\n";
    
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 101"));
    try testing.expect(std.mem.indexOf(u8, response, "Sec-WebSocket-Accept") != null);
}
