const std = @import("std");
const compat = @import("../../compat.zig");
const net = compat.net;
const config = @import("../../config.zig");
const Config = config.Config;
const Proxy = config.Proxy;
const ProxyType = config.ProxyType;
const meta = @import("../../meta.zig");
const ss = @import("shadowsocks.zig");
const simple_obfs_http = @import("simple_obfs_http.zig");
const runtime_capability = @import("../../runtime_capability.zig");
const anytls = @import("../../protocol/anytls.zig");
const anytls_pool = @import("anytls_pool.zig");
const udp_uot = @import("../udp_uot.zig");
const runtime_selection = @import("../../runtime_selection.zig");
const config_catalog = @import("../../config_catalog.zig");

/// The production UoT v2 codec instantiated over a real borrowed anytls.Stream.
/// The ProxyStream UDP arm owns a heap instance of this; the relay (D6) drives
/// writeDatagram/readDatagram on it via ProxyStream.udpStream().
pub const AnyTlsUdpStream = udp_uot.UotStream(anytls.Stream);
const crypto = std.crypto;
const trojan = @import("../../protocol/trojan.zig");
const socket_options = @import("../../socket_options.zig");

const CapabilityValidationProbe = struct {
    complete_scans: u32 = 0,
    proxies_visited: u32 = 0,
    groups_visited: u32 = 0,
    selected_proxy_gates: u32 = 0,
    group_index_lookups: u32 = 0,
    proxy_index_lookups: u32 = 0,
    linear_config_scans: u32 = 0,
};

fn requireCompleteConfigCapabilities(
    config_arg: *const Config,
    probe: ?*CapabilityValidationProbe,
) !void {
    if (probe) |value| {
        value.complete_scans +|= 1;
        value.linear_config_scans +|= 1;
        value.proxies_visited +|= @intCast(config_arg.proxies.items.len);
        value.groups_visited +|= @intCast(config_arg.proxy_groups.items.len);
    }
    try runtime_capability.requireConfig(config_arg);
}

fn requireSelectedProxyCapabilities(
    proxy: *const Proxy,
    probe: ?*CapabilityValidationProbe,
) !runtime_capability.Capability {
    if (probe) |value| value.selected_proxy_gates +|= 1;
    return runtime_capability.requireProxy(proxy);
}

/// 代理流包装器
pub const ProxyStream = struct {
    base_stream: net.Stream,
    allocator: ?std.mem.Allocator = null,
    owned_ss_client: ?*ss.ShadowsocksClient = null,
    /// AnyTLS multiplexed stream borrowed from a SessionPool (C3b). The pool owns
    /// the Session; this struct owns ONLY the per-stream borrow. close() routes to
    /// Stream.close (FIN + return-to-idle + ref drop) — the manager NEVER destroys
    /// the Session here (that is the pool's drain in §13).
    owned_anytls_stream: ?*anytls.Stream = null,
    owned_trojan_client: ?*trojan.Client = null,
    /// Retained AnyTLS UoT v2 arm for protocol tests and future capability work.
    /// The v1 `connectUdp` path never constructs it. It never flows through
    /// relay(); only close/getHandle/udpStream/move are valid.
    owned_anytls_udp: ?*AnyTlsUdpStream = null,
    is_closed: bool = false,

    pub fn initDirect(stream: net.Stream) ProxyStream {
        return .{
            .base_stream = stream,
        };
    }

    pub fn initShadowsocks(allocator: std.mem.Allocator, stream: net.Stream, client: *ss.ShadowsocksClient) ProxyStream {
        return .{
            .base_stream = stream,
            .allocator = allocator,
            .owned_ss_client = client,
        };
    }

    pub fn initTrojan(allocator: std.mem.Allocator, stream: net.Stream, client: *trojan.Client) ProxyStream {
        return .{
            .base_stream = stream,
            .allocator = allocator,
            .owned_trojan_client = client,
        };
    }

    /// Borrow an AnyTLS multiplexed Stream from a SessionPool (C3b). No
    /// `net.Stream`/allocator: read/write/close/hasPendingRead/getHandle all route
    /// to the Stream, whose getHandle() returns the per-stream notifier read fd so
    /// the plain CONNECT relay polls it unchanged.
    ///
    /// KNOWN GAP (TODO C5): the HTTPS-forward path (mixed.zig HttpsForwardStream)
    /// is NOT yet correct over anytls. The guard at mixed.zig:621
    /// (`owned_ss_client == null and owned_trojan_client == null`) does NOT exclude
    /// `owned_anytls_stream`, so an anytls target currently takes the no-poll
    /// `handleDirectHttpsForwardStream` path whose UpstreamReader turns WouldBlock
    /// into a FATAL error.ReadFailed. C5 must (a) add `and
    /// target_stream.owned_anytls_stream == null` to that guard so anytls takes the
    /// move()/HttpsForwardStream path, and (b) route that reader through
    /// `Stream.readBlocking` (§14). We do NOT touch mixed.zig in C3b (relays are
    /// out of scope for this sub-stage); until C5, anytls is production-reachable
    /// on the plain CONNECT relay path only.
    pub fn initAnyTlsStream(stream: *anytls.Stream) ProxyStream {
        return .{
            .base_stream = .{ .handle = -1 },
            .allocator = null,
            .owned_anytls_stream = stream,
        };
    }

    /// Wrap a heap AnyTlsUdpStream (UoT v2 over a borrowed anytls.Stream) as a
    /// UDP-only ProxyStream (D5). base_stream is the fd=-1 sentinel; the byte
    /// methods @panic. The relay drives I/O through udpStream(); close() frees
    /// the UotStream + routes the inner Stream.close.
    pub fn initAnyTlsUdp(allocator: std.mem.Allocator, ust: *AnyTlsUdpStream) ProxyStream {
        return .{
            .base_stream = .{ .handle = -1 },
            .allocator = allocator,
            .owned_anytls_udp = ust,
        };
    }

    pub fn move(self: *ProxyStream) ProxyStream {
        const moved = self.*;
        self.base_stream = .{ .handle = -1 };
        self.allocator = null;
        self.owned_ss_client = null;
        self.owned_anytls_stream = null;
        self.owned_trojan_client = null;
        self.owned_anytls_udp = null;
        self.is_closed = true;
        return moved;
    }

    /// Accessor for the relay (D6). The UDP arm exposes ONLY this + close +
    /// getHandle + move; the byte-stream methods @panic on a UDP ProxyStream.
    pub fn udpStream(self: *ProxyStream) *AnyTlsUdpStream {
        return self.owned_anytls_udp.?;
    }

    pub fn write(self: *ProxyStream, data: []const u8) !void {
        if (self.owned_anytls_udp != null) @panic("ProxyStream.write called on a UDP (UoT) arm");
        if (self.is_closed) return error.StreamClosed;
        if (self.owned_ss_client) |client| {
            try client.write(data);
        } else if (self.owned_anytls_stream) |stream| {
            try stream.write(data);
        } else if (self.owned_trojan_client) |client| {
            try client.write(data);
        } else {
            try self.base_stream.writeAll(data);
        }
    }

    pub fn read(self: *ProxyStream, buf: []u8) !usize {
        if (self.owned_anytls_udp != null) @panic("ProxyStream.read called on a UDP (UoT) arm");
        if (self.is_closed) return error.StreamClosed;
        if (self.owned_ss_client) |client| {
            return try client.read(buf);
        } else if (self.owned_anytls_stream) |stream| {
            return try stream.read(buf);
        } else if (self.owned_trojan_client) |client| {
            return try client.read(buf);
        } else {
            return try self.base_stream.read(buf);
        }
    }

    /// Blocking read that never surfaces WouldBlock. Used by the HttpsForward
    /// no-poll TLS pump (mixed.zig UpstreamReader): AnyTLS waits on its notifier;
    /// Shadowsocks polls across synthetic WouldBlock from split salts/frames;
    /// direct and Trojan retain their plain blocking read behavior.
    pub fn readBlocking(self: *ProxyStream, buf: []u8) !usize {
        if (self.owned_anytls_udp != null) @panic("ProxyStream.readBlocking called on a UDP (UoT) arm");
        if (self.is_closed) return error.StreamClosed;
        if (self.owned_ss_client) |client| {
            return try client.readBlocking(buf);
        }
        if (self.owned_anytls_stream) |stream| {
            return try stream.readBlocking(buf);
        }
        return try self.read(buf);
    }

    pub fn close(self: *ProxyStream) void {
        if (self.is_closed) return;
        self.is_closed = true;

        if (self.owned_anytls_udp) |u| {
            // UDP arm teardown (D5). Route the inner Stream.close (FIN + return
            // the Session to the pool's idle list / discard + drop the relay
            // borrow ref) exactly like the TCP anytls arm, then free the
            // UotStream (deinit frees its rx buffer) and the heap wrapper.
            self.owned_anytls_udp = null;
            u.stream.close();
            u.deinit();
            self.allocator.?.destroy(u);
            return;
        }
        if (self.owned_ss_client) |client| {
            self.owned_ss_client = null;
            client.deinit();
            self.allocator.?.destroy(client);
            return;
        }
        if (self.owned_anytls_stream) |stream| {
            // The Stream owns its own teardown: close() sends a per-stream FIN,
            // returns the Session to the pool's idle list (or frees it), and drops
            // the relay-borrow ref. The manager does NOT destroy the Session — the
            // pool's §13 drain (OutboundManager.deinit) owns Session lifetimes.
            self.owned_anytls_stream = null;
            stream.close();
            return;
        }
        if (self.owned_trojan_client) |client| {
            self.owned_trojan_client = null;
            client.deinit();
            self.allocator.?.destroy(client);
            return;
        }
        self.base_stream.close();
    }

    pub fn hasPendingRead(self: *const ProxyStream) bool {
        if (self.owned_anytls_udp != null) @panic("ProxyStream.hasPendingRead called on a UDP (UoT) arm");
        if (self.is_closed) return false;
        if (self.owned_ss_client) |client| {
            return client.hasPendingRead();
        }
        if (self.owned_anytls_stream) |stream| {
            return stream.hasPendingRead();
        }
        if (self.owned_trojan_client) |client| {
            return client.hasPendingRead();
        }
        return false;
    }

    pub fn responseDeadlineRemainingMsAt(
        self: *const ProxyStream,
        now_ms: i64,
    ) ?i32 {
        if (self.is_closed) return null;
        if (self.owned_ss_client) |client| {
            return client.responseDeadlineRemainingMsAt(now_ms);
        }
        return null;
    }

    pub fn checkResponseDeadlineAt(
        self: *const ProxyStream,
        now_ms: i64,
    ) !void {
        if (self.is_closed) return;
        if (self.owned_ss_client) |client| {
            try client.checkResponseDeadlineAt(now_ms);
        }
    }

    /// Diagnostic: most recent underlying TLS read error for a trojan target,
    /// or null. Lets the relay log distinguish a benign mid-record truncation
    /// from a fatal TLS error when a read surfaces `error.ReadFailed`.
    /// Returns null for non-trojan protocols (anytls, shadowsocks, plain TCP).
    pub fn lastTlsReadError(self: *const ProxyStream) ?anyerror {
        if (self.is_closed) return null;
        if (self.owned_trojan_client) |client| return client.lastReadError();
        return null;
    }

    pub fn getHandle(self: *ProxyStream) std.posix.fd_t {
        if (self.is_closed) return -1;
        if (self.owned_anytls_udp) |u| {
            // The UDP relay (D6) polls the inner anytls Stream's notifier fd for
            // inbound UoT frames exactly as the TCP relay polls a stream fd.
            return u.stream.getHandle();
        }
        if (self.owned_anytls_stream) |stream| {
            // The per-stream notifier read fd: the plain CONNECT relay polls this
            // for readiness exactly as it would a socket fd.
            return stream.getHandle();
        }
        return self.base_stream.handle;
    }

    /// Half-close the write side. For anytls this sends a per-stream cmdFIN and
    /// keeps the read side open (§14); shutdown(SHUT_WR) on the notifier fd would
    /// be a no-op and break half-close. For every other type it does
    /// compat.shutdownWrite(getHandle()) — byte-for-byte what shutdownTargetWrite
    /// did before (direct/ss/trojan/vless all shut down the real socket fd).
    pub fn shutdownWrite(self: *ProxyStream) !void {
        if (self.owned_anytls_udp != null) @panic("ProxyStream.shutdownWrite called on a UDP (UoT) arm");
        if (self.is_closed) return;
        if (self.owned_anytls_stream) |stream| {
            stream.shutdownWrite();
            return;
        }
        try compat.shutdownWrite(self.getHandle());
    }
};

