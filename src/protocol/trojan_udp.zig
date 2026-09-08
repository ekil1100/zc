const std = @import("std");
const socks_address = @import("socks_address.zig");

pub const payload_size_max: usize = std.math.maxInt(u16);
pub const frame_size_max: usize =
    socks_address.encoded_size_max + @sizeOf(u16) + 2 + payload_size_max;

comptime {
    std.debug.assert(socks_address.encoded_size_max == 259);
    std.debug.assert(frame_size_max == 65_798);
}

pub const Datagram = struct {
    address: socks_address.Parsed,
    payload: []const u8,
    consumed_byte_count: usize,
};

pub const DecodeResult = union(enum) {
    need_more,
    datagram: Datagram,
};

pub const EncodeError = error{
    InvalidAddress,
    InvalidPort,
    DatagramTooLarge,
    OutputTooSmall,
};

pub const DecodeError = error{
    UnknownAddressType,
    EmptyDomain,
    LengthOverflow,
    InvalidPort,
    InvalidCRLF,
};

/// Encodes one Trojan UDP frame. Every check happens before output mutation.
pub fn encode(
    destination: socks_address.Parsed,
    payload: []const u8,
    output: []u8,
) EncodeError![]u8 {
    if (!parsedAddressIsExact(destination)) return error.InvalidAddress;
    if (destination.port == 0) return error.InvalidPort;
    if (payload.len > payload_size_max) return error.DatagramTooLarge;

    const length_offset = destination.raw.len;
    const crlf_offset = std.math.add(
        usize,
        length_offset,
        @sizeOf(u16),
    ) catch return error.DatagramTooLarge;
    const payload_offset = std.math.add(
        usize,
        crlf_offset,
        2,
    ) catch return error.DatagramTooLarge;
    const frame_size = std.math.add(
        usize,
        payload_offset,
        payload.len,
    ) catch return error.DatagramTooLarge;
    if (frame_size > frame_size_max) return error.DatagramTooLarge;
    if (output.len < frame_size) return error.OutputTooSmall;

    @memcpy(output[0..length_offset], destination.raw);
    std.mem.writeInt(
        u16,
        output[length_offset..crlf_offset][0..2],
        @intCast(payload.len),
        .big,
    );
    output[crlf_offset] = '\r';
    output[crlf_offset + 1] = '\n';
    @memcpy(output[payload_offset..frame_size], payload);
    return output[0..frame_size];
}

/// Decodes at most one frame from a stream prefix. A complete frame returns a
/// borrowed view plus the exact byte count so callers can retain a following
/// coalesced frame. Truncated prefixes are never treated as malformed.
pub fn decode(input: []const u8) DecodeError!DecodeResult {
    const address = socks_address.parse(input) catch |err| switch (err) {
        error.MissingAddressType,
        error.MissingDomainLength,
        error.TruncatedHost,
        error.TruncatedPort,
        => return .need_more,
        error.UnknownAddressType => return error.UnknownAddressType,
        error.EmptyDomain => return error.EmptyDomain,
        error.LengthOverflow => return error.LengthOverflow,
    };
    if (address.port == 0) return error.InvalidPort;

    const length_offset = address.consumed;
    const crlf_offset = std.math.add(
        usize,
        length_offset,
        @sizeOf(u16),
    ) catch return error.LengthOverflow;
    const payload_offset = std.math.add(
        usize,
        crlf_offset,
        2,
    ) catch return error.LengthOverflow;
    if (input.len < payload_offset) return .need_more;
    if (input[crlf_offset] != '\r') return error.InvalidCRLF;
    if (input[crlf_offset + 1] != '\n') return error.InvalidCRLF;

    const payload_size = std.mem.readInt(
        u16,
        input[length_offset..crlf_offset][0..2],
        .big,
    );
    const frame_size = std.math.add(
        usize,
        payload_offset,
        payload_size,
    ) catch return error.LengthOverflow;
    if (frame_size > frame_size_max) return error.LengthOverflow;
    if (input.len < frame_size) return .need_more;

    return .{ .datagram = .{
        .address = address,
        .payload = input[payload_offset..frame_size],
        .consumed_byte_count = frame_size,
    } };
}

