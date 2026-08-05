const std = @import("std");
const testing = std.testing;
const catalog = @import("config_catalog.zig");
const identity = @import("config_identity.zig");

const revision_a = identity.Revision{ .bytes = [_]u8{0x11} ** 16 };
const revision_b = identity.Revision{ .bytes = [_]u8{0x22} ** 16 };

fn canonicalFixture() []const u8 {
    return "{\"schema_version\":2,\"sequence\":7,\"active\":{\"key\":\"home\",\"revision\":\"11111111111111111111111111111111\"},\"profiles\":[" ++
        "{\"key\":\"home\",\"storage_id\":\"dc3fb855b586386498f9ec0db774a3d31da4003977fcbcd9a697fb7455a6645b\",\"head\":\"11111111111111111111111111111111\",\"desired\":{\"generation\":1,\"selections\":[{\"group\":\"Proxy\",\"proxy\":\"A\"}]}}]}\n";
}

test "ConfigCatalog decodes and re-encodes canonical exact identities" {
    var decoded = try catalog.decodeCanonical(testing.allocator, canonicalFixture());
    defer decoded.deinit();

    try testing.expectEqual(@as(u64, 7), decoded.state.sequence);
    try testing.expectEqual(@as(usize, 1), decoded.state.profiles.len);
    try testing.expectEqualStrings("home", decoded.state.profiles[0].key);
    try testing.expect(decoded.state.profiles[0].storage_id.eql(identity.StorageId.derive("home")));
    try testing.expect(decoded.state.profiles[0].head.eql(revision_a));
    try testing.expectEqualStrings("Proxy", decoded.state.profiles[0].desired.selections[0].group);

    const encoded = try catalog.encodeCanonical(testing.allocator, decoded.state);
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings(canonicalFixture(), encoded);
}

test "ConfigCatalog encoder sorts profiles and desired selections deterministically" {
    const profiles = [_]catalog.Profile{
        .{
            .key = "zeta",
            .storage_id = identity.StorageId.derive("zeta"),
            .head = revision_b,
            .desired = .{ .generation = 2, .selections = &.{
                .{ .group = "z", .proxy = "last" },
                .{ .group = "a", .proxy = "first" },
            } },
        },
        .{
            .key = "home",
            .storage_id = identity.StorageId.derive("home"),
            .head = revision_a,
            .desired = .{},
        },
    };
    const bytes = try catalog.encodeCanonical(testing.allocator, .{
        .sequence = 9,
        .active = .{ .key = "zeta", .revision = revision_b },
        .profiles = &profiles,
    });
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "\"profiles\":[{\"key\":\"home\"").? <
        std.mem.lastIndexOf(u8, bytes, "\"key\":\"zeta\"").?);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"group\":\"a\"").? <
        std.mem.indexOf(u8, bytes, "\"group\":\"z\"").?);
    var decoded = try catalog.decodeCanonical(testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqualStrings("home", decoded.state.profiles[0].key);
    try testing.expectEqualStrings("zeta", decoded.state.profiles[1].key);
}

test "ConfigCatalog fails closed for noncanonical and inconsistent catalogs" {
    const noncanonical =
        "{ \"schema_version\":2,\"sequence\":0,\"active\":null,\"profiles\":[] }\n";
    try testing.expectError(error.CorruptCatalog, catalog.decodeCanonical(testing.allocator, noncanonical));

    const uppercase_revision =
        "{\"schema_version\":2,\"sequence\":0,\"active\":null,\"profiles\":[{\"key\":\"home\",\"storage_id\":\"dc3fb855b586386498f9ec0db774a3d31da4003977fcbcd9a697fb7455a6645b\",\"head\":\"1111111111111111111111111111111A\",\"desired\":{\"generation\":0,\"selections\":[]}}]}\n";
    try testing.expectError(error.CorruptCatalog, catalog.decodeCanonical(testing.allocator, uppercase_revision));

    const dangling_active =
        "{\"schema_version\":2,\"sequence\":0,\"active\":{\"key\":\"missing\",\"revision\":\"11111111111111111111111111111111\"},\"profiles\":[]}\n";
    try testing.expectError(error.CorruptCatalog, catalog.decodeCanonical(testing.allocator, dangling_active));

    const duplicate_field =
        "{\"schema_version\":2,\"schema_version\":2,\"sequence\":0,\"active\":null,\"profiles\":[]}\n";
    try testing.expectError(error.CorruptCatalog, catalog.decodeCanonical(testing.allocator, duplicate_field));
}

