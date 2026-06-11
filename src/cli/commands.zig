//! Declarative command table — single source of truth for the CLI surface.
//! Dispatch (alias resolution) and all help text are generated from this
//! table so help can never drift from what the binary accepts.

const std = @import("std");

pub const Flag = struct {
    /// Display spec, e.g. "-c <config>", "--json".
    spec: []const u8,
    help: []const u8,
};

pub const Command = struct {
    /// Canonical path, e.g. "start" or "config list".
    path: []const u8,
    /// Full-path aliases, e.g. "up" for "start", "config ls" for "config list".
    aliases: []const []const u8 = &.{},
    summary: []const u8,
    /// Positional args shown in usage, e.g. "<url>".
    args: []const u8 = "",
    flags: []const Flag = &.{},
    examples: []const []const u8 = &.{},
};

pub const Group = struct {
    name: []const u8,
    summary: []const u8,
};

const json_flag: Flag = .{ .spec = "--json", .help = "Machine-readable envelope on stdout" };
const config_flag: Flag = .{ .spec = "-c <config>", .help = "Use specific config file" };
const override_flags = [_]Flag{
    .{ .spec = "--override-script <path>", .help = "Run override script (lua table or executable printing YAML)" },
    .{ .spec = "--override-arg <k=v>", .help = "Pass key/value to override script (repeatable)" },
    .{ .spec = "--override-timeout-ms <n>", .help = "Override script timeout in milliseconds (default: 500)" },
};

pub const groups = [_]Group{
    .{ .name = "config", .summary = "Manage configurations" },
    .{ .name = "proxy", .summary = "Manage proxies" },
    .{ .name = "profile", .summary = "Alias group for proxy operations" },
    .{ .name = "diag", .summary = "Diagnostic command group" },
};

