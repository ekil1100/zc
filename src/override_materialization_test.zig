const std = @import("std");
const testing = std.testing;
const materialization = @import("override_materialization.zig");

const FakeRunner = struct {
    calls: usize = 0,
    patch: []const u8,

    fn run(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        script: materialization.Script,
        invocation: materialization.Invocation,
    ) ![]u8 {
        const self: *FakeRunner = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try testing.expectEqualStrings("override.sh", script.name);
        try testing.expectEqualStrings("#!/bin/sh\n", script.bytes);
        try testing.expectEqualStrings("legacy-migration", invocation.command);
        try testing.expectEqual(materialization.timeout_ms_default, invocation.timeout_ms);
        try testing.expectEqual(@as(usize, 1), invocation.args.len);
        try testing.expectEqualStrings("region", invocation.args[0].key);
        return allocator.dupe(u8, self.patch);
    }
};

test "OverrideMaterialization executes once and freezes every effective input" {
    const allocator = testing.allocator;
    var fake = FakeRunner{ .patch = "mixed-port: 9000\n" };
    const args = [_]materialization.Argument{.{ .key = "region", .value = "hk" }};
    var result = try materialization.build(allocator, .{
        .source = "mixed-port: 7890\n",
        .script = .{ .name = "override.sh", .bytes = "#!/bin/sh\n" },
        .invocation = .{
            .command = "legacy-migration",
            .config_path = "configs/home.yaml",
            .timeout_ms = materialization.timeout_ms_default,
            .args = &args,
        },
        .runner = .{ .context = &fake, .run = FakeRunner.run },
    });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), fake.calls);
    try testing.expectEqualStrings("override.sh", result.script.name);
    try testing.expectEqualStrings("#!/bin/sh\n", result.script.bytes);
    try testing.expectEqualStrings("mixed-port: 9000\n", result.patch_bytes);
    try testing.expectEqualStrings("legacy-migration", result.invocation.command);
    try testing.expectEqualStrings("configs/home.yaml", result.invocation.config_path.?);
    try testing.expectEqualStrings("region", result.invocation.args[0].key);
    try testing.expectEqualStrings("hk", result.invocation.args[0].value);

    const config = @import("config.zig");
    var parsed = try config.parseDocument(allocator, result.effective_source);
    defer parsed.deinit();
    try testing.expectEqual(@as(u16, 9000), parsed.mixed_port);
}

test "OverrideMaterialization preserves ordered duplicate args and empty patch source" {
    const allocator = testing.allocator;
    var fake = FakeRunner{ .patch = "\n" };
    const args = [_]materialization.Argument{
        .{ .key = "x", .value = "first" },
        .{ .key = "x", .value = "second" },
    };
    const source = "mixed-port: 7890\n";
    var result = try materialization.build(allocator, .{
        .source = source,
        .script = .{ .name = "override.sh", .bytes = "#!/bin/sh\n" },
        .invocation = .{ .command = "test", .args = &args },
        .runner = .{ .context = &fake, .run = runUnchecked },
    });
    defer result.deinit();
    try testing.expectEqualStrings(source, result.effective_source);
    try testing.expectEqual(@as(usize, 2), result.invocation.args.len);
    try testing.expectEqualStrings("first", result.invocation.args[0].value);
    try testing.expectEqualStrings("second", result.invocation.args[1].value);
}

fn runUnchecked(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    script: materialization.Script,
    invocation: materialization.Invocation,
) ![]u8 {
    _ = script;
    _ = invocation;
    const self: *FakeRunner = @ptrCast(@alignCast(raw));
    self.calls += 1;
    return allocator.dupe(u8, self.patch);
}

fn allocationFixture(allocator: std.mem.Allocator) !void {
    var fake = FakeRunner{ .patch = "mixed-port: 9000\n" };
    var result = try materialization.build(allocator, .{
        .source = "mixed-port: 7890\n",
        .script = .{ .name = "override.sh", .bytes = "#!/bin/sh\n" },
        .invocation = .{ .command = "test" },
        .runner = .{ .context = &fake, .run = runUnchecked },
    });
    result.deinit();
}

test "OverrideMaterialization ProcessRunner executes frozen bytes and cleans staging" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var process_runner = materialization.ProcessRunner.init(tmp.dir);
    const args = [_]materialization.Argument{.{ .key = "port", .value = "9000" }};
    var result = try materialization.build(allocator, .{
        .source = "mixed-port: 7890\n",
        .script = .{
            .name = "override.sh",
            .bytes = "#!/bin/sh\nprintf 'mixed-port: %s\\n' \"$ZC_OVERRIDE_ARG_PORT\"\n",
        },
        .invocation = .{
            .command = "legacy-migration",
            .config_path = "configs/home.yaml",
            .timeout_ms = 5000,
            .args = &args,
        },
        .runner = process_runner.runner(),
    });
    defer result.deinit();
    try testing.expectEqualStrings("mixed-port: 9000\n", result.patch_bytes);

    var dir = tmp.dir;
    var iterator = dir.iterate();
    try testing.expect((try iterator.next(@import("compat.zig").io())) == null);
}

test "OverrideMaterialization ProcessRunner enforces timeout and cleans staging" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var process_runner = materialization.ProcessRunner.init(tmp.dir);
    try testing.expectError(error.OverrideScriptTimeout, materialization.build(allocator, .{
        .source = "mixed-port: 7890\n",
        .script = .{ .name = "slow.sh", .bytes = "#!/bin/sh\nsleep 1\n" },
        .invocation = .{ .command = "test", .timeout_ms = 20 },
        .runner = process_runner.runner(),
    }));
    var iterator = tmp.dir.iterate();
    try testing.expect((try iterator.next(@import("compat.zig").io())) == null);
}

test "OverrideMaterialization releases every allocation failure path" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFixture, .{});
}
