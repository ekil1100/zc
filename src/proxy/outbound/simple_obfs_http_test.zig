const std = @import("std");
const simple_obfs_http = @import("simple_obfs_http.zig");

const RecordingStream = struct {
    bytes: [2048]u8 = undefined,
    len: usize = 0,
    max_write: usize = std.math.maxInt(usize),

    pub fn write(self: *RecordingStream, data: []const u8) !usize {
        const count = @min(data.len, self.max_write);
        if (count == 0) return error.WriteZero;
        const end = try std.math.add(usize, self.len, count);
        if (end > self.bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len..end], data[0..count]);
        self.len = end;
        return count;
    }

    fn written(self: *const RecordingStream) []const u8 {
        return self.bytes[0..self.len];
    }
};

const fixed_entropy = simple_obfs_http.RequestEntropy{
    .curl_major = 13,
    .curl_minor = 1,
    .websocket_key = .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    },
};

test "simple-obfs HTTP request matches the v0.0.5 wire" {
    var client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 8388,
    });
    var stream = RecordingStream{ .max_write = 1 };

    try client.writeWithEntropy(&stream, "abc", fixed_entropy);

    try std.testing.expectEqualStrings(
        "GET / HTTP/1.1\r\n" ++
            "Host: www.example.com:8388\r\n" ++
            "User-Agent: curl/7.13.1\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: AAECAwQFBgcICQoLDA0ODw==\r\n" ++
            "Content-Length: 3\r\n" ++
            "\r\n" ++
            "abc",
        stream.written(),
    );
}

test "simple-obfs HTTP request sends one header then raw bytes" {
    var client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
    });
    var stream = RecordingStream{};

    // An empty first write must not consume the one-shot request stage.
    try client.writeWithEntropy(&stream, "", fixed_entropy);
    try std.testing.expectEqual(@as(usize, 0), stream.len);

    try client.writeWithEntropy(&stream, "first", fixed_entropy);
    try client.writeWithEntropy(&stream, "second", fixed_entropy);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stream.written(), "GET / HTTP/1.1"));
    try std.testing.expect(std.mem.indexOf(u8, stream.written(), "Host: www.example.com\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, stream.written(), "firstsecond"));
}

test "simple-obfs HTTP request rejects unsafe or oversized hosts" {
    try std.testing.expectError(
        error.InvalidObfsHost,
        simple_obfs_http.Client.init(.{ .host = "", .server_port = 80 }),
    );
    try std.testing.expectError(
        error.InvalidObfsHost,
        simple_obfs_http.Client.init(.{ .host = "safe.example\r\nInjected: yes", .server_port = 80 }),
    );
    const oversized = [_]u8{'a'} ** (simple_obfs_http.host_max + 1);
    try std.testing.expectError(
        error.ObfsHostTooLong,
        simple_obfs_http.Client.init(.{ .host = &oversized, .server_port = 80 }),
    );
}

const ChunkedStream = struct {
    input: []const u8,
    limits: []const usize,
    offset: usize = 0,
    limit_index: usize = 0,
    read_calls: usize = 0,

    pub fn read(self: *ChunkedStream, output: []u8) !usize {
        self.read_calls += 1;
        if (self.limit_index < self.limits.len) {
            const limit = self.limits[self.limit_index];
            self.limit_index += 1;
            if (limit == 0) return error.WouldBlock;
            return self.copyInput(output, limit);
        }
        return self.copyInput(output, output.len);
    }

    fn copyInput(self: *ChunkedStream, output: []u8, limit: usize) usize {
        const remaining = self.input.len - self.offset;
        const count = @min(remaining, @min(output.len, limit));
        @memcpy(output[0..count], self.input[self.offset .. self.offset + count]);
        self.offset += count;
        return count;
    }
};

const response_header =
    "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "\r\n";

fn readPayload(
    client: *simple_obfs_http.Client,
    stream: *ChunkedStream,
    output: []u8,
) !usize {
    var attempts: usize = 0;
    while (attempts < simple_obfs_http.response_header_max + 4) : (attempts += 1) {
        return client.read(stream, output) catch |err| {
            if (err == error.NeedMoreData) continue;
            return err;
        };
    }
    return error.TestExpectedPayload;
}

test "simple-obfs HTTP response accepts every header split" {
    const wire = response_header ++ "salt-and-ciphertext";
    var split: usize = 1;
    while (split <= response_header.len) : (split += 1) {
        var client = try simple_obfs_http.Client.init(.{
            .host = "www.example.com",
            .server_port = 80,
        });
        const limits = [_]usize{ split, wire.len - split };
        var stream = ChunkedStream{ .input = wire, .limits = &limits };
        var output: [64]u8 = undefined;

        const count = try readPayload(&client, &stream, &output);
        try std.testing.expectEqualStrings("salt-and-ciphertext", output[0..count]);
    }
}

test "simple-obfs HTTP response resumes bytewise and after WouldBlock" {
    const wire = response_header ++ "raw";
    var limits: [wire.len + 1]usize = undefined;
    @memset(&limits, 1);
    limits[17] = 0;

    var client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
    });
    var stream = ChunkedStream{ .input = wire, .limits = &limits };
    var output: [16]u8 = undefined;
    var output_len: usize = 0;
    var saw_kernel_would_block = false;
    while (output_len < 3) {
        const count = client.read(&stream, output[output_len..]) catch |err| {
            if (err == error.NeedMoreData) continue;
            if (err == error.WouldBlock) {
                try std.testing.expect(!saw_kernel_would_block);
                saw_kernel_would_block = true;
                continue;
            }
            return err;
        };
        output_len += count;
    }
    try std.testing.expect(saw_kernel_would_block);
    try std.testing.expectEqualStrings("raw", output[0..output_len]);
}

