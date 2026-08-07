const std = @import("std");
const testing = std.testing;
const compat = @import("compat.zig");
const catalog_commands = @import("catalog_commands.zig");
const catalog_service = @import("catalog_service.zig");
const config_bundle = @import("config_bundle.zig");
const revision_store = @import("revision_store.zig");
const state_authority = @import("state_authority.zig");

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(compat.io(), bytes);
}

const TreeSnapshot = struct {
    allocator: std.mem.Allocator,
    entries: [][]u8,

    fn deinit(self: *TreeSnapshot) void {
        for (self.entries) |entry| self.allocator.free(entry);
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

fn snapshotTree(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
) !TreeSnapshot {
    const dir = try root.openDir(compat.io(), path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(compat.io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var entries = std.ArrayList([]u8).empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }
    while (try walker.next(compat.io())) |entry| {
        const record = try std.fmt.allocPrint(
            allocator,
            "{s}:{s}",
            .{ @tagName(entry.kind), entry.path },
        );
        entries.append(allocator, record) catch |err| {
            allocator.free(record);
            return err;
        };
    }
    std.mem.sort([]u8, entries.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return .{
        .allocator = allocator,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn expectTreeEqual(expected: TreeSnapshot, actual: TreeSnapshot) !void {
    try testing.expectEqual(expected.entries.len, actual.entries.len);
    for (expected.entries, actual.entries) |expected_entry, actual_entry| {
        try testing.expectEqualStrings(expected_entry, actual_entry);
    }
}

fn bootstrapEmpty(allocator: std.mem.Allocator, root: std.Io.Dir) !state_authority.StateToken {
    const authority = state_authority.Authority.init(allocator, root);
    var missing = try authority.inspect();
    defer missing.deinit();
    return switch (try authority.bootstrapCatalog(missing.token(), .{})) {
        .committed => |receipt| receipt.token,
        else => error.TestExpectedEqual,
    };
}

fn publish(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    token: state_authority.StateToken,
    key: []const u8,
    display: ?[]const u8,
) !state_authority.StateToken {
    const path = try root.realPathFileAlloc(compat.io(), "source.yaml", allocator);
    defer allocator.free(path);
    var bundle = try config_bundle.ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    return switch (try catalog_service.Service.init(allocator, root).publish(token, .{
        .key = key,
        .expected = .missing,
        .bundle = &bundle,
        .metadata = .{ .filename = display },
        .desired = .clear,
    })) {
        .applied => |value| value.receipt.token,
        else => error.TestExpectedEqual,
    };
}

test "CatalogCommands lists exact keys and immutable display metadata" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var token = try bootstrapEmpty(allocator, tmp.dir);
    token = try publish(allocator, tmp.dir, token, "alpha", "Alpha");
    _ = try publish(allocator, tmp.dir, token, "Home", null);

    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    var listing = try commands.list();
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 2), listing.entries.len);
    try testing.expectEqual(state_authority.StateFormat.catalog_v2, listing.token.format);
    try testing.expectEqual(@as(u64, 3), listing.token.sequence);
    try testing.expectEqualStrings("Home", listing.entries[0].key);
    try testing.expectEqualStrings("Home", listing.entries[0].display);
    try testing.expectEqualStrings("alpha", listing.entries[1].key);
    try testing.expectEqualStrings("Alpha", listing.entries[1].display);
    try testing.expect(listing.active == null);
}

fn listAllocationFixture(allocator: std.mem.Allocator, root: std.Io.Dir) !void {
    var listing = try catalog_commands.Commands.init(allocator, root).list();
    listing.deinit();
}

test "CatalogCommands releases every listing allocation failure path" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var token = try bootstrapEmpty(allocator, tmp.dir);
    token = try publish(allocator, tmp.dir, token, "alpha", "Alpha");
    _ = try publish(allocator, tmp.dir, token, "home", null);
    try testing.checkAllAllocationFailures(testing.allocator, listAllocationFixture, .{tmp.dir});
}

test "CatalogCommands publishes and updates validated downloaded revisions" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try bootstrapEmpty(allocator, tmp.dir);
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    const first_source =
        "mixed-port: 7890\nproxies:\n  - name: A\n    type: direct\nproxy-groups:\n  - name: Proxy\n    type: select\n    proxies: [A]\nrules:\n  - MATCH,Proxy\n";
    const created = try commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = first_source,
        .metadata = .{ .url = "https://example.invalid/sub", .filename = "Home" },
        .mode = .create,
    });
    try testing.expect(created.receipt.mirror_error == null);
    var subscription = try commands.subscription("home");
    defer subscription.deinit();
    try testing.expectEqualStrings("https://example.invalid/sub", subscription.url);
    try testing.expect(subscription.revision.eql(created.revision));
    try testing.expectError(error.ManagedProfileNotFound, commands.subscription("missing"));
    try testing.expectError(error.ManagedProfileAlreadyExists, commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = first_source,
        .mode = .create,
    }));

    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var before = try authority.inspect();
    const token = before.token();
    const selections = [_]@import("config_catalog.zig").Selection{.{ .group = "Proxy", .proxy = "A" }};
    const selected = switch (try catalog_service.Service.init(allocator, tmp.dir).mutate(token, .{ .set_desired = .{
        .identity = .{ .key = "home", .revision = created.revision },
        .expected_generation = 0,
        .selections = &selections,
    } })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    before.deinit();
    _ = selected;

    const second_source =
        "mixed-port: 9000\nproxies:\n  - name: B\n    type: direct\nproxy-groups:\n  - name: Proxy\n    type: select\n    proxies: [B]\nrules:\n  - MATCH,Proxy\n";
    const updated = try commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = second_source,
        .mode = .update,
        .expected_revision = subscription.revision,
    });
    try testing.expect(!updated.revision.eql(created.revision));
    try testing.expectError(error.ProfileIdentityConflict, commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = first_source,
        .mode = .update,
        .expected_revision = subscription.revision,
    }));
    var after = try authority.inspect();
    defer after.deinit();
    switch (after) {
        .catalog_v2 => |*catalog| {
            const profile = catalog.catalog.state.profiles[0];
            try testing.expect(profile.head.eql(updated.revision));
            try testing.expectEqual(@as(u64, 2), profile.desired.generation);
            try testing.expectEqual(@as(usize, 0), profile.desired.selections.len);
            try testing.expect(catalog.catalog.state.active.?.revision.eql(updated.revision));
        },
        else => return error.TestExpectedEqual,
    }
}

