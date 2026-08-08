//! Allocation-free runtime capability assessment shared by validation and the
//! outbound manager. This module is the single v1 admission policy: callers may
//! render findings differently, but they must not reimplement capability rules.

const std = @import("std");
const aead = @import("crypto/aead.zig");
const config = @import("config.zig");
const shadowsocks = @import("shadowsocks_capability.zig");

pub const ShadowsocksFailure = shadowsocks.Failure;
pub const ShadowsocksTransport = shadowsocks.Transport;

pub const Mode = enum {
    runtime,
    catalog_capture,
};

pub const Failure = union(enum) {
    global_port,
    global_socks_port,
    reserved_proxy_name,
    reserved_proxy_group_name,
    plugin_metadata_requires_shadowsocks,
    unsupported_proxy_type: config.ProxyType,
    shadowsocks: shadowsocks.Failure,
    unsupported_shadowsocks_cipher: []const u8,
    websocket_not_supported: config.ProxyType,
    trojan_udp_not_supported,
    unsupported_proxy_group_type: config.ProxyGroupType,
};

pub const Assessment = struct {
    failures: [8]Failure = undefined,
    count: u8 = 0,

    fn append(self: *Assessment, failure: Failure) void {
        std.debug.assert(self.count < self.failures.len);
        self.failures[self.count] = failure;
        self.count += 1;
    }

    pub fn items(self: *const Assessment) []const Failure {
        return self.failures[0..self.count];
    }
};

pub const ProxyAssessment = struct {
    findings: Assessment = .{},
    shadowsocks_transport: ?shadowsocks.Transport = null,

    pub fn items(self: *const ProxyAssessment) []const Failure {
        return self.findings.items();
    }
};

pub const Capability = union(enum) {
    direct,
    reject,
    shadowsocks: shadowsocks.Transport,
    trojan,
};

pub const CapabilityError = error{
    UnsupportedHttpPort,
    UnsupportedSocksPort,
    ReservedProxyName,
    PluginMetadataRequiresShadowsocks,
    UnsupportedProxyType,
    ShadowsocksTlsNotSupported,
    InconsistentShadowsocksPluginFields,
    UnsupportedShadowsocksPlugin,
    MissingShadowsocksPluginOptions,
    MalformedShadowsocksPluginOptions,
    MissingSimpleObfsMode,
    UnsupportedSimpleObfsMode,
    MissingSimpleObfsHost,
    InvalidSimpleObfsHost,
    SimpleObfsHostTooLong,
    UnsupportedShadowsocksCipher,
    WebSocketNotSupported,
    TrojanUdpNotSupported,
    UnsupportedProxyGroupType,
};

pub fn assessGlobals(cfg: *const config.Config) Assessment {
    var result: Assessment = .{};
    if (cfg.port != 0) result.append(.global_port);
    if (cfg.socks_port != 0) result.append(.global_socks_port);
    return result;
}

pub fn assessProxy(proxy: *const config.Proxy) ProxyAssessment {
    var result: ProxyAssessment = .{};

    if (config.isReservedProxyName(proxy.name)) {
        result.findings.append(.reserved_proxy_name);
    }
    if (proxy.proxy_type != .ss and config.hasPluginMetadata(proxy)) {
        result.findings.append(.plugin_metadata_requires_shadowsocks);
    }

    switch (proxy.proxy_type) {
        .direct, .reject => {},
        .http, .socks5, .vmess, .vless, .anytls => {
            result.findings.append(.{
                .unsupported_proxy_type = proxy.proxy_type,
            });
        },
        .ss => {
            // Top-level TLS is independent from plugin parsing so catalog
            // recovery cannot hide it with malformed plugin metadata.
            if (proxy.tls) {
                result.findings.append(.{
                    .shadowsocks = .tls_not_supported,
                });
            }

            const plugin = shadowsocks.classify(.{
                .semantic_state = proxy.semantic_state,
                .plugin = proxy.plugin,
                .plugin_options_state = proxy.plugin_options_state,
                .obfs_mode = proxy.obfs_mode,
                .obfs_host = proxy.obfs_host,
            });
            switch (plugin) {
                .supported => |transport| {
                    result.shadowsocks_transport = transport;
                },
                .rejected => |failure| {
                    result.findings.append(.{ .shadowsocks = failure });
                },
            }

            if (proxy.cipher) |cipher| {
                if (aead.parseCipherType(cipher) == null) {
                    result.findings.append(.{
                        .unsupported_shadowsocks_cipher = cipher,
                    });
                }
            }
            if (proxy.ws) {
                result.findings.append(.{ .websocket_not_supported = .ss });
            }
        },
        .trojan => {
            if (proxy.udp) {
                result.findings.append(.trojan_udp_not_supported);
            }
            if (proxy.ws) {
                result.findings.append(.{
                    .websocket_not_supported = .trojan,
                });
            }
        },
    }

    return result;
}

