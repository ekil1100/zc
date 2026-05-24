const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const crypto = std.crypto;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;
const socket_options = @import("../socket_options.zig");

const frame_header_len = 7;
const default_padding0_len: u16 = 30;
const max_frame_data_len = std.math.maxInt(u16);

const default_padding_scheme =
    "stop=8\n" ++
    "0=30-30\n" ++
    "1=100-400\n" ++
    "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000\n" ++
    "3=9-9,500-1000\n" ++
    "4=500-1000\n" ++
    "5=500-1000\n" ++
    "6=500-1000\n" ++
    "7=500-1000";

const Command = enum(u8) {
    waste = 0,
    syn = 1,
    psh = 2,
    fin = 3,
    settings = 4,
    alert = 5,
    update_padding_scheme = 6,
    syn_ack = 7,
    heart_request = 8,
    heart_response = 9,
    server_settings = 10,
};

pub const Config = struct {
    password: []const u8,
    address: []const u8,
    port: u16,
    sni: ?[]const u8 = null,
    skip_cert_verify: bool = false,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    password_hash: [32]u8,
    tls_conn: ?*TlsConnection = null,
    stream_id: u32 = 0,
    stream_closed: bool = false,
    peer_version: u8 = 1,
    packet_counter: u32 = 0,
    pending_read: ?[]u8 = null,
    pending_offset: usize = 0,

    const TlsConnection = struct {
        stream: net.Stream,
        stream_reader: net.Stream.Reader,
        stream_writer: net.Stream.Writer,
        tls_client: tls.Client,
        ca_bundle: ?Certificate.Bundle = null,
        ca_lock: std.Io.RwLock = .init,
        socket_read_buffer: [tls.Client.min_buffer_len]u8,
        socket_write_buffer: [tls.Client.min_buffer_len]u8,
        tls_read_buffer: [tls.Client.min_buffer_len]u8,
        tls_write_buffer: [tls.Client.min_buffer_len]u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        var password_hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(config.password, &password_hash, .{});

        return .{
            .allocator = allocator,
            .config = config,
            .password_hash = password_hash,
        };
    }

    pub fn deinit(self: *Client) void {
        if (!self.stream_closed and self.tls_conn != null and self.stream_id != 0) {
            self.sendFrame(.fin, self.stream_id, "") catch {};
            self.stream_closed = true;
        }
        if (self.pending_read) |pending| {
            self.allocator.free(pending);
            self.pending_read = null;
        }
        if (self.tls_conn) |conn| {
            _ = conn.tls_client.end() catch {};
            conn.stream.close();
            if (conn.ca_bundle) |*ca_bundle| {
                ca_bundle.deinit(self.allocator);
            }
            self.allocator.destroy(conn);
            self.tls_conn = null;
        }
    }

    pub fn connect(self: *Client, target_host: []const u8, target_port: u16) !net.Stream {
        if (self.tls_conn != null) return error.AlreadyConnected;

        const stream = try net.tcpConnectToHost(self.allocator, self.config.address, self.config.port);
        var stream_owned_by_conn = false;
        errdefer if (!stream_owned_by_conn) stream.close();
        try socket_options.configureConnectedStream(stream);

        const conn = try self.initTlsConnection(stream);
        stream_owned_by_conn = true;
        var conn_owned_by_self = false;
        errdefer if (!conn_owned_by_self) self.deinitTlsConnection(conn);

        const auth = try buildAuthRequest(self.allocator, self.config.password);
        defer self.allocator.free(auth);
        try conn.tls_client.writer.writeAll(auth);
        try flushTlsAndSocket(conn);

        self.tls_conn = conn;
        conn_owned_by_self = true;
        self.stream_id = 1;
        self.stream_closed = false;

        self.openStream(target_host, target_port) catch |err| {
            self.deinit();
            return err;
        };

        return conn.stream;
    }

    pub fn write(self: *Client, data: []const u8) !void {
        if (self.stream_closed) return error.StreamClosed;
        if (self.tls_conn == null) return error.NotConnected;

        var offset: usize = 0;
        while (offset < data.len) {
            const n = @min(data.len - offset, max_frame_data_len);
            try self.sendFrame(.psh, self.stream_id, data[offset..][0..n]);
            offset += n;
        }
    }

    pub fn read(self: *Client, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        if (self.stream_closed) return 0;
        if (self.tls_conn == null) return error.NotConnected;

        if (self.consumePending(buf)) |n| return n;

        while (true) {
            const frame = try self.readFrameHeader();
            const command = commandFromByte(frame.command) orelse {
                try self.discardFrameData(frame.length);
                continue;
            };
            switch (command) {
                .psh => {
                    const data = try self.readFrameData(frame.length);
                    if (frame.stream_id != self.stream_id) {
                        if (data.len > 0) self.allocator.free(data);
                        continue;
                    }
                    if (data.len == 0) continue;
                    return self.copyFrameData(buf, data);
                },
                .fin => {
                    try self.discardFrameData(frame.length);
                    if (frame.stream_id == self.stream_id) {
                        self.stream_closed = true;
                        return 0;
                    }
                },
                .syn_ack => {
                    const data = try self.readFrameData(frame.length);
                    defer if (data.len > 0) self.allocator.free(data);
                    if (frame.stream_id == self.stream_id and data.len > 0) {
                        return error.AnyTlsStreamRejected;
                    }
                },
                .server_settings => {
                    const data = try self.readFrameData(frame.length);
                    defer if (data.len > 0) self.allocator.free(data);
                    self.applyServerSettings(data);
                },
                .alert => {
                    try self.discardFrameData(frame.length);
                    self.stream_closed = true;
                    return error.AnyTlsAlert;
                },
                .update_padding_scheme, .waste, .settings => {
                    try self.discardFrameData(frame.length);
                },
                .heart_request => {
                    try self.discardFrameData(frame.length);
                    try self.sendFrame(.heart_response, frame.stream_id, "");
                },
                .heart_response, .syn => {
                    try self.discardFrameData(frame.length);
                },
            }
        }
    }

    pub fn hasPendingRead(self: *const Client) bool {
        if (self.pending_read) |pending| {
            if (self.pending_offset < pending.len) return true;
        }
        if (self.tls_conn) |conn| {
            return conn.tls_client.reader.bufferedLen() > 0 or
                conn.stream_reader.interface.bufferedLen() > 0;
        }
        return false;
    }

    fn openStream(self: *Client, target_host: []const u8, target_port: u16) !void {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);

        const settings = try buildSettings(self.allocator);
        defer self.allocator.free(settings);
        try appendFrame(self.allocator, &payload, .settings, 0, settings);
        try appendFrame(self.allocator, &payload, .syn, self.stream_id, "");

        const socks_addr = try encodeSocksAddr(self.allocator, target_host, target_port);
        defer self.allocator.free(socks_addr);
        try appendFrame(self.allocator, &payload, .psh, self.stream_id, socks_addr);

        try self.writeSessionPayload(payload.items);
    }

    fn sendFrame(self: *Client, command: Command, stream_id: u32, data: []const u8) !void {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);

        try appendFrame(self.allocator, &payload, command, stream_id, data);
        try self.writeSessionPayload(payload.items);
    }

    fn writeSessionPayload(self: *Client, payload: []const u8) !void {
        const conn = self.tls_conn orelse return error.NotConnected;
        self.packet_counter += 1;

        var owned_payload: ?[]u8 = null;
        const out = blk: {
            if (defaultPaddingTarget(self.packet_counter)) |target_len| {
                if (target_len > payload.len + frame_header_len) {
                    const padded = try self.allocator.alloc(u8, target_len);
                    @memcpy(padded[0..payload.len], payload);
                    const waste_len = target_len - payload.len - frame_header_len;
                    padded[payload.len] = @intFromEnum(Command.waste);
                    writeU32(padded[payload.len + 1 .. payload.len + 5], 0);
                    writeU16(padded[payload.len + 5 .. payload.len + 7], @intCast(waste_len));
                    @memset(padded[payload.len + frame_header_len ..], 0);
                    owned_payload = padded;
                    break :blk padded;
                }
            }
            break :blk payload;
        };
        defer if (owned_payload) |p| self.allocator.free(p);

        try conn.tls_client.writer.writeAll(out);
        try flushTlsAndSocket(conn);
    }

    fn initTlsConnection(self: *Client, stream: net.Stream) !*TlsConnection {
        const conn = try self.allocator.create(TlsConnection);
        errdefer self.allocator.destroy(conn);
        errdefer if (conn.ca_bundle) |*ca_bundle| ca_bundle.deinit(self.allocator);

        conn.stream = stream;
        conn.ca_bundle = null;
        conn.ca_lock = .init;
        conn.socket_read_buffer = undefined;
        conn.socket_write_buffer = undefined;
        conn.tls_read_buffer = undefined;
        conn.tls_write_buffer = undefined;
        conn.stream_reader = conn.stream.reader(&conn.socket_read_buffer);
        conn.stream_writer = conn.stream.writer(&conn.socket_write_buffer);
        conn.tls_client = undefined;

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        compat.randomBytes(&entropy);
        const now = std.Io.Timestamp.now(compat.io(), .real);
        var options = tls.Client.Options{
            .host = .{ .explicit = self.tlsHost() },
            .ca = .{ .no_verification = {} },
            .allow_truncation_attacks = true,
            .read_buffer = &conn.tls_read_buffer,
            .write_buffer = &conn.tls_write_buffer,
            .entropy = &entropy,
            .realtime_now = now,
        };

        if (!self.config.skip_cert_verify) {
            conn.ca_bundle = .empty;
            if (conn.ca_bundle) |*bundle| {
                try bundle.rescan(self.allocator, compat.io(), now);
                options.ca = .{ .bundle = .{
                    .gpa = self.allocator,
                    .io = compat.io(),
                    .lock = &conn.ca_lock,
                    .bundle = bundle,
                } };
            }
        }

        conn.tls_client = tls.Client.init(
            &conn.stream_reader.interface,
            &conn.stream_writer.interface,
            options,
        ) catch |err| {
            if (conn.ca_bundle) |*ca_bundle| {
                ca_bundle.deinit(self.allocator);
                conn.ca_bundle = null;
            }
            return err;
        };

        return conn;
    }

    fn tlsHost(self: *const Client) []const u8 {
        return self.config.sni orelse self.config.address;
    }

    fn deinitTlsConnection(self: *Client, conn: *TlsConnection) void {
        _ = conn.tls_client.end() catch {};
        conn.stream.close();
        if (conn.ca_bundle) |*ca_bundle| {
            ca_bundle.deinit(self.allocator);
        }
        self.allocator.destroy(conn);
    }

    const FrameHeader = struct {
        command: u8,
        stream_id: u32,
        length: u16,
    };

    fn readFrameHeader(self: *Client) !FrameHeader {
        const conn = self.tls_conn orelse return error.NotConnected;
        var header: [frame_header_len]u8 = undefined;
        try readTlsExact(&conn.tls_client.reader, &header);
        return .{
            .command = header[0],
            .stream_id = readU32(header[1..5]),
            .length = readU16(header[5..7]),
        };
    }

    fn readFrameData(self: *Client, length: u16) ![]u8 {
        if (length == 0) return &.{};
        const conn = self.tls_conn orelse return error.NotConnected;
        const data = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(data);
        try readTlsExact(&conn.tls_client.reader, data);
        return data;
    }

    fn discardFrameData(self: *Client, length: u16) !void {
        if (length == 0) return;
        const conn = self.tls_conn orelse return error.NotConnected;
        var remaining: usize = length;
        var scratch: [1024]u8 = undefined;
        while (remaining > 0) {
            const n = @min(remaining, scratch.len);
            try readTlsExact(&conn.tls_client.reader, scratch[0..n]);
            remaining -= n;
        }
    }

    fn consumePending(self: *Client, buf: []u8) ?usize {
        const pending = self.pending_read orelse return null;
        const remaining = pending[self.pending_offset..];
        const n = @min(buf.len, remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.pending_offset += n;
        if (self.pending_offset >= pending.len) {
            self.allocator.free(pending);
            self.pending_read = null;
            self.pending_offset = 0;
        }
        return n;
    }

    fn copyFrameData(self: *Client, buf: []u8, data: []u8) usize {
        if (data.len == 0) return 0;
        const n = @min(buf.len, data.len);
        @memcpy(buf[0..n], data[0..n]);
        if (n < data.len) {
            self.pending_read = data;
            self.pending_offset = n;
        } else {
            self.allocator.free(data);
        }
        return n;
    }

    fn applyServerSettings(self: *Client, data: []const u8) void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "v=")) {
                self.peer_version = std.fmt.parseInt(u8, line[2..], 10) catch self.peer_version;
            }
        }
    }
};

