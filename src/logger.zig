const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    level: Level,
    file: ?std.fs.File = null,
    enable_console: bool = true,
    enable_file: bool = true,

    pub fn init(allocator: std.mem.Allocator) Logger {
        return .{
            .allocator = allocator,
            .level = .info,
        };
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |f| {
            f.close();
        }
    }

    pub fn setLevel(self: *Logger, level: Level) void {
        self.level = level;
    }

    pub fn setFile(self: *Logger, path: []const u8) !void {
        self.file = try std.fs.createFileAbsolute(path, .{
            .access_sub_path = true,
            .append = true,
        });
    }

    fn shouldLog(self: *const Logger, level: Level) bool {
        const level_order: u2 = switch (level) {
            .debug => 0,
            .info => 1,
            .warn => 2,
            .err => 3,
        };
        const current_level: u2 = switch (self.level) {
            .debug => 0,
            .info => 1,
            .warn => 2,
            .err => 3,
        };
        return level_order >= current_level;
    }

    pub fn log(self: *Logger, level: Level, comptime format: []const u8, args: anytype) void {
        if (!self.shouldLog(level)) return;

        const timestamp = std.time.Timestamp{};
        const now = timestamp.now();

        const level_str = switch (level) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };

        const prefix = std.fmt.comptimePrint("[{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}] [{s}] ", .{
            now.year,           @intCast(now.month),  @intCast(now.day),
            @intCast(now.hour), @intCast(now.minute), @intCast(now.second),
            level_str,
        });

        const message = std.fmt.allocPrint(self.allocator, format, args) catch {
            return;
        };
        defer self.allocator.free(message);

        const line = std.fmt.allocPrint(self.allocator, "{s}{s}\n", .{ prefix, message }) catch {
            return;
        };
        defer self.allocator.free(line);

        if (self.enable_console) {
            std.debug.print("{s}", .{line});
        }

        if (self.enable_file and self.file) |f| {
            f.writeAll(line) catch {};
        }
    }

    pub fn debug(self: *Logger, comptime format: []const u8, args: anytype) void {
        self.log(.debug, format, args);
    }

    pub fn info(self: *Logger, comptime format: []const u8, args: anytype) void {
        self.log(.info, format, args);
    }

    pub fn warn(self: *Logger, comptime format: []const u8, args: anytype) void {
        self.log(.warn, format, args);
    }

    pub fn err(self: *Logger, comptime format: []const u8, args: anytype) void {
        self.log(.err, format, args);
    }
};

pub var global_logger: Logger = undefined;

pub fn initGlobalLogger(allocator: std.mem.Allocator) void {
    global_logger = Logger.init(allocator);
}

pub fn getGlobalLogger() *Logger {
    return &global_logger;
}
