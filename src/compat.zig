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

pub fn setDirPermissions(dir: std.Io.Dir, permissions: std.Io.File.Permissions) !void {
    const writable = try dir.openDir(io(), ".", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer writable.close(io());
    try writable.setPermissions(io(), permissions);
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
    return @intCast(@divTrunc(
        std.Io.Timestamp.now(io(), .real).nanoseconds,
        std.time.ns_per_ms,
    ));
}

pub fn monotonicMilliTimestamp() i64 {
    return @intCast(@divTrunc(
        std.Io.Timestamp.now(io(), .awake).nanoseconds,
        std.time.ns_per_ms,
    ));
}

const SystemPollOps = struct {
    fn now(_: *@This()) i64 {
        return monotonicMilliTimestamp();
    }

    fn poll(
        _: *@This(),
        descriptors: []std.posix.pollfd,
        timeout_ms: i32,
    ) !usize {
        const result = std.c.poll(
            descriptors.ptr,
            @intCast(descriptors.len),
            timeout_ms,
        );
        if (result >= 0) return @intCast(result);
        return switch (std.c.errno(result)) {
            .INTR => error.Interrupted,
            .NOMEM => error.SystemResources,
            else => error.PollFailed,
        };
    }
};

/// Polls until an absolute awake-clock millisecond deadline. Unlike
/// `std.posix.poll`, an EINTR cannot restart the original relative timeout:
/// every retry clears stale revents and derives a new bounded timeout from the
/// same monotonic deadline.
pub fn pollUntil(
    descriptors: []std.posix.pollfd,
    deadline_ms: i64,
) !usize {
    var ops = SystemPollOps{};
    return pollUntilUsing(SystemPollOps, &ops, descriptors, deadline_ms);
}

/// Explicit absolute-deadline spelling used by bounded socket paths.
pub fn pollAbsolute(
    descriptors: []std.posix.pollfd,
    deadline_ms: i64,
) !usize {
    return pollUntil(descriptors, deadline_ms);
}

fn pollUntilUsing(
    comptime Ops: type,
    ops: *Ops,
    descriptors: []std.posix.pollfd,
    deadline_ms: i64,
) !usize {
    while (true) {
        const now_ms = ops.now();
        if (now_ms >= deadline_ms) return 0;
        const remaining_ms = std.math.sub(i64, deadline_ms, now_ms) catch
            return 0;
        const timeout_ms: i32 = @intCast(@min(
            remaining_ms,
            @as(i64, std.math.maxInt(i32)),
        ));
        for (descriptors) |*descriptor| descriptor.revents = 0;
        const ready = ops.poll(descriptors, timeout_ms) catch |err| switch (err) {
            error.Interrupted => continue,
            else => |other| return other,
        };
        if (ready != 0) return ready;
        // A timeout clamped to i32 may expire before the absolute deadline;
        // clock granularity can also wake a millisecond early.
        if (ops.now() >= deadline_ms) return 0;
    }
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

/// Writes to a connected socket without allowing peer closure to terminate the
/// process via SIGPIPE. Darwin sockets are configured with SO_NOSIGPIPE when
/// created/accepted below; Linux and other supporting targets use MSG_NOSIGNAL.
pub fn posixSocketWrite(fd: std.posix.fd_t, buffer: []const u8) !usize {
    const flags: u32 = if (@hasDecl(std.c.MSG, "NOSIGNAL"))
        @intCast(std.c.MSG.NOSIGNAL)
    else
        0;
    while (true) {
        const rc = std.c.send(fd, buffer.ptr, buffer.len, flags);
        if (rc >= 0) return @intCast(rc);
        if (std.c.errno(rc) == .INTR) continue;
        return posixWriteError(rc);
    }
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
        .AGAIN => error.WouldBlock,
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

/// Set O_NONBLOCK on a socket fd. udpSocket4() returns a BLOCKING socket on this
/// toolchain (std.Io.Threaded), so the poll-driven UoT relay MUST mark its client
/// UDP socket nonblocking before polling — otherwise recvfrom blocks the worker.
pub fn setNonBlock(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.SetNonblockFailed;
    const nb: c_int = flags | @as(c_int, @bitCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }))));
    if (std.c.fcntl(fd, std.posix.F.SETFL, nb) < 0) return error.SetNonblockFailed;
}

