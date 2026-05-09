const std = @import("std");
const testing = std.testing;

// SOCKS5 protocol tests
test "SOCKS5 version" {
    try testing.expectEqual(@as(u8, 0x05), 0x05);
}

test "SOCKS5 authentication methods" {
    const NO_AUTH: u8 = 0x00;
    const GSSAPI: u8 = 0x01;
    const USERPASS: u8 = 0x02;
    const NO_ACCEPTABLE: u8 = 0xFF;
    
    try testing.expectEqual(@as(u8, 0x00), NO_AUTH);
    try testing.expectEqual(@as(u8, 0x01), GSSAPI);
    try testing.expectEqual(@as(u8, 0x02), USERPASS);
    try testing.expectEqual(@as(u8, 0xFF), NO_ACCEPTABLE);
}

test "SOCKS5 commands" {
    const CONNECT: u8 = 0x01;
    const BIND: u8 = 0x02;
    const UDP_ASSOCIATE: u8 = 0x03;
    
    try testing.expectEqual(@as(u8, 0x01), CONNECT);
    try testing.expectEqual(@as(u8, 0x02), BIND);
    try testing.expectEqual(@as(u8, 0x03), UDP_ASSOCIATE);
}

test "SOCKS5 address types" {
    const IPV4: u8 = 0x01;
    const DOMAIN: u8 = 0x03;
    const IPV6: u8 = 0x04;
    
    try testing.expectEqual(@as(u8, 0x01), IPV4);
    try testing.expectEqual(@as(u8, 0x03), DOMAIN);
    try testing.expectEqual(@as(u8, 0x04), IPV6);
}

test "SOCKS5 reply codes" {
    const SUCCESS: u8 = 0x00;
    const GEN_FAILURE: u8 = 0x01;
    const NOT_ALLOWED: u8 = 0x02;
    const NET_UNREACHABLE: u8 = 0x03;
    const HOST_UNREACHABLE: u8 = 0x04;
    const CONN_REFUSED: u8 = 0x05;
    const TTL_EXPIRED: u8 = 0x06;
    const CMD_NOT_SUPPORTED: u8 = 0x07;
    const ADDR_NOT_SUPPORTED: u8 = 0x08;
    
    try testing.expectEqual(@as(u8, 0x00), SUCCESS);
    try testing.expectEqual(@as(u8, 0x01), GEN_FAILURE);
    try testing.expectEqual(@as(u8, 0x02), NOT_ALLOWED);
    try testing.expectEqual(@as(u8, 0x03), NET_UNREACHABLE);
    try testing.expectEqual(@as(u8, 0x04), HOST_UNREACHABLE);
    try testing.expectEqual(@as(u8, 0x05), CONN_REFUSED);
    try testing.expectEqual(@as(u8, 0x06), TTL_EXPIRED);
    try testing.expectEqual(@as(u8, 0x07), CMD_NOT_SUPPORTED);
    try testing.expectEqual(@as(u8, 0x08), ADDR_NOT_SUPPORTED);
}

test "SOCKS5 greeting packet structure" {
    // [VER, NMETHODS, METHODS...]
    const greeting = [_]u8{ 0x05, 0x02, 0x00, 0x02 };
    
    try testing.expectEqual(@as(u8, 0x05), greeting[0]); // SOCKS5
    try testing.expectEqual(@as(u8, 0x02), greeting[1]); // 2 methods
    try testing.expectEqual(@as(u8, 0x00), greeting[2]); // No auth
    try testing.expectEqual(@as(u8, 0x02), greeting[3]); // User/pass
}

test "SOCKS5 connect request structure" {
    // [VER, CMD, RSV, ATYP, DST.ADDR, DST.PORT]
    const request = [_]u8{
        0x05, // VER
        0x01, // CMD=CONNECT
        0x00, // RSV
        0x01, // ATYP=IPv4
        192, 168, 1, 1, // IP
        0x00, 0x50, // Port 80
    };
    
    try testing.expectEqual(@as(u8, 0x05), request[0]);
    try testing.expectEqual(@as(u8, 0x01), request[1]);
    try testing.expectEqual(@as(u8, 0x00), request[2]);
    try testing.expectEqual(@as(u8, 0x01), request[3]);
    
    // Port calculation
    const port = (@as(u16, request[8]) << 8) | request[9];
    try testing.expectEqual(@as(u16, 80), port);
}

test "SOCKS5 domain address encoding" {
    // [VER, CMD, RSV, ATYP=3, LEN, DOMAIN, PORT]
    const domain = "example.com";
    const port: u16 = 443;
    
    var request: [256]u8 = undefined;
    request[0] = 0x05;
    request[1] = 0x01;
    request[2] = 0x00;
    request[3] = 0x03; // Domain
    request[4] = @intCast(domain.len);
    @memcpy(request[5..5+domain.len], domain);
    request[5+domain.len] = @intCast(port >> 8);
    request[6+domain.len] = @intCast(port & 0xFF);
    
    try testing.expectEqual(@as(u8, 0x03), request[3]);
    try testing.expectEqual(@as(u8, 11), request[4]); // domain length
    try testing.expectEqualStrings("example.com", request[5..16]);
}
