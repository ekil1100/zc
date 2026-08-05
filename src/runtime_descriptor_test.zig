const std = @import("std");
const testing = std.testing;
const compat = @import("compat.zig");
const config_identity = @import("config_identity.zig");
const runtime_descriptor = @import("runtime_descriptor.zig");

const Store = runtime_descriptor.Store;

fn nonce(text: []const u8) !runtime_descriptor.Nonce {
    return runtime_descriptor.Nonce.parseHex(text);
}

test "RuntimeDescriptor publishes canonical tracked endpoint and exact identity" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(allocator, tmp.dir);
    const revision = try config_identity.Revision.parseHex("00112233445566778899aabbccddeeff");
    const instance_nonce = try nonce("11111111111111111111111111111111");
    const outcome = try store.publish(.missing, .{
        .pid = 1234,
        .nonce = instance_nonce,
        .endpoint = "127.0.0.1:29001",
        .identity = .{ .key = "home", .revision = revision },
        .generation = 7,
    });
    try testing.expect(outcome == .committed);

    var observed = (try store.observe()) orelse return error.TestExpectedEqual;
    defer observed.deinit();
    try testing.expectEqual(@as(u32, 1234), observed.pid);
    try testing.expect(observed.nonce.eql(instance_nonce));
    try testing.expectEqualStrings("127.0.0.1:29001", observed.endpoint.?);
    try testing.expectEqualStrings("home", observed.identity.?.key);
    try testing.expect(observed.identity.?.revision.eql(revision));
    try testing.expectEqual(@as(u64, 7), observed.generation);

    const descriptor_file = try tmp.dir.openFile(
        compat.io(),
        runtime_descriptor.file_name,
        .{},
    );
    defer descriptor_file.close(compat.io());
    if (@import("builtin").os.tag != .windows) {
        const stat = try descriptor_file.stat(compat.io());
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
        const root_file = try tmp.dir.openFile(compat.io(), ".", .{ .allow_directory = true });
        defer root_file.close(compat.io());
        const root_stat = try root_file.stat(compat.io());
        try testing.expectEqual(@as(std.posix.mode_t, 0o700), root_stat.permissions.toMode() & 0o777);
    }
    const bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        runtime_descriptor.file_name,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(bytes);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"pid\":1234,\"nonce\":\"11111111111111111111111111111111\",\"endpoint\":\"127.0.0.1:29001\",\"identity\":{\"key\":\"home\",\"revision\":\"00112233445566778899aabbccddeeff\"},\"generation\":7,\"ready\":true}\n",
        bytes,
    );
}

test "RuntimeDescriptor tracks readiness when the controller is disabled" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(allocator, tmp.dir);
    const instance_nonce = try nonce("11111111111111111111111111111111");
    _ = try store.publish(.missing, .{
        .pid = 42,
        .nonce = instance_nonce,
        .ready = false,
    });
    {
        var observed = (try store.observe()) orelse return error.TestExpectedEqual;
        defer observed.deinit();
        try testing.expect(observed.endpoint == null);
        try testing.expect(!observed.ready);
    }
    try testing.expect((try store.publish(.{ .state = .{
        .nonce = instance_nonce,
        .generation = 0,
        .ready = false,
    } }, .{
        .pid = 42,
        .nonce = instance_nonce,
        .ready = true,
    })) == .committed);
    var ready = (try store.observe()) orelse return error.TestExpectedEqual;
    defer ready.deinit();
    try testing.expect(ready.ready);
    try testing.expectError(
        error.RuntimeReadinessRegression,
        store.publish(.{ .nonce = instance_nonce }, .{
            .pid = 42,
            .nonce = instance_nonce,
            .ready = false,
        }),
    );
}

