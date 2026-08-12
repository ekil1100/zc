//! Test-only rule-matrix scenario runner.
//! Loads frozen YAML cases and evaluates them with the production rule engine.
//! Not installed and not part of release archives.

const std = @import("std");
const config = @import("config.zig");
const Engine = @import("rule/engine.zig").Engine;
const yaml = @import("util/yaml.zig");
const compat = @import("compat.zig");

const Allocator = std.mem.Allocator;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn load_file(allocator: Allocator, path: []const u8) ![]u8 {
    return try compat.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
}

fn yaml_string(value: yaml.YamlValue, field: []const u8) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => {
            std.debug.print("expected string for {s}\n", .{field});
            return error.InvalidMatrix;
        },
    };
}

fn build_config_yaml(allocator: Allocator, rule_strings: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\mixed-port: 0
        \\mode: rule
        \\proxies:
        \\  - { name: PROXY, type: direct }
        \\  - { name: DIRECT, type: direct }
        \\  - { name: REJECT, type: reject }
        \\proxy-groups: []
        \\rules:
        \\
    );
    for (rule_strings) |rule| {
        try out.appendSlice(allocator, "  - ");
        try out.appendSlice(allocator, rule);
        try out.appendSlice(allocator, "\n");
    }
    return try out.toOwnedSlice(allocator);
}

fn collect_rule_strings(allocator: Allocator, root: yaml.YamlValue) ![][]const u8 {
    const map = switch (root) {
        .map => |m| m,
        else => return error.InvalidMatrix,
    };
    const rules_val = map.get("rules") orelse return error.InvalidMatrix;
    const arr = switch (rules_val) {
        .array => |a| a,
        else => return error.InvalidMatrix,
    };
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |item| {
        const s = try yaml_string(item, "rules[]");
        try list.append(allocator, s);
    }
    return try list.toOwnedSlice(allocator);
}

const CaseInput = struct {
    host: ?[]const u8 = null,
    ip: ?[]const u8 = null,
};

const Case = struct {
    id: []const u8,
    input: CaseInput,
    expect_target: []const u8,
    expect_matched_rule: ?[]const u8 = null,
};

fn parse_cases(allocator: Allocator, root: yaml.YamlValue) ![]Case {
    const map = switch (root) {
        .map => |m| m,
        else => return error.InvalidMatrix,
    };
    const cases_val = map.get("cases") orelse return error.InvalidMatrix;
    const arr = switch (cases_val) {
        .array => |a| a,
        else => return error.InvalidMatrix,
    };
    var list: std.ArrayList(Case) = .empty;
    errdefer list.deinit(allocator);
    for (arr.items) |item| {
        const case_map = switch (item) {
            .map => |m| m,
            else => return error.InvalidMatrix,
        };
        const id = try yaml_string(case_map.get("id") orelse return error.InvalidMatrix, "id");
        const input_val = case_map.get("input") orelse return error.InvalidMatrix;
        const input_map = switch (input_val) {
            .map => |m| m,
            else => return error.InvalidMatrix,
        };
        var input: CaseInput = .{};
        if (input_map.get("host")) |h| input.host = try yaml_string(h, "host");
        if (input_map.get("ip")) |ip| input.ip = try yaml_string(ip, "ip");
        if (input.host == null and input.ip == null) return error.InvalidMatrix;

        const expect_val = case_map.get("expect") orelse return error.InvalidMatrix;
        const expect_map = switch (expect_val) {
            .map => |m| m,
            else => return error.InvalidMatrix,
        };
        const target = try yaml_string(expect_map.get("target") orelse return error.InvalidMatrix, "target");
        var matched: ?[]const u8 = null;
        if (expect_map.get("matched_rule")) |mr| matched = try yaml_string(mr, "matched_rule");

        try list.append(allocator, .{
            .id = id,
            .input = input,
            .expect_target = target,
            .expect_matched_rule = matched,
        });
    }
    return try list.toOwnedSlice(allocator);
}

fn format_rule_label(allocator: Allocator, rule: config.Rule) ![]u8 {
    const type_name: []const u8 = switch (rule.rule_type) {
        .domain => "DOMAIN",
        .domain_suffix => "DOMAIN-SUFFIX",
        .domain_keyword => "DOMAIN-KEYWORD",
        .ip_cidr => "IP-CIDR",
        .ip_cidr6 => "IP-CIDR6",
        .geoip => "GEOIP",
        .rule_set => "RULE-SET",
        .src_ip_cidr => "SRC-IP-CIDR",
        .dst_port => "DST-PORT",
        .src_port => "SRC-PORT",
        .process_name => "PROCESS-NAME",
        .final => "MATCH",
    };
    if (rule.rule_type == .final) {
        return try std.fmt.allocPrint(allocator, "MATCH", .{});
    }
    return try std.fmt.allocPrint(allocator, "{s},{s}", .{ type_name, rule.payload });
}

fn match_target(engine: *Engine, case: Case) ?[]const u8 {
    const host = case.input.host orelse case.input.ip.?;
    const is_domain = case.input.host != null;
    return engine.match(host, is_domain);
}

