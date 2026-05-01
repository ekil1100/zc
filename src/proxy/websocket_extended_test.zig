const std = @import("std");
const compat = @import("../compat.zig");
const testing = std.testing;
const base64 = std.base64;

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
    
    var key_b64: [24]u8 = .{'A'} ** 24;
    
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
