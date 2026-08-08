const std = @import("std");

const address_type_ipv4: u8 = 0x01;
const address_type_domain: u8 = 0x03;
const address_type_ipv6: u8 = 0x04;
const ipv4_size: usize = 4;
const ipv6_size: usize = 16;
const port_size: usize = 2;
const domain_size_max: usize = 255;

pub const encoded_size_max: usize = 259;

comptime {
    std.debug.assert(encoded_size_max == 1 + 1 + domain_size_max + port_size);
}

pub const EncodeError = error{
    EmptyDomain,
    DomainTooLong,
    LengthOverflow,
    OutputTooSmall,
};

pub const ParseError = error{
    MissingAddressType,
    MissingDomainLength,
    TruncatedHost,
    TruncatedPort,
    UnknownAddressType,
    EmptyDomain,
    LengthOverflow,
};

/// A parsed host is either fixed-width IP bytes or a domain view into the input.
pub const Host = union(enum) {
    ipv4: [ipv4_size]u8,
    domain: []const u8,
    ipv6: [ipv6_size]u8,
};

/// Parsed is an allocation-free view of one ATYP, ADDR, and PORT tuple.
pub const Parsed = struct {
    raw: []const u8,
    host: Host,
    port: u16,
    consumed: usize,
};

/// Address encodes a textual host and host-order port in SOCKS wire format.
pub const Address = struct {
    host: []const u8,
    port: u16,

    pub fn encode(self: Address, output: []u8) EncodeError!usize {
        if (self.host.len == 0) return error.EmptyDomain;
        if (self.host.len > domain_size_max) return error.DomainTooLong;

        if (std.Io.net.Ip4Address.parse(self.host, self.port)) |address| {
            return encodeIp(output, address_type_ipv4, &address.bytes, self.port);
        } else |_| {}

        if (std.Io.net.Ip6Address.parse(self.host, self.port)) |address| {
            return encodeIp(output, address_type_ipv6, &address.bytes, self.port);
        } else |_| {}

        return self.encodeDomain(output);
    }

    fn encodeDomain(self: Address, output: []u8) EncodeError!usize {
        const host_start: usize = 2;
        const host_end = std.math.add(usize, host_start, self.host.len) catch
            return error.LengthOverflow;
        const encoded_size = std.math.add(usize, host_end, port_size) catch
            return error.LengthOverflow;
        if (encoded_size > encoded_size_max) return error.LengthOverflow;
        if (output.len < encoded_size) return error.OutputTooSmall;

        copyAliased(output[host_start..host_end], self.host);
        output[0] = address_type_domain;
        output[1] = @intCast(self.host.len);
        std.mem.writeInt(u16, output[host_end..encoded_size][0..port_size], self.port, .big);
        return encoded_size;
    }
};

/// Parses one SOCKS address while allowing unrelated payload bytes to follow it.
pub fn parse(input: []const u8) ParseError!Parsed {
    if (input.len == 0) return error.MissingAddressType;

    return switch (input[0]) {
        address_type_ipv4 => parseIpv4(input),
        address_type_domain => parseDomain(input),
        address_type_ipv6 => parseIpv6(input),
        else => error.UnknownAddressType,
    };
}

fn encodeIp(
    output: []u8,
    address_type: u8,
    address: []const u8,
    port: u16,
) EncodeError!usize {
    const host_start: usize = 1;
    const host_end = std.math.add(usize, host_start, address.len) catch
        return error.LengthOverflow;
    const encoded_size = std.math.add(usize, host_end, port_size) catch
        return error.LengthOverflow;
    if (encoded_size > encoded_size_max) return error.LengthOverflow;
    if (output.len < encoded_size) return error.OutputTooSmall;

    output[0] = address_type;
    @memcpy(output[host_start..host_end], address);
    std.mem.writeInt(u16, output[host_end..encoded_size][0..port_size], port, .big);
    return encoded_size;
}

fn parseIpv4(input: []const u8) ParseError!Parsed {
    const host_start: usize = 1;
    const host_end = std.math.add(usize, host_start, ipv4_size) catch
        return error.LengthOverflow;
    if (input.len < host_end) return error.TruncatedHost;
    const port_end = std.math.add(usize, host_end, port_size) catch
        return error.LengthOverflow;
    if (input.len < port_end) return error.TruncatedPort;

    return .{
        .raw = input[0..port_end],
        .host = .{ .ipv4 = input[host_start..host_end][0..ipv4_size].* },
        .port = std.mem.readInt(u16, input[host_end..port_end][0..port_size], .big),
        .consumed = port_end,
    };
}

fn parseDomain(input: []const u8) ParseError!Parsed {
    const host_start: usize = 2;
    if (input.len < host_start) return error.MissingDomainLength;
    const host_size = input[1];
    if (host_size == 0) return error.EmptyDomain;

    const host_end = std.math.add(usize, host_start, host_size) catch
        return error.LengthOverflow;
    if (input.len < host_end) return error.TruncatedHost;
    const port_end = std.math.add(usize, host_end, port_size) catch
        return error.LengthOverflow;
    if (input.len < port_end) return error.TruncatedPort;

    return .{
        .raw = input[0..port_end],
        .host = .{ .domain = input[host_start..host_end] },
        .port = std.mem.readInt(u16, input[host_end..port_end][0..port_size], .big),
        .consumed = port_end,
    };
}

