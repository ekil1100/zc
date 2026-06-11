const std = @import("std");
const compat = @import("compat.zig");
const config = @import("config.zig");
const yaml = @import("util/yaml.zig");

pub const OverrideArg = struct {
    key: []u8,
    value: []u8,
};

pub const CliOptions = struct {
    script_path: ?[]u8 = null,
    timeout_ms: u32 = 500,
    args: std.ArrayList(OverrideArg) = .empty,

    pub fn deinit(self: *CliOptions, allocator: std.mem.Allocator) void {
        if (self.script_path) |p| allocator.free(p);
        for (self.args.items) |arg| {
            allocator.free(arg.key);
            allocator.free(arg.value);
        }
        self.args.deinit(allocator);
    }

    pub fn appendForwardArgs(self: *const CliOptions, allocator: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
        if (self.script_path) |script| {
            try out.append(allocator, try allocator.dupe(u8, "--override-script"));
            try out.append(allocator, try allocator.dupe(u8, script));
        }
        for (self.args.items) |arg| {
            const kv = try std.fmt.allocPrint(allocator, "{s}={s}", .{ arg.key, arg.value });
            try out.append(allocator, try allocator.dupe(u8, "--override-arg"));
            try out.append(allocator, kv);
        }
        if (self.timeout_ms != 500) {
            try out.append(allocator, try allocator.dupe(u8, "--override-timeout-ms"));
            try out.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{self.timeout_ms}));
        }
    }
};

pub const Errors = error{
    MissingOverrideScriptPath,
    InvalidOverrideTimeout,
    MissingOverrideArg,
    InvalidOverrideArg,
    OverrideScriptNotFound,
    OverrideScriptExecFailed,
    OverrideScriptTimeout,
    OverrideOutputInvalid,
    OverrideMergeFailed,
    DeprecatedOverrideDumpOption,
};

pub fn parseCliOptions(allocator: std.mem.Allocator, args: []const []const u8) !CliOptions {
    var opts = CliOptions{};
    errdefer opts.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--override-script")) {
            if (i + 1 >= args.len) return Errors.MissingOverrideScriptPath;
            i += 1;
            if (opts.script_path) |old| allocator.free(old);
            opts.script_path = try allocator.dupe(u8, args[i]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--override-script=")) {
            const value = arg["--override-script=".len..];
            if (value.len == 0) return Errors.MissingOverrideScriptPath;
            if (opts.script_path) |old| allocator.free(old);
            opts.script_path = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--override-timeout-ms")) {
            if (i + 1 >= args.len) return Errors.InvalidOverrideTimeout;
            i += 1;
            opts.timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch return Errors.InvalidOverrideTimeout;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--override-timeout-ms=")) {
            const value = arg["--override-timeout-ms=".len..];
            opts.timeout_ms = std.fmt.parseInt(u32, value, 10) catch return Errors.InvalidOverrideTimeout;
            continue;
        }

        if (std.mem.eql(u8, arg, "--override-arg")) {
            if (i + 1 >= args.len) return Errors.MissingOverrideArg;
            i += 1;
            const pair = try parseOverrideArg(allocator, args[i]);
            try opts.args.append(allocator, pair);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--override-arg=")) {
            const pair = try parseOverrideArg(allocator, arg["--override-arg=".len..]);
            try opts.args.append(allocator, pair);
            continue;
        }

        if (std.mem.eql(u8, arg, "--override-dump-json") or std.mem.eql(u8, arg, "--override-dump-yaml")) {
            return Errors.DeprecatedOverrideDumpOption;
        }
    }

    return opts;
}

fn parseOverrideArg(allocator: std.mem.Allocator, pair: []const u8) !OverrideArg {
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return Errors.InvalidOverrideArg;
    const key = std.mem.trim(u8, pair[0..eq], " \t");
    const value = pair[eq + 1 ..];
    if (key.len == 0) return Errors.InvalidOverrideArg;
    return .{
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
    };
}

