const std = @import("std");
const compat = @import("../compat.zig");
const net = compat.net;
const http = std.http;

/// 代理健康检查结果
pub const HealthCheckResult = struct {
    name: []const u8,
    delay_ms: u32,
    alive: bool,
    last_check: i64,
};

/// 代理选择器类型
pub const SelectorType = enum {
    select,         // 手动选择
    url_test,       // URL 测试，选择延迟最低的
    fallback,       // 故障转移，按顺序选择可用的
    load_balance,   // 负载均衡，轮询或随机
};

/// 负载均衡策略
pub const LoadBalanceStrategy = enum {
    round_robin,    // 轮询
    random,         // 随机
    least_conn,     // 最少连接
};

/// 智能代理组
pub const SmartGroup = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    selector_type: SelectorType,
    proxies: std.ArrayList([]const u8),
    
    // URL-Test / Fallback 配置
    url: []const u8,
    interval: u32,      // 测试间隔（秒）
    timeout: u32,       // 超时（毫秒）
    
    // Load-Balance 配置
    strategy: LoadBalanceStrategy,
    
    // 状态
    current_index: usize,
    health_results: std.StringHashMap(HealthCheckResult),
    last_check_time: i64,
    rr_counter: usize,  // Round-robin 计数器

    pub fn init(allocator: std.mem.Allocator, name: []const u8, selector_type: SelectorType, proxies: []const []const u8) !SmartGroup {
        var group = SmartGroup{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .selector_type = selector_type,
            .proxies = std.ArrayList([]const u8).empty,
            .url = try allocator.dupe(u8, "http://www.gstatic.com/generate_204"),
            .interval = 300,    // 5 分钟
            .timeout = 5000,    // 5 秒
            .strategy = .round_robin,
            .current_index = 0,
            .health_results = std.StringHashMap(HealthCheckResult).init(allocator),
            .last_check_time = 0,
            .rr_counter = 0,
        };

        for (proxies) |proxy| {
            try group.proxies.append(allocator, try allocator.dupe(u8, proxy));
        }

        return group;
    }

    pub fn deinit(self: *SmartGroup) void {
        self.allocator.free(self.name);
        self.allocator.free(self.url);
        
        for (self.proxies.items) |proxy| {
            self.allocator.free(proxy);
        }
        self.proxies.deinit(self.allocator);

        var iter = self.health_results.valueIterator();
        while (iter.next()) |result| {
            self.allocator.free(result.name);
        }
        self.health_results.deinit();
    }

    /// 获取当前应该使用的代理
    pub fn selectProxy(self: *SmartGroup) ![]const u8 {
        switch (self.selector_type) {
            .select => {
                // 手动选择，返回当前选中的
                if (self.proxies.items.len == 0) return error.NoProxy;
                return self.proxies.items[self.current_index];
            },
            .url_test => {
                // 选择延迟最低的可用代理
                return self.selectByLatency();
            },
            .fallback => {
                // 按顺序选择第一个可用的
                return self.selectFirstAvailable();
            },
            .load_balance => {
                // 按策略选择
                return self.selectByStrategy();
            },
        }
    }

    /// 切换到指定代理（用于 select 类型）
    pub fn switchProxy(self: *SmartGroup, proxy_name: []const u8) !void {
        for (self.proxies.items, 0..) |proxy, i| {
            if (std.mem.eql(u8, proxy, proxy_name)) {
                self.current_index = i;
                return;
            }
        }
        return error.ProxyNotFound;
    }

    /// 执行健康检查
    pub fn checkHealth(self: *SmartGroup, testFn: *const fn ([]const u8, []const u8, u32) u32) !void {
        const now = compat.timestamp();
        
        // 检查是否需要重新测试
        if (now - self.last_check_time < self.interval) {
            return;
        }

        std.debug.print("[SmartGroup] Checking health for {s}...\n", .{self.name});

        for (self.proxies.items) |proxy| {
            const delay = testFn(proxy, self.url, self.timeout);
            
            const result = HealthCheckResult{
                .name = try self.allocator.dupe(u8, proxy),
                .delay_ms = delay,
                .alive = delay < self.timeout,
                .last_check = now,
            };

            // 更新结果
            if (self.health_results.get(proxy)) |old| {
                self.allocator.free(old.name);
            }
            try self.health_results.put(proxy, result);

            std.debug.print("  {s}: {d}ms ({s})\n", .{
                proxy,
                delay,
                if (result.alive) "alive" else "dead",
            });
        }

        self.last_check_time = now;
    }

    fn selectByLatency(self: *SmartGroup) ![]const u8 {
        var best_proxy: ?[]const u8 = null;
        var best_delay: u32 = std.math.maxInt(u32);

        for (self.proxies.items) |proxy| {
            if (self.health_results.get(proxy)) |result| {
                if (result.alive and result.delay_ms < best_delay) {
                    best_delay = result.delay_ms;
                    best_proxy = proxy;
                }
            }
        }

        // 如果没有测试结果，返回第一个
        if (best_proxy == null and self.proxies.items.len > 0) {
            return self.proxies.items[0];
        }

        return best_proxy orelse error.NoAvailableProxy;
    }

    fn selectFirstAvailable(self: *SmartGroup) ![]const u8 {
        for (self.proxies.items) |proxy| {
            if (self.health_results.get(proxy)) |result| {
                if (result.alive) return proxy;
            } else {
                // 没有测试结果，假设可用
                return proxy;
            }
        }

        // 都不可用，返回第一个
        if (self.proxies.items.len > 0) {
            return self.proxies.items[0];
        }

        return error.NoAvailableProxy;
    }

    fn selectByStrategy(self: *SmartGroup) ![]const u8 {
        if (self.proxies.items.len == 0) {
            return error.NoProxy;
        }

        switch (self.strategy) {
            .round_robin => {
                const idx = self.rr_counter % self.proxies.items.len;
                self.rr_counter += 1;
                return self.proxies.items[idx];
            },
            .random => {
                var buf: [8]u8 = undefined;
                compat.randomBytes(&buf);
                const idx = std.mem.readInt(u64, &buf, .little) % self.proxies.items.len;
                return self.proxies.items[idx];
            },
            .least_conn => {
                // 简化：随机选择
                return self.selectByStrategy(); // Fallback to round_robin
            },
        }
    }
};

/// 简化的延迟测试函数（占位符）
/// 实际应该通过代理发送 HTTP 请求测试
pub fn testProxyDelay(proxy_name: []const u8, url: []const u8, timeout: u32) u32 {
    _ = url;
    _ = timeout;
    
    // 简化：返回随机延迟，实际应该通过代理连接测试
    var buf: [4]u8 = undefined;
    compat.randomBytes(&buf);
    const delay = @as(u32, @intCast(buf[0])) * 10;
    
    std.debug.print("[DelayTest] {s}: {d}ms (placeholder)\n", .{ proxy_name, delay });
    return delay;
}
