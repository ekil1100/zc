const std = @import("std");
const testing = std.testing;
const vmess = @import("vmess.zig");
const Client = vmess.Client;
const Config = vmess.Config;

test "VMess Client init" {
    const allocator = testing.allocator;

    const client = try Client.init(allocator, .{
        .id = "12345678-1234-1234-1234-123456789abc",
        .address = "127.0.0.1",
        .port = 443,
        .alter_id = 0,
    });

    // 验证 UUID 被正确解析
    try testing.expectEqual(@as(u16, 443), client.config.port);
    try testing.expectEqual(@as(u16, 0), client.config.alter_id);
}

test "VMess parseUuid" {
    var uuid: [16]u8 = undefined;
    try vmess.parseUuid("12345678-1234-1234-1234-123456789abc", &uuid);

    // 验证前几个字节
    try testing.expectEqual(@as(u8, 0x12), uuid[0]);
    try testing.expectEqual(@as(u8, 0x34), uuid[1]);
    try testing.expectEqual(@as(u8, 0x56), uuid[2]);
    try testing.expectEqual(@as(u8, 0x78), uuid[3]);
}

test "VMess parseUuid invalid" {
    var uuid: [16]u8 = undefined;
    const result = vmess.parseUuid("invalid-uuid", &uuid);
    try testing.expectError(error.InvalidUuid, result);
}

test "VMess parseIpv4 valid" {
    var ip: [4]u8 = undefined;
    const result = vmess.parseIpv4("192.168.1.1", &ip);

    try testing.expect(result);
    try testing.expectEqual(@as(u8, 192), ip[0]);
    try testing.expectEqual(@as(u8, 168), ip[1]);
    try testing.expectEqual(@as(u8, 1), ip[2]);
    try testing.expectEqual(@as(u8, 1), ip[3]);
}

test "VMess parseIpv4 invalid" {
    var ip: [4]u8 = undefined;
    const result = vmess.parseIpv4("invalid", &ip);
    try testing.expect(!result);
}

test "VMess parseIpv4 rejects empty octets" {
    // Invalid separators must not silently become zero-valued octets.
    var ip: [4]u8 = undefined;
    try testing.expect(!vmess.parseIpv4("1..2.3", &ip));
    try testing.expect(!vmess.parseIpv4(".1.2.3", &ip));
    try testing.expect(!vmess.parseIpv4("1.2.3.", &ip));
}

test "VMess parseIpv4 octet overflow rejected" {
    var ip: [4]u8 = undefined;
    // Octet > 255 whose running accumulation overflows a u8 must be rejected,
    // not panic or wrap around.
    try testing.expect(!vmess.parseIpv4("256.0.0.1", &ip));
    try testing.expect(!vmess.parseIpv4("999.1.1.1", &ip));
    try testing.expect(!vmess.parseIpv4("1.2.3.300", &ip));
}

test "VMess parseUuid no out-of-bounds read" {
    var uuid: [16]u8 = undefined;
    // 36-char string: 30 hex digits (0-29), dashes (30-34), one hex at 35.
    // The trailing lone hex digit would make the old code read str[36].
    const malicious = "000000000000000000000000000000-----a";
    try testing.expectEqual(@as(usize, 36), malicious.len);
    try testing.expectError(error.InvalidUuid, vmess.parseUuid(malicious, &uuid));
}

test "VMess hexDigit" {
    try testing.expectEqual(@as(u8, 0), try vmess.hexDigit('0'));
    try testing.expectEqual(@as(u8, 9), try vmess.hexDigit('9'));
    try testing.expectEqual(@as(u8, 10), try vmess.hexDigit('a'));
    try testing.expectEqual(@as(u8, 15), try vmess.hexDigit('f'));
    try testing.expectEqual(@as(u8, 10), try vmess.hexDigit('A'));
    try testing.expectEqual(@as(u8, 15), try vmess.hexDigit('F'));
}

test "VMess hexDigit invalid" {
    const result = vmess.hexDigit('g');
    try testing.expectError(error.InvalidHex, result);
}
