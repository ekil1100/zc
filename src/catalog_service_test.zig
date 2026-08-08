const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const compat = @import("compat.zig");
const catalog_commands = @import("catalog_commands.zig");
const catalog_runtime_gate = @import("catalog_runtime_gate.zig");
const catalog_service = @import("catalog_service.zig");
const config = @import("config.zig");
const config_bundle = @import("config_bundle.zig");
const config_catalog = @import("config_catalog.zig");
const config_identity = @import("config_identity.zig");
const state_authority = @import("state_authority.zig");

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(compat.io(), bytes);
}

fn bootstrapEmpty(allocator: std.mem.Allocator, root: std.Io.Dir) !state_authority.StateToken {
    const authority = state_authority.Authority.init(allocator, root);
    var missing = try authority.inspect();
    defer missing.deinit();
    return switch (try authority.bootstrapCatalog(missing.token(), .{})) {
        .committed => |receipt| receipt.token,
        else => error.TestExpectedEqual,
    };
}

fn capture(allocator: std.mem.Allocator, root: std.Io.Dir, name: []const u8) !config_bundle.ConfigBundle {
    const path = try root.realPathFileAlloc(compat.io(), name, allocator);
    defer allocator.free(path);
    return config_bundle.ConfigBundle.capture(allocator, path, .{});
}

const RevisionNames = struct {
    allocator: std.mem.Allocator,
    names: [][]u8,

    fn deinit(self: *RevisionNames) void {
        for (self.names) |name| self.allocator.free(name);
        self.allocator.free(self.names);
        self.* = undefined;
    }
};

