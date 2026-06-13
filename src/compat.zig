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

// ---------------------------------------------------------------------------
// D1: IPv4 UDP helpers (getsockname / recvfrom) for the UoT relay datapath.
// ---------------------------------------------------------------------------

/// A bound IPv4 endpoint: octets in network order ([0..4] order) + host-order port.
pub const BoundAddr = struct { ip: [4]u8, port: u16 };

/// One recvfrom result: bytes read + the raw IPv4 sender sockaddr.
pub const RecvFrom = struct { n: usize, addr: std.c.sockaddr.in };

/// getsockname on a bound IPv4 UDP socket. Returns the host-order port and the
/// IPv4 octets. MUST-FIX #6: the returned family must be AF.INET; anything else
/// (e.g. a v6 / unix fd handed to us by mistake) is a hard error rather than a
/// silently mis-decoded address.
pub fn udpGetSockName(fd: std.posix.fd_t) !BoundAddr {
    var sa: std.c.sockaddr.in = undefined;
    var sl: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&sa), &sl) < 0) return error.GetSockNameFailed;
    if (sa.family != std.c.AF.INET) return error.UnexpectedAddressFamily;
    const port = std.mem.bigToNative(u16, sa.port); // sa.port is network-order
    const ip: [4]u8 = @bitCast(sa.addr); // network-order octets, already [0..4]
    return .{ .ip = ip, .port = port };
}

/// recvfrom one datagram, learning the peer (sender) IPv4 address.
///
/// Error mapping (MUST-FIX #3):
///   EAGAIN/EWOULDBLOCK -> error.WouldBlock   (no data on a nonblocking socket)
///   EINTR              -> retry              (spurious interrupt)
///   EMSGSIZE / ECONNREFUSED / other non-fatal per-datagram errnos
///                      -> error.PacketDropped (caller drops THIS datagram and
///                         keeps the association alive — never folded into
///                         error.InputOutput which would kill the relay)
///   anything else      -> error.InputOutput
pub fn udpRecvFrom(fd: std.posix.fd_t, buffer: []u8) !RecvFrom {
    while (true) {
        var sa: std.c.sockaddr.in = undefined;
        var sl: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        const rc = std.c.recvfrom(fd, buffer.ptr, buffer.len, 0, @ptrCast(&sa), &sl);
        if (rc < 0) {
            switch (std.c.errno(rc)) {
                .AGAIN => return error.WouldBlock,
                .INTR => continue, // spurious interrupt: retry the syscall
                // Per-datagram, non-fatal conditions. ECONNREFUSED is the
                // ICMP port-unreachable that a prior sendto provoked; EMSGSIZE
                // is an oversized datagram. Drop the packet, keep the relay up.
                .MSGSIZE, .CONNREFUSED, .HOSTUNREACH, .NETUNREACH, .NOMEM => return error.PacketDropped,
                else => return error.InputOutput,
            }
        }
        return .{ .n = @intCast(rc), .addr = sa };
    }
}

pub fn shutdownWrite(fd: std.posix.fd_t) !void {
    if (std.c.shutdown(fd, std.c.SHUT.WR) < 0) return error.InputOutput;
}

