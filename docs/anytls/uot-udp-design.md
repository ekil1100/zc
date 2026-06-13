# SOCKS5 UDP ASSOCIATE -> sing UoT v2 over AnyTLS — Implementation-Ready Design (Stage D)

Status: design. Grounded against the actual zc tree at Stage C
(`src/protocol/anytls.zig` Session/Stream/pool, `src/proxy/outbound/manager.zig`
ProxyStream + pool wiring, `src/proxy/mixed.zig` handleSocks5 + relay,
`src/compat.zig` Notifier/udpSocket4/posixSendTo, `src/config.zig` Proxy/parseProxy)
and the verified UoT v2 wire (sing `common/uot`), anytls UDP mapping, and RFC1928.

This builds the **greenfield** UDP datapath. The Stage-C AnyTLS Session / Stream /
SessionPool are reused **verbatim** (no new anytls frame types, no pool changes).
The TCP CONNECT relay is **byte-for-byte unchanged**: the only mixed.zig edit is one
new dispatch branch; the only manager.zig edit is one new sibling entry point.

---

## 0. Chosen approach (merge of the two proposals)

We take **Proposal 1's structure** (one ASSOCIATE == one client UDP socket == ONE
anytls Stream, IsConnect=0 unconnected, no per-flow session table) because it is the
minimal correct mapping for the common case, and **fold in Proposal 2's clean
module boundary**: a dedicated `src/proxy/udp_uot.zig` that owns the UoT v2 codec and
the SOCKS5 datagram codec as *pure, independently testable* pieces, plus the
`udpRelay` pump and `handleAssociate` ingress. The codec wraps `*anytls.Stream`
directly; `ProxyStream` gains a thin UDP arm only so the manager checkout path and the
pool ownership/teardown rules stay identical to the TCP path.

Decisions locked:
- **One UoT stream per association**, `IsConnect = 0` (unconnected / multi-destination).
  Every datagram is self-describing on both legs, so demux is the UoT frame's own
  SOCKS address — **no per-5-tuple session table** is needed. This matches RFC1928
  ASSOCIATE semantics (one association may target many destinations).
- **Single proxy per association**, chosen once at ASSOCIATE time via a default rule
  match. Per-datagram re-routing is out of scope (documented limitation; the TCP path's
  per-target matchCtx does not apply to UDP).
- **Magic dest** = domain `sp.v2.udp-over-tcp.arpa`, port `443` (the anytls server keys
  on the domain; the port is a placeholder — see open decisions).
- **Lifetime** = the control TCP connection that issued ASSOCIATE owns the whole UDP
  session (RFC1928). `udpRelay` polls the control fd for EOF and tears everything down
  the instant it closes.
- **Client-facing socket is IPv4-only** (mirrors the existing mixed.zig/socks5.zig
  IPv4-only limitation). UDP *targets* may be IPv4/domain/IPv6 over the UoT leg.
- **FRAG != 0 datagrams are dropped** (no reassembly).
- No new threads: `udpRelay` runs on the existing per-connection worker thread
  (`spawnConnectionTask`). The only extra threads are the pool's own per-Session
  recv-loops, which already exist.

---

## 1. Module layout

| File | Change |
|------|--------|
| `src/proxy/udp_uot.zig` (NEW) | `UotStream` (UoT v2 codec over `*anytls.Stream`), `SocksAddr` (raw RFC1928 addr holder), pure SOCKS5-UDP datagram parse/build helpers, `handleAssociate` ingress, `udpRelay` pump. Imports `compat`, `anytls`, `outbound/manager.zig`, `rule/engine.zig`. Does NOT import mixed.zig. |
| `src/proxy/mixed.zig` | ONE dispatch branch in `handleSocks5` at the `buf[1]` check (line 134): `0x01` -> existing CONNECT path (verbatim), `0x03` -> `udp_uot.handleAssociate(...)`, else REP=0x07. Stop discarding `allocator` (line 108). Nothing else touched; `relay()`/`relaySocks5()`/`drainTargetPending` untouched and NOT reused. |
| `src/proxy/outbound/manager.zig` | Add `connectUdp(proxy_name) !ProxyStream` (sibling of `connect`) + `connectAnyTlsUdp(proxy) !ProxyStream`. Add the `owned_anytls_udp` arm to `ProxyStream` (ctor/move/close/getHandle + `udpStream()` accessor). The existing 4 arms and all TCP methods are untouched. |
| `src/compat.zig` | Add `udpGetSockName(fd) !BoundAddr` and `udpRecvFrom(fd, buf) !RecvFrom` (raw `std.c.getsockname`/`std.c.recvfrom`). Reuse existing `udpSocket4()`, `posixSendTo`, `posixClose`. |
| `src/config.zig` | Add `udp: bool = false` to `Proxy` (scalar; deinit unchanged). Parse `udp:` key in `parseProxy`. |
| `src/config_validator.zig` | Soft warning: `udp:true` only honored for `proxy_type == .anytls`. |
| `src/protocol/anytls.zig` | Make `encodeSocksAddr` `pub` (currently file-private at :1558) so the UoT codec reuses the single canonical SOCKS-addr encoder. Alternative: duplicate it privately in udp_uot.zig (see open decisions). |
| `http.zig`, `socks5.zig`, `anytls_pool.zig`, the TCP `relay()` | UNCHANGED. |