/// 代理出站管理器
const Impl = struct {
    const GroupIndexEntry = struct {
        group: *const config.ProxyGroup,
        ordinal: usize,
    };

    allocator: std.mem.Allocator,
    /// Borrowed immutable configuration. The caller keeps the Config and every
    /// nested allocation alive and address-stable for this Impl's lifetime.
    config: *const Config,
    /// Borrowed-key indexes built once after complete allocation-free admission.
    /// Values point directly into the immutable Config arrays.
    proxy_index: std.StringHashMap(*const Proxy),
    group_index: std.StringHashMap(GroupIndexEntry),

    /// 每个代理组的当前选择（group_name → proxy_name）
    group_selections: std.StringHashMap([]const u8),
    group_selection_sources: std.StringHashMap(runtime_selection.SelectionSource),
    group_selections_mutex: std.Io.Mutex = .init,
    selection_generation: u64 = 0,
    /// Internal test seams; production instances leave these null.
    selection_commit_probe: ?*SelectionCommitProbe = null,
    capability_validation_probe: ?*CapabilityValidationProbe = null,
    traffic_ready: std.atomic.Value(bool) = .init(true),

    /// 当前配置 key（用于持久化 selections 到 meta.json）
    config_key: ?[]const u8 = null,
    persist_invocations: usize = 0,

    /// AnyTLS per-identity SessionPools (§12). Keyed by an owned poolKey string
    /// (addr|port|sni|skip|hex(pwhash[0..8])). Guarded by pools_mutex, which is the
    /// outermost lock (§16): NEVER held while calling a pool method that locks
    /// pool.mutex.
    anytls_pools: std.StringHashMapUnmanaged(*anytls_pool.SessionPool) = .empty,
    pools_mutex: std.Io.Mutex = .init,

    fn init(
        allocator: std.mem.Allocator,
        config_arg: *const Config,
    ) !*Impl {
        return initWithKey(allocator, config_arg, null);
    }

    /// Complete capability admission precedes allocator.create: invalid configs
    /// fail before the first manager allocation. Index/key allocation happens
    /// only after that proof and is fully unwound on every failure.
    fn initWithKey(
        allocator: std.mem.Allocator,
        config_arg: *const Config,
        config_key: ?[]const u8,
    ) !*Impl {
        try requireCompleteConfigCapabilities(config_arg, null);

        const self = try allocator.create(Impl);
        self.* = .{
            .allocator = allocator,
            .config = config_arg,
            .proxy_index = std.StringHashMap(*const Proxy).init(allocator),
            .group_index = std.StringHashMap(GroupIndexEntry).init(allocator),
            .group_selections = std.StringHashMap([]const u8).init(allocator),
            .group_selection_sources = std.StringHashMap(
                runtime_selection.SelectionSource,
            ).init(allocator),
        };
        errdefer {
            self.deinitStorage();
            allocator.destroy(self);
        }

        try self.buildConfigIndexes();
        if (config_key) |key| {
            self.config_key = try allocator.dupe(u8, key);
        }
        return self;
    }

    fn buildConfigIndexes(self: *Impl) !void {
        try self.proxy_index.ensureTotalCapacity(
            @intCast(self.config.proxies.items.len),
        );
        for (self.config.proxies.items) |*proxy| {
            // General validation rejects duplicate names. Preserve historical
            // first-match behavior for manually constructed configs as well.
            if (self.proxy_index.contains(proxy.name)) continue;
            self.proxy_index.putAssumeCapacity(proxy.name, proxy);
        }

        try self.group_index.ensureTotalCapacity(
            @intCast(self.config.proxy_groups.items.len),
        );
        for (self.config.proxy_groups.items, 0..) |*group, ordinal| {
            if (self.group_index.contains(group.name)) continue;
            self.group_index.putAssumeCapacity(group.name, .{
                .group = group,
                .ordinal = ordinal,
            });
        }
    }

    fn borrowedConfig(self: *const Impl) *const Config {
        return self.config;
    }

    fn requireCompleteCapabilities(self: *Impl) !void {
        try requireCompleteConfigCapabilities(
            self.borrowedConfig(),
            self.capability_validation_probe,
        );
    }

    fn requireSelectedCapabilities(
        self: *Impl,
        proxy: *const Proxy,
    ) !runtime_capability.Capability {
        return requireSelectedProxyCapabilities(
            proxy,
            self.capability_validation_probe,
        );
    }

    fn deinitStorage(self: *Impl) void {
        // §13 drain: tear down every AnyTLS pool. pool.deinit joins the reaper +
        // every recv-loop thread; relay-held Streams free later via
        // ProxyStream.close -> Stream.close -> Session.releaseRef. We hold
        // pools_mutex only to snapshot/iterate the map (pool.deinit takes the
        // pool's own mutex, never pools_mutex — no inversion, §16).
        self.lockPools();
        var it = self.anytls_pools.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.anytls_pools.deinit(self.allocator);
        self.unlockPools();

        self.lockSelections();
        defer self.unlockSelections();
        self.group_selections.deinit();
        self.group_selection_sources.deinit();
        self.proxy_index.deinit();
        self.group_index.deinit();
        if (self.config_key) |k| self.allocator.free(k);
    }

    fn lockPools(self: *Impl) void {
        std.Io.Threaded.mutexLock(&self.pools_mutex);
    }

    fn unlockPools(self: *Impl) void {
        std.Io.Threaded.mutexUnlock(&self.pools_mutex);
    }

    /// Builds an owned per-identity pool key (§12):
    /// "addr|port|sni|skip|hex(pwhash[0..8])". Two proxies sharing every field
    /// share a pool; any difference (incl. password) routes to a distinct pool.
    /// Caller owns the returned slice.
    fn poolKey(self: *Impl, proxy: *const Proxy) ![]u8 {
        var pwhash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(proxy.password orelse "", &pwhash, .{});
        return std.fmt.allocPrint(self.allocator, "{s}|{d}|{s}|{d}|{x}", .{
            proxy.server,
            proxy.port,
            proxy.sni orelse "",
            @as(u8, if (proxy.skip_cert_verify) 1 else 0),
            pwhash[0..8],
        });
    }

    /// Returns the SessionPool for `key`, lazily creating it (and spawning its
    /// reaper) on a miss. Stored under the owned `key`; on a hit the passed `key`
    /// is the caller's to free. Held under pools_mutex (§16: we do NOT call into
    /// pool methods that lock pool.mutex while holding it — createStream runs after
    /// this returns and the lock is released).
    fn getOrCreatePool(self: *Impl, key: []const u8, proxy: *const Proxy) !*anytls_pool.SessionPool {
        self.lockPools();
        defer self.unlockPools();

        if (self.anytls_pools.get(key)) |existing| return existing;

        const dial_config = anytls.Config{
            .password = proxy.password orelse return error.MissingPassword,
            .address = proxy.server,
            .port = proxy.port,
            .sni = proxy.sni,
            .skip_cert_verify = proxy.skip_cert_verify,
        };
        // §15: build PoolConfig from the validated config. Config carries the
        // tunables in SECONDS (already clamped by config_validator); the pool wants
        // milliseconds. syn_done_ms is fixed at 3000 (not user-configurable).
        const pool_cfg = anytls_pool.PoolConfig{
            .idle_session_check_interval_ms = self.borrowedConfig()
                .idle_session_check_interval * 1000,
            .idle_session_timeout_ms = self.borrowedConfig()
                .idle_session_timeout * 1000,
            .min_idle_session = self.borrowedConfig().min_idle_session,
            .syn_done_ms = 3000,
        };
        const pool = try anytls_pool.SessionPool.init(self.allocator, key, dial_config, pool_cfg);
        errdefer pool.deinit();
        try pool.startReaper();

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.anytls_pools.put(self.allocator, owned_key, pool);
        return pool;
    }

    /// Applies and persists a legacy metadata selection.
    pub fn selectProxy(
        self: *Impl,
        group_name: []const u8,
        proxy_name: []const u8,
    ) !bool {
        try self.requireCompleteCapabilities();
        return self.selectProxyInternal(
            group_name,
            proxy_name,
            true,
            .persisted,
        );
    }

    /// Applies a selection already committed by the CLI authority path.
    pub fn applyPersistedSelection(
        self: *Impl,
        group_name: []const u8,
        proxy_name: []const u8,
    ) !bool {
        try self.requireCompleteCapabilities();
        return self.selectProxyInternal(
            group_name,
            proxy_name,
            false,
            .persisted,
        );
    }

    pub fn applyTransientSelection(
        self: *Impl,
        group_name: []const u8,
        proxy_name: []const u8,
    ) !bool {
        try self.requireCompleteCapabilities();
        return self.selectProxyInternal(
            group_name,
            proxy_name,
            false,
            .transient,
        );
    }

    const PreparedSelectionMaps = struct {
        selections: std.StringHashMap([]const u8),
        sources: std.StringHashMap(runtime_selection.SelectionSource),

        fn init(allocator: std.mem.Allocator) PreparedSelectionMaps {
            return .{
                .selections = std.StringHashMap([]const u8).init(allocator),
                .sources = std.StringHashMap(
                    runtime_selection.SelectionSource,
                ).init(allocator),
            };
        }

        fn deinit(self: *PreparedSelectionMaps) void {
            self.selections.deinit();
            self.sources.deinit();
            self.* = undefined;
        }
    };

    const SelectionCommitProbe = struct {
        old_selection_capacity: u32 = 0,
        old_source_capacity: u32 = 0,
        critical_map_swaps: u8 = 0,
        old_maps_deinitialized_after_unlock: bool = false,
    };

    /// Private value transaction. Public callers receive an allocated opaque
    /// pointer handle, so this lock-owning value cannot be shallow-copied across
    /// the API boundary.
    const PersistedSelectionTransaction = struct {
        manager: *Impl,
        replacement: PreparedSelectionMaps,
        generation: u64,

        fn preparedGeneration(
            self: *const PersistedSelectionTransaction,
        ) u64 {
            return self.generation;
        }

        /// Publishes the already-built maps with two constant-size swaps. The old
        /// maps are released only after the selection lock is no longer held.
        fn commit(self: *PersistedSelectionTransaction) void {
            const manager = self.manager;
            const probe = manager.selection_commit_probe;
            if (probe) |value| {
                value.* = .{
                    .old_selection_capacity = manager.group_selections.capacity(),
                    .old_source_capacity = manager.group_selection_sources.capacity(),
                };
            }

            std.mem.swap(
                std.StringHashMap([]const u8),
                &manager.group_selections,
                &self.replacement.selections,
            );
            if (probe) |value| value.critical_map_swaps += 1;
            std.mem.swap(
                std.StringHashMap(runtime_selection.SelectionSource),
                &manager.group_selection_sources,
                &self.replacement.sources,
            );
            if (probe) |value| value.critical_map_swaps += 1;
            manager.selection_generation = self.generation;

            manager.unlockSelections();
            self.replacement.deinit();
            if (probe) |value| {
                value.old_maps_deinitialized_after_unlock = true;
            }
            self.* = undefined;
        }

        /// Abandons a plan after unlocking, so conflict/error cleanup never scans
        /// or releases replacement storage in the critical section.
        fn deinit(self: *PersistedSelectionTransaction) void {
            const manager = self.manager;
            manager.unlockSelections();
            self.replacement.deinit();
            self.* = undefined;
        }
    };

    const PersistedSelectionTransactionHandle = struct {
        inner: PersistedSelectionTransaction,
    };

    fn requirePersistedSelectionCapabilities(
        self: *Impl,
        selections: []const config_catalog.Selection,
    ) !void {
        try self.requireCompleteCapabilities();
        try config.requirePersistedSelectionLimit(selections.len);
    }

    fn preparePersistedSelectionMaps(
        self: *Impl,
        selections: []const config_catalog.Selection,
    ) !?PreparedSelectionMaps {
        var replacement = PreparedSelectionMaps.init(self.allocator);
        var replacement_owned = true;
        defer if (replacement_owned) replacement.deinit();
        try replacement.selections.ensureTotalCapacity(
            @intCast(selections.len),
        );
        try replacement.sources.ensureTotalCapacity(
            @intCast(selections.len),
        );
        if (selections.len == 0) {
            replacement_owned = false;
            return replacement;
        }

        for (selections) |selection| {
            if (replacement.selections.contains(selection.group)) return null;
            const indexed_group = self.group_index.get(selection.group) orelse
                return null;
            const group = indexed_group.group;
            const proxy = findPreparedSelectionMember(
                group,
                selection.proxy,
            ) orelse return null;
            replacement.selections.putAssumeCapacity(group.name, proxy);
            replacement.sources.putAssumeCapacity(group.name, .persisted);
        }
        replacement_owned = false;
        return replacement;
    }

    fn findPreparedSelectionMember(
        group: *const config.ProxyGroup,
        proxy_name: []const u8,
    ) ?[]const u8 {
        for (group.proxies.items) |proxy| {
            if (std.mem.eql(u8, proxy, proxy_name)) return proxy;
        }
        return null;
    }

    fn beginPersistedSelectionsAfterCapabilities(
        self: *Impl,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !?PersistedSelectionTransaction {
        // The immutable Config is indexed and complete replacement maps are built
        // before the lock. Nothing after lock acquisition can allocate or fail.
        var replacement = (try self.preparePersistedSelectionMaps(
            selections,
        )) orelse return null;

        self.lockSelections();
        if (generation < self.selection_generation) {
            self.unlockSelections();
            replacement.deinit();
            return null;
        }
        if (generation == self.selection_generation) {
            if (!self.persistedSelectionMapsMatchCurrentLocked(&replacement)) {
                self.unlockSelections();
                replacement.deinit();
                return null;
            }
        }
        return .{
            .manager = self,
            .replacement = replacement,
            .generation = generation,
        };
    }

    fn beginPersistedSelections(
        self: *Impl,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !?PersistedSelectionTransaction {
        try self.requirePersistedSelectionCapabilities(selections);
        return self.beginPersistedSelectionsAfterCapabilities(
            selections,
            generation,
        );
    }

    pub fn preparePersistedSelections(
        self: *Impl,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !bool {
        var transaction = (try self.beginPersistedSelections(
            selections,
            generation,
        )) orelse return false;
        transaction.deinit();
        return true;
    }

    fn persistedSelectionMapsMatchCurrentLocked(
        self: *Impl,
        replacement: *const PreparedSelectionMaps,
    ) bool {
        if (self.group_selections.count() != replacement.selections.count()) {
            return false;
        }
        if (self.group_selection_sources.count() != replacement.sources.count()) {
            return false;
        }
        var selections = replacement.selections.iterator();
        while (selections.next()) |selection| {
            const current_proxy = self.group_selections.get(
                selection.key_ptr.*,
            ) orelse return false;
            if (!std.mem.eql(u8, current_proxy, selection.value_ptr.*)) {
                return false;
            }
            const replacement_source = replacement.sources.get(
                selection.key_ptr.*,
            ) orelse return false;
            const current_source = self.group_selection_sources.get(
                selection.key_ptr.*,
            ) orelse return false;
            if (current_source != replacement_source) return false;
        }
        return true;
    }

    pub fn commitPersistedSelections(
        self: *Impl,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !bool {
        var transaction = (try self.beginPersistedSelections(
            selections,
            generation,
        )) orelse return false;
        transaction.commit();
        return true;
    }

    /// Private value barrier wrapped by a public allocated opaque handle.
    const SelectionBarrier = struct {
        manager: *Impl,

        fn deinit(self: *SelectionBarrier) void {
            const manager = self.manager;
            manager.unlockSelections();
            self.* = undefined;
        }
    };

    const SelectionBarrierHandle = struct {
        inner: SelectionBarrier,
    };

    fn acquireSelectionBarrier(self: *Impl) SelectionBarrier {
        self.lockSelections();
        return .{ .manager = self };
    }

    pub fn waitForPersistedSelectionUpdates(self: *Impl) void {
        var barrier = self.acquireSelectionBarrier();
        barrier.deinit();
    }

    pub fn persistedSelectionGeneration(self: *Impl) u64 {
        self.lockSelections();
        defer self.unlockSelections();
        return self.selection_generation;
    }

    pub fn applyPersistedSelections(
        self: *Impl,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !bool {
        return self.commitPersistedSelections(selections, generation);
    }

    /// daemon 实际加载的配置 key（启动时设定）。status 经 IPC 读取此值而非
    /// 用户指针 getCurrentConfigName，避免配置切换未重启 daemon 时的错位。
    pub fn configKey(self: *const Impl) ?[]const u8 {
        return self.config_key;
    }

    /// 拷贝当前 group_selections 的快照（group → proxy，owned）。status 经 IPC
    /// 读取 daemon 运行时内存状态，而非 meta.json 持久化层——后者在
    /// config_key 与 active_config 错位时会读到空，显示 default 而与实际不符。
    pub fn snapshotSelections(self: *Impl, allocator: std.mem.Allocator) ![]runtime_selection.SelectionEntry {
        try self.requireCompleteCapabilities();
        self.lockSelections();
        defer self.unlockSelections();

        var entries = std.ArrayList(runtime_selection.SelectionEntry).empty;
        errdefer {
            for (entries.items) |e| {
                allocator.free(e.group);
                allocator.free(e.proxy);
            }
            entries.deinit(allocator);
        }
        var it = self.group_selections.iterator();
        while (it.next()) |entry| {
            const group = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(group);
            const proxy = try allocator.dupe(u8, entry.value_ptr.*);
            errdefer allocator.free(proxy);
            const source = self.group_selection_sources.get(
                entry.key_ptr.*,
            ) orelse .persisted;
            try entries.append(allocator, .{
                .group = group,
                .proxy = proxy,
                .source = source,
            });
        }
        return entries.toOwnedSlice(allocator);
    }

    fn selectProxyInternal(
        self: *Impl,
        group_name: []const u8,
        proxy_name: []const u8,
        persist: bool,
        source: runtime_selection.SelectionSource,
    ) !bool {
        self.lockSelections();
        defer self.unlockSelections();

        const indexed_group = self.group_index.get(group_name) orelse {
            std.debug.print("[Manager] Group '{s}' not found\n", .{group_name});
            return false;
        };
        const group = indexed_group.group;
        for (group.proxies.items) |member_name| {
            if (!std.mem.eql(u8, member_name, proxy_name)) continue;

            const previous = self.group_selections.get(group.name);
            const previous_source = self.group_selection_sources.get(
                group.name,
            );
            try self.group_selections.ensureUnusedCapacity(1);
            try self.group_selection_sources.ensureUnusedCapacity(1);
            self.group_selections.putAssumeCapacity(group.name, member_name);
            self.group_selection_sources.putAssumeCapacity(
                group.name,
                source,
            );
            if (persist) {
                self.persistSelections() catch |err| {
                    if (previous) |old_proxy| {
                        self.group_selections.getPtr(group.name).?.* = old_proxy;
                        self.group_selection_sources.getPtr(group.name).?.* =
                            previous_source orelse .persisted;
                    } else {
                        std.debug.assert(
                            self.group_selections.remove(group.name),
                        );
                        std.debug.assert(
                            self.group_selection_sources.remove(group.name),
                        );
                    }
                    return err;
                };
            }
            std.debug.print(
                "[Manager] Group '{s}' selected: {s}\n",
                .{ group.name, member_name },
            );
            return true;
        }
        std.debug.print(
            "[Manager] Proxy '{s}' not found in group '{s}'\n",
            .{ proxy_name, group_name },
        );
        return false;
    }

    fn persistSelectionsPut(
        self: *Impl,
        selections: *std.StringHashMap([]const u8),
        selection: config_catalog.Selection,
    ) !void {
        const group = try self.allocator.dupe(u8, selection.group);
        errdefer self.allocator.free(group);
        const proxy = try self.allocator.dupe(u8, selection.proxy);
        errdefer self.allocator.free(proxy);
        try selections.put(group, proxy);
    }

    fn copyPersistableSelectionsLocked(
        self: *Impl,
        selections: *std.StringHashMap([]const u8),
    ) !void {
        var selection_iterator = self.group_selections.iterator();
        while (selection_iterator.next()) |selection| {
            const source = self.group_selection_sources.get(
                selection.key_ptr.*,
            ) orelse .persisted;
            if (source == .transient) continue;
            try self.persistSelectionsPut(selections, .{
                .group = selection.key_ptr.*,
                .proxy = selection.value_ptr.*,
            });
        }
    }

    fn persistSelections(self: *Impl) !void {
        const key = self.config_key orelse return;
        self.persist_invocations +|= 1;

        var legacy_guard = try config.acquireLegacyWriteGuard(self.allocator);
        defer legacy_guard.deinit();
        var meta_data = try meta.load(self.allocator);
        defer meta_data.deinit();
        const entry = meta_data.configs.getPtr(key) orelse
            return error.LegacyMetadataEntryMissing;

        var old_iterator = entry.selections.iterator();
        while (old_iterator.next()) |old_selection| {
            self.allocator.free(old_selection.key_ptr.*);
            self.allocator.free(old_selection.value_ptr.*);
        }
        entry.selections.clearRetainingCapacity();

        try self.copyPersistableSelectionsLocked(&entry.selections);
        try meta.saveVisible(self.allocator, &meta_data);
    }

    /// 从 meta.json 加载持久化的 selections
    pub fn loadPersistedSelections(self: *Impl) !void {
        try self.requireCompleteCapabilities();
        const key = self.config_key orelse return;

        var meta_data = try meta.load(self.allocator);
        defer meta_data.deinit();

        const cm = meta_data.configs.get(key) orelse return;
        try config.requirePersistedSelectionLimit(cm.selections.count());

        var it = cm.selections.iterator();
        while (it.next()) |entry| {
            if (!try self.selectProxyInternal(
                entry.key_ptr.*,
                entry.value_ptr.*,
                false,
                .persisted,
            )) {
                return error.InvalidDesiredSelection;
            }
        }
    }

    pub fn setTrafficReady(self: *Impl, ready: bool) void {
        self.traffic_ready.store(ready, .release);
    }

    fn waitForTrafficReady(self: *Impl) void {
        while (!self.traffic_ready.load(.acquire)) {
            compat.sleepNs(1 * std.time.ns_per_ms);
        }
    }

    /// 根据代理名称建立连接（返回加密的代理流）
    pub fn connect(self: *Impl, proxy_name: []const u8, target: []const u8, port: u16) !ProxyStream {
        _ = self.borrowedConfig();
        self.waitForTrafficReady();
        std.debug.print("[Manager] connect: proxy={s}, target={s}:{d}\n", .{ proxy_name, target, port });

        // Resolve policy before applying the private-target loop guard. A deny
        // decision is terminal and must never be rewritten to DIRECT.
        if (std.mem.eql(u8, proxy_name, "DIRECT")) {
            std.debug.print("[Manager] Using DIRECT\n", .{});
            return try self.connectDirectTarget(target, port);
        }
        if (std.mem.eql(u8, proxy_name, "REJECT")) {
            return error.ConnectionRejected;
        }

        const current_name = try self.resolvePolicyName(proxy_name);

        if (std.mem.eql(u8, current_name, "DIRECT")) {
            return try self.connectDirectTarget(target, port);
        }
        if (std.mem.eql(u8, current_name, "REJECT")) {
            return error.ConnectionRejected;
        }

        const proxy = self.findProxy(current_name) orelse {
            std.debug.print("[Manager] Proxy not found: {s}\n", .{current_name});
            return error.ProxyNotFound;
        };
        // The immutable config was fully gated at init. Recheck only the proxy
        // selected for this flow before any direct shortcut or dial.
        const capability = try self.requireSelectedCapabilities(proxy);
        switch (capability) {
            .direct => return try self.connectDirectTarget(target, port),
            .reject => return error.ConnectionRejected,
            .shadowsocks, .trojan => {},
        }

        if (shouldBypassProxyForTarget(target)) {
            std.debug.print("[Manager] Bypassing proxy for local/private target: {s}:{d}\n", .{ target, port });
            return try self.connectDirectTarget(target, port);
        }
        return try self.connectToProxy(
            proxy,
            capability,
            target,
            port,
        );
    }

    /// Reject all v1 UDP proxy paths before dialing. DIRECT and REJECT preserve
    /// their narrower policy errors so SOCKS5 can report an accurate denial.
    pub fn connectUdp(self: *Impl, proxy_name: []const u8) !ProxyStream {
        _ = self.borrowedConfig();
        self.waitForTrafficReady();
        if (std.mem.eql(u8, proxy_name, "DIRECT")) return error.UdpNotSupportedForDirect;
        if (std.mem.eql(u8, proxy_name, "REJECT")) return error.ConnectionRejected;

        // TCP and UDP share one bounded resolver and selection-lock scope.
        const current_name = try self.resolvePolicyName(proxy_name);

        // A group may resolve to the literal DIRECT/REJECT names.
        if (std.mem.eql(u8, current_name, "DIRECT")) return error.UdpNotSupportedForDirect;
        if (std.mem.eql(u8, current_name, "REJECT")) return error.ConnectionRejected;

        const proxy = self.findProxy(current_name) orelse return error.ProxyNotFound;
        const capability = try self.requireSelectedCapabilities(proxy);
        return switch (capability) {
            .direct => error.UdpNotSupportedForDirect,
            .reject => error.ConnectionRejected,
            .shadowsocks, .trojan => error.UnsupportedProxyType,
        };
    }

    /// Open the single UoT v2 stream for an association: gate on the proxy being
    /// anytls + udp:true, then check out a Stream to the magic UoT dest via the
    /// SAME SessionPool the TCP path uses (shared poolKey). Wrap it in a heap
    /// AnyTlsUdpStream owned by the returned ProxyStream's UDP arm.
    fn connectAnyTlsUdp(self: *Impl, proxy: *const Proxy) !ProxyStream {
        switch (proxy.proxy_type) {
            .direct => return error.UdpNotSupportedForDirect,
            .reject => return error.ConnectionRejected,
            .anytls => {},
            else => return error.UdpNotSupportedByProxy,
        }
        if (!proxy.udp) return error.UdpNotSupportedByProxy;

        const key = try self.poolKey(proxy);
        defer self.allocator.free(key);
        const pool = try self.getOrCreatePool(key, proxy);
        const stream = try pool.createStream(udp_uot.MAGIC_DOMAIN, udp_uot.MAGIC_PORT);
        errdefer stream.close();

        const ust = try self.allocator.create(AnyTlsUdpStream);
        errdefer self.allocator.destroy(ust);
        ust.* = AnyTlsUdpStream.init(self.allocator, stream);
        return ProxyStream.initAnyTlsUdp(self.allocator, ust);
    }

    /// Connects an already-admitted concrete proxy. The capability value came
    /// from the focused gate before private-target bypass, so this function does
    /// not reclassify the proxy or scan configuration storage.
    fn connectToProxy(
        self: *Impl,
        proxy: *const Proxy,
        capability: runtime_capability.Capability,
        target: []const u8,
        port: u16,
    ) !ProxyStream {
        switch (capability) {
            .direct => return self.connectDirectTarget(target, port),
            .reject => return error.ConnectionRejected,
            .shadowsocks => |transport| {
                const client = try self.makeShadowsocksClientForTransport(
                    proxy,
                    transport,
                );
                errdefer {
                    client.deinit();
                    self.allocator.destroy(client);
                }
                const addr = ss.Address{
                    .host = target,
                    .port = port,
                };
                const stream = try client.connect(addr);
                return ProxyStream.initShadowsocks(self.allocator, stream, client);
            },
            .trojan => {
                const client = try self.allocator.create(trojan.Client);
                errdefer self.allocator.destroy(client);
                client.* = try trojan.Client.init(self.allocator, .{
                    .password = proxy.password orelse return error.MissingPassword,
                    .address = proxy.server,
                    .port = proxy.port,
                    .sni = proxy.sni,
                    .skip_cert_verify = proxy.skip_cert_verify,
                });
                errdefer client.deinit();
                const stream = try client.connect(target, port);
                return ProxyStream.initTrojan(self.allocator, stream, client);
            },
        }
    }

    fn makeShadowsocksClient(self: *Impl, proxy: *const Proxy) !*ss.ShadowsocksClient {
        const capability = try self.requireSelectedCapabilities(proxy);
        const transport = switch (capability) {
            .shadowsocks => |value| value,
            else => return error.UnsupportedProxyType,
        };
        return self.makeShadowsocksClientForTransport(proxy, transport);
    }

    fn makeShadowsocksClientForTransport(
        self: *Impl,
        proxy: *const Proxy,
        transport: runtime_capability.ShadowsocksTransport,
    ) !*ss.ShadowsocksClient {
        const client = try self.allocator.create(ss.ShadowsocksClient);
        errdefer self.allocator.destroy(client);

        switch (transport) {
            .plain => client.* = try ss.ShadowsocksClient.init(
                self.allocator,
                proxy.server,
                proxy.port,
                proxy.password orelse "",
                proxy.cipher orelse "aes-128-gcm",
            ),
            .simple_obfs_http => |obfs| client.* = try ss.ShadowsocksClient.initWithObfs(
                self.allocator,
                proxy.server,
                proxy.port,
                proxy.password orelse "",
                proxy.cipher orelse "aes-128-gcm",
                simple_obfs_http.Config{
                    .host = obfs.host,
                    .server_port = proxy.port,
                },
            ),
        }

        return client;
    }

    fn connectDirectTarget(self: *Impl, target: []const u8, port: u16) !ProxyStream {
        var addr_list = net.getAddressList(self.allocator, target, port) catch |err| {
            std.debug.print("[Manager] Target DNS resolve failed: target={s}:{d} err={}\n", .{ target, port, err });
            return error.TargetDnsResolveFailed;
        };
        defer addr_list.deinit();

        if (addr_list.addrs.len == 0) {
            std.debug.print("[Manager] Target DNS resolve returned no address: target={s}:{d}\n", .{ target, port });
            return error.TargetDnsResolveFailed;
        }

        const stream = net.tcpConnectToAddress(addr_list.addrs[0]) catch |err| {
            std.debug.print("[Manager] Target TCP connect failed: target={s}:{d} err={}\n", .{ target, port, err });
            return error.TargetTcpConnectFailed;
        };
        socket_options.configureConnectedStream(stream) catch |err| {
            stream.close();
            std.debug.print("[Manager] Target socket setup failed: target={s}:{d} err={}\n", .{ target, port, err });
            return error.TargetSocketSetupFailed;
        };
        return ProxyStream.initDirect(stream);
    }

    /// Resolves a TCP/UDP policy under the selection mutex. The fixed bitset is
    /// indexed by the prebuilt group hash entry, so cycle checks allocate
    /// nothing and each visited layer performs exactly one group-index lookup.
    fn resolvePolicyName(
        self: *Impl,
        initial_name: []const u8,
    ) ![]const u8 {
        self.lockSelections();
        defer self.unlockSelections();

        var visited = std.StaticBitSet(
            config.proxy_group_count_max,
        ).initEmpty();
        var unique_depth: usize = 0;
        var current_name = initial_name;
        while (true) {
            if (isPolicyLiteral(current_name)) return current_name;
            if (self.capability_validation_probe) |probe| {
                probe.group_index_lookups +|= 1;
            }
            const indexed_group = self.group_index.get(current_name) orelse
                return current_name;
            // The lookup after 1024 unique layers is intentional: a terminal
            // non-group name is still valid, while another group hit is an
            // explicit limit error rather than a misleading ProxyNotFound.
            if (unique_depth == config.proxy_group_count_max) {
                return error.ProxyGroupResolutionLimit;
            }
            if (visited.isSet(indexed_group.ordinal)) {
                return error.ProxyGroupResolutionCycle;
            }
            visited.set(indexed_group.ordinal);
            unique_depth += 1;

            const next = self.selectedGroupMemberLocked(
                indexed_group.group,
            ) orelse return current_name;
            current_name = next;
        }
    }

    fn selectedGroupMemberLocked(
        self: *Impl,
        group: *const config.ProxyGroup,
    ) ?[]const u8 {
        // Prefer the user selection while the caller holds the lock. Keep this
        // per-layer resolver silent: `connect` already emits one flow-level
        // line, while errors remain visible at their call sites.
        if (self.group_selections.get(group.name)) |value| return value;
        if (group.proxies.items.len > 0) {
            return group.proxies.items[0];
        }
        return null;
    }

    fn lockSelections(self: *Impl) void {
        std.Io.Threaded.mutexLock(&self.group_selections_mutex);
    }

    fn unlockSelections(self: *Impl) void {
        std.Io.Threaded.mutexUnlock(&self.group_selections_mutex);
    }

    fn findProxy(self: *Impl, name: []const u8) ?*const Proxy {
        if (self.capability_validation_probe) |probe| {
            probe.proxy_index_lookups +|= 1;
        }
        return self.proxy_index.get(name);
    }
};

/// Owned opaque outbound-manager handle. `init`/`initWithKey` allocate the
/// private Impl and return its sole owning pointer; `deinit` releases all maps,
/// pools, owned key storage, and the Impl allocation itself. No public concrete
/// value exists that callers can forge with `undefined` fields.
pub const OutboundManager = opaque {
    /// Owned opaque transaction pointer. `commit` and `deinit` both consume and
    /// destroy the handle; callers must choose exactly one, exactly once. Pointer
    /// copying does not create another owner and the former public value API is
    /// intentionally not supported.
    pub const PersistedSelectionTransaction = opaque {
        fn handle(
            self: *PersistedSelectionTransaction,
        ) *Impl.PersistedSelectionTransactionHandle {
            return @ptrCast(@alignCast(self));
        }

        fn constHandle(
            self: *const PersistedSelectionTransaction,
        ) *const Impl.PersistedSelectionTransactionHandle {
            return @ptrCast(@alignCast(self));
        }

        pub fn preparedGeneration(
            self: *const PersistedSelectionTransaction,
        ) u64 {
            return self.constHandle().inner.preparedGeneration();
        }

        pub fn commit(self: *PersistedSelectionTransaction) void {
            const owned_handle = self.handle();
            const allocator = owned_handle.inner.manager.allocator;
            owned_handle.inner.commit();
            allocator.destroy(owned_handle);
        }

        pub fn deinit(self: *PersistedSelectionTransaction) void {
            const owned_handle = self.handle();
            const allocator = owned_handle.inner.manager.allocator;
            owned_handle.inner.deinit();
            allocator.destroy(owned_handle);
        }
    };

    /// Owned allocation prepared before listener threads can be detached.
    /// `acquire` consumes its ownership conceptually and performs only the
    /// infallible selection lock, returning the acquired barrier in-place.
    pub const PreparedSelectionBarrier = opaque {
        fn handle(
            self: *PreparedSelectionBarrier,
        ) *Impl.SelectionBarrierHandle {
            return @ptrCast(@alignCast(self));
        }

        pub fn acquire(
            self: *PreparedSelectionBarrier,
        ) *SelectionBarrier {
            const owned_handle = self.handle();
            owned_handle.inner.manager.lockSelections();
            return @ptrCast(owned_handle);
        }

        /// Releases a handle that was prepared but never acquired.
        pub fn deinit(self: *PreparedSelectionBarrier) void {
            const owned_handle = self.handle();
            const allocator = owned_handle.inner.manager.allocator;
            allocator.destroy(owned_handle);
        }
    };

    /// Owned opaque acquired barrier pointer. `deinit` unlocks and destroys it
    /// exactly once; copying this pointer never transfers ownership.
    pub const SelectionBarrier = opaque {
        fn handle(self: *SelectionBarrier) *Impl.SelectionBarrierHandle {
            return @ptrCast(@alignCast(self));
        }

        pub fn deinit(self: *SelectionBarrier) void {
            const owned_handle = self.handle();
            const allocator = owned_handle.inner.manager.allocator;
            owned_handle.inner.deinit();
            allocator.destroy(owned_handle);
        }
    };

    fn impl(self: *OutboundManager) *Impl {
        return @ptrCast(@alignCast(self));
    }

    fn constImpl(self: *const OutboundManager) *const Impl {
        return @ptrCast(@alignCast(self));
    }

    pub fn init(
        allocator: std.mem.Allocator,
        config_arg: *const Config,
    ) !*OutboundManager {
        return @ptrCast(try Impl.init(allocator, config_arg));
    }

    pub fn initWithKey(
        allocator: std.mem.Allocator,
        config_arg: *const Config,
        config_key: ?[]const u8,
    ) !*OutboundManager {
        return @ptrCast(try Impl.initWithKey(
            allocator,
            config_arg,
            config_key,
        ));
    }

    pub fn deinit(self: *OutboundManager) void {
        const value = self.impl();
        const allocator = value.allocator;
        value.deinitStorage();
        allocator.destroy(value);
    }

    pub fn selectProxy(
        self: *OutboundManager,
        group_name: []const u8,
        proxy_name: []const u8,
    ) !bool {
        return self.impl().selectProxy(group_name, proxy_name);
    }

    pub fn applyPersistedSelection(
        self: *OutboundManager,
        group_name: []const u8,
        proxy_name: []const u8,
    ) !bool {
        return self.impl().applyPersistedSelection(group_name, proxy_name);
    }

    pub fn applyTransientSelection(
        self: *OutboundManager,
        group_name: []const u8,
        proxy_name: []const u8,
    ) !bool {
        return self.impl().applyTransientSelection(group_name, proxy_name);
    }

    pub fn beginPersistedSelections(
        self: *OutboundManager,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !?*PersistedSelectionTransaction {
        const value = self.impl();
        // Preserve fail-first public limit/capability errors, then allocate the
        // owner wrapper before replacement-map preparation can acquire the lock.
        try value.requirePersistedSelectionCapabilities(selections);
        const owned_handle = try value.allocator.create(
            Impl.PersistedSelectionTransactionHandle,
        );
        errdefer value.allocator.destroy(owned_handle);
        const inner = (try value.beginPersistedSelectionsAfterCapabilities(
            selections,
            generation,
        )) orelse {
            value.allocator.destroy(owned_handle);
            return null;
        };
        owned_handle.* = .{ .inner = inner };
        return @ptrCast(owned_handle);
    }

    pub fn preparePersistedSelections(
        self: *OutboundManager,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !bool {
        return self.impl().preparePersistedSelections(selections, generation);
    }

    pub fn commitPersistedSelections(
        self: *OutboundManager,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !bool {
        return self.impl().commitPersistedSelections(selections, generation);
    }

    pub fn prepareSelectionBarrier(
        self: *OutboundManager,
    ) !*PreparedSelectionBarrier {
        const value = self.impl();
        const owned_handle = try value.allocator.create(
            Impl.SelectionBarrierHandle,
        );
        owned_handle.* = .{
            .inner = .{ .manager = value },
        };
        return @ptrCast(owned_handle);
    }

    pub fn waitForPersistedSelectionUpdates(self: *OutboundManager) void {
        self.impl().waitForPersistedSelectionUpdates();
    }

    pub fn persistedSelectionGeneration(self: *OutboundManager) u64 {
        return self.impl().persistedSelectionGeneration();
    }

    pub fn applyPersistedSelections(
        self: *OutboundManager,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !bool {
        return self.impl().applyPersistedSelections(selections, generation);
    }

    pub fn configKey(self: *const OutboundManager) ?[]const u8 {
        return self.constImpl().configKey();
    }

    pub fn snapshotSelections(
        self: *OutboundManager,
        allocator: std.mem.Allocator,
    ) ![]runtime_selection.SelectionEntry {
        return self.impl().snapshotSelections(allocator);
    }

    pub fn loadPersistedSelections(self: *OutboundManager) !void {
        return self.impl().loadPersistedSelections();
    }

    pub fn setTrafficReady(self: *OutboundManager, ready: bool) void {
        self.impl().setTrafficReady(ready);
    }

    pub fn connect(
        self: *OutboundManager,
        proxy_name: []const u8,
        target: []const u8,
        port: u16,
    ) !ProxyStream {
        return self.impl().connect(proxy_name, target, port);
    }

    pub fn connectUdp(
        self: *OutboundManager,
        proxy_name: []const u8,
    ) !ProxyStream {
        return self.impl().connectUdp(proxy_name);
    }
};

fn managerImpl(manager: *OutboundManager) *Impl {
    return @ptrCast(@alignCast(manager));
}

fn isPolicyLiteral(name: []const u8) bool {
    return std.mem.eql(u8, name, "DIRECT") or
        std.mem.eql(u8, name, "REJECT");
}

fn shouldBypassProxyForTarget(target: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(target, "localhost")) return true;

    if (compat.net.Address.parseIp4(target, 0)) |addr| {
        const ip = addr.in.sa.addr;
        const a = @as(u8, @truncate(ip >> 0));
        const b = @as(u8, @truncate(ip >> 8));

        if (a == 127) return true;
        if (a == 10) return true;
        if (a == 172 and b >= 16 and b <= 31) return true;
        if (a == 192 and b == 168) return true;
        if (a == 169 and b == 254) return true;
        return false;
    } else |_| {}

    if (compat.net.Address.parseIp6(target, 0)) |addr6| {
        const ip = addr6.in6.sa.addr;
        if (isIpv6Loopback(ip)) return true;
        if ((ip[0] & 0xfe) == 0xfc) return true; // fc00::/7
        if (ip[0] == 0xfe and (ip[1] & 0xc0) == 0x80) return true; // fe80::/10
        return false;
    } else |_| {}

    return false;
}

fn isIpv6Loopback(ip: [16]u8) bool {
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        if (ip[i] != 0) return false;
    }
    return ip[15] == 1;
}

test "OutboundManager and public selection owners are opaque pointers" {
    switch (@typeInfo(OutboundManager)) {
        .@"opaque" => {},
        else => return error.ExpectedOpaqueOutboundManager,
    }
    switch (@typeInfo(OutboundManager.PersistedSelectionTransaction)) {
        .@"opaque" => {},
        else => return error.ExpectedOpaqueSelectionTransaction,
    }
    switch (@typeInfo(OutboundManager.PreparedSelectionBarrier)) {
        .@"opaque" => {},
        else => return error.ExpectedOpaquePreparedSelectionBarrier,
    }
    switch (@typeInfo(OutboundManager.SelectionBarrier)) {
        .@"opaque" => {},
        else => return error.ExpectedOpaqueSelectionBarrier,
    }

    const init_info = @typeInfo(@TypeOf(OutboundManager.init)).@"fn";
    const init_return = @typeInfo(init_info.return_type.?);
    switch (init_return) {
        .error_union => |error_union| try std.testing.expect(
            error_union.payload == *OutboundManager,
        ),
        else => return error.ExpectedOwnedOutboundManagerPointer,
    }

    const begin_info = @typeInfo(
        @TypeOf(OutboundManager.beginPersistedSelections),
    ).@"fn";
    const begin_return = @typeInfo(begin_info.return_type.?);
    switch (begin_return) {
        .error_union => |error_union| switch (@typeInfo(error_union.payload)) {
            .optional => |optional| try std.testing.expect(
                optional.child == *OutboundManager.PersistedSelectionTransaction,
            ),
            else => return error.ExpectedOptionalSelectionTransactionPointer,
        },
        else => return error.ExpectedSelectionTransactionErrorUnion,
    }

    const prepare_barrier_info = @typeInfo(
        @TypeOf(OutboundManager.prepareSelectionBarrier),
    ).@"fn";
    const prepare_barrier_return = @typeInfo(
        prepare_barrier_info.return_type.?,
    );
    switch (prepare_barrier_return) {
        .error_union => |error_union| try std.testing.expect(
            error_union.payload == *OutboundManager.PreparedSelectionBarrier,
        ),
        else => return error.ExpectedPreparedSelectionBarrierErrorUnion,
    }

    const acquire_barrier_info = @typeInfo(
        @TypeOf(OutboundManager.PreparedSelectionBarrier.acquire),
    ).@"fn";
    try std.testing.expect(
        acquire_barrier_info.return_type.? == *OutboundManager.SelectionBarrier,
    );
}

const ManualResourceConfig = struct {
    value: Config,
    proxy_storage: []Proxy,
    group_storage: []config.ProxyGroup,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !ManualResourceConfig {
        const proxy_storage = try allocator.alloc(Proxy, 4097);
        errdefer allocator.free(proxy_storage);
        const group_storage = try allocator.alloc(config.ProxyGroup, 1025);
        errdefer allocator.free(group_storage);

        for (proxy_storage) |*proxy| {
            proxy.* = .{
                .name = "bounded-node",
                .proxy_type = .direct,
                .server = "",
                .port = 0,
            };
        }
        for (group_storage) |*group| {
            group.* = .{
                .name = "bounded-group",
                .group_type = .select,
                .proxies = .empty,
            };
        }

        return .{
            .value = .{
                .allocator = allocator,
                .mode = "rule",
                .log_level = "info",
                .bind_address = "*",
                .proxies = .empty,
                .proxy_groups = .empty,
                .rules = .empty,
            },
            .proxy_storage = proxy_storage,
            .group_storage = group_storage,
            .allocator = allocator,
        };
    }

    fn setCounts(
        self: *ManualResourceConfig,
        proxy_count: usize,
        group_count: usize,
    ) void {
        std.debug.assert(proxy_count <= self.proxy_storage.len);
        std.debug.assert(group_count <= self.group_storage.len);
        self.value.proxies = .{
            .items = self.proxy_storage[0..proxy_count],
            .capacity = self.proxy_storage.len,
        };
        self.value.proxy_groups = .{
            .items = self.group_storage[0..group_count],
            .capacity = self.group_storage.len,
        };
    }

    fn deinit(self: *ManualResourceConfig) void {
        // Repeated scalar fields are borrowed test fixtures, so Config.deinit
        // must not free them individually.
        self.allocator.free(self.proxy_storage);
        self.allocator.free(self.group_storage);
        self.* = undefined;
    }
};

fn makeManySelectGroupConfig(
    allocator: std.mem.Allocator,
    group_count: usize,
) !Config {
    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = .empty,
        .proxy_groups = .empty,
        .rules = .empty,
    };
    errdefer cfg.deinit();

    for (0..group_count) |group_index| {
        var group = config.ProxyGroup{
            .name = try std.fmt.allocPrint(
                allocator,
                "Policy-{d}",
                .{group_index},
            ),
            .group_type = .select,
            .proxies = .empty,
        };
        var group_owned = true;
        errdefer if (group_owned) group.deinit(allocator);
        const member = try allocator.dupe(u8, "DIRECT");
        var member_owned = true;
        errdefer if (member_owned) allocator.free(member);
        try group.proxies.append(allocator, member);
        member_owned = false;
        try cfg.proxy_groups.append(allocator, group);
        group_owned = false;
    }
    return cfg;
}

fn appendIndexedDirectProxy(
    allocator: std.mem.Allocator,
    proxies: *std.ArrayList(Proxy),
    proxy_index: usize,
) !void {
    const name = try std.fmt.allocPrint(
        allocator,
        "indexed-node-{d}",
        .{proxy_index},
    );
    errdefer allocator.free(name);
    const server = try allocator.dupe(u8, "");
    errdefer allocator.free(server);
    proxies.appendAssumeCapacity(.{
        .name = name,
        .proxy_type = .direct,
        .server = server,
        .port = 0,
    });
}

fn makeGroupChainConfig(
    allocator: std.mem.Allocator,
    chain_depth: usize,
    terminal: []const u8,
) !Config {
    std.debug.assert(chain_depth > 0);
    std.debug.assert(chain_depth <= config.proxy_group_count_max);
    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = .empty,
        .proxy_groups = .empty,
        .rules = .empty,
    };
    errdefer cfg.deinit();
    try cfg.proxy_groups.ensureTotalCapacity(allocator, chain_depth);

    for (0..chain_depth) |group_index| {
        var group = config.ProxyGroup{
            .name = try std.fmt.allocPrint(
                allocator,
                "chain-group-{d}",
                .{group_index},
            ),
            .group_type = .select,
            .proxies = .empty,
        };
        var group_owned = true;
        errdefer if (group_owned) group.deinit(allocator);
        const member = if (group_index + 1 < chain_depth)
            try std.fmt.allocPrint(
                allocator,
                "chain-group-{d}",
                .{group_index + 1},
            )
        else
            try allocator.dupe(u8, terminal);
        var member_owned = true;
        errdefer if (member_owned) allocator.free(member);
        try group.proxies.append(allocator, member);
        member_owned = false;
        cfg.proxy_groups.appendAssumeCapacity(group);
        group_owned = false;
    }
    return cfg;
}

fn makeNearMaximumIndexedConfig(allocator: std.mem.Allocator) !Config {
    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = .empty,
        .proxy_groups = .empty,
        .rules = .empty,
    };
    errdefer cfg.deinit();
    try cfg.proxies.ensureTotalCapacity(allocator, config.proxy_count_max);
    try cfg.proxy_groups.ensureTotalCapacity(
        allocator,
        config.proxy_group_count_max,
    );

    for (0..config.proxy_count_max) |proxy_index| {
        try appendIndexedDirectProxy(
            allocator,
            &cfg.proxies,
            proxy_index,
        );
    }

    // Deliberately exceed the removed historical depth-10 cutoff without
    // coinciding with the public 1024-group boundary test below.
    const chain_depth: usize = 11;
    const chain_start = config.proxy_group_count_max - chain_depth;
    for (0..config.proxy_group_count_max) |group_index| {
        var group = config.ProxyGroup{
            .name = try std.fmt.allocPrint(
                allocator,
                "indexed-group-{d}",
                .{group_index},
            ),
            .group_type = .select,
            .proxies = .empty,
        };
        var group_owned = true;
        errdefer if (group_owned) group.deinit(allocator);
        const member = if (group_index < chain_start)
            try allocator.dupe(u8, "DIRECT")
        else if (group_index + 1 < config.proxy_group_count_max)
            try std.fmt.allocPrint(
                allocator,
                "indexed-group-{d}",
                .{group_index + 1},
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "indexed-node-{d}",
                .{config.proxy_count_max - 1},
            );
        var member_owned = true;
        errdefer if (member_owned) allocator.free(member);
        try group.proxies.append(allocator, member);
        member_owned = false;
        cfg.proxy_groups.appendAssumeCapacity(group);
        group_owned = false;
    }
    return cfg;
}

fn expectProxyStreamError(expected: anyerror, result: anyerror!ProxyStream) !void {
    if (result) |value| {
        var stream = value;
        stream.close();
        return error.TestExpectedError;
    } else |actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

fn expectBeginPersistedSelectionsError(
    expected: anyerror,
    manager: *OutboundManager,
    selections: []const config_catalog.Selection,
    generation: u64,
) !void {
    if (manager.beginPersistedSelections(selections, generation)) |maybe| {
        if (maybe) |transaction| transaction.deinit();
        return error.TestExpectedError;
    } else |actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

fn expectCommitPersistedSelectionsError(
    expected: anyerror,
    manager: *OutboundManager,
    selections: []const config_catalog.Selection,
    generation: u64,
) !void {
    if (manager.commitPersistedSelections(selections, generation)) |_| {
        return error.TestExpectedError;
    } else |actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

fn expectBeginPersistedSelectionsConflict(
    manager: *OutboundManager,
    selections: []const config_catalog.Selection,
    generation: u64,
) !void {
    if (try manager.beginPersistedSelections(selections, generation)) |transaction| {
        transaction.deinit();
        return error.TestExpectedEqual;
    }
}

test "manager init rejects manual config maxima plus one before allocation" {
    const allocator = std.testing.allocator;
    var manual = try ManualResourceConfig.init(allocator);
    defer manual.deinit();

    manual.setCounts(4097, 0);
    manual.proxy_storage[0].proxy_type = .http;
    var proxy_failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.ProxyCountLimitExceeded,
        OutboundManager.initWithKey(
            proxy_failing.allocator(),
            &manual.value,
            "must-not-allocate",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), proxy_failing.allocations);
    try std.testing.expect(!proxy_failing.has_induced_failure);

    manual.proxy_storage[0].proxy_type = .direct;
    manual.setCounts(0, 1025);
    manual.group_storage[0].name = "DIRECT";
    var group_failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.ProxyGroupCountLimitExceeded,
        OutboundManager.initWithKey(
            group_failing.allocator(),
            &manual.value,
            "must-not-allocate",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), group_failing.allocations);
    try std.testing.expect(!group_failing.has_induced_failure);
}

fn managerIndexAllocationFixture(
    allocator: std.mem.Allocator,
    cfg: *const Config,
) !void {
    const manager = try OutboundManager.initWithKey(
        allocator,
        cfg,
        "allocation-fixture",
    );
    manager.deinit();
}

test "near-maximum tail capability failures precede first manager allocation" {
    const allocator = std.testing.allocator;
    var manual = try ManualResourceConfig.init(allocator);
    defer manual.deinit();
    manual.setCounts(
        config.proxy_count_max,
        config.proxy_group_count_max,
    );

    manual.proxy_storage[config.proxy_count_max - 1].proxy_type = .http;
    var proxy_failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.UnsupportedProxyType,
        OutboundManager.initWithKey(
            proxy_failing.allocator(),
            &manual.value,
            "must-not-allocate",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), proxy_failing.allocations);
    try std.testing.expect(!proxy_failing.has_induced_failure);

    manual.proxy_storage[config.proxy_count_max - 1].proxy_type = .direct;
    manual.group_storage[config.proxy_group_count_max - 1].group_type =
        .url_test;
    var group_failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.UnsupportedProxyGroupType,
        OutboundManager.initWithKey(
            group_failing.allocator(),
            &manual.value,
            "must-not-allocate",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), group_failing.allocations);
    try std.testing.expect(!group_failing.has_induced_failure);
}

test "manager index construction unwinds every allocation failure" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxies:
        \\  - { name: first, type: direct }
        \\  - { name: second, type: reject }
        \\proxy-groups:
        \\  - { name: first-group, type: select, proxies: [first] }
        \\  - { name: second-group, type: select, proxies: [second] }
    );
    defer cfg.deinit();
    try std.testing.checkAllAllocationFailures(
        allocator,
        managerIndexAllocationFixture,
        .{&cfg},
    );
}

test "large config literal TCP and UDP avoid complete capability scans" {
    // Exercise both data paths at the public maxima. The probe distinguishes a
    // complete scan from the constant-size initialization-proof check.
    const allocator = std.testing.allocator;
    var manual = try ManualResourceConfig.init(allocator);
    defer manual.deinit();
    manual.setCounts(
        config.proxy_count_max,
        config.proxy_group_count_max,
    );

    const manager = try OutboundManager.init(allocator, &manual.value);
    defer manager.deinit();
    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    const listen_address = try net.Address.parseIp4("127.0.0.1", 0);
    var target_server = try net.listenReuseAddr(listen_address);
    defer target_server.deinit();

    var stream = try manager.connect(
        "DIRECT",
        "127.0.0.1",
        target_server.listen_address.getPort(),
    );
    stream.close();
    const accepted = try target_server.accept();
    accepted.stream.close();
    try expectProxyStreamError(
        error.UdpNotSupportedForDirect,
        manager.connectUdp("DIRECT"),
    );

    try std.testing.expectEqual(@as(u32, 0), probe.complete_scans);
    try std.testing.expectEqual(@as(u32, 0), probe.proxies_visited);
    try std.testing.expectEqual(@as(u32, 0), probe.groups_visited);
    try std.testing.expectEqual(@as(u32, 0), probe.selected_proxy_gates);
    try std.testing.expectEqual(@as(u32, 0), probe.group_index_lookups);
    try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);
    try std.testing.expectEqual(@as(u32, 0), probe.linear_config_scans);
}

