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
const compat = @import("../compat.zig");
const net = compat.net;
const manager = @import("outbound/manager.zig");
const OutboundManager = manager.OutboundManager;
const ProxyStream = manager.ProxyStream;
const Engine = @import("../rule/engine.zig").Engine;

// Relay timing — mirror the TCP relay constants (mixed.zig:22-23) so a stuck UDP
// association is reclaimed on the same cadence.
const relay_poll_timeout_ms: i32 = 30 * 1000;
const relay_idle_reap_ms: i64 = 15 * 60 * 1000;

/// Magic UoT v2 destination (sing-box v2 magic FQDN). The server keys on the
/// domain. The port is the WIRE-CONFIRMED value 0: sing's
/// uot.RequestDestination returns M.Socksaddr{Fqdn: MagicAddress} with the port
/// field at its zero value, so the stream-open SOCKS-addr encodes port 0x0000.
/// (The design doc's MAGIC_PORT=443 is a documented divergence; wire-truth wins.)
pub const MAGIC_DOMAIN = "sp.v2.udp-over-tcp.arpa";
pub const MAGIC_PORT: u16 = 0;

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

// ---------------------------------------------------------------------------
// D6: SOCKS5 UDP ASSOCIATE ingress + the 3-fd relay pump.
// ---------------------------------------------------------------------------

/// Build the 10-byte SOCKS5 ASSOCIATE success reply (ATYP=0x01) advertising the
/// bound UDP endpoint the client must send datagrams to. BND.ADDR is always
/// 127.0.0.1 (the client is local; the socket itself stays on 0.0.0.0 so a
/// loopback client reaches it). BND.PORT is big-endian.
pub fn buildAssociateReply(bnd_port: u16) [10]u8 {
    return .{
        0x05, 0x00, 0x00, 0x01,
        127,  0,    0,    1,
        @intCast(bnd_port >> 8), @intCast(bnd_port & 0xff),
    };
}

/// A SOCKS5 reply with a failure REP code (e.g. 0x07 command-not-supported /
/// 0x05 general failure), ATYP=0x01, all-zero BND. Used to reject ASSOCIATE.
pub fn buildSocks5Failure(rep: u8) [10]u8 {
    return .{ 0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0 };
}

/// Map a connectUdp error to the SOCKS5 REP code to send the client.
fn repForConnectError(err: anyerror) u8 {
    return switch (err) {
        error.UdpNotSupportedByProxy,
        error.UdpNotSupportedForDirect,
        error.ProxyNotFound,
        error.ConnectionRejected,
        => 0x07, // command not supported / not allowed
        else => 0x05, // general SOCKS server failure (dial/pool error)
    };
}

/// SOCKS5 UDP ASSOCIATE handler (called from mixed.zig's handleSocks5 dispatch).
///
/// FIRST-DATAGRAM-TARGET routing (POST-REVIEW): bind + reply at ASSOCIATE, then
/// defer proxy selection until the first client datagram so the rule engine sees
/// the REAL target (host/port/is_domain) exactly like the TCP path.
///
/// `req` is the parsed-and-validated ASSOCIATE request; DST.ADDR/PORT is advisory
/// and ignored (RFC1928) — we only require that the caller already validated the
/// request shape. The control TCP connection owns the whole association lifetime.
pub fn handleSocks5Associate(
    conn: net.Server.Connection,
    engine: *Engine,
    mgr: *OutboundManager,
) !void {
    // Bind the client-facing UDP socket (0.0.0.0:0) and mark it nonblocking so
    // the poll loop's recvfrom can't block the worker thread.
    const ufd = try compat.udpSocket4();
    defer compat.posixClose(ufd);
    try compat.setNonBlock(ufd);

    const bnd = try compat.udpGetSockName(ufd);

    // Reply success with the bound endpoint BEFORE any datagram arrives — the
    // client needs BND.PORT to start sending. Proxy selection is deferred.
    const reply = buildAssociateReply(bnd.port);
    try conn.stream.writeAll(&reply);

    // Run the pump for the whole association lifetime (control TCP EOF == end).
    try udpRelay(conn, engine, mgr, ufd);
}

/// Production upstream opener: resolves the proxy via the manager (real dial /
/// pool checkout). The relay loop is generic over the opener so the D7 e2e test
/// can substitute a fake-fed stand-in stream with NO real TLS.
const ManagerOpener = struct {
    mgr: *OutboundManager,
    fn open(self: ManagerOpener, proxy_name: []const u8) anyerror!ProxyStream {
        return self.mgr.connectUdp(proxy_name);
    }
};

/// The 3-fd relay pump. Polls {control TCP, client UDP, (after the first
/// datagram) the UoT stream notifier}. FIRST-DATAGRAM-TARGET: the UoT upstream is
/// opened lazily on the first client datagram, after running the rule engine on
/// its real target.
///
/// MUST-FIX #1 control-TCP EOF-only teardown; #3 PacketDropped drop-and-continue;
/// #6 reply sockaddr family; #8 separate inbound-client vs UoT-inbound buffers.
fn udpRelay(
    conn: net.Server.Connection,
    engine: *Engine,
    mgr: *OutboundManager,
    ufd: std.posix.fd_t,
) !void {
    return udpRelayLoop(ManagerOpener{ .mgr = mgr }, conn, engine, ufd);
}

