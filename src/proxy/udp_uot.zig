//! SOCKS5 UDP ASSOCIATE <-> sing UoT v2 over AnyTLS — pure codec core (Stage D2/D3).
//!
//! This file owns two *independently testable* codecs with NO ingress/relay
//! wiring (that is D5/D6):
//!   - D2: the RFC1928 SOCKS5 UDP datagram parse/build (client <-> bound socket).
//!   - D3: the UoT v2 stream framing over a borrowed anytls.Stream.
//!
//! Both legs share one raw SOCKS address representation (`SocksAddr`) so the
//! address bytes can be memcpy'd between the two wire formats with no
//! decode/re-encode. Server-controlled inbound bytes are treated as untrusted:
//! every parse on insufficient data returns "need more" rather than guessing
//! (MUST-FIX #4).

const std = @import("std");
const anytls = @import("../protocol/anytls.zig");

/// Magic UoT v2 destination (sing-box v2 magic FQDN). The server keys on the
/// domain; the port is best-effort. Locked default (POST-REVIEW).
pub const MAGIC_DOMAIN = "sp.v2.udp-over-tcp.arpa";
pub const MAGIC_PORT: u16 = 443;

// RFC1928 ATYP values.
const ATYP_V4: u8 = 0x01;
const ATYP_DOMAIN: u8 = 0x03;
const ATYP_V6: u8 = 0x04;

