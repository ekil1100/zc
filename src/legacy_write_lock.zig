const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");

const lock_file_name = "legacy-cutover.lock";
const state_file_name = "state-v2.json";
const state_header_bytes_max = 64;

fn ownerOnlyPermissions() std.Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    return std.Io.File.Permissions.fromMode(0o600);
}

pub const Guard = struct {
    lock: std.Io.File,

    pub fn deinit(self: *Guard) void {
        self.lock.close(compat.io());
        self.* = undefined;
    }
};

pub fn acquire(root: std.Io.Dir) !Guard {
    while (true) {
        const lock = root.openFile(compat.io(), lock_file_name, .{
            .mode = .read_write,
            .lock = .exclusive,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                const created = root.createFile(compat.io(), lock_file_name, .{
                    .exclusive = true,
                    .permissions = ownerOnlyPermissions(),
                }) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => continue,
                    else => return create_err,
                };
                created.close(compat.io());
                continue;
            },
            error.SymLinkLoop, error.IsDir => return error.InvalidLegacyWriteLock,
            else => return err,
        };
        errdefer lock.close(compat.io());
        if ((try lock.stat(compat.io())).kind != .file) {
            return error.InvalidLegacyWriteLock;
        }
        try lock.setPermissions(compat.io(), ownerOnlyPermissions());
        return .{ .lock = lock };
    }
}

pub fn rejectCatalogAuthority(root: std.Io.Dir) !void {
    const state = root.openFile(compat.io(), state_file_name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.SymLinkLoop, error.IsDir => return error.CorruptState,
        else => return err,
    };
    defer state.close(compat.io());
    if ((try state.stat(compat.io())).kind != .file) return error.CorruptState;
    var header: [state_header_bytes_max]u8 = undefined;
    const length = try compat.fileReadAll(state, &header);
    const bytes = header[0..length];
    if (std.mem.startsWith(u8, bytes, "{\"schema_version\":2,")) {
        return error.CatalogAuthorityActive;
    }
    if (!std.mem.startsWith(u8, bytes, "{\"schema_version\":1,")) {
        return error.CorruptState;
    }
}

test "LegacyWriteLock serializes writers and rejects catalog authority" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var guard = try acquire(tmp.dir);
    var started = std.atomic.Value(bool).init(false);
    var acquired = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(
            root: std.Io.Dir,
            writer_started: *std.atomic.Value(bool),
            writer_acquired: *std.atomic.Value(bool),
        ) void {
            writer_started.store(true, .seq_cst);
            var writer = acquire(root) catch return;
            defer writer.deinit();
            writer_acquired.store(true, .seq_cst);
        }
    }.run, .{ tmp.dir, &started, &acquired });
    while (!started.load(.seq_cst)) compat.sleepNs(std.time.ns_per_ms);
    compat.sleepNs(10 * std.time.ns_per_ms);
    const acquired_while_locked = acquired.load(.seq_cst);
    guard.deinit();
    thread.join();
    try testing.expect(!acquired_while_locked);
    try testing.expect(acquired.load(.seq_cst));

    try rejectCatalogAuthority(tmp.dir);
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = state_file_name,
        .data = "{\"schema_version\":2,\"sequence\":0,\"active\":null,\"profiles\":[]}\n",
    });
    try testing.expectError(
        error.CatalogAuthorityActive,
        rejectCatalogAuthority(tmp.dir),
    );
}
