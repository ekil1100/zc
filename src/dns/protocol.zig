const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;

/// DNS 查询类型
pub const QueryType = enum(u16) {
    a = 1,
    ns = 2,
    cname = 5,
    soa = 6,
    ptr = 12,
    mx = 15,
    txt = 16,
    aaaa = 28,
    srv = 33,
    any = 255,
};

/// DNS 响应码
pub const ResponseCode = enum(u4) {
    no_error = 0,
    format_error = 1,
    server_failure = 2,
    name_error = 3,
    not_implemented = 4,
    refused = 5,
};

/// DNS 问题结构
pub const Question = struct {
    name: []const u8,
    qtype: QueryType,
    qclass: u16 = 1, // IN (Internet)
};

/// DNS 资源记录
pub const ResourceRecord = struct {
    name: []const u8,
    rtype: u16,
    rclass: u16,
    ttl: u32,
    rdata: []const u8,
};

/// DNS 消息
pub const Message = struct {
    allocator: std.mem.Allocator,
    id: u16,
    flags: u16,
    questions: std.ArrayList(Question),
    answers: std.ArrayList(ResourceRecord),
    authorities: std.ArrayList(ResourceRecord),
    additionals: std.ArrayList(ResourceRecord),

    pub fn init(allocator: std.mem.Allocator) Message {
        return .{
            .allocator = allocator,
            .id = 0,
            .flags = 0,
            .questions = std.ArrayList(Question).empty,
            .answers = std.ArrayList(ResourceRecord).empty,
            .authorities = std.ArrayList(ResourceRecord).empty,
            .additionals = std.ArrayList(ResourceRecord).empty,
        };
    }

    pub fn deinit(self: *Message) void {
        for (self.questions.items) |q| {
            self.allocator.free(q.name);
        }
        self.questions.deinit(self.allocator);

        for (self.answers.items) |rr| {
            self.allocator.free(rr.name);
            self.allocator.free(rr.rdata);
        }
        self.answers.deinit(self.allocator);

        for (self.authorities.items) |rr| {
            self.allocator.free(rr.name);
            self.allocator.free(rr.rdata);
        }
        self.authorities.deinit(self.allocator);

        for (self.additionals.items) |rr| {
            self.allocator.free(rr.name);
            self.allocator.free(rr.rdata);
        }
        self.additionals.deinit(self.allocator);
    }

    /// 解析 DNS 消息
    pub fn decode(self: *Message, data: []const u8) !void {
        if (data.len < 12) return error.InvalidMessage;

        var pos: usize = 0;

        // Header
        self.id = std.mem.readInt(u16, @as(*const [2]u8, data[0..2]), .big);
        self.flags = std.mem.readInt(u16, @as(*const [2]u8, data[2..4]), .big);
        const qdcount = std.mem.readInt(u16, @as(*const [2]u8, data[4..6]), .big);
        const ancount = std.mem.readInt(u16, @as(*const [2]u8, data[6..8]), .big);
        const nscount = std.mem.readInt(u16, @as(*const [2]u8, data[8..10]), .big);
        const arcount = std.mem.readInt(u16, @as(*const [2]u8, data[10..12]), .big);

        pos = 12;

        // Questions
        var i: u16 = 0;
        while (i < qdcount) : (i += 1) {
            const name = try decodeName(self.allocator, data, &pos);
            if (pos + 4 > data.len) return error.InvalidMessage;
            const qtype = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(data[pos..pos+2].ptr)), .big);
            const qclass = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(data[pos+2..pos+4].ptr)), .big);
            pos += 4;

            try self.questions.append(self.allocator, .{
                .name = name,
                .qtype = @enumFromInt(qtype),
                .qclass = qclass,
            });
        }

        // Answers
        i = 0;
        while (i < ancount) : (i += 1) {
            try self.decodeResourceRecord(data, &pos, &self.answers);
        }

        // Authorities
        i = 0;
        while (i < nscount) : (i += 1) {
            try self.decodeResourceRecord(data, &pos, &self.authorities);
        }

        // Additionals
        i = 0;
        while (i < arcount) : (i += 1) {
            try self.decodeResourceRecord(data, &pos, &self.additionals);
        }
    }

    fn decodeResourceRecord(self: *Message, data: []const u8, pos: *usize, list: *std.ArrayList(ResourceRecord)) !void {
        const name = try decodeName(self.allocator, data, pos);
        if (pos.* + 10 > data.len) return error.InvalidMessage;

        const rtype = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(data[pos.*..pos.*+2].ptr)), .big);
        const rclass = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(data[pos.*+2..pos.*+4].ptr)), .big);
        const ttl = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(data[pos.*+4..pos.*+8].ptr)), .big);
        const rdlength = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(data[pos.*+8..pos.*+10].ptr)), .big);
        pos.* += 10;

        if (pos.* + rdlength > data.len) return error.InvalidMessage;

        const rdata = try self.allocator.dupe(u8, data[pos.*..pos.*+rdlength]);
        pos.* += rdlength;

        try list.append(self.allocator, .{
            .name = name,
            .rtype = rtype,
            .rclass = rclass,
            .ttl = ttl,
            .rdata = rdata,
        });
    }

    /// 编码 DNS 消息
    pub fn encode(self: *const Message, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);

        // Header
        const header = try buf.addManyAsSlice(allocator, 12);
        std.mem.writeInt(u16, header[0..2], self.id, .big);
        std.mem.writeInt(u16, header[2..4], self.flags, .big);
        std.mem.writeInt(u16, header[4..6], @intCast(self.questions.items.len), .big);
        std.mem.writeInt(u16, header[6..8], @intCast(self.answers.items.len), .big);
        std.mem.writeInt(u16, header[8..10], @intCast(self.authorities.items.len), .big);
        std.mem.writeInt(u16, header[10..12], @intCast(self.additionals.items.len), .big);

        // Questions
        for (self.questions.items) |q| {
            try encodeName(allocator, &buf, q.name);
            try buf.appendSlice(allocator, &[_]u8{
                @intCast(@intFromEnum(q.qtype) >> 8),
                @intCast(@intFromEnum(q.qtype) & 0xFF),
                @intCast(q.qclass >> 8),
                @intCast(q.qclass & 0xFF),
            });
        }

        return try buf.toOwnedSlice(allocator);
    }

    /// 获取响应码
    pub fn getResponseCode(self: Message) ResponseCode {
        return @enumFromInt(@as(u4, @intCast(self.flags & 0x0F)));
    }

    /// 是否为响应消息
    pub fn isResponse(self: Message) bool {
        return (self.flags & 0x8000) != 0;
    }
};

