const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");

// This executable is an independent, test-only simple-obfs HTTP oracle. It
// deliberately does not import production config, Shadowsocks, or simple-obfs
// modules. Every network operation is nonblocking and guarded by an absolute
// monotonic deadline.
const connection_count_max: u16 = 64;
const request_header_max: usize = 8 * 1024;
const request_buffer_max: usize = 32 * 1024;
const request_read_count_max: u16 = 128;
const required_header_count_max: u8 = 128;
const relay_iteration_max: u16 = 4096;
const content_length_max: usize = 4 * 1024;
const relay_buffer_size: usize = 16 * 1024;

const accept_timeout_ms: i64 = 120_000;
const request_timeout_ms: i64 = 10_000;
const connect_timeout_ms: u32 = 5_000;
const write_timeout_ms: i64 = 10_000;
const backend_tail_timeout_ms: i64 = 10_000;
const relay_idle_timeout_ms: i64 = 20_000;
const relay_lifetime_ms: i64 = 60_000;

comptime {
    std.debug.assert(content_length_max < request_buffer_max);
    std.debug.assert(request_header_max + content_length_max < request_buffer_max);
    std.debug.assert(relay_buffer_size <= request_buffer_max);
}

const response_header =
    "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Server: zc-e2e-obfs-oracle\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "\r\n";

const ResponseMode = enum {
    fragmented_header,
    same_write_tail,
};

const Deadline = struct {
    expires_ms: i64,

    fn init(timeout_ms: i64) Deadline {
        return initAt(compat.monotonicMilliTimestamp(), timeout_ms);
    }

    fn initAt(now_ms: i64, timeout_ms: i64) Deadline {
        std.debug.assert(timeout_ms > 0);
        return .{
            .expires_ms = std.math.add(i64, now_ms, timeout_ms) catch
                std.math.maxInt(i64),
        };
    }

    fn remaining(self: Deadline) !i32 {
        return self.remainingAt(compat.monotonicMilliTimestamp());
    }

    fn remainingAt(self: Deadline, now_ms: i64) !i32 {
        if (now_ms >= self.expires_ms) return error.DeadlineExceeded;
        const difference = std.math.sub(i64, self.expires_ms, now_ms) catch
            return error.DeadlineExceeded;
        return @intCast(@min(difference, std.math.maxInt(i32)));
    }

    fn earlier(left: Deadline, right: Deadline) Deadline {
        return .{ .expires_ms = @min(left.expires_ms, right.expires_ms) };
    }
};

const Request = struct {
    initial_body: []const u8,
    raw_tail: []const u8,
    content_length: usize,
};

const RequestProgress = union(enum) {
    need_more,
    complete: Request,
};

const Attestation = struct {
    mode: ResponseMode,
    content_length: usize,
};

const RelayTimeouts = struct {
    lifetime_ms: i64 = relay_lifetime_ms,
    idle_ms: i64 = relay_idle_timeout_ms,

    fn validate(self: RelayTimeouts) !void {
        if (self.lifetime_ms <= 0 or self.lifetime_ms > relay_lifetime_ms) {
            return error.InvalidRelayTimeout;
        }
        if (self.idle_ms <= 0 or self.idle_ms > self.lifetime_ms) {
            return error.InvalidRelayTimeout;
        }
    }
};

const RelayReadState = struct {
    front_open: bool = true,
    backend_open: bool = true,
};

pub fn main(init: std.process.Init) !void {
    compat.setIo(init.io);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6) return error.InvalidArguments;

    const backend_port = try std.fmt.parseInt(u16, args[1], 10);
    if (backend_port == 0) return error.InvalidArguments;
    const expected_host = args[2];
    if (expected_host.len == 0 or expected_host.len > 255) {
        return error.InvalidArguments;
    }
    const expected_initial_body_bytes = try std.fmt.parseInt(usize, args[3], 10);
    if (expected_initial_body_bytes == 0 or
        expected_initial_body_bytes > content_length_max)
    {
        return error.InvalidArguments;
    }
    const response_mode = parseResponseMode(args[4]) orelse
        return error.InvalidArguments;
    const endpoint_id = args[5];
    if (!validEndpointId(endpoint_id)) return error.InvalidArguments;

    const listen_address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var server = try compat.net.listenReuseAddr(listen_address);
    defer server.deinit();
    try configureNonblockingSocket(server.fd);
    const listen_port = server.listen_address.getPort();

    var ready_buffer: [320]u8 = undefined;
    const ready = try std.fmt.bufPrint(
        &ready_buffer,
        "E2E_OBFS_ORACLE_READY={s}:{d}\n" ++
            "E2E_OBFS_ORACLE_EXPECTED={s}:host={s}:body={d}:mode={s}\n",
        .{
            endpoint_id,
            listen_port,
            endpoint_id,
            expected_host,
            expected_initial_body_bytes,
            @tagName(response_mode),
        },
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, ready);

    var raw_accepted_count: u16 = 0;
    var verified_count: u16 = 0;
    while (raw_accepted_count < connection_count_max) {
        const front = try acceptWithDeadline(
            server.fd,
            Deadline.init(accept_timeout_ms),
        );
        defer front.close();
        raw_accepted_count += 1;

        var raw_buffer: [192]u8 = undefined;
        const raw_event = try std.fmt.bufPrint(
            &raw_buffer,
            "E2E_OBFS_ORACLE_RAW_ACCEPTED={s}:{d}\n",
            .{ endpoint_id, raw_accepted_count },
        );
        try std.Io.File.stdout().writeStreamingAll(init.io, raw_event);

        const attestation = recordVerifiedConnection(
            handleConnection(
                front,
                backend_port,
                expected_host,
                listen_port,
                expected_initial_body_bytes,
                response_mode,
            ),
            &verified_count,
        ) catch |err| {
            var reject_buffer: [256]u8 = undefined;
            const reject = try std.fmt.bufPrint(
                &reject_buffer,
                "E2E_OBFS_ORACLE_REJECTED={s}:raw={d}:verified={d}:error={s}\n",
                .{
                    endpoint_id,
                    raw_accepted_count,
                    verified_count,
                    @errorName(err),
                },
            );
            try std.Io.File.stdout().writeStreamingAll(init.io, reject);
            continue;
        };

        var event_buffer: [512]u8 = undefined;
        const event = try std.fmt.bufPrint(
            &event_buffer,
            "E2E_OBFS_ORACLE_VERIFIED={s}:{d}\n" ++
                "E2E_OBFS_ORACLE_REQUEST={s}:GET_HOST_UPGRADE_" ++
                "CONNECTION_KEY_CONTENT_LENGTH_EXACT:{d}\n" ++
                "E2E_OBFS_ORACLE_RESPONSE={s}:{s}\n" ++
                "E2E_OBFS_ORACLE_FORWARD={s}:RAW_TCP_HALF_CLOSE_PASS\n",
            .{
                endpoint_id,
                verified_count,
                endpoint_id,
                attestation.content_length,
                endpoint_id,
                @tagName(attestation.mode),
                endpoint_id,
            },
        );
        try std.Io.File.stdout().writeStreamingAll(init.io, event);
    }
    return error.ConnectionLimitReached;
}