FD cost per active UDP association: 1 client UDP socket + the borrowed anytls Stream's
fds (darwin 3 / linux 2, per Stage-C §1) + the control TCP fd (already counted by the
worker). Idle pooled sessions are unaffected.

---

## 2. Wire formats (byte layouts)

### 2.1 SOCKS5 control handshake (client <-> control TCP) — RFC1928

Greeting + method select are SHARED with the existing CONNECT path (mixed.zig
110-129), unchanged.

ASSOCIATE request (read into `buf` at mixed.zig:131):
```
+-----+-----+-----+------+----------+----------+
| VER | CMD | RSV | ATYP | DST.ADDR | DST.PORT |
| 05  | 03  | 00  |  .   | Variable |    2     |
+-----+-----+-----+------+----------+----------+
```
DST.ADDR/PORT is the address the client will send datagrams FROM; it is advisory and
**ignored** (commonly `0.0.0.0:0`). We only validate it parses.

ASSOCIATE reply (10 bytes, ATYP=0x01):
```
+-----+-----+-----+------+----------+----------+
| VER | REP | RSV | ATYP | BND.ADDR | BND.PORT |
| 05  | 00  | 00  | 01   | 4 bytes  | 2 (BE)   |
+-----+-----+-----+------+----------+----------+
BND.ADDR = 127.0.0.1, BND.PORT = bound UDP port (from getsockname), big-endian.
```
This tells the client where to send relayed datagrams. (The existing CONNECT reply
template `{05,00,00,01, 0,0,0,0, 0,0}` at mixed.zig:172 is NOT reused — we fill bytes
[4..8] and [8..10].)

### 2.2 SOCKS5 UDP datagram (client <-> bound UDP socket) — RFC1928

```
+-----+------+------+----------+----------+----------+
| RSV | FRAG | ATYP | DST.ADDR | DST.PORT |   DATA   |
|  2  |  1   |  1   | Variable |  2 (BE)  | Variable |
+-----+------+------+----------+----------+----------+
RSV  = 0x0000 (ignored on parse, written 0x0000 on build)
FRAG = 0x00 standalone; FRAG != 0 -> DROP the datagram (no reassembly)
ATYP = 0x01 IPv4(4) | 0x03 domain(1-len + bytes) | 0x04 IPv6(16)
```
header_len: ATYP 0x01 -> 4+2+4 = 10 ; 0x03 -> 4 + 1 + len + 2 = 7+len ; 0x04 -> 4+2+16 = 22.
DATA = the raw UDP payload (passed verbatim into the UoT leg).

### 2.3 UoT v2 stream request header (zc -> server, ONCE at stream start)

```
[IsConnect: 1 byte = 0x00]  [SOCKS-ADDR of Request.Destination]
```
`IsConnect = 0` (unconnected). For unconnected mode sing still serializes a
Destination; we write the SOCKS addr of the **first datagram's real target** (sing
reads it but ignores it in unconnected mode). SOCKS-ADDR = RFC1928 ATYP+ADDR+PORT(BE),
identical encoding to 2.2's address portion (produced by `anytls.encodeSocksAddr`).

This header is the FIRST stream payload after the anytls SYN/PSH that opened the stream
to the magic domain. (Open decision O3 flags confirming this against sing
`uot/client.go`; design assumes header-as-first-payload per the dossier.)

### 2.4 UoT v2 per-datagram frame (both directions, unconnected)

```
[SOCKS-ADDR][len: u16 BE][payload[len]]
```
- Outbound (zc -> server): SOCKS-ADDR = the datagram's DST from 2.2.
- Inbound (server -> zc): SOCKS-ADDR = the source the reply came from; we copy it raw
  into the downstream 2.2 header.

All of this is ordinary anytls cmdPSH stream payload — the anytls layer is unchanged.

---

## 3. compat.zig additions

