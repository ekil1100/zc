const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const config_bundle = @import("config_bundle.zig");
const config_identity = @import("config_identity.zig");

const max_manifest_bytes = 1024 * 1024;
const max_identity_bytes = 64 * 1024;
const max_source_bytes = 16 * 1024 * 1024;
const max_object_bytes = 8 * 1024 * 1024;
const max_override_script_bytes = 1024 * 1024;
const max_override_patch_bytes = 1024 * 1024;

pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

pub const OverrideArgument = Param;

pub const OverrideInput = struct {
    script_name: []const u8,
    script_bytes: []const u8,
    command: []const u8,
    config_path: ?[]const u8 = null,
    timeout_ms: u32 = 500,
    args: []const OverrideArgument = &.{},
    patch_bytes: []const u8,
};

pub const MetadataInput = struct {
    url: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    params: []const Param = &.{},
    override: ?OverrideInput = null,
};

pub const PublishedRevision = struct {
    storage_id: [32]u8,
    storage_id_hex: [64]u8,
    revision: config_identity.Revision,

    pub fn storageIdHex(self: *const PublishedRevision) []const u8 {
        return &self.storage_id_hex;
    }
};

pub const OwnedMetadata = struct {
    allocator: std.mem.Allocator,
    url: ?[]const u8,
    filename: ?[]const u8,
    params: []Param,

    fn deinit(self: *OwnedMetadata) void {
        if (self.url) |value| self.allocator.free(value);
        if (self.filename) |value| self.allocator.free(value);
        for (self.params) |param| {
            self.allocator.free(param.key);
            self.allocator.free(param.value);
        }
        self.allocator.free(self.params);
        self.* = undefined;
    }
};

pub const ViewAsset = struct {
    logical_path: []const u8,
    canonical_relative_target: []const u8,
    object_id: [32]u8,
    bytes: []const u8,
};

pub const ViewRemote = struct {
    provider_name: []const u8,
    logical_path: []const u8,
};

pub const ViewOverride = struct {
    script_name: []const u8,
    script_bytes: []const u8,
    command: []const u8,
    config_path: ?[]const u8,
    timeout_ms: u32,
    args: []Param,
    patch_bytes: []const u8,
};

pub const RevisionView = struct {
    allocator: std.mem.Allocator,
    key: []const u8,
    storage_id: [32]u8,
    revision: config_identity.Revision,
    metadata: OwnedMetadata,
    override: ?ViewOverride,
    source_bytes: []const u8,
    materialized_bytes: ?[]const u8,
    assets: []ViewAsset,
    remotes: []ViewRemote,
    aggregate_bytes: usize,

    pub fn deinit(self: *RevisionView) void {
        self.allocator.free(self.key);
        self.metadata.deinit();
        if (self.override) |frozen| deinitViewOverride(self.allocator, frozen);
        self.allocator.free(self.source_bytes);
        if (self.materialized_bytes) |bytes| self.allocator.free(bytes);
        for (self.assets) |asset| {
            self.allocator.free(asset.logical_path);
            self.allocator.free(asset.canonical_relative_target);
            self.allocator.free(asset.bytes);
        }
        self.allocator.free(self.assets);
        for (self.remotes) |remote| {
            self.allocator.free(remote.provider_name);
            self.allocator.free(remote.logical_path);
        }
        self.allocator.free(self.remotes);
        self.* = undefined;
    }

    pub fn sourceBytes(self: *const RevisionView) []const u8 {
        return self.source_bytes;
    }

    pub fn effectiveSourceBytes(self: *const RevisionView) []const u8 {
        return self.materialized_bytes orelse self.source_bytes;
    }

    pub fn resolveLocal(self: *const RevisionView, logical_path: []const u8) ![]const u8 {
        var low: usize = 0;
        var high = self.assets.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, logical_path, self.assets[mid].logical_path)) {
                .lt => high = mid,
                .gt => low = mid + 1,
                .eq => return self.assets[mid].bytes,
            }
        }
        return error.AssetNotDeclared;
    }
};

const DiskIdentity = struct {
    schema_version: u32,
    key: []const u8,
    storage_id: []const u8,
};

const DiskParam = struct {
    key: []const u8,
    value: []const u8,
};

const DiskMetadata = struct {
    url: ?[]const u8,
    filename: ?[]const u8,
    params: []const DiskParam,
};

const DiskContent = struct {
    size: usize,
    sha256: []const u8,
};

const DiskOverride = struct {
    script_name: []const u8,
    script: DiskContent,
    command: []const u8,
    config_path: ?[]const u8,
    timeout_ms: u32,
    args: []const DiskParam,
    patch: DiskContent,
};

const DiskAsset = struct {
    logical_path: []const u8,
    canonical_relative_target: []const u8,
    object_id: []const u8,
    size: usize,
    sha256: []const u8,
};

const DiskRemote = struct {
    provider_name: []const u8,
    logical_path: []const u8,
    remote_deferred: bool,
};

const DiskManifest = struct {
    schema_version: u32,
    key: []const u8,
    storage_id: []const u8,
    revision: []const u8,
    content_digest: []const u8,
    metadata: DiskMetadata,
    override: ?DiskOverride = null,
    source: DiskContent,
    materialized_source: ?DiskContent,
    aggregate_bytes: usize,
    local_assets: []const DiskAsset,
    remote_providers: []const DiskRemote,
};