fn snapshotRevisions(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    key: []const u8,
) !RevisionNames {
    const storage_id = config_identity.StorageId.derive(key);
    var storage_hex: [64]u8 = undefined;
    const path = try std.fmt.allocPrint(
        allocator,
        "profiles/{s}/revisions",
        .{storage_id.formatHex(&storage_hex)},
    );
    defer allocator.free(path);
    const revisions = try root.openDir(compat.io(), path, .{ .iterate = true });
    defer revisions.close(compat.io());
    var iterator = revisions.iterate();
    var names = std.ArrayList([]u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    while (try iterator.next(compat.io())) |entry| {
        if (entry.kind != .directory) continue;
        const name = try allocator.dupe(u8, entry.name);
        names.append(allocator, name) catch |err| {
            allocator.free(name);
            return err;
        };
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    return .{ .allocator = allocator, .names = try names.toOwnedSlice(allocator) };
}

fn expectRevisionNamesEqual(expected: RevisionNames, actual: RevisionNames) !void {
    try testing.expectEqual(expected.names.len, actual.names.len);
    for (expected.names, actual.names) |expected_name, actual_name| {
        try testing.expectEqualStrings(expected_name, actual_name);
    }
}

fn containsRevision(names: RevisionNames, revision: config_identity.Revision) bool {
    var revision_hex: [32]u8 = undefined;
    const expected = revision.formatHex(&revision_hex);
    for (names.names) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}

const TreeBytesSnapshot = struct {
    allocator: std.mem.Allocator,
    records: [][]u8,

    fn deinit(self: *TreeBytesSnapshot) void {
        for (self.records) |record| self.allocator.free(record);
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

fn snapshotTreeBytes(
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
) !TreeBytesSnapshot {
    const dir = try root.openDir(compat.io(), path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(compat.io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var records = std.ArrayList([]u8).empty;
    errdefer {
        for (records.items) |record| allocator.free(record);
        records.deinit(allocator);
    }
    while (try walker.next(compat.io())) |entry| {
        const prefix = try std.fmt.allocPrint(
            allocator,
            "{s}:{s}\x00",
            .{ @tagName(entry.kind), entry.path },
        );
        defer allocator.free(prefix);
        const bytes = if (entry.kind == .file)
            try dir.readFileAlloc(
                compat.io(),
                entry.path,
                allocator,
                .limited(16 * 1024 * 1024),
            )
        else
            try allocator.alloc(u8, 0);
        defer allocator.free(bytes);
        const record = try allocator.alloc(u8, prefix.len + bytes.len);
        @memcpy(record[0..prefix.len], prefix);
        @memcpy(record[prefix.len..], bytes);
        records.append(allocator, record) catch |err| {
            allocator.free(record);
            return err;
        };
    }
    std.mem.sort([]u8, records.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    return .{
        .allocator = allocator,
        .records = try records.toOwnedSlice(allocator),
    };
}

fn expectTreeBytesEqual(
    expected: TreeBytesSnapshot,
    actual: TreeBytesSnapshot,
) !void {
    try testing.expectEqual(expected.records.len, actual.records.len);
    for (expected.records, actual.records) |expected_record, actual_record| {
        try testing.expectEqualSlices(u8, expected_record, actual_record);
    }
}

const remote_rule_set_source =
    \\mixed-port: 7890
    \\rule-providers:
    \\  deferred:
    \\    type: http
    \\    behavior: domain
    \\    url: https://example.invalid/rules.yaml
    \\    path: deferred.yaml
    \\rules:
    \\  - RULE-SET,deferred,DIRECT
    \\  - MATCH,DIRECT
;

fn malformedBundle(allocator: std.mem.Allocator, suffix: []const u8) !config_bundle.ConfigBundle {
    const source = try std.fmt.allocPrint(
        allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: recoverable
        \\    type: ss
        \\    server: {s}.example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: "obfs=http"
    ,
        .{suffix},
    );
    defer allocator.free(source);
    return config_bundle.ConfigBundle.captureCatalogMemory(
        allocator,
        source,
        null,
        .{},
    );
}

fn waitForFlag(flag: *const std.atomic.Value(bool), deadline_ms: i64) !void {
    while (!flag.load(.acquire)) {
        if (compat.monotonicMilliTimestamp() >= deadline_ms) return error.TestTimedOut;
        compat.sleepNs(std.time.ns_per_ms);
    }
}

const PublishPause = struct {
    reached: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    deadline_ms: i64,

    fn afterPreflight(context: *anyopaque) void {
        const self: *PublishPause = @ptrCast(@alignCast(context));
        self.reached.store(true, .release);
        while (!self.release.load(.acquire)) {
            if (compat.monotonicMilliTimestamp() >= self.deadline_ms) {
                self.timed_out.store(true, .release);
                return;
            }
            compat.sleepNs(std.time.ns_per_ms);
        }
    }
};

const PublishThread = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    token: state_authority.StateToken,
    expected: config_identity.Revision,
    bundle: *const config_bundle.ConfigBundle,
    hook: ?catalog_service.PublishTestHook = null,
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    outcome: ?catalog_service.PublishOutcome = null,
    failure: ?anyerror = null,

    fn run(self: *PublishThread) void {
        defer self.done.store(true, .release);
        self.started.store(true, .release);
        const service = if (self.hook) |hook|
            catalog_service.Service.initWithPublishTestHook(
                self.allocator,
                self.root,
                hook,
            )
        else
            catalog_service.Service.init(self.allocator, self.root);
        self.outcome = service.publish(self.token, .{
            .key = "home",
            .expected = .{ .revision = self.expected },
            .bundle = self.bundle,
            .desired = .clear,
        }) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "CatalogService exposes publish synchronization callbacks only in tests" {
    try testing.expect(builtin.is_test);
    try testing.expect(@sizeOf(catalog_service.PublishTestHook) > 0);
    const service_fields = @typeInfo(catalog_service.Service).@"struct".fields;
    var found_hook_storage = false;
    inline for (service_fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "publish_test_hook")) continue;
        found_hook_storage = true;
        try testing.expect(field.type == ?catalog_service.PublishTestHook);
    }
    try testing.expect(found_hook_storage);
}

const ActivateThread = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    receipt: ?catalog_service.ApplyReceipt = null,
    failure: ?anyerror = null,

    fn run(self: *ActivateThread) void {
        defer self.done.store(true, .release);
        self.started.store(true, .release);
        self.receipt = catalog_commands.Commands.init(
            self.allocator,
            self.root,
        ).activate("home") catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "CatalogService publishes one revision and refreshes the derived legacy mirror" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var bundle = try capture(allocator, tmp.dir, "source.yaml");
    defer bundle.deinit();
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const outcome = try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &bundle,
        .metadata = .{ .url = "https://example.invalid/sub", .filename = "Home" },
        .desired = .clear,
        .activate = true,
    });
    const applied = switch (outcome) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    try testing.expect(applied.receipt.state_sync_error == null);
    try testing.expect(applied.receipt.mirror_error == null);
    try testing.expectEqual(applied.receipt.token.sequence, applied.receipt.mirror_sequence.?);

    const yaml = try tmp.dir.readFileAlloc(compat.io(), "configs/home.yaml", allocator, .limited(1024));
    defer allocator.free(yaml);
    try testing.expectEqualStrings("mixed-port: 7890\n", yaml);
    const meta = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(meta);
    try testing.expect(std.mem.indexOf(u8, meta, "\"active\":\"home\"") != null);
    try testing.expect(std.mem.indexOf(u8, meta, "https://example.invalid/sub") != null);
}

test "CatalogService desired and delete mutations refresh mirror from authoritative state" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var bundle = try capture(allocator, tmp.dir, "source.yaml");
    defer bundle.deinit();
    var token = try bootstrapEmpty(allocator, tmp.dir);
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const published = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &bundle,
        .desired = .clear,
        .activate = true,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    token = published.receipt.token;
    const selections = [_]config_catalog.Selection{.{ .group = "Proxy", .proxy = "A" }};
    const desired = switch (try service.mutate(token, .{ .set_desired = .{
        .identity = .{ .key = "home", .revision = published.revision },
        .expected_generation = 0,
        .selections = &selections,
    } })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    token = desired.token;
    const meta = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(meta);
    try testing.expect(std.mem.indexOf(u8, meta, "\"Proxy\":\"A\"") != null);

    const deleted = switch (try service.mutate(token, .{ .delete_profile = .{
        .key = "home",
        .expected = published.revision,
    } })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    try testing.expect(deleted.mirror_error == null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(compat.io(), "configs/home.yaml", .{}));
    const after = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "\"active\":null") != null);
}

test "CatalogService reports mirror failure after authoritative state is already committed" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\nrule-providers:\n  local:\n    type: file\n    behavior: domain\n    path: home.yaml\nrules:\n  - RULE-SET,local,DIRECT\n");
    try writeFile(tmp.dir, "home.yaml", "payload:\n  - example.com\n");
    var bundle = try capture(allocator, tmp.dir, "source.yaml");
    defer bundle.deinit();
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const applied = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &bundle,
        .desired = .clear,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    try testing.expectEqual(error.LegacyMirrorCollision, applied.receipt.mirror_error.?);
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var observed = try authority.inspect();
    defer observed.deinit();
    switch (observed) {
        .catalog_v2 => |*catalog| {
            try testing.expectEqual(@as(usize, 1), catalog.catalog.state.profiles.len);
            try testing.expect(catalog.catalog.state.profiles[0].head.eql(applied.revision));
        },
        else => return error.TestExpectedEqual,
    }
}

test "CatalogService never activates a malformed raw revision" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\mixed-port: 7890
        \\proxies:
        \\  - name: recoverable
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: "obfs=http"
    ;
    var bundle = try config_bundle.ConfigBundle.captureCatalogMemory(
        allocator,
        source,
        null,
        .{},
    );
    defer bundle.deinit();
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const state_before = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_before);
    const service = catalog_service.Service.init(allocator, tmp.dir);
    try testing.expectError(
        error.ProfileNotRuntimeReady,
        service.publish(token, .{
            .key = "recovery",
            .expected = .missing,
            .bundle = &bundle,
            .desired = .clear,
            .activate = true,
        }),
    );
    const state_after = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_after);
    try testing.expectEqualStrings(state_before, state_after);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "profiles", .{}),
    );
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var rejected_state = try authority.inspect();
    defer rejected_state.deinit();
    switch (rejected_state) {
        .catalog_v2 => |*observed| {
            try testing.expect(observed.catalog.state.active == null);
            try testing.expectEqual(
                @as(usize, 0),
                observed.catalog.state.profiles.len,
            );
        },
        else => return error.TestExpectedEqual,
    }

    const published = switch (try service.publish(token, .{
        .key = "recovery",
        .expected = .missing,
        .bundle = &bundle,
        .desired = .clear,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    try testing.expectError(
        error.ProfileNotRuntimeReady,
        service.mutate(
            published.receipt.token,
            .{ .set_active = .{ .key = "recovery" } },
        ),
    );
}

test "CatalogService catalog gate rejects every unrelated inactive defect without mutation" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var ready = try capture(allocator, tmp.dir, "source.yaml");
    defer ready.deinit();
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const initial = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &ready,
        .desired = .clear,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    const state_before = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_before);
    var tree_before = try snapshotTreeBytes(allocator, tmp.dir, "profiles");
    defer tree_before.deinit();

    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
    }{
        .{
            .name = "unsupported proxy type",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - { name: recoverable, type: ss, server: example.com, port: 8388, cipher: aes-128-gcm, password: secret, plugin: obfs, plugin-opts: "obfs=http" }
            \\  - { name: disabled, type: http, server: example.com, port: 8080 }
            \\rules:
            \\  - MATCH,recoverable
            ,
        },
        .{
            .name = "bad reference",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - { name: recoverable, type: ss, server: example.com, port: 8388, cipher: aes-128-gcm, password: secret, plugin: obfs, plugin-opts: "obfs=http" }
            \\rules:
            \\  - MATCH,undefined-target
            ,
        },
        .{
            .name = "tls",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - { name: recoverable, type: ss, server: example.com, port: 8388, cipher: aes-128-gcm, password: secret, plugin: obfs, plugin-opts: "obfs=http", tls: true }
            \\rules:
            \\  - MATCH,recoverable
            ,
        },
        .{
            .name = "cipher",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - { name: recoverable, type: ss, server: example.com, port: 8388, cipher: unsupported-cipher, password: secret, plugin: obfs, plugin-opts: "obfs=http" }
            \\rules:
            \\  - MATCH,recoverable
            ,
        },
        .{
            .name = "websocket",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - name: recoverable
            \\    type: ss
            \\    server: example.com
            \\    port: 8388
            \\    cipher: aes-128-gcm
            \\    password: secret
            \\    plugin: obfs
            \\    plugin-opts: "obfs=http"
            \\    ws-opts: { path: /ws }
            \\rules:
            \\  - MATCH,recoverable
            ,
        },
        .{
            .name = "unsupported group type",
            .source =
            \\mixed-port: 7890
            \\proxies:
            \\  - { name: recoverable, type: ss, server: example.com, port: 8388, cipher: aes-128-gcm, password: secret, plugin: obfs, plugin-opts: "obfs=http" }
            \\proxy-groups:
            \\  - { name: automatic, type: url-test, proxies: [recoverable], url: "https://example.com/ping" }
            \\rules:
            \\  - MATCH,automatic
            ,
        },
    };

    for (cases) |case| {
        var bundle = try config_bundle.ConfigBundle.captureCatalogMemory(
            allocator,
            case.source,
            null,
            .{},
        );
        defer bundle.deinit();
        try testing.expectEqual(
            config_bundle.SemanticState.malformed,
            bundle.semanticState(),
        );
        testing.expectError(
            error.ProfileNotRuntimeReady,
            service.publish(initial.receipt.token, .{
                .key = "home",
                .expected = .{ .revision = initial.revision },
                .bundle = &bundle,
                .desired = .clear,
            }),
        ) catch |err| {
            std.debug.print("catalog gate case failed: {s}\n", .{case.name});
            return err;
        };
        const state_after = try tmp.dir.readFileAlloc(
            compat.io(),
            "state-v2.json",
            allocator,
            .limited(1024 * 1024),
        );
        defer allocator.free(state_after);
        try testing.expectEqualStrings(state_before, state_after);
        var tree_after = try snapshotTreeBytes(allocator, tmp.dir, "profiles");
        defer tree_after.deinit();
        try expectTreeBytesEqual(tree_before, tree_after);
    }
}