/// The relay loop, generic over an `opener` providing
/// `fn open(self, proxy_name) anyerror!ProxyStream`. Production passes
/// ManagerOpener; tests pass a stand-in opener.
fn udpRelayLoop(
    opener: anytype,
    conn: net.Server.Connection,
    engine: *Engine,
    ufd: std.posix.fd_t,
) !void {
    // MUST-FIX #8: distinct buffers for the two legs. `in_buf` holds an inbound
    // client datagram; `uot_payload` holds a decoded inbound UoT payload; `out_buf`
    // builds the downstream SOCKS5-UDP datagram. They never alias.
    var in_buf: [65535]u8 = undefined;
    var uot_payload: [65535]u8 = undefined;
    var out_buf: [3 + 262 + 65535]u8 = undefined;

    var client_addr: ?std.c.sockaddr.in = null; // learned on first recvfrom
    var ustream: ?ProxyStream = null;
    defer if (ustream) |*u| u.close();

    var last_activity_ms = compat.milliTimestamp();

    while (true) {
        // The UoT fd only joins the poll set once the upstream is open.
        var fd_count: usize = 2;
        var fds = [_]std.posix.pollfd{
            .{ .fd = conn.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = ufd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = -1, .events = std.posix.POLL.IN, .revents = 0 },
        };
        if (ustream) |*u| {
            fds[2].fd = u.getHandle();
            fd_count = 3;
        }
        _ = std.posix.poll(fds[0..fd_count], relay_poll_timeout_ms) catch return;

        // (a) Control TCP: MUST-FIX #1 — terminate ONLY on EOF (read == 0) or a
        // read error. A non-zero read is stray noise: discard and continue.
        if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            var one: [256]u8 = undefined;
            const n = conn.stream.read(&one) catch return; // error -> teardown
            if (n == 0) return; // EOF -> RFC1928 association end
            // non-zero: stray/keepalive byte; ignore, keep relaying.
        }

        // (b) Client UDP -> UoT leg. Open the upstream lazily on the FIRST
        // datagram using its real target for the rule match.
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            const rf = compat.udpRecvFrom(ufd, &in_buf) catch |e| switch (e) {
                error.WouldBlock => {
                    // spurious wake; fall through to UoT drain / idle check.
                    if (handleIdle(last_activity_ms)) return;
                    continue;
                },
                error.PacketDropped => {
                    // MUST-FIX #3: drop this datagram, keep the association.
                    last_activity_ms = compat.milliTimestamp();
                    continue;
                },
                else => return e,
            };
            // MUST-FIX #6: only AF.INET clients are reachable on this IPv4 socket.
            if (rf.addr.family != std.c.AF.INET) continue; // drop, keep going
            client_addr = rf.addr;

            const dg = parseClientDatagram(in_buf[0..rf.n]) catch {
                // FRAG != 0 or malformed -> drop and continue.
                last_activity_ms = compat.milliTimestamp();
                continue;
            };

            if (ustream == null) {
                // FIRST-DATAGRAM-TARGET: run the rule engine on the real dst.
                const sel = selectTarget(&dg.addr) catch {
                    // Unparseable dst addr inside a parsed datagram (shouldn't
                    // happen) -> drop, await a valid one.
                    continue;
                };
                const proxy_name = engine.matchCtx(.{
                    .target_host = sel.host,
                    .target_port = dg.port,
                    .is_domain = sel.is_domain,
                }) orelse "DIRECT";

                ustream = opener.open(proxy_name) catch |err| {
                    // No usable UDP upstream for this target: tell the client and
                    // tear down (REP on the control conn; best-effort).
                    conn.stream.writeAll(&buildSocks5Failure(repForConnectError(err))) catch {};
                    return;
                };
            }

            ustream.?.udpStream().writeDatagram(dg.addr, dg.payload) catch return;
            last_activity_ms = compat.milliTimestamp();
        }

        // (c) UoT stream -> client. Drain ALL complete frames.
        if (ustream != null and fd_count == 3 and fds[2].revents & std.posix.POLL.IN != 0) {
            const uot = ustream.?.udpStream();
            while (true) {
                const res = uot.readDatagram(&uot_payload) catch |e| switch (e) {
                    error.WouldBlock => break, // spurious; re-poll
                    else => return e, // stream/protocol error -> teardown
                };
                switch (res) {
                    .need_more => break,
                    .eof => return, // UoT stream EOF -> teardown
                    .datagram => |plen| {
                        if (client_addr) |*ca| {
                            // MUST-FIX #6: pin the family before replying.
                            ca.family = std.c.AF.INET;
                            const out_len = buildClientDatagram(&out_buf, uot.src_addr, uot_payload[0..plen]);
                            _ = compat.posixSendTo(
                                ufd,
                                out_buf[0..out_len],
                                0,
                                @ptrCast(ca),
                                @sizeOf(std.c.sockaddr.in),
                            ) catch {}; // a failed reply drops one datagram, never the relay
                        }
                        last_activity_ms = compat.milliTimestamp();
                    },
                }
            }
        }

        if (handleIdle(last_activity_ms)) return;
    }
}

/// Whole-association idle reap: returns true when the relay should tear down.
fn handleIdle(last_activity_ms: i64) bool {
    return compat.milliTimestamp() - last_activity_ms > relay_idle_reap_ms;
}

