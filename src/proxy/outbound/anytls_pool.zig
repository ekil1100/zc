//! AnyTLS idle Session pool + reaper (Stage C, sub-stage C3a).
//!
//! Faithful to docs/anytls/session-multiplexing-design.md §12 (SessionPool) and
//! §13 (reaper + deinit join protocol). The pool owns the Sessions; a
//! `ProxyStream` borrows the per-stream handle (wired in C3b — NOT here).
//!
//! Concurrency model (single-active-stream-per-session + idle pool, §0): a
//! Session carries at most ONE active Stream; concurrency comes from the pool of
//! Sessions. The idle list is kept sorted by `seq` DESCENDING so the head is the
//! warmest (highest-seq) session and the tail is the coldest/oldest — the reaper
//! evicts from the TAIL.
//!
//! Race discipline (§12): `in_idle` / `active_streams` are flipped ONLY under
//! `pool.mutex`. `createStream` pops a session out of the idle list under the
//! mutex (clearing `in_idle`, setting `active_streams = 1`) BEFORE releasing it,
//! so the reaper — which only ever selects sessions still in the idle list under
//! the same mutex — can never grab a checked-out session.
//!
//! Lock ordering (§16): `pool.mutex` is taken with NO session/stream lock held,
//! and we never call back into a session method that locks while holding
//! `pool.mutex`. The reaper's blocking `join` and `requestClose` run with NO
//! pool lock held.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../../compat.zig");
const anytls = @import("../../protocol/anytls.zig");

const Session = anytls.Session;
const Stream = anytls.Stream;

pub const PoolConfig = struct {
    idle_session_timeout_ms: i64 = 30_000,
    idle_session_check_interval_ms: i64 = 30_000,
    min_idle_session: u32 = 0,
    /// SYN-DONE bounded wait (§11). Used by the C4 arm in createStream; carried
    /// here so the pool owns the value end-to-end.
    syn_done_ms: i64 = 3000,
};

