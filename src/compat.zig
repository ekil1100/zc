const std = @import("std");
const builtin = @import("builtin");

var runtime_io: ?std.Io = null;
var runtime_environ_map: ?*const std.process.Environ.Map = null;

pub fn setIo(new_io: std.Io) void {
    runtime_io = new_io;
}

pub fn setEnvironMap(environ_map: ?*const std.process.Environ.Map) void {
    runtime_environ_map = environ_map;
}

pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    return runtime_io orelse @panic("compat.io used before main initialized std.Io");
}

pub fn environMap() ?*const std.process.Environ.Map {
    return runtime_environ_map;
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (builtin.is_test) {
        if (std.testing.environ.getAlloc(allocator, name)) |value| return value else |err| switch (err) {
            error.EnvironmentVariableMissing => {},
            else => |e| return e,
        }
    }

    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const value = std.c.getenv(name_z.ptr) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(value));
}

pub fn timestamp() i64 {
    const ts = std.Io.Timestamp.now(io(), .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

pub fn nanoTimestamp() i128 {
    return std.Io.Timestamp.now(io(), .real).nanoseconds;
}

pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io(), .real).nanoseconds, std.time.ns_per_ms));
}

pub fn randomBytes(buffer: []u8) void {
    io().random(buffer);
}

pub fn writeStdoutAll(bytes: []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(bytes);
    try stdout.flush();
}

pub fn posixRead(fd: std.posix.fd_t, buffer: []u8) !usize {
    const rc = std.c.read(fd, buffer.ptr, buffer.len);
    if (rc < 0) return posixReadError(rc);
    return @intCast(rc);
}

pub fn posixWrite(fd: std.posix.fd_t, buffer: []const u8) !usize {
    const rc = std.c.write(fd, buffer.ptr, buffer.len);
    if (rc < 0) return posixWriteError(rc);
    return @intCast(rc);
}

fn posixReadError(rc: isize) anyerror {
    return switch (std.c.errno(rc)) {
        .CONNRESET => error.ConnectionResetByPeer,
        .PIPE => error.BrokenPipe,
        .BADF => error.NotOpenForReading,
        // EAGAIN/EWOULDBLOCK (e.g. SO_RCVTIMEO firing) is a transient "no data
        // yet", not a fatal I/O error. Surface it distinctly so callers can wait
        // instead of tearing the connection down.
        .AGAIN => error.WouldBlock,
        else => error.InputOutput,
    };
}

fn posixWriteError(rc: isize) anyerror {
    return switch (std.c.errno(rc)) {
        .CONNRESET => error.ConnectionResetByPeer,
        .PIPE => error.BrokenPipe,
        .BADF => error.NotOpenForWriting,
        else => error.InputOutput,
    };
}

pub fn posixClose(fd: std.posix.fd_t) void {
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    io().vtable.fileClose(io().userdata, (&file)[0..1]);
}

pub fn posixSendTo(fd: std.posix.fd_t, buffer: []const u8, flags: u32, dest_addr: ?*const std.c.sockaddr, addr_len: usize) !usize {
    const rc = std.c.sendto(fd, buffer.ptr, buffer.len, flags, dest_addr, @intCast(addr_len));
    if (rc < 0) return error.InputOutput;
    return @intCast(rc);
}

pub fn posixRecv(fd: std.posix.fd_t, buffer: []u8, flags: u32) !usize {
    const rc = std.c.recv(fd, buffer.ptr, buffer.len, @intCast(flags));
    if (rc < 0) return error.InputOutput;
    return @intCast(rc);
}

pub fn shutdownWrite(fd: std.posix.fd_t) !void {
    if (std.c.shutdown(fd, std.c.SHUT.WR) < 0) return error.InputOutput;
}

pub fn udpSocket4() !std.posix.fd_t {
    const any = try net.Address.parseIp4("0.0.0.0", 0);
    var inner = any.toIo();
    const socket = try inner.bind(io(), .{ .mode = .dgram });
    return socket.handle;
}

pub fn fileRead(file: std.Io.File, buffer: []u8) !usize {
    return posixRead(file.handle, buffer);
}

pub fn fileWriteAll(file: std.Io.File, buffer: []const u8) !void {
    var written: usize = 0;
    while (written < buffer.len) written += try posixWrite(file.handle, buffer[written..]);
}

pub fn fileSeekTo(file: std.Io.File, offset: u64) !void {
    const rc = std.c.lseek(file.handle, @intCast(offset), std.c.SEEK.SET);
    if (rc < 0) return error.InputOutput;
}

