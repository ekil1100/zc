const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const crypto = std.crypto;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;
const socket_options = @import("../socket_options.zig");
const anytls_pool = @import("../proxy/outbound/anytls_pool.zig");

const frame_header_len = 7;
const max_alert_log_len = 256;
const default_padding0_len: u16 = 30;
const max_frame_data_len = std.math.maxInt(u16);

const default_padding_scheme =
    "stop=8\n" ++
    "0=30-30\n" ++
    "1=100-400\n" ++
    "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000\n" ++
    "3=9-9,500-1000\n" ++
    "4=500-1000\n" ++
    "5=500-1000\n" ++
    "6=500-1000\n" ++
    "7=500-1000";

/// CheckMark sentinel token ('c' in a scheme segment list). Upstream uses the
/// constant CheckMark = -1; we model the segment as a tagged union instead of an
/// i64 to stay type-safe in Zig.
const Segment = union(enum) {
    /// Fixed/random target record-payload size. For a `MIN-MAX` token the
    /// concrete size is drawn lazily; `min == max` means a fixed size.
    range: struct { min: u32, max: u32 },
    /// The `c` CheckMark token: emits no record, only short-circuits the tail.
    check_mark,
};

/// A parsed AnyTLS padding scheme. Mirrors upstream PaddingFactory: a `stop`
/// cutoff plus a lazily-evaluated per-packet-index list of segments. Owns its
/// raw scheme bytes so `padding-md5` is always derived from the ACTIVE scheme.
const PaddingFactory = struct {
    allocator: std.mem.Allocator,
    /// Exact raw scheme bytes as loaded; md5 is computed over these verbatim.
    raw: []u8,
    /// Lowercase hex MD5 of `raw`.
    md5_hex: [32]u8,
    /// Packet-index cutoff: padding applies only while `pkt < stop`.
    stop: u32,
    /// Per-index segment lists, indexed by packet index. Entries may be null
    /// (no line for that index -> GenerateRecordPayloadSizes returns empty).
    entries: std.AutoHashMapUnmanaged(u32, []Segment),

    /// Parses `scheme` into a PaddingFactory. Returns an error (so the caller can
    /// keep the previous factory) if `stop` is absent or unparseable. Lines that
    /// are blank or lack '=' are ignored. Per-index lines whose key is not a
    /// decimal integer are ignored. Malformed segment tokens are skipped.
    fn init(allocator: std.mem.Allocator, scheme: []const u8) !PaddingFactory {
        const raw = try allocator.dupe(u8, scheme);
        errdefer allocator.free(raw);

        var md5: [16]u8 = undefined;
        crypto.hash.Md5.hash(raw, &md5, .{});
        var md5_hex: [32]u8 = undefined;
        writeLowerHex(&md5_hex, &md5);

        var entries: std.AutoHashMapUnmanaged(u32, []Segment) = .empty;
        errdefer freeEntries(allocator, &entries);

        var stop: ?u32 = null;

        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            const value = line[eq + 1 ..];

            if (std.mem.eql(u8, key, "stop")) {
                stop = std.fmt.parseInt(u32, value, 10) catch return error.InvalidPaddingScheme;
                continue;
            }

            const idx = std.fmt.parseInt(u32, key, 10) catch continue;
            const segments = try parseSegments(allocator, value);
            errdefer allocator.free(segments);
            // Last line wins on duplicate index keys (matches map semantics).
            const gop = try entries.getOrPut(allocator, idx);
            if (gop.found_existing) allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = segments;
        }

        const stop_val = stop orelse return error.InvalidPaddingScheme;

        return .{
            .allocator = allocator,
            .raw = raw,
            .md5_hex = md5_hex,
            .stop = stop_val,
            .entries = entries,
        };
    }

    fn deinit(self: *PaddingFactory) void {
        freeEntries(self.allocator, &self.entries);
        self.allocator.free(self.raw);
        self.* = undefined;
    }

    fn freeEntries(allocator: std.mem.Allocator, entries: *std.AutoHashMapUnmanaged(u32, []Segment)) void {
        var it = entries.iterator();
        while (it.next()) |e| allocator.free(e.value_ptr.*);
        entries.deinit(allocator);
    }

    /// Parses a comma-separated SEGMENTLIST into Segments. `c` -> check_mark;
    /// `MIN-MAX` -> range (skipped if malformed or min > max).
    fn parseSegments(allocator: std.mem.Allocator, value: []const u8) ![]Segment {
        var list = std.ArrayList(Segment).empty;
        errdefer list.deinit(allocator);

        var tokens = std.mem.splitScalar(u8, value, ',');
        while (tokens.next()) |token| {
            if (token.len == 0) continue;
            if (std.mem.eql(u8, token, "c")) {
                try list.append(allocator, .check_mark);
                continue;
            }
            const dash = std.mem.indexOfScalar(u8, token, '-') orelse continue;
            const min = std.fmt.parseInt(u32, token[0..dash], 10) catch continue;
            const max = std.fmt.parseInt(u32, token[dash + 1 ..], 10) catch continue;
            if (min > max) continue;
            // A drawn range size can become a u16 waste-frame data length
            // (buildSessionRecords cases C/D), so clamp the range into
            // [0, max_frame_data_len] to stop a malicious/buggy server pushing a
            // cmd-6 update_padding_scheme whose oversized range panics the
            // narrowing @intCast on the client's next shaped write (DoS).
            const cmin = @min(min, max_frame_data_len);
            const cmax = @min(max, max_frame_data_len);
            try list.append(allocator, .{ .range = .{ .min = cmin, .max = cmax } });
        }

        return try list.toOwnedSlice(allocator);
    }

    /// Looks up the segment list for `pkt`. Returns an empty slice when no line
    /// exists for that index (NO fallback to a default/highest index).
    fn segmentsFor(self: *const PaddingFactory, pkt: u32) []const Segment {
        return self.entries.get(pkt) orelse &.{};
    }

    /// Draws the concrete record-payload size for a range segment. Equal
    /// min/max yields the exact value; otherwise a uniform integer in
    /// [min, max) (max EXCLUSIVE), matching upstream's big.NewInt(max-min)+min.
    fn drawRangeSize(range: anytype) usize {
        if (range.min == range.max) return range.min;
        const span = range.max - range.min;
        var bytes: [4]u8 = undefined;
        compat.randomBytes(&bytes);
        const r = readU32(&bytes) % span;
        return range.min + r;
    }
};

const Command = enum(u8) {
    waste = 0,
    syn = 1,
    psh = 2,
    fin = 3,
    settings = 4,
    alert = 5,
    update_padding_scheme = 6,
    syn_ack = 7,
    heart_request = 8,
    heart_response = 9,
    server_settings = 10,
};

pub const Config = struct {
    password: []const u8,
    address: []const u8,
    port: u16,
    sni: ?[]const u8 = null,
    skip_cert_verify: bool = false,
};

/// Verbatim TLS connection state (unchanged from the original Client). Promoted
/// to file scope (was `Client.TlsConnection`) so `Session` can own it.
pub const TlsConnection = struct {
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
    tls_client: tls.Client,
    ca_bundle: ?Certificate.Bundle = null,
    ca_lock: std.Io.RwLock = .init,
    socket_read_buffer: [tls.Client.min_buffer_len]u8,
    socket_write_buffer: [tls.Client.min_buffer_len]u8,
    tls_read_buffer: [tls.Client.min_buffer_len]u8,
    tls_write_buffer: [tls.Client.min_buffer_len]u8,
};

const FrameHeader = struct {
    command: u8,
    stream_id: u32,
    length: u16,
};

