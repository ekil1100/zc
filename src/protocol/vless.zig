const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const socket_options = @import("../socket_options.zig");

/// VLESS 命令类型
pub const Command = enum(u8) {
    tcp = 0x01,
    udp = 0x02,
    mux = 0x03,
};

/// VLESS 配置
pub const Config = struct {
    id: []const u8,       // UUID
    address: []const u8,  // 服务器地址
    port: u16,            // 服务器端口
};

/// VLESS 客户端（最小可用版本，仅 TCP）
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    uuid: [16]u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        var uuid: [16]u8 = undefined;
        try parseUuid(config.id, &uuid);

        return .{
            .allocator = allocator,
            .config = config,
            .uuid = uuid,
        };
    }

    pub fn connect(self: *Client, target_host: []const u8, target_port: u16) !net.Stream {
        var stream = try net.tcpConnectToHost(self.allocator, self.config.address, self.config.port);
        errdefer stream.close();
        try socket_options.configureConnectedStream(stream);

        try self.handshake(&stream, target_host, target_port);
        return stream;
    }

    /// VLESS request:
    /// [version(1)] [uuid(16)] [addon_len(1)] [command(1)] [port(2)] [addr_type(1)] [addr]
    fn handshake(self: *Client, stream: *net.Stream, target_host: []const u8, target_port: u16) !void {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        // Version
        try buf.append(self.allocator, 0x00);

        // UUID
        try buf.appendSlice(self.allocator, &self.uuid);

        // Addons length (none)
        try buf.append(self.allocator, 0x00);

        // Command: TCP
        try buf.append(self.allocator, @intFromEnum(Command.tcp));

        // Port (big endian)
        try buf.append(self.allocator, @intCast(target_port >> 8));
        try buf.append(self.allocator, @intCast(target_port & 0xFF));

        // Address
        try self.encodeAddress(&buf, target_host);

        try stream.writeAll(buf.items);
    }

    fn encodeAddress(self: *Client, buf: *std.ArrayList(u8), host: []const u8) !void {
        var ipv4: [4]u8 = undefined;
        if (parseIpv4(host, &ipv4)) {
            try buf.append(self.allocator, 0x01); // IPv4
            try buf.appendSlice(self.allocator, &ipv4);
            return;
        }

        var ipv6: [16]u8 = undefined;
        if (parseIpv6(host, &ipv6)) {
            try buf.append(self.allocator, 0x03); // IPv6
            try buf.appendSlice(self.allocator, &ipv6);
            return;
        }

        if (host.len > 255) return error.DomainTooLong;
        try buf.append(self.allocator, 0x02); // Domain
        try buf.append(self.allocator, @intCast(host.len));
        try buf.appendSlice(self.allocator, host);
    }
};

fn parseUuid(str: []const u8, out: *[16]u8) !void {
    if (str.len != 36) return error.InvalidUuid;

    var idx: usize = 0;
    var out_idx: usize = 0;

    while (idx < str.len and out_idx < 16) {
        if (str[idx] == '-') {
            idx += 1;
            continue;
        }

        if (idx + 1 >= str.len) return error.InvalidUuid;
        const high = try hexDigit(str[idx]);
        const low = try hexDigit(str[idx + 1]);
        out[out_idx] = (high << 4) | low;

        idx += 2;
        out_idx += 1;
    }

    if (out_idx != 16) return error.InvalidUuid;
}

fn hexDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn parseIpv4(str: []const u8, out: *[4]u8) bool {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var current: u16 = 0;

    for (str) |c| {
        if (c == '.') {
            if (part_idx >= 4) return false;
            parts[part_idx] = @intCast(current);
            part_idx += 1;
            current = 0;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
            if (current > 255) return false;
        } else {
            return false;
        }
    }

    if (part_idx != 3) return false;
    parts[3] = @intCast(current);

    @memcpy(out, &parts);
    return true;
}

fn parseIpv6(str: []const u8, out: *[16]u8) bool {
    // RFC 5952 compliant IPv6 parser
    // Supports: full form, compressed (::), and IPv4-mapped (::ffff:x.x.x.x)
    @memset(out, 0);

    // Check for IPv4-mapped IPv6 (::ffff:x.x.x.x)
    if (std.mem.startsWith(u8, str, "::ffff:") or std.mem.startsWith(u8, str, "::FFFF:")) {
        const ipv4_part = str[7..];
        var ipv4: [4]u8 = undefined;
        if (!parseIpv4(ipv4_part, &ipv4)) return false;
        out[10] = 0xff;
        out[11] = 0xff;
        @memcpy(out[12..16], &ipv4);
        return true;
    }

    // Find :: position for compressed form
    const double_colon = std.mem.indexOf(u8, str, "::");
    var parts: [8]u16 = undefined;
    @memset(&parts, 0);
    var part_count: usize = 0;

    if (double_colon) |dc_pos| {
        // Parse before ::
        if (dc_pos > 0) {
            var it = std.mem.splitScalar(u8, str[0..dc_pos], ':');
            while (it.next()) |part| {
                if (part.len == 0 or part.len > 4) return false;
                parts[part_count] = std.fmt.parseInt(u16, part, 16) catch return false;
                part_count += 1;
                if (part_count > 8) return false;
            }
        }

        // Parse after ::
        const after = str[dc_pos + 2 ..];
        var after_parts: [8]u16 = undefined;
        var after_count: usize = 0;
        if (after.len > 0) {
            var it = std.mem.splitScalar(u8, after, ':');
            while (it.next()) |part| {
                if (part.len == 0 or part.len > 4) return false;
                after_parts[after_count] = std.fmt.parseInt(u16, part, 16) catch return false;
                after_count += 1;
                if (after_count > 8) return false;
            }
        }

        // Total parts must not exceed 8
        if (part_count + after_count >= 8) return false;

        // Fill middle zeros and copy after parts
        const zero_count = 8 - part_count - after_count;
        for (0..after_count) |i| {
            parts[part_count + zero_count + i] = after_parts[i];
        }
    } else {
        // Full form: exactly 8 parts
        var it = std.mem.splitScalar(u8, str, ':');
        while (it.next()) |part| {
            if (part.len == 0 or part.len > 4) return false;
            if (part_count >= 8) return false;
            parts[part_count] = std.fmt.parseInt(u16, part, 16) catch return false;
            part_count += 1;
        }
        if (part_count != 8) return false;
    }

    // Convert to 16-byte representation (network byte order)
    for (0..8) |i| {
        out[i * 2] = @intCast(parts[i] >> 8);
        out[i * 2 + 1] = @intCast(parts[i] & 0xFF);
    }

    return true;
}

