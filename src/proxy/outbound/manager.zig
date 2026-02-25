const std = @import("std");
const net = std.net;
const Config = @import("../../config.zig").Config;
const Proxy = @import("../../config.zig").Proxy;
const ProxyType = @import("../../config.zig").ProxyType;
const ss = @import("shadowsocks.zig");
const vmess = @import("../../protocol/vmess.zig");
const trojan = @import("../../protocol/trojan.zig");
const vless = @import("../../protocol/vless.zig");

/// 代理流包装器
pub const ProxyStream = struct {
    base_stream: net.Stream,
    ss_client: ?*ss.ShadowsocksClient = null,
    is_encrypted: bool = false,

    pub fn initDirect(stream: net.Stream) ProxyStream {
        return .{
            .base_stream = stream,
            .is_encrypted = false,
        };
    }

    pub fn initShadowsocks(stream: net.Stream, client: *ss.ShadowsocksClient) ProxyStream {
        return .{
            .base_stream = stream,
            .ss_client = client,
            .is_encrypted = true,
        };
    }

    pub fn write(self: *ProxyStream, data: []const u8) !void {
        if (self.is_encrypted) {
            try self.ss_client.?.write(data);
        } else {
            try self.base_stream.writeAll(data);
        }
    }

    pub fn read(self: *ProxyStream, buf: []u8) !usize {
        if (self.is_encrypted) {
            return try self.ss_client.?.read(buf);
        } else {
            return try self.base_stream.read(buf);
        }
    }

    pub fn close(self: *ProxyStream) void {
        self.base_stream.close();
    }

    pub fn getHandle(self: *ProxyStream) std.posix.fd_t {
        return self.base_stream.handle;
    }
};

