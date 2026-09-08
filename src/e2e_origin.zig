const std = @import("std");
const compat = @import("compat.zig");

const connection_count_max: u16 = 256;
const request_read_count_max: u8 = 16;
const request_size_max: usize = 4 * 1024;
const request_poll_timeout_ms: i32 = 500;
const request_path_size_max: usize = 128;
const eof_payload = "NEEDS_EOF";
const eof_response = "EOF-RESPONSE";

const ServerMode = enum {
    http,
    reject,
    eof_response,
};

const SocksEOFProbeOptions = struct {
    mixed_port: u16,
    target_port: u16,
    target_host: []const u8,
};

pub fn main(init: std.process.Init) !void {
    compat.setIo(init.io);
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 5) {
        if (!std.mem.eql(u8, args[1], "socks-eof-probe")) {
            return error.InvalidArguments;
        }
        const mixed_port = try parseRequiredPort(args[2]);
        const target_port = try parseRequiredPort(args[3]);
        try probeSocksEOF(allocator, init.io, .{
            .mixed_port = mixed_port,
            .target_port = target_port,
            .target_host = args[4],
        });
        return;
    }
    if (args.len > 2) return error.InvalidArguments;

    const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var server = try compat.net.listenReuseAddr(address);
    defer server.deinit();

    var ready_buffer: [64]u8 = undefined;
    var mode: ServerMode = .http;
    if (args.len == 2) {
        if (std.mem.eql(u8, args[1], "reserve-port")) {
            const port_text = try std.fmt.bufPrint(
                &ready_buffer,
                "{d}\n",
                .{server.listen_address.getPort()},
            );
            try std.Io.File.stdout().writeStreamingAll(init.io, port_text);
            return;
        }
        if (std.mem.eql(u8, args[1], "reject")) {
            mode = .reject;
        } else if (std.mem.eql(u8, args[1], "eof-response")) {
            mode = .eof_response;
        } else {
            return error.InvalidArguments;
        }
    }

    const ready_label = if (mode == .eof_response)
        "E2E_EOF_ORIGIN_PORT"
    else
        "E2E_ORIGIN_PORT";
    const ready = try std.fmt.bufPrint(
        &ready_buffer,
        "{s}={d}\n",
        .{ ready_label, server.listen_address.getPort() },
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, ready);
    if (mode == .eof_response) {
        try serveEOFResponse(init.io, &server);
        return;
    }
    const reject_requests = mode == .reject;

    var connection_count: u16 = 0;
    while (connection_count < connection_count_max) : (connection_count += 1) {
        const connection = try server.accept();
        defer connection.stream.close();

        var request_buffer: [request_size_max]u8 = undefined;
        const request_size = (try readRequestHeaders(
            connection.stream,
            &request_buffer,
        )) orelse continue;
        const path = parseRequestPath(request_buffer[0..request_size]) orelse {
            try connection.stream.writeAll(
                "HTTP/1.1 400 Bad Request\r\n" ++
                    "Content-Length: 0\r\n" ++
                    "Connection: close\r\n\r\n",
            );
            continue;
        };

        var event_buffer: [256]u8 = undefined;
        const event = if (reject_requests)
            try std.fmt.bufPrint(
                &event_buffer,
                "E2E_ORIGIN_REJECT={s}\n",
                .{path},
            )
        else
            try std.fmt.bufPrint(
                &event_buffer,
                "E2E_ORIGIN_REQUEST={s}\n",
                .{path},
            );
        try std.Io.File.stdout().writeStreamingAll(init.io, event);

        if (reject_requests) {
            try connection.stream.writeAll(
                "HTTP/1.1 403 Forbidden\r\n" ++
                    "Content-Length: 9\r\n" ++
                    "Connection: close\r\n\r\n" ++
                    "forbidden",
            );
            continue;
        }

        var body_buffer: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(
            &body_buffer,
            "zc-e2e-origin:{s}",
            .{path[1..]},
        );
        var response_buffer: [512]u8 = undefined;
        const response = try std.fmt.bufPrint(
            &response_buffer,
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: close\r\n" ++
                "Content-Type: text/plain\r\n\r\n" ++
                "{s}",
            .{ body.len, body },
        );
        try connection.stream.writeAll(response);
    }
}

fn parseRequiredPort(text: []const u8) !u16 {
    const port = try std.fmt.parseInt(u16, text, 10);
    if (port == 0) return error.InvalidPort;
    return port;
}