test "near-maximum eleven-layer tail uses indexed TCP and UDP lookups" {
    const allocator = std.testing.allocator;
    var cfg = try makeNearMaximumIndexedConfig(allocator);
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    const first_chain_group = config.proxy_group_count_max - 11;
    const policy = try std.fmt.allocPrint(
        allocator,
        "indexed-group-{d}",
        .{first_chain_group},
    );
    defer allocator.free(policy);

    const listen_address = try net.Address.parseIp4("127.0.0.1", 0);
    var target_server = try net.listenReuseAddr(listen_address);
    defer target_server.deinit();
    var stream = try manager.connect(
        policy,
        "127.0.0.1",
        target_server.listen_address.getPort(),
    );
    stream.close();
    const accepted = try target_server.accept();
    accepted.stream.close();

    try std.testing.expectEqual(@as(u32, 0), probe.complete_scans);
    try std.testing.expectEqual(@as(u32, 0), probe.linear_config_scans);
    try std.testing.expectEqual(@as(u32, 12), probe.group_index_lookups);
    try std.testing.expectEqual(@as(u32, 1), probe.proxy_index_lookups);
    try std.testing.expectEqual(@as(u32, 1), probe.selected_proxy_gates);

    probe = .{};
    try expectProxyStreamError(
        error.UdpNotSupportedForDirect,
        manager.connectUdp(policy),
    );
    try std.testing.expectEqual(@as(u32, 0), probe.complete_scans);
    try std.testing.expectEqual(@as(u32, 0), probe.linear_config_scans);
    try std.testing.expectEqual(@as(u32, 12), probe.group_index_lookups);
    try std.testing.expectEqual(@as(u32, 1), probe.proxy_index_lookups);
    try std.testing.expectEqual(@as(u32, 1), probe.selected_proxy_gates);
}

