const std = @import("std");
const testing = std.testing;
const compat = @import("compat.zig");
const config = @import("config.zig");
const config_import = @import("config_import.zig");

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(compat.io(), bytes);
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

    var receipt = try config_import.Importer.init(allocator, root.dir).load(source_path);
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