test "CatalogCommands update preserves captured local assets" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "legacy", .default_dir);
    const source =
        "mixed-port: 7890\nrule-providers:\n  local:\n    type: file\n    behavior: domain\n    path: rules.yaml\nrules:\n  - RULE-SET,local,DIRECT\n";
    try writeFile(tmp.dir, "legacy/config.yaml", source);
    try writeFile(tmp.dir, "legacy/rules.yaml", "payload:\n  - example.com\n");
    const path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "legacy/config.yaml",
        allocator,
    );
    defer allocator.free(path);
    var bundle = try config_bundle.ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const created = switch (try catalog_service.Service.init(
        allocator,
        tmp.dir,
    ).publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &bundle,
        .metadata = .{ .url = "https://example.invalid/sub" },
        .desired = .clear,
        .activate = true,
    })) {
        .applied => |receipt| receipt,
        else => return error.TestExpectedEqual,
    };
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    const updated = try commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = source,
        .mode = .update,
        .expected_revision = created.revision,
    });
    var view = try @import("revision_store.zig").RevisionStore.init(
        allocator,
        tmp.dir,
    ).openVerified("home", updated.revision);
    defer view.deinit();
    try testing.expectEqualStrings(
        "payload:\n  - example.com\n",
        try view.resolveLocal("rules.yaml"),
    );
}

fn fixedOverridePatch(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    _: @import("override_materialization.zig").Script,
    _: @import("override_materialization.zig").Invocation,
) ![]u8 {
    const calls: *u8 = @ptrCast(@alignCast(raw));
    calls.* += 1;
    return allocator.dupe(u8, "mixed-port: 9000\n");
}

