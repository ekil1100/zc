const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const compat = @import("compat.zig");
const bundle_mod = @import("config_bundle.zig");
const config_mod = @import("config.zig");

const ConfigBundle = bundle_mod.ConfigBundle;
const CaptureLimits = bundle_mod.CaptureLimits;

extern "c" fn mkfifoat(c_int, [*:0]const u8, std.posix.mode_t) c_int;

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(compat.io(), bytes);
}

fn realPath(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const resolved = try dir.realPathFileAlloc(compat.io(), path, allocator);
    defer allocator.free(resolved);
    return allocator.dupe(u8, resolved);
}

test "ConfigBundle preserves source bytes and enforces an inclusive source limit" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source = "port: 7890\n";
    try writeFile(tmp.dir, "config.yaml", source);
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{
        .max_source_bytes = source.len,
        .max_asset_bytes = 32,
        .max_aggregate_bytes = source.len,
        .max_assets = 1,
    });
    defer bundle.deinit();

    try testing.expectEqualStrings(source, bundle.sourceBytes());
    try testing.expectEqual(source.len, bundle.manifest().source.size);
    try testing.expectEqual(source.len, bundle.manifest().aggregate_bytes);

    try testing.expectError(error.SourceTooLarge, ConfigBundle.capture(allocator, path, .{
        .max_source_bytes = source.len - 1,
        .max_asset_bytes = 32,
        .max_aggregate_bytes = source.len,
        .max_assets = 1,
    }));
}

test "ConfigBundle captures local providers and defers remote providers without file access" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\rule-providers:
        \\  local:
        \\    type: http
        \\    behavior: domain
        \\    path: rules.yaml
        \\    url: null
        \\  "remote provider":
        \\    type: http
        \\    behavior: domain
        \\    path: ../must-not-be-opened.yaml
        \\    "url": "http://127.0.0.1:1/rules"
    ;
    const rules = "payload:\n  - example.com\n";
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", rules);
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();

    try testing.expectEqual(@as(usize, 1), bundle.manifest().local_assets.len);
    try testing.expectEqual(@as(usize, 1), bundle.manifest().remote_providers.len);
    try testing.expectEqualStrings("rules.yaml", bundle.manifest().local_assets[0].logical_path);
    try testing.expectEqualStrings(rules, try bundle.resolveLocal("rules.yaml"));
    try testing.expectError(error.AssetNotDeclared, bundle.resolveLocal("../must-not-be-opened.yaml"));

    try writeFile(tmp.dir, "rules.yaml", "payload:\n  - changed.example\n");
    try testing.expectEqualStrings(rules, try bundle.resolveLocal("rules.yaml"));
}

