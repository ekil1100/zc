const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const compat = @import("compat.zig");
const config_bundle = @import("config_bundle.zig");
const revision_store = @import("revision_store.zig");

const ConfigBundle = config_bundle.ConfigBundle;
const RevisionStore = revision_store.RevisionStore;

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

fn revisionPath(
    allocator: std.mem.Allocator,
    published: *const revision_store.PublishedRevision,
    tail: []const u8,
) ![]u8 {
    var revision_hex: [32]u8 = undefined;
    return std.fmt.allocPrint(
        allocator,
        "profiles/{s}/revisions/{s}/{s}",
        .{ published.storageIdHex(), published.revision.formatHex(&revision_hex), tail },
    );
}

fn configSource() []const u8 {
    return
    \\mixed-port: 7890
    \\rule-providers:
    \\  local:
    \\    type: file
    \\    behavior: domain
    \\    path: rules.yaml
    \\rules:
    \\  - RULE-SET,local,DIRECT
    ;
}

test "RevisionStore publishes and reopens an immutable bundle after legacy deletion" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "legacy", .default_dir);
    try writeFile(tmp.dir, "legacy/config.yaml", configSource());
    try writeFile(tmp.dir, "legacy/rules.yaml", "payload:\n  - example.com\n");
    const source_path = try realPath(allocator, tmp.dir, "legacy/config.yaml");
    defer allocator.free(source_path);

    const store = RevisionStore.init(allocator, tmp.dir);
    const published = blk: {
        var bundle = try ConfigBundle.capture(allocator, source_path, .{});
        defer bundle.deinit();
        break :blk try store.publishMigration("../家庭/配置", &bundle, .{
            .url = "https://example.test/subscription",
            .filename = "Home",
            .params = &.{
                .{ .key = "emoji", .value = "true" },
                .{ .key = "target", .value = "clash" },
            },
        });
    };
    try testing.expectEqual(@as(usize, 64), published.storageIdHex().len);
    try testing.expect(std.mem.indexOf(u8, published.storageIdHex(), "家庭") == null);

    try tmp.dir.deleteTree(compat.io(), "legacy");

    var view = try store.openVerified("../家庭/配置", published.revision);
    defer view.deinit();
    try testing.expectEqualStrings(configSource(), view.sourceBytes());
    try testing.expectEqualStrings(
        "payload:\n  - example.com\n",
        try view.resolveLocal("rules.yaml"),
    );
    try testing.expectEqualStrings("Home", view.metadata.filename.?);
    try testing.expectEqual(@as(usize, 2), view.metadata.params.len);
}

test "RevisionStore migration publish is idempotent and metadata order is canonical" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.capture(allocator, source_path, .{});
    defer bundle.deinit();
    const store = RevisionStore.init(allocator, tmp.dir);

    const first = try store.publishMigration("home", &bundle, .{ .params = &.{
        .{ .key = "z", .value = "last" },
        .{ .key = "a", .value = "first" },
    } });
    const repeated = try store.publishMigration("home", &bundle, .{ .params = &.{
        .{ .key = "a", .value = "first" },
        .{ .key = "z", .value = "last" },
    } });
    try testing.expectEqualStrings(
        "dc3fb855b586386498f9ec0db774a3d31da4003977fcbcd9a697fb7455a6645b",
        first.storageIdHex(),
    );
    try testing.expect(first.revision.eql(repeated.revision));
    try testing.expectEqualSlices(u8, &first.storage_id, &repeated.storage_id);
}

test "RevisionStore revision changes with dependency and materialized bytes" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", configSource());
    try writeFile(tmp.dir, "rules.yaml", "payload:\n  - one.example\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    const store = RevisionStore.init(allocator, tmp.dir);

    var first_bundle = try ConfigBundle.capture(allocator, source_path, .{});
    const first = try store.publishMigration("home", &first_bundle, .{});
    first_bundle.deinit();

    try writeFile(tmp.dir, "rules.yaml", "payload:\n  - two.example\n");
    var second_bundle = try ConfigBundle.capture(allocator, source_path, .{});
    const second = try store.publishMigration("home", &second_bundle, .{});
    second_bundle.deinit();
    try testing.expect(!first.revision.eql(second.revision));

    const materialized = "mixed-port: 7891\n";
    var materialized_bundle = try ConfigBundle.captureMaterialized(
        allocator,
        source_path,
        materialized,
        .{},
    );
    defer materialized_bundle.deinit();
    const third = try store.publishMigration("home", &materialized_bundle, .{});
    try testing.expect(!second.revision.eql(third.revision));
}

