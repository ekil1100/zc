const std = @import("std");
const compat = @import("../../compat.zig");
const aead = @import("../../crypto/aead.zig");
const socks_address = @import("../../protocol/socks_address.zig");
const shadowsocks_udp = @import("shadowsocks_udp.zig");

const test_timeout_ms: i64 = 2_000;

fn deadlineAfter(timeout_ms: i64) !i64 {
    return std.math.add(
        i64,
        compat.monotonicMilliTimestamp(),
        timeout_ms,
    );
}

fn waitReadable(fd: std.posix.fd_t, deadline_ms: i64) !void {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try compat.pollAbsolute(&descriptors, deadline_ms);
    if (ready == 0) return error.TestTimeout;
    if (descriptors[0].revents & std.posix.POLL.IN == 0) {
        return error.TestSocketFailure;
    }
}

fn sendToPeer(
    fd: std.posix.fd_t,
    peer: *const std.c.sockaddr.in,
    wire: []const u8,
) !void {
    const sent = try compat.posixSendTo(
        fd,
        wire,
        0,
        @ptrCast(peer),
        @sizeOf(std.c.sockaddr.in),
    );
    if (sent != wire.len) return error.TestPartialDatagram;
}

test "Shadowsocks UDP Session loopback tracer uses the public seam" {
    // A real connected client and loopback UDP server exchange one classic AEAD packet each way.
    const server_fd = try compat.udpSocket4();
    defer compat.posixClose(server_fd);
    try compat.setNonBlock(server_fd);
    const server_address = try compat.socketGetName4(server_fd);

    const session = try shadowsocks_udp.Session.create(
        std.testing.allocator,
        "127.0.0.1",
        server_address.port,
        "tracer-password",
        .aes_128_gcm,
        try deadlineAfter(test_timeout_ms),
        null,
    );
    defer session.destroy();

    const destination_raw = "\x03\x0bexample.com\x00\x35";
    const destination = try socks_address.parse(destination_raw);
    try session.send(destination, "question");

    try waitReadable(server_fd, try deadlineAfter(test_timeout_ms));
    var request_wire_buffer: [65_536]u8 = undefined;
    const request = try compat.udpRecvFrom(server_fd, &request_wire_buffer);
    const server_crypto = try aead.AeadDatagram.create(
        std.testing.allocator,
        .aes_128_gcm,
        "tracer-password",
    );
    defer server_crypto.destroy();
    var request_plaintext_buffer: [65_507]u8 = undefined;
    const request_plaintext = try server_crypto.open(
        request_wire_buffer[0..request.n],
        &request_plaintext_buffer,
    );
    try std.testing.expectEqualStrings(destination_raw ++ "question", request_plaintext);

    switch (try session.receive()) {
        .would_block => {},
        else => return error.ExpectedWouldBlock,
    }

    const source_raw = "\x03\x0borigin.test\x14\xe9";
    const response_plaintext = source_raw ++ "answer";
    var response_wire_buffer: [128]u8 = undefined;
    const response_wire = try server_crypto.seal(
        std.testing.io,
        response_plaintext,
        &response_wire_buffer,
    );
    try sendToPeer(server_fd, &request.addr, response_wire);

    try waitReadable(session.pollHandle(), try deadlineAfter(test_timeout_ms));
    switch (try session.receive()) {
        .datagram => |datagram| {
            try std.testing.expectEqualStrings(source_raw, datagram.source.raw);
            try std.testing.expectEqual(@as(u16, 5353), datagram.source.port);
            switch (datagram.source.host) {
                .domain => |host| try std.testing.expectEqualStrings("origin.test", host),
                else => return error.UnexpectedSourceType,
            }
            try std.testing.expectEqualStrings("answer", datagram.payload);
        },
        else => return error.ExpectedDatagram,
    }
}