pub fn apply(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    opts: *const CliOptions,
    command_name: []const u8,
    config_path: ?[]const u8,
) !void {
    if (opts.script_path) |script_path| {
        const patch_text = try executeOverrideScript(allocator, script_path, opts, command_name, config_path);
        defer allocator.free(patch_text);

        const trimmed = std.mem.trim(u8, patch_text, " \t\r\n");
        if (trimmed.len > 0) {
            var root = yaml.parse(allocator, trimmed) catch return Errors.OverrideOutputInvalid;
            defer root.deinit(allocator);
            if (root != .map) return Errors.OverrideOutputInvalid;
            applyMapOverride(allocator, cfg, &root.map) catch return Errors.OverrideMergeFailed;
        }
    }
}

fn executeOverrideScript(
    allocator: std.mem.Allocator,
    script_path: []const u8,
    opts: *const CliOptions,
    command_name: []const u8,
    config_path: ?[]const u8,
) ![]u8 {
    var env_map = try std.process.Environ.empty.createMap(allocator);
    defer env_map.deinit();

    try env_map.put("ZC_OVERRIDE_COMMAND", command_name);
    if (config_path) |p| {
        try env_map.put("ZC_OVERRIDE_CONFIG_PATH", p);
    } else {
        try env_map.put("ZC_OVERRIDE_CONFIG_PATH", "");
    }
    try env_map.put("ZC_OVERRIDE_SCRIPT_PATH", script_path);
    const timeout_text = try std.fmt.allocPrint(allocator, "{d}", .{opts.timeout_ms});
    defer allocator.free(timeout_text);
    try env_map.put("ZC_OVERRIDE_TIMEOUT_MS", timeout_text);

    var args_buf = std.ArrayList(u8).empty;
    defer args_buf.deinit(allocator);
    for (opts.args.items, 0..) |arg, idx| {
        if (idx > 0) try args_buf.append(allocator, ';');
        try args_buf.appendSlice(allocator, arg.key);
        try args_buf.append(allocator, '=');
        try args_buf.appendSlice(allocator, arg.value);

        const env_key = try sanitizeEnvKey(allocator, arg.key);
        defer allocator.free(env_key);
        const full_key = try std.fmt.allocPrint(allocator, "ZC_OVERRIDE_ARG_{s}", .{env_key});
        defer allocator.free(full_key);
        try env_map.put(full_key, arg.value);
    }
    try env_map.put("ZC_OVERRIDE_ARGS", args_buf.items);

    if (std.mem.endsWith(u8, script_path, ".lua")) {
        const wrapper = luaWrapper();
        const lua_candidates = [_][]const u8{
            "/opt/homebrew/bin/luajit",
            "luajit",
            "lua",
        };
        for (lua_candidates) |lua_cmd| {
            var argv = std.ArrayList([]const u8).empty;
            defer argv.deinit(allocator);
            try argv.append(allocator, lua_cmd);
            try argv.append(allocator, "-e");
            try argv.append(allocator, wrapper);
            try argv.append(allocator, "--");
            try argv.append(allocator, script_path);

            const out = runCommandWithTimeout(allocator, argv.items, &env_map, opts.timeout_ms) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return mapRunError(err),
            };
            return out;
        }
        return Errors.OverrideScriptNotFound;
    }

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, script_path);
    const out = runCommandWithTimeout(allocator, argv.items, &env_map, opts.timeout_ms) catch |err| return mapRunError(err);
    return out;
}

fn mapRunError(err: anyerror) anyerror {
    return switch (err) {
        error.OverrideScriptTimeout => Errors.OverrideScriptTimeout,
        error.FileNotFound => Errors.OverrideScriptNotFound,
        error.OverrideScriptExecFailed => Errors.OverrideScriptExecFailed,
        else => Errors.OverrideScriptExecFailed,
    };
}

fn runCommandWithTimeout(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: *const std.process.Environ.Map,
    timeout_ms: u32,
) ![]u8 {
    _ = timeout_ms;
    const result = try std.process.run(allocator, compat.io(), .{
        .argv = argv,
        .environ_map = env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .nothing,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return error.OverrideScriptExecFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.OverrideScriptExecFailed;
        },
    }

    return result.stdout;
}

