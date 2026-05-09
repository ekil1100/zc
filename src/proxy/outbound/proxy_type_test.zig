const std = @import("std");
const testing = std.testing;
const ProxyType = @import("../../config.zig").ProxyType;

test "ProxyType enum values" {
    try testing.expectEqual(ProxyType.direct, ProxyType.direct);
    try testing.expectEqual(ProxyType.reject, ProxyType.reject);
    try testing.expectEqual(ProxyType.http, ProxyType.http);
    try testing.expectEqual(ProxyType.socks5, ProxyType.socks5);
    try testing.expectEqual(ProxyType.ss, ProxyType.ss);
    try testing.expectEqual(ProxyType.vmess, ProxyType.vmess);
    try testing.expectEqual(ProxyType.vless, ProxyType.vless);
    try testing.expectEqual(ProxyType.trojan, ProxyType.trojan);
}

test "ProxyType switch" {
    const proxy_type = ProxyType.ss;
    
    const name = switch (proxy_type) {
        .direct => "Direct",
        .reject => "Reject",
        .http => "HTTP",
        .socks5 => "SOCKS5",
        .ss => "Shadowsocks",
        .vmess => "VMess",
        .vless => "VLESS",
        .trojan => "Trojan",
    };
    
    try testing.expectEqualStrings("Shadowsocks", name);
}