/// 代理出站管理器
pub const OutboundManager = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    ss_clients: std.StringHashMap(*ss.ShadowsocksClient),
    vmess_clients: std.StringHashMap(*vmess.Client),
    trojan_clients: std.StringHashMap(*trojan.Client),
    vless_clients: std.StringHashMap(*vless.Client),

    /// 每个代理组的当前选择（group_name → proxy_name）
    group_selections: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, config: *const Config) !OutboundManager {
        var manager = OutboundManager{
            .allocator = allocator,
            .config = config,
            .ss_clients = std.StringHashMap(*ss.ShadowsocksClient).init(allocator),
            .vmess_clients = std.StringHashMap(*vmess.Client).init(allocator),
            .trojan_clients = std.StringHashMap(*trojan.Client).init(allocator),
            .vless_clients = std.StringHashMap(*vless.Client).init(allocator),
            .group_selections = std.StringHashMap([]const u8).init(allocator),
        };

        // 预初始化代理客户端
        for (config.proxies.items) |*proxy| {
            if (proxy.proxy_type == .ss) {
                std.debug.print("[Manager] SS proxy: {s}, obfs_mode={s}, obfs_host={s}, plugin={s}\n", .{ proxy.name, proxy.obfs_mode orelse "null", proxy.obfs_host orelse "null", proxy.plugin orelse "null" });
            }
            switch (proxy.proxy_type) {
                .ss => {
                    const client = try allocator.create(ss.ShadowsocksClient);
                    // 启用 obfs
                    const use_obfs = true;
                    if (use_obfs and proxy.obfs_mode != null) {
                        const obfs_mode = proxy.obfs_mode.?;
                        const obfs_host = proxy.obfs_host orelse proxy.server;
                        client.* = try ss.ShadowsocksClient.initWithObfs(
                            allocator,
                            proxy.server,
                            proxy.port,
                            proxy.password orelse "",
                            proxy.cipher orelse "aes-128-gcm",
                            obfs_mode,
                            obfs_host,
                        );
                    } else {
                        client.* = try ss.ShadowsocksClient.init(
                            allocator,
                            proxy.server,
                            proxy.port,
                            proxy.password orelse "",
                            proxy.cipher orelse "aes-128-gcm",
                        );
                    }
                    try manager.ss_clients.put(proxy.name, client);
                },
                .vmess => {
                    const client = try allocator.create(vmess.Client);
                    client.* = try vmess.Client.init(allocator, .{
                        .id = proxy.uuid orelse return error.MissingUuid,
                        .address = proxy.server,
                        .port = proxy.port,
                        .alter_id = proxy.alter_id,
                    });
                    try manager.vmess_clients.put(proxy.name, client);
                },
                .trojan => {
                    const client = try allocator.create(trojan.Client);
                    client.* = try trojan.Client.init(allocator, .{
                        .password = proxy.password orelse return error.MissingPassword,
                        .address = proxy.server,
                        .port = proxy.port,
                        .sni = proxy.sni,
                        .skip_cert_verify = proxy.skip_cert_verify,
                    });
                    try manager.trojan_clients.put(proxy.name, client);
                },
                .vless => {
                    const client = try allocator.create(vless.Client);
                    client.* = try vless.Client.init(allocator, .{
                        .id = proxy.uuid orelse return error.MissingUuid,
                        .address = proxy.server,
                        .port = proxy.port,
                    });
                    try manager.vless_clients.put(proxy.name, client);
                },
                else => {},
            }
        }

        return manager;
    }

    pub fn deinit(self: *OutboundManager) void {
        var iter = self.ss_clients.valueIterator();
        while (iter.next()) |client| {
            client.*.deinit();
            self.allocator.destroy(client.*);
        }
        self.ss_clients.deinit();

        var vmess_iter = self.vmess_clients.valueIterator();
        while (vmess_iter.next()) |client| {
            self.allocator.destroy(client.*);
        }
        self.vmess_clients.deinit();

        var trojan_iter = self.trojan_clients.valueIterator();
        while (trojan_iter.next()) |client| {
            self.allocator.destroy(client.*);
        }
        self.trojan_clients.deinit();

        var vless_iter = self.vless_clients.valueIterator();
        while (vless_iter.next()) |client| {
            self.allocator.destroy(client.*);
        }
        self.vless_clients.deinit();
        self.group_selections.deinit();
    }

    /// 设置代理组的选择（由 TUI/API 调用）
    /// 注意：存储 config 中的稳定字符串引用，而非调用者的临时切片
    pub fn selectProxy(self: *OutboundManager, group_name: []const u8, proxy_name: []const u8) void {
        for (self.config.proxy_groups.items) |grp| {
            if (std.mem.eql(u8, grp.name, group_name)) {
                for (grp.proxies.items) |pname| {
                    if (std.mem.eql(u8, pname, proxy_name)) {
                        self.group_selections.put(grp.name, pname) catch {};
                        std.debug.print("[Manager] Group '{s}' selected: {s}\n", .{ grp.name, pname });
                        return;
                    }
                }
                std.debug.print("[Manager] Proxy '{s}' not found in group '{s}'\n", .{ proxy_name, group_name });
                return;
            }
        }
        std.debug.print("[Manager] Group '{s}' not found\n", .{group_name});
    }

    /// 根据代理名称建立连接（返回加密的代理流）
    pub fn connect(self: *OutboundManager, proxy_name: []const u8, target: []const u8, port: u16) !ProxyStream {
        std.debug.print("[Manager] connect: proxy={s}, target={s}:{d}\n", .{ proxy_name, target, port });

        // 处理 DIRECT 和 REJECT 特殊代理
        if (std.mem.eql(u8, proxy_name, "DIRECT")) {
            std.debug.print("[Manager] Using DIRECT\n", .{});
            var addr_list = try net.getAddressList(self.allocator, target, port);
            defer addr_list.deinit();
            if (addr_list.addrs.len == 0) return error.HostNotFound;
            const stream = try net.tcpConnectToAddress(addr_list.addrs[0]);
            return ProxyStream.initDirect(stream);
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
                var addr_list = try net.getAddressList(self.allocator, target, port);
                defer addr_list.deinit();
                if (addr_list.addrs.len == 0) return error.HostNotFound;
                const stream = try net.tcpConnectToAddress(addr_list.addrs[0]);
                return ProxyStream.initDirect(stream);
            },
            .reject => {
                return error.ConnectionRejected;
            },
            .ss => {
                const client = self.ss_clients.get(proxy.name) orelse return error.ClientNotFound;
                const addr = ss.Address{
                    .host = target,
                    .port = port,
                };
                const stream = try client.connect(addr);
                return ProxyStream.initShadowsocks(stream, client);
            },
            .vmess => {
                const client = self.vmess_clients.get(proxy.name) orelse return error.ClientNotFound;
                const stream = try client.connect(target, port);
                return ProxyStream.initDirect(stream);
            },
            .trojan => {
                const client = self.trojan_clients.get(proxy.name) orelse return error.ClientNotFound;
                const stream = try client.connect(target, port);
                return ProxyStream.initDirect(stream);
            },
            .vless => {
                const client = self.vless_clients.get(proxy.name) orelse return error.ClientNotFound;
                const stream = try client.connect(target, port);
                return ProxyStream.initDirect(stream);
            },
            else => {
                std.debug.print("Proxy type not implemented yet\n", .{});
                return error.NotImplemented;
            },
        }
    }

    /// 解析代理组为实际代理名称
    fn resolveProxyGroup(self: *OutboundManager, group_name: []const u8) ?[]const u8 {
        for (self.config.proxy_groups.items) |grp| {
            if (std.mem.eql(u8, grp.name, group_name)) {
                // 优先使用用户选择的代理
                if (self.group_selections.get(group_name)) |selected| {
                    std.debug.print("[Manager] Proxy group {s} -> {s} (selected)\n", .{ group_name, selected });
                    return selected;
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

    fn findProxy(self: *OutboundManager, name: []const u8) ?*const Proxy {
        for (self.config.proxies.items) |*proxy| {
            if (std.mem.eql(u8, proxy.name, name)) {
                return proxy;
            }
        }
        return null;
    }
};