fn parseResponseMode(text: []const u8) ?ResponseMode {
    if (std.mem.eql(u8, text, "fragmented_header")) return .fragmented_header;
    if (std.mem.eql(u8, text, "same_write_tail")) return .same_write_tail;
    return null;
}

fn validEndpointId(text: []const u8) bool {
    if (text.len == 0 or text.len > 32) return false;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') {
            continue;
        }
        return false;
    }
    return true;
}

fn handleConnection(
    front: compat.net.Stream,
    backend_port: u16,
    expected_host: []const u8,
    listen_port: u16,
    expected_initial_body_bytes: usize,
    mode: ResponseMode,
) !Attestation {
    var request_storage: [request_buffer_max]u8 = undefined;
    const request = try readAndValidateRequest(
        front,
        expected_host,
        listen_port,
        expected_initial_body_bytes,
        &request_storage,
        Deadline.init(request_timeout_ms),
    );

    const backend = try connectBackend(
        backend_port,
        Deadline.init(connect_timeout_ms),
    );
    defer backend.close();

    const initial_write_deadline = Deadline.init(write_timeout_ms);
    var backend_writer = SocketWriter{ .stream = backend };
    try writeAllBounded(
        &backend_writer,
        request.initial_body,
        initial_write_deadline,
    );
    try writeAllBounded(
        &backend_writer,
        request.raw_tail,
        initial_write_deadline,
    );

    var relay_read_state = RelayReadState{};
    switch (mode) {
        .fragmented_header => {
            try writeFragmentedResponse(front);
        },
        .same_write_tail => {
            relay_read_state = try writeResponseWithBackendTail(front, backend);
        },
    }
    try relayRaw(front, backend, .{}, relay_read_state);

    return .{
        .mode = mode,
        .content_length = request.content_length,
    };
}

fn recordVerifiedConnection(
    result: anyerror!Attestation,
    verified_count: *u16,
) !Attestation {
    const attestation = try result;
    verified_count.* = std.math.add(u16, verified_count.*, 1) catch
        return error.VerifiedCountOverflow;
    return attestation;
}

fn readAndValidateRequest(
    stream: compat.net.Stream,
    expected_host: []const u8,
    listen_port: u16,
    expected_initial_body_bytes: usize,
    storage: []u8,
    deadline: Deadline,
) !Request {
    if (storage.len > request_buffer_max) return error.RequestBufferLimitExceeded;
    var size: usize = 0;
    var read_count: u16 = 0;
    while (read_count < request_read_count_max) : (read_count += 1) {
        switch (try inspectRequestBytes(
            storage[0..size],
            expected_host,
            listen_port,
            expected_initial_body_bytes,
        )) {
            .complete => |request| return request,
            .need_more => {},
        }
        if (size == storage.len) return error.RequestBufferLimitExceeded;
        const count = try readSocket(stream, storage[size..], deadline);
        if (count == 0) return error.RequestUnexpectedEof;
        size = std.math.add(usize, size, count) catch
            return error.LengthOverflow;
    }
    return error.RequestReadLimitExceeded;
}

fn inspectRequestBytes(
    bytes: []const u8,
    expected_host: []const u8,
    listen_port: u16,
    expected_initial_body_bytes: usize,
) !RequestProgress {
    if (bytes.len > request_buffer_max) return error.RequestBufferLimitExceeded;
    const terminator = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        if (bytes.len >= request_header_max) {
            return error.RequestHeaderLimitExceeded;
        }
        return .need_more;
    };
    const header_end = std.math.add(usize, terminator, 4) catch
        return error.LengthOverflow;
    if (header_end > request_header_max) {
        return error.RequestHeaderLimitExceeded;
    }
    const content_length = try validateRequestHeaders(
        bytes[0..header_end],
        expected_host,
        listen_port,
        expected_initial_body_bytes,
    );
    const body_end = std.math.add(usize, header_end, content_length) catch
        return error.RequestBodyLimitExceeded;
    if (body_end > request_buffer_max) return error.RequestBodyLimitExceeded;
    if (bytes.len < body_end) return .need_more;
    return .{ .complete = .{
        .initial_body = bytes[header_end..body_end],
        .raw_tail = bytes[body_end..],
        .content_length = content_length,
    } };
}

