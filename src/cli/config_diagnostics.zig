const std = @import("std");
const cli_output = @import("output.zig");
const validator = @import("../config_validator.zig");
const safe_text = @import("../safe_text.zig");

const diagnostic_count_max = validator.validation_diagnostic_count_max;
const escaped_diagnostic_bytes_max =
    validator.validation_diagnostic_bytes_max *
    safe_text.escape_expansion_factor_max;

pub const View = struct {
    config_errors: []const []const u8,
    config_warnings: []const []const u8,
    config_diagnostics_truncated: bool,
};

/// Stack-owned slices that borrow messages from one live ValidationResult.
pub const Storage = struct {
    errors: [diagnostic_count_max][]const u8 = undefined,
    warnings: [diagnostic_count_max][]const u8 = undefined,
    error_count: usize = 0,
    warning_count: usize = 0,
    truncated: bool = false,

    pub fn init(
        storage: *Storage,
        result: *const validator.ValidationResult,
    ) void {
        storage.* = .{
            .truncated = result.diagnostics_truncated,
        };
        std.debug.assert(
            result.errors.items.len + result.warnings.items.len <=
                diagnostic_count_max,
        );
        for (0..diagnostic_count_max) |error_index| {
            if (error_index == result.errors.items.len) break;
            const diagnostic = result.errors.items[error_index];
            std.debug.assert(storage.error_count < storage.errors.len);
            storage.errors[storage.error_count] = diagnostic.message;
            storage.error_count += 1;
        }
        for (0..diagnostic_count_max) |warning_index| {
            if (warning_index == result.warnings.items.len) break;
            const diagnostic = result.warnings.items[warning_index];
            std.debug.assert(storage.warning_count < storage.warnings.len);
            storage.warnings[storage.warning_count] = diagnostic.message;
            storage.warning_count += 1;
        }
        std.debug.assert(
            storage.error_count + storage.warning_count <=
                diagnostic_count_max,
        );
    }

    pub fn view(self: *const Storage) View {
        return .{
            .config_errors = self.errors[0..self.error_count],
            .config_warnings = self.warnings[0..self.warning_count],
            .config_diagnostics_truncated = self.truncated,
        };
    }
};

/// Renders diagnostics as safe, single-line stderr entries. JSON output keeps
/// original strings and relies on std.json escaping instead.
pub fn renderText(
    output: *cli_output.Output,
    result: *const validator.ValidationResult,
) !void {
    if (result.errors.items.len > 0) {
        try output.note("\nConfiguration errors:\n", .{});
        std.debug.assert(result.errors.items.len <= diagnostic_count_max);
        for (0..diagnostic_count_max) |error_index| {
            if (error_index == result.errors.items.len) break;
            const diagnostic = result.errors.items[error_index];
            var escaped_buffer: [escaped_diagnostic_bytes_max]u8 = undefined;
            const escaped = safe_text.escape(
                diagnostic.message,
                &escaped_buffer,
            );
            try output.note(
                "  [{d}] {s}\n",
                .{ error_index + 1, escaped },
            );
        }
    }
    if (result.warnings.items.len > 0) {
        try output.note("\nConfiguration warnings:\n", .{});
        std.debug.assert(result.warnings.items.len <= diagnostic_count_max);
        for (0..diagnostic_count_max) |warning_index| {
            if (warning_index == result.warnings.items.len) break;
            const diagnostic = result.warnings.items[warning_index];
            var escaped_buffer: [escaped_diagnostic_bytes_max]u8 = undefined;
            const escaped = safe_text.escape(
                diagnostic.message,
                &escaped_buffer,
            );
            try output.note(
                "  [{d}] {s}\n",
                .{ warning_index + 1, escaped },
            );
        }
    }
    if (result.diagnostics_truncated) {
        try output.note(
            "\nAdditional validation details were omitted " ++
                "(max {d} entries, {d} bytes each).\n",
            .{
                validator.validation_diagnostic_count_max,
                validator.validation_diagnostic_bytes_max,
            },
        );
    }
}

test "diagnostic storage exposes JSON string arrays without allocation" {
    // Initialize caller-owned storage and verify its view borrows the bounded
    // validation messages without allocating or changing their contents.
    const allocator = std.testing.allocator;
    var result = validator.ValidationResult.init(allocator);
    defer result.deinit();
    try result.errors.append(allocator, .{
        .message = try allocator.dupe(u8, "bad config 1"),
    });
    try result.warnings.append(allocator, .{
        .message = try allocator.dupe(u8, "unsafe setting"),
    });
    result.has_errors = true;

    var storage: Storage = undefined;
    storage.init(&result);
    const view_value = storage.view();
    try std.testing.expectEqual(@as(usize, 1), view_value.config_errors.len);
    try std.testing.expectEqualStrings(
        "bad config 1",
        view_value.config_errors[0],
    );
    try std.testing.expectEqual(@as(usize, 1), view_value.config_warnings.len);
    try std.testing.expectEqualStrings(
        "unsafe setting",
        view_value.config_warnings[0],
    );
    try std.testing.expect(!view_value.config_diagnostics_truncated);
}