/// A single AnyTLS session: owns the TLS connection, the active padding scheme,
/// the monotonic packet counter, the negotiated peer protocol version, and the
/// `tls_mutex` that serializes all access to the TLS engine + counter + padding.
///
/// In C1 the Session carries exactly ONE logical stream (sid=1) and is driven
/// synchronously by the `Client` shim (no recv-loop, no streams map, no
/// Notifier — those arrive in C2). All wire framing/shaping is byte-identical to
/// the pre-refactor `Client`; the only structural change is that
/// `writeSessionPayload`'s TLS writes are now wrapped in
/// `tls_mutex` lock/unlock so later multiplex stages have the lock in place.
pub const Session = struct {
    allocator: std.mem.Allocator,
    config: Config,
    password_hash: [32]u8,
    conn: ?*TlsConnection = null,
    peer_version: u8 = 1,
    /// True once cmdServerSettings has been parsed with an explicit `v=`. Until
    /// then `peer_version` is the unverified default (1) and `knownBelowV2`
    /// returns false (conservative "treat as v2" per §11).
    learned_version: bool = false,
    packet_counter: u32 = 0,
    /// Active padding scheme. Seeded from default_padding_scheme in init() and
    /// atomically replaced when the server pushes cmdUpdatePaddingScheme (cmd 6).
    padding: PaddingFactory,
    /// Guards ALL access to `conn.tls_client` (reader + writer sides) plus
    /// `packet_counter` and `padding` during shaping. In C1 the writer is the
    /// only contender; later stages add a recv-loop that also takes it.
    tls_mutex: std.Io.Mutex = .init,

    // ---- C2 multiplex state (used only by the recv-loop / Stream path) ----
    /// Monotonic stream-id allocator. `openStream` does fetchAdd(1)+1, so the
    /// first stream gets sid=1.
    next_stream_id: std.atomic.Value(u32) = .init(0),
    /// Live streams keyed by sid. Holds at most one entry in the single-active
    /// model, but the map machinery generalizes to N for the demux tests.
    streams: std.AutoHashMapUnmanaged(u32, *Stream) = .empty,
    /// Guards `streams` + `dying`. Leaf-ordered above `buf_mutex`, never nested
    /// with `tls_mutex` (§16).
    streams_mutex: std.Io.Mutex = .init,
    /// The recv-loop thread, spawned JOINABLE in `startRecvLoop`.
    recv_thread: ?std.Thread = null,
    /// Set by requestClose (store .release, still under `streams_mutex` for the
    /// map snapshot). Atomic because it is also read across DIFFERENT locks:
    /// SessionPool.putIdle holds pool.mutex (not streams_mutex), and Stream
    /// write/shutdownWrite/close read it lock-free. A plain bool gave no
    /// happens-before between the requestClose write and the putIdle read, so a
    /// stale dying==false could re-pool an evicted/dying session -> UAF. The
    /// acquire/release pairing supplies that ordering (§16 amendment).
    dying: std.atomic.Value(bool) = .init(false),
    /// Idempotency gate for requestClose (the loser of the cmpxchg returns).
    die_once: std.atomic.Value(bool) = .init(false),
    /// recv-loop ref + one session-ref per live stream. The Session is freed
    /// (finalize) only when this reaches 0.
    refs: std.atomic.Value(u32) = .init(0),
    /// One-shot deferred "send heart-response" flag set by the recv-loop's
    /// heart_request demux, drained at the top of the next iteration BEFORE
    /// polling (so we never recursively lock tls_mutex, §7).
    heart_pending: std.atomic.Value(bool) = .init(false),

    // ---- C3 pool linkage (§3/§12). These fields are managed exclusively by the
    // SessionPool under `pool.mutex`; the Session never mutates them itself
    // except `pool`/`pool_key` set once at open time. `in_idle`/`active_streams`
    // are flipped ONLY under `pool.mutex` so the reaper can never grab a
    // checked-out session.
    /// Monotonic pool sequence (higher == warmer). Assigned by the pool at open.
    seq: u64 = 0,
    /// True while this session sits in the pool's idle list. Flipped only under
    /// pool.mutex.
    in_idle: bool = false,
    /// 0 or 1 in the single-active model. Flipped only under pool.mutex.
    active_streams: u32 = 0,
    /// Monotonic-clock timestamp (ms, .boot) of when the session entered idle.
    idle_since_ms: i64 = 0,
    /// Handshake-response deadline (ms, monotonic). Set in open() after dial;
    /// cleared by dispatchFrame on server_settings or syn_ack. When this is
    /// non-zero and the current monotonic clock exceeds it, the recv-loop tears
    /// down the session. 0 = disabled / already completed.
    handshake_deadline_ms: i64 = 0,
    /// Back-pointer to the owning pool, or null for a non-pooled session (the
    /// Client shim and the C2/C3 stand-in tests). When non-null, requestClose's
    /// die-hook removes this session from the pool (§12) before tearing down.
    pool: ?*anytls_pool.SessionPool = null,
    /// Owned dup of the pool's key, freed in finalize. Empty for non-pooled.
    pool_key: []u8 = &.{},

    /// TEST-ONLY outbound sink. When non-null, `writeSessionPayload` delivers the
    /// shaped-payload bytes here INSTEAD of the (absent) TLS connection, so a
    /// stand-in Session (conn=null) can have a SUCCEEDING outbound write. This is
    /// the seam the udp_uot D-stage branch-(c) e2e uses to drive the REAL
    /// udpRelayLoop's outbound leg without a TLS handshake. NEVER set in
    /// production (the production path always has a real `conn`).
    test_outbound_sink: ?*const fn (ctx: ?*anyopaque, payload: []const u8) void = null,
    test_outbound_ctx: ?*anyopaque = null,

    fn lockStreams(self: *Session) void {
        std.Io.Threaded.mutexLock(&self.streams_mutex);
    }

    fn unlockStreams(self: *Session) void {
        std.Io.Threaded.mutexUnlock(&self.streams_mutex);
    }

    fn lockTls(self: *Session) void {
        std.Io.Threaded.mutexLock(&self.tls_mutex);
    }

    fn unlockTls(self: *Session) void {
        std.Io.Threaded.mutexUnlock(&self.tls_mutex);
    }

    fn init(allocator: std.mem.Allocator, config: Config) !Session {
        var password_hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(config.password, &password_hash, .{});

        const padding = try PaddingFactory.init(allocator, default_padding_scheme);

        return .{
            .allocator = allocator,
            .config = config,
            .password_hash = password_hash,
            .padding = padding,
        };
    }

    /// Test-only public constructor for a NON-DIALED Session stand-in
    /// (conn = null, recv_thread = null). Used by anytls_pool.zig's pool-mechanics
    /// tests, which exercise the pool without a real TLS handshake (§ "TESTING").
    /// NOT for production use — the production path is `open`.
    pub fn initForTest(allocator: std.mem.Allocator, config: Config) !Session {
        return Session.init(allocator, config);
    }

    /// Frees the padding factory and the owned TLS connection. Callers that need
    /// to emit a session-close FIN first must do so before calling this (see
    /// Client.deinit), since FIN shaping reads `padding`.
    fn deinit(self: *Session) void {
        self.padding.deinit();
        if (self.conn) |conn| {
            _ = conn.tls_client.end() catch {};
            conn.stream.close();
            if (conn.ca_bundle) |*ca_bundle| {
                ca_bundle.deinit(self.allocator);
            }
            self.allocator.destroy(conn);
            self.conn = null;
        }
    }

    /// Dials the upstream, performs the TLS handshake, and sends the auth
    /// request. On success `self.conn` is populated. Verbatim from the original
    /// Client.connect prologue.
    fn dial(self: *Session) !void {
        if (self.conn != null) return error.AlreadyConnected;

        const stream = try net.tcpConnectToHost(self.allocator, self.config.address, self.config.port);
        var stream_owned_by_conn = false;
        errdefer if (!stream_owned_by_conn) stream.close();
        try socket_options.configureUpstreamProxyStream(stream);

        const conn = try self.initTlsConnection(stream);
        stream_owned_by_conn = true;
        var conn_owned_by_self = false;
        errdefer if (!conn_owned_by_self) self.deinitTlsConnection(conn);

        const auth = try buildAuthRequest(self.allocator, self.config.password);
        defer self.allocator.free(auth);
        try conn.tls_client.writer.writeAll(auth);
        try flushTlsAndSocket(conn);

        self.conn = conn;
        conn_owned_by_self = true;
    }

    /// Sends `settings + syn + psh(socks_addr)` for the first logical stream of
    /// the session (sid). Verbatim from the original Client.openStream. Used
    /// only by the synchronous Client shim (the multiplex path uses the public
    /// `openStream` below).
    fn openFirstStream(self: *Session, stream_id: u32, target_host: []const u8, target_port: u16) !void {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);

        const settings = try buildSettings(self.allocator, &self.padding.md5_hex);
        defer self.allocator.free(settings);
        try appendFrame(self.allocator, &payload, .settings, 0, settings);
        try appendFrame(self.allocator, &payload, .syn, stream_id, "");

        const socks_addr = try encodeSocksAddr(self.allocator, target_host, target_port);
        defer self.allocator.free(socks_addr);
        try appendFrame(self.allocator, &payload, .psh, stream_id, socks_addr);

        try self.writeSessionPayload(payload.items);
    }

    fn sendFrame(self: *Session, command: Command, stream_id: u32, data: []const u8) !void {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);

        try appendFrame(self.allocator, &payload, command, stream_id, data);
        try self.writeSessionPayload(payload.items);
    }

    /// Fragments one logical write `payload` into one or more TLS records per the
    /// active padding scheme, then writes each record (a distinct TLS record
    /// boundary) and flushes. Mirrors upstream writeConn: pkt = ++counter; if
    /// pkt >= stop, write `payload` unshaped in a single record; otherwise split
    /// per GenerateRecordPayloadSizes, inserting cmdWaste(0) frames to hit target
    /// sizes, with CheckMark short-circuiting the padding-only tail.
    ///
    /// The TLS writes (and the counter increment + padding read that feed them)
    /// run under `tls_mutex` so later multiplex stages can share this lock. The
    /// counter-increment-then-build-records ordering is unchanged, so the shaped
    /// wire bytes are byte-identical to the pre-refactor code.
    fn writeSessionPayload(self: *Session, payload: []const u8) !void {
        self.lockTls();
        defer self.unlockTls();

        // TEST-ONLY seam: a stand-in Session (conn=null) with a test sink set
        // delivers the logical payload to the sink and returns success, so the
        // REAL relay's outbound writeDatagram does not fail before branch (c).
        if (self.conn == null) {
            if (self.test_outbound_sink) |sink| {
                self.packet_counter += 1;
                sink(self.test_outbound_ctx, payload);
                return;
            }
        }

        const conn = self.conn orelse return error.NotConnected;
        self.packet_counter += 1;

        var records = std.ArrayList(u8).empty;
        defer records.deinit(self.allocator);
        var boundaries = std.ArrayList(usize).empty;
        defer boundaries.deinit(self.allocator);

        try buildSessionRecords(
            self.allocator,
            &self.padding,
            self.packet_counter,
            payload,
            &records,
            &boundaries,
        );

        // Each boundary segment must become its own TLS record to reproduce
        // upstream's record-size shaping (upstream emits N distinct conn.Write
        // calls = N TLS records). The std TLS writer packs all buffered
        // cleartext up to max_ciphertext_inner_record_len into one record on
        // flush, so we must flush after each segment to force a record boundary;
        // writeAll alone would coalesce everything into a single large record
        // and defeat the shaping a DPI observer is meant to see.
        var prev: usize = 0;
        for (boundaries.items) |end| {
            // Skip zero-length segments: they carry no bytes and an empty
            // writer.flush() would not seal a record anyway.
            if (end > prev) {
                try conn.tls_client.writer.writeAll(records.items[prev..end]);
                try conn.tls_client.writer.flush();
            }
            prev = end;
        }
        // flushTlsAndSocket also pushes the underlying socket writer; the
        // per-boundary writer.flush() calls only sealed TLS records into the
        // socket write buffer.
        try flushTlsAndSocket(conn);
    }

    fn initTlsConnection(self: *Session, stream: net.Stream) !*TlsConnection {
        const conn = try self.allocator.create(TlsConnection);
        errdefer self.allocator.destroy(conn);
        errdefer if (conn.ca_bundle) |*ca_bundle| ca_bundle.deinit(self.allocator);

        conn.stream = stream;
        conn.ca_bundle = null;
        conn.ca_lock = .init;
        conn.socket_read_buffer = undefined;
        conn.socket_write_buffer = undefined;
        conn.tls_read_buffer = undefined;
        conn.tls_write_buffer = undefined;
        conn.stream_reader = conn.stream.reader(&conn.socket_read_buffer);
        conn.stream_writer = conn.stream.writer(&conn.socket_write_buffer);
        conn.tls_client = undefined;

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        compat.randomBytes(&entropy);
        const now = std.Io.Timestamp.now(compat.io(), .real);
        const effective_host = self.tlsHost();
        // For IP-literal targets there is no hostname to send or match: emitting
        // the IP as SNI produces an abnormal ClientHello (a strong DPI
        // fingerprint) and violates the AnyTLS URI contract. std TLS couples SNI
        // omission to .no_verification, which only disables HOSTNAME verification
        // (correct for an IP). The CA-chain verification configured below via
        // .ca = .{ .bundle = ... } when skip_cert_verify is false is UNAFFECTED.
        var options = tls.Client.Options{
            .host = if (shouldOmitSni(effective_host))
                .{ .no_verification = {} }
            else
                .{ .explicit = effective_host },
            .ca = .{ .no_verification = {} },
            // AnyTLS frames carry explicit lengths and sessions end via FIN
            // (cmd 3) / alert (cmd 5); a mid-frame TCP truncation still surfaces
            // as error.EndOfStream via readTlsExact. close_notify-truncation
            // protection is therefore redundant here, so we allow it.
            .allow_truncation_attacks = true,
            .read_buffer = &conn.tls_read_buffer,
            .write_buffer = &conn.tls_write_buffer,
            .entropy = &entropy,
            .realtime_now = now,
        };

        if (!self.config.skip_cert_verify) {
            conn.ca_bundle = .empty;
            if (conn.ca_bundle) |*bundle| {
                try bundle.rescan(self.allocator, compat.io(), now);
                options.ca = .{ .bundle = .{
                    .gpa = self.allocator,
                    .io = compat.io(),
                    .lock = &conn.ca_lock,
                    .bundle = bundle,
                } };
            }
        }

        conn.tls_client = tls.Client.init(
            &conn.stream_reader.interface,
            &conn.stream_writer.interface,
            options,
        ) catch |err| {
            if (conn.ca_bundle) |*ca_bundle| {
                ca_bundle.deinit(self.allocator);
                conn.ca_bundle = null;
            }
            return err;
        };

        return conn;
    }

    fn tlsHost(self: *const Session) []const u8 {
        return self.config.sni orelse self.config.address;
    }

    fn deinitTlsConnection(self: *Session, conn: *TlsConnection) void {
        _ = conn.tls_client.end() catch {};
        conn.stream.close();
        if (conn.ca_bundle) |*ca_bundle| {
            ca_bundle.deinit(self.allocator);
        }
        self.allocator.destroy(conn);
    }

    fn readFrameHeader(self: *Session) !FrameHeader {
        const conn = self.conn orelse return error.NotConnected;
        var header: [frame_header_len]u8 = undefined;
        try readTlsExact(&conn.tls_client.reader, &header);
        return .{
            .command = header[0],
            .stream_id = readU32(header[1..5]),
            .length = readU16(header[5..7]),
        };
    }

    fn readFrameData(self: *Session, length: u16) ![]u8 {
        if (length == 0) return &.{};
        const conn = self.conn orelse return error.NotConnected;
        const data = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(data);
        try readTlsExact(&conn.tls_client.reader, data);
        return data;
    }

    fn discardFrameData(self: *Session, length: u16) !void {
        if (length == 0) return;
        const conn = self.conn orelse return error.NotConnected;
        var remaining: usize = length;
        var scratch: [1024]u8 = undefined;
        while (remaining > 0) {
            const n = @min(remaining, scratch.len);
            try readTlsExact(&conn.tls_client.reader, scratch[0..n]);
            remaining -= n;
        }
    }

    /// Adopts a server-pushed padding scheme (cmdUpdatePaddingScheme, cmd 6).
    /// On successful parse, atomically replaces the active factory (freeing the
    /// old one) and logs adoption with the new md5; on parse failure keeps the
    /// existing factory and logs a warning.
    fn adoptPaddingScheme(self: *Session, data: []const u8) void {
        const next = PaddingFactory.init(self.allocator, data) catch {
            std.log.warn("anytls: rejected update_padding_scheme: invalid scheme (keeping current)", .{});
            return;
        };
        self.padding.deinit();
        self.padding = next;
        std.log.info("anytls: adopted padding scheme md5={s}", .{&self.padding.md5_hex});
    }

    fn applyServerSettings(self: *Session, data: []const u8) void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "v=")) {
                self.peer_version = std.fmt.parseInt(u8, line[2..], 10) catch self.peer_version;
                self.learned_version = true;
            }
        }
    }

    fn hasBufferedRead(self: *const Session) bool {
        if (self.conn) |conn| {
            return conn.tls_client.reader.bufferedLen() > 0 or
                conn.stream_reader.interface.bufferedLen() > 0;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // C2 multiplex API (recv-loop + Stream path). Cleanly separate from the
    // synchronous Client shim above: the shim never touches any of this.
    // -----------------------------------------------------------------------

    /// Heap-allocates and connects a multiplex Session: dial + TLS + auth, seed
    /// the recv-loop ref, then spawn the JOINABLE recv-loop. On any failure the
    /// half-built Session is fully torn down and the error propagates.
    pub fn open(allocator: std.mem.Allocator, config: Config, seq: u64) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = try Session.init(allocator, config);
        errdefer self.padding.deinit();
        self.seq = seq;

        try self.dial();
        // dial populated self.conn; from here teardown must close it.
        errdefer if (self.conn) |conn| self.deinitTlsConnection(conn);

        self.handshake_deadline_ms = std.Io.Timestamp.now(compat.io(), .awake).toMilliseconds() + 15_000;
        self.refs.store(1, .monotonic); // recv-loop ref
        self.recv_thread = try std.Thread.spawn(.{}, recvLoopEntry, .{self});
        return self;
    }

    /// True only when we have POSITIVELY learned the peer speaks anytls < v2
    /// (i.e. cmdServerSettings was observed with v < 2). An unknown/default
    /// peer_version (the conservative "treat as v2" case in §11) returns false,
    /// so the SYN-DONE wait is armed on reuse. `learned_version` is set by
    /// applyServerSettings; until then this is false.
    pub fn knownBelowV2(self: *Session) bool {
        return self.learned_version and self.peer_version < 2;
    }

    /// Allocates a sid, registers a fresh Stream under streams_mutex, and
    /// pipelines the open frames (settings+syn+psh on the first stream of the
    /// session, syn+psh on a reused session). Returns the borrowed Stream (the
    /// caller holds the relay-borrow ref). On write failure escalates (§9).
    pub fn openStream(self: *Session, target_host: []const u8, target_port: u16) !*Stream {
        const sid = self.next_stream_id.fetchAdd(1, .monotonic) + 1;
        const first = (sid == 1);

        const stream = try Stream.create(self, sid);
        // Until the map put transfers ownership this is the ONLY cleanup; once
        // `registered`, unregisterStreamOnOpenFail (below) takes over. The guard
        // ensures the two errdefers never BOTH run on a post-put error — that
        // would free the Stream twice (unregister drops the last ref and frees,
        // then destroyNow runs on freed memory → UAF/double-free).
        var registered = false;
        errdefer if (!registered) stream.destroyNow();

        self.lockStreams();
        if (self.dying.load(.acquire)) {
            self.unlockStreams();
            return error.SessionDying;
        }
        // On put failure unlock before returning (the errdefer frees the stream);
        // a bare `try` here would leak streams_mutex.
        self.streams.put(self.allocator, sid, stream) catch |e| {
            self.unlockStreams();
            return e;
        };
        self.unlockStreams();
        // session-ref for this stream (paired with the map-presence ref already
        // baked into Stream.create's refs=2). This ref's lifetime is bound to
        // the Stream STRUCT: owns_session_ref marks it so releaseStreamRef drops
        // it exactly once when the Stream is finally freed (UAF fix).
        _ = self.refs.fetchAdd(1, .monotonic);
        stream.owns_session_ref = true;
        registered = true;

        // From here a failure must unregister + drop both refs the stream owns.
        errdefer self.unregisterStreamOnOpenFail(stream);

        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);

        if (first) {
            const settings = try buildSettings(self.allocator, &self.padding.md5_hex);
            defer self.allocator.free(settings);
            try appendFrame(self.allocator, &payload, .settings, 0, settings);
        }
        try appendFrame(self.allocator, &payload, .syn, sid, "");
        const socks_addr = try encodeSocksAddr(self.allocator, target_host, target_port);
        defer self.allocator.free(socks_addr);
        try appendFrame(self.allocator, &payload, .psh, sid, socks_addr);

        self.writeSessionPayload(payload.items) catch |e| {
            // The shared stream is desynced; the session is unusable.
            self.requestClose(.write_error);
            return e;
        };

        return stream;
    }

    /// Rolls back a stream registration when openStream fails AFTER the map put.
    /// Mirrors the ownership rule in Stream.close: only the evictor of the map
    /// entry drops the map-presence ref, so if requestClose (e.g. the write-error
    /// path) already evicted this stream we must NOT drop it again. The
    /// per-stream Session-ref is NOT dropped here: it is bound to the Stream
    /// struct and travels out in releaseStreamRef's last-ref branch when the
    /// Stream frees (UAF fix). The relay-borrow ref is always dropped here
    /// because the caller receives an error and therefore never calls
    /// Stream.close (the only other dropper of the relay-borrow ref); a
    /// never-handed-out stream must be fully freed — and that final
    /// releaseStreamRef is what drops the Session-ref. Used only on the error
    /// path, never on normal close.
    fn unregisterStreamOnOpenFail(self: *Session, stream: *Stream) void {
        self.lockStreams();
        const removed = self.streams.fetchRemove(stream.id) != null;
        self.unlockStreams();
        if (removed) {
            stream.releaseStreamRef(); // drop map-presence ref
        }
        stream.releaseStreamRef(); // drop relay-borrow ref (always) -> frees Stream -> drops Session-ref
    }

    /// Fragments `data` into <=65535-byte cmdPSH frames. Any write error means
    /// the session is desynced -> caller escalates (Stream.write does).
    fn writeDataFrame(self: *Session, sid: u32, data: []const u8) !void {
        var offset: usize = 0;
        if (data.len == 0) return;
        while (offset < data.len) {
            const n = @min(data.len - offset, max_frame_data_len);
            try self.sendFrame(.psh, sid, data[offset..][0..n]);
            offset += n;
        }
    }

    /// Best-effort per-stream FIN. Errors ignored (peer/session may be gone).
    fn sendFin(self: *Session, sid: u32) void {
        self.sendFrame(.fin, sid, "") catch {};
    }

    /// Removes a stream from the map on explicit close. Returns whether the map
    /// entry was present (so the caller drops the map-presence ref) and whether
    /// the session is dying. Single-active bookkeeping is implicit.
    fn streamClosed(self: *Session, sid: u32) struct { dropped_map: bool, dying: bool } {
        self.lockStreams();
        defer self.unlockStreams();
        const dropped = self.streams.fetchRemove(sid) != null;
        return .{ .dropped_map = dropped, .dying = self.dying.load(.acquire) };
    }

    /// THREAD ENTRY for the recv-loop. Reads + demuxes frames from the TLS
    /// connection until EndOfStream, then ensures requestClose ran and drops the
    /// recv-loop ref.
    fn recvLoopEntry(self: *Session) void {
        var src = TlsFrameSource{ .session = self };
        self.recvLoop(src.source());
        self.requestClose(.eof); // idempotent
        self.releaseRef(); // drop recv-loop ref
    }

    /// Test-only seam (C7): spawn the REAL recv-loop on a JOINABLE thread over an
    /// injected FrameSource, bypassing only the TLS frame DECODE (everything else
    /// — demux, dispatch, the production exit cleanup of requestClose(.eof) +
    /// releaseRef — is the production code path). This lets the C7 concurrency/e2e
    /// tests drive a genuine recv-loop thread (running concurrently with
    /// Stream.close, putIdle, the reaper, etc.) over a non-TLS in-memory frame
    /// transport, surfacing races the synchronous dispatchFrame seam cannot.
    ///
    /// The caller seeds the recv-loop ref (refs == 1) and owns the FrameSource's
    /// backing context for the lifetime of the loop. The spawned thread is stored
    /// in `recv_thread` so the pool's reapClose/deinit/onOpenFail JOIN it exactly
    /// like a production session — i.e. the SAME join protocol (§13) is exercised.
    /// NOT for production use (the production entry is `recvLoopEntry` via `open`).
    pub fn testSpawnRecvLoop(
        self: *Session,
        ctx: *anyopaque,
        nextFn: *const fn (ctx: *anyopaque) anyerror!DecodedFrame,
    ) !void {
        const Injected = struct {
            session: *Session,
            ctx: *anyopaque,
            nextFn: *const fn (ctx: *anyopaque) anyerror!DecodedFrame,
            fn entry(arg: *@This()) void {
                const session = arg.session;
                const fs = FrameSource{ .ctx = arg.ctx, .nextFn = arg.nextFn };
                // Free the heap arg BEFORE running the loop so the recv-loop's
                // own exit (which may finalize the Session) leaves nothing dangling.
                const a = session.allocator;
                const owned = arg;
                a.destroy(owned);
                session.recvLoop(fs);
                session.requestClose(.eof); // idempotent — production exit cleanup
                session.releaseRef(); // drop recv-loop ref
            }
        };
        const arg = try self.allocator.create(Injected);
        errdefer self.allocator.destroy(arg);
        arg.* = .{ .session = self, .ctx = ctx, .nextFn = nextFn };
        self.recv_thread = try std.Thread.spawn(.{}, Injected.entry, .{arg});
    }

    /// The demux pump. Drains frames from `fs` (the seam tests drive in-memory),
    /// handling the deferred heart-response at the top of each iteration BEFORE
    /// reading the next frame so tls_mutex is never recursively held.
    fn recvLoop(self: *Session, fs: FrameSource) void {
        while (true) {
            if (self.heart_pending.swap(false, .acq_rel)) {
                self.sendFrame(.heart_response, 0, "") catch {};
            }
            const frame = fs.next() catch break; // EndOfStream / WouldYield-as-EOF
            self.dispatchFrame(frame);
            self.allocator.free(frame.owned_body);
        }
    }

    /// Handles exactly one decoded frame. Factored out so tests can drive it via
    /// a scripted FrameSource without a TLS handshake.
    fn dispatchFrame(self: *Session, frame: DecodedFrame) void {
        const command = commandFromByte(frame.command) orelse return; // unknown -> ignore
        const body = frame.owned_body;
        switch (command) {
            .psh => {
                if (body.len == 0) return;
                self.lockStreams();
                const s = self.streams.get(frame.stream_id);
                // Take a transient ref WHILE holding streams_mutex so a concurrent
                // Stream.close() on the relay thread cannot free the Stream in the
                // window between unlock and the deref below (§8 UAF safety).
                if (s) |stream| _ = stream.refs.fetchAdd(1, .acq_rel);
                self.unlockStreams();
                if (s) |stream| {
                    stream.appendInbound(body); // copies under buf_mutex
                    stream.releaseStreamRef(); // drop transient ref
                }
            },
            .fin => {
                self.lockStreams();
                const entry = self.streams.fetchRemove(frame.stream_id);
                self.unlockStreams();
                if (entry) |kv| {
                    kv.value.markEof();
                    // The map remover drops the map-presence ref. The per-stream
                    // Session-ref is NOT dropped here: it is bound to the Stream
                    // struct and is released in releaseStreamRef when the Stream
                    // finally frees (UAF fix) — which, if the relay still holds
                    // the relay-borrow ref, happens only after Stream.close.
                    kv.value.releaseStreamRef(); // drop map-presence ref
                }
            },
            .syn_ack => {
                self.lockStreams();
                const s = self.streams.get(frame.stream_id);
                // Transient ref under streams_mutex, same UAF rationale as .psh.
                if (s) |stream| _ = stream.refs.fetchAdd(1, .acq_rel);
                self.unlockStreams();
                if (s) |stream| {
                    stream.markSynAck(body.len > 0);
                    stream.releaseStreamRef(); // drop transient ref
                }
                self.handshake_deadline_ms = 0; // handshake complete
            },
            .alert => {
                var alert_buf: [max_alert_log_len]u8 = undefined;
                const text = sanitizeAlertText(&alert_buf, body);
                std.log.err("anytls: server alert: {s}", .{text});
                self.requestClose(.alert);
            },
            .server_settings => {
                // peer_version is read by openStream's arming decision (C4) and
                // is otherwise leaf state; guard under tls_mutex for consistency
                // with the writer that may race on a reused session.
                self.lockTls();
                defer self.unlockTls();
                self.applyServerSettings(body);
                self.handshake_deadline_ms = 0; // handshake complete
            },
            .update_padding_scheme => {
                // padding is read by writeSessionPayload under tls_mutex; the
                // adoption must take the same lock (§16) so a concurrent shaped
                // write never sees a half-swapped factory.
                self.lockTls();
                defer self.unlockTls();
                self.adoptPaddingScheme(body);
            },
            .heart_request => self.heart_pending.store(true, .release),
            .waste, .settings, .heart_response, .syn => {}, // discard
        }
    }

    /// External/internal death trigger. Idempotent; the loser of the cmpxchg
    /// returns immediately. Sets dying, wakes every live stream with an error,
    /// and self-closes the TLS socket to unblock the recv-loop's fillMore.
    pub fn requestClose(self: *Session, reason: CloseReason) void {
        if (self.die_once.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;

        // §12 die-hook: a dying session must leave the pool FIRST (remove from
        // idle + all) so no concurrent createStream/reaper can resurrect it.
        // evict takes pool.mutex and holds NO session lock (lock order §16).
        if (self.pool) |p| p.evict(self);

        const err: anyerror = switch (reason) {
            .alert => error.AnyTlsAlert,
            .write_error => error.StreamClosed,
            .syn_timeout => error.AnyTlsSynTimeout,
            else => error.SessionClosed,
        };

        // Snapshot + clear the streams map under streams_mutex. Reserve capacity
        // for the whole map FIRST (still under the lock) so the per-entry append
        // below cannot OOM and silently drop a stream from the wake/eviction set
        // — a dropped stream would keep its map-presence ref forever (leak) and
        // never be woken. If ensureTotalCapacity itself OOMs we fall back to the
        // best-effort append loop and the catch documents the residual risk.
        self.lockStreams();
        self.dying.store(true, .release);
        var snapshot = std.ArrayList(*Stream).empty;
        snapshot.ensureTotalCapacity(self.allocator, self.streams.count()) catch {};
        var it = self.streams.iterator();
        while (it.next()) |e| snapshot.append(self.allocator, e.value_ptr.*) catch {
            // OOM with capacity reserved is unreachable; should the reserve above
            // have failed, this drops a stream from the eviction set (it keeps its
            // map-presence ref / is never woken). Accepted as a last-resort path.
        };
        self.streams.clearRetainingCapacity();
        self.unlockStreams();

        for (snapshot.items) |stream| {
            stream.markErr(err); // wakes blocked relays
            // Drop only the map-presence ref. The per-stream Session-ref is bound
            // to the Stream struct: if the relay still holds the relay-borrow ref
            // the Stream survives here (and so does its Session-ref), and the
            // Session-ref is dropped later in releaseStreamRef when the Stream is
            // finally freed by the relay's Stream.close (UAF fix).
            stream.releaseStreamRef(); // drop map-presence ref
        }
        snapshot.deinit(self.allocator);

        // Close the TLS socket to unblock the recv-loop's poll/fillMore.
        self.lockTls();
        if (self.conn) |conn| {
            _ = conn.tls_client.end() catch {};
            conn.stream.close();
        }
        self.unlockTls();
    }

    /// Drops a session-ref; on the last ref, finalize: free padding, conn,
    /// config-owned state, and the Session itself.
    pub fn releaseRef(self: *Session) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.finalize();
    }

    fn finalize(self: *Session) void {
        self.padding.deinit();
        self.streams.deinit(self.allocator);
        if (self.pool_key.len > 0) self.allocator.free(self.pool_key);
        if (self.conn) |conn| {
            // requestClose already ran end()+close() under tls_mutex; here we
            // only free the heap struct + CA bundle.
            if (conn.ca_bundle) |*ca_bundle| ca_bundle.deinit(self.allocator);
            self.allocator.destroy(conn);
            self.conn = null;
        }
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// deinit for a Session opened via `open` (multiplex): requestClose then JOIN
    /// the recv-loop before any free, so no detached thread touches freed memory.
    /// The recv-loop's exit drops the last ref and finalizes. If no recv_thread
    /// was ever spawned (init-only Session), fall back to the synchronous deinit.
    pub fn deinitMultiplex(self: *Session) void {
        if (self.recv_thread) |t| {
            self.requestClose(.shutdown);
            t.join(); // recv-loop exit -> releaseRef -> finalize frees self
        } else {
            self.deinit();
            self.allocator.destroy(self);
        }
    }
};