fn validateRequestHeaders(
    header: []const u8,
    expected_host: []const u8,
    listen_port: u16,
    expected_initial_body_bytes: usize,
) !usize {
    const terminator = std.mem.indexOf(u8, header, "\r\n\r\n") orelse
        return error.MissingHeaderTerminator;
    const first_line_end = std.mem.indexOf(
        u8,
        header[0..terminator],
        "\r\n",
    ) orelse return error.InvalidRequestLine;
    if (!std.mem.eql(u8, header[0..first_line_end], "GET / HTTP/1.1")) {
        return error.InvalidRequestLine;
    }

    var expected_host_storage: [320]u8 = undefined;
    const expected_host_value = if (listen_port == 80)
        expected_host
    else
        try std.fmt.bufPrint(
            &expected_host_storage,
            "{s}:{d}",
            .{ expected_host, listen_port },
        );

    var saw_host = false;
    var saw_upgrade = false;
    var saw_connection = false;
    var saw_key = false;
    var saw_content_length = false;
    var content_length: usize = 0;
    var cursor = std.math.add(usize, first_line_end, 2) catch
        return error.LengthOverflow;
    const header_lines_end = std.math.add(usize, terminator, 2) catch
        return error.LengthOverflow;
    var header_count: u8 = 0;
    while (cursor < header_lines_end and
        header_count < required_header_count_max) : (header_count += 1)
    {
        const relative_end = std.mem.indexOf(
            u8,
            header[cursor..header_lines_end],
            "\r\n",
        ) orelse return error.InvalidHeaderLine;
        const line_end = std.math.add(usize, cursor, relative_end) catch
            return error.LengthOverflow;
        const line = header[cursor..line_end];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse
            return error.InvalidHeaderLine;
        if (colon == 0) return error.InvalidHeaderLine;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "Host")) {
            if (saw_host) return error.DuplicateRequiredHeader;
            saw_host = true;
            if (!std.mem.eql(u8, value, expected_host_value)) {
                return error.InvalidHostHeader;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "Upgrade")) {
            if (saw_upgrade) return error.DuplicateRequiredHeader;
            saw_upgrade = true;
            if (!std.ascii.eqlIgnoreCase(value, "websocket")) {
                return error.InvalidUpgradeHeader;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "Connection")) {
            if (saw_connection) return error.DuplicateRequiredHeader;
            saw_connection = true;
            if (!std.ascii.eqlIgnoreCase(value, "Upgrade")) {
                return error.InvalidConnectionHeader;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Key")) {
            if (saw_key) return error.DuplicateRequiredHeader;
            saw_key = true;
            var decoded: [16]u8 = undefined;
            std.base64.standard.Decoder.decode(&decoded, value) catch
                return error.InvalidWebSocketKey;
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (saw_content_length) return error.DuplicateRequiredHeader;
            saw_content_length = true;
            if (value.len == 0) return error.InvalidContentLength;
            for (value) |byte| {
                if (!std.ascii.isDigit(byte)) {
                    return error.InvalidContentLength;
                }
            }
            content_length = std.fmt.parseInt(usize, value, 10) catch
                return error.InvalidContentLength;
            if (content_length == 0 or content_length > content_length_max) {
                return error.InvalidContentLength;
            }
        }

        cursor = std.math.add(usize, line_end, 2) catch
            return error.LengthOverflow;
    }
    if (cursor != header_lines_end) return error.TooManyHeaders;
    if (!saw_host) return error.MissingHostHeader;
    if (!saw_upgrade) return error.MissingUpgradeHeader;
    if (!saw_connection) return error.MissingConnectionHeader;
    if (!saw_key) return error.MissingWebSocketKey;
    if (!saw_content_length) return error.MissingContentLength;
    if (content_length != expected_initial_body_bytes) {
        return error.ContentLengthMismatch;
    }
    return content_length;
}

fn writeFragmentedResponse(front: compat.net.Stream) !void {
    const cuts = [_]usize{
        1,
        8,
        31,
        67,
        response_header.len - 3,
        response_header.len - 1,
        response_header.len,
    };
    const deadline = Deadline.init(write_timeout_ms);
    var writer = SocketWriter{ .stream = front };
    var offset: usize = 0;
    for (cuts) |end| {
        if (end <= offset or end > response_header.len) {
            return error.InvalidFragmentPlan;
        }
        try writeAllBounded(&writer, response_header[offset..end], deadline);
        offset = end;
        if (offset != response_header.len) {
            compat.sleepNs(2 * std.time.ns_per_ms);
        }
    }
}

fn writeResponseWithBackendTail(
    front: compat.net.Stream,
    backend: compat.net.Stream,
) !RelayReadState {
    const deadline = Deadline.init(backend_tail_timeout_ms);
    var front_read_open = true;
    var buffer: [relay_buffer_size]u8 = undefined;
    var iteration: u16 = 0;
    while (iteration < relay_iteration_max) : (iteration += 1) {
        const events = try pollPair(
            .{
                if (front_read_open) front.handle else -1,
                backend.handle,
            },
            .{
                if (front_read_open) std.posix.POLL.IN else 0,
                std.posix.POLL.IN,
            },
            deadline,
        );
        if (front_read_open and hasReadEvent(events[0])) {
            const maybe_count: ?usize = readSocketReady(
                front,
                &buffer,
            ) catch |err| switch (err) {
                error.WouldBlock => null,
                else => return err,
            };
            if (maybe_count) |count| {
                if (count == 0) {
                    front_read_open = false;
                    try shutdownSocketWrite(backend.handle);
                } else {
                    var backend_writer = SocketWriter{ .stream = backend };
                    try writeAllBounded(
                        &backend_writer,
                        buffer[0..count],
                        deadline,
                    );
                }
            }
        }
        if (hasReadEvent(events[1])) {
            const count = readSocketReady(backend, &buffer) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (count == 0) return error.BackendUnexpectedEof;
            var combined: [response_header.len + relay_buffer_size]u8 = undefined;
            @memcpy(combined[0..response_header.len], response_header);
            @memcpy(
                combined[response_header.len .. response_header.len + count],
                buffer[0..count],
            );
            var front_writer = SocketWriter{ .stream = front };
            try writeAllBounded(
                &front_writer,
                combined[0 .. response_header.len + count],
                deadline,
            );
            return .{
                .front_open = front_read_open,
                .backend_open = true,
            };
        }
        if (front_read_open and !hasKnownEvent(events[0])) {
            return error.UnexpectedPollEvent;
        }
        if (!hasKnownEvent(events[1])) return error.UnexpectedPollEvent;
    }
    return error.RelayIterationLimitExceeded;
}

