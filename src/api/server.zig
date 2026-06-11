const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const Config = @import("../config.zig").Config;
const Engine = @import("../rule/engine.zig").Engine;
const OutboundManager = @import("../proxy/outbound/manager.zig").OutboundManager;
const build_options = @import("build_options");
const socket_options = @import("../socket_options.zig");

/// REST API 服务器
pub const ApiServer = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    engine: *Engine,
    manager: *OutboundManager,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, config: *const Config, engine: *Engine, manager: *OutboundManager, port: u16) ApiServer {
        return .{
            .allocator = allocator,
            .config = config,
            .engine = engine,
            .manager = manager,
            .port = port,
        };
    }

    pub fn start(self: *ApiServer) !void {
        const address = try net.Address.parseIp4("127.0.0.1", self.port);
        // SO_REUSEADDR-only (see compat.net.listenReuseAddr): rebind past
        // TIME_WAIT on restart, but a 2nd active listener still fails.
        var server = try net.listenReuseAddr(address);
        defer server.deinit();

        std.debug.print("REST API listening on port {}\n", .{self.port});

        while (true) {
            const conn = try server.accept();
            socket_options.configureConnectedStream(conn.stream) catch |err| {
                std.debug.print("API accepted socket setup error: {}\n", .{err});
                conn.stream.close();
                continue;
            };
            // handleConnection owns the connection and closes it via its own
            // `defer conn.stream.close()` on every return path (success or
            // error). Do NOT close it again here, or the fd would be closed
            // twice — racing with concurrent fd allocation in other threads.
            self.handleConnection(conn) catch |err| {
                std.debug.print("API connection error: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *ApiServer, conn: net.Server.Connection) !void {
        defer conn.stream.close();

        var buf: [4096]u8 = undefined;
        const n = try conn.stream.read(&buf);
        if (n == 0) return;

        const request = buf[0..n];

        // 解析请求行
        const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
        const request_line = request[0..line_end];

        // 解析方法和路径
        const parts = std.mem.splitScalar(u8, request_line, ' ');
        var part_iter = parts;
        const method = part_iter.next() orelse return;
        const path = part_iter.next() orelse return;

        // 提取 body（\r\n\r\n 之后的部分）
        const body = if (std.mem.indexOf(u8, request, "\r\n\r\n")) |hdr_end|
            request[hdr_end + 4 ..]
        else
            "";

        std.debug.print("[API] {s} {s}\n", .{ method, path });

        // 路由
        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, path, "/")) {
                try self.sendJson(conn, comptime std.fmt.comptimePrint("{{\"version\":\"{s}\",\"hello\":\"zc\"}}", .{build_options.version}));
            } else if (std.mem.eql(u8, path, "/proxies")) {
                try self.handleGetProxies(conn);
            } else if (std.mem.eql(u8, path, "/rules")) {
                try self.handleGetRules(conn);
            } else if (std.mem.eql(u8, path, "/version")) {
                try self.sendJson(conn, comptime std.fmt.comptimePrint("{{\"version\":\"{s}\"}}", .{build_options.version}));
            } else {
                try self.sendError(conn, 404, "Not Found");
            }
        } else if (std.mem.eql(u8, method, "PUT")) {
            if (std.mem.startsWith(u8, path, "/proxies/")) {
                // CLI 侧对组名做了百分号编码（空格/特殊字符），这里解码还原。
                const group_buf = try self.allocator.dupe(u8, path[9..]);
                defer self.allocator.free(group_buf);
                const group_name = std.Uri.percentDecodeInPlace(group_buf);
                try self.handleSwitchProxy(conn, group_name, body);
            } else {
                try self.sendError(conn, 404, "Not Found");
            }
        } else {
            try self.sendError(conn, 405, "Method Not Allowed");
        }
    }

    fn handleGetProxies(self: *ApiServer, conn: net.Server.Connection) !void {
        var json = std.ArrayList(u8).empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"proxies\":[");

        for (self.config.proxies.items, 0..) |proxy, i| {
            if (i > 0) try json.appendSlice(self.allocator, ",");

            const type_str = switch (proxy.proxy_type) {
                .direct => "Direct",
                .reject => "Reject",
                .http => "Http",
                .socks5 => "Socks5",
                .ss => "Shadowsocks",
                .vmess => "Vmess",
                .trojan => "Trojan",
                .vless => "Vless",
                .anytls => "AnyTLS",
            };

            try json.print(self.allocator, "{{\"name\":\"{s}\",\"type\":\"{s}\",\"server\":\"{s}\",\"port\":{d}}}", .{ proxy.name, type_str, proxy.server, proxy.port });
        }

        try json.appendSlice(self.allocator, "]}");
        try self.sendJsonRaw(conn, json.items);
    }

    fn handleGetRules(self: *ApiServer, conn: net.Server.Connection) !void {
        var json = std.ArrayList(u8).empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"rules\":[");

        for (self.config.rules.items, 0..) |rule, i| {
            if (i > 0) try json.appendSlice(self.allocator, ",");

            const type_str = switch (rule.rule_type) {
                .domain => "DOMAIN",
                .domain_suffix => "DOMAIN-SUFFIX",
                .domain_keyword => "DOMAIN-KEYWORD",
                .ip_cidr => "IP-CIDR",
                .ip_cidr6 => "IP-CIDR6",
                .geoip => "GEOIP",
                .rule_set => "RULE-SET",
                .src_ip_cidr => "SRC-IP-CIDR",
                .dst_port => "DST-PORT",
                .src_port => "SRC-PORT",
                .process_name => "PROCESS-NAME",
                .final => "MATCH",
            };

            try json.print(self.allocator, "{{\"type\":\"{s}\",\"payload\":\"{s}\",\"target\":\"{s}\"}}", .{ type_str, rule.payload, rule.target });
        }

        try json.appendSlice(self.allocator, "]}");
        try self.sendJsonRaw(conn, json.items);
    }

    /// PUT /proxies/<group_name> body: {"name":"proxy_name"}
    ///
    /// body 经 std.json 解析（真实反转义 —— 节点名可含 `"`/`\`/换行等，
    /// 修复旧 extractJsonString 扫到第一个 `"` 字节截断转义名的 bug）；
    /// 组/节点先对照配置校验，未命中返回 404 而不是无条件 200（修复 CLI
    /// `data.applied` 假阳性）。
    fn handleSwitchProxy(self: *ApiServer, conn: net.Server.Connection, group_name: []const u8, body: []const u8) !void {
        const proxy_name = parseSelectionName(self.allocator, body) orelse {
            try self.sendError(conn, 400, "Missing name in body");
            return;
        };
        defer self.allocator.free(proxy_name);

        switch (validateSelection(self.config, group_name, proxy_name)) {
            .group_not_found => {
                try self.sendError(conn, 404, "Group not found");
                return;
            },
            .proxy_not_found => {
                try self.sendError(conn, 404, "Proxy not found in group");
                return;
            },
            .ok => {},
        }

        std.debug.print("[API] Switch proxy: group={s}, proxy={s}\n", .{ group_name, proxy_name });
        self.manager.selectProxy(group_name, proxy_name);

        // 响应体经 std.json 序列化（名称真实转义，禁止手拼 JSON）。
        var resp: std.Io.Writer.Allocating = .init(self.allocator);
        defer resp.deinit();
        std.json.Stringify.value(
            .{ .ok = true, .group = group_name, .proxy = proxy_name },
            .{ .whitespace = .minified },
            &resp.writer,
        ) catch return;
        try self.sendJsonRaw(conn, resp.written());
    }

    fn sendJson(self: *ApiServer, conn: net.Server.Connection, json_str: []const u8) !void {
        try self.sendJsonRaw(conn, json_str);
    }

    fn sendJsonRaw(self: *ApiServer, conn: net.Server.Connection, body: []const u8) !void {
        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}", .{ body.len, body });
        defer self.allocator.free(response);

        try conn.stream.writeAll(response);
    }

    fn sendError(self: *ApiServer, conn: net.Server.Connection, code: u16, message: []const u8) !void {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{message});
        defer self.allocator.free(body);

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}", .{ code, message, body.len, body });
        defer self.allocator.free(response);

        try conn.stream.writeAll(response);
    }
};

/// 从 PUT body 解析 `name` 字段（std.json，真实反转义）。返回 owned slice，
/// 调用方负责 free；body 非法/缺字段/非字符串返回 null。
pub fn parseSelectionName(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const name_val = parsed.value.object.get("name") orelse return null;
    if (name_val != .string) return null;
    return allocator.dupe(u8, name_val.string) catch null;
}

pub const SelectionCheck = enum { ok, group_not_found, proxy_not_found };

/// 对照配置校验选择目标（与 OutboundManager.selectProxyInternal 的成员
/// 匹配语义一致），让 handleSwitchProxy 能对未命中返回 404。
pub fn validateSelection(cfg: *const Config, group_name: []const u8, proxy_name: []const u8) SelectionCheck {
    for (cfg.proxy_groups.items) |grp| {
        if (std.mem.eql(u8, grp.name, group_name)) {
            for (grp.proxies.items) |member| {
                if (std.mem.eql(u8, member, proxy_name)) return .ok;
            }
            return .proxy_not_found;
        }
    }
    return .group_not_found;
}