pub const RevisionStore = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, root: std.Io.Dir) RevisionStore {
        return .{ .allocator = allocator, .root = root };
    }

    pub fn publishMigration(
        self: RevisionStore,
        key: []const u8,
        bundle: *const config_bundle.ConfigBundle,
        metadata: MetadataInput,
    ) !PublishedRevision {
        if (key.len == 0) return error.InvalidKey;
        try compat.setDirPermissions(self.root, ownerDirPermissions());
        const sorted_params = try sortedParamIndexes(self.allocator, metadata.params);
        defer self.allocator.free(sorted_params);
        try validateDistinctParams(metadata.params, sorted_params);
        try validateOverrideInput(bundle, metadata.override);

        const storage_id = config_identity.StorageId.derive(key).bytes;
        const content_digest = computeBundleContentDigest(key, bundle, metadata, sorted_params);
        const revision = computeMigrationRevision(key, content_digest);
        const published = makePublished(storage_id, revision);
        const identity_bytes = try encodeIdentity(self.allocator, key, published.storageIdHex());
        defer self.allocator.free(identity_bytes);
        if (identity_bytes.len > max_identity_bytes) return error.IdentityTooLarge;

        const profiles_dir = try openOrCreateDir(self.root, "profiles");
        defer profiles_dir.close(compat.io());
        const profile_dir = try openOrCreateDir(profiles_dir, published.storageIdHex());
        defer profile_dir.close(compat.io());
        try ensureIdentity(self.allocator, profile_dir, key, published.storageIdHex(), identity_bytes);

        const revisions_dir = try openOrCreateDir(profile_dir, "revisions");
        defer revisions_dir.close(compat.io());
        var revision_buffer: [32]u8 = undefined;
        const revision_text = revision.formatHex(&revision_buffer);

        if (openExistingDir(revisions_dir, revision_text)) |existing| {
            existing.close(compat.io());
            var verified = try self.openVerified(key, revision);
            verified.deinit();
            try syncDir(revisions_dir);
            return published;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        var nonce: [16]u8 = undefined;
        compat.randomBytes(&nonce);
        var nonce_hex: [32]u8 = std.fmt.bytesToHex(nonce, .lower);
        const staging_name = try std.fmt.allocPrint(self.allocator, ".staging-{s}", .{&nonce_hex});
        defer self.allocator.free(staging_name);
        try revisions_dir.createDir(compat.io(), staging_name, ownerDirPermissions());
        var staging_owned = true;
        defer if (staging_owned) revisions_dir.deleteTree(compat.io(), staging_name) catch {};
        const staging = try openExistingDir(revisions_dir, staging_name);
        defer staging.close(compat.io());

        try writeSyncedFile(staging, "source.yaml", bundle.sourceBytes());
        if (bundle.materializedSourceBytes()) |bytes| {
            try writeSyncedFile(staging, "materialized.yaml", bytes);
        }
        if (metadata.override) |frozen| {
            try writeSyncedFile(staging, "override-script", frozen.script_bytes);
            try writeSyncedFile(staging, "override-output.yaml", frozen.patch_bytes);
        }
        const objects = try openOrCreateDir(staging, "objects");
        defer objects.close(compat.io());
        for (bundle.manifest().local_assets) |asset| {
            const bytes = try bundle.resolveLocal(asset.logical_path);
            var object_hex: [64]u8 = std.fmt.bytesToHex(asset.content.sha256, .lower);
            try writeObject(objects, &object_hex, bytes);
        }
        try syncDir(objects);

        const manifest_bytes = try encodeManifest(
            self.allocator,
            key,
            &published,
            content_digest,
            bundle,
            metadata,
            sorted_params,
        );
        defer self.allocator.free(manifest_bytes);
        if (manifest_bytes.len > max_manifest_bytes) return error.ManifestTooLarge;
        try writeSyncedFile(staging, "manifest.json", manifest_bytes);
        try syncDir(staging);

        const publish_lock = try acquirePublishLock(revisions_dir);
        defer publish_lock.close(compat.io());
        if (openExistingDir(revisions_dir, revision_text)) |existing| {
            existing.close(compat.io());
            var verified = try self.openVerified(key, revision);
            verified.deinit();
            try syncDir(revisions_dir);
            return published;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try revisions_dir.rename(staging_name, revisions_dir, revision_text, compat.io());
        staging_owned = false;
        try syncDir(revisions_dir);
        return published;
    }

    pub fn openVerified(
        self: RevisionStore,
        key: []const u8,
        revision: config_identity.Revision,
    ) !RevisionView {
        if (key.len == 0) return error.InvalidKey;
        try compat.setDirPermissions(self.root, ownerDirPermissions());
        const storage_id = config_identity.StorageId.derive(key).bytes;
        var storage_hex: [64]u8 = std.fmt.bytesToHex(storage_id, .lower);
        var revision_hex: [32]u8 = undefined;
        const revision_text = revision.formatHex(&revision_hex);

        const profiles_dir = openExistingDir(self.root, "profiles") catch |err| return mapCorrupt(err);
        defer profiles_dir.close(compat.io());
        const profile_dir = openExistingDir(profiles_dir, &storage_hex) catch |err| return mapCorrupt(err);
        defer profile_dir.close(compat.io());
        verifyIdentity(self.allocator, profile_dir, key, &storage_hex) catch |err| return mapCorrupt(err);
        const revisions_dir = openExistingDir(profile_dir, "revisions") catch |err| return mapCorrupt(err);
        defer revisions_dir.close(compat.io());
        const revision_dir = openExistingDir(revisions_dir, revision_text) catch |err| return mapCorrupt(err);
        defer revision_dir.close(compat.io());
        const manifest_bytes = readRegularBounded(self.allocator, revision_dir, "manifest.json", max_manifest_bytes) catch |err|
            return mapCorrupt(err);
        defer self.allocator.free(manifest_bytes);
        var parsed = std.json.parseFromSlice(DiskManifest, self.allocator, manifest_bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.CorruptRevision,
        };
        defer parsed.deinit();
        const manifest = parsed.value;
        if (manifest.schema_version != 1 or
            !std.mem.eql(u8, manifest.key, key) or
            !std.mem.eql(u8, manifest.storage_id, &storage_hex) or
            !std.mem.eql(u8, manifest.revision, revision_text))
        {
            return error.CorruptRevision;
        }

        if (manifest.local_assets.len > config_bundle.CaptureLimits.defaults.max_assets or
            manifest.aggregate_bytes > config_bundle.CaptureLimits.defaults.max_aggregate_bytes)
        {
            return error.CorruptRevision;
        }
        const disk_content_digest = parseSha256(manifest.content_digest) catch return error.CorruptRevision;
        const source_identity = try parseDiskContent(manifest.source);
        if (source_identity.size > max_source_bytes) return error.CorruptRevision;
        var source = readRegularBounded(self.allocator, revision_dir, "source.yaml", max_source_bytes) catch |err|
            return mapCorrupt(err);
        errdefer self.allocator.free(source);
        if (!contentMatches(source, source_identity)) return error.CorruptRevision;

        var materialized: ?[]const u8 = null;
        errdefer if (materialized) |bytes| self.allocator.free(bytes);
        var materialized_identity: ?config_bundle.ContentIdentity = null;
        if (manifest.materialized_source) |disk_materialized| {
            const identity = try parseDiskContent(disk_materialized);
            if (identity.size > max_source_bytes) return error.CorruptRevision;
            const bytes = readRegularBounded(self.allocator, revision_dir, "materialized.yaml", max_source_bytes) catch |err|
                return mapCorrupt(err);
            if (!contentMatches(bytes, identity)) {
                self.allocator.free(bytes);
                return error.CorruptRevision;
            }
            materialized = bytes;
            materialized_identity = identity;
        } else if (strictFileExists(revision_dir, "materialized.yaml") catch return error.CorruptRevision) {
            return error.CorruptRevision;
        }

        var owned_override: ?ViewOverride = null;
        errdefer if (owned_override) |frozen| deinitViewOverride(self.allocator, frozen);
        if (manifest.override) |disk_override| {
            if (materialized == null) return error.CorruptRevision;
            owned_override = copyVerifiedOverride(
                self.allocator,
                revision_dir,
                disk_override,
            ) catch |err| return mapCorrupt(err);
        } else {
            if (strictFileExists(revision_dir, "override-script") catch return error.CorruptRevision) {
                return error.CorruptRevision;
            }
            if (strictFileExists(revision_dir, "override-output.yaml") catch return error.CorruptRevision) {
                return error.CorruptRevision;
            }
        }

        var owned_metadata = try copyMetadata(self.allocator, manifest.metadata);
        errdefer owned_metadata.deinit();
        try validateSortedParams(owned_metadata.params);

        const objects_dir = openExistingDir(revision_dir, "objects") catch |err| return mapCorrupt(err);
        defer objects_dir.close(compat.io());
        const assets = try self.allocator.alloc(ViewAsset, manifest.local_assets.len);
        var assets_initialized: usize = 0;
        errdefer {
            for (assets[0..assets_initialized]) |asset| {
                self.allocator.free(asset.logical_path);
                self.allocator.free(asset.canonical_relative_target);
                self.allocator.free(asset.bytes);
            }
            self.allocator.free(assets);
        }
        var aggregate = source.len;
        if (materialized) |bytes| aggregate = std.math.add(usize, aggregate, bytes.len) catch return error.CorruptRevision;
        if (aggregate > config_bundle.CaptureLimits.defaults.max_aggregate_bytes) return error.CorruptRevision;
        var previous_logical: ?[]const u8 = null;
        for (manifest.local_assets, assets) |disk_asset, *asset| {
            if (previous_logical) |previous| {
                if (std.mem.order(u8, previous, disk_asset.logical_path) != .lt) return error.CorruptRevision;
            }
            previous_logical = disk_asset.logical_path;
            if (disk_asset.size > max_object_bytes) return error.CorruptRevision;
            const declared_aggregate = std.math.add(usize, aggregate, disk_asset.size) catch return error.CorruptRevision;
            if (declared_aggregate > config_bundle.CaptureLimits.defaults.max_aggregate_bytes or
                declared_aggregate > manifest.aggregate_bytes)
            {
                return error.CorruptRevision;
            }
            const object_id = parseSha256(disk_asset.object_id) catch return error.CorruptRevision;
            const digest = parseSha256(disk_asset.sha256) catch return error.CorruptRevision;
            if (!std.mem.eql(u8, &object_id, &digest)) return error.CorruptRevision;
            const bytes = readRegularBounded(self.allocator, objects_dir, disk_asset.object_id, max_object_bytes) catch |err|
                return mapCorrupt(err);
            errdefer self.allocator.free(bytes);
            const actual_digest = sha256(bytes);
            if (bytes.len != disk_asset.size or !std.mem.eql(u8, &actual_digest, &digest)) {
                return error.CorruptRevision;
            }
            aggregate = std.math.add(usize, aggregate, bytes.len) catch return error.CorruptRevision;
            const logical_path = try self.allocator.dupe(u8, disk_asset.logical_path);
            errdefer self.allocator.free(logical_path);
            const relative_target = try self.allocator.dupe(u8, disk_asset.canonical_relative_target);
            asset.* = .{
                .logical_path = logical_path,
                .canonical_relative_target = relative_target,
                .object_id = object_id,
                .bytes = bytes,
            };
            assets_initialized += 1;
        }
        if (aggregate != manifest.aggregate_bytes) return error.CorruptRevision;

        const remotes = try self.allocator.alloc(ViewRemote, manifest.remote_providers.len);
        var remotes_initialized: usize = 0;
        errdefer {
            for (remotes[0..remotes_initialized]) |remote| {
                self.allocator.free(remote.provider_name);
                self.allocator.free(remote.logical_path);
            }
            self.allocator.free(remotes);
        }
        var previous_remote: ?[]const u8 = null;
        for (manifest.remote_providers, remotes) |disk_remote, *remote| {
            if (!disk_remote.remote_deferred) return error.CorruptRevision;
            if (previous_remote) |previous| {
                if (std.mem.order(u8, previous, disk_remote.provider_name) != .lt) return error.CorruptRevision;
            }
            previous_remote = disk_remote.provider_name;
            const provider_name = try self.allocator.dupe(u8, disk_remote.provider_name);
            errdefer self.allocator.free(provider_name);
            const logical_path = try self.allocator.dupe(u8, disk_remote.logical_path);
            remote.* = .{ .provider_name = provider_name, .logical_path = logical_path };
            remotes_initialized += 1;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const view = RevisionView{
            .allocator = self.allocator,
            .key = key_copy,
            .storage_id = storage_id,
            .revision = revision,
            .metadata = owned_metadata,
            .override = owned_override,
            .source_bytes = source,
            .materialized_bytes = materialized,
            .assets = assets,
            .remotes = remotes,
            .aggregate_bytes = aggregate,
        };
        const computed_digest = computeViewContentDigest(&view, source_identity, materialized_identity);
        if (!std.mem.eql(u8, &computed_digest, &disk_content_digest) or
            !computeMigrationRevision(key, computed_digest).eql(revision))
        {
            return error.CorruptRevision;
        }

        // Ownership moves into the returned view.
        owned_metadata = undefined;
        owned_override = null;
        source = &.{};
        materialized = null;
        assets_initialized = 0;
        remotes_initialized = 0;
        return view;
    }
};

fn ownerDirPermissions() std.Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_dir;
    return std.Io.File.Permissions.fromMode(0o700);
}

fn ownerFilePermissions() std.Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    return std.Io.File.Permissions.fromMode(0o600);
}