/// A cross-platform, level-triggered readiness primitive a relay can `poll()`.
///
/// Linux: a single `eventfd(0, EFD_NONBLOCK|EFD_CLOEXEC)` whose fd serves as both
/// read and write end (`read_fd == write_fd`); `signal` adds 1 to the 64-bit
/// counter, `drain` reads it back to 0.
/// macOS/darwin: a self-pipe (`pipe()` + per-fd O_NONBLOCK / FD_CLOEXEC);
/// `read_fd = fds[0]`, `write_fd = fds[1]`; `signal` writes one byte, `drain`
/// loops reading into scratch until EAGAIN.
///
/// All I/O is raw `std.posix.write`/`std.posix.read` so EAGAIN is a plain errno
/// (a transient "already readable"/"already drained"), never an errnoBug panic.
pub const Notifier = struct {
    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t, // == read_fd on linux (eventfd)

    // EFD flags are not exposed by std.c on this toolchain; define them locally.
    const EFD_NONBLOCK: c_uint = 0o0004000; // O_NONBLOCK on linux
    const EFD_CLOEXEC: c_uint = 0o2000000; // O_CLOEXEC on linux
    const FD_CLOEXEC: c_int = 1;

    pub fn init() !Notifier {
        if (builtin.os.tag == .linux) {
            const fd = std.c.eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
            if (fd < 0) return error.NotifierInitFailed;
            return .{ .read_fd = fd, .write_fd = fd };
        } else {
            var fds: [2]std.posix.fd_t = undefined;
            if (std.c.pipe(&fds) < 0) return error.NotifierInitFailed;
            errdefer {
                _ = std.c.close(fds[0]);
                _ = std.c.close(fds[1]);
            }
            const nonblock: c_int = @bitCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
            for (fds) |fd| {
                if (std.c.fcntl(fd, std.posix.F.SETFL, nonblock) < 0) return error.NotifierInitFailed;
                if (std.c.fcntl(fd, std.posix.F.SETFD, FD_CLOEXEC) < 0) return error.NotifierInitFailed;
            }
            return .{ .read_fd = fds[0], .write_fd = fds[1] };
        }
    }

    /// Raise the readiness level. Idempotent and non-fatal: EINTR retries; EAGAIN
    /// (eventfd counter saturated / pipe full) means "already readable" and is
    /// ignored. Never errors out.
    pub fn signal(self: Notifier) void {
        if (builtin.os.tag == .linux) {
            const one: u64 = 1;
            const buf = std.mem.asBytes(&one);
            while (true) {
                const rc = std.c.write(self.write_fd, buf.ptr, buf.len);
                if (rc < 0) {
                    switch (std.c.errno(rc)) {
                        .INTR => continue,
                        else => return, // EAGAIN/saturated/closed -> already readable
                    }
                }
                return;
            }
        } else {
            const byte = [_]u8{1};
            while (true) {
                const rc = std.c.write(self.write_fd, &byte, byte.len);
                if (rc < 0) {
                    switch (std.c.errno(rc)) {
                        .INTR => continue,
                        else => return, // EAGAIN (full pipe == already readable)
                    }
                }
                return;
            }
        }
    }

    /// Lower the readiness level. eventfd: a single 8-byte read resets the
    /// counter. pipe: loop reading into scratch until EAGAIN so the level goes low.
    pub fn drain(self: Notifier) void {
        if (builtin.os.tag == .linux) {
            var val: u64 = undefined;
            const buf = std.mem.asBytes(&val);
            while (true) {
                const rc = std.c.read(self.read_fd, buf.ptr, buf.len);
                if (rc < 0) {
                    switch (std.c.errno(rc)) {
                        .INTR => continue,
                        else => return, // EAGAIN -> already drained
                    }
                }
                return;
            }
        } else {
            var scratch: [256]u8 = undefined;
            while (true) {
                const rc = std.c.read(self.read_fd, &scratch, scratch.len);
                if (rc < 0) {
                    switch (std.c.errno(rc)) {
                        .INTR => continue,
                        else => return, // EAGAIN -> fully drained
                    }
                }
                if (rc == 0) return; // EOF (write end closed) -> nothing left
                // A short read may still leave bytes; loop until EAGAIN.
            }
        }
    }

    pub fn handle(self: Notifier) std.posix.fd_t {
        return self.read_fd;
    }

    pub fn deinit(self: *Notifier) void {
        if (self.read_fd >= 0) _ = std.c.close(self.read_fd);
        if (self.write_fd != self.read_fd and self.write_fd >= 0) _ = std.c.close(self.write_fd);
        self.read_fd = -1;
        self.write_fd = -1;
    }
};

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

    /// A TCP listener created with SO_REUSEADDR but deliberately WITHOUT
    /// SO_REUSEPORT. SO_REUSEADDR lets `zc restart` rebind the port immediately
    /// while the previous instance's connections linger in TIME_WAIT; omitting
    /// SO_REUSEPORT means a second *active* listener still fails with EADDRINUSE,
    /// so two daemons can never silently bind the same port. The high-level
    /// `Address.listen(.{ .reuse_address = true })` sets BOTH options (see
    /// std/Io/Threaded.zig), which on macOS permits duplicate listeners — hence
    /// this hand-rolled libc variant.
    pub const ReuseAddrListener = struct {
        fd: std.posix.fd_t,
        listen_address: Address,

        pub fn accept(self: *ReuseAddrListener) !Server.Connection {
            var sa: std.c.sockaddr.in = undefined;
            var sa_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
            const cfd = std.c.accept(self.fd, @ptrCast(&sa), &sa_len);
            if (cfd < 0) return error.AcceptFailed;
            setCloexec(cfd);
            return .{
                .stream = Stream{ .handle = cfd },
                .address = .{ .in = .{ .sa = sa } },
            };
        }

        pub fn deinit(self: *ReuseAddrListener) void {
            _ = std.c.close(self.fd);
        }
    };

    /// FD_CLOEXEC == 1 on every POSIX target. Best-effort, mirrors the CLOEXEC
    /// default of the high-level std listener so the fd does not leak into child
    /// processes the daemon spawns.
    fn setCloexec(fd: std.posix.fd_t) void {
        _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, 1));
    }

    /// Bind + listen an IPv4 TCP address with SO_REUSEADDR-only (see
    /// `ReuseAddrListener`). Returns error.AddressInUse when an active listener
    /// already holds the port.
    pub fn listenReuseAddr(address: Address) !ReuseAddrListener {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, std.c.IPPROTO.TCP);
        if (fd < 0) return error.SocketSetupFailed;
        errdefer _ = std.c.close(fd);
        setCloexec(fd);

        var one: c_int = 1;
        if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int)) != 0)
            return error.SocketSetupFailed;

        const sa = address.in.sa;
        const brc = std.c.bind(fd, @ptrCast(&sa), @sizeOf(std.c.sockaddr.in));
        if (brc != 0) {
            return switch (std.c.errno(brc)) {
                .ADDRINUSE => error.AddressInUse,
                else => error.BindFailed,
            };
        }
        if (std.c.listen(fd, 128) != 0) return error.ListenFailed;

        // Reflect the actually-bound address (resolves an ephemeral port-0 bind).
        var bound: std.c.sockaddr.in = sa;
        var bound_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        _ = std.c.getsockname(fd, @ptrCast(&bound), &bound_len);
        return .{ .fd = fd, .listen_address = .{ .in = .{ .sa = bound } } };
    }

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