fn buildAuthRequest(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    const auth_len = 32 + 2 + default_padding0_len;
    const auth = try allocator.alloc(u8, auth_len);
    crypto.hash.sha2.Sha256.hash(password, auth[0..32], .{});
    writeU16(auth[32..34], default_padding0_len);
    @memset(auth[34..], 0);
    return auth;
}

fn buildSettings(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var md5: [16]u8 = undefined;
    crypto.hash.Md5.hash(default_padding_scheme, &md5, .{});
    var md5_hex: [32]u8 = undefined;
    writeLowerHex(&md5_hex, &md5);

    try out.appendSlice(allocator, "v=2\n");
    try out.appendSlice(allocator, "client=zc/anytls\n");
    try out.appendSlice(allocator, "padding-md5=");
    try out.appendSlice(allocator, &md5_hex);
    return try out.toOwnedSlice(allocator);
}

fn appendFrame(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    command: Command,
    stream_id: u32,
    data: []const u8,
) !void {
    if (data.len > max_frame_data_len) return error.FrameTooLarge;
    try out.append(allocator, @intFromEnum(command));

    var header: [6]u8 = undefined;
    writeU32(header[0..4], stream_id);
    writeU16(header[4..6], @intCast(data.len));
    try out.appendSlice(allocator, &header);
    try out.appendSlice(allocator, data);
}

