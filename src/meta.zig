const std = @import("std");
const config_mod = @import("config.zig");

/// 单个配置的元数据
pub const ConfigMeta = struct {
    url: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    /// 配置级持久化 override 脚本路径
    override_script: ?[]const u8 = null,
    /// URL 中的其他参数（target, emoji 等）
    params: std.StringHashMap([]const u8),
    /// 节点选择持久化（group_name → proxy_name）
    selections: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ConfigMeta {
        return .{
            .params = std.StringHashMap([]const u8).init(allocator),
            .selections = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ConfigMeta, allocator: std.mem.Allocator) void {
        if (self.url) |u| allocator.free(u);
        if (self.filename) |f| allocator.free(f);
        if (self.override_script) |s| allocator.free(s);
        {
            var it = self.params.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.params.deinit();
        }
        {
            var it = self.selections.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.selections.deinit();
        }
    }
};

/// 顶层元数据结构
pub const MetaData = struct {
    active: ?[]const u8 = null,
    configs: std.StringHashMap(ConfigMeta),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MetaData {
        return .{
            .configs = std.StringHashMap(ConfigMeta).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MetaData) void {
        if (self.active) |a| self.allocator.free(a);
        var it = self.configs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.configs.deinit();
    }
};

/// 获取 configs/ 子目录路径
pub fn getConfigsDir(allocator: std.mem.Allocator) !?[]const u8 {
    const config_dir = try config_mod.getDefaultConfigDir(allocator) orelse return null;
    defer allocator.free(config_dir);
    return try std.fs.path.join(allocator, &.{ config_dir, "configs" });
}

/// 获取 meta.json 文件路径
pub fn getMetaPath(allocator: std.mem.Allocator) !?[]const u8 {
    const config_dir = try config_mod.getDefaultConfigDir(allocator) orelse return null;
    defer allocator.free(config_dir);
    return try std.fs.path.join(allocator, &.{ config_dir, "meta.json" });
}

/// 确保 configs/ 目录存在
pub fn ensureConfigsDir(allocator: std.mem.Allocator) !void {
    const configs_dir = try getConfigsDir(allocator) orelse return;
    defer allocator.free(configs_dir);

    // 也要确保父目录存在
    const config_dir = try config_mod.getDefaultConfigDir(allocator) orelse return;
    defer allocator.free(config_dir);

    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    std.fs.makeDirAbsolute(configs_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

/// 读取 meta.json 并扫描 configs/ 补全缺失的 entry
pub fn load(allocator: std.mem.Allocator) !MetaData {
    var meta = MetaData.init(allocator);
    errdefer meta.deinit();

    const meta_path = try getMetaPath(allocator) orelse return meta;
    defer allocator.free(meta_path);

    const file = std.fs.openFileAbsolute(meta_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // meta.json 不存在，扫描 configs/ 补全
            try syncFromDisk(allocator, &meta);
            return meta;
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    if (content.len == 0) {
        try syncFromDisk(allocator, &meta);
        return meta;
    }

    // 解析 JSON
    try parseMetaJson(allocator, content, &meta);

    // 扫描 configs/ 补全
    try syncFromDisk(allocator, &meta);

    return meta;
}

/// 写入 meta.json
pub fn save(allocator: std.mem.Allocator, meta: *const MetaData) !void {
    const meta_path = try getMetaPath(allocator) orelse return;
    defer allocator.free(meta_path);

    // 确保目录存在
    try ensureConfigsDir(allocator);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");

    // active
    try buf.appendSlice(allocator, "  \"active\": ");
    if (meta.active) |active| {
        try writeJsonString(allocator, &buf, active);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\n");

    // configs
    try buf.appendSlice(allocator, "  \"configs\": {\n");
    var first = true;
    var it = meta.configs.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.appendSlice(allocator, ",\n");
        first = false;

        try buf.appendSlice(allocator, "    ");
        try writeJsonString(allocator, &buf, entry.key_ptr.*);
        try buf.appendSlice(allocator, ": {\n");

        const cm = entry.value_ptr;
        var field_first = true;

        if (cm.url) |url| {
            if (!field_first) try buf.appendSlice(allocator, ",\n");
            field_first = false;
            try buf.appendSlice(allocator, "      \"url\": ");
            try writeJsonString(allocator, &buf, url);
        }

        if (cm.filename) |fname| {
            if (!field_first) try buf.appendSlice(allocator, ",\n");
            field_first = false;
            try buf.appendSlice(allocator, "      \"filename\": ");
            try writeJsonString(allocator, &buf, fname);
        }

        if (cm.override_script) |script_path| {
            if (!field_first) try buf.appendSlice(allocator, ",\n");
            field_first = false;
            try buf.appendSlice(allocator, "      \"override_script\": ");
            try writeJsonString(allocator, &buf, script_path);
        }

        // params
        if (cm.params.count() > 0) {
            if (!field_first) try buf.appendSlice(allocator, ",\n");
            field_first = false;
            try buf.appendSlice(allocator, "      \"params\": {");
            var pfirst = true;
            var pit = cm.params.iterator();
            while (pit.next()) |pe| {
                if (!pfirst) try buf.appendSlice(allocator, ", ");
                pfirst = false;
                try writeJsonString(allocator, &buf, pe.key_ptr.*);
                try buf.appendSlice(allocator, ": ");
                try writeJsonString(allocator, &buf, pe.value_ptr.*);
            }
            try buf.appendSlice(allocator, "}");
        }

        // selections
        if (cm.selections.count() > 0) {
            if (!field_first) try buf.appendSlice(allocator, ",\n");
            field_first = false;
            try buf.appendSlice(allocator, "      \"selections\": {");
            var sfirst = true;
            var sit = cm.selections.iterator();
            while (sit.next()) |se| {
                if (!sfirst) try buf.appendSlice(allocator, ", ");
                sfirst = false;
                try writeJsonString(allocator, &buf, se.key_ptr.*);
                try buf.appendSlice(allocator, ": ");
                try writeJsonString(allocator, &buf, se.value_ptr.*);
            }
            try buf.appendSlice(allocator, "}");
        }

        try buf.appendSlice(allocator, "\n    }");
    }
    try buf.appendSlice(allocator, "\n  }\n}\n");

    const file = try std.fs.createFileAbsolute(meta_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// 扫描 configs/ 目录，为不在 meta 中的 .yaml 文件创建空 entry
pub fn syncFromDisk(allocator: std.mem.Allocator, meta: *MetaData) !void {
    const configs_dir = try getConfigsDir(allocator) orelse return;
    defer allocator.free(configs_dir);

    var dir = std.fs.openDirAbsolute(configs_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close();

    var dir_it = dir.iterate();
    while (try dir_it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".yaml")) {
            const key = entry.name[0 .. entry.name.len - 5]; // 去掉 .yaml
            if (!meta.configs.contains(key)) {
                const key_owned = try allocator.dupe(u8, key);
                var cm = ConfigMeta.init(allocator);
                try meta.configs.put(key_owned, cm);
                _ = &cm;
            }
        }
    }
}

/// 获取显示名称：filename 元数据 → 回退到 key
pub fn getDisplayName(cm: *const ConfigMeta, key: []const u8) []const u8 {
    return cm.filename orelse key;
}

/// 生成 8 位 nanoid（[a-zA-Z0-9]）
pub fn generateKey(allocator: std.mem.Allocator) ![]const u8 {
    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len) {
        var b: [1]u8 = undefined;
        std.crypto.random.bytes(&b);
        // rejection sampling: 248 可被 62 整除，避免 modulo bias
        if (b[0] >= 248) continue;
        buf[i] = charset[b[0] % charset.len];
        i += 1;
    }

    return try allocator.dupe(u8, &buf);
}

/// 解析 URL query string 参数
pub fn parseUrlParams(allocator: std.mem.Allocator, url: []const u8) !std.StringHashMap([]const u8) {
    var params = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = params.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        params.deinit();
    }

    // 找到 ? 之后的 query string
    const qmark = std.mem.indexOfScalar(u8, url, '?') orelse return params;
    const query = url[qmark + 1 ..];

    // 分割 & 号
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            const key = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];
            if (key.len > 0) {
                const key_owned = try allocator.dupe(u8, key);
                const value_owned = try allocator.dupe(u8, value);
                try params.put(key_owned, value_owned);
            }
        }
    }

    return params;
}

/// 从 meta 中设置某个配置的 selection
pub fn setSelection(allocator: std.mem.Allocator, meta: *MetaData, config_key: []const u8, group_name: []const u8, proxy_name: []const u8) !void {
    const entry = meta.configs.getPtr(config_key) orelse return;

    // 如果已存在，先释放旧值
    if (entry.selections.fetchRemove(group_name)) |removed| {
        allocator.free(removed.key);
        allocator.free(removed.value);
    }

    const gn = try allocator.dupe(u8, group_name);
    const pn = try allocator.dupe(u8, proxy_name);
    try entry.selections.put(gn, pn);
}

/// 获取当前活跃配置的 selections
pub fn getActiveSelections(allocator: std.mem.Allocator, meta: *const MetaData) !?*const std.StringHashMap([]const u8) {
    _ = allocator;
    const active = meta.active orelse return null;
    const entry = meta.configs.getPtr(active) orelse return null;
    return &entry.selections;
}

// ── JSON 解析辅助 ──

fn writeJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

/// 简单 JSON 解析器——只解析 meta.json 的特定结构
fn parseMetaJson(allocator: std.mem.Allocator, content: []const u8, meta: *MetaData) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidMetaJson;

    if (root.object.get("active")) |active_val| {
        switch (active_val) {
            .null => meta.active = null,
            .string => |s| meta.active = try allocator.dupe(u8, s),
            else => return error.InvalidMetaJson,
        }
    }

    const configs_val = root.object.get("configs") orelse return;
    if (configs_val != .object) return error.InvalidMetaJson;

    var it = configs_val.object.iterator();
    while (it.next()) |entry| {
        const config_key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(config_key);

        var cm = ConfigMeta.init(allocator);
        errdefer cm.deinit(allocator);

        if (entry.value_ptr.* != .object) return error.InvalidMetaJson;
        const obj = entry.value_ptr.object;

        if (obj.get("url")) |url_val| {
            switch (url_val) {
                .null => {},
                .string => |s| cm.url = try allocator.dupe(u8, s),
                else => return error.InvalidMetaJson,
            }
        }

        if (obj.get("filename")) |filename_val| {
            switch (filename_val) {
                .null => {},
                .string => |s| cm.filename = try allocator.dupe(u8, s),
                else => return error.InvalidMetaJson,
            }
        }

        if (obj.get("override_script")) |override_val| {
            switch (override_val) {
                .null => {},
                .string => |s| cm.override_script = try allocator.dupe(u8, s),
                else => return error.InvalidMetaJson,
            }
        }

        if (obj.get("params")) |params_val| {
            if (params_val != .object) return error.InvalidMetaJson;
            var pit = params_val.object.iterator();
            while (pit.next()) |pe| {
                if (pe.value_ptr.* != .string) return error.InvalidMetaJson;
                try cm.params.put(
                    try allocator.dupe(u8, pe.key_ptr.*),
                    try allocator.dupe(u8, pe.value_ptr.string),
                );
            }
        }

        if (obj.get("selections")) |selections_val| {
            if (selections_val != .object) return error.InvalidMetaJson;
            var sit = selections_val.object.iterator();
            while (sit.next()) |se| {
                if (se.value_ptr.* != .string) return error.InvalidMetaJson;
                try cm.selections.put(
                    try allocator.dupe(u8, se.key_ptr.*),
                    try allocator.dupe(u8, se.value_ptr.string),
                );
            }
        }

        try meta.configs.put(config_key, cm);
    }
}

