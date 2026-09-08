const std = @import("std");
const testing = std.testing;
const compat = @import("compat.zig");
const config = @import("config.zig");
const config_import = @import("config_import.zig");
const catalog_runtime_gate = @import("catalog_runtime_gate.zig");
const config_identity = @import("config_identity.zig");
const revision_store = @import("revision_store.zig");

const test_directory_options: std.Io.Dir.OpenOptions = .{
    .access_sub_paths = true,
    .iterate = false,
    .follow_symlinks = true,
};

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(compat.io(), bytes);
}

fn expectLoaded(outcome: config_import.LoadOutcome) !config_import.Receipt {
    return switch (outcome) {
        .loaded => |receipt| receipt,
        .invalid_config => |validation_value| {
            var validation = validation_value;
            validation.deinit();
            return error.ExpectedLoadedConfig;
        },
    };
}

test "config load imports a local bundle, assets, and active mirror" {
    const allocator = testing.allocator;
    var root = testing.tmpDir(.{});
    defer root.cleanup();
    var source = testing.tmpDir(.{});
    defer source.cleanup();
    try source.dir.createDir(compat.io(), "rules", .default_dir);
    try writeFile(source.dir, "rules/local.yaml", "payload:\n  - example.com\n");
    try writeFile(source.dir, "Home.yaml", "mixed-port: 7890\nrule-providers:\n  local:\n    type: file\n    behavior: domain\n    path: rules/local.yaml\nrules:\n  - RULE-SET,local,DIRECT\n");
    const source_path = try source.dir.realPathFileAlloc(compat.io(), "Home.yaml", allocator);
    defer allocator.free(source_path);

    var receipt = try expectLoaded(
        try config_import.Importer.init(allocator, root.dir).load(source_path),
    );
    defer receipt.deinit(allocator);
    try testing.expectEqualStrings("Home", receipt.key);
    try testing.expect(receipt.active);
    try testing.expectError(
        error.ManagedProfileAlreadyExists,
        config_import.Importer.init(allocator, root.dir).load(source_path),
    );
    const mirrored = try root.dir.readFileAlloc(compat.io(), "configs/Home.yaml", allocator, .limited(1024));
    defer allocator.free(mirrored);
    try testing.expect(std.mem.indexOf(u8, mirrored, "mixed-port: 7890") != null);
    const asset = try root.dir.readFileAlloc(compat.io(), "configs/rules/local.yaml", allocator, .limited(1024));
    defer allocator.free(asset);
    try testing.expectEqualStrings("payload:\n  - example.com\n", asset);
    const meta = try root.dir.readFileAlloc(compat.io(), "meta.json", allocator, .limited(4096));
    defer allocator.free(meta);
    try testing.expect(std.mem.indexOf(u8, meta, "\"active\":\"Home\"") != null);

    const config_path = try root.dir.realPathFileAlloc(compat.io(), "configs/Home.yaml", allocator);
    defer allocator.free(config_path);
    var loaded = try config.load(allocator, config_path);
    defer loaded.deinit();
    try config.prepareRuleProvidersForRuntime(allocator, &loaded, config_path);
    try testing.expectEqualStrings("example.com", loaded.rules.items[0].payload);
}

test "config load returns concrete validation diagnostics before publication" {
    // Load a focused bundle through Importer, then inspect publication,
    // diagnostics, and persisted state.
    const allocator = testing.allocator;
    var root = testing.tmpDir(test_directory_options);
    defer root.cleanup();
    var source = testing.tmpDir(test_directory_options);
    defer source.cleanup();
    try writeFile(
        source.dir,
        "Invalid.yaml",
        "mixed-port: 7890\nlog-level: verbose\nrules:\n  - MATCH,missing\n",
    );
    const source_path = try source.dir.realPathFileAlloc(
        compat.io(),
        "Invalid.yaml",
        allocator,
    );
    defer allocator.free(source_path);

    const outcome = try config_import.Importer.init(
        allocator,
        root.dir,
    ).load(source_path);
    switch (outcome) {
        .loaded => |receipt_value| {
            var receipt = receipt_value;
            receipt.deinit(allocator);
            return error.ExpectedInvalidConfig;
        },
        .invalid_config => |validation_value| {
            var validation = validation_value;
            defer validation.deinit();
            try testing.expect(!validation.isValid());
            try testing.expectEqual(@as(usize, 2), validation.errors.items.len);
            try testing.expect(
                std.mem.indexOf(
                    u8,
                    validation.errors.items[0].message,
                    "Unknown log level",
                ) != null,
            );
            try testing.expect(
                std.mem.indexOf(
                    u8,
                    validation.errors.items[1].message,
                    "undefined target 'missing'",
                ) != null,
            );
        },
    }
    try testing.expectError(
        error.FileNotFound,
        root.dir.statFile(
            compat.io(),
            "state-v2.json",
            .{ .follow_symlinks = true },
        ),
    );
}