fn relayRaw(
    front: compat.net.Stream,
    backend: compat.net.Stream,
    timeouts: RelayTimeouts,
    initial_read_state: RelayReadState,
) !void {
    try timeouts.validate();
    var front_read_open = initial_read_state.front_open;
    var backend_read_open = initial_read_state.backend_open;
    const lifetime_deadline = Deadline.init(timeouts.lifetime_ms);
    var idle_deadline = Deadline.init(timeouts.idle_ms);
    var buffer: [relay_buffer_size]u8 = undefined;
    var iteration: u16 = 0;

    while ((front_read_open or backend_read_open) and
        iteration < relay_iteration_max) : (iteration += 1)
    {
        const phase_deadline = Deadline.earlier(
            lifetime_deadline,
            idle_deadline,
        );
        const events = pollPair(
            .{
                if (front_read_open) front.handle else -1,
                if (backend_read_open) backend.handle else -1,
            },
            .{
                if (front_read_open) std.posix.POLL.IN else 0,
                if (backend_read_open) std.posix.POLL.IN else 0,
            },
            phase_deadline,
        ) catch |err| switch (err) {
            error.DeadlineExceeded => {
                const now_ms = compat.monotonicMilliTimestamp();
                if (now_ms >= lifetime_deadline.expires_ms) {
                    return error.RelayLifetimeExceeded;
                }
                return error.RelayIdleTimeout;
            },
            else => return err,
        };
        var transferred = false;

        if (front_read_open and hasReadEvent(events[0])) {
            const maybe_count: ?usize = readSocketReady(
                front,
                &buffer,
            ) catch |err| switch (err) {
                error.WouldBlock => null,
                else => return err,
            };
            if (maybe_count) |count| {
                if (count == 0) {
                    front_read_open = false;
                    try shutdownSocketWrite(backend.handle);
                } else {
                    const write_deadline = Deadline.earlier(
                        lifetime_deadline,
                        Deadline.init(write_timeout_ms),
                    );
                    var backend_writer = SocketWriter{ .stream = backend };
                    try writeAllBounded(
                        &backend_writer,
                        buffer[0..count],
                        write_deadline,
                    );
                    transferred = true;
                }
            }
        }
        if (backend_read_open and hasReadEvent(events[1])) {
            const maybe_count: ?usize = readSocketReady(
                backend,
                &buffer,
            ) catch |err| switch (err) {
                error.WouldBlock => null,
                else => return err,
            };
            if (maybe_count) |count| {
                if (count == 0) {
                    backend_read_open = false;
                    try shutdownSocketWrite(front.handle);
                } else {
                    const write_deadline = Deadline.earlier(
                        lifetime_deadline,
                        Deadline.init(write_timeout_ms),
                    );
                    var front_writer = SocketWriter{ .stream = front };
                    try writeAllBounded(
                        &front_writer,
                        buffer[0..count],
                        write_deadline,
                    );
                    transferred = true;
                }
            }
        }
        if (transferred) idle_deadline = Deadline.init(timeouts.idle_ms);

        if (front_read_open and !hasKnownEvent(events[0])) {
            return error.UnexpectedPollEvent;
        }
        if (backend_read_open and !hasKnownEvent(events[1])) {
            return error.UnexpectedPollEvent;
        }
    }
    if (front_read_open or backend_read_open) {
        return error.RelayIterationLimitExceeded;
    }
}

const SocketWriter = struct {
    stream: compat.net.Stream,

    fn writeSome(
        self: *SocketWriter,
        bytes: []const u8,
        deadline: Deadline,
    ) !usize {
        return writeSocketSome(self.stream, bytes, deadline);
    }
};

fn writeAllBounded(writer: anytype, bytes: []const u8, deadline: Deadline) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try writer.writeSome(bytes[offset..], deadline);
        const remaining = bytes.len - offset;
        if (count == 0) return error.WriteZero;
        if (count > remaining) return error.InvalidWriteCount;
        offset = std.math.add(usize, offset, count) catch
            return error.LengthOverflow;
    }
}

fn writeSocketSome(
    stream: compat.net.Stream,
    bytes: []const u8,
    deadline: Deadline,
) !usize {
    if (bytes.len == 0) return 0;
    while (true) {
        _ = try waitForEvents(stream.handle, std.posix.POLL.OUT, deadline);
        const flags: u32 = if (@hasDecl(std.c.MSG, "NOSIGNAL"))
            @intCast(std.c.MSG.NOSIGNAL)
        else
            0;
        const result = std.c.send(
            stream.handle,
            bytes.ptr,
            bytes.len,
            flags,
        );
        if (result >= 0) return @intCast(result);
        switch (std.c.errno(result)) {
            .INTR, .AGAIN => continue,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BADF => return error.NotOpenForWriting,
            else => return error.SocketWriteFailed,
        }
    }
}

fn readSocket(
    stream: compat.net.Stream,
    output: []u8,
    deadline: Deadline,
) !usize {
    if (output.len == 0) return 0;
    while (true) {
        _ = try waitForEvents(stream.handle, std.posix.POLL.IN, deadline);
        return readSocketReady(stream, output) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
    }
}

fn readSocketReady(stream: compat.net.Stream, output: []u8) !usize {
    const result = std.c.recv(stream.handle, output.ptr, output.len, 0);
    if (result >= 0) return @intCast(result);
    return switch (std.c.errno(result)) {
        .INTR, .AGAIN => error.WouldBlock,
        .CONNRESET => error.ConnectionResetByPeer,
        .BADF => error.NotOpenForReading,
        else => error.SocketReadFailed,
    };
}