test "simple-obfs HTTP response retains same-read tail" {
    const wire = response_header ++ "abcdef";
    var stream = ChunkedStream{ .input = wire, .limits = &.{} };
    var client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
    });
    var output: [2]u8 = undefined;

    const first = try client.read(&stream, &output);
    try std.testing.expectEqualStrings("ab", output[0..first]);
    try std.testing.expect(client.hasPendingRead());
    const reads_after_header = stream.read_calls;

    const second = try client.read(&stream, &output);
    try std.testing.expectEqualStrings("cd", output[0..second]);
    try std.testing.expect(client.hasPendingRead());
    const third = try client.read(&stream, &output);
    try std.testing.expectEqualStrings("ef", output[0..third]);
    try std.testing.expect(!client.hasPendingRead());
    try std.testing.expectEqual(reads_after_header, stream.read_calls);
}

test "simple-obfs HTTP response accepts 8192 header bytes" {
    var wire: [simple_obfs_http.response_header_max + 1]u8 = undefined;
    const prefix = "HTTP/1.1 101 Switching Protocols\r\nX-Fill: ";
    @memcpy(wire[0..prefix.len], prefix);
    @memset(wire[prefix.len .. simple_obfs_http.response_header_max - 4], 'a');
    @memcpy(wire[simple_obfs_http.response_header_max - 4 .. simple_obfs_http.response_header_max], "\r\n\r\n");
    wire[simple_obfs_http.response_header_max] = 'x';

    const limits = [_]usize{ simple_obfs_http.response_header_max, 1 };
    var stream = ChunkedStream{ .input = &wire, .limits = &limits };
    var client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
    });
    var output: [1]u8 = undefined;

    try std.testing.expectError(error.NeedMoreData, client.read(&stream, &output));
    const count = try client.read(&stream, &output);
    try std.testing.expectEqualStrings("x", output[0..count]);
}

test "simple-obfs HTTP response rejects 8193 header bytes" {
    var wire: [simple_obfs_http.response_header_max + 1]u8 = undefined;
    const prefix = "HTTP/1.1 101 Switching Protocols\r\nX-Fill: ";
    @memcpy(wire[0..prefix.len], prefix);
    @memset(wire[prefix.len .. wire.len - 4], 'a');
    @memcpy(wire[wire.len - 4 ..], "\r\n\r\n");

    var stream = ChunkedStream{ .input = &wire, .limits = &.{} };
    var client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
    });
    var output: [1]u8 = undefined;

    try std.testing.expectError(
        error.ObfsResponseTooLarge,
        client.read(&stream, &output),
    );
}

test "simple-obfs HTTP response rejects non-101 and incomplete EOF" {
    var bad_status_stream = ChunkedStream{
        .input = "HTTP/1.1 200 OK\r\n\r\nraw",
        .limits = &.{},
    };
    var bad_status_client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
    });
    var output: [16]u8 = undefined;
    try std.testing.expectError(
        error.InvalidObfsResponseStatus,
        bad_status_client.read(&bad_status_stream, &output),
    );

    var eof_stream = ChunkedStream{
        .input = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n",
        .limits = &.{},
    };
    var eof_client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
    });
    try std.testing.expectError(error.NeedMoreData, eof_client.read(&eof_stream, &output));
    try std.testing.expectError(
        error.ObfsResponseUnexpectedEof,
        eof_client.read(&eof_stream, &output),
    );
}