pub const table = [_]Command{
    .{
        .path = "help",
        .args = "[command]",
        .summary = "Show help for zc or a specific command",
        .examples = &.{ "zc help", "zc help start", "zc help config download" },
    },
    .{
        .path = "start",
        .aliases = &.{"up"},
        .summary = "Start proxy daemon in background",
        .flags = &([_]Flag{
            config_flag,
            .{ .spec = "--port <port>", .help = "Override mixed-port for this run" },
            .{ .spec = "--foreground", .help = "Run in the foreground without forking (containers/systemd)" },
            json_flag,
        } ++ override_flags),
        .examples = &.{ "zc start", "zc start -c config.yaml --port 7901", "zc start --foreground" },
    },
    .{
        .path = "stop",
        .aliases = &.{"down"},
        .summary = "Stop proxy daemon",
        .flags = &.{json_flag},
        .examples = &.{"zc stop"},
    },
    .{
        .path = "restart",
        .summary = "Restart proxy daemon (keeps the old daemon's -c/--port unless overridden)",
        .flags = &([_]Flag{
            config_flag,
            .{ .spec = "--port <port>", .help = "Override mixed-port for the restarted daemon" },
            json_flag,
        } ++ override_flags),
        .examples = &.{ "zc restart", "zc restart -c config.yaml --port 7901" },
    },
    .{
        .path = "reload",
        .summary = "Hot-reload current config into the running daemon",
        .flags = &.{json_flag},
        .examples = &.{ "zc reload", "zc reload --json" },
    },
    .{
        .path = "status",
        .summary = "Show daemon status and selected proxies",
        .flags = &.{json_flag},
        .examples = &.{ "zc status", "zc status --json" },
    },
    .{
        .path = "log",
        .summary = "View daemon logs (follows by default)",
        .flags = &.{
            .{ .spec = "-n <lines>", .help = "Number of lines to show (default: 50)" },
            .{ .spec = "-f", .help = "Keep following (default in text mode; opt-in with --json)" },
            .{ .spec = "--no-follow", .help = "Print once and exit" },
            .{ .spec = "--json", .help = "JSON Lines on stdout (implies --no-follow unless -f)" },
        },
        .examples = &.{ "zc log", "zc log -n 100 --no-follow", "zc log --json | jq -r .line" },
    },
    .{
        .path = "test",
        .summary = "Test network connectivity through the proxy",
        .flags = &.{ config_flag, json_flag },
        .examples = &.{"zc test"},
    },
    .{
        .path = "doctor",
        .summary = "Diagnose config, daemon, ports, and connectivity",
        .flags = &.{ config_flag, json_flag },
        .examples = &.{"zc doctor --json"},
    },
    .{
        .path = "version",
        .aliases = &.{"--version"},
        .summary = "Print zc version",
    },
    .{
        .path = "config list",
        .aliases = &.{"config ls"},
        .summary = "List all available configs",
        .flags = &.{json_flag},
        .examples = &.{ "zc config list", "zc config list --json" },
    },
    .{
        .path = "config download",
        .args = "<url>",
        .summary = "Download config from URL",
        .flags = &.{
            .{ .spec = "-n <name>", .help = "Config filename (default: timestamp)" },
            .{ .spec = "-d", .help = "Set as default after download" },
            json_flag,
        },
        .examples = &.{"zc config download https://example.com/config.yaml -n myconfig -d"},
    },
    .{
        .path = "config update",
        .args = "[name]",
        .summary = "Re-download a previously downloaded config",
        .flags = &.{
            .{ .spec = "--apply <auto|hot|restart>", .help = "How to apply to a running daemon" },
            json_flag,
        },
        .examples = &.{"zc config update --apply auto"},
    },
    .{
        .path = "config use",
        .args = "<name>",
        .summary = "Switch to specified config (apply with `zc reload` afterwards)",
        .flags = &.{json_flag},
        .examples = &.{"zc config use myconfig.yaml"},
    },
    .{
        .path = "config dump",
        .summary = "Print merged config (YAML; bare JSON document with --json)",
        .flags = &([_]Flag{
            config_flag,
            .{ .spec = "--no-override", .help = "Skip persisted override script" },
            json_flag,
        } ++ override_flags),
        .examples = &.{ "zc config dump", "zc config dump --json | jq ." },
    },
    .{
        .path = "config override",
        .args = "[script|--clear]",
        .summary = "Bind/clear persisted override for current config",
        .flags = &.{json_flag},
        .examples = &.{ "zc config override ./override.lua", "zc config override --clear" },
    },
    .{
        .path = "proxy list",
        .aliases = &.{"proxy ls"},
        .summary = "List all proxy groups and nodes",
        .flags = &.{json_flag},
        .examples = &.{"zc proxy list --json"},
    },
    .{
        .path = "proxy select",
        .summary = "Select proxy for a group (interactive without -g/-p)",
        .flags = &.{
            .{ .spec = "-g <group>", .help = "Proxy group to change" },
            .{ .spec = "-p <proxy>", .help = "Proxy node to select" },
            json_flag,
        },
        .examples = &.{ "zc proxy select", "zc proxy select -g Proxy -p HK" },
    },
    .{
        .path = "proxy test",
        .summary = "Test configured proxy connectivity",
        .flags = &.{ config_flag, json_flag },
        .examples = &.{"zc proxy test"},
    },
    .{
        .path = "profile list",
        .aliases = &.{"profile ls"},
        .summary = "List all proxy groups and nodes",
        .flags = &.{json_flag},
    },
    .{
        .path = "profile select",
        .summary = "Select proxy for a group (interactive without -g/-p)",
        .flags = &.{
            .{ .spec = "-g <group>", .help = "Proxy group to change" },
            .{ .spec = "-p <proxy>", .help = "Proxy node to select" },
            json_flag,
        },
    },
    .{
        .path = "profile test",
        .summary = "Test configured proxy connectivity",
        .flags = &.{ config_flag, json_flag },
    },
    .{
        .path = "diag doctor",
        .summary = "Alias of zc doctor",
        .flags = &.{ config_flag, json_flag },
    },
};

