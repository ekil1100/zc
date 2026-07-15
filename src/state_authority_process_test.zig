const std = @import("std");
const compat = @import("compat.zig");
const state = @import("state_authority.zig");

fn collectArgs(allocator: std.mem.Allocator, raw_args: std.process.Args) ![]const []const u8 {
    var it = try std.process.Args.Iterator.initAllocator(raw_args, allocator);
    defer it.deinit();
    var args = std.ArrayList([]const u8).empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    while (it.next()) |arg| try args.append(allocator, try allocator.dupe(u8, arg));
    return args.toOwnedSlice(allocator);
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn printToken(token: []const u8) !void {
    var buffer: [32]u8 = undefined;
    if (token.len + 1 > buffer.len) return error.TokenTooLong;
    @memcpy(buffer[0..token.len], token);
    buffer[token.len] = '\n';
    try compat.writeStdoutAll(buffer[0 .. token.len + 1]);
}

fn runCas(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 7) return error.InvalidArguments;
    const root = args[2];
    const key = args[3];
    const expected_text = args[4];
    const next = try state.Revision.parseHex(args[5]);
    const ready_path = args[6];

    var dir = try compat.fs.openDirAbsolute(root, .{});
    defer dir.close(compat.io());
    const authority = state.Authority.init(allocator, dir);
    const expected: state.ExpectedHead = if (std.mem.eql(u8, expected_text, "missing"))
        .missing
    else
        .{ .revision = try state.Revision.parseHex(expected_text) };
    const ready = try compat.fs.createFileAbsolute(ready_path, .{});
    ready.close(compat.io());
    const outcome = try authority.commit(.{ .compare_exchange_head = .{
        .key = key,
        .expected = expected,
        .next = next,
    } });
    switch (outcome) {
        .committed => try printToken("committed"),
        .conflict => try printToken("conflict"),
        .durability_uncertain => try printToken("uncertain"),
    }
}

fn runHoldLock(args: []const []const u8) !void {
    if (args.len != 4) return error.InvalidArguments;
    const root = args[2];
    const ready_path = args[3];
    var dir = try compat.fs.openDirAbsolute(root, .{});
    defer dir.close(compat.io());
    const lock = try dir.createFile(compat.io(), "state-v2.lock", .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer lock.close(compat.io());

    const ready = try compat.fs.createFileAbsolute(ready_path, .{});
    ready.close(compat.io());
    while (true) compat.sleepNs(10 * std.time.ns_per_ms);
}

fn runProbeLock(args: []const []const u8) !void {
    if (args.len != 3) return error.InvalidArguments;
    var dir = try compat.fs.openDirAbsolute(args[2], .{});
    defer dir.close(compat.io());
    const lock = dir.createFile(compat.io(), "state-v2.lock", .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => {
            try printToken("blocked");
            return;
        },
        else => return err,
    };
    defer lock.close(compat.io());
    try printToken("acquired");
}

pub fn main(init: std.process.Init) !void {
    compat.setIo(init.io);
    compat.setEnvironMap(init.environ_map);
    const allocator = init.gpa;
    const args = try collectArgs(allocator, init.minimal.args);
    defer freeArgs(allocator, args);
    if (args.len < 2) return error.InvalidArguments;

    if (std.mem.eql(u8, args[1], "cas")) return runCas(allocator, args);
    if (std.mem.eql(u8, args[1], "hold-lock")) return runHoldLock(args);
    if (std.mem.eql(u8, args[1], "probe-lock")) return runProbeLock(args);
    return error.InvalidArguments;
}