/// Fixed-capacity stream accumulator. Returned datagram views stay valid until
/// the next writable() call or decoder destruction.
pub const Decoder = struct {
    storage: [frame_size_max]u8 = undefined,
    start_byte_index: usize = 0,
    end_byte_index: usize = 0,

    fn assertValid(self: *const Decoder) void {
        std.debug.assert(self.start_byte_index <= self.end_byte_index);
        std.debug.assert(self.end_byte_index <= self.storage.len);
    }

    pub fn writable(self: *Decoder) []u8 {
        self.assertValid();
        if (self.start_byte_index > 0) {
            const remaining_byte_count = self.end_byte_index - self.start_byte_index;
            std.mem.copyForwards(
                u8,
                self.storage[0..remaining_byte_count],
                self.storage[self.start_byte_index..self.end_byte_index],
            );
            self.start_byte_index = 0;
            self.end_byte_index = remaining_byte_count;
        }
        self.assertValid();
        return self.storage[self.end_byte_index..];
    }

    pub fn commit(self: *Decoder, byte_count: usize) void {
        self.assertValid();
        std.debug.assert(byte_count <= self.storage.len - self.end_byte_index);
        self.end_byte_index += byte_count;
        self.assertValid();
    }

    pub fn next(self: *Decoder) DecodeError!DecodeResult {
        self.assertValid();
        const result = try decode(self.storage[self.start_byte_index..self.end_byte_index]);
        switch (result) {
            .need_more => {},
            .datagram => |datagram| {
                self.start_byte_index += datagram.consumed_byte_count;
                self.assertValid();
            },
        }
        self.assertValid();
        return result;
    }

    pub fn hasComplete(self: *const Decoder) bool {
        self.assertValid();
        const buffered = self.storage[self.start_byte_index..self.end_byte_index];
        const result = decode(buffered) catch return true;
        return result == .datagram;
    }

    pub fn finish(self: *const Decoder) !void {
        self.assertValid();
        if (self.start_byte_index != self.end_byte_index) return error.TruncatedFrame;
    }
};

fn parsedAddressIsExact(destination: socks_address.Parsed) bool {
    if (destination.raw.len == 0) return false;
    if (destination.raw.len > socks_address.encoded_size_max) return false;
    if (destination.consumed != destination.raw.len) return false;

    const reparsed = socks_address.parse(destination.raw) catch return false;
    if (reparsed.consumed != destination.raw.len) return false;
    if (reparsed.port != destination.port) return false;
    return switch (reparsed.host) {
        .ipv4 => |host| switch (destination.host) {
            .ipv4 => |expected| std.mem.eql(u8, &host, &expected),
            else => false,
        },
        .domain => |host| switch (destination.host) {
            .domain => |expected| std.mem.eql(u8, host, expected),
            else => false,
        },
        .ipv6 => |host| switch (destination.host) {
            .ipv6 => |expected| std.mem.eql(u8, &host, &expected),
            else => false,
        },
    };
}

test "Trojan UDP IPv4 frame matches the official wire format" {
    // Encode or decode focused wire fixtures and compare the observable Trojan UDP frames.
    const expected =
        "\x01\xc0\x00\x02\x01\x00\x35" ++
        "\x00\x03\r\nabc";
    const destination = try socks_address.parse(expected[0..7]);
    var output: [64]u8 = undefined;

    const encoded = try encode(destination, "abc", &output);
    try std.testing.expectEqualStrings(expected, encoded);

    const decoded = try decode(encoded);
    switch (decoded) {
        .datagram => |datagram| {
            try std.testing.expectEqualStrings(destination.raw, datagram.address.raw);
            try std.testing.expectEqualStrings("abc", datagram.payload);
            try std.testing.expectEqual(expected.len, datagram.consumed_byte_count);
        },
        .need_more => return error.ExpectedDatagram,
    }
}

test "Trojan UDP frames preserve domain IPv6 empty and maximum payloads" {
    // Encode or decode focused wire fixtures and compare the observable Trojan UDP frames.
    const domain_address = "\x03\x0bexample.com\x01\xbb";
    const ipv6_address =
        "\x04\x20\x01\x0d\xb8\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x01\x14\xe9";
    var output: [frame_size_max]u8 = undefined;

    for ([_][]const u8{ domain_address, ipv6_address }) |address_bytes| {
        const address = try socks_address.parse(address_bytes);
        const empty_frame = try encode(address, "", &output);
        const decoded_empty = try decode(empty_frame);
        switch (decoded_empty) {
            .datagram => |datagram| {
                try std.testing.expectEqual(@as(usize, 0), datagram.payload.len);
                try std.testing.expectEqualStrings(address_bytes, datagram.address.raw);
            },
            .need_more => return error.ExpectedDatagram,
        }
    }

    const address = try socks_address.parse(domain_address);
    var payload: [payload_size_max]u8 = undefined;
    @memset(&payload, 0xa5);
    const maximum_frame = try encode(address, &payload, &output);
    const decoded_maximum = try decode(maximum_frame);
    switch (decoded_maximum) {
        .datagram => |datagram| {
            try std.testing.expectEqual(payload.len, datagram.payload.len);
            try std.testing.expectEqualSlices(u8, &payload, datagram.payload);
        },
        .need_more => return error.ExpectedDatagram,
    }
}

