const std = @import("std");

pub const Error = error{InvalidControllerEndpoint};
pub const loopback_host = "127.0.0.1";

pub const Endpoint = struct {
    port: u16,
};

pub fn parse(value: []const u8) Error!Endpoint {
    const prefix = loopback_host ++ ":";
    if (!std.mem.startsWith(u8, value, prefix)) {
        return error.InvalidControllerEndpoint;
    }

    const port_text = value[prefix.len..];
    if (port_text.len == 0) return error.InvalidControllerEndpoint;
    const port = std.fmt.parseInt(u16, port_text, 10) catch
        return error.InvalidControllerEndpoint;
    if (port == 0) return error.InvalidControllerEndpoint;
    return .{ .port = port };
}

test "controller endpoint accepts only explicit IPv4 loopback" {
    const testing = std.testing;

    try testing.expectEqual(@as(u16, 9090), (try parse("127.0.0.1:9090")).port);
    try testing.expectError(error.InvalidControllerEndpoint, parse("0.0.0.0:9090"));
    try testing.expectError(error.InvalidControllerEndpoint, parse("localhost:9090"));
    try testing.expectError(error.InvalidControllerEndpoint, parse("[::1]:9090"));
    try testing.expectError(error.InvalidControllerEndpoint, parse("127.0.0.1:0"));
    try testing.expectError(error.InvalidControllerEndpoint, parse("127.0.0.1:65536"));
    try testing.expectError(error.InvalidControllerEndpoint, parse("127.0.0.1:"));
}
