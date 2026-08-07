//! CLI 集成测试：驱动真实 `zc` 二进制，断言 envelope 形状与退出码。
//!
//! 运行环境约定（build.zig 的 test step 提供）：
//! - HOME / XDG_RUNTIME_DIR 已指向 .zig-cache 下的隔离目录，本文件的所有
//!   zc 调用绝不触碰真实用户环境或生产 daemon；
//! - cwd 为仓库根（与 main.zig 中读取 src/*.zig 的现有测试同一约定）。
//!
//! 二进制由首个用例触发 `zig build` 产出（zig-out/bin/zc），之后直接复用。

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const daemon = @import("daemon.zig");
const runtime_descriptor = @import("runtime_descriptor.zig");
const runtime_dir = @import("runtime_dir.zig");
const config = @import("config.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");
const selection_state = @import("selection_state.zig");
const state_authority = @import("state_authority.zig");

const max_output = 1024 * 1024;
const zc_binary = "zig-out/bin/zc";
const cli_awake_timeout_seconds = 60;
const build_awake_timeout_seconds = 180;

var zc_binary_ready = false;

fn awakeTimeoutSeconds(seconds: i64) std.Io.Timeout {
    return .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromSeconds(seconds),
    } };
}

fn exitCode(term: anytype) !u8 {
    return switch (term) {
        .exited => |code| code,
        else => error.AbnormalTermination,
    };
}

fn ensureZcBinary(allocator: std.mem.Allocator) !void {
    if (zc_binary_ready) return;
    const result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ "zig", "build" },
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = awakeTimeoutSeconds(build_awake_timeout_seconds),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if ((try exitCode(result.term)) != 0) {
        std.debug.print("zig build failed:\n{s}\n", .{result.stderr});
        return error.ZcBuildFailed;
    }
    zc_binary_ready = true;
}

const CliRun = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(self: *CliRun, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !CliRun {
    try ensureZcBinary(allocator);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zc_binary);
    for (args) |arg| try argv.append(allocator, arg);

    const result = try std.process.run(allocator, compat.io(), .{
        .argv = argv.items,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = awakeTimeoutSeconds(cli_awake_timeout_seconds),
    });
    errdefer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = try exitCode(result.term),
    };
}

fn runCliWithHome(
    allocator: std.mem.Allocator,
    home: []const u8,
    args: []const []const u8,
) !CliRun {
    try ensureZcBinary(allocator);
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zc_binary);
    for (args) |arg| try argv.append(allocator, arg);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    const result = try std.process.run(allocator, compat.io(), .{
        .argv = argv.items,
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = awakeTimeoutSeconds(cli_awake_timeout_seconds),
    });
    errdefer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = try exitCode(result.term),
    };
}

/// stdout 必须是恰好一行可解析的 JSON envelope。
fn parseEnvelope(
    allocator: std.mem.Allocator,
    stdout: []const u8,
) !std.json.Parsed(std.json.Value) {
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stdout, "\n"));
    return std.json.parseFromSlice(std.json.Value, allocator, stdout, .{});
}

fn expectErrorEnvelope(root: std.json.Value, command: []const u8, code: []const u8) !void {
    const obj = root.object;
    try std.testing.expect(!obj.get("ok").?.bool);
    try std.testing.expectEqualStrings(command, obj.get("command").?.string);
    const err = obj.get("error").?.object;
    try std.testing.expectEqualStrings(code, err.get("code").?.string);
    try std.testing.expect(err.get("message").?.string.len != 0);
    try std.testing.expect(err.get("hint").?.string.len != 0);
}

const config_capability_message =
    "config revision cannot be activated because it uses an unsupported runtime capability";
const download_capability_hint =
    "retry without `-d` to retain an inactive revision; inspect its raw source with " ++
    "`zc config dump -c <name> --no-override`, then fix the subscription source";
const update_capability_hint =
    "fix the subscription source, then retry `zc config update <name>`";
const use_capability_hint =
    "inspect the retained raw source with `zc config dump -c <name> --no-override`; " ++
    "fix the subscription source, then retry";
const source_resource_limit_message =
    "config exceeds resource limits: 4096 proxies, 1024 proxy groups, " ++
    "5120 mixed entries, or 5122 members per group";
const source_resource_limit_hint =
    "remove unused proxies, groups, members, or subscription banner entries and retry";
const yaml_collection_entry_limit_message =
    "config exceeds the global limit of 262144 decoded YAML collection entries";
const yaml_collection_entry_limit_hint =
    "remove unused YAML mapping entries or sequence items, including unknown extension data, and retry";
const rule_provider_count_limit_message =
    "config exceeds the limit of 4096 rule providers";
const rule_provider_count_limit_hint =
    "remove unused rule-provider declarations and retry";

fn expectCapabilityError(
    root: std.json.Value,
    command: []const u8,
    expected_hint: []const u8,
) !void {
    try expectErrorEnvelope(root, command, "CONFIG_CAPABILITY_UNSUPPORTED");
    const capability_error = root.object.get("error").?.object;
    try std.testing.expectEqualStrings(
        config_capability_message,
        capability_error.get("message").?.string,
    );
    try std.testing.expectEqualStrings(
        expected_hint,
        capability_error.get("hint").?.string,
    );
}

fn expectResourceLimitError(
    root: std.json.Value,
    command: []const u8,
    code: []const u8,
) !void {
    try expectErrorEnvelope(root, command, code);
    const resource_error = root.object.get("error").?.object;
    try std.testing.expectEqualStrings(
        source_resource_limit_message,
        resource_error.get("message").?.string,
    );
    try std.testing.expectEqualStrings(
        source_resource_limit_hint,
        resource_error.get("hint").?.string,
    );
}

fn expectRuleProviderCountLimitError(
    root: std.json.Value,
    command: []const u8,
    code: []const u8,
) !void {
    try expectErrorEnvelope(root, command, code);
    const limit_error = root.object.get("error").?.object;
    try std.testing.expectEqualStrings(
        rule_provider_count_limit_message,
        limit_error.get("message").?.string,
    );
    try std.testing.expectEqualStrings(
        rule_provider_count_limit_hint,
        limit_error.get("hint").?.string,
    );
}

fn expectConfigTooLargeError(
    root: std.json.Value,
    command: []const u8,
    code: []const u8,
    message: []const u8,
    hint: []const u8,
) !void {
    try expectErrorEnvelope(root, command, code);
    const size_error = root.object.get("error").?.object;
    try std.testing.expectEqualStrings(message, size_error.get("message").?.string);
    try std.testing.expectEqualStrings(hint, size_error.get("hint").?.string);
}

fn expectYamlCollectionEntryLimitError(
    root: std.json.Value,
    command: []const u8,
    code: []const u8,
) !void {
    try expectErrorEnvelope(root, command, code);
    const limit_error = root.object.get("error").?.object;
    try std.testing.expectEqualStrings(
        yaml_collection_entry_limit_message,
        limit_error.get("message").?.string,
    );
    try std.testing.expectEqualStrings(
        yaml_collection_entry_limit_hint,
        limit_error.get("hint").?.string,
    );
}

/// 写到 cwd（仓库根）下的 .zig-cache，返回 zc 子进程可用的相对路径。
fn writeTempConfig(allocator: std.mem.Allocator, name: []const u8, contents: []const u8) ![]u8 {
    const rel_path = try compat.fs.path.join(allocator, &.{ ".zig-cache", name });
    errdefer allocator.free(rel_path);
    const file = try std.Io.Dir.cwd().createFile(compat.io(), rel_path, .{});
    defer file.close(compat.io());
    try compat.fileWriteAll(file, contents);
    return rel_path;
}

/// 仓库 YAML 解析器要求 block-style（无 inline {}/[]）。
fn validConfigYaml(allocator: std.mem.Allocator, mixed_port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\mixed-port: {d}
        \\mode: rule
        \\log-level: info
        \\
        \\proxies:
        \\  - name: demo-ss
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: "password"
        \\
        \\proxy-groups:
        \\  - name: PROXY
        \\    type: select
        \\    proxies:
        \\      - demo-ss
        \\      - DIRECT
        \\
        \\rules:
        \\  - MATCH,PROXY
        \\
    , .{mixed_port});
}

const runtime_ready_managed_config =
    \\mixed-port: 7890
    \\proxy-groups:
    \\  - name: Proxy
    \\    type: select
    \\    proxies:
    \\      - DIRECT
    \\      - REJECT
    \\rules:
    \\  - MATCH,Proxy
;

const malformed_obfs_managed_config =
    \\mixed-port: 7890
    \\proxies:
    \\  - name: recoverable
    \\    type: ss
    \\    server: example.com
    \\    port: 8388
    \\    cipher: aes-128-gcm
    \\    password: secret
    \\    plugin: obfs
    \\    plugin-opts: "obfs=http;obfs-host=example.com"
    \\rules:
    \\  - MATCH,recoverable
;

fn makeRepeatedResourceConfig(
    allocator: std.mem.Allocator,
    header: []const u8,
    entry: []const u8,
    count: usize,
) ![]u8 {
    var document = std.ArrayList(u8).empty;
    errdefer document.deinit(allocator);
    try document.appendSlice(allocator, header);
    for (0..count) |_| try document.appendSlice(allocator, entry);
    return document.toOwnedSlice(allocator);
}

fn makeProxyCountLimitConfig(allocator: std.mem.Allocator) ![]u8 {
    return makeRepeatedResourceConfig(
        allocator,
        "proxies:\n",
        "  - { name: node, type: direct }\n",
        4097,
    );
}

fn makeRuleProviderCountLimitConfig(
    allocator: std.mem.Allocator,
) ![]u8 {
    var source = std.ArrayList(u8).empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "rule-providers:\n");
    for (0..config.rule_provider_count_max + 1) |index| {
        var line_buffer: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "  provider-{d}: {{ type: file, behavior: domain, path: p{d}.txt }}\n",
            .{ index, index },
        );
        try source.appendSlice(allocator, line);
    }
    try source.appendSlice(allocator, "rules:\n  - MATCH,DIRECT\n");
    return source.toOwnedSlice(allocator);
}

fn makeProxyGroupCountLimitConfig(allocator: std.mem.Allocator) ![]u8 {
    return makeRepeatedResourceConfig(
        allocator,
        "proxy-groups:\n",
        "  - { name: group, type: select, proxies: [DIRECT] }\n",
        1025,
    );
}

fn makeProxyGroupMemberLimitConfig(allocator: std.mem.Allocator) ![]u8 {
    return makeRepeatedResourceConfig(
        allocator,
        "proxy-groups:\n  - name: bounded\n    type: select\n    proxies:\n",
        "      - DIRECT\n",
        5123,
    );
}

fn makeProxyEntryCountLimitConfig(allocator: std.mem.Allocator) ![]u8 {
    return makeRepeatedResourceConfig(
        allocator,
        "proxies:\n",
        "  - { name: \"Traffic: quota\", type: direct }\n",
        5121,
    );
}

fn makeYamlCollectionEntryLimitConfig(
    allocator: std.mem.Allocator,
) ![]u8 {
    var source = std.ArrayList(u8).empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "unknown: [");
    for (0..config.yaml_collection_entry_count_max) |index| {
        if (index != 0) try source.append(allocator, ',');
        try source.append(allocator, '0');
    }
    try source.appendSlice(allocator, "]\n");
    return source.toOwnedSlice(allocator);
}

fn makeConfigSourceTooLarge(allocator: std.mem.Allocator) ![]u8 {
    const source = try allocator.alloc(u8, config.config_source_bytes_max + 1);
    @memset(source, ' ');
    return source;
}

fn makeOverrideMaterializationTooLargeSource(
    allocator: std.mem.Allocator,
) ![]u8 {
    const prefix = "mixed-port: 7890\nsecret: '";
    const suffix = "'\nrules:\n  - MATCH,DIRECT\n";
    const escaped_bytes = config.config_source_bytes_max / 2 + 4096;
    const source = try allocator.alloc(
        u8,
        prefix.len + escaped_bytes + suffix.len,
    );
    @memcpy(source[0..prefix.len], prefix);
    @memset(source[prefix.len .. prefix.len + escaped_bytes], '\\');
    @memcpy(source[prefix.len + escaped_bytes ..], suffix);
    return source;
}

fn writeAbsoluteFile(path: []const u8, bytes: []const u8) !void {
    const file = try compat.fs.createFileAbsolute(path, .{});
    defer file.close(compat.io());
    try compat.fileWriteAll(file, bytes);
}

fn catalogRootPathAlloc(
    allocator: std.mem.Allocator,
    home: []const u8,
) ![]u8 {
    return compat.fs.path.join(allocator, &.{ home, ".config", "zc" });
}

fn seedDesiredSelection(
    allocator: std.mem.Allocator,
    home: []const u8,
    key: []const u8,
) !void {
    const root_path = try catalogRootPathAlloc(allocator, home);
    defer allocator.free(root_path);
    const root = try compat.fs.openDirAbsolute(root_path, .{
        .follow_symlinks = false,
    });
    defer root.close(compat.io());

    var inspection = try state_authority.Authority.init(allocator, root).inspect();
    defer inspection.deinit();
    const revision = switch (inspection) {
        .catalog_v2 => |*observed| blk: {
            for (observed.catalog.state.profiles) |profile| {
                if (std.mem.eql(u8, profile.key, key)) break :blk profile.head;
            }
            return error.ManagedProfileNotFound;
        },
        .missing, .legacy_v1 => return error.Schema2CatalogRequired,
    };
    const receipt = try selection_state.State.init(allocator, root).persist(
        .{ .key = key, .revision = revision },
        "Proxy",
        "DIRECT",
    );
    try std.testing.expect(receipt.generation != null);
    try std.testing.expect(receipt.generation.? > 0);
}

fn catalogStateBytes(
    allocator: std.mem.Allocator,
    home: []const u8,
) ![]u8 {
    const root_path = try catalogRootPathAlloc(allocator, home);
    defer allocator.free(root_path);
    const root = try compat.fs.openDirAbsolute(root_path, .{
        .follow_symlinks = false,
    });
    defer root.close(compat.io());
    return root.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(config_catalog.max_catalog_bytes),
    );
}

const RevisionObjectPaths = struct {
    allocator: std.mem.Allocator,
    identity: []const u8,
    source: []const u8,
    manifest: []const u8,

    fn deinit(self: *RevisionObjectPaths) void {
        self.allocator.free(self.identity);
        self.allocator.free(self.source);
        self.allocator.free(self.manifest);
        self.* = undefined;
    }
};

fn exactRevisionObjectPaths(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    key: []const u8,
) !RevisionObjectPaths {
    var inspection = try state_authority.Authority.init(allocator, root).inspect();
    defer inspection.deinit();
    const identity = switch (inspection) {
        .catalog_v2 => |*observed| blk: {
            for (observed.catalog.state.profiles) |profile| {
                if (std.mem.eql(u8, profile.key, key)) break :blk .{
                    .storage_id = profile.storage_id,
                    .revision = profile.head,
                };
            }
            return error.ManagedProfileNotFound;
        },
        .missing, .legacy_v1 => return error.Schema2CatalogRequired,
    };
    var storage_hex: [64]u8 = undefined;
    var revision_hex: [32]u8 = undefined;
    const prefix = try std.fmt.allocPrint(
        allocator,
        "profiles/{s}/revisions/{s}",
        .{
            identity.storage_id.formatHex(&storage_hex),
            identity.revision.formatHex(&revision_hex),
        },
    );
    defer allocator.free(prefix);
    const identity_path = try std.fmt.allocPrint(
        allocator,
        "profiles/{s}/identity.json",
        .{identity.storage_id.formatHex(&storage_hex)},
    );
    errdefer allocator.free(identity_path);
    const source_path = try std.fmt.allocPrint(
        allocator,
        "{s}/source.yaml",
        .{prefix},
    );
    errdefer allocator.free(source_path);
    return .{
        .allocator = allocator,
        .identity = identity_path,
        .source = source_path,
        .manifest = try std.fmt.allocPrint(
            allocator,
            "{s}/manifest.json",
            .{prefix},
        ),
    };
}

