const std = @import("std");
const compat = @import("compat.zig");
const config = @import("config.zig");
const outbound = @import("proxy/outbound/manager.zig");
const runtime_dir = @import("runtime_dir.zig");
const state = @import("state_authority.zig");

fn collectArgs(allocator: std.mem.Allocator, raw_args: std.process.Args) ![]const []const u8 {
    var it = try std.process.Args.Iterator.initAllocator(raw_args, allocator);
    defer it.deinit();
    var args = std.ArrayList([]const u8).empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    while (it.next()) |arg| try args.append(allocator, try allocator.dupe(u8, arg));
    return args.toOwnedSlice(allocator);
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn processExitCode(term: std.process.Child.Term) !u8 {
    return switch (term) {
        .exited => |code| code,
        else => error.AbnormalTermination,
    };
}

fn printToken(token: []const u8) !void {
    var buffer: [64]u8 = undefined;
    if (token.len + 1 > buffer.len) return error.TokenTooLong;
    @memcpy(buffer[0..token.len], token);
    buffer[token.len] = '\n';
    try compat.writeStdoutAll(buffer[0 .. token.len + 1]);
}

fn runCas(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 7) return error.InvalidArguments;
    const root = args[2];
    const key = args[3];
    const expected_text = args[4];
    const next = try state.Revision.parseHex(args[5]);
    const ready_path = args[6];

    var dir = try compat.fs.openDirAbsolute(root, .{});
    defer dir.close(compat.io());
    const authority = state.Authority.init(allocator, dir);
    const expected: state.ExpectedHead = if (std.mem.eql(u8, expected_text, "missing"))
        .missing
    else
        .{ .revision = try state.Revision.parseHex(expected_text) };
    const ready = try compat.fs.createFileAbsolute(ready_path, .{});
    ready.close(compat.io());
    const outcome = try authority.commit(.{ .compare_exchange_head = .{
        .key = key,
        .expected = expected,
        .next = next,
    } });
    switch (outcome) {
        .committed => try printToken("committed"),
        .conflict => try printToken("conflict"),
        .durability_uncertain => try printToken("uncertain"),
    }
}

fn runHoldLock(args: []const []const u8) !void {
    if (args.len != 4) return error.InvalidArguments;
    const root = args[2];
    const ready_path = args[3];
    var dir = try compat.fs.openDirAbsolute(root, .{});
    defer dir.close(compat.io());
    const lock = try dir.createFile(compat.io(), "state-v2.lock", .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer lock.close(compat.io());

    const ready = try compat.fs.createFileAbsolute(ready_path, .{});
    ready.close(compat.io());
    while (true) compat.sleepNs(10 * std.time.ns_per_ms);
}

fn runProbeLock(args: []const []const u8) !void {
    if (args.len != 3) return error.InvalidArguments;
    var dir = try compat.fs.openDirAbsolute(args[2], .{});
    defer dir.close(compat.io());
    const lock = dir.createFile(compat.io(), "state-v2.lock", .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => {
            try printToken("blocked");
            return;
        },
        else => return err,
    };
    defer lock.close(compat.io());
    try printToken("acquired");
}

/// ReleaseFast subprocess regression for the process-fatal default SIGPIPE
/// disposition. A real loopback peer resets the connection; repeated writes go
/// through compat.net.Stream.writeAll and must return an error, never a signal.
fn runSocketWriteAfterReset(args: []const []const u8) !void {
    if (args.len != 2) return error.InvalidArguments;

    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &default_action, null);
    var pipe_mask = std.posix.sigemptyset();
    std.posix.sigaddset(&pipe_mask, .PIPE);
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &pipe_mask, null);

    const loopback = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try compat.net.listenReuseAddr(loopback);
    defer listener.deinit();
    const client = try compat.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    const accepted = try listener.accept();

    const Linger = extern struct {
        enabled: i32,
        timeout_seconds: i32,
    };
    const linger = Linger{ .enabled = 1, .timeout_seconds = 0 };
    try std.posix.setsockopt(
        accepted.stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.LINGER,
        std.mem.asBytes(&linger),
    );
    accepted.stream.close();

    try compat.setNonBlock(client.handle);
    const deadline_ms = compat.monotonicMilliTimestamp() + 2_000;
    while (true) {
        const remaining = deadline_ms - compat.monotonicMilliTimestamp();
        if (remaining <= 0) return error.ResetObservationTimeout;
        var descriptors = [_]std.posix.pollfd{.{
            .fd = client.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(
            &descriptors,
            @intCast(@min(remaining, std.math.maxInt(i32))),
        );
        if (ready == 0) return error.ResetObservationTimeout;
        const revents = descriptors[0].revents;
        if (revents & std.posix.POLL.NVAL != 0) return error.InvalidSocket;
        if (revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP) == 0) {
            continue;
        }
        var byte: [1]u8 = undefined;
        if (client.read(&byte)) |count| {
            if (count != 0) return error.UnexpectedResetPayload;
        } else |err| switch (err) {
            error.ConnectionResetByPeer => {},
            error.WouldBlock => continue,
            else => return err,
        }
        break;
    }

    var error_count: usize = 0;
    while (error_count < 8) : (error_count += 1) {
        client.writeAll("write-after-rst") catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => continue,
            else => return err,
        };
        return error.WriteAfterResetUnexpectedlySucceeded;
    }
    try printToken("socket-write-after-rst-ok");
}

