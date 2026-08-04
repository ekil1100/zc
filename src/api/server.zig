const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const config_mod = @import("../config.zig");
const Config = config_mod.Config;
const Engine = @import("../rule/engine.zig").Engine;
const OutboundManager = @import("../proxy/outbound/manager.zig").OutboundManager;
const build_options = @import("build_options");
const socket_options = @import("../socket_options.zig");
const runtime_selection = @import("../runtime_selection.zig");

pub const max_header_bytes: usize = 16 * 1024;
pub const max_body_bytes: usize = 64 * 1024;
pub const max_response_body_bytes: usize = 4 * 1024 * 1024;
const max_request_bytes = max_header_bytes + 4 + max_body_bytes;
const request_timeout_ms: i64 = 2_000;
const response_timeout_ms: i64 = 2_000;
const max_connections: u32 = 16;
const connection_stack_bytes: usize = 256 * 1024;

comptime {
    std.debug.assert(max_header_bytes < max_request_bytes);
    std.debug.assert(max_body_bytes < max_request_bytes);
    std.debug.assert(max_connections > 0);
}

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

pub const InspectResult = union(enum) {
    incomplete,
    complete: Request,
};

const OwnedRequest = struct {
    storage: []u8,
    request: Request,

    fn deinit(self: *OwnedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }
};

fn isHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!',
            '#',
            '$',
            '%',
            '&',
            '\'',
            '*',
            '+',
            '-',
            '.',
            '^',
            '_',
            '`',
            '|',
            '~',
            => {},
            else => return false,
        }
    }
    return true;
}

fn isHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte == '\t') continue;
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn isRequestTarget(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn parseContentLength(value: []const u8) !usize {
    if (value.len == 0) return error.InvalidRequest;
    var result: usize = 0;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidRequest;
        result = std.math.mul(usize, result, 10) catch
            return error.InvalidRequest;
        result = std.math.add(usize, result, byte - '0') catch
            return error.InvalidRequest;
    }
    return result;
}

pub fn inspectRequest(bytes: []const u8) !InspectResult {
    const header_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        if (bytes.len > max_header_bytes) return error.HeaderTooLarge;
        return .incomplete;
    };
    if (header_end > max_header_bytes) return error.HeaderTooLarge;

    const line_end = std.mem.indexOf(
        u8,
        bytes[0 .. header_end + 2],
        "\r\n",
    ) orelse return error.InvalidRequest;
    var parts = std.mem.splitScalar(u8, bytes[0..line_end], ' ');
    const method = parts.next() orelse return error.InvalidRequest;
    const path = parts.next() orelse return error.InvalidRequest;
    const version = parts.next() orelse return error.InvalidRequest;
    if (parts.next() != null or
        !isHeaderName(method) or
        !isRequestTarget(path))
    {
        return error.InvalidRequest;
    }
    if (!std.mem.eql(u8, version, "HTTP/1.1") and
        !std.mem.eql(u8, version, "HTTP/1.0"))
    {
        return error.InvalidRequest;
    }

    const headers_start = if (line_end == header_end)
        header_end
    else
        line_end + 2;
    const headers = bytes[headers_start..header_end];

    // Validate the complete header syntax before interpreting framing fields.
    // This guarantees malformed controls cannot be masked by an earlier 413/501.
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse
            return error.InvalidRequest;
        const name = line[0..colon];
        if (!isHeaderName(name)) return error.InvalidRequest;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!isHeaderValue(value)) return error.InvalidRequest;
    }

    var content_length: ?usize = null;
    lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse unreachable;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (content_length != null or value.len == 0) {
                return error.InvalidRequest;
            }
            content_length = try parseContentLength(value);
            if (content_length.? > max_body_bytes) return error.PayloadTooLarge;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return error.UnsupportedTransferEncoding;
        }
    }
    if (std.mem.eql(u8, method, "PUT") and content_length == null) {
        return error.LengthRequired;
    }

    const body_length = content_length orelse 0;
    const body_offset = header_end + 4;
    const total_length = std.math.add(usize, body_offset, body_length) catch
        return error.PayloadTooLarge;
    if (total_length > max_request_bytes) return error.PayloadTooLarge;
    if (bytes.len < total_length) return .incomplete;
    if (bytes.len > total_length) return error.InvalidRequest;
    return .{ .complete = .{
        .method = method,
        .path = path,
        .body = bytes[body_offset..total_length],
    } };
}