fn overwriteCatalogObject(
    root: std.Io.Dir,
    path: []const u8,
    bytes: []const u8,
) !void {
    const file = try root.createFile(compat.io(), path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(compat.io());
    if (builtin.os.tag != .windows) {
        try file.setPermissions(
            compat.io(),
            std.Io.File.Permissions.fromMode(0o600),
        );
    }
    try compat.fileWriteAll(file, bytes);
}

fn authoritativeStateSnapshot(
    allocator: std.mem.Allocator,
    home: []const u8,
    active_key: []const u8,
) ![]u8 {
    const bytes = try catalogStateBytes(allocator, home);
    errdefer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const state = parsed.value.object;
    try std.testing.expect(state.get("sequence").?.integer > 0);
    const active = state.get("active").?.object;
    try std.testing.expectEqualStrings(active_key, active.get("key").?.string);
    try std.testing.expectEqual(@as(usize, 32), active.get("revision").?.string.len);

    var found_profile = false;
    for (state.get("profiles").?.array.items) |profile_value| {
        const profile = profile_value.object;
        if (!std.mem.eql(u8, profile.get("key").?.string, active_key)) continue;
        found_profile = true;
        try std.testing.expectEqual(@as(usize, 32), profile.get("head").?.string.len);
        const desired = profile.get("desired").?.object;
        try std.testing.expect(desired.get("generation").?.integer > 0);
        const selections = desired.get("selections").?.array.items;
        try std.testing.expect(selections.len > 0);
        try std.testing.expectEqualStrings(
            "Proxy",
            selections[0].object.get("group").?.string,
        );
        try std.testing.expectEqualStrings(
            "DIRECT",
            selections[0].object.get("proxy").?.string,
        );
    }
    try std.testing.expect(found_profile);
    return bytes;
}

fn expectAuthoritativeStateUnchanged(
    allocator: std.mem.Allocator,
    home: []const u8,
    active_key: []const u8,
    before: []const u8,
) !void {
    const after = try authoritativeStateSnapshot(allocator, home, active_key);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

fn loadBaselineWithDesiredSelection(
    allocator: std.mem.Allocator,
    home: []const u8,
) !void {
    const source_path = try compat.fs.path.join(allocator, &.{ home, "baseline.yaml" });
    defer allocator.free(source_path);
    try writeAbsoluteFile(source_path, runtime_ready_managed_config);
    var loaded = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "load", source_path, "--json" },
    );
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), loaded.code);
    try seedDesiredSelection(allocator, home, "baseline");
}

/// 绑定再立刻释放一个端口：拿到“几乎必然无人监听”的端口号。
fn reserveClosedPort() !u16 {
    const addr = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try compat.net.listenReuseAddr(addr);
    const port = listener.listen_address.getPort();
    listener.deinit();
    return port;
}

// ---------------------------------------------------------------------------
// 未知/缺失子命令：envelope + exit_usage
// ---------------------------------------------------------------------------

test "integration: profile unknown subcommand -> PROFILE_SUBCOMMAND_UNKNOWN, exit_usage" {
    const allocator = std.testing.allocator;
    // 历史漂移：曾断言 PROFILE_NOT_FOUND，但没有任何 dispatch 输出该码；
    // `profile use` 实际走 unknown-subcommand 路径。
    var run = try runCli(allocator, &.{ "profile", "use", "not-exist.yaml", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "profile use", "PROFILE_SUBCOMMAND_UNKNOWN");
}

test "integration: proxy unknown subcommand -> PROXY_SUBCOMMAND_UNKNOWN, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "proxy", "nope", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "proxy nope", "PROXY_SUBCOMMAND_UNKNOWN");
}

test "integration: diag unknown subcommand -> DIAG_SUBCOMMAND_UNKNOWN, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "diag", "nope", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "diag nope", "DIAG_SUBCOMMAND_UNKNOWN");
}

test "integration: diag with flags but no subcommand -> DIAG_SUBCOMMAND_MISSING, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "diag", "-c", "x.yaml", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "diag", "DIAG_SUBCOMMAND_MISSING");
}

test "integration: bare diag prints group help on stdout, exit 0" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{"diag"});
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), run.code);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "Usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "doctor") != null);
    try std.testing.expectEqualStrings("", run.stderr);
}

// ---------------------------------------------------------------------------
// 生命周期命令用法错误（决策 D11）：未知/多余参数、缺值 flag -> exit_usage。
// 全部在参数解析阶段失败，绝不触碰 daemon（且测试环境 HOME/XDG 已隔离）。
// ---------------------------------------------------------------------------

test "integration: start unknown flag -> START_ARGS_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "start", "--bogus", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "start", "START_ARGS_INVALID");
}

test "integration: start unknown flag text mode -> error block on stderr, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "start", "--bogus" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    try std.testing.expectEqualStrings("", run.stdout);
    try std.testing.expect(std.mem.indexOf(u8, run.stderr, "error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stderr, "START_ARGS_INVALID") != null);
}

test "integration: restart missing --port value -> START_PORT_REQUIRED, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "restart", "--port", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "restart", "START_PORT_REQUIRED");
}

test "integration: stop extra argument -> STOP_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "stop", "extra", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "stop", "STOP_ARGUMENT_INVALID");
}

test "integration: status unknown flag -> STATUS_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "status", "--bogus", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "status", "STATUS_ARGUMENT_INVALID");
}

test "integration: reload extra argument -> RELOAD_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "reload", "nope", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "reload", "RELOAD_ARGUMENT_INVALID");
}

test "integration: log invalid -n value -> LOG_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "log", "-n", "abc", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "log", "LOG_ARGUMENT_INVALID");
}

test "integration: doctor unknown flag -> DIAG_DOCTOR_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "doctor", "--bogus", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "doctor", "DIAG_DOCTOR_ARGUMENT_INVALID");
}

test "integration: diag doctor extra argument -> DIAG_DOCTOR_ARGUMENT_INVALID, exit_usage" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "diag", "doctor", "stray", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "diag doctor", "DIAG_DOCTOR_ARGUMENT_INVALID");
}

// ---------------------------------------------------------------------------
// zc test：--help、配置加载失败、CHECKS_FAILED（D3）
// ---------------------------------------------------------------------------

test "integration: zc test --help prints command help via table interception" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "test", "--help" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), run.code);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "zc test") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "--port <port>") != null);
    try std.testing.expectEqualStrings("", run.stderr);
}

test "integration: zc test config-load failure emits envelope in json mode" {
    const allocator = std.testing.allocator;
    var run = try runCli(
        allocator,
        &.{ "test", "-c", ".zig-cache/itest-definitely-missing.yaml", "--json" },
    );
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "test", "PROXY_CONFIG_LOAD_FAILED");
}

test "integration: zc test config-load failure prints error block in text mode" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "test", "-c", ".zig-cache/itest-definitely-missing.yaml" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), run.code);
    try std.testing.expect(std.mem.indexOf(u8, run.stderr, "PROXY_CONFIG_LOAD_FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "\"ok\":") == null);
}

test "integration: zc test --json fails with CHECKS_FAILED when port not listening" {
    const allocator = std.testing.allocator;

    const yaml = try validConfigYaml(allocator, 7892);
    defer allocator.free(yaml);
    const cfg_path = try writeTempConfig(allocator, "itest-test-valid.yaml", yaml);
    defer allocator.free(cfg_path);

    const closed_port = try reserveClosedPort();
    var port_buf: [8]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{closed_port});

    var run = try runCli(allocator, &.{ "test", "-c", cfg_path, "--port", port_text, "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "test", "CHECKS_FAILED");
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqualStrings("proxy_test", data.get("action").?.string);
    try std.testing.expect(data.get("daemon_state") != null);
    const ports = data.get("ports").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), ports.len);
    try std.testing.expect(!ports[0].object.get("listening").?.bool);
    try std.testing.expect(data.get("checks").?.array.items.len >= 1);
}

test "integration: zc test --json succeeds against a local responder (same probes as text)" {
    const allocator = std.testing.allocator;

    const yaml = try validConfigYaml(allocator, 7892);
    defer allocator.free(yaml);
    const cfg_path = try writeTempConfig(allocator, "itest-test-responder.yaml", yaml);
    defer allocator.free(cfg_path);

    var responder = try HttpResponder.start();
    defer responder.stop();

    var port_buf: [8]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{responder.port()});

    var run = try runCli(allocator, &.{ "test", "-c", cfg_path, "--port", port_text, "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("ok").?.bool);
    try std.testing.expectEqualStrings("test", root.get("command").?.string);
    const data = root.get("data").?.object;
    const checks = data.get("checks").?.array.items;
    for (checks) |check| try std.testing.expect(check.object.get("ok").?.bool);
    // JSON 模式跑了真探测：targets 非空（曾经 JSON 跳过全部探测、永不失败）。
    try std.testing.expect(data.get("targets").?.array.items.len > 0);
}

// ---------------------------------------------------------------------------
// zc doctor / diag doctor：CHECKS_FAILED + 配置加载失败
// ---------------------------------------------------------------------------

test "integration: zc doctor --json healthy config (stopped daemon) -> ok:true with facts" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "doctor", "-c", "testdata/config/minimal.yaml", "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("ok").?.bool);
    try std.testing.expectEqualStrings("doctor", root.get("command").?.string);
    const data = root.get("data").?.object;
    // run-soak-real.sh 依赖该字段可从 stdout 读到。
    try std.testing.expect(data.get("proxy_reachable") != null);
    try std.testing.expect(data.get("network_ok") != null);
    try std.testing.expect(data.get("config_ok").?.bool);
    try std.testing.expectEqual(@as(usize, 2), data.get("checks").?.array.items.len);
}

test "integration: zc doctor --json invalid config -> CHECKS_FAILED with config_errors" {
    const allocator = std.testing.allocator;

    // 可解析但通不过校验：组引用未定义节点。
    const yaml =
        \\mixed-port: 7892
        \\mode: rule
        \\log-level: info
        \\
        \\proxies:
        \\  - name: demo-ss
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: "password"
        \\
        \\proxy-groups:
        \\  - name: PROXY
        \\    type: select
        \\    proxies:
        \\      - no-such-node
        \\
        \\rules:
        \\  - MATCH,PROXY
        \\
    ;
    const cfg_path = try writeTempConfig(allocator, "itest-doctor-invalid.yaml", yaml);
    defer allocator.free(cfg_path);

    var run = try runCli(allocator, &.{ "doctor", "-c", cfg_path, "--json" });
    defer run.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), run.code);
    var parsed = try parseEnvelope(allocator, run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "doctor", "CHECKS_FAILED");
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expect(!data.get("config_ok").?.bool);
    try std.testing.expect(data.get("config_errors").?.array.items.len > 0);
    try std.testing.expect(data.get("proxy_reachable") != null);
}

test "integration: doctor config-load failure -> DIAG_DOCTOR_FAILED in both modes" {
    const allocator = std.testing.allocator;

    var json_run = try runCli(
        allocator,
        &.{ "doctor", "-c", ".zig-cache/itest-definitely-missing.yaml", "--json" },
    );
    defer json_run.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), json_run.code);
    var parsed = try parseEnvelope(allocator, json_run.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(parsed.value, "doctor", "DIAG_DOCTOR_FAILED");

    // text 模式曾被 json-only guard 吞错（裸 Zig trace）；现在必须有错误块。
    var text_run = try runCli(
        allocator,
        &.{ "doctor", "-c", ".zig-cache/itest-definitely-missing.yaml" },
    );
    defer text_run.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), text_run.code);
    try std.testing.expect(std.mem.indexOf(u8, text_run.stderr, "DIAG_DOCTOR_FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_run.stderr, "panic") == null);
}

test "integration: zc doctor text keeps frozen labels and exit 0 on healthy config" {
    const allocator = std.testing.allocator;
    var run = try runCli(allocator, &.{ "doctor", "-c", "testdata/config/minimal.yaml" });
    defer run.deinit(allocator);

    // Healthy offline diagnostics keep stable labels and return success.
    try std.testing.expectEqual(@as(u8, 0), run.code);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "Config: OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "Daemon:") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "PID:") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "Port:") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "Connection:") != null);
}

// ---------------------------------------------------------------------------
// 本地 HTTP 应答器：配置订阅与连通性探测都只访问测试沙箱。
// ---------------------------------------------------------------------------

const fixture_listener_poll_ms: i64 = 100;
const fixture_connection_timeout_ms: i64 = 5000;
const fixture_socket_none: std.posix.fd_t = -1;

const ResponderStartOptions = struct {
    inject_thread_spawn_failure: bool = false,
    observed_port: ?*u16 = null,
};

const FixtureDeadline = struct {
    expires_ms: i64,

    fn init(timeout_ms: i64) FixtureDeadline {
        std.debug.assert(timeout_ms > 0);
        return .{
            .expires_ms = std.math.add(
                i64,
                compat.monotonicMilliTimestamp(),
                timeout_ms,
            ) catch std.math.maxInt(i64),
        };
    }

    fn remaining(self: FixtureDeadline) !i32 {
        const now_ms = compat.monotonicMilliTimestamp();
        if (now_ms >= self.expires_ms) return error.DeadlineExceeded;
        const remaining_ms = std.math.sub(
            i64,
            self.expires_ms,
            now_ms,
        ) catch return error.DeadlineExceeded;
        return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
    }
};

fn fixtureWaitForEvents(
    fd: std.posix.fd_t,
    requested: i16,
    deadline: FixtureDeadline,
) !i16 {
    while (true) {
        var descriptors = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = requested,
            .revents = 0,
        }};
        const result = std.c.poll(
            descriptors[0..].ptr,
            @intCast(descriptors.len),
            try deadline.remaining(),
        );
        if (result < 0) {
            switch (std.c.errno(result)) {
                .INTR => continue,
                .NOMEM => return error.SystemResources,
                else => return error.PollFailed,
            }
        }
        if (result == 0) continue;
        const events = descriptors[0].revents;
        if (events & std.posix.POLL.NVAL != 0) return error.InvalidSocket;
        if (events &
            (requested | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)
        {
            return events;
        }
        return error.UnexpectedPollEvent;
    }
}

fn fixtureWriteAllWithinStop(
    fd: std.posix.fd_t,
    bytes: []const u8,
    deadline: FixtureDeadline,
    stop_flag: ?*const std.atomic.Value(bool),
    backpressure_observed: ?*std.atomic.Value(bool),
) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (stop_flag) |flag| {
            if (flag.load(.acquire)) return error.ResponderStopped;
        }
        // Check the same monotonic absolute deadline before every send attempt,
        // including retries after EINTR, partial writes, and writable sockets.
        _ = try deadline.remaining();
        const flags: u32 = if (@hasDecl(std.c.MSG, "NOSIGNAL"))
            @intCast(std.c.MSG.NOSIGNAL)
        else
            0;
        const result = std.c.send(
            fd,
            bytes[offset..].ptr,
            bytes.len - offset,
            flags,
        );
        if (result < 0) {
            switch (std.c.errno(result)) {
                .INTR => continue,
                // Zig exposes the equal EAGAIN/EWOULDBLOCK errno as AGAIN.
                .AGAIN => {
                    if (backpressure_observed) |observed| {
                        observed.store(true, .release);
                    }
                    _ = try fixtureWaitForEvents(
                        fd,
                        std.posix.POLL.OUT,
                        deadline,
                    );
                    continue;
                },
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .BADF => return error.NotOpenForWriting,
                else => return error.SocketWriteFailed,
            }
        }
        if (result == 0) return error.WriteZero;
        const count: usize = @intCast(result);
        if (count > bytes.len - offset) return error.InvalidWriteCount;
        offset = std.math.add(usize, offset, count) catch
            return error.LengthOverflow;
    }
}

fn fixtureWriteAllWithin(
    fd: std.posix.fd_t,
    bytes: []const u8,
    deadline: FixtureDeadline,
) !void {
    return fixtureWriteAllWithinStop(fd, bytes, deadline, null, null);
}

fn fixtureConfigureRawSendSocket(fd: std.posix.fd_t) !void {
    if (comptime builtin.os.tag.isDarwin() and
        @hasDecl(std.c.SO, "NOSIGPIPE"))
    {
        var enabled: c_int = 1;
        if (std.c.setsockopt(
            fd,
            std.c.SOL.SOCKET,
            std.c.SO.NOSIGPIPE,
            std.mem.asBytes(&enabled),
            @sizeOf(c_int),
        ) != 0) return error.SocketSetupFailed;
    }
}

fn fixtureExpectNoSigpipe(fd: std.posix.fd_t) !void {
    if (comptime !builtin.os.tag.isDarwin() or
        !@hasDecl(std.c.SO, "NOSIGPIPE")) return;

    var enabled: c_int = 0;
    var enabled_size: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.NOSIGPIPE,
        std.mem.asBytes(&enabled).ptr,
        &enabled_size,
    ) != 0) return error.SocketOptionFailed;
    try std.testing.expectEqual(@as(c_int, 1), enabled);
}

fn fixtureConnectWithin(
    address: compat.net.Address,
    deadline: FixtureDeadline,
) !compat.net.Stream {
    const fd = std.c.socket(
        std.c.AF.INET,
        std.c.SOCK.STREAM,
        std.c.IPPROTO.TCP,
    );
    if (fd < 0) return error.SocketSetupFailed;
    errdefer _ = std.c.close(fd);
    try fixtureConfigureRawSendSocket(fd);
    try compat.setNonBlock(fd);
    const socket_address = address.in.sa;
    while (true) {
        const result = std.c.connect(
            fd,
            @ptrCast(&socket_address),
            @sizeOf(std.c.sockaddr.in),
        );
        if (result == 0) return .{ .handle = fd };
        switch (std.c.errno(result)) {
            .INTR => continue,
            .ISCONN => return .{ .handle = fd },
            .INPROGRESS, .ALREADY, .AGAIN => break,
            .CONNREFUSED => return error.ConnectionRefused,
            else => return error.ConnectFailed,
        }
    }
    _ = try fixtureWaitForEvents(fd, std.posix.POLL.OUT, deadline);
    var socket_error: c_int = 0;
    var socket_error_size: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.ERROR,
        &socket_error,
        &socket_error_size,
    ) != 0) return error.ConnectFailed;
    if (socket_error != 0) return error.ConnectFailed;
    return .{ .handle = fd };
}