test "eleven nested groups resolve for TCP and UDP at actual depth cost" {
    const allocator = std.testing.allocator;
    var cfg = try makeGroupChainConfig(allocator, 11, "DIRECT");
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    const listen_address = try net.Address.parseIp4("127.0.0.1", 0);
    var target_server = try net.listenReuseAddr(listen_address);
    defer target_server.deinit();
    var stream = try manager.connect(
        "chain-group-0",
        "127.0.0.1",
        target_server.listen_address.getPort(),
    );
    stream.close();
    const accepted = try target_server.accept();
    accepted.stream.close();
    try std.testing.expectEqual(@as(u32, 11), probe.group_index_lookups);
    try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);

    probe = .{};
    try expectProxyStreamError(
        error.UdpNotSupportedForDirect,
        manager.connectUdp("chain-group-0"),
    );
    try std.testing.expectEqual(@as(u32, 11), probe.group_index_lookups);
    try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);
}

test "maximum 1024 unique nested groups resolve for TCP and UDP" {
    const allocator = std.testing.allocator;
    var cfg = try makeGroupChainConfig(
        allocator,
        config.proxy_group_count_max,
        "REJECT",
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    try expectProxyStreamError(
        error.ConnectionRejected,
        manager.connect("chain-group-0", "does-not-dial.invalid", 443),
    );
    try std.testing.expectEqual(
        @as(u32, config.proxy_group_count_max),
        probe.group_index_lookups,
    );
    try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);

    probe = .{};
    try expectProxyStreamError(
        error.ConnectionRejected,
        manager.connectUdp("chain-group-0"),
    );
    try std.testing.expectEqual(
        @as(u32, config.proxy_group_count_max),
        probe.group_index_lookups,
    );
    try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);
}

test "a 1025th group hit returns the explicit resolution limit" {
    const allocator = std.testing.allocator;
    var cfg = try makeGroupChainConfig(
        allocator,
        config.proxy_group_count_max,
        "chain-group-0",
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    try expectProxyStreamError(
        error.ProxyGroupResolutionLimit,
        manager.connect("chain-group-0", "does-not-dial.invalid", 443),
    );
    try std.testing.expectEqual(
        @as(u32, config.proxy_group_count_max + 1),
        probe.group_index_lookups,
    );
    try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);

    probe = .{};
    try expectProxyStreamError(
        error.ProxyGroupResolutionLimit,
        manager.connectUdp("chain-group-0"),
    );
    try std.testing.expectEqual(
        @as(u32, config.proxy_group_count_max + 1),
        probe.group_index_lookups,
    );
    try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);
}

test "self and two-group cycles fail bounded for TCP and UDP" {
    const allocator = std.testing.allocator;
    const Case = struct {
        source: []const u8,
        policy: []const u8,
        expected_lookups: u32,
    };
    const cases = [_]Case{
        .{
            .source =
            \\proxy-groups:
            \\  - { name: self, type: select, proxies: [self] }
            ,
            .policy = "self",
            .expected_lookups = 2,
        },
        .{
            .source =
            \\proxy-groups:
            \\  - { name: first, type: select, proxies: [second] }
            \\  - { name: second, type: select, proxies: [first] }
            ,
            .policy = "first",
            .expected_lookups = 3,
        },
    };

    for (cases) |case| {
        var cfg = try config.parseDocument(allocator, case.source);
        defer cfg.deinit();
        const manager = try OutboundManager.init(allocator, &cfg);
        defer manager.deinit();
        var probe: CapabilityValidationProbe = .{};
        managerImpl(manager).capability_validation_probe = &probe;
        defer managerImpl(manager).capability_validation_probe = null;

        try expectProxyStreamError(
            error.ProxyGroupResolutionCycle,
            manager.connect(case.policy, "does-not-dial.invalid", 443),
        );
        try std.testing.expectEqual(
            case.expected_lookups,
            probe.group_index_lookups,
        );
        try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);

        // The resolver error must release the selection mutex before returning.
        probe = .{};
        try expectProxyStreamError(
            error.ProxyGroupResolutionCycle,
            manager.connectUdp(case.policy),
        );
        try std.testing.expectEqual(
            case.expected_lookups,
            probe.group_index_lookups,
        );
        try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);
    }
}