pub fn setAppend(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.SetAppendFailed;
    const append: c_int = flags |
        @as(c_int, @bitCast(@as(u32, @bitCast(std.posix.O{ .APPEND = true }))));
    if (std.c.fcntl(fd, std.posix.F.SETFL, append) < 0) {
        return error.SetAppendFailed;
    }
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

/// Read a whole file up to an explicit limit. Unlike fileReadToEndAlloc, this
/// probes past the limit and reports oversized input instead of truncating it.
pub fn fileReadBoundedAlloc(file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (out.items.len < max_bytes) {
        const limit = @min(buf.len, max_bytes - out.items.len);
        const n = try fileRead(file, buf[0..limit]);
        if (n == 0) return out.toOwnedSlice(allocator);
        try out.appendSlice(allocator, buf[0..n]);
    }

    var extra: [1]u8 = undefined;
    if (try fileRead(file, &extra) != 0) return error.FileTooLarge;
    return out.toOwnedSlice(allocator);
}

test "setDirPermissions supports path-only directory handles" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try setDirPermissions(tmp.dir, std.Io.File.Permissions.fromMode(0o700));
    const writable = try tmp.dir.openDir(io(), ".", .{ .iterate = true });
    defer writable.close(io());
    const stat = try writable.stat(io());
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
}

test "strict bounded file read accepts the limit and rejects one byte more" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile(io(), "exact", .{});
        defer file.close(io());
        try fileWriteAll(file, "1234");
    }
    {
        const file = try tmp.dir.openFile(io(), "exact", .{});
        defer file.close(io());
        const bytes = try fileReadBoundedAlloc(file, std.testing.allocator, 4);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("1234", bytes);
    }
    {
        const file = try tmp.dir.openFile(io(), "exact", .{});
        defer file.close(io());
        try std.testing.expectError(error.FileTooLarge, fileReadBoundedAlloc(file, std.testing.allocator, 3));
    }
}