test "RuntimeDescriptor observation is side-effect-free and works without write permission" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(allocator, tmp.dir);
    try testing.expect(try store.observe() == null);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), runtime_descriptor.lock_name, .{}),
    );
    if (@import("builtin").os.tag == .windows) return;

    const instance_nonce = try nonce("11111111111111111111111111111111");
    _ = try store.publish(.missing, .{ .pid = 1, .nonce = instance_nonce, .endpoint = "127.0.0.1:1" });
    try compat.setDirPermissions(tmp.dir, std.Io.File.Permissions.fromMode(0o500));
    defer compat.setDirPermissions(tmp.dir, std.Io.File.Permissions.fromMode(0o700)) catch {};
    var observed = (try store.observe()) orelse return error.TestExpectedEqual;
    defer observed.deinit();
    try testing.expect(observed.nonce.eql(instance_nonce));
    const root_file = try tmp.dir.openFile(compat.io(), ".", .{ .allow_directory = true });
    defer root_file.close(compat.io());
    const stat = try root_file.stat(compat.io());
    try testing.expectEqual(@as(std.posix.mode_t, 0o500), stat.permissions.toMode() & 0o777);
}

test "RuntimeDescriptor stale instance cannot replace a newer daemon" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(allocator, tmp.dir);
    const first_nonce = try nonce("11111111111111111111111111111111");
    const second_nonce = try nonce("22222222222222222222222222222222");
    try testing.expect((try store.publish(.missing, .{
        .pid = 1,
        .nonce = first_nonce,
        .endpoint = "127.0.0.1:1",
    })) == .committed);
    try testing.expect((try store.publish(.{ .nonce = first_nonce }, .{
        .pid = 2,
        .nonce = second_nonce,
        .endpoint = "127.0.0.1:2",
    })) == .committed);
    const stale = try store.publish(.{ .nonce = first_nonce }, .{
        .pid = 3,
        .nonce = first_nonce,
        .endpoint = "127.0.0.1:3",
    });
    switch (stale) {
        .conflict => |actual| try testing.expect(actual.?.eql(second_nonce)),
        else => return error.TestExpectedEqual,
    }
    var observed = (try store.observe()) orelse return error.TestExpectedEqual;
    defer observed.deinit();
    try testing.expectEqual(@as(u32, 2), observed.pid);
    try testing.expectEqualStrings("127.0.0.1:2", observed.endpoint.?);
}

test "RuntimeDescriptor generation state prevents reordered updates" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(allocator, tmp.dir);
    const instance_nonce = try nonce("11111111111111111111111111111111");
    const revision = try config_identity.Revision.parseHex(
        "00112233445566778899aabbccddeeff",
    );
    _ = try store.publish(.missing, .{
        .pid = 1,
        .nonce = instance_nonce,
        .endpoint = "127.0.0.1:1",
        .identity = .{ .key = "home", .revision = revision },
    });
    try testing.expect((try store.publish(.{ .state = .{
        .nonce = instance_nonce,
        .generation = 0,
    } }, .{
        .pid = 1,
        .nonce = instance_nonce,
        .endpoint = "127.0.0.1:1",
        .identity = .{ .key = "home", .revision = revision },
        .generation = 1,
    })) == .committed);
    const reordered = try store.publish(.{ .state = .{
        .nonce = instance_nonce,
        .generation = 0,
    } }, .{
        .pid = 1,
        .nonce = instance_nonce,
        .endpoint = "127.0.0.1:1",
        .identity = .{ .key = "home", .revision = revision },
        .generation = 2,
    });
    try testing.expect(reordered == .conflict);
    try testing.expect((try store.publish(.{ .state = .{
        .nonce = instance_nonce,
        .generation = 1,
    } }, .{
        .pid = 1,
        .nonce = instance_nonce,
        .endpoint = "127.0.0.1:1",
        .identity = .{ .key = "home", .revision = revision },
        .generation = 4,
    })) == .committed);
    try testing.expectError(
        error.InvalidRuntimeGeneration,
        store.publish(.{ .state = .{
            .nonce = instance_nonce,
            .generation = 4,
        } }, .{
            .pid = 1,
            .nonce = instance_nonce,
            .endpoint = "127.0.0.1:1",
            .identity = .{ .key = "home", .revision = revision },
            .generation = 3,
        }),
    );
}

