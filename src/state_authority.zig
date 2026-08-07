const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const catalog_runtime_gate = @import("catalog_runtime_gate.zig");
const config_identity = @import("config_identity.zig");
const config_catalog = @import("config_catalog.zig");
const revision_store = @import("revision_store.zig");

pub const Revision = config_identity.Revision;

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

extern "c" fn mkfifoat(c_int, [*:0]const u8, std.posix.mode_t) c_int;

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

pub const StateFormat = enum {
    missing,
    legacy_v1,
    catalog_v2,
};

pub const StateToken = struct {
    format: StateFormat,
    sequence: u64,
    digest: [32]u8,

    pub fn eql(a: StateToken, b: StateToken) bool {
        return a.format == b.format and a.sequence == b.sequence and
            std.mem.eql(u8, &a.digest, &b.digest);
    }
};

pub const LegacyObservation = struct {
    token: StateToken,
    snapshot: Snapshot,
};

pub const CatalogObservation = struct {
    token: StateToken,
    catalog: config_catalog.Catalog,
};

pub const Inspection = union(enum) {
    missing: StateToken,
    legacy_v1: LegacyObservation,
    catalog_v2: CatalogObservation,

    pub fn token(self: *const Inspection) StateToken {
        return switch (self.*) {
            .missing => |value| value,
            .legacy_v1 => |value| value.token,
            .catalog_v2 => |value| value.token,
        };
    }

    pub fn deinit(self: *Inspection) void {
        switch (self.*) {
            .missing => {},
            .legacy_v1 => |*value| value.snapshot.deinit(),
            .catalog_v2 => |*value| value.catalog.deinit(),
        }
        self.* = undefined;
    }
};

pub const CatalogSeed = struct {
    active: ?config_catalog.ActiveIdentity = null,
    profiles: []const config_catalog.Profile = &.{},
};

pub const BootstrapReceipt = struct {
    token: StateToken,
};

pub const BootstrapOutcome = union(enum) {
    committed: BootstrapReceipt,
    conflict: struct { actual: StateToken },
    durability_uncertain: struct {
        receipt: BootstrapReceipt,
        cause: anyerror,
    },
};

pub const ExpectedHead = union(enum) {
    missing,
    revision: Revision,
};

pub const ProfileDesired = union(enum) {
    preserve,
    clear,
    replace: []const config_catalog.Selection,
};

pub const CatalogPutPreflight = struct {
    key: []const u8,
    expected: ExpectedHead,
    desired: ProfileDesired,
    activate: bool = false,
};

pub const CatalogPutIntent = struct {
    creates_active_identity: bool,
};

pub const CatalogPutPreflightOutcome = union(enum) {
    accepted: CatalogPutIntent,
    conflict: struct { actual: StateToken },
};

pub const CatalogPutChange = struct {
    key: []const u8,
    expected: ExpectedHead,
    head: Revision,
    desired: ProfileDesired,
    activate: bool = false,
};

pub const CatalogMutation = union(enum) {
    put_profile: CatalogPutChange,
    set_active: struct { key: ?[]const u8 },
    delete_profile: struct {
        key: []const u8,
        expected: Revision,
    },
    set_desired: struct {
        identity: config_identity.ManagedIdentity,
        expected_generation: u64,
        selections: []const config_catalog.Selection,
    },
};