/// Exact lookup by canonical path or full-path alias.
pub fn find(path: []const u8) ?*const Command {
    for (&table) |*cmd| {
        if (std.mem.eql(u8, cmd.path, path)) return cmd;
        for (cmd.aliases) |alias| {
            if (std.mem.eql(u8, alias, path)) return cmd;
        }
    }
    return null;
}

/// Resolve a single top-level token through aliases: "up" -> "start".
/// Unknown tokens are returned unchanged.
pub fn canonicalTop(token: []const u8) []const u8 {
    for (&table) |*cmd| {
        if (std.mem.indexOfScalar(u8, cmd.path, ' ') != null) continue;
        for (cmd.aliases) |alias| {
            if (std.mem.eql(u8, alias, token)) return cmd.path;
        }
    }
    return token;
}

fn isGroup(name: []const u8) ?*const Group {
    for (&groups) |*g| {
        if (std.mem.eql(u8, g.name, name)) return g;
    }
    return null;
}

pub fn writeGlobalHelp(w: *std.Io.Writer, version: []const u8) !void {
    try w.print("zc v{s} — a Zig-powered proxy runtime\n\n", .{version});
    try w.writeAll("Usage:\n    zc <command> [options]\n\nCommands:\n");
    for (&table) |*cmd| {
        if (std.mem.indexOfScalar(u8, cmd.path, ' ') != null) continue;
        try writeSummaryLine(w, cmd.path, cmd.summary);
    }
    for (&groups) |*g| {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "{s} <subcmd>", .{g.name});
        try writeSummaryLine(w, name, g.summary);
    }
    try w.writeAll(
        \\
        \\Aliases:
        \\    up = start, down = stop, ls = list
        \\
        \\Global options:
        \\    --json        Machine-readable envelope on stdout
        \\    --no-color    Disable ANSI colors (NO_COLOR is honored too)
        \\
        \\Run `zc help <command>` or `zc <command> --help` for details.
        \\
    );
    try w.flush();
}

fn writeSummaryLine(w: *std.Io.Writer, name: []const u8, summary: []const u8) !void {
    try w.print("    {s}", .{name});
    if (name.len < 18) {
        try w.splatByteAll(' ', 18 - name.len);
    } else {
        try w.writeAll("  ");
    }
    try w.print("{s}\n", .{summary});
}

pub fn writeCommandHelp(w: *std.Io.Writer, cmd: *const Command) !void {
    try w.print("zc {s} — {s}\n\nUsage:\n    zc {s}", .{ cmd.path, cmd.summary, cmd.path });
    if (cmd.args.len != 0) try w.print(" {s}", .{cmd.args});
    if (cmd.flags.len != 0) try w.writeAll(" [options]");
    try w.writeAll("\n");
    if (cmd.aliases.len != 0) {
        try w.writeAll("\nAliases:\n");
        for (cmd.aliases) |alias| try w.print("    zc {s}\n", .{alias});
    }
    if (cmd.flags.len != 0) {
        try w.writeAll("\nOptions:\n");
        for (cmd.flags) |flag| {
            try w.print("    {s}", .{flag.spec});
            if (flag.spec.len < 28) {
                try w.splatByteAll(' ', 28 - flag.spec.len);
            } else {
                try w.writeAll("  ");
            }
            try w.print("{s}\n", .{flag.help});
        }
    }
    if (cmd.examples.len != 0) {
        try w.writeAll("\nExamples:\n");
        for (cmd.examples) |example| try w.print("    {s}\n", .{example});
    }
    try w.flush();
}