fn timeoutThread(
    child: *std.process.Child,
    done: *std.atomic.Value(bool),
    timed_out: *std.atomic.Value(bool),
    timeout_ms: u32,
) void {
    if (timeout_ms == 0) return;
    compat.sleepNs(@as(u64, timeout_ms) * std.time.ns_per_ms);
    if (!done.load(.seq_cst)) {
        timed_out.store(true, .seq_cst);
        _ = child.kill() catch {};
    }
}

fn sanitizeEnvKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (key) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
            try out.append(allocator, std.ascii.toUpper(c));
        } else {
            try out.append(allocator, '_');
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn luaWrapper() []const u8 {
    return
    \\local function parse_args(raw)
    \\  local out = {}
    \\  if not raw or raw == "" then return out end
    \\  for part in string.gmatch(raw, "([^;]+)") do
    \\    local eq = string.find(part, "=", 1, true)
    \\    if eq then
    \\      local k = string.sub(part, 1, eq - 1)
    \\      local v = string.sub(part, eq + 1)
    \\      out[k] = v
    \\    end
    \\  end
    \\  return out
    \\end
    \\
    \\input = {
    \\  command = os.getenv("ZC_OVERRIDE_COMMAND"),
    \\  config_path = os.getenv("ZC_OVERRIDE_CONFIG_PATH"),
    \\  script_path = os.getenv("ZC_OVERRIDE_SCRIPT_PATH"),
    \\  args = parse_args(os.getenv("ZC_OVERRIDE_ARGS")),
    \\}
    \\
    \\local function esc(s)
    \\  s = tostring(s)
    \\  s = string.gsub(s, "\\", "\\\\")
    \\  s = string.gsub(s, "\"", "\\\"")
    \\  return "\"" .. s .. "\""
    \\end
    \\
    \\local function scalar(v)
    \\  local t = type(v)
    \\  if t == "boolean" then
    \\    return v and "true" or "false"
    \\  elseif t == "number" then
    \\    return tostring(v)
    \\  elseif t == "nil" then
    \\    return "null"
    \\  else
    \\    return esc(v)
    \\  end
    \\end
    \\
    \\local function is_array(t)
    \\  local max = 0
    \\  for k, _ in pairs(t) do
    \\    if type(k) ~= "number" then return false end
    \\    if k > max then max = k end
    \\  end
    \\  for i = 1, max do
    \\    if t[i] == nil then return false end
    \\  end
    \\  return true
    \\end
    \\
    \\local function emit(v, indent, key)
    \\  local pad = string.rep(" ", indent)
    \\  local child_indent = indent
    \\  local t = type(v)
    \\
    \\  if key ~= nil then
    \\    if t == "table" then
    \\      io.write(pad .. key .. ":\n")
    \\      child_indent = indent + 2
    \\      pad = string.rep(" ", child_indent)
    \\    else
    \\      io.write(pad .. key .. ": " .. scalar(v) .. "\n")
    \\      return
    \\    end
    \\  end
    \\
    \\  if t ~= "table" then
    \\    io.write(pad .. scalar(v) .. "\n")
    \\    return
    \\  end
    \\
    \\  if is_array(v) then
    \\    for _, item in ipairs(v) do
    \\      if type(item) == "table" then
    \\        io.write(pad .. "-\n")
    \\        emit(item, child_indent + 2, nil)
    \\      else
    \\        io.write(pad .. "- " .. scalar(item) .. "\n")
    \\      end
    \\    end
    \\    return
    \\  end
    \\
    \\  for mk, mv in pairs(v) do
    \\    if type(mk) == "string" then
    \\      emit(mv, child_indent, mk)
    \\    end
    \\  end
    \\end
    \\
    \\local script = arg[1]
    \\if (not script) and arg[0] and string.match(arg[0], "%.lua$") then
    \\  script = arg[0]
    \\end
    \\if not script then
    \\  io.stderr:write("missing lua script path")
    \\  os.exit(2)
    \\end
    \\
    \\local f, ferr = loadfile(script)
    \\if not f then
    \\  io.stderr:write(ferr or "failed to load script")
    \\  os.exit(2)
    \\end
    \\
    \\local ok, result = pcall(f)
    \\if not ok then
    \\  io.stderr:write(result or "script failed")
    \\  os.exit(3)
    \\end
    \\
    \\if result == nil then
    \\  os.exit(0)
    \\end
    \\if type(result) ~= "table" then
    \\  io.stderr:write("override script must return table or nil")
    \\  os.exit(4)
    \\end
    \\
    \\emit(result, 0, nil)
    ;
}

fn applyMapOverride(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    m: *const std.StringHashMap(yaml.YamlValue),
) !void {
    var it = m.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "port")) {
            cfg.port = try decodePort(value);
            continue;
        }
        if (std.mem.eql(u8, key, "socks-port")) {
            cfg.socks_port = try decodePort(value);
            continue;
        }
        if (std.mem.eql(u8, key, "mixed-port")) {
            cfg.mixed_port = try decodePort(value);
            continue;
        }
        if (std.mem.eql(u8, key, "allow-lan")) {
            cfg.allow_lan = switch (value) {
                .boolean => |b| b,
                else => return Errors.OverrideOutputInvalid,
            };
            continue;
        }
        if (std.mem.eql(u8, key, "bind-address")) {
            const s = switch (value) {
                .string => |v| v,
                else => return Errors.OverrideOutputInvalid,
            };
            cfg.allocator.free(cfg.bind_address);
            cfg.bind_address = try cfg.allocator.dupe(u8, s);
            continue;
        }
        if (std.mem.eql(u8, key, "mode")) {
            const s = switch (value) {
                .string => |v| v,
                else => return Errors.OverrideOutputInvalid,
            };
            cfg.allocator.free(cfg.mode);
            cfg.mode = try cfg.allocator.dupe(u8, s);
            continue;
        }
        if (std.mem.eql(u8, key, "log-level")) {
            const s = switch (value) {
                .string => |v| v,
                else => return Errors.OverrideOutputInvalid,
            };
            cfg.allocator.free(cfg.log_level);
            cfg.log_level = try cfg.allocator.dupe(u8, s);
            continue;
        }
        if (std.mem.eql(u8, key, "external-controller")) {
            if (cfg.external_controller) |old| cfg.allocator.free(old);
            switch (value) {
                .null => cfg.external_controller = null,
                .string => |v| {
                    if (std.mem.eql(u8, v, "null")) {
                        cfg.external_controller = null;
                    } else {
                        cfg.external_controller = try cfg.allocator.dupe(u8, v);
                    }
                },
                else => return Errors.OverrideOutputInvalid,
            }
            continue;
        }
        if (std.mem.eql(u8, key, "proxies")) {
            var tmp = try parseSingleFieldOverride(allocator, "proxies", value);
            defer releaseTempConfig(&tmp);
            moveProxies(cfg, &tmp);
            continue;
        }
        if (std.mem.eql(u8, key, "proxy-groups")) {
            var tmp = try parseSingleFieldOverride(allocator, "proxy-groups", value);
            defer releaseTempConfig(&tmp);
            moveProxyGroups(cfg, &tmp);
            continue;
        }
        if (std.mem.eql(u8, key, "rule-providers")) {
            var tmp = try parseSingleFieldOverride(allocator, "rule-providers", value);
            defer releaseTempConfig(&tmp);
            moveRuleProviders(cfg, &tmp);
            continue;
        }
        if (std.mem.eql(u8, key, "rules")) {
            var tmp = try parseSingleFieldOverride(allocator, "rules", value);
            defer releaseTempConfig(&tmp);
            moveRules(cfg, &tmp);
            continue;
        }

        return Errors.OverrideOutputInvalid;
    }
}