test "catalog gates reject deferred remote RULE-SET and admit captured or unused providers" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var remote = try config_bundle.ConfigBundle.captureMemory(
        allocator,
        remote_rule_set_source,
        null,
        .{},
    );
    defer remote.deinit();
    try testing.expectError(
        error.ProfileNotRuntimeReady,
        catalog_runtime_gate.ensureBundleCatalogAdmissible(allocator, &remote),
    );
    try testing.expectError(
        error.ProfileNotRuntimeReady,
        catalog_runtime_gate.ensureBundleRuntimeReady(allocator, &remote),
    );

    var unused = try config_bundle.ConfigBundle.captureMemory(
        allocator,
        \\mixed-port: 7890
        \\rule-providers:
        \\  deferred:
        \\    type: http
        \\    behavior: domain
        \\    url: https://example.invalid/unused.yaml
        \\    path: unused.yaml
        \\rules:
        \\  - MATCH,DIRECT
    ,
        null,
        .{},
    );
    defer unused.deinit();
    try catalog_runtime_gate.ensureBundleCatalogAdmissible(allocator, &unused);
    try catalog_runtime_gate.ensureBundleRuntimeReady(allocator, &unused);

    try tmp.dir.createDir(compat.io(), "captured", .default_dir);
    try writeFile(tmp.dir, "captured/config.yaml",
        \\mixed-port: 7890
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.txt
        \\rules:
        \\  - RULE-SET,local,DIRECT
        \\  - MATCH,DIRECT
    );
    try writeFile(tmp.dir, "captured/rules.txt", "example.com\n");
    const local_path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "captured/config.yaml",
        allocator,
    );
    defer allocator.free(local_path);
    var local = try config_bundle.ConfigBundle.capture(
        allocator,
        local_path,
        .{},
    );
    defer local.deinit();
    try catalog_runtime_gate.ensureBundleCatalogAdmissible(allocator, &local);
    try catalog_runtime_gate.ensureBundleRuntimeReady(allocator, &local);
}

