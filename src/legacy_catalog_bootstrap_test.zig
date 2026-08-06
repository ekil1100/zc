const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const compat = @import("compat.zig");
const config_identity = @import("config_identity.zig");
const legacy_bootstrap = @import("legacy_catalog_bootstrap.zig");
const revision_store = @import("revision_store.zig");
const state_authority = @import("state_authority.zig");

const LegacyCatalogBootstrap = legacy_bootstrap.LegacyCatalogBootstrap;

extern "c" fn mkfifoat(c_int, [*:0]const u8, std.posix.mode_t) c_int;

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try compat.fileWriteAll(file, bytes);
}

fn sourceWithProvider() []const u8 {
    return
    \\mixed-port: 7890
    \\rule-providers:
    \\  local:
    \\    type: file
    \\    behavior: domain
    \\    path: assets/rules.yaml
    \\rules:
    \\  - RULE-SET,local,DIRECT
    ;
}

test "LegacyCatalogBootstrap migrates exact active metadata and desired selections once" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try tmp.dir.createDir(compat.io(), "configs/assets", .default_dir);
    try writeFile(tmp.dir, "configs/home.yaml", sourceWithProvider());
    try writeFile(tmp.dir, "configs/assets/rules.yaml", "payload:\n  - example.com\n");
    try writeFile(tmp.dir, "meta.json", "{\"active\":\"home\",\"configs\":{\"home\":{\"url\":\"https://example.test/sub\",\"filename\":\"Home\",\"params\":{\"target\":\"clash\"},\"selections\":{\"Proxy\":\"A\"}}}}\n");

    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    const outcome = try bootstrap.ensure();
    switch (outcome) {
        .migrated => |receipt| {
            try testing.expectEqual(@as(usize, 1), receipt.profile_count);
            try testing.expectEqual(@as(u64, 1), receipt.token.sequence);
        },
        else => return error.TestExpectedEqual,
    }

    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var inspection = try authority.inspect();
    defer inspection.deinit();
    const profile = switch (inspection) {
        .catalog_v2 => |*observed| blk: {
            try testing.expectEqualStrings("home", observed.catalog.state.active.?.key);
            break :blk observed.catalog.state.profiles[0];
        },
        else => return error.TestExpectedEqual,
    };
    try testing.expectEqual(@as(u64, 1), profile.desired.generation);
    try testing.expectEqualStrings("Proxy", profile.desired.selections[0].group);
    try testing.expectEqualStrings("A", profile.desired.selections[0].proxy);

    const store = revision_store.RevisionStore.init(allocator, tmp.dir);
    var view = try store.openVerified("home", profile.head);
    defer view.deinit();
    try testing.expectEqualStrings("https://example.test/sub", view.metadata.url.?);
    try testing.expectEqualStrings("target", view.metadata.params[0].key);
    try testing.expectEqualStrings("clash", view.metadata.params[0].value);
    try testing.expectEqualStrings("payload:\n  - example.com\n", try view.resolveLocal("assets/rules.yaml"));

    try tmp.dir.deleteTree(compat.io(), "configs");
    try tmp.dir.deleteFile(compat.io(), "meta.json");
    const repeated = try bootstrap.ensure();
    switch (repeated) {
        .already_current => |receipt| {
            try testing.expectEqual(@as(u64, 1), receipt.token.sequence);
            try testing.expect(receipt.mirror_error != null);
        },
        else => return error.TestExpectedEqual,
    }
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "configs/home.yaml", .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "meta.json", .{}),
    );
}