fn encodeSocksAddr(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var ipv4: [4]u8 = undefined;
    if (parseIpv4(host, &ipv4)) {
        try out.append(allocator, 0x01);
        try out.appendSlice(allocator, &ipv4);
    } else {
        var ipv6: [16]u8 = undefined;
        if (parseIpv6(host, &ipv6)) {
            try out.append(allocator, 0x04);
            try out.appendSlice(allocator, &ipv6);
        } else {
            if (host.len > 255) return error.DomainTooLong;
            try out.append(allocator, 0x03);
            try out.append(allocator, @intCast(host.len));
            try out.appendSlice(allocator, host);
        }
    }

    try out.append(allocator, @intCast(port >> 8));
    try out.append(allocator, @intCast(port & 0xff));
    return try out.toOwnedSlice(allocator);
}

fn defaultPaddingTarget(packet_counter: u32) ?usize {
    return switch (packet_counter) {
        1 => 100,
        2 => 400,
        3 => 9,
        4...7 => 500,
        else => null,
    };
}

fn commandFromByte(value: u8) ?Command {
    return switch (value) {
        0 => .waste,
        1 => .syn,
        2 => .psh,
        3 => .fin,
        4 => .settings,
        5 => .alert,
        6 => .update_padding_scheme,
        7 => .syn_ack,
        8 => .heart_request,
        9 => .heart_response,
        10 => .server_settings,
        else => null,
    };
}

