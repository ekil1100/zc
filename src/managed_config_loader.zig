const std = @import("std");
const config = @import("config.zig");
const config_bundle = @import("config_bundle.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");
const config_validator = @import("config_validator.zig");
const revision_store = @import("revision_store.zig");
const state_authority = @import("state_authority.zig");

pub const Origin = enum {
    managed_revision,
    unmanaged_path,
};

pub const Identity = config_identity.ManagedIdentity;

/// Parsed and validated without network access. Local providers have been
/// resolved from captured immutable bytes; remote providers remain deferred.
pub const LoadedConfig = struct {
    allocator: std.mem.Allocator,
    config: config.Config,
    validation: config_validator.ValidationResult,
    origin: Origin,
    identity: ?Identity,

    pub fn deinit(self: *LoadedConfig) void {
        self.config.deinit();
        self.validation.deinit();
        if (self.identity) |identity| self.allocator.free(identity.key);
        self.* = undefined;
    }
};

/// Exact config reader. It never applies persisted overrides again and never
/// falls back from a managed identity to active or ambient filesystem state.
pub const Loader = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, root: std.Io.Dir) Loader {
        return .{ .allocator = allocator, .root = root };
    }

    pub fn loadActive(self: Loader) !LoadedConfig {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        const state = switch (inspection) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        const active = state.active orelse return error.NoActiveManagedConfig;
        const profile = findProfile(state.profiles, active.key) orelse return error.CorruptState;
        if (!profile.head.eql(active.revision)) return error.CorruptState;
        return self.loadManagedRevision(active.key, active.revision);
    }

    pub fn loadHead(self: Loader, key: []const u8) !LoadedConfig {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        const state = switch (inspection) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        const profile = findProfile(state.profiles, key) orelse return error.ManagedProfileNotFound;
        return self.loadManagedRevision(profile.key, profile.head);
    }

    pub fn loadExact(self: Loader, identity: Identity) !LoadedConfig {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        const state = switch (inspection) {
            .catalog_v2 => |*observed| observed.catalog.state,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        const profile = findProfile(state.profiles, identity.key) orelse
            return error.ManagedProfileNotFound;
        return self.loadManagedRevision(profile.key, identity.revision);
    }

    pub fn loadUnmanagedPath(self: Loader, path: []const u8) !LoadedConfig {
        var bundle = try config_bundle.ConfigBundle.capture(self.allocator, path, .{});
        defer bundle.deinit();
        var loaded = try bundle.loadOffline(self.allocator);
        errdefer loaded.deinit();
        return .{
            .allocator = self.allocator,
            .config = loaded.config,
            .validation = loaded.validation,
            .origin = .unmanaged_path,
            .identity = null,
        };
    }

    fn loadManagedRevision(
        self: Loader,
        key: []const u8,
        revision: config_identity.Revision,
    ) !LoadedConfig {
        const store = revision_store.RevisionStore.init(self.allocator, self.root);
        var view = try store.openVerified(key, revision);
        defer view.deinit();
        var parsed = try config.parseDocument(self.allocator, view.effectiveSourceBytes());
        errdefer parsed.deinit();
        try config.prepareRuleProvidersOffline(self.allocator, &parsed, &view);
        var validation = try config_validator.validate(self.allocator, &parsed);
        errdefer validation.deinit();
        const key_copy = try self.allocator.dupe(u8, key);
        return .{
            .allocator = self.allocator,
            .config = parsed,
            .validation = validation,
            .origin = .managed_revision,
            .identity = .{ .key = key_copy, .revision = revision },
        };
    }
};

fn findProfile(
    profiles: []const config_catalog.Profile,
    key: []const u8,
) ?*const config_catalog.Profile {
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