/// Identify the winning rule using only production Engine.match on successive
/// rule prefixes (no second matcher implementation).
fn winning_rule_label(
    allocator: Allocator,
    all_rules: *const std.ArrayList(config.Rule),
    case: Case,
    full_target: []const u8,
) !?[]u8 {
    var prefix_count: usize = 1;
    while (prefix_count <= all_rules.items.len) : (prefix_count += 1) {
        var prefix_rules: std.ArrayList(config.Rule) = .empty;
        defer prefix_rules.deinit(allocator);
        try prefix_rules.appendSlice(allocator, all_rules.items[0..prefix_count]);

        var engine = try Engine.init(allocator, &prefix_rules);
        defer engine.deinit();

        const target = match_target(&engine, case) orelse continue;
        if (!std.mem.eql(u8, target, full_target)) continue;

        // First prefix that yields the full-engine target owns the match.
        return try format_rule_label(allocator, all_rules.items[prefix_count - 1]);
    }
    return null;
}

fn run_case(
    allocator: Allocator,
    engine: *Engine,
    all_rules: *const std.ArrayList(config.Rule),
    case: Case,
) !bool {
    const actual = match_target(engine, case);
    if (actual == null) {
        std.debug.print("FAIL {s}: engine returned no match (expected target={s})\n", .{ case.id, case.expect_target });
        return false;
    }
    if (!std.mem.eql(u8, actual.?, case.expect_target)) {
        std.debug.print(
            "FAIL {s}: target got={s} expected={s}\n",
            .{ case.id, actual.?, case.expect_target },
        );
        return false;
    }

    if (case.expect_matched_rule) |expected_label| {
        if (expected_label.len == 0) {
            std.debug.print("FAIL {s}: empty matched_rule in fixture\n", .{case.id});
            return false;
        }
        const actual_label = try winning_rule_label(allocator, all_rules, case, actual.?);
        defer if (actual_label) |l| allocator.free(l);
        if (actual_label == null) {
            std.debug.print("FAIL {s}: could not identify winning rule via engine prefixes\n", .{case.id});
            return false;
        }
        if (!std.mem.eql(u8, actual_label.?, expected_label)) {
            std.debug.print(
                "FAIL {s}: matched_rule got={s} expected={s}\n",
                .{ case.id, actual_label.?, expected_label },
            );
            return false;
        }
    }
    return true;
}

pub fn main(init: std.process.Init) !void {
    compat.setIo(init.io);
    compat.setEnvironMap(init.environ_map);

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        fail("usage: eval-rule-matrix <matrix.yaml>", .{});
    }
    const matrix_path = args[1];

    const raw = load_file(allocator, matrix_path) catch |err| {
        fail("failed to read {s}: {s}", .{ matrix_path, @errorName(err) });
    };
    defer allocator.free(raw);

    var root = yaml.parseDocument(allocator, raw) catch |err| {
        fail("failed to parse matrix yaml: {s}", .{@errorName(err)});
    };
    defer root.deinit(allocator);

    const rule_strings = collect_rule_strings(allocator, root) catch |err| {
        fail("matrix missing rules[] string list: {s}", .{@errorName(err)});
    };
    defer allocator.free(rule_strings);

    const cases = parse_cases(allocator, root) catch |err| {
        fail("matrix missing or invalid cases[]: {s}", .{@errorName(err)});
    };
    defer allocator.free(cases);

    const cfg_yaml = try build_config_yaml(allocator, rule_strings);
    defer allocator.free(cfg_yaml);

    var cfg = config.parseDocument(allocator, cfg_yaml) catch |err| {
        fail("failed to parse synthetic config for rules: {s}", .{@errorName(err)});
    };
    defer cfg.deinit();

    var engine = Engine.init(allocator, &cfg.rules) catch |err| {
        fail("engine init failed: {s}", .{@errorName(err)});
    };
    defer engine.deinit();

    var passed: usize = 0;
    var failed: usize = 0;
    var failed_ids: std.ArrayList([]const u8) = .empty;
    defer failed_ids.deinit(allocator);

    for (cases) |case| {
        const ok = run_case(allocator, &engine, &cfg.rules, case) catch |err| blk: {
            std.debug.print("FAIL {s}: internal error {s}\n", .{ case.id, @errorName(err) });
            break :blk false;
        };
        if (ok) {
            passed += 1;
        } else {
            failed += 1;
            try failed_ids.append(allocator, case.id);
        }
    }

    const total = passed + failed;
    if (failed == 0) {
        std.debug.print("RULE_MATRIX_RESULT=PASS\n", .{});
    } else {
        std.debug.print("RULE_MATRIX_RESULT=FAIL\n", .{});
    }
    std.debug.print("RULE_MATRIX_PASSED={d}\n", .{passed});
    std.debug.print("RULE_MATRIX_FAILED={d}\n", .{failed});
    std.debug.print("RULE_MATRIX_TOTAL={d}\n", .{total});
    if (failed_ids.items.len > 0) {
        std.debug.print("RULE_MATRIX_FAILED_IDS=", .{});
        for (failed_ids.items, 0..) |id, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("{s}", .{id});
        }
        std.debug.print("\n", .{});
    }

    if (failed != 0) std.process.exit(1);
    if (total == 0) {
        std.debug.print("no cases executed\n", .{});
        std.process.exit(1);
    }
}