test "LegacyCatalogBootstrap remains bound to its root descriptor after pathname rebinding" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "store", .default_dir);
    try tmp.dir.createDir(compat.io(), "store/configs", .default_dir);
    try tmp.dir.createDir(compat.io(), "store/configs/assets", .default_dir);
    try writeFile(tmp.dir, "store/configs/home.yaml", sourceWithProvider());
    try writeFile(tmp.dir, "store/configs/assets/rules.yaml", "payload:\n  - original.example\n");
    const store_dir = try tmp.dir.openDir(compat.io(), "store", .{ .follow_symlinks = false });
    defer store_dir.close(compat.io());
    try tmp.dir.rename("store", tmp.dir, "moved", compat.io());
    try tmp.dir.createDir(compat.io(), "store", .default_dir);
    try tmp.dir.createDir(compat.io(), "store/configs", .default_dir);
    try tmp.dir.createDir(compat.io(), "store/configs/assets", .default_dir);
    try writeFile(tmp.dir, "store/configs/home.yaml", sourceWithProvider());
    try writeFile(tmp.dir, "store/configs/assets/rules.yaml", "payload:\n  - replacement.example\n");

    const bootstrap = LegacyCatalogBootstrap.init(allocator, store_dir);
    try testing.expect((try bootstrap.ensure()) == .migrated);
    const authority = state_authority.Authority.init(allocator, store_dir);
    var inspection = try authority.inspect();
    defer inspection.deinit();
    const head = switch (inspection) {
        .catalog_v2 => |*observed| observed.catalog.state.profiles[0].head,
        else => return error.TestExpectedEqual,
    };
    const store = revision_store.RevisionStore.init(allocator, store_dir);
    var view = try store.openVerified("home", head);
    defer view.deinit();
    try testing.expectEqualStrings(sourceWithProvider(), view.sourceBytes());
    try testing.expectEqualStrings(
        "payload:\n  - original.example\n",
        try view.resolveLocal("assets/rules.yaml"),
    );
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "store/state-v2.json", .{}));
}

test "LegacyCatalogBootstrap includes disk-only yaml with an empty desired baseline" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/local.yaml", "mixed-port: 7890\n");
    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    try testing.expect((try bootstrap.ensure()) == .migrated);

    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var inspection = try authority.inspect();
    defer inspection.deinit();
    switch (inspection) {
        .catalog_v2 => |*observed| {
            try testing.expect(observed.catalog.state.active == null);
            try testing.expectEqual(@as(usize, 1), observed.catalog.state.profiles.len);
            try testing.expectEqualStrings("local", observed.catalog.state.profiles[0].key);
            try testing.expectEqual(@as(u64, 0), observed.catalog.state.profiles[0].desired.generation);
        },
        else => return error.TestExpectedEqual,
    }
}

test "LegacyCatalogBootstrap preserves an explicit empty selection baseline" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/home.yaml", "mixed-port: 7890\n");
    try writeFile(tmp.dir, "meta.json", "{\"active\":null,\"configs\":{\"home\":{\"selections\":{}}}}\n");
    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    try testing.expect((try bootstrap.ensure()) == .migrated);

    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var inspection = try authority.inspect();
    defer inspection.deinit();
    switch (inspection) {
        .catalog_v2 => |*observed| {
            const desired = observed.catalog.state.profiles[0].desired;
            try testing.expectEqual(@as(u64, 1), desired.generation);
            try testing.expectEqual(@as(usize, 0), desired.selections.len);
        },
        else => return error.TestExpectedEqual,
    }
}

