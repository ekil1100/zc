const std = @import("std");
const catalog_service = @import("catalog_service.zig");
const config = @import("config.zig");
const config_bundle = @import("config_bundle.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");
const override_materialization = @import("override_materialization.zig");
const revision_store = @import("revision_store.zig");
const state_authority = @import("state_authority.zig");

const max_attempts = 4;

pub const Entry = struct {
    key: []const u8,
    display: []const u8,
    revision: config_identity.Revision,
    active: bool,
    desired_generation: u64,
};

pub const Listing = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    active: ?[]const u8,
    token: state_authority.StateToken,

    pub fn deinit(self: *Listing) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.display);
        }
        self.allocator.free(self.entries);
        if (self.active) |active| self.allocator.free(active);
        self.* = undefined;
    }
};

pub const DeleteReceipt = struct {
    was_active: bool,
    receipt: catalog_service.ApplyReceipt,
};

pub const DownloadedMode = enum { create, update };
pub const DownloadedInput = struct {
    key: []const u8,
    source_bytes: []const u8,
    metadata: revision_store.MetadataInput = .{},
    mode: DownloadedMode,
    expected_revision: ?config_identity.Revision = null,
    activate: bool = false,
    override_runner: ?override_materialization.Runner = null,
};

pub const Subscription = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    revision: config_identity.Revision,

    pub fn deinit(self: *Subscription) void {
        self.allocator.free(self.url);
        self.* = undefined;
    }
};

pub const Source = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    revision: config_identity.Revision,

    pub fn deinit(self: *Source) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const OverrideChange = struct {
    key: []const u8,
    script: override_materialization.Script,
    invocation: override_materialization.Invocation,
    runner: override_materialization.Runner,
    expected_token: ?state_authority.StateToken = null,
    require_active: bool = false,
};

pub const OverrideClear = struct {
    key: []const u8,
    expected_token: ?state_authority.StateToken = null,
    require_active: bool = false,
};

pub const ActiveOverride = struct {
    allocator: std.mem.Allocator,
    key: ?[]const u8,
    revision: ?config_identity.Revision,
    script_name: ?[]const u8,
    token: state_authority.StateToken,

    pub fn deinit(self: *ActiveOverride) void {
        if (self.key) |key| self.allocator.free(key);
        if (self.script_name) |name| self.allocator.free(name);
        self.* = undefined;
    }
};
pub const DownloadedReceipt = catalog_service.PublishReceipt;