```zig
pub const BoundAddr = struct { ip: [4]u8, port: u16 };
pub const RecvFrom = struct { n: usize, addr: std.c.sockaddr.in };

/// getsockname on a bound IPv4 UDP socket; returns host-order port + IPv4 octets.
pub fn udpGetSockName(fd: std.posix.fd_t) !BoundAddr {
    var sa: std.c.sockaddr.in = undefined;
    var sl: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&sa), &sl) < 0) return error.GetSockNameFailed;
    const p = std.mem.bigToNative(u16, sa.port);  // sa.port is network-order
    const a: [4]u8 = @bitCast(sa.addr);            // network-order octets, already in [0..4] order
    return .{ .ip = a, .port = p };
}

/// recvfrom learning the peer (client) address. EAGAIN -> error.WouldBlock so the
/// poll-driven relay treats it as a spurious wake (mirrors posixReadError).
pub fn udpRecvFrom(fd: std.posix.fd_t, buffer: []u8) !RecvFrom {
    var sa: std.c.sockaddr.in = undefined;
    var sl: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    const rc = std.c.recvfrom(fd, buffer.ptr, buffer.len, 0, @ptrCast(&sa), &sl);
    if (rc < 0) return switch (std.c.errno(rc)) {
        .AGAIN => error.WouldBlock,
        .INTR => error.WouldBlock, // treat as spurious; relay re-polls
        else => error.InputOutput,
    };
    return .{ .n = @intCast(rc), .addr = sa };
}
```
Reply path uses the EXISTING `compat.posixSendTo(fd, buf, 0, @ptrCast(&client_addr),
@sizeOf(std.c.sockaddr.in))`. The bound socket from `compat.udpSocket4()` is closed with
`compat.posixClose`.

Note: `udpSocket4()` binds `0.0.0.0:0`; the relay replies BND.ADDR = `127.0.0.1` (the
client is local). The bound socket itself stays on 0.0.0.0 so a loopback client reaches it.

---

## 4. src/proxy/udp_uot.zig

### 4.1 Constants + SocksAddr

```zig
pub const MAGIC_DOMAIN = "sp.v2.udp-over-tcp.arpa";
pub const MAGIC_PORT: u16 = 443;

/// Raw RFC1928 address (ATYP..PORT) held verbatim so it can be memcpy'd between the
/// UoT frame and the downstream SOCKS5 UDP header with no decode/re-encode.
pub const SocksAddr = struct {
    bytes: [262]u8 = undefined, // max: 1 atyp + 1 len + 255 domain + 2 port + slack
    len: usize = 0,
};
```

### 4.2 Pure SOCKS5-UDP datagram codec

```zig
pub const ClientDatagram = struct {
    frag: u8,
    addr: SocksAddr,        // raw ATYP+ADDR+PORT slice from the packet
    payload: []const u8,    // slice INTO the recv buffer
};

/// Parse a client->relay UDP datagram (2.2). FRAG!=0 -> error.FragNotSupported.
pub fn parseClientDatagram(pkt: []const u8) !ClientDatagram;
//  pkt[0..2] RSV ignored; pkt[2]=FRAG; pkt[3]=ATYP; addr = socksAddrLen(...) bytes
//  starting at pkt[3]; payload = pkt[3+addr_body..]. Bounds-checked; truncated -> error.Invalid.

/// Build a relay->client UDP datagram (2.2): {0,0,0} ++ addr.bytes ++ payload.
/// Returns total length written into out.
pub fn buildClientDatagram(out: []u8, addr: SocksAddr, payload: []const u8) usize;

/// Length of a raw SOCKS addr (ATYP+ADDR+PORT) starting at buf[0]; used by both the
/// SOCKS5-UDP parser and the UoT-frame parser so they agree. v4->7, domain->4+len, v6->19.
fn socksAddrLen(buf: []const u8) !usize;
```

### 4.3 UotStream — UoT v2 codec over `*anytls.Stream`

```zig
pub const UotStream = struct {
    stream: *anytls.Stream,            // borrowed from the pool (pool owns the Session)
    allocator: std.mem.Allocator,
    header_sent: bool = false,
    rx: std.ArrayListUnmanaged(u8) = .empty, // inbound reassembly across stream reads
    rx_off: usize = 0,

    pub fn deinit(self: *UotStream) void { self.rx.deinit(self.allocator); }

    /// Outbound datagram. On first call also writes the v2 Request header (2.3) with
    /// IsConnect=0 and this datagram's dst as Request.Destination. `dst` is the raw
    /// SOCKS addr (ATYP+ADDR+PORT) extracted from the client datagram.
    pub fn writeDatagram(self: *UotStream, dst: SocksAddr, payload: []const u8) !void {
        // build one buffer to minimize stream.write calls:
        //   if !header_sent: [0x00][dst.bytes]   (Request header)
        //   then per datagram: [dst.bytes][len:u16 BE][payload]
        // self.stream.write(buf)  -> anytls fragments into cmdPSH frames.
        // header_sent = true.
    }

    /// Inbound datagram. Pulls bytes from the anytls Stream into rx, then parses ONE
    /// complete UoT frame (2.4). Returns:
    ///   null      -> no full frame buffered yet (relay re-polls)
    ///   0/error   -> 0 means EOF (stream closed); errors propagate
    ///   n>0       -> payload length copied to out_payload; out_addr filled (raw SOCKS addr)
    pub fn readDatagram(self: *UotStream, out_addr: *SocksAddr, out_payload: []u8) !?usize {
        // 1. Try to parse a frame already in rx[rx_off..]:
        //    addr_len = socksAddrLen(rx[rx_off..]) (need >= 1 byte for ATYP; if short -> step 2)
        //    need = addr_len + 2 + len  (len read as u16 BE after the addr)
        //    if buffered >= need: copy addr -> out_addr, copy payload -> out_payload,
        //                         rx_off += need; compact when rx_off large; return payload len.
        // 2. Not enough: read more from the stream:
        //    n = self.stream.read(scratch) catch |e| switch (e) {
        //        error.WouldBlock => return null,   // spurious wake; re-poll
        //        else => return e,
        //    };
        //    if n == 0: if rx has leftover bytes -> they are an incomplete frame at EOF;
        //               return 0 (treat as EOF). else return 0.
        //    rx.appendSlice(scratch[0..n]); goto 1 (loop).
    }
};
```