test "CatalogService rejects inactive deferred remote RULE-SET before any revision write" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const state_before = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_before);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "profiles", .{}),
    );
    var bundle = try config_bundle.ConfigBundle.captureCatalogMemory(
        allocator,
        remote_rule_set_source,
        null,
        .{},
    );
    defer bundle.deinit();

    try testing.expectError(
        error.ProfileNotRuntimeReady,
        catalog_service.Service.init(allocator, tmp.dir).publish(token, .{
            .key = "deferred",
            .expected = .missing,
            .bundle = &bundle,
            .desired = .clear,
        }),
    );
    const state_after = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_after);
    try testing.expectEqualStrings(state_before, state_after);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(compat.io(), "profiles", .{}),
    );
}

fn writeRepeatedProviderEntries(
    dir: std.Io.Dir,
    path: []const u8,
    count: usize,
) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    for (0..count) |_| try file.writeStreamingAll(compat.io(), "x\n");
}

test "CatalogService provider aggregate overflow preserves captured state and revision tree" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var ready = try capture(allocator, tmp.dir, "source.yaml");
    defer ready.deinit();
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const initial = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &ready,
        .desired = .clear,
        .activate = true,
    })) {
        .applied => |value| value,
        .conflict => return error.TestExpectedEqual,
    };

    try tmp.dir.createDir(compat.io(), "candidate", .default_dir);
    try writeFile(tmp.dir, "candidate/config.yaml",
        \\mixed-port: 7890
        \\rule-providers:
        \\  local:
        \\    type: file
        \\    behavior: domain
        \\    path: rules.txt
        \\rules:
        \\  - RULE-SET,local,DIRECT
        \\  - MATCH,DIRECT
    );
    try writeRepeatedProviderEntries(
        tmp.dir,
        "candidate/rules.txt",
        @import("config.zig").yaml_collection_entry_count_max + 1,
    );
    const candidate_path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "candidate/config.yaml",
        allocator,
    );
    defer allocator.free(candidate_path);
    var candidate = try config_bundle.ConfigBundle.capture(
        allocator,
        candidate_path,
        .{},
    );
    defer candidate.deinit();

    const state_before = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_before);
    var tree_before = try snapshotTreeBytes(allocator, tmp.dir, "profiles");
    defer tree_before.deinit();
    try testing.expectError(
        error.RuleProviderAggregateEntryCountLimitExceeded,
        service.publish(initial.receipt.token, .{
            .key = "home",
            .expected = .{ .revision = initial.revision },
            .bundle = &candidate,
            .desired = .clear,
        }),
    );
    const state_after = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_after);
    try testing.expectEqualStrings(state_before, state_after);
    var tree_after = try snapshotTreeBytes(allocator, tmp.dir, "profiles");
    defer tree_after.deinit();
    try expectTreeBytesEqual(tree_before, tree_after);
}