fn clearingOverridePatch(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    _: @import("override_materialization.zig").Script,
    _: @import("override_materialization.zig").Invocation,
) ![]u8 {
    const calls: *u8 = @ptrCast(@alignCast(raw));
    calls.* += 1;
    return allocator.dupe(u8, "mixed-port: 9000\nrule-providers: {}\nrules:\n  - MATCH,DIRECT\n");
}

fn materializationExpansionSource(allocator: std.mem.Allocator) ![]u8 {
    const max_source_bytes = @import("override_materialization.zig")
        .max_effective_source_bytes;
    const prefix = "mixed-port: 7890\nsecret: '";
    const suffix = "'\nrules:\n  - MATCH,DIRECT\n";
    const escaped_bytes = max_source_bytes / 2 + 4096;
    const source = try allocator.alloc(
        u8,
        prefix.len + escaped_bytes + suffix.len,
    );
    @memcpy(source[0..prefix.len], prefix);
    @memset(source[prefix.len .. prefix.len + escaped_bytes], '\\');
    @memcpy(source[prefix.len + escaped_bytes ..], suffix);
    return source;
}

test "CatalogCommands sets and clears a frozen override as exact revisions" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try bootstrapEmpty(allocator, tmp.dir);
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    const created = try commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = "mixed-port: 7890\n",
        .mode = .create,
    });
    var runner_context: u8 = 0;
    const overridden = try commands.setOverride(.{
        .key = "home",
        .script = .{ .name = "override.sh", .bytes = "#!/bin/sh\n" },
        .invocation = .{ .command = "config.override" },
        .runner = .{ .context = &runner_context, .run = fixedOverridePatch },
    });
    try testing.expectEqual(@as(u8, 1), runner_context);
    try testing.expect(!overridden.revision.eql(created.revision));
    var override_status = try commands.activeOverride();
    defer override_status.deinit();
    try testing.expectEqualStrings("home", override_status.key.?);
    try testing.expectEqualStrings("override.sh", override_status.script_name.?);
    var view = try @import("revision_store.zig").RevisionStore.init(allocator, tmp.dir).openVerified(
        "home",
        overridden.revision,
    );
    try testing.expect(view.override != null);
    try testing.expect(std.mem.indexOf(u8, view.effectiveSourceBytes(), "mixed-port: 9000") != null);
    view.deinit();

    _ = try commands.publishDownloaded(.{
        .key = "other",
        .source_bytes = "mixed-port: 7000\n",
        .mode = .create,
    });
    try testing.expectError(error.StateConflict, commands.setOverride(.{
        .key = "home",
        .script = .{ .name = "override.sh", .bytes = "#!/bin/sh\n" },
        .invocation = .{ .command = "config.override" },
        .runner = .{ .context = &runner_context, .run = fixedOverridePatch },
        .expected_token = override_status.token,
        .require_active = true,
    }));
    _ = try commands.activate("other");
    try testing.expectError(error.ActiveManagedProfileChanged, commands.setOverride(.{
        .key = "home",
        .script = .{ .name = "override.sh", .bytes = "#!/bin/sh\n" },
        .invocation = .{ .command = "config.override" },
        .runner = .{ .context = &runner_context, .run = fixedOverridePatch },
        .require_active = true,
    }));
    _ = try commands.activate("home");
    const cleared = (try commands.clearOverride(.{ .key = "home" })) orelse
        return error.TestExpectedEqual;
    try testing.expect(!cleared.revision.eql(overridden.revision));
    var clear_view = try @import("revision_store.zig").RevisionStore.init(allocator, tmp.dir).openVerified(
        "home",
        cleared.revision,
    );
    defer clear_view.deinit();
    try testing.expect(clear_view.override == null);
    try testing.expectEqualStrings("mixed-port: 7890\n", clear_view.effectiveSourceBytes());
    var cleared_status = try commands.activeOverride();
    defer cleared_status.deinit();
    try testing.expect(cleared_status.script_name == null);
    try testing.expect(try commands.clearOverride(.{ .key = "home" }) == null);
}