pub const SessionPool = struct {
    allocator: std.mem.Allocator,
    /// Owned: "addr|port|sni|skip|hex(pwhash[0..8])". Freed in deinit.
    key: []u8,
    /// Config used to dial fresh sessions on a pool miss.
    dial_config: anytls.Config,
    mutex: std.Io.Mutex = .init,
    /// Monotonic session-sequence allocator (++ under mutex). Higher == warmer.
    seq_counter: u64 = 0,
    /// Idle sessions, sorted by seq DESCENDING (head = warmest, tail = oldest).
    idle: std.ArrayListUnmanaged(*Session) = .empty,
    /// Every live session this pool owns (for the deinit drain).
    all: std.AutoHashMapUnmanaged(*Session, void) = .empty,
    reaper: ?std.Thread = null,
    /// poll(timeout) wake so shutdown / reap-now interrupts the reaper instantly.
    reaper_wake: compat.Notifier,
    shutting_down: bool = false,
    cfg: PoolConfig,

    fn lock(self: *SessionPool) void {
        std.Io.Threaded.mutexLock(&self.mutex);
    }

    fn unlock(self: *SessionPool) void {
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    /// Monotonic milliseconds since boot. Single source of time for idle aging
    /// (NO Date.now per the toolchain constraints).
    fn nowMs() i64 {
        const ns = std.Io.Timestamp.now(compat.io(), .boot).toNanoseconds();
        return @intCast(@divTrunc(ns, 1_000_000));
    }

    /// Allocates a pool with its owned key. The reaper is NOT spawned here; the
    /// caller (getOrCreatePool in C3b, or a test) calls `startReaper` once the
    /// pool pointer is stable. `reaper_wake` is initialized eagerly so deinit can
    /// always signal/deinit it.
    pub fn init(
        allocator: std.mem.Allocator,
        key: []const u8,
        dial_config: anytls.Config,
        cfg: PoolConfig,
    ) !*SessionPool {
        const self = try allocator.create(SessionPool);
        errdefer allocator.destroy(self);

        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);

        var wake = try compat.Notifier.init();
        errdefer wake.deinit();

        self.* = .{
            .allocator = allocator,
            .key = owned_key,
            .dial_config = dial_config,
            .reaper_wake = wake,
            .cfg = cfg,
        };
        return self;
    }

    /// Spawns the JOINABLE reaper thread. Idempotent-safe to call once.
    pub fn startReaper(self: *SessionPool) !void {
        self.reaper = try std.Thread.spawn(.{}, reaperEntry, .{self});
    }

    // ---- checkout / return ----

    /// Pops the warmest idle session (head, highest seq) under the mutex,
    /// flipping it to checked-out state so the reaper can never select it.
    /// Returns null if the idle list is empty. MUST be called with `mutex` held.
    fn popHighestIdle(self: *SessionPool) ?*Session {
        if (self.idle.items.len == 0) return null;
        // idle is sorted seq DESC -> head (index 0) is warmest.
        const sess = self.idle.orderedRemove(0);
        sess.in_idle = false;
        sess.active_streams = 1;
        return sess;
    }

    /// Inserts `sess` into the idle list keeping it sorted by seq DESC. MUST be
    /// called with `mutex` held.
    fn sortedInsertDesc(self: *SessionPool, sess: *Session) !void {
        var i: usize = 0;
        while (i < self.idle.items.len and self.idle.items[i].seq > sess.seq) : (i += 1) {}
        try self.idle.insert(self.allocator, i, sess);
    }

    /// Checks out a stream: reuse the warmest idle session, else dial a fresh
    /// one. Per §12. NOTE(C3a): the SYN-DONE bounded wait (§11) is deferred to
    /// C4 — see the clearly-marked TODO below. This sub-stage does
    /// open/reuse + openStream only.
    pub fn createStream(self: *SessionPool, host: []const u8, port: u16) !*Stream {
        self.lock();
        if (self.shutting_down) {
            self.unlock();
            return error.PoolShuttingDown;
        }
        var sess = self.popHighestIdle();
        self.unlock();

        if (sess == null) {
            self.lock();
            const seq = blk: {
                self.seq_counter += 1;
                break :blk self.seq_counter;
            };
            self.unlock();

            const fresh = try Session.open(self.allocator, self.dial_config, seq);
            fresh.pool = self;
            fresh.pool_key = self.allocator.dupe(u8, self.key) catch |e| {
                // Could not record the pool key; tear the half-built session down
                // and join its recv-loop (§13) before propagating.
                self.onOpenFail(fresh);
                return e;
            };

            self.lock();
            self.all.put(self.allocator, fresh, {}) catch |e| {
                self.unlock();
                self.onOpenFail(fresh);
                return e;
            };
            fresh.active_streams = 1;
            self.unlock();

            sess = fresh;
        }

        const session = sess.?;
        const stream = session.openStream(host, port) catch |e| {
            // §9: a failed open desyncs the session — never pool it.
            self.onOpenFail(session);
            return e;
        };

        // §11 SYN-DONE bounded wait. Arm on the REUSE path (sid >= 2) unless we
        // have positively learned the peer is below v2 (unknown/default => treat
        // as v2 => arm). The first-ever stream (sid == 1) is pipelined
        // optimistically and never waits; its rejection surfaces via the recv-loop
        // notifier just like before.
        const arm = (stream.id >= 2) and !session.knownBelowV2();
        if (arm) {
            try self.synDoneWait(session, stream);
        }

        return stream;
    }

    /// §11 SYN-DONE bounded futex wait. Blocks until the recv-loop records a
    /// SYNACK on `stream.syn_state` or the once-computed `.boot` deadline passes.
    /// On timeout it tears the (now-desynced/unusable) session down and returns
    /// error.AnyTlsSynTimeout; on cancellation it tears down and returns
    /// error.Canceled; on rejection it returns the err the recv-loop stored.
    ///
    /// CRITICAL (§11): `io.futexWaitTimeout` returns `Cancelable!void` —
    /// error{Canceled} ONLY. A TIMEOUT is NOT an error: it returns void. Timeout
    /// is detected solely by re-reading the clock against the deadline computed
    /// ONCE up front.
    fn synDoneWait(self: *SessionPool, session: *Session, stream: *Stream) !void {
        const io = compat.io();
        const start_ns = std.Io.Timestamp.now(io, .boot).toNanoseconds();
        const deadline_ns = start_ns + @as(i96, self.cfg.syn_done_ms) * std.time.ns_per_ms;
        while (true) {
            if (@atomicLoad(u32, &stream.syn_state, .acquire) != 0) break; // SYNACK/err arrived
            const now_ns = std.Io.Timestamp.now(io, .boot).toNanoseconds();
            const remaining_ns = deadline_ns - now_ns;
            if (remaining_ns <= 0) {
                // Timeout detected by the clock recheck (NOT a futex error).
                self.synDoneAbort(session, stream, .syn_timeout);
                return error.AnyTlsSynTimeout;
            }
            io.futexWaitTimeout(
                u32,
                &stream.syn_state,
                0,
                .{ .duration = .{ .raw = .{ .nanoseconds = remaining_ns }, .clock = .boot } },
            ) catch |e| switch (e) {
                error.Canceled => {
                    self.synDoneAbort(session, stream, .canceled);
                    return error.Canceled;
                },
            };
            // Wake may be real / spurious / timeout — loop rechecks flag and clock.
        }
        switch (@atomicLoad(u32, &stream.syn_state, .acquire)) {
            1 => {}, // acked OK
            else => {
                // Rejected: the recv-loop already markErr'd the stream and (since
                // we hold only the recv-loop + this stream's refs) the session is
                // poisoned for reuse. Tear it down + reclaim the just-opened stream
                // and surface the err the recv-loop stored.
                const e = stream.err orelse error.AnyTlsStreamRejected;
                self.synDoneAbort(session, stream, .write_error);
                return e;
            },
        }
    }

    /// Reclaims a just-opened stream when its SYN-DONE wait fails (timeout /
    /// cancellation / rejection). The session is unusable for reuse, so we tear it
    /// down and reclaim the orphaned Stream (no ProxyStream will ever borrow it).
    ///
    /// requestClose(reason) sets `dying`, evicts the session from the pool, drops
    /// each stream's map-presence ref + markErr's it, and closes the TLS socket so
    /// the recv-loop unblocks. We then run Stream.close (idempotent, sees dying ->
    /// no FIN / no putIdle, drops the relay-borrow ref -> frees the struct -> drops
    /// the per-stream session-ref) and JOIN the recv-loop (§11/§13) so no detached
    /// thread outlives the freed Session and the recv-loop's exit drops the last
    /// (recv-loop) ref -> finalize.
    fn synDoneAbort(self: *SessionPool, session: *Session, stream: *Stream, reason: anytls.CloseReason) void {
        _ = self;
        // Capture the recv_thread handle BEFORE any ref drop: stream.close may
        // drop the last non-recv-loop ref, and a racing recv-loop exit could then
        // finalize+destroy the Session, making a later `session.recv_thread` read
        // a use-after-free. The thread handle is a value copy and stays valid to
        // join even after the Session struct is freed.
        const recv_thread = session.recv_thread;
        session.requestClose(reason);
        stream.close();
        if (recv_thread) |t| t.join();
    }

    /// Returns a session to the idle list after its stream closed. Returns false
    /// (caller must close the session) when the pool is shutting down or the
    /// session is already dying. Flips `active_streams`/`in_idle` under the mutex.
    pub fn putIdle(self: *SessionPool, sess: *Session) bool {
        self.lock();
        defer self.unlock();
        if (self.shutting_down or sess.dying.load(.acquire)) return false;
        sess.active_streams = 0;
        sess.idle_since_ms = nowMs();
        sess.in_idle = true;
        self.sortedInsertDesc(sess) catch {
            // OOM on re-insert: leave it out of idle so the caller closes it.
            sess.in_idle = false;
            return false;
        };
        return true;
    }

    /// Die-hook (§12): a dying session leaves the pool. Removes from idle (by
    /// ptr) and from `all`, clears `in_idle`. Idempotent (removing an absent
    /// session is a no-op). Called from Session.requestClose with NO session
    /// lock held.
    pub fn evict(self: *SessionPool, sess: *Session) void {
        self.lock();
        defer self.unlock();
        self.removeFromIdleLocked(sess);
        _ = self.all.remove(sess);
    }

    /// Removes `sess` from the idle list by pointer and clears its `in_idle`.
    /// MUST be called with `mutex` held.
    fn removeFromIdleLocked(self: *SessionPool, sess: *Session) void {
        if (!sess.in_idle) return;
        for (self.idle.items, 0..) |s, i| {
            if (s == sess) {
                _ = self.idle.orderedRemove(i);
                break;
            }
        }
        sess.in_idle = false;
    }

    /// A freshly-opened (or reused) session whose openStream failed: remove it
    /// from the pool, trigger close, and JOIN its recv-loop before returning so
    /// no detached thread touches freed memory (§12/§13). evict here is harmless
    /// for a session not yet in `all` (it is for a reused one).
    pub fn onOpenFail(self: *SessionPool, sess: *Session) void {
        self.evict(sess);
        sess.requestClose(.open_error);
        if (sess.recv_thread) |t| t.join();
        // recv-loop's exit dropped the recv-loop ref -> finalize freed `sess`.
        // A reused session that still had a relay-borrowed stream elsewhere is
        // impossible here (single-active model: this stream WAS the only one).
    }

    // ---- reaper ----

    fn reaperEntry(self: *SessionPool) void {
        self.reaperLoop();
    }

    fn reaperLoop(self: *SessionPool) void {
        while (true) {
            // Poll the wake fd with the check-interval as the timeout. A wake
            // (shutdown / reap-now) returns immediately; a timeout falls through
            // to a periodic reap.
            var fds = [_]std.posix.pollfd{.{
                .fd = self.reaper_wake.handle(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const interval: i32 = clampInterval(self.cfg.idle_session_check_interval_ms);
            _ = std.posix.poll(&fds, interval) catch {};

            self.lock();
            const stop = self.shutting_down;
            self.unlock();
            if (stop) return;

            self.reaper_wake.drain();
            self.reapOnce();
        }
    }

    fn clampInterval(ms: i64) i32 {
        if (ms <= 0) return 0;
        if (ms > std.math.maxInt(i32)) return std.math.maxInt(i32);
        return @intCast(ms);
    }

    /// One reap pass (§12). Under the mutex: from the TAIL (oldest) while
    /// `idle.len > min_idle` AND the tail session timed out, pop it, clear
    /// `in_idle`, remove from `all`, and collect it as a victim (keeping a ref so
    /// it cannot be resurrected — createStream only pops from `idle`). Release
    /// the mutex, then reapClose each victim holding NO lock.
    pub fn reapOnce(self: *SessionPool) void {
        var victims = std.ArrayListUnmanaged(*Session).empty;
        defer victims.deinit(self.allocator);

        self.lock();
        const threshold = nowMs() - self.cfg.idle_session_timeout_ms;
        while (self.idle.items.len > self.cfg.min_idle_session) {
            const tail = self.idle.items[self.idle.items.len - 1];
            // Sorted seq DESC: the tail is the oldest by seq, but idle_since is
            // the aging metric. We only evict a tail that has actually timed out;
            // a not-yet-timed-out tail stops the scan (any warmer session is
            // newer-or-equal seq but may be older in time — however in the
            // single-active model a session re-enters idle with a fresh
            // idle_since AND a fresh (higher) seq each checkout, so seq-DESC
            // order coincides with idle_since-DESC order; the tail is both the
            // lowest seq AND the oldest idle_since, so stopping here is correct).
            if (tail.idle_since_ms >= threshold) break;
            _ = self.idle.pop();
            tail.in_idle = false;
            _ = self.all.remove(tail);
            victims.append(self.allocator, tail) catch {
                // OOM collecting a victim: leave it removed-from-pool but close
                // it inline below via a direct reapClose to avoid leaking it.
                self.unlock();
                self.reapClose(tail);
                self.lock();
            };
        }
        self.unlock();

        for (victims.items) |v| self.reapClose(v);
    }

    /// Closes one reaped session and JOINS its recv-loop (§13), holding NO pool
    /// lock. An idle session has no live streams (active_streams == 0), so after
    /// the join the recv-loop's releaseRef drops the last ref and frees it. The
    /// reaper never held a ref itself.
    fn reapClose(self: *SessionPool, sess: *Session) void {
        _ = self;
        sess.requestClose(.reaped);
        if (sess.recv_thread) |t| {
            // Production: the join blocks until the recv-loop exits, which drops
            // the recv-loop ref -> finalize frees the (stream-less) idle session.
            t.join();
        } else {
            // Stand-in (no recv-loop, test path): drop the recv-loop ref here,
            // mirroring the recv-loop exit. A pooled production session always
            // has a recv_thread, so this branch never runs in production.
            sess.releaseRef();
        }
    }

    // ---- shutdown ----

    /// §13 drain + join protocol. Set shutting_down under the mutex, wake + join
    /// the reaper, snapshot `all`, requestClose each (wakes any live streams,
    /// closes TLS), join each recv_thread, free everything. Sessions with live
    /// relay-borrowed streams free later as those relays call Stream.close; deinit
    /// only guarantees no recv-loop thread outlives the pool.
    pub fn deinit(self: *SessionPool) void {
        // Capture the allocator up front: the snapshot list is freed AFTER
        // `allocator.destroy(self)` below, so it must NOT read `self.allocator`
        // through the freed `self`.
        const allocator = self.allocator;

        self.lock();
        self.shutting_down = true;
        self.unlock();

        self.reaper_wake.signal();
        if (self.reaper) |r| r.join();
        self.reaper = null;

        // Snapshot all-keys under the mutex, then operate lock-free.
        var snapshot = std.ArrayListUnmanaged(*Session).empty;
        defer snapshot.deinit(allocator);
        self.lock();
        var it = self.all.iterator();
        while (it.next()) |e| snapshot.append(allocator, e.key_ptr.*) catch {};
        self.unlock();

        for (snapshot.items) |sess| sess.requestClose(.shutdown);
        for (snapshot.items) |sess| {
            if (sess.recv_thread) |t| {
                // Production: the recv-loop exit drops the recv-loop ref ->
                // finalize frees the session (no live relay-borrowed streams).
                t.join();
            } else {
                // Stand-in (no recv-loop spawned, test path): no thread will drop
                // the recv-loop ref, so the pool drops it here, mirroring the
                // recv-loop exit. A pooled production session ALWAYS has a
                // recv_thread, so this branch never runs in production.
                sess.releaseRef();
            }
        }

        // Every recv-loop is now joined; the idle/all maps may still reference
        // freed-or-soon-freed sessions, but we never deref them again — just free
        // the containers and the pool's own resources.
        self.idle.deinit(allocator);
        self.all.deinit(allocator);
        allocator.free(self.key);
        self.reaper_wake.deinit();
        allocator.destroy(self);
    }
};

// ===========================================================================
// Tests — pool MECHANICS exercised with lightweight NON-DIALED Session
// stand-ins (conn = null, recv_thread = null). We construct *Session directly,
// set seq/in_idle/active_streams/idle_since_ms manually, and insert into
// idle/all. These DO NOT require a TLS handshake; the real Session.open
// dial + recv-loop path is integration-tested in C3b. Each test clearly marks
// whether it uses a stand-in vs a real session.
// ===========================================================================

const test_config = anytls.Config{ .password = "pw", .address = "127.0.0.1", .port = 443 };

/// Build a NON-DIALED stand-in *Session (conn = null, recv_thread = null) owned
/// by `pool`. Mirrors the pool's createStream bookkeeping minus the dial: assigns
/// a seq, sets the pool back-pointer + owned pool_key, and seeds refs = 1 (the
/// stand-in for the recv-loop ref) so requestClose-driven teardown is balanced.
fn makeStandin(pool: *SessionPool, seq: u64) !*Session {
    const allocator = pool.allocator;
    const self = try allocator.create(Session);
    errdefer allocator.destroy(self);
    self.* = try Session.initForTest(allocator, test_config);
    self.seq = seq;
    self.pool = pool;
    self.pool_key = try allocator.dupe(u8, pool.key);
    self.refs = std.atomic.Value(u32).init(1); // stand-in recv-loop ref
    return self;
}

/// Insert a stand-in into idle (sorted DESC) + all, marked idle. Mirrors putIdle
/// minus the dying/shutdown guard (the stand-ins are freshly created).
fn insertIdleStandin(pool: *SessionPool, sess: *Session, idle_since_ms: i64) !void {
    pool.lock();
    defer pool.unlock();
    try pool.all.put(pool.allocator, sess, {});
    sess.in_idle = true;
    sess.active_streams = 0;
    sess.idle_since_ms = idle_since_ms;
    try pool.sortedInsertDesc(sess);
}

/// Drive a stand-in's teardown the way the recv-loop exit would: requestClose
/// (idempotent; also fires the pool die-hook) then drop the stand-in ref so
/// finalize frees it. Used by tests to release stand-ins NOT reaped/drained by
/// the pool itself.
fn destroyStandin(sess: *Session) void {
    sess.requestClose(.shutdown);
    sess.releaseRef();
}

fn makePool(allocator: std.mem.Allocator, cfg: PoolConfig) !*SessionPool {
    return SessionPool.init(allocator, "test-key", test_config, cfg);
}

test "C3a: popHighestIdle returns the HIGHEST-seq idle session (warmest first)" {
    // Stand-in sessions only (no dial).
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{});
    defer pool.deinit();

    const s_lo = try makeStandin(pool, 1);
    const s_mid = try makeStandin(pool, 5);
    const s_hi = try makeStandin(pool, 9);
    // Insert out of order to prove sortedInsertDesc orders them.
    try insertIdleStandin(pool, s_mid, 0);
    try insertIdleStandin(pool, s_hi, 0);
    try insertIdleStandin(pool, s_lo, 0);

    pool.lock();
    const first = pool.popHighestIdle().?;
    const second = pool.popHighestIdle().?;
    const third = pool.popHighestIdle().?;
    const none = pool.popHighestIdle();
    pool.unlock();

    try std.testing.expectEqual(@as(u64, 9), first.seq);
    try std.testing.expectEqual(@as(u64, 5), second.seq);
    try std.testing.expectEqual(@as(u64, 1), third.seq);
    try std.testing.expectEqual(@as(?*Session, null), none);
    // popHighestIdle flips checked-out state under the mutex.
    try std.testing.expect(!first.in_idle and first.active_streams == 1);

    // These were popped (checked out), so they are no longer in idle but still
    // in `all`; tear them down as the relay/recv-loop would.
    destroyStandin(s_lo);
    destroyStandin(s_mid);
    destroyStandin(s_hi);
}

test "C3a: putIdle inserts sorted seq-DESC and refuses a dying/shutting-down session" {
    // Stand-in sessions only (no dial).
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{});

    const a = try makeStandin(pool, 2);
    const b = try makeStandin(pool, 7);
    const c = try makeStandin(pool, 4);
    // putIdle requires the session be in `all` already (createStream put it
    // there on a miss). Register the stand-ins directly.
    pool.lock();
    try pool.all.put(allocator, a, {});
    try pool.all.put(allocator, b, {});
    try pool.all.put(allocator, c, {});
    pool.unlock();

    try std.testing.expect(pool.putIdle(a));
    try std.testing.expect(pool.putIdle(b));
    try std.testing.expect(pool.putIdle(c));

    // Sorted DESC: 7, 4, 2.
    pool.lock();
    try std.testing.expectEqual(@as(u64, 7), pool.idle.items[0].seq);
    try std.testing.expectEqual(@as(u64, 4), pool.idle.items[1].seq);
    try std.testing.expectEqual(@as(u64, 2), pool.idle.items[2].seq);
    pool.unlock();

    // A dying session is refused (caller must close it).
    const d = try makeStandin(pool, 99);
    pool.lock();
    try pool.all.put(allocator, d, {});
    pool.unlock();
    d.dying.store(true, .release);
    try std.testing.expect(!pool.putIdle(d));
    try std.testing.expect(!d.in_idle);

    // deinit drains a/b/c (in idle + all) and d (in all). All are stand-ins with
    // recv_thread == null, so requestClose + finalize frees them; no leak.
    pool.deinit();
}

test "C3a: evict removes by ptr from idle+all and clears in_idle" {
    // Stand-in sessions only (no dial).
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{});
    defer pool.deinit();

    const a = try makeStandin(pool, 1);
    const b = try makeStandin(pool, 2);
    try insertIdleStandin(pool, a, 0);
    try insertIdleStandin(pool, b, 0);

    pool.evict(a);

    pool.lock();
    try std.testing.expect(!a.in_idle);
    try std.testing.expect(pool.all.get(a) == null);
    // b untouched.
    try std.testing.expect(pool.all.get(b) != null);
    try std.testing.expectEqual(@as(usize, 1), pool.idle.items.len);
    try std.testing.expectEqual(@as(u64, 2), pool.idle.items[0].seq);
    pool.unlock();

    // a was evicted from the pool but still holds its stand-in ref -> free it.
    destroyStandin(a);
    // b is still in idle + all -> deinit drains it.
}

