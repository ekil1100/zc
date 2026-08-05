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

test "Engine preserves first-match order across rule types" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer rules.deinit(allocator);
    try rules.append(allocator, .{
        .rule_type = .domain_suffix,
        .payload = try allocator.dupe(u8, "example.com"),
        .target = try allocator.dupe(u8, "REJECT"),
    });
    try rules.append(allocator, .{
        .rule_type = .domain,
        .payload = try allocator.dupe(u8, "allow.example.com"),
        .target = try allocator.dupe(u8, "DIRECT"),
    });
    try rules.append(allocator, .{
        .rule_type = .final,
        .payload = try allocator.dupe(u8, ""),
        .target = try allocator.dupe(u8, "DIRECT"),
    });

    var engine = try Engine.init(allocator, &rules);
    defer {
        for (rules.items) |*rule| rule.deinit(allocator);
        engine.deinit();
    }

    try testing.expectEqualStrings(
        "REJECT",
        engine.match("allow.example.com", true).?,
    );
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
    try testing.expectEqualStrings("PROXY", engine.match("WWW.GOOGLE.COM.", true).?);
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

test "Engine match IP-CIDR prefix /8" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer rules.deinit(allocator);

    try rules.append(allocator, .{
        .rule_type = .ip_cidr,
        .payload = try allocator.dupe(u8, "10.0.0.0/8"),
        .target = try allocator.dupe(u8, "DIRECT"),
    });

    var engine = try Engine.init(allocator, &rules);
    defer {
        for (rules.items) |*rule| {
            rule.deinit(allocator);
        }
        engine.deinit();
    }

    // With the old buggy mask (always 0xFFFFFFFF) this only matched the exact
    // network address 10.0.0.0 and failed for any other host inside the /8.
    const result = engine.match("10.20.30.40", false);
    try testing.expect(result != null);
    try testing.expectEqualStrings("DIRECT", result.?);
}

test "Engine treats an IP literal sent as a domain as an IP" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer rules.deinit(allocator);
    try rules.append(allocator, .{
        .rule_type = .ip_cidr,
        .payload = try allocator.dupe(u8, "10.0.0.0/8"),
        .target = try allocator.dupe(u8, "REJECT"),
        .no_resolve = true,
    });
    try rules.append(allocator, .{
        .rule_type = .final,
        .payload = try allocator.dupe(u8, ""),
        .target = try allocator.dupe(u8, "DIRECT"),
    });

    var engine = try Engine.init(allocator, &rules);
    defer {
        for (rules.items) |*rule| rule.deinit(allocator);
        engine.deinit();
    }

    try testing.expectEqualStrings("REJECT", engine.match("10.20.30.40", true).?);
}

test "Engine IP-CIDR /8 does not match outside the network" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer rules.deinit(allocator);

    try rules.append(allocator, .{
        .rule_type = .ip_cidr,
        .payload = try allocator.dupe(u8, "10.0.0.0/8"),
        .target = try allocator.dupe(u8, "DIRECT"),
    });

    var engine = try Engine.init(allocator, &rules);
    defer {
        for (rules.items) |*rule| {
            rule.deinit(allocator);
        }
        engine.deinit();
    }

    // 11.0.0.1 is outside 10.0.0.0/8 and must not match (guards against an
    // over-broad / zero mask).
    const result = engine.match("11.0.0.1", false);
    try testing.expect(result == null);
}

test "Engine match IP-CIDR prefix /16" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer rules.deinit(allocator);

    try rules.append(allocator, .{
        .rule_type = .ip_cidr,
        .payload = try allocator.dupe(u8, "192.168.0.0/16"),
        .target = try allocator.dupe(u8, "DIRECT"),
    });

    var engine = try Engine.init(allocator, &rules);
    defer {
        for (rules.items) |*rule| {
            rule.deinit(allocator);
        }
        engine.deinit();
    }

    try testing.expect(engine.match("192.168.5.7", false) != null);
    try testing.expect(engine.match("192.169.0.1", false) == null);
}

test "Engine GEOIP uses network-order address bytes" {
    const allocator = testing.allocator;

    var rules = std.ArrayList(Rule).empty;
    defer rules.deinit(allocator);
    try rules.append(allocator, .{
        .rule_type = .geoip,
        .payload = try allocator.dupe(u8, "CN"),
        .target = try allocator.dupe(u8, "REJECT"),
    });
    try rules.append(allocator, .{
        .rule_type = .final,
        .payload = try allocator.dupe(u8, ""),
        .target = try allocator.dupe(u8, "DIRECT"),
    });

    var engine = try Engine.init(allocator, &rules);
    defer {
        for (rules.items) |*rule| rule.deinit(allocator);
        engine.deinit();
    }

    try testing.expectEqualStrings("REJECT", engine.match("1.0.0.1", false).?);
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