test "RuntimeDescriptor stale shutdown cannot remove a replacement daemon" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(allocator, tmp.dir);
    const first_nonce = try nonce("11111111111111111111111111111111");
    const second_nonce = try nonce("22222222222222222222222222222222");
    _ = try store.publish(.missing, .{ .pid = 1, .nonce = first_nonce, .endpoint = "127.0.0.1:1" });
    _ = try store.publish(.{ .nonce = first_nonce }, .{ .pid = 2, .nonce = second_nonce, .endpoint = "127.0.0.1:2" });
    const stale = try store.remove(first_nonce);
    switch (stale) {
        .conflict => |actual| try testing.expect(actual.eql(second_nonce)),
        else => return error.TestExpectedEqual,
    }
    try testing.expect((try store.remove(second_nonce)) == .removed);
    try testing.expect(try store.observe() == null);
    try testing.expect((try store.remove(second_nonce)) == .absent);
}

test "RuntimeDescriptor rejects noncanonical and symlinked descriptors" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = runtime_descriptor.file_name,
        .data = "{ \"schema_version\": 1, \"pid\": 1, \"nonce\": \"11111111111111111111111111111111\", \"endpoint\": \"x\", \"identity\": null, \"generation\": 0 }\n",
    });
    const store = Store.init(allocator, tmp.dir);
    try testing.expectError(error.CorruptRuntimeDescriptor, store.observe());
    try tmp.dir.deleteFile(compat.io(), runtime_descriptor.file_name);
    try tmp.dir.writeFile(compat.io(), .{ .sub_path = "target", .data = "{}\n" });
    try tmp.dir.symLink(
        compat.io(),
        "target",
        runtime_descriptor.file_name,
        .{},
    );
    try testing.expectError(error.CorruptRuntimeDescriptor, store.observe());
}

test "RuntimeDescriptor distinguishes unmanaged runtime and same key different revision" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(allocator, tmp.dir);
    const first_nonce = try nonce("11111111111111111111111111111111");
    const second_nonce = try nonce("22222222222222222222222222222222");
    const revision = try config_identity.Revision.parseHex("ffeeddccbbaa99887766554433221100");
    _ = try store.publish(.missing, .{
        .pid = 1,
        .nonce = first_nonce,
        .endpoint = "127.0.0.1:29001",
        .identity = null,
    });
    var unmanaged = (try store.observe()) orelse return error.TestExpectedEqual;
    try testing.expect(unmanaged.identity == null);
    unmanaged.deinit();
    _ = try store.publish(.{ .nonce = first_nonce }, .{
        .pid = 2,
        .nonce = second_nonce,
        .endpoint = "127.0.0.1:29002",
        .identity = .{ .key = "home", .revision = revision },
        .generation = 9,
    });
    var managed = (try store.observe()) orelse return error.TestExpectedEqual;
    defer managed.deinit();
    try testing.expect(managed.identity.?.revision.eql(revision));
    try testing.expectEqual(@as(u64, 9), managed.generation);
}

test "RuntimeDescriptor bounds lock contention" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(compat.io(), runtime_descriptor.lock_name, .{
        .read = true,
        .lock = .exclusive,
    });
    defer lock.close(compat.io());
    const store = Store.init(allocator, tmp.dir);
    try testing.expectError(
        error.RuntimeDescriptorBusy,
        store.publish(.missing, .{
            .pid = 1,
            .nonce = try nonce("11111111111111111111111111111111"),
            .endpoint = "127.0.0.1:29001",
        }),
    );
}

fn observeAllocationFixture(allocator: std.mem.Allocator, root: std.Io.Dir) !void {
    const store = Store.init(allocator, root);
    var observed = (try store.observe()) orelse return error.TestExpectedEqual;
    observed.deinit();
}

test "RuntimeDescriptor releases every observe allocation failure path" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = Store.init(allocator, tmp.dir);
    _ = try store.publish(.missing, .{
        .pid = 1,
        .nonce = try nonce("11111111111111111111111111111111"),
        .endpoint = "127.0.0.1:29001",
    });
    try testing.checkAllAllocationFailures(
        testing.allocator,
        observeAllocationFixture,
        .{tmp.dir},
    );
}