pub const CloseReason = enum { eof, alert, write_error, syn_timeout, shutdown, discard, reaped, open_error, canceled };

/// A decoded frame handed to `dispatchFrame`. `owned_body` is heap-allocated by
/// the FrameSource and freed by the recv-loop after dispatch.
/// Public so the C7 test seam (`Session.testSpawnRecvLoop`) can construct frames
/// from another module's in-memory fake-server source.
pub const DecodedFrame = struct {
    command: u8,
    stream_id: u32,
    owned_body: []u8,
};

/// The recv-loop reads frames through this seam. The production source decodes
/// from the TLS connection (poll-before-lock, §4); tests inject a scripted
/// in-memory source. `next` returns error.EndOfStream to end the loop.
const FrameSource = struct {
    ctx: *anyopaque,
    nextFn: *const fn (ctx: *anyopaque) anyerror!DecodedFrame,

    fn next(self: FrameSource) anyerror!DecodedFrame {
        return self.nextFn(self.ctx);
    }
};

/// Production FrameSource: poll-before-lock read of the TLS connection.
const TlsFrameSource = struct {
    session: *Session,
    recv_poll_timeout_ms: i32 = 1000,

    fn source(self: *TlsFrameSource) FrameSource {
        return .{ .ctx = self, .nextFn = nextImpl };
    }

    fn nextImpl(ctx: *anyopaque) anyerror!DecodedFrame {
        const self: *TlsFrameSource = @ptrCast(@alignCast(ctx));
        const session = self.session;
        while (true) {
            if (session.die_once.load(.acquire)) return error.EndOfStream;

            // Step 1 (§4): poll the socket with NO lock held, unless ciphertext
            // is already buffered in the TLS/socket reader (then go straight to
            // decode under the lock).
            session.lockTls();
            // Only consider DECRYPTED application data for the buffered check.
            // Raw TLS ciphertext in stream_reader (e.g. NewSessionTicket records)
            // must NOT skip the poll path: TLS will consume those records
            // internally without producing application data, and then block on
            // readTlsExact waiting for more data that the server may never send.
            const buffered = if (session.conn) |conn|
                conn.tls_client.reader.bufferedLen() > 0
            else
                false;
            session.unlockTls();

            if (!buffered) {
                const fd = blk: {
                    session.lockTls();
                    defer session.unlockTls();
                    const conn = session.conn orelse return error.EndOfStream;
                    break :blk conn.stream.handle;
                };
                var fds = [_]std.posix.pollfd{.{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const before_poll_ms = compat.monotonicMilliTimestamp();
                const heartbeat_deadline_ms = std.math.add(
                    i64,
                    before_poll_ms,
                    self.recv_poll_timeout_ms,
                ) catch std.math.maxInt(i64);
                const poll_deadline_ms = if (session.handshake_deadline_ms > 0)
                    @min(heartbeat_deadline_ms, session.handshake_deadline_ms)
                else
                    heartbeat_deadline_ms;
                const ready = compat.pollUntil(&fds, poll_deadline_ms) catch
                    return error.EndOfStream;
                if (ready == 0) {
                    // Handshake deadline: if the server hasn't sent a valid
                    // protocol frame (server_settings / syn_ack) within the
                    // deadline, tear down the session so the relay doesn't hang.
                    const now_ms = compat.monotonicMilliTimestamp();
                    if (session.handshake_deadline_ms > 0 and
                        now_ms >= session.handshake_deadline_ms)
                    {
                        // Shut down the socket to unblock the main thread which
                        // may be holding tls_mutex while blocked in send() inside
                        // flushTlsAndSocket -> writeSessionPayload. Without this
                        // shutdown, requestClose(.eof) in recvLoopEntry would
                        // deadlock waiting on tls_mutex while the main thread is
                        // stuck in send() and never releases the lock.
                        _ = std.c.shutdown(fd, std.c.SHUT.RDWR);
                        return error.EndOfStream;
                    }
                    continue; // timeout: re-check dying, re-poll
                }
                if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0 and
                    (fds[0].revents & std.posix.POLL.IN) == 0)
                {
                    // peer hung up with no pending data
                    return error.EndOfStream;
                }
            }

            // Step 2-3 (§4): take tls_mutex, decode exactly ONE frame. (One frame
            // per call keeps the seam simple; the loop re-polls between frames.)
            session.lockTls();
            defer session.unlockTls();
            if (session.conn == null) return error.EndOfStream;

            const header = session.readFrameHeader() catch return error.EndOfStream;
            const body = session.readFrameData(header.length) catch return error.EndOfStream;
            // readFrameData returns &.{} for length==0 (not heap); normalize so
            // the recv-loop can always free owned_body.
            const owned: []u8 = if (header.length == 0)
                session.allocator.alloc(u8, 0) catch return error.EndOfStream
            else
                body;
            return .{ .command = header.command, .stream_id = header.stream_id, .owned_body = owned };
        }
    }
};

/// One logical multiplexed stream on a Session. Owns a level-triggered Notifier
/// the relay polls, an inbound byte buffer the recv-loop fills, and terminal
/// eof/err state. Ref-counted by two independent owners: the map-presence ref
/// (held while in `session.streams`) and the relay-borrow ref (held by the
/// ProxyStream from creation to close). The struct frees only when both drop
/// (§8) — this is what makes the recv-loop's `appendInbound` UAF-safe.
pub const Stream = struct {
    session: *Session,
    id: u32,
    notifier: compat.Notifier,

    buf: std.ArrayListUnmanaged(u8) = .empty,
    buf_off: usize = 0,
    /// Guards buf/buf_off/eof/err. Leaf lock (§16).
    buf_mutex: std.Io.Mutex = .init,
    eof: bool = false,
    err: ?anyerror = null,

    // SYN-DONE state (§11). Fields only in C2; the full bounded wait is C4. The
    // recv-loop sets these on cmdSYNACK so the relay's read still surfaces a
    // rejection immediately via the notifier.
    syn_state: u32 = 0, // 0 unacked, 1 acked-ok, 2 rejected/err
    syn_deadline_ms: i64 = 0,

    refs: std.atomic.Value(u8) = .init(2), // map-presence ref + relay-borrow ref
    closed: bool = false, // set by close() on the relay side
    write_shut: bool = false, // set by shutdownWrite (idempotent half-close)
    /// True once a per-stream Session-ref has been added on behalf of THIS
    /// Stream (in Session.openStream / testRegisterStream, right after the
    /// fetchAdd that adds it). That Session-ref lives exactly as long as the
    /// Stream STRUCT: it is dropped EXACTLY ONCE, in releaseStreamRef's
    /// last-ref branch when the Stream is finally freed. This couples the
    /// Session-ref's lifetime to the Stream's actual free so the Session can
    /// never finalize while a Stream still points at it (UAF fix). Stays false
    /// for a never-registered Stream (destroyNow path), which owns no
    /// Session-ref and must not drop one.
    owns_session_ref: bool = false,

    fn lockBuf(self: *Stream) void {
        std.Io.Threaded.mutexLock(&self.buf_mutex);
    }

    fn unlockBuf(self: *Stream) void {
        std.Io.Threaded.mutexUnlock(&self.buf_mutex);
    }

    /// Allocates a Stream with refs=2 (map-presence + relay-borrow). On any
    /// failure nothing is leaked.
    fn create(session: *Session, id: u32) !*Stream {
        const self = try session.allocator.create(Stream);
        errdefer session.allocator.destroy(self);
        self.* = .{
            .session = session,
            .id = id,
            .notifier = try compat.Notifier.init(),
        };
        return self;
    }

    /// Frees a never-registered Stream (refs still 2, no map/relay ownership
    /// transferred). Used only on the openStream allocation/registration error
    /// path before any ref was handed out.
    fn destroyNow(self: *Stream) void {
        const allocator = self.session.allocator;
        self.notifier.deinit();
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }

    /// Drops one ref; on the last ref free the Stream (buf + notifier). A
    /// buf_mutex acquire/release barrier guarantees no `appendInbound` is
    /// mid-flight at free time (§7). If this Stream owns a per-stream
    /// Session-ref it travels out WITH the struct: it is dropped LAST, after
    /// the Stream is freed, so the Session can outlive every Stream that points
    /// at it and only finalize once the last such Stream is gone (UAF fix).
    /// Capture session + allocator + owns into locals BEFORE destroy, since
    /// destroy invalidates `self`, and `session.releaseRef()` may finalize the
    /// Session (freeing it) so it must be the very last thing we touch.
    fn releaseStreamRef(self: *Stream) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.lockBuf();
            self.unlockBuf(); // barrier: drain any in-flight appendInbound
            const session = self.session;
            const allocator = session.allocator;
            const owns = self.owns_session_ref;
            self.notifier.deinit();
            self.buf.deinit(allocator);
            allocator.destroy(self);
            // self is now invalid; only the captured locals are safe.
            if (owns) session.releaseRef(); // may finalize the Session — LAST
        }
    }

    // ---- recv-loop producer side ----

    /// recv-loop: append inbound PSH bytes (copied) then raise readiness.
    fn appendInbound(self: *Stream, bytes: []const u8) void {
        self.lockBuf();
        self.buf.appendSlice(self.session.allocator, bytes) catch {
            // OOM on the inbound path: surface as a terminal error so the relay
            // tears down rather than silently dropping bytes.
            if (self.err == null) self.err = error.OutOfMemory;
            self.eof = true;
            self.unlockBuf();
            self.notifier.signal();
            return;
        };
        self.unlockBuf();
        self.notifier.signal();
    }

    /// recv-loop: peer FIN OR session death (clean half/full close).
    fn markEof(self: *Stream) void {
        self.lockBuf();
        self.eof = true;
        self.unlockBuf();
        self.notifier.signal();
    }

    /// recv-loop: terminal error (alert / rejection / death). First error wins.
    fn markErr(self: *Stream, e: anyerror) void {
        self.lockBuf();
        if (self.err == null) self.err = e;
        self.eof = true;
        self.unlockBuf();
        self.notifier.signal();
    }

    /// recv-loop: cmdSYNACK demux. Records the syn_state and, on rejection,
    /// surfaces error.AnyTlsStreamRejected through the read path.
    fn markSynAck(self: *Stream, rejected: bool) void {
        if (rejected) {
            // Set err/eof FIRST so a SYN-DONE waiter that observes syn_state==2
            // (release/acquire) is guaranteed to see a non-null stream.err.
            self.markErr(error.AnyTlsStreamRejected);
            @atomicStore(u32, &self.syn_state, 2, .release);
        } else {
            @atomicStore(u32, &self.syn_state, 1, .release);
            self.notifier.signal();
        }
        // Wake the bounded SYN-DONE futex waiter in createStream (§11). Harmless
        // when no one is waiting (sid==1 path or non-armed reuse).
        compat.io().futexWake(u32, &self.syn_state, 1);
    }

    /// Test-only seam: drive the recv-loop's cmdSYNACK demux from another module
    /// (anytls_pool.zig's C4 SYN-DONE tests) without a real TLS recv-loop.
    pub fn testMarkSynAck(self: *Stream, rejected: bool) void {
        self.markSynAck(rejected);
    }

    /// Test-only seam: drive the recv-loop's inbound producer side from another
    /// module (manager.zig's C5 delegation tests) without a real TLS recv-loop.
    pub fn testAppendInbound(self: *Stream, bytes: []const u8) void {
        self.appendInbound(bytes);
    }

    /// Test-only seam: drive the recv-loop's peer-FIN/EOF from another module.
    pub fn testMarkEof(self: *Stream) void {
        self.markEof();
    }

    // ---- relay consumer side (single-threaded per stream) ----

    /// Drains buffered bytes; on empty buffer surfaces terminal err/eof. Returns
    /// error.WouldBlock on a spurious wake (empty + no terminal). The §6
    /// notifier-drain-vs-EOF invariant: drain ONLY when the buffer empties AND
    /// no terminal is pending, so a blocking poll always wakes for EOF/err.
    pub fn read(self: *Stream, out: []u8) !usize {
        self.lockBuf();
        defer self.unlockBuf();

        const available = self.buf.items.len - self.buf_off;
        if (available > 0) {
            const n = @min(out.len, available);
            @memcpy(out[0..n], self.buf.items[self.buf_off..][0..n]);
            self.buf_off += n;
            if (self.buf_off == self.buf.items.len) {
                self.buf.clearRetainingCapacity();
                self.buf_off = 0;
                // Keep the level HIGH if a terminal is still pending so the next
                // read's poll wakes for it; otherwise lower the level.
                if (!(self.eof or self.err != null)) self.notifier.drain();
            }
            return n;
        }
        if (self.err) |e| {
            self.notifier.drain();
            return e;
        }
        if (self.eof) {
            self.notifier.drain();
            return 0;
        }
        return error.WouldBlock;
    }

    /// Blocking read for the no-poll HttpsForward caller (§6, C5). Waits on the
    /// notifier until data/eof/err; NEVER returns WouldBlock.
    pub fn readBlocking(self: *Stream, out: []u8) !usize {
        while (true) {
            const n = self.read(out) catch |e| switch (e) {
                error.WouldBlock => {
                    var fds = [_]std.posix.pollfd{.{
                        .fd = self.notifier.handle(),
                        .events = std.posix.POLL.IN,
                        .revents = 0,
                    }};
                    _ = std.posix.poll(&fds, -1) catch {};
                    continue;
                },
                else => return e,
            };
            return n;
        }
    }

    /// Relay write: fragment into PSH frames. On any write error escalate to
    /// session.requestClose(.write_error) and surface error.StreamClosed.
    pub fn write(self: *Stream, data: []const u8) !void {
        if (self.closed or self.session.dying.load(.acquire)) return error.StreamClosed;
        self.session.writeDataFrame(self.id, data) catch {
            self.session.requestClose(.write_error);
            return error.StreamClosed;
        };
    }

    /// Half-close: send a per-stream FIN, keep the read side open. Idempotent.
    pub fn shutdownWrite(self: *Stream) void {
        if (self.write_shut) return;
        self.write_shut = true;
        if (!self.session.dying.load(.acquire)) self.session.sendFin(self.id);
    }

    pub fn hasPendingRead(self: *Stream) bool {
        self.lockBuf();
        defer self.unlockBuf();
        return self.buf_off < self.buf.items.len;
    }

    pub fn getHandle(self: *Stream) std.posix.fd_t {
        return if (self.closed) -1 else self.notifier.handle();
    }

    /// Relay-driven explicit close (§8). Idempotent. Sends FIN, removes from the
    /// map (dropping the map-presence ref if still present), and finally drops
    /// the relay-borrow ref. The per-stream Session-ref is NOT dropped here: it
    /// is bound to the Stream struct and is released in releaseStreamRef when the
    /// Stream is finally freed — which, on this relay-borrow-ref drop being the
    /// last ref, happens right below (UAF fix).
    pub fn close(self: *Stream) void {
        if (self.closed) return;
        self.closed = true;

        const session = self.session;
        if (!session.dying.load(.acquire)) session.sendFin(self.id);

        const r = session.streamClosed(self.id);
        // The remover of the map entry drops the map-presence ref. If requestClose
        // (or a peer FIN) already evicted this stream it dropped the map-presence
        // ref, so we must NOT drop it again here.
        if (r.dropped_map) {
            self.releaseStreamRef(); // drop map-presence ref
        }

        // §8 return-to-idle: this stream is the session's single active stream, so
        // on a clean close (session NOT dying) hand the session back to its pool
        // for reuse. putIdle flips active_streams/in_idle under the pool mutex.
        // A non-pooled session (Client shim / stand-in) or a putIdle refusal
        // (shutting down / OOM on re-insert) means the session can never be
        // reused -> tear it down with requestClose(.discard) so its recv-loop +
        // TLS socket are reclaimed rather than orphaned. If d (already dying),
        // requestClose has already run; do nothing. This decision MUST happen
        // here, BEFORE the final releaseStreamRef below, because that drop may
        // free the Stream and release the per-stream Session-ref (the last ref to
        // a dead session), after which `session` is no longer safe to touch.
        if (!r.dying) {
            if (session.pool) |p| {
                if (!p.putIdle(session)) session.requestClose(.discard);
            } else {
                session.requestClose(.discard);
            }
        }

        // Drop the relay-borrow ref last. When this is the Stream's final ref,
        // releaseStreamRef frees the struct and then drops the per-stream
        // Session-ref (which may finalize the Session) — strictly after the
        // Stream that points at the Session is gone.
        self.releaseStreamRef(); // drop relay-borrow ref (always)
    }
};

