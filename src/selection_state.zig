const std = @import("std");
const catalog_service = @import("catalog_service.zig");
const compat = @import("compat.zig");
const config = @import("config.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");
const meta = @import("meta.zig");
const state_authority = @import("state_authority.zig");

const max_attempts = 4;

pub const Receipt = struct {
    identity: ?config_identity.ManagedIdentity = null,
    generation: ?u64 = null,
};

pub const DesiredSnapshot = struct {
    allocator: std.mem.Allocator,
    identity: config_identity.ManagedIdentity,
    generation: u64,
    selections: []config_catalog.Selection,

    pub fn deinit(self: *DesiredSnapshot) void {
        self.allocator.free(self.identity.key);
        for (self.selections) |selection| {
            self.allocator.free(selection.group);
            self.allocator.free(selection.proxy);
        }
        self.allocator.free(self.selections);
        self.* = undefined;
    }
};

pub fn persistDefault(
    allocator: std.mem.Allocator,
    key: []const u8,
    group: []const u8,
    proxy: []const u8,
) !Receipt {
    if (try config.getDefaultConfigDir(allocator)) |root_path| {
        defer allocator.free(root_path);
        if (!compat.fs.path.isAbsolute(root_path)) return error.NoConfigDir;
        if (compat.fs.openDirAbsolute(root_path, .{ .follow_symlinks = false })) |root| {
            defer root.close(compat.io());
            if (root.access(compat.io(), "state-v2.json", .{})) |_| {
                return State.init(allocator, root).persist(key, group, proxy);
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    var metadata = try meta.load(allocator);
    defer metadata.deinit();
    if (!metadata.configs.contains(key)) return error.ManagedProfileNotFound;
    try meta.setSelection(allocator, &metadata, key, group, proxy);
    try meta.save(allocator, &metadata);
    return .{ .identity = .{ .key = key, .revision = config_identity.legacyRevision(key) } };
}

pub fn loadDesiredDefault(
    allocator: std.mem.Allocator,
    key: []const u8,
) !?DesiredSnapshot {
    const root_path = try config.getDefaultConfigDir(allocator) orelse return null;
    defer allocator.free(root_path);
    if (!compat.fs.path.isAbsolute(root_path)) return error.NoConfigDir;
    const root = compat.fs.openDirAbsolute(root_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer root.close(compat.io());
    const authority = state_authority.Authority.init(allocator, root);
    var inspection = try authority.inspect();
    defer inspection.deinit();
    const profile = switch (inspection) {
        .catalog_v2 => |*observed| findProfile(observed.catalog.state.profiles, key) orelse
            return error.ManagedProfileNotFound,
        .missing, .legacy_v1 => return null,
    };
    const key_copy = try allocator.dupe(u8, profile.key);
    errdefer allocator.free(key_copy);
    const selections = try allocator.alloc(config_catalog.Selection, profile.desired.selections.len);
    var initialized: usize = 0;
    errdefer {
        for (selections[0..initialized]) |selection| {
            allocator.free(selection.group);
            allocator.free(selection.proxy);
        }
        allocator.free(selections);
    }
    for (profile.desired.selections, selections) |selection, *output| {
        const group = try allocator.dupe(u8, selection.group);
        errdefer allocator.free(group);
        const proxy = try allocator.dupe(u8, selection.proxy);
        output.* = .{ .group = group, .proxy = proxy };
        initialized += 1;
    }
    return .{
        .allocator = allocator,
        .identity = .{ .key = key_copy, .revision = profile.head },
        .generation = profile.desired.generation,
        .selections = selections,
    };
}

pub fn observeDefault(
    allocator: std.mem.Allocator,
    key: []const u8,
) !Receipt {
    const root_path = try config.getDefaultConfigDir(allocator) orelse return .{};
    defer allocator.free(root_path);
    if (!compat.fs.path.isAbsolute(root_path)) return error.NoConfigDir;
    const root = compat.fs.openDirAbsolute(root_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer root.close(compat.io());
    const authority = state_authority.Authority.init(allocator, root);
    var inspection = try authority.inspect();
    defer inspection.deinit();
    return switch (inspection) {
        .catalog_v2 => |*observed| if (findProfile(observed.catalog.state.profiles, key)) |profile| .{
            .identity = .{ .key = key, .revision = profile.head },
            .generation = profile.desired.generation,
        } else error.ManagedProfileNotFound,
        .missing, .legacy_v1 => .{
            .identity = .{ .key = key, .revision = config_identity.legacyRevision(key) },
            .generation = 0,
        },
    };
}

pub const State = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, root: std.Io.Dir) State {
        return .{ .allocator = allocator, .root = root };
    }

    pub fn persist(self: State, key: []const u8, group: []const u8, proxy: []const u8) !Receipt {
        for (0..max_attempts) |_| {
            const authority = state_authority.Authority.init(self.allocator, self.root);
            var inspection = try authority.inspect();
            const token = inspection.token();
            const profile = switch (inspection) {
                .catalog_v2 => |*observed| findProfile(observed.catalog.state.profiles, key) orelse {
                    inspection.deinit();
                    return error.ManagedProfileNotFound;
                },
                .missing, .legacy_v1 => {
                    inspection.deinit();
                    return error.Schema2CatalogRequired;
                },
            };
            const next = try replaceSelection(
                self.allocator,
                profile.desired.selections,
                group,
                proxy,
            );
            const revision = profile.head;
            const generation = profile.desired.generation;
            const outcome = catalog_service.Service.init(self.allocator, self.root).mutate(token, .{
                .set_desired = .{
                    .identity = .{ .key = key, .revision = revision },
                    .expected_generation = generation,
                    .selections = next,
                },
            }) catch |err| {
                self.allocator.free(next);
                inspection.deinit();
                return err;
            };
            self.allocator.free(next);
            inspection.deinit();
            switch (outcome) {
                .applied => return .{
                    .identity = .{ .key = key, .revision = revision },
                    .generation = generation + 1,
                },
                .conflict => continue,
            }
        }
        return error.StateConflict;
    }
};

fn replaceSelection(
    allocator: std.mem.Allocator,
    selections: []const config_catalog.Selection,
    group: []const u8,
    proxy: []const u8,
) ![]config_catalog.Selection {
    var found = false;
    const output = try allocator.alloc(
        config_catalog.Selection,
        selections.len + @intFromBool(!containsGroup(selections, group)),
    );
    var index: usize = 0;
    for (selections) |selection| {
        if (std.mem.eql(u8, selection.group, group)) {
            output[index] = .{ .group = group, .proxy = proxy };
            found = true;
        } else {
            output[index] = selection;
        }
        index += 1;
    }
    if (!found) output[index] = .{ .group = group, .proxy = proxy };
    return output;
}

fn containsGroup(selections: []const config_catalog.Selection, group: []const u8) bool {
    for (selections) |selection| {
        if (std.mem.eql(u8, selection.group, group)) return true;
    }
    return false;
}

fn findProfile(profiles: []const config_catalog.Profile, key: []const u8) ?*const config_catalog.Profile {
    for (profiles) |*profile| {
        if (std.mem.eql(u8, profile.key, key)) return profile;
    }
    return null;
}
