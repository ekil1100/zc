const std = @import("std");
const config_bundle = @import("config_bundle.zig");
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

/// Coordinates immutable publication, the single authoritative state commit,
/// and best-effort refresh of the derived legacy mirror. Once state is visible,
/// later durability or mirror failures are returned as receipt facts rather
/// than misleading the caller with a rollback-style error.
pub const Service = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, root: std.Io.Dir) Service {
        return .{ .allocator = allocator, .root = root };
    }

    pub fn publish(
        self: Service,
        expected_token: state_authority.StateToken,
        input: PublishInput,
    ) !PublishOutcome {
        const store = revision_store.RevisionStore.init(self.allocator, self.root);
        const published = try store.publishMigration(
            input.key,
            input.bundle,
            input.metadata,
        );
        return switch (try self.mutate(expected_token, .{ .put_profile = .{
            .key = input.key,
            .expected = input.expected,
            .head = published.revision,
            .desired = input.desired,
            .activate = input.activate,
        } })) {
            .applied => |receipt| .{ .applied = .{
                .revision = published.revision,
                .receipt = receipt,
            } },
            .conflict => |actual| .{ .conflict = actual },
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
