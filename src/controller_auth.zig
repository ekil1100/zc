const std = @import("std");

pub const max_secret_bytes: usize = 256;

pub fn isValidSecret(secret: []const u8) bool {
    if (secret.len == 0 or secret.len > max_secret_bytes) return false;
    for (secret) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '-', '.', '_', '~' => {},
            else => return false,
        }
    }
    return true;
}

pub fn isAuthorized(
    configured_secret: ?[]const u8,
    authorization: ?[]const u8,
) bool {
    const secret = configured_secret orelse return true;
    if (secret.len == 0) return true;
    if (!isValidSecret(secret)) return false;
    const value = authorization orelse return false;
    const prefix = "Bearer ";
    if (value.len != prefix.len + secret.len or
        !std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix))
    {
        return false;
    }
    var difference: u8 = 0;
    for (value[prefix.len..], secret) |actual, expected| {
        difference |= actual ^ expected;
    }
    return difference == 0;
}

test "controller bearer secrets are bounded tokens" {
    try std.testing.expect(isValidSecret("aZ09-._~"));
    try std.testing.expect(!isValidSecret(""));
    try std.testing.expect(!isValidSecret("has space"));
    try std.testing.expect(!isValidSecret("has:colon"));

    var too_long: [max_secret_bytes + 1]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expect(!isValidSecret(&too_long));
}