fn makePublished(storage_id: [32]u8, revision: config_identity.Revision) PublishedRevision {
    return .{
        .storage_id = storage_id,
        .storage_id_hex = std.fmt.bytesToHex(storage_id, .lower),
        .revision = revision,
    };
}

fn computeMigrationRevision(key: []const u8, content_digest: [32]u8) config_identity.Revision {
    var incarnation_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    incarnation_hasher.update("zc.migration-incarnation.v1");
    hashBytes(&incarnation_hasher, key);
    incarnation_hasher.update(&content_digest);
    const incarnation = incarnation_hasher.finalResult();

    var revision_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    revision_hasher.update("zc.revision.v1");
    revision_hasher.update(&content_digest);
    revision_hasher.update(&incarnation);
    const full = revision_hasher.finalResult();
    return .{ .bytes = full[0..16].* };
}

fn computeBundleContentDigest(
    key: []const u8,
    bundle: *const config_bundle.ConfigBundle,
    metadata: MetadataInput,
    sorted_params: []const usize,
) [32]u8 {
    var hasher = beginContentDigest(key, metadata.url, metadata.filename);
    hashParams(&hasher, metadata.params, sorted_params);
    hashOverrideInput(&hasher, metadata.override);
    const manifest = bundle.manifest();
    hashContentIdentity(&hasher, manifest.source);
    hashOptionalContentIdentity(&hasher, manifest.materialized_source);
    hashU64(&hasher, manifest.aggregate_bytes);
    for (manifest.local_assets) |asset| {
        hashBytes(&hasher, asset.logical_path);
        hashBytes(&hasher, asset.canonical_relative_target);
        hashContentIdentity(&hasher, asset.content);
    }
    hashU64(&hasher, manifest.local_assets.len);
    for (manifest.remote_providers) |remote| {
        hashBytes(&hasher, remote.provider_name);
        hashBytes(&hasher, remote.logical_path);
    }
    hashU64(&hasher, manifest.remote_providers.len);
    return hasher.finalResult();
}

