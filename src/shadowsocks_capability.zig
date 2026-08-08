const std = @import("std");
const config = @import("config.zig");

pub const Transport = union(enum) {
    plain,
    simple_obfs_http: struct {
        host: []const u8,
    },
};

pub const Failure = enum {
    tls_not_supported,
    inconsistent_plugin_fields,
    unsupported_plugin,
    missing_plugin_options,
    malformed_plugin_options,
    missing_obfs_mode,
    unsupported_obfs_mode,
    missing_obfs_host,
    invalid_obfs_host,
    obfs_host_too_long,
};

pub const Classification = union(enum) {
    supported: Transport,
    rejected: Failure,
};

pub const Input = struct {
    semantic_state: config.ProxySemanticState = .valid,
    tls: bool = false,
    plugin: ?[]const u8 = null,
    plugin_options_state: config.PluginOptionsState = .absent,
    obfs_mode: ?[]const u8 = null,
    obfs_host: ?[]const u8 = null,
};

pub const CapabilityError = error{
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
};

pub fn classifyProxy(proxy: *const config.Proxy) Classification {
    return classify(.{
        .semantic_state = proxy.semantic_state,
        .tls = proxy.tls,
        .plugin = proxy.plugin,
        .plugin_options_state = proxy.plugin_options_state,
        .obfs_mode = proxy.obfs_mode,
        .obfs_host = proxy.obfs_host,
    });
}

pub fn classify(input: Input) Classification {
    if (input.semantic_state == .malformed) {
        return .{ .rejected = .malformed_plugin_options };
    }
    if (input.tls) return .{ .rejected = .tls_not_supported };

    const plugin = input.plugin orelse {
        if (input.plugin_options_state != .absent or
            input.obfs_mode != null or
            input.obfs_host != null)
        {
            return .{ .rejected = .inconsistent_plugin_fields };
        }
        return .{ .supported = .plain };
    };

    if (!std.mem.eql(u8, plugin, "obfs") and
        !std.mem.eql(u8, plugin, "obfs-local"))
    {
        return .{ .rejected = .unsupported_plugin };
    }

    switch (input.plugin_options_state) {
        .absent => return .{ .rejected = .missing_plugin_options },
        .malformed => return .{ .rejected = .malformed_plugin_options },
        .map => {},
    }

    const mode = input.obfs_mode orelse {
        return .{ .rejected = .missing_obfs_mode };
    };
    if (!std.mem.eql(u8, mode, "http")) {
        return .{ .rejected = .unsupported_obfs_mode };
    }

    const host = input.obfs_host orelse {
        return .{ .rejected = .missing_obfs_host };
    };
    if (host.len == 0) return .{ .rejected = .missing_obfs_host };
    if (host.len > 255) return .{ .rejected = .obfs_host_too_long };
    for (host) |byte| {
        if (byte == '\r' or byte == '\n' or byte == 0) {
            return .{ .rejected = .invalid_obfs_host };
        }
    }

    return .{ .supported = .{ .simple_obfs_http = .{ .host = host } } };
}

pub fn requireProxy(proxy: *const config.Proxy) CapabilityError!Transport {
    return switch (classifyProxy(proxy)) {
        .supported => |transport| transport,
        .rejected => |failure| failureToError(failure),
    };
}

fn failureToError(failure: Failure) CapabilityError {
    return switch (failure) {
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
    };
}

