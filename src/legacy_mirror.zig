const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const config_catalog = @import("config_catalog.zig");
const revision_store = @import("revision_store.zig");
const state_authority = @import("state_authority.zig");

pub const RebuildReceipt = struct {
    sequence: u64,
    profile_count: usize,
};

pub const LegacyMirror = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, root: std.Io.Dir) LegacyMirror {
        return .{ .allocator = allocator, .root = root };
    }

    pub fn rebuild(self: LegacyMirror) !RebuildReceipt {
        try self.root.setPermissions(compat.io(), ownerDirPermissions());
        const mirror_lock = try acquireMirrorLock(self.root);
        defer mirror_lock.close(compat.io());
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var inspection = try authority.inspect();
        defer inspection.deinit();
        const observed = switch (inspection) {
            .catalog_v2 => |*value| value,
            .missing, .legacy_v1 => return error.Schema2CatalogRequired,
        };
        const store = revision_store.RevisionStore.init(self.allocator, self.root);

        var nonce: [16]u8 = undefined;
        compat.randomBytes(&nonce);
        var nonce_hex: [32]u8 = std.fmt.bytesToHex(nonce, .lower);
        const stage_name = try std.fmt.allocPrint(self.allocator, ".legacy-stage-{s}", .{&nonce_hex});
        defer self.allocator.free(stage_name);
        try self.root.createDir(compat.io(), stage_name, ownerDirPermissions());
        defer self.root.deleteTree(compat.io(), stage_name) catch {};
        const stage = try self.root.openDir(compat.io(), stage_name, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer stage.close(compat.io());
        try stage.createDir(compat.io(), "configs", ownerDirPermissions());
        const stage_configs = try stage.openDir(compat.io(), "configs", .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer stage_configs.close(compat.io());

        var published_paths = std.StringHashMap([32]u8).init(self.allocator);
        defer {
            var iterator = published_paths.iterator();
            while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
            published_paths.deinit();
        }
        for (observed.catalog.state.profiles) |profile| {
            if (!config_catalog.isManagedKey(profile.key)) return error.CorruptState;
            var view = try store.openVerified(profile.key, profile.head);
            defer view.deinit();
            const config_name = try std.fmt.allocPrint(self.allocator, "{s}.yaml", .{profile.key});
            defer self.allocator.free(config_name);
            try stagePath(
                self.allocator,
                stage_configs,
                &published_paths,
                config_name,
                view.effectiveSourceBytes(),
            );
            for (view.assets) |asset| {
                if (compat.fs.path.isAbsolute(asset.logical_path)) {
                    return error.LegacyMirrorUnsupportedPath;
                }
                try stagePath(
                    self.allocator,
                    stage_configs,
                    &published_paths,
                    asset.logical_path,
                    asset.bytes,
                );
            }
        }
        try syncTree(stage_configs);

        const meta_bytes = try encodeLegacyMeta(
            self.allocator,
            observed.catalog.state,
            &store,
        );
        defer self.allocator.free(meta_bytes);
        try writeExclusiveFile(stage, "meta.json", meta_bytes);
        try syncDir(stage);
        try syncDir(self.root);

        compat.randomBytes(&nonce);
        nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        const backup_name = try std.fmt.allocPrint(self.allocator, ".legacy-backup-{s}", .{&nonce_hex});
        defer self.allocator.free(backup_name);
        var old_moved = false;
        var new_installed = false;
        var committed = false;
        errdefer if (!committed) {
            if (new_installed) self.root.deleteTree(compat.io(), "configs") catch {};
            if (old_moved) self.root.rename(backup_name, self.root, "configs", compat.io()) catch {};
            syncDir(self.root) catch {};
        };

        if (self.root.openDir(compat.io(), "configs", .{ .follow_symlinks = false })) |existing| {
            existing.close(compat.io());
            try self.root.rename("configs", self.root, backup_name, compat.io());
            old_moved = true;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return error.InvalidLegacyMirror,
        }
        try stage.rename("configs", self.root, "configs", compat.io());
        new_installed = true;
        try syncDir(self.root);
        try stage.rename("meta.json", self.root, "meta.json", compat.io());
        // Both derived surfaces now describe the same catalog. A later sync
        // error must not roll configs back underneath the new metadata.
        committed = true;
        try syncDir(self.root);

        const written_meta = try readRegularBounded(
            self.allocator,
            self.root,
            "meta.json",
            config_catalog.max_catalog_bytes,
        );
        defer self.allocator.free(written_meta);
        if (!std.mem.eql(u8, meta_bytes, written_meta)) return error.InvalidLegacyMirror;
        if (old_moved) {
            try self.root.deleteTree(compat.io(), backup_name);
            try syncDir(self.root);
        }
        return .{
            .sequence = observed.catalog.state.sequence,
            .profile_count = observed.catalog.state.profiles.len,
        };
    }
};

fn stagePath(
    allocator: std.mem.Allocator,
    configs: std.Io.Dir,
    published: *std.StringHashMap([32]u8),
    relative_path: []const u8,
    bytes: []const u8,
) !void {
    try validateRelativePath(relative_path);
    const digest = sha256(bytes);
    if (published.get(relative_path)) |existing| {
        if (!std.mem.eql(u8, &existing, &digest)) return error.LegacyMirrorCollision;
        return;
    }
    const owned_path = try allocator.dupe(u8, relative_path);
    var path_owned = true;
    errdefer if (path_owned) allocator.free(owned_path);
    try published.put(owned_path, digest);
    path_owned = false;

    var components = std.mem.splitScalar(u8, relative_path, '/');
    var component_list = std.ArrayList([]const u8).empty;
    defer component_list.deinit(allocator);
    while (components.next()) |component| try component_list.append(allocator, component);
    var current = configs;
    var owned_dir: ?std.Io.Dir = null;
    defer if (owned_dir) |dir| dir.close(compat.io());
    for (component_list.items[0 .. component_list.items.len - 1]) |component| {
        const next = current.openDir(compat.io(), component, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                current.createDir(compat.io(), component, ownerDirPermissions()) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => return error.LegacyMirrorCollision,
                    else => return create_err,
                };
                try syncDir(current);
                break :blk try current.openDir(compat.io(), component, .{ .follow_symlinks = false });
            },
            else => return error.LegacyMirrorCollision,
        };
        if (owned_dir) |dir| dir.close(compat.io());
        owned_dir = next;
        current = next;
    }
    writeExclusiveFile(current, component_list.items[component_list.items.len - 1], bytes) catch |err| switch (err) {
        error.PathAlreadyExists, error.IsDir => return error.LegacyMirrorCollision,
        else => return err,
    };
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or compat.fs.path.isAbsolute(path) or
        std.mem.indexOfScalar(u8, path, '\\') != null)
    {
        return error.LegacyMirrorUnsupportedPath;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;
    while (components.next()) |component| : (count += 1) {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return error.LegacyMirrorUnsupportedPath;
        }
    }
    if (count == 0) return error.LegacyMirrorUnsupportedPath;
}

