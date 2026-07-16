const std = @import("std");
const testing = std.testing;
const compat = @import("compat.zig");
const config_bundle = @import("config_bundle.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");
const revision_store = @import("revision_store.zig");
const state_authority = @import("state_authority.zig");

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(compat.io(), bytes);
}

fn publish(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    key: []const u8,
    path: []const u8,
    materialized: ?[]const u8,
) !revision_store.PublishedRevision {
    var bundle = if (materialized) |effective|
        try config_bundle.ConfigBundle.captureMaterialized(allocator, path, effective, .{})
    else
        try config_bundle.ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    return revision_store.RevisionStore.init(allocator, root).publishMigration(key, &bundle, .{});
}

fn bootstrapEmpty(authority: state_authority.Authority) !state_authority.StateToken {
    var missing = try authority.inspect();
    defer missing.deinit();
    const outcome = try authority.bootstrapCatalog(missing.token(), .{});
    return switch (outcome) {
        .committed => |receipt| receipt.token,
        else => error.TestExpectedEqual,
    };
}

fn committedToken(outcome: state_authority.CatalogMutationOutcome) !state_authority.StateToken {
    return switch (outcome) {
        .committed => |receipt| receipt.token,
        else => error.TestExpectedEqual,
    };
}

test "StateAuthority typed catalog mutations preserve exact identity invariants" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    const source_path = try tmp.dir.realPathFileAlloc(compat.io(), "source.yaml", allocator);
    defer allocator.free(source_path);
    const first = try publish(allocator, tmp.dir, "home", source_path, null);
    const second = try publish(allocator, tmp.dir, "home", source_path, "mixed-port: 9000\n");
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var token = try bootstrapEmpty(authority);

    token = try committedToken(try authority.mutateCatalog(token, .{ .put_profile = .{
        .key = "home",
        .expected = .missing,
        .head = first.revision,
        .desired = .clear,
        .activate = true,
    } }));
    const selections = [_]config_catalog.Selection{.{ .group = "Proxy", .proxy = "A" }};
    token = try committedToken(try authority.mutateCatalog(token, .{ .set_desired = .{
        .identity = .{ .key = "home", .revision = first.revision },
        .expected_generation = 0,
        .selections = &selections,
    } }));
    token = try committedToken(try authority.mutateCatalog(token, .{ .put_profile = .{
        .key = "home",
        .expected = .{ .revision = first.revision },
        .head = second.revision,
        .desired = .{ .replace = &selections },
    } }));

    var observed = try authority.inspect();
    defer observed.deinit();
    try testing.expect(observed.token().eql(token));
    switch (observed) {
        .catalog_v2 => |*catalog| {
            try testing.expectEqual(@as(usize, 1), catalog.catalog.state.profiles.len);
            const profile = catalog.catalog.state.profiles[0];
            try testing.expect(profile.head.eql(second.revision));
            try testing.expectEqual(@as(u64, 1), profile.desired.generation);
            try testing.expectEqualStrings("A", profile.desired.selections[0].proxy);
            try testing.expect(catalog.catalog.state.active.?.revision.eql(second.revision));
        },
        else => return error.TestExpectedEqual,
    }

    token = try committedToken(try authority.mutateCatalog(token, .{ .put_profile = .{
        .key = "home",
        .expected = .{ .revision = second.revision },
        .head = second.revision,
        .desired = .clear,
    } }));
    var cleared = try authority.inspect();
    defer cleared.deinit();
    switch (cleared) {
        .catalog_v2 => |*catalog| {
            try testing.expectEqual(@as(u64, 2), catalog.catalog.state.profiles[0].desired.generation);
            try testing.expectEqual(@as(usize, 0), catalog.catalog.state.profiles[0].desired.selections.len);
        },
        else => return error.TestExpectedEqual,
    }

    token = try committedToken(try authority.mutateCatalog(token, .{ .delete_profile = .{
        .key = "home",
        .expected = second.revision,
    } }));
    var deleted = try authority.inspect();
    defer deleted.deinit();
    switch (deleted) {
        .catalog_v2 => |*catalog| {
            try testing.expectEqual(@as(usize, 0), catalog.catalog.state.profiles.len);
            try testing.expect(catalog.catalog.state.active == null);
            try testing.expect(catalog.token.eql(token));
        },
        else => return error.TestExpectedEqual,
    }
}

