const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const config_bundle = @import("config_bundle.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");
const legacy_mirror = @import("legacy_mirror.zig");
const override_materialization = @import("override_materialization.zig");
const revision_store = @import("revision_store.zig");
const state_authority = @import("state_authority.zig");

const max_legacy_meta_bytes = 1024 * 1024;

pub const BlockedReason = enum {
    unproven_schema1,
    legacy_changed,
    state_conflict,
};

pub const EnsureReceipt = struct {
    token: state_authority.StateToken,
    profile_count: usize,
};

pub const EnsureOutcome = union(enum) {
    migrated: EnsureReceipt,
    already_current: EnsureReceipt,
    blocked: BlockedReason,
    durability_uncertain: struct {
        receipt: EnsureReceipt,
        cause: anyerror,
    },
};

const LegacyProfile = struct {
    key: []const u8,
    source_name: []const u8,
    url: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    override_script: ?[]const u8 = null,
    params: []const revision_store.Param = &.{},
    selections: []const config_catalog.Selection = &.{},
    selections_present: bool = false,
};

const MetaProfile = struct {
    key: []const u8,
    url: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    override_script: ?[]const u8 = null,
    params: []const revision_store.Param = &.{},
    selections: []const config_catalog.Selection = &.{},
    selections_present: bool = false,
};

const ParsedMeta = struct {
    active: ?[]const u8 = null,
    profiles: []const MetaProfile = &.{},
};

const LegacySnapshot = struct {
    arena: std.heap.ArenaAllocator,
    configs_dir: ?std.Io.Dir,
    active: ?[]const u8,
    profiles: []const LegacyProfile,
    witness: [32]u8,

    fn closeConfigs(self: *LegacySnapshot) void {
        if (self.configs_dir) |dir| dir.close(compat.io());
        self.configs_dir = null;
    }

    fn deinit(self: *LegacySnapshot) void {
        self.closeConfigs();
        self.arena.deinit();
        self.* = undefined;
    }
};

const CapturedProfile = struct {
    legacy: *const LegacyProfile,
    bundle: config_bundle.ConfigBundle,
    materialization: ?override_materialization.Materialization,
    published: revision_store.PublishedRevision,
};

