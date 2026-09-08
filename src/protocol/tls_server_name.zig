const std = @import("std");

pub const bytes_max: usize = 253;

pub const ValidationError = error{
    EmptyServerName,
    ServerNameTooLong,
    InvalidServerName,
    SNIMustBeHostname,
};

pub fn validateServer(value: []const u8) ValidationError!void {
    try validateLength(value);
    const normalized = stripRootDot(value);
    if (isIPLiteral(normalized)) {
        if (normalized.len != value.len) return error.InvalidServerName;
        return;
    }
    std.Io.net.HostName.validate(value) catch return error.InvalidServerName;
}

pub fn validateSNI(value: []const u8) ValidationError!void {
    try validateLength(value);
    if (value[value.len - 1] == '.') return error.InvalidServerName;
    if (isIPLiteral(value)) return error.SNIMustBeHostname;
    std.Io.net.HostName.validate(value) catch return error.InvalidServerName;
}

pub fn stripRootDot(value: []const u8) []const u8 {
    if (std.mem.endsWith(u8, value, ".")) {
        return value[0 .. value.len - 1];
    }
    return value;
}

pub fn isIPLiteral(value: []const u8) bool {
    if (std.Io.net.IpAddress.parse(value, 0)) |_| {
        return true;
    } else |_| {
        return false;
    }
}

fn validateLength(value: []const u8) ValidationError!void {
    if (value.len == 0) return error.EmptyServerName;
    if (value.len > bytes_max) return error.ServerNameTooLong;
}

test "TLS server names accept IP literals and RFC hostnames" {
    // Validate focused endpoint identities and inspect the accepted and
    // rejected name classes.
    try validateServer("example.com");
    try validateServer("node-1.example.com");
    try validateServer("edge.example.com.");
    try validateServer("127.0.0.1");
    try validateServer("2001:db8::1");
    try validateSNI("edge.example.com");
    try std.testing.expectError(
        error.InvalidServerName,
        validateServer("127.0.0.1."),
    );
}

test "TLS server names reject wildcard whitespace Unicode and IP SNI" {
    // Validate focused endpoint identities and inspect the accepted and
    // rejected name classes.
    const invalid = [_][]const u8{
        "",
        "*.example.com",
        "edge example.com",
        "edge_example.com",
        "edge\xc2\x85example.com",
        "-edge.example.com",
        "edge-.example.com",
        "edge.example.com.",
    };
    for (invalid) |value| {
        try std.testing.expectError(
            if (value.len == 0)
                error.EmptyServerName
            else
                error.InvalidServerName,
            validateSNI(value),
        );
    }
    try std.testing.expectError(
        error.SNIMustBeHostname,
        validateSNI("127.0.0.1"),
    );
    try std.testing.expectError(
        error.ServerNameTooLong,
        validateServer("a" ** (bytes_max + 1)),
    );
}