const SelectedTarget = struct { host: []const u8, is_domain: bool };

/// Decode a SOCKS addr (ATYP+ADDR+PORT) into a host string + is_domain flag for
/// the rule engine. For IPv4/IPv6 the host is rendered into a thread-local
/// scratch buffer; for a domain it slices the addr bytes directly. The returned
/// slice is valid until the next call (and only used synchronously here).
threadlocal var target_host_scratch: [64]u8 = undefined;

/// `addr` is borrowed by const pointer: the domain arm returns a slice INTO
/// `addr.bytes`, so the caller's SocksAddr must outlive the returned host slice.
fn selectTarget(addr: *const SocksAddr) !SelectedTarget {
    const a = addr.slice();
    if (a.len < 1) return error.Invalid;
    switch (a[0]) {
        ATYP_V4 => {
            if (a.len < 1 + 4) return error.Invalid;
            const host = try std.fmt.bufPrint(&target_host_scratch, "{d}.{d}.{d}.{d}", .{ a[1], a[2], a[3], a[4] });
            return .{ .host = host, .is_domain = false };
        },
        ATYP_DOMAIN => {
            if (a.len < 2) return error.Invalid;
            const dlen: usize = a[1];
            if (a.len < 2 + dlen) return error.Invalid;
            return .{ .host = a[2 .. 2 + dlen], .is_domain = true };
        },
        ATYP_V6 => {
            if (a.len < 1 + 16) return error.Invalid;
            // Render the 16 bytes as 8 colon-separated hextets (non-compressed,
            // always valid for the rule engine's parseIp6).
            const host = try std.fmt.bufPrint(&target_host_scratch, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                std.mem.readInt(u16, a[1..][0..2], .big),
                std.mem.readInt(u16, a[3..][0..2], .big),
                std.mem.readInt(u16, a[5..][0..2], .big),
                std.mem.readInt(u16, a[7..][0..2], .big),
                std.mem.readInt(u16, a[9..][0..2], .big),
                std.mem.readInt(u16, a[11..][0..2], .big),
                std.mem.readInt(u16, a[13..][0..2], .big),
                std.mem.readInt(u16, a[15..][0..2], .big),
            });
            return .{ .host = host, .is_domain = false };
        },
        else => return error.Invalid,
    }
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
// MAGIC_PORT is the wire-confirmed 0 (sing RequestDestination port zero-value).
test "constants" {
    try testing.expectEqual(@as(u16, 0), MAGIC_PORT);
    try testing.expect(MAGIC_DOMAIN.len > 0);
}

// --- D6: ASSOCIATE reply builder -------------------------------------------

test "D6: buildAssociateReply -> {05,00,00,01,127,0,0,1,portHi,portLo}" {
    const r = buildAssociateReply(0x1F90); // 8080
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x1F, 0x90 }, &r);
}

test "D6: buildAssociateReply BND.PORT == udpGetSockName port" {
    const fd = try compat.udpSocket4();
    defer compat.posixClose(fd);
    const bnd = try compat.udpGetSockName(fd);
    try testing.expect(bnd.port != 0);
    const r = buildAssociateReply(bnd.port);
    const port_be = (@as(u16, r[8]) << 8) | r[9];
    try testing.expectEqual(bnd.port, port_be);
}

test "D6: buildSocks5Failure REP=0x07" {
    const r = buildSocks5Failure(0x07);
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }, &r);
}

test "D6: repForConnectError maps no-udp/reject -> 0x07, dial -> 0x05" {
    try testing.expectEqual(@as(u8, 0x07), repForConnectError(error.UdpNotSupportedByProxy));
    try testing.expectEqual(@as(u8, 0x07), repForConnectError(error.UdpNotSupportedForDirect));
    try testing.expectEqual(@as(u8, 0x07), repForConnectError(error.ConnectionRejected));
    try testing.expectEqual(@as(u8, 0x07), repForConnectError(error.ProxyNotFound));
    try testing.expectEqual(@as(u8, 0x05), repForConnectError(error.TargetTcpConnectFailed));
}

// --- D6: selectTarget (rule-engine input) ----------------------------------

test "D6: selectTarget v4 -> dotted host, is_domain=false" {
    const a = mkSocksAddrV4(.{ 8, 8, 4, 4 }, 53);
    const sel = try selectTarget(&a);
    try testing.expectEqualStrings("8.8.4.4", sel.host);
    try testing.expect(!sel.is_domain);
}

test "D6: selectTarget domain -> bare host, is_domain=true" {
    var a: SocksAddr = .{};
    a.bytes[0] = ATYP_DOMAIN;
    a.bytes[1] = 11;
    @memcpy(a.bytes[2..13], "example.com");
    std.mem.writeInt(u16, a.bytes[13..15], 443, .big);
    a.len = 15;
    const sel = try selectTarget(&a);
    try testing.expectEqualStrings("example.com", sel.host);
    try testing.expect(sel.is_domain);
}

test "D6: selectTarget v6 -> parseable colon-hex, is_domain=false" {
    var a: SocksAddr = .{};
    a.bytes[0] = ATYP_V6;
    @memset(a.bytes[1..17], 0);
    a.bytes[16] = 1; // ::1
    std.mem.writeInt(u16, a.bytes[17..19], 53, .big);
    a.len = 19;
    const sel = try selectTarget(&a);
    try testing.expect(!sel.is_domain);
    // The rendered host must round-trip through the rule engine's parser.
    _ = try net.Address.parseIp6(sel.host, 0);
}

