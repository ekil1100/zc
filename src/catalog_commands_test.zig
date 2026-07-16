const std = @import("std");
const testing = std.testing;
const compat = @import("compat.zig");
const catalog_commands = @import("catalog_commands.zig");
const catalog_service = @import("catalog_service.zig");
const config_bundle = @import("config_bundle.zig");
const state_authority = @import("state_authority.zig");

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(compat.io(), bytes);
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
    });
    try testing.expect(!updated.revision.eql(created.revision));
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
    var view = try @import("revision_store.zig").RevisionStore.init(allocator, tmp.dir).openVerified(
        "home",
        overridden.revision,
    );
    try testing.expect(view.override != null);
    try testing.expect(std.mem.indexOf(u8, view.effectiveSourceBytes(), "mixed-port: 9000") != null);
    view.deinit();

    const cleared = (try commands.clearOverride("home")) orelse return error.TestExpectedEqual;
    try testing.expect(!cleared.revision.eql(overridden.revision));
    var clear_view = try @import("revision_store.zig").RevisionStore.init(allocator, tmp.dir).openVerified(
        "home",
        cleared.revision,
    );
    defer clear_view.deinit();
    try testing.expect(clear_view.override == null);
    try testing.expectEqualStrings("mixed-port: 7890\n", clear_view.effectiveSourceBytes());
    try testing.expect(try commands.clearOverride("home") == null);
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

test "CatalogCommands downloaded writer rejects invalid and ambient local configs" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try bootstrapEmpty(allocator, tmp.dir);
    const commands = catalog_commands.Commands.init(allocator, tmp.dir);
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