/// A raw RFC1928 address (ATYP + ADDR + PORT) held verbatim so it can be
/// memcpy'd between the UoT frame and the downstream SOCKS5-UDP header with no
/// decode/re-encode. Max: 1 atyp + 1 len + 255 domain + 2 port + slack.
pub const SocksAddr = struct {
    bytes: [262]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const SocksAddr) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Length of the SOCKS *address body* (ADDR bytes, excluding the ATYP and the
/// trailing 2-byte PORT) given the ATYP and the bytes that FOLLOW the ATYP.
///   v4     -> 4
///   domain -> 1 + domain_len  (domain_len read from rest[0]; must be > 0)
///   v6     -> 16
/// Bounds-checks that `rest` actually holds the body; otherwise error.NeedMore.
/// Unknown ATYP -> error.Invalid. domain_len == 0 -> error.Invalid.
pub fn socksAddrLen(atyp: u8, rest: []const u8) !usize {
    switch (atyp) {
        ATYP_V4 => {
            if (rest.len < 4) return error.NeedMore;
            return 4;
        },
        ATYP_DOMAIN => {
            if (rest.len < 1) return error.NeedMore;
            const domain_len = rest[0];
            if (domain_len == 0) return error.Invalid;
            if (rest.len < 1 + @as(usize, domain_len)) return error.NeedMore;
            return 1 + @as(usize, domain_len);
        },
        ATYP_V6 => {
            if (rest.len < 16) return error.NeedMore;
            return 16;
        },
        else => return error.Invalid,
    }
}

/// Total length of a full SOCKS address (ATYP + ADDR + PORT) at buf[0..].
/// = 1 (atyp) + body + 2 (port). Same need/invalid semantics as socksAddrLen.
pub fn fullSocksAddrLen(buf: []const u8) !usize {
    if (buf.len < 1) return error.NeedMore;
    const body = try socksAddrLen(buf[0], buf[1..]);
    const total = 1 + body + 2;
    if (buf.len < total) return error.NeedMore;
    return total;
}

// ---------------------------------------------------------------------------
// D2: pure SOCKS5 UDP datagram codec (RFC1928 §7).
// ---------------------------------------------------------------------------
//
//   +-----+------+------+----------+----------+----------+
//   | RSV | FRAG | ATYP | DST.ADDR | DST.PORT |   DATA   |
//   |  2  |  1   |  1   | Variable |  2 (BE)  | Variable |
//   +-----+------+------+----------+----------+----------+

pub const ClientDatagram = struct {
    frag: u8,
    addr: SocksAddr, // raw ATYP+ADDR+PORT copied out of the packet
    port: u16, // host-order convenience copy of DST.PORT
    payload: []const u8, // slice INTO the input packet
};

/// Parse a client->relay UDP datagram. FRAG != 0 -> error.FragNotSupported
/// (no reassembly). Truncated / malformed -> error.Invalid.
pub fn parseClientDatagram(pkt: []const u8) !ClientDatagram {
    // RSV(2) + FRAG(1) + ATYP(1) minimum before any address body.
    if (pkt.len < 4) return error.Invalid;
    const frag = pkt[2];
    if (frag != 0) return error.FragNotSupported;

    const atyp = pkt[3];
    // Address body starts at pkt[4]; port follows the body.
    const body = socksAddrLen(atyp, pkt[4..]) catch return error.Invalid;
    const addr_total = 1 + body + 2; // atyp + body + port, relative to pkt[3]
    if (pkt.len < 3 + addr_total) return error.Invalid;

    var addr: SocksAddr = .{};
    addr.len = addr_total;
    @memcpy(addr.bytes[0..addr_total], pkt[3 .. 3 + addr_total]);

    const port_off = 3 + 1 + body; // pkt index of DST.PORT high byte
    const port = std.mem.readInt(u16, pkt[port_off..][0..2], .big);

    return .{
        .frag = frag,
        .addr = addr,
        .port = port,
        .payload = pkt[3 + addr_total ..],
    };
}

/// Build a relay->client UDP datagram: {0,0,0} ++ addr.bytes ++ payload.
/// Returns total bytes written into `out`. `out` must hold 3 + addr.len + payload.len.
pub fn buildClientDatagram(out: []u8, addr: SocksAddr, payload: []const u8) usize {
    out[0] = 0; // RSV
    out[1] = 0; // RSV
    out[2] = 0; // FRAG
    @memcpy(out[3 .. 3 + addr.len], addr.bytes[0..addr.len]);
    const off = 3 + addr.len;
    @memcpy(out[off .. off + payload.len], payload);
    return off + payload.len;
}

// ---------------------------------------------------------------------------
// D3: UoT v2 codec over a borrowed anytls.Stream (or any read/write seam).
// ---------------------------------------------------------------------------
//
// Request header (ONCE, first stream payload):  [IsConnect:1 = 0x00][SOCKS-ADDR]
// Per-datagram frame (both directions):          [SOCKS-ADDR][len:u16 BE][payload]

/// What `readDatagram` produced.
pub const ReadResult = union(enum) {
    /// A full datagram was decoded; payload bytes were copied into out_payload.
    datagram: usize,
    /// Not enough buffered bytes for a complete frame yet (re-poll).
    need_more,
    /// The underlying stream reached EOF.
    eof,
};

/// Generic over the stream type so tests can drive a deterministic in-memory
/// FakeStream. The real call site instantiates `UotStream(anytls.Stream)`.
///
/// Required of `Stream`:
///   fn write(self: *Stream, data: []const u8) !void
///   fn read(self: *Stream, out: []u8) !usize   // 0 = EOF, error.WouldBlock = no data
pub fn UotStream(comptime Stream: type) type {
    return struct {
        const Self = @This();

        stream: *Stream,
        allocator: std.mem.Allocator,
        header_sent: bool = false,
        rx: std.ArrayListUnmanaged(u8) = .empty,
        rx_off: usize = 0,
        /// Source address of the most recently decoded inbound datagram.
        src_addr: SocksAddr = .{},

        pub fn init(allocator: std.mem.Allocator, stream: *Stream) Self {
            return .{ .stream = stream, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.rx.deinit(self.allocator);
        }

        /// Outbound datagram. On the FIRST call also emits the v2 Request header
        /// ([0x00][dst SOCKS-addr]) exactly once. Every datagram then emits
        /// [dst SOCKS-addr][len:u16 BE][payload] in a single stream.write.
        pub fn writeDatagram(self: *Self, dst: SocksAddr, payload: []const u8) !void {
            var hdr: [1 + 262]u8 = undefined; // IsConnect + max SOCKS-addr
            var frame: [262 + 2]u8 = undefined; // SOCKS-addr + u16 len prefix

            if (!self.header_sent) {
                hdr[0] = 0x00; // IsConnect = 0 (unconnected)
                @memcpy(hdr[1 .. 1 + dst.len], dst.bytes[0..dst.len]);
                try self.stream.write(hdr[0 .. 1 + dst.len]);
                self.header_sent = true;
            }

            @memcpy(frame[0..dst.len], dst.bytes[0..dst.len]);
            std.mem.writeInt(u16, frame[dst.len..][0..2], @intCast(payload.len), .big);
            const fhdr = dst.len + 2;
            // Two writes (frame header then payload) avoids a 64KiB stack copy;
            // anytls coalesces both into cmdPSH frames.
            try self.stream.write(frame[0..fhdr]);
            if (payload.len > 0) try self.stream.write(payload);
        }

        /// Inbound datagram. Pulls bytes from the stream into rx, then parses ONE
        /// complete UoT frame. Returns .need_more on insufficient data /
        /// WouldBlock, .eof on stream EOF, or .datagram(n) with payload copied to
        /// out_payload and self.src_addr filled with the raw SOCKS source addr.
        /// Server bytes are untrusted: never parse on under-length rx.
        pub fn readDatagram(self: *Self, out_payload: []u8) !ReadResult {
            while (true) {
                if (try self.tryParse(out_payload)) |res| return res;
                // Not enough buffered; pull more from the stream.
                var scratch: [16 * 1024]u8 = undefined;
                const n = self.stream.read(&scratch) catch |e| switch (e) {
                    error.WouldBlock => return .need_more,
                    else => return e,
                };
                if (n == 0) return .eof; // EOF (any leftover is a truncated frame)
                try self.rx.appendSlice(self.allocator, scratch[0..n]);
            }
        }

        /// Try to decode one frame from rx[rx_off..]. Returns null when more bytes
        /// are needed (caller pulls from the stream). Reject unknown ATYP /
        /// domain_len==0 as error.ProtocolError (server-controlled, untrusted).
        fn tryParse(self: *Self, out_payload: []u8) !?ReadResult {
            const avail = self.rx.items[self.rx_off..];
            if (avail.len < 1) return null; // need ATYP

            const atyp = avail[0];
            const body = socksAddrLen(atyp, avail[1..]) catch |e| switch (e) {
                error.NeedMore => return null, // incomplete addr
                error.Invalid => return error.ProtocolError, // unknown ATYP / domain_len==0
            };
            const addr_total = 1 + body; // atyp + body (no port yet)
            // Need addr + port(2) + len(2) before we even know payload length.
            const port_end = addr_total + 2;
            if (avail.len < port_end + 2) return null;

            const plen = std.mem.readInt(u16, avail[port_end..][0..2], .big);
            const frame_total = port_end + 2 + @as(usize, plen);
            if (avail.len < frame_total) return null; // incomplete payload

            // Full frame available. Copy out the SOCKS source addr (atyp+addr+port).
            const sa_total = addr_total + 2;
            self.src_addr.len = sa_total;
            @memcpy(self.src_addr.bytes[0..sa_total], avail[0..sa_total]);

            const payload = avail[port_end + 2 .. frame_total];
            @memcpy(out_payload[0..payload.len], payload);

            self.rx_off += frame_total;
            // Compact once the consumed prefix dominates the buffer.
            if (self.rx_off == self.rx.items.len) {
                self.rx.clearRetainingCapacity();
                self.rx_off = 0;
            } else if (self.rx_off > 4096) {
                const rem = self.rx.items.len - self.rx_off;
                std.mem.copyForwards(u8, self.rx.items[0..rem], self.rx.items[self.rx_off..]);
                self.rx.shrinkRetainingCapacity(rem);
                self.rx_off = 0;
            }

            return ReadResult{ .datagram = payload.len };
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn mkSocksAddrV4(ip: [4]u8, port: u16) SocksAddr {
    var a: SocksAddr = .{};
    a.bytes[0] = ATYP_V4;
    @memcpy(a.bytes[1..5], &ip);
    std.mem.writeInt(u16, a.bytes[5..7], port, .big);
    a.len = 7;
    return a;
}

// --- D2: socksAddrLen ------------------------------------------------------

test "D2: socksAddrLen v4 body=4" {
    try testing.expectEqual(@as(usize, 4), try socksAddrLen(ATYP_V4, &.{ 1, 2, 3, 4 }));
}

test "D2: socksAddrLen domain body=1+len, header_len=7+len" {
    // domain "abc" (len 3): body = 1+3 = 4; full addr = 1+4+2 = 7; +RSV/FRAG/ATYP
    const rest = [_]u8{ 3, 'a', 'b', 'c' };
    try testing.expectEqual(@as(usize, 4), try socksAddrLen(ATYP_DOMAIN, &rest));
}

test "D2: socksAddrLen v6 body=16, header_len=22" {
    var rest: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 16), try socksAddrLen(ATYP_V6, &rest));
}

test "D2: socksAddrLen domain_len==0 -> error.Invalid" {
    try testing.expectError(error.Invalid, socksAddrLen(ATYP_DOMAIN, &.{0}));
}

test "D2: socksAddrLen short rest -> error.NeedMore" {
    try testing.expectError(error.NeedMore, socksAddrLen(ATYP_V4, &.{ 1, 2 }));
    try testing.expectError(error.NeedMore, socksAddrLen(ATYP_DOMAIN, &.{ 5, 'a' }));
    try testing.expectError(error.NeedMore, socksAddrLen(ATYP_V6, &.{ 1, 2, 3 }));
}

test "D2: socksAddrLen unknown ATYP -> error.Invalid" {
    try testing.expectError(error.Invalid, socksAddrLen(0x02, &.{ 1, 2, 3, 4 }));
}

// --- D2: parseClientDatagram header_len (10 / 7+len / 22) ------------------

test "D2: parse v4 datagram, header_len 10, port BE, payload sliced" {
    // RSV RSV FRAG ATYP=1 IP(4) PORT(2 BE=0x1F90=8080) DATA
    const pkt = [_]u8{ 0, 0, 0, 0x01, 10, 0, 0, 1, 0x1F, 0x90, 'h', 'i' };
    const dg = try parseClientDatagram(&pkt);
    try testing.expectEqual(@as(u8, 0), dg.frag);
    try testing.expectEqual(@as(u16, 8080), dg.port);
    try testing.expectEqual(@as(usize, 7), dg.addr.len); // atyp+4+port
    try testing.expectEqualStrings("hi", dg.payload);
    // Header before DATA is 3 (RSV/FRAG) + 7 (addr) = 10.
    try testing.expectEqual(@as(usize, 10), pkt.len - dg.payload.len);
}

test "D2: parse domain datagram, header_len 7+len" {
    const pkt = [_]u8{ 0, 0, 0, 0x03, 3, 'a', 'b', 'c', 0x00, 0x35, 'x' };
    const dg = try parseClientDatagram(&pkt);
    try testing.expectEqual(@as(u16, 53), dg.port);
    try testing.expectEqualStrings("x", dg.payload);
    // header = 3 + (1 atyp + 1 len + 3 domain + 2 port) = 3 + 7 = 10 = 7+len(3)
    try testing.expectEqual(@as(usize, 7 + 3), pkt.len - dg.payload.len);
}

test "D2: parse v6 datagram, header_len 22" {
    var pkt: [3 + 1 + 16 + 2 + 4]u8 = undefined;
    @memset(&pkt, 0);
    pkt[3] = 0x04; // ATYP v6
    std.mem.writeInt(u16, pkt[3 + 1 + 16 ..][0..2], 443, .big);
    @memcpy(pkt[3 + 1 + 16 + 2 ..], "DATA");
    const dg = try parseClientDatagram(&pkt);
    try testing.expectEqual(@as(u16, 443), dg.port);
    try testing.expectEqualStrings("DATA", dg.payload);
    try testing.expectEqual(@as(usize, 22), pkt.len - dg.payload.len); // 3 + 19
}

test "D2: RSV bytes ignored on parse" {
    const pkt = [_]u8{ 0xAB, 0xCD, 0, 0x01, 10, 0, 0, 1, 0, 0, 'z' };
    const dg = try parseClientDatagram(&pkt);
    try testing.expectEqualStrings("z", dg.payload);
}

test "D2: FRAG != 0 -> error.FragNotSupported" {
    const pkt = [_]u8{ 0, 0, 0x01, 0x01, 10, 0, 0, 1, 0, 0, 'z' };
    try testing.expectError(error.FragNotSupported, parseClientDatagram(&pkt));
}

test "D2: truncated datagram -> error.Invalid" {
    // Claims v4 but only 2 addr bytes present.
    const pkt = [_]u8{ 0, 0, 0, 0x01, 10, 0 };
    try testing.expectError(error.Invalid, parseClientDatagram(&pkt));
    // Too short for even RSV/FRAG/ATYP.
    try testing.expectError(error.Invalid, parseClientDatagram(&.{ 0, 0, 0 }));
}

test "D2: domain_len==0 -> error.Invalid" {
    const pkt = [_]u8{ 0, 0, 0, 0x03, 0, 0, 0, 'd' };
    try testing.expectError(error.Invalid, parseClientDatagram(&pkt));
}

test "D2: parse -> build round-trip" {
    const pkt = [_]u8{ 0, 0, 0, 0x01, 10, 0, 0, 1, 0x1F, 0x90, 'h', 'i' };
    const dg = try parseClientDatagram(&pkt);
    var out: [64]u8 = undefined;
    const n = buildClientDatagram(&out, dg.addr, dg.payload);
    try testing.expectEqualSlices(u8, &pkt, out[0..n]);
}

// --- D3: FakeStream seam ---------------------------------------------------

/// Deterministic in-memory stream. `inbox` feeds `read` in scripted chunks;
/// `outbox` captures `write`. `would_block` makes the next read return WouldBlock
/// once; `eof` makes read return 0 when the inbox is drained.
const FakeStream = struct {
    allocator: std.mem.Allocator,
    inbox: std.ArrayListUnmanaged(u8) = .empty,
    inbox_off: usize = 0,
    outbox: std.ArrayListUnmanaged(u8) = .empty,
    /// Read at most this many bytes per read (0 = unlimited); models chunking.
    read_chunk: usize = 0,
    would_block_once: bool = false,
    eof: bool = false,

    fn init(allocator: std.mem.Allocator) FakeStream {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *FakeStream) void {
        self.inbox.deinit(self.allocator);
        self.outbox.deinit(self.allocator);
    }
    fn feed(self: *FakeStream, bytes: []const u8) !void {
        try self.inbox.appendSlice(self.allocator, bytes);
    }
    fn write(self: *FakeStream, data: []const u8) !void {
        try self.outbox.appendSlice(self.allocator, data);
    }
    // Return type is anyerror!usize (not the inferred {WouldBlock}) so the
    // generic readDatagram's `else => return e` arm stays reachable, matching
    // the real anytls.Stream whose read can surface stream errors.
    fn read(self: *FakeStream, out: []u8) anyerror!usize {
        if (self.would_block_once) {
            self.would_block_once = false;
            return error.WouldBlock;
        }
        const avail = self.inbox.items[self.inbox_off..];
        if (avail.len == 0) {
            if (self.eof) return 0;
            return error.WouldBlock;
        }
        var n = @min(out.len, avail.len);
        if (self.read_chunk != 0) n = @min(n, self.read_chunk);
        @memcpy(out[0..n], avail[0..n]);
        self.inbox_off += n;
        return n;
    }
};

const TestUot = UotStream(FakeStream);

// --- D3: writeDatagram framing ---------------------------------------------

test "D3: writeDatagram emits request header once then per-datagram framing" {
    var fs = FakeStream.init(testing.allocator);
    defer fs.deinit();
    var uot = TestUot.init(testing.allocator, &fs);
    defer uot.deinit();

    const dst = mkSocksAddrV4(.{ 8, 8, 8, 8 }, 53);
    try uot.writeDatagram(dst, "AB");

    // Expect: [0x00][dst(7)]  then  [dst(7)][len=2 BE][AB]
    var expected: std.ArrayListUnmanaged(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.append(testing.allocator, 0x00);
    try expected.appendSlice(testing.allocator, dst.slice());
    try expected.appendSlice(testing.allocator, dst.slice());
    try expected.appendSlice(testing.allocator, &.{ 0x00, 0x02 });
    try expected.appendSlice(testing.allocator, "AB");
    try testing.expectEqualSlices(u8, expected.items, fs.outbox.items);

    // Second datagram: NO header, just [dst][len][payload].
    fs.outbox.clearRetainingCapacity();
    try uot.writeDatagram(dst, "C");
    var expected2: std.ArrayListUnmanaged(u8) = .empty;
    defer expected2.deinit(testing.allocator);
    try expected2.appendSlice(testing.allocator, dst.slice());
    try expected2.appendSlice(testing.allocator, &.{ 0x00, 0x01 });
    try expected2.appendSlice(testing.allocator, "C");
    try testing.expectEqualSlices(u8, expected2.items, fs.outbox.items);
}

// --- D3: readDatagram reassembly -------------------------------------------

fn frameBytes(allocator: std.mem.Allocator, addr: SocksAddr, payload: []const u8) ![]u8 {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    try b.appendSlice(allocator, addr.slice());
    var lenb: [2]u8 = undefined;
    std.mem.writeInt(u16, &lenb, @intCast(payload.len), .big);
    try b.appendSlice(allocator, &lenb);
    try b.appendSlice(allocator, payload);
    return b.toOwnedSlice(allocator);
}

test "D3: readDatagram reassembles a frame split across two reads" {
    var fs = FakeStream.init(testing.allocator);
    defer fs.deinit();
    var uot = TestUot.init(testing.allocator, &fs);
    defer uot.deinit();

    const src = mkSocksAddrV4(.{ 1, 1, 1, 1 }, 9000);
    const frame = try frameBytes(testing.allocator, src, "hello");
    defer testing.allocator.free(frame);

    // First read delivers only the first 4 bytes -> need_more.
    try fs.feed(frame[0..4]);
    var out: [128]u8 = undefined;
    try testing.expectEqual(ReadResult.need_more, try uot.readDatagram(&out));

    // Feed the rest -> full datagram.
    try fs.feed(frame[4..]);
    const res = try uot.readDatagram(&out);
    try testing.expectEqual(@as(usize, 5), res.datagram);
    try testing.expectEqualStrings("hello", out[0..5]);
    try testing.expectEqualSlices(u8, src.slice(), uot.src_addr.slice());
}

test "D3: drains two frames in one read then need_more" {
    var fs = FakeStream.init(testing.allocator);
    defer fs.deinit();
    var uot = TestUot.init(testing.allocator, &fs);
    defer uot.deinit();

    const a = mkSocksAddrV4(.{ 2, 2, 2, 2 }, 1 );
    const b = mkSocksAddrV4(.{ 3, 3, 3, 3 }, 2 );
    const fa = try frameBytes(testing.allocator, a, "one");
    defer testing.allocator.free(fa);
    const fb = try frameBytes(testing.allocator, b, "two");
    defer testing.allocator.free(fb);
    try fs.feed(fa);
    try fs.feed(fb);

    var out: [128]u8 = undefined;
    const r1 = try uot.readDatagram(&out);
    try testing.expectEqual(@as(usize, 3), r1.datagram);
    try testing.expectEqualStrings("one", out[0..3]);
    const r2 = try uot.readDatagram(&out);
    try testing.expectEqual(@as(usize, 3), r2.datagram);
    try testing.expectEqualStrings("two", out[0..3]);
    // No more buffered, no EOF set -> need_more.
    try testing.expectEqual(ReadResult.need_more, try uot.readDatagram(&out));
}

test "D3: stream WouldBlock -> need_more" {
    var fs = FakeStream.init(testing.allocator);
    defer fs.deinit();
    fs.would_block_once = true;
    var uot = TestUot.init(testing.allocator, &fs);
    defer uot.deinit();
    var out: [16]u8 = undefined;
    try testing.expectEqual(ReadResult.need_more, try uot.readDatagram(&out));
}

test "D3: stream EOF -> eof" {
    var fs = FakeStream.init(testing.allocator);
    defer fs.deinit();
    fs.eof = true;
    var uot = TestUot.init(testing.allocator, &fs);
    defer uot.deinit();
    var out: [16]u8 = undefined;
    try testing.expectEqual(ReadResult.eof, try uot.readDatagram(&out));
}

test "D3: malformed server bytes (ATYP=0x04 then <16) -> need_more not a bad parse" {
    var fs = FakeStream.init(testing.allocator);
    defer fs.deinit();
    var uot = TestUot.init(testing.allocator, &fs);
    defer uot.deinit();
    // ATYP v6 but only 3 of 16 addr bytes; no EOF -> need_more, never parses.
    try fs.feed(&.{ 0x04, 0xDE, 0xAD, 0xBE });
    var out: [16]u8 = undefined;
    try testing.expectEqual(ReadResult.need_more, try uot.readDatagram(&out));
}

test "D3: unknown ATYP -> ProtocolError" {
    var fs = FakeStream.init(testing.allocator);
    defer fs.deinit();
    var uot = TestUot.init(testing.allocator, &fs);
    defer uot.deinit();
    try fs.feed(&.{ 0x02, 1, 2, 3, 4, 0, 0, 0, 0 });
    var out: [16]u8 = undefined;
    try testing.expectError(error.ProtocolError, uot.readDatagram(&out));
}

test "D3: domain ATYP with domain_len==0 -> ProtocolError" {
    var fs = FakeStream.init(testing.allocator);
    defer fs.deinit();
    var uot = TestUot.init(testing.allocator, &fs);
    defer uot.deinit();
    // Need >= 2 bytes (atyp + len) before socksAddrLen rejects len==0.
    try fs.feed(&.{ 0x03, 0x00 });
    var out: [16]u8 = undefined;
    try testing.expectError(error.ProtocolError, uot.readDatagram(&out));
}

test "D3: partial-frame held in rx survives across reads (notifier-drain safety)" {
    // Mirrors the design note: a partial UoT frame buffered in rx must not be
    // lost when stream.read yields chunk-by-chunk; the next chunk completes it.
    var fs = FakeStream.init(testing.allocator);
    defer fs.deinit();
    fs.read_chunk = 1; // one byte per read, maximally adversarial chunking
    var uot = TestUot.init(testing.allocator, &fs);
    defer uot.deinit();

    const src = mkSocksAddrV4(.{ 4, 4, 4, 4 }, 7 );
    const frame = try frameBytes(testing.allocator, src, "ok");
    defer testing.allocator.free(frame);
    try fs.feed(frame);

    var out: [16]u8 = undefined;
    const res = try uot.readDatagram(&out); // loops pulling 1 byte at a time
    try testing.expectEqual(@as(usize, 2), res.datagram);
    try testing.expectEqualStrings("ok", out[0..2]);
}

// Reference both magic constants so they are part of the compiled surface.
test "constants" {
    try testing.expectEqual(@as(u16, 443), MAGIC_PORT);
    try testing.expect(MAGIC_DOMAIN.len > 0);
}
