const std = @import("std");
const compat = @import("compat.zig");
const config = @import("config.zig");
const posix = std.posix;

fn proxyTypeString(pt: config.ProxyType) []const u8 {
    return switch (pt) {
        .direct => "DIRECT",
        .reject => "REJECT",
        .http => "HTTP",
        .socks5 => "SOCKS5",
        .ss => "SS",
        .vmess => "VMess",
        .trojan => "Trojan",
        .vless => "VLESS",
    };
}

fn groupTypeString(gt: config.ProxyGroupType) []const u8 {
    return switch (gt) {
        .select => "select",
        .url_test => "url-test",
        .fallback => "fallback",
        .load_balance => "load-balance",
        .relay => "relay",
    };
}

// ── Terminal output helpers ──

fn writeStr(s: []const u8) void {
    _ = compat.posixWrite(posix.STDERR_FILENO, s) catch {};
}

fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStr(msg);
}

/// 列出所有代理组和节点
pub fn listProxies(_: std.mem.Allocator, cfg: *const config.Config) !void {
    std.debug.print("Proxy Groups:\n", .{});
    std.debug.print("{s:-^60}\n", .{""});

    for (cfg.proxy_groups.items) |group| {
        const type_str = groupTypeString(group.group_type);
        std.debug.print("\n{s} ({s}) - {d} proxies\n", .{ group.name, type_str, group.proxies.items.len });

        for (group.proxies.items, 0..) |proxy_name, i| {
            var proxy_type: ?[]const u8 = null;
            for (cfg.proxies.items) |proxy| {
                if (std.mem.eql(u8, proxy.name, proxy_name)) {
                    proxy_type = proxyTypeString(proxy.proxy_type);
                    break;
                }
            }
            if (proxy_type == null) {
                for (cfg.proxy_groups.items) |grp| {
                    if (std.mem.eql(u8, grp.name, proxy_name)) {
                        proxy_type = groupTypeString(grp.group_type);
                        break;
                    }
                }
            }
            if (proxy_type) |pt| {
                std.debug.print("  {d}. {s:20} [{s}]\n", .{ i + 1, proxy_name, pt });
            } else {
                std.debug.print("  {d}. {s}\n", .{ i + 1, proxy_name });
            }
        }
    }

    if (cfg.proxy_groups.items.len == 0) {
        std.debug.print("\nAll Proxies:\n", .{});
        std.debug.print("{s:-^60}\n", .{""});
        for (cfg.proxies.items, 0..) |proxy, i| {
            const proxy_type = proxyTypeString(proxy.proxy_type);
            if (proxy.port > 0) {
                std.debug.print("{d}. {s:20} [{s}] {s}:{d}\n", .{ i + 1, proxy.name, proxy_type, proxy.server, proxy.port });
            } else {
                std.debug.print("{d}. {s:20} [{s}]\n", .{ i + 1, proxy.name, proxy_type });
            }
        }
    }
    std.debug.print("\n", .{});
}

/// 以 JSON 格式列出代理组和节点
pub fn listProxiesJson(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"ok\":true,\"data\":{\"groups\":[");

    for (cfg.proxy_groups.items, 0..) |group, gi| {
        if (gi > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "{\"name\":\"");
        try out.appendSlice(allocator, group.name);
        try out.appendSlice(allocator, "\",\"type\":\"");
        try out.appendSlice(allocator, groupTypeString(group.group_type));
        try out.appendSlice(allocator, "\",\"proxies\":[");

        for (group.proxies.items, 0..) |proxy_name, pi| {
            if (pi > 0) try out.appendSlice(allocator, ",");
            var ptype: []const u8 = "unknown";
            for (cfg.proxies.items) |proxy| {
                if (std.mem.eql(u8, proxy.name, proxy_name)) {
                    ptype = proxyTypeString(proxy.proxy_type);
                    break;
                }
            }
            if (std.mem.eql(u8, ptype, "unknown")) {
                for (cfg.proxy_groups.items) |grp| {
                    if (std.mem.eql(u8, grp.name, proxy_name)) {
                        ptype = groupTypeString(grp.group_type);
                        break;
                    }
                }
            }
            const final_type = if (std.mem.eql(u8, ptype, "unknown")) proxy_name else ptype;
            try out.appendSlice(allocator, "{\"name\":\"");
            try out.appendSlice(allocator, proxy_name);
            try out.appendSlice(allocator, "\",\"type\":\"");
            try out.appendSlice(allocator, final_type);
            try out.appendSlice(allocator, "\"}");
        }
        try out.appendSlice(allocator, "]}");
    }

    try out.appendSlice(allocator, "],\"stats\":{\"group_count\":");
    try out.print(allocator, "{d}", .{cfg.proxy_groups.items.len});
    try out.appendSlice(allocator, ",\"proxy_count\":");
    try out.print(allocator, "{d}", .{cfg.proxies.items.len});
    try out.appendSlice(allocator, "}}}\n");
    std.debug.print("{s}", .{out.items});
}

