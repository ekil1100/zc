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

// Keepalive timers for upstream proxy sockets: probe an idle-but-presumed-alive
// connection well before the macOS 2h default so dead upstreams are detected in
// a bounded window. Values in seconds (KEEPCNT is a probe count).
const keepalive_idle_secs: c_int = 30;
const keepalive_intvl_secs: c_int = 10;
const keepalive_probe_count: c_int = 3;

// Configures an UPSTREAM proxy socket: everything configureConnectedSocket does,
// plus SO_KEEPALIVE with a bounded keepalive window. This is deliberately NOT
// folded into configureConnectedSocket, which is shared with the client-facing
// accept socket where keepalive is unwanted. We do NOT set SO_RCVTIMEO/SO_SNDTIMEO:
// under std.Io.Threaded a recv/send timeout fires EAGAIN -> errnoBug()/panic, and
// a read timeout would also wrongly kill idle-but-healthy streams.
pub fn configureUpstreamProxySocket(fd: std.posix.fd_t) !void {
    try configureConnectedSocket(fd);

    var enabled: c_int = 1;
    try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enabled));

    // Tolerate setsockopt errors on per-OS options the platform may lack.
    if (comptime builtin.os.tag == .macos) {
        var idle: c_int = keepalive_idle_secs;
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPALIVE, std.mem.asBytes(&idle)) catch {};
        if (@hasDecl(std.posix.TCP, "KEEPINTVL")) {
            var intvl: c_int = keepalive_intvl_secs;
            std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPINTVL, std.mem.asBytes(&intvl)) catch {};
        }
        if (@hasDecl(std.posix.TCP, "KEEPCNT")) {
            var cnt: c_int = keepalive_probe_count;
            std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPCNT, std.mem.asBytes(&cnt)) catch {};
        }
    } else if (comptime builtin.os.tag == .linux) {
        var idle: c_int = keepalive_idle_secs;
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPIDLE, std.mem.asBytes(&idle)) catch {};
        var intvl: c_int = keepalive_intvl_secs;
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPINTVL, std.mem.asBytes(&intvl)) catch {};
        var cnt: c_int = keepalive_probe_count;
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPCNT, std.mem.asBytes(&cnt)) catch {};
    }
}

pub fn configureUpstreamProxyStream(stream: net.Stream) !void {
    try configureUpstreamProxySocket(stream.handle);
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

test "configureUpstreamProxySocket enables SO_KEEPALIVE" {
    const pair = try makeTcpStreamPair();
    defer pair.left.close();
    defer pair.right.close();

    try configureUpstreamProxySocket(pair.left.handle);

    var value: c_int = 0;
    var len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(
        pair.left.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.KEEPALIVE,
        std.mem.asBytes(&value).ptr,
        &len,
    ) < 0) return error.InputOutput;
    try std.testing.expect(value != 0);
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
