const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const tls = std.crypto.tls;

/// TLS 包装流 - 使用标准库的 TLS Client
pub const TlsStream = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    tls_client: tls.Client,
    read_buf: [8192]u8,
    write_buf: [8192]u8,
    read_pos: usize,
    read_len: usize,

    pub fn init(allocator: std.mem.Allocator, stream: net.Stream, host: []const u8) !TlsStream {
        var self = TlsStream{
            .allocator = allocator,
            .stream = stream,
            .tls_client = undefined,
            .read_buf = undefined,
            .write_buf = undefined,
            .read_pos = 0,
            .read_len = 0,
        };

        // 创建读写适配器
        var read_adapter = ReadAdapter{ .stream = &self.stream, .buf = &self.read_buf };
        var write_adapter = WriteAdapter{ .stream = &self.stream, .buf = &self.write_buf };

        // 执行 TLS 握手
        self.tls_client = try tls.Client.init(
            &read_adapter.reader(),
            &write_adapter.writer(),
            .{
                .host = .{ .explicit = host },
                .ca = .{ .no_verification = {} }, // 简化：跳过证书验证
            },
        );

        return self;
    }

    pub fn read(self: *TlsStream, buf: []u8) !usize {
        return try self.tls_client.read(buf);
    }

    pub fn write(self: *TlsStream, data: []const u8) !void {
        try self.tls_client.write(data);
    }

    pub fn close(self: *TlsStream) void {
        self.stream.close();
    }

    // 内部适配器结构
    const ReadAdapter = struct {
        stream: *net.Stream,
        buf: *[8192]u8,

        pub fn reader(self: *ReadAdapter) std.io.AnyReader {
            return .{
                .context = self,
                .readFn = readFn,
            };
        }

        fn readFn(context: *const anyopaque, buf: []u8) anyerror!usize {
            const self: *ReadAdapter = @constCast(@ptrCast(@alignCast(context)));
            return try self.stream.read(buf);
        }
    };

    const WriteAdapter = struct {
        stream: *net.Stream,
        buf: *[8192]u8,

        pub fn writer(self: *WriteAdapter) std.io.AnyWriter {
            return .{
                .context = self,
                .writeFn = writeFn,
            };
        }

        fn writeFn(context: *const anyopaque, data: []const u8) anyerror!usize {
            const self: *WriteAdapter = @constCast(@ptrCast(@alignCast(context)));
            try self.stream.writeAll(data);
            return data.len;
        }
    };
};
