const std = @import("std");
const compat = @import("compat.zig");
const config = @import("config.zig");
const cli_output = @import("cli/output.zig");
const runtime_selection = @import("runtime_selection.zig");
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
        .anytls => "AnyTLS",
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

/// 在 cfg 里查组成员（节点或嵌套组）的类型标签。未知成员返回 null —— 修复
/// 旧 JSON 路径把成员名本身当 type 回退的 bug（基线缺口：proxy_cli.zig:122）。
fn lookupMemberType(cfg: *const config.Config, member_name: []const u8) ?[]const u8 {
    // 内建出口（配置校验允许的两个特殊成员）。
    if (std.mem.eql(u8, member_name, "DIRECT")) return "DIRECT";
    if (std.mem.eql(u8, member_name, "REJECT")) return "REJECT";
    for (cfg.proxies.items) |proxy| {
        if (std.mem.eql(u8, proxy.name, member_name)) return proxyTypeString(proxy.proxy_type);
    }
    for (cfg.proxy_groups.items) |grp| {
        if (std.mem.eql(u8, grp.name, member_name)) return groupTypeString(grp.group_type);
    }
    return null;
}

/// 当前选择（runtime_selection 计算结果）里某个组的选中节点。
pub fn currentSelection(
    selections: []const runtime_selection.SelectedProxy,
    group_name: []const u8,
) ?[]const u8 {
    for (selections) |selection| {
        if (std.mem.eql(u8, selection.group_name, group_name)) return selection.proxy_name;
    }
    return null;
}

// ── Terminal output helpers（交互选择器的 chrome，固定走 stderr）──

fn writeStr(s: []const u8) void {
    _ = compat.posixWrite(posix.STDERR_FILENO, s) catch {};
}

fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStr(msg);
}

/// 文本模式列出所有代理组和节点（主输出 stdout，当前选择带标记）。
pub fn listProxies(
    cfg: *const config.Config,
    selections: []const runtime_selection.SelectedProxy,
    out: *cli_output.Output,
) !void {
    try out.print("Proxy Groups:\n", .{});
    try out.print("{s:-^60}\n", .{""});

    for (cfg.proxy_groups.items) |group| {
        const type_str = groupTypeString(group.group_type);
        try out.print("\n{s}{s}{s} ({s}) - {d} proxies\n", .{
            out.style(.bold), group.name, out.style(.reset), type_str, group.proxies.items.len,
        });

        const current = currentSelection(selections, group.name);
        for (group.proxies.items, 0..) |member, i| {
            const member_type = lookupMemberType(cfg, member);
            const is_current = if (current) |c| std.mem.eql(u8, c, member) else false;
            if (is_current) {
                if (member_type) |pt| {
                    try out.print("  {s}* {d}. {s} [{s}] (current){s}\n", .{ out.style(.green), i + 1, member, pt, out.style(.reset) });
                } else {
                    try out.print("  {s}* {d}. {s} (current){s}\n", .{ out.style(.green), i + 1, member, out.style(.reset) });
                }
            } else {
                if (member_type) |pt| {
                    try out.print("    {d}. {s} [{s}]\n", .{ i + 1, member, pt });
                } else {
                    try out.print("    {d}. {s}\n", .{ i + 1, member });
                }
            }
        }
    }

    if (cfg.proxy_groups.items.len == 0) {
        try out.print("\nAll Proxies:\n", .{});
        try out.print("{s:-^60}\n", .{""});
        for (cfg.proxies.items, 0..) |proxy, i| {
            const proxy_type = proxyTypeString(proxy.proxy_type);
            if (proxy.port > 0) {
                try out.print("{d}. {s} [{s}] {s}:{d}\n", .{ i + 1, proxy.name, proxy_type, proxy.server, proxy.port });
            } else {
                try out.print("{d}. {s} [{s}]\n", .{ i + 1, proxy.name, proxy_type });
            }
        }
    }
    try out.print("\n", .{});
    try out.flush();
}

