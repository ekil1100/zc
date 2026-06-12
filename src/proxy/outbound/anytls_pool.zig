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

        // §11 SYN-DONE arm decision (computed now; the bounded futex wait is C4):
        //   arm = (stream.id >= 2) and not session.knownBelowV2()
        // TODO(C4): when armed, perform the bounded `io.futexWaitTimeout` on
        // `stream.syn_state` here (§11); on timeout call
        // `session.requestClose(.syn_timeout)` and return error.AnyTlsSynTimeout.
        // For C3a we open/reuse + openStream only and return the stream
        // immediately (the recv-loop still surfaces a rejection via the
        // notifier, matching the sid==1 path).
        _ = (stream.id >= 2) and !session.knownBelowV2();

        return stream;
    }

    /// Returns a session to the idle list after its stream closed. Returns false
    /// (caller must close the session) when the pool is shutting down or the
    /// session is already dying. Flips `active_streams`/`in_idle` under the mutex.
    pub fn putIdle(self: *SessionPool, sess: *Session) bool {
        self.lock();
        defer self.unlock();
        if (self.shutting_down or sess.dying) return false;
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
    d.dying = true;
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
