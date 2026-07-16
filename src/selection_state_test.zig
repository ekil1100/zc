const std = @import("std");
const testing = std.testing;
const catalog_service = @import("catalog_service.zig");
const compat = @import("compat.zig");
const config_bundle = @import("config_bundle.zig");
const selection_state = @import("selection_state.zig");
const state_authority = @import("state_authority.zig");

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(compat.io(), bytes);
}

test "SelectionState durably replaces one exact desired group and generation" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    const path = try tmp.dir.realPathFileAlloc(compat.io(), "source.yaml", allocator);
    defer allocator.free(path);
    var bundle = try config_bundle.ConfigBundle.capture(allocator, path, .{});
    defer bundle.deinit();
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var missing = try authority.inspect();
    const token = missing.token();
    missing.deinit();
    const bootstrapped = try authority.bootstrapCatalog(token, .{});
    const initial = switch (bootstrapped) {
        .committed => |receipt| receipt.token,
        else => return error.TestExpectedEqual,
    };
    _ = switch (try catalog_service.Service.init(allocator, tmp.dir).publish(initial, .{
        .key = "home",
        .expected = .missing,
        .bundle = &bundle,
        .desired = .clear,
        .activate = true,
    })) {
        .applied => |receipt| receipt,
        else => return error.TestExpectedEqual,
    };

    const state = selection_state.State.init(allocator, tmp.dir);
    const first = try state.persist("home", "Proxy", "A");
    try testing.expectEqual(@as(u64, 1), first.generation.?);
    const second = try state.persist("home", "Proxy", "B");
    try testing.expectEqual(@as(u64, 2), second.generation.?);

    var observed = try authority.inspect();
    defer observed.deinit();
    switch (observed) {
        .catalog_v2 => |*catalog| {
            const profile = catalog.catalog.state.profiles[0];
            try testing.expectEqual(@as(u64, 2), profile.desired.generation);
            try testing.expectEqual(@as(usize, 1), profile.desired.selections.len);
            try testing.expectEqualStrings("B", profile.desired.selections[0].proxy);
        },
        else => return error.TestExpectedEqual,
    }
    // Runtime startup reads authority directly rather than trusting the mirror.
    // The default-path adapter is covered by CLI smoke; this root-level state
    // assertion proves the authoritative values restored by that adapter.
    const mirror = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(mirror);
    try testing.expect(std.mem.indexOf(u8, mirror, "\"Proxy\":\"B\"") != null);
}