fn serveEOFResponse(
    io: std.Io,
    server: *compat.net.ReuseAddrListener,
) !void {
    const connection = try server.accept();
    defer connection.stream.close();
    var request_buffer: [64]u8 = undefined;
    var request_size: usize = 0;
    for (0..request_read_count_max) |_| {
        var descriptors = [_]std.posix.pollfd{.{
            .fd = connection.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready_count = try std.posix.poll(
            &descriptors,
            request_poll_timeout_ms,
        );
        if (ready_count == 0) continue;
        if (descriptors[0].revents &
            (std.posix.POLL.IN | std.posix.POLL.HUP) == 0)
        {
            return error.UnexpectedPollEvent;
        }
        if (request_size == request_buffer.len) {
            return error.RequestTooLarge;
        }
        const bytes_read = try connection.stream.read(
            request_buffer[request_size..],
        );
        if (bytes_read == 0) {
            if (!std.mem.eql(
                u8,
                request_buffer[0..request_size],
                eof_payload,
            )) return error.InvalidEOFPayload;
            try connection.stream.writeAll(eof_response);
            try std.Io.File.stdout().writeStreamingAll(
                io,
                "E2E_EOF_ORIGIN_RESPONSE=PASS\n",
            );
            return;
        }
        request_size = std.math.add(
            usize,
            request_size,
            bytes_read,
        ) catch return error.RequestTooLarge;
    }
    return error.DeadlineExceeded;
}

fn probeSocksEOF(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SocksEOFProbeOptions,
) !void {
    const stream = try compat.net.tcpConnectToHost(
        allocator,
        "127.0.0.1",
        options.mixed_port,
    );
    defer stream.close();

    try stream.writeAll(&.{ 5, 1, 0 });
    var greeting_response: [2]u8 = undefined;
    try readExactWithTimeout(stream, &greeting_response);
    if (!std.mem.eql(u8, &greeting_response, &.{ 5, 0 })) {
        return error.InvalidSocksGreeting;
    }

    if (options.target_host.len == 0) return error.InvalidTargetHost;
    if (options.target_host.len > 255) return error.InvalidTargetHost;
    var request: [262]u8 = undefined;
    request[0..5].* = .{
        5,
        1,
        0,
        3,
        @intCast(options.target_host.len),
    };
    @memcpy(
        request[5 .. 5 + options.target_host.len],
        options.target_host,
    );
    const port_index = 5 + options.target_host.len;
    request[port_index] = @intCast(options.target_port >> 8);
    request[port_index + 1] = @intCast(options.target_port & 0xff);
    try stream.writeAll(request[0 .. port_index + 2]);
    var connect_response: [10]u8 = undefined;
    try readExactWithTimeout(stream, &connect_response);
    const expected_connect_header = [_]u8{ 5, 0, 0, 1 };
    if (!std.mem.eql(
        u8,
        connect_response[0..expected_connect_header.len],
        &expected_connect_header,
    )) return error.InvalidSocksConnectResponse;

    try stream.writeAll(eof_payload);
    try compat.shutdownWrite(stream.handle);
    try expectEOFWithTimeout(stream);
    try std.Io.File.stdout().writeStreamingAll(
        io,
        "E2E_TROJAN_TCP_EOF_TERMINATION=PASS\n",
    );
}

fn expectEOFWithTimeout(stream: compat.net.Stream) !void {
    for (0..request_read_count_max) |_| {
        var descriptors = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready_count = try std.posix.poll(
            &descriptors,
            request_poll_timeout_ms,
        );
        if (ready_count == 0) continue;
        if (descriptors[0].revents &
            (std.posix.POLL.IN | std.posix.POLL.HUP) == 0)
        {
            return error.UnexpectedPollEvent;
        }
        var response: [eof_response.len]u8 = undefined;
        const bytes_read = try stream.read(&response);
        if (bytes_read == 0) return;
        return error.UnexpectedEOFResponse;
    }
    return error.DeadlineExceeded;
}

fn readExactWithTimeout(
    stream: compat.net.Stream,
    output: []u8,
) !void {
    var offset: usize = 0;
    for (0..request_read_count_max) |_| {
        if (offset == output.len) return;
        var descriptors = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready_count = try std.posix.poll(
            &descriptors,
            request_poll_timeout_ms,
        );
        if (ready_count == 0) continue;
        if (descriptors[0].revents &
            (std.posix.POLL.IN | std.posix.POLL.HUP) == 0)
        {
            return error.UnexpectedPollEvent;
        }
        const bytes_read = try stream.read(output[offset..]);
        if (bytes_read == 0) return error.UnexpectedEOF;
        offset = std.math.add(
            usize,
            offset,
            bytes_read,
        ) catch return error.ResponseTooLarge;
    }
    return error.DeadlineExceeded;
}

fn readRequestHeaders(
    stream: compat.net.Stream,
    buffer: []u8,
) !?usize {
    var size: usize = 0;
    var read_count: u8 = 0;
    while (read_count < request_read_count_max) : (read_count += 1) {
        var descriptors = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready_count = try std.posix.poll(
            &descriptors,
            request_poll_timeout_ms,
        );
        if (ready_count == 0) continue;
        if (descriptors[0].revents & std.posix.POLL.IN == 0) return null;
        if (size == buffer.len) return null;

        const bytes_read = try stream.read(buffer[size..]);
        if (bytes_read == 0) return null;
        size += bytes_read;
        if (std.mem.indexOf(u8, buffer[0..size], "\r\n\r\n") != null) {
            return size;
        }
    }
    return null;
}

fn parseRequestPath(request: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return null;
    var parts = std.mem.tokenizeScalar(u8, request[0..line_end], ' ');
    const method = parts.next() orelse return null;
    const path = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (!std.mem.eql(u8, method, "GET")) return null;
    if (!std.mem.eql(u8, version, "HTTP/1.1")) return null;
    if (path.len < 2) return null;
    if (path.len > request_path_size_max) return null;
    if (path[0] != '/') return null;
    for (path[1..]) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (byte == '-') continue;
        if (byte == '_') continue;
        return null;
    }
    return path;
}
