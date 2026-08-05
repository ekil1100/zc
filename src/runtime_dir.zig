const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");

pub const pid_name = "zc.pid";
pub const lock_name = "zc.lock";
pub const log_name = "zc.log";
pub const descriptor_name = "zc.daemon.json";
pub const stop_prefix = "zc.stop.";
pub const startup_prefix = "zc.start.";

fn ownerDirPermissions() std.Io.File.Permissions {
    return std.Io.File.Permissions.fromMode(0o700);
}

pub fn ownerFilePermissions() std.Io.File.Permissions {
    return std.Io.File.Permissions.fromMode(0o600);
}

fn effectiveUid() std.posix.uid_t {
    return std.c.geteuid();
}

fn statOwner(dir: std.Io.Dir) !std.posix.uid_t {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stat = std.mem.zeroes(linux.Statx);
        const result = linux.statx(
            dir.handle,
            "",
            linux.AT.EMPTY_PATH,
            .{ .UID = true },
            &stat,
        );
        if (linux.errno(result) != .SUCCESS or !stat.mask.UID) {
            return error.RuntimeDirectoryStatFailed;
        }
        return stat.uid;
    }

    var stat = std.mem.zeroes(std.posix.Stat);
    const result = std.posix.system.fstat(dir.handle, &stat);
    if (std.posix.errno(result) != .SUCCESS) {
        return error.RuntimeDirectoryStatFailed;
    }
    return stat.uid;
}

fn validateOwnedDirectory(dir: std.Io.Dir, strict: bool) !void {
    const stat = try dir.stat(compat.io());
    if (stat.kind != .directory) return error.InvalidRuntimeDirectory;
    if (try statOwner(dir) != effectiveUid()) {
        return error.RuntimeDirectoryOwnerMismatch;
    }
    const mode = stat.permissions.toMode() & 0o777;
    if (strict) {
        if (mode != 0o700) return error.RuntimeDirectoryPermissions;
    } else if (mode & 0o022 != 0) {
        return error.RuntimeDirectoryPermissions;
    }
}

fn validateDirectory(dir: std.Io.Dir) !void {
    return validateOwnedDirectory(dir, true);
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\") != null)
    {
        return error.InvalidRuntimeFileName;
    }
}

pub const RuntimeDir = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    dir: std.Io.Dir,

    pub fn deinit(self: *RuntimeDir) void {
        self.dir.close(compat.io());
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn filePath(self: RuntimeDir, name: []const u8) ![]u8 {
        try validateName(name);
        return compat.fs.path.join(self.allocator, &.{ self.path, name });
    }

    pub fn openFile(
        self: RuntimeDir,
        name: []const u8,
        options: std.Io.Dir.OpenFileOptions,
    ) !std.Io.File {
        try validateName(name);
        if (comptime builtin.os.tag == .windows) {
            var safe_options = options;
            safe_options.follow_symlinks = false;
            safe_options.resolve_beneath = true;
            const file = try self.dir.openFile(compat.io(), name, safe_options);
            errdefer file.close(compat.io());
            if ((try file.stat(compat.io())).kind != .file) {
                return error.InvalidRuntimeFile;
            }
            return file;
        }

        const access_mode: std.posix.ACCMODE = switch (options.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        };
        const fd = try std.posix.openat(self.dir.handle, name, .{
            .ACCMODE = access_mode,
            .NONBLOCK = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0);
        const file: std.Io.File = .{
            .handle = fd,
            .flags = .{ .nonblocking = true },
        };
        errdefer file.close(compat.io());
        if ((try file.stat(compat.io())).kind != .file) {
            return error.InvalidRuntimeFile;
        }
        if (options.lock != .none) {
            if (options.lock_nonblocking) {
                if (!try file.tryLock(compat.io(), options.lock)) {
                    return error.WouldBlock;
                }
            } else {
                try file.lock(compat.io(), options.lock);
            }
        }
        return file;
    }

    pub fn createExclusive(self: RuntimeDir, name: []const u8) !std.Io.File {
        try validateName(name);
        const file = try self.dir.createFile(compat.io(), name, .{
            .exclusive = true,
            .permissions = ownerFilePermissions(),
            .resolve_beneath = true,
        });
        errdefer file.close(compat.io());
        try file.setPermissions(compat.io(), ownerFilePermissions());
        if ((try file.stat(compat.io())).kind != .file) {
            return error.InvalidRuntimeFile;
        }
        return file;
    }

    pub fn replaceFile(self: RuntimeDir, name: []const u8, bytes: []const u8) !void {
        try validateName(name);
        var atomic = try self.dir.createFileAtomic(compat.io(), name, .{
            .replace = true,
            .permissions = ownerFilePermissions(),
        });
        defer atomic.deinit(compat.io());
        try atomic.file.setPermissions(compat.io(), ownerFilePermissions());
        try compat.fileWriteAll(atomic.file, bytes);
        try atomic.file.sync(compat.io());
        try atomic.replace(compat.io());
        const parent = try self.dir.openFile(compat.io(), ".", .{
            .allow_directory = true,
            .follow_symlinks = false,
        });
        defer parent.close(compat.io());
        try parent.sync(compat.io());
    }

    pub fn deleteFile(self: RuntimeDir, name: []const u8) !void {
        try validateName(name);
        return self.dir.deleteFile(compat.io(), name);
    }
};

fn openAbsoluteDirectoryNoFollow(path: []const u8) !std.Io.Dir {
    if (!compat.fs.path.isAbsolute(path)) return error.InvalidRuntimeDirectory;
    if (comptime builtin.os.tag == .windows) {
        return std.Io.Dir.openDirAbsolute(compat.io(), path, .{
            .follow_symlinks = false,
        });
    }

    var current = try std.Io.Dir.openDirAbsolute(compat.io(), "/", .{
        .follow_symlinks = false,
    });
    errdefer current.close(compat.io());
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return error.RuntimeDirectoryNotCanonical;
        }
        const next = try current.openDir(compat.io(), component, .{
            .follow_symlinks = false,
        });
        current.close(compat.io());
        current = next;
    }
    return current;
}

