const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");

pub const Revision = struct {
    bytes: [16]u8,

    pub fn parseHex(text: []const u8) !Revision {
        if (text.len != 32) return error.InvalidRevision;
        var bytes: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, text) catch return error.InvalidRevision;
        return .{ .bytes = bytes };
    }

    pub fn formatHex(self: Revision, output: *[32]u8) []const u8 {
        output.* = std.fmt.bytesToHex(self.bytes, .lower);
        return output;
    }

    pub fn eql(a: Revision, b: Revision) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    sequence: u64 = 0,
    profiles: std.StringHashMap(Revision),

    fn init(allocator: std.mem.Allocator) Snapshot {
        return .{
            .allocator = allocator,
            .profiles = std.StringHashMap(Revision).init(allocator),
        };
    }

    pub fn deinit(self: *Snapshot) void {
        var it = self.profiles.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.profiles.deinit();
        self.* = undefined;
    }

    pub fn head(self: *const Snapshot, key: []const u8) ?Revision {
        return self.profiles.get(key);
    }
};

const max_state_bytes = 4 * 1024 * 1024;
const state_file_name = "state-v2.json";
const lock_file_name = "state-v2.lock";

fn ownerOnlyPermissions() std.Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    return std.Io.File.Permissions.fromMode(0o600);
}

const DiskProfile = struct {
    key: []const u8,
    head: []const u8,
};

const DiskState = struct {
    schema_version: u32,
    sequence: u64,
    profiles: []const DiskProfile,
};

pub const ExpectedHead = union(enum) {
    missing,
    revision: Revision,
};

pub const Mutation = union(enum) {
    compare_exchange_head: struct {
        key: []const u8,
        expected: ExpectedHead,
        next: Revision,
    },
};

pub const CommitReceipt = struct {
    sequence: u64,
    head: Revision,
};

pub const CommitOutcome = union(enum) {
    committed: CommitReceipt,
    conflict: struct { actual: ?Revision },
    durability_uncertain: struct {
        receipt: CommitReceipt,
        cause: anyerror,
    },
};

const FaultPoint = enum {
    create,
    write,
    file_sync,
    replace,
    parent_open,
    parent_sync,
};

