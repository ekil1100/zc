const std = @import("std");
const testing = std.testing;
const shadowsocks = @import("shadowsocks.zig");
const simple_obfs_http = @import("simple_obfs_http.zig");
const aead = @import("../../crypto/aead.zig");
const socks_address = @import("../../protocol/socks_address.zig");
const ShadowsocksClient = shadowsocks.ShadowsocksClient;

test "Shadowsocks callers use the shared SOCKS address module" {
    // Callers must not recover the removed crypto or Shadowsocks address aliases.
    try testing.expect(!@hasDecl(shadowsocks, "Address"));
    try testing.expect(!@hasDecl(aead, "Address"));

    const address = socks_address.Address{
        .host = "127.0.0.1",
        .port = 8080,
    };
    var output: [7]u8 = undefined;
    const encoded_size = try address.encode(&output);

    try testing.expectEqual(@as(usize, 7), encoded_size);
    try testing.expectEqualSlices(
        u8,
        "\x01\x7f\x00\x00\x01\x1f\x90",
        &output,
    );
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

test "Shadowsocks AEAD wire parameters match every supported datagram cipher" {
    // Production constants must retain the protocol salt, nonce, tag, and wire limits.
    try testing.expectEqual(@as(usize, 16), aead.CipherType.aes_128_gcm.saltLen());
    try testing.expectEqual(@as(usize, 32), aead.CipherType.aes_256_gcm.saltLen());
    try testing.expectEqual(@as(usize, 32), aead.CipherType.chacha20_poly1305.saltLen());
    try testing.expectEqual(@as(usize, 32), aead.CipherType.chacha20_ietf_poly1305.saltLen());
    try testing.expectEqual(@as(usize, 12), aead.AeadDatagram.nonce_size);
    try testing.expectEqual(@as(usize, 16), aead.AeadDatagram.tag_size);
    try testing.expectEqual(@as(usize, 65_507), aead.AeadDatagram.wire_size_max);
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
