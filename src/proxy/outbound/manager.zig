const std = @import("std");
const compat = @import("../../compat.zig");
const net = compat.net;
const Config = @import("../../config.zig").Config;
const Proxy = @import("../../config.zig").Proxy;
const ProxyType = @import("../../config.zig").ProxyType;
const meta = @import("../../meta.zig");
const ss = @import("shadowsocks.zig");
const anytls = @import("../../protocol/anytls.zig");
const anytls_pool = @import("anytls_pool.zig");
const crypto = std.crypto;
const vmess = @import("../../protocol/vmess.zig");
const trojan = @import("../../protocol/trojan.zig");
const vless = @import("../../protocol/vless.zig");
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

    pub fn move(self: *ProxyStream) ProxyStream {
        const moved = self.*;
        self.base_stream = .{ .handle = -1 };
        self.allocator = null;
        self.owned_ss_client = null;
        self.owned_anytls_stream = null;
        self.owned_trojan_client = null;
        self.is_closed = true;
        return moved;
    }

    pub fn write(self: *ProxyStream, data: []const u8) !void {
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
        if (self.is_closed) return error.StreamClosed;
        if (self.owned_anytls_stream) |stream| {
            return try stream.readBlocking(buf);
        }
        return try self.read(buf);
    }

    pub fn close(self: *ProxyStream) void {
        if (self.is_closed) return;
        self.is_closed = true;

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

    pub fn getHandle(self: *ProxyStream) std.posix.fd_t {
        if (self.is_closed) return -1;
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
    group_selections_mutex: std.Io.Mutex = .init,

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

    pub fn initWithKey(allocator: std.mem.Allocator, config_arg: *const Config, config_key: ?[]const u8) !OutboundManager {
        const manager = OutboundManager{
            .allocator = allocator,
            .config = config_arg,
            .group_selections = std.StringHashMap([]const u8).init(allocator),
            .config_key = if (config_key) |k| allocator.dupe(u8, k) catch null else null,
        };

        return manager;
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

    /// 设置代理组的选择（由 TUI/API 调用）
    /// 注意：存储 config 中的稳定字符串引用，而非调用者的临时切片
    pub fn selectProxy(self: *OutboundManager, group_name: []const u8, proxy_name: []const u8) void {
        self.selectProxyInternal(group_name, proxy_name, true);
    }

    fn selectProxyInternal(self: *OutboundManager, group_name: []const u8, proxy_name: []const u8, persist: bool) void {
        self.lockSelections();
        defer self.unlockSelections();

        for (self.config.proxy_groups.items) |grp| {
            if (std.mem.eql(u8, grp.name, group_name)) {
                for (grp.proxies.items) |pname| {
                    if (std.mem.eql(u8, pname, proxy_name)) {
                        self.group_selections.put(grp.name, pname) catch {};
                        std.debug.print("[Manager] Group '{s}' selected: {s}\n", .{ grp.name, pname });

                        if (persist) {
                            // 持久化到 meta.json
                            self.persistSelections();
                        }
                        return;
                    }
                }
                std.debug.print("[Manager] Proxy '{s}' not found in group '{s}'\n", .{ proxy_name, group_name });
                return;
            }
        }
        std.debug.print("[Manager] Group '{s}' not found\n", .{group_name});
    }

    /// 持久化当前 selections 到 meta.json
    fn persistSelections(self: *OutboundManager) void {
        const key = self.config_key orelse return;
        self.persist_invocations += 1;

        var meta_data = meta.load(self.allocator) catch return;
        defer meta_data.deinit();

        const entry = meta_data.configs.getPtr(key) orelse return;

        // 清除旧的 selections
        {
            var it = entry.selections.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            entry.selections.clearRetainingCapacity();
        }

        // 写入当前 selections
        var sel_it = self.group_selections.iterator();
        while (sel_it.next()) |e| {
            const gn = self.allocator.dupe(u8, e.key_ptr.*) catch continue;
            const pn = self.allocator.dupe(u8, e.value_ptr.*) catch {
                self.allocator.free(gn);
                continue;
            };
            entry.selections.put(gn, pn) catch {
                self.allocator.free(gn);
                self.allocator.free(pn);
                continue;
            };
        }

        meta.save(self.allocator, &meta_data) catch {};
    }

    /// 从 meta.json 加载持久化的 selections
    pub fn loadPersistedSelections(self: *OutboundManager) void {
        const key = self.config_key orelse return;

        var meta_data = meta.load(self.allocator) catch return;
        defer meta_data.deinit();

        const cm = meta_data.configs.get(key) orelse return;

        var it = cm.selections.iterator();
        while (it.next()) |entry| {
            self.selectProxyInternal(entry.key_ptr.*, entry.value_ptr.*, false);
        }
    }

    /// 根据代理名称建立连接（返回加密的代理流）
    pub fn connect(self: *OutboundManager, proxy_name: []const u8, target: []const u8, port: u16) !ProxyStream {
        std.debug.print("[Manager] connect: proxy={s}, target={s}:{d}\n", .{ proxy_name, target, port });

        if (shouldBypassProxyForTarget(target)) {
            std.debug.print("[Manager] Bypassing proxy for local/private target: {s}:{d}\n", .{ target, port });
            return try self.connectDirectTarget(target, port);
        }

        // 处理 DIRECT 和 REJECT 特殊代理
        if (std.mem.eql(u8, proxy_name, "DIRECT")) {
            std.debug.print("[Manager] Using DIRECT\n", .{});
            return try self.connectDirectTarget(target, port);
        }
        if (std.mem.eql(u8, proxy_name, "REJECT")) {
            return error.ConnectionRejected;
        }

        // 如果是代理组名称，解析为实际代理（递归解析嵌套的代理组）
        var current_name = proxy_name;
        var resolved_name: ?[]const u8 = undefined;
        var iter: usize = 0;
        while (iter < 10) : (iter += 1) {
            resolved_name = self.resolveProxyGroup(current_name);
            if (resolved_name) |next| {
                std.debug.print("[Manager] Resolved {s} to {s}\n", .{ current_name, next });
                current_name = next;
            } else {
                break;
            }
        }

        // 现在 current_name 应该是一个实际的代理名称
        const proxy = self.findProxy(current_name) orelse {
            std.debug.print("[Manager] Proxy not found: {s}\n", .{current_name});
            return error.ProxyNotFound;
        };
        return try self.connectToProxy(proxy, target, port);
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
            .anytls => {
                // Route through the per-identity SessionPool (§12): reuse a warm
                // idle Session or dial a fresh one, then check out a multiplexed
                // Stream. The pool owns the Session; ProxyStream borrows the Stream.
                const key = try self.poolKey(proxy);
                defer self.allocator.free(key);
                const pool = try self.getOrCreatePool(key, proxy);
                const stream = try pool.createStream(target, port);
                return ProxyStream.initAnyTlsStream(stream);
            },
            .vmess => {
                var client = try vmess.Client.init(self.allocator, .{
                    .id = proxy.uuid orelse return error.MissingUuid,
                    .address = proxy.server,
                    .port = proxy.port,
                    .alter_id = proxy.alter_id,
                });
                const stream = try client.connect(target, port);
                return ProxyStream.initDirect(stream);
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
            .vless => {
                var client = try vless.Client.init(self.allocator, .{
                    .id = proxy.uuid orelse return error.MissingUuid,
                    .address = proxy.server,
                    .port = proxy.port,
                });
                const stream = try client.connect(target, port);
                return ProxyStream.initDirect(stream);
            },
            else => {
                std.debug.print("Proxy type not implemented yet\n", .{});
                return error.NotImplemented;
            },
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
    fn resolveProxyGroup(self: *OutboundManager, group_name: []const u8) ?[]const u8 {
        for (self.config.proxy_groups.items) |grp| {
            if (std.mem.eql(u8, grp.name, group_name)) {
                // 优先使用用户选择的代理
                self.lockSelections();
                const selected = self.group_selections.get(group_name);
                self.unlockSelections();
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

    mgr.selectProxyInternal("G1", "P1", false);
    try std.testing.expectEqual(@as(usize, 0), mgr.persist_invocations);
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