test "ConfigBundle capture and offline load perform zero remote network attempts" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const address = try compat.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try compat.net.listenReuseAddr(address);
    defer listener.deinit();
    const source = try std.fmt.allocPrint(
        allocator,
        "mixed-port: 7890\nrule-providers:\n  remote:\n    type: http\n    behavior: domain\n    path: missing.yaml\n    url: http://127.0.0.1:{d}/rules\n",
        .{listener.listen_address.getPort()},
    );
    defer allocator.free(source);
    try writeFile(tmp.dir, "config.yaml", source);
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    var loaded = try bundle.loadOffline(allocator);
    defer loaded.deinit();

    var descriptors = [_]std.posix.pollfd{.{
        .fd = listener.fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try testing.expectEqual(@as(usize, 0), try std.posix.poll(&descriptors, 0));
}

test "ConfigBundle manifest is deterministic and counts exact logical aliases" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\rule-providers:
        \\  z-local:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.yaml
        \\  duplicate:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.yaml
        \\  alias:
        \\    type: file
        \\    behavior: domain
        \\    path: alias.yaml
        \\  z-remote:
        \\    type: http
        \\    behavior: domain
        \\    path: z.yaml
        \\    url: https://example.test/z
        \\  a-remote:
        \\    type: http
        \\    behavior: domain
        \\    path: a.yaml
        \\    url: https://example.test/a
    ;
    const rules = "payload: []\n";
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", rules);
    tmp.dir.symLink(compat.io(), "rules.yaml", "alias.yaml", .{}) catch return error.SkipZigTest;
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var first = try ConfigBundle.capture(allocator, path, .{});
    defer first.deinit();
    var second = try ConfigBundle.capture(allocator, path, .{});
    defer second.deinit();

    const manifest = first.manifest();
    try testing.expectEqual(@as(usize, 2), manifest.local_assets.len);
    try testing.expectEqualStrings("alias.yaml", manifest.local_assets[0].logical_path);
    try testing.expectEqualStrings("rules.yaml", manifest.local_assets[1].logical_path);
    try testing.expectEqual(source.len + 2 * rules.len, manifest.aggregate_bytes);
    try testing.expectEqualStrings("a-remote", manifest.remote_providers[0].provider_name);
    try testing.expectEqualStrings("z-remote", manifest.remote_providers[1].provider_name);
    try testing.expectEqualSlices(
        u8,
        &manifest.local_assets[0].content.sha256,
        &manifest.local_assets[1].content.sha256,
    );
    const repeated = second.manifest();
    try testing.expectEqual(manifest.version, repeated.version);
    try testing.expectEqual(manifest.aggregate_bytes, repeated.aggregate_bytes);
    try testing.expectEqual(manifest.materialized_source, repeated.materialized_source);
    try testing.expectEqualSlices(u8, &manifest.source.sha256, &repeated.source.sha256);
    try testing.expectEqual(manifest.local_assets.len, repeated.local_assets.len);
    for (manifest.local_assets, repeated.local_assets) |expected, actual| {
        try testing.expectEqualStrings(expected.logical_path, actual.logical_path);
        try testing.expectEqualStrings(expected.canonical_relative_target, actual.canonical_relative_target);
        try testing.expectEqual(expected.content.size, actual.content.size);
        try testing.expectEqualSlices(u8, &expected.content.sha256, &actual.content.sha256);
    }
    try testing.expectEqual(manifest.remote_providers.len, repeated.remote_providers.len);
    for (manifest.remote_providers, repeated.remote_providers) |expected, actual| {
        try testing.expectEqualStrings(expected.provider_name, actual.provider_name);
        try testing.expectEqualStrings(expected.logical_path, actual.logical_path);
        try testing.expectEqual(expected.remote_deferred, actual.remote_deferred);
    }
}

test "ConfigBundle anchors a symlinked source at the canonical target parent" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(compat.io(), "real", .default_dir);
    try tmp.dir.createDir(compat.io(), "decoy", .default_dir);
    const source =
        \\rule-providers:
        \\  local:
        \\    type: http
        \\    behavior: domain
        \\    path: rules.yaml
    ;
    try writeFile(tmp.dir, "real/config.yaml", source);
    try writeFile(tmp.dir, "real/rules.yaml", "payload:\n  - real.example\n");
    try writeFile(tmp.dir, "decoy/rules.yaml", "payload:\n  - decoy.example\n");
    tmp.dir.symLink(compat.io(), "real/config.yaml", "config-link.yaml", .{}) catch return error.SkipZigTest;
    const link_path = try realPath(allocator, tmp.dir, "config-link.yaml");
    defer allocator.free(link_path);

    // realPath above returns the target path; exercise the input symlink itself.
    const root_path = try realPath(allocator, tmp.dir, ".");
    defer allocator.free(root_path);
    const source_path = try compat.fs.path.join(allocator, &.{ root_path, "config-link.yaml" });
    defer allocator.free(source_path);

    var bundle = try ConfigBundle.capture(allocator, source_path, .{});
    defer bundle.deinit();
    try testing.expectEqualStrings("payload:\n  - real.example\n", try bundle.resolveLocal("rules.yaml"));
}

test "ConfigBundle rejects escaped local providers but never authorizes remote paths" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(compat.io(), "root", .default_dir);
    try writeFile(tmp.dir, "outside.yaml", "payload: []\n");
    tmp.dir.symLink(compat.io(), "../outside.yaml", "root/escape.yaml", .{}) catch return error.SkipZigTest;
    const local_source =
        \\rule-providers:
        \\  escaped:
        \\    type: http
        \\    behavior: domain
        \\    path: escape.yaml
    ;
    try writeFile(tmp.dir, "root/config.yaml", local_source);
    const path = try realPath(allocator, tmp.dir, "root/config.yaml");
    defer allocator.free(path);
    try testing.expectError(error.PathOutsideSourceRoot, ConfigBundle.capture(allocator, path, .{}));

    const remote_source =
        \\rule-providers:
        \\  deferred:
        \\    type: http
        \\    behavior: domain
        \\    path: escape.yaml
        \\    url: "https://example.invalid/rules"
    ;
    try writeFile(tmp.dir, "root/config.yaml", remote_source);
    var remote = try ConfigBundle.capture(allocator, path, .{});
    defer remote.deinit();
    try testing.expectEqual(@as(usize, 0), remote.manifest().local_assets.len);
    try testing.expectEqual(@as(usize, 1), remote.manifest().remote_providers.len);
}