const LoopbackFixture = struct {
    server_fd: std.posix.fd_t,
    session: *shadowsocks_udp.Session,
    server_crypto: *aead.AeadDatagram,
    peer: ?std.c.sockaddr.in = null,

    fn init(cipher: aead.CipherType, password: []const u8) !LoopbackFixture {
        const server_fd = try compat.udpSocket4();
        errdefer compat.posixClose(server_fd);
        try compat.setNonBlock(server_fd);
        const bound = try compat.socketGetName4(server_fd);

        const session = try shadowsocks_udp.Session.create(
            std.testing.allocator,
            "127.0.0.1",
            bound.port,
            password,
            cipher,
            try deadlineAfter(test_timeout_ms),
            null,
        );
        errdefer session.destroy();
        const server_crypto = try aead.AeadDatagram.create(
            std.testing.allocator,
            cipher,
            password,
        );
        errdefer server_crypto.destroy();
        return .{
            .server_fd = server_fd,
            .session = session,
            .server_crypto = server_crypto,
        };
    }

    fn deinit(self: *LoopbackFixture) void {
        self.server_crypto.destroy();
        self.session.destroy();
        compat.posixClose(self.server_fd);
        self.* = undefined;
    }

    fn expectRequest(
        self: *LoopbackFixture,
        expected_address: []const u8,
        expected_payload: []const u8,
    ) !usize {
        try waitReadable(self.server_fd, try deadlineAfter(test_timeout_ms));
        var wire_buffer: [65_536]u8 = undefined;
        const request = try compat.udpRecvFrom(self.server_fd, &wire_buffer);
        self.peer = request.addr;
        var plaintext_buffer: [65_507]u8 = undefined;
        const plaintext = try self.server_crypto.open(
            wire_buffer[0..request.n],
            &plaintext_buffer,
        );
        const address = try socks_address.parse(plaintext);
        try std.testing.expectEqualStrings(expected_address, address.raw);
        try std.testing.expectEqualStrings(
            expected_payload,
            plaintext[address.consumed..],
        );
        return request.n;
    }

    fn sendWire(self: *LoopbackFixture, wire: []const u8) !void {
        const peer = self.peer orelse return error.TestPeerUnknown;
        try sendToPeer(self.server_fd, &peer, wire);
    }

    fn sendPlaintext(self: *LoopbackFixture, plaintext: []const u8) !void {
        var wire_buffer: [512]u8 = undefined;
        const wire = try self.server_crypto.seal(
            std.testing.io,
            plaintext,
            &wire_buffer,
        );
        try self.sendWire(wire);
    }
};

fn expectCipherWireProperties(cipher: aead.CipherType) !void {
    // This function scope releases each fixture before the next cipher starts.
    var fixture = try LoopbackFixture.init(cipher, "cipher-password");
    defer fixture.deinit();

    const descriptor_flags = std.c.fcntl(
        fixture.session.pollHandle(),
        std.posix.F.GETFD,
        @as(c_int, 0),
    );
    if (descriptor_flags < 0) return error.TestFcntlFailed;
    try std.testing.expect(
        descriptor_flags & std.posix.FD_CLOEXEC != 0,
    );
    const status_flags = std.c.fcntl(
        fixture.session.pollHandle(),
        std.posix.F.GETFL,
        @as(c_int, 0),
    );
    if (status_flags < 0) return error.TestFcntlFailed;
    const nonblocking: c_int = @bitCast(@as(
        u32,
        @bitCast(std.posix.O{ .NONBLOCK = true }),
    ));
    try std.testing.expect(status_flags & nonblocking != 0);

    const destination_raw = "\x03\x03dns\x00\x35";
    const destination = try socks_address.parse(destination_raw);
    try fixture.session.send(destination, "query");
    const wire_len = try fixture.expectRequest(
        destination_raw,
        "query",
    );
    try std.testing.expectEqual(
        cipher.saltLen() + destination_raw.len + "query".len +
            aead.AeadDatagram.tag_size,
        wire_len,
    );
}

test "Shadowsocks UDP Session creates nonblocking CLOEXEC wire for every cipher and alias" {
    // Every accepted 2017 AEAD name opens the same allocation-free connected UDP seam.
    const cases = [_]aead.CipherType{
        .aes_128_gcm,
        .aes_256_gcm,
        .chacha20_ietf_poly1305,
        .chacha20_poly1305,
    };
    for (cases) |cipher| try expectCipherWireProperties(cipher);
}