fn writeExpandedBytesLimitConfig(
    dir: std.Io.Dir,
    path: []const u8,
    target_len: usize,
) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(
        compat.io(),
        "mixed-port: 7890\n" ++
            "rule-providers:\n" ++
            "  local:\n" ++
            "    type: file\n" ++
            "    behavior: domain\n" ++
            "    path: rules.txt\n" ++
            "rules:\n" ++
            "  - RULE-SET,local,",
    );
    var chunk: [4096]u8 = @splat('x');
    var remaining = target_len;
    while (remaining > 0) {
        const count = @min(remaining, chunk.len);
        try file.writeStreamingAll(compat.io(), chunk[0..count]);
        remaining -= count;
    }
    try file.writeStreamingAll(
        compat.io(),
        "\n  - MATCH,DIRECT\n",
    );
}

test "CatalogService expanded target bytes overflow preserves state and revision tree" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var ready = try capture(allocator, tmp.dir, "source.yaml");
    defer ready.deinit();
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const initial = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &ready,
        .desired = .clear,
        .activate = true,
    })) {
        .applied => |value| value,
        .conflict => return error.TestExpectedEqual,
    };

    try tmp.dir.createDir(compat.io(), "expanded-candidate", .default_dir);
    try writeFile(
        tmp.dir,
        "expanded-candidate/rules.txt",
        "a\nb\nc\nd\ne\n",
    );
    const target_len = config.expanded_rule_bytes_max / 5 + 1;
    try writeExpandedBytesLimitConfig(
        tmp.dir,
        "expanded-candidate/config.yaml",
        target_len,
    );
    const candidate_path = try tmp.dir.realPathFileAlloc(
        compat.io(),
        "expanded-candidate/config.yaml",
        allocator,
    );
    defer allocator.free(candidate_path);
    var candidate = try config_bundle.ConfigBundle.capture(
        allocator,
        candidate_path,
        .{},
    );
    defer candidate.deinit();

    const state_before = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_before);
    var tree_before = try snapshotTreeBytes(allocator, tmp.dir, "profiles");
    defer tree_before.deinit();
    try testing.expectError(
        error.ExpandedRuleBytesLimitExceeded,
        service.publish(initial.receipt.token, .{
            .key = "home",
            .expected = .{ .revision = initial.revision },
            .bundle = &candidate,
            .desired = .clear,
        }),
    );
    const state_after = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_after);
    try testing.expectEqualStrings(state_before, state_after);
    var tree_after = try snapshotTreeBytes(allocator, tmp.dir, "profiles");
    defer tree_after.deinit();
    try expectTreeBytesEqual(tree_before, tree_after);
}