test "VLESS parseIpv6 full" {
    var out: [16]u8 = undefined;
    try std.testing.expect(parseIpv6("2001:0db8:85a3:0000:0000:8a2e:0370:7334", &out));
    try std.testing.expectEqual(@as(u8, 0x20), out[0]);
    try std.testing.expectEqual(@as(u8, 0x01), out[1]);
    try std.testing.expectEqual(@as(u8, 0x73), out[14]);
    try std.testing.expectEqual(@as(u8, 0x34), out[15]);
}

test "VLESS parseIpv6 compressed" {
    var out: [16]u8 = undefined;
    try std.testing.expect(parseIpv6("2001:db8::1", &out));
    try std.testing.expectEqual(@as(u8, 0x20), out[0]);
    try std.testing.expectEqual(@as(u8, 0x01), out[1]);
    try std.testing.expectEqual(@as(u8, 0x0d), out[2]);
    try std.testing.expectEqual(@as(u8, 0xb8), out[3]);
    try std.testing.expectEqual(@as(u8, 0), out[14]);
    try std.testing.expectEqual(@as(u8, 1), out[15]);
}

test "VLESS parseIpv6 ipv4-mapped" {
    var out: [16]u8 = undefined;
    try std.testing.expect(parseIpv6("::ffff:192.168.1.1", &out));
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expectEqual(@as(u8, 0xff), out[10]);
    try std.testing.expectEqual(@as(u8, 0xff), out[11]);
    try std.testing.expectEqual(@as(u8, 192), out[12]);
    try std.testing.expectEqual(@as(u8, 168), out[13]);
    try std.testing.expectEqual(@as(u8, 1), out[14]);
    try std.testing.expectEqual(@as(u8, 1), out[15]);
}

test "VLESS encodeAddress IPv6" {
    const allocator = std.testing.allocator;
    var client = try Client.init(allocator, .{
        .id = "123e4567-e89b-12d3-a456-426614174000",
        .address = "127.0.0.1",
        .port = 443,
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try client.encodeAddress(&buf, "2001:db8::1");

    try std.testing.expectEqual(@as(u8, 0x03), buf.items[0]); // IPv6 type
    try std.testing.expectEqual(@as(u8, 0x20), buf.items[1]);
    try std.testing.expectEqual(@as(u8, 0x01), buf.items[2]);
    try std.testing.expectEqual(@as(u8, 1), buf.items[16]); // last byte
}

const testing = std.testing;

test "VLESS init parses uuid" {
    const allocator = testing.allocator;

    const client = try Client.init(allocator, .{
        .id = "123e4567-e89b-12d3-a456-426614174000",
        .address = "127.0.0.1",
        .port = 443,
    });

    try testing.expectEqual(@as(usize, 16), client.uuid.len);
    try testing.expectEqual(@as(u8, 0x12), client.uuid[0]);
    try testing.expectEqual(@as(u8, 0x00), client.uuid[15]);
}

test "VLESS rejects invalid uuid" {
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidUuid, Client.init(allocator, .{
        .id = "invalid-uuid",
        .address = "127.0.0.1",
        .port = 443,
    }));
}

test "VLESS encodeAddress IPv4" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .id = "123e4567-e89b-12d3-a456-426614174000",
        .address = "127.0.0.1",
        .port = 443,
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try client.encodeAddress(&buf, "8.8.8.8");

    try testing.expectEqual(@as(u8, 0x01), buf.items[0]);
    try testing.expectEqual(@as(u8, 8), buf.items[1]);
    try testing.expectEqual(@as(u8, 8), buf.items[2]);
    try testing.expectEqual(@as(u8, 8), buf.items[3]);
    try testing.expectEqual(@as(u8, 8), buf.items[4]);
}

test "VLESS encodeAddress domain" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .id = "123e4567-e89b-12d3-a456-426614174000",
        .address = "127.0.0.1",
        .port = 443,
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try client.encodeAddress(&buf, "example.com");

    try testing.expectEqual(@as(u8, 0x02), buf.items[0]);
    try testing.expectEqual(@as(u8, 11), buf.items[1]);
    try testing.expectEqualStrings("example.com", buf.items[2..]);
}

test "VLESS encodeAddress rejects domain longer than 255 bytes" {
    const allocator = testing.allocator;

    var client = try Client.init(allocator, .{
        .id = "123e4567-e89b-12d3-a456-426614174000",
        .address = "127.0.0.1",
        .port = 443,
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const long_host = "a" ** 256;
    try testing.expectError(error.DomainTooLong, client.encodeAddress(&buf, long_host));
}
