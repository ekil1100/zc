const std = @import("std");
const compat = @import("compat.zig");
const builtin = @import("builtin");
const net = compat.net;

pub fn configureConnectedSocket(fd: std.posix.fd_t) !void {
    if (comptime builtin.os.tag == .macos) {
        var enabled: c_int = 1;
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.c.SO.NOSIGPIPE, std.mem.asBytes(&enabled));
    }
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
    try std.posix.getsockopt(
        pair.left.handle,
        std.posix.SOL.SOCKET,
        std.c.SO.NOSIGPIPE,
        std.mem.asBytes(&value),
    );
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