test "C3a: reapOnce removes only timed-out sessions beyond min_idle (from oldest end)" {
    // Stand-in sessions only (no dial); recv_thread == null so reapClose's join
    // is a no-op and requestClose drives finalize.
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{ .idle_session_timeout_ms = 1000, .min_idle_session = 1 });
    defer pool.deinit();

    const now = SessionPool.nowMs();
    // seq DESC order in idle will be: 4(new), 3(new), 2(old), 1(old).
    // idle_since: warmer (higher seq) are NEWER, tail (lowest seq) are OLDEST,
    // matching the single-active invariant noted in reapOnce.
    const s1 = try makeStandin(pool, 1); // oldest
    const s2 = try makeStandin(pool, 2); // old
    const s3 = try makeStandin(pool, 3); // fresh
    const s4 = try makeStandin(pool, 4); // freshest
    try insertIdleStandin(pool, s1, now - 5000); // timed out
    try insertIdleStandin(pool, s2, now - 5000); // timed out
    try insertIdleStandin(pool, s3, now - 100); // fresh
    try insertIdleStandin(pool, s4, now - 100); // fresh

    pool.reapOnce();

    // min_idle = 1 keeps at least one; both timed-out tail sessions (s1, s2) are
    // evicted, the two fresh ones (s3, s4) remain. Victim selection from the
    // OLDEST (tail) end: s1 then s2.
    pool.lock();
    try std.testing.expectEqual(@as(usize, 2), pool.idle.items.len);
    try std.testing.expectEqual(@as(u64, 4), pool.idle.items[0].seq);
    try std.testing.expectEqual(@as(u64, 3), pool.idle.items[1].seq);
    try std.testing.expect(pool.all.get(s1) == null);
    try std.testing.expect(pool.all.get(s2) == null);
    pool.unlock();
    // s1, s2 were closed + finalized by reapClose (recv_thread == null). s3, s4
    // remain and are drained by deinit.
}