fn openExisting(allocator: std.mem.Allocator, path: []const u8) !?RuntimeDir {
    if (!compat.fs.path.isAbsolute(path)) return error.InvalidRuntimeDirectory;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const dir = openAbsoluteDirectoryNoFollow(path) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(owned_path);
            return null;
        },
        else => return err,
    };
    errdefer dir.close(compat.io());
    try validateDirectory(dir);
    return .{ .allocator = allocator, .path = owned_path, .dir = dir };
}

pub fn openPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    create: bool,
) !?RuntimeDir {
    if (!compat.fs.path.isAbsolute(path)) return error.InvalidRuntimeDirectory;
    const canonical = compat.fs.realpathAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (canonical) |resolved| {
        defer allocator.free(resolved);
        if (!std.mem.eql(u8, path, resolved)) {
            return error.RuntimeDirectoryNotCanonical;
        }
    }
    if (try openExisting(allocator, path)) |runtime| return runtime;
    if (!create) return null;

    const parent_path = compat.fs.path.dirname(path) orelse
        return error.InvalidRuntimeDirectory;
    const name = compat.fs.path.basename(path);
    try validateName(name);
    const canonical_parent = try compat.fs.realpathAlloc(allocator, parent_path);
    defer allocator.free(canonical_parent);
    if (!std.mem.eql(u8, parent_path, canonical_parent)) {
        return error.RuntimeDirectoryNotCanonical;
    }
    const parent = try openAbsoluteDirectoryNoFollow(parent_path);
    defer parent.close(compat.io());
    var created = true;
    parent.createDir(
        compat.io(),
        name,
        ownerDirPermissions(),
    ) catch |err| switch (err) {
        error.PathAlreadyExists => created = false,
        else => return err,
    };
    if (created) {
        try parent.setFilePermissions(
            compat.io(),
            name,
            ownerDirPermissions(),
            .{ .follow_symlinks = false },
        );
    }
    if (parent.openDir(compat.io(), name, .{ .follow_symlinks = false })) |child| {
        defer child.close(compat.io());
        try validateOwnedDirectory(child, false);
    } else |err| return err;
    return (try openExisting(allocator, path)) orelse error.InvalidRuntimeDirectory;
}

fn canonicalHome(allocator: std.mem.Allocator) ![]u8 {
    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    if (!compat.fs.path.isAbsolute(home)) return error.InvalidRuntimeDirectory;
    const canonical = try compat.fs.realpathAlloc(allocator, home);
    errdefer allocator.free(canonical);
    if (!std.mem.eql(u8, home, canonical)) {
        return error.RuntimeDirectoryNotCanonical;
    }
    return canonical;
}

pub fn fallbackPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try canonicalHome(allocator);
    defer allocator.free(home);
    return compat.fs.path.join(
        allocator,
        &.{ home, ".local", "state", "zc", "runtime" },
    );
}

pub fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    return compat.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => fallbackPath(allocator),
        else => return err,
    };
}

fn openChildDirectory(
    parent: std.Io.Dir,
    name: []const u8,
    create: bool,
    strict: bool,
) !?std.Io.Dir {
    var created = false;
    const child = parent.openDir(compat.io(), name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (!create) return null;
            parent.createDir(compat.io(), name, ownerDirPermissions()) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return create_err,
            };
            created = true;
            try parent.setFilePermissions(
                compat.io(),
                name,
                ownerDirPermissions(),
                .{ .follow_symlinks = false },
            );
            break :blk try parent.openDir(compat.io(), name, .{
                .follow_symlinks = false,
            });
        },
        else => return err,
    };
    errdefer child.close(compat.io());
    try validateOwnedDirectory(child, false);
    if (created) try compat.setDirPermissions(child, ownerDirPermissions());
    try validateOwnedDirectory(child, strict);
    return child;
}