/// ReleaseFast process fixture for the startup ownership boundary: wrapper OOM
/// is injectable only while the handle is prepared, and final acquisition does
/// not allocate or return an error after listener threads could be detached.
fn runSelectionBarrierFault(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len != 2) return error.InvalidArguments;
    var cfg = try config.parseDocument(allocator, "proxy-groups: []\n");
    defer cfg.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const manager = try outbound.OutboundManager.init(
        failing.allocator(),
        &cfg,
    );
    defer manager.deinit();

    failing.fail_index = failing.alloc_index;
    if (manager.prepareSelectionBarrier()) |prepared| {
        prepared.deinit();
        return error.ExpectedOutOfMemory;
    } else |err| {
        if (err != error.OutOfMemory) return err;
    }
    if (!failing.has_induced_failure) return error.ExpectedInjectedFailure;

    failing.fail_index = std.math.maxInt(usize);
    failing.has_induced_failure = false;
    const prepared = try manager.prepareSelectionBarrier();
    const allocations_before_acquire = failing.allocations;
    failing.fail_index = failing.alloc_index;
    const barrier = prepared.acquire();
    if (failing.has_induced_failure or
        failing.allocations != allocations_before_acquire)
    {
        barrier.deinit();
        return error.SelectionBarrierAcquireAllocated;
    }
    barrier.deinit();
    try printToken("selection-barrier-fault-ok");
}