test "C3a: reapOnce keeps min_idle warmest even if all timed out" {
    // Stand-in sessions only (no dial).
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{ .idle_session_timeout_ms = 1000, .min_idle_session = 2 });
    defer pool.deinit();

    const now = SessionPool.nowMs();
    const s1 = try makeStandin(pool, 1);
    const s2 = try makeStandin(pool, 2);
    const s3 = try makeStandin(pool, 3);
    try insertIdleStandin(pool, s1, now - 9000);
    try insertIdleStandin(pool, s2, now - 9000);
    try insertIdleStandin(pool, s3, now - 9000);

    pool.reapOnce();

    // All timed out, but min_idle = 2 keeps the two warmest (seq 3, 2); only the
    // single oldest (seq 1) is evicted.
    pool.lock();
    try std.testing.expectEqual(@as(usize, 2), pool.idle.items.len);
    try std.testing.expectEqual(@as(u64, 3), pool.idle.items[0].seq);
    try std.testing.expectEqual(@as(u64, 2), pool.idle.items[1].seq);
    try std.testing.expect(pool.all.get(s1) == null);
    pool.unlock();
}

test "C3a: checked-out session (in_idle=false, active_streams=1) is never reaped" {
    // Stand-in sessions only (no dial). Race-discipline proof: a popped session
    // is removed from `idle` under the mutex, so reapOnce — which only scans the
    // idle list — can never select it, no matter how old its idle_since looks.
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{ .idle_session_timeout_ms = 1000, .min_idle_session = 0 });
    defer pool.deinit();

    const now = SessionPool.nowMs();
    const idle_old = try makeStandin(pool, 1);
    const checked_out = try makeStandin(pool, 2);
    try insertIdleStandin(pool, idle_old, now - 9000);
    // Register the checked-out session in `all` and simulate a checkout: it is
    // NOT in idle, in_idle=false, active_streams=1, with a stale idle_since that
    // WOULD make it a victim if the reaper looked at it.
    pool.lock();
    try pool.all.put(allocator, checked_out, {});
    pool.unlock();
    checked_out.in_idle = false;
    checked_out.active_streams = 1;
    checked_out.idle_since_ms = now - 9000;

    pool.reapOnce();

    pool.lock();
    // The idle session was reaped; the checked-out one is untouched (still in
    // `all`, never selected).
    try std.testing.expectEqual(@as(usize, 0), pool.idle.items.len);
    try std.testing.expect(pool.all.get(checked_out) != null);
    try std.testing.expect(checked_out.active_streams == 1);
    pool.unlock();

    // idle_old was reaped (closed + finalized). The checked-out stand-in must be
    // torn down by us (the "relay" never returned it).
    destroyStandin(checked_out);
}