fn parseIpv6(input: []const u8) ParseError!Parsed {
    const host_start: usize = 1;
    const host_end = std.math.add(usize, host_start, ipv6_size) catch
        return error.LengthOverflow;
    if (input.len < host_end) return error.TruncatedHost;
    const port_end = std.math.add(usize, host_end, port_size) catch
        return error.LengthOverflow;
    if (input.len < port_end) return error.TruncatedPort;

    return .{
        .raw = input[0..port_end],
        .host = .{ .ipv6 = input[host_start..host_end][0..ipv6_size].* },
        .port = std.mem.readInt(u16, input[host_end..port_end][0..port_size], .big),
        .consumed = port_end,
    };
}

fn copyAliased(destination: []u8, source: []const u8) void {
    if (destination.len == 0) return;
    if (@intFromPtr(destination.ptr) < @intFromPtr(source.ptr)) {
        std.mem.copyForwards(u8, destination, source);
    } else if (@intFromPtr(destination.ptr) > @intFromPtr(source.ptr)) {
        std.mem.copyBackwards(u8, destination, source);
    }
}

fn expectExactAndShortOutput(
    comptime host: []const u8,
    port: u16,
    comptime expected: []const u8,
) !void {
    var exact: [expected.len]u8 = undefined;
    const encoded_size = try (Address{ .host = host, .port = port }).encode(&exact);
    try std.testing.expectEqual(expected.len, encoded_size);
    try std.testing.expectEqualSlices(u8, expected, &exact);

    var short: [expected.len - 1]u8 = @splat(0xa5);
    const unchanged = short;
    try std.testing.expectError(
        error.OutputTooSmall,
        (Address{ .host = host, .port = port }).encode(&short),
    );
    try std.testing.expectEqualSlices(u8, &unchanged, &short);
}

fn expectEveryTruncation(
    encoded: []const u8,
    host_start: usize,
    host_end: usize,
) !void {
    try std.testing.expect(encoded.len <= encoded_size_max);
    try std.testing.expectEqual(host_end + 2, encoded.len);

    for (0..encoded.len) |end| {
        const expected_error: anyerror = if (end == 0)
            error.MissingAddressType
        else if (end < host_start)
            error.MissingDomainLength
        else if (end < host_end)
            error.TruncatedHost
        else
            error.TruncatedPort;
        try std.testing.expectError(expected_error, parse(encoded[0..end]));
    }
}

test "Address encodes and parse views an IPv4 address" {
    // The literal vector fixes ATYP, network-order address bytes, and the parsed view.
    const expected = [_]u8{ 0x01, 192, 0, 2, 1, 0x20, 0xfb };
    var output: [expected.len]u8 = undefined;

    const encoded_size = try (Address{
        .host = "192.0.2.1",
        .port = 8443,
    }).encode(&output);
    try std.testing.expectEqual(expected.len, encoded_size);
    try std.testing.expectEqualSlices(u8, &expected, &output);

    const parsed = try parse(&output);
    try std.testing.expectEqualSlices(u8, &expected, parsed.raw);
    try std.testing.expectEqual(expected.len, parsed.consumed);
    try std.testing.expectEqual(@as(u16, 8443), parsed.port);
    switch (parsed.host) {
        .ipv4 => |host| try std.testing.expectEqual([4]u8{ 192, 0, 2, 1 }, host),
        else => return error.UnexpectedHostType,
    }
}

test "Address encodes and parse views a domain address" {
    // A domain view excludes its length prefix while raw retains the complete address.
    const expected = "\x03\x0bexample.com\x00\x35";
    var output: [expected.len]u8 = undefined;

    const encoded_size = try (Address{
        .host = "example.com",
        .port = 53,
    }).encode(&output);
    try std.testing.expectEqual(expected.len, encoded_size);
    try std.testing.expectEqualStrings(expected, &output);

    const parsed = try parse(&output);
    try std.testing.expectEqualStrings(expected, parsed.raw);
    try std.testing.expectEqual(expected.len, parsed.consumed);
    try std.testing.expectEqual(@as(u16, 53), parsed.port);
    switch (parsed.host) {
        .domain => |host| try std.testing.expectEqualStrings("example.com", host),
        else => return error.UnexpectedHostType,
    }
}