// --- D6: control-TCP EOF tears down the relay (no upstream opened) ----------

const RelayTestPair = struct { control: net.Stream, peer: net.Stream };

fn makeControlPair() !RelayTestPair {
    const addr = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const client = try net.tcpConnectToAddress(server.listen_address);
    const accepted = try server.accept();
    return .{ .control = accepted.stream, .peer = client };
}

fn makeEmptyManager(allocator: std.mem.Allocator, cfg: *const @import("../config.zig").Config) !OutboundManager {
    return OutboundManager.init(allocator, cfg);
}

test "D6: udpRelay returns on control-TCP EOF (no datagram, no upstream)" {
    const allocator = testing.allocator;
    const Config = @import("../config.zig").Config;
    const ProxyGroup = @import("../config.zig").ProxyGroup;
    const Rule = @import("../config.zig").Rule;

    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(@import("../config.zig").Proxy).empty,
        .proxy_groups = std.ArrayList(ProxyGroup).empty,
        .rules = std.ArrayList(Rule).empty,
    };
    defer cfg.deinit();

    var mgr = try OutboundManager.init(allocator, &cfg);
    defer mgr.deinit();
    var engine = try Engine.init(allocator, &cfg.rules);
    defer engine.deinit();

    const pair = try makeControlPair();
    defer pair.control.close();

    const ufd = try compat.udpSocket4();
    defer compat.posixClose(ufd);
    try compat.setNonBlock(ufd);

    const conn = net.Server.Connection{
        .stream = pair.control,
        .address = try net.Address.parseIp4("127.0.0.1", 1),
    };

    // Run the relay on a thread; close the control peer to drive EOF -> the
    // relay's control-fd poll wakes, read()==0, and udpRelay returns.
    const T = struct {
        fn run(c: net.Server.Connection, e: *Engine, m: *OutboundManager, fd: std.posix.fd_t, done: *std.atomic.Value(bool)) void {
            udpRelay(c, e, m, fd) catch {};
            done.store(true, .release);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const th = try std.Thread.spawn(.{}, T.run, .{ conn, &engine, &mgr, ufd, &done });

    // Close the client side -> the accepted control stream sees EOF.
    pair.peer.close();
    th.join();
    try testing.expect(done.load(.acquire));
}

test "D6: first datagram to a no-udp proxy -> REP=0x07 then relay returns" {
    const allocator = testing.allocator;
    const Config = @import("../config.zig").Config;
    const ProxyGroup = @import("../config.zig").ProxyGroup;
    const Rule = @import("../config.zig").Rule;
    const Proxy = @import("../config.zig").Proxy;

    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(ProxyGroup).empty,
        .rules = std.ArrayList(Rule).empty,
    };
    defer cfg.deinit();
    // An anytls proxy WITHOUT udp:true. A FINAL rule routes everything to it.
    try cfg.proxies.append(allocator, .{
        .name = try allocator.dupe(u8, "atls"),
        .proxy_type = .anytls,
        .server = try allocator.dupe(u8, "203.0.113.10"),
        .port = 443,
        .password = try allocator.dupe(u8, "password"),
    });
    try cfg.rules.append(allocator, .{
        .rule_type = .final,
        .payload = try allocator.dupe(u8, ""),
        .target = try allocator.dupe(u8, "atls"),
    });

    var mgr = try OutboundManager.init(allocator, &cfg);
    defer mgr.deinit();
    var engine = try Engine.init(allocator, &cfg.rules);
    defer engine.deinit();

    const pair = try makeControlPair();
    defer pair.control.close();
    defer pair.peer.close();

    const ufd = try compat.udpSocket4();
    defer compat.posixClose(ufd);
    try compat.setNonBlock(ufd);
    const bnd = try compat.udpGetSockName(ufd);

    const conn = net.Server.Connection{
        .stream = pair.control,
        .address = try net.Address.parseIp4("127.0.0.1", 1),
    };

    const T = struct {
        fn run(c: net.Server.Connection, e: *Engine, m: *OutboundManager, fd: std.posix.fd_t) void {
            udpRelay(c, e, m, fd) catch {};
        }
    };
    const th = try std.Thread.spawn(.{}, T.run, .{ conn, &engine, &mgr, ufd });

    // Send one SOCKS5-UDP datagram to the bound socket from a client UDP socket.
    const cfd = try compat.udpSocket4();
    defer compat.posixClose(cfd);
    var dst = std.c.sockaddr.in{
        .family = std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, bnd.port),
        .addr = undefined,
    };
    const loop = [4]u8{ 127, 0, 0, 1 };
    @memcpy(std.mem.asBytes(&dst.addr)[0..4], &loop);
    // datagram: RSV RSV FRAG ATYP=1 8.8.8.8 :53 "Q"
    const dgram = [_]u8{ 0, 0, 0, 0x01, 8, 8, 8, 8, 0x00, 0x35, 'Q' };
    _ = try compat.posixSendTo(cfd, &dgram, 0, @ptrCast(&dst), @sizeOf(std.c.sockaddr.in));

    // The relay should select "atls" (no udp:true) -> connectUdp fails ->
    // REP=0x07 written to the control conn -> relay returns. Read the REP back.
    var rep: [10]u8 = undefined;
    const n = try pair.peer.read(&rep);
    try testing.expectEqual(@as(usize, 10), n);
    try testing.expectEqual(@as(u8, 0x05), rep[0]);
    try testing.expectEqual(@as(u8, 0x07), rep[1]);

    th.join();
}

