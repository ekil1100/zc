const std = @import("std");

pub const Revision = struct {
    bytes: [16]u8,

    pub fn parseHex(text: []const u8) !Revision {
        if (text.len != 32 or !isLowerHex(text)) return error.InvalidRevision;
        var bytes: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, text) catch return error.InvalidRevision;
        return .{ .bytes = bytes };
    }

    pub fn formatHex(self: Revision, output: *[32]u8) []const u8 {
        output.* = std.fmt.bytesToHex(self.bytes, .lower);
        return output;
    }

    pub fn eql(a: Revision, b: Revision) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

pub fn legacyRevision(key: []const u8) Revision {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("zc.legacy-key.v1");
    hashLength(&hasher, key.len);
    hasher.update(key);
    const digest = hasher.finalResult();
    return .{ .bytes = digest[0..16].* };
}

pub const ManagedIdentity = struct {
    key: []const u8,
    revision: Revision,
};

pub const StorageId = struct {
    bytes: [32]u8,

    pub fn derive(key: []const u8) StorageId {
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("zc.profile-storage.v1");
        hashLength(&hasher, key.len);
        hasher.update(key);
        hasher.final(&digest);
        return .{ .bytes = digest };
    }

    pub fn parseHex(text: []const u8) !StorageId {
        if (text.len != 64 or !isLowerHex(text)) return error.InvalidStorageId;
        var bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, text) catch return error.InvalidStorageId;
        return .{ .bytes = bytes };
    }

    pub fn formatHex(self: StorageId, output: *[64]u8) []const u8 {
        output.* = std.fmt.bytesToHex(self.bytes, .lower);
        return output;
    }

    pub fn eql(a: StorageId, b: StorageId) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

fn isLowerHex(text: []const u8) bool {
    for (text) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn hashLength(hasher: *std.crypto.hash.sha2.Sha256, length: usize) void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, @intCast(length), .big);
    hasher.update(&buffer);
}

test "config identity uses canonical exact-byte encodings" {
    const testing = std.testing;
    const revision = try Revision.parseHex("00112233445566778899aabbccddeeff");
    var revision_hex: [32]u8 = undefined;
    try testing.expectEqualStrings(
        "00112233445566778899aabbccddeeff",
        revision.formatHex(&revision_hex),
    );
    try testing.expectError(
        error.InvalidRevision,
        Revision.parseHex("00112233445566778899AABBCCDDEEFF"),
    );

    try testing.expect(!legacyRevision("home").eql(legacyRevision("Home")));

    const storage_id = StorageId.derive("home");
    var storage_hex: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "dc3fb855b586386498f9ec0db774a3d31da4003977fcbcd9a697fb7455a6645b",
        storage_id.formatHex(&storage_hex),
    );
    try testing.expect((try StorageId.parseHex(&storage_hex)).eql(storage_id));
}