/// Thin public shim preserving the exact pre-C1 Client API. It is exactly ONE
/// Session driving ONE logical stream (sid=1) with a SYNCHRONOUS read path —
/// no recv-loop, no streams map, no Notifier (those land in C2). All wire
/// behavior is byte-identical to the original Client.
pub const Client = struct {
    session: Session,
    stream_id: u32 = 0,
    stream_closed: bool = false,
    pending_read: ?[]u8 = null,
    pending_offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        return .{ .session = try Session.init(allocator, config) };
    }

    pub fn deinit(self: *Client) void {
        // Send the session-close FIN before freeing the padding factory:
        // sendFrame -> writeSessionPayload -> buildSessionRecords reads
        // padding, so it must remain live until no further frame is sent.
        if (!self.stream_closed and self.session.conn != null and self.stream_id != 0) {
            self.session.sendFrame(.fin, self.stream_id, "") catch {};
            self.stream_closed = true;
        }
        if (self.pending_read) |pending| {
            self.session.allocator.free(pending);
            self.pending_read = null;
        }
        self.session.deinit();
    }

    pub fn connect(self: *Client, target_host: []const u8, target_port: u16) !net.Stream {
        try self.session.dial();
        const conn = self.session.conn.?;

        self.stream_id = 1;
        self.stream_closed = false;

        // On failure, do NOT self-destruct here: the sole caller
        // (OutboundManager.connectToProxy .anytls) owns cleanup via
        // `errdefer client.deinit()`, mirroring the ss/trojan paths. Calling
        // self.deinit() here too would double-free the PaddingFactory (its
        // deinit sets self.* = undefined, so a second deinit frees freed memory).
        try self.session.openFirstStream(self.stream_id, target_host, target_port);

        return conn.stream;
    }

    pub fn write(self: *Client, data: []const u8) !void {
        if (self.stream_closed) return error.StreamClosed;
        if (self.session.conn == null) return error.NotConnected;

        var offset: usize = 0;
        while (offset < data.len) {
            const n = @min(data.len - offset, max_frame_data_len);
            try self.session.sendFrame(.psh, self.stream_id, data[offset..][0..n]);
            offset += n;
        }
    }

    pub fn read(self: *Client, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        if (self.stream_closed) return 0;
        if (self.session.conn == null) return error.NotConnected;

        if (self.consumePending(buf)) |n| return n;

        while (true) {
            const frame = try self.session.readFrameHeader();
            const command = commandFromByte(frame.command) orelse {
                try self.session.discardFrameData(frame.length);
                continue;
            };
            switch (command) {
                .psh => {
                    const data = try self.session.readFrameData(frame.length);
                    if (frame.stream_id != self.stream_id) {
                        if (data.len > 0) self.session.allocator.free(data);
                        continue;
                    }
                    if (data.len == 0) continue;
                    return self.copyFrameData(buf, data);
                },
                .fin => {
                    try self.session.discardFrameData(frame.length);
                    if (frame.stream_id == self.stream_id) {
                        self.stream_closed = true;
                        return 0;
                    }
                },
                .syn_ack => {
                    const data = try self.session.readFrameData(frame.length);
                    defer if (data.len > 0) self.session.allocator.free(data);
                    if (frame.stream_id == self.stream_id and data.len > 0) {
                        return error.AnyTlsStreamRejected;
                    }
                },
                .server_settings => {
                    const data = try self.session.readFrameData(frame.length);
                    defer if (data.len > 0) self.session.allocator.free(data);
                    self.session.applyServerSettings(data);
                },
                .alert => {
                    const data = try self.session.readFrameData(frame.length);
                    defer if (data.len > 0) self.session.allocator.free(data);
                    // The alert body is attacker-controlled and may be non-UTF8:
                    // bound the length and sanitize before logging.
                    var alert_buf: [max_alert_log_len]u8 = undefined;
                    const text = sanitizeAlertText(&alert_buf, data);
                    std.log.err("anytls: server alert: {s}", .{text});
                    self.stream_closed = true;
                    return error.AnyTlsAlert;
                },
                .update_padding_scheme => {
                    const data = try self.session.readFrameData(frame.length);
                    defer if (data.len > 0) self.session.allocator.free(data);
                    self.session.adoptPaddingScheme(data);
                },
                .waste, .settings => {
                    try self.session.discardFrameData(frame.length);
                },
                .heart_request => {
                    try self.session.discardFrameData(frame.length);
                    try self.session.sendFrame(.heart_response, frame.stream_id, "");
                },
                .heart_response, .syn => {
                    try self.session.discardFrameData(frame.length);
                },
            }
        }
    }

    pub fn hasPendingRead(self: *const Client) bool {
        if (self.pending_read) |pending| {
            if (self.pending_offset < pending.len) return true;
        }
        return self.session.hasBufferedRead();
    }

    fn consumePending(self: *Client, buf: []u8) ?usize {
        const pending = self.pending_read orelse return null;
        const remaining = pending[self.pending_offset..];
        const n = @min(buf.len, remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.pending_offset += n;
        if (self.pending_offset >= pending.len) {
            self.session.allocator.free(pending);
            self.pending_read = null;
            self.pending_offset = 0;
        }
        return n;
    }

    fn copyFrameData(self: *Client, buf: []u8, data: []u8) usize {
        if (data.len == 0) return 0;
        const n = @min(buf.len, data.len);
        @memcpy(buf[0..n], data[0..n]);
        if (n < data.len) {
            self.pending_read = data;
            self.pending_offset = n;
        } else {
            self.session.allocator.free(data);
        }
        return n;
    }
};