pub const Authority = struct {
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    fault: ?FaultPoint = null,

    pub fn init(allocator: std.mem.Allocator, dir: std.Io.Dir) Authority {
        return .{ .allocator = allocator, .dir = dir };
    }

    fn initWithFault(allocator: std.mem.Allocator, dir: std.Io.Dir, fault: FaultPoint) Authority {
        return .{ .allocator = allocator, .dir = dir, .fault = fault };
    }

    fn maybeFail(self: Authority, point: FaultPoint) !void {
        if (self.fault == point) return error.InjectedFailure;
    }

    pub fn observe(self: Authority) !Snapshot {
        const lock = try self.acquireLock();
        defer lock.close(compat.io());
        return self.loadUnlocked();
    }

    pub fn commit(self: Authority, mutation: Mutation) !CommitOutcome {
        const lock = try self.acquireLock();
        defer lock.close(compat.io());

        var snapshot = try self.loadUnlocked();
        defer snapshot.deinit();

        const change = switch (mutation) {
            .compare_exchange_head => |change| change,
        };
        if (change.key.len == 0) return error.InvalidKey;

        const actual = snapshot.head(change.key);
        const matches = switch (change.expected) {
            .missing => actual == null,
            .revision => |expected| actual != null and actual.?.eql(expected),
        };
        if (!matches) return .{ .conflict = .{ .actual = actual } };

        if (snapshot.profiles.getPtr(change.key)) |head| {
            head.* = change.next;
        } else {
            const key = try self.allocator.dupe(u8, change.key);
            errdefer self.allocator.free(key);
            try snapshot.profiles.put(key, change.next);
        }
        snapshot.sequence = std.math.add(u64, snapshot.sequence, 1) catch return error.SequenceOverflow;

        const receipt: CommitReceipt = .{
            .sequence = snapshot.sequence,
            .head = change.next,
        };
        if (try self.writeUnlocked(&snapshot)) |sync_error| {
            return .{ .durability_uncertain = .{
                .receipt = receipt,
                .cause = sync_error,
            } };
        }
        return .{ .committed = receipt };
    }

    fn acquireLock(self: Authority) !std.Io.File {
        // Keep a stable inode for advisory locking. Creation uses an exclusive
        // no-lock step so concurrent first writers cannot lock different files.
        while (true) {
            const lock = self.dir.openFile(compat.io(), lock_file_name, .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
                .lock = .exclusive,
            }) catch |err| switch (err) {
                error.FileNotFound => {
                    const created = self.dir.createFile(compat.io(), lock_file_name, .{
                        .read = true,
                        .truncate = false,
                        .exclusive = true,
                        .permissions = ownerOnlyPermissions(),
                    }) catch |create_err| switch (create_err) {
                        error.PathAlreadyExists => continue,
                        else => return create_err,
                    };
                    created.close(compat.io());
                    continue;
                },
                error.SymLinkLoop, error.IsDir => return error.InvalidLockFile,
                else => return err,
            };
            errdefer lock.close(compat.io());
            const stat = try lock.stat(compat.io());
            if (stat.kind != .file) return error.InvalidLockFile;
            try lock.setPermissions(compat.io(), ownerOnlyPermissions());
            return lock;
        }
    }

    fn loadUnlocked(self: Authority) !Snapshot {
        const path_handle = self.dir.openFile(compat.io(), state_file_name, .{
            .path_only = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return Snapshot.init(self.allocator),
            error.SymLinkLoop, error.IsDir => return error.CorruptState,
            else => return err,
        };
        defer path_handle.close(compat.io());
        const path_stat = try path_handle.stat(compat.io());
        if (path_stat.kind != .file) return error.CorruptState;

        const file = self.dir.openFile(compat.io(), state_file_name, .{
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound, error.SymLinkLoop, error.IsDir => return error.CorruptState,
            else => return err,
        };
        defer file.close(compat.io());
        const file_stat = try file.stat(compat.io());
        if (file_stat.kind != .file or file_stat.inode != path_stat.inode) return error.CorruptState;

        const content = try compat.fileReadBoundedAlloc(file, self.allocator, max_state_bytes);
        defer self.allocator.free(content);

        var parsed = std.json.parseFromSlice(DiskState, self.allocator, content, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.CorruptState,
        };
        defer parsed.deinit();
        const disk = parsed.value;
        if (disk.schema_version != 1) return error.CorruptState;

        var snapshot = Snapshot.init(self.allocator);
        errdefer snapshot.deinit();
        snapshot.sequence = disk.sequence;
        for (disk.profiles) |profile| {
            if (profile.key.len == 0 or snapshot.profiles.contains(profile.key)) return error.CorruptState;
            const revision = Revision.parseHex(profile.head) catch return error.CorruptState;
            const key = try self.allocator.dupe(u8, profile.key);
            errdefer self.allocator.free(key);
            try snapshot.profiles.put(key, revision);
        }
        return snapshot;
    }

    fn writeUnlocked(self: Authority, snapshot: *const Snapshot) !?anyerror {
        const bytes = try encodeSnapshot(self.allocator, snapshot);
        defer self.allocator.free(bytes);
        if (bytes.len > max_state_bytes) return error.FileTooLarge;

        try self.maybeFail(.create);
        var atomic = try self.dir.createFileAtomic(compat.io(), state_file_name, .{
            .replace = true,
            .permissions = ownerOnlyPermissions(),
        });
        defer atomic.deinit(compat.io());
        try self.maybeFail(.write);
        try compat.fileWriteAll(atomic.file, bytes);
        try self.maybeFail(.file_sync);
        try atomic.file.sync(compat.io());
        try self.maybeFail(.parent_open);
        const dir_file = try self.dir.openFile(compat.io(), ".", .{ .allow_directory = true });
        defer dir_file.close(compat.io());

        try self.maybeFail(.replace);
        try atomic.replace(compat.io());

        self.maybeFail(.parent_sync) catch |err| return @as(?anyerror, err);
        dir_file.sync(compat.io()) catch |err| return @as(?anyerror, err);
        return null;
    }
};

fn encodeSnapshot(allocator: std.mem.Allocator, snapshot: *const Snapshot) ![]u8 {
    const keys = try allocator.alloc([]const u8, snapshot.profiles.count());
    defer allocator.free(keys);
    var key_index: usize = 0;
    var profile_it = snapshot.profiles.iterator();
    while (profile_it.next()) |entry| : (key_index += 1) keys[key_index] = entry.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    const EncodedProfile = struct {
        key: []const u8,
        head: []const u8,
    };
    const profiles = try allocator.alloc(EncodedProfile, keys.len);
    defer allocator.free(profiles);
    const heads = try allocator.alloc([32]u8, keys.len);
    defer allocator.free(heads);
    for (keys, profiles, heads) |key, *profile, *head| {
        const revision = snapshot.profiles.get(key).?;
        profile.* = .{ .key = key, .head = revision.formatHex(head) };
    }

    const Output = struct {
        schema_version: u32 = 1,
        sequence: u64,
        profiles: []const EncodedProfile,
    };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(Output{
        .sequence = snapshot.sequence,
        .profiles = profiles,
    }, .{}, &writer.writer);
    try writer.writer.writeByte('\n');
    return allocator.dupe(u8, writer.written());
}

test "StateAuthority revision round trips a fixed 32 character hex identity" {
    const text = "00112233445566778899aabbccddeeff";
    const revision = try Revision.parseHex(text);
    var encoded: [32]u8 = undefined;
    try std.testing.expectEqualStrings(text, revision.formatHex(&encoded));
}

test "StateAuthority revision rejects malformed identities" {
    try std.testing.expectError(error.InvalidRevision, Revision.parseHex("0011"));
    try std.testing.expectError(error.InvalidRevision, Revision.parseHex("00112233445566778899aabbccddeefg"));
}

test "StateAuthority observes a missing catalog as empty and decodes a canonical catalog" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const authority = Authority.init(std.testing.allocator, tmp.dir);
    {
        var empty = try authority.observe();
        defer empty.deinit();
        try std.testing.expectEqual(@as(u64, 0), empty.sequence);
        try std.testing.expectEqual(@as(usize, 0), empty.profiles.count());
    }

    const json =
        \\{"schema_version":1,"sequence":7,"profiles":[{"key":"home","head":"00112233445566778899aabbccddeeff"}]}
    ;
    {
        const file = try tmp.dir.createFile(compat.io(), "state-v2.json", .{});
        defer file.close(compat.io());
        try compat.fileWriteAll(file, json);
    }

    var snapshot = try authority.observe();
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 7), snapshot.sequence);
    const head = snapshot.head("home") orelse return error.TestExpectedEqual;
    var encoded: [32]u8 = undefined;
    try std.testing.expectEqualStrings("00112233445566778899aabbccddeeff", head.formatHex(&encoded));
}