test "nested selected literals terminate TCP and UDP resolution immediately" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - { name: outer, type: select, proxies: [inner, DIRECT] }
        \\  - { name: inner, type: select, proxies: [DIRECT, REJECT] }
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    try std.testing.expect(try manager.applyTransientSelection(
        "outer",
        "inner",
    ));
    try std.testing.expect(try manager.applyTransientSelection(
        "inner",
        "REJECT",
    ));
    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    try expectProxyStreamError(
        error.ConnectionRejected,
        manager.connect("outer", "does-not-dial.invalid", 443),
    );
    try std.testing.expectEqual(@as(u32, 2), probe.group_index_lookups);
    try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);

    probe = .{};
    try expectProxyStreamError(
        error.ConnectionRejected,
        manager.connectUdp("outer"),
    );
    try std.testing.expectEqual(@as(u32, 2), probe.group_index_lookups);
    try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);
}

test "unknown nested terminal retains final ProxyNotFound lookup" {
    const allocator = std.testing.allocator;
    var cfg = try makeGroupChainConfig(allocator, 2, "missing-node");
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    try expectProxyStreamError(
        error.ProxyNotFound,
        manager.connect("chain-group-0", "does-not-dial.invalid", 443),
    );
    try std.testing.expectEqual(@as(u32, 3), probe.group_index_lookups);
    try std.testing.expectEqual(@as(u32, 1), probe.proxy_index_lookups);

    probe = .{};
    try expectProxyStreamError(
        error.ProxyNotFound,
        manager.connectUdp("chain-group-0"),
    );
    try std.testing.expectEqual(@as(u32, 3), probe.group_index_lookups);
    try std.testing.expectEqual(@as(u32, 1), probe.proxy_index_lookups);
}

test "manager rejects reserved proxy names before allocation or dial" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "DIRECT", "REJECT" }) |reserved_name| {
        const document = try std.fmt.allocPrint(
            allocator,
            "mixed-port: 7890\nproxies:\n  - name: {s}\n    type: ss\n    server: 127.0.0.1\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\nrules:\n  - MATCH,{s}\n",
            .{ reserved_name, reserved_name },
        );
        defer allocator.free(document);
        var cfg = try config.parseDocument(allocator, document);
        defer cfg.deinit();

        var failing = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = 0,
        });
        try std.testing.expectError(
            error.ReservedProxyName,
            OutboundManager.initWithKey(
                failing.allocator(),
                &cfg,
                "would-allocate",
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }

    for ([_][]const u8{ "DIRECT", "REJECT" }) |reserved_name| {
        const document = try std.fmt.allocPrint(
            allocator,
            "mixed-port: 7890\nproxies: []\nproxy-groups:\n  - name: {s}\n    type: select\n    proxies: [DIRECT]\nrules:\n  - MATCH,{s}\n",
            .{ reserved_name, reserved_name },
        );
        defer allocator.free(document);
        var cfg = try config.parseDocument(allocator, document);
        defer cfg.deinit();

        var failing = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = 0,
        });
        try std.testing.expectError(
            error.ReservedProxyName,
            OutboundManager.initWithKey(
                failing.allocator(),
                &cfg,
                "would-allocate",
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }

    var literals = try config.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies: []
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
        \\rules:
        \\  - MATCH,Policy
    );
    defer literals.deinit();
    const literals_manager = try OutboundManager.init(allocator, &literals);
    literals_manager.deinit();

    const listen_address = try net.Address.parseIp4("127.0.0.1", 0);
    var target_server = try net.listenReuseAddr(listen_address);
    defer target_server.deinit();
    const dial_document = try std.fmt.allocPrint(
        allocator,
        "mixed-port: 7890\nproxies:\n  - name: DIRECT\n    type: ss\n    server: 127.0.0.1\n    port: {d}\n    cipher: aes-128-gcm\n    password: secret\nrules:\n  - MATCH,DIRECT\n",
        .{target_server.listen_address.getPort()},
    );
    defer allocator.free(dial_document);
    var cfg = try config.parseDocument(allocator, dial_document);
    defer cfg.deinit();
    try std.testing.expectError(
        error.ReservedProxyName,
        OutboundManager.init(allocator, &cfg),
    );
    var descriptors = [_]std.posix.pollfd{.{
        .fd = target_server.fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(
        @as(usize, 0),
        try std.posix.poll(&descriptors, 0),
    );
}

test "manager member limit accepts max and rejects max plus one before allocation" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT]
    );
    defer cfg.deinit();
    const members = try allocator.alloc(
        []const u8,
        config.proxy_group_member_count_max + 1,
    );
    defer allocator.free(members);
    @memset(members, "DIRECT");
    const original_members = cfg.proxy_groups.items[0].proxies;
    defer cfg.proxy_groups.items[0].proxies = original_members;
    cfg.proxy_groups.items[0].proxies = .{
        .items = members[0..config.proxy_group_member_count_max],
        .capacity = members.len,
    };

    {
        const manager = try OutboundManager.init(allocator, &cfg);
        defer manager.deinit();
    }

    // End the borrow before changing the fixture to its rejecting shape.
    cfg.proxy_groups.items[0].proxies.items = members;
    var failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.ProxyGroupMemberCountLimitExceeded,
        OutboundManager.initWithKey(
            failing.allocator(),
            &cfg,
            "must-not-allocate",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "persisted selection input accepts max and rejects max plus one fail first" {
    const allocator = std.testing.allocator;
    var maximum_cfg = try makeManySelectGroupConfig(
        allocator,
        config.persisted_selection_count_max,
    );
    defer maximum_cfg.deinit();
    const maximum = try allocator.alloc(
        config_catalog.Selection,
        config.persisted_selection_count_max,
    );
    defer allocator.free(maximum);
    for (maximum_cfg.proxy_groups.items, maximum) |group, *selection| {
        selection.* = .{
            .group = group.name,
            .proxy = group.proxies.items[0],
        };
    }
    const accepting = try OutboundManager.init(allocator, &maximum_cfg);
    defer accepting.deinit();
    try std.testing.expect(try accepting.preparePersistedSelections(
        maximum,
        1,
    ));

    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT]
    );
    defer cfg.deinit();
    const desired = try allocator.alloc(
        config_catalog.Selection,
        config.persisted_selection_count_max + 1,
    );
    defer allocator.free(desired);
    @memset(desired, .{ .group = "Policy", .proxy = "DIRECT" });
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const rejecting = try OutboundManager.init(failing.allocator(), &cfg);
    defer rejecting.deinit();
    const manager_allocations = failing.allocations;
    failing.fail_index = failing.alloc_index;
    try expectBeginPersistedSelectionsError(
        error.PersistedSelectionCountLimitExceeded,
        rejecting,
        desired,
        1,
    );
    try std.testing.expectError(
        error.PersistedSelectionCountLimitExceeded,
        rejecting.preparePersistedSelections(desired, 1),
    );
    try std.testing.expectError(
        error.PersistedSelectionCountLimitExceeded,
        rejecting.applyPersistedSelections(desired, 1),
    );
    try expectCommitPersistedSelectionsError(
        error.PersistedSelectionCountLimitExceeded,
        rejecting,
        desired,
        1,
    );
    try std.testing.expectEqual(manager_allocations, failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

fn persistedSelectionPlanAllocationFixture(
    allocator: std.mem.Allocator,
    cfg: *const Config,
) !void {
    const manager = try OutboundManager.init(allocator, cfg);
    defer manager.deinit();
    const desired = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "DIRECT",
    }};
    const transaction = manager.beginPersistedSelections(
        &desired,
        1,
    ) catch |err| {
        try std.testing.expectEqual(@as(u64, 0), managerImpl(manager).selection_generation);
        try std.testing.expectEqual(@as(u32, 0), managerImpl(manager).group_selections.count());
        return err;
    } orelse return error.TestExpectedEqual;
    transaction.deinit();
    try std.testing.expectEqual(@as(u64, 0), managerImpl(manager).selection_generation);
    try std.testing.expectEqual(@as(u32, 0), managerImpl(manager).group_selections.count());
}

test "persisted selection prepare releases every allocation failure path" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    try std.testing.checkAllAllocationFailures(
        allocator,
        persistedSelectionPlanAllocationFixture,
        .{&cfg},
    );
}

test "selection transaction wrapper allocation precedes lock acquisition" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - { name: Policy, type: select, proxies: [DIRECT] }
    );
    defer cfg.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const manager = try OutboundManager.init(failing.allocator(), &cfg);
    defer manager.deinit();

    const prepared_barrier = try manager.prepareSelectionBarrier();
    const barrier = prepared_barrier.acquire();
    defer barrier.deinit();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        manager.beginPersistedSelections(&.{}, 0),
    );
    try std.testing.expect(failing.has_induced_failure);
}

test "selection transaction null and allocation errors release owned wrapper" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - { name: Policy, type: select, proxies: [DIRECT] }
    );
    defer cfg.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const manager = try OutboundManager.init(failing.allocator(), &cfg);
    defer manager.deinit();

    const invalid = [_]config_catalog.Selection{.{
        .group = "missing",
        .proxy = "DIRECT",
    }};
    try std.testing.expect((try manager.beginPersistedSelections(
        &invalid,
        1,
    )) == null);

    const valid = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "DIRECT",
    }};
    const allocations_before = failing.allocations;
    const deallocations_before = failing.deallocations;
    // The public handle allocation succeeds; the following replacement-map
    // allocation fails and must destroy that already-owned handle.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(
        error.OutOfMemory,
        manager.beginPersistedSelections(&valid, 1),
    );
    try std.testing.expectEqual(
        allocations_before + 1,
        failing.allocations,
    );
    try std.testing.expectEqual(
        deallocations_before + 1,
        failing.deallocations,
    );
}

test "selection barrier prepare failure precedes locking and acquire is infallible" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator, "proxy-groups: []\n");
    defer cfg.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const manager = try OutboundManager.init(failing.allocator(), &cfg);
    defer manager.deinit();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        manager.prepareSelectionBarrier(),
    );
    try std.testing.expect(failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
    failing.has_induced_failure = false;
    const prepared = try manager.prepareSelectionBarrier();
    const allocations_before_acquire = failing.allocations;
    failing.fail_index = failing.alloc_index;
    const barrier = prepared.acquire();
    try std.testing.expectEqual(
        allocations_before_acquire,
        failing.allocations,
    );
    try std.testing.expect(!failing.has_induced_failure);
    barrier.deinit();
}

test "commitPersistedSelections applies legal nonempty and empty plans" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    const desired = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "REJECT",
    }};
    try std.testing.expect(try manager.commitPersistedSelections(
        &desired,
        1,
    ));
    try std.testing.expectEqualStrings(
        "REJECT",
        managerImpl(manager).group_selections.get("Policy").?,
    );
    try std.testing.expect(try manager.commitPersistedSelections(&.{}, 2));
    try std.testing.expectEqual(@as(u32, 0), managerImpl(manager).group_selections.count());
    try std.testing.expectEqual(@as(u64, 2), managerImpl(manager).selection_generation);
}

test "large to empty public commit performs fixed map swaps in the lock" {
    const allocator = std.testing.allocator;
    const selection_count = config.persisted_selection_count_max;
    var cfg = try makeManySelectGroupConfig(allocator, selection_count);
    defer cfg.deinit();
    const desired = try allocator.alloc(
        config_catalog.Selection,
        selection_count,
    );
    defer allocator.free(desired);
    for (cfg.proxy_groups.items, desired) |group, *selection| {
        selection.* = .{
            .group = group.name,
            .proxy = group.proxies.items[0],
        };
    }
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    try std.testing.expect(try manager.commitPersistedSelections(
        desired,
        1,
    ));
    try std.testing.expect(
        managerImpl(manager).group_selections.capacity() >= selection_count,
    );

    var probe: Impl.SelectionCommitProbe = .{};
    managerImpl(manager).selection_commit_probe = &probe;
    defer managerImpl(manager).selection_commit_probe = null;
    try std.testing.expect(try manager.commitPersistedSelections(&.{}, 2));

    try std.testing.expect(probe.old_selection_capacity >= selection_count);
    try std.testing.expect(probe.old_source_capacity >= selection_count);
    try std.testing.expectEqual(@as(u8, 2), probe.critical_map_swaps);
    try std.testing.expect(probe.old_maps_deinitialized_after_unlock);
    try std.testing.expectEqual(@as(u32, 0), managerImpl(manager).group_selections.count());
    try std.testing.expectEqual(@as(u32, 0), managerImpl(manager).group_selections.capacity());
    try std.testing.expectEqual(
        @as(u32, 0),
        managerImpl(manager).group_selection_sources.capacity(),
    );
    try std.testing.expectEqual(@as(u64, 2), managerImpl(manager).selection_generation);
}

test "commitPersistedSelections rejects an invalid plan without advancing generation" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    const invalid = [_]config_catalog.Selection{
        .{ .group = "Policy", .proxy = "DIRECT" },
        .{ .group = "Policy", .proxy = "missing" },
    };
    try std.testing.expect(!try manager.commitPersistedSelections(
        &invalid,
        7,
    ));
    try std.testing.expectEqual(
        @as(u64, 0),
        manager.persistedSelectionGeneration(),
    );
    const snapshot = try manager.snapshotSelections(allocator);
    defer runtime_selection.freeSelectionEntries(allocator, snapshot);
    try std.testing.expectEqual(@as(usize, 0), snapshot.len);
}

test "snapshotSelections propagates every allocation seam without partial success" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    try std.testing.expect(try manager.applyTransientSelection(
        "Policy",
        "DIRECT",
    ));

    const failure_cases = [_]std.testing.FailingAllocator.Config{
        .{ .fail_index = 0 }, // group dupe
        .{ .fail_index = 1 }, // proxy dupe
        .{ .fail_index = 2 }, // entries append backing allocation
        // Force toOwnedSlice's remap fallback, then fail its exact-size alloc.
        .{ .fail_index = 3, .resize_fail_index = 0 },
    };
    for (failure_cases) |failure| {
        var probe: CapabilityValidationProbe = .{};
        managerImpl(manager).capability_validation_probe = &probe;
        defer managerImpl(manager).capability_validation_probe = null;
        var failing = std.testing.FailingAllocator.init(allocator, failure);
        try std.testing.expectError(
            error.OutOfMemory,
            manager.snapshotSelections(failing.allocator()),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocations, failing.deallocations);
        try std.testing.expectEqual(@as(u32, 1), probe.complete_scans);
        try std.testing.expectEqual(@as(u32, 1), probe.groups_visited);
        managerImpl(manager).capability_validation_probe = null;
    }

    const snapshot = try manager.snapshotSelections(allocator);
    defer runtime_selection.freeSelectionEntries(allocator, snapshot);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqualStrings("Policy", snapshot[0].group);
    try std.testing.expectEqualStrings("DIRECT", snapshot[0].proxy);
    try std.testing.expectEqual(
        runtime_selection.SelectionSource.transient,
        snapshot[0].source,
    );
}

test "selection APIs retain bounded complete capability validation" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    try std.testing.expect(try manager.selectProxy("Policy", "DIRECT"));
    try std.testing.expect(try manager.applyPersistedSelection(
        "Policy",
        "DIRECT",
    ));
    try std.testing.expect(try manager.applyTransientSelection(
        "Policy",
        "DIRECT",
    ));
    const desired = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "DIRECT",
    }};
    try std.testing.expect(try manager.preparePersistedSelections(
        &desired,
        1,
    ));

    try std.testing.expectEqual(@as(u32, 4), probe.complete_scans);
    try std.testing.expectEqual(@as(u32, 4), probe.groups_visited);
    try std.testing.expectEqual(@as(u32, 0), probe.selected_proxy_gates);
}

test "begin accepts only exact idempotent plans at the current generation" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    const initial = (try manager.beginPersistedSelections(&.{}, 0)).?;
    try std.testing.expectEqual(@as(u64, 0), initial.preparedGeneration());
    initial.deinit();
    try std.testing.expect(try manager.commitPersistedSelections(&.{}, 0));

    const direct = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "DIRECT",
    }};
    try std.testing.expect(try manager.commitPersistedSelections(&direct, 1));
    const identical = (try manager.beginPersistedSelections(&direct, 1)).?;
    identical.deinit();
    try std.testing.expect(try manager.commitPersistedSelections(&direct, 1));

    const reject = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "REJECT",
    }};
    try expectBeginPersistedSelectionsConflict(manager, &reject, 1);
    try std.testing.expect(!try manager.commitPersistedSelections(&reject, 1));
    try expectBeginPersistedSelectionsConflict(manager, &.{}, 1);
    try std.testing.expectEqual(@as(u64, 1), managerImpl(manager).selection_generation);
    try std.testing.expectEqualStrings(
        "DIRECT",
        managerImpl(manager).group_selections.get("Policy").?,
    );
    try std.testing.expectEqual(
        runtime_selection.SelectionSource.persisted,
        managerImpl(manager).group_selection_sources.get("Policy").?,
    );

    const transient = try OutboundManager.init(allocator, &cfg);
    defer transient.deinit();
    try std.testing.expect(try transient.applyTransientSelection(
        "Policy",
        "DIRECT",
    ));
    try expectBeginPersistedSelectionsConflict(transient, &direct, 0);
    try std.testing.expect(!try transient.commitPersistedSelections(
        &direct,
        0,
    ));
    try std.testing.expectEqual(
        runtime_selection.SelectionSource.transient,
        managerImpl(transient).group_selection_sources.get("Policy").?,
    );
}

test "prepare rejects duplicate selection groups before mutation" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    const duplicate_same = [_]config_catalog.Selection{
        .{ .group = "Policy", .proxy = "DIRECT" },
        .{ .group = "Policy", .proxy = "DIRECT" },
    };
    const duplicate_different = [_]config_catalog.Selection{
        .{ .group = "Policy", .proxy = "DIRECT" },
        .{ .group = "Policy", .proxy = "REJECT" },
    };
    for ([_][]const config_catalog.Selection{
        &duplicate_same,
        &duplicate_different,
    }) |duplicate| {
        try expectBeginPersistedSelectionsConflict(
            manager,
            duplicate,
            1,
        );
        try std.testing.expect(!try manager.preparePersistedSelections(
            duplicate,
            1,
        ));
        try std.testing.expect(!try manager.commitPersistedSelections(
            duplicate,
            1,
        ));
    }
    try std.testing.expectEqual(@as(u64, 0), managerImpl(manager).selection_generation);
    try std.testing.expectEqual(@as(u32, 0), managerImpl(manager).group_selections.count());
    try std.testing.expectEqual(
        @as(u32, 0),
        managerImpl(manager).group_selection_sources.count(),
    );
}

