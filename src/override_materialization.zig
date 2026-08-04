const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const override = @import("override.zig");

pub const max_script_bytes = 1024 * 1024;
pub const max_patch_bytes = 1024 * 1024;
pub const max_effective_source_bytes = 16 * 1024 * 1024;
pub const timeout_ms_default = override.timeout_ms_default;

pub const Argument = struct {
    key: []const u8,
    value: []const u8,
};

pub const Script = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const Invocation = struct {
    command: []const u8,
    config_path: ?[]const u8 = null,
    timeout_ms: u32 = timeout_ms_default,
    args: []const Argument = &.{},
};

pub const Runner = struct {
    context: *anyopaque,
    run: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        script: Script,
        invocation: Invocation,
    ) anyerror![]u8,
};

pub const ProcessRunner = struct {
    dir: std.Io.Dir,

    pub fn init(dir: std.Io.Dir) ProcessRunner {
        return .{ .dir = dir };
    }

    pub fn runner(self: *ProcessRunner) Runner {
        return .{ .context = self, .run = run };
    }

    fn run(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        script: Script,
        invocation: Invocation,
    ) ![]u8 {
        const self: *ProcessRunner = @ptrCast(@alignCast(raw));
        var nonce: [16]u8 = undefined;
        compat.randomBytes(&nonce);
        var nonce_hex: [32]u8 = std.fmt.bytesToHex(nonce, .lower);
        const suffix: []const u8 = if (std.mem.endsWith(u8, script.name, ".lua")) ".lua" else "";
        const temp_name = try std.fmt.allocPrint(allocator, ".override-{s}{s}", .{ &nonce_hex, suffix });
        defer allocator.free(temp_name);
        const permissions = if (builtin.os.tag == .windows)
            std.Io.File.Permissions.default_file
        else
            std.Io.File.Permissions.fromMode(0o700);
        const file = try self.dir.createFile(compat.io(), temp_name, .{
            .exclusive = true,
            .permissions = permissions,
        });
        var file_open = true;
        defer if (file_open) file.close(compat.io());
        var temp_owned = true;
        defer if (temp_owned) self.dir.deleteFile(compat.io(), temp_name) catch {};
        try compat.fileWriteAll(file, script.bytes);
        try file.sync(compat.io());
        file.close(compat.io());
        file_open = false;

        const script_path = try self.dir.realPathFileAlloc(compat.io(), temp_name, allocator);
        defer allocator.free(script_path);
        const arguments = try allocator.alloc(override.ExecutionArgument, invocation.args.len);
        defer allocator.free(arguments);
        for (invocation.args, arguments) |argument, *execution_argument| {
            execution_argument.* = .{ .key = argument.key, .value = argument.value };
        }
        const patch = try override.executeScriptPatch(
            allocator,
            script_path,
            arguments,
            invocation.timeout_ms,
            invocation.command,
            invocation.config_path,
        );
        errdefer allocator.free(patch);
        try self.dir.deleteFile(compat.io(), temp_name);
        temp_owned = false;
        return patch;
    }
};

pub const BuildInput = struct {
    source: []const u8,
    script: Script,
    invocation: Invocation,
    runner: Runner,
};

pub const Materialization = struct {
    allocator: std.mem.Allocator,
    script: Script,
    invocation: Invocation,
    patch_bytes: []const u8,
    effective_source: []const u8,

    pub fn deinit(self: *Materialization) void {
        self.allocator.free(self.script.name);
        self.allocator.free(self.script.bytes);
        self.allocator.free(self.invocation.command);
        if (self.invocation.config_path) |path| self.allocator.free(path);
        for (self.invocation.args) |argument| {
            self.allocator.free(argument.key);
            self.allocator.free(argument.value);
        }
        self.allocator.free(self.invocation.args);
        self.allocator.free(self.patch_bytes);
        self.allocator.free(self.effective_source);
        self.* = undefined;
    }
};

pub fn build(allocator: std.mem.Allocator, input: BuildInput) !Materialization {
    try validateInput(input);

    const script_name = try allocator.dupe(u8, input.script.name);
    errdefer allocator.free(script_name);
    const script_bytes = try allocator.dupe(u8, input.script.bytes);
    errdefer allocator.free(script_bytes);
    const command = try allocator.dupe(u8, input.invocation.command);
    errdefer allocator.free(command);
    const config_path = if (input.invocation.config_path) |path|
        try allocator.dupe(u8, path)
    else
        null;
    errdefer if (config_path) |path| allocator.free(path);

    const args = try allocator.alloc(Argument, input.invocation.args.len);
    var args_initialized: usize = 0;
    errdefer {
        for (args[0..args_initialized]) |argument| {
            allocator.free(argument.key);
            allocator.free(argument.value);
        }
        allocator.free(args);
    }
    for (input.invocation.args, args) |argument, *owned| {
        const key = try allocator.dupe(u8, argument.key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, argument.value);
        owned.* = .{ .key = key, .value = value };
        args_initialized += 1;
    }

    const frozen_script: Script = .{ .name = script_name, .bytes = script_bytes };
    const frozen_invocation: Invocation = .{
        .command = command,
        .config_path = config_path,
        .timeout_ms = input.invocation.timeout_ms,
        .args = args,
    };
    const patch = try input.runner.run(
        input.runner.context,
        allocator,
        frozen_script,
        frozen_invocation,
    );
    errdefer allocator.free(patch);
    if (patch.len > max_patch_bytes) return error.OverridePatchTooLarge;

    const effective = try override.materializeSource(allocator, input.source, patch);
    errdefer allocator.free(effective);
    if (effective.len > max_effective_source_bytes) return error.MaterializedSourceTooLarge;

    return .{
        .allocator = allocator,
        .script = frozen_script,
        .invocation = frozen_invocation,
        .patch_bytes = patch,
        .effective_source = effective,
    };
}

fn validateInput(input: BuildInput) !void {
    if (input.source.len > max_effective_source_bytes) return error.SourceTooLarge;
    if (input.script.bytes.len > max_script_bytes) return error.OverrideScriptTooLarge;
    if (!isSingleComponent(input.script.name)) return error.InvalidOverrideScriptName;
    if (!isText(input.invocation.command)) return error.InvalidOverrideInvocation;
    if (input.invocation.config_path) |path| {
        if (!isText(path)) return error.InvalidOverrideInvocation;
    }
    for (input.invocation.args) |argument| {
        if (!isText(argument.key) or !isUtf8WithoutNul(argument.value)) {
            return error.InvalidOverrideInvocation;
        }
    }
}

fn isSingleComponent(name: []const u8) bool {
    return name.len != 0 and name.len <= 255 and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\\") == null and isText(name);
}

fn isText(text: []const u8) bool {
    if (text.len == 0 or !isUtf8WithoutNul(text)) return false;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn isUtf8WithoutNul(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text) and std.mem.indexOfScalar(u8, text, 0) == null;
}