pub const LegacyCatalogBootstrap = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, root: std.Io.Dir) LegacyCatalogBootstrap {
        return .{ .allocator = allocator, .root = root };
    }

    pub fn ensure(self: LegacyCatalogBootstrap) !EnsureOutcome {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        const store = revision_store.RevisionStore.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        switch (inspection) {
            .catalog_v2 => |*observed| {
                try verifyCatalog(&store, observed.catalog.state);
                _ = try legacy_mirror.LegacyMirror.init(self.allocator, self.root).rebuild();
                return .{ .already_current = .{
                    .token = observed.token,
                    .profile_count = observed.catalog.state.profiles.len,
                } };
            },
            .missing, .legacy_v1 => {},
        }
        const expected = inspection.token();

        var legacy = try captureLegacySnapshot(self.allocator, self.root);
        defer legacy.deinit();
        try validateLegacyCatalogSeed(self.allocator, &legacy);

        const captured = try self.allocator.alloc(CapturedProfile, legacy.profiles.len);
        var captured_count: usize = 0;
        defer {
            for (captured[0..captured_count]) |*profile| {
                profile.bundle.deinit();
                if (profile.materialization) |*frozen| frozen.deinit();
            }
            self.allocator.free(captured);
        }
        for (legacy.profiles, captured) |*profile, *result| {
            const configs_dir = legacy.configs_dir orelse return error.LegacyConfigMissing;
            result.* = try prepareProfile(
                self.allocator,
                self.root,
                configs_dir,
                profile,
            );
            captured_count += 1;
        }

        for (captured) |*profile| {
            profile.published = try store.publishMigration(
                profile.legacy.key,
                &profile.bundle,
                .{
                    .url = profile.legacy.url,
                    .filename = profile.legacy.filename,
                    .params = profile.legacy.params,
                    .override = if (profile.materialization) |*frozen| .{
                        .script_name = frozen.script.name,
                        .script_bytes = frozen.script.bytes,
                        .command = frozen.invocation.command,
                        .config_path = frozen.invocation.config_path,
                        .timeout_ms = frozen.invocation.timeout_ms,
                        // Legacy metadata never persisted override args. In
                        // particular, subscription params are not args.
                        .args = &.{},
                        .patch_bytes = frozen.patch_bytes,
                    } else null,
                },
            );
        }

        var second = captureLegacySnapshot(self.allocator, self.root) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{ .blocked = .legacy_changed },
        };
        defer second.deinit();
        if (!std.mem.eql(u8, &legacy.witness, &second.witness)) {
            return .{ .blocked = .legacy_changed };
        }
        if (captured.len != second.profiles.len) return .{ .blocked = .legacy_changed };
        for (captured, second.profiles) |*profile, repeated_profile| {
            if (!std.mem.eql(u8, profile.legacy.key, repeated_profile.key)) {
                return .{ .blocked = .legacy_changed };
            }
            const second_configs = second.configs_dir orelse return .{ .blocked = .legacy_changed };
            var repeated = if (profile.materialization) |*frozen| blk: {
                const script_path = repeated_profile.override_script orelse
                    return .{ .blocked = .legacy_changed };
                var script = captureOverrideScript(self.allocator, script_path) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return .{ .blocked = .legacy_changed },
                };
                defer script.deinit();
                if (!std.mem.eql(u8, script.script.name, frozen.script.name) or
                    !std.mem.eql(u8, script.script.bytes, frozen.script.bytes))
                {
                    return .{ .blocked = .legacy_changed };
                }
                break :blk config_bundle.ConfigBundle.captureMaterializedFromDir(
                    self.allocator,
                    second_configs,
                    repeated_profile.source_name,
                    frozen.effective_source,
                    .{},
                ) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return .{ .blocked = .legacy_changed },
                };
            } else config_bundle.ConfigBundle.captureFromDir(
                self.allocator,
                second_configs,
                repeated_profile.source_name,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return .{ .blocked = .legacy_changed },
            };
            defer repeated.deinit();
            if (!bundlesEqual(&profile.bundle, &repeated)) {
                return .{ .blocked = .legacy_changed };
            }
        }

        const profiles = try self.allocator.alloc(config_catalog.Profile, captured.len);
        defer self.allocator.free(profiles);
        for (captured, profiles) |*source, *profile| {
            profile.* = .{
                .key = source.legacy.key,
                .storage_id = .{ .bytes = source.published.storage_id },
                .head = source.published.revision,
                .desired = .{
                    .generation = if (source.legacy.selections_present) 1 else 0,
                    .selections = source.legacy.selections,
                },
            };
        }
        const active: ?config_catalog.ActiveIdentity = if (legacy.active) |active_key| blk: {
            for (profiles) |profile| {
                if (std.mem.eql(u8, profile.key, active_key)) {
                    break :blk .{ .key = profile.key, .revision = profile.head };
                }
            }
            return error.LegacyActiveMissing;
        } else null;

        // The derived mirror replaces the legacy configs directory after the
        // catalog commit; release snapshot handles before that rename.
        legacy.closeConfigs();
        second.closeConfigs();
        const outcome = authority.bootstrapCatalog(expected, .{
            .active = active,
            .profiles = profiles,
        }) catch |err| switch (err) {
            error.LegacyProofMismatch => return .{ .blocked = .unproven_schema1 },
            else => return err,
        };
        return switch (outcome) {
            .committed => |receipt| blk: {
                _ = try legacy_mirror.LegacyMirror.init(self.allocator, self.root).rebuild();
                break :blk .{ .migrated = .{
                    .token = receipt.token,
                    .profile_count = profiles.len,
                } };
            },
            .durability_uncertain => |uncertain| .{ .durability_uncertain = .{
                .receipt = .{
                    .token = uncertain.receipt.token,
                    .profile_count = profiles.len,
                },
                .cause = uncertain.cause,
            } },
            .conflict => self.resolveConflict(&authority, &store),
        };
    }

    fn resolveConflict(
        self: LegacyCatalogBootstrap,
        authority: *const state_authority.Authority,
        store: *const revision_store.RevisionStore,
    ) !EnsureOutcome {
        var current = try authority.inspect();
        defer current.deinit();
        return switch (current) {
            .catalog_v2 => |*observed| blk: {
                try verifyCatalog(store, observed.catalog.state);
                _ = try legacy_mirror.LegacyMirror.init(self.allocator, self.root).rebuild();
                break :blk .{ .already_current = .{
                    .token = observed.token,
                    .profile_count = observed.catalog.state.profiles.len,
                } };
            },
            .missing, .legacy_v1 => .{ .blocked = .state_conflict },
        };
    }
};

