# AnyTLS Session Multiplexing — Implementation-Ready Design (Stage C)

Status: revised after adversarial review. Resolves all 8 must-fix blockers and
bakes in the locked decisions. Grounded against the actual zc tree
(`src/protocol/anytls.zig`, `src/proxy/outbound/manager.zig`, `src/proxy/mixed.zig`,
`src/compat.zig`) and the verified Zig 0.16 concurrency primitives in
`/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/Io.zig`.

---

## 0. Locked decisions (baked in, not re-opened)

- **Concurrency model = SINGLE-ACTIVE-STREAM-PER-SESSION + idle pool**, exact
  anytls-go parity. A `Session` carries at most ONE active `Stream` at a time;
  concurrency comes from the *pool of sessions*, not from N streams on one
  session. The `streams` map therefore never holds more than one entry.
  Consequently the `sid >= 2` / SYN-DONE path is the **REUSE** path (the 2nd+
  stream opened on a session that was checked back out of the idle pool), NOT a
  concurrent-streams path. There is no untested N-stream path.
- **Timers**: `idle_session_timeout` default 30s, `idle_session_check_interval`
  default 30s, `min_idle_session` default 0. Clamp `interval <= 5s -> 30s` and
  `timeout <= 5s -> 30s` independently; `min_idle` unclamped. `syn_done = 3000ms`,
  not user-configurable.
- Keep the thin `anytls.Client` shim through all sub-stages (Stage-A/B framing &
  padding tests stay green, unchanged).
- **fd cap**: unbounded by default. Note: darwin costs 3 fds / linux 2 fds per
  *active* connection (see §1).

---

## 1. Module layout

| File | Change |
|------|--------|
| `src/protocol/anytls.zig` | Refactor `Client` internals into `Session` (owns `conn`+`padding`+`packet_counter`+TLS locks) and add `Stream`. Keep a thin `Client` shim (one Session + one Stream, sid=1, synchronous read, **no recv-loop**) so all existing framing/padding tests pass UNCHANGED. Make wire helpers Session needs file-scope `pub`. `TlsConnection` struct stays verbatim. |
| `src/proxy/outbound/anytls_pool.zig` (NEW) | `SessionPool` + `PoolConfig`. Imports anytls; colocated in a sibling file so `anytls.zig` stays free of any `manager.zig`/pool dependency. |
| `src/compat.zig` | Add `Notifier` (eventfd on linux, self-pipe on darwin). |
| `src/proxy/outbound/manager.zig` | `ProxyStream`: swap `owned_anytls_client` -> `owned_anytls_stream`; route `connect(.anytls)` through a per-key pool; OutboundManager owns `anytls_pools` map + drains in deinit. |
| `src/proxy/mixed.zig` | Extend the HttpsForward guard (line 621) to treat anytls like ss/trojan; add `ProxyStream.shutdownWrite()`; wire it into `shutdownTargetWrite` (line 999); add `Stream.readBlocking` for the no-poll HttpsForward path. |
| `src/config.zig` + `src/config_validator.zig` | Add idle/pool tunables + clamps. |
| `http.zig`, `socks5.zig` | UNCHANGED. |

### FD cost
- linux: +1 fd / active stream (eventfd is read==write fd); +1 TLS fd / session;
  +1 for pool `reaper_wake`. Net per active connection: **2 fds** (1 TLS + 1
  eventfd).
- darwin: +2 fds / active stream (self-pipe r+w); +1 TLS fd / session; +2 for
  `reaper_wake`. Net per active connection: **3 fds**.
- Idle pooled sessions hold ONLY their TLS fd: the `Stream` (and thus its
  Notifier fds) is freed on stream close before the session returns to idle.

---

## 2. `compat.Notifier` (C0)

A level-triggered wake handle the relay can `poll()`. **Never** routed through the
`std.Io` socket abstraction — raw `std.c.read`/`std.c.write` so `EAGAIN` is a
plain errno (the existing `compat.posixRead`/`posixWrite` already do exactly
this), not an `errnoBug()` panic.

```zig
pub const Notifier = struct {
    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t, // == read_fd on linux (eventfd)

    pub fn init() !Notifier;
    // linux: eventfd(0, EFD_NONBLOCK|EFD_CLOEXEC); read_fd=write_fd=fd.
    // darwin: pipe2 unavailable -> pipe(), then per-fd fcntl
    //   F_SETFL O_NONBLOCK and F_SETFD FD_CLOEXEC on BOTH ends.
    //   read_fd=fds[0], write_fd=fds[1].

    pub fn signal(self: Notifier) void;
    // raw write of 8 bytes (eventfd u64=1) / 1 byte (pipe).
    // EINTR -> retry. EAGAIN -> ignore (full pipe == already readable;
    // eventfd at MAX == already signalled). NEVER errors out.

    pub fn drain(self: Notifier) void;
    // eventfd: one 8-byte read resets the counter.
    // pipe: loop raw read into scratch[256] until EAGAIN.

    pub fn handle(self: Notifier) std.posix.fd_t { return self.read_fd; }

    pub fn deinit(self: *Notifier) void;
    // close read_fd; if write_fd != read_fd close write_fd; set both = -1.
};
```

**C0 test**: `signal()` then `poll(handle, 0)` has `POLL.IN`; `drain()` then
`poll(handle, 0)` has no `POLL.IN`; multiple `signal()`s collapse to one `drain()`
(no spin). `zig build test` green.

---

## 3. Concurrency primitives (MUST-FIX #1)

The prior design wrongly used `std.Thread.Mutex`/`std.Thread.Condition` which do
**not** exist in this toolchain. All locking is rewritten to the verified APIs:

- **Mutex**: `std.Io.Mutex` (`= .init`). Locked/unlocked via the codebase's
  established VTable-free helpers `std.Io.Threaded.mutexLock(&m)` /
  `std.Io.Threaded.mutexUnlock(&m)` (already used at
  `manager.zig:447/451` across `std.Thread`-spawned threads). These take no `io`
  and are correct across `std.Thread` threads.