fn waitForSocket(
    fd: std.posix.fd_t,
    events: i16,
    deadline_ms: i64,
) !void {
    while (true) {
        const remaining = deadline_ms - compat.monotonicMilliTimestamp();
        if (remaining <= 0) return error.RequestTimeout;
        const timeout_ms: i32 = @intCast(@min(
            remaining,
            @as(i64, std.math.maxInt(i32)),
        ));
        var descriptors = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = events,
            .revents = 0,
        }};
        const ready = std.posix.poll(&descriptors, timeout_ms) catch
            return error.PollFailed;
        if (ready == 0) return error.RequestTimeout;
        const result = descriptors[0].revents;
        if (result & std.posix.POLL.NVAL != 0) return error.InvalidSocket;
        if (result & std.posix.POLL.ERR != 0) return error.SocketFailure;
        if (result & events != 0 or result & std.posix.POLL.HUP != 0) return;
    }
}

fn socketRead(fd: std.posix.fd_t, buffer: []u8) !usize {
    while (true) {
        const result = std.c.recv(fd, buffer.ptr, buffer.len, 0);
        if (result >= 0) return @intCast(result);
        switch (std.c.errno(result)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => return error.InputOutput,
        }
    }
}

fn socketWrite(fd: std.posix.fd_t, bytes: []const u8) !usize {
    const flags: u32 = if (comptime @hasDecl(std.posix.MSG, "NOSIGNAL"))
        std.posix.MSG.NOSIGNAL
    else
        0;
    while (true) {
        const result = std.c.send(fd, bytes.ptr, bytes.len, flags);
        if (result >= 0) return @intCast(result);
        switch (std.c.errno(result)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNRESET => return error.ConnectionResetByPeer,
            .PIPE => return error.BrokenPipe,
            else => return error.InputOutput,
        }
    }
}