test "CatalogCommands update rejects persisted override materialization above 16 MiB" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try bootstrapEmpty(allocator, tmp.dir);
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    _ = try commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = "mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n",
        .mode = .create,
    });
    var runner_context: u8 = 0;
    _ = try commands.setOverride(.{
        .key = "home",
        .script = .{ .name = "override.sh", .bytes = "#!/bin/sh\n" },
        .invocation = .{ .command = "config.override" },
        .runner = .{ .context = &runner_context, .run = fixedOverridePatch },
    });
    try testing.expectEqual(@as(u8, 1), runner_context);
    const before = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(before);
    const expanded = try materializationExpansionSource(allocator);
    defer allocator.free(expanded);

    try testing.expectError(
        error.MaterializedSourceTooLarge,
        commands.publishDownloaded(.{
            .key = "home",
            .source_bytes = expanded,
            .mode = .update,
            .override_runner = .{
                .context = &runner_context,
                .run = fixedOverridePatch,
            },
        }),
    );
    try testing.expectEqual(@as(u8, 2), runner_context);
    const after = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "CatalogCommands update blocks instead of dropping frozen override provenance" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    const path = try tmp.dir.realPathFileAlloc(compat.io(), "source.yaml", allocator);
    defer allocator.free(path);
    var bundle = try config_bundle.ConfigBundle.captureMaterialized(
        allocator,
        path,
        "mixed-port: 9000\n",
        .{},
    );
    defer bundle.deinit();
    const token = try bootstrapEmpty(allocator, tmp.dir);
    _ = switch (try catalog_service.Service.init(allocator, tmp.dir).publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &bundle,
        .metadata = .{ .override = .{
            .script_name = "override.sh",
            .script_bytes = "#!/bin/sh\n",
            .command = "test",
            .patch_bytes = "mixed-port: 9000\n",
        } },
        .desired = .clear,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    const updated_source = "mixed-port: 8000\nrule-providers:\n  local:\n    type: file\n    behavior: domain\n    path: unavailable.yaml\nrules:\n  - RULE-SET,local,DIRECT\n";
    try testing.expectError(error.OverrideRematerializationRequired, commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = updated_source,
        .mode = .update,
    }));
    var runner_context: u8 = 0;
    const updated = try commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = updated_source,
        .mode = .update,
        .override_runner = .{ .context = &runner_context, .run = clearingOverridePatch },
    });
    try testing.expectEqual(@as(u8, 1), runner_context);
    var view = try @import("revision_store.zig").RevisionStore.init(allocator, tmp.dir).openVerified(
        "home",
        updated.revision,
    );
    defer view.deinit();
    try testing.expect(view.override != null);
    try testing.expectEqualStrings(updated_source, view.sourceBytes());
    try testing.expect(std.mem.indexOf(u8, view.effectiveSourceBytes(), "mixed-port: 9000") != null);
}