test "StateAuthority compare-and-swap commits one head and reports stale conflicts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const authority = Authority.init(std.testing.allocator, tmp.dir);

    const revision_a = try Revision.parseHex("00112233445566778899aabbccddeeff");
    const revision_b = try Revision.parseHex("ffeeddccbbaa99887766554433221100");

    const first = try authority.commit(.{ .compare_exchange_head = .{
        .key = "home",
        .expected = .missing,
        .next = revision_a,
    } });
    switch (first) {
        .committed => |receipt| try std.testing.expectEqual(@as(u64, 1), receipt.sequence),
        else => return error.TestExpectedEqual,
    }

    const second = try authority.commit(.{ .compare_exchange_head = .{
        .key = "home",
        .expected = .{ .revision = revision_a },
        .next = revision_b,
    } });
    switch (second) {
        .committed => |receipt| try std.testing.expectEqual(@as(u64, 2), receipt.sequence),
        else => return error.TestExpectedEqual,
    }

    const stale = try authority.commit(.{ .compare_exchange_head = .{
        .key = "home",
        .expected = .{ .revision = revision_a },
        .next = revision_a,
    } });
    switch (stale) {
        .conflict => |conflict| {
            const actual = conflict.actual orelse return error.TestExpectedEqual;
            try std.testing.expect(actual.eql(revision_b));
        },
        else => return error.TestExpectedEqual,
    }

    var snapshot = try authority.observe();
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 2), snapshot.sequence);
    try std.testing.expect(snapshot.head("home").?.eql(revision_b));
}

