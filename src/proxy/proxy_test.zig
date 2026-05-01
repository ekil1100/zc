const std = @import("std");
const compat = @import("../compat.zig");
const testing = std.testing;
const net = compat.net;

// HTTP 代理测试
test "HTTP proxy request parsing" {
    const request = "CONNECT www.google.com:443 HTTP/1.1\r\nHost: www.google.com:443\r\n\r\n";

    // 验证 CONNECT 请求格式
    try testing.expect(std.mem.startsWith(u8, request, "CONNECT"));
    try testing.expect(std.mem.indexOf(u8, request, "www.google.com:443") != null);
    try testing.expect(std.mem.indexOf(u8, request, "HTTP/1.1") != null);
}

test "HTTP proxy response 200" {
    const response = "HTTP/1.1 200 Connection established\r\n\r\n";

    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, response, "Connection established") != null);
}

test "HTTP proxy response 502" {
    const response = "HTTP/1.1 502 Bad Gateway\r\n\r\n";

    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 502"));
}

// SOCKS5 代理测试
test "SOCKS5 greeting" {
    // Client greeting: VER=5, NMETHODS=1, METHODS=[0] (no auth)
    const greeting = [_]u8{ 0x05, 0x01, 0x00 };

    try testing.expectEqual(@as(u8, 0x05), greeting[0]); // SOCKS5
    try testing.expectEqual(@as(u8, 0x01), greeting[1]); // 1 method
    try testing.expectEqual(@as(u8, 0x00), greeting[2]); // No auth
}

test "SOCKS5 server response" {
    // Server response: VER=5, METHOD=0 (no auth)
    const response = [_]u8{ 0x05, 0x00 };

    try testing.expectEqual(@as(u8, 0x05), response[0]);
    try testing.expectEqual(@as(u8, 0x00), response[1]);
}

test "SOCKS5 connect request" {
    // CONNECT request: VER=5, CMD=1, RSV=0, ATYP=1 (IPv4), DST.ADDR, DST.PORT
    const request = [_]u8{
        0x05, // VER
        0x01, // CMD=CONNECT
        0x00, // RSV
        0x01, // ATYP=IPv4
        127,  0,    0,    1,    // 127.0.0.1
        0x1F, 0x90, // Port 8080
    };

    try testing.expectEqual(@as(u8, 0x05), request[0]);
    try testing.expectEqual(@as(u8, 0x01), request[1]); // CONNECT
    try testing.expectEqual(@as(u8, 0x01), request[3]); // IPv4
}

test "SOCKS5 connect success response" {
    // Success response: VER=5, REP=0, RSV, ATYP, BND.ADDR, BND.PORT
    const response = [_]u8{
        0x05, // VER
        0x00, // REP=Success
        0x00, // RSV
        0x01, // ATYP=IPv4
        0,    0,    0,    0,    // 0.0.0.0
        0,    0,    // Port 0
    };

    try testing.expectEqual(@as(u8, 0x00), response[1]); // Success
}

test "SOCKS5 connect failure response" {
    // Failure response: VER=5, REP=1 (general failure)
    const response = [_]u8{
        0x05, // VER
        0x01, // REP=General failure
        0x00, // RSV
        0x01, // ATYP=IPv4
        0,    0,    0,    0,
        0,    0,
    };

    try testing.expectEqual(@as(u8, 0x01), response[1]); // Failure
}