fn decodePort(value: yaml.YamlValue) !u16 {
    return switch (value) {
        .integer => |v| blk: {
            if (v < 0 or v > 65535) return Errors.OverrideOutputInvalid;
            break :blk @as(u16, @intCast(v));
        },
        else => Errors.OverrideOutputInvalid,
    };
}

fn parseSingleFieldOverride(allocator: std.mem.Allocator, field: []const u8, value: yaml.YamlValue) !config.Config {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, field);
    switch (value) {
        .null, .boolean, .integer, .string => {
            try out.appendSlice(allocator, ": ");
            try writeYamlScalar(&out, allocator, value);
            try out.append(allocator, '\n');
        },
        else => {
            try out.appendSlice(allocator, ":\n");
            try writeYamlValue(&out, allocator, &value, 2);
        },
    }

    return config.parse(allocator, out.items) catch Errors.OverrideOutputInvalid;
}

fn releaseTempConfig(tmp: *config.Config) void {
    tmp.deinit();
}

fn moveProxies(dst: *config.Config, src: *config.Config) void {
    for (dst.proxies.items) |*item| item.deinit(dst.allocator);
    dst.proxies.deinit(dst.allocator);
    dst.proxies = src.proxies;
    src.proxies = .empty;
}

fn moveProxyGroups(dst: *config.Config, src: *config.Config) void {
    for (dst.proxy_groups.items) |*item| item.deinit(dst.allocator);
    dst.proxy_groups.deinit(dst.allocator);
    dst.proxy_groups = src.proxy_groups;
    src.proxy_groups = .empty;
}

