const std = @import("std");
const compat = @import("../../compat.zig");
const net = compat.net;
const config = @import("../../config.zig");
const Config = config.Config;
const Proxy = config.Proxy;
const ProxyType = config.ProxyType;
const meta = @import("../../meta.zig");
const ss = @import("shadowsocks.zig");
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
    /// no-poll TLS pump (mixed.zig UpstreamReader): a multiplexed anytls stream
    /// must wait on its notifier rather than returning WouldBlock. For every
    /// non-anytls type this is a plain read — byte-for-byte the prior behavior of
    /// the no-poll pump (direct/ss/trojan/vless took the same blocking read).
    pub fn readBlocking(self: *ProxyStream, buf: []u8) !usize {
        if (self.owned_anytls_udp != null) @panic("ProxyStream.readBlocking called on a UDP (UoT) arm");
        if (self.is_closed) return error.StreamClosed;
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
pub const OutboundManager = struct {
    allocator: std.mem.Allocator,
    config: *const Config,

    /// 每个代理组的当前选择（group_name → proxy_name）
    group_selections: std.StringHashMap([]const u8),
    group_selection_sources: std.StringHashMap(runtime_selection.SelectionSource),
    group_selections_mutex: std.Io.Mutex = .init,
    selection_generation: u64 = 0,
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

    pub fn init(allocator: std.mem.Allocator, config_arg: *const Config) !OutboundManager {
        return try initWithKey(allocator, config_arg, null);
    }

    pub fn initWithKey(
        allocator: std.mem.Allocator,
        config_arg: *const Config,
        config_key: ?[]const u8,
    ) !OutboundManager {
        const owned_config_key = if (config_key) |key|
            try allocator.dupe(u8, key)
        else
            null;
        return .{
            .allocator = allocator,
            .config = config_arg,
            .group_selections = std.StringHashMap([]const u8).init(allocator),
            .group_selection_sources = std.StringHashMap(
                runtime_selection.SelectionSource,
            ).init(allocator),
            .config_key = owned_config_key,
        };
    }

    pub fn deinit(self: *OutboundManager) void {
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
        if (self.config_key) |k| self.allocator.free(k);
    }

    fn lockPools(self: *OutboundManager) void {
        std.Io.Threaded.mutexLock(&self.pools_mutex);
    }

    fn unlockPools(self: *OutboundManager) void {
        std.Io.Threaded.mutexUnlock(&self.pools_mutex);
    }

    /// Builds an owned per-identity pool key (§12):
    /// "addr|port|sni|skip|hex(pwhash[0..8])". Two proxies sharing every field
    /// share a pool; any difference (incl. password) routes to a distinct pool.
    /// Caller owns the returned slice.
    fn poolKey(self: *OutboundManager, proxy: *const Proxy) ![]u8 {
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
    fn getOrCreatePool(self: *OutboundManager, key: []const u8, proxy: *const Proxy) !*anytls_pool.SessionPool {
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
            .idle_session_check_interval_ms = self.config.idle_session_check_interval * 1000,
            .idle_session_timeout_ms = self.config.idle_session_timeout * 1000,
            .min_idle_session = self.config.min_idle_session,
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
        self: *OutboundManager,
        group_name: []const u8,
        proxy_name: []const u8,
    ) !bool {
        return self.selectProxyInternal(
            group_name,
            proxy_name,
            true,
            .persisted,
        );
    }

    /// Applies a selection already committed by the CLI authority path.
    pub fn applyPersistedSelection(
        self: *OutboundManager,
        group_name: []const u8,
        proxy_name: []const u8,
    ) !bool {
        return self.selectProxyInternal(
            group_name,
            proxy_name,
            false,
            .persisted,
        );
    }

    pub fn applyTransientSelection(
        self: *OutboundManager,
        group_name: []const u8,
        proxy_name: []const u8,
    ) !bool {
        return self.selectProxyInternal(
            group_name,
            proxy_name,
            false,
            .transient,
        );
    }

    pub const PersistedSelectionTransaction = struct {
        manager: *OutboundManager,
        selections: []const config_catalog.Selection,
        generation: u64,
        active: bool = true,

        pub fn commit(self: *PersistedSelectionTransaction) bool {
            std.debug.assert(self.active);
            defer {
                self.active = false;
                self.manager.unlockSelections();
            }
            if (self.generation < self.manager.selection_generation) {
                return false;
            }
            self.manager.commitPersistedSelectionsLocked(
                self.selections,
                self.generation,
            );
            return true;
        }

        pub fn deinit(self: *PersistedSelectionTransaction) void {
            if (!self.active) return;
            self.active = false;
            self.manager.unlockSelections();
        }
    };

    fn validateAndReservePersistedSelectionsLocked(
        self: *OutboundManager,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !bool {
        if (generation < self.selection_generation) return false;
        for (selections) |selection| {
            var valid = false;
            for (self.config.proxy_groups.items) |group| {
                if (!std.mem.eql(u8, group.name, selection.group)) continue;
                for (group.proxies.items) |proxy| {
                    if (std.mem.eql(u8, proxy, selection.proxy)) {
                        valid = true;
                        break;
                    }
                }
                break;
            }
            if (!valid) return false;
        }
        try self.group_selections.ensureUnusedCapacity(@intCast(selections.len));
        try self.group_selection_sources.ensureUnusedCapacity(
            @intCast(selections.len),
        );
        return true;
    }

    pub fn beginPersistedSelections(
        self: *OutboundManager,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !?PersistedSelectionTransaction {
        self.lockSelections();
        errdefer self.unlockSelections();
        if (!try self.validateAndReservePersistedSelectionsLocked(
            selections,
            generation,
        )) {
            self.unlockSelections();
            return null;
        }
        return .{
            .manager = self,
            .selections = selections,
            .generation = generation,
        };
    }

    pub fn preparePersistedSelections(
        self: *OutboundManager,
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

    fn commitPersistedSelectionsLocked(
        self: *OutboundManager,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) void {
        self.group_selections.clearRetainingCapacity();
        self.group_selection_sources.clearRetainingCapacity();
        for (selections) |selection| {
            for (self.config.proxy_groups.items) |group| {
                if (!std.mem.eql(u8, group.name, selection.group)) continue;
                for (group.proxies.items) |proxy| {
                    if (!std.mem.eql(u8, proxy, selection.proxy)) continue;
                    self.group_selections.putAssumeCapacity(group.name, proxy);
                    self.group_selection_sources.putAssumeCapacity(
                        group.name,
                        .persisted,
                    );
                    break;
                }
                break;
            }
        }
        self.selection_generation = generation;
    }

    pub fn commitPersistedSelections(
        self: *OutboundManager,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) bool {
        self.lockSelections();
        defer self.unlockSelections();
        if (generation < self.selection_generation) return false;
        self.commitPersistedSelectionsLocked(selections, generation);
        return true;
    }

    pub const SelectionBarrier = struct {
        manager: *OutboundManager,
        active: bool = true,

        pub fn deinit(self: *SelectionBarrier) void {
            if (!self.active) return;
            self.active = false;
            self.manager.unlockSelections();
        }
    };

    pub fn acquireSelectionBarrier(self: *OutboundManager) SelectionBarrier {
        self.lockSelections();
        return .{ .manager = self };
    }

    pub fn waitForPersistedSelectionUpdates(self: *OutboundManager) void {
        var barrier = self.acquireSelectionBarrier();
        barrier.deinit();
    }

    pub fn persistedSelectionGeneration(self: *OutboundManager) u64 {
        self.lockSelections();
        defer self.unlockSelections();
        return self.selection_generation;
    }

    pub fn applyPersistedSelections(
        self: *OutboundManager,
        selections: []const config_catalog.Selection,
        generation: u64,
    ) !bool {
        var transaction = (try self.beginPersistedSelections(
            selections,
            generation,
        )) orelse return false;
        defer transaction.deinit();
        return transaction.commit();
    }

    /// daemon 实际加载的配置 key（启动时设定）。status 经 IPC 读取此值而非
    /// 用户指针 getCurrentConfigName，避免配置切换未重启 daemon 时的错位。
    pub fn configKey(self: *const OutboundManager) ?[]const u8 {
        return self.config_key;
    }

    /// 拷贝当前 group_selections 的快照（group → proxy，owned）。status 经 IPC
    /// 读取 daemon 运行时内存状态，而非 meta.json 持久化层——后者在
    /// config_key 与 active_config 错位时会读到空，显示 default 而与实际不符。
    pub fn snapshotSelections(self: *OutboundManager, allocator: std.mem.Allocator) ![]runtime_selection.SelectionEntry {
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
            const group = allocator.dupe(u8, entry.key_ptr.*) catch continue;
            const proxy = allocator.dupe(u8, entry.value_ptr.*) catch {
                allocator.free(group);
                continue;
            };
            const source = self.group_selection_sources.get(
                entry.key_ptr.*,
            ) orelse .persisted;
            entries.append(allocator, .{
                .group = group,
                .proxy = proxy,
                .source = source,
            }) catch {
                allocator.free(group);
                allocator.free(proxy);
                continue;
            };
        }
        return entries.toOwnedSlice(allocator);
    }

    fn selectProxyInternal(
        self: *OutboundManager,
        group_name: []const u8,
        proxy_name: []const u8,
        persist: bool,
        source: runtime_selection.SelectionSource,
    ) !bool {
        self.lockSelections();
        defer self.unlockSelections();

        for (self.config.proxy_groups.items) |grp| {
            if (std.mem.eql(u8, grp.name, group_name)) {
                for (grp.proxies.items) |pname| {
                    if (std.mem.eql(u8, pname, proxy_name)) {
                        const previous = self.group_selections.get(grp.name);
                        const previous_source = self.group_selection_sources.get(
                            grp.name,
                        );
                        try self.group_selections.ensureUnusedCapacity(1);
                        try self.group_selection_sources.ensureUnusedCapacity(1);
                        self.group_selections.putAssumeCapacity(grp.name, pname);
                        self.group_selection_sources.putAssumeCapacity(
                            grp.name,
                            source,
                        );
                        if (persist) {
                            self.persistSelections() catch |err| {
                                if (previous) |old_proxy| {
                                    self.group_selections.getPtr(grp.name).?.* =
                                        old_proxy;
                                    self.group_selection_sources.getPtr(
                                        grp.name,
                                    ).?.* = previous_source orelse .persisted;
                                } else {
                                    std.debug.assert(
                                        self.group_selections.remove(grp.name),
                                    );
                                    std.debug.assert(
                                        self.group_selection_sources.remove(
                                            grp.name,
                                        ),
                                    );
                                }
                                return err;
                            };
                        }
                        std.debug.print(
                            "[Manager] Group '{s}' selected: {s}\n",
                            .{ grp.name, pname },
                        );
                        return true;
                    }
                }
                std.debug.print("[Manager] Proxy '{s}' not found in group '{s}'\n", .{ proxy_name, group_name });
                return false;
            }
        }
        std.debug.print("[Manager] Group '{s}' not found\n", .{group_name});
        return false;
    }

    fn persistSelectionsPut(
        self: *OutboundManager,
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
        self: *OutboundManager,
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

    fn persistSelections(self: *OutboundManager) !void {
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
    pub fn loadPersistedSelections(self: *OutboundManager) !void {
        const key = self.config_key orelse return;

        var meta_data = try meta.load(self.allocator);
        defer meta_data.deinit();

        const cm = meta_data.configs.get(key) orelse return;

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

    pub fn setTrafficReady(self: *OutboundManager, ready: bool) void {
        self.traffic_ready.store(ready, .release);
    }

    fn waitForTrafficReady(self: *OutboundManager) void {
        while (!self.traffic_ready.load(.acquire)) {
            compat.sleepNs(1 * std.time.ns_per_ms);
        }
    }

    /// 根据代理名称建立连接（返回加密的代理流）
    pub fn connect(self: *OutboundManager, proxy_name: []const u8, target: []const u8, port: u16) !ProxyStream {
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

        self.lockSelections();
        var current_name = proxy_name;
        var iteration: usize = 0;
        while (iteration < 10) : (iteration += 1) {
            const next = self.resolveProxyGroupLocked(current_name) orelse break;
            std.debug.print("[Manager] Resolved {s} to {s}\n", .{ current_name, next });
            current_name = next;
        }
        self.unlockSelections();

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
        switch (proxy.proxy_type) {
            .direct => return try self.connectDirectTarget(target, port),
            .reject => return error.ConnectionRejected,
            else => {},
        }

        if (shouldBypassProxyForTarget(target)) {
            std.debug.print("[Manager] Bypassing proxy for local/private target: {s}:{d}\n", .{ target, port });
            return try self.connectDirectTarget(target, port);
        }
        return try self.connectToProxy(proxy, target, port);
    }

    /// Reject all v1 UDP proxy paths before dialing. DIRECT and REJECT preserve
    /// their narrower policy errors so SOCKS5 can report an accurate denial.
    pub fn connectUdp(self: *OutboundManager, proxy_name: []const u8) !ProxyStream {
        self.waitForTrafficReady();
        if (std.mem.eql(u8, proxy_name, "DIRECT")) return error.UdpNotSupportedForDirect;
        if (std.mem.eql(u8, proxy_name, "REJECT")) return error.ConnectionRejected;

        // Resolve nested proxy groups exactly like connect() (lines 416-424).
        self.lockSelections();
        var current_name = proxy_name;
        var iter: usize = 0;
        while (iter < 10) : (iter += 1) {
            if (self.resolveProxyGroupLocked(current_name)) |next| {
                current_name = next;
            } else {
                break;
            }
        }
        self.unlockSelections();

        // A group may resolve to the literal DIRECT/REJECT names.
        if (std.mem.eql(u8, current_name, "DIRECT")) return error.UdpNotSupportedForDirect;
        if (std.mem.eql(u8, current_name, "REJECT")) return error.ConnectionRejected;

        const proxy = self.findProxy(current_name) orelse return error.ProxyNotFound;
        return switch (proxy.proxy_type) {
            .direct => error.UdpNotSupportedForDirect,
            .reject => error.ConnectionRejected,
            else => error.UnsupportedProxyType,
        };
    }

    /// Open the single UoT v2 stream for an association: gate on the proxy being
    /// anytls + udp:true, then check out a Stream to the magic UoT dest via the
    /// SAME SessionPool the TCP path uses (shared poolKey). Wrap it in a heap
    /// AnyTlsUdpStream owned by the returned ProxyStream's UDP arm.
    fn connectAnyTlsUdp(self: *OutboundManager, proxy: *const Proxy) !ProxyStream {
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

    /// 连接到一个具体的代理
    fn connectToProxy(self: *OutboundManager, proxy: *const Proxy, target: []const u8, port: u16) !ProxyStream {
        switch (proxy.proxy_type) {
            .direct => {
                return try self.connectDirectTarget(target, port);
            },
            .reject => {
                return error.ConnectionRejected;
            },
            .ss => {
                const client = try self.makeShadowsocksClient(proxy);
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
            .anytls, .vmess => return error.UnsupportedProxyType,
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
            .vless, .http, .socks5 => return error.UnsupportedProxyType,
        }
    }

    fn makeShadowsocksClient(self: *OutboundManager, proxy: *const Proxy) !*ss.ShadowsocksClient {
        const client = try self.allocator.create(ss.ShadowsocksClient);
        errdefer self.allocator.destroy(client);

        if (proxy.obfs_mode) |obfs_mode| {
            const obfs_host = proxy.obfs_host orelse proxy.server;
            client.* = try ss.ShadowsocksClient.initWithObfs(
                self.allocator,
                proxy.server,
                proxy.port,
                proxy.password orelse "",
                proxy.cipher orelse "aes-128-gcm",
                obfs_mode,
                obfs_host,
            );
        } else {
            client.* = try ss.ShadowsocksClient.init(
                self.allocator,
                proxy.server,
                proxy.port,
                proxy.password orelse "",
                proxy.cipher orelse "aes-128-gcm",
            );
        }

        return client;
    }

    fn connectDirectTarget(self: *OutboundManager, target: []const u8, port: u16) !ProxyStream {
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

    /// 解析代理组为实际代理名称
    fn resolveProxyGroupLocked(
        self: *OutboundManager,
        group_name: []const u8,
    ) ?[]const u8 {
        for (self.config.proxy_groups.items) |grp| {
            if (std.mem.eql(u8, grp.name, group_name)) {
                // Prefer the user selection while the caller holds the lock.
                const selected = self.group_selections.get(group_name);
                if (selected) |value| {
                    std.debug.print("[Manager] Proxy group {s} -> {s} (selected)\n", .{ group_name, value });
                    return value;
                }
                // 否则使用第一个
                if (grp.proxies.items.len > 0) {
                    const proxy_name = grp.proxies.items[0];
                    std.debug.print("[Manager] Proxy group {s} -> {s} (default)\n", .{ group_name, proxy_name });
                    return proxy_name;
                }
            }
        }
        return null;
    }

    fn lockSelections(self: *OutboundManager) void {
        std.Io.Threaded.mutexLock(&self.group_selections_mutex);
    }

    fn unlockSelections(self: *OutboundManager) void {
        std.Io.Threaded.mutexUnlock(&self.group_selections_mutex);
    }

    fn findProxy(self: *OutboundManager, name: []const u8) ?*const Proxy {
        for (self.config.proxies.items) |*proxy| {
            if (std.mem.eql(u8, proxy.name, name)) {
                return proxy;
            }
        }
        return null;
    }
};

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

    var manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    const proxy = Proxy{
        .name = "ss-test",
        .proxy_type = .ss,
        .server = "127.0.0.1",
        .port = 8388,
        .password = "password",
        .cipher = "aes-128-gcm",
        .obfs_mode = "http",
        .obfs_host = "example.com",
    };

    const c1 = try manager.makeShadowsocksClient(&proxy);
    defer {
        c1.deinit();
        allocator.destroy(c1);
    }
    const c2 = try manager.makeShadowsocksClient(&proxy);
    defer {
        c2.deinit();
        allocator.destroy(c2);
    }

    try std.testing.expect(c1 != c2);
    try std.testing.expect(c1.stream == null);
    try std.testing.expect(c2.stream == null);
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

    var manager = try OutboundManager.init(allocator, &cfg);
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
        manager.connectToProxy(&proxy, "example.com", 80),
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

    var mgr = try OutboundManager.init(allocator, &cfg);
    defer mgr.deinit();

    try std.testing.expect(try mgr.selectProxyInternal("G1", "P1", false, .transient));
    try std.testing.expectEqual(@as(usize, 0), mgr.persist_invocations);

    var durable = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iterator = durable.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        durable.deinit();
    }
    try mgr.copyPersistableSelectionsLocked(&durable);
    try std.testing.expectEqual(@as(usize, 0), durable.count());
    try std.testing.expect(try mgr.applyPersistedSelection("G1", "P1"));
    try mgr.copyPersistableSelectionsLocked(&durable);
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

    var manager = try OutboundManager.initWithKey(
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

    var mgr = try OutboundManager.initWithKey(allocator, &cfg, "runtimkey");
    defer mgr.deinit();

    // configKey reflects the init key; empty selections -> empty snapshot.
    try std.testing.expectEqualStrings("runtimkey", mgr.configKey().?);
    const snap0 = try mgr.snapshotSelections(allocator);
    defer runtime_selection.freeSelectionEntries(allocator, snap0);
    try std.testing.expectEqual(@as(usize, 0), snap0.len);

    // Select P2 in G1 (persist=false: no meta.json writes) -> snapshot reflects it.
    try std.testing.expect(try mgr.selectProxyInternal(
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
    try std.testing.expect(!mgr.commitPersistedSelections(&stale, 1));
    const snap2 = try mgr.snapshotSelections(allocator);
    defer runtime_selection.freeSelectionEntries(allocator, snap2);
    try std.testing.expectEqualStrings("P1", snap2[0].proxy);
    try std.testing.expectEqual(
        runtime_selection.SelectionSource.persisted,
        snap2[0].source,
    );

    try std.testing.expect(try mgr.selectProxyInternal(
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

    var manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    const policies = [_][]const u8{ "REJECT", "deny", "blocked" };
    for (policies) |policy| {
        try std.testing.expectError(
            error.ConnectionRejected,
            manager.connect(policy, "127.0.0.1", 1),
        );
    }
}

test "connect rejects disabled proxy types before dialing" {
    // The manager is the second fail-closed boundary after config validation.
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
        .name = try allocator.dupe(u8, "vmess-disabled"),
        .proxy_type = .vmess,
        .server = try allocator.dupe(u8, "127.0.0.1"),
        .port = 1,
        .uuid = try allocator.dupe(
            u8,
            "12345678-1234-1234-1234-123456789abc",
        ),
    });

    var manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();
    try std.testing.expectError(
        error.UnsupportedProxyType,
        manager.connect("vmess-disabled", "8.8.8.8", 53),
    );
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

    var manager = try OutboundManager.init(allocator, &cfg);
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
    var manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    try std.testing.expectError(error.UdpNotSupportedForDirect, manager.connectUdp("DIRECT"));
}

test "D5: connectUdp(REJECT) -> error.ConnectionRejected" {
    const allocator = std.testing.allocator;
    var cfg = try makeUdpTestConfig(allocator);
    defer cfg.deinit();
    var manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    try std.testing.expectError(error.ConnectionRejected, manager.connectUdp("REJECT"));
}

test "v1 capability gate rejects AnyTLS UDP before dialing" {
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
    var manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    try std.testing.expectError(
        error.UnsupportedProxyType,
        manager.connectUdp("atls"),
    );
}

test "v1 connectUdp rejects AnyTLS without dialing" {
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
    var manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    try std.testing.expectError(error.UnsupportedProxyType, manager.connectUdp("atls"));
}

test "v1 connectUdp rejects Shadowsocks UDP" {
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
    var manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    try std.testing.expectError(error.UnsupportedProxyType, manager.connectUdp("ss-udp"));
}

test "v1 connectUdp rejects a group resolving to AnyTLS" {
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

    var manager = try OutboundManager.init(allocator, &cfg);
    defer manager.deinit();

    // Group resolution cannot bypass the v1 capability gate.
    try std.testing.expectError(error.UnsupportedProxyType, manager.connectUdp("G"));
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