// ---------------------------------------------------------------------------
// C0: compat.Notifier tests
// ---------------------------------------------------------------------------

/// Returns true when `n`'s read handle currently reports POLL.IN (readable).
fn notifierReadable(n: Notifier) bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = n.handle(),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, 0) catch return false;
    if (ready == 0) return false;
    return (fds[0].revents & std.posix.POLL.IN) != 0;
}

test "Notifier: signal then poll(0) reports POLL.IN" {
    var n = try Notifier.init();
    defer n.deinit();
    try std.testing.expect(!notifierReadable(n)); // fresh: not readable
    n.signal();
    try std.testing.expect(notifierReadable(n));
}

test "Notifier: drain clears readability" {
    var n = try Notifier.init();
    defer n.deinit();
    n.signal();
    try std.testing.expect(notifierReadable(n));
    n.drain();
    try std.testing.expect(!notifierReadable(n));
}

test "Notifier: multiple signals collapse to a single drain (no spin)" {
    var n = try Notifier.init();
    defer n.deinit();
    n.signal();
    n.signal();
    n.signal();
    try std.testing.expect(notifierReadable(n));
    n.drain(); // one drain must leave it NOT readable
    try std.testing.expect(!notifierReadable(n));
}

test "Notifier: re-signal after drain is readable again" {
    var n = try Notifier.init();
    defer n.deinit();
    n.signal();
    n.drain();
    try std.testing.expect(!notifierReadable(n));
    n.signal();
    try std.testing.expect(notifierReadable(n));
}

test "Notifier: deinit sets fds to -1" {
    var n = try Notifier.init();
    n.deinit();
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), n.read_fd);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), n.write_fd);
}

// ---------------------------------------------------------------------------
// D1: UDP helper tests
// ---------------------------------------------------------------------------

test "D1: udpGetSockName returns AF.INET + nonzero ephemeral port" {
    const fd = try udpSocket4();
    defer posixClose(fd);
    const bnd = try udpGetSockName(fd);
    try std.testing.expect(bnd.port != 0); // ephemeral bind resolved
}

test "D1: loopback sendto -> udpRecvFrom returns sender addr + payload bytes" {
    const rx = try udpSocket4();
    defer posixClose(rx);
    const tx = try udpSocket4();
    defer posixClose(tx);

    const rx_bnd = try udpGetSockName(rx);

    // Send to 127.0.0.1:rx_port from tx.
    var dst: std.c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, rx_bnd.port),
        .addr = undefined,
    };
    dst.family = std.c.AF.INET;
    const loopback = [4]u8{ 127, 0, 0, 1 };
    @memcpy(std.mem.asBytes(&dst.addr)[0..4], &loopback);

    const payload = "hello-uot";
    _ = try posixSendTo(tx, payload, 0, @ptrCast(&dst), @sizeOf(std.c.sockaddr.in));

    // Wait until the loopback datagram is readable so recvfrom can't block the
    // whole test suite if delivery is momentarily delayed.
    var pfds = [_]std.posix.pollfd{.{ .fd = rx, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&pfds, 2000);
    try std.testing.expect((pfds[0].revents & std.posix.POLL.IN) != 0);

    var buf: [64]u8 = undefined;
    const rf = try udpRecvFrom(rx, &buf);
    try std.testing.expectEqual(payload.len, rf.n);
    try std.testing.expectEqualStrings(payload, buf[0..rf.n]);
    // Sender addr is loopback IPv4 with a nonzero source port.
    try std.testing.expectEqual(std.c.AF.INET, rf.addr.family);
    const src_ip: [4]u8 = @bitCast(rf.addr.addr);
    try std.testing.expectEqualSlices(u8, &loopback, &src_ip);
    try std.testing.expect(std.mem.bigToNative(u16, rf.addr.port) != 0);
}

test "D1: udpRecvFrom on empty nonblocking socket -> error.WouldBlock" {
    const fd = try udpSocket4();
    defer posixClose(fd);
    // udpSocket4 binds a BLOCKING dgram socket; mark it nonblocking so an empty
    // socket surfaces EAGAIN instead of blocking forever (the relay will do the
    // same before polling).
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.SetNonblockFailed;
    const nb: c_int = flags | @as(c_int, @bitCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }))));
    if (std.c.fcntl(fd, std.posix.F.SETFL, nb) < 0) return error.SetNonblockFailed;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, udpRecvFrom(fd, &buf));
}
