const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const config_mod = @import("config.zig");
const config_validator = @import("config_validator.zig");

pub const CaptureLimits = struct {
    max_source_bytes: usize = 16 * 1024 * 1024,
    max_asset_bytes: usize = 8 * 1024 * 1024,
    max_aggregate_bytes: usize = 64 * 1024 * 1024,
    max_assets: usize = 1024,

    pub const defaults: CaptureLimits = .{};

    fn validate(self: CaptureLimits) !void {
        if (self.max_source_bytes > defaults.max_source_bytes or
            self.max_asset_bytes > defaults.max_asset_bytes or
            self.max_aggregate_bytes > defaults.max_aggregate_bytes or
            self.max_assets > defaults.max_assets)
        {
            return error.LimitsExceedContract;
        }
    }
};

pub const ContentIdentity = struct {
    size: usize,
    sha256: [32]u8,
};

pub const LocalAsset = struct {
    logical_path: []const u8,
    canonical_relative_target: []const u8,
    content: ContentIdentity,
};

pub const MemoryAsset = struct {
    logical_path: []const u8,
    canonical_relative_target: []const u8,
    bytes: []const u8,
};

pub const RemoteProvider = struct {
    provider_name: []const u8,
    logical_path: []const u8,
    remote_deferred: bool = true,
};

pub const Manifest = struct {
    version: u8 = 1,
    source: ContentIdentity,
    materialized_source: ?ContentIdentity = null,
    aggregate_bytes: usize,
    local_assets: []const LocalAsset,
    remote_providers: []const RemoteProvider,
};

const CapturedAsset = struct {
    record: LocalAsset,
    bytes: []const u8,
    initial_stat: std.Io.File.Stat,
};

const ProviderRef = struct {
    name: []const u8,
    path: []const u8,
};

const CaptureHook = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) anyerror!void,
};

pub const OfflineLoad = struct {
    config: config_mod.Config,
    validation: config_validator.ValidationResult,

    pub fn deinit(self: *OfflineLoad) void {
        self.validation.deinit();
        self.config.deinit();
        self.* = undefined;
    }
};