test "ConfigBundle accepts relative source paths without weakening canonical capture" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const absolute = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(absolute);
    const cwd = try std.process.currentPathAlloc(compat.io(), allocator);
    defer allocator.free(cwd);
    const relative = try compat.fs.path.relative(allocator, cwd, null, cwd, absolute);
    defer allocator.free(relative);

    var bundle = try ConfigBundle.capture(allocator, relative, .{});
    defer bundle.deinit();
    try testing.expectEqualStrings("mixed-port: 7890\n", bundle.sourceBytes());
}

test "ConfigBundle rejects root-prefix siblings using platform path separators" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(compat.io(), "root", .default_dir);
    try tmp.dir.createDir(compat.io(), "root-other", .default_dir);
    try tmp.dir.createDir(compat.io(), "root\\escape", .default_dir);
    try writeFile(tmp.dir, "root-other/rules.yaml", "payload: []\n");
    try writeFile(tmp.dir, "root\\escape/rules.yaml", "payload: []\n");
    const sibling = try realPath(allocator, tmp.dir, "root-other/rules.yaml");
    defer allocator.free(sibling);
    const backslash_sibling = try realPath(allocator, tmp.dir, "root\\escape/rules.yaml");
    defer allocator.free(backslash_sibling);

    for ([_][]const u8{ sibling, backslash_sibling }) |outside| {
        const source = try std.fmt.allocPrint(
            allocator,
            "rule-providers:\n  escaped:\n    type: file\n    behavior: domain\n    path: {s}\n",
            .{outside},
        );
        defer allocator.free(source);
        try writeFile(tmp.dir, "root/config.yaml", source);
        const path = try realPath(allocator, tmp.dir, "root/config.yaml");
        defer allocator.free(path);
        try testing.expectError(error.PathOutsideSourceRoot, ConfigBundle.capture(allocator, path, .{}));
    }
}

test "ConfigBundle rejects special files without blocking" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    if (mkfifoat(tmp.dir.handle, "source-fifo", 0o600) != 0) return error.SkipZigTest;
    const root = try realPath(allocator, tmp.dir, ".");
    defer allocator.free(root);
    try testing.expectError(error.NotRegularFile, ConfigBundle.capture(allocator, root, .{}));
    if (compat.fs.accessAbsolute("/dev/null", .{})) |_| {
        try testing.expectError(error.NotRegularFile, ConfigBundle.capture(allocator, "/dev/null", .{}));
    } else |_| {}
    const fifo_path = try compat.fs.path.join(allocator, &.{ root, "source-fifo" });
    defer allocator.free(fifo_path);
    try testing.expectError(error.NotRegularFile, ConfigBundle.capture(allocator, fifo_path, .{}));

    const source =
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: domain
        \\    path: provider-fifo
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    if (mkfifoat(tmp.dir.handle, "provider-fifo", 0o600) != 0) return error.SkipZigTest;
    const config_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(config_path);
    try testing.expectError(error.NotRegularFile, ConfigBundle.capture(allocator, config_path, .{}));
}

test "ConfigBundle checks asset count before opening local paths" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\rule-providers:
        \\  one:
        \\    type: http
        \\    behavior: domain
        \\    path: missing-one.yaml
        \\  two:
        \\    type: http
        \\    behavior: domain
        \\    path: missing-two.yaml
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    try testing.expectError(error.TooManyAssets, ConfigBundle.capture(allocator, path, .{
        .max_assets = 1,
    }));
}

test "ConfigBundle enforces the default 1024 distinct asset boundary before opening files" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var source = std.ArrayList(u8).empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "rule-providers:\n");
    for (0..CaptureLimits.defaults.max_assets) |index| {
        const declaration = try std.fmt.allocPrint(
            allocator,
            "  p{d}:\n    type: file\n    behavior: domain\n    path: missing-{d}.yaml\n",
            .{ index, index },
        );
        defer allocator.free(declaration);
        try source.appendSlice(allocator, declaration);
    }
    try writeFile(tmp.dir, "config.yaml", source.items);
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);
    try testing.expectError(error.FileNotFound, ConfigBundle.capture(allocator, path, .{}));

    try source.appendSlice(
        allocator,
        "  overflow:\n    type: file\n    behavior: domain\n    path: overflow.yaml\n",
    );
    try writeFile(tmp.dir, "config.yaml", source.items);
    try testing.expectError(error.TooManyAssets, ConfigBundle.capture(allocator, path, .{}));
}