fn buildAuthRequest(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    const auth_len = 32 + 2 + default_padding0_len;
    const auth = try allocator.alloc(u8, auth_len);
    crypto.hash.sha2.Sha256.hash(password, auth[0..32], .{});
    writeU16(auth[32..34], default_padding0_len);
    @memset(auth[34..], 0);
    return auth;
}

/// Builds the cmdSettings body. `md5_hex` is the ACTIVE padding factory's md5
/// so negotiation always reflects the scheme the client will actually shape with.
fn buildSettings(allocator: std.mem.Allocator, md5_hex: *const [32]u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "v=2\n");
    try out.appendSlice(allocator, "client=zc/anytls\n");
    try out.appendSlice(allocator, "padding-md5=");
    try out.appendSlice(allocator, md5_hex);
    return try out.toOwnedSlice(allocator);
}

fn appendFrame(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    command: Command,
    stream_id: u32,
    data: []const u8,
) !void {
    if (data.len > max_frame_data_len) return error.FrameTooLarge;
    try out.append(allocator, @intFromEnum(command));

    var header: [6]u8 = undefined;
    writeU32(header[0..4], stream_id);
    writeU16(header[4..6], @intCast(data.len));
    try out.appendSlice(allocator, &header);
    try out.appendSlice(allocator, data);
}

pub fn encodeSocksAddr(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var ipv4: [4]u8 = undefined;
    if (parseIpv4(host, &ipv4)) {
        try out.append(allocator, 0x01);
        try out.appendSlice(allocator, &ipv4);
    } else {
        var ipv6: [16]u8 = undefined;
        if (parseIpv6(host, &ipv6)) {
            try out.append(allocator, 0x04);
            try out.appendSlice(allocator, &ipv6);
        } else {
            if (host.len > 255) return error.DomainTooLong;
            try out.append(allocator, 0x03);
            try out.append(allocator, @intCast(host.len));
            try out.appendSlice(allocator, host);
        }
    }

    try out.append(allocator, @intCast(port >> 8));
    try out.append(allocator, @intCast(port & 0xff));
    return try out.toOwnedSlice(allocator);
}

/// Builds the byte stream of TLS records for one logical write, appending the
/// concatenated record bytes into `records` and the cumulative end offset of
/// each record into `boundaries` (so tests can inspect per-record sizing). This
/// is the testable core of writeSessionPayload and faithfully implements
/// upstream writeConn for a given `pkt` and active `factory`.
fn buildSessionRecords(
    allocator: std.mem.Allocator,
    factory: *const PaddingFactory,
    pkt: u32,
    payload: []const u8,
    records: *std.ArrayList(u8),
    boundaries: *std.ArrayList(usize),
) !void {
    // Global stop: pkt >= stop -> no shaping, single unbounded record.
    if (pkt >= factory.stop) {
        try records.appendSlice(allocator, payload);
        try boundaries.append(allocator, records.items.len);
        return;
    }

    const segments = factory.segmentsFor(pkt);
    // No line for this index -> empty list -> fall through to final write.
    var b = payload;

    for (segments) |segment| {
        const l: usize = switch (segment) {
            .check_mark => {
                // CheckMark: if no payload remains, stop emitting the padding
                // tail; otherwise it is a pure no-op and we continue.
                if (b.len == 0) break;
                continue;
            },
            .range => |r| PaddingFactory.drawRangeSize(r),
        };

        if (b.len > l) {
            // (B) plenty of payload: one record of exactly l real bytes.
            try records.appendSlice(allocator, b[0..l]);
            try boundaries.append(allocator, records.items.len);
            b = b[l..];
        } else if (b.len > 0) {
            // (C) some payload but <= l: emit all remaining, pad up to l with a
            // cmdWaste frame only if l - len(b) - header > 0.
            try records.appendSlice(allocator, b);
            if (l > b.len + frame_header_len) {
                const padding_len = l - b.len - frame_header_len;
                try appendWasteFrame(allocator, records, @intCast(padding_len));
            }
            try boundaries.append(allocator, records.items.len);
            b = b[b.len..]; // b = nil
        } else {
            // (D) no payload left: standalone cmdWaste frame, data length = l
            // (wire size 7 + l). Asymmetric vs case (C) by design.
            try appendWasteFrame(allocator, records, @intCast(l));
            try boundaries.append(allocator, records.items.len);
        }
    }

    // (Step 4) flush any leftover real bytes in one final unbounded record.
    if (b.len > 0) {
        try records.appendSlice(allocator, b);
        try boundaries.append(allocator, records.items.len);
    }
}

/// Appends a cmdWaste(0) frame with stream_id=0 and `data_len` zero payload
/// bytes (wire size = frame_header_len + data_len). Reuses the verified waste
/// frame layout: cmd=0 | sid BE u32=0 | len BE u16=data_len | zeros.
fn appendWasteFrame(allocator: std.mem.Allocator, out: *std.ArrayList(u8), data_len: u16) !void {
    try appendFrame(allocator, out, .waste, 0, ZERO_PADDING[0..data_len]);
}

const ZERO_PADDING = [_]u8{0} ** max_frame_data_len;

fn commandFromByte(value: u8) ?Command {
    return switch (value) {
        0 => .waste,
        1 => .syn,
        2 => .psh,
        3 => .fin,
        4 => .settings,
        5 => .alert,
        6 => .update_padding_scheme,
        7 => .syn_ack,
        8 => .heart_request,
        9 => .heart_response,
        10 => .server_settings,
        else => null,
    };
}

fn flushTlsAndSocket(conn: *TlsConnection) !void {
    try conn.tls_client.writer.flush();
    try conn.stream_writer.interface.flush();
}

fn readTlsExact(reader: *std.Io.Reader, out: []u8) !void {
    var filled: usize = 0;
    while (filled < out.len) {
        while (reader.bufferedLen() == 0) {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                else => return err,
            };
        }

        const buffered = reader.buffered();
        const n = @min(out.len - filled, buffered.len);
        @memcpy(out[filled..][0..n], buffered[0..n]);
        reader.seek += n;
        filled += n;
    }
}

/// Copies up to `out.len` (and at most `max_alert_log_len`) bytes of an
/// untrusted server alert body into `out`, replacing any non-printable byte
/// with '?', and returns the sanitized slice. Bounds the logged length and
/// guarantees the result is safe to format with {s}.
fn sanitizeAlertText(out: *[max_alert_log_len]u8, data: []const u8) []const u8 {
    const n = @min(data.len, out.len);
    for (data[0..n], 0..) |byte, i| {
        out[i] = if (byte >= 0x20 and byte < 0x7f) byte else '?';
    }
    return out[0..n];
}

/// Returns true when `host` is an IPv4 or IPv6 literal, in which case SNI must
/// be omitted (an IP has no hostname to send or match). Used to select between
/// .no_verification (omit server_name) and .explicit (send hostname) for TLS.
fn shouldOmitSni(host: []const u8) bool {
    var ipv4: [4]u8 = undefined;
    if (parseIpv4(host, &ipv4)) return true;
    var ipv6: [16]u8 = undefined;
    if (parseIpv6(host, &ipv6)) return true;
    return false;
}