test "LegacyCatalogBootstrap materializes persisted override exactly once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/home.yaml", "mixed-port: 7890\n");
    try writeFile(tmp.dir, "counter", "0\n");
    const counter_path = try tmp.dir.realPathFileAlloc(compat.io(), "counter", allocator);
    defer allocator.free(counter_path);
    const script_text = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\ncount=$(cat '{s}')\ncount=$((count + 1))\nprintf '%s\\n' \"$count\" > '{s}'\nprintf 'mixed-port: %s\\n' \"${{ZC_OVERRIDE_ARG_PORT:-9000}}\"\n",
        .{ counter_path, counter_path },
    );
    defer allocator.free(script_text);
    try writeFile(tmp.dir, "override.sh", script_text);
    const script_file = try tmp.dir.openFile(compat.io(), "override.sh", .{ .mode = .read_write });
    try script_file.setPermissions(compat.io(), std.Io.File.Permissions.fromMode(0o700));
    script_file.close(compat.io());
    const script_path = try tmp.dir.realPathFileAlloc(compat.io(), "override.sh", allocator);
    defer allocator.free(script_path);
    const meta_json = try std.fmt.allocPrint(
        allocator,
        "{{\"active\":null,\"configs\":{{\"home\":{{\"override_script\":\"{s}\",\"params\":{{\"port\":\"9999\"}}}}}}}}\n",
        .{script_path},
    );
    defer allocator.free(meta_json);
    try writeFile(tmp.dir, "meta.json", meta_json);

    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    try testing.expect((try bootstrap.ensure()) == .migrated);
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var inspection = try authority.inspect();
    defer inspection.deinit();
    const head = switch (inspection) {
        .catalog_v2 => |*observed| observed.catalog.state.profiles[0].head,
        else => return error.TestExpectedEqual,
    };
    const store = revision_store.RevisionStore.init(allocator, tmp.dir);
    var view = try store.openVerified("home", head);
    defer view.deinit();
    const frozen = view.override orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 0), frozen.args.len);
    try testing.expectEqualStrings("port", view.metadata.params[0].key);
    const config = @import("config.zig");
    var effective = try config.parseDocument(allocator, view.effectiveSourceBytes());
    defer effective.deinit();
    try testing.expectEqual(@as(u16, 9000), effective.mixed_port);

    const counter = try tmp.dir.readFileAlloc(compat.io(), "counter", allocator, .limited(16));
    defer allocator.free(counter);
    try testing.expectEqualStrings("1\n", counter);
    try tmp.dir.deleteTree(compat.io(), "configs");
    try tmp.dir.deleteFile(compat.io(), "meta.json");
    try tmp.dir.deleteFile(compat.io(), "override.sh");
    const repeated = try bootstrap.ensure();
    switch (repeated) {
        .already_current => |receipt| try testing.expect(receipt.mirror_error != null),
        else => return error.TestExpectedEqual,
    }
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "configs/home.yaml", .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "meta.json", .{}),
    );
    const counter_after = try tmp.dir.readFileAlloc(compat.io(), "counter", allocator, .limited(16));
    defer allocator.free(counter_after);
    try testing.expectEqualStrings("1\n", counter_after);
}

test "LegacyCatalogBootstrap materializes before resolving replaced local dependencies" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/home.yaml", "rule-providers:\n  missing:\n    type: file\n    behavior: domain\n    path: absent.yaml\nrules:\n  - RULE-SET,missing,DIRECT\n");
    try writeFile(tmp.dir, "override.sh", "#!/bin/sh\nprintf 'rule-providers: {}\\nrules: []\\nmixed-port: 9000\\n'\n");
    const script = try tmp.dir.openFile(compat.io(), "override.sh", .{ .mode = .read_write });
    try script.setPermissions(compat.io(), std.Io.File.Permissions.fromMode(0o700));
    script.close(compat.io());
    const script_path = try tmp.dir.realPathFileAlloc(compat.io(), "override.sh", allocator);
    defer allocator.free(script_path);
    const meta_json = try std.fmt.allocPrint(
        allocator,
        "{{\"active\":null,\"configs\":{{\"home\":{{\"override_script\":\"{s}\"}}}}}}\n",
        .{script_path},
    );
    defer allocator.free(meta_json);
    try writeFile(tmp.dir, "meta.json", meta_json);
    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    try testing.expect((try bootstrap.ensure()) == .migrated);
}