test "Shadowsocks capability matrix is exact and fail closed" {
    const Case = struct {
        name: []const u8,
        input: Input,
        expected_failure: ?Failure,
        expected_transport: ?std.meta.Tag(Transport) = null,
    };
    const long_host = [_]u8{'x'} ** 256;
    const cases = [_]Case{
        .{
            .name = "plain",
            .input = .{},
            .expected_failure = null,
            .expected_transport = .plain,
        },
        .{
            .name = "mihomo obfs HTTP",
            .input = .{
                .plugin = "obfs",
                .plugin_options_state = .map,
                .obfs_mode = "http",
                .obfs_host = "cdn.example.com",
            },
            .expected_failure = null,
            .expected_transport = .simple_obfs_http,
        },
        .{
            .name = "SIP003 obfs-local HTTP",
            .input = .{
                .plugin = "obfs-local",
                .plugin_options_state = .map,
                .obfs_mode = "http",
                .obfs_host = "cdn.example.com",
            },
            .expected_failure = null,
            .expected_transport = .simple_obfs_http,
        },
        .{ .name = "top-level tls", .input = .{ .tls = true }, .expected_failure = .tls_not_supported },
        .{
            .name = "derived mode without plugin",
            .input = .{ .obfs_mode = "http" },
            .expected_failure = .inconsistent_plugin_fields,
        },
        .{
            .name = "options without plugin",
            .input = .{ .plugin_options_state = .map },
            .expected_failure = .inconsistent_plugin_fields,
        },
        .{
            .name = "unknown plugin",
            .input = .{ .plugin = "v2ray-plugin" },
            .expected_failure = .unsupported_plugin,
        },
        .{
            .name = "missing options",
            .input = .{
                .plugin = "obfs",
                .obfs_mode = "http",
                .obfs_host = "cdn.example.com",
            },
            .expected_failure = .missing_plugin_options,
        },
        .{
            .name = "malformed legacy options",
            .input = .{
                .plugin = "obfs",
                .plugin_options_state = .malformed,
                .obfs_mode = "http",
                .obfs_host = "cdn.example.com",
            },
            .expected_failure = .malformed_plugin_options,
        },
        .{
            .name = "missing mode",
            .input = .{
                .plugin = "obfs",
                .plugin_options_state = .map,
                .obfs_host = "cdn.example.com",
            },
            .expected_failure = .missing_obfs_mode,
        },
        .{
            .name = "tls mode",
            .input = .{
                .plugin = "obfs",
                .plugin_options_state = .map,
                .obfs_mode = "tls",
                .obfs_host = "cdn.example.com",
            },
            .expected_failure = .unsupported_obfs_mode,
        },
        .{
            .name = "unknown mode",
            .input = .{
                .plugin = "obfs",
                .plugin_options_state = .map,
                .obfs_mode = "quic",
                .obfs_host = "cdn.example.com",
            },
            .expected_failure = .unsupported_obfs_mode,
        },
        .{
            .name = "missing host",
            .input = .{
                .plugin = "obfs-local",
                .plugin_options_state = .map,
                .obfs_mode = "http",
            },
            .expected_failure = .missing_obfs_host,
        },
        .{
            .name = "empty host",
            .input = .{
                .plugin = "obfs",
                .plugin_options_state = .map,
                .obfs_mode = "http",
                .obfs_host = "",
            },
            .expected_failure = .missing_obfs_host,
        },
        .{
            .name = "CR host",
            .input = .{
                .plugin = "obfs",
                .plugin_options_state = .map,
                .obfs_mode = "http",
                .obfs_host = "safe\rinjected",
            },
            .expected_failure = .invalid_obfs_host,
        },
        .{
            .name = "LF host",
            .input = .{
                .plugin = "obfs",
                .plugin_options_state = .map,
                .obfs_mode = "http",
                .obfs_host = "safe\ninjected",
            },
            .expected_failure = .invalid_obfs_host,
        },
        .{
            .name = "NUL host",
            .input = .{
                .plugin = "obfs",
                .plugin_options_state = .map,
                .obfs_mode = "http",
                .obfs_host = "safe\x00injected",
            },
            .expected_failure = .invalid_obfs_host,
        },
        .{
            .name = "oversized host",
            .input = .{
                .plugin = "obfs",
                .plugin_options_state = .map,
                .obfs_mode = "http",
                .obfs_host = &long_host,
            },
            .expected_failure = .obfs_host_too_long,
        },
    };

    for (cases) |case| {
        const result = classify(case.input);
        if (case.expected_failure) |expected| {
            switch (result) {
                .rejected => |actual| try std.testing.expectEqual(expected, actual),
                .supported => return error.ExpectedCapabilityRejection,
            }
        } else {
            switch (result) {
                .supported => |transport| try std.testing.expectEqual(
                    case.expected_transport.?,
                    std.meta.activeTag(transport),
                ),
                .rejected => return error.UnexpectedCapabilityRejection,
            }
        }
    }
}

test "Shadowsocks capability accepts the full 255-byte host boundary" {
    const host = [_]u8{'h'} ** 255;
    const result = classify(.{
        .plugin = "obfs",
        .plugin_options_state = .map,
        .obfs_mode = "http",
        .obfs_host = &host,
    });
    switch (result) {
        .supported => |transport| switch (transport) {
            .simple_obfs_http => |obfs| try std.testing.expectEqual(@as(usize, 255), obfs.host.len),
            .plain => return error.ExpectedSimpleObfsHttp,
        },
        .rejected => return error.UnexpectedCapabilityRejection,
    }
}