test "config load persists and authoritatively reloads an exact 16 MiB local provider" {
    const allocator = testing.allocator;
    var root = testing.tmpDir(.{});
    defer root.cleanup();
    var source = testing.tmpDir(.{});
    defer source.cleanup();

    const provider_limit = config.config_source_bytes_max;
    const comments = try allocator.alloc(u8, provider_limit + 1);
    defer allocator.free(comments);
    @memset(comments, '#');
    try writeFile(source.dir, "comments.rules", comments[0..provider_limit]);
    const exact_source =
        \\mixed-port: 7890
        \\rule-providers:
        \\  comments:
        \\    type: file
        \\    behavior: domain
        \\    path: comments.rules
        \\rules:
        \\  - MATCH,DIRECT
    ;
    try writeFile(source.dir, "Exact.yaml", exact_source);
    const exact_path = try source.dir.realPathFileAlloc(
        compat.io(),
        "Exact.yaml",
        allocator,
    );
    defer allocator.free(exact_path);

    var receipt = try expectLoaded(try config_import.Importer.init(
        allocator,
        root.dir,
    ).load(exact_path));
    defer receipt.deinit(allocator);
    try catalog_runtime_gate.ensureIdentityRuntimeReady(
        allocator,
        root.dir,
        receipt.key,
        receipt.revision,
    );
    var view = try revision_store.RevisionStore.init(
        allocator,
        root.dir,
    ).openVerified(receipt.key, receipt.revision);
    defer view.deinit();
    const persisted = try view.resolveLocal("comments.rules");
    try testing.expectEqual(provider_limit, persisted.len);
    try testing.expectEqual(@as(u8, '#'), persisted[0]);
    try testing.expect(
        view.aggregate_bytes < 64 * 1024 * 1024,
    );

    const state_before = try root.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_before);
    try writeFile(source.dir, "comments.rules", comments);
    try writeFile(source.dir, "Oversized.yaml", exact_source);
    const oversized_path = try source.dir.realPathFileAlloc(
        compat.io(),
        "Oversized.yaml",
        allocator,
    );
    defer allocator.free(oversized_path);
    try testing.expectError(
        error.RuleProviderFileTooLarge,
        config_import.Importer.init(allocator, root.dir).load(oversized_path),
    );

    const state_after = try root.dir.readFileAlloc(
        compat.io(),
        "state-v2.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(state_after);
    try testing.expectEqualStrings(state_before, state_after);
    const oversized_storage = config_identity.StorageId.derive("Oversized");
    var storage_hex: [64]u8 = std.fmt.bytesToHex(
        oversized_storage.bytes,
        .lower,
    );
    const oversized_profile_path = try std.fmt.allocPrint(
        allocator,
        "profiles/{s}",
        .{&storage_hex},
    );
    defer allocator.free(oversized_profile_path);
    try testing.expectError(
        error.FileNotFound,
        root.dir.statFile(
            compat.io(),
            oversized_profile_path,
            .{ .follow_symlinks = false },
        ),
    );
    // The external +1 mutation cannot affect the exact immutable revision.
    try catalog_runtime_gate.ensureIdentityRuntimeReady(
        allocator,
        root.dir,
        receipt.key,
        receipt.revision,
    );
}

test "config load admits a Trojan subscription that declares udp:true" {
    // Load a focused bundle through Importer, then inspect publication,
    // diagnostics, and persisted state.
    const allocator = testing.allocator;
    var root = testing.tmpDir(test_directory_options);
    defer root.cleanup();
    var source = testing.tmpDir(test_directory_options);
    defer source.cleanup();
    try writeFile(source.dir, "Flower_Trojan.yaml",
        \\mixed-port: 7890
        \\proxies:
        \\  - name: HK-1
        \\    type: trojan
        \\    server: 127.0.0.1
        \\    port: 443
        \\    password: secret
        \\    sni: localhost
        \\    udp: true
        \\rules:
        \\  - MATCH,HK-1
    );
    const source_path = try source.dir.realPathFileAlloc(
        compat.io(),
        "Flower_Trojan.yaml",
        allocator,
    );
    defer allocator.free(source_path);

    var receipt = try expectLoaded(
        try config_import.Importer.init(allocator, root.dir).load(source_path),
    );
    defer receipt.deinit(allocator);
    try testing.expectEqualStrings("Flower_Trojan", receipt.key);
    try testing.expect(receipt.active);
    try catalog_runtime_gate.ensureIdentityRuntimeReady(
        allocator,
        root.dir,
        receipt.key,
        receipt.revision,
    );
}