test "Shadowsocks UDP Session drops a bad tag then receives the next valid packet" {
    // Authentication failure is scoped to one datagram and cannot poison the association.
    var fixture = try LoopbackFixture.init(.aes_128_gcm, "recovery-password");
    defer fixture.deinit();
    const destination_raw = "\x01\xc0\x00\x02\x01\x01\xbb";
    const destination = try socks_address.parse(destination_raw);
    try fixture.session.send(destination, "probe");
    _ = try fixture.expectRequest(destination_raw, "probe");

    const response_plaintext = "\x03\x06source\x00\x35reply";
    var valid_wire_buffer: [128]u8 = undefined;
    const valid_wire = try fixture.server_crypto.seal(
        std.testing.io,
        response_plaintext,
        &valid_wire_buffer,
    );
    var invalid_wire: [128]u8 = undefined;
    @memcpy(invalid_wire[0..valid_wire.len], valid_wire);
    invalid_wire[valid_wire.len - 1] ^= 0x01;
    try fixture.sendWire(invalid_wire[0..valid_wire.len]);

    try waitReadable(
        fixture.session.pollHandle(),
        try deadlineAfter(test_timeout_ms),
    );
    switch (try fixture.session.receive()) {
        .dropped => |reason| try std.testing.expectEqual(
            shadowsocks_udp.DropReason.authentication_failed,
            reason,
        ),
        else => return error.ExpectedAuthenticationDrop,
    }

    try fixture.sendWire(valid_wire);
    try waitReadable(
        fixture.session.pollHandle(),
        try deadlineAfter(test_timeout_ms),
    );
    switch (try fixture.session.receive()) {
        .datagram => |datagram| {
            try std.testing.expectEqualStrings("source", datagram.source.host.domain);
            try std.testing.expectEqualStrings("reply", datagram.payload);
        },
        else => return error.ExpectedRecoveryDatagram,
    }
}

test "Shadowsocks UDP Session drops authenticated invalid addresses and keeps receiving" {
    // Authentication alone is insufficient: unknown and truncated SOCKS addresses stay hidden.
    var fixture = try LoopbackFixture.init(.aes_256_gcm, "address-password");
    defer fixture.deinit();
    const destination_raw = "\x03\x03dns\x00\x35";
    const destination = try socks_address.parse(destination_raw);
    try fixture.session.send(destination, "probe");
    _ = try fixture.expectRequest(destination_raw, "probe");

    const invalid_plaintexts = [_][]const u8{
        "\x02not-an-address",
        "\x03\x05ab",
    };
    for (invalid_plaintexts) |invalid_plaintext| {
        try fixture.sendPlaintext(invalid_plaintext);
        try waitReadable(
            fixture.session.pollHandle(),
            try deadlineAfter(test_timeout_ms),
        );
        switch (try fixture.session.receive()) {
            .dropped => |reason| try std.testing.expectEqual(
                shadowsocks_udp.DropReason.invalid_address,
                reason,
            ),
            else => return error.ExpectedInvalidAddressDrop,
        }
    }

    try fixture.sendPlaintext("\x01\xcb\x00\x71\x09\x1f\x90ok");
    try waitReadable(
        fixture.session.pollHandle(),
        try deadlineAfter(test_timeout_ms),
    );
    switch (try fixture.session.receive()) {
        .datagram => |datagram| try std.testing.expectEqualStrings(
            "ok",
            datagram.payload,
        ),
        else => return error.ExpectedRecoveryDatagram,
    }
}