fn computeViewContentDigest(
    view: *const RevisionView,
    source_identity: config_bundle.ContentIdentity,
    materialized_identity: ?config_bundle.ContentIdentity,
) [32]u8 {
    var hasher = beginContentDigest(view.key, view.metadata.url, view.metadata.filename);
    for (view.metadata.params) |param| {
        hashBytes(&hasher, param.key);
        hashBytes(&hasher, param.value);
    }
    hashU64(&hasher, view.metadata.params.len);
    hashViewOverride(&hasher, view.override);
    hashContentIdentity(&hasher, source_identity);
    hashOptionalContentIdentity(&hasher, materialized_identity);
    hashU64(&hasher, view.aggregate_bytes);
    for (view.assets) |asset| {
        hashBytes(&hasher, asset.logical_path);
        hashBytes(&hasher, asset.canonical_relative_target);
        hashContentIdentity(&hasher, .{ .size = asset.bytes.len, .sha256 = asset.object_id });
    }
    hashU64(&hasher, view.assets.len);
    for (view.remotes) |remote| {
        hashBytes(&hasher, remote.provider_name);
        hashBytes(&hasher, remote.logical_path);
    }
    hashU64(&hasher, view.remotes.len);
    return hasher.finalResult();
}

fn beginContentDigest(key: []const u8, url: ?[]const u8, filename: ?[]const u8) std.crypto.hash.sha2.Sha256 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("zc.revision-content.v1");
    hashBytes(&hasher, key);
    hashOptionalBytes(&hasher, url);
    hashOptionalBytes(&hasher, filename);
    return hasher;
}