pub fn assessProxyGroup(group: *const config.ProxyGroup) Assessment {
    var result: Assessment = .{};
    if (config.isReservedProxyName(group.name)) {
        result.append(.reserved_proxy_group_name);
    }
    if (group.group_type != .select) {
        result.append(.{
            .unsupported_proxy_group_type = group.group_type,
        });
    }
    return result;
}

/// Catalog capture may retain only explicitly marked, recoverable Shadowsocks
/// plugin semantics. TLS, cipher, WebSocket, declarations, and every
/// non-Shadowsocks finding remain reportable.
pub fn reportsProxyFailure(
    mode: Mode,
    proxy: *const config.Proxy,
    failure: Failure,
) bool {
    if (mode == .runtime or
        proxy.proxy_type != .ss or
        proxy.semantic_state != .malformed)
    {
        return true;
    }

    return switch (failure) {
        .shadowsocks => |plugin_failure| switch (plugin_failure) {
            .tls_not_supported => true,
            .inconsistent_plugin_fields,
            .unsupported_plugin,
            .missing_plugin_options,
            .malformed_plugin_options,
            .missing_obfs_mode,
            .unsupported_obfs_mode,
            .missing_obfs_host,
            .invalid_obfs_host,
            .obfs_host_too_long,
            => false,
        },
        else => true,
    };
}

pub fn requireProxy(
    proxy: *const config.Proxy,
) CapabilityError!Capability {
    const assessment = assessProxy(proxy);
    for (assessment.items()) |failure| {
        return failureToError(failure);
    }

    return switch (proxy.proxy_type) {
        .direct => .direct,
        .reject => .reject,
        .ss => .{
            .shadowsocks = assessment.shadowsocks_transport orelse
                unreachable,
        },
        .trojan => .trojan,
        .http, .socks5, .vmess, .vless, .anytls => unreachable,
    };
}

/// Complete allocation-free runtime admission. Resource bounds are checked
/// before the first traversal, then every capability finding is assessed in a
/// deterministic order. The outbound manager calls this before its first heap
/// allocation.
pub fn requireConfig(cfg: *const config.Config) !void {
    try config.requireConfigResourceLimits(cfg);

    const globals = assessGlobals(cfg);
    for (globals.items()) |failure| return failureToError(failure);

    for (cfg.proxies.items) |*proxy| {
        _ = try requireProxy(proxy);
    }
    for (cfg.proxy_groups.items) |*group| {
        const assessment = assessProxyGroup(group);
        for (assessment.items()) |failure| return failureToError(failure);
    }
}

pub fn failureToError(failure: Failure) CapabilityError {
    return switch (failure) {
        .global_port => error.UnsupportedHttpPort,
        .global_socks_port => error.UnsupportedSocksPort,
        .reserved_proxy_name,
        .reserved_proxy_group_name,
        => error.ReservedProxyName,
        .plugin_metadata_requires_shadowsocks => error.PluginMetadataRequiresShadowsocks,
        .unsupported_proxy_type => error.UnsupportedProxyType,
        .shadowsocks => |ss_failure| switch (ss_failure) {
            .tls_not_supported => error.ShadowsocksTlsNotSupported,
            .inconsistent_plugin_fields => error.InconsistentShadowsocksPluginFields,
            .unsupported_plugin => error.UnsupportedShadowsocksPlugin,
            .missing_plugin_options => error.MissingShadowsocksPluginOptions,
            .malformed_plugin_options => error.MalformedShadowsocksPluginOptions,
            .missing_obfs_mode => error.MissingSimpleObfsMode,
            .unsupported_obfs_mode => error.UnsupportedSimpleObfsMode,
            .missing_obfs_host => error.MissingSimpleObfsHost,
            .invalid_obfs_host => error.InvalidSimpleObfsHost,
            .obfs_host_too_long => error.SimpleObfsHostTooLong,
        },
        .unsupported_shadowsocks_cipher => error.UnsupportedShadowsocksCipher,
        .websocket_not_supported => error.WebSocketNotSupported,
        .trojan_udp_not_supported => error.TrojanUdpNotSupported,
        .unsupported_proxy_group_type => error.UnsupportedProxyGroupType,
    };
}