fn waitForEvents(
    fd: std.posix.fd_t,
    requested: i16,
    deadline: Deadline,
) !i16 {
    while (true) {
        var descriptors = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = requested,
            .revents = 0,
        }};
        const ready = try pollAbsolute(&descriptors, deadline);
        if (ready == 0) continue;
        const events = descriptors[0].revents;
        if (events & std.posix.POLL.NVAL != 0) return error.InvalidSocket;
        if (events & (requested | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            return events;
        }
        return error.UnexpectedPollEvent;
    }
}

fn pollPair(
    descriptors_fds: [2]std.posix.fd_t,
    requested: [2]i16,
    deadline: Deadline,
) ![2]i16 {
    while (true) {
        var descriptors = [_]std.posix.pollfd{
            .{
                .fd = descriptors_fds[0],
                .events = requested[0],
                .revents = 0,
            },
            .{
                .fd = descriptors_fds[1],
                .events = requested[1],
                .revents = 0,
            },
        };
        const ready = try pollAbsolute(&descriptors, deadline);
        if (ready == 0) continue;
        for (descriptors) |descriptor| {
            if (descriptor.revents & std.posix.POLL.NVAL != 0) {
                return error.InvalidSocket;
            }
        }
        return .{ descriptors[0].revents, descriptors[1].revents };
    }
}

fn pollAbsolute(
    descriptors: []std.posix.pollfd,
    deadline: Deadline,
) !usize {
    while (true) {
        const timeout_ms = try deadline.remaining();
        const result = std.c.poll(
            descriptors.ptr,
            @intCast(descriptors.len),
            timeout_ms,
        );
        if (result >= 0) return @intCast(result);
        switch (std.c.errno(result)) {
            .INTR => continue,
            .NOMEM => return error.SystemResources,
            else => return error.PollFailed,
        }
    }
}

fn hasReadEvent(events: i16) bool {
    return events &
        (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0;
}

fn hasKnownEvent(events: i16) bool {
    return events == 0 or hasReadEvent(events);
}

fn connectBackend(
    backend_port: u16,
    deadline: Deadline,
) !compat.net.Stream {
    const address = try compat.net.Address.parseIp4(
        "127.0.0.1",
        backend_port,
    );
    const fd = std.c.socket(
        std.c.AF.INET,
        std.c.SOCK.STREAM,
        std.c.IPPROTO.TCP,
    );
    if (fd < 0) return error.SocketSetupFailed;
    errdefer _ = std.c.close(fd);
    try configureNonblockingSocket(fd);

    const socket_address = address.in.sa;
    while (true) {
        const result = std.c.connect(
            fd,
            @ptrCast(&socket_address),
            @sizeOf(std.c.sockaddr.in),
        );
        if (result == 0) return .{ .handle = fd };
        switch (std.c.errno(result)) {
            .INTR => continue,
            .ISCONN => return .{ .handle = fd },
            .INPROGRESS, .ALREADY, .AGAIN => break,
            .CONNREFUSED => return error.BackendConnectionRefused,
            else => return error.BackendConnectFailed,
        }
    }

    _ = try waitForEvents(fd, std.posix.POLL.OUT, deadline);
    var socket_error: c_int = 0;
    var socket_error_size: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.ERROR,
        &socket_error,
        &socket_error_size,
    ) != 0) {
        return error.BackendConnectFailed;
    }
    if (socket_error != 0) return error.BackendConnectFailed;
    return .{ .handle = fd };
}

fn acceptWithDeadline(
    listener_fd: std.posix.fd_t,
    deadline: Deadline,
) !compat.net.Stream {
    while (true) {
        _ = try waitForEvents(listener_fd, std.posix.POLL.IN, deadline);
        const accepted_fd = std.c.accept(listener_fd, null, null);
        if (accepted_fd >= 0) {
            errdefer _ = std.c.close(accepted_fd);
            try configureNonblockingSocket(accepted_fd);
            return .{ .handle = accepted_fd };
        }
        switch (std.c.errno(accepted_fd)) {
            .INTR, .AGAIN, .CONNABORTED => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.AcceptFailed,
        }
    }
}

fn configureRawSendSocket(fd: std.posix.fd_t) !void {
    if (comptime builtin.os.tag.isDarwin() and
        @hasDecl(std.c.SO, "NOSIGPIPE"))
    {
        var enabled: c_int = 1;
        if (std.c.setsockopt(
            fd,
            std.c.SOL.SOCKET,
            std.c.SO.NOSIGPIPE,
            std.mem.asBytes(&enabled),
            @sizeOf(c_int),
        ) != 0) return error.SocketSetupFailed;
    }
}

fn configureNonblockingSocket(fd: std.posix.fd_t) !void {
    try configureRawSendSocket(fd);
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.SocketSetupFailed;
    const nonblocking: c_int = @bitCast(@as(u32, @bitCast(std.posix.O{
        .NONBLOCK = true,
    })));
    if (std.c.fcntl(fd, std.posix.F.SETFL, flags | nonblocking) < 0) {
        return error.SocketSetupFailed;
    }
    if (std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, 1)) < 0) {
        return error.SocketSetupFailed;
    }
}

fn shutdownSocketWrite(fd: std.posix.fd_t) !void {
    var attempt: u8 = 0;
    while (attempt < 4) : (attempt += 1) {
        const result = std.c.shutdown(fd, std.c.SHUT.WR);
        if (result == 0) return;
        switch (std.c.errno(result)) {
            .INTR => continue,
            .NOTCONN, .PIPE => return,
            else => return error.SocketShutdownFailed,
        }
    }
    return error.SocketShutdownInterrupted;
}

const PartialTestWriter = struct {
    output: *[8]u8,
    size: usize = 0,
    calls: usize = 0,
    chunk_max: usize,

    fn writeSome(
        self: *PartialTestWriter,
        bytes: []const u8,
        deadline: Deadline,
    ) !usize {
        _ = try deadline.remainingAt(0);
        self.calls += 1;
        const count = @min(bytes.len, self.chunk_max);
        @memcpy(self.output[self.size .. self.size + count], bytes[0..count]);
        self.size += count;
        return count;
    }
};

