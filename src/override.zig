const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const config = @import("config.zig");
const config_validator = @import("config_validator.zig");
const yaml = @import("util/yaml.zig");

pub const timeout_ms_default: u32 = 5_000;
pub const timeout_ms_max: u32 = 60_000;

pub const OverrideArg = struct {
    key: []u8,
    value: []u8,
};

fn appendOwnedSlice(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const copy = try allocator.dupe(u8, value);
    errdefer allocator.free(copy);
    try out.append(allocator, copy);
}

pub const CliOptions = struct {
    script_path: ?[]u8 = null,
    timeout_ms: u32 = timeout_ms_default,
    args: std.ArrayList(OverrideArg) = .empty,

    pub fn deinit(self: *CliOptions, allocator: std.mem.Allocator) void {
        if (self.script_path) |p| allocator.free(p);
        for (self.args.items) |arg| {
            allocator.free(arg.key);
            allocator.free(arg.value);
        }
        self.args.deinit(allocator);
    }

    pub fn appendForwardArgs(
        self: *const CliOptions,
        allocator: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
    ) !void {
        if (self.script_path) |script| {
            try appendOwnedSlice(allocator, out, "--override-script");
            try appendOwnedSlice(allocator, out, script);
        }
        for (self.args.items) |arg| {
            try appendOwnedSlice(allocator, out, "--override-arg");
            const pair = try std.fmt.allocPrint(
                allocator,
                "{s}={s}",
                .{ arg.key, arg.value },
            );
            errdefer allocator.free(pair);
            try out.append(allocator, pair);
        }
        if (self.timeout_ms != timeout_ms_default) {
            try appendOwnedSlice(allocator, out, "--override-timeout-ms");
            const timeout = try std.fmt.allocPrint(
                allocator,
                "{d}",
                .{self.timeout_ms},
            );
            errdefer allocator.free(timeout);
            try out.append(allocator, timeout);
        }
    }
};