/// JSON 列表：envelope 经 Output/std.json 序列化（真实转义）输出到 stdout。
pub fn listProxiesJson(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    selections: []const runtime_selection.SelectedProxy,
    out: *cli_output.Output,
) !void {
    const MemberJson = struct { name: []const u8, type: []const u8 };
    const GroupJson = struct {
        name: []const u8,
        type: []const u8,
        now: ?[]const u8,
        proxies: []const MemberJson,
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const group_list = try arena.alloc(GroupJson, cfg.proxy_groups.items.len);
    for (cfg.proxy_groups.items, group_list) |group, *group_json| {
        const members = try arena.alloc(MemberJson, group.proxies.items.len);
        for (group.proxies.items, members) |member, *member_json| {
            member_json.* = .{
                .name = member,
                .type = lookupMemberType(cfg, member) orelse "unknown",
            };
        }
        group_json.* = .{
            .name = group.name,
            .type = groupTypeString(group.group_type),
            .now = currentSelection(selections, group.name),
            .proxies = members,
        };
    }

    try out.success(.{
        .groups = group_list,
        .stats = .{
            .group_count = cfg.proxy_groups.items.len,
            .proxy_count = cfg.proxies.items.len,
        },
    });
}

/// 统一两种模式的 `-g` 匹配语义：只在 select 类型组里解析；命中非 select
/// 组报 GroupNotSelect（清晰区别于 GroupNotFound）。`-g` 缺省取第一个
/// select 组。
pub fn resolveSelectGroup(cfg: *config.Config, group_name: ?[]const u8) !*config.ProxyGroup {
    if (group_name) |gn| {
        for (cfg.proxy_groups.items) |*group| {
            if (std.mem.eql(u8, group.name, gn)) {
                if (group.group_type != .select) return error.GroupNotSelect;
                return group;
            }
        }
        return error.GroupNotFound;
    }
    for (cfg.proxy_groups.items) |*group| {
        if (group.group_type == .select) return group;
    }
    return error.NoSelectGroup;
}

/// 校验并应用选择：文本模式打印确认行（stdout），随后通知运行中的 daemon。
/// 返回 applied —— 是否成功通知了运行中的 daemon（envelope data.applied）。
pub fn applySelection(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    group: *const config.ProxyGroup,
    proxy_name: []const u8,
    out: *cli_output.Output,
) !bool {
    var found = false;
    for (group.proxies.items) |p| {
        if (std.mem.eql(u8, p, proxy_name)) {
            found = true;
            break;
        }
    }
    if (!found) return error.ProxyNotFound;

    if (out.mode == .text) {
        try out.print("{s}✓{s} Selected {s}{s}{s} in group {s}{s}{s}\n", .{
            out.style(.green), out.style(.reset),
            out.style(.bold),  proxy_name,
            out.style(.reset), out.style(.bold),
            group.name,        out.style(.reset),
        });
        try out.flush();
    }

    return notifyDaemon(allocator, cfg, group.name, proxy_name, out);
}

pub const InteractiveSelection = struct {
    group: *config.ProxyGroup,
    proxy: []const u8,
};

/// 交互式选择（仅 TTY）。非 TTY 一律 error.NotInteractive —— 绝不静默
/// 选第一个节点。用户按 q/Esc 取消时返回 null。
pub fn selectProxyInteractive(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    group_name: ?[]const u8,
    selections: []const runtime_selection.SelectedProxy,
    out: *cli_output.Output,
) !?InteractiveSelection {
    var select_groups = std.ArrayList(usize).empty;
    defer select_groups.deinit(allocator);
    for (cfg.proxy_groups.items, 0..) |group, i| {
        if (group.group_type == .select) {
            try select_groups.append(allocator, i);
        }
    }
    if (select_groups.items.len == 0) return error.NoSelectGroup;

    var group: *config.ProxyGroup = undefined;
    if (group_name != null) {
        group = try resolveSelectGroup(cfg, group_name);
    } else if (select_groups.items.len > 1) {
        const picked = (try interactiveSelectGroup(cfg, select_groups.items, out)) orelse return null;
        group = &cfg.proxy_groups.items[select_groups.items[picked]];
    } else {
        group = &cfg.proxy_groups.items[select_groups.items[0]];
    }

    const current = currentSelection(selections, group.name);
    const selected = (try interactiveSelectProxy(cfg, group, current, out)) orelse return null;
    return .{ .group = group, .proxy = group.proxies.items[selected] };
}

/// 交互式选择代理组
fn interactiveSelectGroup(
    cfg: *config.Config,
    group_indices: []const usize,
    out: *cli_output.Output,
) !?usize {
    var original = enableRawMode() catch |err| switch (err) {
        error.NotATerminal => return error.NotInteractive,
        else => return err,
    };
    defer disableRawMode(&original);

    var cursor: usize = 0;
    writeStr("\x1b[?25l"); // 隐藏光标

    writeFmt("{s}Select proxy group:{s}  {s}↑↓ navigate  ↵ select  q quit{s}\n\n", .{
        out.style(.bold), out.style(.reset), out.style(.dim), out.style(.reset),
    });
    const header_lines: usize = 2;

    drawGroupList(cfg, group_indices, cursor, out);

    while (true) {
        const key = readKey() catch break;
        switch (key) {
            .up => if (cursor > 0) {
                cursor -= 1;
            },
            .down => if (cursor + 1 < group_indices.len) {
                cursor += 1;
            },
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
        drawGroupList(cfg, group_indices, cursor, out);
    }

    writeStr("\x1b[?25h");
    return null;
}

/// 交互式选择代理节点（当前选择高亮，光标从当前选择起步）
fn interactiveSelectProxy(
    cfg: *config.Config,
    group: *const config.ProxyGroup,
    current: ?[]const u8,
    out: *cli_output.Output,
) !?usize {
    if (group.proxies.items.len == 0) return null;

    var original = enableRawMode() catch |err| switch (err) {
        error.NotATerminal => return error.NotInteractive,
        else => return err,
    };
    defer disableRawMode(&original);

    var current_idx: ?usize = null;
    if (current) |c| {
        for (group.proxies.items, 0..) |member, i| {
            if (std.mem.eql(u8, member, c)) {
                current_idx = i;
                break;
            }
        }
    }

    var cursor: usize = current_idx orelse 0;
    var scroll_offset: usize = 0;
    const max_visible: usize = 20;
    const visible = @min(max_visible, group.proxies.items.len);
    if (cursor >= visible) {
        scroll_offset = @min(cursor - visible + 1, group.proxies.items.len - visible);
    }

    writeStr("\x1b[?25l");

    writeFmt("{s}{s}{s} ({d} proxies)  {s}↑↓ navigate  ↵ select  q quit{s}\n\n", .{
        out.style(.bold),        group.name,      out.style(.reset),
        group.proxies.items.len, out.style(.dim), out.style(.reset),
    });
    const header_lines: usize = 2;

    drawProxyList(cfg, group, cursor, scroll_offset, visible, current_idx, out);

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
        drawProxyList(cfg, group, cursor, scroll_offset, visible, current_idx, out);
    }

    writeStr("\x1b[?25h");
    return null;
}

fn drawGroupList(
    cfg: *config.Config,
    group_indices: []const usize,
    cursor: usize,
    out: *cli_output.Output,
) void {
    for (group_indices, 0..) |gi, i| {
        const group = &cfg.proxy_groups.items[gi];
        if (i == cursor) {
            writeFmt("\x1b[2K {s}❯{s} {s}{s}{s}{s} ({d} proxies)\n", .{
                out.style(.cyan), out.style(.reset), out.style(.bold),        out.style(.cyan),
                group.name,       out.style(.reset), group.proxies.items.len,
            });
        } else {
            writeFmt("\x1b[2K   {s} ({d} proxies)\n", .{ group.name, group.proxies.items.len });
        }
    }
}

fn drawProxyList(
    cfg: *const config.Config,
    group: *const config.ProxyGroup,
    cursor: usize,
    scroll_offset: usize,
    visible: usize,
    current_idx: ?usize,
    out: *cli_output.Output,
) void {
    const end = @min(scroll_offset + visible, group.proxies.items.len);
    for (scroll_offset..end) |i| {
        const proxy_name = group.proxies.items[i];
        const ptype = lookupMemberType(cfg, proxy_name) orelse "";
        const is_current = current_idx != null and current_idx.? == i;
        const current_mark: []const u8 = if (is_current) " (current)" else "";

        if (i == cursor) {
            if (ptype.len > 0) {
                writeFmt("\x1b[2K {s}❯{s} {s}{s}{s}{s} {s}[{s}]{s}{s}\n", .{
                    out.style(.cyan),  out.style(.reset), out.style(.bold), out.style(.cyan),
                    proxy_name,        out.style(.reset), out.style(.dim),  ptype,
                    out.style(.reset), current_mark,
                });
            } else {
                writeFmt("\x1b[2K {s}❯{s} {s}{s}{s}{s}{s}\n", .{
                    out.style(.cyan), out.style(.reset), out.style(.bold), out.style(.cyan),
                    proxy_name,       out.style(.reset), current_mark,
                });
            }
        } else {
            if (ptype.len > 0) {
                writeFmt("\x1b[2K   {s} {s}[{s}]{s}{s}\n", .{
                    proxy_name, out.style(.dim), ptype, out.style(.reset), current_mark,
                });
            } else {
                writeFmt("\x1b[2K   {s}{s}\n", .{ proxy_name, current_mark });
            }
        }
    }
}

/// 通知运行中的 daemon 更新代理选择。返回是否真的应用成功（envelope 的
/// data.applied）。诊断提示只在文本模式输出（stderr，带样式开关）。
fn notifyDaemon(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    group_name: []const u8,
    proxy_name: []const u8,
    out: *cli_output.Output,
) bool {
    const ec = cfg.external_controller orelse {
        noteDim(out, "(no external-controller, restart daemon to apply)", .{});
        return false;
    };

    const colon = std.mem.lastIndexOf(u8, ec, ":") orelse return false;
    const port = std.fmt.parseInt(u16, ec[colon + 1 ..], 10) catch return false;
    const host = ec[0..colon];

    // PUT body 经 std.json 序列化（节点名真实转义，禁止手拼 JSON）。
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();
    std.json.Stringify.value(.{ .name = proxy_name }, .{ .whitespace = .minified }, &body_writer.writer) catch return false;
    const body = body_writer.written();

    // 组名进 URL path 必须百分号编码：含空格的组名否则会截断请求行，
    // CR/LF 更会构成请求行注入（daemon 侧对应做解码）。
    var path_writer: std.Io.Writer.Allocating = .init(allocator);
    defer path_writer.deinit();
    std.Uri.Component.percentEncode(&path_writer.writer, group_name, isUriPathSegmentChar) catch return false;
    const encoded_group = path_writer.written();

    const req = std.fmt.allocPrint(allocator, "PUT /proxies/{s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ encoded_group, ec, body.len, body }) catch return false;
    defer allocator.free(req);

    const stream = compat.net.tcpConnectToHost(allocator, host, port) catch {
        noteDim(out, "(daemon not reachable at {s}, restart to apply)", .{ec});
        return false;
    };
    defer stream.close();

    stream.writeAll(req) catch return false;

    var buf: [512]u8 = undefined;
    const n = stream.read(&buf) catch return false;
    // 只认状态行的 200（daemon 对未知组/节点返回 404；body 里碰巧出现的
    // "200" 不能当成功）。applied 必须如实反映 daemon 是否接受了选择。
    if (responseAccepted(buf[0..n])) {
        noteDim(out, "(daemon updated)", .{});
        return true;
    }
    noteDim(out, "(daemon at {s} rejected the selection; is it running this config?)", .{ec});
    return false;
}

/// URL path 段安全字符（RFC 3986 unreserved）；其余一律 %XX 编码。
fn isUriPathSegmentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// HTTP 响应是否为 2xx 成功（按状态行判定，而非全文找 "200" 子串）。
fn responseAccepted(response: []const u8) bool {
    return std.mem.startsWith(u8, response, "HTTP/1.1 200") or
        std.mem.startsWith(u8, response, "HTTP/1.0 200");
}

/// 文本模式专用的弱化诊断行（stderr）。JSON 模式保持 stdout 单文档、stderr 干净。
fn noteDim(out: *cli_output.Output, comptime fmt: []const u8, args: anytype) void {
    if (out.mode != .text) return;
    out.note("{s}", .{out.style(.dim)}) catch {};
    out.note(fmt, args) catch {};
    out.note("{s}\n", .{out.style(.reset)}) catch {};
}

// ── Terminal raw mode helpers ──

const Key = enum { up, down, enter, quit, other };

/// 计算 picker 的 raw-mode termios。除 ECHO/ICANON 外还必须关 ISIG：
/// 否则 Ctrl-C 触发默认 SIGINT 终止，`defer disableRawMode` 与
/// `\x1b[?25h`（恢复光标）永远不会执行，终端被留在 raw + 光标隐藏状态。
/// 关掉 ISIG 后 Ctrl-C 作为 0x03 字节进入 readKey，走与 q/Esc 相同的
/// 取消路径（清屏、恢复光标、还原 termios）。
fn rawModeTermios(original: posix.termios) posix.termios {
    var raw = original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    return raw;
}

fn enableRawMode() !posix.termios {
    if (std.c.isatty(posix.STDIN_FILENO) == 0) return error.NotATerminal;
    const original = try posix.tcgetattr(posix.STDIN_FILENO);
    try posix.tcsetattr(posix.STDIN_FILENO, .NOW, rawModeTermios(original));
    return original;
}

fn disableRawMode(original: *posix.termios) void {
    posix.tcsetattr(posix.STDIN_FILENO, .NOW, original.*) catch {};
}

fn readKey() !Key {
    var buf: [8]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &buf) catch return .other;
    return decodeKey(buf[0..n]);
}

/// 字节序列 → 按键。ISIG 关闭后控制键以普通字节到达：Ctrl-C (0x03)、
/// Ctrl-\ (0x1c)、Ctrl-D (0x04) 全部映射为取消，保证终端经正常路径恢复。
fn decodeKey(bytes: []const u8) Key {
    if (bytes.len == 0) return .other;

    if (bytes.len == 1) {
        return switch (bytes[0]) {
            'q' => .quit,
            0x1b => .quit, // Esc
            0x03 => .quit, // Ctrl-C（ISIG 已关，按取消处理）
            0x04 => .quit, // Ctrl-D
            0x1c => .quit, // Ctrl-\
            '\r', '\n' => .enter,
            'k' => .up,
            'j' => .down,
            else => .other,
        };
    }

    if (bytes.len >= 3 and bytes[0] == 0x1b and bytes[1] == '[') {
        return switch (bytes[2]) {
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

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestStreams = struct {
    out_alloc: std.Io.Writer.Allocating,
    err_alloc: std.Io.Writer.Allocating,

    fn init(allocator: std.mem.Allocator) TestStreams {
        return .{
            .out_alloc = .init(allocator),
            .err_alloc = .init(allocator),
        };
    }

    fn deinit(self: *TestStreams) void {
        self.out_alloc.deinit();
        self.err_alloc.deinit();
    }

    fn output(self: *TestStreams, mode: cli_output.Mode) cli_output.Output {
        return cli_output.Output.init(mode, "proxy list", false, false, &self.out_alloc.writer, &self.err_alloc.writer);
    }
};

fn makeTestConfig(allocator: std.mem.Allocator) !config.Config {
    var cfg = config.Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    errdefer cfg.deinit();

    try cfg.proxies.append(allocator, .{
        .name = try allocator.dupe(u8, "node \"HK\""),
        .proxy_type = .ss,
        .server = try allocator.dupe(u8, "example.com"),
        .port = 443,
    });

    var select_group = config.ProxyGroup{
        .name = try allocator.dupe(u8, "Proxy"),
        .group_type = .select,
        .proxies = std.ArrayList([]const u8).empty,
    };
    errdefer select_group.deinit(allocator);
    try select_group.proxies.append(allocator, try allocator.dupe(u8, "node \"HK\""));
    try select_group.proxies.append(allocator, try allocator.dupe(u8, "Auto"));
    try select_group.proxies.append(allocator, try allocator.dupe(u8, "ghost-node"));
    try cfg.proxy_groups.append(allocator, select_group);

    var auto_group = config.ProxyGroup{
        .name = try allocator.dupe(u8, "Auto"),
        .group_type = .url_test,
        .proxies = std.ArrayList([]const u8).empty,
    };
    errdefer auto_group.deinit(allocator);
    try auto_group.proxies.append(allocator, try allocator.dupe(u8, "node \"HK\""));
    try cfg.proxy_groups.append(allocator, auto_group);

    return cfg;
}

test "listProxiesJson emits valid escaped envelope and fixes type fallback" {
    const allocator = testing.allocator;
    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var streams = TestStreams.init(allocator);
    defer streams.deinit();
    var out = streams.output(.json);

    const selections = [_]runtime_selection.SelectedProxy{.{
        .group_name = "Proxy",
        .proxy_name = "Auto",
        .source = .persisted,
    }};
    try listProxiesJson(allocator, &cfg, selections[0..], &out);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, streams.out_alloc.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("ok").?.bool);
    try testing.expectEqualStrings("proxy list", parsed.value.object.get("command").?.string);

    const data = parsed.value.object.get("data").?.object;
    const groups = data.get("groups").?.array.items;
    try testing.expectEqual(@as(usize, 2), groups.len);

    const select_group = groups[0].object;
    try testing.expectEqualStrings("Proxy", select_group.get("name").?.string);
    try testing.expectEqualStrings("select", select_group.get("type").?.string);
    try testing.expectEqualStrings("Auto", select_group.get("now").?.string);

    const members = select_group.get("proxies").?.array.items;
    try testing.expectEqualStrings("node \"HK\"", members[0].object.get("name").?.string);
    try testing.expectEqualStrings("SS", members[0].object.get("type").?.string);
    try testing.expectEqualStrings("url-test", members[1].object.get("type").?.string);
    // 修复点：未知成员的 type 必须是 "unknown"，而不是回退成员名本身。
    try testing.expectEqualStrings("ghost-node", members[2].object.get("name").?.string);
    try testing.expectEqualStrings("unknown", members[2].object.get("type").?.string);

    const stats = data.get("stats").?.object;
    try testing.expectEqual(@as(i64, 2), stats.get("group_count").?.integer);
    try testing.expectEqual(@as(i64, 1), stats.get("proxy_count").?.integer);
}

test "listProxies renders text to stdout with current marker" {
    const allocator = testing.allocator;
    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var streams = TestStreams.init(allocator);
    defer streams.deinit();
    var out = streams.output(.text);

    const selections = [_]runtime_selection.SelectedProxy{.{
        .group_name = "Proxy",
        .proxy_name = "Auto",
        .source = .default,
    }};
    try listProxies(&cfg, selections[0..], &out);

    const stdout = streams.out_alloc.written();
    try testing.expect(std.mem.indexOf(u8, stdout, "Proxy (select) - 3 proxies") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "* 2. Auto [url-test] (current)") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "1. node \"HK\" [SS]") != null);
    try testing.expectEqualStrings("", streams.err_alloc.written());
}

test "resolveSelectGroup restricts to select-type groups in every mode" {
    const allocator = testing.allocator;
    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    const by_name = try resolveSelectGroup(&cfg, "Proxy");
    try testing.expectEqualStrings("Proxy", by_name.name);

    const default_group = try resolveSelectGroup(&cfg, null);
    try testing.expectEqualStrings("Proxy", default_group.name);

    try testing.expectError(error.GroupNotSelect, resolveSelectGroup(&cfg, "Auto"));
    try testing.expectError(error.GroupNotFound, resolveSelectGroup(&cfg, "Nope"));
}

test "resolveSelectGroup reports missing select group" {
    const allocator = testing.allocator;
    var cfg = config.Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    try testing.expectError(error.NoSelectGroup, resolveSelectGroup(&cfg, null));
}

test "applySelection validates membership and reports applied=false without controller" {
    const allocator = testing.allocator;
    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var streams = TestStreams.init(allocator);
    defer streams.deinit();
    var out = streams.output(.text);

    const group = try resolveSelectGroup(&cfg, "Proxy");
    try testing.expectError(error.ProxyNotFound, applySelection(allocator, &cfg, group, "missing", &out));

    const applied = try applySelection(allocator, &cfg, group, "Auto", &out);
    try testing.expect(!applied);
    // 确认行在 stdout，daemon 提示在 stderr。
    try testing.expect(std.mem.indexOf(u8, streams.out_alloc.written(), "Selected Auto in group Proxy") != null);
    try testing.expect(std.mem.indexOf(u8, streams.err_alloc.written(), "no external-controller") != null);
}

test "applySelection in json mode keeps stdout free for the envelope" {
    const allocator = testing.allocator;
    var cfg = try makeTestConfig(allocator);
    defer cfg.deinit();

    var streams = TestStreams.init(allocator);
    defer streams.deinit();
    var out = streams.output(.json);

    const group = try resolveSelectGroup(&cfg, "Proxy");
    const applied = try applySelection(allocator, &cfg, group, "Auto", &out);
    try testing.expect(!applied);
    try testing.expectEqualStrings("", streams.out_alloc.written());
    try testing.expectEqualStrings("", streams.err_alloc.written());
}

test "rawModeTermios disables ECHO/ICANON/ISIG without mutating the original" {
    var original = std.mem.zeroes(posix.termios);
    original.lflag.ECHO = true;
    original.lflag.ICANON = true;
    original.lflag.ISIG = true;

    const raw = rawModeTermios(original);
    try testing.expect(!raw.lflag.ECHO);
    try testing.expect(!raw.lflag.ICANON);
    // Ctrl-C 必须以字节进入取消路径，而不是 SIGINT 默认终止（终端无法恢复）。
    try testing.expect(!raw.lflag.ISIG);
    try testing.expectEqual(@as(u8, 1), raw.cc[@intFromEnum(posix.V.MIN)]);
    try testing.expectEqual(@as(u8, 0), raw.cc[@intFromEnum(posix.V.TIME)]);

    // disableRawMode 还原用的 original 不能被改动。
    try testing.expect(original.lflag.ECHO);
    try testing.expect(original.lflag.ICANON);
    try testing.expect(original.lflag.ISIG);
}

test "decodeKey maps Ctrl-C and friends to quit (terminal-restoring cancel path)" {
    try testing.expectEqual(Key.quit, decodeKey(&.{0x03})); // Ctrl-C
    try testing.expectEqual(Key.quit, decodeKey(&.{0x04})); // Ctrl-D
    try testing.expectEqual(Key.quit, decodeKey(&.{0x1c})); // Ctrl-\
    try testing.expectEqual(Key.quit, decodeKey("q"));
    try testing.expectEqual(Key.quit, decodeKey(&.{0x1b})); // Esc
    try testing.expectEqual(Key.enter, decodeKey("\r"));
    try testing.expectEqual(Key.enter, decodeKey("\n"));
    try testing.expectEqual(Key.up, decodeKey("k"));
    try testing.expectEqual(Key.down, decodeKey("j"));
    try testing.expectEqual(Key.up, decodeKey("\x1b[A"));
    try testing.expectEqual(Key.down, decodeKey("\x1b[B"));
    try testing.expectEqual(Key.other, decodeKey(""));
    try testing.expectEqual(Key.other, decodeKey("x"));
}

test "isUriPathSegmentChar drives percent-encoding of group names" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try std.Uri.Component.percentEncode(&aw.writer, "My Proxies/\r\n\"x\"", isUriPathSegmentChar);
    try std.testing.expectEqualStrings("My%20Proxies%2F%0D%0A%22x%22", aw.written());
}

test "responseAccepted matches only the status line" {
    try testing.expect(responseAccepted("HTTP/1.1 200 OK\r\n\r\n{\"ok\":true}"));
    try testing.expect(!responseAccepted("HTTP/1.1 404 Not Found\r\n\r\n{\"error\":\"Proxy not found in group\"}"));
    // body 里碰巧出现 "200" 不算成功。
    try testing.expect(!responseAccepted("HTTP/1.1 404 Not Found\r\nContent-Length: 200\r\n\r\n"));
    try testing.expect(!responseAccepted(""));
}

test "currentSelection finds group selection" {
    const selections = [_]runtime_selection.SelectedProxy{
        .{ .group_name = "Proxy", .proxy_name = "B", .source = .persisted },
        .{ .group_name = "Other", .proxy_name = null, .source = .default },
    };
    try testing.expectEqualStrings("B", currentSelection(selections[0..], "Proxy").?);
    try testing.expect(currentSelection(selections[0..], "Other") == null);
    try testing.expect(currentSelection(selections[0..], "Missing") == null);
}
