const std = @import("std");
const catalog_service = @import("catalog_service.zig");
const compat = @import("compat.zig");
const config = @import("config.zig");
const config_bundle = @import("config_bundle.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");
const legacy_bootstrap = @import("legacy_catalog_bootstrap.zig");
const state_authority = @import("state_authority.zig");

const max_attempts = 4;

pub const Receipt = struct {
    key: []const u8,
    revision: config_identity.Revision,
    active: bool,
    state_sync_error: ?anyerror = null,
    mirror_error: ?anyerror = null,

    pub fn deinit(self: *Receipt, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.* = undefined;
    }
};

pub fn loadDefault(allocator: std.mem.Allocator, source_path: []const u8) !Receipt {
    const root_path = try config.getDefaultConfigDir(allocator) orelse return error.NoConfigDir;
    defer allocator.free(root_path);
    if (!compat.fs.path.isAbsolute(root_path)) return error.NoConfigDir;
    try compat.fs.cwd().makePath(root_path);
    const root = try compat.fs.openDirAbsolute(root_path, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(compat.io());
    return Importer.init(allocator, root).load(source_path);
}

pub const Importer = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, root: std.Io.Dir) Importer {
        return .{ .allocator = allocator, .root = root };
    }

    pub fn load(self: Importer, source_path: []const u8) !Receipt {
        const key = try deriveKey(self.allocator, source_path);
        errdefer self.allocator.free(key);
        var bundle = try config_bundle.ConfigBundle.capture(self.allocator, source_path, .{});
        defer bundle.deinit();
        for (bundle.manifest().local_assets) |asset| {
            if (compat.fs.path.isAbsolute(asset.logical_path)) return error.AbsoluteAssetPathNotAllowed;
        }
        var loaded = try bundle.loadOffline(self.allocator);
        defer loaded.deinit();
        if (!loaded.validation.isValid()) return error.InvalidConfig;

        const migration = try legacy_bootstrap.LegacyCatalogBootstrap.init(self.allocator, self.root).ensure();
        switch (migration) {
            .migrated, .already_current, .durability_uncertain => {},
            .blocked => return error.LegacyMigrationBlocked,
        }

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
            if (findProfile(state.profiles, key) != null) {
                inspection.deinit();
                return error.ManagedProfileAlreadyExists;
            }
            inspection.deinit();
            const outcome = try catalog_service.Service.init(self.allocator, self.root).publish(token, .{
                .key = key,
                .expected = .missing,
                .bundle = &bundle,
                .metadata = .{ .filename = compat.fs.path.basename(source_path) },
                .desired = .clear,
                .activate = true,
            });
            switch (outcome) {
                .conflict => continue,
                .applied => |published| return .{
                    .key = key,
                    .revision = published.revision,
                    .active = true,
                    // A successful later publication rewrites and syncs both
                    // authority and mirror, superseding bootstrap health.
                    .state_sync_error = published.receipt.state_sync_error,
                    .mirror_error = published.receipt.mirror_error,
                },
            }
        }
        return error.StateConflict;
    }
};

fn deriveKey(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    const basename = compat.fs.path.basename(source_path);
    const key = if (std.mem.endsWith(u8, basename, ".yaml"))
        basename[0 .. basename.len - 5]
    else if (std.mem.endsWith(u8, basename, ".yml"))
        basename[0 .. basename.len - 4]
    else
        basename;
    if (!config_catalog.isPortableManagedKey(key)) return error.InvalidConfigKey;
    return allocator.dupe(u8, key);
}

fn findProfile(profiles: []const config_catalog.Profile, key: []const u8) ?*const config_catalog.Profile {
    for (profiles) |*profile| if (std.mem.eql(u8, profile.key, key)) return profile;
    return null;
}