const JsonParser = struct {
    data: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    fn skipWhitespace(self: *JsonParser) void {
        while (self.pos < self.data.len and (self.data[self.pos] == ' ' or self.data[self.pos] == '\t' or self.data[self.pos] == '\n' or self.data[self.pos] == '\r')) {
            self.pos += 1;
        }
    }

    fn expect(self: *JsonParser, c: u8) !void {
        self.skipWhitespace();
        if (self.pos >= self.data.len or self.data[self.pos] != c) return error.UnexpectedToken;
        self.pos += 1;
    }

    fn peek(self: *JsonParser) ?u8 {
        self.skipWhitespace();
        if (self.pos >= self.data.len) return null;
        return self.data[self.pos];
    }

    fn parseString(self: *JsonParser) ![]const u8 {
        self.skipWhitespace();
        if (self.pos >= self.data.len or self.data[self.pos] != '"') return error.ExpectedString;
        self.pos += 1;

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        while (self.pos < self.data.len and self.data[self.pos] != '"') {
            if (self.data[self.pos] == '\\' and self.pos + 1 < self.data.len) {
                self.pos += 1;
                switch (self.data[self.pos]) {
                    '"' => try buf.append(self.allocator, '"'),
                    '\\' => try buf.append(self.allocator, '\\'),
                    'n' => try buf.append(self.allocator, '\n'),
                    'r' => try buf.append(self.allocator, '\r'),
                    't' => try buf.append(self.allocator, '\t'),
                    '/' => try buf.append(self.allocator, '/'),
                    else => try buf.append(self.allocator, self.data[self.pos]),
                }
            } else {
                try buf.append(self.allocator, self.data[self.pos]);
            }
            self.pos += 1;
        }

        if (self.pos >= self.data.len) return error.UnterminatedString;
        self.pos += 1; // skip closing "

        return try self.allocator.dupe(u8, buf.items);
    }

    fn parseNull(self: *JsonParser) !void {
        self.skipWhitespace();
        if (self.pos + 4 <= self.data.len and std.mem.eql(u8, self.data[self.pos .. self.pos + 4], "null")) {
            self.pos += 4;
            return;
        }
        return error.ExpectedNull;
    }

    fn skipValue(self: *JsonParser) !void {
        self.skipWhitespace();
        if (self.pos >= self.data.len) return error.UnexpectedEof;

        switch (self.data[self.pos]) {
            '"' => {
                const s = try self.parseString();
                self.allocator.free(s);
            },
            '{' => {
                self.pos += 1;
                if (self.peek() == '}') {
                    self.pos += 1;
                    return;
                }
                while (true) {
                    const k = try self.parseString();
                    self.allocator.free(k);
                    try self.expect(':');
                    try self.skipValue();
                    self.skipWhitespace();
                    if (self.pos < self.data.len and self.data[self.pos] == ',') {
                        self.pos += 1;
                        continue;
                    }
                    break;
                }
                try self.expect('}');
            },
            '[' => {
                self.pos += 1;
                if (self.peek() == ']') {
                    self.pos += 1;
                    return;
                }
                while (true) {
                    try self.skipValue();
                    self.skipWhitespace();
                    if (self.pos < self.data.len and self.data[self.pos] == ',') {
                        self.pos += 1;
                        continue;
                    }
                    break;
                }
                try self.expect(']');
            },
            'n' => try self.parseNull(),
            't' => {
                if (self.pos + 4 <= self.data.len) self.pos += 4;
            },
            'f' => {
                if (self.pos + 5 <= self.data.len) self.pos += 5;
            },
            else => {
                // number
                while (self.pos < self.data.len and (self.data[self.pos] == '-' or self.data[self.pos] == '+' or self.data[self.pos] == '.' or (self.data[self.pos] >= '0' and self.data[self.pos] <= '9') or self.data[self.pos] == 'e' or self.data[self.pos] == 'E')) {
                    self.pos += 1;
                }
            },
        }
    }

    fn parseStringMap(self: *JsonParser) !std.StringHashMap([]const u8) {
        var map = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            map.deinit();
        }

        try self.expect('{');
        if (self.peek() == '}') {
            self.pos += 1;
            return map;
        }

        while (true) {
            const key = try self.parseString();
            try self.expect(':');
            const value = try self.parseString();
            try map.put(key, value);

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            break;
        }

        try self.expect('}');
        return map;
    }

    fn parseConfigMeta(self: *JsonParser) !ConfigMeta {
        var cm = ConfigMeta.init(self.allocator);
        errdefer cm.deinit(self.allocator);

        try self.expect('{');
        if (self.peek() == '}') {
            self.pos += 1;
            return cm;
        }

        while (true) {
            const field_name = try self.parseString();
            defer self.allocator.free(field_name);
            try self.expect(':');

            if (std.mem.eql(u8, field_name, "url")) {
                if (self.peek() == 'n') {
                    try self.parseNull();
                } else {
                    cm.url = try self.parseString();
                }
            } else if (std.mem.eql(u8, field_name, "filename")) {
                if (self.peek() == 'n') {
                    try self.parseNull();
                } else {
                    cm.filename = try self.parseString();
                }
            } else if (std.mem.eql(u8, field_name, "override_script")) {
                if (self.peek() == 'n') {
                    try self.parseNull();
                } else {
                    cm.override_script = try self.parseString();
                }
            } else if (std.mem.eql(u8, field_name, "params")) {
                var old_params = cm.params;
                cm.params = try self.parseStringMap();
                old_params.deinit();
            } else if (std.mem.eql(u8, field_name, "selections")) {
                var old_sel = cm.selections;
                cm.selections = try self.parseStringMap();
                old_sel.deinit();
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            break;
        }

        try self.expect('}');
        return cm;
    }

    fn parseRoot(self: *JsonParser, meta: *MetaData) !void {
        try self.expect('{');

        if (self.peek() == '}') {
            self.pos += 1;
            return;
        }

        while (true) {
            const key = try self.parseString();
            defer self.allocator.free(key);
            try self.expect(':');

            if (std.mem.eql(u8, key, "active")) {
                if (self.peek() == 'n') {
                    try self.parseNull();
                    meta.active = null;
                } else {
                    meta.active = try self.parseString();
                }
            } else if (std.mem.eql(u8, key, "configs")) {
                try self.expect('{');
                if (self.peek() != '}') {
                    while (true) {
                        const config_key = try self.parseString();
                        try self.expect(':');
                        var cm = try self.parseConfigMeta();
                        errdefer cm.deinit(self.allocator);
                        try meta.configs.put(config_key, cm);

                        self.skipWhitespace();
                        if (self.pos < self.data.len and self.data[self.pos] == ',') {
                            self.pos += 1;
                            continue;
                        }
                        break;
                    }
                }
                try self.expect('}');
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            break;
        }

        try self.expect('}');
    }
};

// ── Tests ──

test "generateKey produces 8-char alphanumeric" {
    const allocator = std.testing.allocator;
    const key = try generateKey(allocator);
    defer allocator.free(key);
    try std.testing.expectEqual(@as(usize, 8), key.len);
    for (key) |c| {
        try std.testing.expect((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'));
    }
}

test "parseUrlParams extracts query params" {
    const allocator = std.testing.allocator;
    var params = try parseUrlParams(allocator, "https://api.example.com/sub?target=clash&filename=Flower_SS.yaml&emoji=true");
    defer {
        var it = params.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        params.deinit();
    }

    try std.testing.expectEqualStrings("clash", params.get("target").?);
    try std.testing.expectEqualStrings("Flower_SS.yaml", params.get("filename").?);
    try std.testing.expectEqualStrings("true", params.get("emoji").?);
}

test "parseUrlParams handles no query string" {
    const allocator = std.testing.allocator;
    var params = try parseUrlParams(allocator, "https://example.com/sub");
    defer params.deinit();
    try std.testing.expectEqual(@as(u32, 0), params.count());
}

test "getDisplayName returns filename or key" {
    var allocator = std.testing.allocator;
    var cm = ConfigMeta.init(allocator);
    defer cm.deinit(allocator);

    // No filename → return key
    try std.testing.expectEqualStrings("mykey", getDisplayName(&cm, "mykey"));

    // Has filename → return filename
    cm.filename = try allocator.dupe(u8, "Flower_SS.yaml");
    try std.testing.expectEqualStrings("Flower_SS.yaml", getDisplayName(&cm, "mykey"));
}

test "meta json round trip" {
    const allocator = std.testing.allocator;

    var meta = MetaData.init(allocator);
    defer meta.deinit();

    meta.active = try allocator.dupe(u8, "V1StGXR8");

    var cm = ConfigMeta.init(allocator);
    cm.url = try allocator.dupe(u8, "https://example.com/sub?target=clash");
    cm.filename = try allocator.dupe(u8, "Flower_SS.yaml");
    {
        const gn = try allocator.dupe(u8, "Proxy");
        const pn = try allocator.dupe(u8, "HK-Node-01");
        try cm.selections.put(gn, pn);
    }

    const key = try allocator.dupe(u8, "V1StGXR8");
    try meta.configs.put(key, cm);

    // Serialize
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    try buf.appendSlice(allocator, "  \"active\": ");
    try writeJsonString(allocator, &buf, meta.active.?);
    try buf.appendSlice(allocator, ",\n");
    try buf.appendSlice(allocator, "  \"configs\": {\n");

    var it = meta.configs.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try buf.appendSlice(allocator, ",\n");
        first = false;
        try buf.appendSlice(allocator, "    ");
        try writeJsonString(allocator, &buf, entry.key_ptr.*);
        try buf.appendSlice(allocator, ": {\"url\": ");
        try writeJsonString(allocator, &buf, entry.value_ptr.url.?);
        try buf.appendSlice(allocator, ", \"filename\": ");
        try writeJsonString(allocator, &buf, entry.value_ptr.filename.?);
        try buf.appendSlice(allocator, "}");
    }
    try buf.appendSlice(allocator, "\n  }\n}\n");

    // Parse back
    var meta2 = MetaData.init(allocator);
    defer meta2.deinit();
    try parseMetaJson(allocator, buf.items, &meta2);

    try std.testing.expectEqualStrings("V1StGXR8", meta2.active.?);
    try std.testing.expect(meta2.configs.contains("V1StGXR8"));
    const cm2 = meta2.configs.get("V1StGXR8").?;
    try std.testing.expectEqualStrings("https://example.com/sub?target=clash", cm2.url.?);
    try std.testing.expectEqualStrings("Flower_SS.yaml", cm2.filename.?);
}

test "parseMetaJson decodes unicode escape sequences" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "active": "abc12345",
        \\  "configs": {
        \\    "abc12345": {
        \\      "filename": "A\u003cB.yaml"
        \\    }
        \\  }
        \\}
    ;

    var meta = MetaData.init(allocator);
    defer meta.deinit();

    try parseMetaJson(allocator, payload, &meta);
    const cm = meta.configs.get("abc12345").?;
    try std.testing.expectEqualStrings("A<B.yaml", cm.filename.?);
}
