const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");

const file_name = "daemon.json";
const lock_name = "daemon.lock";
const max_bytes = 64 * 1024;

fn ownerOnly() std.Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    return .fromMode(0o600);
}

fn ownerOnlyDir() std.Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_dir;
    return .fromMode(0o700);
}

pub const Nonce = struct {
    bytes: [16]u8,

    pub fn parseHex(text: []const u8) !Nonce {
        if (text.len != 32) return error.InvalidNonce;
        for (text) |c| switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return error.InvalidNonce,
        };
        var bytes: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, text) catch return error.InvalidNonce;
        return .{ .bytes = bytes };
    }

    pub fn generate() Nonce {
        var bytes: [16]u8 = undefined;
        compat.randomBytes(&bytes);
        return .{ .bytes = bytes };
    }

    pub fn formatHex(self: Nonce, out: *[32]u8) []const u8 {
        out.* = std.fmt.bytesToHex(self.bytes, .lower);
        return out;
    }

    pub fn eql(a: Nonce, b: Nonce) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

pub const Identity = config_identity.ManagedIdentity;
pub const DescriptorInput = struct {
    pid: u32,
    nonce: Nonce,
    endpoint: []const u8,
    identity: ?Identity = null,
    generation: u64 = 0,
};
pub const Descriptor = struct {
    allocator: std.mem.Allocator,
    pid: u32,
    nonce: Nonce,
    endpoint: []const u8,
    identity: ?Identity,
    generation: u64,

    pub fn deinit(self: *Descriptor) void {
        self.allocator.free(self.endpoint);
        if (self.identity) |value| self.allocator.free(value.key);
        self.* = undefined;
    }
};
pub const Expected = union(enum) { missing, nonce: Nonce };
pub const PublishOutcome = union(enum) {
    committed,
    conflict: ?Nonce,
    durability_uncertain: anyerror,
};
pub const RemoveOutcome = union(enum) {
    removed,
    absent,
    conflict: Nonce,
    durability_uncertain: anyerror,
};

const DiskIdentity = struct { key: []const u8, revision: []const u8 };
const DiskDescriptor = struct {
    schema_version: u32,
    pid: u32,
    nonce: []const u8,
    endpoint: []const u8,
    identity: ?DiskIdentity,
    generation: u64,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, dir: std.Io.Dir) Store {
        return .{ .allocator = allocator, .dir = dir };
    }

    /// Reads one atomic old-or-new descriptor without creating or locking files.
    pub fn observe(self: Store) !?Descriptor {
        return self.loadUnlocked();
    }

    pub fn publish(self: Store, expected: Expected, next: DescriptorInput) !PublishOutcome {
        try validateInput(next);
        try self.dir.setPermissions(compat.io(), ownerOnlyDir());
        const lock = try self.acquireLock();
        defer lock.close(compat.io());
        var current = try self.loadUnlocked();
        defer if (current) |*value| value.deinit();
        const matches = switch (expected) {
            .missing => current == null,
            .nonce => |value| current != null and current.?.nonce.eql(value),
        };
        if (!matches) return .{ .conflict = if (current) |value| value.nonce else null };
        const bytes = try encode(self.allocator, next);
        defer self.allocator.free(bytes);
        var atomic = try self.dir.createFileAtomic(compat.io(), file_name, .{
            .replace = true,
            .permissions = ownerOnly(),
        });
        defer atomic.deinit(compat.io());
        try compat.fileWriteAll(atomic.file, bytes);
        try atomic.file.sync(compat.io());
        const parent = try self.dir.openFile(compat.io(), ".", .{ .allow_directory = true });
        defer parent.close(compat.io());
        try atomic.replace(compat.io());
        parent.sync(compat.io()) catch |err| return .{ .durability_uncertain = err };
        return .committed;
    }

    pub fn remove(self: Store, expected: Nonce) !RemoveOutcome {
        try self.dir.setPermissions(compat.io(), ownerOnlyDir());
        const lock = try self.acquireLock();
        defer lock.close(compat.io());
        var current = try self.loadUnlocked() orelse return .absent;
        defer current.deinit();
        if (!current.nonce.eql(expected)) return .{ .conflict = current.nonce };
        const parent = try self.dir.openFile(compat.io(), ".", .{ .allow_directory = true });
        defer parent.close(compat.io());
        try self.dir.deleteFile(compat.io(), file_name);
        parent.sync(compat.io()) catch |err| return .{ .durability_uncertain = err };
        return .removed;
    }

    fn acquireLock(self: Store) !std.Io.File {
        while (true) {
            const lock = self.dir.openFile(compat.io(), lock_name, .{
                .mode = .read_write,
                .follow_symlinks = false,
                .lock = .exclusive,
            }) catch |err| switch (err) {
                error.FileNotFound => {
                    const created = self.dir.createFile(compat.io(), lock_name, .{
                        .read = true,
                        .truncate = false,
                        .exclusive = true,
                        .permissions = ownerOnly(),
                    }) catch |create_err| switch (create_err) {
                        error.PathAlreadyExists => continue,
                        else => return create_err,
                    };
                    created.close(compat.io());
                    continue;
                },
                error.SymLinkLoop, error.IsDir => return error.InvalidRuntimeLock,
                else => return err,
            };
            errdefer lock.close(compat.io());
            if ((try lock.stat(compat.io())).kind != .file) return error.InvalidRuntimeLock;
            try lock.setPermissions(compat.io(), ownerOnly());
            return lock;
        }
    }

    fn loadUnlocked(self: Store) !?Descriptor {
        const file = openFile(self.dir) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.CorruptRuntimeDescriptor,
        };
        defer file.close(compat.io());
        const bytes = compat.fileReadBoundedAlloc(file, self.allocator, max_bytes) catch |err| switch (err) {
            error.OutOfMemory, error.FileTooLarge => return err,
            else => return error.CorruptRuntimeDescriptor,
        };
        defer self.allocator.free(bytes);
        return try decode(self.allocator, bytes);
    }
};

