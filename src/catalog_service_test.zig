const std = @import("std");
const testing = std.testing;
const compat = @import("compat.zig");
const catalog_service = @import("catalog_service.zig");
const config_bundle = @import("config_bundle.zig");
const config_catalog = @import("config_catalog.zig");
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

fn capture(allocator: std.mem.Allocator, root: std.Io.Dir, name: []const u8) !config_bundle.ConfigBundle {
    const path = try root.realPathFileAlloc(compat.io(), name, allocator);
    defer allocator.free(path);
    return config_bundle.ConfigBundle.capture(allocator, path, .{});
}

test "CatalogService publishes one revision and refreshes the derived legacy mirror" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var bundle = try capture(allocator, tmp.dir, "source.yaml");
    defer bundle.deinit();
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const outcome = try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &bundle,
        .metadata = .{ .url = "https://example.invalid/sub", .filename = "Home" },
        .desired = .clear,
        .activate = true,
    });
    const applied = switch (outcome) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    try testing.expect(applied.receipt.state_sync_error == null);
    try testing.expect(applied.receipt.mirror_error == null);
    try testing.expectEqual(applied.receipt.token.sequence, applied.receipt.mirror_sequence.?);

    const yaml = try tmp.dir.readFileAlloc(compat.io(), "configs/home.yaml", allocator, .limited(1024));
    defer allocator.free(yaml);
    try testing.expectEqualStrings("mixed-port: 7890\n", yaml);
    const meta = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(meta);
    try testing.expect(std.mem.indexOf(u8, meta, "\"active\":\"home\"") != null);
    try testing.expect(std.mem.indexOf(u8, meta, "https://example.invalid/sub") != null);
}

test "CatalogService desired and delete mutations refresh mirror from authoritative state" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var bundle = try capture(allocator, tmp.dir, "source.yaml");
    defer bundle.deinit();
    var token = try bootstrapEmpty(allocator, tmp.dir);
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const published = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &bundle,
        .desired = .clear,
        .activate = true,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    token = published.receipt.token;
    const selections = [_]config_catalog.Selection{.{ .group = "Proxy", .proxy = "A" }};
    const desired = switch (try service.mutate(token, .{ .set_desired = .{
        .identity = .{ .key = "home", .revision = published.revision },
        .expected_generation = 0,
        .selections = &selections,
    } })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    token = desired.token;
    const meta = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(meta);
    try testing.expect(std.mem.indexOf(u8, meta, "\"Proxy\":\"A\"") != null);

    const deleted = switch (try service.mutate(token, .{ .delete_profile = .{
        .key = "home",
        .expected = published.revision,
    } })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    try testing.expect(deleted.mirror_error == null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "configs/home.yaml", .{}));
    const after = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "\"active\":null") != null);
}

test "CatalogService reports mirror failure after authoritative state is already committed" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "rule-providers:\n  local:\n    type: file\n    behavior: domain\n    path: home.yaml\nrules:\n  - RULE-SET,local,DIRECT\n");
    try writeFile(tmp.dir, "home.yaml", "payload:\n  - example.com\n");
    var bundle = try capture(allocator, tmp.dir, "source.yaml");
    defer bundle.deinit();
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const applied = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &bundle,
        .desired = .clear,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    try testing.expectEqual(error.LegacyMirrorCollision, applied.receipt.mirror_error.?);
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var observed = try authority.inspect();
    defer observed.deinit();
    switch (observed) {
        .catalog_v2 => |*catalog| {
            try testing.expectEqual(@as(usize, 1), catalog.catalog.state.profiles.len);
            try testing.expect(catalog.catalog.state.profiles[0].head.eql(applied.revision));
        },
        else => return error.TestExpectedEqual,
    }
}

test "CatalogService reports token conflict without refreshing mirror" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const first = switch (try service.mutate(token, .{ .set_active = .{ .key = null } })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    const before = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(before);
    const stale = try service.mutate(token, .{ .set_active = .{ .key = null } });
    switch (stale) {
        .conflict => |actual| try testing.expect(actual.eql(first.token)),
        else => return error.TestExpectedEqual,
    }
    const after = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(after);
    try testing.expectEqualStrings(before, after);
}
