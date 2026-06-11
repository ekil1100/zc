const std = @import("std");
const config = @import("config.zig");
const meta = @import("meta.zig");

pub const SelectionSource = enum {
    persisted,
    default,
};

pub const SelectedProxy = struct {
    group_name: []const u8,
    proxy_name: ?[]const u8,
    source: SelectionSource,

    pub fn deinit(self: *SelectedProxy, allocator: std.mem.Allocator) void {
        allocator.free(self.group_name);
        if (self.proxy_name) |name| allocator.free(name);
    }

    /// std.json 序列化钩子：保持冻结的字段名 group/proxy/source
    /// （docs/cli/ux-workflow.md 第 3 节）。
    pub fn jsonStringify(self: SelectedProxy, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("group");
        try jws.write(self.group_name);
        try jws.objectField("proxy");
        try jws.write(self.proxy_name);
        try jws.objectField("source");
        try jws.write(sourceString(self.source));
        try jws.endObject();
    }
};

pub fn sourceString(source: SelectionSource) []const u8 {
    return switch (source) {
        .persisted => "persisted",
        .default => "default",
    };
}

pub fn deinitSelectedProxies(allocator: std.mem.Allocator, selections: []SelectedProxy) void {
    for (selections) |*selection| {
        selection.deinit(allocator);
    }
    if (selections.len > 0) allocator.free(selections);
}

pub fn collectSelectedProxies(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    config_key: ?[]const u8,
) ![]SelectedProxy {
    var meta_data: ?meta.MetaData = null;
    defer if (meta_data) |*data| data.deinit();

    if (config_key != null) {
        meta_data = meta.load(allocator) catch null;
    }

    return try collectSelectedProxiesFromMetaData(allocator, cfg, config_key, if (meta_data) |*data| data else null);
}

fn collectSelectedProxiesFromMetaData(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    config_key: ?[]const u8,
    meta_data: ?*const meta.MetaData,
) ![]SelectedProxy {
    var selections = std.ArrayList(SelectedProxy).empty;
    errdefer {
        for (selections.items) |*selection| {
            selection.deinit(allocator);
        }
        selections.deinit(allocator);
    }

    for (cfg.proxy_groups.items) |group| {
        if (group.group_type != .select) continue;

        const persisted_proxy = findPersistedSelection(&meta_data, config_key, &group);
        const selected_proxy = persisted_proxy orelse firstGroupProxy(&group);

        try appendSelectedProxy(
            allocator,
            &selections,
            group.name,
            selected_proxy,
            if (persisted_proxy != null) .persisted else .default,
        );
    }

    return selections.toOwnedSlice(allocator);
}

fn appendSelectedProxy(
    allocator: std.mem.Allocator,
    selections: *std.ArrayList(SelectedProxy),
    group_name: []const u8,
    proxy_name: ?[]const u8,
    source: SelectionSource,
) !void {
    const group_name_owned = try allocator.dupe(u8, group_name);
    errdefer allocator.free(group_name_owned);

    const proxy_name_owned = if (proxy_name) |proxy| try allocator.dupe(u8, proxy) else null;
    errdefer if (proxy_name_owned) |proxy| allocator.free(proxy);

    try selections.append(allocator, .{
        .group_name = group_name_owned,
        .proxy_name = proxy_name_owned,
        .source = source,
    });
}

fn findPersistedSelection(
    meta_data: *const ?*const meta.MetaData,
    config_key: ?[]const u8,
    group: *const config.ProxyGroup,
) ?[]const u8 {
    const key = config_key orelse return null;
    const data = meta_data.* orelse return null;
    const cm = data.configs.get(key) orelse return null;
    const proxy_name = cm.selections.get(group.name) orelse return null;
    if (!groupContainsProxy(group, proxy_name)) return null;
    return proxy_name;
}

fn firstGroupProxy(group: *const config.ProxyGroup) ?[]const u8 {
    if (group.proxies.items.len == 0) return null;
    return group.proxies.items[0];
}

fn groupContainsProxy(group: *const config.ProxyGroup, proxy_name: []const u8) bool {
    for (group.proxies.items) |candidate| {
        if (std.mem.eql(u8, candidate, proxy_name)) return true;
    }
    return false;
}

pub fn appendSelectedProxiesJson(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    selections: []const SelectedProxy,
) !void {
    // 经 std.json 序列化（真实转义），禁止手拼 JSON 字符串。
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(selections, .{ .whitespace = .minified }, &aw.writer);
    try out.appendSlice(allocator, aw.written());
}