fn moveRuleProviders(dst: *config.Config, src: *config.Config) void {
    for (dst.rule_providers.items) |*item| item.deinit(dst.allocator);
    dst.rule_providers.deinit(dst.allocator);
    dst.rule_providers = src.rule_providers;
    src.rule_providers = .empty;
}

fn moveRules(dst: *config.Config, src: *config.Config) void {
    for (dst.rules.items) |*item| item.deinit(dst.allocator);
    dst.rules.deinit(dst.allocator);
    dst.rules = src.rules;
    src.rules = .empty;
}

fn appendIndent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try out.append(allocator, ' ');
}

fn writeYamlScalar(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: yaml.YamlValue) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |n| try out.print(allocator, "{d}", .{n}),
        .string => |s| try writeYamlQuotedString(out, allocator, s),
        .array, .map => return Errors.OverrideOutputInvalid,
    }
}

fn writeYamlValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: *const yaml.YamlValue, indent: usize) !void {
    switch (value.*) {
        .map => |*m| {
            var it = m.iterator();
            while (it.next()) |entry| {
                try appendIndent(out, allocator, indent);
                try out.appendSlice(allocator, entry.key_ptr.*);
                switch (entry.value_ptr.*) {
                    .array, .map => {
                        try out.appendSlice(allocator, ":\n");
                        try writeYamlValue(out, allocator, entry.value_ptr, indent + 2);
                    },
                    else => {
                        try out.appendSlice(allocator, ": ");
                        try writeYamlScalar(out, allocator, entry.value_ptr.*);
                        try out.append(allocator, '\n');
                    },
                }
            }
        },
        .array => |*arr| {
            for (arr.items) |*item| {
                try appendIndent(out, allocator, indent);
                switch (item.*) {
                    .array, .map => {
                        try out.appendSlice(allocator, "-\n");
                        try writeYamlValue(out, allocator, item, indent + 2);
                    },
                    else => {
                        try out.appendSlice(allocator, "- ");
                        try writeYamlScalar(out, allocator, item.*);
                        try out.append(allocator, '\n');
                    },
                }
            }
        },
        else => {
            try appendIndent(out, allocator, indent);
            try writeYamlScalar(out, allocator, value.*);
            try out.append(allocator, '\n');
        },
    }
}

fn writeYamlQuotedString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