test "catalog admissibility gate propagates every injected allocation failure" {
    const allocator = testing.allocator;
    var bundle = try malformedBundle(allocator, "allocation-gate");
    defer bundle.deinit();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 512) return error.TestExpectedEqual;
        var failing = testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });
        catalog_runtime_gate.ensureBundleCatalogAdmissible(
            failing.allocator(),
            &bundle,
        ) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            continue;
        };
        try testing.expect(!failing.has_induced_failure);
        break;
    }
}

test "CatalogService rejects malformed active replacement before publication" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var ready = try capture(allocator, tmp.dir, "source.yaml");
    defer ready.deinit();
    var malformed = try malformedBundle(allocator, "active-replacement");
    defer malformed.deinit();
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const active = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &ready,
        .desired = .clear,
        .activate = true,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    const state_before = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_before);
    var tree_before = try snapshotRevisions(allocator, tmp.dir, "home");
    defer tree_before.deinit();

    try testing.expectError(
        error.ProfileNotRuntimeReady,
        service.publish(active.receipt.token, .{
            .key = "home",
            .expected = .{ .revision = active.revision },
            .bundle = &malformed,
            .desired = .clear,
        }),
    );
    const state_after = try tmp.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_after);
    try testing.expectEqualStrings(state_before, state_after);
    var tree_after = try snapshotRevisions(allocator, tmp.dir, "home");
    defer tree_after.deinit();
    try expectRevisionNamesEqual(tree_before, tree_after);
}

test "CatalogService stale token conflicts before malformed active identity gates" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var runtime_bundle = try capture(allocator, tmp.dir, "source.yaml");
    defer runtime_bundle.deinit();
    var malformed_bundle = try config_bundle.ConfigBundle.captureCatalogMemory(
        allocator,
        \\mixed-port: 7890
        \\proxies:
        \\  - name: recoverable
        \\    type: ss
        \\    server: example.com
        \\    port: 8388
        \\    cipher: aes-128-gcm
        \\    password: secret
        \\    plugin: obfs
        \\    plugin-opts: "obfs=http"
    ,
        null,
        .{},
    );
    defer malformed_bundle.deinit();
    try testing.expectEqual(
        config_bundle.SemanticState.malformed,
        malformed_bundle.semanticState(),
    );

    const service = catalog_service.Service.init(allocator, tmp.dir);
    const initial_token = try bootstrapEmpty(allocator, tmp.dir);
    const active = switch (try service.publish(initial_token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &runtime_bundle,
        .desired = .clear,
        .activate = true,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    const stale_token = active.receipt.token;
    const advanced = switch (try service.mutate(
        stale_token,
        .{ .set_active = .{ .key = "home" } },
    )) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };

    const stale_activate = try service.publish(stale_token, .{
        .key = "recovery",
        .expected = .missing,
        .bundle = &malformed_bundle,
        .desired = .clear,
        .activate = true,
    });
    switch (stale_activate) {
        .conflict => |actual| try testing.expect(actual.eql(advanced.token)),
        .applied => return error.TestExpectedEqual,
    }

    const stale_active_replacement = try service.publish(stale_token, .{
        .key = "home",
        .expected = .{ .revision = active.revision },
        .bundle = &malformed_bundle,
        .desired = .clear,
    });
    switch (stale_active_replacement) {
        .conflict => |actual| try testing.expect(actual.eql(advanced.token)),
        .applied => return error.TestExpectedEqual,
    }
}

