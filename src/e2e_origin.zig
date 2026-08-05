const std = @import("std");
const compat = @import("compat.zig");

const connection_count_max: u16 = 256;
const request_read_count_max: u8 = 16;
const request_size_max: usize = 4 * 1024;
const request_poll_timeout_ms: i32 = 500;
const request_path_size_max: usize = 128;

pub fn main(init: std.process.Init) !void {
    compat.setIo(init.io);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) return error.InvalidArguments;

    const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var server = try compat.net.listenReuseAddr(address);
    defer server.deinit();

    var ready_buffer: [64]u8 = undefined;
    var reject_requests = false;
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
        if (!std.mem.eql(u8, args[1], "reject")) return error.InvalidArguments;
        reject_requests = true;
    }

    const ready = try std.fmt.bufPrint(
        &ready_buffer,
        "E2E_ORIGIN_PORT={d}\n",
        .{server.listen_address.getPort()},
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, ready);

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