pub fn dumpConfigYaml(allocator: std.mem.Allocator, cfg: *const config.Config) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.print(allocator, "port: {d}\n", .{cfg.port});
    try out.print(allocator, "socks-port: {d}\n", .{cfg.socks_port});
    try out.print(allocator, "mixed-port: {d}\n", .{cfg.mixed_port});
    try out.print(allocator, "allow-lan: {s}\n", .{if (cfg.allow_lan) "true" else "false"});
    try out.appendSlice(allocator, "bind-address: ");
    try writeYamlQuotedString(&out, allocator, cfg.bind_address);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "mode: ");
    try writeYamlQuotedString(&out, allocator, cfg.mode);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "log-level: ");
    try writeYamlQuotedString(&out, allocator, cfg.log_level);
    try out.append(allocator, '\n');
    if (cfg.external_controller) |ec| {
        try out.appendSlice(allocator, "external-controller: ");
        try writeYamlQuotedString(&out, allocator, ec);
        try out.append(allocator, '\n');
    }
    if (cfg.secret != null) {
        try out.appendSlice(allocator, "secret: \"******\"\n");
    }

    if (cfg.rule_providers.items.len > 0) {
        try out.appendSlice(allocator, "rule-providers:\n");
        for (cfg.rule_providers.items) |provider| {
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, provider.name);
            try out.appendSlice(allocator, ":\n");
            try out.appendSlice(allocator, "    type: ");
            try writeYamlQuotedString(&out, allocator, provider.provider_type);
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, "    behavior: ");
            try writeYamlQuotedString(&out, allocator, ruleProviderBehaviorString(provider.behavior));
            try out.append(allocator, '\n');
            if (provider.url) |url| {
                try out.appendSlice(allocator, "    url: ");
                try writeYamlQuotedString(&out, allocator, url);
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, "    path: ");
            try writeYamlQuotedString(&out, allocator, provider.path);
            try out.append(allocator, '\n');
            try out.print(allocator, "    interval: {d}\n", .{provider.interval});
        }
    }

    try out.appendSlice(allocator, "proxies:\n");
    for (cfg.proxies.items) |proxy| {
        try out.appendSlice(allocator, "  - name: ");
        try writeYamlQuotedString(&out, allocator, proxy.name);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, "    type: ");
        try writeYamlQuotedString(&out, allocator, proxyTypeString(proxy.proxy_type));
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, "    server: ");
        try writeYamlQuotedString(&out, allocator, proxy.server);
        try out.append(allocator, '\n');
        try out.print(allocator, "    port: {d}\n", .{proxy.port});
        if (proxy.password != null) try out.appendSlice(allocator, "    password: \"******\"\n");
        if (proxy.cipher) |cipher| {
            try out.appendSlice(allocator, "    cipher: ");
            try writeYamlQuotedString(&out, allocator, cipher);
            try out.append(allocator, '\n');
        }
        if (proxy.uuid != null) try out.appendSlice(allocator, "    uuid: \"******\"\n");
        if (proxy.alter_id != 0) try out.print(allocator, "    alterId: {d}\n", .{proxy.alter_id});
        if (proxy.tls) try out.appendSlice(allocator, "    tls: true\n");
        if (proxy.skip_cert_verify) try out.appendSlice(allocator, "    skip-cert-verify: true\n");
        if (proxy.sni != null) try out.appendSlice(allocator, "    sni: \"******\"\n");
        if (proxy.ws) try out.appendSlice(allocator, "    ws: true\n");
        if (proxy.ws_path) |ws_path| {
            try out.appendSlice(allocator, "    ws-path: ");
            try writeYamlQuotedString(&out, allocator, ws_path);
            try out.append(allocator, '\n');
        }
        if (proxy.ws_host) |ws_host| {
            try out.appendSlice(allocator, "    ws-host: ");
            try writeYamlQuotedString(&out, allocator, ws_host);
            try out.append(allocator, '\n');
        }
    }

    try out.appendSlice(allocator, "proxy-groups:\n");
    for (cfg.proxy_groups.items) |group| {
        try out.appendSlice(allocator, "  - name: ");
        try writeYamlQuotedString(&out, allocator, group.name);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, "    type: ");
        try writeYamlQuotedString(&out, allocator, proxyGroupTypeString(group.group_type));
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, "    proxies:\n");
        for (group.proxies.items) |item| {
            try out.appendSlice(allocator, "      - ");
            try writeYamlQuotedString(&out, allocator, item);
            try out.append(allocator, '\n');
        }
        if (group.url) |url| {
            try out.appendSlice(allocator, "    url: ");
            try writeYamlQuotedString(&out, allocator, url);
            try out.append(allocator, '\n');
        }
        try out.print(allocator, "    interval: {d}\n", .{group.interval});
        try out.print(allocator, "    tolerance: {d}\n", .{group.tolerance});
        try out.appendSlice(allocator, "    lazy: ");
        try out.appendSlice(allocator, if (group.lazy) "true\n" else "false\n");
    }

    try out.appendSlice(allocator, "rules:\n");
    for (cfg.rules.items) |rule| {
        const as_text = try ruleToText(allocator, rule);
        defer allocator.free(as_text);
        try out.appendSlice(allocator, "  - ");
        try writeYamlQuotedString(&out, allocator, as_text);
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

/// 经 std.json 序列化（真实转义），禁止手拼 JSON 字符串。
/// 字段名保持 clash 风格（连字符），密钥字段统一打码。
pub fn dumpConfigJson(allocator: std.mem.Allocator, cfg: *const config.Config) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .minified } };
    try js.beginObject();

    try js.objectField("port");
    try js.write(cfg.port);
    try js.objectField("socks-port");
    try js.write(cfg.socks_port);
    try js.objectField("mixed-port");
    try js.write(cfg.mixed_port);
    try js.objectField("allow-lan");
    try js.write(cfg.allow_lan);
    try js.objectField("bind-address");
    try js.write(cfg.bind_address);
    try js.objectField("mode");
    try js.write(cfg.mode);
    try js.objectField("log-level");
    try js.write(cfg.log_level);
    try js.objectField("external-controller");
    try js.write(cfg.external_controller);

    try js.objectField("rule-providers");
    try js.beginObject();
    for (cfg.rule_providers.items) |provider| {
        try js.objectField(provider.name);
        try js.beginObject();
        try js.objectField("type");
        try js.write(provider.provider_type);
        try js.objectField("behavior");
        try js.write(ruleProviderBehaviorString(provider.behavior));
        try js.objectField("url");
        try js.write(provider.url);
        try js.objectField("path");
        try js.write(provider.path);
        try js.objectField("interval");
        try js.write(provider.interval);
        try js.endObject();
    }
    try js.endObject();

    try js.objectField("proxies");
    try js.beginArray();
    for (cfg.proxies.items) |proxy| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(proxy.name);
        try js.objectField("type");
        try js.write(proxyTypeString(proxy.proxy_type));
        try js.objectField("server");
        try js.write(proxy.server);
        try js.objectField("port");
        try js.write(proxy.port);
        if (proxy.password != null) {
            try js.objectField("password");
            try js.write("******");
        }
        if (proxy.uuid != null) {
            try js.objectField("uuid");
            try js.write("******");
        }
        if (proxy.sni != null) {
            try js.objectField("sni");
            try js.write("******");
        }
        try js.endObject();
    }
    try js.endArray();

    try js.objectField("proxy-groups");
    try js.beginArray();
    for (cfg.proxy_groups.items) |group| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(group.name);
        try js.objectField("type");
        try js.write(proxyGroupTypeString(group.group_type));
        try js.objectField("proxies");
        try js.beginArray();
        for (group.proxies.items) |proxy_name| {
            try js.write(proxy_name);
        }
        try js.endArray();
        try js.endObject();
    }
    try js.endArray();

    try js.objectField("rules");
    try js.beginArray();
    for (cfg.rules.items) |rule| {
        const as_text = try ruleToText(allocator, rule);
        defer allocator.free(as_text);
        try js.write(as_text);
    }
    try js.endArray();

    try js.endObject();
    return try aw.toOwnedSlice();
}