fn testRequestHeader(
    storage: []u8,
    host: []const u8,
    port: u16,
    content_length: usize,
) ![]const u8 {
    return std.fmt.bufPrint(
        storage,
        "GET / HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n",
        .{ host, port, content_length },
    );
}

fn makeSocketPair() ![2]std.posix.fd_t {
    var descriptors: [2]std.posix.fd_t = undefined;
    const result = std.c.socketpair(
        @intCast(std.posix.AF.UNIX),
        @intCast(std.posix.SOCK.STREAM),
        0,
        &descriptors,
    );
    if (result != 0) return error.SocketPairFailed;
    return descriptors;
}

fn makeTcpSocketPair() ![2]compat.net.Stream {
    const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var server = try compat.net.listenReuseAddr(address);
    defer server.deinit();
    try configureNonblockingSocket(server.fd);

    const client = try connectBackend(
        server.listen_address.getPort(),
        Deadline.init(2_000),
    );
    errdefer client.close();
    const accepted = try acceptWithDeadline(server.fd, Deadline.init(2_000));
    return .{ client, accepted };
}

fn setResetOnClose(fd: std.posix.fd_t) !void {
    const Linger = extern struct {
        enabled: i32,
        timeout_seconds: i32,
    };
    const linger = Linger{
        .enabled = 1,
        .timeout_seconds = 0,
    };
    try std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.LINGER,
        std.mem.asBytes(&linger),
    );
}

fn wakeTestSocket(fd: std.posix.fd_t) void {
    var attempt: u8 = 0;
    while (attempt < 4) : (attempt += 1) {
        const result = std.c.shutdown(fd, std.c.SHUT.RDWR);
        if (result == 0) return;
        switch (std.c.errno(result)) {
            .INTR => continue,
            .BADF, .INVAL, .NOTCONN, .PIPE => return,
            else => return,
        }
    }
}

fn waitForTestThread(done: *const std.atomic.Value(bool)) !void {
    var iteration: u16 = 0;
    while (iteration < 5_000) : (iteration += 1) {
        if (done.load(.acquire)) return;
        compat.sleepNs(std.time.ns_per_ms);
    }
    return error.TestThreadTimeout;
}

fn waitForTestFlagUntil(
    value: *const std.atomic.Value(bool),
    deadline: Deadline,
) !void {
    while (!value.load(.acquire)) {
        const remaining_ms = try deadline.remaining();
        compat.sleepNs(
            @as(u64, @intCast(@min(remaining_ms, 1))) *
                std.time.ns_per_ms,
        );
    }
}

const LargeWriteTestContext = struct {
    stream: compat.net.Stream,
    bytes: []const u8,
    deadline: Deadline,
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn run(context: *@This()) void {
        defer context.done.store(true, .release);
        context.started.store(true, .release);
        var writer = SocketWriter{ .stream = context.stream };
        writeAllBounded(
            &writer,
            context.bytes,
            context.deadline,
        ) catch |err| {
            context.failure = err;
        };
    }
};

fn testLargeWriteDuringPeerReset() !void {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, relay_buffer_size * 256);
    defer allocator.free(bytes);
    @memset(bytes, 'x');

    const pair = try makeTcpSocketPair();
    defer pair[0].close();
    var peer_open = true;
    defer if (peer_open) pair[1].close();
    var send_buffer_bytes: c_int = 1024;
    if (std.c.setsockopt(
        pair[0].handle,
        std.c.SOL.SOCKET,
        std.c.SO.SNDBUF,
        std.mem.asBytes(&send_buffer_bytes),
        @sizeOf(c_int),
    ) != 0) return error.SocketSetupFailed;

    const total_deadline = Deadline.init(2_000);
    var context = LargeWriteTestContext{
        .stream = pair[0],
        .bytes = bytes,
        .deadline = total_deadline,
    };
    const thread = try std.Thread.spawn(.{}, LargeWriteTestContext.run, .{&context});
    var joined = false;
    defer if (!joined) {
        wakeTestSocket(pair[0].handle);
        thread.join();
    };

    try waitForTestFlagUntil(&context.started, total_deadline);
    try setResetOnClose(pair[1].handle);
    pair[1].close();
    peer_open = false;
    try waitForTestFlagUntil(&context.done, total_deadline);
    thread.join();
    joined = true;
    _ = try total_deadline.remaining();

    const failure = context.failure orelse return error.TestExpectedError;
    try std.testing.expect(
        failure == error.BrokenPipe or
            failure == error.ConnectionResetByPeer,
    );
}

fn expectNoSigpipe(fd: std.posix.fd_t) !void {
    if (comptime !builtin.os.tag.isDarwin() or
        !@hasDecl(std.c.SO, "NOSIGPIPE")) return;

    var value: c_int = 0;
    var value_size: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.NOSIGPIPE,
        std.mem.asBytes(&value).ptr,
        &value_size,
    ) != 0) return error.SocketOptionFailed;
    try std.testing.expectEqual(@as(c_int, 1), value);
}

fn readExactSocket(
    stream: compat.net.Stream,
    output: []u8,
    deadline: Deadline,
) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        const count = try readSocket(stream, output[offset..], deadline);
        if (count == 0) return error.UnexpectedEof;
        offset += count;
    }
}

const OracleTestContext = struct {
    front: compat.net.Stream,
    backend_port: u16,
    mode: ResponseMode = .same_write_tail,
    verified_count: u16 = 0,
    attestation: ?Attestation = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(context: *@This()) void {
        defer context.done.store(true, .release);
        context.attestation = recordVerifiedConnection(
            handleConnection(
                context.front,
                context.backend_port,
                "alias.example.test",
                12345,
                3,
                context.mode,
            ),
            &context.verified_count,
        ) catch |err| {
            context.failure = err;
            return;
        };
    }
};

fn writeOracleTestRequest(front: compat.net.Stream, deadline: Deadline) !void {
    var header_storage: [512]u8 = undefined;
    const header = try testRequestHeader(
        &header_storage,
        "alias.example.test",
        12345,
        3,
    );
    var writer = SocketWriter{ .stream = front };
    try writeAllBounded(&writer, header, deadline);
    try writeAllBounded(&writer, "abc", deadline);
}

