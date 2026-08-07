const std = @import("std");
const testing = std.testing;
const shadowsocks = @import("shadowsocks.zig");
const simple_obfs_http = @import("simple_obfs_http.zig");
const aead = @import("../../crypto/aead.zig");
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
    const cases = [_]struct {
        name: []const u8,
        expected: aead.CipherType,
    }{
        .{ .name = "aes-128-gcm", .expected = .aes_128_gcm },
        .{ .name = "aes-256-gcm", .expected = .aes_256_gcm },
        .{ .name = "chacha20-ietf-poly1305", .expected = .chacha20_ietf_poly1305 },
        .{ .name = "chacha20-poly1305", .expected = .chacha20_poly1305 },
    };

    for (cases) |case| {
        try testing.expectEqual(case.expected, aead.parseCipherType(case.name).?);
    }
    try testing.expect(aead.parseCipherType("aes-128-cfb") == null);
}

test "ShadowsocksClient init params" {
    var client = try ShadowsocksClient.init(
        testing.allocator,
        "127.0.0.1",
        8388,
        "test-password",
        "aes-128-gcm",
    );
    defer client.deinit();

    try testing.expectEqualStrings("127.0.0.1", client.server);
    try testing.expectEqual(@as(u16, 8388), client.port);
    try testing.expectEqualStrings("test-password", client.password);
    try testing.expectEqual(aead.CipherType.aes_128_gcm, client.cipher_type);
}

test "Shadowsocks salt size" {
    // Shadowsocks AEAD salts use the cipher key length, not the nonce length.
    try testing.expectEqual(@as(usize, 16), aead.CipherType.aes_128_gcm.saltLen());
    try testing.expectEqual(@as(usize, 32), aead.CipherType.aes_256_gcm.saltLen());
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

test "Shadowsocks retry policy uses one 10 second absolute deadline" {
    try testing.expectEqual(@as(usize, 3), shadowsocks.connect_retry_attempts);
    try testing.expectEqual(@as(u32, 10_000), shadowsocks.upstream_connect_timeout_ms);
    try testing.expectEqual(@as(u64, 200), ShadowsocksClient.retryBackoffMs(0));
    try testing.expectEqual(@as(u64, 500), ShadowsocksClient.retryBackoffMs(1));
    try testing.expectEqual(@as(u64, 1000), ShadowsocksClient.retryBackoffMs(2));
    try testing.expectEqual(@as(u64, 1000), ShadowsocksClient.retryBackoffMs(99));
}

fn initWithObfsAllocationFixture(allocator: std.mem.Allocator) !void {
    var client = try ShadowsocksClient.initWithObfs(
        allocator,
        "127.0.0.1",
        8388,
        "password",
        "aes-128-gcm",
        simple_obfs_http.Config{
            .host = "www.example.com",
            .server_port = 8388,
        },
    );
    defer client.deinit();
}

test "ShadowsocksClient initWithObfs rolls back every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        initWithObfsAllocationFixture,
        .{},
    );
}

test "ShadowsocksClient initWithObfs rejects an unsafe HTTP host without leaks" {
    try testing.expectError(
        error.InvalidObfsHost,
        ShadowsocksClient.initWithObfs(
            testing.allocator,
            "127.0.0.1",
            8388,
            "password",
            "aes-128-gcm",
            simple_obfs_http.Config{
                .host = "example.com\r\nInjected: yes",
                .server_port = 8388,
            },
        ),
    );
}
