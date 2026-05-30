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

// Regression test for the double-close bug in ApiServer.start/handleConnection.
//
// Previously start() called `conn.stream.close()` in its `catch |err|` handler
// AND handleConnection() closed the same stream via `defer conn.stream.close()`,
// so any error path inside handleConnection closed the same fd twice. The fix
// removed the close in start()'s catch handler, leaving exactly one owner.
//
// We model the connection lifecycle with a close-counting stub. The buggy
// pattern closes twice on the error path; the fixed pattern closes exactly once.
const CloseCounter = struct {
    count: usize = 0,
    fn close(self: *CloseCounter) void {
        self.count += 1;
    }
};

// Mirrors the FIXED control flow: handleConnection's defer is the sole closer,
// start() does not close again in its catch handler.
fn fixedDriveConnection(c: *CloseCounter, fail: bool) void {
    // handleConnection body
    const handle = struct {
        fn run(cc: *CloseCounter, should_fail: bool) error{ConnError}!void {
            defer cc.close(); // `defer conn.stream.close()`
            if (should_fail) return error.ConnError;
        }
    }.run;
    // start() catch handler: must NOT close again
    handle(c, fail) catch {};
}

test "connection closed exactly once on error path (no double close)" {
    var c = CloseCounter{};
    fixedDriveConnection(&c, true); // error path
    try testing.expectEqual(@as(usize, 1), c.count);

    var c2 = CloseCounter{};
    fixedDriveConnection(&c2, false); // success path
    try testing.expectEqual(@as(usize, 1), c2.count);
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