fn parseIpv4(str: []const u8, out: *[4]u8) bool {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var current: u16 = 0;
    var saw_digit = false;

    for (str) |c| {
        if (c == '.') {
            if (!saw_digit or part_idx >= 3) return false;
            parts[part_idx] = @intCast(current);
            part_idx += 1;
            current = 0;
            saw_digit = false;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
            if (current > 255) return false;
            saw_digit = true;
        } else {
            return false;
        }
    }

    if (!saw_digit or part_idx != 3) return false;
    parts[3] = @intCast(current);
    @memcpy(out, &parts);
    return true;
}

fn parseIpv6(str: []const u8, out: *[16]u8) bool {
    @memset(out, 0);

    if (std.mem.startsWith(u8, str, "::ffff:") or std.mem.startsWith(u8, str, "::FFFF:")) {
        const ipv4_part = str[7..];
        var ipv4: [4]u8 = undefined;
        if (!parseIpv4(ipv4_part, &ipv4)) return false;
        out[10] = 0xff;
        out[11] = 0xff;
        @memcpy(out[12..16], &ipv4);
        return true;
    }

    const double_colon = std.mem.indexOf(u8, str, "::");
    var parts: [8]u16 = undefined;
    @memset(&parts, 0);
    var part_count: usize = 0;

    if (double_colon) |dc_pos| {
        if (dc_pos > 0) {
            var it = std.mem.splitScalar(u8, str[0..dc_pos], ':');
            while (it.next()) |part| {
                if (part.len == 0 or part.len > 4 or part_count >= 8) return false;
                parts[part_count] = std.fmt.parseInt(u16, part, 16) catch return false;
                part_count += 1;
            }
        }

        const after = str[dc_pos + 2 ..];
        var after_parts: [8]u16 = undefined;
        var after_count: usize = 0;
        if (after.len > 0) {
            var it = std.mem.splitScalar(u8, after, ':');
            while (it.next()) |part| {
                if (part.len == 0 or part.len > 4 or after_count >= 8) return false;
                after_parts[after_count] = std.fmt.parseInt(u16, part, 16) catch return false;
                after_count += 1;
            }
        }

        if (part_count + after_count >= 8) return false;
        const zero_count = 8 - part_count - after_count;
        for (0..after_count) |i| {
            parts[part_count + zero_count + i] = after_parts[i];
        }
    } else {
        var it = std.mem.splitScalar(u8, str, ':');
        while (it.next()) |part| {
            if (part.len == 0 or part.len > 4 or part_count >= 8) return false;
            parts[part_count] = std.fmt.parseInt(u16, part, 16) catch return false;
            part_count += 1;
        }
        if (part_count != 8) return false;
    }

    for (0..8) |i| {
        out[i * 2] = @intCast(parts[i] >> 8);
        out[i * 2 + 1] = @intCast(parts[i] & 0xff);
    }
    return true;
}

fn readU16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn readU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

fn writeU16(out: []u8, value: u16) void {
    out[0] = @intCast(value >> 8);
    out[1] = @intCast(value & 0xff);
}

fn writeU32(out: []u8, value: u32) void {
    out[0] = @intCast(value >> 24);
    out[1] = @intCast((value >> 16) & 0xff);
    out[2] = @intCast((value >> 8) & 0xff);
    out[3] = @intCast(value & 0xff);
}

fn writeLowerHex(out: *[32]u8, bytes: *const [16]u8) void {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
}

test "AnyTLS auth request uses sha256 password and default padding0" {
    const allocator = std.testing.allocator;
    const auth = try buildAuthRequest(allocator, "secret");
    defer allocator.free(auth);

    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("secret", &expected_hash, .{});

    try std.testing.expectEqual(@as(usize, 64), auth.len);
    try std.testing.expectEqualSlices(u8, &expected_hash, auth[0..32]);
    try std.testing.expectEqual(@as(u8, 0), auth[32]);
    try std.testing.expectEqual(@as(u8, 30), auth[33]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 30), auth[34..64]);
}

test "AnyTLS frame encoding is command stream id length data" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendFrame(allocator, &out, .psh, 7, "abc");

    const expected = [_]u8{ 2, 0, 0, 0, 7, 0, 3, 'a', 'b', 'c' };
    try std.testing.expectEqualSlices(u8, &expected, out.items);
}

test "AnyTLS settings advertise protocol v2 and default padding md5" {
    const allocator = std.testing.allocator;
    var factory = try PaddingFactory.init(allocator, default_padding_scheme);
    defer factory.deinit();
    const settings = try buildSettings(allocator, &factory.md5_hex);
    defer allocator.free(settings);

    try std.testing.expect(std.mem.indexOf(u8, settings, "v=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "client=zc/anytls") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "padding-md5=75cff2ad89aadf5e257059ee571ebe11") != null);
}

test "AnyTLS treats unknown frame commands as ignorable" {
    try std.testing.expectEqual(@as(?Command, null), commandFromByte(255));
    try std.testing.expectEqual(Command.psh, commandFromByte(2).?);
}

test "AnyTLS omits SNI for IP-literal targets but keeps it for hostnames" {
    // IPv4 and IPv6 literals (including an IP passed via sni) must omit SNI.
    try std.testing.expect(shouldOmitSni("192.168.1.2"));
    try std.testing.expect(shouldOmitSni("8.8.8.8"));
    try std.testing.expect(shouldOmitSni("2001:db8::1"));
    try std.testing.expect(shouldOmitSni("::1"));
    try std.testing.expect(shouldOmitSni("::ffff:192.168.0.1"));

    // Hostnames must keep SNI.
    try std.testing.expect(!shouldOmitSni("example.com"));
    try std.testing.expect(!shouldOmitSni("anytls.example.org"));
    try std.testing.expect(!shouldOmitSni("localhost"));
}

test "AnyTLS sanitizes and bounds untrusted alert text" {
    var buf: [max_alert_log_len]u8 = undefined;

    const ascii = sanitizeAlertText(&buf, "auth failed");
    try std.testing.expectEqualStrings("auth failed", ascii);

    // Non-printable bytes are replaced with '?'.
    const mixed = sanitizeAlertText(&buf, &[_]u8{ 'a', 0x00, 'b', 0xff, '\n', 'c' });
    try std.testing.expectEqualStrings("a?b??c", mixed);

    // Over-long payload is bounded to max_alert_log_len.
    const long = [_]u8{'x'} ** (max_alert_log_len + 100);
    const bounded = sanitizeAlertText(&buf, &long);
    try std.testing.expectEqual(@as(usize, max_alert_log_len), bounded.len);
}

test "AnyTLS SocksAddr encoding matches sing-box serializer" {
    const allocator = std.testing.allocator;

    const domain = try encodeSocksAddr(allocator, "example.com", 443);
    defer allocator.free(domain);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x03, 11, 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm', 0x01, 0xbb,
    }, domain);

    const ipv4 = try encodeSocksAddr(allocator, "192.168.1.2", 8080);
    defer allocator.free(ipv4);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x01, 192, 168, 1, 2, 0x1f, 0x90,
    }, ipv4);

    const ipv6 = try encodeSocksAddr(allocator, "2001:db8::1", 53);
    defer allocator.free(ipv6);
    try std.testing.expectEqual(@as(u8, 0x04), ipv6[0]);
    try std.testing.expectEqual(@as(usize, 19), ipv6.len);
    try std.testing.expectEqual(@as(u8, 0x20), ipv6[1]);
    try std.testing.expectEqual(@as(u8, 0x01), ipv6[2]);
    try std.testing.expectEqual(@as(u8, 0x00), ipv6[17]);
    try std.testing.expectEqual(@as(u8, 0x35), ipv6[18]);
}

// ---------------------------------------------------------------------------
// Stage B: PaddingFactory + dynamic emit tests
// ---------------------------------------------------------------------------

test "AnyTLS PaddingFactory parses default scheme structure" {
    const allocator = std.testing.allocator;
    var f = try PaddingFactory.init(allocator, default_padding_scheme);
    defer f.deinit();

    try std.testing.expectEqual(@as(u32, 8), f.stop);

    // pkt 0 -> [30] fixed.
    const s0 = f.segmentsFor(0);
    try std.testing.expectEqual(@as(usize, 1), s0.len);
    try std.testing.expectEqual(@as(u32, 30), s0[0].range.min);
    try std.testing.expectEqual(@as(u32, 30), s0[0].range.max);

    // pkt 1 -> [100-400].
    const s1 = f.segmentsFor(1);
    try std.testing.expectEqual(@as(usize, 1), s1.len);
    try std.testing.expectEqual(@as(u32, 100), s1[0].range.min);
    try std.testing.expectEqual(@as(u32, 400), s1[0].range.max);

    // pkt 2 -> 9 segments: range, c, range, c, range, c, range, c, range.
    const s2 = f.segmentsFor(2);
    try std.testing.expectEqual(@as(usize, 9), s2.len);
    try std.testing.expectEqual(@as(u32, 400), s2[0].range.min);
    try std.testing.expectEqual(@as(u32, 500), s2[0].range.max);
    try std.testing.expect(s2[1] == .check_mark);
    try std.testing.expectEqual(@as(u32, 500), s2[2].range.min);
    try std.testing.expectEqual(@as(u32, 1000), s2[2].range.max);
    try std.testing.expect(s2[3] == .check_mark);
    try std.testing.expect(s2[5] == .check_mark);
    try std.testing.expect(s2[7] == .check_mark);
    try std.testing.expect(s2[8] == .range);

    // pkt 3 -> [9-9, 500-1000].
    const s3 = f.segmentsFor(3);
    try std.testing.expectEqual(@as(usize, 2), s3.len);
    try std.testing.expectEqual(@as(u32, 9), s3[0].range.min);
    try std.testing.expectEqual(@as(u32, 9), s3[0].range.max);
    try std.testing.expectEqual(@as(u32, 500), s3[1].range.min);
    try std.testing.expectEqual(@as(u32, 1000), s3[1].range.max);

    // pkt 7 -> [500-1000]; pkt 8 -> no line (empty).
    const s7 = f.segmentsFor(7);
    try std.testing.expectEqual(@as(usize, 1), s7.len);
    try std.testing.expectEqual(@as(usize, 0), f.segmentsFor(8).len);
}

test "AnyTLS PaddingFactory segment parsing edge cases" {
    const allocator = std.testing.allocator;

    // Table-driven: scheme value -> expected parsed segment kinds.
    const scheme =
        "stop=3\n" ++
        "0=30-30\n" ++ // fixed (min==max)
        "1=10-20,c,30-40\n" ++ // range, checkmark, range
        "2=5-1,c,0-0\n"; // 5-1 invalid(min>max) skipped, c, 0-0 fixed

    var f = try PaddingFactory.init(allocator, scheme);
    defer f.deinit();

    try std.testing.expectEqual(@as(u32, 3), f.stop);

    const s0 = f.segmentsFor(0);
    try std.testing.expectEqual(@as(usize, 1), s0.len);
    try std.testing.expectEqual(@as(u32, 30), s0[0].range.min);

    const s1 = f.segmentsFor(1);
    try std.testing.expectEqual(@as(usize, 3), s1.len);
    try std.testing.expect(s1[0] == .range);
    try std.testing.expect(s1[1] == .check_mark);
    try std.testing.expect(s1[2] == .range);

    // 5-1 is dropped (min>max); remaining are c and 0-0.
    const s2 = f.segmentsFor(2);
    try std.testing.expectEqual(@as(usize, 2), s2.len);
    try std.testing.expect(s2[0] == .check_mark);
    try std.testing.expectEqual(@as(u32, 0), s2[1].range.min);
    try std.testing.expectEqual(@as(u32, 0), s2[1].range.max);
}

test "AnyTLS PaddingFactory rejects malformed scheme (missing stop)" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPaddingScheme, PaddingFactory.init(allocator, "0=30-30\n1=100-400"));
    try std.testing.expectError(error.InvalidPaddingScheme, PaddingFactory.init(allocator, "stop=notanumber\n0=30-30"));
}

test "AnyTLS PaddingFactory md5 matches default and tracks active scheme" {
    const allocator = std.testing.allocator;
    var f = try PaddingFactory.init(allocator, default_padding_scheme);
    defer f.deinit();
    try std.testing.expectEqualStrings("75cff2ad89aadf5e257059ee571ebe11", &f.md5_hex);

    // A different scheme yields a different md5 (hash of exact raw bytes).
    var g = try PaddingFactory.init(allocator, "stop=2\n0=1-1");
    defer g.deinit();
    try std.testing.expect(!std.mem.eql(u8, &f.md5_hex, &g.md5_hex));
}

// Test-only frame walker: decodes a record byte stream into frames and
// concatenates the payload of all non-waste frames, asserting well-formed
// framing along the way.
const DecodedFrames = struct {
    real_payload: std.ArrayList(u8),
    waste_count: usize,

    fn deinit(self: *DecodedFrames, allocator: std.mem.Allocator) void {
        self.real_payload.deinit(allocator);
    }
};

fn decodeFrames(allocator: std.mem.Allocator, bytes: []const u8) !DecodedFrames {
    var real = std.ArrayList(u8).empty;
    errdefer real.deinit(allocator);
    var waste_count: usize = 0;

    var i: usize = 0;
    while (i < bytes.len) {
        try std.testing.expect(bytes.len - i >= frame_header_len); // well-formed header
        const frame_start = i;
        const cmd = bytes[i];
        const len = readU16(bytes[i + 5 .. i + 7]);
        i += frame_header_len;
        try std.testing.expect(bytes.len - i >= len); // well-formed body
        const body = bytes[i .. i + len];
        i += len;
        if (cmd == @intFromEnum(Command.waste)) {
            waste_count += 1;
            // waste body must be all zeros.
            for (body) |z| try std.testing.expectEqual(@as(u8, 0), z);
        } else {
            // Preserve the FULL frame bytes (header + body) so non-waste frames
            // concatenate back to the original logical payload exactly.
            try real.appendSlice(allocator, bytes[frame_start..i]);
        }
    }
    return .{ .real_payload = real, .waste_count = waste_count };
}