fn fixtureReadHttpRequest(
    fd: std.posix.fd_t,
    buffer: []u8,
    stop_flag: *const std.atomic.Value(bool),
) !void {
    const deadline = FixtureDeadline.init(fixture_connection_timeout_ms);
    var used: usize = 0;
    while (used < buffer.len) {
        if (stop_flag.load(.acquire)) return error.ResponderStopped;
        _ = try fixtureWaitForEvents(fd, std.posix.POLL.IN, deadline);
        const result = std.c.recv(fd, buffer[used..].ptr, buffer.len - used, 0);
        if (result < 0) {
            switch (std.c.errno(result)) {
                .INTR, .AGAIN => continue,
                .CONNRESET => return error.ConnectionResetByPeer,
                .BADF => return error.NotOpenForReading,
                else => return error.SocketReadFailed,
            }
        }
        if (result == 0) return error.UnexpectedEndOfStream;
        used = std.math.add(usize, used, @intCast(result)) catch
            return error.LengthOverflow;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n") != null) return;
    }
    return error.RequestTooLarge;
}

fn fixtureClaimActiveFd(
    active_fd: *std.atomic.Value(std.posix.fd_t),
    active_lock: *std.Io.Mutex,
    stop_flag: *const std.atomic.Value(bool),
    fd: std.posix.fd_t,
) bool {
    active_lock.lockUncancelable(compat.io());
    defer active_lock.unlock(compat.io());
    if (stop_flag.load(.acquire)) return false;
    std.debug.assert(active_fd.load(.acquire) == fixture_socket_none);
    active_fd.store(fd, .release);
    return true;
}

fn fixtureReleaseActiveFd(
    active_fd: *std.atomic.Value(std.posix.fd_t),
    active_lock: *std.Io.Mutex,
    fd: std.posix.fd_t,
) void {
    active_lock.lockUncancelable(compat.io());
    defer active_lock.unlock(compat.io());
    std.debug.assert(active_fd.load(.acquire) == fd);
    active_fd.store(fixture_socket_none, .release);
    _ = std.c.close(fd);
}

fn fixtureWakeActiveFd(
    active_fd: *std.atomic.Value(std.posix.fd_t),
    active_lock: *std.Io.Mutex,
) void {
    active_lock.lockUncancelable(compat.io());
    defer active_lock.unlock(compat.io());
    const fd = active_fd.load(.acquire);
    if (fd == fixture_socket_none) return;
    for (0..4) |_| {
        const result = std.c.shutdown(fd, std.c.SHUT.RDWR);
        if (result == 0) return;
        switch (std.c.errno(result)) {
            .INTR => continue,
            .BADF, .INVAL, .NOTCONN => return,
            else => return,
        }
    }
}

fn fixtureWaitForActiveFd(
    active_fd: *const std.atomic.Value(std.posix.fd_t),
    timeout_ms: i64,
) !void {
    const deadline = FixtureDeadline.init(timeout_ms);
    while (true) {
        if (active_fd.load(.acquire) != fixture_socket_none) return;
        const remaining_ms = try deadline.remaining();
        compat.sleepNs(
            @as(u64, @intCast(@min(remaining_ms, 1))) *
                std.time.ns_per_ms,
        );
    }
}

fn fixtureWaitForTrueUntil(
    value: *const std.atomic.Value(bool),
    deadline: FixtureDeadline,
) !void {
    while (true) {
        if (value.load(.acquire)) return;
        const remaining_ms = try deadline.remaining();
        compat.sleepNs(
            @as(u64, @intCast(@min(remaining_ms, 1))) *
                std.time.ns_per_ms,
        );
    }
}

fn fixtureWaitForTrue(
    value: *const std.atomic.Value(bool),
    timeout_ms: i64,
) !void {
    try fixtureWaitForTrueUntil(value, FixtureDeadline.init(timeout_ms));
}

const ConfigHttpResponder = struct {
    listener: compat.net.ReuseAddrListener,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    active_fd: std.atomic.Value(std.posix.fd_t),
    active_lock: std.Io.Mutex,
    request_index: std.atomic.Value(usize),
    response_started: std.atomic.Value(bool),
    backpressure_observed: std.atomic.Value(bool),
    responses: []const []const u8,

    fn start(responses: []const []const u8) !*ConfigHttpResponder {
        return startWithOptions(responses, .{});
    }

    fn startWithOptions(
        responses: []const []const u8,
        options: ResponderStartOptions,
    ) !*ConfigHttpResponder {
        std.debug.assert(responses.len > 0);
        const self = try std.heap.page_allocator.create(ConfigHttpResponder);
        errdefer std.heap.page_allocator.destroy(self);
        const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
        const listener = try compat.net.listenReuseAddr(address);
        self.* = .{
            .listener = listener,
            .thread = undefined,
            .stop_flag = .init(false),
            .active_fd = .init(fixture_socket_none),
            .active_lock = .init,
            .request_index = .init(0),
            .response_started = .init(false),
            .backpressure_observed = .init(false),
            .responses = responses,
        };
        errdefer self.listener.deinit();
        try compat.setNonBlock(self.listener.fd);
        if (options.observed_port) |observed| observed.* = self.port();
        if (options.inject_thread_spawn_failure) {
            return error.InjectedThreadSpawnFailure;
        }
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
        return self;
    }

    fn port(self: *const ConfigHttpResponder) u16 {
        return self.listener.listen_address.getPort();
    }

    fn urlAlloc(
        self: *ConfigHttpResponder,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "http://127.0.0.1:{d}/config.yaml",
            .{self.port()},
        );
    }

    fn waitForResponseStart(
        self: *const ConfigHttpResponder,
        timeout_ms: i64,
    ) !void {
        try fixtureWaitForTrue(&self.response_started, timeout_ms);
    }

    fn waitForBackpressure(
        self: *const ConfigHttpResponder,
        deadline: FixtureDeadline,
    ) !void {
        try fixtureWaitForTrueUntil(&self.backpressure_observed, deadline);
    }

    fn stop(self: *ConfigHttpResponder) void {
        self.stop_flag.store(true, .release);
        fixtureWakeActiveFd(&self.active_fd, &self.active_lock);
        self.thread.join();
        std.debug.assert(
            self.active_fd.load(.acquire) == fixture_socket_none,
        );
        self.listener.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn serveLoop(self: *ConfigHttpResponder) void {
        while (true) {
            if (self.stop_flag.load(.acquire)) return;
            _ = fixtureWaitForEvents(
                self.listener.fd,
                std.posix.POLL.IN,
                FixtureDeadline.init(fixture_listener_poll_ms),
            ) catch |err| switch (err) {
                error.DeadlineExceeded => continue,
                else => return,
            };
            if (self.stop_flag.load(.acquire)) return;
            const connection = self.listener.accept() catch |err| switch (err) {
                error.WouldBlock, error.ConnectionAborted => continue,
                else => return,
            };
            const fd = connection.stream.handle;
            fixtureConfigureRawSendSocket(fd) catch {
                _ = std.c.close(fd);
                continue;
            };
            compat.setNonBlock(fd) catch {
                _ = std.c.close(fd);
                continue;
            };
            if (!fixtureClaimActiveFd(
                &self.active_fd,
                &self.active_lock,
                &self.stop_flag,
                fd,
            )) {
                _ = std.c.close(fd);
                return;
            }
            self.serveConnection(fd);
            fixtureReleaseActiveFd(
                &self.active_fd,
                &self.active_lock,
                fd,
            );
        }
    }

    fn serveConnection(
        self: *ConfigHttpResponder,
        fd: std.posix.fd_t,
    ) void {
        var request_buffer: [4096]u8 = undefined;
        fixtureReadHttpRequest(
            fd,
            &request_buffer,
            &self.stop_flag,
        ) catch return;
        const request_index = self.request_index.fetchAdd(1, .monotonic);
        const response_index = @min(request_index, self.responses.len - 1);
        const response_body = self.responses[response_index];
        var header_buffer: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buffer,
            "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n" ++
                "Content-Type: application/yaml\r\nConnection: close\r\n\r\n",
            .{response_body.len},
        ) catch return;
        self.response_started.store(true, .release);
        const deadline = FixtureDeadline.init(fixture_connection_timeout_ms);
        fixtureWriteAllWithinStop(
            fd,
            header,
            deadline,
            &self.stop_flag,
            &self.backpressure_observed,
        ) catch return;
        fixtureWriteAllWithinStop(
            fd,
            response_body,
            deadline,
            &self.stop_flag,
            &self.backpressure_observed,
        ) catch return;
    }
};

const HttpResponder = struct {
    listener: compat.net.ReuseAddrListener,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    active_fd: std.atomic.Value(std.posix.fd_t),
    active_lock: std.Io.Mutex,

    fn start() !*HttpResponder {
        return startWithOptions(.{});
    }

    fn startWithOptions(
        options: ResponderStartOptions,
    ) !*HttpResponder {
        const self = try std.heap.page_allocator.create(HttpResponder);
        errdefer std.heap.page_allocator.destroy(self);
        const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
        const listener = try compat.net.listenReuseAddr(address);
        self.* = .{
            .listener = listener,
            .thread = undefined,
            .stop_flag = .init(false),
            .active_fd = .init(fixture_socket_none),
            .active_lock = .init,
        };
        errdefer self.listener.deinit();
        try compat.setNonBlock(self.listener.fd);
        if (options.observed_port) |observed| observed.* = self.port();
        if (options.inject_thread_spawn_failure) {
            return error.InjectedThreadSpawnFailure;
        }
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
        return self;
    }

    fn port(self: *const HttpResponder) u16 {
        return self.listener.listen_address.getPort();
    }

    fn waitForActiveConnection(
        self: *const HttpResponder,
        timeout_ms: i64,
    ) !void {
        try fixtureWaitForActiveFd(&self.active_fd, timeout_ms);
    }

    fn stop(self: *HttpResponder) void {
        self.stop_flag.store(true, .release);
        fixtureWakeActiveFd(&self.active_fd, &self.active_lock);
        self.thread.join();
        std.debug.assert(
            self.active_fd.load(.acquire) == fixture_socket_none,
        );
        self.listener.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn serveLoop(self: *HttpResponder) void {
        while (true) {
            if (self.stop_flag.load(.acquire)) return;
            _ = fixtureWaitForEvents(
                self.listener.fd,
                std.posix.POLL.IN,
                FixtureDeadline.init(fixture_listener_poll_ms),
            ) catch |err| switch (err) {
                error.DeadlineExceeded => continue,
                else => return,
            };
            if (self.stop_flag.load(.acquire)) return;
            const connection = self.listener.accept() catch |err| switch (err) {
                error.WouldBlock, error.ConnectionAborted => continue,
                else => return,
            };
            const fd = connection.stream.handle;
            fixtureConfigureRawSendSocket(fd) catch {
                _ = std.c.close(fd);
                continue;
            };
            compat.setNonBlock(fd) catch {
                _ = std.c.close(fd);
                continue;
            };
            if (!fixtureClaimActiveFd(
                &self.active_fd,
                &self.active_lock,
                &self.stop_flag,
                fd,
            )) {
                _ = std.c.close(fd);
                return;
            }
            self.serveConnection(fd);
            fixtureReleaseActiveFd(
                &self.active_fd,
                &self.active_lock,
                fd,
            );
        }
    }

    fn serveConnection(
        self: *HttpResponder,
        fd: std.posix.fd_t,
    ) void {
        var request_buffer: [4096]u8 = undefined;
        fixtureReadHttpRequest(
            fd,
            &request_buffer,
            &self.stop_flag,
        ) catch return;
        fixtureWriteAllWithinStop(
            fd,
            "HTTP/1.1 204 No Content\r\n" ++
                "Content-Length: 0\r\nConnection: close\r\n\r\n",
            FixtureDeadline.init(fixture_connection_timeout_ms),
            &self.stop_flag,
            null,
        ) catch return;
    }
};

test "HTTP fixture listener cleanup runs when thread spawn fails" {
    var config_port: u16 = 0;
    try std.testing.expectError(
        error.InjectedThreadSpawnFailure,
        ConfigHttpResponder.startWithOptions(&.{"ok\n"}, .{
            .inject_thread_spawn_failure = true,
            .observed_port = &config_port,
        }),
    );
    const config_address = try compat.net.Address.parseIp4(
        "127.0.0.1",
        config_port,
    );
    var config_listener = try compat.net.listenReuseAddr(config_address);
    config_listener.deinit();

    var probe_port: u16 = 0;
    try std.testing.expectError(
        error.InjectedThreadSpawnFailure,
        HttpResponder.startWithOptions(.{
            .inject_thread_spawn_failure = true,
            .observed_port = &probe_port,
        }),
    );
    const probe_address = try compat.net.Address.parseIp4(
        "127.0.0.1",
        probe_port,
    );
    var probe_listener = try compat.net.listenReuseAddr(probe_address);
    probe_listener.deinit();
}

test "HTTP fixture stop wakes a stalled accepted request" {
    var responder = try HttpResponder.start();
    var stopped = false;
    defer if (!stopped) responder.stop();
    const address = try compat.net.Address.parseIp4(
        "127.0.0.1",
        responder.port(),
    );
    const client = try fixtureConnectWithin(
        address,
        FixtureDeadline.init(500),
    );
    defer client.close();
    try responder.waitForActiveConnection(1000);

    const started_ms = compat.monotonicMilliTimestamp();
    responder.stop();
    stopped = true;
    try std.testing.expect(
        compat.monotonicMilliTimestamp() - started_ms < 3000,
    );
}

test "fixture write rejects an expired deadline before a writable one-byte send" {
    var descriptors: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(
            @intCast(std.posix.AF.UNIX),
            @intCast(std.posix.SOCK.STREAM),
            0,
            &descriptors,
        ),
    );
    defer _ = std.c.close(descriptors[0]);
    defer _ = std.c.close(descriptors[1]);
    try fixtureConfigureRawSendSocket(descriptors[0]);

    var writable = [_]std.posix.pollfd{.{
        .fd = descriptors[0],
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    try std.testing.expectEqual(
        @as(usize, 1),
        try std.posix.poll(&writable, 0),
    );
    try std.testing.expect(writable[0].revents & std.posix.POLL.OUT != 0);

    try std.testing.expectError(
        error.DeadlineExceeded,
        fixtureWriteAllWithinStop(
            descriptors[0],
            "x",
            .{ .expires_ms = compat.monotonicMilliTimestamp() },
            null,
            null,
        ),
    );

    var readable = [_]std.posix.pollfd{.{
        .fd = descriptors[1],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(
        @as(usize, 0),
        try std.posix.poll(&readable, 0),
    );
}

test "config HTTP fixture raw-send sockets suppress SIGPIPE on macOS" {
    var responder = try ConfigHttpResponder.start(&.{"ok\n"});
    var stopped = false;
    defer if (!stopped) responder.stop();
    const deadline = FixtureDeadline.init(2000);
    const address = try compat.net.Address.parseIp4(
        "127.0.0.1",
        responder.port(),
    );
    const client = try fixtureConnectWithin(address, deadline);
    defer client.close();
    try fixtureWaitForActiveFd(&responder.active_fd, try deadline.remaining());

    try fixtureExpectNoSigpipe(client.handle);
    const accepted_fd = responder.active_fd.load(.acquire);
    try std.testing.expect(accepted_fd != fixture_socket_none);
    try fixtureExpectNoSigpipe(accepted_fd);

    responder.stop();
    stopped = true;
    _ = try deadline.remaining();
}

test "config HTTP fixture stop wakes a backpressured response" {
    const allocator = std.testing.allocator;
    const body = try allocator.alloc(u8, config.config_source_bytes_max);
    defer allocator.free(body);
    @memset(body, 'x');
    var responder = try ConfigHttpResponder.start(&.{body});
    var stopped = false;
    defer if (!stopped) responder.stop();
    const total_deadline = FixtureDeadline.init(5000);
    const address = try compat.net.Address.parseIp4(
        "127.0.0.1",
        responder.port(),
    );
    const client = try fixtureConnectWithin(address, total_deadline);
    defer client.close();
    var receive_buffer_bytes: c_int = 1024;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.setsockopt(
            client.handle,
            std.c.SOL.SOCKET,
            std.c.SO.RCVBUF,
            std.mem.asBytes(&receive_buffer_bytes),
            @sizeOf(c_int),
        ),
    );
    try fixtureWriteAllWithin(
        client.handle,
        "GET /config.yaml HTTP/1.1\r\nHost: local\r\n\r\n",
        total_deadline,
    );
    try responder.waitForBackpressure(total_deadline);

    responder.stop();
    stopped = true;
    _ = try total_deadline.remaining();
}

fn connectController(port: u16) !compat.net.Stream {
    const address = try compat.net.Address.parseIp4("127.0.0.1", port);
    return compat.net.tcpConnectToAddress(address);
}

fn waitForController(port: u16) !void {
    for (0..250) |_| {
        if (connectController(port)) |stream| {
            stream.close();
            return;
        } else |_| {}
        compat.sleepNs(20 * std.time.ns_per_ms);
    }
    return error.ControllerStartTimeout;
}

fn waitForControllerResponse(port: u16) !void {
    for (0..100) |_| {
        if (connectController(port)) |stream| {
            defer stream.close();
            stream.writeAll("GET /version HTTP/1.1\r\nHost: local\r\n\r\n") catch {
                compat.sleepNs(20 * std.time.ns_per_ms);
                continue;
            };
            var response_buffer: [4096]u8 = undefined;
            const response = readResponseWithin(
                stream,
                &response_buffer,
                100,
            ) catch {
                compat.sleepNs(20 * std.time.ns_per_ms);
                continue;
            };
            if (std.mem.indexOf(u8, response, "200 OK") != null) return;
        } else |_| {}
        compat.sleepNs(20 * std.time.ns_per_ms);
    }
    return error.ControllerResponseTimeout;
}

fn responseContentLength(header: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    _ = lines.next() orelse return error.InvalidHttpResponse;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch
            error.InvalidHttpResponse;
    }
    return error.InvalidHttpResponse;
}

fn readResponseWithin(
    stream: compat.net.Stream,
    buffer: []u8,
    timeout_ms: i32,
) ![]const u8 {
    const deadline = compat.monotonicMilliTimestamp() + timeout_ms;
    var used: usize = 0;
    while (true) {
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |header_end| {
            const body_length = try responseContentLength(buffer[0..header_end]);
            const total = header_end + 4 + body_length;
            if (total > buffer.len) return error.ResponseTooLarge;
            if (used >= total) return buffer[0..total];
        }
        if (used == buffer.len) return error.ResponseTooLarge;
        const remaining = deadline - compat.monotonicMilliTimestamp();
        if (remaining <= 0) return error.ResponseTimeout;
        var descriptors = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(
            &descriptors,
            @intCast(@min(remaining, std.math.maxInt(i32))),
        );
        if (ready == 0) return error.ResponseTimeout;
        const count = stream.read(buffer[used..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (count == 0) return error.UnexpectedEndOfStream;
        used += count;
    }
}

fn stopIsolatedDaemon(
    allocator: std.mem.Allocator,
    environment: *std.process.Environ.Map,
) void {
    const result = std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "stop", "--json" },
        .environ_map = environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

test "integration: special pid files fail without blocking" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.setDirPermissions(
        tmp.dir,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const pid_path = try compat.fs.path.join(allocator, &.{ root, "zc.pid" });
    defer allocator.free(pid_path);
    const made = try compat.childRun(allocator, &.{ "mkfifo", pid_path }, max_output);
    defer allocator.free(made.stdout);
    defer allocator.free(made.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(made.term));

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("XDG_RUNTIME_DIR", root);
    const result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(1),
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(result.term));
    var envelope = try parseEnvelope(allocator, result.stdout);
    defer envelope.deinit();
    try expectErrorEnvelope(envelope.value, "status", "STATUS_FAILED");
}

test "integration: config load reports proxy count limit without state mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);
    try loadBaselineWithDesiredSelection(allocator, home);

    const oversized = try makeProxyCountLimitConfig(allocator);
    defer allocator.free(oversized);
    const source_path = try compat.fs.path.join(
        allocator,
        &.{ home, "too-many-proxies.yaml" },
    );
    defer allocator.free(source_path);
    try writeAbsoluteFile(source_path, oversized);
    const before = try authoritativeStateSnapshot(allocator, home, "baseline");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "load", source_path, "--json" },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var rejected_envelope = try parseEnvelope(allocator, rejected.stdout);
    defer rejected_envelope.deinit();
    try expectResourceLimitError(
        rejected_envelope.value,
        "config load",
        "CONFIG_LOAD_LIMIT_EXCEEDED",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "baseline",
        before,
    );
}

test "integration: config load maps rule-provider count limit without state mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);
    try loadBaselineWithDesiredSelection(allocator, home);

    const oversized = try makeRuleProviderCountLimitConfig(allocator);
    defer allocator.free(oversized);
    const source_path = try compat.fs.path.join(
        allocator,
        &.{ home, "too-many-rule-providers.yaml" },
    );
    defer allocator.free(source_path);
    try writeAbsoluteFile(source_path, oversized);
    const before = try authoritativeStateSnapshot(allocator, home, "baseline");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "load", source_path, "--json" },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var envelope = try parseEnvelope(allocator, rejected.stdout);
    defer envelope.deinit();
    try expectRuleProviderCountLimitError(
        envelope.value,
        "config load",
        "CONFIG_LOAD_LIMIT_EXCEEDED",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "baseline",
        before,
    );
}

