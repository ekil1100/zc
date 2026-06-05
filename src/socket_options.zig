const std = @import("std");
const compat = @import("compat.zig");
const builtin = @import("builtin");
const net = compat.net;

pub fn configureConnectedSocket(fd: std.posix.fd_t) !void {
    if (comptime builtin.os.tag == .macos) {
        var enabled: c_int = 1;
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.c.SO.NOSIGPIPE, std.mem.asBytes(&enabled));
    }
    // Disable Nagle on every relayed socket. The relay forwards each decrypted
    // AEAD chunk as its own write(2); with Nagle on, those small writes deadlock
    // against the peer's delayed-ACK and stall streaming (SSE) downloads
    // ("Codex SSE response headers timed out"). Applies to both the client-facing
    // accept socket and the upstream proxy socket, which share this helper.
    var nodelay: c_int = 1;
    try std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&nodelay));
}

pub fn configureConnectedStream(stream: net.Stream) !void {
    try configureConnectedSocket(stream.handle);
}

test "configureConnectedSocket enables SO_NOSIGPIPE on macOS" {
    if (builtin.os.tag != .macos) return;

    const pair = try makeTcpStreamPair();
    defer pair.left.close();
    defer pair.right.close();

    try configureConnectedSocket(pair.left.handle);

    var value: c_int = 0;
    var len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(
        pair.left.handle,
        std.posix.SOL.SOCKET,
        std.c.SO.NOSIGPIPE,
        std.mem.asBytes(&value).ptr,
        &len,
    ) < 0) return error.InputOutput;
    try std.testing.expectEqual(@as(c_int, 1), value);
}

const StreamPair = struct {
    left: net.Stream,
    right: net.Stream,
};

fn makeTcpStreamPair() !StreamPair {
    const addr = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const client = try net.tcpConnectToAddress(server.listen_address);
    const accepted = try server.accept();
    return .{
        .left = accepted.stream,
        .right = client,
    };
}