test "begin rejects a stale selection generation" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    const desired = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "DIRECT",
    }};

    try std.testing.expect(try manager.commitPersistedSelections(
        &desired,
        2,
    ));
    try expectBeginPersistedSelectionsConflict(manager, &desired, 1);
    try std.testing.expectEqual(@as(u64, 2), managerImpl(manager).selection_generation);
}

test "prepared transaction commit is infallible allocation-free and input-stable" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const manager = try OutboundManager.init(failing.allocator(), &cfg);
    defer manager.deinit();
    var desired = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "DIRECT",
    }};
    const transaction = (try manager.beginPersistedSelections(
        &desired,
        1,
    )).?;

    // The transaction borrows only immutable Config storage, not this caller
    // input slice, so changing the request after prepare cannot change commit.
    desired[0].proxy = "missing-after-prepare";
    failing.fail_index = failing.alloc_index;
    transaction.commit();

    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 1), managerImpl(manager).selection_generation);
    try std.testing.expectEqualStrings(
        "DIRECT",
        managerImpl(manager).group_selections.get("Policy").?,
    );
}

test "descriptor publish rejects mismatched prepared generation before mutation" {
    const allocator = std.testing.allocator;
    const descriptor = @import("../../runtime_descriptor.zig");
    const identity_mod = @import("../../config_identity.zig");
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    try std.testing.expect(try manager.applyTransientSelection(
        "Policy",
        "DIRECT",
    ));

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = descriptor.Store.init(allocator, temporary.dir);
    const nonce = try descriptor.Nonce.parseHex(
        "11111111111111111111111111111111",
    );
    const revision = try identity_mod.Revision.parseHex(
        "00112233445566778899aabbccddeeff",
    );
    const identity: descriptor.Identity = .{
        .key = "home",
        .revision = revision,
    };
    try std.testing.expect((try store.publish(.missing, .{
        .pid = 1,
        .nonce = nonce,
        .identity = identity,
    })) == .committed);

    const desired = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "REJECT",
    }};
    const transaction = (try manager.beginPersistedSelections(
        &desired,
        1,
    )).?;
    try std.testing.expectError(
        error.SelectionGenerationMismatch,
        runtime_selection.publishPreparedSelectionTransaction(
            transaction,
            store,
            .{ .state = .{
                .nonce = nonce,
                .generation = 0,
            } },
            .{
                .pid = 1,
                .nonce = nonce,
                .identity = identity,
                .generation = 2,
            },
        ),
    );

    var observed = (try store.observe()) orelse return error.TestExpectedEqual;
    defer observed.deinit();
    try std.testing.expectEqual(@as(u64, 0), observed.generation);
    try std.testing.expectEqual(@as(u64, 0), managerImpl(manager).selection_generation);
    const snapshot = try manager.snapshotSelections(allocator);
    defer runtime_selection.freeSelectionEntries(allocator, snapshot);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqualStrings("DIRECT", snapshot[0].proxy);
    try std.testing.expectEqual(
        runtime_selection.SelectionSource.transient,
        snapshot[0].source,
    );
}

test "descriptor error conflict commit and durability paths keep generations atomic" {
    const allocator = std.testing.allocator;
    const descriptor = @import("../../runtime_descriptor.zig");
    const identity_mod = @import("../../config_identity.zig");
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    try std.testing.expect(try manager.applyTransientSelection(
        "Policy",
        "DIRECT",
    ));

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = descriptor.Store.init(allocator, temporary.dir);
    const first_nonce = try descriptor.Nonce.parseHex(
        "11111111111111111111111111111111",
    );
    const second_nonce = try descriptor.Nonce.parseHex(
        "22222222222222222222222222222222",
    );
    const revision = try identity_mod.Revision.parseHex(
        "00112233445566778899aabbccddeeff",
    );
    const identity: descriptor.Identity = .{
        .key = "home",
        .revision = revision,
    };
    try std.testing.expect((try store.publish(.missing, .{
        .pid = 1,
        .nonce = first_nonce,
        .identity = identity,
    })) == .committed);
    const reject = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "REJECT",
    }};

    {
        const transaction = (try manager.beginPersistedSelections(
            &reject,
            1,
        )).?;
        const completion = try runtime_selection
            .publishPreparedSelectionTransaction(
            transaction,
            store,
            .{ .state = .{
                .nonce = second_nonce,
                .generation = 0,
            } },
            .{
                .pid = 1,
                .nonce = second_nonce,
                .identity = identity,
                .generation = 1,
            },
        );
        try std.testing.expectEqual(
            runtime_selection.DescriptorSelectionCompletion.conflict,
            completion,
        );
    }
    try std.testing.expectEqual(@as(u64, 0), managerImpl(manager).selection_generation);
    try std.testing.expectEqualStrings(
        "DIRECT",
        managerImpl(manager).group_selections.get("Policy").?,
    );

    {
        const transaction = (try manager.beginPersistedSelections(
            &reject,
            1,
        )).?;
        try std.testing.expectError(
            error.InvalidRuntimeDescriptor,
            runtime_selection.publishPreparedSelectionTransaction(
                transaction,
                store,
                .{ .state = .{
                    .nonce = first_nonce,
                    .generation = 0,
                } },
                .{
                    .pid = 0,
                    .nonce = first_nonce,
                    .identity = identity,
                    .generation = 1,
                },
            ),
        );
    }
    try std.testing.expectEqual(@as(u64, 0), managerImpl(manager).selection_generation);

    {
        const transaction = (try manager.beginPersistedSelections(
            &reject,
            1,
        )).?;
        const completion = try runtime_selection
            .publishPreparedSelectionTransaction(
            transaction,
            store,
            .{ .state = .{
                .nonce = first_nonce,
                .generation = 0,
            } },
            .{
                .pid = 1,
                .nonce = first_nonce,
                .identity = identity,
                .generation = 1,
            },
        );
        try std.testing.expectEqual(
            runtime_selection.DescriptorSelectionCompletion.applied,
            completion,
        );
    }
    try std.testing.expectEqual(@as(u64, 1), managerImpl(manager).selection_generation);
    try std.testing.expectEqualStrings(
        "REJECT",
        managerImpl(manager).group_selections.get("Policy").?,
    );

    const direct = [_]config_catalog.Selection{.{
        .group = "Policy",
        .proxy = "DIRECT",
    }};
    {
        const transaction = (try manager.beginPersistedSelections(
            &direct,
            2,
        )).?;
        try std.testing.expect((try store.publish(.{ .state = .{
            .nonce = first_nonce,
            .generation = 1,
        } }, .{
            .pid = 1,
            .nonce = first_nonce,
            .identity = identity,
            .generation = 2,
        })) == .committed);
        const completion = runtime_selection.completeSelectionDescriptorPublish(
            transaction,
            .{ .durability_uncertain = error.TestDurabilityUncertain },
        );
        try std.testing.expectEqual(
            runtime_selection.DescriptorSelectionCompletion.applied,
            completion,
        );
    }
    var observed = (try store.observe()) orelse return error.TestExpectedEqual;
    defer observed.deinit();
    try std.testing.expectEqual(@as(u64, 2), observed.generation);
    try std.testing.expectEqual(@as(u64, 2), managerImpl(manager).selection_generation);
    try std.testing.expectEqualStrings(
        "DIRECT",
        managerImpl(manager).group_selections.get("Policy").?,
    );
}

test "legal select groups retain DIRECT and REJECT members" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxy-groups:
        \\  - name: Policy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    try std.testing.expect(try manager.applyTransientSelection(
        "Policy",
        "REJECT",
    ));
    try expectProxyStreamError(
        error.ConnectionRejected,
        manager.connect("Policy", "does-not-dial.invalid", 443),
    );
    try std.testing.expect(try manager.applyTransientSelection(
        "Policy",
        "DIRECT",
    ));
    try expectProxyStreamError(
        error.UdpNotSupportedForDirect,
        manager.connectUdp("Policy"),
    );
}

test "initWithKey rejects unsupported proxy group strategies before allocation" {
    const allocator = std.testing.allocator;
    const unsupported_types = [_][]const u8{
        "url-test",
        "fallback",
        "load-balance",
        "relay",
    };
    for (unsupported_types) |group_type| {
        const document = try std.fmt.allocPrint(
            allocator,
            "proxy-groups:\n  - name: unsupported\n    type: {s}\n" ++
                "    proxies: [DIRECT]\n",
            .{group_type},
        );
        defer allocator.free(document);
        var cfg = try config.parseDocument(allocator, document);
        defer cfg.deinit();

        var failing = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = 0,
        });
        try std.testing.expectError(
            error.UnsupportedProxyGroupType,
            OutboundManager.initWithKey(
                failing.allocator(),
                &cfg,
                "must-not-allocate",
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expect(!failing.has_induced_failure);
    }
}

test "initWithKey rejects whole-config capability failures before allocation" {
    const allocator = std.testing.allocator;
    const Case = struct {
        source: []const u8,
        expected: anyerror,
    };
    const cases = [_]Case{
        .{
            .source = "port: 8080\n",
            .expected = error.UnsupportedHttpPort,
        },
        .{
            .source = "socks-port: 1080\n",
            .expected = error.UnsupportedSocksPort,
        },
        .{
            .source =
            \\proxies:
            \\  - { name: plugin-on-direct, type: direct, plugin: obfs }
            ,
            .expected = error.PluginMetadataRequiresShadowsocks,
        },
        .{
            .source =
            \\proxies:
            \\  - { name: disabled-http, type: http, server: 127.0.0.1, port: 8080 }
            ,
            .expected = error.UnsupportedProxyType,
        },
        .{
            .source =
            \\proxies:
            \\  - { name: disabled-socks, type: socks5, server: 127.0.0.1, port: 1080 }
            ,
            .expected = error.UnsupportedProxyType,
        },
        .{
            .source =
            \\proxies:
            \\  - name: disabled-vmess
            \\    type: vmess
            \\    server: 127.0.0.1
            \\    port: 443
            \\    uuid: 12345678-1234-1234-1234-123456789abc
            ,
            .expected = error.UnsupportedProxyType,
        },
        .{
            .source =
            \\proxies:
            \\  - name: disabled-vless
            \\    type: vless
            \\    server: 127.0.0.1
            \\    port: 443
            \\    uuid: 12345678-1234-1234-1234-123456789abc
            ,
            .expected = error.UnsupportedProxyType,
        },
        .{
            .source =
            \\proxies:
            \\  - { name: disabled-anytls, type: anytls, server: 127.0.0.1, port: 443, password: secret }
            ,
            .expected = error.UnsupportedProxyType,
        },
        .{
            .source =
            \\proxies:
            \\  - name: unknown-plugin
            \\    type: ss
            \\    server: 127.0.0.1
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: v2ray-plugin
            ,
            .expected = error.UnsupportedShadowsocksPlugin,
        },
        .{
            .source =
            \\proxies:
            \\  - name: tls-mode
            \\    type: ss
            \\    server: 127.0.0.1
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts: { mode: tls, host: example.com }
            ,
            .expected = error.UnsupportedSimpleObfsMode,
        },
        .{
            .source =
            \\proxies:
            \\  - name: missing-options
            \\    type: ss
            \\    server: 127.0.0.1
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            ,
            .expected = error.MissingShadowsocksPluginOptions,
        },
        .{
            .source =
            \\proxies:
            \\  - name: udp-ss
            \\    type: ss
            \\    server: 127.0.0.1
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    udp: true
            ,
            .expected = error.ShadowsocksUdpNotSupported,
        },
        .{
            .source =
            \\proxies:
            \\  - { name: tls-ss, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-128-gcm, password: secret, tls: true }
            ,
            .expected = error.ShadowsocksTlsNotSupported,
        },
        .{
            .source =
            \\proxies:
            \\  - { name: cipher-ss, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-128-cfb, password: secret }
            ,
            .expected = error.UnsupportedShadowsocksCipher,
        },
        .{
            .source =
            \\proxies:
            \\  - name: ws-ss
            \\    type: ss
            \\    server: 127.0.0.1
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    ws-opts: { path: /ws }
            ,
            .expected = error.WebSocketNotSupported,
        },
        .{
            .source =
            \\proxies:
            \\  - { name: udp-trojan, type: trojan, server: 127.0.0.1, port: 443, password: secret, udp: true }
            ,
            .expected = error.TrojanUdpNotSupported,
        },
        .{
            .source =
            \\proxies:
            \\  - name: ws-trojan
            \\    type: trojan
            \\    server: 127.0.0.1
            \\    port: 443
            \\    password: secret
            \\    ws-opts: { path: /ws }
            ,
            .expected = error.WebSocketNotSupported,
        },
    };

    for (cases) |case| {
        var cfg = try config.parseDocument(allocator, case.source);
        defer cfg.deinit();
        var failing = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = 0,
        });
        try std.testing.expectError(
            case.expected,
            OutboundManager.initWithKey(
                failing.allocator(),
                &cfg,
                "must-not-allocate",
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expect(!failing.has_induced_failure);
    }
}

test "focused proxy capability gate covers every selected proxy class" {
    // Test the focused gate directly because invalid proxies cannot pass the
    // manager's fail-before-allocation initialization admission.
    var proxy = Proxy{
        .name = "selected",
        .proxy_type = .direct,
        .server = "",
        .port = 0,
        .plugin = "obfs",
    };
    try std.testing.expectError(
        error.PluginMetadataRequiresShadowsocks,
        requireSelectedProxyCapabilities(&proxy, null),
    );

    proxy.plugin = null;
    for ([_]ProxyType{ .http, .socks5, .vmess, .vless, .anytls }) |proxy_type| {
        proxy.proxy_type = proxy_type;
        try std.testing.expectError(
            error.UnsupportedProxyType,
            requireSelectedProxyCapabilities(&proxy, null),
        );
    }

    proxy.proxy_type = .ss;
    proxy.server = "127.0.0.1";
    proxy.port = 8388;
    proxy.password = "secret";
    proxy.cipher = "aes-128-gcm";
    proxy.plugin = "v2ray-plugin";
    try std.testing.expectError(
        error.UnsupportedShadowsocksPlugin,
        requireSelectedProxyCapabilities(&proxy, null),
    );
    proxy.plugin = null;
    proxy.udp = true;
    try std.testing.expectError(
        error.ShadowsocksUdpNotSupported,
        requireSelectedProxyCapabilities(&proxy, null),
    );
    proxy.udp = false;
    proxy.tls = true;
    try std.testing.expectError(
        error.ShadowsocksTlsNotSupported,
        requireSelectedProxyCapabilities(&proxy, null),
    );
    proxy.tls = false;
    proxy.cipher = "aes-128-cfb";
    try std.testing.expectError(
        error.UnsupportedShadowsocksCipher,
        requireSelectedProxyCapabilities(&proxy, null),
    );
    proxy.cipher = "aes-128-gcm";
    proxy.ws = true;
    try std.testing.expectError(
        error.WebSocketNotSupported,
        requireSelectedProxyCapabilities(&proxy, null),
    );

    proxy.proxy_type = .trojan;
    proxy.ws = false;
    proxy.plugin = "obfs";
    try std.testing.expectError(
        error.PluginMetadataRequiresShadowsocks,
        requireSelectedProxyCapabilities(&proxy, null),
    );
    proxy.plugin = null;
    proxy.udp = true;
    try std.testing.expectError(
        error.TrojanUdpNotSupported,
        requireSelectedProxyCapabilities(&proxy, null),
    );
    proxy.udp = false;
    proxy.ws = true;
    try std.testing.expectError(
        error.WebSocketNotSupported,
        requireSelectedProxyCapabilities(&proxy, null),
    );

    proxy.ws = false;
    _ = try requireSelectedProxyCapabilities(&proxy, null);
    proxy.proxy_type = .direct;
    _ = try requireSelectedProxyCapabilities(&proxy, null);
    proxy.proxy_type = .reject;
    _ = try requireSelectedProxyCapabilities(&proxy, null);
}

test "selected Shadowsocks gets one focused gate before private shortcut" {
    // A loopback target takes the direct shortcut, but only after the selected
    // Shadowsocks node has passed its focused capability gate.
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: selected-ss
        \\    type: ss
        \\    server: 203.0.113.10
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\proxy-groups:
        \\  - { name: Policy, type: select, proxies: [selected-ss] }
        \\rules:
        \\  - MATCH,Policy
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    const listen_address = try net.Address.parseIp4("127.0.0.1", 0);
    var target_server = try net.listenReuseAddr(listen_address);
    defer target_server.deinit();
    var stream = try manager.connect(
        "Policy",
        "127.0.0.1",
        target_server.listen_address.getPort(),
    );
    stream.close();
    const accepted = try target_server.accept();
    accepted.stream.close();

    try std.testing.expectEqual(@as(u32, 0), probe.complete_scans);
    try std.testing.expectEqual(@as(u32, 1), probe.selected_proxy_gates);
}

test "connectUdp applies only the selected proxy capability gate" {
    // A valid TCP-only Shadowsocks node reaches UDP's protocol rejection after
    // one focused gate and without a complete configuration scan.
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\proxies:
        \\  - name: selected-ss
        \\    type: ss
        \\    server: 203.0.113.10
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    try std.testing.expectError(
        error.UnsupportedProxyType,
        manager.connectUdp("selected-ss"),
    );
    try std.testing.expectEqual(@as(u32, 0), probe.complete_scans);
    try std.testing.expectEqual(@as(u32, 1), probe.selected_proxy_gates);
}

test "manager init rejects non-Shadowsocks plugin metadata before allocation" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        catalog_capture: bool = false,
    }{
        .{
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: direct-node
            \\    type: direct
            \\    plugin: obfs
            ,
        },
        .{
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: reject-node
            \\    type: reject
            \\    plugin-opts: { mode: http, host: example.com }
            ,
        },
        .{
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: trojan-node
            \\    type: trojan
            \\    server: does-not-resolve.invalid
            \\    port: 443
            \\    password: secret
            \\    plugin: obfs
            \\    plugin_opts: { mode: http, host: example.com }
            ,
        },
        .{
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: malformed-node
            \\    type: direct
            \\    plugin-opts: "obfs=http"
            ,
            .catalog_capture = true,
        },
    };

    for (cases) |case| {
        var cfg = if (case.catalog_capture)
            try config.parseCatalogDocument(allocator, case.source)
        else
            try config.parseDocument(allocator, case.source);
        defer cfg.deinit();
        var failing = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = 0,
        });
        try std.testing.expectError(
            error.PluginMetadataRequiresShadowsocks,
            OutboundManager.initWithKey(
                failing.allocator(),
                &cfg,
                "must-not-allocate",
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expect(!failing.has_induced_failure);
    }
}

