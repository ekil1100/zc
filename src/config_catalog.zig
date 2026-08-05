const std = @import("std");
const config_identity = @import("config_identity.zig");

pub const max_catalog_bytes = 4 * 1024 * 1024;
// Persisted catalogs grandfather keys accepted by earlier releases. New keys
// reserve room for the derived legacy mirror's `.yaml` suffix on filesystems
// with the common 255-byte NAME_MAX limit.
pub const max_key_bytes = 255;
pub const max_portable_key_bytes = 250;

pub const Selection = struct {
    group: []const u8,
    proxy: []const u8,
};

pub const Desired = struct {
    generation: u64 = 0,
    selections: []const Selection = &.{},
};

pub const Profile = struct {
    key: []const u8,
    storage_id: config_identity.StorageId,
    head: config_identity.Revision,
    desired: Desired = .{},
};

pub const ActiveIdentity = struct {
    key: []const u8,
    revision: config_identity.Revision,
};

pub const State = struct {
    sequence: u64 = 0,
    active: ?ActiveIdentity = null,
    profiles: []const Profile = &.{},
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    state: State,

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const DiskSelection = struct {
    group: []const u8,
    proxy: []const u8,
};

const DiskDesired = struct {
    generation: u64,
    selections: []const DiskSelection,
};

const DiskProfile = struct {
    key: []const u8,
    storage_id: []const u8,
    head: []const u8,
    desired: DiskDesired,
};

const DiskActive = struct {
    key: []const u8,
    revision: []const u8,
};

const DiskState = struct {
    schema_version: u32,
    sequence: u64,
    active: ?DiskActive,
    profiles: []const DiskProfile,
};

pub fn encodeCanonical(allocator: std.mem.Allocator, state: State) ![]u8 {
    try validateState(allocator, state);

    const profile_order = try allocator.alloc(usize, state.profiles.len);
    defer allocator.free(profile_order);
    for (profile_order, 0..) |*index, value| index.* = value;
    std.mem.sort(usize, profile_order, state.profiles, struct {
        fn lessThan(profiles: []const Profile, a: usize, b: usize) bool {
            return std.mem.order(u8, profiles[a].key, profiles[b].key) == .lt;
        }
    }.lessThan);

    const EncodedSelection = struct {
        group: []const u8,
        proxy: []const u8,
    };
    const EncodedDesired = struct {
        generation: u64,
        selections: []const EncodedSelection,
    };
    const EncodedProfile = struct {
        key: []const u8,
        storage_id: []const u8,
        head: []const u8,
        desired: EncodedDesired,
    };
    const EncodedActive = struct {
        key: []const u8,
        revision: []const u8,
    };
    const EncodedState = struct {
        schema_version: u32 = 2,
        sequence: u64,
        active: ?EncodedActive,
        profiles: []const EncodedProfile,
    };

    const encoded_profiles = try allocator.alloc(EncodedProfile, state.profiles.len);
    defer allocator.free(encoded_profiles);
    const storage_hex = try allocator.alloc([64]u8, state.profiles.len);
    defer allocator.free(storage_hex);
    const head_hex = try allocator.alloc([32]u8, state.profiles.len);
    defer allocator.free(head_hex);
    const encoded_selections = try allocator.alloc([]EncodedSelection, state.profiles.len);
    var initialized: usize = 0;
    defer {
        for (encoded_selections[0..initialized]) |selections| allocator.free(selections);
        allocator.free(encoded_selections);
    }

    for (profile_order, 0..) |source_index, output_index| {
        const profile = state.profiles[source_index];
        const selections = try allocator.alloc(EncodedSelection, profile.desired.selections.len);
        encoded_selections[output_index] = selections;
        initialized += 1;
        for (profile.desired.selections, selections) |selection, *encoded| {
            encoded.* = .{ .group = selection.group, .proxy = selection.proxy };
        }
        std.mem.sort(EncodedSelection, selections, {}, struct {
            fn lessThan(_: void, a: EncodedSelection, b: EncodedSelection) bool {
                return std.mem.order(u8, a.group, b.group) == .lt;
            }
        }.lessThan);
        encoded_profiles[output_index] = .{
            .key = profile.key,
            .storage_id = profile.storage_id.formatHex(&storage_hex[output_index]),
            .head = profile.head.formatHex(&head_hex[output_index]),
            .desired = .{
                .generation = profile.desired.generation,
                .selections = selections,
            },
        };
    }

    var active_revision_hex: [32]u8 = undefined;
    const encoded_active: ?EncodedActive = if (state.active) |active| .{
        .key = active.key,
        .revision = active.revision.formatHex(&active_revision_hex),
    } else null;

    const output: EncodedState = .{
        .sequence = state.sequence,
        .active = encoded_active,
        .profiles = encoded_profiles,
    };
    var count_buffer: [1024]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try std.json.Stringify.value(output, .{}, &counter.writer);
    try counter.writer.writeByte('\n');
    const encoded_size = counter.fullCount();
    if (encoded_size > max_catalog_bytes) return error.CatalogTooLarge;

    const bytes = try allocator.alloc(u8, @intCast(encoded_size));
    errdefer allocator.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);
    try std.json.Stringify.value(output, .{}, &writer);
    try writer.writeByte('\n');
    std.debug.assert(writer.end == bytes.len);
    return bytes;
}