/// Immutable, in-memory capture of a managed configuration and its local assets.
/// After capture, resolution never falls back to the source filesystem.
pub const ConfigBundle = struct {
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    materialized_bytes: ?[]const u8,
    assets: []CapturedAsset,
    remote_providers: []RemoteProvider,
    manifest_data: Manifest,

    pub fn capture(
        allocator: std.mem.Allocator,
        source_path: []const u8,
        limits: CaptureLimits,
    ) !ConfigBundle {
        return captureImpl(allocator, std.Io.Dir.cwd(), source_path, false, null, limits, null);
    }

    /// Captures dependencies from a caller-provided, already-materialized config.
    /// The original source remains available for audit and export.
    pub fn captureMaterialized(
        allocator: std.mem.Allocator,
        source_path: []const u8,
        materialized_source: []const u8,
        limits: CaptureLimits,
    ) !ConfigBundle {
        return captureImpl(
            allocator,
            std.Io.Dir.cwd(),
            source_path,
            false,
            materialized_source,
            limits,
            null,
        );
    }

    /// Captures source bytes that have no trusted filesystem root, such as a
    /// subscription response. Remote providers remain deferred; any local
    /// provider is rejected instead of consulting ambient files.
    pub fn captureMemory(
        allocator: std.mem.Allocator,
        source_bytes: []const u8,
        materialized_source: ?[]const u8,
        limits: CaptureLimits,
    ) !ConfigBundle {
        return reconstructMemory(allocator, source_bytes, materialized_source, &.{}, limits);
    }

    /// Rebuilds a bundle exclusively from already-verified immutable records.
    /// Only assets declared by the effective source are copied; missing assets
    /// fail closed and extra records never leak into the new revision.
    pub fn reconstructMemory(
        allocator: std.mem.Allocator,
        source_bytes: []const u8,
        materialized_source: ?[]const u8,
        available_assets: []const MemoryAsset,
        limits: CaptureLimits,
    ) !ConfigBundle {
        try limits.validate();
        if (source_bytes.len > limits.max_source_bytes) return error.SourceTooLarge;
        const source = try allocator.dupe(u8, source_bytes);
        errdefer allocator.free(source);
        var materialized: ?[]const u8 = null;
        errdefer if (materialized) |bytes| allocator.free(bytes);
        if (materialized_source) |bytes| {
            if (bytes.len > limits.max_source_bytes) return error.MaterializedSourceTooLarge;
            materialized = try allocator.dupe(u8, bytes);
        }
        var aggregate = try addToAggregate(0, source.len, limits.max_aggregate_bytes);
        if (materialized) |bytes| aggregate = try addToAggregate(aggregate, bytes.len, limits.max_aggregate_bytes);
        var parsed = try config_mod.parseDocument(allocator, materialized orelse source);
        defer parsed.deinit();
        var local_paths = std.ArrayList([]const u8).empty;
        defer local_paths.deinit(allocator);
        var seen_local = std.StringHashMap(void).init(allocator);
        defer seen_local.deinit();
        var remote_refs = std.ArrayList(ProviderRef).empty;
        defer remote_refs.deinit(allocator);
        for (parsed.rule_providers.items) |provider| {
            if (provider.url == null) {
                const gop = try seen_local.getOrPut(provider.path);
                if (!gop.found_existing) try local_paths.append(allocator, provider.path);
            } else try remote_refs.append(allocator, .{ .name = provider.name, .path = provider.path });
        }
        if (local_paths.items.len > limits.max_assets) return error.TooManyAssets;
        std.mem.sort([]const u8, local_paths.items, {}, lessString);
        std.mem.sort(ProviderRef, remote_refs.items, {}, lessProviderRef);
        const assets = try allocator.alloc(CapturedAsset, local_paths.items.len);
        var assets_initialized: usize = 0;
        errdefer {
            for (assets[0..assets_initialized]) |*asset| deinitAsset(allocator, asset);
            allocator.free(assets);
        }
        for (local_paths.items, assets) |logical_path, *asset| {
            var matched: ?MemoryAsset = null;
            for (available_assets) |candidate| {
                if (!std.mem.eql(u8, candidate.logical_path, logical_path)) continue;
                if (matched != null) return error.DuplicateAssetRecord;
                matched = candidate;
            }
            const input = matched orelse return error.AssetNotDeclared;
            if (input.bytes.len > limits.max_asset_bytes) return error.AssetTooLarge;
            aggregate = try addToAggregate(aggregate, input.bytes.len, limits.max_aggregate_bytes);
            const logical_copy = try allocator.dupe(u8, input.logical_path);
            errdefer allocator.free(logical_copy);
            const target_copy = try allocator.dupe(u8, input.canonical_relative_target);
            errdefer allocator.free(target_copy);
            const bytes_copy = try allocator.dupe(u8, input.bytes);
            asset.* = .{
                .record = .{
                    .logical_path = logical_copy,
                    .canonical_relative_target = target_copy,
                    .content = contentIdentity(bytes_copy),
                },
                .bytes = bytes_copy,
                .initial_stat = undefined,
            };
            assets_initialized += 1;
        }
        const remotes = try allocator.alloc(RemoteProvider, remote_refs.items.len);
        var remote_initialized: usize = 0;
        errdefer {
            for (remotes[0..remote_initialized]) |remote| {
                allocator.free(remote.provider_name);
                allocator.free(remote.logical_path);
            }
            allocator.free(remotes);
        }
        for (remote_refs.items, remotes) |provider, *remote| {
            const name = try allocator.dupe(u8, provider.name);
            errdefer allocator.free(name);
            const path = try allocator.dupe(u8, provider.path);
            remote.* = .{ .provider_name = name, .logical_path = path };
            remote_initialized += 1;
        }
        const local_manifest = try allocator.alloc(LocalAsset, assets.len);
        errdefer allocator.free(local_manifest);
        for (assets, local_manifest) |asset, *record| record.* = asset.record;
        return .{
            .allocator = allocator,
            .source_bytes = source,
            .materialized_bytes = materialized,
            .assets = assets,
            .remote_providers = remotes,
            .manifest_data = .{
                .source = contentIdentity(source),
                .materialized_source = if (materialized) |bytes| contentIdentity(bytes) else null,
                .aggregate_bytes = aggregate,
                .local_assets = local_manifest,
                .remote_providers = remotes,
            },
        };
    }

    /// Captures a single-component source relative to a caller-held directory
    /// descriptor. The descriptor is also the asset containment root, so no
    /// source or dependency lookup can escape through a rebound pathname.
    pub fn captureFromDir(
        allocator: std.mem.Allocator,
        source_dir: std.Io.Dir,
        source_path: []const u8,
        limits: CaptureLimits,
    ) !ConfigBundle {
        return captureImpl(allocator, source_dir, source_path, true, null, limits, null);
    }

    pub fn readSourceFromDir(
        allocator: std.mem.Allocator,
        source_dir: std.Io.Dir,
        source_path: []const u8,
    ) ![]u8 {
        if (!isSingleComponent(source_path)) return error.InvalidSourcePath;
        const root = try dirCanonicalPathAlloc(allocator, source_dir);
        defer allocator.free(root);
        var source_capture = try openCapturedRegularFile(allocator, source_dir, source_path);
        defer source_capture.deinit();
        if (!isStrictDescendant(root, source_capture.canonical_path)) return error.PathOutsideSourceRoot;
        const bytes = readCapturedFile(
            allocator,
            &source_capture,
            CaptureLimits.defaults.max_source_bytes,
        ) catch |err| switch (err) {
            error.FileTooLarge => return error.SourceTooLarge,
            else => return err,
        };
        errdefer allocator.free(bytes);

        const root_after = try dirCanonicalPathAlloc(allocator, source_dir);
        defer allocator.free(root_after);
        if (!std.mem.eql(u8, root, root_after)) return error.SourceChanged;
        var repeated = openCapturedRegularFile(allocator, source_dir, source_path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.SourceChanged,
        };
        defer repeated.deinit();
        if (!std.mem.eql(u8, source_capture.canonical_path, repeated.canonical_path) or
            !sameFileStat(source_capture.initial_stat, repeated.initial_stat))
        {
            return error.SourceChanged;
        }
        const repeated_bytes = readCapturedFile(
            allocator,
            &repeated,
            CaptureLimits.defaults.max_source_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.SourceChanged,
        };
        defer allocator.free(repeated_bytes);
        if (!std.mem.eql(u8, bytes, repeated_bytes)) return error.SourceChanged;
        return bytes;
    }

    pub fn captureMaterializedFromDir(
        allocator: std.mem.Allocator,
        source_dir: std.Io.Dir,
        source_path: []const u8,
        materialized_source: []const u8,
        limits: CaptureLimits,
    ) !ConfigBundle {
        return captureImpl(
            allocator,
            source_dir,
            source_path,
            true,
            materialized_source,
            limits,
            null,
        );
    }

    fn captureImpl(
        allocator: std.mem.Allocator,
        source_dir: std.Io.Dir,
        source_path: []const u8,
        bind_source_dir_root: bool,
        materialized_source: ?[]const u8,
        limits: CaptureLimits,
        hook: ?CaptureHook,
    ) !ConfigBundle {
        try limits.validate();
        if (bind_source_dir_root and !isSingleComponent(source_path)) return error.InvalidSourcePath;
        var source_capture = try openCapturedRegularFile(allocator, source_dir, source_path);
        defer source_capture.deinit();

        var owned_root: ?std.Io.Dir = null;
        defer if (owned_root) |dir| dir.close(compat.io());
        const root_hint = if (bind_source_dir_root)
            null
        else
            compat.fs.path.dirname(source_capture.canonical_path) orelse
                return error.InvalidSourcePath;
        const root_dir = if (bind_source_dir_root)
            source_dir
        else blk: {
            owned_root = try compat.fs.openDirAbsolute(root_hint.?, .{ .follow_symlinks = false });
            break :blk owned_root.?;
        };
        const root = try dirCanonicalPathAlloc(allocator, root_dir);
        defer allocator.free(root);
        if (bind_source_dir_root) {
            if (!isStrictDescendant(root, source_capture.canonical_path)) {
                return error.PathOutsideSourceRoot;
            }
        } else if (!std.mem.eql(u8, root_hint.?, root)) {
            return error.SourceChanged;
        }
        const source_lookup = if (bind_source_dir_root)
            source_path
        else
            compat.fs.path.basename(source_capture.canonical_path);
        var rooted_source = try openCapturedRegularFile(allocator, root_dir, source_lookup);
        defer rooted_source.deinit();
        if (!std.mem.eql(u8, rooted_source.canonical_path, source_capture.canonical_path) or
            !sameFileStat(rooted_source.initial_stat, source_capture.initial_stat))
        {
            return error.SourceChanged;
        }

        var source = readCapturedFile(allocator, &source_capture, limits.max_source_bytes) catch |err| switch (err) {
            error.FileTooLarge => return error.SourceTooLarge,
            else => return err,
        };
        errdefer allocator.free(source);

        var materialized: ?[]const u8 = null;
        errdefer if (materialized) |bytes| allocator.free(bytes);
        if (materialized_source) |bytes| {
            if (bytes.len > limits.max_source_bytes) return error.MaterializedSourceTooLarge;
            materialized = try allocator.dupe(u8, bytes);
        }

        var aggregate_bytes = try addToAggregate(0, source.len, limits.max_aggregate_bytes);
        if (materialized) |bytes| {
            aggregate_bytes = try addToAggregate(
                aggregate_bytes,
                bytes.len,
                limits.max_aggregate_bytes,
            );
        }

        const effective_source = materialized orelse source;
        var parsed = try config_mod.parseDocument(allocator, effective_source);
        defer parsed.deinit();

        var local_paths = std.ArrayList([]const u8).empty;
        defer local_paths.deinit(allocator);
        var seen_local = std.StringHashMap(void).init(allocator);
        defer seen_local.deinit();
        var remote_refs = std.ArrayList(ProviderRef).empty;
        defer remote_refs.deinit(allocator);

        for (parsed.rule_providers.items) |provider| {
            if (provider.url == null) {
                const gop = try seen_local.getOrPut(provider.path);
                if (!gop.found_existing) try local_paths.append(allocator, provider.path);
            } else {
                try remote_refs.append(allocator, .{ .name = provider.name, .path = provider.path });
            }
        }
        if (local_paths.items.len > limits.max_assets) return error.TooManyAssets;

        std.mem.sort([]const u8, local_paths.items, {}, lessString);
        std.mem.sort(ProviderRef, remote_refs.items, {}, lessProviderRef);

        var assets = std.ArrayList(CapturedAsset).empty;
        errdefer {
            for (assets.items) |*asset| deinitAsset(allocator, asset);
            assets.deinit(allocator);
        }
        try assets.ensureTotalCapacity(allocator, local_paths.items.len);

        for (local_paths.items) |logical_path| {
            if (bind_source_dir_root and compat.fs.path.isAbsolute(logical_path)) {
                return error.AbsoluteAssetPathNotAllowed;
            }
            const base_dir = if (compat.fs.path.isAbsolute(logical_path)) std.Io.Dir.cwd() else root_dir;
            var asset_capture = try openCapturedRegularFile(allocator, base_dir, logical_path);
            defer asset_capture.deinit();
            if (!isStrictDescendant(root, asset_capture.canonical_path)) {
                return error.PathOutsideSourceRoot;
            }

            var bytes = readCapturedFile(allocator, &asset_capture, limits.max_asset_bytes) catch |err| switch (err) {
                error.FileTooLarge => return error.AssetTooLarge,
                else => return err,
            };
            errdefer allocator.free(bytes);

            aggregate_bytes = try addToAggregate(
                aggregate_bytes,
                bytes.len,
                limits.max_aggregate_bytes,
            );

            const relative = relativeToRoot(root, asset_capture.canonical_path) orelse
                return error.PathOutsideSourceRoot;
            const logical_copy = try allocator.dupe(u8, logical_path);
            errdefer allocator.free(logical_copy);
            const relative_copy = try allocator.dupe(u8, relative);
            errdefer allocator.free(relative_copy);
            assets.appendAssumeCapacity(.{
                .record = .{
                    .logical_path = logical_copy,
                    .canonical_relative_target = relative_copy,
                    .content = contentIdentity(bytes),
                },
                .bytes = bytes,
                .initial_stat = asset_capture.initial_stat,
            });
            bytes = &.{};
        }

        if (hook) |capture_hook| try capture_hook.run(capture_hook.context);
        for (assets.items) |asset| {
            try revalidateAsset(allocator, root_dir, root, &asset, limits.max_asset_bytes);
        }
        const root_after = try dirCanonicalPathAlloc(allocator, root_dir);
        defer allocator.free(root_after);
        if (!std.mem.eql(u8, root, root_after)) return error.SourceChanged;

        var source_after_capture = openCapturedRegularFile(allocator, source_dir, source_path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.SourceChanged,
        };
        defer source_after_capture.deinit();
        if (!std.mem.eql(u8, source_capture.canonical_path, source_after_capture.canonical_path) or
            !sameFileStat(source_capture.initial_stat, source_after_capture.initial_stat))
        {
            return error.SourceChanged;
        }
        const source_after = readCapturedFile(allocator, &source_after_capture, limits.max_source_bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.SourceChanged,
        };
        defer allocator.free(source_after);
        if (!std.mem.eql(u8, source, source_after)) return error.SourceChanged;

        var remotes = try allocator.alloc(RemoteProvider, remote_refs.items.len);
        var remote_initialized: usize = 0;
        errdefer {
            for (remotes[0..remote_initialized]) |remote| {
                allocator.free(remote.provider_name);
                allocator.free(remote.logical_path);
            }
            allocator.free(remotes);
        }
        for (remote_refs.items, remotes) |provider, *remote| {
            const name = try allocator.dupe(u8, provider.name);
            errdefer allocator.free(name);
            const path = try allocator.dupe(u8, provider.path);
            remote.* = .{ .provider_name = name, .logical_path = path };
            remote_initialized += 1;
        }

        const owned_assets = try assets.toOwnedSlice(allocator);
        var owned_assets_transferred = false;
        errdefer if (!owned_assets_transferred) {
            for (owned_assets) |*asset| deinitAsset(allocator, asset);
            allocator.free(owned_assets);
        };
        const local_manifest = try allocator.alloc(LocalAsset, owned_assets.len);
        errdefer allocator.free(local_manifest);
        for (owned_assets, local_manifest) |asset, *record| record.* = asset.record;

        const manifest_data = Manifest{
            .source = contentIdentity(source),
            .materialized_source = if (materialized) |bytes| contentIdentity(bytes) else null,
            .aggregate_bytes = aggregate_bytes,
            .local_assets = local_manifest,
            .remote_providers = remotes,
        };
        const result = ConfigBundle{
            .allocator = allocator,
            .source_bytes = source,
            .materialized_bytes = materialized,
            .assets = owned_assets,
            .remote_providers = remotes,
            .manifest_data = manifest_data,
        };
        source = &.{};
        materialized = null;
        owned_assets_transferred = true;
        return result;
    }

    pub fn deinit(self: *ConfigBundle) void {
        self.allocator.free(self.source_bytes);
        if (self.materialized_bytes) |bytes| self.allocator.free(bytes);
        for (self.assets) |*asset| deinitAsset(self.allocator, asset);
        self.allocator.free(self.assets);
        self.allocator.free(self.manifest_data.local_assets);
        for (self.remote_providers) |remote| {
            self.allocator.free(remote.provider_name);
            self.allocator.free(remote.logical_path);
        }
        self.allocator.free(self.remote_providers);
        self.* = undefined;
    }

    pub fn sourceBytes(self: *const ConfigBundle) []const u8 {
        return self.source_bytes;
    }

    pub fn materializedSourceBytes(self: *const ConfigBundle) ?[]const u8 {
        return self.materialized_bytes;
    }

    pub fn effectiveSourceBytes(self: *const ConfigBundle) []const u8 {
        return self.materialized_bytes orelse self.source_bytes;
    }

    pub fn manifest(self: *const ConfigBundle) *const Manifest {
        return &self.manifest_data;
    }

    /// Reconstructs and validates a runtime-ready local view using bundle bytes only.
    pub fn loadOffline(self: *const ConfigBundle, allocator: std.mem.Allocator) !OfflineLoad {
        var config = try config_mod.parseDocument(allocator, self.effectiveSourceBytes());
        errdefer config.deinit();
        try config_mod.prepareRuleProvidersOffline(allocator, &config, self);
        var validation = try config_validator.validate(allocator, &config);
        errdefer validation.deinit();
        return .{ .config = config, .validation = validation };
    }

    /// Resolves an exact logical path from captured memory only.
    pub fn resolveLocal(self: *const ConfigBundle, logical_path: []const u8) ![]const u8 {
        var low: usize = 0;
        var high = self.assets.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, logical_path, self.assets[mid].record.logical_path)) {
                .lt => high = mid,
                .gt => low = mid + 1,
                .eq => return self.assets[mid].bytes,
            }
        }
        return error.AssetNotDeclared;
    }
};