test "Address encodes and parse views an IPv6 address" {
    // The compressed text must become the RFC 1928 sixteen-byte IPv6 representation.
    const expected = [_]u8{
        0x04,
        0x20,
        0x01,
        0x0d,
        0xb8,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x01,
        0xbb,
    };
    var output: [expected.len]u8 = undefined;

    const encoded_size = try (Address{
        .host = "2001:db8::1",
        .port = 443,
    }).encode(&output);
    try std.testing.expectEqual(expected.len, encoded_size);
    try std.testing.expectEqualSlices(u8, &expected, &output);

    const parsed = try parse(&output);
    try std.testing.expectEqualSlices(u8, &expected, parsed.raw);
    try std.testing.expectEqual(expected.len, parsed.consumed);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    switch (parsed.host) {
        .ipv6 => |host| try std.testing.expectEqual([16]u8{
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        }, host),
        else => return error.UnexpectedHostType,
    }
}

test "Address accepts a 255-byte domain at the encoded maximum" {
    // The largest legal domain must occupy the complete 259-byte address budget.
    const host = [_]u8{'d'} ** 255;
    var output: [encoded_size_max]u8 = undefined;

    const encoded_size = try (Address{ .host = &host, .port = 65535 }).encode(&output);
    try std.testing.expectEqual(@as(usize, 259), encoded_size);
    try std.testing.expectEqual(@as(u8, 0x03), output[0]);
    try std.testing.expectEqual(@as(u8, 255), output[1]);
    try std.testing.expectEqual(@as(u8, 0xff), output[257]);
    try std.testing.expectEqual(@as(u8, 0xff), output[258]);

    const parsed = try parse(&output);
    try std.testing.expectEqual(encoded_size_max, parsed.consumed);
    try std.testing.expectEqual(@as(u16, 65535), parsed.port);
    switch (parsed.host) {
        .domain => |parsed_host| try std.testing.expectEqualSlices(u8, &host, parsed_host),
        else => return error.UnexpectedHostType,
    }
}

test "Address rejects empty and 256-byte domains" {
    // Domain bounds are validated before a length cast or output mutation can occur.
    const overlong_host = [_]u8{'x'} ** 256;
    var output: [encoded_size_max]u8 = @splat(0xa5);

    try std.testing.expectError(
        error.EmptyDomain,
        (Address{ .host = "", .port = 1 }).encode(&output),
    );
    try std.testing.expectError(
        error.DomainTooLong,
        (Address{ .host = &overlong_host, .port = 1 }).encode(&output),
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0xa5} ** encoded_size_max),
        &output,
    );
}

test "Address accepts exact output and atomically rejects one byte short" {
    // Every address kind validates total capacity before writing the first byte.
    try expectExactAndShortOutput(
        "203.0.113.9",
        0x1234,
        "\x01\xcb\x00\x71\x09\x12\x34",
    );
    try expectExactAndShortOutput(
        "example.org",
        0x1234,
        "\x03\x0bexample.org\x12\x34",
    );
    try expectExactAndShortOutput(
        "2001:db8::2",
        0x1234,
        "\x04\x20\x01\x0d\xb8\x00\x00\x00\x00" ++
            "\x00\x00\x00\x00\x00\x00\x00\x02\x12\x34",
    );
}

test "parse rejects unknown ATYP and an empty domain" {
    // Invalid discriminants and forbidden zero-length domains have distinct errors.
    try std.testing.expectError(error.UnknownAddressType, parse("\x02"));
    try std.testing.expectError(error.EmptyDomain, parse("\x03\x00\x00\x50"));
}

test "parse returns typed errors at every IPv4 truncation point" {
    // Every strict prefix of a valid IPv4 address must fail without a slice panic.
    try expectEveryTruncation("\x01\xc0\x00\x02\x01\x01\xbb", 1, 5);
}

test "parse returns typed errors at every domain truncation point" {
    // Every strict prefix includes the missing length, host, and port boundaries.
    try expectEveryTruncation("\x03\x03api\x01\xbb", 2, 5);
}

test "parse returns typed errors at every IPv6 truncation point" {
    // Every strict prefix of the longest fixed-width host remains a recoverable error.
    try expectEveryTruncation(
        "\x04\x20\x01\x0d\xb8\x00\x00\x00\x00" ++
            "\x00\x00\x00\x00\x00\x00\x00\x01\x01\xbb",
        1,
        17,
    );
}

test "parse consumes only the address before trailing payload" {
    // Datagram payload remains outside both raw and consumed address views.
    const input = "\x03\x03api\x01\xbbpayload";
    const expected_raw = "\x03\x03api\x01\xbb";

    const parsed = try parse(input);
    try std.testing.expectEqualStrings(expected_raw, parsed.raw);
    try std.testing.expectEqual(expected_raw.len, parsed.consumed);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    switch (parsed.host) {
        .domain => |host| try std.testing.expectEqualStrings("api", host),
        else => return error.UnexpectedHostType,
    }
}

test "Address ports use big-endian wire order" {
    // Independent encode and parse literals catch accidental native-endian handling.
    var output: [5]u8 = undefined;
    _ = try (Address{ .host = "a", .port = 0x1234 }).encode(&output);
    try std.testing.expectEqualStrings("\x03\x01a\x12\x34", &output);

    const parsed = try parse("\x03\x01a\xab\xcd");
    try std.testing.expectEqual(@as(u16, 0xabcd), parsed.port);
}