test "ConfigBundle enforces per-asset and aggregate limits without truncation" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\rule-providers:
        \\  local:
        \\    type: http
        \\    behavior: domain
        \\    path: rules.yaml
    ;
    const rules = "12345678";
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", rules);
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var exact = try ConfigBundle.capture(allocator, path, .{
        .max_source_bytes = 1024,
        .max_asset_bytes = rules.len,
        .max_aggregate_bytes = source.len + rules.len,
    });
    exact.deinit();

    try testing.expectError(error.AssetTooLarge, ConfigBundle.capture(allocator, path, .{
        .max_source_bytes = 1024,
        .max_asset_bytes = rules.len - 1,
        .max_aggregate_bytes = 1024,
    }));
    try testing.expectError(error.BundleTooLarge, ConfigBundle.capture(allocator, path, .{
        .max_source_bytes = 1024,
        .max_asset_bytes = rules.len,
        .max_aggregate_bytes = source.len + rules.len - 1,
    }));
}

test "ConfigBundle enforces real default source and asset byte boundaries" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source_limit = CaptureLimits.defaults.max_source_bytes;
    const source_storage = try allocator.alloc(u8, source_limit + 1);
    defer allocator.free(source_storage);
    @memset(source_storage, ' ');
    const prefix = "mixed-port: 7890\n#";
    @memcpy(source_storage[0..prefix.len], prefix);
    try writeFile(tmp.dir, "config.yaml", source_storage[0..source_limit]);
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var source_exact = try ConfigBundle.capture(allocator, path, .{});
    source_exact.deinit();
    try writeFile(tmp.dir, "config.yaml", source_storage);
    try testing.expectError(error.SourceTooLarge, ConfigBundle.capture(allocator, path, .{}));

    const provider_source =
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.yaml
    ;
    try writeFile(tmp.dir, "config.yaml", provider_source);
    const asset_limit = CaptureLimits.defaults.max_asset_bytes;
    const asset_storage = try allocator.alloc(u8, asset_limit + 1);
    defer allocator.free(asset_storage);
    @memset(asset_storage, 'a');
    try writeFile(tmp.dir, "rules.yaml", asset_storage[0..asset_limit]);
    var asset_exact = try ConfigBundle.capture(allocator, path, .{});
    asset_exact.deinit();
    try writeFile(tmp.dir, "rules.yaml", asset_storage);
    try testing.expectError(error.AssetTooLarge, ConfigBundle.capture(allocator, path, .{}));
}

test "ConfigBundle materialized source is authoritative while original bytes stay preserved" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  original:
        \\    type: http
        \\    behavior: domain
        \\    path: original.yaml
    ;
    const materialized = try allocator.dupe(u8,
        \\mixed-port: 7891
        \\rule-providers:
        \\  effective:
        \\    type: http
        \\    behavior: domain
        \\    path: effective.yaml
    );
    defer allocator.free(materialized);
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "effective.yaml", "payload:\n  - effective.example\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.captureMaterialized(allocator, path, materialized, .{});
    defer bundle.deinit();
    @memset(materialized, 'x');

    try testing.expectEqualStrings(source, bundle.sourceBytes());
    try testing.expect(bundle.manifest().materialized_source != null);
    try testing.expectError(error.AssetNotDeclared, bundle.resolveLocal("original.yaml"));
    try testing.expectEqualStrings(
        "payload:\n  - effective.example\n",
        try bundle.resolveLocal("effective.yaml"),
    );
    var loaded = try bundle.loadOffline(allocator);
    defer loaded.deinit();
    try testing.expectEqual(@as(u16, 7891), loaded.config.mixed_port);
    var loaded_again = try bundle.loadOffline(allocator);
    defer loaded_again.deinit();
    try testing.expectEqual(@as(u16, 7891), loaded_again.config.mixed_port);
    try testing.expectEqualStrings(
        bundle.materializedSourceBytes().?,
        bundle.effectiveSourceBytes(),
    );
}