test "makeShadowsocksClient returns isolated instances" {
    const allocator = std.testing.allocator;

    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(@import("../../config.zig").ProxyGroup).empty,
        .rules = std.ArrayList(@import("../../config.zig").Rule).empty,
    };
    defer cfg.deinit();

    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    const proxy = Proxy{
        .name = "ss-test",
        .proxy_type = .ss,
        .server = "127.0.0.1",
        .port = 8388,
        .password = "password",
        .cipher = "aes-128-gcm",
        .plugin = "obfs",
        .plugin_options_state = .map,
        .obfs_mode = "http",
        .obfs_host = "example.com",
    };

    const c1 = try managerImpl(manager).makeShadowsocksClient(&proxy);
    defer {
        c1.deinit();
        allocator.destroy(c1);
    }
    const c2 = try managerImpl(manager).makeShadowsocksClient(&proxy);
    defer {
        c2.deinit();
        allocator.destroy(c2);
    }

    try std.testing.expect(c1 != c2);
    try std.testing.expect(c1.stream == null);
    try std.testing.expect(c2.stream == null);
}

test "makeShadowsocksClient rejects unknown obfs mode before allocation or dialing" {
    const allocator = std.testing.allocator;

    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(@import("../../config.zig").ProxyGroup).empty,
        .rules = std.ArrayList(@import("../../config.zig").Rule).empty,
    };
    defer cfg.deinit();

    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    var proxy = Proxy{
        .name = "ss-test",
        .proxy_type = .ss,
        .server = "127.0.0.1",
        .port = 8388,
        .password = "password",
        .cipher = "aes-128-gcm",
        .plugin = "obfs",
        .plugin_options_state = .map,
        .obfs_mode = "tls",
        .obfs_host = "example.com",
    };

    try std.testing.expectError(
        error.UnsupportedSimpleObfsMode,
        managerImpl(manager).makeShadowsocksClient(&proxy),
    );
    proxy.obfs_mode = "unknown";
    try std.testing.expectError(
        error.UnsupportedSimpleObfsMode,
        managerImpl(manager).makeShadowsocksClient(&proxy),
    );
}

test "focused gate forwards every Shadowsocks classifier failure" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: tls-mode
        \\    type: ss
        \\    server: does-not-resolve.invalid
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: { mode: tls, host: example.com }
        \\  - name: unknown-mode
        \\    type: ss
        \\    server: does-not-resolve.invalid
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: { mode: quic, host: example.com }
        \\  - name: unknown-plugin
        \\    type: ss
        \\    server: does-not-resolve.invalid
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: v2ray-plugin
        \\  - name: missing-options
        \\    type: ss
        \\    server: does-not-resolve.invalid
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\  - name: missing-host
        \\    type: ss
        \\    server: does-not-resolve.invalid
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs-local
        \\    plugin-opts: { mode: http }
        \\  - name: injected-host
        \\    type: ss
        \\    server: does-not-resolve.invalid
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: { mode: http, host: "safe\\r\\nInjected" }
        \\  - name: ss-udp
        \\    type: ss
        \\    server: does-not-resolve.invalid
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    udp: true
        \\  - name: derived-without-plugin
        \\    type: ss
        \\    server: does-not-resolve.invalid
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin-opts: { mode: http, host: example.com }
        \\rules:
        \\  - MATCH,REJECT
    );
    defer cfg.deinit();
    for (cfg.proxies.items) |*proxy| {
        if (!std.mem.eql(u8, proxy.name, "injected-host")) continue;
        allocator.free(proxy.obfs_host.?);
        proxy.obfs_host = try allocator.dupe(u8, "safe\r\nInjected");
    }

    const Case = struct { index: usize, expected: anyerror };
    const cases = [_]Case{
        .{ .index = 0, .expected = error.UnsupportedSimpleObfsMode },
        .{ .index = 1, .expected = error.UnsupportedSimpleObfsMode },
        .{ .index = 2, .expected = error.UnsupportedShadowsocksPlugin },
        .{ .index = 3, .expected = error.MissingShadowsocksPluginOptions },
        .{ .index = 4, .expected = error.MissingSimpleObfsHost },
        .{ .index = 5, .expected = error.InvalidSimpleObfsHost },
        .{ .index = 6, .expected = error.ShadowsocksUdpNotSupported },
        .{ .index = 7, .expected = error.InconsistentShadowsocksPluginFields },
    };
    for (cases) |case| {
        try std.testing.expectError(
            case.expected,
            requireSelectedProxyCapabilities(
                &cfg.proxies.items[case.index],
                null,
            ),
        );
    }
}

test "ProxyStream move transfers shadowsocks ownership" {
    const allocator = std.testing.allocator;

    const ss_client = try allocator.create(ss.ShadowsocksClient);
    errdefer allocator.destroy(ss_client);
    ss_client.* = try ss.ShadowsocksClient.init(allocator, "127.0.0.1", 8388, "password", "aes-128-gcm");

    var source = ProxyStream.initShadowsocks(allocator, .{ .handle = -1 }, ss_client);
    var moved = source.move();
    defer moved.close();
    source.close();

    try std.testing.expect(source.is_closed);
    try std.testing.expect(source.owned_ss_client == null);
    try std.testing.expect(moved.owned_ss_client == ss_client);
}

test "ProxyStream move transfers trojan ownership" {
    const allocator = std.testing.allocator;

    // trojan.Client.init only hashes the password — it does NOT dial — so
    // tls_conn stays null and the close path below is a no-op deinit + destroy.
    const trojan_client = try allocator.create(trojan.Client);
    errdefer allocator.destroy(trojan_client);
    trojan_client.* = try trojan.Client.init(allocator, .{
        .password = "password",
        .address = "127.0.0.1",
        .port = 443,
    });

    var source = ProxyStream.initTrojan(allocator, .{ .handle = -1 }, trojan_client);
    var moved = source.move();
    defer moved.close();
    source.close();

    try std.testing.expect(source.is_closed);
    try std.testing.expect(source.owned_trojan_client == null);
    try std.testing.expect(moved.owned_trojan_client == trojan_client);
}

test "ProxyStream.lastTlsReadError null for non-trojan, unconnected trojan, and closed streams" {
    const allocator = std.testing.allocator;

    // The diagnostic is trojan-only: a non-trojan (direct) stream returns null.
    var direct = ProxyStream.initDirect(.{ .handle = -1 });
    try std.testing.expectEqual(@as(?anyerror, null), direct.lastTlsReadError());

    // trojan.Client.init only hashes (no dial), so tls_conn stays null and the
    // underlying read_err is null -> lastReadError() -> null.
    const client = try allocator.create(trojan.Client);
    client.* = try trojan.Client.init(allocator, .{
        .password = "password",
        .address = "127.0.0.1",
        .port = 443,
    });
    var ts = ProxyStream.initTrojan(allocator, .{ .handle = -1 }, client);
    defer ts.close(); // idempotent (is_closed guard); frees the client exactly once
    try std.testing.expectEqual(@as(?anyerror, null), ts.lastTlsReadError());

    // After close the is_closed guard returns null WITHOUT dereferencing the freed
    // client (no UAF) — the breadcrumb contract the relay logging depends on.
    ts.close();
    try std.testing.expectEqual(@as(?anyerror, null), ts.lastTlsReadError());
}

test "connectToProxy(trojan) without password -> error.MissingPassword" {
    const allocator = std.testing.allocator;

    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(@import("../../config.zig").ProxyGroup).empty,
        .rules = std.ArrayList(@import("../../config.zig").Rule).empty,
    };
    defer cfg.deinit();

    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    // password defaults to null; the `orelse return error.MissingPassword` guard
    // fires before client.connect(), so no dial occurs and the heap-create at the
    // top of the trojan arm is reclaimed by its errdefer (leak-clean).
    const proxy = Proxy{
        .name = "t",
        .proxy_type = .trojan,
        .server = "127.0.0.1",
        .port = 443,
        .password = null,
    };

    try std.testing.expectError(
        error.MissingPassword,
        managerImpl(manager).connectToProxy(&proxy, .trojan, "example.com", 80),
    );
}

// KNOWN GAP (TODO C7): a real end-to-end loopback test — manager.connect(.anytls)
// -> real dial -> relay, asserting "one dial on reuse" — needs a TLS + anytls-
// protocol fake server. Deferred to C7; here we cover the ProxyStream ownership
// transfer with a non-dialed Stream stand-in only.

// Build a NON-DIALED Session stand-in (conn = null, recv_thread = null) +
// registered Stream, mirroring the seam used by anytls.zig C2/C3a tests and the
// pool's makeStandin. Uses only pub anytls API (Session.initForTest, the pub
// Session/Stream struct fields, compat.Notifier). The Stream's close() is safe on
// a stand-in: sendFin -> sendFrame -> writeSessionPayload returns NotConnected
// (conn == null), which sendFin swallows.
const anytls_test_config = anytls.Config{ .password = "password", .address = "127.0.0.1", .port = 443 };

fn makeStandinAnyTlsStream(allocator: std.mem.Allocator) !struct { session: *anytls.Session, stream: *anytls.Stream } {
    const session = try allocator.create(anytls.Session);
    errdefer allocator.destroy(session);
    session.* = try anytls.Session.initForTest(allocator, anytls_test_config);
    // Stand-in for the recv-loop ref; +1 per-stream session-ref added below.
    session.refs = std.atomic.Value(u32).init(1);

    const stream = try allocator.create(anytls.Stream);
    errdefer allocator.destroy(stream);
    stream.* = .{
        .session = session,
        .id = 1,
        .notifier = try compat.Notifier.init(),
    };

    // Mirror Session.openStream / testRegisterStream: insert into the map, add the
    // per-stream session-ref, and bind it to the Stream struct so releaseStreamRef
    // drops it exactly once when the Stream is finally freed.
    std.Io.Threaded.mutexLock(&session.streams_mutex);
    try session.streams.put(allocator, 1, stream);
    std.Io.Threaded.mutexUnlock(&session.streams_mutex);
    _ = session.refs.fetchAdd(1, .monotonic);
    stream.owns_session_ref = true;

    return .{ .session = session, .stream = stream };
}

test "ProxyStream move transfers AnyTLS ownership" {
    const allocator = std.testing.allocator;

    const standin = try makeStandinAnyTlsStream(allocator);
    const session = standin.session;
    const stream = standin.stream;

    var source = ProxyStream.initAnyTlsStream(stream);
    var moved = source.move();

    try std.testing.expect(source.is_closed);
    try std.testing.expect(source.owned_anytls_stream == null);
    try std.testing.expect(moved.owned_anytls_stream == stream);

    // close() routes to Stream.close (drops map-presence + relay-borrow refs ->
    // frees the Stream -> drops the per-stream session-ref). source.close() is a
    // no-op (ownership moved). Then drive the session teardown like a recv-loop
    // exit would: requestClose + drop the stand-in recv-loop ref -> finalize.
    source.close();
    moved.close();
    session.requestClose(.shutdown);
    session.releaseRef();
}

test "C5: ProxyStream.readBlocking delegates to the anytls stream" {
    // The HttpsForward no-poll pump (mixed.zig UpstreamReader) reads through
    // readBlocking; for an anytls stand-in it must route to Stream.readBlocking.
    // Seed inbound bytes so the blocking read returns deterministically.
    const allocator = std.testing.allocator;

    const standin = try makeStandinAnyTlsStream(allocator);
    const session = standin.session;
    const stream = standin.stream;

    stream.testAppendInbound("hello");

    var ps = ProxyStream.initAnyTlsStream(stream);
    var buf: [16]u8 = undefined;
    const n = try ps.readBlocking(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..5]);

    // Next read sees EOF (peer FIN) -> returns 0 without blocking.
    stream.testMarkEof();
    try std.testing.expectEqual(@as(usize, 0), try ps.readBlocking(&buf));

    ps.close();
    session.requestClose(.shutdown);
    session.releaseRef();
}

test "C5: ProxyStream.readBlocking falls back to plain read for a non-anytls stream" {
    // A pipe pair stands in for a plain socket: readBlocking must just call read.
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) < 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    _ = try compat.posixWrite(fds[1], "ping");

    var ps = ProxyStream{ .base_stream = .{ .handle = fds[0] } };
    var buf: [16]u8 = undefined;
    const n = try ps.readBlocking(&buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("ping", buf[0..4]);
}

test "C5: ProxyStream.shutdownWrite delegates to the anytls stream (half-close)" {
    // anytls branch -> Stream.shutdownWrite (per-stream cmdFIN; sendFin on a
    // conn==null stand-in is swallowed). Idempotent: a 2nd call is a no-op.
    const allocator = std.testing.allocator;

    const standin = try makeStandinAnyTlsStream(allocator);
    const session = standin.session;
    const stream = standin.stream;

    var ps = ProxyStream.initAnyTlsStream(stream);
    try ps.shutdownWrite();
    try std.testing.expect(stream.write_shut);
    // 2nd call stays a no-op (idempotent half-close).
    try ps.shutdownWrite();
    try std.testing.expect(stream.write_shut);

    ps.close();
    session.requestClose(.shutdown);
    session.releaseRef();
}

test "C5: ProxyStream.shutdownWrite falls back to compat.shutdownWrite for a non-anytls stream" {
    // Non-anytls path must call compat.shutdownWrite(getHandle()). Use a real
    // connected socketpair so shutdown(SHUT_WR) succeeds (byte-for-byte the
    // pre-existing direct/ss/trojan/vless behavior).
    var pair: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(
        @as(c_uint, @intCast(std.posix.AF.UNIX)),
        @as(c_uint, @intCast(std.posix.SOCK.STREAM)),
        0,
        &pair,
    );
    if (rc != 0) return error.SocketPairFailed;
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);

    var ps = ProxyStream{ .base_stream = .{ .handle = pair[0] } };
    try ps.shutdownWrite(); // shutdown(SHUT_WR) on the real fd — no error.
}

test "ProxyStream write rejects closed stream" {
    var stream = ProxyStream{
        .base_stream = .{ .handle = -1 },
        .is_closed = true,
    };

    try std.testing.expectError(error.StreamClosed, stream.write("x"));
}

test "selectProxyInternal with persist=false skips persist" {
    const allocator = std.testing.allocator;

    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(@import("../../config.zig").ProxyGroup).empty,
        .rules = std.ArrayList(@import("../../config.zig").Rule).empty,
    };
    defer cfg.deinit();

    var gp = @import("../../config.zig").ProxyGroup{
        .name = try allocator.dupe(u8, "G1"),
        .group_type = .select,
        .proxies = std.ArrayList([]const u8).empty,
    };
    try gp.proxies.append(allocator, try allocator.dupe(u8, "P1"));
    try cfg.proxy_groups.append(allocator, gp);

    const mgr = try OutboundManager.init(allocator, &cfg);
    defer mgr.deinit();

    try std.testing.expect(try managerImpl(mgr).selectProxyInternal("G1", "P1", false, .transient));
    try std.testing.expectEqual(@as(usize, 0), managerImpl(mgr).persist_invocations);

    var durable = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iterator = durable.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        durable.deinit();
    }
    try managerImpl(mgr).copyPersistableSelectionsLocked(&durable);
    try std.testing.expectEqual(@as(usize, 0), durable.count());
    try std.testing.expect(try mgr.applyPersistedSelection("G1", "P1"));
    try managerImpl(mgr).copyPersistableSelectionsLocked(&durable);
    try std.testing.expectEqual(@as(usize, 1), durable.count());
}

test "legacy persistence failure rolls back the runtime selection" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(
            @import("../../config.zig").ProxyGroup,
        ).empty,
        .rules = std.ArrayList(@import("../../config.zig").Rule).empty,
    };
    defer cfg.deinit();
    var group = @import("../../config.zig").ProxyGroup{
        .name = try allocator.dupe(u8, "rollback-group"),
        .group_type = .select,
        .proxies = std.ArrayList([]const u8).empty,
    };
    try group.proxies.append(allocator, try allocator.dupe(u8, "A"));
    try group.proxies.append(allocator, try allocator.dupe(u8, "B"));
    try cfg.proxy_groups.append(allocator, group);

    const manager = try OutboundManager.initWithKey(
        allocator,
        &cfg,
        "missing-legacy-entry",
    );
    defer manager.deinit();
    try std.testing.expect(try manager.applyPersistedSelection(
        "rollback-group",
        "A",
    ));
    try std.testing.expectError(
        error.LegacyMetadataEntryMissing,
        manager.selectProxy("rollback-group", "B"),
    );
    const selections = try manager.snapshotSelections(allocator);
    defer runtime_selection.freeSelectionEntries(allocator, selections);
    try std.testing.expectEqual(@as(usize, 1), selections.len);
    try std.testing.expectEqualStrings("A", selections[0].proxy);
}

test "configKey and snapshotSelections expose daemon runtime state" {
    const allocator = std.testing.allocator;

    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(@import("../../config.zig").ProxyGroup).empty,
        .rules = std.ArrayList(@import("../../config.zig").Rule).empty,
    };
    defer cfg.deinit();

    var gp = @import("../../config.zig").ProxyGroup{
        .name = try allocator.dupe(u8, "G1"),
        .group_type = .select,
        .proxies = std.ArrayList([]const u8).empty,
    };
    try gp.proxies.append(allocator, try allocator.dupe(u8, "P1"));
    try gp.proxies.append(allocator, try allocator.dupe(u8, "P2"));
    try cfg.proxy_groups.append(allocator, gp);

    const mgr = try OutboundManager.initWithKey(allocator, &cfg, "runtimkey");
    defer mgr.deinit();

    // configKey reflects the init key; empty selections -> empty snapshot.
    try std.testing.expectEqualStrings("runtimkey", managerImpl(mgr).configKey().?);
    const snap0 = try mgr.snapshotSelections(allocator);
    defer runtime_selection.freeSelectionEntries(allocator, snap0);
    try std.testing.expectEqual(@as(usize, 0), snap0.len);

    // Select P2 in G1 (persist=false: no meta.json writes) -> snapshot reflects it.
    try std.testing.expect(try managerImpl(mgr).selectProxyInternal(
        "G1",
        "P2",
        false,
        .transient,
    ));
    const snap1 = try mgr.snapshotSelections(allocator);
    defer runtime_selection.freeSelectionEntries(allocator, snap1);
    try std.testing.expectEqual(@as(usize, 1), snap1.len);
    try std.testing.expectEqualStrings("G1", snap1[0].group);
    try std.testing.expectEqualStrings("P2", snap1[0].proxy);
    try std.testing.expectEqual(
        runtime_selection.SelectionSource.transient,
        snap1[0].source,
    );

    const generation_two = [_]config_catalog.Selection{.{
        .group = "G1",
        .proxy = "P1",
    }};
    try std.testing.expect(try mgr.applyPersistedSelections(&generation_two, 2));
    const stale = [_]config_catalog.Selection{.{
        .group = "G1",
        .proxy = "P2",
    }};
    try std.testing.expect(!try mgr.preparePersistedSelections(&stale, 1));
    try std.testing.expect(!try mgr.commitPersistedSelections(&stale, 1));
    const snap2 = try mgr.snapshotSelections(allocator);
    defer runtime_selection.freeSelectionEntries(allocator, snap2);
    try std.testing.expectEqualStrings("P1", snap2[0].proxy);
    try std.testing.expectEqual(
        runtime_selection.SelectionSource.persisted,
        snap2[0].source,
    );

    try std.testing.expect(try managerImpl(mgr).selectProxyInternal(
        "G1",
        "P2",
        false,
        .transient,
    ));
    try std.testing.expect(try mgr.applyPersistedSelections(&.{}, 3));
    const snap3 = try mgr.snapshotSelections(allocator);
    defer runtime_selection.freeSelectionEntries(allocator, snap3);
    try std.testing.expectEqual(@as(usize, 0), snap3.len);
}