test "C3a: pool.deinit on idle + checked-out stand-ins is leak/double-free free" {
    // Stand-in sessions only (no dial). Exercises the §13 drain+join protocol
    // under std.testing.allocator: free key/idle/all, reaper joined, every
    // session requestClose'd + finalized.
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{});
    // Spawn the real reaper so deinit's signal+join path is covered.
    try pool.startReaper();

    const idle_a = try makeStandin(pool, 1);
    const idle_b = try makeStandin(pool, 2);
    try insertIdleStandin(pool, idle_a, 0);
    try insertIdleStandin(pool, idle_b, 0);

    // A "checked-out" session: in `all` but not idle, active_streams=1. deinit
    // requestCloses it and (recv_thread == null) it finalizes via the snapshot
    // drain. In production a relay-borrowed stream would keep a ref and free
    // later; here there is no extra ref, so the drain frees it directly.
    const live = try makeStandin(pool, 3);
    pool.lock();
    try pool.all.put(allocator, live, {});
    pool.unlock();
    live.active_streams = 1;

    // deinit joins the reaper, requestCloses + finalizes all three, frees the
    // containers + key + reaper_wake, and destroys the pool. No leak/double-free.
    pool.deinit();
}

test "C3a: createStream returns PoolShuttingDown after deinit set the flag" {
    // No dial: we only reach the shutting_down guard, which returns before any
    // Session.open. Exercises the early-out without a TLS handshake.
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{});

    pool.lock();
    pool.shutting_down = true;
    pool.unlock();

    try std.testing.expectError(error.PoolShuttingDown, pool.createStream("example.com", 443));

    // Manually finish teardown (we set shutting_down by hand, no reaper spawned).
    pool.idle.deinit(allocator);
    pool.all.deinit(allocator);
    allocator.free(pool.key);
    pool.reaper_wake.deinit();
    allocator.destroy(pool);
}

/// Register a real *Stream (refs = 2: map-presence + relay-borrow) on a pooled
/// stand-in session, adding the per-stream Session-ref bound to the Stream
/// struct — exactly as Session.openStream does on a real checkout. Uses only
/// pub anytls API + the Stream struct fields, mirroring manager.zig's
/// makeStandinAnyTlsStream. The Stream's close() is safe on a stand-in:
/// sendFin -> sendFrame -> writeSessionPayload returns NotConnected (conn ==
/// null), which sendFin swallows.
fn registerStandinStream(sess: *Session, sid: u32) !*Stream {
    const allocator = sess.allocator;
    const stream = try allocator.create(Stream);
    errdefer allocator.destroy(stream);
    stream.* = .{
        .session = sess,
        .id = sid,
        .notifier = try compat.Notifier.init(),
    };
    std.Io.Threaded.mutexLock(&sess.streams_mutex);
    try sess.streams.put(allocator, sid, stream);
    std.Io.Threaded.mutexUnlock(&sess.streams_mutex);
    _ = sess.refs.fetchAdd(1, .monotonic); // per-stream Session-ref
    stream.owns_session_ref = true; // lifetime bound to the Stream struct
    return stream;
}

test "C3b: Stream.close returns its session to idle for reuse (one session, no second dial)" {
    // Regression for the missing-putIdle blocker: after a relay closes its
    // stream the session MUST go back to the pool's idle list so the next
    // createStream reuses it (popHighestIdle != null) instead of dialing fresh,
    // and so the session is reapable rather than orphaned in `all` forever.
    // Stand-in session only (no dial); the production close() path is exercised
    // end-to-end through pool.putIdle.
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{});
    defer pool.deinit();

    // Simulate a checkout: session in `all`, NOT idle, active_streams = 1.
    const sess = try makeStandin(pool, 1);
    pool.lock();
    try pool.all.put(allocator, sess, {});
    sess.active_streams = 1;
    pool.unlock();

    const stream = try registerStandinStream(sess, 1);

    // Relay close -> §8 return-to-idle. The stand-in keeps its recv-loop ref, so
    // the session is NOT freed: it lands back in idle, reusable.
    stream.close();

    pool.lock();
    try std.testing.expectEqual(@as(usize, 1), pool.idle.items.len);
    try std.testing.expect(pool.idle.items[0] == sess);
    try std.testing.expect(sess.in_idle);
    try std.testing.expectEqual(@as(u32, 0), sess.active_streams);
    // recv-loop ref only (per-stream ref dropped when the Stream freed).
    try std.testing.expectEqual(@as(u32, 1), sess.refs.load(.acquire));
    // Reuse: the next checkout pops the SAME session (no second dial).
    const reused = pool.popHighestIdle();
    pool.unlock();
    try std.testing.expect(reused.? == sess);
    try std.testing.expect(!sess.in_idle and sess.active_streams == 1);

    // Tear down the (now checked-out-again) stand-in like a recv-loop exit would.
    destroyStandin(sess);
}

test "C3b: Stream.close on a checked-out session discards it when the pool is shutting down" {
    // putIdle refusal path: a shutting-down pool refuses the session, so close()
    // must requestClose(.discard) it (NOT orphan it in `all`). Stand-in keeps a
    // recv-loop ref; requestClose evicts from the pool, the per-stream ref drops
    // when the Stream frees, and destroyStandin's releaseRef finalizes.
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{});

    const sess = try makeStandin(pool, 1);
    pool.lock();
    try pool.all.put(allocator, sess, {});
    sess.active_streams = 1;
    pool.unlock();

    const stream = try registerStandinStream(sess, 1);

    pool.lock();
    pool.shutting_down = true;
    pool.unlock();

    stream.close();

    // Refused -> discarded: evicted from idle + all, marked dying, never pooled.
    pool.lock();
    try std.testing.expectEqual(@as(usize, 0), pool.idle.items.len);
    try std.testing.expect(pool.all.get(sess) == null);
    pool.unlock();
    try std.testing.expect(sess.dying.load(.acquire));

    // destroyStandin's releaseRef drops the lone recv-loop ref -> finalize.
    destroyStandin(sess);

    // Manually finish pool teardown (shutting_down set by hand, no reaper).
    pool.idle.deinit(allocator);
    pool.all.deinit(allocator);
    allocator.free(pool.key);
    pool.reaper_wake.deinit();
    allocator.destroy(pool);
}

// ===========================================================================
// C4 — SYN-DONE bounded futex wait (§11). Driven through synDoneWait on
// stand-in sessions (no real TLS): a withheld SYNACK times out and tears the
// session down; a signalled markSynAck(false) returns ok; markSynAck(true)
// surfaces the rejection error. Stand-ins carry no recv_thread, so synDoneAbort
// skips the join (the production join is covered by the C3 reap/deinit tests).
// ===========================================================================