pub const ExecutionArgument = struct {
    key: []const u8,
    value: []const u8,
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

fn parseTimeoutMs(text: []const u8) !u32 {
    const value = std.fmt.parseInt(u32, text, 10) catch
        return Errors.InvalidOverrideTimeout;
    if (value == 0 or value > timeout_ms_max) {
        return Errors.InvalidOverrideTimeout;
    }
    return value;
}

fn replaceScriptPath(
    allocator: std.mem.Allocator,
    options: *CliOptions,
    value: []const u8,
) !void {
    const replacement = try allocator.dupe(u8, value);
    const old = options.script_path;
    options.script_path = replacement;
    if (old) |item| allocator.free(item);
}

fn appendOverrideArg(
    allocator: std.mem.Allocator,
    options: *CliOptions,
    text: []const u8,
) !void {
    const pair = try parseOverrideArg(allocator, text);
    errdefer {
        allocator.free(pair.key);
        allocator.free(pair.value);
    }
    try options.args.append(allocator, pair);
}

pub fn parseCliOptions(allocator: std.mem.Allocator, args: []const []const u8) !CliOptions {
    var opts = CliOptions{};
    errdefer opts.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--override-script")) {
            if (i + 1 >= args.len) return Errors.MissingOverrideScriptPath;
            i += 1;
            try replaceScriptPath(allocator, &opts, args[i]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--override-script=")) {
            const value = arg["--override-script=".len..];
            if (value.len == 0) return Errors.MissingOverrideScriptPath;
            try replaceScriptPath(allocator, &opts, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--override-timeout-ms")) {
            if (i + 1 >= args.len) return Errors.InvalidOverrideTimeout;
            i += 1;
            opts.timeout_ms = try parseTimeoutMs(args[i]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--override-timeout-ms=")) {
            const value = arg["--override-timeout-ms=".len..];
            opts.timeout_ms = try parseTimeoutMs(value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--override-arg")) {
            if (i + 1 >= args.len) return Errors.MissingOverrideArg;
            i += 1;
            try appendOverrideArg(allocator, &opts, args[i]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--override-arg=")) {
            try appendOverrideArg(
                allocator,
                &opts,
                arg["--override-arg=".len..],
            );
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
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    const value_copy = try allocator.dupe(u8, value);
    return .{
        .key = key_copy,
        .value = value_copy,
    };
}

pub fn executeScriptPatch(
    allocator: std.mem.Allocator,
    script_path: []const u8,
    arguments: []const ExecutionArgument,
    timeout_ms: u32,
    command_name: []const u8,
    config_path: ?[]const u8,
) ![]u8 {
    if (timeout_ms == 0 or timeout_ms > timeout_ms_max) {
        return Errors.InvalidOverrideTimeout;
    }
    var options = CliOptions{
        .script_path = try allocator.dupe(u8, script_path),
        .timeout_ms = timeout_ms,
    };
    defer options.deinit(allocator);
    for (arguments) |argument| {
        const key = try allocator.dupe(u8, argument.key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, argument.value);
        errdefer allocator.free(value);
        try options.args.append(allocator, .{ .key = key, .value = value });
    }
    return executeOverrideScript(
        allocator,
        options.script_path.?,
        &options,
        command_name,
        config_path,
    );
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

        try applyPatch(allocator, cfg, patch_text);
    }
}

const PatchConfigParseMode = enum {
    runtime,
    catalog_capture,
};

pub fn applyPatch(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    patch_text: []const u8,
) !void {
    return applyPatchImpl(allocator, cfg, patch_text, .runtime);
}

fn applyPatchImpl(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    patch_text: []const u8,
    parse_mode: PatchConfigParseMode,
) !void {
    const trimmed = std.mem.trim(u8, patch_text, " \t\r\n");
    if (trimmed.len == 0) return;
    var root = yaml.parseDocument(allocator, trimmed) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return Errors.OverrideOutputInvalid,
    };
    defer root.deinit(allocator);
    if (root != .map) return Errors.OverrideOutputInvalid;

    const source = try dumpEffectiveConfigYaml(allocator, cfg);
    defer allocator.free(source);
    var replacement = try config.parseDocument(allocator, source);
    errdefer replacement.deinit();
    applyMapOverride(
        allocator,
        &replacement,
        &root.map,
        parse_mode,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return Errors.OverrideMergeFailed,
    };

    var previous = cfg.*;
    cfg.* = replacement;
    previous.deinit();
}

pub fn materializeSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    patch_text: []const u8,
) ![]u8 {
    var cfg = try config.parseCatalogDocument(allocator, source);
    defer cfg.deinit();
    if (std.mem.trim(u8, patch_text, " \t\r\n").len == 0) {
        try requireMaterializableCapabilities(allocator, &cfg);
        return allocator.dupe(u8, source);
    }
    applyPatchImpl(
        allocator,
        &cfg,
        patch_text,
        .catalog_capture,
    ) catch |err| switch (err) {
        error.InvalidPluginOptions => return error.UnsupportedCapability,
        else => return err,
    };
    try requireMaterializableCapabilities(allocator, &cfg);
    return dumpEffectiveConfigYaml(allocator, &cfg);
}

fn requireMaterializableCapabilities(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
) !void {
    var validation = try config_validator.validateRuntimeCapabilities(
        allocator,
        cfg,
    );
    defer validation.deinit();
    if (!validation.isValid()) return error.UnsupportedCapability;
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

    const argument_count = try std.fmt.allocPrint(
        allocator,
        "{d}",
        .{opts.args.items.len},
    );
    defer allocator.free(argument_count);
    try env_map.put("ZC_OVERRIDE_ARG_COUNT", argument_count);

    var args_buf = std.ArrayList(u8).empty;
    defer args_buf.deinit(allocator);
    for (opts.args.items, 0..) |arg, index| {
        if (index > 0) try args_buf.append(allocator, ';');
        try args_buf.appendSlice(allocator, arg.key);
        try args_buf.append(allocator, '=');
        try args_buf.appendSlice(allocator, arg.value);

        const key_name = try std.fmt.allocPrint(
            allocator,
            "ZC_OVERRIDE_ARG_{d}_KEY",
            .{index},
        );
        defer allocator.free(key_name);
        const value_name = try std.fmt.allocPrint(
            allocator,
            "ZC_OVERRIDE_ARG_{d}_VALUE",
            .{index},
        );
        defer allocator.free(value_name);
        try env_map.put(key_name, arg.key);
        try env_map.put(value_name, arg.value);

        const env_key = try sanitizeEnvKey(allocator, arg.key);
        defer allocator.free(env_key);
        const full_key = try std.fmt.allocPrint(
            allocator,
            "ZC_OVERRIDE_ARG_{s}",
            .{env_key},
        );
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
        error.OutOfMemory => error.OutOfMemory,
        error.OverrideScriptTimeout, error.Timeout => Errors.OverrideScriptTimeout,
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
    std.debug.assert(timeout_ms > 0);
    std.debug.assert(timeout_ms <= timeout_ms_max);
    const timeout: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
    } };
    const result = try std.process.run(allocator, compat.io(), .{
        .argv = argv,
        .environ_map = env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .nothing,
        .timeout = timeout,
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
    \\local function parse_legacy_args(raw)
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
    \\local function parse_args()
    \\  local count = tonumber(os.getenv("ZC_OVERRIDE_ARG_COUNT"))
    \\  if count == nil then
    \\    return parse_legacy_args(os.getenv("ZC_OVERRIDE_ARGS"))
    \\  end
    \\  local out = {}
    \\  for index = 0, count - 1 do
    \\    local prefix = "ZC_OVERRIDE_ARG_" .. tostring(index)
    \\    local key = os.getenv(prefix .. "_KEY")
    \\    local value = os.getenv(prefix .. "_VALUE")
    \\    if key ~= nil then out[key] = value or "" end
    \\  end
    \\  return out
    \\end
    \\
    \\input = {
    \\  command = os.getenv("ZC_OVERRIDE_COMMAND"),
    \\  config_path = os.getenv("ZC_OVERRIDE_CONFIG_PATH"),
    \\  script_path = os.getenv("ZC_OVERRIDE_SCRIPT_PATH"),
    \\  args = parse_args(),
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

fn replaceOwnedString(
    allocator: std.mem.Allocator,
    field: *[]const u8,
    value: []const u8,
) !void {
    const replacement = try allocator.dupe(u8, value);
    const old = field.*;
    field.* = replacement;
    allocator.free(old);
}

fn applyMapOverride(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    m: *const std.StringHashMap(yaml.YamlValue),
    parse_mode: PatchConfigParseMode,
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
            const string = switch (value) {
                .string => |item| item,
                else => return Errors.OverrideOutputInvalid,
            };
            try replaceOwnedString(cfg.allocator, &cfg.bind_address, string);
            continue;
        }
        if (std.mem.eql(u8, key, "mode")) {
            const string = switch (value) {
                .string => |item| item,
                else => return Errors.OverrideOutputInvalid,
            };
            try replaceOwnedString(cfg.allocator, &cfg.mode, string);
            continue;
        }
        if (std.mem.eql(u8, key, "log-level")) {
            const string = switch (value) {
                .string => |item| item,
                else => return Errors.OverrideOutputInvalid,
            };
            try replaceOwnedString(cfg.allocator, &cfg.log_level, string);
            continue;
        }
        if (std.mem.eql(u8, key, "external-controller")) {
            const replacement: ?[]const u8 = switch (value) {
                .null => null,
                .string => |item| try cfg.allocator.dupe(u8, item),
                else => return Errors.OverrideOutputInvalid,
            };
            const old = cfg.external_controller;
            cfg.external_controller = replacement;
            if (old) |item| cfg.allocator.free(item);
            continue;
        }
        if (std.mem.eql(u8, key, "proxies")) {
            var tmp = try parseSingleFieldOverride(
                allocator,
                "proxies",
                value,
                parse_mode,
            );
            defer releaseTempConfig(&tmp);
            moveProxies(cfg, &tmp);
            continue;
        }
        if (std.mem.eql(u8, key, "proxy-groups")) {
            var tmp = try parseSingleFieldOverride(
                allocator,
                "proxy-groups",
                value,
                parse_mode,
            );
            defer releaseTempConfig(&tmp);
            moveProxyGroups(cfg, &tmp);
            continue;
        }
        if (std.mem.eql(u8, key, "rule-providers")) {
            var tmp = try parseSingleFieldOverride(
                allocator,
                "rule-providers",
                value,
                parse_mode,
            );
            defer releaseTempConfig(&tmp);
            moveRuleProviders(cfg, &tmp);
            continue;
        }
        if (std.mem.eql(u8, key, "rules")) {
            var tmp = try parseSingleFieldOverride(
                allocator,
                "rules",
                value,
                parse_mode,
            );
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

fn parseSingleFieldOverride(
    allocator: std.mem.Allocator,
    field: []const u8,
    value: yaml.YamlValue,
    parse_mode: PatchConfigParseMode,
) !config.Config {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, field);
    switch (value) {
        .null, .boolean, .integer, .string => {
            try out.appendSlice(allocator, ": ");
            try writeYamlScalar(&out, allocator, value);
            try out.append(allocator, '\n');
        },
        .array => |items| {
            if (items.items.len == 0) {
                try out.appendSlice(allocator, ": []\n");
            } else {
                try out.appendSlice(allocator, ":\n");
                try writeYamlValue(&out, allocator, &value, 2);
            }
        },
        .map => |items| {
            if (items.count() == 0) {
                try out.appendSlice(allocator, ": {}\n");
            } else {
                try out.appendSlice(allocator, ":\n");
                try writeYamlValue(&out, allocator, &value, 2);
            }
        },
    }

    return switch (parse_mode) {
        .runtime => config.parseDocument(allocator, out.items),
        .catalog_capture => config.parseCatalogDocument(allocator, out.items),
    } catch Errors.OverrideOutputInvalid;
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
                        if (emptyCollectionMarker(entry.value_ptr)) |marker| {
                            try out.appendSlice(allocator, ": ");
                            try out.appendSlice(allocator, marker);
                            try out.append(allocator, '\n');
                        } else {
                            try out.appendSlice(allocator, ":\n");
                            try writeYamlValue(out, allocator, entry.value_ptr, indent + 2);
                        }
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
                        if (emptyCollectionMarker(item)) |marker| {
                            try out.appendSlice(allocator, "- ");
                            try out.appendSlice(allocator, marker);
                            try out.append(allocator, '\n');
                        } else {
                            try out.appendSlice(allocator, "-\n");
                            try writeYamlValue(out, allocator, item, indent + 2);
                        }
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

fn emptyCollectionMarker(value: *const yaml.YamlValue) ?[]const u8 {
    return switch (value.*) {
        .array => |items| if (items.items.len == 0) "[]" else null,
        .map => |items| if (items.count() == 0) "{}" else null,
        else => null,
    };
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

fn dumpEffectiveConfigYaml(allocator: std.mem.Allocator, cfg: *const config.Config) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.print(allocator, "port: {d}\n", .{cfg.port});
    try out.print(allocator, "socks-port: {d}\n", .{cfg.socks_port});
    try out.print(allocator, "mixed-port: {d}\n", .{cfg.mixed_port});
    try out.print(allocator, "redir-port: {d}\n", .{cfg.redir_port});
    try out.print(allocator, "tproxy-port: {d}\n", .{cfg.tproxy_port});
    try out.appendSlice(allocator, "allow-lan: ");
    try out.appendSlice(allocator, if (cfg.allow_lan) "true\n" else "false\n");
    try out.appendSlice(allocator, "bind-address: ");
    try writeYamlQuotedString(&out, allocator, cfg.bind_address);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "mode: ");
    try writeYamlQuotedString(&out, allocator, cfg.mode);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "log-level: ");
    try writeYamlQuotedString(&out, allocator, cfg.log_level);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "ipv6: ");
    try out.appendSlice(allocator, if (cfg.ipv6) "true\n" else "false\n");
    if (cfg.external_controller) |value| {
        try out.appendSlice(allocator, "external-controller: ");
        try writeYamlQuotedString(&out, allocator, value);
        try out.append(allocator, '\n');
    }
    if (cfg.external_ui) |value| {
        try out.appendSlice(allocator, "external-ui: ");
        try writeYamlQuotedString(&out, allocator, value);
        try out.append(allocator, '\n');
    }
    if (cfg.secret) |value| {
        try out.appendSlice(allocator, "secret: ");
        try writeYamlQuotedString(&out, allocator, value);
        try out.append(allocator, '\n');
    }
    try out.print(allocator, "idle-session-check-interval: {d}\n", .{cfg.idle_session_check_interval});
    try out.print(allocator, "idle-session-timeout: {d}\n", .{cfg.idle_session_timeout});
    try out.print(allocator, "min-idle-session: {d}\n", .{cfg.min_idle_session});

    if (cfg.rule_providers.items.len == 0) {
        try out.appendSlice(allocator, "rule-providers: {}\n");
    } else {
        try out.appendSlice(allocator, "rule-providers:\n");
        for (cfg.rule_providers.items) |provider| {
            try out.appendSlice(allocator, "  ");
            try writeYamlQuotedString(&out, allocator, provider.name);
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

    if (cfg.proxies.items.len == 0) {
        try out.appendSlice(allocator, "proxies: []\n");
    } else {
        try out.appendSlice(allocator, "proxies:\n");
        for (cfg.proxies.items) |proxy| {
            try out.appendSlice(allocator, "  - name: ");
            try writeYamlQuotedString(&out, allocator, proxy.name);
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, "    type: ");
            try writeYamlQuotedString(&out, allocator, proxyTypeString(proxy.proxy_type));
            try out.append(allocator, '\n');
            if (proxy.proxy_type != .direct and proxy.proxy_type != .reject) {
                try out.appendSlice(allocator, "    server: ");
                try writeYamlQuotedString(&out, allocator, proxy.server);
                try out.append(allocator, '\n');
                try out.print(allocator, "    port: {d}\n", .{proxy.port});
            }
            if (proxy.password) |value| {
                try out.appendSlice(allocator, "    password: ");
                try writeYamlQuotedString(&out, allocator, value);
                try out.append(allocator, '\n');
            }
            if (proxy.cipher) |value| {
                try out.appendSlice(allocator, "    cipher: ");
                try writeYamlQuotedString(&out, allocator, value);
                try out.append(allocator, '\n');
            }
            if (proxy.uuid) |value| {
                try out.appendSlice(allocator, "    uuid: ");
                try writeYamlQuotedString(&out, allocator, value);
                try out.append(allocator, '\n');
            }
            if (proxy.alter_id != 0) try out.print(allocator, "    alterId: {d}\n", .{proxy.alter_id});
            if (proxy.tls) try out.appendSlice(allocator, "    tls: true\n");
            if (proxy.skip_cert_verify) try out.appendSlice(allocator, "    skip-cert-verify: true\n");
            if (proxy.udp) try out.appendSlice(allocator, "    udp: true\n");
            if (proxy.sni) |value| {
                try out.appendSlice(allocator, "    sni: ");
                try writeYamlQuotedString(&out, allocator, value);
                try out.append(allocator, '\n');
            }
            if (proxy.ws or proxy.ws_path != null or proxy.ws_host != null) {
                if (proxy.ws_path == null and proxy.ws_host == null) {
                    try out.appendSlice(allocator, "    ws-opts: {}\n");
                } else {
                    try out.appendSlice(allocator, "    ws-opts:\n");
                }
                if (proxy.ws_path) |value| {
                    try out.appendSlice(allocator, "      path: ");
                    try writeYamlQuotedString(&out, allocator, value);
                    try out.append(allocator, '\n');
                }
                if (proxy.ws_host) |value| {
                    try out.appendSlice(allocator, "      headers:\n        Host: ");
                    try writeYamlQuotedString(&out, allocator, value);
                    try out.append(allocator, '\n');
                }
            }
            if (proxy.plugin) |value| {
                try out.appendSlice(allocator, "    plugin: ");
                try writeYamlQuotedString(&out, allocator, value);
                try out.append(allocator, '\n');
            }
            if (proxy.semantic_state == .malformed or
                proxy.plugin_options_state == .malformed)
            {
                return error.InvalidPluginOptions;
            }
            if (proxy.plugin_options_state == .map or
                proxy.obfs_mode != null or proxy.obfs_host != null)
            {
                if (proxy.obfs_mode == null and proxy.obfs_host == null) {
                    try out.appendSlice(allocator, "    plugin-opts: {}\n");
                } else {
                    try out.appendSlice(allocator, "    plugin-opts:\n");
                    if (proxy.obfs_mode) |value| {
                        try out.appendSlice(allocator, "      mode: ");
                        try writeYamlQuotedString(&out, allocator, value);
                        try out.append(allocator, '\n');
                    }
                    if (proxy.obfs_host) |value| {
                        try out.appendSlice(allocator, "      host: ");
                        try writeYamlQuotedString(&out, allocator, value);
                        try out.append(allocator, '\n');
                    }
                }
            }
        }
    }

    if (cfg.proxy_groups.items.len == 0) {
        try out.appendSlice(allocator, "proxy-groups: []\n");
    } else {
        try out.appendSlice(allocator, "proxy-groups:\n");
        for (cfg.proxy_groups.items) |group| {
            try out.appendSlice(allocator, "  - name: ");
            try writeYamlQuotedString(&out, allocator, group.name);
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, "    type: ");
            try writeYamlQuotedString(&out, allocator, proxyGroupTypeString(group.group_type));
            try out.append(allocator, '\n');
            if (group.proxies.items.len == 0) {
                try out.appendSlice(allocator, "    proxies: []\n");
            } else {
                try out.appendSlice(allocator, "    proxies:\n");
                for (group.proxies.items) |item| {
                    try out.appendSlice(allocator, "      - ");
                    try writeYamlQuotedString(&out, allocator, item);
                    try out.append(allocator, '\n');
                }
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
    }

    if (cfg.rules.items.len == 0) {
        try out.appendSlice(allocator, "rules: []\n");
    } else {
        try out.appendSlice(allocator, "rules:\n");
        for (cfg.rules.items) |rule| {
            const text = try ruleToText(allocator, rule);
            defer allocator.free(text);
            try out.appendSlice(allocator, "  - ");
            try writeYamlQuotedString(&out, allocator, text);
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

const DumpYamlOptions = struct {
    redact_secrets: bool,
    include_rule_providers: bool,
};

pub fn dumpConfigYaml(allocator: std.mem.Allocator, cfg: *const config.Config) ![]u8 {
    return dumpConfigYamlWithOptions(allocator, cfg, .{
        .redact_secrets = true,
        .include_rule_providers = true,
    });
}

pub fn dumpRuntimeConfigYaml(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
) ![]u8 {
    return dumpConfigYamlWithOptions(allocator, cfg, .{
        .redact_secrets = false,
        .include_rule_providers = false,
    });
}

fn dumpConfigYamlWithOptions(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    options: DumpYamlOptions,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.print(allocator, "port: {d}\n", .{cfg.port});
    try out.print(allocator, "socks-port: {d}\n", .{cfg.socks_port});
    try out.print(allocator, "mixed-port: {d}\n", .{cfg.mixed_port});
    try out.print(allocator, "redir-port: {d}\n", .{cfg.redir_port});
    try out.print(allocator, "tproxy-port: {d}\n", .{cfg.tproxy_port});
    try out.print(allocator, "allow-lan: {s}\n", .{if (cfg.allow_lan) "true" else "false"});
    try out.print(allocator, "ipv6: {s}\n", .{if (cfg.ipv6) "true" else "false"});
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
    if (cfg.external_ui) |ui| {
        try out.appendSlice(allocator, "external-ui: ");
        try writeYamlQuotedString(&out, allocator, ui);
        try out.append(allocator, '\n');
    }
    if (cfg.secret) |secret| {
        try out.appendSlice(allocator, "secret: ");
        try writeYamlQuotedString(
            &out,
            allocator,
            if (options.redact_secrets) "******" else secret,
        );
        try out.append(allocator, '\n');
    }
    try out.print(
        allocator,
        "idle-session-check-interval: {d}\n",
        .{cfg.idle_session_check_interval},
    );
    try out.print(
        allocator,
        "idle-session-timeout: {d}\n",
        .{cfg.idle_session_timeout},
    );
    try out.print(allocator, "min-idle-session: {d}\n", .{cfg.min_idle_session});

    if (options.include_rule_providers and cfg.rule_providers.items.len > 0) {
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

    if (cfg.proxies.items.len == 0) {
        try out.appendSlice(allocator, "proxies: []\n");
    } else {
        try out.appendSlice(allocator, "proxies:\n");
    }
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
        if (proxy.password) |password| {
            try out.appendSlice(allocator, "    password: ");
            try writeYamlQuotedString(
                &out,
                allocator,
                if (options.redact_secrets) "******" else password,
            );
            try out.append(allocator, '\n');
        }
        if (proxy.cipher) |cipher| {
            try out.appendSlice(allocator, "    cipher: ");
            try writeYamlQuotedString(&out, allocator, cipher);
            try out.append(allocator, '\n');
        }
        if (proxy.uuid) |uuid| {
            try out.appendSlice(allocator, "    uuid: ");
            try writeYamlQuotedString(
                &out,
                allocator,
                if (options.redact_secrets) "******" else uuid,
            );
            try out.append(allocator, '\n');
        }
        if (proxy.alter_id != 0) try out.print(allocator, "    alterId: {d}\n", .{proxy.alter_id});
        if (proxy.tls) try out.appendSlice(allocator, "    tls: true\n");
        if (proxy.skip_cert_verify) try out.appendSlice(allocator, "    skip-cert-verify: true\n");
        if (proxy.sni) |sni| {
            try out.appendSlice(allocator, "    sni: ");
            try writeYamlQuotedString(
                &out,
                allocator,
                if (options.redact_secrets) "******" else sni,
            );
            try out.append(allocator, '\n');
        }
        if (proxy.udp) try out.appendSlice(allocator, "    udp: true\n");
        if (proxy.ws) {
            if (proxy.ws_path == null and proxy.ws_host == null) {
                try out.appendSlice(allocator, "    ws-opts: {}\n");
            } else {
                try out.appendSlice(allocator, "    ws-opts:\n");
                if (proxy.ws_path) |ws_path| {
                    try out.appendSlice(allocator, "      path: ");
                    try writeYamlQuotedString(&out, allocator, ws_path);
                    try out.append(allocator, '\n');
                }
                if (proxy.ws_host) |ws_host| {
                    try out.appendSlice(allocator, "      headers:\n");
                    try out.appendSlice(allocator, "        Host: ");
                    try writeYamlQuotedString(&out, allocator, ws_host);
                    try out.append(allocator, '\n');
                }
            }
        }
        if (proxy.plugin) |plugin| {
            try out.appendSlice(allocator, "    plugin: ");
            try writeYamlQuotedString(&out, allocator, plugin);
            try out.append(allocator, '\n');
        }
        if (proxy.semantic_state == .malformed or
            proxy.plugin_options_state == .malformed)
        {
            return error.InvalidPluginOptions;
        }
        if (proxy.plugin_options_state == .map or
            proxy.obfs_mode != null or proxy.obfs_host != null)
        {
            if (proxy.obfs_mode == null and proxy.obfs_host == null) {
                try out.appendSlice(allocator, "    plugin-opts: {}\n");
            } else {
                try out.appendSlice(allocator, "    plugin-opts:\n");
                if (proxy.obfs_mode) |obfs_mode| {
                    try out.appendSlice(allocator, "      mode: ");
                    try writeYamlQuotedString(&out, allocator, obfs_mode);
                    try out.append(allocator, '\n');
                }
                if (proxy.obfs_host) |obfs_host| {
                    try out.appendSlice(allocator, "      host: ");
                    try writeYamlQuotedString(&out, allocator, obfs_host);
                    try out.append(allocator, '\n');
                }
            }
        }
    }

    if (cfg.proxy_groups.items.len == 0) {
        try out.appendSlice(allocator, "proxy-groups: []\n");
    } else {
        try out.appendSlice(allocator, "proxy-groups:\n");
    }
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

    if (cfg.rules.items.len == 0) {
        try out.appendSlice(allocator, "rules: []\n");
    } else {
        try out.appendSlice(allocator, "rules:\n");
    }
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
        if (proxy.cipher) |cipher| {
            try js.objectField("cipher");
            try js.write(cipher);
        }
        if (proxy.plugin) |plugin| {
            try js.objectField("plugin");
            try js.write(plugin);
        }
        if (proxy.semantic_state == .malformed or
            proxy.plugin_options_state == .malformed)
        {
            return error.InvalidPluginOptions;
        }
        if (proxy.plugin_options_state == .map or
            proxy.obfs_mode != null or proxy.obfs_host != null)
        {
            try js.objectField("plugin-opts");
            try js.beginObject();
            if (proxy.obfs_mode) |mode| {
                try js.objectField("mode");
                try js.write(mode);
            }
            if (proxy.obfs_host) |host| {
                try js.objectField("host");
                try js.write(host);
            }
            try js.endObject();
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

fn parseCliOptionsAllocationFixture(allocator: std.mem.Allocator) !void {
    const args = [_][]const u8{
        "zc",
        "--override-script=first.lua",
        "--override-script",
        "second.lua",
        "--override-arg",
        "region=sg",
        "--override-arg=empty=",
    };
    var options = try parseCliOptions(allocator, &args);
    defer options.deinit(allocator);

    var forwarded = std.ArrayList([]const u8).empty;
    defer {
        for (forwarded.items) |item| allocator.free(item);
        forwarded.deinit(allocator);
    }
    try options.appendForwardArgs(allocator, &forwarded);
}

test "override CLI options release every allocation failure path" {
    // Repeated options and list growth must transfer each allocation once.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseCliOptionsAllocationFixture,
        .{},
    );
}

test "override parse options enforces a bounded timeout" {
    // Zero disables deadlines today; values above one minute are not actionable.
    const allocator = std.testing.allocator;
    const zero = [_][]const u8{ "zc", "--override-timeout-ms=0" };
    try std.testing.expectError(
        Errors.InvalidOverrideTimeout,
        parseCliOptions(allocator, &zero),
    );
    const excessive = [_][]const u8{
        "zc",
        "--override-timeout-ms=60001",
    };
    try std.testing.expectError(
        Errors.InvalidOverrideTimeout,
        parseCliOptions(allocator, &excessive),
    );
    try std.testing.expectError(
        Errors.InvalidOverrideTimeout,
        executeScriptPatch(allocator, "unused", &.{}, 0, "test", null),
    );
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

test "runtime YAML snapshot preserves secrets and omits provider declarations" {
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator,
        \\mixed-port: 7890
        \\secret: controller-secret
        \\proxies:
        \\  - name: secure
        \\    type: ss
        \\    server: example.com
        \\    port: 443
        \\    password: proxy-secret
        \\    cipher: aes-128-gcm
        \\    plugin: obfs-local
        \\    plugin_opts:
        \\      mode: http
        \\      host: cdn.example.com
        \\  - name: websocket
        \\    type: trojan
        \\    server: ws.example.com
        \\    port: 443
        \\    password: trojan-secret
        \\    ws-opts:
        \\      path: /tunnel
        \\      headers:
        \\        Host: edge.example.com
        \\rule-providers:
        \\  unused:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.yaml
        \\rules:
        \\  - MATCH,DIRECT
        \\
    );
    defer cfg.deinit();
    const snapshot = try dumpRuntimeConfigYaml(allocator, &cfg);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "controller-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "proxy-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "rule-providers:") == null);
    var restored = try config.parseDocument(allocator, snapshot);
    defer restored.deinit();
    try std.testing.expectEqualStrings("controller-secret", restored.secret.?);
    try std.testing.expectEqualStrings("proxy-secret", restored.proxies.items[0].password.?);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "plugin-opts:") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "plugin_opts:") == null);
    try std.testing.expectEqualStrings("obfs-local", restored.proxies.items[0].plugin.?);
    try std.testing.expectEqual(
        config.PluginOptionsState.map,
        restored.proxies.items[0].plugin_options_state,
    );
    try std.testing.expectEqualStrings("http", restored.proxies.items[0].obfs_mode.?);
    try std.testing.expectEqualStrings(
        "cdn.example.com",
        restored.proxies.items[0].obfs_host.?,
    );
    try std.testing.expect(restored.proxies.items[1].ws);
    try std.testing.expectEqualStrings(
        "/tunnel",
        restored.proxies.items[1].ws_path.?,
    );
    try std.testing.expectEqualStrings(
        "edge.example.com",
        restored.proxies.items[1].ws_host.?,
    );
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
        \\    plugin: obfs
        \\    plugin_opts:
        \\      mode: http
        \\      host: cdn.example.com
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
    try std.testing.expectEqualStrings("aes-128-gcm", proxy.get("cipher").?.string);
    try std.testing.expectEqualStrings("obfs", proxy.get("plugin").?.string);
    const plugin_options = proxy.get("plugin-opts").?.object;
    try std.testing.expectEqualStrings("http", plugin_options.get("mode").?.string);
    try std.testing.expectEqualStrings(
        "cdn.example.com",
        plugin_options.get("host").?.string,
    );
    try std.testing.expect(proxy.get("plugin_opts") == null);
    try std.testing.expectEqualStrings("MATCH,DIRECT", parsed.value.object.get("rules").?.array.items[0].string);
}

test "override materialization preserves runtime secrets in owner-only effective bytes" {
    const allocator = std.testing.allocator;
    const source =
        \\mixed-port: 7890
        \\redir-port: 7892
        \\tproxy-port: 7893
        \\ipv6: false
        \\external-ui: "/tmp/ui"
        \\secret: "controller-secret"
        \\rule-providers:
        \\  "local rules":
        \\    type: "file"
        \\    behavior: "domain"
        \\    path: "assets/rules.yaml"
        \\proxies:
        \\  - name: "node"
        \\    type: "trojan"
        \\    server: "example.com"
        \\    port: 443
        \\    password: "proxy-password"
        \\    sni: "sni.example.com"
        \\proxy-groups:
        \\  - name: "Proxy"
        \\    type: "select"
        \\    proxies: ["node"]
        \\rules:
        \\  - "MATCH,Proxy"
    ;
    const patch = "mixed-port: 9000\nmode: global\n";
    const effective = try materializeSource(allocator, source, patch);
    defer allocator.free(effective);
    try std.testing.expect(std.mem.indexOf(u8, effective, "******") == null);
    try std.testing.expect(std.mem.indexOf(u8, effective, "controller-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, effective, "proxy-password") != null);

    var parsed = try config.parseDocument(allocator, effective);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 9000), parsed.mixed_port);
    try std.testing.expectEqual(@as(u16, 7892), parsed.redir_port);
    try std.testing.expectEqual(@as(u16, 7893), parsed.tproxy_port);
    try std.testing.expect(!parsed.ipv6);
    try std.testing.expectEqualStrings("global", parsed.mode);
    try std.testing.expectEqualStrings("controller-secret", parsed.secret.?);
    try std.testing.expectEqualStrings("proxy-password", parsed.proxies.items[0].password.?);
    try std.testing.expectEqualStrings("local rules", parsed.rule_providers.items[0].name);
    try std.testing.expectEqualStrings("assets/rules.yaml", parsed.rule_providers.items[0].path);
}

test "override field parsing preserves nested empty collections" {
    const allocator = std.testing.allocator;
    const source = "mixed-port: 7890\n";
    const patch =
        \\proxies: []
        \\rule-providers: {}
        \\proxy-groups:
        \\  - name: Empty
        \\    type: select
        \\    proxies: []
        \\rules: []
    ;
    const effective = try materializeSource(allocator, source, patch);
    defer allocator.free(effective);

    var parsed = try config.parseDocument(allocator, effective);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.proxies.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.rule_providers.items.len);
    try std.testing.expectEqual(
        @as(usize, 0),
        parsed.proxy_groups.items[0].proxies.items.len,
    );
    try std.testing.expectEqual(config.RuleType.final, parsed.rules.items[0].rule_type);
    try std.testing.expectEqualStrings("REJECT", parsed.rules.items[0].target);
}

test "override materialization keeps original bytes for an empty patch and is deterministic" {
    const allocator = std.testing.allocator;
    const source = "mixed-port: 7890\n";
    const unchanged = try materializeSource(allocator, source, " \r\n");
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(source, unchanged);

    const first = try materializeSource(allocator, source, "mixed-port: 9000\n");
    defer allocator.free(first);
    const second = try materializeSource(allocator, source, "mixed-port: 9000\n");
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "override materialization maps every runtime capability rejection for empty and nonempty patches" {
    const allocator = std.testing.allocator;
    const documents = [_][]const u8{
        \\mixed-port: 7890
        \\proxies:
        \\  - name: DIRECT
        \\    type: direct
        \\rules:
        \\  - MATCH,DIRECT
        ,
        \\mixed-port: 7890
        \\proxies: []
        \\proxy-groups:
        \\  - name: REJECT
        \\    type: select
        \\    proxies: [DIRECT]
        \\rules:
        \\  - MATCH,REJECT
        ,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: disabled-http
        \\    type: http
        \\    server: example.com
        \\    port: 8080
        \\rules:
        \\  - MATCH,disabled-http
        ,
        \\mixed-port: 7890
        \\proxies: []
        \\proxy-groups:
        \\  - name: automatic
        \\    type: url-test
        \\    proxies: [DIRECT]
        \\    url: https://example.com/ping
        \\rules:
        \\  - MATCH,automatic
        ,
        \\port: 7890
        \\socks-port: 7891
        \\mixed-port: 7892
        \\rules:
        \\  - MATCH,DIRECT
        ,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: unsupported-obfs
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: { mode: tls, host: example.com }
        \\rules:
        \\  - MATCH,unsupported-obfs
        ,
    };
    for (documents) |document| {
        for ([_][]const u8{ "", "mode: global\n" }) |patch| {
            try std.testing.expectError(
                error.UnsupportedCapability,
                materializeSource(allocator, document, patch),
            );
        }
    }
    try std.testing.expectError(
        error.UnsupportedCapability,
        materializeSource(
            allocator,
            "mixed-port: 7890\n",
            \\proxies:
            \\  - name: malformed-patch
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts: "obfs=http"
            ,
        ),
    );
}

test "override capability validation performs no provider network or asset IO" {
    const allocator = std.testing.allocator;
    const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try compat.net.listenReuseAddr(address);
    defer listener.deinit();
    const source = try std.fmt.allocPrint(
        allocator,
        \\mixed-port: 7890
        \\rule-providers:
        \\  missing-local:
        \\    type: file
        \\    behavior: domain
        \\    path: definitely-absent.yaml
        \\  remote:
        \\    type: http
        \\    behavior: domain
        \\    path: remote.yaml
        \\    url: http://127.0.0.1:{d}/rules
        \\rules:
        \\  - MATCH,DIRECT
    ,
        .{listener.listen_address.getPort()},
    );
    defer allocator.free(source);

    const unchanged = try materializeSource(allocator, source, "");
    defer allocator.free(unchanged);
    const patched = try materializeSource(
        allocator,
        source,
        "mode: global\n",
    );
    defer allocator.free(patched);

    var descriptors = [_]std.posix.pollfd{.{
        .fd = listener.fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(
        @as(usize, 0),
        try std.posix.poll(&descriptors, 0),
    );
}

test "override materialization rejects plugin metadata on non-Shadowsocks proxies" {
    const allocator = std.testing.allocator;
    const documents = [_][]const u8{
        \\mixed-port: 7890
        \\proxies:
        \\  - name: direct-plugin
        \\    type: direct
        \\    plugin: obfs
        ,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: reject-derived
        \\    type: reject
        \\    plugin-opts: { mode: http, host: example.com }
        ,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: trojan-plugin
        \\    type: trojan
        \\    server: example.com
        \\    port: 443
        \\    password: secret
        \\    plugin: obfs
        \\    plugin_opts: { mode: http, host: example.com }
        ,
    };
    for (documents) |document| {
        try std.testing.expectError(
            error.UnsupportedCapability,
            materializeSource(allocator, document, ""),
        );
    }
    try std.testing.expectError(
        error.UnsupportedCapability,
        materializeSource(allocator,
            \\mixed-port: 7890
            \\proxies:
            \\  - name: malformed
            \\    type: trojan
            \\    server: example.com
            \\    port: 443
            \\    password: secret
            \\    plugin-opts: "obfs=http"
        , ""),
    );
}

test "override materialization rejects malformed and unsupported obfs semantics" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.UnsupportedCapability,
        materializeSource(allocator,
            \\mixed-port: 7890
            \\proxies:
            \\  - name: malformed
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts: "obfs=http"
        , ""),
    );
    const unsupported =
        \\mixed-port: 7890
        \\proxies:
        \\  - name: unsupported
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: { mode: tls, host: example.com }
    ;
    try std.testing.expectError(
        error.UnsupportedCapability,
        materializeSource(allocator, unsupported, ""),
    );
    var captured = try config.parseCatalogDocument(allocator, unsupported);
    defer captured.deinit();
    try std.testing.expectEqual(
        config.ProxySemanticState.malformed,
        captured.proxies.items[0].semantic_state,
    );
    try std.testing.expectError(
        error.InvalidPluginOptions,
        dumpConfigYaml(allocator, &captured),
    );
}

fn materializeAllocationFixture(allocator: std.mem.Allocator) !void {
    const source =
        \\mixed-port: 7890
        \\secret: "secret"
        \\proxies: []
        \\proxy-groups: []
        \\rules: []
    ;
    const effective = try materializeSource(allocator, source, "mixed-port: 9000\n");
    allocator.free(effective);
}

test "override materialization releases every allocation failure path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        materializeAllocationFixture,
        .{},
    );
}

test "override execution enforces the configured timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try tmp.dir.createFile(compat.io(), "slow.sh", .{});
    try script.writeStreamingAll(compat.io(), "#!/bin/sh\nsleep 1\nprintf 'mixed-port: 9000\\n'\n");
    try script.setPermissions(compat.io(), std.Io.File.Permissions.fromMode(0o700));
    script.close(compat.io());
    const script_path = try tmp.dir.realPathFileAlloc(compat.io(), "slow.sh", allocator);
    defer allocator.free(script_path);

    var cfg = try config.parseDocument(allocator, "mixed-port: 7890\n");
    defer cfg.deinit();
    var opts = CliOptions{ .script_path = try allocator.dupe(u8, script_path), .timeout_ms = 25 };
    defer opts.deinit(allocator);
    try std.testing.expectError(
        Errors.OverrideScriptTimeout,
        apply(allocator, &cfg, &opts, "test", null),
    );
    try std.testing.expectEqual(@as(u16, 7890), cfg.mixed_port);
}

test "Lua override arguments preserve delimiters" {
    // The execution seam must transport values without delimiter re-parsing.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try tmp.dir.createFile(compat.io(), "args.lua", .{});
    try script.writeStreamingAll(
        compat.io(),
        "return { [\"bind-address\"] = input.args.value }\n",
    );
    script.close(compat.io());
    const script_path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "args.lua",
        allocator,
    );
    defer allocator.free(script_path);

    const value = "alpha;injected=beta=gamma";
    const patch = executeScriptPatch(
        allocator,
        script_path,
        &.{.{ .key = "value", .value = value }},
        2_000,
        "test",
        null,
    ) catch |err| switch (err) {
        Errors.OverrideScriptNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(patch);

    var cfg = try config.parseDocument(allocator, "bind-address: old\n");
    defer cfg.deinit();
    try applyPatch(allocator, &cfg, patch);
    try std.testing.expectEqualStrings(value, cfg.bind_address);
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

    var cfg = try config.loadDefault(allocator);
    defer cfg.deinit();
    if (cfg.external_controller) |old| allocator.free(old);
    cfg.external_controller = try allocator.dupe(u8, "127.0.0.1:9090");

    try applyPatch(allocator, &cfg, content);
    try std.testing.expectEqualStrings("global", cfg.mode);
    try std.testing.expectEqualStrings("debug", cfg.log_level);
    try std.testing.expect(cfg.allow_lan);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.bind_address);
    try std.testing.expect(cfg.external_controller == null);
}

test "invalid external-controller override preserves config ownership" {
    // A rejected patch must leave the old allocation readable and singly owned.
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(
        allocator,
        "external-controller: 127.0.0.1:9090\n",
    );
    defer cfg.deinit();

    try std.testing.expectError(
        Errors.OverrideMergeFailed,
        applyPatch(allocator, &cfg, "external-controller: false\n"),
    );
    try std.testing.expectEqualStrings(
        "127.0.0.1:9090",
        cfg.external_controller.?,
    );
}

fn applyOwnedStringPatchAllocationFixture(allocator: std.mem.Allocator) !void {
    var cfg = try config.parseDocument(
        allocator,
        "bind-address: 127.0.0.1\n" ++
            "mode: rule\n" ++
            "log-level: info\n" ++
            "external-controller: 127.0.0.1:9090\n",
    );
    defer cfg.deinit();
    try applyPatch(
        allocator,
        &cfg,
        "bind-address: 0.0.0.0\n" ++
            "mode: global\n" ++
            "log-level: debug\n" ++
            "external-controller: 127.0.0.1:9091\n",
    );
}

test "owned string overrides release every allocation failure path" {
    // Failing every allocation proves replacement never loses the old owner.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        applyOwnedStringPatchAllocationFixture,
        .{},
    );
}