pub fn appendSelectedProxiesText(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    selections: []const SelectedProxy,
) !void {
    if (selections.len == 0) {
        try out.appendSlice(allocator, "selected_proxies: (none)\n");
        return;
    }

    try out.appendSlice(allocator, "selected_proxies:\n");
    for (selections) |selection| {
        try out.print(allocator, "  {s}: ", .{selection.group_name});
        if (selection.proxy_name) |proxy_name| {
            try out.print(allocator, "{s}", .{proxy_name});
        } else {
            try out.appendSlice(allocator, "(none)");
        }
        try out.print(allocator, " ({s})\n", .{sourceString(selection.source)});
    }
}

pub fn printSelectedProxiesText(allocator: std.mem.Allocator, selections: []const SelectedProxy) void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    appendSelectedProxiesText(&out, allocator, selections) catch return;
    std.debug.print("{s}", .{out.items});
}

fn makeConfigWithSelectGroup(allocator: std.mem.Allocator) !config.Config {
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

    var group = config.ProxyGroup{
        .name = try allocator.dupe(u8, "Proxy"),
        .group_type = .select,
        .proxies = std.ArrayList([]const u8).empty,
    };
    errdefer group.deinit(allocator);
    try group.proxies.append(allocator, try allocator.dupe(u8, "A"));
    try group.proxies.append(allocator, try allocator.dupe(u8, "B"));
    try cfg.proxy_groups.append(allocator, group);
    return cfg;
}

test "collectSelectedProxies falls back to first select proxy" {
    const allocator = std.testing.allocator;
    var cfg = try makeConfigWithSelectGroup(allocator);
    defer cfg.deinit();

    const selections = try collectSelectedProxies(allocator, &cfg, null);
    defer deinitSelectedProxies(allocator, selections);

    try std.testing.expectEqual(@as(usize, 1), selections.len);
    try std.testing.expectEqualStrings("Proxy", selections[0].group_name);
    try std.testing.expectEqualStrings("A", selections[0].proxy_name.?);
    try std.testing.expectEqual(SelectionSource.default, selections[0].source);
}

test "collectSelectedProxies prefers valid persisted selection" {
    const allocator = std.testing.allocator;
    var cfg = try makeConfigWithSelectGroup(allocator);
    defer cfg.deinit();

    var meta_data = meta.MetaData.init(allocator);
    defer meta_data.deinit();
    var cm = meta.ConfigMeta.init(allocator);
    errdefer cm.deinit(allocator);
    try cm.selections.put(try allocator.dupe(u8, "Proxy"), try allocator.dupe(u8, "B"));
    try meta_data.configs.put(try allocator.dupe(u8, "demo"), cm);

    const selections = try collectSelectedProxiesFromMetaData(allocator, &cfg, "demo", &meta_data);
    defer deinitSelectedProxies(allocator, selections);

    try std.testing.expectEqual(@as(usize, 1), selections.len);
    try std.testing.expectEqualStrings("B", selections[0].proxy_name.?);
    try std.testing.expectEqual(SelectionSource.persisted, selections[0].source);
}

test "appendSelectedProxiesJson writes node info with frozen keys" {
    const allocator = std.testing.allocator;
    const selections = [_]SelectedProxy{
        .{
            .group_name = "Pro\"xy\n",
            .proxy_name = "B",
            .source = .persisted,
        },
        .{
            .group_name = "Auto",
            .proxy_name = null,
            .source = .default,
        },
    };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try appendSelectedProxiesJson(&out, allocator, selections[0..]);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    const items = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("Pro\"xy\n", items[0].object.get("group").?.string);
    try std.testing.expectEqualStrings("B", items[0].object.get("proxy").?.string);
    try std.testing.expectEqualStrings("persisted", items[0].object.get("source").?.string);
    try std.testing.expectEqualStrings("Auto", items[1].object.get("group").?.string);
    try std.testing.expect(items[1].object.get("proxy").? == .null);
    try std.testing.expectEqualStrings("default", items[1].object.get("source").?.string);
}

test "appendSelectedProxiesText writes shared CLI node block" {
    const allocator = std.testing.allocator;
    const selections = [_]SelectedProxy{.{
        .group_name = "Proxy",
        .proxy_name = "B",
        .source = .persisted,
    }};

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try appendSelectedProxiesText(&out, allocator, selections[0..]);

    try std.testing.expectEqualStrings(
        \\selected_proxies:
        \\  Proxy: B (persisted)
        \\
    , out.items);
}