test "RevisionStore rejects intermediate symlink escape" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "store", .default_dir);
    try tmp.dir.createDir(compat.io(), "outside", .default_dir);
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    tmp.dir.symLink(compat.io(), "../outside", "store/profiles", .{}) catch return error.SkipZigTest;
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.capture(allocator, source_path, .{});
    defer bundle.deinit();
    const store_dir = try tmp.dir.openDir(compat.io(), "store", .{});
    defer store_dir.close(compat.io());
    const store = RevisionStore.init(allocator, store_dir);

    if (store.publishMigration("home", &bundle, .{})) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    var outside = try tmp.dir.openDir(compat.io(), "outside", .{ .iterate = true });
    defer outside.close(compat.io());
    var iterator = outside.iterate();
    try testing.expect((try iterator.next(compat.io())) == null);
}

test "RevisionStore rejects oversized encoded identity before persistence" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.capture(allocator, source_path, .{});
    defer bundle.deinit();
    const oversized_key = try allocator.alloc(u8, 70 * 1024);
    defer allocator.free(oversized_key);
    @memset(oversized_key, 'k');
    const store = RevisionStore.init(allocator, tmp.dir);
    try testing.expectError(error.IdentityTooLarge, store.publishMigration(oversized_key, &bundle, .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "profiles", .{}));
}

test "RevisionStore strict reopen rejects FIFO and dangling optional symlink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.capture(allocator, source_path, .{});
    defer bundle.deinit();
    const store = RevisionStore.init(allocator, tmp.dir);
    const published = try store.publishMigration("home", &bundle, .{});

    const materialized_path = try revisionPath(allocator, &published, "materialized.yaml");
    defer allocator.free(materialized_path);
    tmp.dir.symLink(compat.io(), "missing-target", materialized_path, .{}) catch return error.SkipZigTest;
    try testing.expectError(error.CorruptRevision, store.openVerified("home", published.revision));
    try tmp.dir.deleteFile(compat.io(), materialized_path);

    const source_revision_path = try revisionPath(allocator, &published, "source.yaml");
    defer allocator.free(source_revision_path);
    try tmp.dir.deleteFile(compat.io(), source_revision_path);
    const source_z = try allocator.dupeZ(u8, source_revision_path);
    defer allocator.free(source_z);
    if (mkfifoat(tmp.dir.handle, source_z, 0o600) != 0) return error.SkipZigTest;
    try testing.expectError(error.CorruptRevision, store.openVerified("home", published.revision));
}

test "RevisionStore tightens existing file permissions on verified reopen" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.capture(allocator, source_path, .{});
    defer bundle.deinit();
    const store = RevisionStore.init(allocator, tmp.dir);
    const published = try store.publishMigration("home", &bundle, .{});
    const stored_source = try revisionPath(allocator, &published, "source.yaml");
    defer allocator.free(stored_source);
    const file = try tmp.dir.openFile(compat.io(), stored_source, .{});
    try file.setPermissions(compat.io(), std.Io.File.Permissions.fromMode(0o666));
    file.close(compat.io());

    var view = try store.openVerified("home", published.revision);
    view.deinit();
    const reopened = try tmp.dir.openFile(compat.io(), stored_source, .{});
    defer reopened.close(compat.io());
    const stat = try reopened.stat(compat.io());
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