const WouldBlockStream = struct {
    pub fn read(_: *WouldBlockStream, _: []u8) !usize {
        return error.WouldBlock;
    }
};

test "simple-obfs HTTP response deadline uses explicit monotonic time" {
    var client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
    });
    var request_stream = RecordingStream{};
    try client.writeWithEntropyAt(
        &request_stream,
        "first-payload",
        fixed_entropy,
        1_000,
    );

    try std.testing.expectEqual(
        @as(?i32, 10_000),
        client.responseDeadlineRemainingMsAt(1_000),
    );
    try std.testing.expectEqual(
        @as(?i32, 1),
        client.responseDeadlineRemainingMsAt(10_999),
    );
    try std.testing.expect(!client.responseDeadlineExpiredAt(10_999));
    try std.testing.expect(client.responseDeadlineExpiredAt(11_000));

    var blocked = WouldBlockStream{};
    var output: [1]u8 = undefined;
    try std.testing.expectError(
        error.WouldBlock,
        client.readAt(&blocked, &output, 10_999),
    );
    try std.testing.expectError(
        error.ObfsResponseTimeout,
        client.readAt(&blocked, &output, 11_000),
    );
}

test "simple-obfs HTTP response completion clears its deadline" {
    var client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
    });
    var request_stream = RecordingStream{};
    try client.writeWithEntropyAt(
        &request_stream,
        "first-payload",
        fixed_entropy,
        1_000,
    );

    const wire = response_header ++ "x";
    var response_stream = ChunkedStream{ .input = wire, .limits = &.{} };
    var output: [1]u8 = undefined;
    const count = try client.readAt(&response_stream, &output, 1_001);
    try std.testing.expectEqualStrings("x", output[0..count]);
    try std.testing.expectEqual(
        @as(?i32, null),
        client.responseDeadlineRemainingMsAt(20_000),
    );
    try std.testing.expect(!client.responseDeadlineExpiredAt(20_000));
}

const PartialThenErrorStream = struct {
    bytes: [32]u8 = undefined,
    len: usize = 0,
    calls: usize = 0,

    pub fn write(self: *PartialThenErrorStream, data: []const u8) !usize {
        self.calls += 1;
        if (self.calls > 1) return error.InjectedWriteFailure;
        const count = @min(@as(usize, 5), data.len);
        @memcpy(self.bytes[0..count], data[0..count]);
        self.len = count;
        return count;
    }
};

test "simple-obfs HTTP request is poisoned after a partial write error" {
    var client = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
    });
    var stream = PartialThenErrorStream{};

    try std.testing.expectError(
        error.InjectedWriteFailure,
        client.writeWithEntropyAt(
            &stream,
            "first-payload",
            fixed_entropy,
            1_000,
        ),
    );
    const bytes_after_failure = stream.len;
    const calls_after_failure = stream.calls;
    try std.testing.expectEqualStrings("GET /", stream.bytes[0..stream.len]);

    try std.testing.expectError(
        error.ObfsRequestPoisoned,
        client.writeWithEntropyAt(
            &stream,
            "first-payload",
            fixed_entropy,
            1_001,
        ),
    );
    try std.testing.expectEqual(bytes_after_failure, stream.len);
    try std.testing.expectEqual(calls_after_failure, stream.calls);
    try std.testing.expectEqual(
        @as(?i32, null),
        client.responseDeadlineRemainingMsAt(1_001),
    );
}

test "simple-obfs HTTP response timeout config only permits shortening" {
    var shortened = try simple_obfs_http.Client.init(.{
        .host = "www.example.com",
        .server_port = 80,
        .response_timeout_ms = 50,
    });
    var stream = RecordingStream{};
    try shortened.writeWithEntropyAt(
        &stream,
        "first-payload",
        fixed_entropy,
        1_000,
    );
    try std.testing.expectEqual(
        @as(?i32, 50),
        shortened.responseDeadlineRemainingMsAt(1_000),
    );

    try std.testing.expectError(
        error.InvalidObfsResponseTimeout,
        simple_obfs_http.Client.init(.{
            .host = "www.example.com",
            .server_port = 80,
            .response_timeout_ms = 0,
        }),
    );
    try std.testing.expectError(
        error.InvalidObfsResponseTimeout,
        simple_obfs_http.Client.init(.{
            .host = "www.example.com",
            .server_port = 80,
            .response_timeout_ms = 10_001,
        }),
    );
}