test "ConfigCatalog rejects invalid managed keys and duplicate desired groups" {
    const invalid_key = [_]catalog.Profile{.{
        .key = "../home",
        .storage_id = identity.StorageId.derive("../home"),
        .head = revision_a,
        .desired = .{},
    }};
    try testing.expectError(error.InvalidCatalog, catalog.encodeCanonical(testing.allocator, .{
        .profiles = &invalid_key,
    }));

    const duplicate_groups = [_]catalog.Profile{.{
        .key = "home",
        .storage_id = identity.StorageId.derive("home"),
        .head = revision_a,
        .desired = .{ .generation = 1, .selections = &.{
            .{ .group = "Proxy", .proxy = "A" },
            .{ .group = "Proxy", .proxy = "B" },
        } },
    }};
    try testing.expectError(error.InvalidCatalog, catalog.encodeCanonical(testing.allocator, .{
        .profiles = &duplicate_groups,
    }));
}

test "ConfigCatalog grandfathers persisted keys but reserves new filename space" {
    const portable_key = "a" ** catalog.max_portable_key_bytes;
    const grandfathered_key = "a" ** catalog.max_key_bytes;
    const oversized_key = "a" ** (catalog.max_key_bytes + 1);
    try testing.expect(catalog.isPortableManagedKey(portable_key));
    try testing.expect(!catalog.isPortableManagedKey(grandfathered_key));
    try testing.expect(catalog.isManagedKey(grandfathered_key));
    try testing.expect(!catalog.isManagedKey(oversized_key));
    const profiles = [_]catalog.Profile{.{
        .key = grandfathered_key,
        .storage_id = identity.StorageId.derive(grandfathered_key),
        .head = revision_a,
    }};
    const encoded = try catalog.encodeCanonical(testing.allocator, .{
        .profiles = &profiles,
    });
    defer testing.allocator.free(encoded);
    var decoded = try catalog.decodeCanonical(testing.allocator, encoded);
    defer decoded.deinit();
    try testing.expectEqualStrings(grandfathered_key, decoded.state.profiles[0].key);
}

test "ConfigCatalog enforces its persisted byte limit" {
    const bytes = try testing.allocator.alloc(u8, catalog.max_catalog_bytes + 1);
    defer testing.allocator.free(bytes);
    @memset(bytes, ' ');
    try testing.expectError(error.CatalogTooLarge, catalog.decodeCanonical(testing.allocator, bytes));
}

fn encodeAllocationFixture(allocator: std.mem.Allocator) !void {
    const profiles = [_]catalog.Profile{.{
        .key = "home",
        .storage_id = identity.StorageId.derive("home"),
        .head = revision_a,
        .desired = .{ .generation = 1, .selections = &.{.{ .group = "Proxy", .proxy = "A" }} },
    }};
    const bytes = try catalog.encodeCanonical(allocator, .{
        .sequence = 7,
        .active = .{ .key = "home", .revision = revision_a },
        .profiles = &profiles,
    });
    allocator.free(bytes);
}

fn decodeAllocationFixture(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var decoded = try catalog.decodeCanonical(allocator, bytes);
    decoded.deinit();
}

test "ConfigCatalog releases every encode and decode allocation failure path" {
    try testing.checkAllAllocationFailures(testing.allocator, encodeAllocationFixture, .{});
    try testing.checkAllAllocationFailures(
        testing.allocator,
        decodeAllocationFixture,
        .{canonicalFixture()},
    );
}