test "CatalogCommands rejects deferred remote RULE-SET for exact activation and every active publication path" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const remote_source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  deferred:
        \\    type: http
        \\    behavior: domain
        \\    url: https://example.invalid/rules.yaml
        \\    path: deferred.yaml
        \\rules:
        \\  - RULE-SET,deferred,DIRECT
        \\  - MATCH,DIRECT
    ;
    var token = try bootstrapEmpty(allocator, tmp.dir);
    var historical_bundle = try config_bundle.ConfigBundle.captureMemory(
        allocator,
        remote_source,
        null,
        .{},
    );
    defer historical_bundle.deinit();
    const historical = try revision_store.RevisionStore.init(
        allocator,
        tmp.dir,
    ).publishMigration("historical", &historical_bundle, .{});
    token = switch (try state_authority.Authority.init(
        allocator,
        tmp.dir,
    ).mutateCatalog(token, .{ .put_profile = .{
        .key = "historical",
        .expected = .missing,
        .head = historical.revision,
        .desired = .clear,
    } })) {
        .committed => |receipt| receipt.token,
        .durability_uncertain => |uncertain| uncertain.receipt.token,
        .conflict => return error.TestExpectedEqual,
    };

    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    const inactive_state = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(inactive_state);
    var inactive_tree = try snapshotTree(allocator, tmp.dir, "profiles");
    defer inactive_tree.deinit();

    try testing.expectError(
        error.ProfileNotRuntimeReady,
        commands.activate("historical"),
    );
    try testing.expectError(
        error.ProfileNotRuntimeReady,
        commands.publishDownloaded(.{
            .key = "automatic",
            .source_bytes = remote_source,
            .mode = .create,
        }),
    );
    try testing.expectError(
        error.ProfileNotRuntimeReady,
        commands.publishDownloaded(.{
            .key = "explicit",
            .source_bytes = remote_source,
            .mode = .create,
            .activate = true,
        }),
    );
    const rejected_state = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(rejected_state);
    try testing.expectEqualStrings(inactive_state, rejected_state);
    var rejected_tree = try snapshotTree(allocator, tmp.dir, "profiles");
    defer rejected_tree.deinit();
    try expectTreeEqual(inactive_tree, rejected_tree);

    const ready = try commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = "mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n",
        .mode = .create,
    });
    const active_state = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(active_state);
    var active_tree = try snapshotTree(allocator, tmp.dir, "profiles");
    defer active_tree.deinit();
    try testing.expectError(
        error.ProfileNotRuntimeReady,
        commands.publishDownloaded(.{
            .key = "home",
            .source_bytes = remote_source,
            .mode = .update,
            .expected_revision = ready.revision,
        }),
    );
    const update_state = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(update_state);
    try testing.expectEqualStrings(active_state, update_state);
    var update_tree = try snapshotTree(allocator, tmp.dir, "profiles");
    defer update_tree.deinit();
    try expectTreeEqual(active_tree, update_tree);
    var listing = try commands.list();
    defer listing.deinit();
    var found_home = false;
    for (listing.entries) |entry| {
        if (!std.mem.eql(u8, entry.key, "home")) continue;
        found_home = true;
        try testing.expect(entry.revision.eql(ready.revision));
        try testing.expect(entry.active);
    }
    try testing.expect(found_home);
}

test "CatalogCommands preserves malformed downloaded obfs as inactive raw" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try bootstrapEmpty(allocator, tmp.dir);
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    const source =
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
    const published = try commands.publishDownloaded(.{
        .key = "recovery",
        .source_bytes = source,
        .mode = .create,
    });

    var listing = try commands.list();
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 1), listing.entries.len);
    try testing.expect(listing.active == null);
    var view = try @import("revision_store.zig").RevisionStore.init(
        allocator,
        tmp.dir,
    ).openVerified("recovery", published.revision);
    defer view.deinit();
    try testing.expectEqualStrings(source, view.sourceBytes());
    var inspected_source = try commands.source("recovery");
    defer inspected_source.deinit();
    try testing.expectEqualStrings(source, inspected_source.bytes);
    try testing.expect(inspected_source.revision.eql(published.revision));
    try testing.expectError(
        error.ProfileNotRuntimeReady,
        commands.activate("recovery"),
    );
    try testing.expectError(
        error.ProfileNotRuntimeReady,
        commands.publishDownloaded(.{
            .key = "explicit-active",
            .source_bytes = source,
            .mode = .create,
            .activate = true,
        }),
    );
    const state_before_activation = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_before_activation);
    var tree_before_activation = try snapshotTree(allocator, tmp.dir, "profiles");
    defer tree_before_activation.deinit();
    try testing.expectError(
        error.ProfileNotRuntimeReady,
        commands.publishDownloaded(.{
            .key = "recovery",
            .source_bytes = source ++ "\n# requested activation\n",
            .mode = .update,
            .expected_revision = published.revision,
            .activate = true,
        }),
    );
    const state_after_activation = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_after_activation);
    try testing.expectEqualStrings(
        state_before_activation,
        state_after_activation,
    );
    var tree_after_activation = try snapshotTree(allocator, tmp.dir, "profiles");
    defer tree_after_activation.deinit();
    try expectTreeEqual(tree_before_activation, tree_after_activation);

    const refreshed_source = source ++ "\n# refreshed malformed body\n";
    const refreshed = try commands.publishDownloaded(.{
        .key = "recovery",
        .source_bytes = refreshed_source,
        .mode = .update,
        .expected_revision = published.revision,
    });
    try testing.expect(!refreshed.revision.eql(published.revision));
    var refreshed_view = try @import("revision_store.zig").RevisionStore.init(
        allocator,
        tmp.dir,
    ).openVerified("recovery", refreshed.revision);
    defer refreshed_view.deinit();
    try testing.expectEqualStrings(refreshed_source, refreshed_view.sourceBytes());

    try testing.expectError(
        error.InvalidConfig,
        commands.publishDownloaded(.{
            .key = "recovery",
            .source_bytes = source ++ "\nmode: unsupported\n",
            .mode = .update,
            .expected_revision = refreshed.revision,
        }),
    );
    var unchanged = try commands.list();
    defer unchanged.deinit();
    try testing.expect(unchanged.entries[0].revision.eql(refreshed.revision));
    _ = try commands.delete("recovery");
}