test "Trojan UDP decoder waits at every truncated frame boundary" {
    // Encode or decode focused wire fixtures and compare the observable Trojan UDP frames.
    const full_frame =
        "\x03\x0bexample.com\x00\x35" ++
        "\x00\x07\r\npayload";
    for (0..full_frame.len) |end| {
        const result = try decode(full_frame[0..end]);
        try std.testing.expect(result == .need_more);
    }
    const complete = try decode(full_frame);
    try std.testing.expect(complete == .datagram);
}

test "Trojan UDP stream decoder preserves fragmented and coalesced frames" {
    // Encode or decode focused wire fixtures and compare the observable Trojan UDP frames.
    const first = "\x01\x7f\x00\x00\x01\x00\x35\x00\x01\r\na";
    const second = "\x03\x0bexample.com\x01\xbb\x00\x01\r\nb";
    const combined = first ++ second;
    var decoder: Decoder = .{};

    for (combined) |byte| {
        try std.testing.expect(!decoder.hasComplete());
        const writable_bytes = decoder.writable();
        writable_bytes[0] = byte;
        decoder.commit(1);
        if (decoder.hasComplete()) break;
    }
    const first_result = try decoder.next();
    switch (first_result) {
        .datagram => |datagram| try std.testing.expectEqualStrings(
            "a",
            datagram.payload,
        ),
        .need_more => return error.ExpectedDatagram,
    }

    const first_frame_byte_count = first.len;
    const writable_bytes = decoder.writable();
    const remaining_byte_count = combined.len - first_frame_byte_count;
    @memcpy(
        writable_bytes[0..remaining_byte_count],
        combined[first_frame_byte_count..],
    );
    decoder.commit(combined.len - first_frame_byte_count);
    const second_result = try decoder.next();
    switch (second_result) {
        .datagram => |datagram| try std.testing.expectEqualStrings(
            "b",
            datagram.payload,
        ),
        .need_more => return error.ExpectedDatagram,
    }
    try decoder.finish();
}

test "Trojan UDP stream decoder rejects EOF inside a frame" {
    // Encode or decode focused wire fixtures and compare the observable Trojan UDP frames.
    var decoder: Decoder = .{};
    const partial = "\x01\x7f\x00\x00\x01\x00\x35\x00\x03\r\nab";
    const writable_bytes = decoder.writable();
    @memcpy(writable_bytes[0..partial.len], partial);
    decoder.commit(partial.len);
    try std.testing.expect((try decoder.next()) == .need_more);
    try std.testing.expectError(error.TruncatedFrame, decoder.finish());
}

test "Trojan UDP codec rejects malformed and non-operational frames" {
    // Encode or decode focused wire fixtures and compare the observable Trojan UDP frames.
    const address_bytes = "\x01\x7f\x00\x00\x01\x00\x35";
    const address = try socks_address.parse(address_bytes);
    var output: [64]u8 = @splat(0xa5);
    const unchanged = output;

    try std.testing.expectError(
        error.OutputTooSmall,
        encode(address, "abc", output[0..12]),
    );
    try std.testing.expectEqualSlices(u8, &unchanged, &output);
    try std.testing.expectError(
        error.InvalidCRLF,
        decode(address_bytes ++ "\x00\x01xxa"),
    );
    try std.testing.expectError(error.UnknownAddressType, decode("\x02"));

    const port_zero = try socks_address.parse("\x01\x7f\x00\x00\x01\x00\x00");
    try std.testing.expectError(error.InvalidPort, encode(port_zero, "a", &output));
    try std.testing.expectError(
        error.InvalidPort,
        decode("\x01\x7f\x00\x00\x01\x00\x00\x00\x01\r\na"),
    );
}