fn deinitAsset(allocator: std.mem.Allocator, asset: *CapturedAsset) void {
    allocator.free(asset.record.logical_path);
    allocator.free(asset.record.canonical_relative_target);
    allocator.free(asset.bytes);
}

fn contentIdentity(bytes: []const u8) ContentIdentity {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .size = bytes.len, .sha256 = digest };
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn lessProviderRef(_: void, left: ProviderRef, right: ProviderRef) bool {
    const name_order = std.mem.order(u8, left.name, right.name);
    if (name_order != .eq) return name_order == .lt;
    return std.mem.order(u8, left.path, right.path) == .lt;
}

fn isSingleComponent(path: []const u8) bool {
    return path.len != 0 and !std.mem.eql(u8, path, ".") and !std.mem.eql(u8, path, "..") and
        std.mem.indexOfAny(u8, path, "/\\") == null;
}

fn isStrictDescendant(root: []const u8, path: []const u8) bool {
    return relativeToRoot(root, path) != null;
}

fn relativeToRoot(root: []const u8, path: []const u8) ?[]const u8 {
    if (path.len <= root.len or !std.mem.startsWith(u8, path, root)) return null;
    if (root.len != 0 and isPathSeparator(root[root.len - 1])) {
        return path[root.len..];
    }
    if (!isPathSeparator(path[root.len])) return null;
    return path[root.len + 1 ..];
}