`stream.read` semantics (Stage-C anytls.Stream.read, verified): returns `WouldBlock` on
a spurious notifier wake, `0` on EOF, bytes otherwise. `readDatagram` maps `WouldBlock`
-> `null` exactly like the TCP `relay()` maps it -> `continue` (mixed.zig:926).

SOCKS-addr encoding for the outbound path reuses `anytls.encodeSocksAddr` (made `pub`):
the client datagram's raw addr bytes are already in RFC1928 form, so `writeDatagram`
copies `dst.bytes[0..dst.len]` directly — no re-encode needed. The encoder is only
needed if a host string must be encoded; here the bytes are already wire-form, so the
`pub` change is optional and the duplication risk is avoided (see open decisions O7).

---

## 5. Outbound: UoT-over-AnyTLS path (manager.zig)

### 5.1 ProxyStream UDP arm (mirrors `owned_anytls_stream`)

```zig
// new field on ProxyStream:
owned_anytls_udp: ?*udp_uot.UotStream = null,

pub fn initAnyTlsUdp(allocator: std.mem.Allocator, ust: *udp_uot.UotStream) ProxyStream {
    return .{ .base_stream = .{ .handle = -1 }, .allocator = allocator, .owned_anytls_udp = ust };
}

// move(): add `self.owned_anytls_udp = null;` to the reset list.

// close(): add the FIRST arm (before others), exactly mirroring owned_anytls_stream:
//   if (self.owned_anytls_udp) |u| {
//       self.owned_anytls_udp = null;
//       u.stream.close();          // FIN + return Session to idle/discard + drop borrow ref (Stage-C §8/§13)
//       u.deinit();                // frees rx
//       self.allocator.?.destroy(u);
//       return;
//   }

// getHandle(): add `if (self.owned_anytls_udp) |u| return u.stream.getHandle();`

// NEW accessor for the relay (the byte-stream write/read/readBlocking/hasPendingRead
// are NOT wired to the UDP arm and must never be called on it):
pub fn udpStream(self: *ProxyStream) *udp_uot.UotStream { return self.owned_anytls_udp.?; }
```

CRITICAL invariant: a UDP `ProxyStream` is produced ONLY by `connectUdp` (new entry
point) and never flows through `relay()`. The existing `connect()`/`connectToProxy()`
(the sole feeders of `relay()`) never set `owned_anytls_udp`. Therefore the TCP CONNECT
path's `write`/`read`/`readBlocking` are compile-time guaranteed untouched.

### 5.2 connectUdp / connectAnyTlsUdp

```zig
pub fn connectUdp(self: *OutboundManager, proxy_name: []const u8) !ProxyStream {
    // resolution prologue mirrors connect() WITHOUT a concrete target:
    if (std.mem.eql(u8, proxy_name, "DIRECT")) return error.UdpNotSupportedForDirect;
    if (std.mem.eql(u8, proxy_name, "REJECT")) return error.ConnectionRejected;
    // resolveProxyGroup loop (same as connect lines 413-424) -> current_name
    const proxy = self.findProxy(current_name) orelse return error.ProxyNotFound;
    return try self.connectAnyTlsUdp(proxy);
}

fn connectAnyTlsUdp(self: *OutboundManager, proxy: *const Proxy) !ProxyStream {
    if (proxy.proxy_type != .anytls) return error.UdpNotSupportedByProxy;
    if (!proxy.udp) return error.UdpNotSupportedByProxy;
    // EXACT Stage-C checkout path (manager.zig:460-464) but to the magic dest:
    const key = try self.poolKey(proxy);
    defer self.allocator.free(key);
    const pool = try self.getOrCreatePool(key, proxy);
    const stream = try pool.createStream(udp_uot.MAGIC_DOMAIN, udp_uot.MAGIC_PORT);
    errdefer stream.close();
    const ust = try self.allocator.create(udp_uot.UotStream);
    ust.* = .{ .stream = stream, .allocator = self.allocator };
    return ProxyStream.initAnyTlsUdp(self.allocator, ust);
}
```
`pool.createStream` is UNCHANGED: it sends cmdSettings (first stream) + cmdSYN(sid) +
cmdPSH(`encodeSocksAddr(MAGIC_DOMAIN, 443)`) via the existing `openStream`; the server
recognizes the magic domain and switches that stream to UoT v2. `encodeSocksAddr`
already emits the domain as ATYP=0x03 (anytls.zig:1572-1575). The SYN-DONE bounded wait
(Stage-C §11) applies automatically on the reuse path. A UDP association and a TCP
CONNECT on the same proxy share the same SessionPool (same poolKey) transparently.