test "AnyTLS writeSessionPayload preserves real framing across records (wire-compat)" {
    const allocator = std.testing.allocator;
    var f = try PaddingFactory.init(allocator, default_padding_scheme);
    defer f.deinit();

    // Build a representative logical payload: a real PSH frame the relay depends on.
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    const app_data = "the quick brown fox jumps over the lazy dog" ** 30; // ~1290 bytes
    try appendFrame(allocator, &payload, .psh, 1, app_data);

    // Exercise shaped packets 1..7.
    var pkt: u32 = 1;
    while (pkt < f.stop) : (pkt += 1) {
        var records = std.ArrayList(u8).empty;
        defer records.deinit(allocator);
        var boundaries = std.ArrayList(usize).empty;
        defer boundaries.deinit(allocator);

        try buildSessionRecords(allocator, &f, pkt, payload.items, &records, &boundaries);

        // (a)+(b): decoding yields well-formed framing whose real frames
        // concatenate EXACTLY to the original logical payload.
        var decoded = try decodeFrames(allocator, records.items);
        defer decoded.deinit(allocator);
        try std.testing.expectEqualSlices(u8, payload.items, decoded.real_payload.items);

        // At least one record was produced.
        try std.testing.expect(boundaries.items.len >= 1);
    }
}

test "AnyTLS writeSessionPayload respects scheme sizing and stop" {
    const allocator = std.testing.allocator;
    var f = try PaddingFactory.init(allocator, default_padding_scheme);
    defer f.deinit();

    // Small payload + pkt 1 (100-400): with data <= target, exactly one record
    // is produced, padded up to the drawn target via a waste frame.
    {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(allocator);
        try appendFrame(allocator, &payload, .psh, 1, "hi"); // 9 bytes total

        var records = std.ArrayList(u8).empty;
        defer records.deinit(allocator);
        var boundaries = std.ArrayList(usize).empty;
        defer boundaries.deinit(allocator);

        try buildSessionRecords(allocator, &f, 1, payload.items, &records, &boundaries);
        try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
        // record size in [len(payload), 400) — padded toward a 100..399 target.
        const sz = boundaries.items[0];
        try std.testing.expect(sz >= payload.items.len);
        try std.testing.expect(sz < 400);

        var decoded = try decodeFrames(allocator, records.items);
        defer decoded.deinit(allocator);
        try std.testing.expectEqualSlices(u8, payload.items, decoded.real_payload.items);
    }

    // pkt >= stop (8): no shaping, single record equal to the raw payload.
    {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(allocator);
        try appendFrame(allocator, &payload, .psh, 1, "data beyond stop");

        var records = std.ArrayList(u8).empty;
        defer records.deinit(allocator);
        var boundaries = std.ArrayList(usize).empty;
        defer boundaries.deinit(allocator);

        try buildSessionRecords(allocator, &f, 8, payload.items, &records, &boundaries);
        try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
        try std.testing.expectEqualSlices(u8, payload.items, records.items);
    }

    // Index with no line (pkt 8 already > stop) — verify the empty-list path
    // directly using a custom scheme where an index in-range has no line.
    {
        var g = try PaddingFactory.init(allocator, "stop=5\n1=100-100");
        defer g.deinit();
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(allocator);
        try appendFrame(allocator, &payload, .psh, 1, "no-line-index");

        var records = std.ArrayList(u8).empty;
        defer records.deinit(allocator);
        var boundaries = std.ArrayList(usize).empty;
        defer boundaries.deinit(allocator);

        // pkt 2 has no line and pkt < stop -> single unbounded final record.
        try buildSessionRecords(allocator, &g, 2, payload.items, &records, &boundaries);
        try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
        try std.testing.expectEqualSlices(u8, payload.items, records.items);
    }
}

test "AnyTLS CheckMark short-circuits padding-only tail when data exhausted" {
    const allocator = std.testing.allocator;
    var f = try PaddingFactory.init(allocator, default_padding_scheme);
    defer f.deinit();

    // pkt 2: 400-500,c,500-1000,c,... A small payload (<= first target 400-499)
    // is consumed in the first (mixed) record; the next CheckMark sees no data
    // and BREAKS, so NO pure-padding tail records appear.
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    try appendFrame(allocator, &payload, .psh, 1, "small"); // 12 bytes total

    var records = std.ArrayList(u8).empty;
    defer records.deinit(allocator);
    var boundaries = std.ArrayList(usize).empty;
    defer boundaries.deinit(allocator);

    try buildSessionRecords(allocator, &f, 2, payload.items, &records, &boundaries);
    // Exactly one record: the first range consumed all data; the following 'c'
    // broke the loop before any 500-1000 padding-only record was emitted.
    try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);

    var decoded = try decodeFrames(allocator, records.items);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualSlices(u8, payload.items, decoded.real_payload.items);
}

test "AnyTLS randomized record sizes differ across writes within ranges" {
    const allocator = std.testing.allocator;
    var f = try PaddingFactory.init(allocator, default_padding_scheme);
    defer f.deinit();

    // Large payload + pkt 2 so multiple range records are produced.
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    const big = "x" ** 5000;
    try appendFrame(allocator, &payload, .psh, 1, big);

    // Collect the per-record boundary sizes for two independent writes.
    var seqs: [2][]usize = undefined;
    for (0..2) |k| {
        var records = std.ArrayList(u8).empty;
        defer records.deinit(allocator);
        var boundaries = std.ArrayList(usize).empty;
        defer boundaries.deinit(allocator);
        try buildSessionRecords(allocator, &f, 2, payload.items, &records, &boundaries);

        // Per-record sizes from cumulative boundaries.
        var sizes = std.ArrayList(usize).empty;
        var prev: usize = 0;
        for (boundaries.items) |end| {
            try sizes.append(allocator, end - prev);
            prev = end;
        }
        seqs[k] = try sizes.toOwnedSlice(allocator);
        sizes.deinit(allocator);

        // First-record real-data size for pkt 2 lies in [400, 500).
        try std.testing.expect(seqs[k][0] >= 400 and seqs[k][0] < 500);
    }
    defer allocator.free(seqs[0]);
    defer allocator.free(seqs[1]);

    // Randomization: the two size sequences are not identical. (CSPRNG; the
    // chance of a full collision across multiple [400,500)/[500,1000) draws is
    // negligible.)
    const same_len = seqs[0].len == seqs[1].len;
    var identical = same_len;
    if (same_len) {
        for (seqs[0], seqs[1]) |a, b| {
            if (a != b) {
                identical = false;
                break;
            }
        }
    }
    try std.testing.expect(!identical);
}

test "AnyTLS oversized server padding range is clamped (no @intCast panic)" {
    const allocator = std.testing.allocator;

    // A malicious cmd-6 update_padding_scheme pushing a range far above u16.
    // parseSegments must clamp it to max_frame_data_len so the drawn size never
    // overflows the u16 waste-frame length narrowed by @intCast in cases C/D.
    var f = try PaddingFactory.init(allocator, "stop=8\n1=70000-70000");
    defer f.deinit();

    // Case (D): no real payload -> standalone waste frame of length l. With the
    // unclamped range (70000) the @intCast(l) would panic; clamped it is 65535.
    {
        var records = std.ArrayList(u8).empty;
        defer records.deinit(allocator);
        var boundaries = std.ArrayList(usize).empty;
        defer boundaries.deinit(allocator);
        try buildSessionRecords(allocator, &f, 1, &.{}, &records, &boundaries);
        // One pure-padding waste record of wire size header + 65535.
        try std.testing.expectEqual(@as(usize, 1), boundaries.items.len);
        try std.testing.expectEqual(
            @as(usize, frame_header_len + max_frame_data_len),
            records.items.len,
        );
    }

    // Case (C): some payload but <= clamped target -> data + waste padding.
    {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(allocator);
        try appendFrame(allocator, &payload, .psh, 1, "hi");

        var records = std.ArrayList(u8).empty;
        defer records.deinit(allocator);
        var boundaries = std.ArrayList(usize).empty;
        defer boundaries.deinit(allocator);
        try buildSessionRecords(allocator, &f, 1, payload.items, &records, &boundaries);

        // Real framing is preserved byte-exact despite the oversized range.
        var decoded = try decodeFrames(allocator, records.items);
        defer decoded.deinit(allocator);
        try std.testing.expectEqualSlices(u8, payload.items, decoded.real_payload.items);
    }
}

test "AnyTLS shaped write splits into multiple per-boundary records" {
    const allocator = std.testing.allocator;
    var f = try PaddingFactory.init(allocator, default_padding_scheme);
    defer f.deinit();

    // A large logical payload at a shaped pkt must split into MULTIPLE boundary
    // segments. writeSessionPayload flushes once per boundary, turning each into
    // a distinct TLS record (the record-size shaping fidelity vs upstream).
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    try appendFrame(allocator, &payload, .psh, 1, "y" ** 5000);

    var records = std.ArrayList(u8).empty;
    defer records.deinit(allocator);
    var boundaries = std.ArrayList(usize).empty;
    defer boundaries.deinit(allocator);
    try buildSessionRecords(allocator, &f, 2, payload.items, &records, &boundaries);

    // More than one record boundary -> per-boundary flush yields >1 TLS record.
    try std.testing.expect(boundaries.items.len > 1);
    // Every boundary segment is non-empty (writeSessionPayload skips empty ones,
    // but the default scheme should never produce a zero-length boundary here).
    var prev: usize = 0;
    for (boundaries.items) |end| {
        try std.testing.expect(end > prev);
        prev = end;
    }
}

// ===========================================================================
// C2: multiplex + demux + readiness tests
//
// These drive the recv-loop's per-frame dispatch through the FrameSource seam
// and the Stream readiness state machine WITHOUT a TLS handshake. All run under
// std.testing.allocator (leak detection) and join every spawned thread.
// ===========================================================================

const test_config = Config{ .password = "pw", .address = "127.0.0.1", .port = 443 };

/// Builds a heap Session with NO TLS connection and NO recv-loop thread, seeded
/// with one synthetic ref so tests can register streams and drive dispatch.
/// Tear down with `testDestroySession` (drops the synthetic ref -> finalize).
fn testMakeSession(allocator: std.mem.Allocator) !*Session {
    const self = try allocator.create(Session);
    errdefer allocator.destroy(self);
    self.* = try Session.init(allocator, test_config);
    self.refs.store(1, .monotonic); // stand-in for the recv-loop ref
    return self;
}

fn testDestroySession(session: *Session) void {
    // Mirror recv-loop exit: ensure death ran, then drop the synthetic ref.
    session.requestClose(.shutdown);
    session.releaseRef();
}

/// A scripted in-memory FrameSource: yields the queued frames in order, then
/// error.EndOfStream. Each body is duplicated onto the heap so the recv-loop's
/// `free(owned_body)` is symmetric with the production source.
const ScriptedSource = struct {
    allocator: std.mem.Allocator,
    frames: []const ScriptFrame,
    idx: usize = 0,

    const ScriptFrame = struct { command: Command, stream_id: u32, body: []const u8 };

    fn source(self: *ScriptedSource) FrameSource {
        return .{ .ctx = self, .nextFn = nextImpl };
    }

    fn nextImpl(ctx: *anyopaque) anyerror!DecodedFrame {
        const self: *ScriptedSource = @ptrCast(@alignCast(ctx));
        if (self.idx >= self.frames.len) return error.EndOfStream;
        const f = self.frames[self.idx];
        self.idx += 1;
        const owned = try self.allocator.dupe(u8, f.body);
        return .{ .command = @intFromEnum(f.command), .stream_id = f.stream_id, .owned_body = owned };
    }
};

/// Registers a freshly-created Stream under the session (map-presence +
/// relay-borrow refs from create, plus the per-stream session-ref bound to the
/// Stream struct). Mirrors Session.openStream: the session-ref is added here and
/// owns_session_ref is set so releaseStreamRef drops it exactly once when the
/// Stream struct is finally freed.
fn testRegisterStream(session: *Session, sid: u32) !*Stream {
    const stream = try Stream.create(session, sid);
    session.lockStreams();
    try session.streams.put(session.allocator, sid, stream);
    session.unlockStreams();
    _ = session.refs.fetchAdd(1, .monotonic); // session-ref for this stream
    stream.owns_session_ref = true; // lifetime bound to the Stream struct
    return stream;
}

fn pollReadable(fd: std.posix.fd_t) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, 0) catch return false;
    return ready > 0 and (fds[0].revents & std.posix.POLL.IN) != 0;
}

test "C2: readiness self-pipe level-trigger (append/read/re-poll)" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);
    const s = try testRegisterStream(session, 1);

    try std.testing.expect(!pollReadable(s.getHandle())); // fresh: not readable

    s.appendInbound("hello");
    try std.testing.expect(pollReadable(s.getHandle())); // readable after append

    var buf: [16]u8 = undefined;
    const n = try s.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, "hello", buf[0..5]);

    // Buffer drained, no terminal -> level low again.
    try std.testing.expect(!pollReadable(s.getHandle()));

    // Re-append -> readable again.
    s.appendInbound("x");
    try std.testing.expect(pollReadable(s.getHandle()));
    const m = try s.read(&buf);
    try std.testing.expectEqual(@as(usize, 1), m);

    s.close();
}

test "C2: buffer-empties-with-EOF invariant (the critical §6 case)" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);
    const s = try testRegisterStream(session, 1);

    // append bytes then mark eof (two signals; collapse to one readable level).
    s.appendInbound("abcd");
    s.markEof();
    try std.testing.expect(pollReadable(s.getHandle()));

    // First read returns ALL the bytes; notifier MUST stay readable (eof pending).
    var buf: [16]u8 = undefined;
    const n = try s.read(&buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(u8, "abcd", buf[0..4]);
    try std.testing.expect(pollReadable(s.getHandle())); // level still HIGH for eof

    // Next read returns 0 (eof) and now the poll has been satisfied/drained.
    const z = try s.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), z);
    try std.testing.expect(!pollReadable(s.getHandle()));

    s.close();
}

test "C2: syn-reject surfaces AnyTlsStreamRejected via dispatch" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);
    const s = try testRegisterStream(session, 1);

    // A cmdSYNACK with a non-empty body == rejection.
    var src = ScriptedSource{ .allocator = allocator, .frames = &.{
        .{ .command = .syn_ack, .stream_id = 1, .body = "rejected" },
    } };
    session.recvLoop(src.source());

    try std.testing.expectEqual(@as(u32, 2), @atomicLoad(u32, &s.syn_state, .acquire));
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.AnyTlsStreamRejected, s.read(&buf));

    s.close();
}