test "C4: SYN-DONE withheld SYNACK times out and tears the session down" {
    const allocator = std.testing.allocator;
    // Short syn_done_ms so the clock-recheck timeout fires fast.
    const pool = try makePool(allocator, .{ .syn_done_ms = 30 });

    const sess = try makeStandin(pool, 1);
    pool.lock();
    try pool.all.put(allocator, sess, {});
    sess.active_streams = 1;
    pool.unlock();

    // Reuse-path stream (sid >= 2). syn_state stays 0 (SYNACK never delivered).
    const stream = try registerStandinStream(sess, 2);

    const t0 = SessionPool.nowMs();
    try std.testing.expectError(error.AnyTlsSynTimeout, pool.synDoneWait(sess, stream));
    const elapsed = SessionPool.nowMs() - t0;

    // Bounded by ~syn_done_ms (generous upper bound to avoid flakiness).
    try std.testing.expect(elapsed < 2000);
    // Torn down: requestClose set dying + evicted from the pool.
    try std.testing.expect(sess.dying.load(.acquire));
    pool.lock();
    try std.testing.expect(pool.all.get(sess) == null);
    try std.testing.expectEqual(@as(usize, 0), pool.idle.items.len);
    pool.unlock();
    // synDoneAbort -> stream.close dropped the relay-borrow ref (freeing the
    // Stream and its per-stream session-ref); only the stand-in recv-loop ref
    // remains. Drop it to finalize.
    try std.testing.expectEqual(@as(u32, 1), sess.refs.load(.acquire));
    sess.releaseRef();

    pool.idle.deinit(allocator);
    pool.all.deinit(allocator);
    allocator.free(pool.key);
    pool.reaper_wake.deinit();
    allocator.destroy(pool);
}

test "C4: SYN-DONE returns ok when markSynAck(false) signals before the deadline" {
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{ .syn_done_ms = 3000 });
    defer pool.deinit();

    const sess = try makeStandin(pool, 1);
    pool.lock();
    try pool.all.put(allocator, sess, {});
    sess.active_streams = 1;
    pool.unlock();

    const stream = try registerStandinStream(sess, 2);

    // Stand-in for the recv-loop: signal a successful SYNACK shortly.
    const Waker = struct {
        fn run(s: *anytls.Stream) void {
            compat.sleepNs(5 * std.time.ns_per_ms);
            s.testMarkSynAck(false); // not rejected -> syn_state = 1 + futexWake
        }
    };
    const th = try std.Thread.spawn(.{}, Waker.run, .{stream});

    // No error: the wait observes syn_state == 1.
    try pool.synDoneWait(sess, stream);
    th.join();

    try std.testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &stream.syn_state, .acquire));
    try std.testing.expect(!sess.dying.load(.acquire));

    // Stream still live (success path leaves it for the relay). Close it back to
    // idle, then let pool.deinit drain the session.
    stream.close();
}

test "C4: SYN-DONE surfaces AnyTlsStreamRejected when markSynAck(true) signals" {
    const allocator = std.testing.allocator;
    const pool = try makePool(allocator, .{ .syn_done_ms = 3000 });

    const sess = try makeStandin(pool, 1);
    pool.lock();
    try pool.all.put(allocator, sess, {});
    sess.active_streams = 1;
    pool.unlock();

    const stream = try registerStandinStream(sess, 2);

    const Waker = struct {
        fn run(s: *anytls.Stream) void {
            compat.sleepNs(5 * std.time.ns_per_ms);
            s.testMarkSynAck(true); // rejected -> markErr + syn_state = 2 + futexWake
        }
    };
    const th = try std.Thread.spawn(.{}, Waker.run, .{stream});

    // Rejection surfaces as the err the recv-loop stored.
    try std.testing.expectError(error.AnyTlsStreamRejected, pool.synDoneWait(sess, stream));
    th.join();

    // synDoneWait's reject branch tore the session down (write_error reason).
    try std.testing.expect(sess.dying.load(.acquire));
    pool.lock();
    try std.testing.expect(pool.all.get(sess) == null);
    pool.unlock();
    try std.testing.expectEqual(@as(u32, 1), sess.refs.load(.acquire));
    sess.releaseRef();

    pool.idle.deinit(allocator);
    pool.all.deinit(allocator);
    allocator.free(pool.key);
    pool.reaper_wake.deinit();
    allocator.destroy(pool);
}

// ===========================================================================
// C7 — Stage-C capstone: CONCURRENCY STRESS + best-effort E2E INTEGRATION.
//
// These tests drive the SessionPool + Session + Stream lifecycle from MANY
// threads at once under std.testing.allocator (leak/UAF/double-free detection)
// and assert the whole graph tears down cleanly with no hang/deadlock. They
// deliberately surface races the synchronous dispatchFrame/stand-in seam tests
// (C2/C3/C4) cannot:
//   - recv-loop demux (appendInbound/markEof) vs Stream.close
//   - putIdle (return-to-idle) vs reaper reapOnce (eviction)
//   - evict (die-hook) vs createStream checkout
//   - ref-count balance on both Session.refs and Stream.refs under contention
//   - pool.deinit while sessions are idle AND checked-out with live recv-loops
//
// Determinism: per-thread behavior is varied by THREAD INDEX (NO Math.random),
// iteration counts are bounded so the suite finishes in a few seconds, and EVERY
// spawned thread is joined.
//
// E2E COVERAGE NOTE (read also the report): a real-TLS in-process end-to-end
// test is NOT possible with Zig std (it provides a CLIENT-only TLS stack — there
// is no server-side handshake to stand up a fake AnyTLS-over-TLS server in
// process). The full wire WRITE path (auth + settings + syn + psh byte framing
// and padding shaping) is already covered byte-for-byte by the Stage-B
// writeSessionPayload wire-compat tests in anytls.zig. What the C7 e2e test below
// covers is the INTEGRATION of the multiplex/relay machinery MINUS the
// std-provided TLS layer: a REAL recv-loop thread (Session.testSpawnRecvLoop,
// the production recvLoop + production exit cleanup) demuxing frames fed by an
// in-process fake AnyTLS frame server over an in-memory transport, driving
// Stream.read relay-style reads, REUSE (a 2nd sequential stream on the same
// pooled session — no second dial), and half-close (shutdownWrite then reads
// continue until the server FIN -> read returns 0). DEFERRED (documented, not
// hacked): the real TLS handshake + on-the-wire write-byte verification end to
// end; covered instead by the existing wire-compat suite.
// ===========================================================================

/// Thread-safe, blocking in-memory FrameSource backing the C7 recv-loop seam.
/// A fake AnyTLS frame server (any thread) pushes DecodedFrames; the recv-loop
/// thread pops them in order. `close()` makes `next()` return EndOfStream once
/// the queue drains, mirroring a peer/socket close. Bodies are duplicated onto
/// the heap so the recv-loop's symmetric `free(owned_body)` is balanced.
const FrameQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayListUnmanaged(anytls.DecodedFrame) = .empty,
    head: usize = 0,
    closed: bool = false,
    /// u32 futex flag bumped on every push/close so a blocked `next()` wakes.
    gen: u32 = 0,

    fn init(allocator: std.mem.Allocator) FrameQueue {
        return .{ .allocator = allocator };
    }

    /// Frees any frames never consumed (queue closed before the recv-loop drained
    /// them) plus the backing storage. Safe to call after the recv-loop joined.
    fn deinit(self: *FrameQueue) void {
        for (self.items.items[self.head..]) |f| self.allocator.free(f.owned_body);
        self.items.deinit(self.allocator);
    }

    fn push(self: *FrameQueue, command: u8, stream_id: u32, body: []const u8) !void {
        const owned = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(owned);
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        try self.items.append(self.allocator, .{ .command = command, .stream_id = stream_id, .owned_body = owned });
        _ = @atomicRmw(u32, &self.gen, .Add, 1, .acq_rel);
        compat.io().futexWake(u32, &self.gen, 1);
    }

    fn close(self: *FrameQueue) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        self.closed = true;
        std.Io.Threaded.mutexUnlock(&self.mutex);
        _ = @atomicRmw(u32, &self.gen, .Add, 1, .acq_rel);
        compat.io().futexWake(u32, &self.gen, 1);
    }

    /// FrameSource.nextFn: block until a frame is available or the queue closes.
    fn next(ctx: *anyopaque) anyerror!anytls.DecodedFrame {
        const self: *FrameQueue = @ptrCast(@alignCast(ctx));
        while (true) {
            const observed = @atomicLoad(u32, &self.gen, .acquire);
            std.Io.Threaded.mutexLock(&self.mutex);
            if (self.head < self.items.items.len) {
                const f = self.items.items[self.head];
                self.head += 1;
                std.Io.Threaded.mutexUnlock(&self.mutex);
                return f;
            }
            const done = self.closed;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            if (done) return error.EndOfStream;
            // Bounded wait so a missed wake can never hang the suite.
            compat.io().futexWaitTimeout(
                u32,
                &self.gen,
                observed,
                .{ .duration = .{ .raw = .{ .nanoseconds = 5 * std.time.ns_per_ms }, .clock = .boot } },
            ) catch {};
        }
    }
};

