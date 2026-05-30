const std = @import("std");
const testing = std.testing;
const dns = @import("protocol.zig");
const Message = dns.Message;
const QueryType = dns.QueryType;

test "DNS Message init" {
    const allocator = testing.allocator;

    var msg = Message.init(allocator);
    defer msg.deinit();

    try testing.expectEqual(@as(u16, 0), msg.id);
    try testing.expectEqual(@as(u16, 0), msg.flags);
    try testing.expectEqual(@as(usize, 0), msg.questions.items.len);
}

test "DNS createAQuery" {
    const allocator = testing.allocator;

    var msg = try dns.createAQuery(allocator, "example.com");
    defer msg.deinit();

    try testing.expectEqual(@as(usize, 1), msg.questions.items.len);
    try testing.expectEqualStrings("example.com", msg.questions.items[0].name);
    try testing.expectEqual(QueryType.a, msg.questions.items[0].qtype);
}

test "DNS encodeName" {
    const allocator = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try dns.encodeName(allocator, &buf, "example.com");

    // Should be: [7] 'e' 'x' 'a' 'm' 'p' 'l' 'e' [3] 'c' 'o' 'm' [0]
    try testing.expectEqual(@as(u8, 7), buf.items[0]);
    try testing.expectEqual(@as(u8, 'e'), buf.items[1]);
    try testing.expectEqual(@as(u8, 3), buf.items[8]);
    try testing.expectEqual(@as(u8, 'c'), buf.items[9]);
    try testing.expectEqual(@as(u8, 0), buf.items[12]);
}

test "DNS encodeName root" {
    const allocator = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try dns.encodeName(allocator, &buf, ".");
    try testing.expectEqual(@as(u8, 0), buf.items[0]);
}

test "DNS decodeName simple" {
    const allocator = testing.allocator;

    // Create encoded name: [7]example[3]com[0]
    var data = [_]u8{ 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0 };
    var pos: usize = 0;

    const name = try dns.decodeName(allocator, &data, &pos);
    defer allocator.free(name);

    try testing.expectEqualStrings("example.com", name);
    try testing.expectEqual(@as(usize, 13), pos);
}

test "DNS getResponseCode" {
    const allocator = testing.allocator;

    var msg = Message.init(allocator);
    defer msg.deinit();

    // Response code is in lower 4 bits of flags
    msg.flags = 0x0000;
    try testing.expectEqual(dns.ResponseCode.no_error, msg.getResponseCode());

    msg.flags = 0x0003;
    try testing.expectEqual(dns.ResponseCode.name_error, msg.getResponseCode());
}

test "DNS decodeName rejects self-referential compression pointer (no infinite loop)" {
    const allocator = testing.allocator;

    // A pointer at offset 0 that points back to offset 0 (0xC0 0x00).
    // The old code looped forever here; now it must return an error.
    var data = [_]u8{ 0xC0, 0x00 };
    var pos: usize = 0;

    try testing.expectError(error.InvalidMessage, dns.decodeName(allocator, &data, &pos));
}

test "DNS decodeName rejects forward/equal compression pointer cycle" {
    const allocator = testing.allocator;

    // Two pointers that reference each other: offset 0 -> offset 2, offset 2 -> offset 0.
    var data = [_]u8{ 0xC0, 0x02, 0xC0, 0x00 };
    var pos: usize = 0;

    try testing.expectError(error.InvalidMessage, dns.decodeName(allocator, &data, &pos));
}

test "DNS decodeName restores pos after labels-then-pointer" {
    const allocator = testing.allocator;

    // Layout:
    //   offset 0:  [3]c o m [0]            -> the compression target "com"
    //   offset 5:  [3]w w w 0xC0 0x00      -> "www" then pointer to offset 0
    // Decoding starting at offset 5 should yield "www.com" and leave pos at 11
    // (right after the 2-byte pointer at offsets 9..10), NOT at start_pos+2.
    var data = [_]u8{
        3, 'c', 'o', 'm', 0, // offset 0..4
        3, 'w', 'w', 'w', 0xC0, 0x00, // offset 5..10
    };
    var pos: usize = 5;

    const name = try dns.decodeName(allocator, &data, &pos);
    defer allocator.free(name);

    try testing.expectEqualStrings("www.com", name);
    try testing.expectEqual(@as(usize, 11), pos);
}

test "DNS decode accepts uncommon question qtype without panic" {
    const allocator = testing.allocator;

    // Minimal DNS message: header + one question with qtype=65 (HTTPS), which
    // is not one of the named QueryType values. The old exhaustive enum made
    // @enumFromInt illegal behavior; now it must decode fine.
    var data = [_]u8{
        0x12, 0x34, // id
        0x81, 0x80, // flags (response)
        0x00, 0x01, // qdcount = 1
        0x00, 0x00, // ancount
        0x00, 0x00, // nscount
        0x00, 0x00, // arcount
        // question: "a" qtype=65 (0x0041) qclass=1
        1, 'a', 0,
        0x00, 0x41,
        0x00, 0x01,
    };

    var msg = Message.init(allocator);
    defer msg.deinit();

    try msg.decode(&data);
    try testing.expectEqual(@as(usize, 1), msg.questions.items.len);
    try testing.expectEqual(@as(u16, 65), @intFromEnum(msg.questions.items[0].qtype));
}

test "DNS getResponseCode handles rcodes 6..15 without panic" {
    const allocator = testing.allocator;

    var msg = Message.init(allocator);
    defer msg.deinit();

    // rcode 6 (YXDOMAIN) is a valid wire value not in the named set.
    msg.flags = 0x0006;
    try testing.expectEqual(@as(u4, 6), @intFromEnum(msg.getResponseCode()));

    msg.flags = 0x000F;
    try testing.expectEqual(@as(u4, 15), @intFromEnum(msg.getResponseCode()));
}

test "DNS isResponse" {
    const allocator = testing.allocator;

    var msg = Message.init(allocator);
    defer msg.deinit();

    // QR bit (bit 15) indicates response
    msg.flags = 0x0000;
    try testing.expect(!msg.isResponse());

    msg.flags = 0x8000;
    try testing.expect(msg.isResponse());
}
