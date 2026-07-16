const std = @import("std");
const testing = std.testing;
const compat = @import("compat.zig");
const config_bundle = @import("config_bundle.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");
const legacy_mirror = @import("legacy_mirror.zig");
const revision_store = @import("revision_store.zig");
const state_authority = @import("state_authority.zig");

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(compat.io(), bytes);
}

fn realPath(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const value = try dir.realPathFileAlloc(compat.io(), path, allocator);
    defer allocator.free(value);
    return allocator.dupe(u8, value);
}

fn source(port: u16) ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "mixed-port: {d}\nrule-providers:\n  local:\n    type: file\n    behavior: domain\n    path: assets/rules.yaml\nrules:\n  - RULE-SET,local,DIRECT\n",
        .{port},
    );
}

test "LegacyMirror rebuilds effective heads metadata selections and local assets" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "legacy", .default_dir);
    try tmp.dir.createDir(compat.io(), "legacy/assets", .default_dir);
    const original = try source(7890);
    defer allocator.free(original);
    const effective = try source(9000);
    defer allocator.free(effective);
    try writeFile(tmp.dir, "legacy/home.yaml", original);
    try writeFile(tmp.dir, "legacy/assets/rules.yaml", "payload:\n  - example.com\n");
    const source_path = try realPath(allocator, tmp.dir, "legacy/home.yaml");
    defer allocator.free(source_path);
    var bundle = try config_bundle.ConfigBundle.captureMaterialized(
        allocator,
        source_path,
        effective,
        .{},
    );
    defer bundle.deinit();
    const store = revision_store.RevisionStore.init(allocator, tmp.dir);
    const published = try store.publishMigration("home", &bundle, .{
        .url = "https://example.test/sub",
        .filename = "Home",
        .params = &.{.{ .key = "target", .value = "clash" }},
        .override = .{
            .script_name = "override.sh",
            .script_bytes = "#!/bin/sh\n",
            .command = "legacy-migration",
            .patch_bytes = "mixed-port: 9000\n",
        },
    });
    const selections = [_]config_catalog.Selection{.{ .group = "Proxy", .proxy = "A" }};
    const profiles = [_]config_catalog.Profile{.{
        .key = "home",
        .storage_id = config_identity.StorageId.derive("home"),
        .head = published.revision,
        .desired = .{ .generation = 1, .selections = &selections },
    }};
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var initial = try authority.inspect();
    defer initial.deinit();
    try testing.expect((try authority.bootstrapCatalog(initial.token(), .{
        .active = .{ .key = "home", .revision = published.revision },
        .profiles = &profiles,
    })) == .committed);

    try tmp.dir.deleteTree(compat.io(), "legacy");
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/stale.yaml", "mixed-port: 1\n");
    try writeFile(tmp.dir, "meta.json", "stale\n");
    const mirror = legacy_mirror.LegacyMirror.init(allocator, tmp.dir);
    const receipt = try mirror.rebuild();
    try testing.expectEqual(@as(u64, 1), receipt.sequence);
    try testing.expectEqual(@as(usize, 1), receipt.profile_count);

    const mirrored = try tmp.dir.readFileAlloc(compat.io(), "configs/home.yaml", allocator, .limited(1024 * 1024));
    defer allocator.free(mirrored);
    try testing.expectEqualStrings(effective, mirrored);
    const asset = try tmp.dir.readFileAlloc(compat.io(), "configs/assets/rules.yaml", allocator, .limited(1024));
    defer allocator.free(asset);
    try testing.expectEqualStrings("payload:\n  - example.com\n", asset);
    const mirrored_path = try realPath(allocator, tmp.dir, "configs/home.yaml");
    defer allocator.free(mirrored_path);
    var mirrored_bundle = try config_bundle.ConfigBundle.capture(allocator, mirrored_path, .{});
    defer mirrored_bundle.deinit();
    var loaded = try mirrored_bundle.loadOffline(allocator);
    defer loaded.deinit();
    try testing.expect(loaded.validation.isValid());
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "configs/stale.yaml", .{}));

    const meta_bytes = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(1024 * 1024));
    defer allocator.free(meta_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, meta_bytes, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("home", parsed.value.object.get("active").?.string);
    const home = parsed.value.object.get("configs").?.object.get("home").?.object;
    try testing.expectEqualStrings("https://example.test/sub", home.get("url").?.string);
    try testing.expectEqualStrings("clash", home.get("params").?.object.get("target").?.string);
    try testing.expectEqualStrings("A", home.get("selections").?.object.get("Proxy").?.string);
    try testing.expect(home.get("override_script") == null);

    const repeated = try mirror.rebuild();
    try testing.expectEqual(receipt.sequence, repeated.sequence);
    const repeated_meta = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(1024 * 1024));
    defer allocator.free(repeated_meta);
    try testing.expectEqualStrings(meta_bytes, repeated_meta);
}