fn isPathSeparator(byte: u8) bool {
    return if (builtin.os.tag == .windows)
        byte == '/' or byte == '\\'
    else
        byte == '/';
}

fn revalidateAsset(
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    root: []const u8,
    asset: *const CapturedAsset,
    max_bytes: usize,
) !void {
    const logical_path = asset.record.logical_path;
    const base_dir = if (compat.fs.path.isAbsolute(logical_path)) std.Io.Dir.cwd() else root_dir;
    var capture = openCapturedRegularFile(allocator, base_dir, logical_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.SourceChanged,
    };
    defer capture.deinit();

    const relative = relativeToRoot(root, capture.canonical_path) orelse return error.SourceChanged;
    if (!std.mem.eql(u8, relative, asset.record.canonical_relative_target) or
        !sameFileStat(capture.initial_stat, asset.initial_stat))
    {
        return error.SourceChanged;
    }

    const bytes = readCapturedFile(allocator, &capture, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.SourceChanged,
    };
    defer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes, asset.bytes)) return error.SourceChanged;
}

const CapturedRegularFile = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    canonical_path: []u8,
    initial_stat: std.Io.File.Stat,

    fn deinit(self: *CapturedRegularFile) void {
        self.file.close(compat.io());
        self.allocator.free(self.canonical_path);
        self.* = undefined;
    }
};