fn writeGroupHelp(w: *std.Io.Writer, group: *const Group) !void {
    try w.print("zc {s} — {s}\n\nUsage:\n    zc {s} <subcommand> [options]\n\nSubcommands:\n", .{
        group.name, group.summary, group.name,
    });
    for (&table) |*cmd| {
        if (!std.mem.startsWith(u8, cmd.path, group.name)) continue;
        if (cmd.path.len <= group.name.len or cmd.path[group.name.len] != ' ') continue;
        try writeSummaryLine(w, cmd.path[group.name.len + 1 ..], cmd.summary);
    }
    try w.print("\nRun `zc help {s} <subcommand>` for details.\n", .{group.name});
    try w.flush();
}

/// Render help for a topic given as tokens (e.g. {"config","download"} or
/// {"start"}). Returns false when the topic is unknown.
pub fn writeTopicHelp(w: *std.Io.Writer, tokens: []const []const u8) !bool {
    if (tokens.len == 0) return false;
    if (tokens.len >= 2) {
        var buf: [64]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, "{s} {s}", .{ tokens[0], tokens[1] }) catch return false;
        if (find(joined)) |cmd| {
            try writeCommandHelp(w, cmd);
            return true;
        }
        return false;
    }
    if (isGroup(tokens[0])) |group| {
        try writeGroupHelp(w, group);
        return true;
    }
    if (find(tokens[0])) |cmd| {
        try writeCommandHelp(w, cmd);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "table has no duplicate paths or aliases" {
    for (&table, 0..) |*a, i| {
        for (table[i + 1 ..]) |*b| {
            try testing.expect(!std.mem.eql(u8, a.path, b.path));
            for (a.aliases) |alias| {
                try testing.expect(!std.mem.eql(u8, alias, b.path));
                for (b.aliases) |other| try testing.expect(!std.mem.eql(u8, alias, other));
            }
        }
    }
}

test "find resolves canonical paths and aliases" {
    try testing.expect(find("start") != null);
    try testing.expectEqualStrings("start", find("up").?.path);
    try testing.expectEqualStrings("stop", find("down").?.path);
    try testing.expectEqualStrings("config list", find("config ls").?.path);
    try testing.expect(find("nope") == null);
}

test "canonicalTop maps top-level aliases only" {
    try testing.expectEqualStrings("start", canonicalTop("up"));
    try testing.expectEqualStrings("stop", canonicalTop("down"));
    try testing.expectEqualStrings("status", canonicalTop("status"));
    try testing.expectEqualStrings("unknown", canonicalTop("unknown"));
}

test "global help lists every top-level command and group" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeGlobalHelp(&aw.writer, "1.0.0-test");
    const help = aw.written();

    try testing.expect(std.mem.indexOf(u8, help, "Usage") != null);
    for (&table) |*cmd| {
        if (std.mem.indexOfScalar(u8, cmd.path, ' ') != null) continue;
        try testing.expect(std.mem.indexOf(u8, help, cmd.path) != null);
    }
    for (&groups) |*g| {
        try testing.expect(std.mem.indexOf(u8, help, g.name) != null);
    }
    try testing.expect(std.mem.indexOf(u8, help, "up = start") != null);
}

test "command help renders usage, options, aliases, examples" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeCommandHelp(&aw.writer, find("start").?);
    const help = aw.written();

    try testing.expect(std.mem.indexOf(u8, help, "Usage") != null);
    try testing.expect(std.mem.indexOf(u8, help, "zc start") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--port <port>") != null);
    try testing.expect(std.mem.indexOf(u8, help, "zc up") != null);
}

test "topic help handles groups, commands, two-token paths, unknowns" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try testing.expect(try writeTopicHelp(&aw.writer, &.{"config"}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "download") != null);

    try testing.expect(try writeTopicHelp(&aw.writer, &.{"start"}));
    try testing.expect(try writeTopicHelp(&aw.writer, &.{ "config", "download" }));
    try testing.expect(!try writeTopicHelp(&aw.writer, &.{"nope"}));
    try testing.expect(!try writeTopicHelp(&aw.writer, &.{ "config", "nope" }));
}