fn readOracleTestResponse(front: compat.net.Stream, deadline: Deadline) !void {
    const tail = "TAIL";
    var response: [response_header.len + tail.len]u8 = undefined;
    try readExactSocket(front, &response, deadline);
    try std.testing.expectEqualStrings(
        response_header,
        response[0..response_header.len],
    );
    try std.testing.expectEqualStrings(tail, response[response_header.len..]);
}

fn testResponseAfterFrontHalfClose() !void {
    const backend_address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var backend_server = try compat.net.listenReuseAddr(backend_address);
    defer backend_server.deinit();
    try configureNonblockingSocket(backend_server.fd);

    const front_pair = try makeTcpSocketPair();
    defer front_pair[0].close();
    defer front_pair[1].close();
    var backend_peer: ?compat.net.Stream = null;
    defer if (backend_peer) |stream| stream.close();

    var context = OracleTestContext{
        .front = front_pair[1],
        .backend_port = backend_server.listen_address.getPort(),
    };
    {
        const thread = try std.Thread.spawn(.{}, OracleTestContext.run, .{&context});
        defer {
            wakeTestSocket(front_pair[1].handle);
            if (backend_peer) |stream| wakeTestSocket(stream.handle);
            thread.join();
        }

        const deadline = Deadline.init(2_000);
        try writeOracleTestRequest(front_pair[0], deadline);
        try shutdownSocketWrite(front_pair[0].handle);

        backend_peer = try acceptWithDeadline(backend_server.fd, deadline);
        var request: [3]u8 = undefined;
        try readExactSocket(backend_peer.?, &request, deadline);
        try std.testing.expectEqualStrings("abc", &request);
        var scratch: [1]u8 = undefined;
        try std.testing.expectEqual(
            @as(usize, 0),
            try readSocket(backend_peer.?, &scratch, deadline),
        );

        compat.sleepNs(20 * std.time.ns_per_ms);
        var backend_writer = SocketWriter{ .stream = backend_peer.? };
        try writeAllBounded(&backend_writer, "TAIL", deadline);
        try shutdownSocketWrite(backend_peer.?.handle);

        try readOracleTestResponse(front_pair[0], deadline);
        try std.testing.expectEqual(
            @as(usize, 0),
            try readSocket(front_pair[0], &scratch, deadline),
        );
        try waitForTestThread(&context.done);
    }

    if (context.failure) |failure| return failure;
    try std.testing.expect(context.attestation != null);
    try std.testing.expectEqual(@as(u16, 1), context.verified_count);
}

const ResetSide = enum {
    front,
    backend,
};

fn testConnectionResetRejected(reset_side: ResetSide) !void {
    const backend_address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var backend_server = try compat.net.listenReuseAddr(backend_address);
    defer backend_server.deinit();
    try configureNonblockingSocket(backend_server.fd);

    const front_pair = try makeTcpSocketPair();
    var front_client_open = true;
    defer if (front_client_open) front_pair[0].close();
    defer front_pair[1].close();
    var backend_peer: ?compat.net.Stream = null;
    defer if (backend_peer) |stream| stream.close();

    var context = OracleTestContext{
        .front = front_pair[1],
        .backend_port = backend_server.listen_address.getPort(),
    };
    {
        const thread = try std.Thread.spawn(.{}, OracleTestContext.run, .{&context});
        defer {
            wakeTestSocket(front_pair[1].handle);
            if (backend_peer) |stream| wakeTestSocket(stream.handle);
            thread.join();
        }

        const deadline = Deadline.init(2_000);
        try writeOracleTestRequest(front_pair[0], deadline);
        backend_peer = try acceptWithDeadline(backend_server.fd, deadline);
        var request: [3]u8 = undefined;
        try readExactSocket(backend_peer.?, &request, deadline);
        try std.testing.expectEqualStrings("abc", &request);

        var backend_writer = SocketWriter{ .stream = backend_peer.? };
        try writeAllBounded(&backend_writer, "TAIL", deadline);
        try readOracleTestResponse(front_pair[0], deadline);

        switch (reset_side) {
            .front => {
                try shutdownSocketWrite(backend_peer.?.handle);
                try setResetOnClose(front_pair[0].handle);
                front_pair[0].close();
                front_client_open = false;
            },
            .backend => {
                try shutdownSocketWrite(front_pair[0].handle);
                try setResetOnClose(backend_peer.?.handle);
                backend_peer.?.close();
                backend_peer = null;
            },
        }
        try waitForTestThread(&context.done);
    }

    try std.testing.expectEqual(
        error.ConnectionResetByPeer,
        context.failure orelse return error.TestExpectedError,
    );
    try std.testing.expect(context.attestation == null);
    try std.testing.expectEqual(@as(u16, 0), context.verified_count);
}