---

## 6. Ingress: handleAssociate (udp_uot.zig)

### 6.1 mixed.zig dispatch (the ONLY mixed.zig change)

At `handleSocks5` line 134, replace
```zig
if (buf[1] != 0x01) return error.CommandNotSupported;
```
with
```zig
switch (buf[1]) {
    0x01 => {},                                  // fall through to existing CONNECT body (lines 136-173, verbatim)
    0x03 => return udp_uot.handleAssociate(allocator, conn, engine, manager, buf[0..req_n]),
    else => {
        try conn.stream.writeAll(&.{ 0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }); // REP=0x07
        return;
    },
}
```
and change `_ = allocator;` (line 108) to thread `allocator` into the ASSOCIATE call.
The greeting/method-select (110-129) and request read (131-133) run BEFORE the switch and
are shared. The CONNECT body is unmodified.

### 6.2 handleAssociate

```zig
pub fn handleAssociate(
    allocator: std.mem.Allocator,
    conn: net.Server.Connection,
    engine: *Engine,
    manager: *OutboundManager,
    req: []const u8,          // the ASSOCIATE request bytes (buf[0..req_n])
) !void {
    // 1. Parse-and-ignore the request DST (validate it parses; reuse the atyp switch
    //    shape from mixed.zig:139-155; v4/domain/v6 all accepted; value unused).
    //    Malformed -> reply REP=0x01 and return.

    // 2. Bind the client-facing UDP socket.
    const ufd = try compat.udpSocket4();          // binds 0.0.0.0:0
    defer compat.posixClose(ufd);
    const bnd = try compat.udpGetSockName(ufd);    // {ip, port}

    // 3. Choose the proxy ONCE (no concrete target at ASSOCIATE time).
    const proxy_name = engine.matchCtx(.{ .target_host = "0.0.0.0", .target_port = 0, .is_domain = false })
        orelse "DIRECT";

    // 4. Open the UoT upstream BEFORE replying success.
    var ustream = manager.connectUdp(proxy_name) catch |err| {
        const rep: u8 = switch (err) {
            error.UdpNotSupportedByProxy, error.UdpNotSupportedForDirect, error.ProxyNotFound => 0x07,
            else => 0x05, // dial/general failure
        };
        try conn.stream.writeAll(&.{ 0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
        return; // defer posixClose(ufd) runs; no relay half-opened
    };
    defer ustream.close();

    // 5. Reply success with the BOUND udp endpoint (127.0.0.1 : bnd.port).
    const reply = [_]u8{
        0x05, 0x00, 0x00, 0x01,
        127, 0, 0, 1,
        @intCast(bnd.port >> 8), @intCast(bnd.port & 0xff),
    };
    try conn.stream.writeAll(&reply);

    // 6. Run the pump for the whole association lifetime (RFC1928).
    try udpRelay(conn.stream, ufd, &ustream);
    // on return: defer ustream.close() (-> pool return + free UotStream),
    //            defer posixClose(ufd), then handleConnection's defer conn.stream.close().
}
```
The worker thread does NOT return after the reply — it stays in `udpRelay` until the
control TCP closes.

---

## 7. Relay loop + timeouts (udp_uot.zig)

Single-threaded `std.posix.poll` over THREE fds, the 3-fd analogue of `relay()`.

```zig
fn udpRelay(control: net.Stream, ufd: std.posix.fd_t, ustream: *ProxyStream) !void {
    var in_buf: [65535]u8 = undefined;            // client datagram in / payload scratch
    var out_buf: [65535 + 262]u8 = undefined;     // downstream SOCKS5 UDP datagram out
    var src_addr: SocksAddr = .{};
    var client_addr: ?std.c.sockaddr.in = null;   // learned on first recvfrom
    var last_activity_ms = compat.milliTimestamp();
    const uot = ustream.udpStream();

    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = control.handle,        .events = std.posix.POLL.IN, .revents = 0 }, // EOF only
            .{ .fd = ufd,                   .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = ustream.getHandle(),   .events = std.posix.POLL.IN, .revents = 0 }, // notifier fd
        };
        _ = try std.posix.poll(&fds, relay_poll_timeout_ms /* 30s heartbeat */);

        // (a) control TCP readable / HUP / ERR -> association end.
        if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            var one: [1]u8 = undefined;
            const n = control.read(&one) catch 0;  // any byte or EOF/err -> terminate
            _ = n; // clients send no data on the control conn post-ASSOCIATE
            return; // RFC1928 teardown
        }

        // (b) client UDP readable -> ingest one datagram, write to UoT leg.
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            const rf = compat.udpRecvFrom(ufd, &in_buf) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return e,
            };
            client_addr = rf.addr;
            const dg = parseClientDatagram(in_buf[0..rf.n]) catch {
                // FragNotSupported or Invalid -> drop, keep going.
                last_activity_ms = compat.milliTimestamp();
                continue;
            };
            try uot.writeDatagram(dg.addr, dg.payload); // write error -> propagate -> teardown
            last_activity_ms = compat.milliTimestamp();
        }

        // (c) UoT stream readable -> drain ALL complete frames, send each to client.
        if (fds[2].revents & std.posix.POLL.IN != 0) {
            while (true) {
                const maybe = uot.readDatagram(&src_addr, &in_buf) catch |e| {
                    if (e == error.WouldBlock) break; // spurious; re-poll
                    return e;                          // stream error -> teardown
                };
                const n = maybe orelse break;          // no full frame yet -> re-poll
                if (n == 0) return;                    // UoT stream EOF -> teardown
                if (client_addr) |ca| {
                    const out_len = buildClientDatagram(&out_buf, src_addr, in_buf[0..n]);
                    _ = compat.posixSendTo(ufd, out_buf[0..out_len], 0,
                        @ptrCast(&ca), @sizeOf(std.c.sockaddr.in)) catch {};
                } // else: no client addr learned yet -> drop (UDP-acceptable)
                last_activity_ms = compat.milliTimestamp();
            }
        }

        // (d) idle reap (NAT-style; bounded so a stuck association is reclaimed).
        const now = compat.milliTimestamp();
        if (now - last_activity_ms > relay_idle_reap_ms /* 15min */) return;
    }
}
```

