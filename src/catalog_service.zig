const std = @import("std");
const builtin = @import("builtin");
const config_bundle = @import("config_bundle.zig");
const catalog_runtime_gate = @import("catalog_runtime_gate.zig");
const config_identity = @import("config_identity.zig");
const legacy_mirror = @import("legacy_mirror.zig");
const revision_store = @import("revision_store.zig");
const state_authority = @import("state_authority.zig");

pub const ApplyReceipt = struct {
    token: state_authority.StateToken,
    state_sync_error: ?anyerror = null,
    mirror_sequence: ?u64 = null,
    mirror_error: ?anyerror = null,
};

pub const MutationOutcome = union(enum) {
    applied: ApplyReceipt,
    conflict: state_authority.StateToken,
};

pub const PublishInput = struct {
    key: []const u8,
    expected: state_authority.ExpectedHead,
    bundle: *const config_bundle.ConfigBundle,
    metadata: revision_store.MetadataInput = .{},
    desired: state_authority.ProfileDesired,
    activate: bool = false,
};

pub const PublishReceipt = struct {
    revision: config_identity.Revision,
    receipt: ApplyReceipt,
};

pub const PublishOutcome = union(enum) {
    applied: PublishReceipt,
    conflict: state_authority.StateToken,
};

/// Test-only synchronization point after guarded logical preflight and before
/// immutable publication. In production this is `void`, so neither the public
/// type nor `Service` can carry an arbitrary callback.
pub const PublishTestHook = if (builtin.is_test) struct {
    context: *anyopaque,
    after_preflight: *const fn (context: *anyopaque) void,
} else void;

const PublishTestHookStorage = if (builtin.is_test) ?PublishTestHook else void;

/// Coordinates immutable publication, the single authoritative state commit,
/// and best-effort refresh of the derived legacy mirror. Once state is visible,
/// later durability or mirror failures are returned as receipt facts rather
/// than misleading the caller with a rollback-style error.
pub const Service = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    publish_test_hook: PublishTestHookStorage = if (builtin.is_test) null else {},

    pub fn init(allocator: std.mem.Allocator, root: std.Io.Dir) Service {
        return .{ .allocator = allocator, .root = root };
    }

    pub fn initWithPublishTestHook(
        allocator: std.mem.Allocator,
        root: std.Io.Dir,
        hook: PublishTestHook,
    ) Service {
        if (!builtin.is_test) {
            @compileError("publish hooks are available only in test builds");
        }
        return .{
            .allocator = allocator,
            .root = root,
            .publish_test_hook = hook,
        };
    }

    pub fn publish(
        self: Service,
        expected_token: state_authority.StateToken,
        input: PublishInput,
    ) !PublishOutcome {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        var guard = try authority.acquireGuard();
        var guard_held = true;
        defer if (guard_held) guard.deinit();

        const preflight = try guard.preflightCatalogPut(expected_token, .{
            .key = input.key,
            .expected = input.expected,
            .desired = input.desired,
            .activate = input.activate,
        });
        const intent = switch (preflight) {
            .accepted => |value| value,
            .conflict => |conflict| return .{ .conflict = conflict.actual },
        };
        // This gate is inside the authority guard and before the first revision
        // write. It applies to inactive publication too; only the designated
        // malformed Shadowsocks-plugin recovery form remains catalogable.
        try catalog_runtime_gate.ensureBundleCatalogAdmissible(
            self.allocator,
            input.bundle,
        );
        if (intent.creates_active_identity) {
            try catalog_runtime_gate.ensureBundleRuntimeReady(
                self.allocator,
                input.bundle,
            );
        }
        if (builtin.is_test) {
            if (self.publish_test_hook) |hook| {
                hook.after_preflight(hook.context);
            }
        }

        const store = revision_store.RevisionStore.init(self.allocator, self.root);
        const published = try store.publishMigration(
            input.key,
            input.bundle,
            input.metadata,
        );
        const outcome = try guard.mutateCatalog(expected_token, .{ .put_profile = .{
            .key = input.key,
            .expected = input.expected,
            .head = published.revision,
            .desired = input.desired,
            .activate = input.activate,
        } });

        // Legacy mirror rebuilding inspects authority again, so the publication
        // guard must be released before any best-effort refresh begins.
        guard.deinit();
        guard_held = false;
        return switch (outcome) {
            .conflict => |conflict| .{ .conflict = conflict.actual },
            .committed => |committed| .{ .applied = .{
                .revision = published.revision,
                .receipt = self.refreshMirror(committed.token, null),
            } },
            .durability_uncertain => |uncertain| .{ .applied = .{
                .revision = published.revision,
                .receipt = self.refreshMirror(
                    uncertain.receipt.token,
                    uncertain.cause,
                ),
            } },
        };
    }

    pub fn mutate(
        self: Service,
        expected_token: state_authority.StateToken,
        mutation: state_authority.CatalogMutation,
    ) !MutationOutcome {
        const authority = state_authority.Authority.init(self.allocator, self.root);
        const outcome = try authority.mutateCatalog(expected_token, mutation);
        return switch (outcome) {
            .conflict => |conflict| .{ .conflict = conflict.actual },
            .committed => |committed| .{
                .applied = self.refreshMirror(committed.token, null),
            },
            .durability_uncertain => |uncertain| .{
                .applied = self.refreshMirror(uncertain.receipt.token, uncertain.cause),
            },
        };
    }

    fn refreshMirror(
        self: Service,
        token: state_authority.StateToken,
        state_sync_error: ?anyerror,
    ) ApplyReceipt {
        const rebuilt = legacy_mirror.LegacyMirror.init(self.allocator, self.root).rebuild() catch |err| {
            return .{
                .token = token,
                .state_sync_error = state_sync_error,
                .mirror_error = err,
            };
        };
        return .{
            .token = token,
            .state_sync_error = state_sync_error,
            .mirror_sequence = rebuilt.sequence,
        };
    }
};

// Positive production compile contract. `initWithPublishTestHook` remains a
// lazy compile error if called, while ordinary production imports prove that
// Service has exactly the callback-free storage footprint.
comptime {
    if (!builtin.is_test) {
        if (PublishTestHook != void or PublishTestHookStorage != void) {
            @compileError("production catalog service exposed a publish hook type");
        }
        const CallbackFreeService = struct {
            allocator: std.mem.Allocator,
            root: std.Io.Dir,
        };
        if (@sizeOf(Service) != @sizeOf(CallbackFreeService) or
            @alignOf(Service) != @alignOf(CallbackFreeService))
        {
            @compileError("production catalog service retained callback storage");
        }
    }
}