fn prepareProfile(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    configs_dir: std.Io.Dir,
    profile: *const LegacyProfile,
) !CapturedProfile {
    var frozen: ?override_materialization.Materialization = null;
    errdefer if (frozen) |*materialized| materialized.deinit();
    var bundle: config_bundle.ConfigBundle = undefined;
    if (profile.override_script) |script_path| {
        const source = try config_bundle.ConfigBundle.readSourceFromDir(
            allocator,
            configs_dir,
            profile.source_name,
        );
        defer allocator.free(source);
        var script = try captureOverrideScript(allocator, script_path);
        defer script.deinit();
        const config_path = try configs_dir.realPathFileAlloc(
            compat.io(),
            profile.source_name,
            allocator,
        );
        defer allocator.free(config_path);
        var process_runner = override_materialization.ProcessRunner.init(root);
        frozen = try override_materialization.build(allocator, .{
            .source = source,
            .script = script.script,
            .invocation = .{
                .command = "legacy-migration",
                .config_path = config_path,
                .timeout_ms = override_materialization.timeout_ms_default,
                .args = &.{},
            },
            .runner = process_runner.runner(),
        });
        bundle = try config_bundle.ConfigBundle.captureMaterializedFromDir(
            allocator,
            configs_dir,
            profile.source_name,
            frozen.?.effective_source,
            .{},
        );
        if (!std.mem.eql(u8, source, bundle.sourceBytes())) {
            bundle.deinit();
            return error.SourceChanged;
        }
    } else {
        bundle = try config_bundle.ConfigBundle.captureFromDir(
            allocator,
            configs_dir,
            profile.source_name,
            .{},
        );
    }
    errdefer bundle.deinit();
    var offline = try bundle.loadOffline(allocator);
    defer offline.deinit();
    if (!offline.validation.isValid()) return error.InvalidLegacyConfig;
    return .{
        .legacy = profile,
        .bundle = bundle,
        .materialization = frozen,
        .published = undefined,
    };
}