test "integration: config load maps global YAML collection entry limit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);
    try loadBaselineWithDesiredSelection(allocator, home);

    const oversized = try makeYamlCollectionEntryLimitConfig(allocator);
    defer allocator.free(oversized);
    try std.testing.expect(oversized.len < 1024 * 1024);
    const source_path = try compat.fs.path.join(
        allocator,
        &.{ home, "too-many-yaml-entries.yaml" },
    );
    defer allocator.free(source_path);
    try writeAbsoluteFile(source_path, oversized);
    const before = try authoritativeStateSnapshot(allocator, home, "baseline");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "load", source_path, "--json" },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var rejected_envelope = try parseEnvelope(allocator, rejected.stdout);
    defer rejected_envelope.deinit();
    try expectYamlCollectionEntryLimitError(
        rejected_envelope.value,
        "config load",
        "CONFIG_LOAD_LIMIT_EXCEEDED",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "baseline",
        before,
    );
}

test "integration: config download maps rule-provider count limit without state mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);
    try loadBaselineWithDesiredSelection(allocator, home);

    const oversized = try makeRuleProviderCountLimitConfig(allocator);
    defer allocator.free(oversized);
    var responder = try ConfigHttpResponder.start(&.{oversized});
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);
    const before = try authoritativeStateSnapshot(allocator, home, "baseline");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{
            "config",
            "download",
            url,
            "-n",
            "too-many-rule-providers",
            "--json",
        },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var envelope = try parseEnvelope(allocator, rejected.stdout);
    defer envelope.deinit();
    try expectRuleProviderCountLimitError(
        envelope.value,
        "config download",
        "CONFIG_DOWNLOAD_LIMIT_EXCEEDED",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "baseline",
        before,
    );
}

test "integration: config download reports group count limit without state mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);
    try loadBaselineWithDesiredSelection(allocator, home);

    const oversized = try makeProxyGroupCountLimitConfig(allocator);
    defer allocator.free(oversized);
    var responder = try ConfigHttpResponder.start(&.{oversized});
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);
    const before = try authoritativeStateSnapshot(allocator, home, "baseline");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{
            "config",
            "download",
            url,
            "-n",
            "too-many-groups",
            "--json",
        },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var rejected_envelope = try parseEnvelope(allocator, rejected.stdout);
    defer rejected_envelope.deinit();
    try expectResourceLimitError(
        rejected_envelope.value,
        "config download",
        "CONFIG_DOWNLOAD_LIMIT_EXCEEDED",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "baseline",
        before,
    );
}

test "integration: config update maps rule-provider count limit without state mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);
    const oversized = try makeRuleProviderCountLimitConfig(allocator);
    defer allocator.free(oversized);
    var responder = try ConfigHttpResponder.start(&.{
        runtime_ready_managed_config,
        oversized,
    });
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);

    var initial = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "download", url, "-n", "primary", "--json" },
    );
    defer initial.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), initial.code);
    try seedDesiredSelection(allocator, home, "primary");
    const before = try authoritativeStateSnapshot(allocator, home, "primary");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "update", "primary", "--json" },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var envelope = try parseEnvelope(allocator, rejected.stdout);
    defer envelope.deinit();
    try expectRuleProviderCountLimitError(
        envelope.value,
        "config update",
        "CONFIG_UPDATE_LIMIT_EXCEEDED",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "primary",
        before,
    );
}

test "integration: config update reports group member limit without state mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);
    const oversized = try makeProxyGroupMemberLimitConfig(allocator);
    defer allocator.free(oversized);
    var responder = try ConfigHttpResponder.start(&.{
        runtime_ready_managed_config,
        oversized,
    });
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);

    var initial = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "download", url, "-n", "primary", "--json" },
    );
    defer initial.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), initial.code);
    try seedDesiredSelection(allocator, home, "primary");
    const before = try authoritativeStateSnapshot(allocator, home, "primary");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "update", "primary", "--json" },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var rejected_envelope = try parseEnvelope(allocator, rejected.stdout);
    defer rejected_envelope.deinit();
    try expectResourceLimitError(
        rejected_envelope.value,
        "config update",
        "CONFIG_UPDATE_LIMIT_EXCEEDED",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "primary",
        before,
    );
}

test "integration: config download maps mixed proxy entry limit without state mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);
    try loadBaselineWithDesiredSelection(allocator, home);

    const oversized = try makeProxyEntryCountLimitConfig(allocator);
    defer allocator.free(oversized);
    var responder = try ConfigHttpResponder.start(&.{oversized});
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);
    const before = try authoritativeStateSnapshot(allocator, home, "baseline");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "download", url, "-n", "too-many-entries", "--json" },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            rejected.stderr,
            "ProxyEntryCountLimitExceeded",
        ) != null,
    );
    var rejected_envelope = try parseEnvelope(allocator, rejected.stdout);
    defer rejected_envelope.deinit();
    try expectResourceLimitError(
        rejected_envelope.value,
        "config download",
        "CONFIG_DOWNLOAD_LIMIT_EXCEEDED",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "baseline",
        before,
    );
}

test "integration: config load maps 16 MiB plus one without state mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);
    try loadBaselineWithDesiredSelection(allocator, home);

    const oversized = try makeConfigSourceTooLarge(allocator);
    defer allocator.free(oversized);
    const source_path = try compat.fs.path.join(
        allocator,
        &.{ home, "too-large.yaml" },
    );
    defer allocator.free(source_path);
    try writeAbsoluteFile(source_path, oversized);
    const before = try authoritativeStateSnapshot(allocator, home, "baseline");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "load", source_path, "--json" },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var rejected_envelope = try parseEnvelope(allocator, rejected.stdout);
    defer rejected_envelope.deinit();
    try expectConfigTooLargeError(
        rejected_envelope.value,
        "config load",
        "CONFIG_LOAD_TOO_LARGE",
        "local config exceeds the 16 MiB limit",
        "reduce the complete config source to 16 MiB or less and retry",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "baseline",
        before,
    );
}

test "integration: config download maps 16 MiB plus one without state mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);
    try loadBaselineWithDesiredSelection(allocator, home);

    const oversized = try makeConfigSourceTooLarge(allocator);
    defer allocator.free(oversized);
    var responder = try ConfigHttpResponder.start(&.{oversized});
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);
    const before = try authoritativeStateSnapshot(allocator, home, "baseline");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "download", url, "-n", "too-large", "--json" },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var rejected_envelope = try parseEnvelope(allocator, rejected.stdout);
    defer rejected_envelope.deinit();
    try expectConfigTooLargeError(
        rejected_envelope.value,
        "config download",
        "CONFIG_DOWNLOAD_TOO_LARGE",
        "downloaded config exceeds the 16 MiB limit",
        "reduce the config size and retry",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "baseline",
        before,
    );
}

test "integration: config update maps 16 MiB plus one without state mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);

    const oversized = try makeConfigSourceTooLarge(allocator);
    defer allocator.free(oversized);
    var responder = try ConfigHttpResponder.start(&.{
        runtime_ready_managed_config,
        oversized,
    });
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);
    var initial = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "download", url, "-n", "primary", "--json" },
    );
    defer initial.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), initial.code);
    try seedDesiredSelection(allocator, home, "primary");
    const before = try authoritativeStateSnapshot(allocator, home, "primary");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "update", "primary", "--json" },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var rejected_envelope = try parseEnvelope(allocator, rejected.stdout);
    defer rejected_envelope.deinit();
    try expectConfigTooLargeError(
        rejected_envelope.value,
        "config update",
        "CONFIG_UPDATE_TOO_LARGE",
        "updated config exceeds the 16 MiB limit",
        "reduce the config size and retry",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "primary",
        before,
    );
}

test "integration: persisted override update maps materialized size and preserves state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);

    const expanded = try makeOverrideMaterializationTooLargeSource(allocator);
    defer allocator.free(expanded);
    var responder = try ConfigHttpResponder.start(&.{
        runtime_ready_managed_config,
        expanded,
    });
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);

    var initial = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "download", url, "-n", "primary", "--json" },
    );
    defer initial.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), initial.code);

    const script_path = try compat.fs.path.join(
        allocator,
        &.{ home, "persisted-override.sh" },
    );
    defer allocator.free(script_path);
    try writeAbsoluteFile(
        script_path,
        "#!/bin/sh\nprintf 'mixed-port: 9000\\n'\n",
    );
    var overridden = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "override", script_path, "--json" },
    );
    defer overridden.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), overridden.code);
    try seedDesiredSelection(allocator, home, "primary");

    const before = try authoritativeStateSnapshot(allocator, home, "primary");
    defer allocator.free(before);
    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "update", "primary", "--json" },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var rejected_envelope = try parseEnvelope(allocator, rejected.stdout);
    defer rejected_envelope.deinit();
    try expectConfigTooLargeError(
        rejected_envelope.value,
        "config update",
        "CONFIG_UPDATE_TOO_LARGE",
        "updated config exceeds the 16 MiB limit",
        "reduce the config size and retry",
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "primary",
        before,
    );
}

test "integration: malformed first download stays inactive and -d preserves exact state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);

    var responder = try ConfigHttpResponder.start(&.{
        malformed_obfs_managed_config,
        runtime_ready_managed_config,
        malformed_obfs_managed_config,
    });
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);

    var retained = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "download", url, "-n", "recovery", "--json" },
    );
    defer retained.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), retained.code);
    var retained_envelope = try parseEnvelope(allocator, retained.stdout);
    defer retained_envelope.deinit();
    const retained_data = retained_envelope.value.object.get("data").?.object;
    try std.testing.expectEqualStrings(
        "recovery",
        retained_data.get("name").?.string,
    );
    try std.testing.expect(!retained_data.get("set_default").?.bool);

    var dumped = try runCliWithHome(
        allocator,
        home,
        &.{
            "config",
            "dump",
            "-c",
            "recovery",
            "--no-override",
        },
    );
    defer dumped.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), dumped.code);
    try std.testing.expect(std.mem.indexOf(
        u8,
        dumped.stdout,
        "plugin-opts: \"obfs=http;obfs-host=example.com\"",
    ) != null);
    var inspected = try config.parseCatalogDocument(allocator, dumped.stdout);
    defer inspected.deinit();
    try std.testing.expectEqual(
        config.ProxySemanticState.malformed,
        inspected.proxies.items[0].semantic_state,
    );

    var listed = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "list", "--json" },
    );
    defer listed.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    var list_envelope = try parseEnvelope(allocator, listed.stdout);
    defer list_envelope.deinit();
    const list_data = list_envelope.value.object.get("data").?.object;
    try std.testing.expect(
        list_data.get("active") == null or list_data.get("active").? == .null,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        list_data.get("configs").?.array.items.len,
    );

    var first_ready = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "download", url, "-n", "ready", "--json" },
    );
    defer first_ready.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), first_ready.code);
    var ready_envelope = try parseEnvelope(allocator, first_ready.stdout);
    defer ready_envelope.deinit();
    try std.testing.expect(
        ready_envelope.value.object.get("data").?.object.get(
            "set_default",
        ).?.bool,
    );
    try seedDesiredSelection(allocator, home, "ready");
    const before = try authoritativeStateSnapshot(allocator, home, "ready");
    defer allocator.free(before);

    var rejected = try runCliWithHome(
        allocator,
        home,
        &.{
            "config",
            "download",
            url,
            "-n",
            "explicit-active",
            "-d",
            "--json",
        },
    );
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected.code);
    var rejected_envelope = try parseEnvelope(allocator, rejected.stdout);
    defer rejected_envelope.deinit();
    try expectCapabilityError(
        rejected_envelope.value,
        "config download",
        download_capability_hint,
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "ready",
        before,
    );

    var ready_list = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "list", "--json" },
    );
    defer ready_list.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), ready_list.code);
    var ready_list_envelope = try parseEnvelope(allocator, ready_list.stdout);
    defer ready_list_envelope.deinit();
    const ready_list_data = ready_list_envelope.value.object.get(
        "data",
    ).?.object;
    try std.testing.expectEqualStrings(
        "ready",
        ready_list_data.get("active").?.string,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        ready_list_data.get("configs").?.array.items.len,
    );
}