test "LegacyMirror exports logical asset aliases rather than canonical source paths" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "legacy", .default_dir);
    try tmp.dir.createDir(compat.io(), "legacy/assets", .default_dir);
    const config_source =
        "rule-providers:\n  local:\n    type: file\n    behavior: domain\n    path: rules.yaml\nrules:\n  - RULE-SET,local,DIRECT\n";
    try writeFile(tmp.dir, "legacy/config.yaml", config_source);
    try writeFile(tmp.dir, "legacy/assets/rules.yaml", "payload:\n  - alias.example\n");
    tmp.dir.symLink(compat.io(), "assets/rules.yaml", "legacy/rules.yaml", .{}) catch
        return error.SkipZigTest;
    const absolute = try realPath(allocator, tmp.dir, "legacy/config.yaml");
    defer allocator.free(absolute);
    var bundle = try config_bundle.ConfigBundle.capture(allocator, absolute, .{});
    defer bundle.deinit();
    const store = revision_store.RevisionStore.init(allocator, tmp.dir);
    const published = try store.publishMigration("home", &bundle, .{});
    const profiles = [_]config_catalog.Profile{.{
        .key = "home",
        .storage_id = config_identity.StorageId.derive("home"),
        .head = published.revision,
    }};
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var initial = try authority.inspect();
    defer initial.deinit();
    _ = try authority.bootstrapCatalog(initial.token(), .{ .profiles = &profiles });
    try tmp.dir.deleteTree(compat.io(), "legacy");

    const mirror = legacy_mirror.LegacyMirror.init(allocator, tmp.dir);
    _ = try mirror.rebuild();
    const alias = try tmp.dir.readFileAlloc(compat.io(), "configs/rules.yaml", allocator, .limited(1024));
    defer allocator.free(alias);
    try testing.expectEqualStrings("payload:\n  - alias.example\n", alias);
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "configs/assets/rules.yaml", .{}));
}

fn rebuildAllocationFixture(allocator: std.mem.Allocator, root: std.Io.Dir) !void {
    const mirror = legacy_mirror.LegacyMirror.init(allocator, root);
    _ = try mirror.rebuild();
}

test "LegacyMirror releases every rebuild allocation failure path" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    const absolute = try realPath(allocator, tmp.dir, "source.yaml");
    defer allocator.free(absolute);
    var bundle = try config_bundle.ConfigBundle.capture(allocator, absolute, .{});
    defer bundle.deinit();
    const store = revision_store.RevisionStore.init(allocator, tmp.dir);
    const published = try store.publishMigration("home", &bundle, .{});
    const profiles = [_]config_catalog.Profile{.{
        .key = "home",
        .storage_id = config_identity.StorageId.derive("home"),
        .head = published.revision,
    }};
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var initial = try authority.inspect();
    defer initial.deinit();
    _ = try authority.bootstrapCatalog(initial.token(), .{ .profiles = &profiles });

    try testing.checkAllAllocationFailures(
        testing.allocator,
        rebuildAllocationFixture,
        .{tmp.dir},
    );
}

test "LegacyMirror collision leaves the existing mirror untouched" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = revision_store.RevisionStore.init(allocator, tmp.dir);
    var catalog_profiles: [2]config_catalog.Profile = undefined;
    for ([_]struct { key: []const u8, body: []const u8 }{
        .{ .key = "a", .body = "payload:\n  - a.example\n" },
        .{ .key = "b", .body = "payload:\n  - b.example\n" },
    }, 0..) |fixture, index| {
        try tmp.dir.createDir(compat.io(), fixture.key, .default_dir);
        const asset_dir = try std.fmt.allocPrint(allocator, "{s}/assets", .{fixture.key});
        defer allocator.free(asset_dir);
        try tmp.dir.createDir(compat.io(), asset_dir, .default_dir);
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config.yaml", .{fixture.key});
        defer allocator.free(config_path);
        const config_source = try source(7890 + @as(u16, @intCast(index)));
        defer allocator.free(config_source);
        try writeFile(tmp.dir, config_path, config_source);
        const asset_path = try std.fmt.allocPrint(allocator, "{s}/assets/rules.yaml", .{fixture.key});
        defer allocator.free(asset_path);
        try writeFile(tmp.dir, asset_path, fixture.body);
        const absolute = try realPath(allocator, tmp.dir, config_path);
        defer allocator.free(absolute);
        var bundle = try config_bundle.ConfigBundle.capture(allocator, absolute, .{});
        defer bundle.deinit();
        const published = try store.publishMigration(fixture.key, &bundle, .{});
        catalog_profiles[index] = .{
            .key = fixture.key,
            .storage_id = config_identity.StorageId.derive(fixture.key),
            .head = published.revision,
        };
    }
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var initial = try authority.inspect();
    defer initial.deinit();
    _ = try authority.bootstrapCatalog(initial.token(), .{ .profiles = &catalog_profiles });
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/sentinel", "keep\n");

    const mirror = legacy_mirror.LegacyMirror.init(allocator, tmp.dir);
    try testing.expectError(error.LegacyMirrorCollision, mirror.rebuild());
    const sentinel = try tmp.dir.readFileAlloc(compat.io(), "configs/sentinel", allocator, .limited(16));
    defer allocator.free(sentinel);
    try testing.expectEqualStrings("keep\n", sentinel);
}