fn validateLegacyCatalogSeed(
    allocator: std.mem.Allocator,
    legacy: *const LegacySnapshot,
) !void {
    const placeholder_revision = config_identity.Revision{ .bytes = [_]u8{0} ** 16 };
    const profiles = try allocator.alloc(config_catalog.Profile, legacy.profiles.len);
    defer allocator.free(profiles);
    for (legacy.profiles, profiles) |source, *profile| {
        profile.* = .{
            .key = source.key,
            .storage_id = config_identity.StorageId.derive(source.key),
            .head = placeholder_revision,
            .desired = .{
                .generation = if (source.selections_present) 1 else 0,
                .selections = source.selections,
            },
        };
    }
    const active: ?config_catalog.ActiveIdentity = if (legacy.active) |active_key|
        .{ .key = active_key, .revision = placeholder_revision }
    else
        null;
    const encoded = config_catalog.encodeCanonical(allocator, .{
        .active = active,
        .profiles = profiles,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidLegacyMetadata,
    };
    allocator.free(encoded);
}

fn verifyCatalog(store: *const revision_store.RevisionStore, state: config_catalog.State) !void {
    for (state.profiles) |profile| {
        var view = try store.openVerified(profile.key, profile.head);
        defer view.deinit();
        if (!std.mem.eql(u8, &view.storage_id, &profile.storage_id.bytes)) {
            return error.StorageIdentityMismatch;
        }
    }
}

fn captureLegacySnapshot(backing_allocator: std.mem.Allocator, root: std.Io.Dir) !LegacySnapshot {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const meta_bytes = try readOptionalMeta(allocator, root);
    const parsed_meta = if (meta_bytes) |bytes| try parseMeta(allocator, bytes) else ParsedMeta{};
    const configs_dir = try openLegacyConfigs(root);
    errdefer if (configs_dir) |dir| dir.close(compat.io());
    const inventory = if (configs_dir) |dir|
        try listLegacyKeys(allocator, dir)
    else
        try allocator.alloc([]const u8, 0);

    var meta_by_key = std.StringHashMap(usize).init(backing_allocator);
    defer meta_by_key.deinit();
    for (parsed_meta.profiles, 0..) |profile, index| {
        const result = try meta_by_key.getOrPut(profile.key);
        if (result.found_existing) return error.InvalidLegacyMetadata;
        result.value_ptr.* = index;
    }
    for (parsed_meta.profiles) |profile| {
        if (!containsString(inventory, profile.key)) return error.LegacyConfigMissing;
    }

    const profiles = try allocator.alloc(LegacyProfile, inventory.len);
    for (inventory, profiles) |key, *profile| {
        const source_name = try std.fmt.allocPrint(allocator, "{s}.yaml", .{key});
        if (meta_by_key.get(key)) |index| {
            const metadata = parsed_meta.profiles[index];
            profile.* = .{
                .key = key,
                .source_name = source_name,
                .url = metadata.url,
                .filename = metadata.filename,
                .override_script = metadata.override_script,
                .params = metadata.params,
                .selections = metadata.selections,
                .selections_present = metadata.selections_present,
            };
        } else {
            profile.* = .{ .key = key, .source_name = source_name };
        }
    }
    if (parsed_meta.active) |active| {
        if (!containsString(inventory, active)) return error.LegacyActiveMissing;
    }

    return .{
        .arena = arena,
        .configs_dir = configs_dir,
        .active = parsed_meta.active,
        .profiles = profiles,
        .witness = legacyWitness(meta_bytes, inventory),
    };
}

const CapturedOverrideScript = struct {
    allocator: std.mem.Allocator,
    script: override_materialization.Script,

    fn deinit(self: *CapturedOverrideScript) void {
        self.allocator.free(self.script.name);
        self.allocator.free(self.script.bytes);
        self.* = undefined;
    }
};

fn captureOverrideScript(
    allocator: std.mem.Allocator,
    script_path: []const u8,
) !CapturedOverrideScript {
    const file = openStrictRegular(std.Io.Dir.cwd(), script_path) catch
        return error.InvalidLegacyOverride;
    defer file.close(compat.io());
    const initial = try file.stat(compat.io());
    if (initial.size == 0 or initial.size > override_materialization.max_script_bytes) {
        return error.InvalidLegacyOverride;
    }
    const bytes = compat.fileReadBoundedAlloc(
        file,
        allocator,
        override_materialization.max_script_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidLegacyOverride,
    };
    errdefer allocator.free(bytes);
    const after = try file.stat(compat.io());
    if (!sameFileStat(initial, after) or bytes.len != after.size) {
        return error.InvalidLegacyOverride;
    }
    const name = try allocator.dupe(u8, compat.fs.path.basename(script_path));
    return .{ .allocator = allocator, .script = .{ .name = name, .bytes = bytes } };
}

fn readOptionalMeta(allocator: std.mem.Allocator, root: std.Io.Dir) !?[]u8 {
    const file = openStrictRegular(root, "meta.json") catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.InvalidLegacyMetadata,
    };
    defer file.close(compat.io());
    const initial = try file.stat(compat.io());
    if (initial.size > max_legacy_meta_bytes) return error.InvalidLegacyMetadata;
    const bytes = compat.fileReadBoundedAlloc(file, allocator, max_legacy_meta_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidLegacyMetadata,
    };
    const after = try file.stat(compat.io());
    if (!sameFileStat(initial, after) or bytes.len != after.size or bytes.len == 0) {
        return error.InvalidLegacyMetadata;
    }
    return @as(?[]u8, bytes);
}