fn openCapturedRegularFile(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    path: []const u8,
) !CapturedRegularFile {
    const file = if (builtin.os.tag == .windows)
        try dir.openFile(compat.io(), path, .{
            .allow_directory = true,
            .follow_symlinks = true,
        })
    else blk: {
        const fd = try std.posix.openat(dir.handle, path, .{
            .ACCMODE = .RDONLY,
            .NONBLOCK = true,
            .CLOEXEC = true,
        }, 0);
        break :blk std.Io.File{ .handle = fd, .flags = .{ .nonblocking = true } };
    };
    errdefer file.close(compat.io());

    const stat = try file.stat(compat.io());
    if (stat.kind != .file) return error.NotRegularFile;
    const canonical_path = try fileCanonicalPathAlloc(allocator, file);
    return .{
        .allocator = allocator,
        .file = file,
        .canonical_path = canonical_path,
        .initial_stat = stat,
    };
}

fn readCapturedFile(
    allocator: std.mem.Allocator,
    capture: *const CapturedRegularFile,
    max_bytes: usize,
) ![]u8 {
    if (capture.initial_stat.size > max_bytes) return error.FileTooLarge;
    const bytes = try compat.fileReadBoundedAlloc(capture.file, allocator, max_bytes);
    errdefer allocator.free(bytes);

    const after = try capture.file.stat(compat.io());
    if (!sameFileStat(capture.initial_stat, after) or after.size != bytes.len) {
        return error.SourceChanged;
    }
    const canonical_after = try fileCanonicalPathAlloc(allocator, capture.file);
    defer allocator.free(canonical_after);
    if (!std.mem.eql(u8, capture.canonical_path, canonical_after)) return error.SourceChanged;
    return bytes;
}

