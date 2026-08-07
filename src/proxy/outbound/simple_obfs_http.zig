const std = @import("std");
const compat = @import("../../compat.zig");

pub const host_max: usize = 255;
pub const request_header_max: usize = 1024;
pub const response_header_max: usize = 8192;
pub const response_timeout_default_ms: i64 = 10_000;
pub const response_timeout_max_ms: i64 = response_timeout_default_ms;
pub const response_timeout_ms: i64 = response_timeout_default_ms;

pub const Config = struct {
    host: []const u8,
    server_port: u16,
    response_timeout_ms: i64 = response_timeout_default_ms,
};

pub const RequestEntropy = struct {
    curl_major: u8,
    curl_minor: u8,
    websocket_key: [16]u8,
};

const RequestState = enum {
    header,
    raw,
    poisoned,
};

const ResponseState = enum {
    header,
    raw,
};

pub const Client = struct {
    host: [host_max]u8 = undefined,
    host_len: usize,
    server_port: u16,
    request_state: RequestState = .header,
    response_state: ResponseState = .header,
    response_bytes: [response_header_max]u8 = undefined,
    response_len: usize = 0,
    tail_start: usize = 0,
    tail_end: usize = 0,
    response_deadline_ms: ?i64 = null,
    response_timeout_ms: i64,

    pub fn init(config: Config) !Client {
        if (config.host.len == 0) return error.InvalidObfsHost;
        if (config.host.len > host_max) return error.ObfsHostTooLong;
        if (config.response_timeout_ms <= 0 or
            config.response_timeout_ms > response_timeout_max_ms)
        {
            return error.InvalidObfsResponseTimeout;
        }
        for (config.host) |byte| {
            if (byte == '\r' or byte == '\n' or byte == 0) {
                return error.InvalidObfsHost;
            }
        }

        var client = Client{
            .host_len = config.host.len,
            .server_port = config.server_port,
            .response_timeout_ms = config.response_timeout_ms,
        };
        @memcpy(client.host[0..config.host.len], config.host);
        return client;
    }

    pub fn write(self: *Client, stream: anytype, payload: []const u8) !void {
        if (self.request_state == .poisoned) return error.ObfsRequestPoisoned;
        if (payload.len == 0) return;
        if (self.request_state == .raw) {
            try writeAll(stream, payload);
            return;
        }

        var random: [18]u8 = undefined;
        compat.randomBytes(&random);
        const entropy = RequestEntropy{
            .curl_major = random[0] % 51,
            .curl_minor = random[1] % 2,
            .websocket_key = random[2..18].*,
        };
        const started = try self.writePayloadWithEntropy(
            stream,
            payload,
            entropy,
        );
        if (started) {
            self.startResponseDeadline(compat.monotonicMilliTimestamp());
        }
    }

    /// Deterministic request seam for fixed v0.0.5 wire vectors.
    pub fn writeWithEntropy(
        self: *Client,
        stream: anytype,
        payload: []const u8,
        entropy: RequestEntropy,
    ) !void {
        const started = try self.writePayloadWithEntropy(
            stream,
            payload,
            entropy,
        );
        if (started) {
            self.startResponseDeadline(compat.monotonicMilliTimestamp());
        }
    }

    /// Explicit-time seam: `completion_now_ms` is when the first request write
    /// completed successfully and therefore when the response deadline starts.
    pub fn writeWithEntropyAt(
        self: *Client,
        stream: anytype,
        payload: []const u8,
        entropy: RequestEntropy,
        completion_now_ms: i64,
    ) !void {
        const started = try self.writePayloadWithEntropy(
            stream,
            payload,
            entropy,
        );
        if (started) self.startResponseDeadline(completion_now_ms);
    }

    pub fn read(self: *Client, stream: anytype, output: []u8) !usize {
        try self.checkResponseDeadlineAt(compat.monotonicMilliTimestamp());
        return self.readOnce(stream, output) catch |err| {
            if (err == error.WouldBlock or err == error.NeedMoreData) {
                try self.checkResponseDeadlineAt(
                    compat.monotonicMilliTimestamp(),
                );
            }
            return err;
        };
    }

    /// Explicit-time read seam used to verify timeout boundaries without sleep.
    pub fn readAt(
        self: *Client,
        stream: anytype,
        output: []u8,
        now_ms: i64,
    ) !usize {
        try self.checkResponseDeadlineAt(now_ms);
        return self.readOnce(stream, output) catch |err| {
            if (err == error.WouldBlock or err == error.NeedMoreData) {
                try self.checkResponseDeadlineAt(now_ms);
            }
            return err;
        };
    }

    fn readOnce(self: *Client, stream: anytype, output: []u8) !usize {
        if (output.len == 0) return 0;

        if (self.response_state == .raw) {
            if (self.hasPendingRead()) return self.drainTail(output);
            return try stream.read(output);
        }

        if (self.response_len == self.response_bytes.len) {
            return error.ObfsResponseTooLarge;
        }

        const read_count = try stream.read(self.response_bytes[self.response_len..]);
        if (read_count == 0) return error.ObfsResponseUnexpectedEof;
        const new_len = std.math.add(usize, self.response_len, read_count) catch {
            return error.LengthOverflow;
        };
        if (new_len > self.response_bytes.len) return error.ObfsResponseTooLarge;
        self.response_len = new_len;

        const terminator = std.mem.indexOf(
            u8,
            self.response_bytes[0..self.response_len],
            "\r\n\r\n",
        );
        if (terminator) |terminator_start| {
            const header_end = std.math.add(usize, terminator_start, 4) catch {
                return error.LengthOverflow;
            };
            try validateResponseStatus(self.response_bytes[0..header_end]);
            self.response_state = .raw;
            self.response_deadline_ms = null;
            self.tail_start = header_end;
            self.tail_end = self.response_len;
            if (self.hasPendingRead()) return self.drainTail(output);
            return error.NeedMoreData;
        }

        if (self.response_len == self.response_bytes.len) {
            return error.ObfsResponseTooLarge;
        }
        return error.NeedMoreData;
    }

    pub fn hasPendingRead(self: *const Client) bool {
        return self.response_state == .raw and self.tail_start < self.tail_end;
    }

    fn drainTail(self: *Client, output: []u8) usize {
        std.debug.assert(self.tail_start <= self.tail_end);
        const available = self.tail_end - self.tail_start;
        const count = @min(available, output.len);
        const end = std.math.add(usize, self.tail_start, count) catch unreachable;
        @memcpy(output[0..count], self.response_bytes[self.tail_start..end]);
        self.tail_start = end;
        if (self.tail_start == self.tail_end) {
            self.tail_start = 0;
            self.tail_end = 0;
            self.response_len = 0;
        }
        return count;
    }

    pub fn responseDeadlineRemainingMsAt(
        self: *const Client,
        now_ms: i64,
    ) ?i32 {
        if (self.response_state == .raw) return null;
        const deadline_ms = self.response_deadline_ms orelse return null;
        if (now_ms >= deadline_ms) return 0;
        const difference = std.math.sub(i64, deadline_ms, now_ms) catch {
            return @intCast(self.response_timeout_ms);
        };
        const bounded = @min(difference, self.response_timeout_ms);
        return @intCast(bounded);
    }

    pub fn responseTimeoutMs(self: *const Client) i64 {
        return self.response_timeout_ms;
    }

    pub fn responseDeadlineExpiredAt(
        self: *const Client,
        now_ms: i64,
    ) bool {
        const deadline_ms = self.response_deadline_ms orelse return false;
        return self.response_state == .header and now_ms >= deadline_ms;
    }

    pub fn checkResponseDeadlineAt(
        self: *const Client,
        now_ms: i64,
    ) !void {
        if (self.responseDeadlineExpiredAt(now_ms)) {
            return error.ObfsResponseTimeout;
        }
    }

    fn startResponseDeadline(self: *Client, completion_now_ms: i64) void {
        self.response_deadline_ms = std.math.add(
            i64,
            completion_now_ms,
            self.response_timeout_ms,
        ) catch std.math.maxInt(i64);
    }

    fn writePayloadWithEntropy(
        self: *Client,
        stream: anytype,
        payload: []const u8,
        entropy: RequestEntropy,
    ) !bool {
        if (self.request_state == .poisoned) {
            return error.ObfsRequestPoisoned;
        }
        if (payload.len == 0) return false;
        if (self.request_state == .raw) {
            try writeAll(stream, payload);
            return false;
        }

        var header_storage: [request_header_max]u8 = undefined;
        const header = try self.formatRequestHeader(
            payload.len,
            entropy,
            &header_storage,
        );
        // From the first attempted wire byte onward this request cannot be
        // retried safely. Leave the client poisoned unless the entire header
        // and payload complete.
        self.request_state = .poisoned;
        try writeAll(stream, header);
        try writeAll(stream, payload);
        self.request_state = .raw;
        return true;
    }

    pub fn formatRequestHeader(
        self: *const Client,
        payload_len: usize,
        entropy: RequestEntropy,
        output: []u8,
    ) ![]const u8 {
        var key_base64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(
            &key_base64,
            &entropy.websocket_key,
        );

        const host = self.host[0..self.host_len];
        if (self.server_port == 80) {
            return std.fmt.bufPrint(
                output,
                "GET / HTTP/1.1\r\n" ++
                    "Host: {s}\r\n" ++
                    "User-Agent: curl/7.{d}.{d}\r\n" ++
                    "Upgrade: websocket\r\n" ++
                    "Connection: Upgrade\r\n" ++
                    "Sec-WebSocket-Key: {s}\r\n" ++
                    "Content-Length: {d}\r\n" ++
                    "\r\n",
                .{
                    host,
                    entropy.curl_major,
                    entropy.curl_minor,
                    &key_base64,
                    payload_len,
                },
            ) catch |err| switch (err) {
                error.NoSpaceLeft => error.ObfsRequestTooLarge,
            };
        }

        return std.fmt.bufPrint(
            output,
            "GET / HTTP/1.1\r\n" ++
                "Host: {s}:{d}\r\n" ++
                "User-Agent: curl/7.{d}.{d}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "\r\n",
            .{
                host,
                self.server_port,
                entropy.curl_major,
                entropy.curl_minor,
                &key_base64,
                payload_len,
            },
        ) catch |err| switch (err) {
            error.NoSpaceLeft => error.ObfsRequestTooLarge,
        };
    }
};

fn validateResponseStatus(header: []const u8) !void {
    const line_end = std.mem.indexOf(u8, header, "\r\n") orelse {
        return error.InvalidObfsResponseStatus;
    };
    const status_line = header[0..line_end];
    const prefix = "HTTP/1.1 ";
    if (!std.mem.startsWith(u8, status_line, prefix)) {
        return error.InvalidObfsResponseStatus;
    }
    const status_end = std.math.add(usize, prefix.len, 3) catch {
        return error.LengthOverflow;
    };
    if (status_line.len < status_end) return error.InvalidObfsResponseStatus;
    if (!std.mem.eql(u8, status_line[prefix.len..status_end], "101")) {
        return error.InvalidObfsResponseStatus;
    }
    if (status_line.len > status_end and
        status_line[status_end] != ' ' and
        status_line[status_end] != '\t')
    {
        return error.InvalidObfsResponseStatus;
    }
}

fn writeAll(stream: anytype, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes.len - offset;
        const written = try stream.write(bytes[offset..]);
        if (written == 0) return error.WriteZero;
        if (written > remaining) return error.InvalidWriteCount;
        offset = std.math.add(usize, offset, written) catch {
            return error.LengthOverflow;
        };
    }
}