test "LegacyCatalogBootstrap preserves semantic-invalid raw source for recovery" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    const source = "mixed-port: 0\nrules:\n  - MATCH,DIRECT\n";
    try writeFile(tmp.dir, "configs/legacy.yaml", source);
    try writeFile(
        tmp.dir,
        "meta.json",
        "{\"active\":null,\"configs\":{\"legacy\":{}}}\n",
    );

    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    try testing.expect((try bootstrap.ensure()) == .migrated);
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var inspection = try authority.inspect();
    defer inspection.deinit();
    const state = switch (inspection) {
        .catalog_v2 => |*observed| observed.catalog.state,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 1), state.profiles.len);
    var view = try revision_store.RevisionStore.init(
        allocator,
        tmp.dir,
    ).openVerified("legacy", state.profiles[0].head);
    defer view.deinit();
    try testing.expectEqualStrings(source, view.sourceBytes());
}

test "LegacyCatalogBootstrap rejects invalid persisted override before commit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/home.yaml", "mixed-port: 7890\n");
    try writeFile(tmp.dir, "override.sh", "#!/bin/sh\nprintf 'mixed-port: 0\\n'\n");
    const script = try tmp.dir.openFile(
        compat.io(),
        "override.sh",
        .{ .mode = .read_write },
    );
    try script.setPermissions(
        compat.io(),
        std.Io.File.Permissions.fromMode(0o700),
    );
    script.close(compat.io());
    const script_path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "override.sh",
        allocator,
    );
    defer allocator.free(script_path);
    const meta_json = try std.fmt.allocPrint(
        allocator,
        "{{\"active\":\"home\",\"configs\":{{\"home\":{{\"override_script\":\"{s}\"}}}}}}\n",
        .{script_path},
    );
    defer allocator.free(meta_json);
    try writeFile(tmp.dir, "meta.json", meta_json);

    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    try testing.expectError(error.InvalidLegacyConfig, bootstrap.ensure());
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "state-v2.json", .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "profiles", .{}),
    );
}

test "LegacyCatalogBootstrap override failure publishes no revision" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/a.yaml", "mixed-port: 7890\n");
    try writeFile(tmp.dir, "configs/z.yaml", "mixed-port: 7891\n");
    try writeFile(tmp.dir, "override.sh", "#!/bin/sh\nexit 7\n");
    const script = try tmp.dir.openFile(compat.io(), "override.sh", .{ .mode = .read_write });
    try script.setPermissions(compat.io(), std.Io.File.Permissions.fromMode(0o700));
    script.close(compat.io());
    const script_path = try tmp.dir.realPathFileAlloc(compat.io(), "override.sh", allocator);
    defer allocator.free(script_path);
    const meta_json = try std.fmt.allocPrint(
        allocator,
        "{{\"active\":null,\"configs\":{{\"a\":{{}},\"z\":{{\"override_script\":\"{s}\"}}}}}}\n",
        .{script_path},
    );
    defer allocator.free(meta_json);
    try writeFile(tmp.dir, "meta.json", meta_json);
    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    if (bootstrap.ensure()) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == error.OverrideScriptExecFailed or err == error.OverrideScriptTimeout);
    }
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "profiles", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "state-v2.json", .{}));
}

test "LegacyCatalogBootstrap validates desired state before publishing revisions" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/home.yaml", "mixed-port: 7890\n");
    try writeFile(tmp.dir, "meta.json", "{\"active\":null,\"configs\":{\"home\":{\"selections\":{\"\":\"A\"}}}}\n");
    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    try testing.expectError(error.InvalidLegacyMetadata, bootstrap.ensure());
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "profiles", .{}));
}

test "LegacyCatalogBootstrap preflights every bundle before publishing any revision" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/a.yaml", "mixed-port: 7890\n");
    try writeFile(tmp.dir, "configs/b.yaml", "rule-providers:\n  missing:\n    type: file\n    behavior: domain\n    path: absent.yaml\nrules:\n  - RULE-SET,missing,DIRECT\n");
    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    if (bootstrap.ensure()) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "state-v2.json", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "profiles", .{}));
}

