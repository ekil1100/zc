const std = @import("std");
const net = std.net;
const posix = std.posix;
const Config = @import("config.zig").Config;
const Proxy = @import("config.zig").Proxy;
const ProxyGroup = @import("config.zig").ProxyGroup;
const ProxyType = @import("config.zig").ProxyType;

/// RGB 颜色
const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }
};

// 主题颜色
const theme = struct {
    const bg = Color.rgb(15, 15, 25);
    const panel_bg = Color.rgb(25, 25, 40);
    const border = Color.rgb(60, 60, 90);
    const border_active = Color.rgb(100, 150, 255);
    const text = Color.rgb(220, 220, 230);
    const text_dim = Color.rgb(120, 120, 140);
    const accent = Color.rgb(100, 200, 255);
    const success = Color.rgb(100, 255, 150);
    const warning = Color.rgb(255, 200, 100);
    const err = Color.rgb(255, 100, 100);
    const select_bg = Color.rgb(50, 60, 90);
    const highlight_bg = Color.rgb(70, 80, 120);
};

/// 连接信息
pub const Connection = struct {
    id: u64,
    target_host: []const u8,
    target_port: u16,
    proxy_name: []const u8,
    upload_bytes: u64,
    download_bytes: u64,
    start_time: i64,
};

/// 延迟测试结果
pub const LatencyResult = struct {
    proxy_name: []const u8,
    latency_ms: i64, // -1 表示超时/失败
    tested_at: i64,
};