pub const CatalogMutationReceipt = struct { token: StateToken };
pub const CatalogMutationOutcome = union(enum) {
    committed: CatalogMutationReceipt,
    conflict: struct { actual: StateToken },
    durability_uncertain: struct {
        receipt: CatalogMutationReceipt,
        cause: anyerror,
    },
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

    pub fn inspect(self: Authority) !Inspection {
        const lock = try self.acquireLock();
        defer lock.close(compat.io());
        return self.inspectUnlocked();
    }

    pub const Guard = struct {
        authority: Authority,
        lock: std.Io.File,

        pub fn inspect(self: Guard) !Inspection {
            return self.authority.inspectUnlocked();
        }

        /// Performs every deterministic catalog-side check that can precede
        /// immutable publication while retaining the authority lock.
        pub fn preflightCatalogPut(
            self: Guard,
            expected: StateToken,
            request: CatalogPutPreflight,
        ) !CatalogPutPreflightOutcome {
            return self.authority.preflightCatalogPutUnlocked(expected, request);
        }

        /// Commits through the same authoritative final gate used by the
        /// ordinary mutation API without recursively acquiring the lock.
        pub fn mutateCatalog(
            self: Guard,
            expected: StateToken,
            mutation: CatalogMutation,
        ) !CatalogMutationOutcome {
            return self.authority.mutateCatalogUnlocked(expected, mutation);
        }

        pub fn deinit(self: *Guard) void {
            self.lock.close(compat.io());
            self.* = undefined;
        }
    };

    pub fn acquireGuard(self: Authority) !Guard {
        return .{
            .authority = self,
            .lock = try self.acquireLock(),
        };
    }

    pub fn bootstrapCatalog(
        self: Authority,
        expected: StateToken,
        seed: CatalogSeed,
    ) !BootstrapOutcome {
        const lock = try self.acquireLock();
        defer lock.close(compat.io());

        var current = try self.inspectUnlocked();
        defer current.deinit();
        const actual = current.token();
        if (!actual.eql(expected)) return .{ .conflict = .{ .actual = actual } };
        switch (current) {
            .catalog_v2 => return .{ .conflict = .{ .actual = actual } },
            .legacy_v1 => |*legacy| {
                if (!legacyMatchesSeed(&legacy.snapshot, seed.profiles)) {
                    return error.LegacyProofMismatch;
                }
            },
            .missing => {},
        }
        if (seed.active) |active| {
            const index = findCatalogProfile(seed.profiles, active.key) orelse
                return error.InvalidCatalog;
            if (!seed.profiles[index].head.eql(active.revision)) {
                return error.InvalidCatalog;
            }
            try catalog_runtime_gate.ensureIdentityRuntimeReady(
                self.allocator,
                self.dir,
                active.key,
                active.revision,
            );
        }

        const sequence = std.math.add(u64, actual.sequence, 1) catch
            return error.SequenceOverflow;
        const bytes = try config_catalog.encodeCanonical(self.allocator, .{
            .sequence = sequence,
            .active = seed.active,
            .profiles = seed.profiles,
        });
        defer self.allocator.free(bytes);
        const receipt: BootstrapReceipt = .{ .token = .{
            .format = .catalog_v2,
            .sequence = sequence,
            .digest = computeStateDigest(bytes),
        } };
        if (try self.writeBytesUnlocked(bytes)) |sync_error| {
            return .{ .durability_uncertain = .{
                .receipt = receipt,
                .cause = sync_error,
            } };
        }
        return .{ .committed = receipt };
    }

    pub fn mutateCatalog(
        self: Authority,
        expected: StateToken,
        mutation: CatalogMutation,
    ) !CatalogMutationOutcome {
        const lock = try self.acquireLock();
        defer lock.close(compat.io());
        return self.mutateCatalogUnlocked(expected, mutation);
    }

    fn preflightCatalogPutUnlocked(
        self: Authority,
        expected: StateToken,
        request: CatalogPutPreflight,
    ) !CatalogPutPreflightOutcome {
        var current = try self.inspectUnlocked();
        defer current.deinit();
        const actual = current.token();
        if (!actual.eql(expected)) return .{ .conflict = .{ .actual = actual } };
        const state = switch (current) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        // Preserve RevisionStore's direct Service error for an empty key while
        // moving that deterministic rejection ahead of publication.
        if (request.key.len == 0) return error.InvalidKey;
        const next_sequence = std.math.add(u64, state.sequence, 1) catch
            return error.SequenceOverflow;
        const creates_active_identity = putCreatesActiveIdentity(
            state,
            request.key,
            request.activate,
        );

        // The revision encoding is fixed-width, so a placeholder can validate
        // the complete prospective catalog (including desired selections and
        // the persisted size bound) before the immutable identity exists.
        const placeholder: Revision = .{ .bytes = @splat(0) };
        var edit = try applyCatalogPut(
            self.allocator,
            self.dir,
            state,
            .{
                .key = request.key,
                .expected = request.expected,
                .head = placeholder,
                .desired = request.desired,
                .activate = request.activate,
            },
            false,
        );
        defer edit.deinit(self.allocator);
        edit.state.sequence = next_sequence;
        const bytes = try config_catalog.encodeCanonical(self.allocator, edit.state);
        self.allocator.free(bytes);
        return .{ .accepted = .{
            .creates_active_identity = creates_active_identity,
        } };
    }

    fn mutateCatalogUnlocked(
        self: Authority,
        expected: StateToken,
        mutation: CatalogMutation,
    ) !CatalogMutationOutcome {
        var current = try self.inspectUnlocked();
        defer current.deinit();
        const actual = current.token();
        if (!actual.eql(expected)) return .{ .conflict = .{ .actual = actual } };
        const state = switch (current) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        const next_sequence = std.math.add(u64, state.sequence, 1) catch
            return error.SequenceOverflow;
        const creates_active_identity = switch (mutation) {
            .put_profile => |change| putCreatesActiveIdentity(
                state,
                change.key,
                change.activate,
            ),
            .set_active => |change| change.key != null,
            .delete_profile, .set_desired => false,
        };
        var edit = try applyCatalogMutation(self.allocator, self.dir, state, mutation);
        defer edit.deinit(self.allocator);
        if (creates_active_identity) {
            const active = edit.state.active orelse return error.InvalidCatalog;
            try catalog_runtime_gate.ensureIdentityRuntimeReady(
                self.allocator,
                self.dir,
                active.key,
                active.revision,
            );
        }
        edit.state.sequence = next_sequence;
        const bytes = try config_catalog.encodeCanonical(self.allocator, edit.state);
        defer self.allocator.free(bytes);
        const receipt: CatalogMutationReceipt = .{ .token = .{
            .format = .catalog_v2,
            .sequence = next_sequence,
            .digest = computeStateDigest(bytes),
        } };
        if (try self.writeBytesUnlocked(bytes)) |sync_error| {
            return .{ .durability_uncertain = .{
                .receipt = receipt,
                .cause = sync_error,
            } };
        }
        return .{ .committed = receipt };
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

    fn inspectUnlocked(self: Authority) !Inspection {
        const content = try self.readStateBytesUnlocked() orelse return .{
            .missing = .{
                .format = .missing,
                .sequence = 0,
                .digest = computeMissingDigest(),
            },
        };
        defer self.allocator.free(content);
        const schema_version = detectSchemaVersion(self.allocator, content) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.CorruptState,
        };
        const digest = computeStateDigest(content);
        return switch (schema_version) {
            1 => blk: {
                var snapshot = try parseLegacySnapshot(self.allocator, content);
                errdefer snapshot.deinit();
                break :blk .{ .legacy_v1 = .{
                    .token = .{
                        .format = .legacy_v1,
                        .sequence = snapshot.sequence,
                        .digest = digest,
                    },
                    .snapshot = snapshot,
                } };
            },
            2 => blk: {
                var catalog = config_catalog.decodeCanonical(self.allocator, content) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return error.CorruptState,
                };
                errdefer catalog.deinit();
                break :blk .{ .catalog_v2 = .{
                    .token = .{
                        .format = .catalog_v2,
                        .sequence = catalog.state.sequence,
                        .digest = digest,
                    },
                    .catalog = catalog,
                } };
            },
            else => error.CorruptState,
        };
    }

    fn loadUnlocked(self: Authority) !Snapshot {
        const content = try self.readStateBytesUnlocked() orelse return Snapshot.init(self.allocator);
        defer self.allocator.free(content);
        const schema_version = detectSchemaVersion(self.allocator, content) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.CorruptState,
        };
        if (schema_version == 2) {
            var catalog = config_catalog.decodeCanonical(self.allocator, content) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.CorruptState,
            };
            catalog.deinit();
            return error.Schema2RequiresTypedMutation;
        }
        if (schema_version != 1) return error.CorruptState;
        return parseLegacySnapshot(self.allocator, content);
    }

    fn readStateBytesUnlocked(self: Authority) !?[]u8 {
        const file = self.openStateFile() catch |err| switch (err) {
            error.FileNotFound => return null,
            error.SymLinkLoop, error.IsDir, error.InvalidStateFile => return error.CorruptState,
            else => return err,
        };
        defer file.close(compat.io());
        return @as(?[]u8, try compat.fileReadBoundedAlloc(file, self.allocator, max_state_bytes));
    }

    fn openStateFile(self: Authority) !std.Io.File {
        if (builtin.os.tag == .windows) {
            const file = try self.dir.openFile(compat.io(), state_file_name, .{
                .allow_directory = false,
                .follow_symlinks = false,
            });
            errdefer file.close(compat.io());
            const stat = try file.stat(compat.io());
            if (stat.kind != .file) return error.InvalidStateFile;
            return file;
        }

        const fd = try std.posix.openat(self.dir.handle, state_file_name, .{
            .ACCMODE = .RDONLY,
            .NONBLOCK = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0);
        const file: std.Io.File = .{
            .handle = fd,
            .flags = .{ .nonblocking = true },
        };
        errdefer file.close(compat.io());
        const stat = try file.stat(compat.io());
        if (stat.kind != .file) return error.InvalidStateFile;
        return file;
    }

    fn writeUnlocked(self: Authority, snapshot: *const Snapshot) !?anyerror {
        const bytes = try encodeSnapshot(self.allocator, snapshot);
        defer self.allocator.free(bytes);
        return self.writeBytesUnlocked(bytes);
    }

    fn writeBytesUnlocked(self: Authority, bytes: []const u8) !?anyerror {
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

const CatalogEdit = struct {
    state: config_catalog.State,
    profiles: []config_catalog.Profile,

    fn deinit(self: *CatalogEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.profiles);
        self.* = undefined;
    }
};

fn putCreatesActiveIdentity(
    state: config_catalog.State,
    key: []const u8,
    activate: bool,
) bool {
    if (activate) return true;
    const active = state.active orelse return false;
    return std.mem.eql(u8, active.key, key);
}

fn applyCatalogPut(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    current: config_catalog.State,
    change: CatalogPutChange,
    verify_revision: bool,
) !CatalogEdit {
    if (!config_catalog.isManagedKey(change.key)) return error.InvalidCatalog;
    const index = findCatalogProfile(current.profiles, change.key);
    const actual = if (index) |value| current.profiles[value].head else null;
    const matches = switch (change.expected) {
        .missing => actual == null,
        .revision => |expected| actual != null and actual.?.eql(expected),
    };
    if (!matches) return error.ProfileIdentityConflict;
    if (verify_revision) {
        var verified = try revision_store.RevisionStore.init(
            allocator,
            root,
        ).openVerified(change.key, change.head);
        defer verified.deinit();
    }
    const previous_desired: config_catalog.Desired = if (index) |value|
        current.profiles[value].desired
    else
        .{};
    const desired = try updateProfileDesired(previous_desired, index != null, change.desired);
    const next: config_catalog.Profile = .{
        .key = change.key,
        .storage_id = config_identity.StorageId.derive(change.key),
        .head = change.head,
        .desired = desired,
    };
    const new_len = if (index == null) current.profiles.len + 1 else current.profiles.len;
    const profiles = try allocator.alloc(config_catalog.Profile, new_len);
    errdefer allocator.free(profiles);
    @memcpy(profiles[0..current.profiles.len], current.profiles);
    if (index) |value| profiles[value] = next else profiles[current.profiles.len] = next;
    var active = current.active;
    if (change.activate) {
        active = .{ .key = next.key, .revision = next.head };
    } else if (active) |value| {
        if (std.mem.eql(u8, value.key, next.key)) {
            active = .{ .key = next.key, .revision = next.head };
        }
    }
    return .{
        .state = .{ .sequence = current.sequence, .active = active, .profiles = profiles },
        .profiles = profiles,
    };
}

fn applyCatalogMutation(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    current: config_catalog.State,
    mutation: CatalogMutation,
) !CatalogEdit {
    const store = revision_store.RevisionStore.init(allocator, root);
    return switch (mutation) {
        .put_profile => |change| applyCatalogPut(
            allocator,
            root,
            current,
            change,
            true,
        ),
        .set_active => |change| blk: {
            const profiles = try allocator.dupe(config_catalog.Profile, current.profiles);
            errdefer allocator.free(profiles);
            const active: ?config_catalog.ActiveIdentity = if (change.key) |key| active_blk: {
                const index = findCatalogProfile(current.profiles, key) orelse return error.ProfileNotFound;
                const profile = current.profiles[index];
                var verified = try store.openVerified(profile.key, profile.head);
                defer verified.deinit();
                break :active_blk .{ .key = profile.key, .revision = profile.head };
            } else null;
            break :blk .{
                .state = .{ .sequence = current.sequence, .active = active, .profiles = profiles },
                .profiles = profiles,
            };
        },
        .delete_profile => |change| blk: {
            const index = findCatalogProfile(current.profiles, change.key) orelse
                return error.ProfileNotFound;
            if (!current.profiles[index].head.eql(change.expected)) {
                return error.ProfileIdentityConflict;
            }
            const profiles = try allocator.alloc(config_catalog.Profile, current.profiles.len - 1);
            errdefer allocator.free(profiles);
            @memcpy(profiles[0..index], current.profiles[0..index]);
            @memcpy(profiles[index..], current.profiles[index + 1 ..]);
            var active = current.active;
            if (active) |value| {
                if (std.mem.eql(u8, value.key, change.key)) active = null;
            }
            break :blk .{
                .state = .{ .sequence = current.sequence, .active = active, .profiles = profiles },
                .profiles = profiles,
            };
        },
        .set_desired => |change| blk: {
            const index = findCatalogProfile(current.profiles, change.identity.key) orelse
                return error.ProfileNotFound;
            const current_profile = current.profiles[index];
            if (!current_profile.head.eql(change.identity.revision)) {
                return error.ProfileIdentityConflict;
            }
            if (current_profile.desired.generation != change.expected_generation) {
                return error.DesiredGenerationConflict;
            }
            const generation = std.math.add(u64, change.expected_generation, 1) catch
                return error.GenerationOverflow;
            var verified = try store.openVerified(current_profile.key, current_profile.head);
            defer verified.deinit();
            const profiles = try allocator.dupe(config_catalog.Profile, current.profiles);
            errdefer allocator.free(profiles);
            profiles[index].desired = .{ .generation = generation, .selections = change.selections };
            break :blk .{
                .state = .{
                    .sequence = current.sequence,
                    .active = current.active,
                    .profiles = profiles,
                },
                .profiles = profiles,
            };
        },
    };
}

fn updateProfileDesired(
    previous: config_catalog.Desired,
    existed: bool,
    policy: ProfileDesired,
) !config_catalog.Desired {
    const selections: []const config_catalog.Selection = switch (policy) {
        .preserve => previous.selections,
        .clear => &.{},
        .replace => |value| value,
    };
    if (!existed) return .{
        .generation = if (selections.len == 0) 0 else 1,
        .selections = selections,
    };
    if (sameSelections(previous.selections, selections)) return previous;
    return .{
        .generation = std.math.add(u64, previous.generation, 1) catch
            return error.GenerationOverflow,
        .selections = selections,
    };
}

fn sameSelections(
    previous: []const config_catalog.Selection,
    next: []const config_catalog.Selection,
) bool {
    if (previous.len != next.len) return false;
    for (previous) |old| {
        var found = false;
        for (next) |candidate| {
            if (std.mem.eql(u8, old.group, candidate.group) and
                std.mem.eql(u8, old.proxy, candidate.proxy))
            {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn findCatalogProfile(profiles: []const config_catalog.Profile, key: []const u8) ?usize {
    for (profiles, 0..) |profile, index| {
        if (std.mem.eql(u8, profile.key, key)) return index;
    }
    return null;
}

fn detectSchemaVersion(allocator: std.mem.Allocator, bytes: []const u8) !u32 {
    const Header = struct { schema_version: u32 };
    var parsed = try std.json.parseFromSlice(Header, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parsed.value.schema_version;
}

fn parseLegacySnapshot(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    var parsed = std.json.parseFromSlice(DiskState, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.CorruptState,
    };
    defer parsed.deinit();
    const disk = parsed.value;
    if (disk.schema_version != 1) return error.CorruptState;

    var snapshot = Snapshot.init(allocator);
    errdefer snapshot.deinit();
    snapshot.sequence = disk.sequence;
    for (disk.profiles) |profile| {
        if (profile.key.len == 0 or snapshot.profiles.contains(profile.key)) return error.CorruptState;
        const revision = Revision.parseHex(profile.head) catch return error.CorruptState;
        const key = try allocator.dupe(u8, profile.key);
        errdefer allocator.free(key);
        try snapshot.profiles.put(key, revision);
    }
    return snapshot;
}

fn legacyMatchesSeed(snapshot: *const Snapshot, profiles: []const config_catalog.Profile) bool {
    if (snapshot.profiles.count() != profiles.len) return false;
    for (profiles) |profile| {
        const head = snapshot.head(profile.key) orelse return false;
        if (!head.eql(profile.head)) return false;
    }
    return true;
}

fn computeMissingDigest() [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("zc.state.missing.v1", &digest, .{});
    return digest;
}

fn computeStateDigest(bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("zc.state-token.v1");
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
    hasher.update(&length);
    hasher.update(bytes);
    return hasher.finalResult();
}

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
    return encodeJsonLine(allocator, Output{
        .sequence = snapshot.sequence,
        .profiles = profiles,
    });
}

fn encodeJsonLine(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var count_buffer: [1024]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try std.json.Stringify.value(value, .{}, &counter.writer);
    try counter.writer.writeByte('\n');
    const bytes = try allocator.alloc(u8, @intCast(counter.fullCount()));
    errdefer allocator.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);
    try std.json.Stringify.value(value, .{}, &writer);
    try writer.writeByte('\n');
    std.debug.assert(writer.end == bytes.len);
    return bytes;
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

fn encodeSnapshotAllocationFixture(allocator: std.mem.Allocator) !void {
    const revision = try Revision.parseHex("00112233445566778899aabbccddeeff");
    var snapshot = Snapshot.init(allocator);
    defer snapshot.deinit();
    const key = try allocator.dupe(u8, "home");
    var key_owned = true;
    errdefer if (key_owned) allocator.free(key);
    try snapshot.profiles.put(key, revision);
    key_owned = false;
    const bytes = try encodeSnapshot(allocator, &snapshot);
    allocator.free(bytes);
}

test "StateAuthority preserves every snapshot encoding allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        encodeSnapshotAllocationFixture,
        .{},
    );
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
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        if (mkfifoat(tmp.dir.handle, state_file_name, 0o600) != 0) return error.SkipZigTest;
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

test "StateAuthority bootstraps one exact catalog and rejects legacy mutations afterward" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const authority = Authority.init(std.testing.allocator, tmp.dir);
    var initial = try authority.inspect();
    defer initial.deinit();
    try std.testing.expect(initial == .missing);

    const config_bundle = @import("config_bundle.zig");
    var bundle = try config_bundle.ConfigBundle.captureMemory(
        std.testing.allocator,
        "mixed-port: 7890\n",
        null,
        .{},
    );
    defer bundle.deinit();
    const published = try revision_store.RevisionStore.init(
        std.testing.allocator,
        tmp.dir,
    ).publishMigration("home", &bundle, .{});
    const revision = published.revision;
    const profiles = [_]config_catalog.Profile{.{
        .key = "home",
        .storage_id = config_identity.StorageId.derive("home"),
        .head = revision,
        .desired = .{ .generation = 1, .selections = &.{.{
            .group = "Proxy",
            .proxy = "A",
        }} },
    }};
    const outcome = try authority.bootstrapCatalog(initial.token(), .{
        .active = .{ .key = "home", .revision = revision },
        .profiles = &profiles,
    });
    switch (outcome) {
        .committed => |receipt| {
            try std.testing.expectEqual(StateFormat.catalog_v2, receipt.token.format);
            try std.testing.expectEqual(@as(u64, 1), receipt.token.sequence);
        },
        else => return error.TestExpectedEqual,
    }

    var reopened = try authority.inspect();
    defer reopened.deinit();
    switch (reopened) {
        .catalog_v2 => |*observed| {
            try std.testing.expectEqual(@as(u64, 1), observed.catalog.state.sequence);
            try std.testing.expectEqualStrings("home", observed.catalog.state.active.?.key);
            try std.testing.expectEqual(@as(u64, 1), observed.catalog.state.profiles[0].desired.generation);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectError(error.Schema2RequiresTypedMutation, authority.observe());
    try std.testing.expectError(error.Schema2RequiresTypedMutation, authority.commit(.{
        .compare_exchange_head = .{
            .key = "home",
            .expected = .{ .revision = revision },
            .next = revision,
        },
    }));
}

test "StateAuthority bootstrap token conflicts without rewriting state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const authority = Authority.init(std.testing.allocator, tmp.dir);
    var missing = try authority.inspect();
    defer missing.deinit();
    const revision = try Revision.parseHex("00112233445566778899aabbccddeeff");
    _ = try authority.commit(.{ .compare_exchange_head = .{
        .key = "home",
        .expected = .missing,
        .next = revision,
    } });
    const before = try tmp.dir.readFileAlloc(compat.io(), state_file_name, std.testing.allocator, .limited(max_state_bytes));
    defer std.testing.allocator.free(before);

    const outcome = try authority.bootstrapCatalog(missing.token(), .{});
    switch (outcome) {
        .conflict => |conflict| {
            try std.testing.expectEqual(StateFormat.legacy_v1, conflict.actual.format);
            try std.testing.expectEqual(@as(u64, 1), conflict.actual.sequence);
        },
        else => return error.TestExpectedEqual,
    }
    const after = try tmp.dir.readFileAlloc(compat.io(), state_file_name, std.testing.allocator, .limited(max_state_bytes));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "StateAuthority bootstrap preserves old state across fault boundaries" {
    const pre_replace_faults = [_]FaultPoint{ .create, .write, .file_sync, .parent_open, .replace };
    for (pre_replace_faults) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const authority = Authority.init(std.testing.allocator, tmp.dir);
        var initial = try authority.inspect();
        defer initial.deinit();
        const faulty = Authority.initWithFault(std.testing.allocator, tmp.dir, fault);
        try std.testing.expectError(
            error.InjectedFailure,
            faulty.bootstrapCatalog(initial.token(), .{}),
        );
        var reopened = try authority.inspect();
        defer reopened.deinit();
        try std.testing.expect(reopened == .missing);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const authority = Authority.init(std.testing.allocator, tmp.dir);
    var initial = try authority.inspect();
    defer initial.deinit();
    const faulty = Authority.initWithFault(std.testing.allocator, tmp.dir, .parent_sync);
    const outcome = try faulty.bootstrapCatalog(initial.token(), .{});
    switch (outcome) {
        .durability_uncertain => |uncertain| {
            try std.testing.expectEqual(error.InjectedFailure, uncertain.cause);
            try std.testing.expectEqual(@as(u64, 1), uncertain.receipt.token.sequence);
        },
        else => return error.TestExpectedEqual,
    }
    var reopened = try authority.inspect();
    defer reopened.deinit();
    switch (reopened) {
        .catalog_v2 => |observed| try std.testing.expectEqual(@as(u64, 1), observed.token.sequence),
        else => return error.TestExpectedEqual,
    }
}

test "StateAuthority typed catalog mutation preserves old state across fault boundaries" {
    const pre_replace_faults = [_]FaultPoint{ .create, .write, .file_sync, .parent_open, .replace };
    for (pre_replace_faults) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const authority = Authority.init(std.testing.allocator, tmp.dir);
        var missing = try authority.inspect();
        defer missing.deinit();
        const bootstrapped = try authority.bootstrapCatalog(missing.token(), .{});
        const token = switch (bootstrapped) {
            .committed => |receipt| receipt.token,
            else => return error.TestExpectedEqual,
        };
        const faulty = Authority.initWithFault(std.testing.allocator, tmp.dir, fault);
        try std.testing.expectError(
            error.InjectedFailure,
            faulty.mutateCatalog(token, .{ .set_active = .{ .key = null } }),
        );
        var reopened = try authority.inspect();
        defer reopened.deinit();
        try std.testing.expect(reopened.token().eql(token));
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const authority = Authority.init(std.testing.allocator, tmp.dir);
    var missing = try authority.inspect();
    defer missing.deinit();
    const bootstrapped = try authority.bootstrapCatalog(missing.token(), .{});
    const token = switch (bootstrapped) {
        .committed => |receipt| receipt.token,
        else => return error.TestExpectedEqual,
    };
    const faulty = Authority.initWithFault(std.testing.allocator, tmp.dir, .parent_sync);
    const outcome = try faulty.mutateCatalog(token, .{ .set_active = .{ .key = null } });
    switch (outcome) {
        .durability_uncertain => |uncertain| {
            try std.testing.expectEqual(error.InjectedFailure, uncertain.cause);
            try std.testing.expectEqual(@as(u64, 2), uncertain.receipt.token.sequence);
        },
        else => return error.TestExpectedEqual,
    }
    var reopened = try authority.inspect();
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 2), reopened.token().sequence);
}

test "StateAuthority requires exact proof before upgrading nonempty schema one" {
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
    var observed = try authority.inspect();
    defer observed.deinit();
    const mismatched = [_]config_catalog.Profile{.{
        .key = "home",
        .storage_id = config_identity.StorageId.derive("home"),
        .head = revision_b,
    }};
    try std.testing.expectError(error.LegacyProofMismatch, authority.bootstrapCatalog(observed.token(), .{
        .profiles = &mismatched,
    }));

    const matching = [_]config_catalog.Profile{.{
        .key = "home",
        .storage_id = config_identity.StorageId.derive("home"),
        .head = revision_a,
    }};
    const outcome = try authority.bootstrapCatalog(observed.token(), .{ .profiles = &matching });
    switch (outcome) {
        .committed => |receipt| try std.testing.expectEqual(@as(u64, 2), receipt.token.sequence),
        else => return error.TestExpectedEqual,
    }
}
