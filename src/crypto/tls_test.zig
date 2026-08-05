const std = @import("std");
const testing = std.testing;
const TlsClient = @import("tls.zig").TlsClient;
const TlsConfig = @import("tls.zig").TlsConfig;

test "TlsConfig init" {
    const config = TlsConfig{
        .sni = "example.com",
        .skip_verify = false,
    };

    try testing.expectEqualStrings("example.com", config.sni);
    try testing.expect(!config.skip_verify);
}

test "TlsClient fails closed before sending plaintext" {
    var sockets: [2]std.posix.fd_t = undefined;
    const result = std.c.socketpair(
        @intCast(std.posix.AF.UNIX),
        @intCast(std.posix.SOCK.STREAM),
        0,
        &sockets,
    );
    try testing.expectEqual(@as(c_int, 0), result);
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);

    var client = TlsClient.init(
        testing.allocator,
        .{ .handle = sockets[0] },
        .{ .sni = "test.com", .skip_verify = false },
    );
    try testing.expectError(error.UnsupportedTLSClient, client.handshake());
    try testing.expect(!client.handshake_complete);
    try testing.expectError(
        error.UnsupportedTLSClient,
        client.write("plaintext"),
    );
    var buffer: [16]u8 = undefined;
    try testing.expectError(
        error.UnsupportedTLSClient,
        client.read(&buffer),
    );
    var descriptors = [_]std.posix.pollfd{.{
        .fd = sockets[1],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try testing.expectEqual(
        @as(usize, 0),
        try std.posix.poll(&descriptors, 0),
    );
}