test "integration: malformed raw dump fails closed for corrupt revision objects" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Corruption = enum {
        identity,
        source,
        manifest,
        unsafe_source_permissions,
    };
    const cases = [_]struct {
        home_name: []const u8,
        corruption: Corruption,
    }{
        .{ .home_name = "identity-home", .corruption = .identity },
        .{ .home_name = "source-home", .corruption = .source },
        .{ .home_name = "manifest-home", .corruption = .manifest },
        .{
            .home_name = "permissions-home",
            .corruption = .unsafe_source_permissions,
        },
    };
    var responder = try ConfigHttpResponder.start(&.{
        malformed_obfs_managed_config,
    });
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);

    for (cases) |case| {
        if (case.corruption == .unsafe_source_permissions and
            builtin.os.tag == .windows)
        {
            continue;
        }
        try tmp.dir.createDir(compat.io(), case.home_name, .default_dir);
        const home = try tmp.dir.realPathFileAlloc(
            compat.io(),
            case.home_name,
            allocator,
        );
        defer allocator.free(home);
        var retained = try runCliWithHome(
            allocator,
            home,
            &.{ "config", "download", url, "-n", "recovery", "--json" },
        );
        defer retained.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0), retained.code);

        const state_before = try catalogStateBytes(allocator, home);
        defer allocator.free(state_before);
        const root_path = try catalogRootPathAlloc(allocator, home);
        defer allocator.free(root_path);
        const root = try compat.fs.openDirAbsolute(root_path, .{
            .follow_symlinks = false,
        });
        defer root.close(compat.io());
        var paths = try exactRevisionObjectPaths(
            allocator,
            root,
            "recovery",
        );
        defer paths.deinit();
        switch (case.corruption) {
            .identity => try overwriteCatalogObject(
                root,
                paths.identity,
                "raw-secret-never-print: corrupt identity\n",
            ),
            .source => try overwriteCatalogObject(
                root,
                paths.source,
                "password: raw-secret-never-print\n",
            ),
            .manifest => try overwriteCatalogObject(
                root,
                paths.manifest,
                "{\"raw-secret-never-print\":true}\n",
            ),
            .unsafe_source_permissions => {
                const source = try root.openFile(
                    compat.io(),
                    paths.source,
                    .{},
                );
                defer source.close(compat.io());
                try source.setPermissions(
                    compat.io(),
                    std.Io.File.Permissions.fromMode(0o644),
                );
            },
        }

        var rejected = try runCliWithHome(
            allocator,
            home,
            &.{
                "config",
                "dump",
                "-c",
                "recovery",
                "--no-override",
            },
        );
        defer rejected.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 1), rejected.code);
        try std.testing.expectEqualStrings("", rejected.stdout);
        try std.testing.expect(std.mem.indexOf(
            u8,
            rejected.stdout,
            "raw-secret-never-print",
        ) == null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            rejected.stdout,
            "password: secret",
        ) == null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            rejected.stdout,
            "plugin-opts",
        ) == null);
        const state_after = try catalogStateBytes(allocator, home);
        defer allocator.free(state_after);
        try std.testing.expectEqualStrings(state_before, state_after);
    }
}

test "integration: active update and use capability failures preserve exact state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    const home = try tmp.dir.realPathFileAlloc(compat.io(), "home", allocator);
    defer allocator.free(home);

    var responder = try ConfigHttpResponder.start(&.{
        runtime_ready_managed_config,
        malformed_obfs_managed_config,
        malformed_obfs_managed_config,
    });
    defer responder.stop();
    const url = try responder.urlAlloc(allocator);
    defer allocator.free(url);

    var initial = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "download", url, "-n", "primary", "--json" },
    );
    defer initial.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), initial.code);
    var recovery = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "download", url, "-n", "recovery", "--json" },
    );
    defer recovery.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), recovery.code);
    try seedDesiredSelection(allocator, home, "primary");
    const before = try authoritativeStateSnapshot(allocator, home, "primary");
    defer allocator.free(before);

    var rejected_update = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "update", "primary", "--json" },
    );
    defer rejected_update.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected_update.code);
    var update_envelope = try parseEnvelope(allocator, rejected_update.stdout);
    defer update_envelope.deinit();
    try expectCapabilityError(
        update_envelope.value,
        "config update",
        update_capability_hint,
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "primary",
        before,
    );

    var rejected_use = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "use", "recovery", "--json" },
    );
    defer rejected_use.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), rejected_use.code);
    var use_envelope = try parseEnvelope(allocator, rejected_use.stdout);
    defer use_envelope.deinit();
    try expectCapabilityError(
        use_envelope.value,
        "config use",
        use_capability_hint,
    );
    try expectAuthoritativeStateUnchanged(
        allocator,
        home,
        "primary",
        before,
    );
}

test "integration: malformed plugin legacy config migrates for inspection but cannot start" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(
        compat.io(),
        "home/.config/zc/configs",
    );
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "home/.config/zc/configs/legacy.yaml",
        .data =
        \\mixed-port: 7891
        \\proxies:
        \\  - name: legacy-obfs
        \\    type: ss
        \\    server: 127.0.0.1
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: test-password
        \\    plugin: obfs
        \\    plugin-opts: "obfs=http"
        \\proxy-groups:
        \\  - name: Proxy
        \\    type: select
        \\    proxies: [legacy-obfs]
        \\rules:
        \\  - MATCH,Proxy
        \\
        ,
    });
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "home/.config/zc/meta.json",
        .data = "{\"active\":null,\"configs\":{\"legacy\":{}}}\n",
    });
    const home = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "home",
        allocator,
    );
    defer allocator.free(home);

    var listed = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "list", "--json" },
    );
    defer listed.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    var list_envelope = try parseEnvelope(allocator, listed.stdout);
    defer list_envelope.deinit();
    const list_data = list_envelope.value.object.get("data").?.object;
    try std.testing.expect(
        list_data.get("active") == null or
            list_data.get("active").? == .null,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        list_data.get("configs").?.array.items.len,
    );

    var unselected_start = try runCliWithHome(
        allocator,
        home,
        &.{ "start", "--port", "65123", "--json" },
    );
    defer unselected_start.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), unselected_start.code);
    var unselected_envelope = try parseEnvelope(
        allocator,
        unselected_start.stdout,
    );
    defer unselected_envelope.deinit();
    try expectErrorEnvelope(
        unselected_envelope.value,
        "start",
        "START_CONFIG_NOT_SELECTED",
    );

    var unselected_restart = try runCliWithHome(
        allocator,
        home,
        &.{ "restart", "--port", "65123", "--json" },
    );
    defer unselected_restart.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), unselected_restart.code);
    var restart_envelope = try parseEnvelope(
        allocator,
        unselected_restart.stdout,
    );
    defer restart_envelope.deinit();
    try expectErrorEnvelope(
        restart_envelope.value,
        "restart",
        "RESTART_CONFIG_NOT_SELECTED",
    );

    var selected = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "use", "legacy", "--json" },
    );
    defer selected.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), selected.code);
    var selected_envelope = try parseEnvelope(allocator, selected.stdout);
    defer selected_envelope.deinit();
    try expectCapabilityError(
        selected_envelope.value,
        "config use",
        use_capability_hint,
    );

    var unsupported_start = try runCliWithHome(
        allocator,
        home,
        &.{ "start", "--port", "65123", "--json" },
    );
    defer unsupported_start.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), unsupported_start.code);
    var unsupported_envelope = try parseEnvelope(
        allocator,
        unsupported_start.stdout,
    );
    defer unsupported_envelope.deinit();
    try expectErrorEnvelope(
        unsupported_envelope.value,
        "start",
        "START_CONFIG_NOT_SELECTED",
    );

    var deleted = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "delete", "legacy", "--json" },
    );
    defer deleted.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), deleted.code);
}

test "integration: restart preserves running daemon after active profile deletion" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "source.yaml",
        .data = "mixed-port: 7891\nrules:\n  - MATCH,DIRECT\n",
    });
    const home = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "home",
        allocator,
    );
    defer allocator.free(home);
    const source_path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "source.yaml",
        allocator,
    );
    defer allocator.free(source_path);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    defer stopIsolatedDaemon(allocator, &environment);

    var loaded = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "load", source_path, "--json" },
    );
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), loaded.code);
    var load_envelope = try parseEnvelope(allocator, loaded.stdout);
    defer load_envelope.deinit();
    const key = load_envelope.value.object.get("data").?.object.get(
        "name",
    ).?.string;
    const port = try reserveClosedPort();
    var port_buffer: [16]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{port});

    var started = try runCliWithHome(
        allocator,
        home,
        &.{ "start", "--port", port_text, "--json" },
    );
    defer started.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    var start_envelope = try parseEnvelope(allocator, started.stdout);
    defer start_envelope.deinit();
    const started_pid = start_envelope.value.object.get("data").?.object.get(
        "pid",
    ).?.integer;

    var deleted = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "delete", key, "--json" },
    );
    defer deleted.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), deleted.code);

    var restarted = try runCliWithHome(
        allocator,
        home,
        &.{ "restart", "--json" },
    );
    defer restarted.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), restarted.code);
    var restart_envelope = try parseEnvelope(allocator, restarted.stdout);
    defer restart_envelope.deinit();
    try expectErrorEnvelope(
        restart_envelope.value,
        "restart",
        "RESTART_CONFIG_NOT_SELECTED",
    );

    var status = try runCliWithHome(
        allocator,
        home,
        &.{ "status", "--json" },
    );
    defer status.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), status.code);
    var status_envelope = try parseEnvelope(allocator, status.stdout);
    defer status_envelope.deinit();
    const status_data = status_envelope.value.object.get("data").?.object;
    try std.testing.expectEqualStrings(
        "running",
        status_data.get("state").?.string,
    );
    try std.testing.expectEqual(started_pid, status_data.get("pid").?.integer);

    const replacement_port = try reserveClosedPort();
    var replacement_port_buffer: [16]u8 = undefined;
    const replacement_port_text = try std.fmt.bufPrint(
        &replacement_port_buffer,
        "{d}",
        .{replacement_port},
    );
    var recovered = try runCliWithHome(
        allocator,
        home,
        &.{
            "restart",
            "-c",
            source_path,
            "--port",
            replacement_port_text,
            "--json",
        },
    );
    defer recovered.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), recovered.code);
    var recovered_envelope = try parseEnvelope(allocator, recovered.stdout);
    defer recovered_envelope.deinit();
    const recovered_pid = recovered_envelope.value.object.get(
        "data",
    ).?.object.get("pid").?.integer;
    try std.testing.expect(recovered_pid != started_pid);
}

test "integration: corrupt metadata fails closed without replacement" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(
        compat.io(),
        "home/.config/zc/configs",
    );
    const home = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "home",
        allocator,
    );
    defer allocator.free(home);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);

    for ([_][]const u8{ "{not-json\n", "" }) |corrupt_metadata| {
        try tmp.dir.writeFile(compat.io(), .{
            .sub_path = "home/.config/zc/meta.json",
            .data = corrupt_metadata,
        });
        const result = try std.process.run(allocator, compat.io(), .{
            .argv = &.{ zc_binary, "config", "list", "--json" },
            .environ_map = &environment,
            .stdout_limit = .limited(max_output),
            .stderr_limit = .limited(max_output),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(
            @as(u8, 1),
            try exitCode(result.term),
        );
        var parsed = try parseEnvelope(allocator, result.stdout);
        defer parsed.deinit();
        try expectErrorEnvelope(
            parsed.value,
            "config list",
            "CONFIG_LIST_FAILED",
        );
        const preserved = try tmp.dir.readFileAlloc(
            compat.io(),
            "home/.config/zc/meta.json",
            allocator,
            .limited(64),
        );
        defer allocator.free(preserved);
        try std.testing.expectEqualStrings(corrupt_metadata, preserved);
    }
}

test "integration: catalog without active config does not fall back during dump" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "home", .default_dir);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "source.yaml",
        .data = "mixed-port: 7890\n",
    });
    const home = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "home",
        allocator,
    );
    defer allocator.free(home);
    const source = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "source.yaml",
        allocator,
    );
    defer allocator.free(source);

    var loaded = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "load", source, "--json" },
    );
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), loaded.code);
    var load_envelope = try parseEnvelope(allocator, loaded.stdout);
    defer load_envelope.deinit();
    const load_data = load_envelope.value.object.get("data").?.object;
    try std.testing.expect(!load_data.get("durability_uncertain").?.bool);
    try std.testing.expect(!load_data.get("mirror_out_of_sync").?.bool);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "home/.config/zc/configs/ghost.yaml",
        .data = "mixed-port: 7000\n",
    });
    const ghost_path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "home/.config/zc/configs/ghost.yaml",
        allocator,
    );
    defer allocator.free(ghost_path);
    var ghost_dump = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "dump", "-c", ghost_path, "--json" },
    );
    defer ghost_dump.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), ghost_dump.code);
    var ghost_envelope = try parseEnvelope(allocator, ghost_dump.stdout);
    defer ghost_envelope.deinit();
    try expectErrorEnvelope(
        ghost_envelope.value,
        "config dump",
        "CONFIG_DUMP_FAILED",
    );

    var deleted = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "delete", "source", "--json" },
    );
    defer deleted.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), deleted.code);

    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "home/.config/zc/meta.json",
        .data = "{not-a-mirror\n",
    });
    var listed = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "list", "--json" },
    );
    defer listed.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    var list_envelope = try parseEnvelope(allocator, listed.stdout);
    defer list_envelope.deinit();
    const list_data = list_envelope.value.object.get("data").?.object;
    try std.testing.expect(!list_data.get("durability_uncertain").?.bool);
    try std.testing.expect(list_data.get("mirror_out_of_sync").?.bool);

    var dumped = try runCliWithHome(
        allocator,
        home,
        &.{ "config", "dump", "--json" },
    );
    defer dumped.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), dumped.code);
    var envelope = try parseEnvelope(allocator, dumped.stdout);
    defer envelope.deinit();
    try expectErrorEnvelope(envelope.value, "config dump", "CONFIG_DUMP_FAILED");
}

test "integration: missing active config does not fall back to direct" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(
        compat.io(),
        "home/.config/zc/configs",
    );
    const metadata =
        "{\"active\":\"missing\",\"configs\":{\"missing\":{}}}\n";
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "home/.config/zc/meta.json",
        .data = metadata,
    });
    const home = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "home",
        allocator,
    );
    defer allocator.free(home);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);

    const result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "proxy", "list", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(result.term));
    var parsed = try parseEnvelope(allocator, result.stdout);
    defer parsed.deinit();
    try expectErrorEnvelope(
        parsed.value,
        "proxy list",
        "PROXY_CONFIG_LOAD_FAILED",
    );

    const override_result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "config", "override", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(override_result.stdout);
    defer allocator.free(override_result.stderr);
    try std.testing.expectEqual(
        @as(u8, 1),
        try exitCode(override_result.term),
    );
    var override_envelope = try parseEnvelope(
        allocator,
        override_result.stdout,
    );
    defer override_envelope.deinit();
    try expectErrorEnvelope(
        override_envelope.value,
        "config override",
        "CONFIG_OVERRIDE_FAILED",
    );
}

test "integration: configured missing runtime directory fails closed" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const missing = try compat.fs.path.join(allocator, &.{ root, "missing" });
    defer allocator.free(missing);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("XDG_RUNTIME_DIR", missing);

    const result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(result.term));
    var envelope = try parseEnvelope(allocator, result.stdout);
    defer envelope.deinit();
    try expectErrorEnvelope(envelope.value, "status", "STATUS_FAILED");
}

test "integration: startup preserves endpoint validation errors" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_path = try compat.fs.path.join(
        allocator,
        &.{ root, "invalid.yaml" },
    );
    defer allocator.free(config_path);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    try tmp.dir.createDirPath(compat.io(), "home/.config/zc");
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "home/.config/zc/meta.json",
        .data = "{corrupt-legacy-metadata\n",
    });

    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "invalid.yaml",
        .data =
        \\allow-lan: true
        \\bind-address: invalid-address
        \\mixed-port: 7891
        \\proxies: []
        \\rules:
        \\  - MATCH,DIRECT
        \\
        ,
    });
    for ([_][]const []const u8{
        &.{
            zc_binary,
            "start",
            "--foreground",
            "-c",
            config_path,
            "--json",
        },
        &.{ zc_binary, "start", "-c", config_path, "--json" },
    }) |argv| {
        const result = try std.process.run(allocator, compat.io(), .{
            .argv = argv,
            .environ_map = &environment,
            .stdout_limit = .limited(max_output),
            .stderr_limit = .limited(max_output),
            .timeout = .{ .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromSeconds(5),
            } },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 1), try exitCode(result.term));
        var envelope = try parseEnvelope(allocator, result.stdout);
        defer envelope.deinit();
        try expectErrorEnvelope(
            envelope.value,
            "start",
            "START_BIND_ADDRESS_INVALID",
        );
    }

    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "invalid.yaml",
        .data =
        \\mixed-port: 7891
        \\external-controller: localhost:9090
        \\proxies: []
        \\rules:
        \\  - MATCH,DIRECT
        \\
        ,
    });
    const controller = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(controller.stdout);
    defer allocator.free(controller.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(controller.term));
    var controller_envelope = try parseEnvelope(allocator, controller.stdout);
    defer controller_envelope.deinit();
    try expectErrorEnvelope(
        controller_envelope.value,
        "start",
        "START_EXTERNAL_CONTROLLER_INVALID",
    );
}