fn fileCanonicalPathAlloc(allocator: std.mem.Allocator, file: std.Io.File) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try file.realPath(compat.io(), &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

fn dirCanonicalPathAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    const resolved = try dir.realPathFileAlloc(compat.io(), ".", allocator);
    defer allocator.free(resolved);
    return allocator.dupe(u8, resolved);
}

fn addToAggregate(current: usize, addition: usize, maximum: usize) !usize {
    const result = std.math.add(usize, current, addition) catch return error.BundleTooLarge;
    if (result > maximum) return error.BundleTooLarge;
    return result;
}

fn sameFileStat(left: std.Io.File.Stat, right: std.Io.File.Stat) bool {
    return left.kind == right.kind and
        left.inode == right.inode and
        left.nlink == right.nlink and
        left.size == right.size and
        std.meta.eql(left.mtime, right.mtime) and
        std.meta.eql(left.ctime, right.ctime);
}

test "aggregate accounting accepts the 64 MiB boundary and rejects one byte more" {
    const maximum = CaptureLimits.defaults.max_aggregate_bytes;
    try std.testing.expectEqual(maximum, try addToAggregate(maximum - 1, 1, maximum));
    try std.testing.expectError(error.BundleTooLarge, addToAggregate(maximum, 1, maximum));
    try std.testing.expectError(error.BundleTooLarge, addToAggregate(std.math.maxInt(usize), 1, maximum));
}

