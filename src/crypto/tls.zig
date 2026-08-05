const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;

pub const TlsConfig = struct {
    sni: []const u8,
    skip_verify: bool = false,
    alpn: ?[]const []const u8 = null,
};

/// This legacy surface remains fail-closed until it uses a verified TLS stack.
pub const TlsClient = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    config: TlsConfig,
    handshake_complete: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        stream: net.Stream,
        config: TlsConfig,
    ) TlsClient {
        return .{
            .allocator = allocator,
            .stream = stream,
            .config = config,
            .handshake_complete = false,
        };
    }

    pub fn handshake(self: *TlsClient) !void {
        self.handshake_complete = false;
        return error.UnsupportedTLSClient;
    }

    pub fn write(self: *TlsClient, data: []const u8) !void {
        _ = self;
        _ = data;
        return error.UnsupportedTLSClient;
    }

    pub fn read(self: *TlsClient, buffer: []u8) !usize {
        _ = self;
        _ = buffer;
        return error.UnsupportedTLSClient;
    }

    pub fn close(self: *TlsClient) void {
        self.stream.close();
    }
};

pub fn wrapTls(
    allocator: std.mem.Allocator,
    stream: net.Stream,
    config: TlsConfig,
) !TlsClient {
    _ = allocator;
    _ = stream;
    _ = config;
    return error.UnsupportedTLSClient;
}

pub fn connect(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    sni: []const u8,
) !TlsClient {
    _ = allocator;
    _ = host;
    _ = port;
    _ = sni;
    return error.UnsupportedTLSClient;
}