test "integration: reserved proxy names fail before outbound dial" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home/.config");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_path = try compat.fs.path.join(
        allocator,
        &.{ root, "reserved.yaml" },
    );
    defer allocator.free(config_path);

    const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var outbound_listener = try compat.net.listenReuseAddr(address);
    defer outbound_listener.deinit();
    const mixed_port = try reserveClosedPort();
    const source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nproxies:\n  - name: DIRECT\n    type: ss\n    server: 127.0.0.1\n    port: {d}\n    cipher: aes-128-gcm\n    password: secret\nrules:\n  - MATCH,DIRECT\n",
        .{ mixed_port, outbound_listener.listen_address.getPort() },
    );
    defer allocator.free(source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "reserved.yaml",
        .data = source,
    });

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    const result = try std.process.run(allocator, compat.io(), .{
        .argv = &.{
            zc_binary,
            "start",
            "--foreground",
            "-c",
            config_path,
            "--json",
        },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(result.term));
    var envelope = try parseEnvelope(allocator, result.stdout);
    defer envelope.deinit();
    try std.testing.expect(!envelope.value.object.get("ok").?.bool);

    var descriptors = [_]std.posix.pollfd{.{
        .fd = outbound_listener.fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(
        @as(usize, 0),
        try std.posix.poll(&descriptors, 0),
    );
}

test "integration: provisional startup is not reported as running" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_path = try compat.fs.path.join(
        allocator,
        &.{ root, "startup.yaml" },
    );
    defer allocator.free(config_path);
    const script_path = try compat.fs.path.join(
        allocator,
        &.{ root, "slow-override.sh" },
    );
    defer allocator.free(script_path);
    const mixed_port = try reserveClosedPort();
    const source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nproxies: []\nrules:\n  - MATCH,DIRECT\n",
        .{mixed_port},
    );
    defer allocator.free(source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "startup.yaml",
        .data = source,
    });
    const script = try tmp.dir.createFile(
        compat.io(),
        "slow-override.sh",
        .{ .permissions = std.Io.File.Permissions.fromMode(0o700) },
    );
    try compat.fileWriteAll(script, "#!/bin/sh\nsleep 1\nprintf '{}\\n'\n");
    script.close(compat.io());

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    defer stopIsolatedDaemon(allocator, &environment);

    const start_argv = [_][]const u8{
        zc_binary,
        "start",
        "-c",
        config_path,
        "--override-script",
        script_path,
        "--json",
    };
    var first = try std.process.spawn(compat.io(), .{
        .argv = &start_argv,
        .environ_map = &environment,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer first.kill(compat.io());

    var saw_provisional = false;
    var provisional_pid: ?i32 = null;
    var daemon_paused = false;
    defer if (daemon_paused) {
        std.posix.kill(provisional_pid.?, std.posix.SIG.CONT) catch {};
    };
    var attempt: u8 = 0;
    while (attempt < 120) : (attempt += 1) {
        const bytes = tmp.dir.readFileAlloc(
            compat.io(),
            "run/zc.daemon.json",
            allocator,
            .limited(64 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                compat.sleepNs(25 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        defer allocator.free(bytes);
        var descriptor = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            bytes,
            .{},
        );
        defer descriptor.deinit();
        if (!descriptor.value.object.get("ready").?.bool) {
            const pid_value = descriptor.value.object.get("pid").?.integer;
            if (pid_value <= 0 or pid_value > std.math.maxInt(i32)) {
                return error.TestUnexpectedResult;
            }
            provisional_pid = @intCast(pid_value);
            try std.posix.kill(provisional_pid.?, std.posix.SIG.STOP);
            daemon_paused = true;
            saw_provisional = true;
            break;
        }
    }
    if (saw_provisional) {
        const status = try std.process.run(allocator, compat.io(), .{
            .argv = &.{ zc_binary, "status", "--json" },
            .environ_map = &environment,
            .stdout_limit = .limited(max_output),
            .stderr_limit = .limited(max_output),
        });
        defer allocator.free(status.stdout);
        defer allocator.free(status.stderr);
        try std.testing.expectEqual(@as(u8, 1), try exitCode(status.term));
        var status_envelope = try parseEnvelope(allocator, status.stdout);
        defer status_envelope.deinit();
        try expectErrorEnvelope(status_envelope.value, "status", "STATUS_FAILED");
        try std.posix.kill(provisional_pid.?, std.posix.SIG.CONT);
        daemon_paused = false;
    }

    const concurrent = try std.process.run(allocator, compat.io(), .{
        .argv = &start_argv,
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(concurrent.stdout);
    defer allocator.free(concurrent.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(concurrent.term));
    var concurrent_envelope = try parseEnvelope(allocator, concurrent.stdout);
    defer concurrent_envelope.deinit();
    try std.testing.expectEqualStrings(
        "already_running",
        concurrent_envelope.value.object.get("data").?.object.get("detail").?.string,
    );
    try std.testing.expectEqual(@as(u8, 0), try exitCode(try first.wait(compat.io())));
    const ready = try connectController(mixed_port);
    ready.close();
}

test "integration: restart preparation failure keeps the old daemon running" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const old_path = try compat.fs.path.join(allocator, &.{ root, "old.yaml" });
    defer allocator.free(old_path);
    const target_path = try compat.fs.path.join(allocator, &.{ root, "target.yaml" });
    defer allocator.free(target_path);
    const old_port = try reserveClosedPort();
    var target_port = try reserveClosedPort();
    while (target_port == old_port) target_port = try reserveClosedPort();
    var unavailable_port = try reserveClosedPort();
    while (unavailable_port == old_port or unavailable_port == target_port) {
        unavailable_port = try reserveClosedPort();
    }
    const old_source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nproxies: []\nrules:\n  - MATCH,DIRECT\n",
        .{old_port},
    );
    defer allocator.free(old_source);
    const target_source = try std.fmt.allocPrint(
        allocator,
        \\mixed-port: {d}
        \\rule-providers:
        \\  remote:
        \\    type: http
        \\    behavior: domain
        \\    url: http://127.0.0.1:{d}/rules.yaml
        \\    path: remote.yaml
        \\rules:
        \\  - RULE-SET,remote,DIRECT
        \\  - MATCH,DIRECT
        \\
    ,
        .{ target_port, unavailable_port },
    );
    defer allocator.free(target_source);
    try tmp.dir.writeFile(compat.io(), .{ .sub_path = "old.yaml", .data = old_source });
    try tmp.dir.writeFile(compat.io(), .{ .sub_path = "target.yaml", .data = target_source });

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    defer stopIsolatedDaemon(allocator, &environment);

    const started = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", old_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(started.stdout);
    defer allocator.free(started.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(started.term));
    var start_envelope = try parseEnvelope(allocator, started.stdout);
    defer start_envelope.deinit();
    const old_pid = start_envelope.value.object.get("data").?.object.get("pid").?.integer;

    const restarted = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "restart", "-c", target_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(restarted.stdout);
    defer allocator.free(restarted.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(restarted.term));

    const status = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(status.stdout);
    defer allocator.free(status.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(status.term));
    var status_envelope = try parseEnvelope(allocator, status.stdout);
    defer status_envelope.deinit();
    try std.testing.expectEqual(
        old_pid,
        status_envelope.value.object.get("data").?.object.get("pid").?.integer,
    );
    const old_listener = try connectController(old_port);
    old_listener.close();
}

test "integration: restart never stops a daemon that replaced its captured instance" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const first_path = try compat.fs.path.join(allocator, &.{ root, "first.yaml" });
    defer allocator.free(first_path);
    const second_path = try compat.fs.path.join(allocator, &.{ root, "second.yaml" });
    defer allocator.free(second_path);
    const target_path = try compat.fs.path.join(allocator, &.{ root, "target.yaml" });
    defer allocator.free(target_path);
    const script_path = try compat.fs.path.join(allocator, &.{ root, "slow.sh" });
    defer allocator.free(script_path);
    const marker_path = try compat.fs.path.join(allocator, &.{ root, "entered" });
    defer allocator.free(marker_path);
    const first_port = try reserveClosedPort();
    var second_port = try reserveClosedPort();
    while (second_port == first_port) second_port = try reserveClosedPort();
    var target_port = try reserveClosedPort();
    while (target_port == first_port or target_port == second_port) {
        target_port = try reserveClosedPort();
    }
    const first_source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nrules:\n  - MATCH,DIRECT\n",
        .{first_port},
    );
    defer allocator.free(first_source);
    const second_source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nrules:\n  - MATCH,DIRECT\n",
        .{second_port},
    );
    defer allocator.free(second_source);
    const target_source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nrules:\n  - MATCH,DIRECT\n",
        .{target_port},
    );
    defer allocator.free(target_source);
    const script_source = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\ntouch \"{s}\"\nsleep 3\nprintf '{{}}\\n'\n",
        .{marker_path},
    );
    defer allocator.free(script_source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "first.yaml",
        .data = first_source,
    });
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "second.yaml",
        .data = second_source,
    });
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "target.yaml",
        .data = target_source,
    });
    const script = try tmp.dir.createFile(compat.io(), "slow.sh", .{
        .permissions = std.Io.File.Permissions.fromMode(0o700),
    });
    try compat.fileWriteAll(script, script_source);
    script.close(compat.io());

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    defer stopIsolatedDaemon(allocator, &environment);

    const first = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", first_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(first.stdout);
    defer allocator.free(first.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(first.term));

    const restart_argv = [_][]const u8{
        zc_binary,
        "restart",
        "-c",
        target_path,
        "--override-script",
        script_path,
        "--json",
    };
    var restart = try std.process.spawn(compat.io(), .{
        .argv = &restart_argv,
        .environ_map = &environment,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var restart_running = true;
    defer if (restart_running) restart.kill(compat.io());
    var marker_seen = false;
    var attempt: u8 = 0;
    while (attempt < 80) : (attempt += 1) {
        tmp.dir.access(compat.io(), "entered", .{}) catch {
            compat.sleepNs(25 * std.time.ns_per_ms);
            continue;
        };
        marker_seen = true;
        break;
    }
    try std.testing.expect(marker_seen);

    const stopped = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "stop", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(stopped.stdout);
    defer allocator.free(stopped.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(stopped.term));
    const second = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", second_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(second.stdout);
    defer allocator.free(second.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(second.term));
    var second_envelope = try parseEnvelope(allocator, second.stdout);
    defer second_envelope.deinit();
    const second_pid = second_envelope.value.object.get("data").?.object.get("pid").?.integer;

    const restart_term = try restart.wait(compat.io());
    restart_running = false;
    try std.testing.expectEqual(@as(u8, 1), try exitCode(restart_term));
    const status = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(status.stdout);
    defer allocator.free(status.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(status.term));
    var status_envelope = try parseEnvelope(allocator, status.stdout);
    defer status_envelope.deinit();
    try std.testing.expectEqual(
        second_pid,
        status_envelope.value.object.get("data").?.object.get("pid").?.integer,
    );
    const second_listener = try connectController(second_port);
    second_listener.close();
}

test "integration: restart child uses the immutable parent-prepared config" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const old_path = try compat.fs.path.join(allocator, &.{ root, "old.yaml" });
    defer allocator.free(old_path);
    const target_path = try compat.fs.path.join(allocator, &.{ root, "target.yaml" });
    defer allocator.free(target_path);
    const script_path = try compat.fs.path.join(allocator, &.{ root, "slow.sh" });
    defer allocator.free(script_path);
    const marker_path = try compat.fs.path.join(allocator, &.{ root, "entered" });
    defer allocator.free(marker_path);
    const old_port = try reserveClosedPort();
    var prepared_port = try reserveClosedPort();
    while (prepared_port == old_port) prepared_port = try reserveClosedPort();
    var mutated_port = try reserveClosedPort();
    while (mutated_port == old_port or mutated_port == prepared_port) {
        mutated_port = try reserveClosedPort();
    }
    const old_source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nrules:\n  - MATCH,DIRECT\n",
        .{old_port},
    );
    defer allocator.free(old_source);
    const prepared_source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nrules:\n  - MATCH,DIRECT\n",
        .{prepared_port},
    );
    defer allocator.free(prepared_source);
    const mutated_source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nrules:\n  - MATCH,DIRECT\n",
        .{mutated_port},
    );
    defer allocator.free(mutated_source);
    const script_source = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\ntouch \"{s}\"\nsleep 2\nprintf '{{}}\\n'\n",
        .{marker_path},
    );
    defer allocator.free(script_source);
    try tmp.dir.writeFile(compat.io(), .{ .sub_path = "old.yaml", .data = old_source });
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "target.yaml",
        .data = prepared_source,
    });
    const script = try tmp.dir.createFile(compat.io(), "slow.sh", .{
        .permissions = std.Io.File.Permissions.fromMode(0o700),
    });
    try compat.fileWriteAll(script, script_source);
    script.close(compat.io());

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    defer stopIsolatedDaemon(allocator, &environment);
    const started = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", old_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(started.stdout);
    defer allocator.free(started.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(started.term));

    const restart_argv = [_][]const u8{
        zc_binary,
        "restart",
        "-c",
        target_path,
        "--override-script",
        script_path,
        "--json",
    };
    var restart = try std.process.spawn(compat.io(), .{
        .argv = &restart_argv,
        .environ_map = &environment,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var restart_running = true;
    defer if (restart_running) restart.kill(compat.io());
    var marker_seen = false;
    var attempt: u8 = 0;
    while (attempt < 80) : (attempt += 1) {
        tmp.dir.access(compat.io(), "entered", .{}) catch {
            compat.sleepNs(25 * std.time.ns_per_ms);
            continue;
        };
        marker_seen = true;
        break;
    }
    try std.testing.expect(marker_seen);
    const old_listener = try connectController(old_port);
    old_listener.close();
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "target.yaml",
        .data = mutated_source,
    });

    const restart_term = try restart.wait(compat.io());
    restart_running = false;
    try std.testing.expectEqual(@as(u8, 0), try exitCode(restart_term));
    const prepared_listener = try connectController(prepared_port);
    prepared_listener.close();
    const reloaded = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "reload", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(reloaded.stdout);
    defer allocator.free(reloaded.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(reloaded.term));
    const reloaded_listener = try connectController(mutated_port);
    reloaded_listener.close();
    if (connectController(prepared_port)) |unexpected| {
        unexpected.close();
        return error.TestUnexpectedResult;
    } else |_| {}

    var override_port = try reserveClosedPort();
    while (override_port == old_port or override_port == prepared_port or
        override_port == mutated_port)
    {
        override_port = try reserveClosedPort();
    }
    var later_source_port = try reserveClosedPort();
    while (later_source_port == old_port or later_source_port == prepared_port or
        later_source_port == mutated_port or later_source_port == override_port)
    {
        later_source_port = try reserveClosedPort();
    }
    var override_port_text: [5]u8 = undefined;
    const override_port_arg = try std.fmt.bufPrint(
        &override_port_text,
        "{d}",
        .{override_port},
    );
    const port_restart = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "restart", "--port", override_port_arg, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(port_restart.stdout);
    defer allocator.free(port_restart.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(port_restart.term));
    const override_listener = try connectController(override_port);
    override_listener.close();
    const later_source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nrules:\n  - MATCH,DIRECT\n",
        .{later_source_port},
    );
    defer allocator.free(later_source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "target.yaml",
        .data = later_source,
    });
    const second_reload = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "reload", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(second_reload.stdout);
    defer allocator.free(second_reload.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(second_reload.term));
    const preserved_override = try connectController(override_port);
    preserved_override.close();
    if (connectController(later_source_port)) |unexpected| {
        unexpected.close();
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "integration: timed out stop is disarmed before the daemon resumes" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    runtime_handle.close(compat.io());
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_path = try compat.fs.path.join(allocator, &.{ root, "config.yaml" });
    defer allocator.free(config_path);
    const port = try reserveClosedPort();
    const source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nrules:\n  - MATCH,DIRECT\n",
        .{port},
    );
    defer allocator.free(source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "config.yaml",
        .data = source,
    });
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    defer stopIsolatedDaemon(allocator, &environment);
    const started = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(started.stdout);
    defer allocator.free(started.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(started.term));
    var start_envelope = try parseEnvelope(allocator, started.stdout);
    defer start_envelope.deinit();
    const pid_value = start_envelope.value.object.get("data").?.object.get("pid").?.integer;
    if (pid_value <= 0 or pid_value > std.math.maxInt(i32)) {
        return error.TestUnexpectedResult;
    }
    const pid: i32 = @intCast(pid_value);
    try std.posix.kill(pid, std.posix.SIG.STOP);
    var daemon_paused = true;
    defer if (daemon_paused) std.posix.kill(pid, std.posix.SIG.CONT) catch {};

    const stopped = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "stop", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(10),
        } },
    });
    defer allocator.free(stopped.stdout);
    defer allocator.free(stopped.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(stopped.term));
    var stop_envelope = try parseEnvelope(allocator, stopped.stdout);
    defer stop_envelope.deinit();
    try expectErrorEnvelope(stop_envelope.value, "stop", "STOP_TIMEOUT");
    const runtime_check = try std.Io.Dir.openDirAbsolute(
        compat.io(),
        runtime_path,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer runtime_check.close(compat.io());
    var iterator = runtime_check.iterate();
    while (try iterator.next(compat.io())) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, "zc.stop."));
    }

    try std.posix.kill(pid, std.posix.SIG.CONT);
    daemon_paused = false;
    compat.sleepNs(300 * std.time.ns_per_ms);
    const status = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(status.stdout);
    defer allocator.free(status.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(status.term));
    const listener = try connectController(port);
    listener.close();
}