fn encodeLegacyMeta(
    allocator: std.mem.Allocator,
    state: config_catalog.State,
    store: *const revision_store.RevisionStore,
) ![]u8 {
    var count_buffer: [1024]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try writeLegacyMeta(&counter.writer, state, store);
    const size = counter.fullCount();
    if (size > config_catalog.max_catalog_bytes) return error.LegacyMetaTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);
    try writeLegacyMeta(&writer, state, store);
    std.debug.assert(writer.end == bytes.len);
    return bytes;
}

fn writeLegacyMeta(
    writer: *std.Io.Writer,
    state: config_catalog.State,
    store: *const revision_store.RevisionStore,
) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try json.beginObject();
    try json.objectField("active");
    if (state.active) |active| try json.write(active.key) else try json.write(null);
    try json.objectField("configs");
    try json.beginObject();
    for (state.profiles) |profile| {
        var view = try store.openVerified(profile.key, profile.head);
        defer view.deinit();
        try json.objectField(profile.key);
        try json.beginObject();
        if (view.metadata.url) |url| {
            try json.objectField("url");
            try json.write(url);
        }
        if (view.metadata.filename) |filename| {
            try json.objectField("filename");
            try json.write(filename);
        }
        if (view.metadata.params.len != 0) {
            try json.objectField("params");
            try json.beginObject();
            for (view.metadata.params) |param| {
                try json.objectField(param.key);
                try json.write(param.value);
            }
            try json.endObject();
        }
        if (profile.desired.generation != 0 or profile.desired.selections.len != 0) {
            try json.objectField("selections");
            try json.beginObject();
            for (profile.desired.selections) |selection| {
                try json.objectField(selection.group);
                try json.write(selection.proxy);
            }
            try json.endObject();
        }
        try json.endObject();
    }
    try json.endObject();
    try json.endObject();
    try writer.writeByte('\n');
}

fn acquireMirrorLock(dir: std.Io.Dir) !std.Io.File {
    const name = ".legacy-mirror.lock";
    while (true) {
        const lock = dir.openFile(compat.io(), name, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .exclusive,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                const created = dir.createFile(compat.io(), name, .{
                    .read = true,
                    .truncate = false,
                    .exclusive = true,
                    .permissions = ownerFilePermissions(),
                }) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => continue,
                    else => return create_err,
                };
                try created.sync(compat.io());
                created.close(compat.io());
                try syncDir(dir);
                continue;
            },
            error.SymLinkLoop, error.IsDir => return error.InvalidLegacyMirrorLock,
            else => return err,
        };
        errdefer lock.close(compat.io());
        const stat = try lock.stat(compat.io());
        if (stat.kind != .file) return error.InvalidLegacyMirrorLock;
        try lock.setPermissions(compat.io(), ownerFilePermissions());
        return lock;
    }
}

fn writeExclusiveFile(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), name, .{
        .exclusive = true,
        .permissions = ownerFilePermissions(),
    });
    defer file.close(compat.io());
    try compat.fileWriteAll(file, bytes);
    try file.sync(compat.io());
}

fn syncTree(dir: std.Io.Dir) !void {
    var iterator = dir.iterate();
    while (try iterator.next(compat.io())) |entry| {
        if (entry.kind != .directory) continue;
        const child = try dir.openDir(compat.io(), entry.name, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer child.close(compat.io());
        try syncTree(child);
    }
    try syncDir(dir);
}

fn syncDir(dir: std.Io.Dir) !void {
    const file = try dir.openFile(compat.io(), ".", .{ .allow_directory = true });
    defer file.close(compat.io());
    try file.sync(compat.io());
}

fn readRegularBounded(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    path: []const u8,
    limit: usize,
) ![]u8 {
    const file = try dir.openFile(compat.io(), path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(compat.io());
    const stat = try file.stat(compat.io());
    if (stat.kind != .file) return error.InvalidLegacyMirror;
    return compat.fileReadBoundedAlloc(file, allocator, limit);
}

fn sha256(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn ownerDirPermissions() std.Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_dir;
    return std.Io.File.Permissions.fromMode(0o700);
}

fn ownerFilePermissions() std.Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    return std.Io.File.Permissions.fromMode(0o600);
}
