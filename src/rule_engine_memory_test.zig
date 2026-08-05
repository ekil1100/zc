const std = @import("std");
const config = @import("config.zig");
const rule_engine = @import("rule/engine.zig");

fn appendTestRule(
    allocator: std.mem.Allocator,
    rules: *std.ArrayList(config.Rule),
    rule_type: config.RuleType,
    payload: []const u8,
    target: []const u8,
) !void {
    try rules.append(allocator, .{
        .rule_type = rule_type,
        .payload = try allocator.dupe(u8, payload),
        .target = try allocator.dupe(u8, target),
    });
}

fn deinitTestRules(allocator: std.mem.Allocator, rules: *std.ArrayList(config.Rule)) void {
    for (rules.items) |*rule| rule.deinit(allocator);
    rules.deinit(allocator);
}

test "domain suffix rules preserve first-match order" {
    const allocator = std.testing.allocator;

    var rules = std.ArrayList(config.Rule).empty;
    defer deinitTestRules(allocator, &rules);
    try appendTestRule(allocator, &rules, .domain_suffix, "example.com", "DIRECT");
    try appendTestRule(allocator, &rules, .domain_suffix, "b.example.com", "PROXY");
    try appendTestRule(allocator, &rules, .final, "", "DIRECT");

    var engine = try rule_engine.Engine.init(allocator, &rules);
    defer engine.deinit();

    try std.testing.expectEqualStrings("DIRECT", engine.match("a.b.example.com", true).?);
}

test "domain suffix matching honors label boundaries" {
    const allocator = std.testing.allocator;

    var rules = std.ArrayList(config.Rule).empty;
    defer deinitTestRules(allocator, &rules);
    try appendTestRule(allocator, &rules, .domain_suffix, "example.com", "DIRECT");
    try appendTestRule(allocator, &rules, .final, "", "PROXY");

    var engine = try rule_engine.Engine.init(allocator, &rules);
    defer engine.deinit();

    try std.testing.expectEqualStrings("DIRECT", engine.match("www.example.com", true).?);
    try std.testing.expectEqualStrings("DIRECT", engine.match("example.com", true).?);
    try std.testing.expectEqualStrings("PROXY", engine.match("badexample.com", true).?);
}
