const std = @import("std");
const testing = std.testing;
const compat = @import("compat.zig");
const config_bundle = @import("config_bundle.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");
const managed_loader = @import("managed_config_loader.zig");
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

fn publish(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    key: []const u8,
    source_path: []const u8,
    materialized: ?[]const u8,
) !revision_store.PublishedRevision {
    var bundle = if (materialized) |effective|
        try config_bundle.ConfigBundle.captureMaterialized(allocator, source_path, effective, .{})
    else
        try config_bundle.ConfigBundle.capture(allocator, source_path, .{});
    defer bundle.deinit();
    return revision_store.RevisionStore.init(allocator, root).publishMigration(key, &bundle, .{});
}

test "ManagedConfigLoader loads active immutable bytes and local assets with exact identity" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "legacy", .default_dir);
    try writeFile(tmp.dir, "legacy/config.yaml", "mixed-port: 7890\nrule-providers:\n  local:\n    type: file\n    behavior: domain\n    path: rules.yaml\nrules:\n  - RULE-SET,local,DIRECT\n");
    try writeFile(tmp.dir, "legacy/rules.yaml", "payload:\n  - example.com\n");
    const path = try realPath(allocator, tmp.dir, "legacy/config.yaml");
    defer allocator.free(path);
    const published = try publish(allocator, tmp.dir, "home", path, null);
    const profiles = [_]config_catalog.Profile{.{
        .key = "home",
        .storage_id = config_identity.StorageId.derive("home"),
        .head = published.revision,
    }};
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var initial = try authority.inspect();
    defer initial.deinit();
    _ = try authority.bootstrapCatalog(initial.token(), .{
        .active = .{ .key = "home", .revision = published.revision },
        .profiles = &profiles,
    });
    try tmp.dir.deleteTree(compat.io(), "legacy");

    const loader = managed_loader.Loader.init(allocator, tmp.dir);
    var loaded = try loader.loadActive();
    defer loaded.deinit();
    try testing.expectEqual(managed_loader.Origin.managed_revision, loaded.origin);
    try testing.expectEqualStrings("home", loaded.identity.?.key);
    try testing.expect(loaded.identity.?.revision.eql(published.revision));
    try testing.expectEqual(@as(u16, 7890), loaded.config.mixed_port);
    try testing.expect(loaded.validation.isValid());
    try testing.expectEqual(@as(usize, 2), loaded.config.rules.items.len);
    try testing.expectEqualStrings("example.com", loaded.config.rules.items[0].payload);
    try testing.expectEqualStrings("REJECT", loaded.config.rules.items[1].target);
}

test "ManagedConfigLoader distinguishes head from an older exact revision" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);
    const first = try publish(allocator, tmp.dir, "home", path, null);
    const second = try publish(allocator, tmp.dir, "home", path, "mixed-port: 9000\n");
    const profiles = [_]config_catalog.Profile{.{
        .key = "home",
        .storage_id = config_identity.StorageId.derive("home"),
        .head = second.revision,
    }};
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var initial = try authority.inspect();
    defer initial.deinit();
    _ = try authority.bootstrapCatalog(initial.token(), .{ .profiles = &profiles });

    const loader = managed_loader.Loader.init(allocator, tmp.dir);
    var head = try loader.loadHead("home");
    defer head.deinit();
    var source = try loader.loadHeadWithoutOverride("home");
    defer source.deinit();
    var old = try loader.loadExact(.{ .key = "home", .revision = first.revision });
    defer old.deinit();
    try testing.expectEqual(@as(u16, 9000), head.config.mixed_port);
    try testing.expectEqual(@as(u16, 7890), source.config.mixed_port);
    try testing.expect(source.identity.?.revision.eql(head.identity.?.revision));
    try testing.expectEqual(@as(u16, 7890), old.config.mixed_port);
    try testing.expect(!head.identity.?.revision.eql(old.identity.?.revision));
}

fn managedLoadAllocationFixture(allocator: std.mem.Allocator, root: std.Io.Dir) !void {
    const loader = managed_loader.Loader.init(allocator, root);
    var loaded = try loader.loadHead("home");
    loaded.deinit();
}

test "ManagedConfigLoader can inspect source replaced by a frozen override" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(
        tmp.dir,
        "config.yaml",
        "rule-providers:\n  missing:\n    type: file\n    behavior: domain\n    path: absent.yaml\nrules:\n  - RULE-SET,missing,DIRECT\n",
    );
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);
    const published = try publish(
        allocator,
        tmp.dir,
        "home",
        path,
        "mixed-port: 9000\nrules:\n  - MATCH,DIRECT\n",
    );
    const profiles = [_]config_catalog.Profile{.{
        .key = "home",
        .storage_id = config_identity.StorageId.derive("home"),
        .head = published.revision,
    }};
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var initial = try authority.inspect();
    defer initial.deinit();
    _ = try authority.bootstrapCatalog(initial.token(), .{
        .active = .{ .key = "home", .revision = published.revision },
        .profiles = &profiles,
    });

    const loader = managed_loader.Loader.init(allocator, tmp.dir);
    var effective = try loader.loadActive();
    defer effective.deinit();
    try testing.expectEqual(@as(u16, 9000), effective.config.mixed_port);
    var source_config = try loader.loadActiveWithoutOverride();
    defer source_config.deinit();
    try testing.expectEqual(
        @as(usize, 1),
        source_config.config.rule_providers.items.len,
    );
    try testing.expectEqualStrings(
        "missing",
        source_config.config.rule_providers.items[0].name,
    );
}

test "ManagedConfigLoader releases every managed load allocation failure path" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(path);
    const published = try publish(allocator, tmp.dir, "home", path, null);
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
        managedLoadAllocationFixture,
        .{tmp.dir},
    );
}

test "ManagedConfigLoader explicit unmanaged path never falls back to active identity" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "managed.yaml", "mixed-port: 9000\n");
    try writeFile(tmp.dir, "unmanaged.yaml", "mixed-port: 7000\nrule-providers:\n  local:\n    type: file\n    behavior: domain\n    path: unmanaged-rules.yaml\nrules:\n  - RULE-SET,local,DIRECT\n");
    try writeFile(tmp.dir, "unmanaged-rules.yaml", "payload:\n  - unmanaged.example\n");
    const managed_path = try realPath(allocator, tmp.dir, "managed.yaml");
    defer allocator.free(managed_path);
    const published = try publish(allocator, tmp.dir, "home", managed_path, null);
    const profiles = [_]config_catalog.Profile{.{
        .key = "home",
        .storage_id = config_identity.StorageId.derive("home"),
        .head = published.revision,
    }};
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var initial = try authority.inspect();
    defer initial.deinit();
    _ = try authority.bootstrapCatalog(initial.token(), .{
        .active = .{ .key = "home", .revision = published.revision },
        .profiles = &profiles,
    });

    const unmanaged_path = try realPath(allocator, tmp.dir, "unmanaged.yaml");
    defer allocator.free(unmanaged_path);
    const loader = managed_loader.Loader.init(allocator, tmp.dir);
    var loaded = try loader.loadUnmanagedPath(unmanaged_path);
    defer loaded.deinit();
    try testing.expectEqual(managed_loader.Origin.unmanaged_path, loaded.origin);
    try testing.expect(loaded.identity == null);
    try testing.expectEqual(@as(u16, 7000), loaded.config.mixed_port);
    try testing.expectEqual(@as(usize, 2), loaded.config.rules.items.len);
    try testing.expectEqualStrings("unmanaged.example", loaded.config.rules.items[0].payload);
    try testing.expectEqualStrings("REJECT", loaded.config.rules.items[1].target);
}