fn hashParams(hasher: *std.crypto.hash.sha2.Sha256, params: anytype, indexes: []const usize) void {
    for (indexes) |index| {
        hashBytes(hasher, params[index].key);
        hashBytes(hasher, params[index].value);
    }
    hashU64(hasher, indexes.len);
}

fn hashOverrideInput(
    hasher: *std.crypto.hash.sha2.Sha256,
    frozen: ?OverrideInput,
) void {
    const value = frozen orelse return;
    hasher.update("zc.override-materialization.v1");
    hashBytes(hasher, value.script_name);
    hashBytes(hasher, value.script_bytes);
    hashBytes(hasher, value.command);
    hashOptionalBytes(hasher, value.config_path);
    hashU64(hasher, value.timeout_ms);
    for (value.args) |argument| {
        hashBytes(hasher, argument.key);
        hashBytes(hasher, argument.value);
    }
    hashU64(hasher, value.args.len);
    hashBytes(hasher, value.patch_bytes);
}

fn hashViewOverride(
    hasher: *std.crypto.hash.sha2.Sha256,
    frozen: ?ViewOverride,
) void {
    const value = frozen orelse return;
    hasher.update("zc.override-materialization.v1");
    hashBytes(hasher, value.script_name);
    hashBytes(hasher, value.script_bytes);
    hashBytes(hasher, value.command);
    hashOptionalBytes(hasher, value.config_path);
    hashU64(hasher, value.timeout_ms);
    for (value.args) |argument| {
        hashBytes(hasher, argument.key);
        hashBytes(hasher, argument.value);
    }
    hashU64(hasher, value.args.len);
    hashBytes(hasher, value.patch_bytes);
}

fn hashOptionalBytes(hasher: *std.crypto.hash.sha2.Sha256, value: ?[]const u8) void {
    const present = [_]u8{if (value == null) 0 else 1};
    hasher.update(&present);
    if (value) |bytes| hashBytes(hasher, bytes);
}

fn hashContentIdentity(hasher: *std.crypto.hash.sha2.Sha256, identity: config_bundle.ContentIdentity) void {
    hashU64(hasher, identity.size);
    hasher.update(&identity.sha256);
}

fn hashOptionalContentIdentity(
    hasher: *std.crypto.hash.sha2.Sha256,
    identity: ?config_bundle.ContentIdentity,
) void {
    const present = [_]u8{if (identity == null) 0 else 1};
    hasher.update(&present);
    if (identity) |value| hashContentIdentity(hasher, value);
}

fn hashBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    hashU64(hasher, bytes.len);
    hasher.update(bytes);
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .big);
    hasher.update(&encoded);
}

fn sortedParamIndexes(allocator: std.mem.Allocator, params: []const Param) ![]usize {
    const indexes = try allocator.alloc(usize, params.len);
    for (indexes, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, indexes, params, struct {
        fn lessThan(values: []const Param, left: usize, right: usize) bool {
            const key_order = std.mem.order(u8, values[left].key, values[right].key);
            if (key_order != .eq) return key_order == .lt;
            return std.mem.order(u8, values[left].value, values[right].value) == .lt;
        }
    }.lessThan);
    return indexes;
}

fn validateDistinctParams(params: []const Param, indexes: []const usize) !void {
    var previous: ?[]const u8 = null;
    for (indexes) |index| {
        if (params[index].key.len == 0) return error.InvalidMetadata;
        if (previous) |key| {
            if (std.mem.eql(u8, key, params[index].key)) return error.DuplicateMetadataParam;
        }
        previous = params[index].key;
    }
}

