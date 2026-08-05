const std = @import("std");
const testing = std.testing;
const dns = @import("client.zig");
const DnsClient = dns.DnsClient;
const DnsConfig = dns.DnsConfig;

test "DnsConfig default" {
    const config = DnsConfig{};

    try testing.expect(config.primary == null);
    try testing.expectEqual(@as(?[]const u8, null), config.secondary);
    try testing.expectEqual(@as(u16, 53), config.port);
    try testing.expectEqual(@as(u32, 5000), config.timeout_ms);
    try testing.expect(!config.use_tcp);
    try testing.expect(config.enable_cache);
    try testing.expectEqual(@as(u32, 300), config.cache_ttl);
}

test "DnsClient init" {
    const allocator = testing.allocator;

    const config = DnsConfig{
        .primary = "127.0.0.1",
        .port = 5353,
    };

    var client = DnsClient.init(allocator, config);
    defer client.deinit();

    try testing.expectEqualStrings("127.0.0.1", client.config.primary.?);
    try testing.expectEqual(@as(u16, 5353), client.config.port);
}

test "DnsClient cache operations" {
    const allocator = testing.allocator;

    const config = DnsConfig{
        .enable_cache = true,
        .cache_ttl = 60,
    };

    var client = DnsClient.init(allocator, config);
    defer client.deinit();

    // Test cache miss (resolve would fail without server, just test struct)
    try testing.expectEqual(@as(usize, 0), client.cache.count());
}

test "DnsClient config with DoH" {
    const config = DnsConfig{
        .primary = "1.1.1.1",
        .doh_enabled = true,
        .doh_url = "https://cloudflare-dns.com/dns-query",
    };

    try testing.expect(config.doh_enabled);
    try testing.expectEqualStrings("https://cloudflare-dns.com/dns-query", config.doh_url.?);
}

test "DnsClient config with DoT" {
    const config = DnsConfig{
        .primary = "1.1.1.1",
        .dot_enabled = true,
        .dot_server = "cloudflare-dns.com",
    };

    try testing.expect(config.dot_enabled);
    try testing.expectEqualStrings("cloudflare-dns.com", config.dot_server.?);
}
