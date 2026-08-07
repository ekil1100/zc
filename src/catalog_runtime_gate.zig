const std = @import("std");
const config = @import("config.zig");
const config_bundle = @import("config_bundle.zig");
const config_catalog = @import("config_catalog.zig");
const config_validator = @import("config_validator.zig");
const revision_store = @import("revision_store.zig");

/// Admits an unpublished bundle to immutable catalog storage using only its
/// bounded bytes and captured assets. Catalog parsing retains the one
/// designated malformed Shadowsocks-plugin recovery case; every unrelated
/// parse, provider, reference, validation, or capability defect is rejected.
pub fn ensureBundleCatalogAdmissible(
    allocator: std.mem.Allocator,
    bundle: *const config_bundle.ConfigBundle,
) !void {
    var loaded = bundle.loadCatalogOffline(allocator) catch |err|
        return mapPreparationError(err);
    defer loaded.deinit();
    try requirePreparedManagedConfig(&loaded.config);
    if (!loaded.validation.isValid()) return error.ProfileNotRuntimeReady;
}

/// Validates an unpublished bundle using only its bounded effective bytes and
/// captured local assets. Logical parse, provider, and capability failures use
/// the same public error as the persisted-revision runtime gate.
pub fn ensureBundleRuntimeReady(
    allocator: std.mem.Allocator,
    bundle: *const config_bundle.ConfigBundle,
) !void {
    var loaded = bundle.loadOffline(allocator) catch |err|
        return mapPreparationError(err);
    defer loaded.deinit();
    try requirePreparedManagedConfig(&loaded.config);
    if (!loaded.validation.isValid()) return error.ProfileNotRuntimeReady;
}

pub fn ensureRevisionRuntimeReady(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    profile: *const config_catalog.Profile,
) !void {
    return ensureIdentityRuntimeReady(
        allocator,
        root,
        profile.key,
        profile.head,
    );
}

pub fn ensureIdentityRuntimeReady(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    key: []const u8,
    revision: @import("config_identity.zig").Revision,
) !void {
    var view = try revision_store.RevisionStore.init(
        allocator,
        root,
    ).openVerified(key, revision);
    defer view.deinit();
    var parsed = config.parseDocument(
        allocator,
        view.effectiveSourceBytes(),
    ) catch |err| return mapPreparationError(err);
    defer parsed.deinit();
    config.prepareRuleProvidersOffline(allocator, &parsed, &view) catch |err|
        return mapPreparationError(err);
    try requirePreparedManagedConfig(&parsed);
    var validation = try config_validator.validate(allocator, &parsed);
    defer validation.deinit();
    if (!validation.isValid()) return error.ProfileNotRuntimeReady;
}

fn requirePreparedManagedConfig(parsed: *const config.Config) !void {
    config.requireManagedRuleProvidersResolved(parsed) catch
        return error.ProfileNotRuntimeReady;
}

fn mapPreparationError(err: anyerror) anyerror {
    return switch (err) {
        error.OutOfMemory,
        error.YamlCollectionEntryLimitExceeded,
        error.ProxyCountLimitExceeded,
        error.ProxyGroupCountLimitExceeded,
        error.ProxyEntryCountLimitExceeded,
        error.ProxyGroupMemberCountLimitExceeded,
        error.PersistedSelectionCountLimitExceeded,
        error.RuleProviderCountLimitExceeded,
        error.RuleProviderFileTooLarge,
        error.RuleProviderAggregateEntryCountLimitExceeded,
        error.RuleProviderAggregateBytesLimitExceeded,
        error.RuleProviderAggregateSourceBytesLimitExceeded,
        error.ExpandedRuleCountLimitExceeded,
        error.ExpandedRuleBytesLimitExceeded,
        => err,
        else => error.ProfileNotRuntimeReady,
    };
}