Notes:
- `relay_poll_timeout_ms` (30s) and `relay_idle_reap_ms` (15min) reuse the existing
  mixed.zig constants (lines 22-23). Define local copies or import them.
- **No per-destination NAT table**: one UoT stream carries all destinations
  (IsConnect=0), and each inbound frame carries its own source addr, so the only state
  is `client_addr` + the whole-association idle timer.
- `readDatagram` returning `null` (partial frame) is the re-poll signal — the notifier
  stays high while `hasPendingRead`/buffered bytes remain; the next poll wakes again.
  (`in_buf` is reused for both the inbound client datagram and the inbound payload
  scratch — they never overlap in time within one loop iteration.)

---

## 8. Lifecycle / teardown (no leak)

Ownership chain (top to bottom):
```
control TCP (handleConnection defer conn.stream.close())
  -> ufd            (handleAssociate defer compat.posixClose(ufd))
  -> ustream        (handleAssociate defer ustream.close())  [ProxyStream]
       -> UotStream  (freed inside ProxyStream.close: u.deinit() frees rx; destroy(u))
            -> borrowed anytls.Stream (Stream.close -> FIN + Session to pool idle/discard + drop borrow ref)
                 -> Session/recv-loop/TLS (owned by SessionPool; reclaimed by reaper / deinit drain, Stage-C §13)
```

Free order on ANY return from `handleAssociate` (normal / error / control EOF):
1. `udpRelay` returns.
2. `defer ustream.close()` -> `ProxyStream.close` UDP arm: `u.stream.close()` (Stage-C
   teardown), `u.deinit()` (frees `rx`), `allocator.destroy(u)`.
3. `defer compat.posixClose(ufd)`.
4. `handleConnection`'s `defer conn.stream.close()`.

No-leak guarantees:
- Error before reply: if `connectUdp` failed, no ProxyStream/UotStream allocated; `ufd`
  still closed by its defer. If `connectUdp` succeeded but a later step fails,
  `defer ustream.close()` frees it.
- `UotStream.rx` ArrayList freed in `UotStream.deinit`, called from `ProxyStream.close`
  before `destroy`.
- No detached threads spawned by the UDP path: `udpRelay` runs on the existing worker;
  when it returns the worker unwinds all defers and exits. Only pool-owned Sessions
  outlive it, joined by the pool's §13 drain.
- All buffers (`in_buf`, `out_buf`, `src_addr`, `client_addr`) are stack-local; no heap
  beyond the single `UotStream`.
- `Stream.close` on the borrowed anytls Stream is the already-tested Stage-C C7 path
  (recv-loop demux vs Stream.close race is UAF-safe via the dual ref count).

The control TCP closing is the single source of truth for association end (RFC1928).

---

## 9. Config + validator

`config.zig` Proxy gains `udp: bool = false` (scalar; `Proxy.deinit` unchanged).

`parseProxy` (alongside the other boolean keys near line 421):
```zig
if (map.get("udp")) |v| { if (v == .boolean) proxy.udp = v.boolean; }
```

`config_validator.zig`: non-fatal warning when `proxy.udp == true and proxy.proxy_type
!= .anytls` ("udp is only supported for anytls proxies; ignored"), mirroring the
existing `addWarning` style. No clamp.

Gating: `connectAnyTlsUdp` returns `error.UdpNotSupportedByProxy` unless
`proxy_type == .anytls and proxy.udp`. A proxy without `udp:true` cleanly rejects
ASSOCIATE with REP=0x07 (no half-opened relay) per §6.2 step 4.

---

## 10. Hooks summary — TCP path provably untouched