fn proxyTypeString(pt: config.ProxyType) []const u8 {
    return switch (pt) {
        .direct => "direct",
        .reject => "reject",
        .http => "http",
        .socks5 => "socks5",
        .ss => "ss",
        .vmess => "vmess",
        .trojan => "trojan",
        .vless => "vless",
        .anytls => "anytls",
    };
}

fn proxyGroupTypeString(gt: config.ProxyGroupType) []const u8 {
    return switch (gt) {
        .select => "select",
        .url_test => "url-test",
        .fallback => "fallback",
        .load_balance => "load-balance",
        .relay => "relay",
    };
}

fn ruleProviderBehaviorString(behavior: config.RuleProviderBehavior) []const u8 {
    return switch (behavior) {
        .domain => "domain",
        .ipcidr => "ipcidr",
        .classical => "classical",
    };
}

fn ruleTypeToken(rt: config.RuleType) []const u8 {
    return switch (rt) {
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

fn ruleToText(allocator: std.mem.Allocator, r: config.Rule) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    if (r.rule_type == .final) {
        try out.print(allocator, "MATCH,{s}", .{r.target});
    } else {
        try out.print(allocator, "{s},{s},{s}", .{ ruleTypeToken(r.rule_type), r.payload, r.target });
    }
    if (r.no_resolve) try out.appendSlice(allocator, ",no-resolve");
    return try out.toOwnedSlice(allocator);
}

test "override parse options supports script args and timeout" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{
        "zc",
        "test",
        "--override-script",
        "./override.lua",
        "--override-arg",
        "region=sg",
        "--override-timeout-ms=1200",
    };

    var opts = try parseCliOptions(allocator, args[0..]);
    defer opts.deinit(allocator);
    try std.testing.expectEqualStrings("./override.lua", opts.script_path.?);
    try std.testing.expectEqual(@as(u32, 1200), opts.timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), opts.args.items.len);
    try std.testing.expectEqualStrings("region", opts.args.items[0].key);
    try std.testing.expectEqualStrings("sg", opts.args.items[0].value);
}