fn publishRevisionAllocationFixture(allocator: std.mem.Allocator) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.captureMaterialized(
        allocator,
        source_path,
        "mixed-port: 9000\n",
        .{},
    );
    defer bundle.deinit();
    const store = RevisionStore.init(allocator, tmp.dir);
    _ = try store.publishMigration("home", &bundle, .{
        .url = "https://example.test/subscription",
        .params = &.{.{ .key = "target", .value = "clash" }},
        .override = .{
            .script_name = "override.sh",
            .script_bytes = "#!/bin/sh\n",
            .command = "test",
            .patch_bytes = "mixed-port: 9000\n",
        },
    });
}

test "RevisionStore releases every publish allocation failure path" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        publishRevisionAllocationFixture,
        .{},
    );
}

fn openRevisionAllocationFixture(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    revision: @import("state_authority.zig").Revision,
) !void {
    const store = RevisionStore.init(allocator, root);
    var view = try store.openVerified("home", revision);
    view.deinit();
}

test "RevisionStore open releases every allocation failure path" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", configSource());
    try writeFile(tmp.dir, "rules.yaml", "payload: []\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.captureMaterialized(allocator, source_path, configSource(), .{});
    defer bundle.deinit();
    const store = RevisionStore.init(allocator, tmp.dir);
    const published = try store.publishMigration("home", &bundle, .{
        .url = "https://example.test/subscription",
        .filename = "Home",
        .params = &.{.{ .key = "target", .value = "clash" }},
        .override = .{
            .script_name = "override.sh",
            .script_bytes = "#!/bin/sh\n",
            .command = "test",
            .patch_bytes = "",
        },
    });

    try testing.checkAllAllocationFailures(
        testing.allocator,
        openRevisionAllocationFixture,
        .{ tmp.dir, published.revision },
    );
}

test "RevisionStore reopens pre-override manifests without changing their identity" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.capture(allocator, source_path, .{});
    defer bundle.deinit();
    const store = RevisionStore.init(allocator, tmp.dir);
    const published = try store.publishMigration("home", &bundle, .{});
    const manifest_path = try revisionPath(allocator, &published, "manifest.json");
    defer allocator.free(manifest_path);
    const manifest = try tmp.dir.readFileAlloc(compat.io(), manifest_path, allocator, .limited(1024 * 1024));
    defer allocator.free(manifest);
    const marker = "\"override\":null,";
    const marker_index = std.mem.indexOf(u8, manifest, marker) orelse return error.TestExpectedEqual;
    const legacy_manifest = try std.mem.concat(allocator, u8, &.{
        manifest[0..marker_index],
        manifest[marker_index + marker.len ..],
    });
    defer allocator.free(legacy_manifest);
    const file = try tmp.dir.createFile(compat.io(), manifest_path, .{ .truncate = true });
    try file.writeStreamingAll(compat.io(), legacy_manifest);
    file.close(compat.io());

    var reopened = try store.openVerified("home", published.revision);
    defer reopened.deinit();
    try testing.expect(reopened.override == null);
}

test "RevisionStore persists and verifies frozen override provenance" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.captureMaterialized(
        allocator,
        source_path,
        "mixed-port: 9000\n",
        .{},
    );
    defer bundle.deinit();
    const args = [_]revision_store.OverrideArgument{
        .{ .key = "region", .value = "hk" },
        .{ .key = "empty", .value = "" },
    };
    const store = RevisionStore.init(allocator, tmp.dir);
    const published = try store.publishMigration("home", &bundle, .{ .override = .{
        .script_name = "override.sh",
        .script_bytes = "#!/bin/sh\n",
        .command = "legacy-migration",
        .config_path = "configs/home.yaml",
        .timeout_ms = 500,
        .args = &args,
        .patch_bytes = "mixed-port: 9000\n",
    } });

    var view = try store.openVerified("home", published.revision);
    defer view.deinit();
    const frozen = view.override orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("override.sh", frozen.script_name);
    try testing.expectEqualStrings("#!/bin/sh\n", frozen.script_bytes);
    try testing.expectEqualStrings("legacy-migration", frozen.command);
    try testing.expectEqualStrings("configs/home.yaml", frozen.config_path.?);
    try testing.expectEqual(@as(u32, 500), frozen.timeout_ms);
    try testing.expectEqual(@as(usize, 2), frozen.args.len);
    try testing.expectEqualStrings("region", frozen.args[0].key);
    try testing.expectEqualStrings("", frozen.args[1].value);
    try testing.expectEqualStrings("mixed-port: 9000\n", frozen.patch_bytes);
    try testing.expectEqualStrings("mixed-port: 9000\n", view.effectiveSourceBytes());
}