fn validateOverrideInput(
    bundle: *const config_bundle.ConfigBundle,
    frozen: ?OverrideInput,
) !void {
    const value = frozen orelse return;
    if (bundle.materializedSourceBytes() == null) return error.OverrideMaterializationMismatch;
    if (!isSingleComponent(value.script_name) or value.script_bytes.len == 0 or
        value.script_bytes.len > max_override_script_bytes or
        value.command.len == 0 or containsNul(value.command) or
        (value.config_path != null and containsNul(value.config_path.?)) or
        value.patch_bytes.len > max_override_patch_bytes)
    {
        return error.InvalidOverrideMaterialization;
    }
    for (value.args) |argument| {
        if (argument.key.len == 0 or containsNul(argument.key) or containsNul(argument.value)) {
            return error.InvalidOverrideMaterialization;
        }
    }
}

fn containsNul(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) != null;
}

fn validateSortedParams(params: []const Param) !void {
    var previous: ?[]const u8 = null;
    for (params) |param| {
        if (param.key.len == 0) return error.CorruptRevision;
        if (previous) |key| {
            if (std.mem.order(u8, key, param.key) != .lt) return error.CorruptRevision;
        }
        previous = param.key;
    }
}

fn encodeManifest(
    allocator: std.mem.Allocator,
    key: []const u8,
    published: *const PublishedRevision,
    content_digest: [32]u8,
    bundle: *const config_bundle.ConfigBundle,
    metadata: MetadataInput,
    sorted_params: []const usize,
) ![]u8 {
    const disk_params = try allocator.alloc(DiskParam, sorted_params.len);
    defer allocator.free(disk_params);
    for (sorted_params, disk_params) |index, *param| {
        param.* = .{ .key = metadata.params[index].key, .value = metadata.params[index].value };
    }

    const manifest = bundle.manifest();
    const disk_assets = try allocator.alloc(DiskAsset, manifest.local_assets.len);
    defer allocator.free(disk_assets);
    const asset_hashes = try allocator.alloc([64]u8, manifest.local_assets.len);
    defer allocator.free(asset_hashes);
    for (manifest.local_assets, disk_assets, asset_hashes) |asset, *disk, *hash| {
        hash.* = std.fmt.bytesToHex(asset.content.sha256, .lower);
        disk.* = .{
            .logical_path = asset.logical_path,
            .canonical_relative_target = asset.canonical_relative_target,
            .object_id = hash,
            .size = asset.content.size,
            .sha256 = hash,
        };
    }
    const disk_remotes = try allocator.alloc(DiskRemote, manifest.remote_providers.len);
    defer allocator.free(disk_remotes);
    for (manifest.remote_providers, disk_remotes) |remote, *disk| {
        disk.* = .{
            .provider_name = remote.provider_name,
            .logical_path = remote.logical_path,
            .remote_deferred = true,
        };
    }

    var source_hash: [64]u8 = std.fmt.bytesToHex(manifest.source.sha256, .lower);
    var materialized_hash: [64]u8 = undefined;
    const disk_materialized: ?DiskContent = if (manifest.materialized_source) |identity| blk: {
        materialized_hash = std.fmt.bytesToHex(identity.sha256, .lower);
        break :blk .{ .size = identity.size, .sha256 = &materialized_hash };
    } else null;
    const override_arg_count = if (metadata.override) |frozen| frozen.args.len else 0;
    const disk_override_args = try allocator.alloc(DiskParam, override_arg_count);
    defer allocator.free(disk_override_args);
    var override_script_hash: [64]u8 = undefined;
    var override_patch_hash: [64]u8 = undefined;
    const disk_override: ?DiskOverride = if (metadata.override) |frozen| blk: {
        for (frozen.args, disk_override_args) |argument, *disk_argument| {
            disk_argument.* = .{ .key = argument.key, .value = argument.value };
        }
        override_script_hash = std.fmt.bytesToHex(sha256(frozen.script_bytes), .lower);
        override_patch_hash = std.fmt.bytesToHex(sha256(frozen.patch_bytes), .lower);
        break :blk .{
            .script_name = frozen.script_name,
            .script = .{ .size = frozen.script_bytes.len, .sha256 = &override_script_hash },
            .command = frozen.command,
            .config_path = frozen.config_path,
            .timeout_ms = frozen.timeout_ms,
            .args = disk_override_args,
            .patch = .{ .size = frozen.patch_bytes.len, .sha256 = &override_patch_hash },
        };
    } else null;
    var revision_hex: [32]u8 = undefined;
    const revision_text = published.revision.formatHex(&revision_hex);
    var digest_hex: [64]u8 = std.fmt.bytesToHex(content_digest, .lower);

    return encodeJsonLine(allocator, DiskManifest{
        .schema_version = 1,
        .key = key,
        .storage_id = published.storageIdHex(),
        .revision = revision_text,
        .content_digest = &digest_hex,
        .metadata = .{
            .url = metadata.url,
            .filename = metadata.filename,
            .params = disk_params,
        },
        .override = disk_override,
        .source = .{ .size = manifest.source.size, .sha256 = &source_hash },
        .materialized_source = disk_materialized,
        .aggregate_bytes = manifest.aggregate_bytes,
        .local_assets = disk_assets,
        .remote_providers = disk_remotes,
    });
}