test "override parse options rejects deprecated dump flags" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{
        "zc",
        "test",
        "--override-dump-yaml",
    };

    try std.testing.expectError(error.DeprecatedOverrideDumpOption, parseCliOptions(allocator, args[0..]));
}

test "dumpConfigJson emits parseable std.json with escaping and masked secrets" {
    const allocator = std.testing.allocator;
    const content =
        \\port: 7890
        \\proxies:
        \\  - name: node "HK" 线路
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: topsecret
        \\proxy-groups:
        \\  - name: Proxy
        \\    type: select
        \\    proxies:
        \\      - node "HK" 线路
        \\rules:
        \\  - MATCH,DIRECT
    ;

    var cfg = try config.parse(allocator, content);
    defer cfg.deinit();

    const dumped = try dumpConfigJson(allocator, &cfg);
    defer allocator.free(dumped);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, dumped, .{});
    defer parsed.deinit();

    const proxy = parsed.value.object.get("proxies").?.array.items[0].object;
    try std.testing.expectEqualStrings("node \"HK\" 线路", proxy.get("name").?.string);
    try std.testing.expectEqualStrings("******", proxy.get("password").?.string);
    try std.testing.expectEqualStrings("MATCH,DIRECT", parsed.value.object.get("rules").?.array.items[0].string);
}

test "override apply map supports scalar fields" {
    const allocator = std.testing.allocator;
    const content =
        \\mode: global
        \\log-level: debug
        \\allow-lan: true
        \\bind-address: "0.0.0.0"
        \\external-controller: null
    ;

    var root = try yaml.parse(allocator, content);
    defer root.deinit(allocator);

    var cfg = try config.loadDefault(allocator);
    defer cfg.deinit();
    if (cfg.external_controller) |old| allocator.free(old);
    cfg.external_controller = try allocator.dupe(u8, "127.0.0.1:9090");

    try applyMapOverride(allocator, &cfg, &root.map);
    try std.testing.expectEqualStrings("global", cfg.mode);
    try std.testing.expectEqualStrings("debug", cfg.log_level);
    try std.testing.expect(cfg.allow_lan);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.bind_address);
    try std.testing.expect(cfg.external_controller == null);
}