fn writeAllWithDeadline(fd: std.posix.fd_t, bytes: []const u8) !void {
    const deadline_ms = compat.monotonicMilliTimestamp() + response_timeout_ms;
    var offset: usize = 0;
    while (offset < bytes.len) {
        try waitForSocket(fd, std.posix.POLL.OUT, deadline_ms);
        const written = socketWrite(fd, bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (written == 0) return error.BrokenPipe;
        offset += written;
    }
}

/// REST API 服务器
pub const ApiServer = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    engine: *Engine,
    manager: *OutboundManager,
    port: u16,
    active_connections: std.atomic.Value(u32) = .init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const Config,
        engine: *Engine,
        manager: *OutboundManager,
        port: u16,
    ) ApiServer {
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
            const conn = server.accept() catch |err| switch (err) {
                error.WouldBlock, error.ConnectionAborted => continue,
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                => {
                    compat.sleepNs(50 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            socket_options.configureConnectedStream(conn.stream) catch |err| {
                std.debug.print("API accepted socket setup error: {}\n", .{err});
                conn.stream.close();
                continue;
            };
            compat.setNonBlock(conn.stream.handle) catch |err| {
                std.debug.print("API nonblocking setup error: {}\n", .{err});
                conn.stream.close();
                continue;
            };
            if (!self.acquireConnectionSlot()) {
                conn.stream.close();
                continue;
            }
            const thread = std.Thread.spawn(
                .{ .stack_size = connection_stack_bytes },
                connectionThread,
                .{ self, conn },
            ) catch |err| {
                self.releaseConnectionSlot();
                conn.stream.close();
                std.debug.print("API connection spawn error: {}\n", .{err});
                continue;
            };
            thread.detach();
        }
    }

    fn acquireConnectionSlot(self: *ApiServer) bool {
        const previous = self.active_connections.fetchAdd(1, .monotonic);
        if (previous < max_connections) return true;
        const after = self.active_connections.fetchSub(1, .monotonic);
        std.debug.assert(after > 0);
        return false;
    }

    fn releaseConnectionSlot(self: *ApiServer) void {
        const previous = self.active_connections.fetchSub(1, .monotonic);
        std.debug.assert(previous > 0);
    }

    fn connectionThread(self: *ApiServer, conn: net.Server.Connection) void {
        defer self.releaseConnectionSlot();
        self.handleConnection(conn) catch |err| {
            std.debug.print("API connection error: {}\n", .{err});
        };
    }

    fn handleConnection(self: *ApiServer, conn: net.Server.Connection) !void {
        defer conn.stream.close();

        var owned_request = self.readRequest(conn.stream.handle) catch |err| {
            self.sendRequestError(conn, err) catch {};
            return;
        };
        defer owned_request.deinit(self.allocator);
        const request = owned_request.request;
        const method = request.method;
        const path = request.path;
        const body = request.body;

        std.debug.print("[API] {s} {s}\n", .{ method, path });

        // 路由
        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, path, "/")) {
                try self.sendJson(
                    conn,
                    comptime std.fmt.comptimePrint(
                        "{{\"version\":\"{s}\",\"hello\":\"zc\"}}",
                        .{build_options.version},
                    ),
                );
            } else if (std.mem.eql(u8, path, "/proxies")) {
                try self.handleGetProxies(conn);
            } else if (std.mem.eql(u8, path, "/rules")) {
                try self.handleGetRules(conn);
            } else if (std.mem.eql(u8, path, "/status")) {
                try self.handleGetStatus(conn);
            } else if (std.mem.eql(u8, path, "/version")) {
                try self.sendJson(
                    conn,
                    comptime std.fmt.comptimePrint(
                        "{{\"version\":\"{s}\"}}",
                        .{build_options.version},
                    ),
                );
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

    fn readRequest(
        self: *ApiServer,
        fd: std.posix.fd_t,
    ) !OwnedRequest {
        const storage = try self.allocator.alloc(u8, max_request_bytes);
        errdefer self.allocator.free(storage);
        const deadline_ms = compat.monotonicMilliTimestamp() + request_timeout_ms;
        var used: usize = 0;

        while (true) {
            switch (try inspectRequest(storage[0..used])) {
                .incomplete => {},
                .complete => |request| return .{
                    .storage = storage,
                    .request = request,
                },
            }
            if (used == storage.len) return error.PayloadTooLarge;
            try waitForSocket(fd, std.posix.POLL.IN, deadline_ms);
            const count = socketRead(fd, storage[used..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (count == 0) {
                if (used == 0) return error.EndOfStream;
                return error.UnexpectedEndOfStream;
            }
            used += count;
        }
    }

    fn sendRequestError(
        self: *ApiServer,
        conn: net.Server.Connection,
        err: anyerror,
    ) !void {
        switch (err) {
            error.EndOfStream => {},
            error.RequestTimeout => try self.sendError(conn, 408, "Request Timeout"),
            error.HeaderTooLarge, error.PayloadTooLarge => try self.sendError(conn, 413, "Payload Too Large"),
            error.LengthRequired => try self.sendError(conn, 411, "Length Required"),
            error.UnsupportedTransferEncoding => try self.sendError(conn, 501, "Transfer Encoding Unsupported"),
            error.OutOfMemory => return error.OutOfMemory,
            else => try self.sendError(conn, 400, "Bad Request"),
        }
    }

    fn handleGetProxies(self: *ApiServer, conn: net.Server.Connection) !void {
        const json = buildProxiesJson(self.allocator, self.config) catch |err| switch (err) {
            error.ResponseTooLarge => {
                try self.sendError(conn, 500, "Response Too Large");
                return;
            },
            else => return err,
        };
        defer self.allocator.free(json);
        try self.sendJsonRaw(conn, json);
    }

    pub fn buildProxiesJson(
        allocator: std.mem.Allocator,
        cfg: *const Config,
    ) ![]u8 {
        const ProxyView = struct {
            name: []const u8,
            type: []const u8,
            server: []const u8,
            port: u16,
        };
        const Response = struct { proxies: []const ProxyView };

        const views = try allocator.alloc(ProxyView, cfg.proxies.items.len);
        defer allocator.free(views);
        for (cfg.proxies.items, views) |proxy, *view| {
            view.* = .{
                .name = proxy.name,
                .type = proxyTypeName(proxy.proxy_type),
                .server = proxy.server,
                .port = proxy.port,
            };
        }
        return stringifyOwned(allocator, Response{ .proxies = views });
    }

    fn handleGetStatus(self: *ApiServer, conn: net.Server.Connection) !void {
        const json = ApiServer.buildStatusJson(
            self.allocator,
            self.manager,
            self.config,
        ) catch |err| switch (err) {
            error.ResponseTooLarge => {
                try self.sendError(conn, 500, "Response Too Large");
                return;
            },
            else => return err,
        };
        defer self.allocator.free(json);
        try self.sendJsonRaw(conn, json);
    }

    /// 返回 daemon 实际运行时状态 JSON：{config_key, selected_proxies:[...]}。
    /// status 经 IPC 读此端点而非 meta.json——后者在 config_key 与 active_config
    /// 错位（配置切换未重启）时读到空，显示 default 而与实际不符。纯函数，不起 socket。
    pub fn buildStatusJson(
        allocator: std.mem.Allocator,
        manager: *OutboundManager,
        cfg: *const Config,
    ) ![]u8 {
        const cfg_key = manager.configKey();
        const entries = try manager.snapshotSelections(allocator);
        defer runtime_selection.freeSelectionEntries(allocator, entries);
        const selections = try runtime_selection.collectSelectedProxiesFromSnapshot(
            allocator,
            cfg,
            entries,
        );
        defer runtime_selection.deinitSelectedProxies(allocator, selections);

        const Resp = struct {
            config_key: ?[]const u8,
            selected_proxies: []const runtime_selection.SelectedProxy,
        };
        return stringifyOwned(
            allocator,
            Resp{ .config_key = cfg_key, .selected_proxies = selections },
        );
    }

    fn handleGetRules(self: *ApiServer, conn: net.Server.Connection) !void {
        const json = buildRulesJson(self.allocator, self.config) catch |err| switch (err) {
            error.ResponseTooLarge => {
                try self.sendError(conn, 500, "Response Too Large");
                return;
            },
            else => return err,
        };
        defer self.allocator.free(json);
        try self.sendJsonRaw(conn, json);
    }

    pub fn buildRulesJson(
        allocator: std.mem.Allocator,
        cfg: *const Config,
    ) ![]u8 {
        const RuleView = struct {
            type: []const u8,
            payload: []const u8,
            target: []const u8,
        };
        const Response = struct { rules: []const RuleView };

        const views = try allocator.alloc(RuleView, cfg.rules.items.len);
        defer allocator.free(views);
        for (cfg.rules.items, views) |rule, *view| {
            view.* = .{
                .type = ruleTypeName(rule.rule_type),
                .payload = rule.payload,
                .target = rule.target,
            };
        }
        return stringifyOwned(allocator, Response{ .rules = views });
    }

    /// PUT /proxies/<group_name> body: {"name":"proxy_name"}
    ///
    /// body 经 std.json 解析（真实反转义 —— 节点名可含 `"`/`\`/换行等，
    /// 修复旧 extractJsonString 扫到第一个 `"` 字节截断转义名的 bug）；
    /// 组/节点先对照配置校验，未命中返回 404 而不是无条件 200（修复 CLI
    /// `data.applied` 假阳性）。
    fn handleSwitchProxy(
        self: *ApiServer,
        conn: net.Server.Connection,
        group_name: []const u8,
        body: []const u8,
    ) !void {
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
        self.manager.applyPersistedSelection(group_name, proxy_name);

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
        if (body.len > max_response_body_bytes) return error.ResponseTooLarge;
        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Connection: close\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}", .{ body.len, body });
        defer self.allocator.free(response);

        try writeAllWithDeadline(conn.stream.handle, response);
    }

    fn sendError(
        self: *ApiServer,
        conn: net.Server.Connection,
        code: u16,
        message: []const u8,
    ) !void {
        const ErrorResponse = struct { @"error": []const u8 };
        const body = try stringifyOwned(
            self.allocator,
            ErrorResponse{ .@"error" = message },
        );
        defer self.allocator.free(body);

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Connection: close\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}", .{ code, message, body.len, body });
        defer self.allocator.free(response);

        try writeAllWithDeadline(conn.stream.handle, response);
    }
};

fn stringifyOwned(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var count_buffer: [256]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    std.json.Stringify.value(
        value,
        .{ .whitespace = .minified },
        &counter.writer,
    ) catch return error.JsonEncodingFailed;
    const count = counter.fullCount();
    if (count > max_response_body_bytes) return error.ResponseTooLarge;

    const output = try allocator.alloc(u8, @intCast(count));
    errdefer allocator.free(output);
    var writer: std.Io.Writer = .fixed(output);
    std.json.Stringify.value(
        value,
        .{ .whitespace = .minified },
        &writer,
    ) catch return error.JsonEncodingFailed;
    std.debug.assert(writer.end == output.len);
    return output;
}

fn proxyTypeName(proxy_type: config_mod.ProxyType) []const u8 {
    return switch (proxy_type) {
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
}

fn ruleTypeName(rule_type: config_mod.RuleType) []const u8 {
    return switch (rule_type) {
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
}

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
pub fn validateSelection(
    cfg: *const Config,
    group_name: []const u8,
    proxy_name: []const u8,
) SelectionCheck {
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