fn openLegacyConfigs(root: std.Io.Dir) !?std.Io.Dir {
    return @as(?std.Io.Dir, root.openDir(compat.io(), "configs", .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.InvalidLegacyLayout,
    });
}

fn listLegacyKeys(allocator: std.mem.Allocator, configs: std.Io.Dir) ![]const []const u8 {
    var keys = std.ArrayList([]const u8).empty;
    errdefer keys.deinit(allocator);
    var iterator = configs.iterate();
    while (try iterator.next(compat.io())) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        const key = entry.name[0 .. entry.name.len - ".yaml".len];
        if (!config_catalog.isManagedKey(key)) return error.InvalidLegacyKey;
        try keys.append(allocator, try allocator.dupe(u8, key));
    }
    std.mem.sort([]const u8, keys.items, {}, lessString);
    if (keys.items.len > 1) {
        for (keys.items[1..], keys.items[0 .. keys.items.len - 1]) |current, previous| {
            if (std.mem.eql(u8, current, previous)) return error.InvalidLegacyLayout;
        }
    }
    return keys.toOwnedSlice(allocator);
}

fn parseMeta(allocator: std.mem.Allocator, bytes: []const u8) !ParsedMeta {
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidLegacyMetadata,
    };
    if (root != .object) return error.InvalidLegacyMetadata;
    try requireOnlyFields(root.object, &.{ "active", "configs" });
    const active_value = root.object.get("active") orelse return error.InvalidLegacyMetadata;
    const active: ?[]const u8 = switch (active_value) {
        .null => null,
        .string => |value| blk: {
            if (!config_catalog.isManagedKey(value)) return error.InvalidLegacyKey;
            break :blk value;
        },
        else => return error.InvalidLegacyMetadata,
    };
    const configs_value = root.object.get("configs") orelse return error.InvalidLegacyMetadata;
    if (configs_value != .object) return error.InvalidLegacyMetadata;

    const profiles = try allocator.alloc(MetaProfile, configs_value.object.count());
    var iterator = configs_value.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        const key = entry.key_ptr.*;
        if (!config_catalog.isManagedKey(key)) return error.InvalidLegacyKey;
        if (entry.value_ptr.* != .object) return error.InvalidLegacyMetadata;
        const object = entry.value_ptr.object;
        try requireOnlyFields(object, &.{ "url", "filename", "override_script", "params", "selections" });
        profiles[index] = .{
            .key = key,
            .url = try optionalString(object.get("url")),
            .filename = try optionalString(object.get("filename")),
            .override_script = try optionalString(object.get("override_script")),
            .params = try parseParams(allocator, object.get("params")),
            .selections = try parseSelections(allocator, object.get("selections")),
            .selections_present = object.get("selections") != null,
        };
    }
    std.mem.sort(MetaProfile, profiles, {}, struct {
        fn lessThan(_: void, a: MetaProfile, b: MetaProfile) bool {
            return lessString({}, a.key, b.key);
        }
    }.lessThan);
    return .{ .active = active, .profiles = profiles };
}

fn optionalString(value: ?std.json.Value) !?[]const u8 {
    const actual = value orelse return null;
    return switch (actual) {
        .null => null,
        .string => |text| text,
        else => error.InvalidLegacyMetadata,
    };
}

fn parseParams(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const revision_store.Param {
    const actual = value orelse return allocator.alloc(revision_store.Param, 0);
    if (actual != .object) return error.InvalidLegacyMetadata;
    const params = try allocator.alloc(revision_store.Param, actual.object.count());
    var iterator = actual.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        if (entry.value_ptr.* != .string) return error.InvalidLegacyMetadata;
        params[index] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.string };
    }
    std.mem.sort(revision_store.Param, params, {}, struct {
        fn lessThan(_: void, a: revision_store.Param, b: revision_store.Param) bool {
            return lessString({}, a.key, b.key);
        }
    }.lessThan);
    return params;
}