test "override patch rejects malformed trailing content before mutation" {
    // Strict document parsing must reject ignored tails before applying fields.
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(allocator, "mixed-port: 7890\n");
    defer cfg.deinit();

    try std.testing.expectError(
        Errors.OverrideOutputInvalid,
        applyPatch(allocator, &cfg, "mixed-port: 9000\nnot-a-mapping\n"),
    );
    try std.testing.expectEqual(@as(u16, 7890), cfg.mixed_port);
}

test "failed override patch is atomic" {
    // A later semantic error must not expose any earlier field mutation.
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(
        allocator,
        "mixed-port: 7890\nmode: rule\n",
    );
    defer cfg.deinit();

    try std.testing.expectError(
        Errors.OverrideMergeFailed,
        applyPatch(
            allocator,
            &cfg,
            "mixed-port: 9000\nmode: global\nunsupported-field: true\n",
        ),
    );
    try std.testing.expectEqual(@as(u16, 7890), cfg.mixed_port);
    try std.testing.expectEqualStrings("rule", cfg.mode);
}

test "quoted null remains an external-controller string" {
    // YAML quoting must distinguish a string from the null scalar.
    const allocator = std.testing.allocator;
    var cfg = try config.parseDocument(
        allocator,
        "external-controller: 127.0.0.1:9090\n",
    );
    defer cfg.deinit();

    try applyPatch(allocator, &cfg, "external-controller: \"null\"\n");
    try std.testing.expectEqualStrings("null", cfg.external_controller.?);
}