fn validateInput(input: DescriptorInput) !void {
    if (input.pid == 0 or input.endpoint.len == 0 or input.endpoint.len > 1024 or
        !std.unicode.utf8ValidateSlice(input.endpoint)) return error.InvalidRuntimeDescriptor;
    for (input.endpoint) |c| if (c < 0x20 or c == 0x7f) return error.InvalidRuntimeDescriptor;
    if (input.identity) |value| {
        if (!config_catalog.isManagedKey(value.key)) return error.InvalidRuntimeDescriptor;
    } else if (input.generation != 0) return error.InvalidRuntimeDescriptor;
}

fn diskValue(input: DescriptorInput, nonce_hex: *[32]u8, revision_hex: *[32]u8) DiskDescriptor {
    return .{
        .schema_version = 1,
        .pid = input.pid,
        .nonce = input.nonce.formatHex(nonce_hex),
        .endpoint = input.endpoint,
        .identity = if (input.identity) |value| .{
            .key = value.key,
            .revision = value.revision.formatHex(revision_hex),
        } else null,
        .generation = input.generation,
    };
}

fn encode(allocator: std.mem.Allocator, input: DescriptorInput) ![]u8 {
    var nonce_hex: [32]u8 = undefined;
    var revision_hex: [32]u8 = undefined;
    const disk = diskValue(input, &nonce_hex, &revision_hex);
    var scratch: [512]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&scratch);
    try std.json.Stringify.value(disk, .{}, &counter.writer);
    try counter.writer.writeByte('\n');
    const size = counter.fullCount();
    if (size > max_bytes) return error.RuntimeDescriptorTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);
    try std.json.Stringify.value(disk, .{}, &writer);
    try writer.writeByte('\n');
    return bytes;
}

fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Descriptor {
    var parsed = std.json.parseFromSlice(DiskDescriptor, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.CorruptRuntimeDescriptor,
    };
    defer parsed.deinit();
    const disk = parsed.value;
    if (disk.schema_version != 1) return error.CorruptRuntimeDescriptor;
    const value: DescriptorInput = .{
        .pid = disk.pid,
        .nonce = Nonce.parseHex(disk.nonce) catch return error.CorruptRuntimeDescriptor,
        .endpoint = disk.endpoint,
        .identity = if (disk.identity) |identity| .{
            .key = identity.key,
            .revision = config_identity.Revision.parseHex(identity.revision) catch
                return error.CorruptRuntimeDescriptor,
        } else null,
        .generation = disk.generation,
    };
    validateInput(value) catch return error.CorruptRuntimeDescriptor;
    const canonical = try encode(allocator, value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.CorruptRuntimeDescriptor;
    const endpoint = try allocator.dupe(u8, value.endpoint);
    errdefer allocator.free(endpoint);
    const identity: ?Identity = if (value.identity) |item| .{
        .key = try allocator.dupe(u8, item.key),
        .revision = item.revision,
    } else null;
    return .{
        .allocator = allocator,
        .pid = value.pid,
        .nonce = value.nonce,
        .endpoint = endpoint,
        .identity = identity,
        .generation = value.generation,
    };
}

fn openFile(dir: std.Io.Dir) !std.Io.File {
    if (builtin.os.tag == .windows) {
        const file = try dir.openFile(compat.io(), file_name, .{ .follow_symlinks = false });
        errdefer file.close(compat.io());
        if ((try file.stat(compat.io())).kind != .file) return error.InvalidRuntimeDescriptor;
        return file;
    }
    const fd = try std.posix.openat(dir.handle, file_name, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    errdefer file.close(compat.io());
    if ((try file.stat(compat.io())).kind != .file) return error.InvalidRuntimeDescriptor;
    return file;
}
