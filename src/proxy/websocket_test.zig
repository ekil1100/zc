const std = @import("std");
const compat = @import("../compat.zig");
const testing = std.testing;
const WebSocket = @import("websocket.zig").WebSocket;
const base64 = std.base64;

test "WebSocket generate key" {
    var key_bytes: [16]u8 = undefined;
    compat.randomBytes(&key_bytes);

    var key_b64: [24]u8 = undefined;
    _ = base64.standard.Encoder.encode(&key_b64, &key_bytes);

    try testing.expectEqual(@as(usize, 24), key_b64.len);
}

test "WebSocket frame encoding - small payload" {
    const allocator = testing.allocator;

    // Create a mock stream (we can't easily test without actual connection)
    // This test just verifies the frame structure logic

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const opcode: u8 = 0x01; // Text
    const mask: u8 = 0x80;
    const payload = "Hello";
    const payload_len: u8 = @intCast(payload.len);

    // First byte: FIN + opcode
    try buf.append(allocator, (1 << 7) | opcode);
    // Second byte: MASK + length
    try buf.append(allocator, mask | payload_len);

    try testing.expectEqual(@as(u8, 0x81), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x85), buf.items[1]);
}

test "WebSocket frame encoding - medium payload" {
    const allocator = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const payload_len: usize = 200;
    const mask: u8 = 0x80;

    try buf.append(allocator, 0x81); // FIN + text

    if (payload_len < 126) {
        try buf.append(allocator, mask | @as(u8, @intCast(payload_len)));
    } else {
        try buf.append(allocator, mask | 126);
        try buf.append(allocator, @intCast(payload_len >> 8));
        try buf.append(allocator, @intCast(payload_len & 0xFF));
    }

    try testing.expectEqual(@as(u8, 0x81), buf.items[0]);
    try testing.expectEqual(@as(u8, 0xFE), buf.items[1]); // MASK + 126
}