- **Bounded timed wait (SYN-DONE, §11)**: a `u32` flag + the io futex:
  `io.futexWaitTimeout(u32, &flag, expected, .{ .duration = .{ .raw = .{ .nanoseconds = remaining_ns }, .clock = .boot } })`.
  It returns `Cancelable!void` (`error{Canceled}` only) — **a timeout returns
  `void`, NOT `error.Timeout`**; the caller detects timeout by re-checking the
  flag and a once-computed `.boot` deadline each iteration (see §11). The recv-loop
  sets the flag and wakes via `io.futexWake(u32, &flag, 1)`. This works across
  `std.Thread` threads for the same reason `std.Io.Mutex.lockUncancelable(io)`
  already does (it internally calls the same `io.vtable.futexWait*`).
- No `std.Thread.Mutex`, no `std.Thread.Condition`, no `Condition.timedWait`
  anywhere. The only condition-like wait is the futex flag.

Threads in play:
1. **recv-loop** — one `std.Thread` per `Session`, spawned JOINABLE.
2. **reaper** — one `std.Thread` per `SessionPool`, joined at `deinit`.
3. **relay handler threads** — existing; the SOLE callers of
   `Stream.read/readBlocking/write/close/hasPendingRead/getHandle`.

---

## 4. TLS cipher-state race (MUST-FIX #2) — resolution: serialize via `tls_mutex` + poll-before-lock

`std.crypto.tls.Client` mutates **WRITE-side** cipher state on the **READ path**:
on `KeyUpdate(update_requested)` (`Client.zig:1283-1300`) it rewrites
`pv.client_secret/client_key/client_iv` and sets `c.write_seq = 0`. There is no
external hook to observe or veto this — it happens inside `fillMore`'s decode. So
"detect KeyUpdate and fail" is NOT implementable against the std client. We
therefore **serialize**: no write may run concurrently with a read that might
process a KeyUpdate.

### The lock
`Session.tls_mutex: std.Io.Mutex` guards **all** access to `conn.tls_client`
(both reader and writer sides), plus `packet_counter` and `padding` read during
shaping. It replaces the prior write-only `write_mutex`.

The naive "recv-loop holds `tls_mutex` across a blocking `fillMore`" would starve
writers forever (a blocking read holds the write lock indefinitely). We avoid
that with **poll-before-lock**, exploiting that the session TLS socket is a plain
blocking socket with no `SO_RCVTIMEO` (see `socket_options.zig` — it
deliberately does NOT set recv timeouts):

recv-loop iteration:
```
1. poll(conn.stream.handle, POLL.IN, recv_poll_timeout_ms)   // NO lock held
   - blocks until the kernel has ciphertext (or timeout -> loop & re-check dying)
2. tls_mutex lock
3. drain ALL currently-decodable frames:
   while there is buffered ciphertext OR the socket fd is still readable:
     readFrameHeader + body via readTlsExact   // CPU-bound on already-arrived bytes
     demux the frame (psh/fin/synack/...)
   stop as soon as a fillMore() would block (we re-poll without the lock)
4. tls_mutex unlock
5. goto 1
```

To "stop as soon as fillMore would block" without ever blocking under the lock,
the recv-loop reads through a **lock-aware exact reader** that, before each
`fillMore`, checks `reader.bufferedLen() > 0`; if the buffer is empty it does a
non-blocking probe `poll(handle, 0)`. If not readable, it returns a sentinel
`error.WouldYield` (NOT a wire error) to bounce back to step 1 *between frames
only*. Mid-frame (a frame header has been consumed but its body has not fully
arrived) we MUST finish the frame, so mid-frame we allow exactly one bounded
blocking `fillMore` while still holding `tls_mutex`; this is acceptable because:
- a partial frame means the peer is mid-send; the body completes within one TCP
  round of the already-committed record — bounded, not indefinite;
- writers contend only for the tail of one in-flight inbound frame, not for an
  idle connection.

This gives the proven property: **the recv-loop never holds `tls_mutex` while
idle-blocked on the socket** (the only unbounded wait — step 1's poll — runs with
no lock), so writers are never starved; and **no writer can run while the read
path is decoding a record that may carry a KeyUpdate** (mutual exclusion via
`tls_mutex`). KeyUpdate's write-state mutation is therefore safe.