/// ReleaseFast child-process contract for the post-proxy/API-spawn failure
/// boundary. The dedicated zc artifact injects API thread-spawn failure at
/// compile time; this driver verifies the startup signal classification and
/// that owner-only runtime artifacts are removed in an isolated runtime.
fn runApiOwnerStartupFault(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len != 4) return error.InvalidArguments;
    const zc_path = args[2];
    const base_path = args[3];
    const cwd = compat.fs.cwd();

    // Keep the product default occupied for the entire child lifetime. The
    // compile-time fault build must neither probe nor open 7899 before reaching
    // InjectedApiThreadSpawnFailure.
    const sentinel_address = try compat.net.Address.parseIp4("127.0.0.1", 7899);
    var default_port_sentinel: ?compat.net.ReuseAddrListener =
        compat.net.listenReuseAddr(sentinel_address) catch |err| switch (err) {
            // A production instance may already own the reserved port. That is
            // an equally strong occupied-port sentinel: reaching the injected
            // API failure proves the child never tried to bind/probe it.
            error.AddressInUse => null,
            else => return err,
        };
    defer if (default_port_sentinel) |*sentinel| sentinel.deinit();
    if (default_port_sentinel) |*sentinel| {
        try compat.setNonBlock(sentinel.fd);
    }
    try cwd.makePath(base_path);
    var nonce: [16]u8 = undefined;
    compat.randomBytes(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const root_path = try compat.fs.path.join(
        allocator,
        &.{ base_path, &nonce_hex },
    );
    defer allocator.free(root_path);
    defer cwd.dir.deleteTree(compat.io(), root_path) catch {};

    const home_path = try compat.fs.path.join(allocator, &.{ root_path, "home" });
    defer allocator.free(home_path);
    const config_home_path = try compat.fs.path.join(
        allocator,
        &.{ home_path, ".config" },
    );
    defer allocator.free(config_home_path);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root_path, "run" });
    defer allocator.free(runtime_path);
    const config_path = try compat.fs.path.join(
        allocator,
        &.{ root_path, "api-owner-fault.yaml" },
    );
    defer allocator.free(config_path);
    const log_path = try compat.fs.path.join(
        allocator,
        &.{ runtime_path, runtime_dir.log_name },
    );
    defer allocator.free(log_path);

    try cwd.makePath(config_home_path);
    try cwd.makePath(runtime_path);
    var runtime = try compat.fs.openDirAbsolute(runtime_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer runtime.close(compat.io());
    try compat.setDirPermissions(
        runtime,
        std.Io.File.Permissions.fromMode(0o700),
    );

    // The fault binary skips child bind probes and fails before spawning the
    // API thread, so the child needs no proxy listener port. This removes
    // reserve/close handoff races from the process attestation.
    const document =
        "mixed-port: 0\n" ++
        "external-controller: \"127.0.0.1:1\"\n" ++
        "allow-lan: false\n" ++
        "proxies: []\n" ++
        "proxy-groups: []\n" ++
        "rules: []\n";

    const config_file = try compat.fs.createFileAbsolute(config_path, .{});
    defer config_file.close(compat.io());
    try compat.fileWriteAll(config_file, document);

    const inherited = compat.environMap() orelse
        return error.EnvironmentUnavailable;
    var environment = try inherited.clone(allocator);
    defer environment.deinit();
    try environment.put("HOME", home_path);
    try environment.put("XDG_CONFIG_HOME", config_home_path);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);

    const result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_path, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(20),
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if ((try processExitCode(result.term)) != 1 or
        std.mem.indexOf(u8, result.stdout, "\"code\":\"START_FAILED\"") == null or
        std.mem.indexOf(
            u8,
            result.stdout,
            "daemon listener failed during startup",
        ) == null)
    {
        std.debug.print(
            "api owner startup fault stdout:\n{s}\nstderr:\n{s}\n",
            .{ result.stdout, result.stderr },
        );
        return error.UnexpectedStartupFaultResult;
    }

    const log = try compat.fs.cwd().readFileAlloc(
        allocator,
        log_path,
        1024 * 1024,
    );
    defer allocator.free(log);
    if (std.mem.indexOf(u8, log, "InjectedApiThreadSpawnFailure") == null) {
        return error.ApiSpawnFaultNotObserved;
    }
    if (std.mem.indexOf(u8, log, "Starting mixed proxy") != null or
        std.mem.indexOf(u8, log, "Starting HTTP proxy") != null or
        std.mem.indexOf(u8, log, "Starting SOCKS5 proxy") != null)
    {
        return error.ApiSpawnFaultOpenedProxyListener;
    }

    if (runtime.access(compat.io(), runtime_dir.pid_name, .{})) |_| {
        return error.RuntimePidLeaked;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (runtime.access(compat.io(), runtime_dir.descriptor_name, .{})) |_| {
        return error.RuntimeDescriptorLeaked;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var iterator = runtime.iterate();
    while (try iterator.next(compat.io())) |entry| {
        if (std.mem.startsWith(u8, entry.name, runtime_dir.startup_prefix) or
            (std.mem.startsWith(u8, entry.name, "zc.prepared.") and
                !std.mem.eql(u8, entry.name, "zc.prepared.key") and
                !std.mem.eql(u8, entry.name, "zc.prepared.key.lock")))
        {
            std.debug.print("leaked startup runtime entry: {s}\n", .{entry.name});
            return error.StartupRuntimeArtifactLeaked;
        }
    }

    if (default_port_sentinel) |*sentinel| {
        if (sentinel.accept()) |connection| {
            connection.stream.close();
            return error.DefaultPortSentinelTouched;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        }
    }
    try printToken("api-owner-startup-fault-ok");
}

pub fn main(init: std.process.Init) !void {
    compat.setIo(init.io);
    compat.setEnvironMap(init.environ_map);
    const allocator = init.gpa;
    const args = try collectArgs(allocator, init.minimal.args);
    defer freeArgs(allocator, args);
    if (args.len < 2) return error.InvalidArguments;

    if (std.mem.eql(u8, args[1], "cas")) return runCas(allocator, args);
    if (std.mem.eql(u8, args[1], "hold-lock")) return runHoldLock(args);
    if (std.mem.eql(u8, args[1], "probe-lock")) return runProbeLock(args);
    if (std.mem.eql(u8, args[1], "socket-write-after-rst")) {
        return runSocketWriteAfterReset(args);
    }
    if (std.mem.eql(u8, args[1], "selection-barrier-fault")) {
        return runSelectionBarrierFault(allocator, args);
    }
    if (std.mem.eql(u8, args[1], "api-owner-startup-fault")) {
        return runApiOwnerStartupFault(allocator, args);
    }
    return error.InvalidArguments;
}