test "integration: startup removes the exact snapshot left by a crashed daemon" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_path = try compat.fs.path.join(allocator, &.{ root, "config.yaml" });
    defer allocator.free(config_path);
    const port = try reserveClosedPort();
    const source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: {d}\nsecret: crash-secret\nrules:\n  - MATCH,DIRECT\n",
        .{port},
    );
    defer allocator.free(source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "config.yaml",
        .data = source,
    });
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    defer stopIsolatedDaemon(allocator, &environment);

    const first = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(first.stdout);
    defer allocator.free(first.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(first.term));
    var first_envelope = try parseEnvelope(allocator, first.stdout);
    defer first_envelope.deinit();
    const pid_value = first_envelope.value.object.get("data").?.object.get("pid").?.integer;
    if (pid_value <= 0 or pid_value > std.math.maxInt(i32)) {
        return error.TestUnexpectedResult;
    }
    const pid: i32 = @intCast(pid_value);
    const descriptor_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        "run/zc.daemon.json",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(descriptor_bytes);
    var descriptor = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        descriptor_bytes,
        .{},
    );
    defer descriptor.deinit();
    const old_snapshot = try allocator.dupe(
        u8,
        descriptor.value.object.get("invocation").?.object.get(
            "config_path",
        ).?.string,
    );
    defer allocator.free(old_snapshot);
    try std.posix.kill(pid, std.posix.SIG.KILL);
    compat.sleepNs(100 * std.time.ns_per_ms);

    const second = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(second.stdout);
    defer allocator.free(second.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(second.term));
    try std.testing.expectError(
        error.FileNotFound,
        compat.fs.accessAbsolute(old_snapshot, .{}),
    );
    const listener = try connectController(port);
    listener.close();
}

test "integration: background start returns only after listeners are ready" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );
    runtime_handle.close(compat.io());

    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_home = try compat.fs.path.join(allocator, &.{ home, ".config" });
    defer allocator.free(config_home);
    const state_home = try compat.fs.path.join(allocator, &.{ home, ".local", "state" });
    defer allocator.free(state_home);
    const config_path = try compat.fs.path.join(allocator, &.{ root, "config.yaml" });
    defer allocator.free(config_path);

    const mixed_port = try reserveClosedPort();
    var controller_port = try reserveClosedPort();
    while (controller_port == mixed_port) controller_port = try reserveClosedPort();
    const source = try std.fmt.allocPrint(allocator,
        \\mixed-port: {d}
        \\external-controller: 127.0.0.1:{d}
        \\proxies: []
        \\proxy-groups:
        \\  - name: Proxy
        \\    type: select
        \\    proxies: [DIRECT, REJECT]
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.yaml
        \\rules:
        \\  - RULE-SET,local,Proxy
        \\  - MATCH,DIRECT
        \\
    , .{ mixed_port, controller_port });
    defer allocator.free(source);
    const file = try tmp.dir.createFile(compat.io(), "config.yaml", .{});
    defer file.close(compat.io());
    try compat.fileWriteAll(file, source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "rules.yaml",
        .data = "payload:\n  - example.com\n",
    });

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_CONFIG_HOME", config_home);
    try environment.put("XDG_STATE_HOME", state_home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);
    defer stopIsolatedDaemon(allocator, &environment);

    const imported = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "config", "load", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(imported.stdout);
    defer allocator.free(imported.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(imported.term));
    try tmp.dir.deleteFile(compat.io(), "rules.yaml");

    const started = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(15),
        } },
    });
    defer allocator.free(started.stdout);
    defer allocator.free(started.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(started.term));
    var envelope = try parseEnvelope(allocator, started.stdout);
    defer envelope.deinit();
    try std.testing.expect(envelope.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings(
        "running",
        envelope.value.object.get("data").?.object.get("state").?.string,
    );

    const mixed = try connectController(mixed_port);
    mixed.close();
    const route_probe = try connectController(mixed_port);
    try route_probe.writeAll(
        "CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n",
    );
    var route_response: [1024]u8 = undefined;
    _ = route_probe.read(&route_response) catch {};
    route_probe.close();
    compat.sleepNs(150 * std.time.ns_per_ms);
    const route_log = try tmp.dir.readFileAlloc(
        compat.io(),
        "run/zc.log",
        allocator,
        .limited(256 * 1024),
    );
    defer allocator.free(route_log);
    try std.testing.expect(
        std.mem.indexOf(u8, route_log, "[Engine]") == null,
    );
    const controller = try connectController(controller_port);
    controller.close();
    try tmp.dir.access(compat.io(), "run/zc.pid", .{});
    var descriptor_path_buffer: [64]u8 = undefined;
    const descriptor_path = try std.fmt.bufPrint(
        &descriptor_path_buffer,
        "run/{s}",
        .{runtime_descriptor.file_name},
    );
    try tmp.dir.access(compat.io(), descriptor_path, .{});

    var lock_path_buffer: [128]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(
        &lock_path_buffer,
        "run/{s}",
        .{runtime_dir.lock_name},
    );
    var old_lock_path_buffer: [160]u8 = undefined;
    const old_lock_path = try std.fmt.bufPrint(
        &old_lock_path_buffer,
        "run/{s}.old",
        .{runtime_dir.lock_name},
    );
    const tracked_pid_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        "run/zc.pid",
        allocator,
        .limited(32),
    );
    defer allocator.free(tracked_pid_bytes);
    const tracked_pid = try std.fmt.parseInt(
        i32,
        std.mem.trim(u8, tracked_pid_bytes, " \t\r\n"),
        10,
    );
    try std.posix.kill(tracked_pid, std.posix.SIG.STOP);
    var daemon_paused = true;
    defer if (daemon_paused) {
        std.posix.kill(tracked_pid, std.posix.SIG.CONT) catch {};
    };
    try tmp.dir.deleteFile(compat.io(), "run/zc.pid");
    try tmp.dir.rename(lock_path, tmp.dir, old_lock_path, compat.io());
    const replacement_lock = try tmp.dir.createFile(
        compat.io(),
        lock_path,
        .{ .read = true, .truncate = false },
    );
    replacement_lock.close(compat.io());
    const uncertain_status = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "status", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(uncertain_status.stdout);
    defer allocator.free(uncertain_status.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(uncertain_status.term));
    var uncertain_envelope = try parseEnvelope(
        allocator,
        uncertain_status.stdout,
    );
    defer uncertain_envelope.deinit();
    try expectErrorEnvelope(uncertain_envelope.value, "status", "STATUS_FAILED");
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "run/zc.pid", .{}),
    );

    const duplicate_start = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(duplicate_start.stdout);
    defer allocator.free(duplicate_start.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(duplicate_start.term));
    try tmp.dir.deleteFile(compat.io(), lock_path);
    try tmp.dir.rename(old_lock_path, tmp.dir, lock_path, compat.io());
    const restored_pid = try tmp.dir.createFile(compat.io(), "run/zc.pid", .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    try compat.fileWriteAll(restored_pid, tracked_pid_bytes);
    restored_pid.close(compat.io());
    try std.posix.kill(tracked_pid, std.posix.SIG.CONT);
    daemon_paused = false;
    try waitForControllerResponse(controller_port);

    const selected = try std.process.run(allocator, compat.io(), .{
        .argv = &.{
            zc_binary,
            "proxy",
            "select",
            "-g",
            "Proxy",
            "-p",
            "REJECT",
            "--json",
        },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(selected.stdout);
    defer allocator.free(selected.stderr);
    const selected_exit = try exitCode(selected.term);
    if (selected_exit != 0) {
        std.debug.print(
            "proxy select failed: stdout={s} stderr={s}\n",
            .{ selected.stdout, selected.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), selected_exit);
    var selected_envelope = try parseEnvelope(allocator, selected.stdout);
    defer selected_envelope.deinit();
    try std.testing.expect(
        selected_envelope.value.object.get("data").?.object.get("applied").?.bool,
    );
    const applied_descriptor_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        descriptor_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(applied_descriptor_bytes);
    var applied_descriptor = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        applied_descriptor_bytes,
        .{},
    );
    defer applied_descriptor.deinit();
    try std.testing.expectEqual(
        @as(i64, 1),
        applied_descriptor.value.object.get("generation").?.integer,
    );
    try std.testing.expect(
        applied_descriptor.value.object.get("ready").?.bool,
    );
    const applied_invocation = applied_descriptor.value.object.get(
        "invocation",
    ).?.object;
    try std.testing.expect(applied_invocation.get("prepared").?.bool);
    try std.testing.expect(applied_invocation.get("config_path") != null);
    const descriptor_object = applied_descriptor.value.object;
    const metadata_free_body = "{\"name\":\"DIRECT\"}";
    const metadata_free_request = try std.fmt.allocPrint(
        allocator,
        "PUT /proxies/Proxy HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n\r\n{s}",
        .{ metadata_free_body.len, metadata_free_body },
    );
    defer allocator.free(metadata_free_request);
    const metadata_free_connection = try connectController(controller_port);
    defer metadata_free_connection.close();
    try metadata_free_connection.writeAll(metadata_free_request);
    var metadata_free_response_buffer: [4096]u8 = undefined;
    const metadata_free_response = try readResponseWithin(
        metadata_free_connection,
        &metadata_free_response_buffer,
        1_000,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, metadata_free_response, "HTTP/1.1 409 ") != null,
    );
    const partial_metadata_body = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"DIRECT\",\"instance_nonce\":\"{s}\"}}",
        .{descriptor_object.get("nonce").?.string},
    );
    defer allocator.free(partial_metadata_body);
    const partial_metadata_request = try std.fmt.allocPrint(
        allocator,
        "PUT /proxies/Proxy HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n\r\n{s}",
        .{ partial_metadata_body.len, partial_metadata_body },
    );
    defer allocator.free(partial_metadata_request);
    const partial_metadata_connection = try connectController(controller_port);
    defer partial_metadata_connection.close();
    try partial_metadata_connection.writeAll(partial_metadata_request);
    var partial_metadata_response_buffer: [4096]u8 = undefined;
    const partial_metadata_response = try readResponseWithin(
        partial_metadata_connection,
        &partial_metadata_response_buffer,
        1_000,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, partial_metadata_response, "HTTP/1.1 400 ") != null,
    );

    const stale_body = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"DIRECT\",\"instance_nonce\":\"{s}\",\"identity_key\":\"{s}\",\"identity_revision\":\"{s}\",\"generation\":1}}",
        .{
            descriptor_object.get("nonce").?.string,
            descriptor_object.get("identity").?.object.get("key").?.string,
            descriptor_object.get("identity").?.object.get("revision").?.string,
        },
    );
    defer allocator.free(stale_body);
    const stale_request = try std.fmt.allocPrint(
        allocator,
        "PUT /proxies/Proxy HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n\r\n{s}",
        .{ stale_body.len, stale_body },
    );
    defer allocator.free(stale_request);
    const stale_connection = try connectController(controller_port);
    defer stale_connection.close();
    try stale_connection.writeAll(stale_request);
    var stale_response_buffer: [4096]u8 = undefined;
    const stale_response = try readResponseWithin(
        stale_connection,
        &stale_response_buffer,
        1_000,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, stale_response, "HTTP/1.1 409 ") != null,
    );

    const managed_identity: config_identity.ManagedIdentity = .{
        .key = descriptor_object.get("identity").?.object.get("key").?.string,
        .revision = try config_identity.Revision.parseHex(
            descriptor_object.get("identity").?.object.get("revision").?.string,
        ),
    };
    const state_root = try tmp.dir.openDir(
        compat.io(),
        "home/.config/zc",
        .{},
    );
    defer state_root.close(compat.io());
    const desired_state = selection_state.State.init(allocator, state_root);
    const generation_two = try desired_state.persist(
        managed_identity,
        "Proxy",
        "DIRECT",
    );
    try std.testing.expectEqual(@as(?u64, 2), generation_two.generation);
    const generation_three = try desired_state.persist(
        managed_identity,
        "Proxy",
        "REJECT",
    );
    try std.testing.expectEqual(@as(?u64, 3), generation_three.generation);

    const jumped = try std.process.run(allocator, compat.io(), .{
        .argv = &.{
            zc_binary,
            "proxy",
            "select",
            "-g",
            "Proxy",
            "-p",
            "DIRECT",
            "--json",
        },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(jumped.stdout);
    defer allocator.free(jumped.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(jumped.term));
    var jumped_envelope = try parseEnvelope(allocator, jumped.stdout);
    defer jumped_envelope.deinit();
    try std.testing.expect(
        jumped_envelope.value.object.get("data").?.object.get("applied").?.bool,
    );
    const jumped_descriptor_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        descriptor_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(jumped_descriptor_bytes);
    var jumped_descriptor = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        jumped_descriptor_bytes,
        .{},
    );
    defer jumped_descriptor.deinit();
    try std.testing.expectEqual(
        @as(i64, 4),
        jumped_descriptor.value.object.get("generation").?.integer,
    );

    const oversized_log = try tmp.dir.openFile(
        compat.io(),
        "run/zc.log",
        .{ .mode = .read_write },
    );
    const oversized_log_inode = (try oversized_log.stat(compat.io())).inode;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.ftruncate(
            oversized_log.handle,
            @intCast(daemon.daemon_log_max_bytes + 1),
        ),
    );
    oversized_log.close(compat.io());
    var log_rotated = false;
    const rotation_deadline = compat.monotonicMilliTimestamp() + 2_000;
    while (compat.monotonicMilliTimestamp() < rotation_deadline) {
        const current_log = try tmp.dir.statFile(
            compat.io(),
            "run/zc.log",
            .{ .follow_symlinks = false },
        );
        if (current_log.inode != oversized_log_inode) {
            log_rotated = true;
            break;
        }
        compat.sleepNs(1 * std.time.ns_per_ms);
    }
    try std.testing.expect(log_rotated);

    try tmp.dir.rename(
        "run/zc.log",
        tmp.dir,
        "run/zc.log.old",
        compat.io(),
    );
    var log_recreated = false;
    var log_attempt: u8 = 0;
    while (log_attempt < 20) : (log_attempt += 1) {
        if (tmp.dir.access(compat.io(), "run/zc.log", .{})) |_| {
            log_recreated = true;
            break;
        } else |_| {}
        compat.sleepNs(50 * std.time.ns_per_ms);
    }
    try std.testing.expect(log_recreated);

    const stopped = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "stop", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(15),
        } },
    });
    defer allocator.free(stopped.stdout);
    defer allocator.free(stopped.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(stopped.term));
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "run/zc.pid", .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), descriptor_path, .{}),
    );
    const runtime_check = try std.Io.Dir.openDirAbsolute(
        compat.io(),
        runtime_path,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer runtime_check.close(compat.io());
    var runtime_entries = runtime_check.iterate();
    while (try runtime_entries.next(compat.io())) |entry| {
        try std.testing.expect(!std.mem.startsWith(
            u8,
            entry.name,
            "zc.prepared.",
        ) or std.mem.eql(u8, entry.name, "zc.prepared.key") or
            std.mem.eql(u8, entry.name, "zc.prepared.key.lock"));
    }

    var follower = try std.process.spawn(compat.io(), .{
        .argv = &.{ zc_binary, "log", "-f", "-n", "1" },
        .environ_map = &environment,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer follower.kill(compat.io());
    const follower_stdout = follower.stdout orelse
        return error.TestUnexpectedResult;
    try compat.setNonBlock(follower_stdout.handle);
    compat.sleepNs(100 * std.time.ns_per_ms);
    try tmp.dir.rename(
        "run/zc.log",
        tmp.dir,
        "run/zc.log.gap-old",
        compat.io(),
    );
    const old_log = try tmp.dir.openFile(
        compat.io(),
        "run/zc.log.gap-old",
        .{ .mode = .read_write },
    );
    try compat.fileSeekTo(old_log, (try old_log.stat(compat.io())).size);
    try compat.fileWriteAll(old_log, "old-after-rename\n");
    old_log.close(compat.io());
    compat.sleepNs(700 * std.time.ns_per_ms);
    const new_log = try tmp.dir.createFile(compat.io(), "run/zc.log", .{});
    try new_log.setPermissions(
        compat.io(),
        std.Io.File.Permissions.fromMode(0o600),
    );
    try compat.fileWriteAll(new_log, "new-after-gap\n");
    new_log.close(compat.io());

    var followed = std.ArrayList(u8).empty;
    defer followed.deinit(allocator);
    const follow_deadline = compat.monotonicMilliTimestamp() + 2_000;
    var read_buffer: [1024]u8 = undefined;
    while (compat.monotonicMilliTimestamp() < follow_deadline) {
        const count = compat.posixRead(
            follower_stdout.handle,
            &read_buffer,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                compat.sleepNs(25 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (count == 0) break;
        try followed.appendSlice(allocator, read_buffer[0..count]);
        if (std.mem.indexOf(u8, followed.items, "new-after-gap") != null) break;
    }
    try std.testing.expect(
        std.mem.indexOf(u8, followed.items, "old-after-rename") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, followed.items, "new-after-gap") != null,
    );

    try tmp.dir.rename("run", tmp.dir, "run.previous", compat.io());
    compat.sleepNs(700 * std.time.ns_per_ms);
    try tmp.dir.createDir(compat.io(), "run", .default_dir);
    const replacement_runtime = try tmp.dir.openDir(compat.io(), "run", .{});
    try compat.setDirPermissions(
        replacement_runtime,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const replacement_runtime_log = try replacement_runtime.createFile(
        compat.io(),
        "zc.log",
        .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
    );
    try compat.fileWriteAll(replacement_runtime_log, "new-runtime-dir\n");
    replacement_runtime_log.close(compat.io());
    replacement_runtime.close(compat.io());
    const runtime_reopen_deadline = compat.monotonicMilliTimestamp() + 2_000;
    while (compat.monotonicMilliTimestamp() < runtime_reopen_deadline) {
        const count = compat.posixRead(
            follower_stdout.handle,
            &read_buffer,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                compat.sleepNs(25 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (count == 0) break;
        try followed.appendSlice(allocator, read_buffer[0..count]);
        if (std.mem.indexOf(u8, followed.items, "new-runtime-dir") != null) break;
    }
    try std.testing.expect(
        std.mem.indexOf(u8, followed.items, "new-runtime-dir") != null,
    );
    follower.kill(compat.io());

    try tmp.dir.deleteFile(compat.io(), "run/zc.log");
    var initial_missing_follower = try std.process.spawn(compat.io(), .{
        .argv = &.{ zc_binary, "log", "-f", "-n", "1" },
        .environ_map = &environment,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer initial_missing_follower.kill(compat.io());
    const initial_missing_stdout = initial_missing_follower.stdout orelse
        return error.TestUnexpectedResult;
    try compat.setNonBlock(initial_missing_stdout.handle);
    compat.sleepNs(100 * std.time.ns_per_ms);
    try tmp.dir.rename("run", tmp.dir, "run.initial-old", compat.io());
    compat.sleepNs(700 * std.time.ns_per_ms);
    try tmp.dir.createDir(compat.io(), "run", .default_dir);
    const initial_replacement_runtime = try tmp.dir.openDir(
        compat.io(),
        "run",
        .{},
    );
    try compat.setDirPermissions(
        initial_replacement_runtime,
        std.Io.File.Permissions.fromMode(0o700),
    );
    const initial_replacement_log = try initial_replacement_runtime.createFile(
        compat.io(),
        "zc.log",
        .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
    );
    try compat.fileWriteAll(initial_replacement_log, "initial-log-appeared\n");
    initial_replacement_log.close(compat.io());
    initial_replacement_runtime.close(compat.io());
    var initial_followed = std.ArrayList(u8).empty;
    defer initial_followed.deinit(allocator);
    const initial_follow_deadline = compat.monotonicMilliTimestamp() + 2_000;
    while (compat.monotonicMilliTimestamp() < initial_follow_deadline) {
        const count = compat.posixRead(
            initial_missing_stdout.handle,
            &read_buffer,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                compat.sleepNs(25 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (count == 0) break;
        try initial_followed.appendSlice(allocator, read_buffer[0..count]);
        if (std.mem.indexOf(
            u8,
            initial_followed.items,
            "initial-log-appeared",
        ) != null) break;
    }
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            initial_followed.items,
            "initial-log-appeared",
        ) != null,
    );
    initial_missing_follower.kill(compat.io());

    const no_controller_port = try reserveClosedPort();
    const no_controller_source = try std.fmt.allocPrint(allocator,
        \\mixed-port: {d}
        \\proxies: []
        \\rules:
        \\  - MATCH,DIRECT
        \\
    , .{no_controller_port});
    defer allocator.free(no_controller_source);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = "config.yaml",
        .data = no_controller_source,
    });
    const no_controller_start = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(15),
        } },
    });
    defer allocator.free(no_controller_start.stdout);
    defer allocator.free(no_controller_start.stderr);
    try std.testing.expectEqual(
        @as(u8, 0),
        try exitCode(no_controller_start.term),
    );
    const no_controller = try connectController(no_controller_port);
    no_controller.close();
    const descriptor_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        descriptor_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(descriptor_bytes);
    var parsed_descriptor = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        descriptor_bytes,
        .{},
    );
    defer parsed_descriptor.deinit();
    try std.testing.expect(
        parsed_descriptor.value.object.get("endpoint").? == .null,
    );
    const replaced_runtime_pid: i32 = @intCast(
        parsed_descriptor.value.object.get("pid").?.integer,
    );
    try tmp.dir.rename(
        "run",
        tmp.dir,
        "run.daemon-replaced",
        compat.io(),
    );
    compat.sleepNs(700 * std.time.ns_per_ms);
    try tmp.dir.createDir(compat.io(), "run", .default_dir);
    const recreated_runtime = try tmp.dir.openDir(compat.io(), "run", .{});
    try compat.setDirPermissions(
        recreated_runtime,
        std.Io.File.Permissions.fromMode(0o700),
    );
    recreated_runtime.close(compat.io());
    var exited = false;
    var exit_attempt: u8 = 0;
    while (exit_attempt < 40) : (exit_attempt += 1) {
        std.posix.kill(replaced_runtime_pid, @enumFromInt(0)) catch {
            exited = true;
            break;
        };
        compat.sleepNs(25 * std.time.ns_per_ms);
    }
    try std.testing.expect(exited);
    const replacement_start = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(15),
        } },
    });
    defer allocator.free(replacement_start.stdout);
    defer allocator.free(replacement_start.stderr);
    try std.testing.expectEqual(
        @as(u8, 0),
        try exitCode(replacement_start.term),
    );
    const final_stop = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "stop", "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(15),
        } },
    });
    defer allocator.free(final_stop.stdout);
    defer allocator.free(final_stop.stderr);
    try std.testing.expectEqual(@as(u8, 0), try exitCode(final_stop.term));

    try tmp.dir.deleteFile(compat.io(), "run/zc.log");
    try tmp.dir.createDir(compat.io(), "run/zc.log", .default_dir);
    const bootstrap_failure = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(bootstrap_failure.stdout);
    defer allocator.free(bootstrap_failure.stderr);
    try std.testing.expectEqual(
        @as(u8, 1),
        try exitCode(bootstrap_failure.term),
    );
    var bootstrap_envelope = try parseEnvelope(
        allocator,
        bootstrap_failure.stdout,
    );
    defer bootstrap_envelope.deinit();
    try expectErrorEnvelope(bootstrap_envelope.value, "start", "START_FAILED");
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, bootstrap_failure.stdout, "{\"ok\":"),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "run/zc.pid", .{}),
    );
    const restart_bootstrap_failure = try std.process.run(
        allocator,
        compat.io(),
        .{
            .argv = &.{ zc_binary, "restart", "-c", config_path, "--json" },
            .environ_map = &environment,
            .stdout_limit = .limited(max_output),
            .stderr_limit = .limited(max_output),
            .timeout = .{ .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromSeconds(5),
            } },
        },
    );
    defer allocator.free(restart_bootstrap_failure.stdout);
    defer allocator.free(restart_bootstrap_failure.stderr);
    try std.testing.expectEqual(
        @as(u8, 1),
        try exitCode(restart_bootstrap_failure.term),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            restart_bootstrap_failure.stdout,
            "{\"ok\":",
        ),
    );
    try tmp.dir.deleteTree(compat.io(), "run/zc.log");

    const descriptor_lock_path = try std.fmt.bufPrint(
        &descriptor_path_buffer,
        "run/{s}",
        .{runtime_descriptor.lock_name},
    );
    const held_descriptor_lock = try tmp.dir.createFile(
        compat.io(),
        descriptor_lock_path,
        .{ .read = true, .truncate = false, .lock = .exclusive },
    );
    defer held_descriptor_lock.close(compat.io());
    const rejected_publish = try std.process.run(allocator, compat.io(), .{
        .argv = &.{
            zc_binary,
            "start",
            "--foreground",
            "-c",
            config_path,
            "--json",
        },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(rejected_publish.stdout);
    defer allocator.free(rejected_publish.stderr);
    try std.testing.expectEqual(
        @as(u8, 1),
        try exitCode(rejected_publish.term),
    );
    var rejected_envelope = try parseEnvelope(
        allocator,
        rejected_publish.stdout,
    );
    defer rejected_envelope.deinit();
    try expectErrorEnvelope(
        rejected_envelope.value,
        "start",
        "START_RUNTIME_PUBLISH_FAILED",
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "run/zc.pid", .{}),
    );

    const rejected_background = try std.process.run(allocator, compat.io(), .{
        .argv = &.{ zc_binary, "start", "-c", config_path, "--json" },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(5),
        } },
    });
    defer allocator.free(rejected_background.stdout);
    defer allocator.free(rejected_background.stderr);
    const rejected_background_exit = try exitCode(rejected_background.term);
    if (std.mem.indexOf(u8, rejected_background.stdout, "START_RUNTIME_PUBLISH_FAILED") == null) {
        std.debug.print(
            "background publish rejection: stdout={s} stderr={s}\n",
            .{ rejected_background.stdout, rejected_background.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 1), rejected_background_exit);
    var background_envelope = try parseEnvelope(
        allocator,
        rejected_background.stdout,
    );
    defer background_envelope.deinit();
    try expectErrorEnvelope(
        background_envelope.value,
        "start",
        "START_RUNTIME_PUBLISH_FAILED",
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "run/zc.pid", .{}),
    );
}