- `mixed.zig`: ONE dispatch branch + un-discard `allocator`. CONNECT body, `relay()`,
  `relaySocks5()`, `drainTargetPending`, `shutdownTargetWrite`, HTTP path: all verbatim.
- `manager.zig`: NEW `connectUdp`/`connectAnyTlsUdp` + ProxyStream `owned_anytls_udp`
  arm (new ctor/move-reset/close-arm/getHandle-arm/`udpStream` accessor). The 4 existing
  arms and `write`/`read`/`readBlocking`/`hasPendingRead` are unchanged. `connect()`/
  `connectToProxy()` (the only relay feeders) never set the UDP arm.
- `anytls_pool.zig` / `anytls.zig` Session/Stream: unchanged except `encodeSocksAddr`
  optionally made `pub`. No new anytls frame types.

---

## 11. Ordered sub-stages (each independently `zig build test`-verifiable)

Build/test (sandbox-safe; judge by exit code; ignore the cosmetic "failed command:"
line): `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-anytls-d zig build test`

- **D1 — compat UDP helpers**: add `udpGetSockName`, `udpRecvFrom`, `BoundAddr`,
  `RecvFrom`. Unit tests: bind via `udpSocket4`, `udpGetSockName` returns a nonzero
  port; loopback pair -> `udpRecvFrom` returns the sender addr + payload; EAGAIN on a
  nonblocking socket -> `error.WouldBlock`. No other file touched.
- **D2 — SOCKS5-UDP datagram codec (pure)**: `udp_uot.zig` skeleton with `SocksAddr`,
  `parseClientDatagram`, `buildClientDatagram`, `socksAddrLen`. Tests: v4/domain/v6
  parse with correct header_len (10 / 7+len / 22); RSV ignored; FRAG!=0 ->
  `error.FragNotSupported`; truncated -> `error.Invalid`; port BE; parse∘build round-trip.
- **D3 — UotStream codec (pure, over a fake Stream seam)**: `UotStream` writeDatagram /
  readDatagram. Use the Stage-C anytls test seams (`testAppendInbound`/`testMarkEof`/
  `testSpawnRecvLoop` referenced by anytls_pool C7) or a mock capturing `stream.write`
  bytes. Tests: first `writeDatagram` emits `[0x00][addr]` request header then
  `[addr][len BE][payload]`; subsequent calls omit the header; `readDatagram` with a
  frame split across two reads returns null then the full payload+addr; two frames in
  one read drain in two calls then null; `WouldBlock` -> null; EOF -> 0.
- **D4 — config udp flag**: `Proxy.udp` + parse + validator warning. Tests: `udp:true`
  parses to `true`; absent -> `false`; validator warns for non-anytls + udp:true.
- **D5 — manager UDP path**: ProxyStream `owned_anytls_udp` arm +
  `connectUdp`/`connectAnyTlsUdp`. Tests: `connectUdp("DIRECT")` ->
  `error.UdpNotSupportedForDirect`; anytls-without-udp -> `error.UdpNotSupportedByProxy`;
  ProxyStream.close on the UDP arm frees the UotStream and returns the Session to pool
  idle (reuse the C3b "close returns session to idle" assertion shape), under
  `std.testing.allocator` (no leak/UAF).
- **D6 — ingress + relay**: `handleAssociate` + `udpRelay` + the mixed.zig dispatch
  branch. Tests: reply builder emits `{05,00,00,01,127,0,0,1, portHi,portLo}` with port
  == `udpGetSockName(ufd).port`; `udpRelay` returns when the control TCP EOFs
  (simulate via a socketpair); negative: proxy without udp:true -> ASSOCIATE reply
  REP=0x07. Full on-wire e2e against a live anytls server is DEFERRED (documented, same
  as the Stage-C TLS-handshake deferral).
- **D7 — final**: full `zig build test`; confirm the TCP CONNECT path, `http.zig`,
  `socks5.zig`, and direct/ss/trojan/vless/anytls-TCP suites are green and unchanged;
  run the D5/D6 leak-checked tests together.

---

## 12. Residual risks

1. Magic-dest port 443 unverified against a live server (server is documented to key on
   the domain). Wrong only if a server validates the port. Mitigation: config knob later.
2. `IsConnect=0` (unconnected) + placeholder Request.Destination unverified end-to-end;
   safest RFC1928-correct choice. Mitigation: Destination = first datagram's real target.
3. Whether the v2 Request header must be the first stream payload (vs folded into the
   magic Socksaddr port) is an open question (sing `uot/client.go`); if wrong the first
   frame desyncs. Confirm before shipping.
4. New compat helpers' sockaddr/socklen handling on this darwin std.c toolchain is
   unverified by build (DESIGN task).
5. Client-facing socket IPv4-only (mirrors existing limitation); a dual-stack client
   sending from an IPv6 src is unsupported. UDP *targets* over UoT may be IPv6.
6. FRAG!=0 dropped (no reassembly) — rare for typical clients.
7. Single proxy per association (chosen at ASSOCIATE via 0.0.0.0:0 match); per-target UDP
   routing rules are NOT honored, diverging from the TCP path.