test "CatalogCommands rejects malformed active updates before revision publication" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try bootstrapEmpty(allocator, tmp.dir);
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    const created = try commands.publishDownloaded(.{
        .key = "home",
        .source_bytes = "mixed-port: 7890\n",
        .mode = .create,
    });
    const malformed_bodies = [_][]const u8{
        \\mixed-port: 7890
        \\proxies:
        \\  - name: recoverable
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: first-secret
        \\    plugin: obfs
        \\    plugin-opts: "obfs=http"
        \\rules:
        \\  - MATCH,recoverable
        ,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: recoverable
        \\    type: ss
        \\    server: other.example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: second-secret
        \\    plugin: obfs
        \\    plugin-opts: "obfs=http"
        \\rules:
        \\  - MATCH,recoverable
        ,
    };
    const state_before = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_before);
    var tree_before = try snapshotTree(allocator, tmp.dir, "profiles");
    defer tree_before.deinit();

    for (malformed_bodies) |malformed| {
        try testing.expectError(
            error.ProfileNotRuntimeReady,
            commands.publishDownloaded(.{
                .key = "home",
                .source_bytes = malformed,
                .mode = .update,
                .expected_revision = created.revision,
            }),
        );
        const state_after = try tmp.dir.readFileAlloc(
            compat.io(),
            "state-v2.json",
            allocator,
            .limited(1024 * 1024),
        );
        defer allocator.free(state_after);
        try testing.expectEqualStrings(state_before, state_after);
        var tree_after = try snapshotTree(allocator, tmp.dir, "profiles");
        defer tree_after.deinit();
        try expectTreeEqual(tree_before, tree_after);
    }

    var listing = try commands.list();
    defer listing.deinit();
    try testing.expectEqualStrings("home", listing.active.?);
    try testing.expect(listing.entries[0].revision.eql(created.revision));
}

test "CatalogCommands rejects malformed-plugin captures with unrelated invalid semantics" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try bootstrapEmpty(allocator, tmp.dir);
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    const cases = [_]struct {
        key: []const u8,
        source: []const u8,
    }{
        .{
            .key = "reserved-proxy",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: DIRECT
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts: "obfs=http"
            \\rules:
            \\  - MATCH,DIRECT
            ,
        },
        .{
            .key = "reserved-group",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: recoverable
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts: "obfs=http"
            \\proxy-groups:
            \\  - name: REJECT
            \\    type: select
            \\    proxies: [recoverable]
            \\rules:
            \\  - MATCH,REJECT
            ,
        },
        .{
            .key = "unsupported-proxy",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: recoverable
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts: "obfs=http"
            \\  - name: disabled
            \\    type: http
            \\    server: example.com
            \\    port: 8080
            \\rules:
            \\  - MATCH,recoverable
            ,
        },
        .{
            .key = "unsupported-group",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: recoverable
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts: "obfs=http"
            \\proxy-groups:
            \\  - name: automatic
            \\    type: url-test
            \\    proxies: [recoverable]
            \\    url: https://example.com/ping
            \\rules:
            \\  - MATCH,automatic
            ,
        },
        .{
            .key = "invalid-reference",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: recoverable
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts: "obfs=http"
            \\rules:
            \\  - MATCH,undefined-target
            ,
        },
    };

    for (cases) |case| {
        try testing.expectError(
            error.InvalidConfig,
            commands.publishDownloaded(.{
                .key = case.key,
                .source_bytes = case.source,
                .mode = .create,
            }),
        );
    }
    var listing = try commands.list();
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 0), listing.entries.len);
}