test "Shadowsocks UDP Session accepts exact 65507 wire and rejects one byte more" {
    // The address-dependent cap is checked before entropy, copies, or a second UDP syscall.
    var fixture = try LoopbackFixture.init(.aes_128_gcm, "limit-password");
    defer fixture.deinit();
    const destination_raw = "\x03\x01a\x00\x35";
    const destination = try socks_address.parse(destination_raw);
    const payload_len_max = comptime aead.AeadDatagram.wire_size_max -
        aead.CipherType.aes_128_gcm.saltLen() -
        destination_raw.len -
        aead.AeadDatagram.tag_size;
    var payload: [payload_len_max + 1]u8 = @splat(0x5a);

    try fixture.session.send(destination, payload[0..payload_len_max]);
    const wire_len = try fixture.expectRequest(
        destination_raw,
        payload[0..payload_len_max],
    );
    try std.testing.expectEqual(aead.AeadDatagram.wire_size_max, wire_len);

    try std.testing.expectError(
        error.DatagramTooLarge,
        fixture.session.send(destination, &payload),
    );
    var descriptors = [_]std.posix.pollfd{.{
        .fd = fixture.server_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try compat.pollAbsolute(
        &descriptors,
        try deadlineAfter(50),
    );
    try std.testing.expectEqual(@as(usize, 0), ready);
}

test "Shadowsocks UDP Session rejects non-exact Parsed destinations before sending" {
    // Public Parsed values are revalidated so trailing or inconsistent metadata cannot enter wire.
    var fixture = try LoopbackFixture.init(.aes_128_gcm, "strict-address");
    defer fixture.deinit();
    const destination_raw = "\x03\x01a\x00\x35";
    const destination = try socks_address.parse(destination_raw);

    var inconsistent = destination;
    inconsistent.port += 1;
    try std.testing.expectError(
        error.InvalidAddress,
        fixture.session.send(inconsistent, "payload"),
    );

    var trailing = destination;
    trailing.raw = destination_raw ++ "x";
    trailing.consumed = trailing.raw.len;
    try std.testing.expectError(
        error.InvalidAddress,
        fixture.session.send(trailing, "payload"),
    );

    var descriptors = [_]std.posix.pollfd{.{
        .fd = fixture.server_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try compat.pollAbsolute(
        &descriptors,
        try deadlineAfter(50),
    );
    try std.testing.expectEqual(@as(usize, 0), ready);
}

fn createDestroyAllocationFixture(
    allocator: std.mem.Allocator,
    server_port: u16,
) !void {
    const session = try shadowsocks_udp.Session.create(
        allocator,
        "127.0.0.1",
        server_port,
        "allocation-password",
        .chacha20_ietf_poly1305,
        try deadlineAfter(test_timeout_ms),
        null,
    );
    session.destroy();
}

test "Shadowsocks UDP Session rolls back every allocation failure" {
    // Impl, owned crypto, and the resolved address list each have exact failure cleanup.
    const server_fd = try compat.udpSocket4();
    defer compat.posixClose(server_fd);
    const bound = try compat.socketGetName4(server_fd);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        createDestroyAllocationFixture,
        .{bound.port},
    );
}

test "Shadowsocks UDP Session create rejects the awake deadline boundary without leaks" {
    // now >= deadline fails after object allocation and before DNS can open a socket.
    const deadlines = [_]i64{
        compat.monotonicMilliTimestamp() - 1,
        compat.monotonicMilliTimestamp(),
    };
    for (deadlines) |deadline_ms| {
        var tracking = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{},
        );
        try std.testing.expectError(
            error.DeadlineExceeded,
            shadowsocks_udp.Session.create(
                tracking.allocator(),
                "127.0.0.1",
                8388,
                "deadline-password",
                .aes_128_gcm,
                deadline_ms,
                null,
            ),
        );
        try std.testing.expectEqual(
            tracking.allocated_bytes,
            tracking.freed_bytes,
        );
        try std.testing.expectEqual(
            tracking.allocations,
            tracking.deallocations,
        );
        try std.testing.expectEqual(@as(usize, 2), tracking.allocations);
    }
}

test "Shadowsocks UDP Session data plane performs no allocator calls" {
    // Allocation counters stay fixed across entropy, send, receive, parse, and a response.
    const server_fd = try compat.udpSocket4();
    defer compat.posixClose(server_fd);
    try compat.setNonBlock(server_fd);
    const bound = try compat.socketGetName4(server_fd);
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const session = try shadowsocks_udp.Session.create(
        tracking.allocator(),
        "127.0.0.1",
        bound.port,
        "no-allocation-password",
        .aes_128_gcm,
        try deadlineAfter(test_timeout_ms),
        null,
    );
    defer session.destroy();
    const allocation_count = tracking.allocations;
    const deallocation_count = tracking.deallocations;

    const destination_raw = "\x03\x03dns\x00\x35";
    const destination = try socks_address.parse(destination_raw);
    try session.send(destination, "query");
    try waitReadable(server_fd, try deadlineAfter(test_timeout_ms));
    var request_wire_buffer: [65_536]u8 = undefined;
    const request = try compat.udpRecvFrom(server_fd, &request_wire_buffer);
    const server_crypto = try aead.AeadDatagram.create(
        std.testing.allocator,
        .aes_128_gcm,
        "no-allocation-password",
    );
    defer server_crypto.destroy();
    var request_plaintext_buffer: [65_507]u8 = undefined;
    const request_plaintext = try server_crypto.open(
        request_wire_buffer[0..request.n],
        &request_plaintext_buffer,
    );
    try std.testing.expectEqualStrings(destination_raw ++ "query", request_plaintext);

    var response_wire_buffer: [128]u8 = undefined;
    const response_wire = try server_crypto.seal(
        std.testing.io,
        "\x03\x06source\x00\x35response",
        &response_wire_buffer,
    );
    try sendToPeer(server_fd, &request.addr, response_wire);
    try waitReadable(session.pollHandle(), try deadlineAfter(test_timeout_ms));
    switch (try session.receive()) {
        .datagram => |datagram| try std.testing.expectEqualStrings(
            "response",
            datagram.payload,
        ),
        else => return error.ExpectedDatagram,
    }

    try std.testing.expectEqual(allocation_count, tracking.allocations);
    try std.testing.expectEqual(deallocation_count, tracking.deallocations);
}

const ZeroInspectingAllocator = struct {
    backing: std.mem.Allocator,
    session_free_seen: bool = false,
    session_free_zeroed: bool = false,

    fn allocator(self: *ZeroInspectingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocate,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn allocate(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ZeroInspectingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *ZeroInspectingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ZeroInspectingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *ZeroInspectingAllocator = @ptrCast(@alignCast(context));
        const session_allocation_size_min =
            4 * aead.AeadDatagram.wire_size_max;
        if (memory.len >= session_allocation_size_min) {
            self.session_free_seen = true;
            self.session_free_zeroed = true;
            for (memory) |byte| {
                if (byte != 0) self.session_free_zeroed = false;
            }
        }
        self.backing.rawFree(memory, alignment, return_address);
    }
};

test "Shadowsocks UDP Session destroy wipes fixed storage before freeing it" {
    // A forwarding allocator observes that even populated wire and plaintext buffers are zeroed.
    const server_fd = try compat.udpSocket4();
    defer compat.posixClose(server_fd);
    try compat.setNonBlock(server_fd);
    const bound = try compat.socketGetName4(server_fd);
    var inspector = ZeroInspectingAllocator{ .backing = std.testing.allocator };
    const session = try shadowsocks_udp.Session.create(
        inspector.allocator(),
        "127.0.0.1",
        bound.port,
        "wipe-password",
        .aes_256_gcm,
        try deadlineAfter(test_timeout_ms),
        null,
    );
    const destination = try socks_address.parse("\x03\x03dns\x00\x35");
    try session.send(destination, "sensitive plaintext");
    try waitReadable(server_fd, try deadlineAfter(test_timeout_ms));
    var wire_buffer: [65_536]u8 = undefined;
    _ = try compat.udpRecvFrom(server_fd, &wire_buffer);

    session.destroy();
    try std.testing.expect(inspector.session_free_seen);
    try std.testing.expect(inspector.session_free_zeroed);
}

fn countOpenFileDescriptors() usize {
    var count: usize = 0;
    var fd: std.posix.fd_t = 0;
    while (fd < 1_024) : (fd += 1) {
        const result = std.c.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0));
        if (result >= 0) count += 1;
    }
    return count;
}

test "Shadowsocks UDP Session numeric create fast-cancels before allocation" {
    var sockets: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(
        std.c.AF.UNIX,
        std.c.SOCK.STREAM,
        0,
        &sockets,
    ) != 0) return error.TestSocketPairFailed;
    defer compat.posixClose(sockets[0]);
    compat.posixClose(sockets[1]);

    // Establish the real peer-close readiness before taking allocation/fd
    // baselines; timing is not the cancellation oracle.
    var descriptors = [_]std.posix.pollfd{.{
        .fd = sockets[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try compat.pollAbsolute(
        &descriptors,
        try deadlineAfter(test_timeout_ms),
    );
    if (ready == 0) return error.TestControlCloseTimeout;
    try std.testing.expect(try compat.cancelFdTriggered(sockets[0]));

    const descriptors_before = countOpenFileDescriptors();
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try std.testing.expectError(
        error.Canceled,
        shadowsocks_udp.Session.create(
            tracking.allocator(),
            "127.0.0.1",
            8388,
            "preclosed-control",
            .aes_128_gcm,
            try deadlineAfter(test_timeout_ms),
            sockets[0],
        ),
    );

    try std.testing.expectEqual(
        descriptors_before,
        countOpenFileDescriptors(),
    );
    try std.testing.expectEqual(@as(usize, 0), tracking.allocations);
    try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    try std.testing.expectEqual(tracking.allocations, tracking.deallocations);
}

test "Shadowsocks UDP Session rolls back a post-connect failure" {
    // The injected error is reachable only after a real connected fd belongs to create.
    const server_fd = try compat.udpSocket4();
    defer compat.posixClose(server_fd);
    const bound = try compat.socketGetName4(server_fd);
    const descriptors_before = countOpenFileDescriptors();
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});

    shadowsocks_udp.testing.injectPostConnectFailureOnce();
    defer shadowsocks_udp.testing.clearPostConnectFailure();
    try std.testing.expectError(
        error.InjectedPostConnectFailure,
        shadowsocks_udp.Session.create(
            tracking.allocator(),
            "127.0.0.1",
            bound.port,
            "setup-password",
            .aes_128_gcm,
            try deadlineAfter(test_timeout_ms),
            null,
        ),
    );
    const descriptors_after = countOpenFileDescriptors();

    try std.testing.expectEqual(descriptors_before, descriptors_after);
    try std.testing.expect(tracking.allocations >= 3);
    try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    try std.testing.expectEqual(tracking.allocations, tracking.deallocations);
}

test "Shadowsocks UDP Session classifies the receive wire boundary" {
    try std.testing.expectEqual(
        shadowsocks_udp.testing.WireLengthClassification.accepted,
        shadowsocks_udp.testing.classifyWireLength(65_507),
    );
    try std.testing.expectEqual(
        shadowsocks_udp.testing.WireLengthClassification.wire_too_large,
        shadowsocks_udp.testing.classifyWireLength(65_508),
    );
}

test "Shadowsocks UDP Session classifies connected receive errors" {
    switch (shadowsocks_udp.testing.classifySocketReceiveError(
        error.WouldBlock,
    )) {
        .would_block => {},
        else => return error.ExpectedWouldBlockClassification,
    }
    switch (shadowsocks_udp.testing.classifySocketReceiveError(
        error.PacketDropped,
    )) {
        .dropped => |reason| try std.testing.expectEqual(
            shadowsocks_udp.DropReason.network_condition,
            reason,
        ),
        else => return error.ExpectedNetworkConditionClassification,
    }
    switch (shadowsocks_udp.testing.classifySocketReceiveError(
        error.DatagramTooLarge,
    )) {
        .dropped => |reason| try std.testing.expectEqual(
            shadowsocks_udp.DropReason.wire_too_large,
            reason,
        ),
        else => return error.ExpectedWireTooLargeClassification,
    }
    switch (shadowsocks_udp.testing.classifySocketReceiveError(
        error.InputOutput,
    )) {
        .fatal => |fatal| try std.testing.expect(fatal == error.InputOutput),
        else => return error.ExpectedFatalClassification,
    }
}

test "Shadowsocks UDP Session drops a truncated wire without exposing plaintext" {
    // A packet shorter than salt plus tag is rejected before any plaintext view exists.
    var fixture = try LoopbackFixture.init(.aes_128_gcm, "truncated-password");
    defer fixture.deinit();
    const destination_raw = "\x03\x03dns\x00\x35";
    const destination = try socks_address.parse(destination_raw);
    try fixture.session.send(destination, "probe");
    _ = try fixture.expectRequest(destination_raw, "probe");

    try fixture.sendWire("truncated");
    try waitReadable(
        fixture.session.pollHandle(),
        try deadlineAfter(test_timeout_ms),
    );
    switch (try fixture.session.receive()) {
        .dropped => |reason| try std.testing.expectEqual(
            shadowsocks_udp.DropReason.invalid_packet,
            reason,
        ),
        else => return error.ExpectedInvalidPacketDrop,
    }

    try fixture.sendPlaintext("\x03\x06source\x00\x35valid");
    try waitReadable(
        fixture.session.pollHandle(),
        try deadlineAfter(test_timeout_ms),
    );
    switch (try fixture.session.receive()) {
        .datagram => |datagram| try std.testing.expectEqualStrings(
            "valid",
            datagram.payload,
        ),
        else => return error.ExpectedRecoveryDatagram,
    }
}