fn flushTlsAndSocket(conn: *Client.TlsConnection) !void {
    try conn.tls_client.writer.flush();
    try conn.stream_writer.interface.flush();
}

fn readTlsExact(reader: *std.Io.Reader, out: []u8) !void {
    var filled: usize = 0;
    while (filled < out.len) {
        while (reader.bufferedLen() == 0) {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                else => return err,
            };
        }

        const buffered = reader.buffered();
        const n = @min(out.len - filled, buffered.len);
        @memcpy(out[filled..][0..n], buffered[0..n]);
        reader.seek += n;
        filled += n;
    }
}

fn parseIpv4(str: []const u8, out: *[4]u8) bool {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var current: u16 = 0;
    var saw_digit = false;

    for (str) |c| {
        if (c == '.') {
            if (!saw_digit or part_idx >= 3) return false;
            parts[part_idx] = @intCast(current);
            part_idx += 1;
            current = 0;
            saw_digit = false;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
            if (current > 255) return false;
            saw_digit = true;
        } else {
            return false;
        }
    }

    if (!saw_digit or part_idx != 3) return false;
    parts[3] = @intCast(current);
    @memcpy(out, &parts);
    return true;
}

fn parseIpv6(str: []const u8, out: *[16]u8) bool {
    @memset(out, 0);

    if (std.mem.startsWith(u8, str, "::ffff:") or std.mem.startsWith(u8, str, "::FFFF:")) {
        const ipv4_part = str[7..];
        var ipv4: [4]u8 = undefined;
        if (!parseIpv4(ipv4_part, &ipv4)) return false;
        out[10] = 0xff;
        out[11] = 0xff;
        @memcpy(out[12..16], &ipv4);
        return true;
    }

    const double_colon = std.mem.indexOf(u8, str, "::");
    var parts: [8]u16 = undefined;
    @memset(&parts, 0);
    var part_count: usize = 0;

    if (double_colon) |dc_pos| {
        if (dc_pos > 0) {
            var it = std.mem.splitScalar(u8, str[0..dc_pos], ':');
            while (it.next()) |part| {
                if (part.len == 0 or part.len > 4 or part_count >= 8) return false;
                parts[part_count] = std.fmt.parseInt(u16, part, 16) catch return false;
                part_count += 1;
            }
        }

        const after = str[dc_pos + 2 ..];
        var after_parts: [8]u16 = undefined;
        var after_count: usize = 0;
        if (after.len > 0) {
            var it = std.mem.splitScalar(u8, after, ':');
            while (it.next()) |part| {
                if (part.len == 0 or part.len > 4 or after_count >= 8) return false;
                after_parts[after_count] = std.fmt.parseInt(u16, part, 16) catch return false;
                after_count += 1;
            }
        }

        if (part_count + after_count >= 8) return false;
        const zero_count = 8 - part_count - after_count;
        for (0..after_count) |i| {
            parts[part_count + zero_count + i] = after_parts[i];
        }
    } else {
        var it = std.mem.splitScalar(u8, str, ':');
        while (it.next()) |part| {
            if (part.len == 0 or part.len > 4 or part_count >= 8) return false;
            parts[part_count] = std.fmt.parseInt(u16, part, 16) catch return false;
            part_count += 1;
        }
        if (part_count != 8) return false;
    }

    for (0..8) |i| {
        out[i * 2] = @intCast(parts[i] >> 8);
        out[i * 2 + 1] = @intCast(parts[i] & 0xff);
    }
    return true;
}