test "strict bounded file read handles a zero byte limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile(io(), "empty", .{});
        file.close(io());
    }
    {
        const file = try tmp.dir.openFile(io(), "empty", .{});
        defer file.close(io());
        const bytes = try fileReadBoundedAlloc(file, std.testing.allocator, 0);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(@as(usize, 0), bytes.len);
    }
    {
        const file = try tmp.dir.createFile(io(), "one", .{});
        defer file.close(io());
        try fileWriteAll(file, "x");
    }
    {
        const file = try tmp.dir.openFile(io(), "one", .{});
        defer file.close(io());
        try std.testing.expectError(error.FileTooLarge, fileReadBoundedAlloc(file, std.testing.allocator, 0));
    }
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

    fn configureSocketWriteSafety(fd: std.posix.fd_t) !void {
        if (comptime builtin.os.tag.isDarwin()) {
            comptime if (!@hasDecl(std.c.SO, "NOSIGPIPE")) {
                @compileError("Darwin socket writes require SO_NOSIGPIPE");
            };
            var enabled: c_int = 1;
            if (std.c.setsockopt(
                fd,
                std.c.SOL.SOCKET,
                std.c.SO.NOSIGPIPE,
                &enabled,
                @sizeOf(c_int),
            ) != 0) return error.SocketSetupFailed;
        }
    }

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

        pub fn initIp6(bytes: [16]u8, port: u16) Address {
            const sa: std.c.sockaddr.in6 = .{
                .port = std.mem.nativeToBig(u16, port),
                .flowinfo = 0,
                .addr = bytes,
                .scope_id = 0,
            };
            return .{ .in6 = .{ .sa = sa } };
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
                .ip6 => |ip6| initIp6(ip6.bytes, ip6.port),
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
            return posixSocketWrite(stream.handle, buffer);
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
            errdefer accepted.close(io());
            try configureSocketWriteSafety(accepted.socket.handle);
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
            while (true) {
                var sa: std.c.sockaddr.in = undefined;
                var sa_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
                const cfd = std.c.accept(self.fd, @ptrCast(&sa), &sa_len);
                if (cfd < 0) switch (std.c.errno(cfd)) {
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    .CONNABORTED => return error.ConnectionAborted,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    else => return error.AcceptFailed,
                };
                setCloexec(cfd);
                configureSocketWriteSafety(cfd) catch |err| {
                    _ = std.c.close(cfd);
                    return err;
                };
                return .{
                    .stream = Stream{ .handle = cfd },
                    .address = .{ .in = .{ .sa = sa } },
                };
            }
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

    const darwin_address_result_count_max: usize = 64;
    const DarwinDnsServiceRef = ?*anyopaque;
    const DarwinDnsFlags = u32;
    const DarwinDnsProtocol = u32;
    const DarwinDnsError = i32;
    const darwin_dns_flags_more_coming: DarwinDnsFlags = 0x1;
    const darwin_dns_flags_add: DarwinDnsFlags = 0x2;
    const darwin_dns_protocol_ipv4: DarwinDnsProtocol = 0x01;
    const darwin_dns_protocol_ipv6: DarwinDnsProtocol = 0x02;
    const darwin_dns_error_no_error: DarwinDnsError = 0;
    const darwin_dns_error_no_such_name: DarwinDnsError = -65538;
    const darwin_dns_error_no_memory: DarwinDnsError = -65539;
    const darwin_dns_error_timeout: DarwinDnsError = -65568;
    const DarwinDnsGetAddrInfoReply = *const fn (
        sd_ref: DarwinDnsServiceRef,
        flags: DarwinDnsFlags,
        interface_index: u32,
        error_code: DarwinDnsError,
        hostname: ?[*:0]const u8,
        address: ?*const std.c.sockaddr,
        ttl: u32,
        context: ?*anyopaque,
    ) callconv(.c) void;

    // Exact C ABI and constants from Apple's dns_sd.h. These declarations are
    // instantiated only for Darwin; libSystem already exports the symbols.
    const DarwinDnsApi = if (builtin.os.tag.isDarwin()) struct {
        extern fn DNSServiceGetAddrInfo(
            sd_ref: *DarwinDnsServiceRef,
            flags: DarwinDnsFlags,
            interface_index: u32,
            protocol: DarwinDnsProtocol,
            hostname: [*:0]const u8,
            callback: DarwinDnsGetAddrInfoReply,
            context: ?*anyopaque,
        ) callconv(.c) DarwinDnsError;
        extern fn DNSServiceRefSockFD(
            sd_ref: DarwinDnsServiceRef,
        ) callconv(.c) c_int;
        extern fn DNSServiceProcessResult(
            sd_ref: DarwinDnsServiceRef,
        ) callconv(.c) DarwinDnsError;
        extern fn DNSServiceRefDeallocate(
            sd_ref: DarwinDnsServiceRef,
        ) callconv(.c) void;

        fn start(
            _: *@This(),
            sd_ref: *DarwinDnsServiceRef,
            hostname: [*:0]const u8,
            callback: DarwinDnsGetAddrInfoReply,
            context: ?*anyopaque,
        ) !void {
            const result = DNSServiceGetAddrInfo(
                sd_ref,
                0,
                0,
                darwin_dns_protocol_ipv4 | darwin_dns_protocol_ipv6,
                hostname,
                callback,
                context,
            );
            if (result != darwin_dns_error_no_error) return mapDarwinDnsError(result);
        }

        fn socketFd(_: *@This(), sd_ref: DarwinDnsServiceRef) !std.posix.fd_t {
            const fd = DNSServiceRefSockFD(sd_ref);
            if (fd < 0) return error.AddressResolutionFailed;
            return fd;
        }

        fn process(_: *@This(), sd_ref: DarwinDnsServiceRef) !void {
            const result = DNSServiceProcessResult(sd_ref);
            if (result != darwin_dns_error_no_error) return mapDarwinDnsError(result);
        }

        fn deallocate(_: *@This(), sd_ref: DarwinDnsServiceRef) void {
            DNSServiceRefDeallocate(sd_ref);
        }

        fn wait(
            _: *@This(),
            descriptors: []std.posix.pollfd,
            deadline_ms: i64,
        ) !usize {
            return pollUntil(descriptors, deadline_ms);
        }
    } else struct {};

    const DarwinAddressContext = struct {
        allocator: std.mem.Allocator,
        port: u16,
        addresses: std.ArrayList(Address) = .empty,
        callback_error: ?anyerror = null,
        batch_complete: bool = false,

        fn deinit(self: *@This()) void {
            self.addresses.deinit(self.allocator);
        }
    };

    fn mapDarwinDnsError(code: DarwinDnsError) anyerror {
        return switch (code) {
            darwin_dns_error_no_error => unreachable,
            darwin_dns_error_no_such_name => error.UnknownHostName,
            darwin_dns_error_no_memory => error.OutOfMemory,
            darwin_dns_error_timeout => error.AddressResolutionTimeout,
            else => error.AddressResolutionFailed,
        };
    }

    fn darwinAddressCallback(
        _: DarwinDnsServiceRef,
        flags: DarwinDnsFlags,
        _: u32,
        error_code: DarwinDnsError,
        _: ?[*:0]const u8,
        raw_address: ?*const std.c.sockaddr,
        _: u32,
        opaque_context: ?*anyopaque,
    ) callconv(.c) void {
        const context: *DarwinAddressContext = @ptrCast(@alignCast(
            opaque_context orelse return,
        ));
        defer if (flags & darwin_dns_flags_more_coming == 0) {
            context.batch_complete = true;
        };
        if (context.callback_error != null) return;
        if (error_code != 0) {
            context.callback_error = mapDarwinDnsError(error_code);
            return;
        }
        // Ignore removal notifications; this bounded one-shot resolver ends
        // after the first immediately available result batch.
        if (flags & darwin_dns_flags_add == 0) return;
        const address = raw_address orelse {
            context.callback_error = error.AddressResolutionFailed;
            return;
        };
        if (context.addresses.items.len >= darwin_address_result_count_max) {
            context.callback_error = error.AddressResolutionResultLimitExceeded;
            return;
        }
        const converted: Address = if (address.family == std.c.AF.INET) blk: {
            const source: *const std.c.sockaddr.in = @ptrCast(@alignCast(address));
            var value = source.*;
            value.port = std.mem.nativeToBig(u16, context.port);
            break :blk .{ .in = .{ .sa = value } };
        } else if (address.family == std.c.AF.INET6) blk: {
            const source: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(address));
            var value = source.*;
            value.port = std.mem.nativeToBig(u16, context.port);
            break :blk .{ .in6 = .{ .sa = value } };
        } else return;
        context.addresses.append(context.allocator, converted) catch |err| {
            context.callback_error = err;
        };
    }

    fn getDarwinAddressListWithTimeoutUsing(
        comptime Ops: type,
        ops: *Ops,
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        timeout_ms: u32,
    ) !AddressList {
        // Keep the test seam fail-closed too: DNSService accepts a C string and
        // would otherwise silently truncate an embedded NUL or accept names
        // that Zig's native resolver rejects.
        _ = try ionet.HostName.init(host);
        const deadline_ms = std.math.add(
            i64,
            monotonicMilliTimestamp(),
            @intCast(timeout_ms),
        ) catch std.math.maxInt(i64);
        const hostname = try allocator.dupeZ(u8, host);
        defer allocator.free(hostname);
        if (monotonicMilliTimestamp() >= deadline_ms) {
            return error.AddressResolutionTimeout;
        }

        var context = DarwinAddressContext{
            .allocator = allocator,
            .port = port,
        };
        defer context.deinit();
        var sd_ref: DarwinDnsServiceRef = null;
        try ops.start(&sd_ref, hostname, darwinAddressCallback, &context);
        std.debug.assert(sd_ref != null);
        defer ops.deallocate(sd_ref);
        const fd = try ops.socketFd(sd_ref);

        while (!context.batch_complete) {
            var descriptors = [_]std.posix.pollfd{.{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try ops.wait(&descriptors, deadline_ms);
            if (ready == 0) return error.AddressResolutionTimeout;
            const revents = descriptors[0].revents;
            if (revents & std.posix.POLL.NVAL != 0) {
                return error.AddressResolutionFailed;
            }
            if (revents & std.posix.POLL.IN == 0) {
                if (revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
                    return error.AddressResolutionFailed;
                }
                continue;
            }
            try ops.process(sd_ref);
            if (context.callback_error) |err| return err;
        }
        if (context.callback_error) |err| return err;
        if (context.addresses.items.len == 0) return error.UnknownHostName;
        return .{
            .addrs = try context.addresses.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    fn singleAddressList(
        allocator: std.mem.Allocator,
        address: Address,
    ) !AddressList {
        const addresses = try allocator.alloc(Address, 1);
        addresses[0] = address;
        return .{ .addrs = addresses, .allocator = allocator };
    }

    const AddressListTimeoutEvent = union(enum) {
        addresses: anyerror!AddressList,
        deadline: anyerror!void,
    };

    const SystemAddressListResolver = struct {
        deadline: std.Io.Clock.Timestamp,

        fn init(timeout_ms: u32) SystemAddressListResolver {
            return .{ .deadline = .fromNow(io(), .{
                .raw = .fromMilliseconds(timeout_ms),
                .clock = .awake,
            }) };
        }

        fn resolve(
            _: *@This(),
            allocator: std.mem.Allocator,
            host: []const u8,
            port: u16,
        ) !AddressList {
            return getAddressList(allocator, host, port);
        }

        fn wait(self: *@This(), _: u32) !void {
            try self.deadline.wait(io());
        }
    };

    pub fn tcpConnectToAddress(address: Address) !Stream {
        var inner_address = address.toIo();
        const stream = try inner_address.connect(io(), .{ .mode = .stream });
        errdefer stream.close(io());
        try configureSocketWriteSafety(stream.socket.handle);
        return Stream.fromIo(stream);
    }

    pub fn tcpConnectToAddressWithTimeout(
        address: Address,
        timeout_ms: u32,
    ) !Stream {
        if (timeout_ms == 0) return error.Timeout;
        const deadline_ms = std.math.add(
            i64,
            monotonicMilliTimestamp(),
            @intCast(timeout_ms),
        ) catch std.math.maxInt(i64);

        const fd = switch (address) {
            .in => std.c.socket(
                std.c.AF.INET,
                std.c.SOCK.STREAM,
                std.c.IPPROTO.TCP,
            ),
            .in6 => std.c.socket(
                std.c.AF.INET6,
                std.c.SOCK.STREAM,
                std.c.IPPROTO.TCP,
            ),
        };
        if (fd < 0) return error.SocketSetupFailed;
        errdefer _ = std.c.close(fd);
        setCloexec(fd);
        try configureSocketWriteSafety(fd);
        try setNonBlock(fd);

        const connect_result = switch (address) {
            .in => |value| std.c.connect(
                fd,
                @ptrCast(&value.sa),
                @sizeOf(std.c.sockaddr.in),
            ),
            .in6 => |value| std.c.connect(
                fd,
                @ptrCast(&value.sa),
                @sizeOf(std.c.sockaddr.in6),
            ),
        };
        if (connect_result < 0) switch (std.c.errno(connect_result)) {
            .INPROGRESS, .ALREADY, .AGAIN, .INTR => {
                while (true) {
                    var descriptors = [_]std.posix.pollfd{.{
                        .fd = fd,
                        .events = std.posix.POLL.OUT,
                        .revents = 0,
                    }};
                    const ready = try pollUntil(&descriptors, deadline_ms);
                    if (ready == 0) return error.Timeout;
                    const revents = descriptors[0].revents;
                    if (revents & std.posix.POLL.NVAL != 0) {
                        return error.InvalidSocket;
                    }
                    if (revents & (std.posix.POLL.OUT |
                        std.posix.POLL.ERR |
                        std.posix.POLL.HUP) == 0)
                    {
                        continue;
                    }

                    var socket_error: c_int = 0;
                    var socket_error_len: std.c.socklen_t = @sizeOf(c_int);
                    if (std.c.getsockopt(
                        fd,
                        std.c.SOL.SOCKET,
                        std.c.SO.ERROR,
                        &socket_error,
                        &socket_error_len,
                    ) != 0) return error.SocketSetupFailed;
                    if (socket_error != 0) {
                        return tcpConnectError(@enumFromInt(socket_error));
                    }
                    break;
                }
            },
            .ISCONN => {},
            else => |err| return tcpConnectError(err),
        };

        if (monotonicMilliTimestamp() >= deadline_ms) return error.Timeout;
        try setBlocking(fd);
        return .{ .handle = fd };
    }

    fn setBlocking(fd: std.posix.fd_t) !void {
        const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
        if (flags < 0) return error.SetNonblockFailed;
        const nonblock: c_int = @bitCast(@as(
            u32,
            @bitCast(std.posix.O{ .NONBLOCK = true }),
        ));
        if (std.c.fcntl(fd, std.posix.F.SETFL, flags & ~nonblock) < 0) {
            return error.SetNonblockFailed;
        }
    }

    fn tcpConnectError(err: std.c.E) anyerror {
        return switch (err) {
            .ADDRNOTAVAIL => error.AddressUnavailable,
            .AFNOSUPPORT => error.AddressFamilyUnsupported,
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET => error.ConnectionResetByPeer,
            .HOSTUNREACH => error.HostUnreachable,
            .NETUNREACH => error.NetworkUnreachable,
            .TIMEDOUT => error.Timeout,
            .ACCES, .PERM => error.AccessDenied,
            .NOBUFS, .NOMEM => error.SystemResources,
            else => error.ConnectFailed,
        };
    }

    pub fn tcpConnectToHost(allocator: std.mem.Allocator, host: []const u8, port: u16) !Stream {
        _ = allocator;
        if (Address.parseIp4(host, port)) |address| return tcpConnectToAddress(address) else |_| {}
        if (Address.parseIp6(host, port)) |address| return tcpConnectToAddress(address) else |_| {}
        const host_name = try ionet.HostName.init(host);
        const stream = try host_name.connect(io(), port, .{ .mode = .stream });
        errdefer stream.close(io());
        try configureSocketWriteSafety(stream.socket.handle);
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

    /// Resolves a host under one awake-clock timeout. Select owns both tasks;
    /// cancel waits for the losing task and every queued AddressList is drained
    /// and deinitialized before return, including a lookup/timeout completion
    /// race. No detached resolver thread can outlive the caller.
    pub fn getAddressListWithTimeout(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        timeout_ms: u32,
    ) !AddressList {
        if (timeout_ms == 0) return error.AddressResolutionTimeout;
        // Numeric literals never enter either asynchronous resolver.
        if (Address.parseIp4(host, port)) |address| {
            return singleAddressList(allocator, address);
        } else |_| {}
        if (Address.parseIp6(host, port)) |address| {
            return singleAddressList(allocator, address);
        } else |_| {}

        // Validate once, before selecting the OS resolver. In particular,
        // Darwin's DNSService C-string API must reject exactly the same
        // embedded-NUL, invalid-label, and overlong inputs as std's resolver.
        _ = try ionet.HostName.init(host);

        if (comptime builtin.os.tag.isDarwin()) {
            var ops = DarwinDnsApi{};
            return getDarwinAddressListWithTimeoutUsing(
                DarwinDnsApi,
                &ops,
                allocator,
                host,
                port,
                timeout_ms,
            );
        }

        // std.Io.Threaded uses Zig's native cancellable DNS implementation on
        // Linux, so Select cancellation remains bounded there.
        var resolver = SystemAddressListResolver.init(timeout_ms);
        return getAddressListWithTimeoutUsing(
            SystemAddressListResolver,
            &resolver,
            allocator,
            host,
            port,
            timeout_ms,
        );
    }

    fn getAddressListWithTimeoutUsing(
        comptime Resolver: type,
        resolver: *Resolver,
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        timeout_ms: u32,
    ) !AddressList {
        if (timeout_ms == 0) return error.AddressResolutionTimeout;

        const Workers = struct {
            fn resolve(
                worker_resolver: *Resolver,
                worker_allocator: std.mem.Allocator,
                worker_host: []const u8,
                worker_port: u16,
            ) anyerror!AddressList {
                return Resolver.resolve(
                    worker_resolver,
                    worker_allocator,
                    worker_host,
                    worker_port,
                );
            }

            fn deadline(
                worker_resolver: *Resolver,
                worker_timeout_ms: u32,
            ) anyerror!void {
                return Resolver.wait(worker_resolver, worker_timeout_ms);
            }
        };

        var event_buffer: [2]AddressListTimeoutEvent = undefined;
        var select: std.Io.Select(AddressListTimeoutEvent) = .init(
            io(),
            &event_buffer,
        );
        select.async(
            .addresses,
            Workers.resolve,
            .{ resolver, allocator, host, port },
        );
        select.async(.deadline, Workers.deadline, .{ resolver, timeout_ms });

        const winner = select.await() catch |err| {
            drainAddressListSelect(&select);
            return err;
        };
        return switch (winner) {
            .addresses => |result| addresses: {
                const value = result catch |err| {
                    drainAddressListSelect(&select);
                    return err;
                };
                drainAddressListSelect(&select);
                break :addresses value;
            },
            .deadline => |result| {
                result catch |err| {
                    drainAddressListSelect(&select);
                    return err;
                };
                drainAddressListSelect(&select);
                return error.AddressResolutionTimeout;
            },
        };
    }

    fn drainAddressListSelect(
        select: *std.Io.Select(AddressListTimeoutEvent),
    ) void {
        while (select.cancel()) |event| switch (event) {
            .addresses => |result| {
                if (result) |value| {
                    var addresses = value;
                    addresses.deinit();
                } else |_| {}
            },
            .deadline => {},
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

test "append mode survives external copytruncate" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io(), "daemon.log", .{
        .read = true,
    });
    defer file.close(io());
    try setAppend(file.handle);
    try fileWriteAll(file, "before");
    if (std.c.ftruncate(file.handle, 0) != 0) return error.TruncateFailed;
    try fileWriteAll(file, "after");

    const bytes = try tmp.dir.readFileAlloc(
        io(),
        "daemon.log",
        allocator,
        .limited(32),
    );
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("after", bytes);
}

test "pollUntil recomputes the absolute deadline after repeated EINTR" {
    const FakePollOps = struct {
        now_ms: i64 = 1_000,
        calls: usize = 0,
        timeouts: [3]i32 = undefined,

        fn now(self: *@This()) i64 {
            return self.now_ms;
        }

        fn poll(
            self: *@This(),
            _: []std.posix.pollfd,
            timeout_ms: i32,
        ) !usize {
            self.timeouts[self.calls] = timeout_ms;
            self.calls += 1;
            const elapsed: i64 = @min(@as(i64, timeout_ms), 40);
            self.now_ms += elapsed;
            if (self.calls < 3) return error.Interrupted;
            return 0;
        }
    };

    var ops = FakePollOps{};
    var descriptors = [_]std.posix.pollfd{.{
        .fd = -1,
        .events = std.posix.POLL.IN,
        .revents = std.posix.POLL.IN,
    }};
    const ready = try pollUntilUsing(
        FakePollOps,
        &ops,
        &descriptors,
        1_100,
    );
    try std.testing.expectEqual(@as(usize, 0), ready);
    try std.testing.expectEqual(@as(usize, 3), ops.calls);
    try std.testing.expectEqualSlices(
        i32,
        &.{ 100, 60, 20 },
        &ops.timeouts,
    );
    try std.testing.expectEqual(@as(i64, 1_100), ops.now_ms);
    try std.testing.expectEqual(@as(i16, 0), descriptors[0].revents);

    const stable_timeout: anyerror!void = if (ready == 0)
        error.TestSocketTimeout
    else {};
    try std.testing.expectError(error.TestSocketTimeout, stable_timeout);
}

test "getAddressListWithTimeout resolves a numeric address" {
    var addresses = try net.getAddressListWithTimeout(
        std.testing.allocator,
        "127.0.0.1",
        8388,
        100,
    );
    defer addresses.deinit();

    try std.testing.expectEqual(@as(usize, 1), addresses.addrs.len);
    try std.testing.expectEqual(@as(u16, 8388), net.Address.getPort(addresses.addrs[0]));
}

test "getAddressListWithTimeout validates hostnames before the OS resolver" {
    const InvalidDarwinOps = struct {
        starts: usize = 0,

        fn start(
            self: *@This(),
            _: *net.DarwinDnsServiceRef,
            _: [*:0]const u8,
            _: net.DarwinDnsGetAddrInfoReply,
            _: ?*anyopaque,
        ) !void {
            self.starts += 1;
            return error.TestUnexpectedResolverStart;
        }

        fn socketFd(_: *@This(), _: net.DarwinDnsServiceRef) !std.posix.fd_t {
            return error.TestUnexpectedSocketFd;
        }

        fn wait(_: *@This(), _: []std.posix.pollfd, _: i64) !usize {
            return error.TestUnexpectedWait;
        }

        fn process(_: *@This(), _: net.DarwinDnsServiceRef) !void {
            return error.TestUnexpectedProcess;
        }

        fn deallocate(_: *@This(), _: net.DarwinDnsServiceRef) void {}
    };

    const invalid_names = [_]struct {
        host: []const u8,
        expected: anyerror,
    }{
        .{ .host = "nul\x00suffix.example", .expected = error.InvalidHostName },
        .{ .host = "-invalid.example", .expected = error.InvalidHostName },
        .{ .host = ("a" ** 64) ++ ".example", .expected = error.InvalidHostName },
        .{ .host = ("a." ** 127) ++ "ab", .expected = error.NameTooLong },
    };

    for (invalid_names) |invalid| {
        try std.testing.expectError(
            invalid.expected,
            net.getAddressListWithTimeout(
                std.testing.allocator,
                invalid.host,
                53,
                100,
            ),
        );

        var ops = InvalidDarwinOps{};
        try std.testing.expectError(
            invalid.expected,
            net.getDarwinAddressListWithTimeoutUsing(
                InvalidDarwinOps,
                &ops,
                std.testing.allocator,
                invalid.host,
                53,
                100,
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), ops.starts);
    }
}

test "Darwin DNSService resolver returns bounded localhost addresses with the requested port" {
    if (!builtin.os.tag.isDarwin()) return;
    var addresses = try net.getAddressListWithTimeout(
        std.testing.allocator,
        "localhost",
        4242,
        2_000,
    );
    defer addresses.deinit();

    try std.testing.expect(addresses.addrs.len > 0);
    try std.testing.expect(
        addresses.addrs.len <= net.darwin_address_result_count_max,
    );
    for (addresses.addrs) |address| {
        try std.testing.expectEqual(@as(u16, 4242), address.getPort());
    }
}

test "Darwin DNSService timeout seam deallocates the active query" {
    if (!builtin.os.tag.isDarwin()) return;
    const TimeoutOps = struct {
        deallocated: bool = false,

        fn start(
            _: *@This(),
            sd_ref: *net.DarwinDnsServiceRef,
            _: [*:0]const u8,
            _: net.DarwinDnsGetAddrInfoReply,
            _: ?*anyopaque,
        ) !void {
            sd_ref.* = @ptrFromInt(1);
        }

        fn socketFd(_: *@This(), _: net.DarwinDnsServiceRef) !std.posix.fd_t {
            return 42;
        }

        fn wait(
            _: *@This(),
            _: []std.posix.pollfd,
            _: i64,
        ) !usize {
            return 0;
        }

        fn process(_: *@This(), _: net.DarwinDnsServiceRef) !void {
            return error.TestUnexpectedProcess;
        }

        fn deallocate(self: *@This(), _: net.DarwinDnsServiceRef) void {
            self.deallocated = true;
        }
    };

    var ops = TimeoutOps{};
    try std.testing.expectError(
        error.AddressResolutionTimeout,
        net.getDarwinAddressListWithTimeoutUsing(
            TimeoutOps,
            &ops,
            std.testing.allocator,
            "resolver-timeout.invalid",
            53,
            50,
        ),
    );
    try std.testing.expect(ops.deallocated);
}

fn darwinResolverAllocationFixture(allocator: std.mem.Allocator) !void {
    const CallbackOps = struct {
        callback: net.DarwinDnsGetAddrInfoReply = undefined,
        context: ?*anyopaque = null,
        sd_ref: net.DarwinDnsServiceRef = @ptrFromInt(1),

        fn start(
            self: *@This(),
            output_ref: *net.DarwinDnsServiceRef,
            _: [*:0]const u8,
            callback: net.DarwinDnsGetAddrInfoReply,
            context: ?*anyopaque,
        ) !void {
            output_ref.* = self.sd_ref;
            self.callback = callback;
            self.context = context;
        }

        fn socketFd(_: *@This(), _: net.DarwinDnsServiceRef) !std.posix.fd_t {
            return 42;
        }

        fn wait(
            _: *@This(),
            descriptors: []std.posix.pollfd,
            _: i64,
        ) !usize {
            descriptors[0].revents = std.posix.POLL.IN;
            return 1;
        }

        fn process(self: *@This(), _: net.DarwinDnsServiceRef) !void {
            var address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).in.sa;
            self.callback(
                self.sd_ref,
                0x2,
                0,
                0,
                "localhost",
                @ptrCast(&address),
                60,
                self.context,
            );
        }

        fn deallocate(_: *@This(), _: net.DarwinDnsServiceRef) void {}
    };

    var ops = CallbackOps{};
    var addresses = try net.getDarwinAddressListWithTimeoutUsing(
        CallbackOps,
        &ops,
        allocator,
        "localhost",
        5353,
        100,
    );
    defer addresses.deinit();
    try std.testing.expectEqual(@as(usize, 1), addresses.addrs.len);
    try std.testing.expectEqual(@as(u16, 5353), addresses.addrs[0].getPort());
}

test "Darwin DNSService callback allocation failures clean up" {
    if (!builtin.os.tag.isDarwin()) return;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        darwinResolverAllocationFixture,
        .{},
    );
}

test "getAddressListWithTimeout cancels and drains an allocating resolver" {
    const SlowResolver = struct {
        started: std.atomic.Value(bool) = .init(false),
        cancellation_observed: std.atomic.Value(bool) = .init(false),

        fn resolve(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: []const u8,
            port: u16,
        ) !net.AddressList {
            const addrs = try allocator.alloc(net.Address, 1);
            errdefer allocator.free(addrs);
            addrs[0] = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
            self.started.store(true, .release);
            std.Io.sleep(io(), .fromSeconds(30), .awake) catch |err| switch (err) {
                // Deliberately turn cancellation into an allocated success.
                // Select.cancel must queue and drain this losing result.
                error.Canceled => self.cancellation_observed.store(true, .release),
            };
            return .{ .addrs = addrs, .allocator = allocator };
        }

        fn wait(self: *@This(), _: u32) !void {
            while (!self.started.load(.acquire)) {
                try std.Io.sleep(io(), .fromMilliseconds(1), .awake);
            }
            try std.Io.sleep(io(), .fromMilliseconds(10), .awake);
        }
    };

    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var resolver = SlowResolver{};
    const started_ms = monotonicMilliTimestamp();
    try std.testing.expectError(
        error.AddressResolutionTimeout,
        net.getAddressListWithTimeoutUsing(
            SlowResolver,
            &resolver,
            tracking.allocator(),
            "resolver-never-completes.invalid",
            8388,
            10,
        ),
    );
    try std.testing.expect(monotonicMilliTimestamp() - started_ms < 2_000);
    try std.testing.expect(resolver.started.load(.acquire));
    try std.testing.expect(resolver.cancellation_observed.load(.acquire));
    try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    try std.testing.expectEqual(tracking.allocations, tracking.deallocations);
}

test "Darwin compat.net connect and accept paths set SO_NOSIGPIPE" {
    if (!builtin.os.tag.isDarwin()) return;

    const expectNoSigpipe = struct {
        fn check(stream: net.Stream) !void {
            var enabled: c_int = 0;
            var len: std.c.socklen_t = @sizeOf(c_int);
            if (std.c.getsockopt(
                stream.handle,
                std.c.SOL.SOCKET,
                std.c.SO.NOSIGPIPE,
                &enabled,
                &len,
            ) != 0) return error.SocketOptionReadFailed;
            try std.testing.expectEqual(@as(c_int, 1), enabled);
        }
    }.check;

    const address = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{});
    defer server.deinit();
    const client = try net.tcpConnectToAddress(server.listen_address);
    defer client.close();
    const accepted = try server.accept();
    defer accepted.stream.close();
    try expectNoSigpipe(client);
    try expectNoSigpipe(accepted.stream);

    var reuse_server = try net.listenReuseAddr(address);
    defer reuse_server.deinit();
    const timed_client = try net.tcpConnectToAddressWithTimeout(
        reuse_server.listen_address,
        1_000,
    );
    defer timed_client.close();
    const reuse_accepted = try reuse_server.accept();
    defer reuse_accepted.stream.close();
    try expectNoSigpipe(timed_client);
    try expectNoSigpipe(reuse_accepted.stream);

    var host_server = try net.listenReuseAddr(address);
    defer host_server.deinit();
    const host_client = try net.tcpConnectToHost(
        std.testing.allocator,
        "localhost",
        host_server.listen_address.getPort(),
    );
    defer host_client.close();
    const host_accepted = try host_server.accept();
    defer host_accepted.stream.close();
    try expectNoSigpipe(host_client);
    try expectNoSigpipe(host_accepted.stream);
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