test "CatalogService token and head conflicts do not publish revisions" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var initial_bundle = try capture(allocator, tmp.dir, "source.yaml");
    defer initial_bundle.deinit();
    var token = try bootstrapEmpty(allocator, tmp.dir);
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const initial = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &initial_bundle,
        .desired = .clear,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    token = initial.receipt.token;
    const advanced = switch (try service.mutate(
        token,
        .{ .set_active = .{ .key = null } },
    )) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    var before = try snapshotRevisions(allocator, tmp.dir, "home");
    defer before.deinit();

    var stale_bundle = try malformedBundle(allocator, "stale-token");
    defer stale_bundle.deinit();
    const stale = try service.publish(token, .{
        .key = "home",
        .expected = .{ .revision = initial.revision },
        .bundle = &stale_bundle,
        .desired = .clear,
    });
    switch (stale) {
        .conflict => |actual| try testing.expect(actual.eql(advanced.token)),
        .applied => return error.TestExpectedEqual,
    }
    var after_stale = try snapshotRevisions(allocator, tmp.dir, "home");
    defer after_stale.deinit();
    try expectRevisionNamesEqual(before, after_stale);

    var wrong_head_bundle = try malformedBundle(allocator, "wrong-head");
    defer wrong_head_bundle.deinit();
    try testing.expectError(
        error.ProfileIdentityConflict,
        service.publish(advanced.token, .{
            .key = "home",
            .expected = .missing,
            .bundle = &wrong_head_bundle,
            .desired = .clear,
        }),
    );
    var after_wrong_head = try snapshotRevisions(allocator, tmp.dir, "home");
    defer after_wrong_head.deinit();
    try expectRevisionNamesEqual(before, after_wrong_head);
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var observed = try authority.inspect();
    defer observed.deinit();
    try testing.expect(observed.token().eql(advanced.token));
    switch (observed) {
        .catalog_v2 => |*catalog| try testing.expect(
            catalog.catalog.state.profiles[0].head.eql(initial.revision),
        ),
        else => return error.TestExpectedEqual,
    }
}

test "CatalogService serializes malformed inactive publication before activation" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var initial_bundle = try capture(allocator, tmp.dir, "source.yaml");
    defer initial_bundle.deinit();
    var malformed = try malformedBundle(allocator, "publish-first");
    defer malformed.deinit();
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const initial = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &initial_bundle,
        .desired = .clear,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    var before = try snapshotRevisions(allocator, tmp.dir, "home");
    defer before.deinit();

    const deadline_ms = compat.monotonicMilliTimestamp() + 5_000;
    var pause: PublishPause = .{ .deadline_ms = deadline_ms };
    var publisher: PublishThread = .{
        .allocator = allocator,
        .root = tmp.dir,
        .token = initial.receipt.token,
        .expected = initial.revision,
        .bundle = &malformed,
        .hook = .{
            .context = &pause,
            .after_preflight = PublishPause.afterPreflight,
        },
    };
    const publish_thread = try std.Thread.spawn(.{}, PublishThread.run, .{&publisher});
    var publish_joined = false;
    defer {
        pause.release.store(true, .release);
        if (!publish_joined) publish_thread.join();
    }
    try waitForFlag(&pause.reached, deadline_ms);

    var activator: ActivateThread = .{ .allocator = allocator, .root = tmp.dir };
    const activate_thread = try std.Thread.spawn(.{}, ActivateThread.run, .{&activator});
    var activate_joined = false;
    defer if (!activate_joined) activate_thread.join();
    try waitForFlag(&activator.started, deadline_ms);
    pause.release.store(true, .release);
    try waitForFlag(&publisher.done, deadline_ms);
    try waitForFlag(&activator.done, deadline_ms);
    publish_thread.join();
    publish_joined = true;
    activate_thread.join();
    activate_joined = true;

    try testing.expect(!pause.timed_out.load(.acquire));
    try testing.expect(publisher.failure == null);
    const published = switch (publisher.outcome orelse return error.TestExpectedEqual) {
        .applied => |value| value,
        .conflict => return error.TestExpectedEqual,
    };
    try testing.expectEqual(error.ProfileNotRuntimeReady, activator.failure.?);
    try testing.expect(activator.receipt == null);

    var after = try snapshotRevisions(allocator, tmp.dir, "home");
    defer after.deinit();
    try testing.expectEqual(before.names.len + 1, after.names.len);
    try testing.expect(containsRevision(after, published.revision));
    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var observed = try authority.inspect();
    defer observed.deinit();
    switch (observed) {
        .catalog_v2 => |*catalog| {
            try testing.expect(catalog.catalog.state.active == null);
            try testing.expect(
                catalog.catalog.state.profiles[0].head.eql(published.revision),
            );
        },
        else => return error.TestExpectedEqual,
    }
}