fn encodeIdentity(allocator: std.mem.Allocator, key: []const u8, storage_id: []const u8) ![]u8 {
    return encodeJsonLine(allocator, DiskIdentity{
        .schema_version = 1,
        .key = key,
        .storage_id = storage_id,
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

fn ensureIdentity(
    allocator: std.mem.Allocator,
    profile_dir: std.Io.Dir,
    key: []const u8,
    storage_id: []const u8,
    encoded: []const u8,
) !void {
    if (try strictFileExists(profile_dir, "identity.json")) {
        try verifyIdentity(allocator, profile_dir, key, storage_id);
        try syncDir(profile_dir);
        return;
    }

    var nonce: [16]u8 = undefined;
    compat.randomBytes(&nonce);
    var nonce_hex: [32]u8 = std.fmt.bytesToHex(nonce, .lower);
    const temp_name = try std.fmt.allocPrint(allocator, ".identity-{s}.tmp", .{&nonce_hex});
    defer allocator.free(temp_name);
    const file = try profile_dir.createFile(compat.io(), temp_name, .{
        .exclusive = true,
        .permissions = ownerFilePermissions(),
    });
    defer file.close(compat.io());
    var temp_owned = true;
    defer if (temp_owned) profile_dir.deleteFile(compat.io(), temp_name) catch {};
    try compat.fileWriteAll(file, encoded);
    try file.sync(compat.io());
    profile_dir.hardLink(temp_name, profile_dir, "identity.json", compat.io(), .{}) catch |err| switch (err) {
        error.PathAlreadyExists => try verifyIdentity(allocator, profile_dir, key, storage_id),
        else => return err,
    };
    try profile_dir.deleteFile(compat.io(), temp_name);
    temp_owned = false;
    try syncDir(profile_dir);
    try verifyIdentity(allocator, profile_dir, key, storage_id);
}

fn verifyIdentity(allocator: std.mem.Allocator, profile_dir: std.Io.Dir, key: []const u8, storage_id: []const u8) !void {
    const bytes = try readRegularBounded(allocator, profile_dir, "identity.json", max_identity_bytes);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(DiskIdentity, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value.schema_version != 1 or
        !std.mem.eql(u8, parsed.value.key, key) or
        !std.mem.eql(u8, parsed.value.storage_id, storage_id))
    {
        return error.StorageIdentityCollision;
    }
}

fn writeObject(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    if (!isSingleComponent(name)) return error.InvalidStoragePath;
    const file = dir.createFile(compat.io(), name, .{
        .exclusive = true,
        .permissions = ownerFilePermissions(),
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const existing = try readRegularBounded(std.heap.page_allocator, dir, name, max_object_bytes);
            defer std.heap.page_allocator.free(existing);
            if (!std.mem.eql(u8, existing, bytes)) return error.ObjectCollision;
            return;
        },
        else => return err,
    };
    defer file.close(compat.io());
    try compat.fileWriteAll(file, bytes);
    try file.sync(compat.io());
}

fn isSingleComponent(name: []const u8) bool {
    return name.len != 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\\") == null;
}

fn openExistingDir(parent: std.Io.Dir, name: []const u8) !std.Io.Dir {
    if (!isSingleComponent(name)) return error.InvalidStoragePath;
    const dir = try parent.openDir(compat.io(), name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(compat.io());
    const stat = try dir.stat(compat.io());
    if (stat.kind != .directory) return error.InvalidStoragePath;
    try dir.setPermissions(compat.io(), ownerDirPermissions());
    return dir;
}

fn openOrCreateDir(parent: std.Io.Dir, name: []const u8) !std.Io.Dir {
    if (openExistingDir(parent, name)) |dir| {
        try syncDir(parent);
        return dir;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var created = false;
    parent.createDir(compat.io(), name, ownerDirPermissions()) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    if (parent.openDir(compat.io(), name, .{ .follow_symlinks = false })) |dir| {
        dir.close(compat.io());
        created = true;
    } else |_| {}
    const dir = try openExistingDir(parent, name);
    if (created) try syncDir(parent);
    return dir;
}

fn acquirePublishLock(dir: std.Io.Dir) !std.Io.File {
    const name = ".publish.lock";
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
            error.SymLinkLoop, error.IsDir => return error.InvalidPublishLock,
            else => return err,
        };
        errdefer lock.close(compat.io());
        const stat = try lock.stat(compat.io());
        if (stat.kind != .file) return error.InvalidPublishLock;
        try lock.setPermissions(compat.io(), ownerFilePermissions());
        return lock;
    }
}

fn writeSyncedFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (!isSingleComponent(path)) return error.InvalidStoragePath;
    const file = try dir.createFile(compat.io(), path, .{
        .exclusive = true,
        .permissions = ownerFilePermissions(),
    });
    defer file.close(compat.io());
    try compat.fileWriteAll(file, bytes);
    try file.sync(compat.io());
}

fn syncDir(dir: std.Io.Dir) !void {
    const file = try dir.openFile(compat.io(), ".", .{ .allow_directory = true });
    defer file.close(compat.io());
    try file.sync(compat.io());
}

fn openStrictRegular(dir: std.Io.Dir, path: []const u8) !std.Io.File {
    if (!isSingleComponent(path)) return error.InvalidStoragePath;
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
    if (stat.kind != .file) return error.InvalidRevisionFile;
    try file.setPermissions(compat.io(), ownerFilePermissions());
    return file;
}

fn strictFileExists(dir: std.Io.Dir, path: []const u8) !bool {
    const file = openStrictRegular(dir, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(compat.io());
    return true;
}

fn readRegularBounded(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    path: []const u8,
    maximum: usize,
) ![]u8 {
    const file = try openStrictRegular(dir, path);
    defer file.close(compat.io());
    return compat.fileReadBoundedAlloc(file, allocator, maximum);
}

fn parseDiskContent(disk: DiskContent) !config_bundle.ContentIdentity {
    return .{ .size = disk.size, .sha256 = try parseSha256(disk.sha256) };
}

fn parseSha256(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidDigest;
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch return error.InvalidDigest;
    return bytes;
}

fn sha256(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn contentMatches(bytes: []const u8, identity: config_bundle.ContentIdentity) bool {
    const digest = sha256(bytes);
    return bytes.len == identity.size and std.mem.eql(u8, &digest, &identity.sha256);
}

fn copyVerifiedOverride(
    allocator: std.mem.Allocator,
    revision_dir: std.Io.Dir,
    disk: DiskOverride,
) !ViewOverride {
    if (!isSingleComponent(disk.script_name) or disk.command.len == 0 or
        containsNul(disk.command) or
        (disk.config_path != null and containsNul(disk.config_path.?)) or
        disk.script.size > max_override_script_bytes or
        disk.patch.size > max_override_patch_bytes)
    {
        return error.InvalidOverrideMaterialization;
    }
    const script_identity = try parseDiskContent(disk.script);
    const patch_identity = try parseDiskContent(disk.patch);
    const script_bytes = try readRegularBounded(
        allocator,
        revision_dir,
        "override-script",
        max_override_script_bytes,
    );
    errdefer allocator.free(script_bytes);
    if (!contentMatches(script_bytes, script_identity) or script_bytes.len == 0) {
        return error.InvalidOverrideMaterialization;
    }
    const patch_bytes = try readRegularBounded(
        allocator,
        revision_dir,
        "override-output.yaml",
        max_override_patch_bytes,
    );
    errdefer allocator.free(patch_bytes);
    if (!contentMatches(patch_bytes, patch_identity)) return error.InvalidOverrideMaterialization;

    const script_name = try allocator.dupe(u8, disk.script_name);
    errdefer allocator.free(script_name);
    const command = try allocator.dupe(u8, disk.command);
    errdefer allocator.free(command);
    const config_path = if (disk.config_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (config_path) |path| allocator.free(path);
    const args = try allocator.alloc(Param, disk.args.len);
    var initialized: usize = 0;
    errdefer {
        for (args[0..initialized]) |argument| {
            allocator.free(argument.key);
            allocator.free(argument.value);
        }
        allocator.free(args);
    }
    for (disk.args, args) |argument, *owned| {
        if (argument.key.len == 0 or containsNul(argument.key) or containsNul(argument.value)) {
            return error.InvalidOverrideMaterialization;
        }
        const key = try allocator.dupe(u8, argument.key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, argument.value);
        owned.* = .{ .key = key, .value = value };
        initialized += 1;
    }
    return .{
        .script_name = script_name,
        .script_bytes = script_bytes,
        .command = command,
        .config_path = config_path,
        .timeout_ms = disk.timeout_ms,
        .args = args,
        .patch_bytes = patch_bytes,
    };
}

fn deinitViewOverride(allocator: std.mem.Allocator, frozen: ViewOverride) void {
    allocator.free(frozen.script_name);
    allocator.free(frozen.script_bytes);
    allocator.free(frozen.command);
    if (frozen.config_path) |path| allocator.free(path);
    for (frozen.args) |argument| {
        allocator.free(argument.key);
        allocator.free(argument.value);
    }
    allocator.free(frozen.args);
    allocator.free(frozen.patch_bytes);
}

fn copyMetadata(allocator: std.mem.Allocator, disk: DiskMetadata) !OwnedMetadata {
    var result = OwnedMetadata{
        .allocator = allocator,
        .url = null,
        .filename = null,
        .params = &.{},
    };
    if (disk.url) |value| result.url = try allocator.dupe(u8, value);
    errdefer if (result.url) |value| allocator.free(value);
    if (disk.filename) |value| result.filename = try allocator.dupe(u8, value);
    errdefer if (result.filename) |value| allocator.free(value);

    result.params = try allocator.alloc(Param, disk.params.len);
    var initialized: usize = 0;
    errdefer {
        for (result.params[0..initialized]) |param| {
            allocator.free(param.key);
            allocator.free(param.value);
        }
        allocator.free(result.params);
    }
    for (disk.params, result.params) |param, *owned| {
        const key = try allocator.dupe(u8, param.key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, param.value);
        owned.* = .{ .key = key, .value = value };
        initialized += 1;
    }
    return result;
}

fn mapCorrupt(err: anyerror) anyerror {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CorruptRevision,
    };
}