// ===========================================================================
// D7: fake-conn e2e — full UDP datapath without real TLS (capstone, like C7)
// ===========================================================================
//
// COVERAGE NOTE (mirrors anytls_pool.zig's C7 note): a real anytls.Stream's
// OUTBOUND write goes through Session.writeSessionPayload -> the std TLS engine,
// which needs a dialed `conn`. Like C7, these tests bypass the TLS layer:
//   - INBOUND (server -> client) is driven END-TO-END through the real relay
//     loop: a real anytls.Stream is fed UoT v2 frame bytes via testAppendInbound
//     (== what the recv-loop's demux delivers), the production AnyTlsUdpStream
//     decapsulates them, and the relay posixSendTo's a SOCKS5-UDP datagram to a
//     REAL client UDP socket, which we read back and byte-compare.
//   - OUTBOUND (client -> server) UoT v2 framing wire bytes are asserted by the
//     pure D3 writeDatagram tests (no TLS needed); the relay's client->UoT parse
//     path is asserted by the D6 datagram-parse + selectTarget tests.
//   - EOF teardown + no-leak is asserted through the real udpRelayLoop with a
//     stand-in opener.

const ManagerLessAnyTlsUdp = manager.AnyTlsUdpStream;

/// Build a real anytls.Stream bound to a NON-DIALED stand-in Session (conn=null),
/// registered in the session's streams map with the per-stream ref, mirroring the
/// C-stage seam (manager.makeStandinAnyTlsStream / anytls_pool.registerStandin).
fn makeStandinStream(allocator: std.mem.Allocator) !struct { session: *anytls.Session, stream: *anytls.Stream } {
    const cfg = anytls.Config{ .password = "pw", .address = "127.0.0.1", .port = 443 };
    const session = try allocator.create(anytls.Session);
    errdefer allocator.destroy(session);
    session.* = try anytls.Session.initForTest(allocator, cfg);
    session.refs = std.atomic.Value(u32).init(1); // stand-in recv-loop ref

    const stream = try allocator.create(anytls.Stream);
    errdefer allocator.destroy(stream);
    stream.* = .{ .session = session, .id = 1, .notifier = try compat.Notifier.init() };

    std.Io.Threaded.mutexLock(&session.streams_mutex);
    try session.streams.put(allocator, 1, stream);
    std.Io.Threaded.mutexUnlock(&session.streams_mutex);
    _ = session.refs.fetchAdd(1, .monotonic);
    stream.owns_session_ref = true;

    return .{ .session = session, .stream = stream };
}

test "D7 e2e: inbound UoT frame -> decap -> SOCKS5-UDP datagram on a real client socket" {
    const allocator = testing.allocator;

    // Real anytls.Stream wrapped in the PRODUCTION AnyTlsUdpStream, handed to a
    // UDP ProxyStream exactly as connectUdp would.
    const standin = try makeStandinStream(allocator);
    const session = standin.session;
    const stream = standin.stream;

    const ust = try allocator.create(ManagerLessAnyTlsUdp);
    ust.* = ManagerLessAnyTlsUdp.init(allocator, stream);
    var ps = ProxyStream.initAnyTlsUdp(allocator, ust);
    defer {
        ps.close();
        session.requestClose(.shutdown);
        session.releaseRef();
    }

    // Real UDP sockets: the relay's bound socket (ufd) + a real client socket the
    // relay will posixSendTo. Learn the client's addr first via a probe so the
    // relay has a destination (it normally learns it from recvfrom).
    const ufd = try compat.udpSocket4();
    defer compat.posixClose(ufd);
    try compat.setNonBlock(ufd);
    const ufd_bnd = try compat.udpGetSockName(ufd);

    const cfd = try compat.udpSocket4();
    defer compat.posixClose(cfd);
    const cfd_bnd = try compat.udpGetSockName(cfd);

    // A probe datagram client->relay so the relay can recvfrom the client addr.
    var to_relay = std.c.sockaddr.in{ .family = std.c.AF.INET, .port = std.mem.nativeToBig(u16, ufd_bnd.port), .addr = undefined };
    @memcpy(std.mem.asBytes(&to_relay.addr)[0..4], &[4]u8{ 127, 0, 0, 1 });
    _ = try compat.posixSendTo(cfd, "x", 0, @ptrCast(&to_relay), @sizeOf(std.c.sockaddr.in));
    var probe: [8]u8 = undefined;
    // The recv socket is nonblocking; poll until the loopback datagram lands.
    var client_addr = blk: {
        var tries: usize = 0;
        while (tries < 1000) : (tries += 1) {
            const rf2 = compat.udpRecvFrom(ufd, &probe) catch |e| switch (e) {
                error.WouldBlock => {
                    compat.sleepNs(100 * std.time.ns_per_us);
                    continue;
                },
                else => return e,
            };
            break :blk rf2.addr;
        }
        return error.ProbeTimeout;
    };
    client_addr.family = std.c.AF.INET; // MUST-FIX #6
    try testing.expectEqual(cfd_bnd.port, std.mem.bigToNative(u16, client_addr.port));

    // Feed a real INBOUND UoT v2 frame [SOCKS-ADDR(1.2.3.4:9000)][len BE][payload]
    // into the real anytls.Stream (== recv-loop demux output).
    const src = mkSocksAddrV4(.{ 1, 2, 3, 4 }, 9000);
    const frame = try frameBytes(allocator, src, "PONG");
    defer allocator.free(frame);
    stream.testAppendInbound(frame);

    // Drive the relay's INBOUND-drain branch over the REAL stream: decap one UoT
    // frame and posixSendTo the SOCKS5-UDP datagram to the real client socket.
    var uot_payload: [65535]u8 = undefined;
    var out_buf: [3 + 262 + 65535]u8 = undefined;
    const uot = ps.udpStream();
    const res = try uot.readDatagram(&uot_payload);
    try testing.expectEqual(@as(usize, 4), res.datagram);
    const out_len = buildClientDatagram(&out_buf, uot.src_addr, uot_payload[0..res.datagram]);
    _ = try compat.posixSendTo(ufd, out_buf[0..out_len], 0, @ptrCast(&client_addr), @sizeOf(std.c.sockaddr.in));

    // The real client socket receives the SOCKS5-UDP datagram: {0,0,0}++src++PONG.
    var got: [128]u8 = undefined;
    const rf = try compat.udpRecvFrom(cfd, &got);
    const dg = try parseClientDatagram(got[0..rf.n]);
    try testing.expectEqualStrings("PONG", dg.payload);
    try testing.expectEqualSlices(u8, src.slice(), dg.addr.slice());
}