test "integration: minimal API isolates idle clients and frames PUT bodies" {
    const allocator = std.testing.allocator;
    try ensureZcBinary(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "home/.config");
    try tmp.dir.createDirPath(compat.io(), "run");
    const runtime_handle = try tmp.dir.openDir(compat.io(), "run", .{});
    defer runtime_handle.close(compat.io());
    try compat.setDirPermissions(
        runtime_handle,
        std.Io.File.Permissions.fromMode(0o700),
    );

    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const home = try compat.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const runtime_path = try compat.fs.path.join(allocator, &.{ root, "run" });
    defer allocator.free(runtime_path);
    const config_path = try compat.fs.path.join(allocator, &.{ root, "config.yaml" });
    defer allocator.free(config_path);

    const mixed_port = try reserveClosedPort();
    var controller_port = try reserveClosedPort();
    while (controller_port == mixed_port) controller_port = try reserveClosedPort();
    const source = try std.fmt.allocPrint(allocator,
        \\mixed-port: {d}
        \\external-controller: 127.0.0.1:{d}
        \\secret: test-secret
        \\proxies: []
        \\proxy-groups:
        \\  - name: Proxy
        \\    type: select
        \\    proxies:
        \\      - DIRECT
        \\rules:
        \\  - MATCH,Proxy
        \\
    , .{ mixed_port, controller_port });
    defer allocator.free(source);
    const file = try tmp.dir.createFile(compat.io(), "config.yaml", .{});
    defer file.close(compat.io());
    try compat.fileWriteAll(file, source);
    const sentinel = try tmp.dir.createFile(compat.io(), "sentinel", .{});
    try compat.fileWriteAll(sentinel, "unchanged");
    sentinel.close(compat.io());
    tmp.dir.symLink(compat.io(), "../sentinel", "run/zc.pid", .{}) catch
        return error.SkipZigTest;

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        allocator,
    );
    defer environment.deinit();
    try environment.put("HOME", home);
    try environment.put("XDG_RUNTIME_DIR", runtime_path);

    const rejected = try std.process.run(allocator, compat.io(), .{
        .argv = &.{
            zc_binary,
            "start",
            "--foreground",
            "-c",
            config_path,
            "--json",
        },
        .environ_map = &environment,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromSeconds(1),
        } },
    });
    defer allocator.free(rejected.stdout);
    defer allocator.free(rejected.stderr);
    try std.testing.expectEqual(@as(u8, 1), try exitCode(rejected.term));
    try std.testing.expect(
        std.mem.indexOf(u8, rejected.stdout, "START_PREFLIGHT_FAILED") != null,
    );
    try tmp.dir.deleteFile(compat.io(), "run/zc.pid");

    var child = try std.process.spawn(compat.io(), .{
        .argv = &.{ zc_binary, "start", "--foreground", "-c", config_path },
        .environ_map = &environment,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(compat.io());
    try waitForController(controller_port);
    const sentinel_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        "sentinel",
        allocator,
        .limited(32),
    );
    defer allocator.free(sentinel_bytes);
    try std.testing.expectEqualStrings("unchanged", sentinel_bytes);

    const idle = try connectController(controller_port);
    defer idle.close();
    {
        const active = try connectController(controller_port);
        defer active.close();
        try active.writeAll("GET /version HTTP/1.1\r\nHost: local\r\n\r\n");
        var response_buffer: [4096]u8 = undefined;
        const response = try readResponseWithin(active, &response_buffer, 1_000);
        try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
        try std.testing.expect(
            std.mem.indexOf(u8, response, "Connection: close\r\n") != null,
        );
    }

    {
        const headerless = try connectController(controller_port);
        defer headerless.close();
        try headerless.writeAll("GET /version HTTP/1.0\r\n\r\n");
        var response_buffer: [4096]u8 = undefined;
        const response = try readResponseWithin(headerless, &response_buffer, 1_000);
        try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    }

    {
        const body = "{\"name\":\"DIRECT\"}";
        const invalid_lengths = [_][]const u8{
            "Content-Length: +17",
            "Content-Length: 1_7",
            "Content-Length : 17",
            " Content-Length: 17",
            "\tContent-Length: 17",
            "Content-Length: 17\r\n" ++
                "X-Ignored: value\nContent-Length: 0",
            "Content-Length: 17\r\n" ++
                "X-Ignored: value\nTransfer-Encoding: chunked",
            "Content-Length: 65537\r\n" ++
                "X-Ignored: value\nTransfer-Encoding: chunked",
            "Transfer-Encoding: chunked\r\n" ++
                "X-Ignored: value\rContent-Length: 0",
        };
        for (invalid_lengths) |length_header| {
            const invalid = try connectController(controller_port);
            defer invalid.close();
            const request = try std.fmt.allocPrint(
                allocator,
                "PUT /proxies/Proxy HTTP/1.1\r\n" ++
                    "Host: local\r\n{s}\r\n\r\n{s}",
                .{ length_header, body },
            );
            defer allocator.free(request);
            try invalid.writeAll(request);
            var response_buffer: [4096]u8 = undefined;
            const response = try readResponseWithin(
                invalid,
                &response_buffer,
                1_000,
            );
            try std.testing.expect(
                std.mem.indexOf(u8, response, "400 Bad Request") != null,
            );
        }
    }

    {
        const body = "{\"name\":\"DIRECT\"}";
        const unauthorized = try connectController(controller_port);
        defer unauthorized.close();
        const unauthorized_request = try std.fmt.allocPrint(
            allocator,
            "PUT /proxies/Proxy HTTP/1.1\r\n" ++
                "Host: local\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ body.len, body },
        );
        defer allocator.free(unauthorized_request);
        try unauthorized.writeAll(unauthorized_request);
        var unauthorized_buffer: [4096]u8 = undefined;
        const unauthorized_response = try readResponseWithin(
            unauthorized,
            &unauthorized_buffer,
            1_000,
        );
        if (std.mem.indexOf(u8, unauthorized_response, "401 Unauthorized") == null) {
            std.debug.print("unauthorized response: {s}\n", .{unauthorized_response});
            return error.TestUnexpectedResult;
        }

        const header = try std.fmt.allocPrint(
            allocator,
            "PUT /proxies/Proxy HTTP/1.1\r\n" ++
                "Host: local\r\n" ++
                "Authorization: Bearer test-secret\r\n" ++
                "Content-Length: {d}\r\n\r\n",
            .{body.len},
        );
        defer allocator.free(header);
        const fragmented = try connectController(controller_port);
        defer fragmented.close();
        try fragmented.writeAll(header);
        compat.sleepNs(20 * std.time.ns_per_ms);
        try fragmented.writeAll(body);
        var response_buffer: [4096]u8 = undefined;
        const response = try readResponseWithin(fragmented, &response_buffer, 1_000);
        try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    }

    {
        const oversized = try connectController(controller_port);
        defer oversized.close();
        try oversized.writeAll(
            "PUT / HTTP/1.1\r\nContent-Length: 65537\r\n\r\n",
        );
        var response_buffer: [4096]u8 = undefined;
        const response = try readResponseWithin(oversized, &response_buffer, 1_000);
        try std.testing.expect(
            std.mem.indexOf(u8, response, "413 Payload Too Large") != null,
        );
    }

    var timeout_buffer: [4096]u8 = undefined;
    const timeout_response = try readResponseWithin(idle, &timeout_buffer, 4_000);
    try std.testing.expect(
        std.mem.indexOf(u8, timeout_response, "408 Request Timeout") != null,
    );
}
