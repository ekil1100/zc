const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

// Simple HTTP response parsing test
test "HTTP response parsing" {
    const ver = build_options.version;
    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" ++ comptime std.fmt.comptimePrint("{{\"version\":\"{s}\"}}", .{ver});

    // Check status line
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK"));

    // Check headers
    try testing.expect(std.mem.indexOf(u8, response, "Content-Type: application/json") != null);

    // Check body
    try testing.expect(std.mem.indexOf(u8, response, "\"version\":\"" ++ ver ++ "\"") != null);
}

test "JSON response format" {
    const allocator = testing.allocator;

    // Test simple JSON serialization
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"proxies\":[");
    try json.appendSlice(allocator, "{\"name\":\"Proxy1\",\"type\":\"Shadowsocks\"}");
    try json.appendSlice(allocator, "]}");

    const result = try json.toOwnedSlice(allocator);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"proxies\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"Proxy1\"") != null);
}