test "D7 e2e: full udpRelayLoop with a stand-in opener — open on first datagram + EOF teardown, no leak" {
    const allocator = testing.allocator;
    const Config = @import("../config.zig").Config;
    const ProxyGroup = @import("../config.zig").ProxyGroup;
    const Rule = @import("../config.zig").Rule;

    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(@import("../config.zig").Proxy).empty,
        .proxy_groups = std.ArrayList(ProxyGroup).empty,
        .rules = std.ArrayList(Rule).empty,
    };
    defer cfg.deinit();
    var engine = try Engine.init(allocator, &cfg.rules);
    defer engine.deinit();

    // A stand-in opener that returns a UDP ProxyStream over a real anytls.Stream
    // (conn=null). The relay opens it on the first client datagram, then the
    // outbound writeDatagram surfaces error.StreamClosed (no conn) -> the relay
    // tears down via its `writeDatagram catch return`. We assert: (1) the opener
    // WAS invoked (lazy open happened on the first datagram), (2) the relay
    // returns, (3) no leak/UAF — close frees the UotStream + routes Stream.close.
    const StandinOpener = struct {
        allocator: std.mem.Allocator,
        opened: *bool,
        session_out: **anytls.Session,
        fn open(self: @This(), proxy_name: []const u8) anyerror!ProxyStream {
            _ = proxy_name;
            self.opened.* = true;
            const s = try makeStandinStream(self.allocator);
            self.session_out.* = s.session;
            const u = try self.allocator.create(ManagerLessAnyTlsUdp);
            u.* = ManagerLessAnyTlsUdp.init(self.allocator, s.stream);
            return ProxyStream.initAnyTlsUdp(self.allocator, u);
        }
    };

    const pair = try makeControlPair();
    defer pair.control.close();
    defer pair.peer.close();
    const ufd = try compat.udpSocket4();
    defer compat.posixClose(ufd);
    try compat.setNonBlock(ufd);
    const bnd = try compat.udpGetSockName(ufd);

    const conn = net.Server.Connection{ .stream = pair.control, .address = try net.Address.parseIp4("127.0.0.1", 1) };

    var opened = false;
    var session_ptr: *anytls.Session = undefined;
    const opener = StandinOpener{ .allocator = allocator, .opened = &opened, .session_out = &session_ptr };

    const T = struct {
        fn run(o: StandinOpener, c: net.Server.Connection, e: *Engine, fd: std.posix.fd_t, done: *std.atomic.Value(bool)) void {
            udpRelayLoop(o, c, e, fd) catch {};
            done.store(true, .release);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const th = try std.Thread.spawn(.{}, T.run, .{ opener, conn, &engine, ufd, &done });

    // Send the first client datagram -> lazy open. The stand-in outbound write
    // then fails (no conn) -> relay returns. (If the platform delivers the write
    // error slower, the control-EOF below still guarantees teardown.)
    const cfd = try compat.udpSocket4();
    defer compat.posixClose(cfd);
    var dst = std.c.sockaddr.in{ .family = std.c.AF.INET, .port = std.mem.nativeToBig(u16, bnd.port), .addr = undefined };
    @memcpy(std.mem.asBytes(&dst.addr)[0..4], &[4]u8{ 127, 0, 0, 1 });
    const dgram = [_]u8{ 0, 0, 0, 0x01, 8, 8, 8, 8, 0x00, 0x35, 'Q' };
    _ = try compat.posixSendTo(cfd, &dgram, 0, @ptrCast(&dst), @sizeOf(std.c.sockaddr.in));

    // The stand-in outbound write (no conn) fails synchronously on the first
    // datagram -> the relay returns. The deferred pair.peer.close() (above)
    // additionally guarantees a control EOF if any platform buffers differently.
    th.join();
    try testing.expect(done.load(.acquire));
    try testing.expect(opened); // lazy open fired on the first datagram

    // The opener's stand-in session was returned to the relay, which closed its
    // Stream (return-to-pool / discard since pool=null). Drive the recv-loop-exit
    // teardown to free the Session (the relay's ProxyStream.close already freed
    // the UotStream wrapper + dropped the stream refs).
    session_ptr.requestClose(.shutdown);
    session_ptr.releaseRef();
}

// ===========================================================================
// D8: REAL udpRelayLoop INBOUND reply branch (c) — full round-trip e2e
// ===========================================================================
//
// Unlike D7 e2e#1 (which drives readDatagram/buildClientDatagram/posixSendTo
// MANUALLY, outside the loop) and D7 e2e#2 (whose stand-in OUTBOUND write fails
// before branch (c) is reached), this test genuinely routes through the REAL
// udpRelayLoop's INBOUND branch (c): poll the UotStream notifier fd ->
// readDatagram -> buildClientDatagram -> posixSendTo back to the learned
// client_addr.
//
// What makes branch (c) reachable here that wasn't before: a stand-in
// anytls.Session has conn=null, so the relay's OUTBOUND writeDatagram normally
// fails with error.StreamClosed and the loop returns BEFORE ever polling the
// notifier. We install the test-only `test_outbound_sink` seam on the Session so
// that outbound write SUCCEEDS (bytes captured, no TLS) — the loop keeps running,
// adds the per-stream notifier fd to its poll set, and when we make an INBOUND
// UoT frame available via testAppendInbound (== what the real recv-loop demux
// delivers), the notifier fires and the REAL branch (c) runs end-to-end.
//
// PROOF branch (c) ran (not the steps manually): the assertion reads a SOCKS5-UDP
// datagram off the TEST's real client UDP socket. The ONLY code path that
// posixSendTo's to that socket from the learned client_addr is branch (c) inside
// udpRelayLoop — the test never calls buildClientDatagram / posixSendTo on ufd
// itself. The decoded payload + source addr must equal the inbound UoT frame.

/// Shared rendezvous between the relay-thread opener and the test thread. The
/// opener publishes the stand-in Stream/Session it created (so the test can feed
/// an inbound frame) and signals when the relay's OUTBOUND write reached the
/// stand-in sink (== the loop processed the client datagram and is now polling
/// the notifier, so branch (c) is armed).
const BranchCRendezvous = struct {
    stream: std.atomic.Value(?*anytls.Stream) = .init(null),
    session: std.atomic.Value(?*anytls.Session) = .init(null),
    outbound_seen: std.atomic.Value(bool) = .init(false),

    /// The test-only outbound sink: records that the relay's outbound writeDatagram
    /// fragmented at least one frame through the stand-in Session.
    fn sink(ctx: ?*anyopaque, payload: []const u8) void {
        _ = payload;
        const self: *BranchCRendezvous = @ptrCast(@alignCast(ctx.?));
        self.outbound_seen.store(true, .release);
    }
};

test "D8 e2e: REAL udpRelayLoop inbound branch (c) -> SOCKS5-UDP datagram on a real client socket" {
    const allocator = testing.allocator;
    const Config = @import("../config.zig").Config;
    const ProxyGroup = @import("../config.zig").ProxyGroup;
    const Rule = @import("../config.zig").Rule;

    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(@import("../config.zig").Proxy).empty,
        .proxy_groups = std.ArrayList(ProxyGroup).empty,
        .rules = std.ArrayList(Rule).empty,
    };
    defer cfg.deinit();
    var engine = try Engine.init(allocator, &cfg.rules);
    defer engine.deinit();

    var rv = BranchCRendezvous{};

    // Stand-in opener: returns a UDP ProxyStream over a REAL anytls.Stream
    // (conn=null) whose Session has the test outbound sink installed so the
    // relay's OUTBOUND writeDatagram succeeds. Publishes the Stream/Session to
    // the rendezvous so the test thread can feed the inbound UoT frame.
    const StandinOpener = struct {
        allocator: std.mem.Allocator,
        rv: *BranchCRendezvous,
        fn open(self: @This(), proxy_name: []const u8) anyerror!ProxyStream {
            _ = proxy_name;
            const s = try makeStandinStream(self.allocator);
            s.session.test_outbound_ctx = self.rv;
            s.session.test_outbound_sink = BranchCRendezvous.sink;
            self.rv.session.store(s.session, .release);
            self.rv.stream.store(s.stream, .release);
            const u = try self.allocator.create(ManagerLessAnyTlsUdp);
            u.* = ManagerLessAnyTlsUdp.init(self.allocator, s.stream);
            return ProxyStream.initAnyTlsUdp(self.allocator, u);
        }
    };

    const pair = try makeControlPair();
    defer pair.control.close();

    // Bind the relay's client-facing UDP socket (production binds this in
    // handleSocks5Associate and hands it to the loop; the loop is the unit under
    // test). Send the ASSOCIATE reply as production would so the SOCKS5 client
    // (this test) learns BND.PORT.
    const ufd = try compat.udpSocket4();
    defer compat.posixClose(ufd);
    try compat.setNonBlock(ufd);
    const bnd = try compat.udpGetSockName(ufd);
    try pair.control.writeAll(&buildAssociateReply(bnd.port));

    const conn = net.Server.Connection{ .stream = pair.control, .address = try net.Address.parseIp4("127.0.0.1", 1) };
    const opener = StandinOpener{ .allocator = allocator, .rv = &rv };

    const T = struct {
        fn run(o: StandinOpener, c: net.Server.Connection, e: *Engine, fd: std.posix.fd_t, done: *std.atomic.Value(bool)) void {
            udpRelayLoop(o, c, e, fd) catch {};
            done.store(true, .release);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const th = try std.Thread.spawn(.{}, T.run, .{ opener, conn, &engine, ufd, &done });

    // Single hang-proof + double-close-proof teardown for ALL exit paths (normal
    // and any early `try`-error return): close pair.peer ONCE to drive the
    // control-TCP EOF that returns udpRelayLoop, then JOIN the relay thread.
    var torn_down = false;
    const Teardown = struct {
        fn run(p: net.Stream, t: std.Thread, flag: *bool) void {
            if (flag.*) return;
            flag.* = true;
            p.close(); // EOF on the relay's control fd -> udpRelayLoop returns
            t.join(); // bounded: the loop returns promptly on EOF
        }
    };
    defer Teardown.run(pair.peer, th, &torn_down);

    // The TEST is the SOCKS5 UDP client. Read the ASSOCIATE reply to confirm
    // BND.PORT, then send a SOCKS5-UDP datagram (target 1.1.1.1:53 + payload) to
    // that bound port from a real loopback UDP socket so the loop learns
    // client_addr and lazily opens the upstream via the injected opener.
    var reply: [10]u8 = undefined;
    try testing.expectEqual(@as(usize, 10), try pair.peer.read(&reply));
    try testing.expectEqual(@as(u8, 0x05), reply[0]);
    try testing.expectEqual(@as(u8, 0x00), reply[1]);
    const reply_port = (@as(u16, reply[8]) << 8) | reply[9];
    try testing.expectEqual(bnd.port, reply_port);

    const cfd = try compat.udpSocket4();
    defer compat.posixClose(cfd);
    try compat.setNonBlock(cfd); // bounded poll on the inbound reply -> no hang
    var dst = std.c.sockaddr.in{ .family = std.c.AF.INET, .port = std.mem.nativeToBig(u16, reply_port), .addr = undefined };
    @memcpy(std.mem.asBytes(&dst.addr)[0..4], &[4]u8{ 127, 0, 0, 1 });
    // target 1.1.1.1:53 + "DNSQ"
    const out_dgram = [_]u8{ 0, 0, 0, 0x01, 1, 1, 1, 1, 0x00, 0x35, 'D', 'N', 'S', 'Q' };
    _ = try compat.posixSendTo(cfd, &out_dgram, 0, @ptrCast(&dst), @sizeOf(std.c.sockaddr.in));

    // Wait (bounded) until the relay's OUTBOUND writeDatagram reached the sink:
    // this guarantees the loop learned client_addr, opened the upstream, sent the
    // outbound frame, and is now polling the notifier — branch (c) is armed.
    {
        var tries: usize = 0;
        while (!rv.outbound_seen.load(.acquire)) : (tries += 1) {
            if (tries >= 5000) return error.OutboundTimeout; // ~5s deadline
            compat.sleepNs(1 * std.time.ns_per_ms);
        }
    }

    const stream = rv.stream.load(.acquire).?;
    const session = rv.session.load(.acquire).?;

    // Make an INBOUND UoT v2 frame available exactly as the recv-loop demux would
    // ([SOCKS-addr(1.2.3.4:9000)][len u16 BE][payload]). testAppendInbound signals
    // the stream notifier -> the REAL loop's poll wakes on fds[2] -> branch (c).
    const src = mkSocksAddrV4(.{ 1, 2, 3, 4 }, 9000);
    const frame = try frameBytes(allocator, src, "PONG");
    defer allocator.free(frame);
    stream.testAppendInbound(frame);

    // ASSERT branch (c) ran: the TEST's client socket receives the SOCKS5-UDP
    // datagram that ONLY branch (c)'s buildClientDatagram + posixSendTo could have
    // produced. Bounded poll on the nonblocking client socket.
    var got: [256]u8 = undefined;
    const rf = blk: {
        var tries: usize = 0;
        while (tries < 5000) : (tries += 1) {
            const r = compat.udpRecvFrom(cfd, &got) catch |e| switch (e) {
                error.WouldBlock => {
                    compat.sleepNs(1 * std.time.ns_per_ms);
                    continue;
                },
                else => return e,
            };
            break :blk r;
        }
        return error.InboundReplyTimeout;
    };
    const dg = try parseClientDatagram(got[0..rf.n]);
    try testing.expectEqualStrings("PONG", dg.payload);
    try testing.expectEqualSlices(u8, src.slice(), dg.addr.slice());

    // Tear down: close the control TCP -> the relay's control-fd poll wakes,
    // read()==0, udpRelayLoop returns. Join (guarded, idempotent) and confirm
    // no hang.
    Teardown.run(pair.peer, th, &torn_down);
    try testing.expect(done.load(.acquire));

    // Free the stand-in Session (the relay's ProxyStream.close already freed the
    // UotStream wrapper + dropped the stream refs); drive recv-loop-exit teardown.
    session.requestClose(.shutdown);
    session.releaseRef();
}