/// JSON 格式选择代理
pub fn selectProxyJson(allocator: std.mem.Allocator, cfg: *config.Config, group_name: ?[]const u8, proxy_name: ?[]const u8) !void {
    var target_group: ?*config.ProxyGroup = null;
    if (group_name) |gn| {
        for (cfg.proxy_groups.items) |*group| {
            if (std.mem.eql(u8, group.name, gn)) { target_group = group; break; }
        }
        if (target_group == null) return error.GroupNotFound;
    } else {
        for (cfg.proxy_groups.items) |*group| {
            if (group.group_type == .select) { target_group = group; break; }
        }
        if (target_group == null) return error.NoSelectGroup;
    }
    const group = target_group.?;

    if (proxy_name) |pn| {
        var found = false;
        for (group.proxies.items) |p| {
            if (std.mem.eql(u8, p, pn)) { found = true; break; }
        }
        if (!found) return error.ProxyNotFound;
        std.debug.print("{{\"ok\":true,\"data\":{{\"action\":\"proxy_select\",\"group\":\"{s}\",\"proxy\":\"{s}\",\"state\":\"selected\"}}}}\n", .{ group.name, pn });
        return;
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":true,\"data\":{\"action\":\"proxy_select\",\"group\":\"");
    try out.appendSlice(allocator, group.name);
    try out.appendSlice(allocator, "\",\"choices\":[");
    for (group.proxies.items, 0..) |name, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, "]}}\n");
    std.debug.print("{s}", .{out.items});
}