fn readU16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn readU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

fn writeU16(out: []u8, value: u16) void {
    out[0] = @intCast(value >> 8);
    out[1] = @intCast(value & 0xff);
}

fn writeU32(out: []u8, value: u32) void {
    out[0] = @intCast(value >> 24);
    out[1] = @intCast((value >> 16) & 0xff);
    out[2] = @intCast((value >> 8) & 0xff);
    out[3] = @intCast(value & 0xff);
}

fn writeLowerHex(out: *[32]u8, bytes: *const [16]u8) void {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
}

test "AnyTLS auth request uses sha256 password and default padding0" {
    const allocator = std.testing.allocator;
    const auth = try buildAuthRequest(allocator, "secret");
    defer allocator.free(auth);

    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("secret", &expected_hash, .{});

    try std.testing.expectEqual(@as(usize, 64), auth.len);
    try std.testing.expectEqualSlices(u8, &expected_hash, auth[0..32]);
    try std.testing.expectEqual(@as(u8, 0), auth[32]);
    try std.testing.expectEqual(@as(u8, 30), auth[33]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 30), auth[34..64]);
}

test "AnyTLS frame encoding is command stream id length data" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendFrame(allocator, &out, .psh, 7, "abc");

    const expected = [_]u8{ 2, 0, 0, 0, 7, 0, 3, 'a', 'b', 'c' };
    try std.testing.expectEqualSlices(u8, &expected, out.items);
}

test "AnyTLS settings advertise protocol v2 and default padding md5" {
    const allocator = std.testing.allocator;
    const settings = try buildSettings(allocator);
    defer allocator.free(settings);

    try std.testing.expect(std.mem.indexOf(u8, settings, "v=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "client=zc/anytls") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "padding-md5=75cff2ad89aadf5e257059ee571ebe11") != null);
}

test "AnyTLS treats unknown frame commands as ignorable" {
    try std.testing.expectEqual(@as(?Command, null), commandFromByte(255));
    try std.testing.expectEqual(Command.psh, commandFromByte(2).?);
}

test "AnyTLS SocksAddr encoding matches sing-box serializer" {
    const allocator = std.testing.allocator;

    const domain = try encodeSocksAddr(allocator, "example.com", 443);
    defer allocator.free(domain);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x03, 11, 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm', 0x01, 0xbb,
    }, domain);

    const ipv4 = try encodeSocksAddr(allocator, "192.168.1.2", 8080);
    defer allocator.free(ipv4);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x01, 192, 168, 1, 2, 0x1f, 0x90,
    }, ipv4);

    const ipv6 = try encodeSocksAddr(allocator, "2001:db8::1", 53);
    defer allocator.free(ipv6);
    try std.testing.expectEqual(@as(u8, 0x04), ipv6[0]);
    try std.testing.expectEqual(@as(usize, 19), ipv6.len);
    try std.testing.expectEqual(@as(u8, 0x20), ipv6[1]);
    try std.testing.expectEqual(@as(u8, 0x01), ipv6[2]);
    try std.testing.expectEqual(@as(u8, 0x00), ipv6[17]);
    try std.testing.expectEqual(@as(u8, 0x35), ipv6[18]);
}