test "ConfigBundle parses nested CRLF blocks across blank and comment lines" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "mixed-port: 7890\r\n" ++
        "rule-providers:\r\n" ++
        "\r\n" ++
        "# provider declarations\r\n" ++
        "  local:\r\n" ++
        "    type: file\r\n" ++
        "    behavior: domain\r\n" ++
        "    path: rules.yaml\r\n" ++
        "rules:\r\n" ++
        "  - RULE-SET,local,DIRECT\r\n";
    const rules = "payload:\r\n\r\n# entries\r\n  - example.com\r\n";
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", rules);
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    var loaded = try bundle.loadOffline(allocator);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.config.rules.items.len);
    try testing.expectEqualStrings("example.com", loaded.config.rules.items[0].payload);
}

test "ConfigBundle offline load expands local rule sets and preserves remote declarations" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  local:
        \\    type: http
        \\    behavior: domain
        \\    path: rules.yaml
        \\  remote:
        \\    type: http
        \\    behavior: domain
        \\    path: remote.yaml
        \\    url: "http://127.0.0.1:1/must-not-connect"
        \\rules:
        \\  - RULE-SET,local,DIRECT
        \\  - RULE-SET,remote,DIRECT
        \\  - MATCH,DIRECT
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", "payload:\n  - +.example.com\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    try tmp.dir.deleteFile(compat.io(), "config.yaml");
    try tmp.dir.deleteFile(compat.io(), "rules.yaml");

    var loaded = try bundle.loadOffline(allocator);
    defer loaded.deinit();
    try testing.expect(loaded.validation.isValid());
    try testing.expectEqual(@as(usize, 3), loaded.config.rules.items.len);
    try testing.expectEqual(.domain_suffix, loaded.config.rules.items[0].rule_type);
    try testing.expectEqualStrings("example.com", loaded.config.rules.items[0].payload);
    try testing.expectEqual(.rule_set, loaded.config.rules.items[1].rule_type);
    try testing.expectEqualStrings("remote", loaded.config.rules.items[1].payload);

    var loaded_again = try bundle.loadOffline(allocator);
    defer loaded_again.deinit();
    try testing.expectEqualStrings(
        loaded.config.rules.items[0].payload,
        loaded_again.config.rules.items[0].payload,
    );
}

test "ConfigBundle block-payload result matches the existing loader in shadow" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.yaml
        \\rules:
        \\  - RULE-SET,local,DIRECT
        \\  - MATCH,DIRECT
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", "payload:\n  - +.example.com\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var legacy = try config_mod.load(allocator, path);
    defer legacy.deinit();
    try config_mod.prepareRuleProvidersForRuntime(allocator, &legacy, path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    var shadow = try bundle.loadOffline(allocator);
    defer shadow.deinit();

    try testing.expectEqual(legacy.rules.items.len, shadow.config.rules.items.len);
    for (legacy.rules.items, shadow.config.rules.items) |expected, actual| {
        try testing.expectEqual(expected.rule_type, actual.rule_type);
        try testing.expectEqualStrings(expected.payload, actual.payload);
        try testing.expectEqualStrings(expected.target, actual.target);
        try testing.expectEqual(expected.no_resolve, actual.no_resolve);
    }
}

test "ConfigBundle offline provider parser accepts an empty YAML payload" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  empty:
        \\    type: file
        \\    behavior: domain
        \\    path: empty.yaml
        \\rules:
        \\  - RULE-SET,empty,DIRECT
        \\  - MATCH,DIRECT
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "empty.yaml", "\xEF\xBB\xBF---\n\"payload\": []\n...\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    var loaded = try bundle.loadOffline(allocator);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.config.rules.items.len);
    try testing.expectEqual(.final, loaded.config.rules.items[0].rule_type);
}

test "ConfigBundle parses root-flow provider documents with metadata" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.yaml
        \\rules:
        \\  - RULE-SET,local,DIRECT
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", "{format: yaml, payload: [\"example\\u002ecom\"]}\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    var loaded = try bundle.loadOffline(allocator);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.config.rules.items.len);
    try testing.expectEqual(.domain_suffix, loaded.config.rules.items[0].rule_type);
    try testing.expectEqualStrings("example.com", loaded.config.rules.items[0].payload);
}

test "ConfigBundle accepts IPv4-embedded IPv6 provider CIDR" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: ipcidr
        \\    path: rules.yaml
        \\rules:
        \\  - RULE-SET,local,DIRECT
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", "::ffff:192.0.2.0/120\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    var loaded = try bundle.loadOffline(allocator);
    defer loaded.deinit();
    try testing.expect(loaded.validation.isValid());
    try testing.expectEqual(@as(usize, 1), loaded.config.rules.items.len);
    try testing.expectEqual(.ip_cidr6, loaded.config.rules.items[0].rule_type);
}