test "C2: WouldBlock on spurious wake (empty buffer, no terminal)" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);
    const s = try testRegisterStream(session, 1);

    // Manually raise the level without buffering data or a terminal -> read must
    // report WouldBlock (the relay then re-polls).
    s.notifier.signal();
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, s.read(&buf));

    s.close();
}

test "C2: multi-sid demux isolation (frames land only in their own stream)" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);

    const s1 = try testRegisterStream(session, 1);
    const s2 = try testRegisterStream(session, 2);
    const s3 = try testRegisterStream(session, 3);

    var src = ScriptedSource{
        .allocator = allocator,
        .frames = &.{
            .{ .command = .psh, .stream_id = 1, .body = "one" },
            .{ .command = .psh, .stream_id = 2, .body = "twotwo" },
            .{ .command = .psh, .stream_id = 3, .body = "three!" },
            .{ .command = .psh, .stream_id = 1, .body = "-1again" },
            .{ .command = .psh, .stream_id = 99, .body = "orphan-dropped" }, // no such stream
        },
    };
    session.recvLoop(src.source());

    var buf: [32]u8 = undefined;
    const n1 = try s1.read(&buf);
    try std.testing.expectEqualSlices(u8, "one-1again", buf[0..n1]);
    const n2 = try s2.read(&buf);
    try std.testing.expectEqualSlices(u8, "twotwo", buf[0..n2]);
    const n3 = try s3.read(&buf);
    try std.testing.expectEqualSlices(u8, "three!", buf[0..n3]);

    s1.close();
    s2.close();
    s3.close();
}

test "C2: FIN demux marks eof + removes from map" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);
    const s = try testRegisterStream(session, 1);

    var src = ScriptedSource{ .allocator = allocator, .frames = &.{
        .{ .command = .psh, .stream_id = 1, .body = "tail" },
        .{ .command = .fin, .stream_id = 1, .body = "" },
    } };
    session.recvLoop(src.source());

    // Stream removed from the map by FIN.
    session.lockStreams();
    const present = session.streams.get(1) != null;
    session.unlockStreams();
    try std.testing.expect(!present);

    // Bytes still delivered, then eof.
    var buf: [16]u8 = undefined;
    const n = try s.read(&buf);
    try std.testing.expectEqualSlices(u8, "tail", buf[0..n]);
    try std.testing.expect(pollReadable(s.getHandle())); // eof level high
    try std.testing.expectEqual(@as(usize, 0), try s.read(&buf));

    s.close(); // dropped_map=false now (FIN already removed it) -> only relay ref
}

test "C2: session-death (requestClose) wakes ALL streams; no leak, refs released" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    // No testDestroySession here: requestClose is the death; we close streams.

    const s1 = try testRegisterStream(session, 1);
    const s2 = try testRegisterStream(session, 2);

    s1.appendInbound("buffered"); // pending data must still be drainable... not after death? death marks err.

    session.requestClose(.alert);

    // Both streams woken; their polls fire and reads surface the terminal error.
    try std.testing.expect(pollReadable(s1.getHandle()));
    try std.testing.expect(pollReadable(s2.getHandle()));

    var buf: [16]u8 = undefined;
    // s1 had buffered bytes appended BEFORE death: read drains them first.
    const n1 = try s1.read(&buf);
    try std.testing.expectEqualSlices(u8, "buffered", buf[0..n1]);
    // Then the terminal error.
    try std.testing.expectError(error.AnyTlsAlert, s1.read(&buf));
    // s2 had nothing buffered: terminal error immediately.
    try std.testing.expectError(error.AnyTlsAlert, s2.read(&buf));

    // The map was cleared by death.
    session.lockStreams();
    const empty = session.streams.count() == 0;
    try std.testing.expect(session.dying.load(.acquire));
    session.unlockStreams();
    try std.testing.expect(empty);

    // Relays close: dropped_map=false (death evicted them) -> only the relay
    // ref drops. Death dropped the map-presence ref but, under the NEW model, NOT
    // the per-stream session-ref — that one is bound to the Stream struct and is
    // dropped now, as the relay-borrow drop frees each Stream (releaseStreamRef
    // drops it LAST). So at this point the Session still holds: 1 synthetic ref +
    // 1 session-ref per still-living Stream. The two close()es free the Streams
    // and return their session-refs; the synthetic drop below frees the Session.
    // The leak detector validates each Stream is freed exactly once.
    s1.close();
    s2.close();
    session.releaseRef(); // drop the synthetic recv-loop stand-in ref -> finalize
}

test "C2: write-error escalates to requestClose; session marked dying" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    // session has no conn -> writeSessionPayload returns NotConnected.
    const s = try testRegisterStream(session, 1);

    try std.testing.expectError(error.StreamClosed, s.write("payload"));
    try std.testing.expect(session.die_once.load(.acquire));

    session.lockStreams();
    try std.testing.expect(session.dying.load(.acquire));
    session.unlockStreams();

    // After death the stream surfaces the terminal error and the map was cleared.
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.StreamClosed, s.read(&buf));

    s.close();
    session.releaseRef(); // synthetic ref -> finalize
}

test "C2: openStream registration-error rollback frees the stream (no leak)" {
    // Mirrors the openStream failure path AFTER the map put but BEFORE any error
    // escalation (e.g. an OOM in buildSettings/appendFrame/encodeSocksAddr). The
    // stream is still in the map, so unregisterStreamOnOpenFail drops the
    // map-presence ref AND the relay-borrow ref (the caller gets an error and
    // never calls Stream.close). The relay-borrow drop is the Stream's last ref,
    // so the struct frees and — under the NEW ref model — releaseStreamRef drops
    // the per-stream session-ref LAST as part of that free. Net: after rollback
    // the session-ref has returned to its pre-registration count and the Stream
    // is fully freed (a surviving relay-borrow ref would leak it; a double-drop
    // would underflow the Session refcount). std.testing.allocator validates.
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);

    const stream = try testRegisterStream(session, 1); // refs=2, +1 session-ref
    const refs_before = session.refs.load(.acquire);

    session.unregisterStreamOnOpenFail(stream); // rollback (stream still in map)

    // The session-ref returns to its pre-registration count — but now it is
    // dropped by the Stream's free (releaseStreamRef), not by unregister itself.
    try std.testing.expectEqual(refs_before - 1, session.refs.load(.acquire));
    session.lockStreams();
    try std.testing.expect(session.streams.get(1) == null);
    session.unlockStreams();
    // If the relay-borrow ref were NOT dropped, the Stream would leak here.
}

test "C2: openStream write-error rollback after eviction drops only relay ref (no UAF)" {
    // Mirrors openStream's write-error path: writeSessionPayload fails ->
    // requestClose(.write_error) evicts the just-registered stream. Under the NEW
    // ref model requestClose drops ONLY the map-presence ref; the per-stream
    // session-ref stays alive, bound to the still-living Stream struct (the
    // relay-borrow ref keeps the struct alive). The errdefer then runs
    // unregisterStreamOnOpenFail, which finds the stream already out of the map
    // and so drops ONLY the relay-borrow ref. That is the Stream's last ref:
    // releaseStreamRef frees the struct and THEN drops the per-stream session-ref
    // exactly once. No double-release, no UAF. The leak detector validates the
    // Stream is freed exactly once and the Session refcount stays balanced.
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);

    const stream = try testRegisterStream(session, 1); // refs=2, +1 session-ref
    const refs_after_register = session.refs.load(.acquire);

    // requestClose evicts the stream: drops ONLY the map-presence ref, marks
    // dying, clears the map. The stream now holds only its relay-borrow ref, and
    // its per-stream session-ref is STILL alive (not dropped at eviction).
    session.requestClose(.write_error);
    try std.testing.expectEqual(@as(u8, 1), stream.refs.load(.acquire));
    // The session-ref survives eviction (this is the UAF fix): refcount unchanged
    // by requestClose's per-stream handling.
    try std.testing.expectEqual(refs_after_register, session.refs.load(.acquire));

    // errdefer rollback: stream no longer in map (removed == false), so only the
    // relay-borrow ref drops -> Stream frees -> session-ref dropped LAST.
    session.unregisterStreamOnOpenFail(stream); // frees the Stream exactly here.
    try std.testing.expectEqual(refs_after_register - 1, session.refs.load(.acquire));

    // The synthetic recv-loop stand-in ref is the only Session ref left.
    session.releaseRef(); // -> finalize, no UAF
}

test "C3b: requestClose-then-relay-close cannot UAF the Session (regression)" {
    // Reproduces the original HIGH UAF and proves it fixed. OLD model: the
    // per-stream Session-ref was dropped at MAP-REMOVAL time (in requestClose),
    // decoupled from the Stream struct's actual free. The relay still held the
    // Stream via its relay-borrow ref. Once the only other Session-ref (the
    // synthetic recv-loop stand-in) was gone, Session.refs hit 0 and finalize()
    // FREED the Session while the relay's Stream still pointed at it; the relay's
    // Stream.close() then dereferenced the freed Session (sendFin/streamClosed/
    // releaseRef) -> UAF.
    //
    // NEW model: requestClose drops only the map-presence ref; the per-stream
    // Session-ref is bound to the Stream struct and survives. The Session CANNOT
    // finalize while the Stream is alive. Only when the relay's close() drops the
    // last Stream ref does releaseStreamRef free the Stream and THEN drop the
    // Session-ref, finalizing the Session exactly once, strictly after the Stream
    // is gone. Run under std.testing.allocator: any UAF/double-free/leak fails.
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator); // refs=1 (synthetic stand-in)

    const s = try testRegisterStream(session, 1); // refs=2 (session-ref + stand-in)
    try std.testing.expectEqual(@as(u32, 2), session.refs.load(.acquire));
    try std.testing.expectEqual(@as(u8, 2), s.refs.load(.acquire)); // map + relay

    // Death: drops the map-presence ref (Stream.refs 2 -> 1, relay-borrow only)
    // and clears the map. The per-stream Session-ref is NOT dropped here.
    session.requestClose(.shutdown);
    try std.testing.expectEqual(@as(u8, 1), s.refs.load(.acquire));

    // CRITICAL: drop the synthetic stand-in NOW, simulating the recv-loop ref
    // going away while the relay still holds the Stream. Under the OLD model this
    // would have finalized the Session (refs would be 1 -> 0 had the session-ref
    // already been dropped). Under the NEW model the Stream still owns a
    // Session-ref, so refs goes 2 -> 1 and the Session stays ALIVE.
    session.releaseRef();
    try std.testing.expectEqual(@as(u32, 1), session.refs.load(.acquire));

    // The relay now closes its Stream. Stream.close dereferences session
    // (sendFin / streamClosed) — this is the exact deref that UAF'd before — then
    // drops the last Stream ref. releaseStreamRef frees the Stream and finally
    // drops the per-stream Session-ref, taking Session.refs 1 -> 0 and finalizing
    // the Session exactly ONCE, only after the Stream is gone.
    s.close();
    // No assertions on `session` after this point: it is now freed (validated by
    // the leak detector: exactly one Session alloc, exactly one free, no UAF).
}

test "C2: openStream write failure runs both errdefers without double-free" {
    // Drives the REAL openStream() into a write failure (conn == null ->
    // writeSessionPayload returns error.NotConnected AFTER the map put), so the
    // stacked errdefers actually execute. Before the `registered` guard, the
    // create-only destroyNow errdefer AND unregisterStreamOnOpenFail both fired
    // and double-freed the Stream. Under std.testing.allocator a double-free /
    // leak / UAF fails the test; a clean error return passes.
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);

    try std.testing.expectError(error.NotConnected, session.openStream("example.com", 443));

    // The stream was rolled back: map empty and the per-stream session-ref was
    // returned (only the recv-loop stand-in ref remains).
    session.lockStreams();
    try std.testing.expect(session.streams.count() == 0);
    session.unlockStreams();
    try std.testing.expectEqual(@as(u32, 1), session.refs.load(.acquire));
}

test "C2: hasPendingRead true while buffered, false after drain" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);
    const s = try testRegisterStream(session, 1);

    try std.testing.expect(!s.hasPendingRead());
    s.appendInbound("data");
    try std.testing.expect(s.hasPendingRead());

    var buf: [16]u8 = undefined;
    _ = try s.read(&buf);
    try std.testing.expect(!s.hasPendingRead());

    s.close();
}

test "C2: readBlocking returns data then 0 on eof (never WouldBlock)" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);
    const s = try testRegisterStream(session, 1);

    // Producer thread appends then marks eof after the consumer is likely blocked.
    const Producer = struct {
        fn run(stream: *Stream) void {
            stream.appendInbound("blocking-bytes");
            stream.markEof();
        }
    };
    var t = try std.Thread.spawn(.{}, Producer.run, .{s});
    defer t.join();

    var buf: [32]u8 = undefined;
    const n = try s.readBlocking(&buf);
    try std.testing.expect(n > 0);
    // Drain remaining + eof.
    var total = n;
    while (total < "blocking-bytes".len) {
        total += try s.readBlocking(buf[0..]);
    }
    try std.testing.expectEqual(@as(usize, 0), try s.readBlocking(&buf)); // eof

    s.close();
}

test "C2: shutdownWrite is idempotent and keeps read side open" {
    const allocator = std.testing.allocator;
    const session = try testMakeSession(allocator);
    defer testDestroySession(session);
    const s = try testRegisterStream(session, 1);

    // No conn -> sendFin's writeSessionPayload errors but is swallowed
    // (best-effort). shutdownWrite must not panic and must be idempotent.
    s.shutdownWrite();
    try std.testing.expect(s.write_shut);
    s.shutdownWrite(); // no-op second call

    // Read side remains usable: append + read still work.
    s.appendInbound("still-reading");
    var buf: [32]u8 = undefined;
    const n = try s.read(&buf);
    try std.testing.expectEqualSlices(u8, "still-reading", buf[0..n]);

    s.close();
}