test "C7: concurrency stress — pool/session/stream churn vs reaper (stand-in, no leak/UAF/deadlock)" {
    // PRIMARY C7 DELIVERABLE (design §17 C7). 8 worker threads each run a bounded
    // loop of: checkout a pooled session (popHighestIdle-or-create via the same
    // bookkeeping createStream uses), register a stream, append+read inbound
    // bytes, then close the stream (exercising putIdle return-to-idle + reuse) —
    // interleaved with the REAL reaper thread reaping idle sessions and occasional
    // requestClose(.write_error) to drive the die-hook + eviction races. Uses the
    // non-dialed stand-in seam (recv_thread == null): the pool's reapClose/deinit
    // drop the recv-loop ref directly, so the pool-mechanics races (putIdle vs
    // reapOnce, evict vs checkout, ref balance) are exercised WITHOUT a TLS
    // handshake. A SEPARATE C7 test drives a real recv-loop thread for the
    // demux-vs-close race.
    const allocator = std.testing.allocator;
    // Aggressive reaper: 1ms interval, 0ms timeout so it races checkouts/returns
    // hard; min_idle 0 so it can drain everything.
    const pool = try makePool(allocator, .{
        .idle_session_check_interval_ms = 1,
        .idle_session_timeout_ms = 0,
        .min_idle_session = 0,
    });
    try pool.startReaper();

    const worker_count = 8;
    const iters_per_worker = 300;

    const Worker = struct {
        pool: *SessionPool,
        idx: usize,

        /// Mirror createStream's checkout bookkeeping for a STAND-IN session:
        /// reuse the warmest idle session, else create a fresh stand-in. Returns a
        /// checked-out session (in_idle == false, active_streams == 1, in `all`).
        fn checkout(p: *SessionPool) !*Session {
            p.lock();
            var sess = p.popHighestIdle();
            if (sess == null) {
                p.seq_counter += 1;
                const seq = p.seq_counter;
                p.unlock();
                const fresh = try makeStandin(p, seq);
                p.lock();
                p.all.put(p.allocator, fresh, {}) catch |e| {
                    p.unlock();
                    // tear the orphan down (no recv-loop: drop the stand-in ref).
                    fresh.requestClose(.open_error);
                    fresh.releaseRef();
                    return e;
                };
                fresh.active_streams = 1;
                sess = fresh;
            }
            p.unlock();
            return sess.?;
        }

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < iters_per_worker) : (i += 1) {
                const sess = checkout(self.pool) catch continue;
                const sid: u32 = @intCast((self.idx << 16) | (i & 0xffff) | 1);
                const stream = registerStandinStream(sess, sid) catch {
                    // Could not register: return the (still checked-out) session.
                    if (!self.pool.putIdle(sess)) sess.requestClose(.discard);
                    continue;
                };

                // Exercise the inbound producer/consumer path concurrently with
                // the reaper: append a few chunks + drain them.
                stream.testAppendInbound("hello");
                stream.testAppendInbound("world");
                var buf: [64]u8 = undefined;
                _ = stream.read(&buf) catch {};
                _ = stream.read(&buf) catch {};

                // Vary the close path by (idx + i) so every branch is hit:
                //  - mostly clean close -> putIdle return-to-idle + reuse
                //  - occasionally requestClose(.write_error) BEFORE close ->
                //    die-hook + eviction race with the reaper / other workers
                //  - occasionally markEof via the stand-in seam before close
                switch ((self.idx + i) % 4) {
                    0, 1 => stream.close(), // clean: return-to-idle / reuse
                    2 => {
                        // Die-hook race: requestClose evicts the stand-in from the
                        // pool (`all`), so the pool's deinit/reaper will NOT reclaim
                        // it. For a stand-in (no recv-loop thread to drop the
                        // recv-loop ref on exit) this worker must drop that ref
                        // itself AFTER stream.close has dropped the per-stream +
                        // relay refs — mirroring the recv-loop exit. A real session
                        // never needs this (its recv-loop thread drops the ref).
                        sess.requestClose(.write_error);
                        stream.close(); // sees dying -> no putIdle, drops its refs
                        sess.releaseRef(); // drop the stand-in recv-loop ref -> finalize
                    },
                    3 => {
                        stream.testMarkEof(); // simulate peer FIN landed
                        stream.close(); // clean (not dying) -> return-to-idle / reuse
                    },
                    else => unreachable,
                }
            }
        }
    };

    var workers: [worker_count]Worker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    for (0..worker_count) |k| {
        workers[k] = .{ .pool = pool, .idx = k };
    }
    for (0..worker_count) |k| {
        threads[k] = try std.Thread.spawn(.{}, Worker.run, .{&workers[k]});
    }
    for (0..worker_count) |k| threads[k].join();

    // deinit drains every remaining idle session (joins the reaper first), frees
    // the containers + key + reaper_wake. std.testing.allocator asserts no leak;
    // the run completing asserts no deadlock/hang.
    pool.deinit();
}