8. No live build run (DESIGN task): `Proxy.udp`, `connectUdp`, `UotStream`, the
   ProxyStream UDP arm, and the compat helpers are unverified against zig compilation.

---

## POST-REVIEW DECISIONS & MUST-FIX (authoritative — overrides anything above that conflicts)

These were settled after the adversarial design review (verdict: needs-revision) and a
user decision. They are binding for implementation.

### Locked defaults (proceed; revisit only if a target server differs)
- **Magic UoT dest** = `sp.v2.udp-over-tcp.arpa` (sing-box v2 magic FQDN), **port 443**.
  The server keys on the domain; port is best-effort. Make it a single named constant.
- **UoT mode** = **IsConnect=0 (unconnected / multi-destination)**, per-datagram SOCKS
  addresses on both legs. RFC1928-correct for ASSOCIATE.
- **Client-facing UDP socket** = IPv4-only (mirrors the existing inbound IPv4 limitation).
  UDP *targets* carried over UoT may still be IPv6.
- **encodeSocksAddr** = make `pub` and reuse the single canonical anytls encoder.
- **FRAG != 0** datagrams are dropped (no reassembly).

### ROUTING (user decision): FIRST-DATAGRAM-TARGET rule matching
Do NOT pick the proxy at ASSOCIATE time with a synthetic `0.0.0.0:0` match (that bypasses
domain/keyword/dst-port rules and silently routes all UDP to the default proxy). Instead:
1. `handleSocks5Associate` binds the client UDP socket, sends the ASSOCIATE reply, and
   enters the relay loop WITHOUT yet choosing a proxy or opening a UoT stream.
2. On the FIRST inbound client datagram, parse its real SOCKS target, run the rule engine
   on that (host/port/is_domain) exactly like the TCP path, resolve the proxy, then
   `connectUdp(proxy)` to open the single UoT stream for the whole association.
3. All subsequent datagrams reuse that one stream/proxy (single-active per association).
4. If the first datagram's target resolves to DIRECT/REJECT, handle consistently with the
   TCP path (DIRECT => a direct UDP path is out of scope for now => REP 0x07 / drop with a
   clear log; REJECT => tear down). Document whichever is chosen.

### MUST-FIX (bake into the relevant sub-stage; do not ship without)
1. **Control-TCP teardown only on EOF**: in `udpRelay`, terminate the association only when
   the control TCP `read` returns 0 (EOF) or errors. A non-zero read is stray/keepalive
   noise — DISCARD it and continue the loop. (RFC1928: association ends when the TCP closes.)
2. **Confirm the UoT v2 Request header placement BEFORE D6**: read sing `common/uot/client.go`
   (NewClientConn / WriteRequest) and confirm `[IsConnect:1][Destination SOCKS-addr]` is the
   FIRST stream payload after SYN/PSH (not folded into the magic Socksaddr port). The whole
   datapath desyncs if wrong.
3. **Per-datagram recv errors are drop-and-continue, not teardown**: `udpRecvFrom` must map
   EMSGSIZE / ECONNREFUSED (ICMP port-unreachable) and other non-fatal errnos to a
   "drop this packet" signal, never `error.InputOutput` that kills the association.
4. **Bound-harden the inbound (server-controlled) UoT parse**: `socksAddrLen` + the `u16`
   length read in `readDatagram` must treat any under-length `rx` as "need more bytes"
   (return null / WouldBlock-style), never parse on insufficient data. Reject ATYP=0x03 with
   domain_len==0 and unknown ATYP as a stream error. Server bytes are untrusted.
5. **Guard the ProxyStream UDP arm**: when `owned_anytls_udp` is set, the byte-stream methods
   (`write`/`read`/`readBlocking`/`hasPendingRead`/`shutdownWrite`) must `@panic`/debug-assert
   rather than silently fall through to `base_stream{handle=-1}`. Only `close`/`getHandle`/
   `udpStream`/`move` are valid on the UDP arm.
6. **sockaddr family correctness**: assert `getsockname`/`recvfrom` returned `AF.INET`; when
   reusing the recvfrom'd client addr for `posixSendTo`, set `family=AF.INET` (and `len` on
   darwin) explicitly so the reply can't go to a mis-decoded address.
7. **connectUdp DIRECT/REJECT semantics** match the TCP path AFTER group resolution: a group
   resolving to REJECT yields `error.ConnectionRejected`, not `ProxyNotFound`.
8. **Separate buffers** for the inbound-client-datagram scratch vs the UoT-inbound payload
   scratch (don't alias `in_buf` across the two legs); document the `src_addr` reuse.

### Notes captured for tests
- Notifier drain-vs-partial-UoT-frame: `Stream.read` drains the notifier only when its buf is
  fully consumed; a partial UoT frame held in `rx` is fine because the next PSH re-signals.
  Add an explicit test + comment so a future anytls notifier change can't silently stall UDP.
- Server-initiated-first flows (server sends before the client's first datagram) are dropped
  until `client_addr` is learned — acceptable for request/response UDP; note it.