test "StateAuthority typed catalog mutation rejects stale token and unverified head" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    const token = try bootstrapEmpty(authority);
    const missing_revision = try config_identity.Revision.parseHex("00112233445566778899aabbccddeeff");
    try testing.expectError(error.CorruptRevision, authority.mutateCatalog(token, .{ .put_profile = .{
        .key = "home",
        .expected = .missing,
        .head = missing_revision,
        .desired = .clear,
    } }));

    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    const source_path = try tmp.dir.realPathFileAlloc(compat.io(), "source.yaml", allocator);
    defer allocator.free(source_path);
    const published = try publish(allocator, tmp.dir, "home", source_path, null);
    const committed = try authority.mutateCatalog(token, .{ .put_profile = .{
        .key = "home",
        .expected = .missing,
        .head = published.revision,
        .desired = .clear,
    } });
    _ = try committedToken(committed);
    const stale = try authority.mutateCatalog(token, .{ .set_active = .{ .key = "home" } });
    switch (stale) {
        .conflict => |conflict| try testing.expect(!conflict.actual.eql(token)),
        else => return error.TestExpectedEqual,
    }
}

fn catalogMutationAllocationFixture(allocator: std.mem.Allocator, root: std.Io.Dir) !void {
    const authority = state_authority.Authority.init(allocator, root);
    var current = try authority.inspect();
    defer current.deinit();
    const outcome = try authority.mutateCatalog(current.token(), .{ .set_active = .{ .key = null } });
    switch (outcome) {
        .committed => {},
        else => return error.TestExpectedEqual,
    }
}

test "StateAuthority typed catalog mutation releases every allocation failure path" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    _ = try bootstrapEmpty(authority);
    try testing.checkAllAllocationFailures(
        testing.allocator,
        catalogMutationAllocationFixture,
        .{tmp.dir},
    );
}

test "StateAuthority desired mutation is exact revision and generation CAS" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    const source_path = try tmp.dir.realPathFileAlloc(compat.io(), "source.yaml", allocator);
    defer allocator.free(source_path);
    const published = try publish(allocator, tmp.dir, "home", source_path, null);
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var token = try bootstrapEmpty(authority);
    token = try committedToken(try authority.mutateCatalog(token, .{ .put_profile = .{
        .key = "home",
        .expected = .missing,
        .head = published.revision,
        .desired = .clear,
    } }));
    const wrong_revision = try config_identity.Revision.parseHex("ffeeddccbbaa99887766554433221100");
    try testing.expectError(error.ProfileIdentityConflict, authority.mutateCatalog(token, .{ .set_desired = .{
        .identity = .{ .key = "home", .revision = wrong_revision },
        .expected_generation = 0,
        .selections = &.{},
    } }));
    try testing.expectError(error.DesiredGenerationConflict, authority.mutateCatalog(token, .{ .set_desired = .{
        .identity = .{ .key = "home", .revision = published.revision },
        .expected_generation = 9,
        .selections = &.{},
    } }));
    const duplicates = [_]config_catalog.Selection{
        .{ .group = "Proxy", .proxy = "A" },
        .{ .group = "Proxy", .proxy = "B" },
    };
    try testing.expectError(error.InvalidCatalog, authority.mutateCatalog(token, .{ .set_desired = .{
        .identity = .{ .key = "home", .revision = published.revision },
        .expected_generation = 0,
        .selections = &duplicates,
    } }));
    var unchanged = try authority.inspect();
    defer unchanged.deinit();
    try testing.expect(unchanged.token().eql(token));
}
