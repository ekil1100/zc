const std = @import("std");
const testing = std.testing;
const yaml = @import("yaml.zig");

test "YAML parse string" {
    const allocator = testing.allocator;

    const content = "hello: world";
    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    try testing.expect(doc == .map);
    try testing.expect(doc.map.contains("hello"));

    const value = doc.map.get("hello").?;
    try testing.expect(value == .string);
    try testing.expectEqualStrings("world", value.string);
}

test "YAML parse integer" {
    const allocator = testing.allocator;

    const content = "port: 7890";
    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    const value = doc.map.get("port").?;
    try testing.expect(value == .integer);
    try testing.expectEqual(@as(i64, 7890), value.integer);
}

test "YAML parse boolean" {
    const allocator = testing.allocator;

    const content = "enable: true\ndisable: false";
    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    const enable = doc.map.get("enable").?;
    try testing.expect(enable == .boolean);
    try testing.expect(enable.boolean);

    const disable = doc.map.get("disable").?;
    try testing.expect(!disable.boolean);
}

test "YAML parse array" {
    const allocator = testing.allocator;

    const content =
        \\- item1
        \\- item2
        \\- item3
    ;

    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    try testing.expect(doc == .array);
    try testing.expectEqual(@as(usize, 3), doc.array.items.len);
    try testing.expectEqualStrings("item1", doc.array.items[0].string);
}

test "YAML parse nested map" {
    const allocator = testing.allocator;

    const content =
        \\server:
        \\  host: localhost
        \\  port: 8080
    ;

    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    const server = doc.map.get("server").?;
    try testing.expect(server == .map);
    try testing.expectEqualStrings("localhost", server.map.get("host").?.string);
}