/// User-intent adapter over typed catalog CAS. Conflicts are retried against a
/// fresh exact head; retries are bounded and never normalize managed keys.
pub const Commands = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, root: std.Io.Dir) Commands {
        return .{ .allocator = allocator, .root = root };
    }

    pub fn list(self: Commands) !Listing {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        const state = switch (inspection) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        const entries = try self.allocator.alloc(Entry, state.profiles.len);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.display);
            }
            self.allocator.free(entries);
        }
        const store = revision_store.RevisionStore.init(self.allocator, self.root);
        for (state.profiles, entries) |profile, *entry| {
            var view = try store.openVerified(profile.key, profile.head);
            const key = self.allocator.dupe(u8, profile.key) catch |err| {
                view.deinit();
                return err;
            };
            const display = self.allocator.dupe(u8, view.metadata.filename orelse profile.key) catch |err| {
                self.allocator.free(key);
                view.deinit();
                return err;
            };
            view.deinit();
            entry.* = .{
                .key = key,
                .display = display,
                .revision = profile.head,
                .active = if (state.active) |active| std.mem.eql(u8, active.key, profile.key) else false,
                .desired_generation = profile.desired.generation,
            };
            initialized += 1;
        }
        const active = if (state.active) |value|
            try self.allocator.dupe(u8, value.key)
        else
            null;
        return .{
            .allocator = self.allocator,
            .entries = entries,
            .active = active,
            .token = inspection.token(),
        };
    }

    pub fn subscription(
        self: Commands,
        key: []const u8,
    ) !Subscription {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        const state = switch (inspection) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        const profile = findProfile(state.profiles, key) orelse
            return error.ManagedProfileNotFound;
        var view = try revision_store.RevisionStore.init(
            self.allocator,
            self.root,
        ).openVerified(profile.key, profile.head);
        defer view.deinit();
        const url = view.metadata.url orelse return error.NoSubscriptionUrl;
        return .{
            .allocator = self.allocator,
            .url = try self.allocator.dupe(u8, url),
            .revision = profile.head,
        };
    }

    pub fn source(self: Commands, key: []const u8) !Source {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        const state = switch (inspection) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        const profile = findProfile(state.profiles, key) orelse
            return error.ManagedProfileNotFound;
        var view = try revision_store.RevisionStore.init(
            self.allocator,
            self.root,
        ).openVerified(profile.key, profile.head);
        defer view.deinit();
        return .{
            .allocator = self.allocator,
            .bytes = try self.allocator.dupe(u8, view.sourceBytes()),
            .revision = profile.head,
        };
    }

    pub fn activeOverride(self: Commands) !ActiveOverride {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        const token = inspection.token();
        const state = switch (inspection) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        const active = state.active orelse return .{
            .allocator = self.allocator,
            .key = null,
            .revision = null,
            .script_name = null,
            .token = token,
        };
        const profile = findProfile(state.profiles, active.key) orelse
            return error.CorruptState;
        if (!profile.head.eql(active.revision)) return error.CorruptState;
        var view = try revision_store.RevisionStore.init(
            self.allocator,
            self.root,
        ).openVerified(profile.key, profile.head);
        defer view.deinit();
        const key = try self.allocator.dupe(u8, profile.key);
        errdefer self.allocator.free(key);
        const script_name = if (view.override) |frozen|
            try self.allocator.dupe(u8, frozen.script_name)
        else
            null;
        return .{
            .allocator = self.allocator,
            .key = key,
            .revision = profile.head,
            .script_name = script_name,
            .token = token,
        };
    }

    pub fn publishDownloaded(self: Commands, input: DownloadedInput) !DownloadedReceipt {
        switch (input.mode) {
            .create => if (!config_catalog.isPortableManagedKey(input.key)) {
                return error.InvalidConfigKey;
            },
            .update => if (!config_catalog.isManagedKey(input.key)) {
                return error.InvalidConfigKey;
            },
        }
        var bundle: ?config_bundle.ConfigBundle = null;
        defer if (bundle) |*value| value.deinit();
        var loaded: ?config_bundle.OfflineLoad = null;
        defer if (loaded) |*value| value.deinit();
        if (input.mode == .create) {
            bundle = try config_bundle.ConfigBundle.captureCatalogMemory(
                self.allocator,
                input.source_bytes,
                null,
                .{},
            );
            loaded = try bundle.?.loadCatalogOffline(self.allocator);
            if (!loaded.?.validation.isValid()) return error.InvalidConfig;
            if (bundle.?.semanticState() == .malformed and input.activate) {
                return error.ProfileNotRuntimeReady;
            }
        }

        var original_head: ?config_identity.Revision = null;
        for (0..max_attempts) |_| {
            const authority = state_authority.Authority.init(self.allocator, self.root);
            var inspection = try authority.inspect();
            const token = inspection.token();
            const state = switch (inspection) {
                .catalog_v2 => |*observed| observed.catalog.state,
                .missing, .legacy_v1 => {
                    inspection.deinit();
                    return error.Schema2CatalogRequired;
                },
            };
            const existing = findProfile(state.profiles, input.key);
            if (input.mode == .create) {
                if (existing != null) {
                    inspection.deinit();
                    return error.ManagedProfileAlreadyExists;
                }
                const should_activate = bundle.?.semanticState() == .runtime_ready and
                    (input.activate or state.active == null);
                inspection.deinit();
                switch (try catalog_service.Service.init(self.allocator, self.root).publish(token, .{
                    .key = input.key,
                    .expected = .missing,
                    .bundle = &bundle.?,
                    .metadata = input.metadata,
                    .desired = .clear,
                    .activate = should_activate,
                })) {
                    .applied => |receipt| return receipt,
                    .conflict => continue,
                }
            }

            const profile = existing orelse {
                inspection.deinit();
                return error.ManagedProfileNotFound;
            };
            if (input.expected_revision) |expected| {
                if (!expected.eql(profile.head)) {
                    inspection.deinit();
                    return error.ProfileIdentityConflict;
                }
            }
            if (original_head) |head| {
                if (!head.eql(profile.head)) {
                    inspection.deinit();
                    return error.ProfileIdentityConflict;
                }
            } else {
                original_head = profile.head;
            }
            var view = revision_store.RevisionStore.init(self.allocator, self.root).openVerified(
                profile.key,
                profile.head,
            ) catch |err| {
                inspection.deinit();
                return err;
            };
            if (view.override) |frozen| {
                const runner = input.override_runner orelse {
                    view.deinit();
                    inspection.deinit();
                    return error.OverrideRematerializationRequired;
                };
                const invocation_args = self.allocator.alloc(
                    override_materialization.Argument,
                    frozen.args.len,
                ) catch |err| {
                    view.deinit();
                    inspection.deinit();
                    return err;
                };
                defer self.allocator.free(invocation_args);
                for (frozen.args, invocation_args) |argument, *output| {
                    output.* = .{ .key = argument.key, .value = argument.value };
                }
                var materialization = override_materialization.build(self.allocator, .{
                    .source = input.source_bytes,
                    .script = .{ .name = frozen.script_name, .bytes = frozen.script_bytes },
                    .invocation = .{
                        .command = frozen.command,
                        .config_path = frozen.config_path,
                        .timeout_ms = frozen.timeout_ms,
                        .args = invocation_args,
                    },
                    .runner = runner,
                }) catch |err| {
                    view.deinit();
                    inspection.deinit();
                    return err;
                };
                defer materialization.deinit();
                const available = memoryAssets(self.allocator, view.assets) catch |err| {
                    view.deinit();
                    inspection.deinit();
                    return err;
                };
                defer self.allocator.free(available);
                var overridden_bundle = config_bundle.ConfigBundle.reconstructMemory(
                    self.allocator,
                    input.source_bytes,
                    materialization.effective_source,
                    available,
                    .{},
                ) catch |err| {
                    view.deinit();
                    inspection.deinit();
                    return err;
                };
                defer overridden_bundle.deinit();
                var overridden_load = overridden_bundle.loadOffline(self.allocator) catch |err| {
                    view.deinit();
                    inspection.deinit();
                    return err;
                };
                defer overridden_load.deinit();
                if (!overridden_load.validation.isValid()) {
                    view.deinit();
                    inspection.deinit();
                    return error.InvalidConfig;
                }
                const overridden_selections = filterSelections(
                    self.allocator,
                    profile.desired.selections,
                    &overridden_load.config,
                ) catch |err| {
                    view.deinit();
                    inspection.deinit();
                    return err;
                };
                defer self.allocator.free(overridden_selections);
                const override_args = self.allocator.alloc(
                    revision_store.OverrideArgument,
                    materialization.invocation.args.len,
                ) catch |err| {
                    view.deinit();
                    inspection.deinit();
                    return err;
                };
                defer self.allocator.free(override_args);
                for (materialization.invocation.args, override_args) |argument, *output| {
                    output.* = .{ .key = argument.key, .value = argument.value };
                }
                const overridden_outcome = catalog_service.Service.init(self.allocator, self.root).publish(token, .{
                    .key = input.key,
                    .expected = .{ .revision = profile.head },
                    .bundle = &overridden_bundle,
                    .metadata = .{
                        .url = view.metadata.url,
                        .filename = view.metadata.filename,
                        .params = view.metadata.params,
                        .override = .{
                            .script_name = materialization.script.name,
                            .script_bytes = materialization.script.bytes,
                            .command = materialization.invocation.command,
                            .config_path = materialization.invocation.config_path,
                            .timeout_ms = materialization.invocation.timeout_ms,
                            .args = override_args,
                            .patch_bytes = materialization.patch_bytes,
                        },
                    },
                    .desired = .{ .replace = overridden_selections },
                }) catch |err| {
                    view.deinit();
                    inspection.deinit();
                    return err;
                };
                view.deinit();
                inspection.deinit();
                return switch (overridden_outcome) {
                    .applied => |receipt| receipt,
                    .conflict => error.StateConflict,
                };
            }
            if (bundle == null) {
                bundle = blk: {
                    const available = memoryAssets(
                        self.allocator,
                        view.assets,
                    ) catch |err| {
                        view.deinit();
                        inspection.deinit();
                        return err;
                    };
                    defer self.allocator.free(available);
                    break :blk config_bundle.ConfigBundle.reconstructCatalogMemory(
                        self.allocator,
                        input.source_bytes,
                        null,
                        available,
                        .{},
                    ) catch |err| {
                        view.deinit();
                        inspection.deinit();
                        return err;
                    };
                };
                loaded = bundle.?.loadCatalogOffline(self.allocator) catch |err| {
                    view.deinit();
                    inspection.deinit();
                    return err;
                };
            }
            if (!loaded.?.validation.isValid()) {
                view.deinit();
                inspection.deinit();
                return error.InvalidConfig;
            }
            if (bundle.?.semanticState() == .malformed and
                (input.activate or isActiveProfile(state, profile)))
            {
                view.deinit();
                inspection.deinit();
                return error.ProfileNotRuntimeReady;
            }
            if (bundle.?.semanticState() == .malformed) {
                const metadata: revision_store.MetadataInput = .{
                    .url = view.metadata.url,
                    .filename = view.metadata.filename,
                    .params = view.metadata.params,
                };
                const raw_outcome = catalog_service.Service.init(
                    self.allocator,
                    self.root,
                ).publish(token, .{
                    .key = input.key,
                    .expected = .{ .revision = profile.head },
                    .bundle = &bundle.?,
                    .metadata = metadata,
                    .desired = .clear,
                    .activate = input.activate,
                }) catch |err| {
                    view.deinit();
                    inspection.deinit();
                    return err;
                };
                view.deinit();
                inspection.deinit();
                switch (raw_outcome) {
                    .applied => |receipt| return receipt,
                    .conflict => continue,
                }
            }
            const filtered = filterSelections(
                self.allocator,
                profile.desired.selections,
                &loaded.?.config,
            ) catch |err| {
                view.deinit();
                inspection.deinit();
                return err;
            };
            const metadata: revision_store.MetadataInput = .{
                .url = view.metadata.url,
                .filename = view.metadata.filename,
                .params = view.metadata.params,
            };
            const result = catalog_service.Service.init(self.allocator, self.root).publish(token, .{
                .key = input.key,
                .expected = .{ .revision = profile.head },
                .bundle = &bundle.?,
                .metadata = metadata,
                .desired = .{ .replace = filtered },
            });
            const outcome = result catch |err| {
                self.allocator.free(filtered);
                view.deinit();
                inspection.deinit();
                return err;
            };
            self.allocator.free(filtered);
            view.deinit();
            inspection.deinit();
            switch (outcome) {
                .applied => |receipt| return receipt,
                .conflict => continue,
            }
        }
        return error.StateConflict;
    }

    pub fn setOverride(self: Commands, change: OverrideChange) !DownloadedReceipt {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        const token = inspection.token();
        const state = switch (inspection) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        try validateOverrideTarget(
            state,
            token,
            change.key,
            change.expected_token,
            change.require_active,
        );
        const profile = findProfile(state.profiles, change.key) orelse return error.ManagedProfileNotFound;
        var view = try revision_store.RevisionStore.init(self.allocator, self.root).openVerified(
            profile.key,
            profile.head,
        );
        defer view.deinit();
        var materialization = try override_materialization.build(self.allocator, .{
            .source = view.sourceBytes(),
            .script = change.script,
            .invocation = change.invocation,
            .runner = change.runner,
        });
        defer materialization.deinit();
        const available = try memoryAssets(self.allocator, view.assets);
        defer self.allocator.free(available);
        var bundle = try config_bundle.ConfigBundle.reconstructMemory(
            self.allocator,
            view.sourceBytes(),
            materialization.effective_source,
            available,
            .{},
        );
        defer bundle.deinit();
        var loaded = try bundle.loadOffline(self.allocator);
        defer loaded.deinit();
        if (!loaded.validation.isValid()) return error.InvalidConfig;
        const filtered = try filterSelections(
            self.allocator,
            profile.desired.selections,
            &loaded.config,
        );
        defer self.allocator.free(filtered);
        const args = try self.allocator.alloc(revision_store.OverrideArgument, materialization.invocation.args.len);
        defer self.allocator.free(args);
        for (materialization.invocation.args, args) |argument, *output| {
            output.* = .{ .key = argument.key, .value = argument.value };
        }
        const outcome = try catalog_service.Service.init(self.allocator, self.root).publish(token, .{
            .key = profile.key,
            .expected = .{ .revision = profile.head },
            .bundle = &bundle,
            .metadata = .{
                .url = view.metadata.url,
                .filename = view.metadata.filename,
                .params = view.metadata.params,
                .override = .{
                    .script_name = materialization.script.name,
                    .script_bytes = materialization.script.bytes,
                    .command = materialization.invocation.command,
                    .config_path = materialization.invocation.config_path,
                    .timeout_ms = materialization.invocation.timeout_ms,
                    .args = args,
                    .patch_bytes = materialization.patch_bytes,
                },
            },
            .desired = .{ .replace = filtered },
        });
        return switch (outcome) {
            .applied => |receipt| receipt,
            .conflict => error.StateConflict,
        };
    }

    pub fn clearOverride(self: Commands, change: OverrideClear) !?DownloadedReceipt {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        const token = inspection.token();
        const state = switch (inspection) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        try validateOverrideTarget(
            state,
            token,
            change.key,
            change.expected_token,
            change.require_active,
        );
        const profile = findProfile(state.profiles, change.key) orelse
            return error.ManagedProfileNotFound;
        var view = try revision_store.RevisionStore.init(self.allocator, self.root).openVerified(
            profile.key,
            profile.head,
        );
        defer view.deinit();
        if (view.override == null) return null;
        const available = try memoryAssets(self.allocator, view.assets);
        defer self.allocator.free(available);
        var bundle = try config_bundle.ConfigBundle.reconstructMemory(
            self.allocator,
            view.sourceBytes(),
            null,
            available,
            .{},
        );
        defer bundle.deinit();
        var loaded = try bundle.loadOffline(self.allocator);
        defer loaded.deinit();
        if (!loaded.validation.isValid()) return error.InvalidConfig;
        const filtered = try filterSelections(self.allocator, profile.desired.selections, &loaded.config);
        defer self.allocator.free(filtered);
        const outcome = try catalog_service.Service.init(self.allocator, self.root).publish(token, .{
            .key = profile.key,
            .expected = .{ .revision = profile.head },
            .bundle = &bundle,
            .metadata = .{
                .url = view.metadata.url,
                .filename = view.metadata.filename,
                .params = view.metadata.params,
            },
            .desired = .{ .replace = filtered },
        });
        return switch (outcome) {
            .applied => |receipt| receipt,
            .conflict => error.StateConflict,
        };
    }

    pub fn activate(self: Commands, key: []const u8) !catalog_service.ApplyReceipt {
        for (0..max_attempts) |_| {
            const authority = state_authority.Authority.init(self.allocator, self.root);
            var inspection = try authority.inspect();
            const token = inspection.token();
            switch (inspection) {
                .catalog_v2 => |*observed| {
                    _ = findProfile(
                        observed.catalog.state.profiles,
                        key,
                    ) orelse {
                        inspection.deinit();
                        return error.ManagedProfileNotFound;
                    };
                },
                .missing, .legacy_v1 => {
                    inspection.deinit();
                    return error.Schema2CatalogRequired;
                },
            }
            inspection.deinit();
            switch (try catalog_service.Service.init(self.allocator, self.root).mutate(
                token,
                .{ .set_active = .{ .key = key } },
            )) {
                .applied => |receipt| return receipt,
                .conflict => continue,
            }
        }
        return error.StateConflict;
    }

    pub fn delete(self: Commands, key: []const u8) !DeleteReceipt {
        for (0..max_attempts) |_| {
            const authority = state_authority.Authority.init(self.allocator, self.root);
            var inspection = try authority.inspect();
            const token = inspection.token();
            var head: config_identity.Revision = undefined;
            var was_active = false;
            switch (inspection) {
                .catalog_v2 => |*observed| {
                    const profile = findProfile(observed.catalog.state.profiles, key) orelse {
                        inspection.deinit();
                        return error.ManagedProfileNotFound;
                    };
                    head = profile.head;
                    was_active = if (observed.catalog.state.active) |active|
                        std.mem.eql(u8, active.key, key)
                    else
                        false;
                },
                .missing, .legacy_v1 => {
                    inspection.deinit();
                    return error.Schema2CatalogRequired;
                },
            }
            inspection.deinit();
            switch (try catalog_service.Service.init(self.allocator, self.root).mutate(
                token,
                .{ .delete_profile = .{ .key = key, .expected = head } },
            )) {
                .applied => |receipt| return .{ .was_active = was_active, .receipt = receipt },
                .conflict => continue,
            }
        }
        return error.StateConflict;
    }
};