pub fn fileReadAll(file: std.Io.File, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = try fileRead(file, buffer[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}

pub fn fileReadToEndAlloc(file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (out.items.len < max_bytes) {
        const limit = @min(buf.len, max_bytes - out.items.len);
        const n = try fileRead(file, buf[0..limit]);
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

pub fn sleepNs(ns: u64) void {
    std.Io.sleep(io(), .fromNanoseconds(@intCast(ns)), .awake) catch {};
}

pub fn childRun(allocator: std.mem.Allocator, argv: []const []const u8, max_output_bytes: usize) !std.process.RunResult {
    return std.process.run(allocator, io(), .{
        .argv = argv,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    });
}

pub const fs = struct {
    pub const path = std.fs.path;
    pub const max_path_bytes = std.Io.Dir.max_path_bytes;
    pub const File = std.Io.File;

    pub const Cwd = struct {
        dir: std.Io.Dir = std.Io.Dir.cwd(),

        pub fn openFile(self: Cwd, sub_path: []const u8, options: std.Io.Dir.OpenFileOptions) !File {
            return self.dir.openFile(io(), sub_path, options);
        }

        pub fn access(self: Cwd, sub_path: []const u8, options: std.Io.Dir.AccessOptions) !void {
            return self.dir.access(io(), sub_path, options);
        }

        pub fn makePath(self: Cwd, sub_path: []const u8) !void {
            return self.dir.createDirPath(io(), sub_path);
        }

        pub fn readFileAlloc(self: Cwd, allocator: std.mem.Allocator, sub_path: []const u8, max_bytes: usize) ![]u8 {
            return self.dir.readFileAlloc(io(), sub_path, allocator, .limited(max_bytes));
        }
    };

    pub fn cwd() Cwd {
        return .{};
    }

    pub fn openFileAbsolute(path_: []const u8, options: std.Io.Dir.OpenFileOptions) !File {
        return std.Io.Dir.openFileAbsolute(io(), path_, options);
    }

    pub fn createFileAbsolute(path_: []const u8, options: std.Io.Dir.CreateFileOptions) !File {
        return std.Io.Dir.createFileAbsolute(io(), path_, options);
    }

    pub fn deleteFileAbsolute(path_: []const u8) !void {
        return std.Io.Dir.deleteFileAbsolute(io(), path_);
    }

    pub fn makeDirAbsolute(path_: []const u8) !void {
        return std.Io.Dir.createDirAbsolute(io(), path_, .default_dir);
    }

    pub fn accessAbsolute(path_: []const u8, options: std.Io.Dir.AccessOptions) !void {
        return std.Io.Dir.accessAbsolute(io(), path_, options);
    }

    pub fn openDirAbsolute(path_: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
        return std.Io.Dir.openDirAbsolute(io(), path_, options);
    }

    pub fn copyFileAbsolute(src: []const u8, dst: []const u8, options: std.Io.Dir.CopyFileOptions) !void {
        return std.Io.Dir.copyFileAbsolute(src, dst, io(), options);
    }

    pub fn symLinkAbsolute(target: []const u8, link_path: []const u8, options: std.Io.Dir.SymLinkFlags) !void {
        return std.Io.Dir.symLinkAbsolute(io(), target, link_path, options);
    }

    pub fn readLinkAbsolute(path_: []const u8, buffer: []u8) ![]u8 {
        const n = try std.Io.Dir.readLinkAbsolute(io(), path_, buffer);
        return buffer[0..n];
    }

    pub fn realpathAlloc(allocator: std.mem.Allocator, path_: []const u8) ![]u8 {
        const resolved_z = try std.Io.Dir.realPathFileAbsoluteAlloc(io(), path_, allocator);
        defer allocator.free(resolved_z);
        return allocator.dupe(u8, resolved_z);
    }

    pub fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
        return std.process.executablePathAlloc(io(), allocator);
    }
};

pub const net = struct {
    const ionet = std.Io.net;

    pub const Address = union(enum) {
        in: struct { sa: std.c.sockaddr.in },
        in6: struct { sa: std.c.sockaddr.in6 },

        pub fn parseIp4(text: []const u8, port: u16) !Address {
            const parsed = try ionet.IpAddress.parseIp4(text, port);
            return fromIo(parsed);
        }

        pub fn parseIp6(text: []const u8, port: u16) !Address {
            const parsed = try ionet.IpAddress.parseIp6(text, port);
            return fromIo(parsed);
        }

        pub fn initIp4(bytes: [4]u8, port: u16) Address {
            var sa: std.c.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, port),
                .addr = undefined,
            };
            @memcpy(std.mem.asBytes(&sa.addr), &bytes);
            return .{ .in = .{ .sa = sa } };
        }

        pub fn listen(address: Address, options: ListenOptions) !Server {
            var inner_address = address.toIo();
            const inner = try inner_address.listen(io(), .{ .reuse_address = options.reuse_address });
            return .{
                .inner = inner,
                .listen_address = fromIo(inner.socket.address),
            };
        }

        pub fn getPort(address: Address) u16 {
            return switch (address) {
                .in => |a| std.mem.bigToNative(u16, a.sa.port),
                .in6 => |a| std.mem.bigToNative(u16, a.sa.port),
            };
        }

        pub fn setPort(address: *Address, port: u16) void {
            switch (address.*) {
                .in => |*a| a.sa.port = std.mem.nativeToBig(u16, port),
                .in6 => |*a| a.sa.port = std.mem.nativeToBig(u16, port),
            }
        }

        pub fn toIo(address: Address) ionet.IpAddress {
            return switch (address) {
                .in => |a| .{ .ip4 = .{
                    .bytes = std.mem.asBytes(&a.sa.addr)[0..4].*,
                    .port = std.mem.bigToNative(u16, a.sa.port),
                } },
                .in6 => |a| .{ .ip6 = .{
                    .bytes = a.sa.addr,
                    .port = std.mem.bigToNative(u16, a.sa.port),
                } },
            };
        }

        fn fromIo(address: ionet.IpAddress) Address {
            return switch (address) {
                .ip4 => |ip4| initIp4(ip4.bytes, ip4.port),
                .ip6 => |ip6| blk: {
                    const sa: std.c.sockaddr.in6 = .{
                        .port = std.mem.nativeToBig(u16, ip6.port),
                        .flowinfo = 0,
                        .addr = ip6.bytes,
                        .scope_id = 0,
                    };
                    break :blk .{ .in6 = .{ .sa = sa } };
                },
            };
        }
    };

    pub const ListenOptions = struct {
        reuse_address: bool = false,
    };

    pub const Stream = struct {
        handle: std.posix.fd_t,

        pub const Reader = ionet.Stream.Reader;
        pub const Writer = ionet.Stream.Writer;

        pub fn fromIo(inner: ionet.Stream) Stream {
            return .{ .handle = inner.socket.handle };
        }

        pub fn read(stream: Stream, buffer: []u8) !usize {
            return posixRead(stream.handle, buffer);
        }

        pub fn write(stream: Stream, buffer: []const u8) !usize {
            return posixWrite(stream.handle, buffer);
        }

        pub fn writeAll(stream: Stream, buffer: []const u8) !void {
            var written: usize = 0;
            while (written < buffer.len) {
                written += try stream.write(buffer[written..]);
            }
        }

        fn toIoStream(stream: Stream) ionet.Stream {
            return .{ .socket = .{ .handle = stream.handle, .address = undefined } };
        }

        pub fn reader(stream: Stream, buffer: []u8) Reader {
            return stream.toIoStream().reader(io(), buffer);
        }

        pub fn writer(stream: Stream, buffer: []u8) Writer {
            return stream.toIoStream().writer(io(), buffer);
        }

        pub fn close(stream: Stream) void {
            io().vtable.netClose(io().userdata, (&stream.handle)[0..1]);
        }
    };

    pub const Server = struct {
        inner: ionet.Server,
        listen_address: Address,

        pub const Connection = struct {
            stream: Stream,
            address: Address,
        };

        pub fn accept(server: *Server) !Connection {
            const accepted = try server.inner.accept(io());
            return .{
                .stream = Stream.fromIo(accepted),
                .address = Address.fromIo(accepted.socket.address),
            };
        }

        pub fn deinit(server: *Server) void {
            server.inner.deinit(io());
        }
    };

    pub const AddressList = struct {
        addrs: []Address,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *AddressList) void {
            self.allocator.free(self.addrs);
        }
    };

    pub fn tcpConnectToAddress(address: Address) !Stream {
        var inner_address = address.toIo();
        const stream = try inner_address.connect(io(), .{ .mode = .stream });
        return Stream.fromIo(stream);
    }

    pub fn tcpConnectToHost(allocator: std.mem.Allocator, host: []const u8, port: u16) !Stream {
        _ = allocator;
        if (Address.parseIp4(host, port)) |address| return tcpConnectToAddress(address) else |_| {}
        if (Address.parseIp6(host, port)) |address| return tcpConnectToAddress(address) else |_| {}
        const host_name = try ionet.HostName.init(host);
        const stream = try host_name.connect(io(), port, .{ .mode = .stream });
        return Stream.fromIo(stream);
    }

    pub fn getAddressList(allocator: std.mem.Allocator, host: []const u8, port: u16) !AddressList {
        var list = std.ArrayList(Address).empty;
        errdefer list.deinit(allocator);

        if (Address.parseIp4(host, port)) |address| {
            try list.append(allocator, address);
        } else |_| if (Address.parseIp6(host, port)) |address| {
            try list.append(allocator, address);
        } else |_| {
            const host_name = try ionet.HostName.init(host);
            var lookup_buffer: [32]ionet.HostName.LookupResult = undefined;
            var lookup_queue: std.Io.Queue(ionet.HostName.LookupResult) = .init(&lookup_buffer);
            try host_name.lookup(io(), &lookup_queue, .{ .port = port });
            while (lookup_queue.getOne(io())) |result| switch (result) {
                .address => |addr| try list.append(allocator, Address.fromIo(addr)),
                .canonical_name => {},
            } else |err| switch (err) {
                error.Closed => {},
                else => |e| return e,
            }
        }

        return .{
            .addrs = try list.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }
};
