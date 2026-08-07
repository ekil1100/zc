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

fn makeSelectionLimitFixture(
    allocator: std.mem.Allocator,
    selection_count: usize,
) !struct {
    names: [][24]u8,
    selections: []catalog.Selection,
} {
    const names = try allocator.alloc([24]u8, selection_count);
    errdefer allocator.free(names);
    const selections = try allocator.alloc(catalog.Selection, selection_count);
    errdefer allocator.free(selections);
    for (names, selections, 0..) |*name_buffer, *selection, index| {
        const name = try std.fmt.bufPrint(name_buffer, "group-{d}", .{index});
        selection.* = .{ .group = name, .proxy = "DIRECT" };
    }
    return .{ .names = names, .selections = selections };
}

test "ConfigCatalog persisted selection limit accepts max and rejects max plus one fail first" {
    const allocator = testing.allocator;
    const maximum = try makeSelectionLimitFixture(
        allocator,
        catalog.persisted_selection_count_max,
    );
    defer allocator.free(maximum.selections);
    defer allocator.free(maximum.names);
    const maximum_profiles = [_]catalog.Profile{.{
        .key = "home",
        .storage_id = identity.StorageId.derive("home"),
        .head = revision_a,
        .desired = .{ .selections = maximum.selections },
    }};
    const encoded = try catalog.encodeCanonical(allocator, .{
        .profiles = &maximum_profiles,
    });
    defer allocator.free(encoded);

    const overflow = try makeSelectionLimitFixture(
        allocator,
        catalog.persisted_selection_count_max + 1,
    );
    defer allocator.free(overflow.selections);
    defer allocator.free(overflow.names);
    const overflow_profiles = [_]catalog.Profile{.{
        .key = "home",
        .storage_id = identity.StorageId.derive("home"),
        .head = revision_a,
        .desired = .{ .selections = overflow.selections },
    }};
    var failing = testing.FailingAllocator.init(allocator, .{
        .fail_index = 0,
    });
    try testing.expectError(
        error.PersistedSelectionCountLimitExceeded,
        catalog.encodeCanonical(failing.allocator(), .{
            .profiles = &overflow_profiles,
        }),
    );
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    try testing.expect(!failing.has_induced_failure);
}

test "ConfigCatalog treats an on-disk persisted selection excess as corruption" {
    const allocator = testing.allocator;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(
        allocator,
        "{\"schema_version\":2,\"sequence\":1,\"active\":null,\"profiles\":[" ++
            "{\"key\":\"home\",\"storage_id\":" ++
            "\"dc3fb855b586386498f9ec0db774a3d31da4003977fcbcd9a697fb7455a6645b\"," ++
            "\"head\":\"11111111111111111111111111111111\"," ++
            "\"desired\":{\"generation\":1,\"selections\":[",
    );
    for (0..catalog.persisted_selection_count_max + 1) |index| {
        if (index > 0) try bytes.append(allocator, ',');
        try bytes.appendSlice(
            allocator,
            "{\"group\":\"Proxy\",\"proxy\":\"DIRECT\"}",
        );
    }
    try bytes.appendSlice(allocator, "]}}]}\n");

    try testing.expectError(
        error.CorruptCatalog,
        catalog.decodeCanonical(allocator, bytes.items),
    );
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