fn testRelayHalfClose() !void {
    const front_pair = try makeSocketPair();
    defer _ = std.c.close(front_pair[0]);
    defer _ = std.c.close(front_pair[1]);
    const backend_pair = try makeSocketPair();
    defer _ = std.c.close(backend_pair[0]);
    defer _ = std.c.close(backend_pair[1]);
    for (front_pair ++ backend_pair) |fd| try configureNonblockingSocket(fd);

    const Context = struct {
        front: compat.net.Stream,
        backend: compat.net.Stream,
        failure: ?anyerror = null,

        fn run(context: *@This()) void {
            relayRaw(
                context.front,
                context.backend,
                .{ .lifetime_ms = 2_000, .idle_ms = 1_000 },
                .{},
            ) catch |err| {
                context.failure = err;
            };
        }
    };
    var context = Context{
        .front = .{ .handle = front_pair[1] },
        .backend = .{ .handle = backend_pair[0] },
    };
    {
        const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
        defer {
            wakeTestSocket(front_pair[1]);
            wakeTestSocket(backend_pair[0]);
            thread.join();
        }

        const deadline = Deadline.init(2_000);
        var client_writer = SocketWriter{ .stream = .{ .handle = front_pair[0] } };
        try writeAllBounded(&client_writer, "request", deadline);
        try shutdownSocketWrite(front_pair[0]);

        var request: [7]u8 = undefined;
        try readExactSocket(.{ .handle = backend_pair[1] }, &request, deadline);
        try std.testing.expectEqualStrings("request", &request);
        var scratch: [1]u8 = undefined;
        try std.testing.expectEqual(
            @as(usize, 0),
            try readSocket(.{ .handle = backend_pair[1] }, &scratch, deadline),
        );

        var backend_writer = SocketWriter{
            .stream = .{ .handle = backend_pair[1] },
        };
        try writeAllBounded(&backend_writer, "response", deadline);
        try shutdownSocketWrite(backend_pair[1]);

        var response: [8]u8 = undefined;
        try readExactSocket(.{ .handle = front_pair[0] }, &response, deadline);
        try std.testing.expectEqualStrings("response", &response);
        try std.testing.expectEqual(
            @as(usize, 0),
            try readSocket(.{ .handle = front_pair[0] }, &scratch, deadline),
        );
    }
    if (context.failure) |failure| return failure;
}

test "oracle deadline and partial-write seams are bounded" {
    const deadline = Deadline.initAt(100, 50);
    try std.testing.expectEqual(@as(i32, 50), try deadline.remainingAt(100));
    try std.testing.expectEqual(@as(i32, 1), try deadline.remainingAt(149));
    try std.testing.expectError(error.DeadlineExceeded, deadline.remainingAt(150));

    var output: [8]u8 = undefined;
    var writer = PartialTestWriter{ .output = &output, .chunk_max = 2 };
    try writeAllBounded(&writer, "partial", Deadline.initAt(0, 100));
    try std.testing.expectEqualStrings("partial", output[0..writer.size]);
    try std.testing.expect(writer.calls > 1);
}

test "oracle socket read and accept deadlines expire without a busy-loop" {
    const pair = try makeSocketPair();
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    try configureNonblockingSocket(pair[0]);
    var byte: [1]u8 = undefined;
    try std.testing.expectError(
        error.DeadlineExceeded,
        readSocket(.{ .handle = pair[0] }, &byte, Deadline.init(20)),
    );

    const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var server = try compat.net.listenReuseAddr(address);
    defer server.deinit();
    try configureNonblockingSocket(server.fd);
    try std.testing.expectError(
        error.DeadlineExceeded,
        acceptWithDeadline(server.fd, Deadline.init(20)),
    );
}

test "oracle exact initial body handles same-read tail and split reads" {
    var header_storage: [512]u8 = undefined;
    const header = try testRequestHeader(
        &header_storage,
        "alias.example.test",
        12345,
        3,
    );
    var request_storage: [1024]u8 = undefined;
    @memcpy(request_storage[0..header.len], header);
    @memcpy(request_storage[header.len .. header.len + 7], "abcTAIL");
    const same_read = try inspectRequestBytes(
        request_storage[0 .. header.len + 7],
        "alias.example.test",
        12345,
        3,
    );
    switch (same_read) {
        .complete => |request| {
            try std.testing.expectEqualStrings("abc", request.initial_body);
            try std.testing.expectEqualStrings("TAIL", request.raw_tail);
        },
        .need_more => return error.TestExpectedEqual,
    }

    const split_header = try inspectRequestBytes(
        request_storage[0 .. header.len / 2],
        "alias.example.test",
        12345,
        3,
    );
    try std.testing.expect(split_header == .need_more);
    const split_body = try inspectRequestBytes(
        request_storage[0 .. header.len + 1],
        "alias.example.test",
        12345,
        3,
    );
    try std.testing.expect(split_body == .need_more);
    const complete = try inspectRequestBytes(
        request_storage[0 .. header.len + 3],
        "alias.example.test",
        12345,
        3,
    );
    try std.testing.expect(complete == .complete);
}

test "oracle rejects range-only Content-Length attestations and oversize input" {
    var header_storage: [request_header_max + 64]u8 = undefined;
    for ([_]usize{ 2, 4 }) |declared| {
        const header = try testRequestHeader(
            &header_storage,
            "alias.example.test",
            12345,
            declared,
        );
        try std.testing.expectError(
            error.ContentLengthMismatch,
            inspectRequestBytes(
                header,
                "alias.example.test",
                12345,
                3,
            ),
        );
    }

    @memset(header_storage[0 .. request_header_max + 1], 'x');
    try std.testing.expectError(
        error.RequestHeaderLimitExceeded,
        inspectRequestBytes(
            header_storage[0 .. request_header_max + 1],
            "alias.example.test",
            12345,
            3,
        ),
    );
    const oversized = try testRequestHeader(
        &header_storage,
        "alias.example.test",
        12345,
        content_length_max + 1,
    );
    try std.testing.expectError(
        error.InvalidContentLength,
        inspectRequestBytes(
            oversized,
            "alias.example.test",
            12345,
            content_length_max + 1,
        ),
    );
}

test "oracle connected raw-send sockets suppress SIGPIPE on macOS" {
    const pair = try makeTcpSocketPair();
    defer pair[0].close();
    defer pair[1].close();
    try expectNoSigpipe(pair[0].handle);
    try expectNoSigpipe(pair[1].handle);
}

test "oracle large write during peer reset returns a bounded socket error" {
    try testLargeWriteDuringPeerReset();
}

test "oracle same-write response survives a front half-close" {
    try testResponseAfterFrontHalfClose();
}

test "oracle rejects a front TCP reset before the verified counter gate" {
    try testConnectionResetRejected(.front);
}

test "oracle rejects a backend TCP reset before the verified counter gate" {
    try testConnectionResetRejected(.backend);
}

test "oracle relay propagates TCP EOF as a half-close and terminates" {
    try testRelayHalfClose();
}