fn testProxy(proxy_type: config.ProxyType) config.Proxy {
    return .{
        .name = "node",
        .proxy_type = proxy_type,
        .server = "example.com",
        .port = 443,
    };
}

fn hasFailureTag(
    assessment: *const ProxyAssessment,
    expected: std.meta.Tag(Failure),
) bool {
    for (assessment.items()) |failure| {
        if (std.meta.activeTag(failure) == expected) return true;
    }
    return false;
}

test "shared proxy assessment covers the complete v1 capability matrix" {
    var proxy = testProxy(.direct);
    proxy.plugin = "obfs";
    var assessment = assessProxy(&proxy);
    try std.testing.expect(hasFailureTag(
        &assessment,
        .plugin_metadata_requires_shadowsocks,
    ));

    for ([_]config.ProxyType{ .http, .socks5, .vmess, .vless, .anytls }) |kind| {
        proxy = testProxy(kind);
        assessment = assessProxy(&proxy);
        try std.testing.expect(hasFailureTag(
            &assessment,
            .unsupported_proxy_type,
        ));
    }

    proxy = testProxy(.ss);
    proxy.udp = true;
    proxy.tls = true;
    proxy.cipher = "aes-128-cfb";
    proxy.ws = true;
    proxy.semantic_state = .malformed;
    assessment = assessProxy(&proxy);
    try std.testing.expectEqual(@as(usize, 4), assessment.items().len);
    try std.testing.expect(hasFailureTag(
        &assessment,
        .unsupported_shadowsocks_cipher,
    ));
    try std.testing.expect(hasFailureTag(
        &assessment,
        .websocket_not_supported,
    ));

    proxy = testProxy(.trojan);
    proxy.udp = true;
    proxy.ws = true;
    assessment = assessProxy(&proxy);
    try std.testing.expectEqual(@as(usize, 2), assessment.items().len);
    try std.testing.expect(hasFailureTag(
        &assessment,
        .trojan_udp_not_supported,
    ));
    try std.testing.expect(hasFailureTag(
        &assessment,
        .websocket_not_supported,
    ));
}

test "classic Shadowsocks UDP is admitted independently of TCP transport" {
    var proxy = testProxy(.ss);
    proxy.cipher = "aes-256-gcm";
    proxy.udp = true;

    const assessment = assessProxy(&proxy);
    try std.testing.expectEqual(@as(usize, 0), assessment.items().len);
    const capability = try requireProxy(&proxy);
    switch (capability) {
        .shadowsocks => |transport| try std.testing.expectEqual(
            shadowsocks.Transport.plain,
            transport,
        ),
        else => return error.ExpectedShadowsocksCapability,
    }
}

test "catalog recovery suppresses only marked Shadowsocks plugin semantics" {
    var proxy = testProxy(.ss);
    proxy.semantic_state = .malformed;
    proxy.udp = true;
    proxy.tls = true;
    proxy.cipher = "unsupported";
    proxy.ws = true;
    const assessment = assessProxy(&proxy);

    var reported: usize = 0;
    for (assessment.items()) |failure| {
        if (!reportsProxyFailure(.catalog_capture, &proxy, failure)) continue;
        reported += 1;
        switch (failure) {
            .shadowsocks => |ss_failure| try std.testing.expect(
                ss_failure == .tls_not_supported,
            ),
            .unsupported_shadowsocks_cipher,
            .websocket_not_supported,
            => {},
            else => return error.UnexpectedCatalogRecoveryFinding,
        }
    }
    try std.testing.expectEqual(@as(usize, 3), reported);
}

test "global and group assessment include standalone ports and declarations" {
    var cfg = config.Config{
        .allocator = std.testing.allocator,
        .port = 8080,
        .socks_port = 1080,
        .proxies = .empty,
        .proxy_groups = .empty,
        .rules = .empty,
    };
    const globals = assessGlobals(&cfg);
    try std.testing.expectEqual(@as(usize, 2), globals.items().len);

    var group = config.ProxyGroup{
        .name = "DIRECT",
        .group_type = .url_test,
        .proxies = .empty,
    };
    const groups = assessProxyGroup(&group);
    try std.testing.expectEqual(@as(usize, 2), groups.items().len);
}