test "ConfigBundle rejects malformed unused local IP provider offline" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  unused:
        \\    type: file
        \\    behavior: ipcidr
        \\    path: rules.yaml
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", "payload:\n  - garbage:address/64\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    try testing.expectError(error.InvalidRuleProviderEntry, bundle.loadOffline(allocator));
}

test "ConfigBundle preserves raw classical entries containing mapping-like colons" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: classical
        \\    path: rules.txt
        \\rules:
        \\  - RULE-SET,local,REJECT
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.txt", "PROCESS-NAME,foo: bar\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    var loaded = try bundle.loadOffline(allocator);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.config.rules.items.len);
    try testing.expectEqual(.process_name, loaded.config.rules.items[0].rule_type);
    try testing.expectEqualStrings("foo: bar", loaded.config.rules.items[0].payload);
    try testing.expectEqualStrings("REJECT", loaded.config.rules.items[0].target);
}

test "ConfigBundle classical providers cannot override the RULE-SET target" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: classical
        \\    path: rules.yaml
        \\rules:
        \\  - RULE-SET,local,REJECT
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", "payload:\n  - DOMAIN,example.com,DIRECT\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    try testing.expectError(error.InvalidRuleProviderEntry, bundle.loadOffline(allocator));
}

test "ConfigBundle validates payloads in unused classical providers" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  unused:
        \\    type: file
        \\    behavior: classical
        \\    path: rules.yaml
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", "payload:\n  - IP-CIDR,garbage/24\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    try testing.expectError(error.InvalidRuleProviderEntry, bundle.loadOffline(allocator));
}

test "ConfigBundle rejects malformed unused local classical provider offline" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\rule-providers:
        \\  unused:
        \\    type: http
        \\    behavior: classical
        \\    path: rules.yaml
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    try writeFile(tmp.dir, "rules.yaml", "payload:\n  - NOT-A-RULE\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    try testing.expectError(error.UnknownRuleType, bundle.loadOffline(allocator));
}

test "ConfigBundle validation rejects rule payloads the runtime cannot parse" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\mixed-port: 7890
        \\rules:
        \\  - IP-CIDR6,192.0.2.0/24,DIRECT
        \\  - DST-PORT,80-443-500,DIRECT
    ;
    try writeFile(tmp.dir, "config.yaml", source);
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    var bundle = try ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    var loaded = try bundle.loadOffline(allocator);
    defer loaded.deinit();
    try testing.expect(!loaded.validation.isValid());
    try testing.expectEqual(@as(usize, 2), loaded.validation.errors.items.len);
}

test "ConfigBundle refuses callers that try to widen managed capture limits" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);

    try testing.expectError(error.LimitsExceedContract, ConfigBundle.capture(allocator, path, .{
        .max_source_bytes = CaptureLimits.defaults.max_source_bytes + 1,
    }));
    try testing.expectError(error.LimitsExceedContract, ConfigBundle.capture(allocator, path, .{
        .max_asset_bytes = CaptureLimits.defaults.max_asset_bytes + 1,
    }));
    try testing.expectError(error.LimitsExceedContract, ConfigBundle.capture(allocator, path, .{
        .max_aggregate_bytes = CaptureLimits.defaults.max_aggregate_bytes + 1,
    }));
    try testing.expectError(error.LimitsExceedContract, ConfigBundle.capture(allocator, path, .{
        .max_assets = CaptureLimits.defaults.max_assets + 1,
    }));
}

test "ConfigBundle default capture limits remain the managed contract" {
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), CaptureLimits.defaults.max_source_bytes);
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024), CaptureLimits.defaults.max_asset_bytes);
    try testing.expectEqual(@as(usize, 64 * 1024 * 1024), CaptureLimits.defaults.max_aggregate_bytes);
    try testing.expectEqual(@as(usize, 1024), CaptureLimits.defaults.max_assets);
}