`writeSessionPayload` becomes: `tls_mutex` lock; `packet_counter += 1`; build
records (reads `padding`); write+flush per boundary; `flushTlsAndSocket`;
`tls_mutex` unlock. (Body otherwise verbatim from today's `writeSessionPayload`.)

Tradeoff documented: writers may briefly wait while the recv-loop drains a burst
of inbound frames or finishes one partial inbound frame. For a proxy data path
this is negligible and strictly correct. We pick serialization over fatal-on-
KeyUpdate because the std client gives no detection hook.

---

## 5. `anytls.Session`

```zig
pub const Session = struct {
    allocator: std.mem.Allocator,
    config: Config,            // dup'd-owned strings
    password_hash: [32]u8,
    conn: ?*TlsConnection,
    peer_version: u8 = 1,      // learned from cmdServerSettings; default 1

    // Stage-B per-session state (moved off Client):
    packet_counter: u32 = 0,
    padding: PaddingFactory,
    tls_mutex: std.Io.Mutex = .init,   // §4: guards ALL conn.tls_client + counter + padding

    // multiplex:
    next_stream_id: std.atomic.Value(u32) = .init(0), // openStream: fetchAdd(1)+1 => first sid=1
    streams: std.AutoHashMapUnmanaged(u32, *Stream) = .empty,
    streams_mutex: std.Io.Mutex = .init,  // guards streams map + dying + active_streams
    recv_thread: ?std.Thread = null,
    dying: bool = false,
    die_once: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(0), // recv-loop ref + each live stream's session-ref

    // pool linkage (managed by SessionPool under pool.mutex):
    seq: u64 = 0,
    idle_since_ms: i64 = 0,
    in_idle: bool = false,
    active_streams: u32 = 0,        // 0 or 1 (single-active model)
    pool: ?*SessionPool = null,
    pool_key: []u8 = &.{},          // owned dup of pool key (freed in finalize)
};
```

Key API:
- `open(alloc, config, seq) !*Session` — dup config; dial TCP;
  `configureUpstreamProxyStream`; TLS init; send auth + flush; `refs = 1`
  (recv-loop ref); spawn recv-loop JOINABLE; return. (No stream yet.)
- `openStream(self, host, port) !*Stream` —
  `sid = next_stream_id.fetchAdd(1, .monotonic) + 1`; create `Stream`
  (`Notifier.init` + empty buf); under `streams_mutex`: if `dying` -> free stream
  + `error.SessionDying`; else `streams.put(sid, stream)`, `active_streams = 1`,
  `refs.fetchAdd(1, .monotonic)` (session-ref for the stream). Build payload:
  if first-ever stream of this session -> `settings + syn + psh` in ONE
  `writeSessionPayload` (today's `openStream` body); else `syn + psh`. If
  `sid >= 2` and `peer_version >= 2` set `stream.syn_deadline_ms` and arm the
  futex flag (§11).
- `writeSessionPayload(self, payload) !void` — §4. **Any error here -> caller
  escalates** (§9).
- `writeDataFrame(self, sid, data) !void` — fragment into `<= 65535`-byte cmdPSH
  frames -> `writeSessionPayload` each.
- `sendFin(self, sid) void` — best-effort cmdFIN via `writeSessionPayload`;
  ignore errors (peer/session may be gone).
- `recvLoop(self) void` — THREAD ENTRY (§7).
- `requestClose(self, reason) void` — external/internal death trigger (§8).
- `releaseRef(self) void` — `if refs.fetchSub(1, .acq_rel) == 1` -> finalize:
  free padding, free dup'd config + `pool_key`, end+close+destroy `conn`,
  `allocator.destroy(self)`.

---

## 6. `anytls.Stream` (satisfies the ProxyStream contract)

```zig
pub const Stream = struct {
    session: *Session,
    id: u32,
    notifier: compat.Notifier,

    buf: std.ArrayListUnmanaged(u8) = .empty,
    buf_off: usize = 0,                 // read cursor; compact when fully drained
    buf_mutex: std.Io.Mutex = .init,    // guards buf/buf_off/eof/err
    eof: bool = false,                  // peer FIN OR session death
    err: ?anyerror = null,              // AnyTlsAlert / AnyTlsStreamRejected / AnyTlsSynTimeout

    // SYN-DONE bounded wait (§11): plain u32 flag for io.futexWaitTimeout.
    // 0 = unacked, 1 = acked-ok, 2 = rejected/err. NO Condition/Mutex.
    syn_state: u32 = 0,                 // align(4) implied; pointer passed to futex
    syn_deadline_ms: i64 = 0,

    refs: std.atomic.Value(u8) = .init(2), // map-presence ref + relay-borrow ref
    closed: bool = false,               // set by ProxyStream.close (relay side)
};
```

`refs` clarifies the two independent owners of the `Stream` struct (distinct from
the `Session.refs`): **map-presence** (held while the stream is in
`session.streams`) and **relay-borrow** (held by the `ProxyStream` from creation
until `ProxyStream.close`). The struct frees only when both drop. This is what
makes the recv-loop's lock-free `appendInbound` safe (§7).

Methods (sole caller = relay handler thread, single-threaded per stream):
- `read(self, buf) !usize`:
  ```
  buf_mutex lock; defer unlock
  if buf_off < buf.items.len:
      n = copy min(buf.len, remaining); buf_off += n
      if buf_off == buf.items.len: buf.clearRetainingCapacity(); buf_off = 0; notifier.drain()
      return n
  if err |e|: notifier.drain(); return e
  if eof:     notifier.drain(); return 0
  return error.WouldBlock          // spurious wake -> relay re-polls
  ```
  Note `notifier.drain()` is called ONLY when the buffer empties or a terminal
  state is delivered — never while bytes remain (MUST-FIX #6 invariant, §10).
- `readBlocking(self, buf) !usize` (MUST-FIX #3): loop:
  ```
  n = read(buf) catch |e| switch (e) { error.WouldBlock => { poll(notifier.handle, -1); continue; }, else => return e };
  return n;   // includes 0 (eof)
  ```
  Waits on the notifier until data/eof/err; never surfaces `WouldBlock` to the
  no-poll caller.
- `write(self, data) !void`: if `closed` or `session.dying` -> `error.StreamClosed`;
  else `session.writeDataFrame(id, data)` — on write error escalate (§9).
- `shutdownWrite(self) void`: half-close — `session.sendFin(id)` (best-effort),
  set a local `write_shut` so a 2nd call is a no-op. Keeps reading (MUST-FIX #7).
- `hasPendingRead(self) bool`: `buf_mutex`; `return buf_off < buf.items.len`.
  (NOT for eof — eof is surfaced via poll+`read()==0`.)
- `getHandle(self) fd`: `closed ? -1 : notifier.handle()`.
- `close(self) void`: teardown (§8, Stream.close).

recv-loop entry points (called by `Session.recvLoop`):
- `appendInbound(self, bytes)`: `buf_mutex`; `buf.appendSlice(bytes)`; unlock;
  `notifier.signal()`.
- `markEof(self)`: `buf_mutex`; `eof = true`; unlock; `notifier.signal()`.
- `markErr(self, e)`: `buf_mutex`; `if (err == null) err = e; eof = true`; unlock;
  `notifier.signal()`.
- `markSynAck(self, rejected)`: if rejected
  `markErr(error.AnyTlsStreamRejected)` and store `syn_state = 2`; else
  `syn_state = 1`; then `futexWake(io, u32, &syn_state, 1)` (§11). (Atomic store
  with `.release` so the waiter sees it.)

---

## 7. recv-loop (`Session.recvLoop`) and lock-free demux

The recv-loop is the SOLE reader of `conn.tls_client.reader`. Per §4 it
poll-before-locks. Per-frame demux:

```
psh:            read body; streams_mutex lock; s = streams.get(sid); streams_mutex unlock
                if s == null: drop body; continue
                s.appendInbound(body)          // buf_mutex briefly + signal
fin:            discard body; streams_mutex lock; s = streams.fetchRemove(sid)?.value;
                if present: dying? -> n/a; else active_streams -= 1; streams_mutex unlock
                if s: s.markEof(); s.releaseStreamRef()  // drop MAP-ref
syn_ack:        read body; if body.len > 0 -> markSynAck(rejected=true) else markSynAck(false)
                (only meaningful for the awaited stream; harmless otherwise)
alert:          requestClose(.alert)  -> wakes all streams with AnyTlsAlert; loop exits via EndOfStream
server_settings: parse v=, set peer_version (under tls_mutex already held during decode)
update_padding_scheme: adoptPaddingScheme (mutates padding — already under tls_mutex)
heart_request:  reply cmdHeartResponse via writeSessionPayload — re-entrant tls_mutex?
                NO: the recv-loop already holds tls_mutex while decoding. The heart
                reply is emitted AFTER releasing the per-iteration lock, by queuing a
                one-shot "send heart" flag the loop drains at the top of step 1
                BEFORE polling (it takes tls_mutex, writes, releases). This avoids
                recursive lock acquisition on a non-recursive std.Io.Mutex.
waste/settings/heart_response/syn: discard body.
```

Loop exit: `fillMore` -> `error.EndOfStream` (peer/socket closed, including the
self-close in `requestClose`). On exit: ensure `requestClose(.eof)` ran (idempotent
via `die_once`), then `releaseRef()` (drop the recv-loop ref). Whoever spawned the
recv-loop joins it (reaper/shutdown); on self-EOF the thread just exits and the
joiner reaps the handle.

### Why lock-free `appendInbound` is UAF-safe
The recv-loop fetches `s` under `streams_mutex` and immediately releases the lock,
then calls `s.appendInbound`. Removal from the map (FIN-removal here, or
`requestClose`, or `Stream.close`) also happens under `streams_mutex`, and the
**map-presence ref** is only dropped *after* the removal. The struct frees only
when BOTH `Stream.refs` hit 0 (map-presence + relay-borrow). Because the relay
holds its borrow ref until `ProxyStream.close`, and `ProxyStream.close` runs on
the relay thread (which is the consumer, not the producer), the struct cannot be
freed out from under an in-flight `appendInbound`: the worst case is appending to
a buffer whose stream was just FIN-removed — harmless, the bytes are never read
and freed in `Stream` free. A `buf_mutex` acquire/release barrier inside
`appendInbound` and again before the final `buf.deinit()` in free guarantees no
append is mid-flight at free time. The recv-loop never touches `s` after
`appendInbound` returns.

---

## 8. Lifecycle: exactly-once close, move, teardown order (MUST-FIX #3 deinit, #4, #5)

### `ProxyStream` integration (manager.zig)
Replace `owned_anytls_client: ?*anytls.Client` with
`owned_anytls_stream: ?*anytls.Stream = null`.
- `initAnyTlsStream(stream) ProxyStream{ .base_stream = .{ .handle = -1 }, .allocator = null, .owned_anytls_stream = stream }` — the **pool owns the Session**; the ProxyStream **borrows the Stream**.
- `write/read/close/hasPendingRead/getHandle`: add an `owned_anytls_stream` branch
  delegating to the Stream; other branches unchanged.
- `read`: delegate to `stream.read` (the relay polls `getHandle()` and tolerates
  `error.WouldBlock` already — `mixed.zig:922`).
- `close`: `const s = owned_anytls_stream.?; owned_anytls_stream = null; s.close();`
  — `s.close()` handles FIN + return-to-idle + ref drop; manager does NOT destroy
  the Session.
- `getHandle`: `if (owned_anytls_stream) |s| return s.getHandle();`
- `shutdownWrite()` (NEW, MUST-FIX #7): `if (owned_anytls_stream) |s| { s.shutdownWrite(); return; }` else `compat.shutdownWrite(getHandle())`.
- `move`: add `owned_anytls_stream = null` to the reset list (already nulls
  the others) — borrow ref transfers with the moved struct exactly once.

OutboundManager: add `anytls_pools: std.StringHashMapUnmanaged(*SessionPool)` +
`pools_mutex: std.Io.Mutex`. `connect(.anytls)`: build `poolKey(proxy)`; `pool =
getOrCreatePool(key)` (under `pools_mutex`, lazy create + spawn reaper); `stream =
try pool.createStream(target, port)`; return `ProxyStream.initAnyTlsStream(stream)`.
`deinit`: under `pools_mutex` iterate -> `pool.deinit()` + `destroy` each; free map.

### `Stream.close()` — relay-driven, explicit => FIN
```
1. if closed return; closed = true.
2. if !session.dying: session.sendFin(id)   // half/full close FIN, best-effort
3. session.streamClosed(id):
     streams_mutex lock
     if streams.fetchRemove(id): active_streams -= 1; dropped_map = true   else dropped_map = false
     d = dying
     streams_mutex unlock
     if dropped_map: self.releaseStreamRef()             // drop MAP-ref
     session.releaseRef()                                // drop SESSION-ref for this stream
     if !d: if !pool.putIdle(session): session.requestClose(.discard)
     // if d: requestClose already ran; do nothing
4. self.releaseStreamRef()                               // drop RELAY-borrow ref
```
`releaseStreamRef`: `if refs.fetchSub(1, .acq_rel) == 1` -> free: `buf_mutex`
acquire/release barrier; `notifier.deinit()`; `buf.deinit(allocator)`;
`allocator.destroy(self)`.

### `Session.requestClose(reason)` — recv-loop EOF/alert, reaper, shutdown, syn-timeout
```
if !die_once.cmpxchg(false, true): return   // idempotent; loser returns
1. if pool: pool.evict(self)                // remove from idle + all FIRST (no resurrection)
2. streams_mutex lock; dying = true; snapshot stream ptrs; clear map; unlock
3. for each snapshotted stream:
       stream.markErr-or-markEof   (NO FIN — half-close correctness, matches
       upstream closeLocally) + signal so blocked relays wake
       stream.releaseStreamRef()   // drop the MAP-ref each held
       session.releaseRef()        // drop the SESSION-ref each stream held
4. close TLS to unblock recv-loop:
       tls_mutex lock; _ = conn.tls_client.end() catch {}; conn.stream.close(); tls_mutex unlock
   (recv-loop's blocked poll/fillMore returns EndOfStream; it will releaseRef on exit.)
   Do NOT free conn here — finalize (releaseRef==0) frees it.
```
Note: closing the socket inside `tls_mutex` and the recv-loop's poll-before-lock
discipline mean the recv-loop is either (a) blocked in poll (no lock) — the
socket close makes poll return readable/HUP, it then takes `tls_mutex` after
requestClose released it, reads EndOfStream; or (b) decoding under `tls_mutex` —
requestClose's step 4 waits for the lock, then closes; recv-loop's next read
yields EndOfStream. No deadlock either way.

**No leak**: every Notifier closed in Stream free + pool.deinit (`reaper_wake`);
TLS conn + padding + config + `pool_key` freed in `Session` finalize; all maps
deinit. FIN sent on explicit stream close; NOT on session death.

---

## 9. Write-error escalation (MUST-FIX #5)

Any error from `writeSessionPayload` (and therefore `writeDataFrame`, `openStream`,
`sendFin`) means a partial/failed TLS record has desynced the shared stream — the
session is unusable for any future reuse. Rule:
- `Stream.write` -> if `session.writeDataFrame` errors: call
  `session.requestClose(.write_error)` and return `error.StreamClosed` to the
  relay. The session is NOT returned to idle (requestClose set `dying`, so
  `Stream.close` step 3 sees `d == true` and skips `putIdle`).
- `openStream` write failure in `createStream` -> `pool.onOpenFail(sess)` ->
  `requestClose(.open_error)` + propagate the error; the half-built session is
  never pooled.
- `sendFin` is best-effort and already inside a dying/closing path; its error is
  ignored (no reuse follows a FIN).

---

## 10. Readiness / notifier state machine + EOF invariant (MUST-FIX #6)

**Invariant (enforced):** the notifier is readable **iff
`(buf_off < buf.items.len) OR eof OR err`** with the unreported terminal state
not yet consumed.

- recv-loop `signal()`s once per appended PSH chunk and once on EOF/err.
- `Stream.read` calls `notifier.drain()` ONLY when the buffer becomes empty, or
  when it delivers a terminal `eof`/`err`. It NEVER drains while bytes remain.
  Therefore a blocking `poll(-1)` in http/socks5 (and `readBlocking`) always wakes
  for EOF: when the buffer empties with `eof` pending, the LAST data-read drains
  the notifier, but `eof` is still unreported; the recv-loop's `markEof` had
  signalled, and crucially the terminal `read()` that returns the final bytes
  does the drain, then the NEXT `read()` sees `eof` and returns 0 — but to wake
  the poll for that next read, `markEof` must have left the level high. We
  enforce this by ordering: `markEof` signals AFTER setting `eof`; `read` drains
  on empty-buffer delivery but, when `eof || err` is set and not yet returned,
  `read` does NOT drain on the empty-buffer branch — it leaves the level high and
  returns 0/err on this same call. Concretely the empty-buffer branch is:
  ```
  if buf drained:
      buf.clearRetainingCapacity(); buf_off = 0
      if !(eof or err): notifier.drain()   // keep level HIGH if terminal pending
      // fall through: if eof/err, return 0/err on THIS call (drain there)
  ```
- Over-signaling is harmless: `drain()` consumes the whole counter/pipe.
  `signal()` tolerates EAGAIN (full == already readable). No spin: if data
  remains, `hasPendingRead() == true`, so the relay drains pre-poll
  (`drainTargetPending`, `mixed.zig:1018`) and never blocks; once drained the
  level goes low.

**C2 unit tests (required)**: append/read/re-poll level-trigger; **buffer-empties-
with-eof** (the explicit case) — append N bytes + markEof, read all N (returns N),
re-poll still readable, next read returns 0; EOF poke read==0; syn-reject ->
`AnyTlsStreamRejected`; `WouldBlock` on spurious wake; `hasPendingRead` true while
buffered; loopback fake-server 2-3 sids demux isolation (sequential reuse, single
active); session-death wakes the stream with no FIN observed.

---

## 11. SYN-DONE bounded wait (MUST-FIX #1 + #8) — futex flag

`syn_done = 3000ms` fixed. NO watcher thread, NO socket timeout (no EAGAIN panic),
NO `Condition`.

- **First-ever stream (sid == 1)**: NO wait (upstream parity).
  `settings + syn + psh` pipelined optimistically; `createStream` returns the
  Stream immediately. Rejection surfaces via recv-loop
  `cmdSYNACK(sid==1, len>0) -> markErr(AnyTlsStreamRejected)`; the relay's first
  `read()` returns the error.
- **Reused session, sid >= 2**: gate on `peer_version`. **MUST-FIX #8**: do NOT
  skip the guard merely because `cmdServerSettings` hasn't been observed.
  Decision: **unknown/default peer_version is treated as v2 -> ARM the wait.** The
  guard is armed when `peer_version >= 2` OR `peer_version` is still the default
  (1 here means "unknown until server_settings"); since a real anytls v2 server
  always sends `v=2`, and arming on a v1 server merely waits up to 3s for a SYNACK
  it won't send (then tears the session down and retries) — the safe, conservative
  choice. We therefore arm whenever `sid >= 2` and we have NOT positively learned
  `peer_version < 2`.
- **API REALITY (verified against `std/Io.zig` 0.16.0)**: `io.futexWaitTimeout(io,
  T, ptr, expected, timeout) Cancelable!void` where `Cancelable = error{Canceled}`.
  **A timeout is NOT an error** — on timeout the Threaded backend returns `void`
  (success). The three wake reasons (real wake / spurious wake / timeout) are
  indistinguishable from the return; the caller MUST disambiguate by re-reading
  the flag and the clock. `Timeout` is `union(enum){ none, duration: Clock.Duration,
  deadline: Clock.Timestamp }`; `Clock.Duration = .{ raw: Io.Duration, clock: Clock }`,
  `Io.Duration = .{ nanoseconds: i96 }`, and `Clock` has NO `monotonic` — use
  `.boot` (monotonic since boot). Build a duration as
  `.{ .duration = .{ .raw = .{ .nanoseconds = remaining_ns }, .clock = .boot } }`.
- Mechanism in `createStream`, after `openStream` wrote the syn (deadline computed
  ONCE; loop breaks on flag, returns timeout when the clock passes the deadline —
  there is no `error.Timeout` branch):
  ```
  if arm:
      const io = compat.io();
      const start_ns = Io.Timestamp.now(io, .boot).toNanoseconds();
      const deadline_ns = start_ns + @as(i96, syn_done_ms) * 1_000_000;
      while (true) {
          if (@atomicLoad(u32, &stream.syn_state, .acquire) != 0) break;   // SYNACK/err arrived
          const now_ns = Io.Timestamp.now(io, .boot).toNanoseconds();
          const remaining_ns = deadline_ns - now_ns;
          if (remaining_ns <= 0) {                                          // TIMEOUT (clock, not an error)
              session.requestClose(.syn_timeout);
              return error.AnyTlsSynTimeout;
          }
          io.futexWaitTimeout(u32, &stream.syn_state, 0,
              .{ .duration = .{ .raw = .{ .nanoseconds = remaining_ns }, .clock = .boot } })
              catch |e| switch (e) {                                       // only error.Canceled exists
                  error.Canceled => { session.requestClose(.canceled); return error.Canceled; },
              };
          // wake may be real / spurious / timeout — loop re-checks flag and clock
      }
      switch (@atomicLoad(u32, &stream.syn_state, .acquire)) {
          1 => {},                            // acked OK
          else => return stream.err.?,        // rejected/err already set by markSynAck (e.g. AnyTlsStreamRejected)
      }
  ```
  recv-loop `markSynAck` stores `syn_state` (release) then
  `io.futexWake(io, u32, &stream.syn_state, 1)`. Spurious/timeout wakes loop; the
  per-iteration clock recheck against the once-computed `deadline_ns` bounds total
  wait to ~3s and guarantees termination against a SYNACK-withholding server.

**C4 test**: fake server withholds SYNACK on the 2nd stream of a reused session;
`createStream` returns `error.AnyTlsSynTimeout` within ~`cfg.syn_done_ms` (use a
short value in test) and the session is torn down.

---

## 12. `SessionPool` (anytls_pool.zig) — C3

```zig
pub const PoolConfig = struct {
    idle_session_timeout_ms: i64 = 30_000,
    idle_session_check_interval_ms: i64 = 30_000,
    min_idle_session: u32 = 0,
    syn_done_ms: i64 = 3000,
};

pub const SessionPool = struct {
    allocator: std.mem.Allocator,
    key: []u8,                     // owned: "addr|port|sni|skip|hex(pwhash[0..8])"
    mutex: std.Io.Mutex = .init,
    seq_counter: u64 = 0,          // ++ under mutex
    idle: std.ArrayListUnmanaged(*Session) = .empty, // sorted seq DESC (head = warmest)
    all: std.AutoHashMapUnmanaged(*Session, void) = .empty, // every live session (for drain)
    reaper: ?std.Thread = null,
    reaper_wake: compat.Notifier,  // poll(timeout) so shutdown wakes instantly
    shutting_down: bool = false,
    cfg: PoolConfig,
};
```

- `createStream(self, host, port) !*Stream`:
  ```
  mutex lock; if shutting_down: unlock; return error.PoolShuttingDown
  sess = popHighestIdle():  // head of idle (highest seq)
      if idle nonempty: pop head; sess.in_idle = false; sess.active_streams = 1   // under mutex: reaper can't grab
      else null
  unlock
  if sess == null:
      mutex lock; seq = ++seq_counter; unlock
      sess = Session.open(alloc, config, seq)               // dial+TLS+recv-loop
      sess.pool = self; sess.pool_key = dup(key)
      mutex lock; all.put(sess); sess.active_streams = 1; unlock
  stream = sess.openStream(host, port) catch |e| { onOpenFail(sess); return e; }   // §9
  // SYN-DONE bounded wait per §11 (sid>=2 reuse path only)
  arm = (stream.id >= 2) and not knownBelowV2(sess);
  if arm: <futex wait, §11>   // on timeout: requestClose + AnyTlsSynTimeout
  return stream
  ```
- `putIdle(self, sess) bool`:
  ```
  mutex lock
  if shutting_down or sess.dying: unlock; return false   // caller closes
  sess.active_streams = 0; sess.idle_since_ms = now; sess.in_idle = true
  sortedInsertDesc(idle, sess)
  unlock; return true
  ```
- `evict(self, sess)` (the die-hook called by `requestClose` step 1):
  `mutex lock; if sess.in_idle: remove-from-idle-by-ptr; sess.in_idle = false;
  _ = all.remove(sess); unlock`.
- `onOpenFail(self, sess)`: `evict(sess)` then `sess.requestClose(.open_error)`;
  caller (in pool.deinit / not) ultimately joins. For the createStream path the
  freshly-opened session has only the recv-loop ref; `requestClose` closes the
  socket -> recv-loop exits -> `releaseRef` frees it. createStream must JOIN
  `sess.recv_thread` before returning the error so no detached thread touches
  freed memory (same protocol as §13).
- **reaper loop**:
  ```
  while true:
      poll(reaper_wake.handle, check_interval_ms)
      if shutting_down: return
      drain reaper_wake (level)
      mutex lock
      threshold = now - idle_timeout_ms
      victims = []
      from TAIL (oldest) while idle.len > min_idle AND idle[tail].idle_since_ms < threshold:
          v = idle.pop(); v.in_idle = false; _ = all.remove(v); victims.append(v)   // §13 keeps a ref
      mutex unlock
      for v in victims: reapClose(v)   // §13
  ```

---

## 13. Reaper join protocol (MUST-FIX #4)

reaped sessions' `recv_thread`s are spawned JOINABLE and MUST be joined; a
detached/un-joined thread could touch a freed `Session`. Protocol:

`reapClose(v)` (reaper thread, holding NO pool lock):
```
v.requestClose(.reaped)    // sets dying, wakes streams (none — it was idle, active_streams==0),
                           // closes TLS socket -> recv-loop will hit EndOfStream
if v.recv_thread |t|: t.join()   // BLOCKS until recv-loop exits; recv-loop's exit
                                 // calls releaseRef (drops the recv-loop ref)
// An idle session has no live streams (active_streams==0, no SESSION-refs beyond
// recv-loop), so after join, refs hit 0 inside the recv-loop's releaseRef and the
// Session is freed. The reaper does NOT call releaseRef itself (it never held one).
```
Because the reaper removed `v` from both `idle` and `all` under `mutex` BEFORE
calling `reapClose`, no other thread can hand a new stream to `v` (createStream
only pops from `idle`), so `v` cannot resurrect. The join is the synchronization
point that guarantees the recv-loop is fully exited before the struct frees.

`pool.deinit` join protocol:
```
mutex lock; shutting_down = true; mutex unlock
reaper_wake.signal(); if reaper |r|: r.join()
mutex lock; snapshot all-keys -> local list; mutex unlock
for sess in local: sess.requestClose(.shutdown)   // wakes any live streams, closes TLS
for sess in local: if sess.recv_thread |t|: t.join()   // recv-loop exits -> drops recv-loop ref
// Sessions with live (relay-borrowed) streams free later as those relays call
// ProxyStream.close -> Stream.close -> session.releaseRef hits 0. deinit does NOT
// block on relays; it only guarantees no recv-loop thread outlives the pool.
free idle/all/key; reaper_wake.deinit(); destroy pool
```
No detached threads ever touch a freed `Session`: every `recv_thread` is joined
in exactly one of {reapClose, pool.deinit, createStream-onOpenFail}.

---

## 14. mixed.zig HttpsForward + half-close (MUST-FIX #3, #7) — C5

- **Guard at `mixed.zig:621`**: change
  `if (target_stream.owned_ss_client == null and target_stream.owned_trojan_client == null)`
  to also exclude `owned_anytls_stream == null`, so anytls takes the
  `HttpsForwardStream` (`inner.read`/`inner.write`) path. Confirmed safe:
  `HttpsForwardStream` uses `self.inner.*` exclusively (lines 256/282/291/299),
  never `base_stream`.
- **No-poll read fix (MUST-FIX #3)**: `HttpsForwardStream.UpstreamReader.stream`
  (line 256) calls `self.parent.inner.read(&buf)` with no poll loop and turns
  `WouldBlock` into FATAL `error.ReadFailed`. Fix: the anytls branch of
  `ProxyStream.read` used on this path must NOT return `WouldBlock`. We route the
  HttpsForward reader through `Stream.readBlocking` (§6) — give `ProxyStream` a
  `readBlocking` that delegates to `owned_anytls_stream.readBlocking` for anytls
  and falls back to plain `read` otherwise; `UpstreamReader.stream` calls
  `inner.readBlocking(&buf)`. `readBlocking` waits on the notifier until
  data/eof/err and never yields `WouldBlock`, so the existing no-poll TLS pump
  works unchanged.
- **`HttpsForwardStream.deinit` (line 348-352)** calls `self.inner.close()`
  exactly once (line 351). For anytls, `inner` is the `ProxyStream` produced by
  `target_stream.move()` (line 629), whose `close()` runs `Stream.close()` -> FIN
  + return-to-idle/free. Confirmed exactly-once: `init`'s `errdefer
  self.inner.close()` (line 312) only fires on init failure (before the success
  return); on success `deinit`'s single `self.inner.close()` is the sole close.
  And `ProxyStream.close` is idempotent (`is_closed`/`owned_anytls_stream = null`
  guard), so even an errdefer+deinit double-call is safe.
- **Half-close FIN on the PLAIN relay path (MUST-FIX #7)**: `shutdownTargetWrite`
  (`mixed.zig:999-1005`) currently calls `compat.shutdownWrite(getHandle())`. For
  anytls `getHandle()` is the notifier read fd; `shutdown(SHUT_WR)` on it is a
  no-op and breaks half-close. Fix: `shutdownTargetWrite` calls
  `target_stream.shutdownWrite()` (the new ProxyStream method, §8) which for
  anytls sends a per-stream `cmdFIN` and keeps the read side open; for all other
  types it does `compat.shutdownWrite(getHandle())` exactly as today.

**C5 test**: HTTPS-forward over an anytls fake server works end to end;
half-close sends a FIN frame and reads continue until the server's FIN -> `read`
returns 0.

---

## 15. Config tunables (MUST-FIX-adjacent) — C6

`config.zig Config` gains (with defaults):
```zig
idle_session_check_interval: i64 = 30, // seconds
idle_session_timeout: i64 = 30,        // seconds
min_idle_session: u32 = 0,
```
Parser reads them; `Config.deinit` needs no change (scalars). `config_validator.zig`
adds clamps (warn + override, mirroring existing `addWarning`):
- `idle_session_check_interval <= 5 -> 30` (independent)
- `idle_session_timeout <= 5 -> 30` (independent)
- `min_idle_session` unclamped.
`getOrCreatePool` builds `PoolConfig` from the validated config:
`*_ms = seconds * 1000`, `syn_done_ms = 3000` (fixed).

**C6 test**: validator clamps the two sub-5s values to 30s and leaves valid
values + `min_idle_session` untouched; defaults applied when absent.

---

## 16. Locking model + lock ordering (deadlock proof)

Locks and their leaf/order:
- `pools_mutex` (manager) — outermost, only around pool map get/create/destroy;
  NEVER held while calling into a pool method that locks `pool.mutex`
  (getOrCreatePool releases `pools_mutex` before `createStream`).
- `pool.mutex` — guards pool maps/seq/in_idle. NEVER taken while holding any
  session or stream lock. `evict`/`putIdle` are called with NO session lock held.
- `session.streams_mutex` — guards `streams`/`dying`/`active_streams`.
- `stream.buf_mutex` — leaf; guards buf/eof/err.
- `session.tls_mutex` — leaf for the TLS engine; guards `conn.tls_client` +
  `packet_counter` + `padding`. NEVER held while taking `streams_mutex` or
  `buf_mutex`, and vice versa.

Ordering when multiple are held: `pool.mutex > streams_mutex > buf_mutex`.
`tls_mutex` is never nested with the others (recv-loop releases `tls_mutex` before
`appendInbound` takes `buf_mutex`; writers take `tls_mutex` alone).

Deadlock analysis of the four actors:
- **recv-loop vs writer**: both want `tls_mutex`; recv-loop never holds it while
  idle-blocked (poll-before-lock, §4), so the writer is never starved; classic
  mutual exclusion, no second lock involved -> no cycle.
- **recv-loop vs reaper**: reaper holds `pool.mutex` only to mutate maps, never
  calls into the session under that lock; `reapClose` runs lockless and only
  `join`s — joining waits on a thread that acquires `tls_mutex`/`buf_mutex`/
  `streams_mutex` but NOT `pool.mutex`, so no inversion.
- **writer vs pool**: `Stream.write` takes `tls_mutex` (leaf); `putIdle`/`evict`
  take `pool.mutex` and are only called from `Stream.close`/`requestClose` with no
  session lock held -> no nesting cycle.
- **requestClose vs everything**: takes `streams_mutex` (snapshot+clear), releases
  it, THEN takes `tls_mutex` (to close socket). Single direction
  `streams_mutex` -> (release) -> `tls_mutex`, never the reverse, no cycle.

All consistent with one global order; no lock is ever acquired against the order
-> no deadlock.

---

## 17. Ordered sub-stages (each independently `zig build test`-verifiable)

Build/test command (sandbox-safe, judge by exit code; ignore cosmetic
"failed command:" noise):
`ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-anytls-c zig build test`

- **C0 — Notifier**: implement `compat.Notifier`; tests in §2. No other edits.
- **C1 — Session/single-stream refactor (no behavior change)**: restructure
  `Client` internals into `Session` owning `conn`+`padding`+`packet_counter`+
  `tls_mutex`, with `writeSessionPayload` wrapped in `tls_mutex`. Keep a `Client`
  shim (one Session + one synchronous Stream, sid=1, NO recv-loop — read like
  today) so ALL existing framing/padding/Stage-B tests pass UNCHANGED. No
  relay/manager edits. Verify: full existing suite green; behavior identical.
- **C2 — multiplex + demux + readiness**: add `anytls.Stream`
  (Notifier+buf+buf_mutex+eof/err+refs) and the recv-loop on Session
  (poll-before-lock, §4/§7). Atomic `next_stream_id`; `openStream` registers under
  `streams_mutex`, pipelines settings/syn/psh (first) or syn/psh (reused). recv-
  loop demux per §7. Implement Stream read/readBlocking/write/shutdownWrite/close/
  hasPendingRead/getHandle + ref-counted teardown + requestClose. Tests: §10 list
  (incl. the buffer-empties-with-eof case) + loopback fake-server demux/death.
- **C3 — idle pool + reaper**: `anytls_pool.SessionPool` (§12) with clamps,
  createStream (getIdle-highest-or-open), putIdle, evict (die-hook), reaper
  reapOnce, checkout race discipline (in_idle flipped under `pool.mutex`),
  graceful drain in deinit (§13). Wire OutboundManager: `anytls_pools` +
  `pools_mutex` + getOrCreatePool + connect(.anytls) + deinit drain. Swap
  ProxyStream `owned_anytls_client` -> `owned_anytls_stream` + all 6 methods +
  `move`. Tests: pool ordering (highest seq first), reuse (same session, one
  dial), reapOnce removes timed-out beyond min_idle, createStream-vs-reap race
  under `std.testing.allocator` (leak/UAF), full `pool.deinit` leak-free + fd
  count returns to baseline.
- **C4 — SYN-DONE futex (§11)**: add `syn_state`/`syn_deadline_ms`; createStream
  bounded `futexWaitTimeout` for `sid >= 2` && armed; sid==1 no watcher; recv-loop
  `markSynAck` stores+wakes. On timeout `requestClose` + `error.AnyTlsSynTimeout`.
  Test per §11.
- **C5 — mixed.zig HttpsForward + half-close (§14)**: extend guard (621); add
  `ProxyStream.readBlocking` + `shutdownWrite`; route UpstreamReader through
  `readBlocking`; update `shutdownTargetWrite` to call `shutdownWrite`. Tests per
  §14.
- **C6 — config tunables (§15)**: add the three fields + parser + validator
  clamps; plumb `PoolConfig` at getOrCreatePool. Tests per §15.
- **C7 — final**: full `zig build test`; concurrency stress (8 relay threads
  churning streams/pool) under the leak-checking allocator; confirm
  `http.zig`/`socks5.zig` untouched and direct/ss/trojan/vless tests still green.

---

## 18. Residual risks

1. **Mid-frame blocking read under `tls_mutex`** (§4): if a malicious/slow server
   sends a frame header then stalls before the body, a writer can be blocked for
   up to that TCP stall. Bounded by the socket's normal behavior (no infinite
   stall short of a half-open connection), but a deliberately drip-fed body could
   delay writers. Mitigation if it ever matters: a recv-side read deadline that
   trips `requestClose` (out of scope for parity; documented).
2. **peer_version=v1 arming** (§8 of must-fix / §11): treating unknown as v2 means
   a genuine v1 server that never sends SYNACK costs a 3s timeout + session
   teardown + retry on the *reuse* path. Acceptable (correctness over a one-time
   3s latency) and matches the conservative choice mandated; a v1 server is not a
   real anytls deployment.
3. **`std` TLS KeyUpdate detection** is impossible externally; we rely on
   serialization (§4) being airtight. If a future std change moved write-state
   mutation off the read path the serialization would be over-strict but still
   correct.
4. **darwin self-pipe fd pressure**: 3 fds/active connection. Unbounded by
   decision; under extreme connection counts the process could hit `RLIMIT_NOFILE`.
   Documented, not capped (locked decision).
