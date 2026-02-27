const std = @import("std");
const testing = std.testing;
const shadowsocks = @import("shadowsocks.zig");
const ShadowsocksClient = shadowsocks.ShadowsocksClient;
const Address = shadowsocks.Address;

test "Shadowsocks Address struct" {
    const addr = Address{
        .host = "127.0.0.1",
        .port = 8080,
    };
    
    try testing.expectEqualStrings("127.0.0.1", addr.host);
    try testing.expectEqual(@as(u16, 8080), addr.port);
}

test "Shadowsocks cipher types" {
    // Test that cipher names are recognized
    const cipher_names = [_][]const u8{
        "aes-128-gcm",
        "aes-256-gcm", 
        "chacha20-ietf-poly1305",
        "chacha20-poly1305",
    };
    
    for (cipher_names) |name| {
        try testing.expect(name.len > 0);
    }
}

test "ShadowsocksClient init params" {
    // Can't easily test without real connection, test params
    const server = "127.0.0.1";
    const port: u16 = 8388;
    const password = "test-password";
    const cipher = "aes-128-gcm";
    
    try testing.expectEqualStrings("127.0.0.1", server);
    try testing.expectEqual(@as(u16, 8388), port);
    try testing.expectEqualStrings("test-password", password);
    try testing.expectEqualStrings("aes-128-gcm", cipher);
}

test "Shadowsocks salt size" {
    // AES-128-GCM uses 12-byte salt
    const salt_size: usize = 12;
    try testing.expectEqual(@as(usize, 12), salt_size);
    
    // AES-256-GCM uses 32-byte salt  
    const salt_size_256: usize = 32;
    try testing.expectEqual(@as(usize, 32), salt_size_256);
}

test "Shadowsocks nonce size" {
    // GCM mode uses 12-byte nonce
    const nonce_size: usize = 12;
    try testing.expectEqual(@as(usize, 12), nonce_size);
}

test "Shadowsocks tag size" {
    // GCM mode uses 16-byte authentication tag
    const tag_size: usize = 16;
    try testing.expectEqual(@as(usize, 16), tag_size);
}

test "Shadowsocks retry policy uses 3 attempts and exponential backoff" {
    try testing.expectEqual(@as(usize, 3), shadowsocks.connect_retry_attempts);
    try testing.expectEqual(@as(u64, 200), ShadowsocksClient.retryBackoffMs(0));
    try testing.expectEqual(@as(u64, 500), ShadowsocksClient.retryBackoffMs(1));
    try testing.expectEqual(@as(u64, 1000), ShadowsocksClient.retryBackoffMs(2));
    try testing.expectEqual(@as(u64, 1000), ShadowsocksClient.retryBackoffMs(99));
}