/// 交互式选择代理节点
pub fn selectProxy(allocator: std.mem.Allocator, cfg: *config.Config, group_name: ?[]const u8, proxy_name: ?[]const u8) !void {
    // 直接指定了 -g 和 -p，跳过交互
    if (group_name != null and proxy_name != null) {
        return directSelect(allocator, cfg, group_name.?, proxy_name.?);
    }

    // 收集 select 类型的代理组
    var select_groups = std.ArrayList(usize).empty;
    defer select_groups.deinit(allocator);
    for (cfg.proxy_groups.items, 0..) |group, i| {
        if (group.group_type == .select) {
            try select_groups.append(allocator, i);
        }
    }
    if (select_groups.items.len == 0) {
        std.debug.print("No select-type proxy group found\n", .{});
        return error.NoSelectGroup;
    }

    // 确定目标组
    var group_idx: usize = 0;
    if (group_name) |gn| {
        var found = false;
        for (select_groups.items, 0..) |gi, si| {
            if (std.mem.eql(u8, cfg.proxy_groups.items[gi].name, gn)) {
                group_idx = si;
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("Proxy group not found: {s}\n", .{gn});
            return error.GroupNotFound;
        }
    } else if (select_groups.items.len > 1) {
        group_idx = try interactiveSelectGroup(cfg, select_groups.items) orelse return;
    }

    const real_group_idx = select_groups.items[group_idx];
    const group = &cfg.proxy_groups.items[real_group_idx];

    // 交互选择节点
    const selected = try interactiveSelectProxy(cfg, group) orelse return;
    const selected_name = group.proxies.items[selected];

    writeFmt("\x1b[32m✓\x1b[0m Selected \x1b[1m{s}\x1b[0m in group \x1b[1m{s}\x1b[0m\n", .{ selected_name, group.name });

    notifyDaemon(allocator, cfg, group.name, selected_name);
}

/// 直接选择（非交互）
fn directSelect(allocator: std.mem.Allocator, cfg: *config.Config, grp_name: []const u8, prx_name: []const u8) !void {
    var group: ?*config.ProxyGroup = null;
    for (cfg.proxy_groups.items) |*g| {
        if (std.mem.eql(u8, g.name, grp_name)) { group = g; break; }
    }
    if (group == null) {
        std.debug.print("Proxy group not found: {s}\n", .{grp_name});
        return error.GroupNotFound;
    }
    var found = false;
    for (group.?.proxies.items) |p| {
        if (std.mem.eql(u8, p, prx_name)) { found = true; break; }
    }
    if (!found) {
        std.debug.print("Proxy '{s}' not found in group '{s}'\n", .{ prx_name, grp_name });
        return error.ProxyNotFound;
    }
    writeFmt("\x1b[32m✓\x1b[0m Selected \x1b[1m{s}\x1b[0m in group \x1b[1m{s}\x1b[0m\n", .{ prx_name, grp_name });
    notifyDaemon(allocator, cfg, grp_name, prx_name);
}

/// 交互式选择代理组
fn interactiveSelectGroup(cfg: *config.Config, group_indices: []const usize) !?usize {
    var original = enableRawMode() catch |err| switch (err) {
        error.NotATerminal => {
            // 非 TTY 环境，使用非交互模式显示列表
            std.debug.print("Select proxy group (not a terminal, using first group):\n", .{});
            for (group_indices, 0..) |gi, i| {
                const g = &cfg.proxy_groups.items[gi];
                std.debug.print("  {d}. {s} ({d} proxies)\n", .{ i + 1, g.name, g.proxies.items.len });
            }
            return 0;
        },
        else => return err,
    };
    defer disableRawMode(&original);

    var cursor: usize = 0;
    writeStr("\x1b[?25l"); // 隐藏光标

    writeFmt("\x1b[1mSelect proxy group:\x1b[0m  \x1b[2m↑↓ navigate  ↵ select  q quit\x1b[0m\n\n", .{});
    const header_lines: usize = 2;

    drawGroupList(cfg, group_indices, cursor);

    while (true) {
        const key = readKey() catch break;
        switch (key) {
            .up => if (cursor > 0) { cursor -= 1; },
            .down => if (cursor + 1 < group_indices.len) { cursor += 1; },
            .enter => {
                clearLines(group_indices.len + header_lines);
                writeStr("\x1b[?25h");
                return cursor;
            },
            .quit => {
                clearLines(group_indices.len + header_lines);
                writeStr("\x1b[?25h");
                return null;
            },
            else => {},
        }
        moveCursorUp(group_indices.len);
        drawGroupList(cfg, group_indices, cursor);
    }

    writeStr("\x1b[?25h");
    return null;
}

/// 交互式选择代理节点
fn interactiveSelectProxy(cfg: *config.Config, group: *const config.ProxyGroup) !?usize {
    if (group.proxies.items.len == 0) return null;

    var original = enableRawMode() catch |err| switch (err) {
        error.NotATerminal => {
            std.debug.print("Proxies in {s} (not a terminal, using first proxy):\n", .{group.name});
            for (group.proxies.items, 0..) |pn, i| {
                std.debug.print("  {d}. {s}\n", .{ i + 1, pn });
            }
            return 0;
        },
        else => return err,
    };
    defer disableRawMode(&original);

    var cursor: usize = 0;
    var scroll_offset: usize = 0;
    const max_visible: usize = 20;
    const visible = @min(max_visible, group.proxies.items.len);

    writeStr("\x1b[?25l");

    writeFmt("\x1b[1m{s}\x1b[0m ({d} proxies)  \x1b[2m↑↓ navigate  ↵ select  q quit\x1b[0m\n\n", .{ group.name, group.proxies.items.len });
    const header_lines: usize = 2;

    drawProxyList(cfg, group, cursor, scroll_offset, visible);

    while (true) {
        const key = readKey() catch break;
        switch (key) {
            .up => if (cursor > 0) {
                cursor -= 1;
                if (cursor < scroll_offset) scroll_offset = cursor;
            },
            .down => if (cursor + 1 < group.proxies.items.len) {
                cursor += 1;
                if (cursor >= scroll_offset + visible) scroll_offset = cursor - visible + 1;
            },
            .enter => {
                clearLines(visible + header_lines);
                writeStr("\x1b[?25h");
                return cursor;
            },
            .quit => {
                clearLines(visible + header_lines);
                writeStr("\x1b[?25h");
                return null;
            },
            else => {},
        }
        moveCursorUp(visible);
        drawProxyList(cfg, group, cursor, scroll_offset, visible);
    }

    writeStr("\x1b[?25h");
    return null;
}

fn drawGroupList(cfg: *config.Config, group_indices: []const usize, cursor: usize) void {
    for (group_indices, 0..) |gi, i| {
        const group = &cfg.proxy_groups.items[gi];
        if (i == cursor) {
            writeFmt("\x1b[2K \x1b[36m❯\x1b[0m \x1b[1;36m{s}\x1b[0m ({d} proxies)\n", .{ group.name, group.proxies.items.len });
        } else {
            writeFmt("\x1b[2K   {s} ({d} proxies)\n", .{ group.name, group.proxies.items.len });
        }
    }
}

fn drawProxyList(cfg: *const config.Config, group: *const config.ProxyGroup, cursor: usize, scroll_offset: usize, visible: usize) void {
    const end = @min(scroll_offset + visible, group.proxies.items.len);
    for (scroll_offset..end) |i| {
        const proxy_name = group.proxies.items[i];

        var ptype: []const u8 = "";
        for (cfg.proxies.items) |proxy| {
            if (std.mem.eql(u8, proxy.name, proxy_name)) {
                ptype = proxyTypeString(proxy.proxy_type);
                break;
            }
        }
        if (ptype.len == 0) {
            for (cfg.proxy_groups.items) |grp| {
                if (std.mem.eql(u8, grp.name, proxy_name)) {
                    ptype = groupTypeString(grp.group_type);
                    break;
                }
            }
        }

        if (i == cursor) {
            if (ptype.len > 0) {
                writeFmt("\x1b[2K \x1b[36m❯\x1b[0m \x1b[1;36m{s}\x1b[0m \x1b[2m[{s}]\x1b[0m\n", .{ proxy_name, ptype });
            } else {
                writeFmt("\x1b[2K \x1b[36m❯\x1b[0m \x1b[1;36m{s}\x1b[0m\n", .{proxy_name});
            }
        } else {
            if (ptype.len > 0) {
                writeFmt("\x1b[2K   {s} \x1b[2m[{s}]\x1b[0m\n", .{ proxy_name, ptype });
            } else {
                writeFmt("\x1b[2K   {s}\n", .{proxy_name});
            }
        }
    }
}

/// 通知运行中的 daemon 更新代理选择
fn notifyDaemon(allocator: std.mem.Allocator, cfg: *config.Config, group_name: []const u8, proxy_name: []const u8) void {
    const ec = cfg.external_controller orelse {
        writeStr("\x1b[2m(no external-controller, restart daemon to apply)\x1b[0m\n");
        return;
    };

    const colon = std.mem.lastIndexOf(u8, ec, ":") orelse return;
    const port = std.fmt.parseInt(u16, ec[colon + 1 ..], 10) catch return;
    const host = ec[0..colon];

    const body = std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{proxy_name}) catch return;
    defer allocator.free(body);
    const req = std.fmt.allocPrint(allocator, "PUT /proxies/{s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ group_name, ec, body.len, body }) catch return;
    defer allocator.free(req);

    const stream = compat.net.tcpConnectToHost(allocator, host, port) catch {
        writeFmt("\x1b[2m(daemon not reachable at {s}, restart to apply)\x1b[0m\n", .{ec});
        return;
    };
    defer stream.close();

    stream.writeAll(req) catch return;

    var buf: [512]u8 = undefined;
    const n = stream.read(&buf) catch return;
    if (n > 0 and std.mem.indexOf(u8, buf[0..n], "200") != null) {
        writeStr("\x1b[2m(daemon updated)\x1b[0m\n");
    }
}

// ── Terminal raw mode helpers ──

const Key = enum { up, down, enter, quit, other };

fn enableRawMode() !posix.termios {
    if (std.c.isatty(posix.STDIN_FILENO) == 0) return error.NotATerminal;
    var raw = try posix.tcgetattr(posix.STDIN_FILENO);
    const original = raw;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);
    return original;
}

fn disableRawMode(original: *posix.termios) void {
    posix.tcsetattr(posix.STDIN_FILENO, .NOW, original.*) catch {};
}

fn readKey() !Key {
    var buf: [8]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &buf) catch return .other;
    if (n == 0) return .other;

    if (n == 1) {
        return switch (buf[0]) {
            'q' => .quit,
            0x1b => .quit,
            '\r', '\n' => .enter,
            'k' => .up,
            'j' => .down,
            else => .other,
        };
    }

    if (n >= 3 and buf[0] == 0x1b and buf[1] == '[') {
        return switch (buf[2]) {
            'A' => .up,
            'B' => .down,
            else => .other,
        };
    }

    return .other;
}

fn moveCursorUp(lines: usize) void {
    if (lines > 0) writeFmt("\x1b[{d}A", .{lines});
}

fn clearLines(lines: usize) void {
    if (lines > 0) writeFmt("\x1b[{d}A", .{lines});
    for (0..lines) |_| writeStr("\x1b[2K\n");
    if (lines > 0) writeFmt("\x1b[{d}A", .{lines});
}