/// 解码域名（处理压缩指针）
pub fn decodeName(allocator: std.mem.Allocator, data: []const u8, pos: *usize) ![]u8 {
    var name_parts = std.ArrayList([]const u8).empty;
    defer name_parts.deinit(allocator);

    const start_pos = pos.*;
    var jumped = false;

    while (true) {
        if (pos.* >= data.len) return error.InvalidMessage;

        const len = data[pos.*];

        // Compression pointer
        if ((len & 0xC0) == 0xC0) {
            if (pos.* + 2 > data.len) return error.InvalidMessage;
            const offset = ((@as(usize, len & 0x3F)) << 8) | data[pos.* + 1];
            if (!jumped) {
                pos.* += 2;
                jumped = true;
            }
            pos.* = offset;
            continue;
        }

        pos.* += 1;

        if (len == 0) break;

        if (pos.* + len > data.len) return error.InvalidMessage;

        const label = try allocator.dupe(u8, data[pos.*..pos.*+len]);
        try name_parts.append(allocator, label);
        pos.* += len;
    }

    if (!jumped) {
        // Update pos to after this name
    } else {
        pos.* = start_pos + 2; // Return to after compression pointer
    }

    // Join labels with dots
    var total_len: usize = 0;
    for (name_parts.items) |label| {
        total_len += label.len + 1;
    }

    if (total_len == 0) {
        return try allocator.dupe(u8, ".");
    }

    total_len -= 1; // Remove last dot

    const result = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (name_parts.items, 0..) |label, i| {
        @memcpy(result[offset..offset+label.len], label);
        offset += label.len;
        if (i < name_parts.items.len - 1) {
            result[offset] = '.';
            offset += 1;
        }
        allocator.free(label);
    }

    return result;
}

/// 编码域名
pub fn encodeName(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".")) {
        try buf.append(allocator, 0);
        return;
    }

    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0) continue;
        if (label.len > 63) return error.LabelTooLong;
        try buf.append(allocator, @intCast(label.len));
        try buf.appendSlice(allocator, label);
    }
    try buf.append(allocator, 0);
}

/// 创建 A 记录查询
pub fn createAQuery(allocator: std.mem.Allocator, domain: []const u8) !Message {
    var msg = Message.init(allocator);
    errdefer msg.deinit();

    // Random ID
    var buf: [2]u8 = undefined;
    compat.randomBytes(&buf);
    msg.id = std.mem.readInt(u16, &buf, .big);

    // Standard query
    msg.flags = 0x0100; // RD (Recursion Desired)

    const name = try allocator.dupe(u8, domain);
    try msg.questions.append(allocator, .{
        .name = name,
        .qtype = .a,
    });

    return msg;
}

/// 解析 A 记录响应
pub fn parseAResponse(msg: *const Message) !?net.Address {
    for (msg.answers.items) |rr| {
        if (rr.rtype == 1 and rr.rclass == 1 and rr.rdata.len == 4) { // A record
            const ip = std.mem.readInt(u32, rr.rdata[0..4], .big);
            return net.Address{ .in = .{
                .sa = .{
                    .family = std.posix.AF.INET,
                    .port = 0,
                    .addr = ip,
                    .zero = undefined,
                },
            } };
        }
    }
    return null;
}

test "DNS message encode/decode" {
    const allocator = std.testing.allocator;

    var msg = try createAQuery(allocator, "example.com");
    defer msg.deinit();

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    var decoded = Message.init(allocator);
    defer decoded.deinit();

    try decoded.decode(encoded);

    try std.testing.expectEqual(msg.id, decoded.id);
    try std.testing.expectEqual(@as(usize, 1), decoded.questions.items.len);
    try std.testing.expectEqualStrings("example.com", decoded.questions.items[0].name);
}
