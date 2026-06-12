const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const crypto = std.crypto;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;
const socket_options = @import("../socket_options.zig");

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

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    password_hash: [32]u8,
    tls_conn: ?*TlsConnection = null,
    stream_id: u32 = 0,
    stream_closed: bool = false,
    peer_version: u8 = 1,
    packet_counter: u32 = 0,
    pending_read: ?[]u8 = null,
    pending_offset: usize = 0,
    /// Active padding scheme. Seeded from default_padding_scheme in init() and
    /// atomically replaced when the server pushes cmdUpdatePaddingScheme (cmd 6).
    padding: PaddingFactory,

    const TlsConnection = struct {
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

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
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

    pub fn deinit(self: *Client) void {
        // Send the session-close FIN before freeing the padding factory:
        // sendFrame -> writeSessionPayload -> buildSessionRecords reads
        // self.padding, so it must remain live until no further frame is sent.
        if (!self.stream_closed and self.tls_conn != null and self.stream_id != 0) {
            self.sendFrame(.fin, self.stream_id, "") catch {};
            self.stream_closed = true;
        }
        self.padding.deinit();
        if (self.pending_read) |pending| {
            self.allocator.free(pending);
            self.pending_read = null;
        }
        if (self.tls_conn) |conn| {
            _ = conn.tls_client.end() catch {};
            conn.stream.close();
            if (conn.ca_bundle) |*ca_bundle| {
                ca_bundle.deinit(self.allocator);
            }
            self.allocator.destroy(conn);
            self.tls_conn = null;
        }
    }

    pub fn connect(self: *Client, target_host: []const u8, target_port: u16) !net.Stream {
        if (self.tls_conn != null) return error.AlreadyConnected;

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

        self.tls_conn = conn;
        conn_owned_by_self = true;
        self.stream_id = 1;
        self.stream_closed = false;

        self.openStream(target_host, target_port) catch |err| {
            self.deinit();
            return err;
        };

        return conn.stream;
    }

    pub fn write(self: *Client, data: []const u8) !void {
        if (self.stream_closed) return error.StreamClosed;
        if (self.tls_conn == null) return error.NotConnected;

        var offset: usize = 0;
        while (offset < data.len) {
            const n = @min(data.len - offset, max_frame_data_len);
            try self.sendFrame(.psh, self.stream_id, data[offset..][0..n]);
            offset += n;
        }
    }

    pub fn read(self: *Client, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        if (self.stream_closed) return 0;
        if (self.tls_conn == null) return error.NotConnected;

        if (self.consumePending(buf)) |n| return n;

        while (true) {
            const frame = try self.readFrameHeader();
            const command = commandFromByte(frame.command) orelse {
                try self.discardFrameData(frame.length);
                continue;
            };
            switch (command) {
                .psh => {
                    const data = try self.readFrameData(frame.length);
                    if (frame.stream_id != self.stream_id) {
                        if (data.len > 0) self.allocator.free(data);
                        continue;
                    }
                    if (data.len == 0) continue;
                    return self.copyFrameData(buf, data);
                },
                .fin => {
                    try self.discardFrameData(frame.length);
                    if (frame.stream_id == self.stream_id) {
                        self.stream_closed = true;
                        return 0;
                    }
                },
                .syn_ack => {
                    const data = try self.readFrameData(frame.length);
                    defer if (data.len > 0) self.allocator.free(data);
                    if (frame.stream_id == self.stream_id and data.len > 0) {
                        return error.AnyTlsStreamRejected;
                    }
                },
                .server_settings => {
                    const data = try self.readFrameData(frame.length);
                    defer if (data.len > 0) self.allocator.free(data);
                    self.applyServerSettings(data);
                },
                .alert => {
                    const data = try self.readFrameData(frame.length);
                    defer if (data.len > 0) self.allocator.free(data);
                    // The alert body is attacker-controlled and may be non-UTF8:
                    // bound the length and sanitize before logging.
                    var alert_buf: [max_alert_log_len]u8 = undefined;
                    const text = sanitizeAlertText(&alert_buf, data);
                    std.log.err("anytls: server alert: {s}", .{text});
                    self.stream_closed = true;
                    return error.AnyTlsAlert;
                },
                .update_padding_scheme => {
                    const data = try self.readFrameData(frame.length);
                    defer if (data.len > 0) self.allocator.free(data);
                    self.adoptPaddingScheme(data);
                },
                .waste, .settings => {
                    try self.discardFrameData(frame.length);
                },
                .heart_request => {
                    try self.discardFrameData(frame.length);
                    try self.sendFrame(.heart_response, frame.stream_id, "");
                },
                .heart_response, .syn => {
                    try self.discardFrameData(frame.length);
                },
            }
        }
    }

    pub fn hasPendingRead(self: *const Client) bool {
        if (self.pending_read) |pending| {
            if (self.pending_offset < pending.len) return true;
        }
        if (self.tls_conn) |conn| {
            return conn.tls_client.reader.bufferedLen() > 0 or
                conn.stream_reader.interface.bufferedLen() > 0;
        }
        return false;
    }

    fn openStream(self: *Client, target_host: []const u8, target_port: u16) !void {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);

        const settings = try buildSettings(self.allocator, &self.padding.md5_hex);
        defer self.allocator.free(settings);
        try appendFrame(self.allocator, &payload, .settings, 0, settings);
        try appendFrame(self.allocator, &payload, .syn, self.stream_id, "");

        const socks_addr = try encodeSocksAddr(self.allocator, target_host, target_port);
        defer self.allocator.free(socks_addr);
        try appendFrame(self.allocator, &payload, .psh, self.stream_id, socks_addr);

        try self.writeSessionPayload(payload.items);
    }

    fn sendFrame(self: *Client, command: Command, stream_id: u32, data: []const u8) !void {
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
    fn writeSessionPayload(self: *Client, payload: []const u8) !void {
        const conn = self.tls_conn orelse return error.NotConnected;
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

    fn initTlsConnection(self: *Client, stream: net.Stream) !*TlsConnection {
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

    fn tlsHost(self: *const Client) []const u8 {
        return self.config.sni orelse self.config.address;
    }

    fn deinitTlsConnection(self: *Client, conn: *TlsConnection) void {
        _ = conn.tls_client.end() catch {};
        conn.stream.close();
        if (conn.ca_bundle) |*ca_bundle| {
            ca_bundle.deinit(self.allocator);
        }
        self.allocator.destroy(conn);
    }

    const FrameHeader = struct {
        command: u8,
        stream_id: u32,
        length: u16,
    };

    fn readFrameHeader(self: *Client) !FrameHeader {
        const conn = self.tls_conn orelse return error.NotConnected;
        var header: [frame_header_len]u8 = undefined;
        try readTlsExact(&conn.tls_client.reader, &header);
        return .{
            .command = header[0],
            .stream_id = readU32(header[1..5]),
            .length = readU16(header[5..7]),
        };
    }

    fn readFrameData(self: *Client, length: u16) ![]u8 {
        if (length == 0) return &.{};
        const conn = self.tls_conn orelse return error.NotConnected;
        const data = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(data);
        try readTlsExact(&conn.tls_client.reader, data);
        return data;
    }

    fn discardFrameData(self: *Client, length: u16) !void {
        if (length == 0) return;
        const conn = self.tls_conn orelse return error.NotConnected;
        var remaining: usize = length;
        var scratch: [1024]u8 = undefined;
        while (remaining > 0) {
            const n = @min(remaining, scratch.len);
            try readTlsExact(&conn.tls_client.reader, scratch[0..n]);
            remaining -= n;
        }
    }

    fn consumePending(self: *Client, buf: []u8) ?usize {
        const pending = self.pending_read orelse return null;
        const remaining = pending[self.pending_offset..];
        const n = @min(buf.len, remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.pending_offset += n;
        if (self.pending_offset >= pending.len) {
            self.allocator.free(pending);
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
            self.allocator.free(data);
        }
        return n;
    }

    /// Adopts a server-pushed padding scheme (cmdUpdatePaddingScheme, cmd 6).
    /// On successful parse, atomically replaces the active factory (freeing the
    /// old one) and logs adoption with the new md5; on parse failure keeps the
    /// existing factory and logs a warning.
    ///
    /// NOTE: manager.zig builds a fresh Client per outbound connection, so an
    /// adopted scheme currently lives only for the lifetime of THIS connection.
    /// Cross-connection persistence arrives with session pooling in a later stage.
    fn adoptPaddingScheme(self: *Client, data: []const u8) void {
        const next = PaddingFactory.init(self.allocator, data) catch {
            std.log.warn("anytls: rejected update_padding_scheme: invalid scheme (keeping current)", .{});
            return;
        };
        self.padding.deinit();
        self.padding = next;
        std.log.info("anytls: adopted padding scheme md5={s}", .{&self.padding.md5_hex});
    }

    fn applyServerSettings(self: *Client, data: []const u8) void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "v=")) {
                self.peer_version = std.fmt.parseInt(u8, line[2..], 10) catch self.peer_version;
            }
        }
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

fn encodeSocksAddr(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
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

fn flushTlsAndSocket(conn: *Client.TlsConnection) !void {
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