test "CatalogService serializes activation before malformed inactive publication" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.yaml", "mixed-port: 7890\n");
    var initial_bundle = try capture(allocator, tmp.dir, "source.yaml");
    defer initial_bundle.deinit();
    var malformed = try malformedBundle(allocator, "activate-first");
    defer malformed.deinit();
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const initial = switch (try service.publish(token, .{
        .key = "home",
        .expected = .missing,
        .bundle = &initial_bundle,
        .desired = .clear,
    })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    var before = try snapshotRevisions(allocator, tmp.dir, "home");
    defer before.deinit();

    const authority = state_authority.Authority.init(allocator, tmp.dir);
    var guard = try authority.acquireGuard();
    var guard_held = true;
    errdefer if (guard_held) guard.deinit();
    var publisher: PublishThread = .{
        .allocator = allocator,
        .root = tmp.dir,
        .token = initial.receipt.token,
        .expected = initial.revision,
        .bundle = &malformed,
    };
    const publish_thread = try std.Thread.spawn(.{}, PublishThread.run, .{&publisher});
    var publish_joined = false;
    defer {
        if (guard_held) {
            guard.deinit();
            guard_held = false;
        }
        if (!publish_joined) publish_thread.join();
    }
    const deadline_ms = compat.monotonicMilliTimestamp() + 5_000;
    try waitForFlag(&publisher.started, deadline_ms);
    const activation = try guard.mutateCatalog(
        initial.receipt.token,
        .{ .set_active = .{ .key = "home" } },
    );
    const active_token = switch (activation) {
        .committed => |receipt| receipt.token,
        else => return error.TestExpectedEqual,
    };
    guard.deinit();
    guard_held = false;
    try waitForFlag(&publisher.done, deadline_ms);
    publish_thread.join();
    publish_joined = true;

    try testing.expect(publisher.failure == null);
    switch (publisher.outcome orelse return error.TestExpectedEqual) {
        .conflict => |actual| try testing.expect(actual.eql(active_token)),
        .applied => return error.TestExpectedEqual,
    }
    var after = try snapshotRevisions(allocator, tmp.dir, "home");
    defer after.deinit();
    try expectRevisionNamesEqual(before, after);
    var observed = try authority.inspect();
    defer observed.deinit();
    switch (observed) {
        .catalog_v2 => |*catalog| {
            const active = catalog.catalog.state.active orelse
                return error.TestExpectedEqual;
            try testing.expect(active.revision.eql(initial.revision));
            try testing.expect(
                catalog.catalog.state.profiles[0].head.eql(initial.revision),
            );
        },
        else => return error.TestExpectedEqual,
    }
}

test "CatalogService reports token conflict without refreshing mirror" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token = try bootstrapEmpty(allocator, tmp.dir);
    const service = catalog_service.Service.init(allocator, tmp.dir);
    const first = switch (try service.mutate(token, .{ .set_active = .{ .key = null } })) {
        .applied => |value| value,
        else => return error.TestExpectedEqual,
    };
    const before = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(before);
    const stale = try service.mutate(token, .{ .set_active = .{ .key = null } });
    switch (stale) {
        .conflict => |actual| try testing.expect(actual.eql(first.token)),
        else => return error.TestExpectedEqual,
    }
    const after = try tmp.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(after);
    try testing.expectEqualStrings(before, after);
}