fn openFallback(
    allocator: std.mem.Allocator,
    create: bool,
) !?RuntimeDir {
    const home_path = try canonicalHome(allocator);
    defer allocator.free(home_path);
    var current = try openAbsoluteDirectoryNoFollow(home_path);
    var current_open = true;
    defer if (current_open) current.close(compat.io());
    try validateOwnedDirectory(current, false);

    const components = [_][]const u8{ ".local", "state", "zc", "runtime" };
    for (components, 0..) |component, index| {
        const next = (try openChildDirectory(
            current,
            component,
            create,
            index + 1 == components.len,
        )) orelse return null;
        current.close(compat.io());
        current = next;
    }
    const path = try fallbackPath(allocator);
    current_open = false;
    return .{ .allocator = allocator, .path = path, .dir = current };
}

pub fn openDefault(
    allocator: std.mem.Allocator,
    create: bool,
) !?RuntimeDir {
    if (compat.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |path| {
        defer allocator.free(path);
        return (try openPath(allocator, path, false)) orelse
            error.InvalidRuntimeDirectory;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    return openFallback(allocator, create);
}

test "RuntimeDir requires owner-only real directories" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.setDirPermissions(tmp.dir, ownerDirPermissions());
    const path = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(path);

    var runtime = (try openPath(allocator, path, false)).?;
    defer runtime.deinit();
    try testing.expectEqualStrings(path, runtime.path);

    try tmp.dir.setPermissions(
        compat.io(),
        std.Io.File.Permissions.fromMode(0o755),
    );
    try testing.expectError(
        error.RuntimeDirectoryPermissions,
        openPath(allocator, path, false),
    );
}

test "RuntimeDir rejects a symlink directory" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(compat.io(), "actual", ownerDirPermissions());
    tmp.dir.symLink(compat.io(), "actual", "runtime", .{ .is_directory = true }) catch
        return error.SkipZigTest;
    const path = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(path);
    const link_path = try compat.fs.path.join(allocator, &.{ path, "runtime" });
    defer allocator.free(link_path);

    if (openPath(allocator, link_path, false)) |runtime| {
        if (runtime) |value| {
            var opened = value;
            opened.deinit();
        }
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(
            err == error.RuntimeDirectoryNotCanonical or
                err == error.SymLinkLoop or
                err == error.NotDir,
        );
    }
}

test "RuntimeDir rejects paths with intermediate symlinks" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), "real-parent/runtime");
    const runtime = try tmp.dir.openDir(compat.io(), "real-parent/runtime", .{});
    defer runtime.close(compat.io());
    try compat.setDirPermissions(runtime, ownerDirPermissions());
    tmp.dir.symLink(compat.io(), "real-parent", "alias", .{}) catch
        return error.SkipZigTest;

    const root = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(root);
    const path = try compat.fs.path.join(
        allocator,
        &.{ root, "alias", "runtime" },
    );
    defer allocator.free(path);
    try testing.expectError(
        error.RuntimeDirectoryNotCanonical,
        openPath(allocator, path, false),
    );
}

test "RuntimeDir atomic replacement does not follow a leaf symlink" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.setDirPermissions(tmp.dir, ownerDirPermissions());
    const sentinel = try tmp.dir.createFile(compat.io(), "sentinel", .{});
    try compat.fileWriteAll(sentinel, "unchanged");
    sentinel.close(compat.io());
    tmp.dir.symLink(compat.io(), "sentinel", pid_name, .{}) catch
        return error.SkipZigTest;
    const path = try tmp.dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(path);
    var runtime = (try openPath(allocator, path, false)).?;
    defer runtime.deinit();

    try runtime.replaceFile(pid_name, "42\n");
    const sentinel_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        "sentinel",
        allocator,
        .limited(32),
    );
    defer allocator.free(sentinel_bytes);
    try testing.expectEqualStrings("unchanged", sentinel_bytes);
    const pid_bytes = try tmp.dir.readFileAlloc(
        compat.io(),
        pid_name,
        allocator,
        .limited(32),
    );
    defer allocator.free(pid_bytes);
    try testing.expectEqualStrings("42\n", pid_bytes);
}

test "RuntimeDir fallback stays under the canonical user home" {
    const allocator = std.testing.allocator;
    const path = try fallbackPath(allocator);
    defer allocator.free(path);
    const home = try canonicalHome(allocator);
    defer allocator.free(home);
    const expected = try compat.fs.path.join(
        allocator,
        &.{ home, ".local", "state", "zc", "runtime" },
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}