test "CatalogCommands rejects non-Shadowsocks plugin metadata from raw capture" {
    const allocator = testing.allocator;
    const cases = [_]struct {
        key: []const u8,
        source: []const u8,
    }{
        .{
            .key = "direct-plugin",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: direct-node
            \\    type: direct
            \\    plugin: obfs
            \\rules:
            \\  - MATCH,direct-node
            ,
        },
        .{
            .key = "reject-derived",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: reject-node
            \\    type: reject
            \\    plugin-opts: { mode: http, host: example.com }
            \\rules:
            \\  - MATCH,reject-node
            ,
        },
        .{
            .key = "trojan-underscore",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: trojan-node
            \\    type: trojan
            \\    server: example.com
            \\    port: 443
            \\    password: secret
            \\    plugin: obfs
            \\    plugin_opts: { mode: http, host: example.com }
            \\rules:
            \\  - MATCH,trojan-node
            ,
        },
        .{
            .key = "trojan-malformed",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: malformed-node
            \\    type: trojan
            \\    server: example.com
            \\    port: 443
            \\    password: secret
            \\    plugin-opts: "obfs=http"
            \\rules:
            \\  - MATCH,malformed-node
            ,
        },
    };

    for (cases) |case| {
        var bundle = try config_bundle.ConfigBundle.captureCatalogMemory(
            allocator,
            case.source,
            null,
            .{},
        );
        defer bundle.deinit();
        try testing.expectEqual(
            config_bundle.SemanticState.malformed,
            bundle.semanticState(),
        );

        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try bootstrapEmpty(allocator, tmp.dir);
        const commands = catalog_commands.Commands.init(allocator, tmp.dir);
        try testing.expectError(
            error.InvalidConfig,
            commands.publishDownloaded(.{
                .key = case.key,
                .source_bytes = case.source,
                .mode = .create,
            }),
        );
        var listing = try commands.list();
        defer listing.deinit();
        try testing.expectEqual(@as(usize, 0), listing.entries.len);
    }
}

test "CatalogCommands downloaded writer rejects invalid and ambient local configs" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try bootstrapEmpty(allocator, tmp.dir);
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    try testing.expectError(error.InvalidConfigKey, commands.publishDownloaded(.{
        .key = "a" ** (@import("config_catalog.zig").max_portable_key_bytes + 1),
        .source_bytes = "mixed-port: 7890\n",
        .mode = .create,
    }));
    try testing.expectError(error.AssetNotDeclared, commands.publishDownloaded(.{
        .key = "local",
        .source_bytes = "rule-providers:\n  local:\n    type: file\n    behavior: domain\n    path: ambient.yaml\n",
        .mode = .create,
    }));
    try testing.expectError(error.InvalidProxyPort, commands.publishDownloaded(.{
        .key = "bad",
        .source_bytes = "proxies:\n  - name: broken\n    type: ss\n    server: ''\n    port: 0\n",
        .mode = .create,
    }));
}

test "CatalogCommands activates and deletes through bounded exact CAS" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    const token = try bootstrapEmpty(allocator, tmp.dir);
    _ = try publish(allocator, tmp.dir, token, "home", null);
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
    const activated = try commands.activate("home");
    try testing.expect(activated.mirror_error == null);
    var listing = try commands.list();
    try testing.expectEqualStrings("home", listing.active.?);
    try testing.expect(listing.entries[0].active);
    listing.deinit();

    const deleted = try commands.delete("home");
    try testing.expect(deleted.was_active);
    try testing.expect(deleted.receipt.mirror_error == null);
    var empty = try commands.list();
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.entries.len);
    try testing.expect(empty.active == null);
    try testing.expectError(error.ManagedProfileNotFound, commands.activate("home"));
}