test "C7: concurrency stress — REAL recv-loop demux vs Stream.close (UAF/leak/deadlock)" {
    // Surfaces the race the synchronous dispatchFrame seam cannot: a genuine
    // recv-loop thread (Session.testSpawnRecvLoop -> production recvLoop) demuxing
    // PSH/FIN frames into a Stream WHILE the relay thread reads and then closes
    // that same Stream. Many sessions, each with its own recv-loop thread fed by a
    // fake-server thread; a relay thread per session reads + closes. All under
    // std.testing.allocator (any UAF/double-free in the lock-free appendInbound vs
    // releaseStreamRef path trips the allocator or a sanitizer).
    const allocator = std.testing.allocator;
    const session_count = 8;
    const frames_per_session = 200;

    const FakeServer = struct {
        fn run(q: *FrameQueue) void {
            var i: usize = 0;
            while (i < frames_per_session) : (i += 1) {
                // sid 1 throughout (single-active model). PSH bodies the relay reads.
                q.push(2, 1, "payload-bytes") catch break; // cmd 2 = psh
            }
            q.push(3, 1, "") catch {}; // cmd 3 = fin -> markEof
            q.close(); // drain -> recv-loop EndOfStream -> requestClose(.eof)
        }
    };

    const Relay = struct {
        // The Stream is registered up front (so the relay-borrow + per-stream
        // Session-ref are held BEFORE the recv-loop can drain and exit — otherwise
        // the lone recv-loop ref could finalize the Session while we still hold a
        // raw `sess`/`stream` pointer). The relay thread only reads + closes.
        fn run(stream: *Stream) void {
            var buf: [32]u8 = undefined;
            var reads: usize = 0;
            while (reads < frames_per_session + 50) : (reads += 1) {
                const n = stream.read(&buf) catch |e| switch (e) {
                    error.WouldBlock => {
                        compat.sleepNs(50 * std.time.ns_per_us);
                        continue;
                    },
                    else => break, // terminal err
                };
                if (n == 0) break; // eof
            }
            stream.close(); // races the recv-loop's demux of the SAME sid
        }
    };

    var queues: [session_count]FrameQueue = undefined;
    var streams: [session_count]*Stream = undefined;
    // recv_thread handles snapshotted up front: the recv-loop's exit may finalize
    // (free) its Session, so reading `sess.recv_thread` AFTER the relays run would
    // be a UAF. A std.Thread is a value handle that stays valid to join even after
    // the Session struct is freed (same rationale as synDoneAbort, §11).
    var recv_threads: [session_count]std.Thread = undefined;
    var server_threads: [session_count]std.Thread = undefined;
    var relay_threads: [session_count]std.Thread = undefined;

    for (0..session_count) |k| {
        queues[k] = FrameQueue.init(allocator);
    }
    // Build sessions, register the relay stream (refs=2: recv-loop + per-stream),
    // THEN spawn the real recv-loops. Registering before the recv-loop can run
    // guarantees the relay ref is held before any drain/exit.
    for (0..session_count) |k| {
        const sess = try allocator.create(Session);
        sess.* = try Session.initForTest(allocator, test_config);
        sess.refs = std.atomic.Value(u32).init(1); // recv-loop ref (seam contract)
        streams[k] = try registerStandinStream(sess, 1); // refs -> 2
        try sess.testSpawnRecvLoop(&queues[k], FrameQueue.next);
        recv_threads[k] = sess.recv_thread.?; // snapshot the joinable handle
    }
    // Spawn fake servers + relays.
    for (0..session_count) |k| {
        server_threads[k] = try std.Thread.spawn(.{}, FakeServer.run, .{&queues[k]});
        relay_threads[k] = try std.Thread.spawn(.{}, Relay.run, .{streams[k]});
    }
    // Join servers + relays, then the recv-loops (whose exit drops the last ref
    // -> finalize frees the Session). Joining the snapshotted handles never
    // touches a (possibly freed) Session.
    for (0..session_count) |k| server_threads[k].join();
    for (0..session_count) |k| relay_threads[k].join();
    for (0..session_count) |k| recv_threads[k].join();
    for (0..session_count) |k| queues[k].deinit();
}

test "C7: e2e integration — real recv-loop demux + relay + REUSE + half-close (no TLS)" {
    // Best-effort end-to-end (read the C7 COVERAGE NOTE above): exercises the full
    // multiplex/relay path MINUS the std-provided TLS layer via a real recv-loop
    // thread fed by an in-process fake AnyTLS frame server.
    //   1. RELAY READ: server pushes PSH frames -> recv-loop demux -> Stream.read
    //      returns exactly those bytes in order.
    //   2. REUSE: a 2nd sequential stream (sid 2) on the SAME session reuses the
    //      same recv-loop (no second "dial") and demuxes to the new sid.
    //   3. HALF-CLOSE: the relay shutdownWrite()s (send-side FIN best-effort; here
    //      the session is non-dialed so it's a no-op write) and KEEPS reading; the
    //      server then sends a FIN frame -> recv-loop markEof -> Stream.read == 0.
    const allocator = std.testing.allocator;

    // A real pool so the first stream's close() returns the session to idle
    // (genuine REUSE: not dying, reused by popHighestIdle for the 2nd stream)
    // rather than discarding it. Long timeouts so the reaper never interferes.
    const pool = try makePool(allocator, .{
        .idle_session_timeout_ms = 60_000,
        .idle_session_check_interval_ms = 60_000,
    });

    var q = FrameQueue.init(allocator);
    // Checkout bookkeeping for a stand-in (in `all`, pool back-pointer set, refs=1
    // recv-loop ref), then spawn the real recv-loop over the in-memory transport.
    const sess = try makeStandin(pool, 1);
    pool.lock();
    try pool.all.put(allocator, sess, {});
    sess.active_streams = 1; // checked out
    pool.unlock();
    try sess.testSpawnRecvLoop(&q, FrameQueue.next);
    // Snapshot the joinable handle up front: at teardown the recv-loop self-exits
    // (q.close -> EndOfStream -> requestClose(.eof) evicts from the pool + drops
    // the recv-loop ref -> finalize frees the Session), so we join via this value
    // handle and let pool.deinit see an already-emptied `all` (no UAF).
    const recv_thread = sess.recv_thread.?;

    // ---- Stream 1: relay read of demuxed PSH bytes ----
    const s1 = try registerStandinStream(sess, 1);
    try q.push(2, 1, "AB"); // psh sid 1
    try q.push(2, 1, "CDE"); // psh sid 1
    var buf: [64]u8 = undefined;
    var got = std.ArrayListUnmanaged(u8).empty;
    defer got.deinit(allocator);
    while (got.items.len < 5) {
        const n = s1.read(&buf) catch |e| switch (e) {
            error.WouldBlock => {
                compat.sleepNs(100 * std.time.ns_per_us);
                continue;
            },
            else => return e,
        };
        try got.appendSlice(allocator, buf[0..n]);
    }
    try std.testing.expectEqualSlices(u8, "ABCDE", got.items);

    // Half-close the send side, then prove reads continue until the server FIN.
    s1.shutdownWrite(); // send-side FIN (best-effort; non-dialed -> no-op)
    try std.testing.expect(s1.write_shut);
    try q.push(3, 1, ""); // server FIN -> markEof; read side open until consumed
    while (true) {
        const n = s1.read(&buf) catch |e| switch (e) {
            error.WouldBlock => {
                compat.sleepNs(100 * std.time.ns_per_us);
                continue;
            },
            else => return e,
        };
        if (n == 0) break; // FIN observed -> half-close read complete
    }
    s1.close(); // pool != null, not dying -> putIdle: session returns to idle

    // The close returned the session to idle (alive, NOT dying) -> REUSE.
    pool.lock();
    try std.testing.expectEqual(@as(usize, 1), pool.idle.items.len);
    const reused = pool.popHighestIdle().?; // check the SAME session back out
    pool.unlock();
    try std.testing.expect(reused == sess); // reuse: no second dial
    try std.testing.expect(!sess.dying.load(.acquire));

    // ---- Stream 2: REUSE the same session (same recv-loop, no new dial) ----
    const s2 = try registerStandinStream(sess, 2);
    try q.push(2, 2, "XYZ"); // psh sid 2 -> demuxed to the NEW stream by the SAME recv-loop
    got.clearRetainingCapacity();
    while (got.items.len < 3) {
        const n = s2.read(&buf) catch |e| switch (e) {
            error.WouldBlock => {
                compat.sleepNs(100 * std.time.ns_per_us);
                continue;
            },
            else => return e,
        };
        try got.appendSlice(allocator, buf[0..n]);
    }
    try std.testing.expectEqualSlices(u8, "XYZ", got.items);
    s2.close(); // putIdle again -> back to idle

    // Tear down: close the queue so the recv-loop hits EndOfStream and self-exits
    // (requestClose(.eof) evicts the session + drops the recv-loop ref ->
    // finalize). JOIN the recv-loop via the snapshotted handle BEFORE pool.deinit,
    // so deinit snapshots an already-emptied `all` and never touches freed memory.
    q.close();
    recv_thread.join();
    pool.deinit();
    q.deinit();
}
