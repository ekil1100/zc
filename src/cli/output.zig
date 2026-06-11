//! CLI output layer — the single place that decides:
//!  - what goes to stdout (payloads) vs stderr (diagnostics),
//!  - the shape of the JSON envelope, serialized via std.json,
//!  - whether ANSI color is emitted.
//!
//! Contract (docs/cli/ux-workflow.md):
//!  - JSON success:  {"ok":true,"command":"<path>","data":{...}}   -> stdout, one line
//!  - JSON failure:  {"ok":false,"command":"<path>","error":{code,message,hint}[,"data":{...}]} -> stdout, one line
//!  - Streaming JSON uses JSON Lines (`jsonLine`).
//!  - `config dump` is the one bare-document exception (`document`).
//!  - Text mode: primary output stdout, diagnostics stderr, color only on TTY
//!    without NO_COLOR/--no-color.

const std = @import("std");

pub const exit_ok: u8 = 0;
pub const exit_failure: u8 = 1;
pub const exit_usage: u8 = 2;

pub const Mode = enum { text, json };

pub const Color = enum {
    reset,
    bold,
    dim,
    red,
    green,
    yellow,
    cyan,

    fn code(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .cyan => "\x1b[36m",
        };
    }
};

/// Pure color policy so it is testable without a real terminal.
pub fn shouldUseColor(stdout_is_tty: bool, no_color_flag: bool, no_color_env: bool) bool {
    if (no_color_flag or no_color_env) return false;
    return stdout_is_tty;
}

const stringify_options: std.json.Stringify.Options = .{
    .whitespace = .minified,
    .emit_null_optional_fields = false,
};

pub const Output = struct {
    mode: Mode,
    /// Canonical command path used in the envelope, e.g. "config list".
    command: []const u8,
    color_enabled: bool,
    /// Payload stream (stdout in production).
    out: *std.Io.Writer,
    /// Diagnostics stream (stderr in production).
    err: *std.Io.Writer,

    pub fn init(
        mode: Mode,
        command: []const u8,
        color_enabled: bool,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
    ) Output {
        return .{
            .mode = mode,
            .command = command,
            .color_enabled = color_enabled,
            .out = out,
            .err = err,
        };
    }

    /// JSON mode: emit the success envelope on stdout and flush.
    /// Text mode: no-op — handlers render human output with `print`.
    pub fn success(self: *Output, data: anytype) !void {
        if (self.mode != .json) return;
        var js: std.json.Stringify = .{ .writer = self.out, .options = stringify_options };
        try js.beginObject();
        try js.objectField("ok");
        try js.write(true);
        try js.objectField("command");
        try js.write(self.command);
        try js.objectField("data");
        try js.write(data);
        try js.endObject();
        try self.out.writeByte('\n');
        try self.out.flush();
    }

    /// Emit a failure in either mode. JSON: one envelope line on stdout.
    /// Text: actionable error block on stderr.
    /// Callers must exit non-zero afterwards (`exit_failure`/`exit_usage`).
    pub fn fail(self: *Output, code: []const u8, message: []const u8, hint: []const u8) !void {
        return self.failImpl(code, message, hint, null);
    }

    /// Failure that carries structured detail (e.g. doctor/test per-check
    /// results next to error.code=CHECKS_FAILED).
    pub fn failWithData(
        self: *Output,
        code: []const u8,
        message: []const u8,
        hint: []const u8,
        data: anytype,
    ) !void {
        return self.failImpl(code, message, hint, data);
    }

    fn failImpl(
        self: *Output,
        code: []const u8,
        message: []const u8,
        hint: []const u8,
        data: anytype,
    ) !void {
        if (self.mode == .json) {
            var js: std.json.Stringify = .{ .writer = self.out, .options = stringify_options };
            try js.beginObject();
            try js.objectField("ok");
            try js.write(false);
            try js.objectField("command");
            try js.write(self.command);
            try js.objectField("error");
            try js.beginObject();
            try js.objectField("code");
            try js.write(code);
            try js.objectField("message");
            try js.write(message);
            try js.objectField("hint");
            try js.write(hint);
            try js.endObject();
            if (@TypeOf(data) != @TypeOf(null)) {
                try js.objectField("data");
                try js.write(data);
            }
            try js.endObject();
            try self.out.writeByte('\n');
            try self.out.flush();
            return;
        }
        try self.err.print("{s}error:{s} {s}\n", .{ self.style(.red), self.style(.reset), message });
        if (hint.len != 0) try self.err.print("  hint: {s}\n", .{hint});
        try self.err.print("  code: {s}\n", .{code});
        try self.err.flush();
    }

    /// One JSON Lines event (zc log --json). No envelope, flushed per line.
    pub fn jsonLine(self: *Output, event: anytype) !void {
        try std.json.Stringify.value(event, stringify_options, self.out);
        try self.out.writeByte('\n');
        try self.out.flush();
    }

    /// Bare JSON document on stdout (the `config dump --json` exception).
    pub fn document(self: *Output, v: anytype) !void {
        try std.json.Stringify.value(v, stringify_options, self.out);
        try self.out.writeByte('\n');
        try self.out.flush();
    }

    /// Human-facing primary output -> stdout. Text mode only by convention;
    /// handlers gate on `mode` before rendering.
    pub fn print(self: *Output, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(fmt, args);
    }

    /// Diagnostics/progress -> stderr (never pollutes pipeable stdout).
    pub fn note(self: *Output, comptime fmt: []const u8, args: anytype) !void {
        try self.err.print(fmt, args);
        try self.err.flush();
    }

    /// ANSI code when color is enabled, "" otherwise. Usable inline in print.
    pub fn style(self: *const Output, c: Color) []const u8 {
        return if (self.color_enabled) c.code() else "";
    }

    pub fn flush(self: *Output) !void {
        try self.out.flush();
        try self.err.flush();
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Capture = struct {
    out_alloc: std.Io.Writer.Allocating,
    err_alloc: std.Io.Writer.Allocating,

    fn init(allocator: std.mem.Allocator) Capture {
        return .{
            .out_alloc = .init(allocator),
            .err_alloc = .init(allocator),
        };
    }

    fn deinit(self: *Capture) void {
        self.out_alloc.deinit();
        self.err_alloc.deinit();
    }

    fn output(self: *Capture, mode: Mode, command: []const u8, color: bool) Output {
        return Output.init(mode, command, color, &self.out_alloc.writer, &self.err_alloc.writer);
    }

    fn stdout(self: *Capture) []const u8 {
        return self.out_alloc.written();
    }

    fn stderr(self: *Capture) []const u8 {
        return self.err_alloc.written();
    }
};

test "json success emits one envelope line on stdout only" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var out = cap.output(.json, "status", false);

    try out.success(.{ .action = "status", .state = "running", .pid = @as(i32, 123) });

    try testing.expectEqualStrings(
        "{\"ok\":true,\"command\":\"status\",\"data\":{\"action\":\"status\",\"state\":\"running\",\"pid\":123}}\n",
        cap.stdout(),
    );
    try testing.expectEqualStrings("", cap.stderr());
}

test "json success escapes hostile strings into valid JSON" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var out = cap.output(.json, "proxy list", false);

    try out.success(.{ .name = "node \"HK\"\nline2\x01" });

    const written = cap.stdout();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, written, .{});
    defer parsed.deinit();
    const name = parsed.value.object.get("data").?.object.get("name").?.string;
    try testing.expectEqualStrings("node \"HK\"\nline2\x01", name);
}