test "StateAuthority writes a deterministic canonical catalog and conflicts do not rewrite it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const authority = Authority.init(std.testing.allocator, tmp.dir);
    const revision_a = try Revision.parseHex("00112233445566778899aabbccddeeff");
    const revision_b = try Revision.parseHex("ffeeddccbbaa99887766554433221100");

    _ = try authority.commit(.{ .compare_exchange_head = .{
        .key = "b",
        .expected = .missing,
        .next = revision_b,
    } });
    _ = try authority.commit(.{ .compare_exchange_head = .{
        .key = "a",
        .expected = .missing,
        .next = revision_a,
    } });

    const expected =
        \\{"schema_version":1,"sequence":2,"profiles":[{"key":"a","head":"00112233445566778899aabbccddeeff"},{"key":"b","head":"ffeeddccbbaa99887766554433221100"}]}
        \\
    ;
    const before = try tmp.dir.readFileAlloc(compat.io(), state_file_name, std.testing.allocator, .limited(max_state_bytes));
    defer std.testing.allocator.free(before);
    try std.testing.expectEqualStrings(expected, before);

    const conflict = try authority.commit(.{ .compare_exchange_head = .{
        .key = "a",
        .expected = .missing,
        .next = revision_b,
    } });
    try std.testing.expect(conflict == .conflict);

    const after = try tmp.dir.readFileAlloc(compat.io(), state_file_name, std.testing.allocator, .limited(max_state_bytes));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "StateAuthority canonical encoding can reach the exact read limit" {
    const revision = try Revision.parseHex("00112233445566778899aabbccddeeff");
    var probe = Snapshot.init(std.testing.allocator);
    defer probe.deinit();
    const probe_key = try std.testing.allocator.dupe(u8, "x");
    try probe.profiles.put(probe_key, revision);
    const probe_bytes = try encodeSnapshot(std.testing.allocator, &probe);
    defer std.testing.allocator.free(probe_bytes);

    const fixed_bytes = probe_bytes.len - probe_key.len;
    const exact_key = try std.testing.allocator.alloc(u8, max_state_bytes - fixed_bytes);
    @memset(exact_key, 'a');
    var exact = Snapshot.init(std.testing.allocator);
    defer exact.deinit();
    try exact.profiles.put(exact_key, revision);
    const exact_bytes = try encodeSnapshot(std.testing.allocator, &exact);
    defer std.testing.allocator.free(exact_bytes);
    try std.testing.expectEqual(max_state_bytes, exact_bytes.len);
}

test "StateAuthority rejects an encoded catalog above its own read limit before replace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const authority = Authority.init(std.testing.allocator, tmp.dir);
    const revision = try Revision.parseHex("00112233445566778899aabbccddeeff");
    const huge_key = try std.testing.allocator.alloc(u8, max_state_bytes);
    defer std.testing.allocator.free(huge_key);
    @memset(huge_key, 'a');

    try std.testing.expectError(error.FileTooLarge, authority.commit(.{ .compare_exchange_head = .{
        .key = huge_key,
        .expected = .missing,
        .next = revision,
    } }));

    var snapshot = try authority.observe();
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 0), snapshot.sequence);
    try std.testing.expectEqual(@as(usize, 0), snapshot.profiles.count());
}

test "StateAuthority rejects oversized state without parsing a prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const file = try tmp.dir.createFile(compat.io(), state_file_name, .{});
        defer file.close(compat.io());
        try file.setLength(compat.io(), max_state_bytes + 1);
    }
    const authority = Authority.init(std.testing.allocator, tmp.dir);
    try std.testing.expectError(error.FileTooLarge, authority.observe());
}

test "StateAuthority rejects state symlinks and special paths" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.symLink(compat.io(), "missing-target", state_file_name, .{});
        const authority = Authority.init(std.testing.allocator, tmp.dir);
        try std.testing.expectError(error.CorruptState, authority.observe());
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmp.dir.createFile(compat.io(), "target", .{});
        target.close(compat.io());
        try tmp.dir.symLink(compat.io(), "target", state_file_name, .{});
        const authority = Authority.init(std.testing.allocator, tmp.dir);
        try std.testing.expectError(error.CorruptState, authority.observe());
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try tmp.dir.createDir(compat.io(), state_file_name, .default_dir);
        const authority = Authority.init(std.testing.allocator, tmp.dir);
        try std.testing.expectError(error.CorruptState, authority.observe());
    }
}

test "StateAuthority rejects dangling and live lock symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.symLink(compat.io(), "missing-target", lock_file_name, .{});
        const authority = Authority.init(std.testing.allocator, tmp.dir);
        try std.testing.expectError(error.InvalidLockFile, authority.observe());
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target = try tmp.dir.createFile(compat.io(), "target", .{});
        target.close(compat.io());
        try tmp.dir.symLink(compat.io(), "target", lock_file_name, .{});
        const authority = Authority.init(std.testing.allocator, tmp.dir);
        try std.testing.expectError(error.InvalidLockFile, authority.observe());
    }
}