fn validateOverrideTarget(
    state: config_catalog.State,
    actual_token: state_authority.StateToken,
    key: []const u8,
    expected_token: ?state_authority.StateToken,
    require_active: bool,
) !void {
    if (expected_token) |expected| {
        if (!expected.eql(actual_token)) return error.StateConflict;
    }
    if (!require_active) return;
    const active = state.active orelse return error.ActiveManagedProfileChanged;
    if (!std.mem.eql(u8, active.key, key)) {
        return error.ActiveManagedProfileChanged;
    }
}

fn memoryAssets(
    allocator: std.mem.Allocator,
    assets: anytype,
) ![]config_bundle.MemoryAsset {
    const records = try allocator.alloc(config_bundle.MemoryAsset, assets.len);
    for (assets, records) |asset, *record| {
        record.* = .{
            .logical_path = asset.logical_path,
            .canonical_relative_target = asset.canonical_relative_target,
            .bytes = asset.bytes,
        };
    }
    return records;
}

fn filterSelections(
    allocator: std.mem.Allocator,
    selections: []const config_catalog.Selection,
    cfg: *const config.Config,
) ![]config_catalog.Selection {
    var filtered = std.ArrayList(config_catalog.Selection).empty;
    errdefer filtered.deinit(allocator);
    for (selections) |selection| {
        var valid = false;
        for (cfg.proxy_groups.items) |group| {
            if (!std.mem.eql(u8, group.name, selection.group)) continue;
            for (group.proxies.items) |member| {
                if (std.mem.eql(u8, member, selection.proxy)) {
                    valid = true;
                    break;
                }
            }
            break;
        }
        if (valid) try filtered.append(allocator, selection);
    }
    return filtered.toOwnedSlice(allocator);
}

fn isActiveProfile(
    state: config_catalog.State,
    profile: *const config_catalog.Profile,
) bool {
    const active = state.active orelse return false;
    return std.mem.eql(u8, active.key, profile.key) and
        active.revision.eql(profile.head);
}

fn findProfile(profiles: []const config_catalog.Profile, key: []const u8) ?*const config_catalog.Profile {
    var low: usize = 0;
    var high = profiles.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, key, profiles[middle].key)) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return &profiles[middle],
        }
    }
    return null;
}