test "capture rejects same-content asset replacement before final revalidation" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.yaml
    ;
    const rules = "payload: []\n";
    for ([_]struct { path: []const u8, bytes: []const u8 }{
        .{ .path = "config.yaml", .bytes = source },
        .{ .path = "rules.yaml", .bytes = rules },
    }) |entry| {
        const file = try tmp.dir.createFile(compat.io(), entry.path, .{});
        defer file.close(compat.io());
        try file.writeStreamingAll(compat.io(), entry.bytes);
    }
    const replacement = try tmp.dir.createFile(compat.io(), "replacement.yaml", .{});
    try replacement.writeStreamingAll(compat.io(), rules);
    replacement.close(compat.io());

    const resolved = try tmp.dir.realPathFileAlloc(compat.io(), "config.yaml", testing.allocator);
    defer testing.allocator.free(resolved);
    const Context = struct {
        dir: std.Io.Dir,

        fn replace(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.dir.rename("replacement.yaml", self.dir, "rules.yaml", compat.io());
        }
    };
    var context = Context{ .dir = tmp.dir };
    try testing.expectError(error.SourceChanged, ConfigBundle.captureImpl(
        testing.allocator,
        std.Io.Dir.cwd(),
        resolved,
        false,
        null,
        .{},
        .{ .context = &context, .run = Context.replace },
    ));
}