test "StateAuthority creates lock and replacement state with owner-only permissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const authority = Authority.init(std.testing.allocator, tmp.dir);
    const revision_a = try Revision.parseHex("00112233445566778899aabbccddeeff");
    const revision_b = try Revision.parseHex("ffeeddccbbaa99887766554433221100");
    _ = try authority.commit(.{ .compare_exchange_head = .{
        .key = "home",
        .expected = .missing,
        .next = revision_a,
    } });
    _ = try authority.commit(.{ .compare_exchange_head = .{
        .key = "home",
        .expected = .{ .revision = revision_a },
        .next = revision_b,
    } });

    const lock = try tmp.dir.openFile(compat.io(), lock_file_name, .{});
    defer lock.close(compat.io());
    const state_file = try tmp.dir.openFile(compat.io(), state_file_name, .{});
    defer state_file.close(compat.io());
    const lock_stat = try lock.stat(compat.io());
    const state_stat = try state_file.stat(compat.io());
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), lock_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), state_stat.permissions.toMode() & 0o777);
}

test "StateAuthority fault boundaries preserve old state until replace and report uncertain directory sync" {
    const pre_replace_faults = [_]FaultPoint{ .create, .write, .file_sync, .parent_open, .replace };
    for (pre_replace_faults) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const revision_a = try Revision.parseHex("00112233445566778899aabbccddeeff");
        const revision_b = try Revision.parseHex("ffeeddccbbaa99887766554433221100");
        const authority = Authority.init(std.testing.allocator, tmp.dir);
        _ = try authority.commit(.{ .compare_exchange_head = .{
            .key = "home",
            .expected = .missing,
            .next = revision_a,
        } });

        const faulty = Authority.initWithFault(std.testing.allocator, tmp.dir, fault);
        try std.testing.expectError(error.InjectedFailure, faulty.commit(.{ .compare_exchange_head = .{
            .key = "home",
            .expected = .{ .revision = revision_a },
            .next = revision_b,
        } }));

        var reopened = try authority.observe();
        defer reopened.deinit();
        try std.testing.expectEqual(@as(u64, 1), reopened.sequence);
        try std.testing.expect(reopened.head("home").?.eql(revision_a));
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const revision_a = try Revision.parseHex("00112233445566778899aabbccddeeff");
    const revision_b = try Revision.parseHex("ffeeddccbbaa99887766554433221100");
    const authority = Authority.init(std.testing.allocator, tmp.dir);
    _ = try authority.commit(.{ .compare_exchange_head = .{
        .key = "home",
        .expected = .missing,
        .next = revision_a,
    } });

    const faulty = Authority.initWithFault(std.testing.allocator, tmp.dir, .parent_sync);
    const outcome = try faulty.commit(.{ .compare_exchange_head = .{
        .key = "home",
        .expected = .{ .revision = revision_a },
        .next = revision_b,
    } });
    switch (outcome) {
        .durability_uncertain => |uncertain| {
            try std.testing.expectEqual(error.InjectedFailure, uncertain.cause);
            try std.testing.expectEqual(@as(u64, 2), uncertain.receipt.sequence);
        },
        else => return error.TestExpectedEqual,
    }

    var reopened = try authority.observe();
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 2), reopened.sequence);
    try std.testing.expect(reopened.head("home").?.eql(revision_b));
}

test "StateAuthority fails closed for corrupt duplicate and unknown state" {
    const cases = [_][]const u8{
        "",
        "{",
        "{\"schema_version\":2,\"sequence\":0,\"profiles\":[]}",
        "{\"schema_version\":1,\"sequence\":0,\"profiles\":[],\"unknown\":true}",
        "{\"schema_version\":1,\"sequence\":0,\"profiles\":[{\"key\":\"a\",\"head\":\"00112233445566778899aabbccddeeff\"},{\"key\":\"a\",\"head\":\"ffeeddccbbaa99887766554433221100\"}]}",
    };

    for (cases) |json| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            const file = try tmp.dir.createFile(compat.io(), "state-v2.json", .{});
            defer file.close(compat.io());
            try compat.fileWriteAll(file, json);
        }
        const authority = Authority.init(std.testing.allocator, tmp.dir);
        try std.testing.expectError(error.CorruptState, authority.observe());
    }
}