test "LegacyCatalogBootstrap rejects symlinked metadata and special legacy paths" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "target.json", "{\"active\":null,\"configs\":{}}\n");
        tmp.dir.symLink(compat.io(), "target.json", "meta.json", .{}) catch return error.SkipZigTest;
        const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
        try testing.expectError(error.InvalidLegacyMetadata, bootstrap.ensure());
    }
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        if (mkfifoat(tmp.dir.handle, "meta.json", 0o600) != 0) return error.SkipZigTest;
        const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
        try testing.expectError(error.InvalidLegacyMetadata, bootstrap.ensure());
    }
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(compat.io(), "actual", .default_dir);
        tmp.dir.symLink(compat.io(), "actual", "configs", .{ .is_directory = true }) catch
            return error.SkipZigTest;
        const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
        try testing.expectError(error.InvalidLegacyLayout, bootstrap.ensure());
    }
}

test "LegacyCatalogBootstrap fails closed for missing config and dangling active" {
    const allocator = testing.allocator;
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(compat.io(), "configs", .default_dir);
        try writeFile(tmp.dir, "meta.json", "{\"active\":null,\"configs\":{\"missing\":{}}}\n");
        const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
        try testing.expectError(error.LegacyConfigMissing, bootstrap.ensure());
        try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "state-v2.json", .{}));
    }
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(compat.io(), "configs", .default_dir);
        try writeFile(tmp.dir, "configs/home.yaml", "mixed-port: 7890\n");
        try writeFile(tmp.dir, "meta.json", "{\"active\":\"missing\",\"configs\":{\"home\":{}}}\n");
        const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
        try testing.expectError(error.LegacyActiveMissing, bootstrap.ensure());
        try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "state-v2.json", .{}));
    }
}

fn bootstrapAllocationFixture(allocator: std.mem.Allocator) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/home.yaml", "mixed-port: 7890\n");
    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    const outcome = try bootstrap.ensure();
    switch (outcome) {
        .migrated => |receipt| if (receipt.mirror_error) |err| return err,
        .durability_uncertain => |uncertain| if (uncertain.receipt.mirror_error) |err| return err,
        else => return error.TestUnexpectedResult,
    }
}

test "LegacyCatalogBootstrap releases every allocation failure path" {
    try testing.checkAllAllocationFailures(testing.allocator, bootstrapAllocationFixture, .{});
}

test "LegacyCatalogBootstrap never revives yaml excluded by an explicit empty schema one" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/home.yaml", "mixed-port: 7890\n");
    const legacy_state = "{\"schema_version\":1,\"sequence\":7,\"profiles\":[]}\n";
    try writeFile(tmp.dir, "state-v2.json", legacy_state);

    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    const outcome = try bootstrap.ensure();
    switch (outcome) {
        .blocked => |reason| try testing.expectEqual(legacy_bootstrap.BlockedReason.unproven_schema1, reason),
        else => return error.TestExpectedEqual,
    }
    const after = try tmp.dir.readFileAlloc(compat.io(), "state-v2.json", allocator, .limited(1024));
    defer allocator.free(after);
    try testing.expectEqualStrings(legacy_state, after);
}

test "LegacyCatalogBootstrap never overwrites an unproven nonempty schema one" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "configs", .default_dir);
    try writeFile(tmp.dir, "configs/home.yaml", "mixed-port: 7890\n");
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    const unrelated = config_identity.Revision{ .bytes = [_]u8{0xaa} ** 16 };
    _ = try authority.commit(.{ .compare_exchange_head = .{
        .key = "home",
        .expected = .missing,
        .next = unrelated,
    } });
    const bootstrap = LegacyCatalogBootstrap.init(allocator, tmp.dir);
    const outcome = try bootstrap.ensure();
    switch (outcome) {
        .blocked => |reason| try testing.expectEqual(legacy_bootstrap.BlockedReason.unproven_schema1, reason),
        else => return error.TestExpectedEqual,
    }
    var snapshot = try authority.observe();
    defer snapshot.deinit();
    try testing.expect(snapshot.head("home").?.eql(unrelated));
}