pub fn decodeCanonical(backing_allocator: std.mem.Allocator, bytes: []const u8) !Catalog {
    if (bytes.len > max_catalog_bytes) return error.CatalogTooLarge;

    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const disk = std.json.parseFromSliceLeaky(DiskState, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.CorruptCatalog,
    };
    if (disk.schema_version != 2) return error.CorruptCatalog;

    const profiles = try allocator.alloc(Profile, disk.profiles.len);
    for (disk.profiles, profiles) |disk_profile, *profile| {
        const storage_id = config_identity.StorageId.parseHex(disk_profile.storage_id) catch
            return error.CorruptCatalog;
        const head = config_identity.Revision.parseHex(disk_profile.head) catch
            return error.CorruptCatalog;
        const selections = try allocator.alloc(Selection, disk_profile.desired.selections.len);
        for (disk_profile.desired.selections, selections) |disk_selection, *selection| {
            selection.* = .{ .group = disk_selection.group, .proxy = disk_selection.proxy };
        }
        profile.* = .{
            .key = disk_profile.key,
            .storage_id = storage_id,
            .head = head,
            .desired = .{
                .generation = disk_profile.desired.generation,
                .selections = selections,
            },
        };
    }
    const active: ?ActiveIdentity = if (disk.active) |disk_active| .{
        .key = disk_active.key,
        .revision = config_identity.Revision.parseHex(disk_active.revision) catch
            return error.CorruptCatalog,
    } else null;
    const state: State = .{
        .sequence = disk.sequence,
        .active = active,
        .profiles = profiles,
    };
    validateState(backing_allocator, state) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.CorruptCatalog,
    };

    const canonical = encodeCanonical(backing_allocator, state) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.CorruptCatalog,
    };
    defer backing_allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.CorruptCatalog;
    return .{ .arena = arena, .state = state };
}

fn validateState(allocator: std.mem.Allocator, state: State) !void {
    var keys = std.StringHashMap(void).init(allocator);
    defer keys.deinit();
    var storage_ids = std.AutoHashMap([32]u8, void).init(allocator);
    defer storage_ids.deinit();

    for (state.profiles) |profile| {
        if (!isManagedKey(profile.key)) return error.InvalidCatalog;
        const key_result = try keys.getOrPut(profile.key);
        if (key_result.found_existing) return error.InvalidCatalog;
        const expected_storage = config_identity.StorageId.derive(profile.key);
        if (!profile.storage_id.eql(expected_storage)) return error.InvalidCatalog;
        const storage_result = try storage_ids.getOrPut(profile.storage_id.bytes);
        if (storage_result.found_existing) return error.InvalidCatalog;

        var groups = std.StringHashMap(void).init(allocator);
        defer groups.deinit();
        for (profile.desired.selections) |selection| {
            if (!isNonemptyText(selection.group) or !isNonemptyText(selection.proxy)) {
                return error.InvalidCatalog;
            }
            const group_result = try groups.getOrPut(selection.group);
            if (group_result.found_existing) return error.InvalidCatalog;
        }
    }

    if (state.active) |active| {
        if (!isManagedKey(active.key)) return error.InvalidCatalog;
        var matched = false;
        for (state.profiles) |profile| {
            if (std.mem.eql(u8, profile.key, active.key)) {
                if (!profile.head.eql(active.revision)) return error.InvalidCatalog;
                matched = true;
                break;
            }
        }
        if (!matched) return error.InvalidCatalog;
    }
}

pub fn isManagedKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_bytes or
        std.mem.eql(u8, key, ".") or std.mem.eql(u8, key, "..") or
        std.mem.indexOfAny(u8, key, "/\\") != null)
    {
        return false;
    }
    return isNonemptyText(key);
}

pub fn isPortableManagedKey(key: []const u8) bool {
    return key.len <= max_portable_key_bytes and isManagedKey(key);
}

fn isNonemptyText(text: []const u8) bool {
    if (text.len == 0) return false;
    var view = std.unicode.Utf8View.init(text) catch return false;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f)) return false;
    }
    return true;
}