fn parseSelections(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const config_catalog.Selection {
    const actual = value orelse return allocator.alloc(config_catalog.Selection, 0);
    if (actual != .object) return error.InvalidLegacyMetadata;
    const selections = try allocator.alloc(config_catalog.Selection, actual.object.count());
    var iterator = actual.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        if (entry.value_ptr.* != .string) return error.InvalidLegacyMetadata;
        selections[index] = .{ .group = entry.key_ptr.*, .proxy = entry.value_ptr.string };
    }
    std.mem.sort(config_catalog.Selection, selections, {}, struct {
        fn lessThan(_: void, a: config_catalog.Selection, b: config_catalog.Selection) bool {
            return lessString({}, a.group, b.group);
        }
    }.lessThan);
    return selections;
}

fn requireOnlyFields(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!containsString(allowed, entry.key_ptr.*)) return error.InvalidLegacyMetadata;
    }
}

fn legacyWitness(meta_bytes: ?[]const u8, keys: []const []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("zc.legacy-witness.v1");
    if (meta_bytes) |bytes| {
        hasher.update(&.{1});
        hashBytes(&hasher, bytes);
    } else {
        hasher.update(&.{0});
    }
    for (keys) |key| hashBytes(&hasher, key);
    return hasher.finalResult();
}

fn bundlesEqual(a: *const config_bundle.ConfigBundle, b: *const config_bundle.ConfigBundle) bool {
    const am = a.manifest();
    const bm = b.manifest();
    if (!contentEqual(am.source, bm.source) or am.aggregate_bytes != bm.aggregate_bytes or
        am.local_assets.len != bm.local_assets.len or
        am.remote_providers.len != bm.remote_providers.len)
    {
        return false;
    }
    if ((am.materialized_source == null) != (bm.materialized_source == null)) return false;
    if (am.materialized_source) |materialized| {
        if (!contentEqual(materialized, bm.materialized_source.?)) return false;
    }
    for (am.local_assets, bm.local_assets) |left, right| {
        if (!std.mem.eql(u8, left.logical_path, right.logical_path) or
            !std.mem.eql(u8, left.canonical_relative_target, right.canonical_relative_target) or
            !contentEqual(left.content, right.content))
        {
            return false;
        }
    }
    for (am.remote_providers, bm.remote_providers) |left, right| {
        if (!std.mem.eql(u8, left.provider_name, right.provider_name) or
            !std.mem.eql(u8, left.logical_path, right.logical_path))
        {
            return false;
        }
    }
    return true;
}

fn contentEqual(a: config_bundle.ContentIdentity, b: config_bundle.ContentIdentity) bool {
    return a.size == b.size and std.mem.eql(u8, &a.sha256, &b.sha256);
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn hashBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
    hasher.update(&length);
    hasher.update(bytes);
}

fn sameFileStat(left: std.Io.File.Stat, right: std.Io.File.Stat) bool {
    return left.kind == right.kind and left.inode == right.inode and
        left.nlink == right.nlink and left.size == right.size and
        std.meta.eql(left.mtime, right.mtime) and std.meta.eql(left.ctime, right.ctime);
}

fn openStrictRegular(dir: std.Io.Dir, path: []const u8) !std.Io.File {
    const file = if (builtin.os.tag == .windows)
        try dir.openFile(compat.io(), path, .{
            .allow_directory = false,
            .follow_symlinks = false,
        })
    else blk: {
        const fd = try std.posix.openat(dir.handle, path, .{
            .ACCMODE = .RDONLY,
            .NONBLOCK = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0);
        break :blk std.Io.File{ .handle = fd, .flags = .{ .nonblocking = true } };
    };
    errdefer file.close(compat.io());
    const stat = try file.stat(compat.io());
    if (stat.kind != .file) return error.InvalidLegacyMetadata;
    return file;
}