test "text mode success is a no-op" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var out = cap.output(.text, "status", false);

    try out.success(.{ .state = "running" });

    try testing.expectEqualStrings("", cap.stdout());
    try testing.expectEqualStrings("", cap.stderr());
}

test "json fail emits envelope with error object on stdout" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var out = cap.output(.json, "start", false);

    try out.fail("START_FAILED", "failed to start daemon", "check config path");

    try testing.expectEqualStrings(
        "{\"ok\":false,\"command\":\"start\",\"error\":{\"code\":\"START_FAILED\",\"message\":\"failed to start daemon\",\"hint\":\"check config path\"}}\n",
        cap.stdout(),
    );
    try testing.expectEqualStrings("", cap.stderr());
}

test "json failWithData carries structured detail next to error" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var out = cap.output(.json, "doctor", false);

    try out.failWithData(
        "CHECKS_FAILED",
        "1 check failed",
        "see data.checks",
        .{ .checks = [_][]const u8{"connection"} },
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, cap.stdout(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("ok").?.bool == false);
    try testing.expectEqualStrings("CHECKS_FAILED", parsed.value.object.get("error").?.object.get("code").?.string);
    try testing.expectEqualStrings("connection", parsed.value.object.get("data").?.object.get("checks").?.array.items[0].string);
}

test "text fail prints actionable block to stderr, stdout untouched" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var out = cap.output(.text, "start", false);

    try out.fail("START_FAILED", "failed to start daemon", "check config path");

    try testing.expectEqualStrings("", cap.stdout());
    try testing.expectEqualStrings(
        "error: failed to start daemon\n  hint: check config path\n  code: START_FAILED\n",
        cap.stderr(),
    );
}

test "text fail uses ANSI only when color enabled" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var out = cap.output(.text, "start", true);

    try out.fail("X", "boom", "");

    try testing.expect(std.mem.indexOf(u8, cap.stderr(), "\x1b[31m") != null);
    try testing.expect(std.mem.indexOf(u8, cap.stderr(), "  hint:") == null);
}

test "jsonLine emits one document per line without envelope" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var out = cap.output(.json, "log", false);

    try out.jsonLine(.{ .line = "a" });
    try out.jsonLine(.{ .line = "b" });

    try testing.expectEqualStrings("{\"line\":\"a\"}\n{\"line\":\"b\"}\n", cap.stdout());
}

test "document emits bare value (config dump exception)" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var out = cap.output(.json, "config dump", false);

    try out.document(.{ .port = @as(u16, 7901) });

    try testing.expectEqualStrings("{\"port\":7901}\n", cap.stdout());
}

test "print targets stdout and note targets stderr" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var out = cap.output(.text, "status", false);

    try out.print("payload {d}\n", .{1});
    try out.note("progress...\n", .{});
    try out.flush();

    try testing.expectEqualStrings("payload 1\n", cap.stdout());
    try testing.expectEqualStrings("progress...\n", cap.stderr());
}

test "style returns codes only when enabled" {
    var cap = Capture.init(testing.allocator);
    defer cap.deinit();
    var on = cap.output(.text, "x", true);
    var off = cap.output(.text, "x", false);

    try testing.expectEqualStrings("\x1b[32m", on.style(.green));
    try testing.expectEqualStrings("", off.style(.green));
}

test "shouldUseColor truth table" {
    try testing.expect(shouldUseColor(true, false, false));
    try testing.expect(!shouldUseColor(false, false, false));
    try testing.expect(!shouldUseColor(true, true, false));
    try testing.expect(!shouldUseColor(true, false, true));
}