test "RevisionStore override provenance changes identity and fails closed on tampering" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.captureMaterialized(
        allocator,
        source_path,
        "mixed-port: 9000\n",
        .{},
    );
    defer bundle.deinit();
    const store = RevisionStore.init(allocator, tmp.dir);
    const base_override: revision_store.OverrideInput = .{
        .script_name = "override.sh",
        .script_bytes = "#!/bin/sh\n",
        .command = "legacy-migration",
        .patch_bytes = "mixed-port: 9000\n",
    };
    const first = try store.publishMigration("home", &bundle, .{ .override = base_override });
    var changed = base_override;
    changed.timeout_ms = 501;
    const second = try store.publishMigration("home", &bundle, .{ .override = changed });
    try testing.expect(!first.revision.eql(second.revision));
    changed = base_override;
    changed.script_bytes = "#!/bin/sh\n# changed\n";
    const changed_script = try store.publishMigration("home", &bundle, .{ .override = changed });
    try testing.expect(!first.revision.eql(changed_script.revision));
    changed = base_override;
    changed.patch_bytes = "# same effective result\nmixed-port: 9000\n";
    const changed_patch = try store.publishMigration("home", &bundle, .{ .override = changed });
    try testing.expect(!first.revision.eql(changed_patch.revision));

    const patch_path = try revisionPath(allocator, &first, "override-output.yaml");
    defer allocator.free(patch_path);
    const patch = try tmp.dir.createFile(compat.io(), patch_path, .{ .truncate = true });
    try patch.writeStreamingAll(compat.io(), "mixed-port: 1\n");
    patch.close(compat.io());
    try testing.expectError(error.CorruptRevision, store.openVerified("home", first.revision));
}

test "RevisionStore requires materialized source and override provenance together" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", "mixed-port: 7890\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var plain = try ConfigBundle.capture(allocator, source_path, .{});
    defer plain.deinit();
    const store = RevisionStore.init(allocator, tmp.dir);
    try testing.expectError(error.OverrideMaterializationMismatch, store.publishMigration("home", &plain, .{
        .override = .{
            .script_name = "override.sh",
            .script_bytes = "#!/bin/sh\n",
            .command = "test",
            .patch_bytes = "mixed-port: 9000\n",
        },
    }));
}

test "RevisionStore open fails closed on missing or corrupt immutable objects" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.yaml", configSource());
    try writeFile(tmp.dir, "rules.yaml", "payload: []\n");
    const source_path = try realPath(allocator, tmp.dir, "config.yaml");
    defer allocator.free(source_path);
    var bundle = try ConfigBundle.capture(allocator, source_path, .{});
    defer bundle.deinit();
    const store = RevisionStore.init(allocator, tmp.dir);
    const published = try store.publishMigration("home", &bundle, .{});

    var revision_hex: [32]u8 = undefined;
    const revision_text = published.revision.formatHex(&revision_hex);
    var object_hex: [64]u8 = undefined;
    object_hex = std.fmt.bytesToHex(bundle.manifest().local_assets[0].content.sha256, .lower);
    const object_path = try std.fmt.allocPrint(
        allocator,
        "profiles/{s}/revisions/{s}/objects/{s}",
        .{ published.storageIdHex(), revision_text, &object_hex },
    );
    defer allocator.free(object_path);
    try writeFile(tmp.dir, object_path, "corrupt");
    try testing.expectError(error.CorruptRevision, store.openVerified("home", published.revision));

    try tmp.dir.deleteFile(compat.io(), object_path);
    try testing.expectError(error.CorruptRevision, store.openVerified("home", published.revision));
}