/// TUI 状态
pub const TuiState = struct {
    running: bool = true,
    selected_tab: usize = 0, // 0=代理组, 1=节点, 2=连接, 3=日志
    selected_group: usize = 0,
    selected_proxy: usize = 0,
    scroll_offset: usize = 0,
    current_proxy: []const u8 = "DIRECT",
    upload_speed: u64 = 0,
    download_speed: u64 = 0,
    active_connections: usize = 0,
    log_messages: std.ArrayList([]const u8),
    connections: std.ArrayList(Connection),
    latency_results: std.StringHashMap(i64), // proxy_name -> latency_ms
    testing_latency: bool = false,
    mouse_enabled: bool = true,
    term_width: usize = 80,
    term_height: usize = 24,
    reload_requested: bool = false,
    dirty: bool = true, // 需要重绘

    pub fn init(allocator: std.mem.Allocator) TuiState {
        return .{
            .log_messages = std.ArrayList([]const u8).empty,
            .connections = std.ArrayList(Connection).empty,
            .latency_results = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *TuiState, allocator: std.mem.Allocator) void {
        for (self.log_messages.items) |msg| {
            allocator.free(msg);
        }
        self.log_messages.deinit(allocator);

        for (self.connections.items) |*conn| {
            allocator.free(conn.target_host);
            allocator.free(conn.proxy_name);
        }
        self.connections.deinit(allocator);

        var latency_it = self.latency_results.iterator();
        while (latency_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.latency_results.deinit();
    }

    pub fn getLatency(self: *const TuiState, proxy_name: []const u8) ?i64 {
        return self.latency_results.get(proxy_name);
    }

    pub fn setLatency(self: *TuiState, allocator: std.mem.Allocator, proxy_name: []const u8, latency: i64) !void {
        const key = try allocator.dupe(u8, proxy_name);
        try self.latency_results.put(key, latency);
    }
};

/// TUI 管理器
const OutboundManager = @import("proxy/outbound/manager.zig").OutboundManager;

pub const TuiManager = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    state: TuiState,
    original_termios: posix.termios,
    reload_callback: ?*const fn () void,
    outbound_manager: ?*OutboundManager = null,

    pub fn init(allocator: std.mem.Allocator, config: *const Config) !TuiManager {
        var manager = TuiManager{
            .allocator = allocator,
            .config = config,
            .state = TuiState.init(allocator),
            .original_termios = undefined,
            .reload_callback = null,
        };

        // 获取终端大小
        manager.updateTerminalSize();

        // 检查 stdin 是否为终端
        const is_terminal = posix.isatty(posix.STDIN_FILENO);

        if (is_terminal) {
            // 保存原始终端设置
            manager.original_termios = try posix.tcgetattr(posix.STDIN_FILENO);

            // 设置终端为 raw 模式
            var raw = manager.original_termios;
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;
            raw.iflag.IXON = false;
            raw.iflag.ICRNL = false;
            raw.cc[@intFromEnum(posix.V.MIN)] = 0;
            raw.cc[@intFromEnum(posix.V.TIME)] = 0;
            try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);

            // 启用鼠标支持
            try enableMouse();

            // 隐藏光标
            try hideCursor();
        } else {
            // 非终端模式，设置默认值
            manager.original_termios = std.mem.zeroes(posix.termios);
        }

        // 清屏
        try clearScreen();

        return manager;
    }

    pub fn deinit(self: *TuiManager) void {
        const is_terminal = posix.isatty(posix.STDIN_FILENO);

        if (is_terminal) {
            disableMouse() catch {};
            posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.original_termios) catch {};
            showCursor() catch {};
        }
        exitAlternateScreen() catch {};
        self.state.deinit(self.allocator);
    }

    pub fn setReloadCallback(self: *TuiManager, callback: *const fn () void) void {
        self.reload_callback = callback;
    }

    fn updateTerminalSize(self: *TuiManager) void {
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0) {
            self.state.term_width = ws.col;
            self.state.term_height = ws.row;
        }
    }

    /// 运行 TUI 主循环
    pub fn run(self: *TuiManager) !void {
        const is_terminal = posix.isatty(posix.STDIN_FILENO);

        if (!is_terminal) {
            std.debug.print("Error: TUI requires a terminal. Please run in an interactive terminal.\n", .{});
            return error.NotATerminal;
        }

        try enterAlternateScreen();
        hideCursor() catch {};

        var buf: [32]u8 = undefined;
        var last_term_size = std.mem.zeroes([2]usize);
        last_term_size[0] = self.state.term_width;
        last_term_size[1] = self.state.term_height;

        // 设置 stdin 为非阻塞模式
        const stdin_flags = posix.fcntl(posix.STDIN_FILENO, posix.F.GETFL, 0) catch 0;
        const new_flags = stdin_flags | 4;
        _ = posix.fcntl(posix.STDIN_FILENO, posix.F.SETFL, new_flags) catch stdin_flags;

        while (self.state.running) {
            // 只有终端大小变化时才更新
            if (self.state.term_width != last_term_size[0] or self.state.term_height != last_term_size[1]) {
                last_term_size[0] = self.state.term_width;
                last_term_size[1] = self.state.term_height;
                self.state.dirty = true;
            }

            if (self.state.dirty) {
                try self.draw();
                self.state.dirty = false;
            }

            // 读取输入 (非阻塞)
            const n = posix.read(posix.STDIN_FILENO, &buf) catch 0;
            if (n > 0) {
                try self.handleInput(buf[0..n]);
                self.state.dirty = true;
            }

            // 检查是否需要重载
            if (self.state.reload_requested) {
                self.state.reload_requested = false;
                if (self.reload_callback) |callback| {
                    callback();
                }
                self.state.dirty = true;
            }

            // 降低 CPU 使用率，16ms 间隔 (约 60fps)
            std.Thread.sleep(16 * std.time.ns_per_ms);
        }

        // 恢复 stdin 模式
        const reset_result = posix.fcntl(posix.STDIN_FILENO, posix.F.SETFL, stdin_flags) catch 0;
        _ = reset_result;

        showCursor() catch {};
        exitAlternateScreen() catch {};
    }

    fn handleInput(self: *TuiManager, input: []const u8) !void {
        var i: usize = 0;
        while (i < input.len) {
            const b = input[i];

            // 鼠标事件
            if (b == 0x1B and i + 2 < input.len and input[i + 1] == '[' and input[i + 2] == '<') {
                try self.parseMouseEvent(input[i..]);
                while (i < input.len and input[i] != 'M' and input[i] != 'm') : (i += 1) {}
                i += 1;
                continue;
            }

            // ESC 序列
            if (b == 0x1B and i + 1 < input.len) {
                const next = input[i + 1];
                if (next == '[' and i + 2 < input.len) {
                    const cmd = input[i + 2];
                    switch (cmd) {
                        'A' => self.moveUp(),
                        'B' => self.moveDown(),
                        'C' => self.moveRight(),
                        'D' => self.moveLeft(),
                        else => {},
                    }
                    i += 3;
                    continue;
                }
            }

            // 普通按键
            switch (b) {
                'q', 'Q' => self.state.running = false,
                'j', 'J' => self.moveDown(),
                'k', 'K' => self.moveUp(),
                'h', 'H' => self.moveLeft(),
                'l', 'L' => self.moveRight(),
                '\t' => self.nextTab(),
                '\r', '\n' => self.selectCurrent(),
                ' ' => self.selectCurrent(),
                'g' => self.goTop(),
                'G' => self.goBottom(),
                't', 'T' => self.testLatency(),
                'r', 'R' => self.requestReload(),
                0x7F, 0x08 => {},
                else => {},
            }

            i += 1;
        }
    }

    fn parseMouseEvent(self: *TuiManager, seq: []const u8) !void {
        if (seq.len < 9) return;

        var pos: usize = 3;
        var btn: u32 = 0;
        while (pos < seq.len and seq[pos] != ';') : (pos += 1) {
            if (seq[pos] >= '0' and seq[pos] <= '9') {
                btn = btn * 10 + (seq[pos] - '0');
            }
        }
        pos += 1;

        var cx: u32 = 0;
        while (pos < seq.len and seq[pos] != ';') : (pos += 1) {
            if (seq[pos] >= '0' and seq[pos] <= '9') {
                cx = cx * 10 + (seq[pos] - '0');
            }
        }
        pos += 1;

        var cy: u32 = 0;
        while (pos < seq.len and seq[pos] != 'M' and seq[pos] != 'm') : (pos += 1) {
            if (seq[pos] >= '0' and seq[pos] <= '9') {
                cy = cy * 10 + (seq[pos] - '0');
            }
        }

        const is_release = pos < seq.len and seq[pos] == 'm';
        const x = if (cx > 0) cx - 1 else 0;
        const y = if (cy > 0) cy - 1 else 0;

        if (!is_release) {
            switch (btn & 3) {
                0 => try self.handleLeftClick(x, y),
                else => {},
            }
        }

        if (btn == 64) {
            self.scrollUp(3);
        } else if (btn == 65) {
            self.scrollDown(3);
        }
    }

    fn handleLeftClick(self: *TuiManager, x: u32, y: u32) !void {
        const row = y;

        // 标签栏
        if (row == 2) {
            const tab_width = self.state.term_width / 4;
            if (x < tab_width) {
                self.state.selected_tab = 0;
            } else if (x < tab_width * 2) {
                self.state.selected_tab = 1;
            } else if (x < tab_width * 3) {
                self.state.selected_tab = 2;
            } else {
                self.state.selected_tab = 3;
            }
            return;
        }

        switch (self.state.selected_tab) {
            0 => {
                const list_start = 5;
                const idx = if (row >= list_start) row - list_start else 0;
                if (idx < self.config.proxy_groups.items.len) {
                    self.state.selected_group = idx;
                    self.state.selected_tab = 1;
                }
            },
            1 => {
                const list_start = 6;
                const idx = if (row >= list_start) row - list_start + self.state.scroll_offset else 0;
                const group = self.getCurrentGroup();
                if (group) |g| {
                    if (idx < g.proxies.items.len) {
                        self.state.selected_proxy = idx;
                        self.selectCurrentProxy();
                    }
                }
            },
            else => {},
        }
    }

    fn moveUp(self: *TuiManager) void {
        switch (self.state.selected_tab) {
            0 => {
                if (self.state.selected_group > 0) {
                    self.state.selected_group -= 1;
                }
            },
            1 => {
                if (self.state.selected_proxy > 0) {
                    self.state.selected_proxy -= 1;
                    if (self.state.selected_proxy < self.state.scroll_offset) {
                        self.state.scroll_offset = self.state.selected_proxy;
                    }
                }
            },
            2 => {
                if (self.state.scroll_offset > 0) {
                    self.state.scroll_offset -= 1;
                }
            },
            else => {},
        }
    }

    fn moveDown(self: *TuiManager) void {
        switch (self.state.selected_tab) {
            0 => {
                if (self.state.selected_group + 1 < self.config.proxy_groups.items.len) {
                    self.state.selected_group += 1;
                }
            },
            1 => {
                const group = self.getCurrentGroup() orelse return;
                if (self.state.selected_proxy + 1 < group.proxies.items.len) {
                    self.state.selected_proxy += 1;
                    const visible_rows = self.state.term_height - 10;
                    if (self.state.selected_proxy >= self.state.scroll_offset + visible_rows) {
                        self.state.scroll_offset = self.state.selected_proxy - visible_rows + 1;
                    }
                }
            },
            2 => {
                if (self.state.scroll_offset + 1 < self.state.connections.items.len) {
                    self.state.scroll_offset += 1;
                }
            },
            else => {},
        }
    }

    fn moveLeft(self: *TuiManager) void {
        if (self.state.selected_tab > 0) {
            self.state.selected_tab -= 1;
        }
    }

    fn moveRight(self: *TuiManager) void {
        if (self.state.selected_tab < 3) {
            self.state.selected_tab += 1;
        }
    }

    fn nextTab(self: *TuiManager) void {
        self.state.selected_tab = (self.state.selected_tab + 1) % 4;
    }

    fn scrollUp(self: *TuiManager, amount: usize) void {
        if (self.state.scroll_offset >= amount) {
            self.state.scroll_offset -= amount;
        } else {
            self.state.scroll_offset = 0;
        }
    }

    fn scrollDown(self: *TuiManager, amount: usize) void {
        const max_items = switch (self.state.selected_tab) {
            1 => blk: {
                const group = self.getCurrentGroup() orelse return;
                break :blk group.proxies.items.len;
            },
            2 => self.state.connections.items.len,
            else => return,
        };

        const max_scroll = if (max_items > 0) max_items - 1 else 0;
        self.state.scroll_offset = @min(self.state.scroll_offset + amount, max_scroll);
    }

    fn goTop(self: *TuiManager) void {
        switch (self.state.selected_tab) {
            0 => self.state.selected_group = 0,
            1, 2 => {
                self.state.scroll_offset = 0;
                if (self.state.selected_tab == 1) {
                    self.state.selected_proxy = 0;
                }
            },
            else => {},
        }
    }

    fn goBottom(self: *TuiManager) void {
        switch (self.state.selected_tab) {
            0 => {
                if (self.config.proxy_groups.items.len > 0) {
                    self.state.selected_group = self.config.proxy_groups.items.len - 1;
                }
            },
            1 => {
                const group = self.getCurrentGroup() orelse return;
                if (group.proxies.items.len > 0) {
                    self.state.selected_proxy = group.proxies.items.len - 1;
                }
            },
            2 => {
                if (self.state.connections.items.len > 0) {
                    self.state.scroll_offset = self.state.connections.items.len - 1;
                }
            },
            else => {},
        }
    }

    fn selectCurrent(self: *TuiManager) void {
        switch (self.state.selected_tab) {
            0 => self.state.selected_tab = 1,
            1 => self.selectCurrentProxy(),
            else => {},
        }
    }

    fn getCurrentGroup(self: *TuiManager) ?*const ProxyGroup {
        if (self.config.proxy_groups.items.len == 0) return null;
        if (self.state.selected_group >= self.config.proxy_groups.items.len) return null;
        return &self.config.proxy_groups.items[self.state.selected_group];
    }

    fn findProxyByName(self: *TuiManager, name: []const u8) ?*const Proxy {
        for (self.config.proxies.items) |*proxy| {
            if (std.mem.eql(u8, proxy.name, name)) {
                return proxy;
            }
        }
        return null;
    }

    fn selectCurrentProxy(self: *TuiManager) void {
        const group = self.getCurrentGroup() orelse return;
        if (self.state.selected_proxy >= group.proxies.items.len) return;

        const proxy_name = group.proxies.items[self.state.selected_proxy];
        self.state.current_proxy = proxy_name;

        // 通知 OutboundManager 更新代理组选择
        if (self.outbound_manager) |mgr| {
            mgr.selectProxy(group.name, proxy_name);
        }

        const msg = std.fmt.allocPrint(self.allocator, "Switched to: {s}", .{proxy_name}) catch return;
        self.log(msg) catch {};
    }

    fn testLatency(self: *TuiManager) void {
        if (self.state.testing_latency) return;

        const group = self.getCurrentGroup() orelse return;
        if (group.proxies.items.len == 0) return;

        self.state.testing_latency = true;
        self.log("Starting latency test...") catch {};

        // 复制 config 指针供线程使用
        const config_ptr = self.config;

        // 启动后台线程测试延迟
        const thread = std.Thread.spawn(.{}, latencyTestThread, .{ self, config_ptr, group }) catch {
            self.state.testing_latency = false;
            return;
        };
        thread.detach();
    }

    fn latencyTestThread(self: *TuiManager, config: *const Config, group: *const ProxyGroup) void {
        defer self.state.testing_latency = false;
        defer {
            self.state.dirty = true;
        }

        for (group.proxies.items) |proxy_name| {
            const latency = testProxyLatency(config, proxy_name);
            self.state.setLatency(self.allocator, proxy_name, latency) catch {};

            const latency_str = if (latency < 0)
                "n/a"
            else
                std.fmt.allocPrint(self.allocator, "{d}ms", .{latency}) catch continue;
            defer self.allocator.free(latency_str);

            const msg = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ proxy_name, latency_str }) catch continue;
            defer self.allocator.free(msg);
            self.log(msg) catch {};
            self.state.dirty = true;
        }

        self.log("Latency test completed") catch {};
    }

    fn testProxyLatency(config: *const Config, proxy_name: []const u8) i64 {
        // DIRECT or REJECT
        if (std.mem.eql(u8, proxy_name, "DIRECT") or std.mem.eql(u8, proxy_name, "REJECT")) {
            return 0;
        }

        // 检查是否是代理组名称，如果是则跳过
        for (config.proxy_groups.items) |grp| {
            if (std.mem.eql(u8, grp.name, proxy_name)) {
                return -1; // 跳过代理组
            }
        }

        // 查找代理信息
        const proxy = for (config.proxies.items) |p| {
            if (std.mem.eql(u8, p.name, proxy_name)) break p;
        } else return -1;

        const test_url = "http://1.1.1.1/";
        const timeout_ms: i64 = 3000;

        // 根据代理类型选择测试方法
        switch (proxy.proxy_type) {
            .http => {
                return curlLatency(proxy.server, proxy.port, test_url, .http, timeout_ms);
            },
            .socks5 => {
                return curlLatency(proxy.server, proxy.port, test_url, .socks5, timeout_ms);
            },
            else => {
                // 其他类型暂时返回 -1
                return -1;
            },
        }
    }

    const ProxyProto = enum { http, socks5 };

    fn curlLatency(server: []const u8, port: u16, url: []const u8, proto: ProxyProto, timeout_ms: i64) i64 {
        const start = std.time.milliTimestamp();

        // 使用固定 allocator，因为这是同步调用
        const allocator = std.heap.page_allocator;

        const proxy_url = switch (proto) {
            .http => std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ server, port }) catch return -1,
            .socks5 => std.fmt.allocPrint(allocator, "socks5://{s}:{d}", .{ server, port }) catch return -1,
        };
        defer allocator.free(proxy_url);

        var args = std.ArrayList([]const u8).empty;
        defer args.deinit(allocator);

        const timeout_secs = @divTrunc(timeout_ms, 1000);
        const timeout_str = std.fmt.allocPrint(allocator, "{d}", .{timeout_secs}) catch return -1;
        defer allocator.free(timeout_str);

        args.appendSlice(allocator, &.{ "curl", "--silent", "--show-error", "-x", proxy_url, "--max-time", timeout_str, "-o", "/dev/null", "-w", "%{http_code}", url }) catch return -1;

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = args.items,
        }) catch return -1;
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        const end = std.time.milliTimestamp();
        const latency = end - start;

        if (result.term == .Exited and result.term.Exited == 0) {
            // 检查 HTTP 状态码
            if (result.stdout.len >= 3) {
                const status = result.stdout[result.stdout.len - 3 ..];
                if (std.mem.eql(u8, status, "200") or std.mem.eql(u8, status, "204") or std.mem.eql(u8, status, "301") or std.mem.eql(u8, status, "302")) {
                    return latency;
                }
            }
        }

        return -1;
    }

    fn requestReload(self: *TuiManager) void {
        self.state.reload_requested = true;
        self.log("Reloading configuration...") catch {};
    }

    pub fn addConnection(self: *TuiManager, target_host: []const u8, target_port: u16, proxy_name: []const u8) !u64 {
        const id = std.crypto.random.int(u64);
        const host = try self.allocator.dupe(u8, target_host);
        const proxy = try self.allocator.dupe(u8, proxy_name);

        try self.state.connections.append(.{
            .id = id,
            .target_host = host,
            .target_port = target_port,
            .proxy_name = proxy,
            .upload_bytes = 0,
            .download_bytes = 0,
            .start_time = std.time.milliTimestamp(),
        });

        self.state.dirty = true;
        return id;
    }

    pub fn removeConnection(self: *TuiManager, id: u64) void {
        for (self.state.connections.items, 0..) |*conn, i| {
            if (conn.id == id) {
                self.allocator.free(conn.target_host);
                self.allocator.free(conn.proxy_name);
                _ = self.state.connections.orderedRemove(i);
                self.state.dirty = true;
                break;
            }
        }
    }

    pub fn updateConnectionStats(self: *TuiManager, id: u64, upload: u64, download: u64) void {
        for (self.state.connections.items) |*conn| {
            if (conn.id == id) {
                conn.upload_bytes = upload;
                conn.download_bytes = download;
                self.state.dirty = true;
                break;
            }
        }
    }

    /// 绘制界面
    fn draw(self: *TuiManager) !void {
        const w = self.state.term_width;
        const h = self.state.term_height;

        // 清屏
        try clearScreen();
        try moveCursor(1, 1);

        // 顶部标题栏
        try setBgColor(theme.panel_bg);
        try setFgColor(theme.accent);
        try print(" === zc === ");
        try setFgColor(theme.text_dim);
        try printCentered("Proxy Dashboard", w - 20);

        // 状态栏
        try moveCursor(2, 1);
        try setFgColor(theme.text);
        const status = try std.fmt.allocPrint(self.allocator, " Active: {s} | Conn: {d} ", .{ self.state.current_proxy, self.state.connections.items.len });
        defer self.allocator.free(status);
        try printPaddedRight(status, w);

        // 标签栏
        try self.drawTabs(3, w);

        // 主内容区
        const content_height = h - 6;

        switch (self.state.selected_tab) {
            0 => try self.drawGroupsView(4, w, content_height),
            1 => try self.drawProxiesView(4, w, content_height),
            2 => try self.drawConnectionsView(4, w, content_height),
            3 => try self.drawLogsView(4, w, content_height),
            else => {},
        }

        // 底部帮助栏
        try moveCursor(h - 1, 1);
        try setBgColor(theme.panel_bg);
        try setFgColor(theme.text_dim);
        const help = if (self.state.testing_latency)
            " Testing latency... | q:Quit "
        else
            " Arrows/j,k:Navigate | Enter:Select | t:Test | r:Reload | q:Quit ";
        try printPaddedRight(help, w);
        try resetStyles();
    }

    fn drawTabs(self: *TuiManager, row: usize, width: usize) !void {
        const tabs = [_][]const u8{ " Groups ", " Proxies ", " Connections ", " Logs " };
        const tab_width = width / tabs.len;

        for (tabs, 0..) |tab, i| {
            const col = i * tab_width + 1;
            try moveCursor(row, col);

            if (i == self.state.selected_tab) {
                try setBgColor(theme.highlight_bg);
                try setFgColor(theme.accent);
                try setBold();
            } else {
                try setBgColor(theme.panel_bg);
                try setFgColor(theme.text_dim);
            }

            try printCentered(tab, tab_width);
            try resetStyles();

            if (i < tabs.len - 1) {
                try setFgColor(theme.border);
                try print("|");
                try resetStyles();
            }
        }
    }

    fn drawGroupsView(self: *TuiManager, start_row: usize, width: usize, height: usize) !void {
        _ = height;
        _ = width;

        try moveCursor(start_row, 2);
        try setFgColor(theme.text_dim);
        try print("Proxy Groups");
        try resetStyles();

        var row = start_row + 2;
        for (self.config.proxy_groups.items, 0..) |group, i| {
            try moveCursor(row, 4);

            if (i == self.state.selected_group) {
                try setBgColor(theme.select_bg);
                try setFgColor(theme.accent);
                try print("> ");
            } else {
                try setFgColor(theme.text);
                try print("  ");
            }

            try setBold();
            try print(group.name);
            try resetBold();

            try setFgColor(theme.text_dim);
            const type_str = switch (group.group_type) {
                .select => " [select]",
                .url_test => " [url-test]",
                .fallback => " [fallback]",
                .load_balance => " [load-balance]",
                .relay => " [relay]",
            };
            try print(type_str);

            try print(" ");
            try setFgColor(theme.warning);
            const count = try std.fmt.allocPrint(self.allocator, "({d})", .{group.proxies.items.len});
            defer self.allocator.free(count);
            try print(count);

            try resetStyles();
            row += 1;
        }

        try moveCursor(row + 2, 4);
        try setFgColor(theme.text_dim);
        try print("Press Enter or click group to view nodes");
        try resetStyles();
    }

    fn drawProxiesView(self: *TuiManager, start_row: usize, width: usize, height: usize) !void {
        _ = height;
        _ = width;

        const group = self.getCurrentGroup();
        try moveCursor(start_row, 2);
        try setFgColor(theme.text_dim);
        if (group) |g| {
            const header = try std.fmt.allocPrint(self.allocator, "{s} > Nodes (press 't' to test latency)", .{g.name});
            defer self.allocator.free(header);
            try print(header);
        } else {
            try print("No proxy group selected");
        }
        try resetStyles();

        // 表头
        try moveCursor(start_row + 2, 2);
        try setFgColor(theme.border);
        try print("  Name              Type        Server              Latency ");
        try resetStyles();

        try moveCursor(start_row + 3, 2);
        try setFgColor(theme.border);
        try print("-----------------------------------------------------------");
        try resetStyles();

        if (group) |g| {
            const visible_count = self.state.term_height - 10;
            const end_idx = @min(g.proxies.items.len, self.state.scroll_offset + visible_count);

            var row = start_row + 4;
            var idx = self.state.scroll_offset;
            while (idx < end_idx) : (idx += 1) {
                const proxy_name = g.proxies.items[idx];
                const is_selected = idx == self.state.selected_proxy;
                const is_current = std.mem.eql(u8, proxy_name, self.state.current_proxy);

                try moveCursor(row, 2);

                if (is_selected) {
                    try setBgColor(theme.select_bg);
                }

                if (is_selected) {
                    try setFgColor(theme.accent);
                    try print("> ");
                } else if (is_current) {
                    try setFgColor(theme.success);
                    try print("* ");
                } else {
                    try print("  ");
                }

                const proxy = self.findProxyByName(proxy_name);

                if (is_current) {
                    try setFgColor(theme.success);
                    try setBold();
                } else if (is_selected) {
                    try setFgColor(theme.accent);
                } else {
                    try setFgColor(theme.text);
                }
                try printPadded(proxy_name, 16);
                try resetBold();

                try setFgColor(theme.text_dim);
                if (proxy) |p| {
                    const type_str = proxyTypeToString(p.proxy_type);
                    try printPadded(type_str, 10);
                } else {
                    try printPadded("-", 10);
                }

                try setFgColor(theme.text);
                if (proxy) |p| {
                    const addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ p.server, p.port });
                    defer self.allocator.free(addr);
                    try printPadded(addr, 18);
                } else {
                    try printPadded("-", 18);
                }

                // 显示延迟
                if (self.state.getLatency(proxy_name)) |latency| {
                    if (latency < 0) {
                        try setFgColor(theme.err);
                        try print("  timeout");
                    } else if (latency < 100) {
                        try setFgColor(theme.success);
                        const lat_str = try std.fmt.allocPrint(self.allocator, "  {d}ms", .{latency});
                        defer self.allocator.free(lat_str);
                        try print(lat_str);
                    } else if (latency < 300) {
                        try setFgColor(theme.warning);
                        const lat_str = try std.fmt.allocPrint(self.allocator, "  {d}ms", .{latency});
                        defer self.allocator.free(lat_str);
                        try print(lat_str);
                    } else {
                        try setFgColor(theme.err);
                        const lat_str = try std.fmt.allocPrint(self.allocator, "  {d}ms", .{latency});
                        defer self.allocator.free(lat_str);
                        try print(lat_str);
                    }
                } else {
                    try setFgColor(theme.text_dim);
                    try print("  --");
                }

                try resetStyles();
                row += 1;
            }

            if (g.proxies.items.len > visible_count) {
                try moveCursor(start_row + 4 + visible_count, 2);
                try setFgColor(theme.text_dim);
                const scroll_info = try std.fmt.allocPrint(self.allocator, "  ({d}/{d})", .{ self.state.scroll_offset + 1, g.proxies.items.len });
                defer self.allocator.free(scroll_info);
                try print(scroll_info);
                try resetStyles();
            }
        }
    }

    fn drawConnectionsView(self: *TuiManager, start_row: usize, width: usize, height: usize) !void {
        _ = height;
        _ = width;

        try moveCursor(start_row, 2);
        try setFgColor(theme.text_dim);
        const header = try std.fmt.allocPrint(self.allocator, "Active Connections ({d})", .{self.state.connections.items.len});
        defer self.allocator.free(header);
        try print(header);
        try resetStyles();

        // 表头
        try moveCursor(start_row + 2, 2);
        try setFgColor(theme.border);
        try print("  ID      Target                    Proxy           Up      Down    Duration ");
        try resetStyles();

        try moveCursor(start_row + 3, 2);
        try setFgColor(theme.border);
        try print("-------------------------------------------------------------------------------");
        try resetStyles();

        const visible_count = self.state.term_height - 10;
        const start = self.state.scroll_offset;
        const end = @min(self.state.connections.items.len, start + visible_count);

        var row = start_row + 4;
        var idx = start;
        while (idx < end) : (idx += 1) {
            const conn = &self.state.connections.items[idx];

            try moveCursor(row, 2);
            try setFgColor(theme.text);

            // ID
            const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{conn.id % 10000});
            defer self.allocator.free(id_str);
            try printPadded(id_str, 8);

            // Target
            const target = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ conn.target_host, conn.target_port });
            defer self.allocator.free(target);
            if (target.len > 22) {
                try print(target[0..19]);
                try setFgColor(theme.text_dim);
                try print("...");
                try setFgColor(theme.text);
            } else {
                try printPadded(target, 22);
            }

            // Proxy
            try setFgColor(theme.accent);
            try printPadded(conn.proxy_name, 14);

            // Upload
            try setFgColor(theme.text_dim);
            const up_str = try formatBytes(conn.upload_bytes);
            defer self.allocator.free(up_str);
            try printPadded(up_str, 8);

            // Download
            const down_str = try formatBytes(conn.download_bytes);
            defer self.allocator.free(down_str);
            try printPadded(down_str, 8);

            // Duration
            const duration = std.time.milliTimestamp() - conn.start_time;
            const dur_str = try formatDuration(duration);
            defer self.allocator.free(dur_str);
            try setFgColor(theme.text);
            try print(dur_str);

            try resetStyles();
            row += 1;
        }

        if (self.state.connections.items.len == 0) {
            try moveCursor(start_row + 5, 4);
            try setFgColor(theme.text_dim);
            try print("No active connections");
            try resetStyles();
        }
    }

    fn drawLogsView(self: *TuiManager, start_row: usize, width: usize, height: usize) !void {
        _ = height;
        _ = width;

        try moveCursor(start_row, 2);
        try setFgColor(theme.text_dim);
        try print("System Logs");
        try resetStyles();

        var row = start_row + 2;
        const visible_count = self.state.term_height - 8;
        const start = if (self.state.log_messages.items.len > visible_count)
            self.state.log_messages.items.len - visible_count
        else
            0;

        for (self.state.log_messages.items[start..]) |msg| {
            try moveCursor(row, 4);

            // Log level color highlighting
            const log_color = logLevelColor(msg);
            try setFgColor(log_color);

            if (msg.len > self.state.term_width - 8) {
                try print(msg[0 .. self.state.term_width - 11]);
                try setFgColor(theme.text_dim);
                try print("...");
            } else {
                try print(msg);
            }

            try resetStyles();
            row += 1;
        }
    }

    fn logLevelColor(msg: []const u8) Color {
        // Match common log prefixes: [error], [warn], [info], ERROR, WARN, INFO
        const lower_bound = if (msg.len > 20) 20 else msg.len;
        const prefix = msg[0..lower_bound];
        if (containsCI(prefix, "error") or containsCI(prefix, "[err")) return theme.err;
        if (containsCI(prefix, "warn")) return theme.warning;
        if (containsCI(prefix, "info")) return theme.accent;
        return theme.text;
    }

    fn containsCI(haystack: []const u8, needle: []const u8) bool {
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            var match = true;
            for (needle, 0..) |nc, j| {
                const hc = haystack[i + j];
                const hlower = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
                const nlower = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
                if (hlower != nlower) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    fn proxyTypeToString(proxy_type: ProxyType) []const u8 {
        return switch (proxy_type) {
            .direct => "Direct",
            .reject => "Reject",
            .http => "HTTP",
            .socks5 => "SOCKS5",
            .ss => "Shadowsocks",
            .vmess => "VMess",
            .trojan => "Trojan",
            .vless => "VLESS",
        };
    }

    /// 添加日志
    pub fn log(self: *TuiManager, message: []const u8) !void {
        const msg = try self.allocator.dupe(u8, message);
        try self.state.log_messages.append(self.allocator, msg);

        if (self.state.log_messages.items.len > 100) {
            const old = self.state.log_messages.orderedRemove(0);
            self.allocator.free(old);
        }
    }

    /// 更新统计
    pub fn updateStats(self: *TuiManager, upload: u64, download: u64, connections: usize) void {
        self.state.upload_speed = upload;
        self.state.download_speed = download;
        self.state.active_connections = connections;
        self.state.dirty = true;
    }

    /// 获取当前选中的代理名称
    pub fn getCurrentProxy(self: *TuiManager) []const u8 {
        return self.state.current_proxy;
    }

    /// 获取重载请求状态
    pub fn isReloadRequested(self: *const TuiManager) bool {
        return self.state.reload_requested;
    }

    /// 清除重载请求
    pub fn clearReloadRequest(self: *TuiManager) void {
        self.state.reload_requested = false;
    }
};

// ============ 辅助函数 ============

fn formatBytes(bytes: u64) ![]const u8 {
    const allocator = std.heap.page_allocator;
    if (bytes < 1024) {
        return try std.fmt.allocPrint(allocator, "{d}B", .{bytes});
    } else if (bytes < 1024 * 1024) {
        return try std.fmt.allocPrint(allocator, "{d:.1}K", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    } else if (bytes < 1024 * 1024 * 1024) {
        return try std.fmt.allocPrint(allocator, "{d:.1}M", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    } else {
        return try std.fmt.allocPrint(allocator, "{d:.1}G", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)});
    }
}

fn formatDuration(ms: i64) ![]const u8 {
    const allocator = std.heap.page_allocator;
    const seconds = @divTrunc(ms, 1000);

    if (seconds < 60) {
        return try std.fmt.allocPrint(allocator, "{d}s", .{seconds});
    } else if (seconds < 3600) {
        const mins = @divTrunc(seconds, 60);
        const secs = @mod(seconds, 60);
        return try std.fmt.allocPrint(allocator, "{d}m{d}s", .{ mins, secs });
    } else {
        const hours = @divTrunc(seconds, 3600);
        const mins = @mod(@divTrunc(seconds, 60), 60);
        return try std.fmt.allocPrint(allocator, "{d}h{d}m", .{ hours, mins });
    }
}

fn clearScreen() !void {
    std.debug.print("\x1B[2J\x1B[H", .{});
}

fn enterAlternateScreen() !void {
    std.debug.print("\x1B[?1049h", .{});
}

fn exitAlternateScreen() !void {
    std.debug.print("\x1B[?1049l", .{});
}

fn fillScreen(char: u8) !void {
    _ = char;
    std.debug.print("\x1B[2J", .{});
}

fn moveCursor(row: usize, col: usize) !void {
    std.debug.print("\x1B[{d};{d}H", .{ row, col });
}

fn hideCursor() !void {
    std.debug.print("\x1B[?25l", .{});
}

fn showCursor() !void {
    std.debug.print("\x1B[?25h", .{});
}

fn enableMouse() !void {
    std.debug.print("\x1B[?1000h", .{});
    std.debug.print("\x1B[?1002h", .{});
    std.debug.print("\x1B[?1006h", .{});
}

fn disableMouse() !void {
    std.debug.print("\x1B[?1006l", .{});
    std.debug.print("\x1B[?1002l", .{});
    std.debug.print("\x1B[?1000l", .{});
}

fn setBold() !void {
    std.debug.print("\x1B[1m", .{});
}

fn resetBold() !void {
    std.debug.print("\x1B[22m", .{});
}

fn setFgColor(color: Color) !void {
    std.debug.print("\x1B[38;2;{d};{d};{d}m", .{ color.r, color.g, color.b });
}

fn setBgColor(color: Color) !void {
    std.debug.print("\x1B[48;2;{d};{d};{d}m", .{ color.r, color.g, color.b });
}

fn resetStyles() !void {
    std.debug.print("\x1B[0m", .{});
}

fn print(str: []const u8) !void {
    std.debug.print("{s}", .{str});
}

fn printCentered(str: []const u8, width: usize) !void {
    if (str.len >= width) {
        try print(str[0..width]);
        return;
    }
    const padding = (width - str.len) / 2;
    var i: usize = 0;
    while (i < padding) : (i += 1) {
        try print(" ");
    }
    try print(str);
    i = 0;
    while (i < width - str.len - padding) : (i += 1) {
        try print(" ");
    }
}

fn printPadded(str: []const u8, width: usize) !void {
    if (str.len >= width) {
        try print(str[0..width]);
        return;
    }
    try print(str);
    var i: usize = 0;
    while (i < width - str.len) : (i += 1) {
        try print(" ");
    }
}

fn printPaddedRight(str: []const u8, width: usize) !void {
    if (str.len >= width) {
        try print(str[0..width]);
        return;
    }
    var i: usize = 0;
    while (i < width - str.len) : (i += 1) {
        try print(" ");
    }
    try print(str);
}