test "shouldBypassProxyForTarget detects loopback and private targets" {
    try std.testing.expect(shouldBypassProxyForTarget("localhost"));
    try std.testing.expect(shouldBypassProxyForTarget("127.0.0.1"));
    try std.testing.expect(shouldBypassProxyForTarget("10.0.0.8"));
    try std.testing.expect(shouldBypassProxyForTarget("172.16.5.4"));
    try std.testing.expect(shouldBypassProxyForTarget("192.168.1.20"));
    try std.testing.expect(shouldBypassProxyForTarget("169.254.1.9"));
    try std.testing.expect(shouldBypassProxyForTarget("::1"));
    try std.testing.expect(shouldBypassProxyForTarget("fc00::1"));
    try std.testing.expect(shouldBypassProxyForTarget("fe80::1"));
    try std.testing.expect(!shouldBypassProxyForTarget("8.8.8.8"));
    try std.testing.expect(!shouldBypassProxyForTarget("1.1.1.1"));
    try std.testing.expect(!shouldBypassProxyForTarget("open.feishu.cn"));
}

test "connect keeps reject policies terminal for private targets" {
    // Explicit denial must be evaluated before any loopback bypass policy.
    const allocator = std.testing.allocator;
    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(@import("../../config.zig").ProxyGroup).empty,
        .rules = std.ArrayList(@import("../../config.zig").Rule).empty,
    };
    defer cfg.deinit();
    try cfg.proxies.append(allocator, .{
        .name = try allocator.dupe(u8, "deny"),
        .proxy_type = .reject,
        .server = try allocator.dupe(u8, ""),
        .port = 0,
    });
    var group = @import("../../config.zig").ProxyGroup{
        .name = try allocator.dupe(u8, "blocked"),
        .group_type = .select,
        .proxies = std.ArrayList([]const u8).empty,
    };
    try group.proxies.append(allocator, try allocator.dupe(u8, "deny"));
    try cfg.proxy_groups.append(allocator, group);

    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    const policies = [_][]const u8{ "REJECT", "deny", "blocked" };
    for (policies) |policy| {
        try std.testing.expectError(
            error.ConnectionRejected,
            manager.connect(policy, "127.0.0.1", 1),
        );
    }
}

test "connect preserves DIRECT and REJECT literals resolved from groups" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\mixed-port: 7890
        \\proxies: []
        \\proxy-groups:
        \\  - { name: direct-policy, type: select, proxies: [DIRECT] }
        \\  - { name: reject-policy, type: select, proxies: [REJECT] }
        \\rules:
        \\  - MATCH,DIRECT
    );
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    var probe: CapabilityValidationProbe = .{};
    managerImpl(manager).capability_validation_probe = &probe;
    defer managerImpl(manager).capability_validation_probe = null;

    const listen_address = try net.Address.parseIp4("127.0.0.1", 0);
    var target_server = try net.listenReuseAddr(listen_address);
    defer target_server.deinit();
    const target_port = target_server.listen_address.getPort();

    for ([_][]const u8{ "DIRECT", "direct-policy" }) |policy| {
        var direct = try manager.connect(
            policy,
            "127.0.0.1",
            target_port,
        );
        direct.close();
        const accepted = try target_server.accept();
        accepted.stream.close();
    }

    try std.testing.expectError(
        error.ConnectionRejected,
        manager.connect("reject-policy", "127.0.0.1", target_port),
    );
    var descriptors = [_]std.posix.pollfd{.{
        .fd = target_server.fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(
        @as(usize, 0),
        try std.posix.poll(&descriptors, 0),
    );
    try std.testing.expectEqual(@as(u32, 0), probe.complete_scans);
    try std.testing.expectEqual(@as(u32, 0), probe.selected_proxy_gates);
    try std.testing.expectEqual(@as(u32, 2), probe.group_index_lookups);
    try std.testing.expectEqual(@as(u32, 0), probe.proxy_index_lookups);
    try std.testing.expectEqual(@as(u32, 0), probe.linear_config_scans);
}

test "connect bypasses proxy groups for loopback targets" {
    const allocator = std.testing.allocator;

    var cfg = Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(@import("../../config.zig").ProxyGroup).empty,
        .rules = std.ArrayList(@import("../../config.zig").Rule).empty,
    };
    defer cfg.deinit();

    try cfg.proxies.append(allocator, .{
        .name = try allocator.dupe(u8, "remote-ss"),
        .proxy_type = .ss,
        .server = try allocator.dupe(u8, "203.0.113.10"),
        .port = 8388,
        .password = try allocator.dupe(u8, "password"),
        .cipher = try allocator.dupe(u8, "aes-128-gcm"),
    });

    var group = @import("../../config.zig").ProxyGroup{
        .name = try allocator.dupe(u8, "Proxies"),
        .group_type = .select,
        .proxies = std.ArrayList([]const u8).empty,
    };
    try group.proxies.append(allocator, try allocator.dupe(u8, "remote-ss"));
    try cfg.proxy_groups.append(allocator, group);

    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    const listen_addr = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const accept_thread = try std.Thread.spawn(.{}, struct {
        fn run(server_arg: *net.Server) void {
            const conn = server_arg.accept() catch return;
            defer conn.stream.close();
            _ = conn.stream.writeAll("ok") catch {};
        }
    }.run, .{&server});
    defer accept_thread.join();

    var stream = try manager.connect("Proxies", "127.0.0.1", server.listen_address.getPort());
    defer stream.close();

    var buf: [2]u8 = undefined;
    const n = try stream.read(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("ok", buf[0..n]);
    try std.testing.expect(stream.owned_ss_client == null);
}

// ===========================================================================
// D5: manager UDP path (connectUdp / connectAnyTlsUdp + ProxyStream UDP arm)
// ===========================================================================

const ConfigZ = @import("../../config.zig");

/// Build a Config carrying exactly the proxies/groups passed in. Caller owns the
/// returned Config (deinit frees the duped scalars; the proxies/groups passed by
/// the caller must already hold duped strings since cfg.deinit frees them).
fn makeUdpTestConfig(allocator: std.mem.Allocator) !Config {
    return Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(Proxy).empty,
        .proxy_groups = std.ArrayList(ConfigZ.ProxyGroup).empty,
        .rules = std.ArrayList(ConfigZ.Rule).empty,
    };
}

test "D5: connectUdp(DIRECT) -> error.UdpNotSupportedForDirect" {
    const allocator = std.testing.allocator;
    var cfg = try makeUdpTestConfig(allocator);
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    try std.testing.expectError(error.UdpNotSupportedForDirect, manager.connectUdp("DIRECT"));
}

test "D5: connectUdp(REJECT) -> error.ConnectionRejected" {
    const allocator = std.testing.allocator;
    var cfg = try makeUdpTestConfig(allocator);
    defer cfg.deinit();
    const manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    try std.testing.expectError(error.ConnectionRejected, manager.connectUdp("REJECT"));
}

test "manager init rejects AnyTLS UDP before dialing" {
    // No UDP transport is enabled in v1, even when the node requests udp:true.
    const allocator = std.testing.allocator;
    var cfg = try makeUdpTestConfig(allocator);
    defer cfg.deinit();
    try cfg.proxies.append(allocator, .{
        .name = try allocator.dupe(u8, "atls"),
        .proxy_type = .anytls,
        .server = try allocator.dupe(u8, "127.0.0.1"),
        .port = 1,
        .password = try allocator.dupe(u8, "password"),
        .udp = true,
    });
    try std.testing.expectError(
        error.UnsupportedProxyType,
        OutboundManager.init(allocator, &cfg),
    );
}

test "manager init rejects AnyTLS without dialing" {
    const allocator = std.testing.allocator;
    var cfg = try makeUdpTestConfig(allocator);
    defer cfg.deinit();
    try cfg.proxies.append(allocator, .{
        .name = try allocator.dupe(u8, "atls"),
        .proxy_type = .anytls,
        .server = try allocator.dupe(u8, "203.0.113.10"),
        .port = 443,
        .password = try allocator.dupe(u8, "password"),
        // udp defaults to false
    });
    try std.testing.expectError(
        error.UnsupportedProxyType,
        OutboundManager.init(allocator, &cfg),
    );
}

test "manager init rejects Shadowsocks UDP" {
    const allocator = std.testing.allocator;
    var cfg = try makeUdpTestConfig(allocator);
    defer cfg.deinit();
    try cfg.proxies.append(allocator, .{
        .name = try allocator.dupe(u8, "ss-udp"),
        .proxy_type = .ss,
        .server = try allocator.dupe(u8, "203.0.113.10"),
        .port = 8388,
        .password = try allocator.dupe(u8, "password"),
        .cipher = try allocator.dupe(u8, "aes-128-gcm"),
        .udp = true, // udp:true ignored for non-anytls
    });
    try std.testing.expectError(
        error.ShadowsocksUdpNotSupported,
        OutboundManager.init(allocator, &cfg),
    );
}

test "manager init rejects a group containing AnyTLS" {
    const allocator = std.testing.allocator;
    var cfg = try makeUdpTestConfig(allocator);
    defer cfg.deinit();
    try cfg.proxies.append(allocator, .{
        .name = try allocator.dupe(u8, "atls"),
        .proxy_type = .anytls,
        .server = try allocator.dupe(u8, "203.0.113.10"),
        .port = 443,
        .password = try allocator.dupe(u8, "password"),
    });
    var group = ConfigZ.ProxyGroup{
        .name = try allocator.dupe(u8, "G"),
        .group_type = .select,
        .proxies = std.ArrayList([]const u8).empty,
    };
    try group.proxies.append(allocator, try allocator.dupe(u8, "atls"));
    try cfg.proxy_groups.append(allocator, group);

    try std.testing.expectError(
        error.UnsupportedProxyType,
        OutboundManager.init(allocator, &cfg),
    );
}

// MUST-FIX #5: the byte-stream methods (write/read/readBlocking/hasPendingRead/
// shutdownWrite) on a UDP ProxyStream arm @panic. Zig 0.16's std.testing has no
// expectPanic, so this is verified by code inspection + the @panic guards added
// at the top of each method; the close/getHandle/udpStream/move paths ARE
// exercised by the test below. (A panic in a unit test would abort the runner,
// so we cannot positively assert it without a child-process harness.)

test "D5: ProxyStream UDP arm close frees the UotStream + returns Session to idle (no leak/UAF)" {
    // Stand-in mirrors the C-stage seam: a real anytls.Stream bound to a
    // non-dialed Session, wrapped in the production AnyTlsUdpStream, then handed
    // to a UDP ProxyStream. close() must route Stream.close (FIN swallowed on a
    // conn==null stand-in; drops the relay-borrow ref) AND free the UotStream
    // (its rx ArrayList) + the heap wrapper — all under std.testing.allocator.
    const allocator = std.testing.allocator;

    const standin = try makeStandinAnyTlsStream(allocator);
    const session = standin.session;
    const stream = standin.stream;

    const ust = try allocator.create(AnyTlsUdpStream);
    ust.* = AnyTlsUdpStream.init(allocator, stream);

    var ps = ProxyStream.initAnyTlsUdp(allocator, ust);
    // Accessors valid on the UDP arm.
    try std.testing.expect(ps.udpStream() == ust);
    try std.testing.expect(ps.getHandle() == stream.getHandle());

    // close() frees the UotStream (rx) + wrapper, routes Stream.close.
    ps.close();
    try std.testing.expect(ps.is_closed);
    try std.testing.expect(ps.owned_anytls_udp == null);

    // Drive the rest of the stand-in teardown like a recv-loop exit would.
    session.requestClose(.shutdown);
    session.releaseRef();
}

test "D5: ProxyStream move transfers the UDP arm" {
    const allocator = std.testing.allocator;

    const standin = try makeStandinAnyTlsStream(allocator);
    const session = standin.session;
    const stream = standin.stream;

    const ust = try allocator.create(AnyTlsUdpStream);
    ust.* = AnyTlsUdpStream.init(allocator, stream);

    var source = ProxyStream.initAnyTlsUdp(allocator, ust);
    var moved = source.move();
    try std.testing.expect(source.is_closed);
    try std.testing.expect(source.owned_anytls_udp == null);
    try std.testing.expect(moved.owned_anytls_udp == ust);

    source.close(); // no-op (moved out)
    moved.close(); // frees ust + routes Stream.close
    session.requestClose(.shutdown);
    session.releaseRef();
}

const SplitSaltWriterContext = struct {
    fd: std.posix.fd_t,
    bytes: []const u8,
    failure: ?anyerror = null,

    fn run(context: *SplitSaltWriterContext) void {
        compat.sleepNs(20 * std.time.ns_per_ms);
        var offset: usize = 0;
        while (offset < context.bytes.len) {
            const count = compat.posixSocketWrite(
                context.fd,
                context.bytes[offset..],
            ) catch |err| {
                context.fail(err);
                return;
            };
            if (count == 0) {
                context.fail(error.WriteZero);
                return;
            }
            offset += count;
        }
    }

    fn fail(context: *SplitSaltWriterContext, err: anyerror) void {
        context.failure = err;
        _ = std.c.shutdown(context.fd, std.c.SHUT.RDWR);
    }
};

test "ProxyStream.readBlocking handles a split Shadowsocks salt" {
    const allocator = std.testing.allocator;
    const aead = @import("../../crypto/aead.zig");

    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(
        @as(c_uint, @intCast(std.posix.AF.UNIX)),
        @as(c_uint, @intCast(std.posix.SOCK.STREAM)),
        0,
        &fds,
    );
    if (rc != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[1]);

    var fd_owned = true;
    errdefer {
        if (fd_owned) _ = std.c.close(fds[0]);
    }
    const client = try allocator.create(ss.ShadowsocksClient);
    var client_initialized = false;
    var client_transferred = false;
    errdefer if (!client_transferred) {
        if (client_initialized) client.deinit();
        allocator.destroy(client);
    };
    client.* = try ss.ShadowsocksClient.init(
        allocator,
        "127.0.0.1",
        8388,
        "password",
        "aes-128-gcm",
    );
    client_initialized = true;
    client.stream = .{ .handle = fds[0] };
    fd_owned = false;
    var proxy_stream = ProxyStream.initShadowsocks(
        allocator,
        client.stream.?,
        client,
    );
    client_transferred = true;
    defer proxy_stream.close();

    const salt = [_]u8{0} ** 16;
    var encrypt = try aead.AeadStream.init(.aes_128_gcm, "password", &salt);
    var frame: [64]u8 = undefined;
    const frame_len = try encrypt.encryptChunk("hello", &frame);
    var remainder: [8 + frame.len]u8 = undefined;
    @memcpy(remainder[0..8], salt[8..]);
    @memcpy(remainder[8 .. 8 + frame_len], frame[0..frame_len]);

    _ = try compat.posixSocketWrite(fds[1], salt[0..8]);
    var context = SplitSaltWriterContext{
        .fd = fds[1],
        .bytes = remainder[0 .. 8 + frame_len],
    };
    const writer = try std.Thread.spawn(
        .{},
        SplitSaltWriterContext.run,
        .{&context},
    );
    const read_result = proxy_stream.readBlocking(&frame);
    writer.join();
    if (context.failure) |err| return err;

    const count = try read_result;
    try std.testing.expectEqualStrings("hello", frame[0..count]);
}

test "ProxyStream.readBlocking enforces the simple-obfs response deadline" {
    const allocator = std.testing.allocator;

    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(
        @as(c_uint, @intCast(std.posix.AF.UNIX)),
        @as(c_uint, @intCast(std.posix.SOCK.STREAM)),
        0,
        &fds,
    );
    if (rc != 0) return error.SocketPairFailed;
    defer _ = std.c.close(fds[1]);

    var fd_owned = true;
    errdefer {
        if (fd_owned) _ = std.c.close(fds[0]);
    }
    const client = try allocator.create(ss.ShadowsocksClient);
    var client_initialized = false;
    var client_transferred = false;
    errdefer if (!client_transferred) {
        if (client_initialized) client.deinit();
        allocator.destroy(client);
    };
    client.* = try ss.ShadowsocksClient.initWithObfs(
        allocator,
        "127.0.0.1",
        8388,
        "password",
        "aes-128-gcm",
        simple_obfs_http.Config{
            .host = "www.example.com",
            .server_port = 8388,
            .response_timeout_ms = 50,
        },
    );
    client_initialized = true;
    client.stream = .{ .handle = fds[0] };
    fd_owned = false;
    var proxy_stream = ProxyStream.initShadowsocks(
        allocator,
        client.stream.?,
        client,
    );
    client_transferred = true;
    defer proxy_stream.close();

    var request_stream = client.stream.?;
    try client.obfs.?.write(&request_stream, "first-payload");
    const remaining_ms = proxy_stream.responseDeadlineRemainingMsAt(
        compat.monotonicMilliTimestamp(),
    ) orelse return error.TestExpectedArmedDeadline;
    try std.testing.expect(remaining_ms > 0);
    try std.testing.expect(remaining_ms <= 50);

    var output: [1]u8 = undefined;
    const started_ms = compat.monotonicMilliTimestamp();
    try std.testing.expectError(
        error.ObfsResponseTimeout,
        proxy_stream.readBlocking(&output),
    );
    const elapsed_ms = compat.monotonicMilliTimestamp() - started_ms;
    try std.testing.expect(elapsed_ms >= 0);
    try std.testing.expect(elapsed_ms <= 1_000);
}
