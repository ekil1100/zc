const std = @import("std");
const testing = std.testing;
const Engine = @import("engine.zig").Engine;
const Rule = @import("../config.zig").Rule;
const RuleType = @import("../config.zig").RuleType;

test "Engine init empty rules" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer {
        for (rules.items) |*rule| {
            rule.deinit(allocator);
        }
        rules.deinit(allocator);
    }

    var engine = try Engine.init(allocator, &rules);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 0), engine.rules.items.len);
}

test "Engine match domain" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer rules.deinit(allocator);

    // Add a domain rule
    try rules.append(allocator, .{
        .rule_type = .domain,
        .payload = try allocator.dupe(u8, "google.com"),
        .target = try allocator.dupe(u8, "PROXY"),
    });

    var engine = try Engine.init(allocator, &rules);
    defer {
        for (rules.items) |*rule| {
            rule.deinit(allocator);
        }
        engine.deinit();
    }

    const result = engine.match("google.com", true);
    try testing.expect(result != null);
    try testing.expectEqualStrings("PROXY", result.?);
}

test "Engine match domain suffix" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer rules.deinit(allocator);

    try rules.append(allocator, .{
        .rule_type = .domain_suffix,
        .payload = try allocator.dupe(u8, "google.com"),
        .target = try allocator.dupe(u8, "PROXY"),
    });

    var engine = try Engine.init(allocator, &rules);
    defer {
        for (rules.items) |*rule| {
            rule.deinit(allocator);
        }
        engine.deinit();
    }

    const result = engine.match("www.google.com", true);
    try testing.expect(result != null);
    try testing.expectEqualStrings("PROXY", result.?);
}

test "Engine match domain keyword" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer rules.deinit(allocator);

    try rules.append(allocator, .{
        .rule_type = .domain_keyword,
        .payload = try allocator.dupe(u8, "google"),
        .target = try allocator.dupe(u8, "PROXY"),
    });

    var engine = try Engine.init(allocator, &rules);
    defer {
        for (rules.items) |*rule| {
            rule.deinit(allocator);
        }
        engine.deinit();
    }

    const result = engine.match("googleapis.com", true);
    try testing.expect(result != null);
    try testing.expectEqualStrings("PROXY", result.?);
}

test "Engine match final" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer rules.deinit(allocator);

    try rules.append(allocator, .{
        .rule_type = .final,
        .payload = try allocator.dupe(u8, ""),
        .target = try allocator.dupe(u8, "DIRECT"),
    });

    var engine = try Engine.init(allocator, &rules);
    defer {
        for (rules.items) |*rule| {
            rule.deinit(allocator);
        }
        engine.deinit();
    }

    const result = engine.match("unknown.com", true);
    try testing.expect(result != null);
    try testing.expectEqualStrings("DIRECT", result.?);
}
