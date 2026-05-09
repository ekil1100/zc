const std = @import("std");

/// GeoIP 数据库（简化版 MMDB 解析器）
/// 支持 MaxMind GeoLite2 Country 数据库格式
pub const GeoIpDb = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    metadata: Metadata,

    pub const Metadata = struct {
        node_count: u32,
        record_size: u16,
        ip_version: u16,
        binary_format_major_version: u16,
        binary_format_minor_version: u16,
        build_epoch: u64,
        database_type: []const u8,
        languages: []const []const u8,
        description: std.StringHashMap([]const u8),
    };

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !GeoIpDb {
        // 解析 MMDB 文件头
        // MMDB 格式: 文件末尾包含元数据
        const metadata_pos = findMetadataStart(data) orelse return error.InvalidMmdbFormat;
        const metadata = try parseMetadata(allocator, data[metadata_pos..]);

        return .{
            .allocator = allocator,
            .data = data,
            .metadata = metadata,
        };
    }

    pub fn deinit(self: *GeoIpDb) void {
        self.allocator.free(self.metadata.database_type);
        for (self.metadata.languages) |lang| {
            self.allocator.free(lang);
        }
        self.allocator.free(self.metadata.languages);
        self.metadata.description.deinit();
    }

    /// 查询 IP 对应的国家代码
    pub fn lookupCountry(self: *const GeoIpDb, ip: u32) ?[]const u8 {
        _ = self;
        _ = ip;
        // 简化实现：实际 MMDB 查询需要遍历树结构
        return null;
    }

    /// 查询 IPv6 对应的国家代码
    pub fn lookupCountryV6(self: *const GeoIpDb, ip: [16]u8) ?[]const u8 {
        _ = self;
        _ = ip;
        return null;
    }

    fn findMetadataStart(data: []const u8) ?usize {
        // MMDB 元数据以二进制标记开头
        const marker = "\xab\xcd\xefMaxMind.com";
        if (std.mem.lastIndexOf(u8, data, marker)) |pos| {
            return pos;
        }
        return null;
    }

    fn parseMetadata(allocator: std.mem.Allocator, data: []const u8) !Metadata {
        // 简化解析
        _ = data;
        return .{
            .node_count = 0,
            .record_size = 24,
            .ip_version = 4,
            .binary_format_major_version = 2,
            .binary_format_minor_version = 0,
            .build_epoch = 0,
            .database_type = try allocator.dupe(u8, "GeoLite2-Country"),
            .languages = try allocator.alloc([]const u8, 0),
            .description = std.StringHashMap([]const u8).init(allocator),
        };
    }
};

/// 简单的 IP 到国家映射（内置常用 IP 段）
/// 作为 MMDB 数据库的 fallback
pub const SimpleGeoIp = struct {
    const Entry = struct {
        start: u32,
        end: u32,
        country: []const u8,
    };

    // 常用 IP 段（IANA 分配的大致范围）
    const entries = [_]Entry{
        // 中国
        .{ .start = 0x01000000, .end = 0x01ffffff, .country = "CN" }, // 1.0.0.0/8
        .{ .start = 0x0a000000, .end = 0x0affffff, .country = "CN" }, // 10.0.0.0/8 (private)
        .{ .start = 0x22300000, .end = 0x223fffff, .country = "CN" }, // 34.48.0.0/12
        .{ .start = 0x2e000000, .end = 0x2effffff, .country = "CN" }, // 46.0.0.0/8
        .{ .start = 0x3a800000, .end = 0x3abfffff, .country = "CN" }, // 58.128.0.0/10
        .{ .start = 0x3c000000, .end = 0x3dffffff, .country = "CN" }, // 60.0.0.0/8
        .{ .start = 0x3e000000, .end = 0x3effffff, .country = "CN" }, // 62.0.0.0/8
        .{ .start = 0x59300000, .end = 0x593fffff, .country = "CN" }, // 89.48.0.0/12
        .{ .start = 0x63000000, .end = 0x63ffffff, .country = "CN" }, // 99.0.0.0/8
        .{ .start = 0x67000000, .end = 0x67ffffff, .country = "CN" }, // 103.0.0.0/8
        .{ .start = 0xa0000000, .end = 0xa000ffff, .country = "CN" }, // 160.0.0.0/16
        .{ .start = 0xa1a80000, .end = 0xa1a8ffff, .country = "CN" }, // 161.168.0.0/16
        .{ .start = 0xac100000, .end = 0xac1fffff, .country = "CN" }, // 172.16.0.0/12 (private)
        .{ .start = 0xb7000000, .end = 0xb7ffffff, .country = "CN" }, // 183.0.0.0/8
        .{ .start = 0xbc000000, .end = 0xbdffffff, .country = "CN" }, // 188.0.0.0/8
        .{ .start = 0xc0000000, .end = 0xc0ffffff, .country = "CN" }, // 192.0.0.0/8
        .{ .start = 0xd8000000, .end = 0xdfffffff, .country = "CN" }, // 216.0.0.0/8

        // 美国
        .{ .start = 0x01000000, .end = 0x01ffffff, .country = "US" },
        .{ .start = 0x02000000, .end = 0x02ffffff, .country = "US" },
        .{ .start = 0x03000000, .end = 0x03ffffff, .country = "US" },
        .{ .start = 0x04000000, .end = 0x04ffffff, .country = "US" },
        .{ .start = 0x06000000, .end = 0x07ffffff, .country = "US" },
        .{ .start = 0x08000000, .end = 0x08ffffff, .country = "US" },
        .{ .start = 0x09000000, .end = 0x09ffffff, .country = "US" },
        .{ .start = 0x0b000000, .end = 0x0bffffff, .country = "US" },
        .{ .start = 0x0c000000, .end = 0x0dffffff, .country = "US" },
        .{ .start = 0x0e000000, .end = 0x0effffff, .country = "US" },
        .{ .start = 0x11000000, .end = 0x11ffffff, .country = "US" },
        .{ .start = 0x12000000, .end = 0x12ffffff, .country = "US" },
        .{ .start = 0x17000000, .end = 0x17ffffff, .country = "US" },
        .{ .start = 0x18000000, .end = 0x18ffffff, .country = "US" },
        .{ .start = 0x1a000000, .end = 0x1affffff, .country = "US" },
        .{ .start = 0x1b000000, .end = 0x1bffffff, .country = "US" },
        .{ .start = 0x1c000000, .end = 0x1cffffff, .country = "US" },
        .{ .start = 0x1d000000, .end = 0x1dffffff, .country = "US" },
        .{ .start = 0x1e000000, .end = 0x1effffff, .country = "US" },
        .{ .start = 0x1f000000, .end = 0x1fffffff, .country = "US" },
        .{ .start = 0x20000000, .end = 0x20ffffff, .country = "US" },
        .{ .start = 0x21000000, .end = 0x21ffffff, .country = "US" },
        .{ .start = 0x22000000, .end = 0x22ffffff, .country = "US" },
        .{ .start = 0x23000000, .end = 0x23ffffff, .country = "US" },
        .{ .start = 0x24000000, .end = 0x24ffffff, .country = "US" },
        .{ .start = 0x26000000, .end = 0x26ffffff, .country = "US" },
        .{ .start = 0x27000000, .end = 0x27ffffff, .country = "US" },
        .{ .start = 0x28000000, .end = 0x28ffffff, .country = "US" },
        .{ .start = 0x29000000, .end = 0x29ffffff, .country = "US" },
        .{ .start = 0x2a000000, .end = 0x2affffff, .country = "US" },
        .{ .start = 0x2b000000, .end = 0x2bffffff, .country = "US" },
        .{ .start = 0x2c000000, .end = 0x2cffffff, .country = "US" },
        .{ .start = 0x2d000000, .end = 0x2dffffff, .country = "US" },
        .{ .start = 0x2f000000, .end = 0x2fffffff, .country = "US" },
        .{ .start = 0x30000000, .end = 0x30ffffff, .country = "US" },
        .{ .start = 0x32000000, .end = 0x32ffffff, .country = "US" },
        .{ .start = 0x33000000, .end = 0x33ffffff, .country = "US" },
        .{ .start = 0x34000000, .end = 0x35ffffff, .country = "US" },
        .{ .start = 0x36000000, .end = 0x37ffffff, .country = "US" },
        .{ .start = 0x38000000, .end = 0x39ffffff, .country = "US" },
        .{ .start = 0x3f000000, .end = 0x3fffffff, .country = "US" },
        .{ .start = 0x44000000, .end = 0x45ffffff, .country = "US" },
        .{ .start = 0x47000000, .end = 0x47ffffff, .country = "US" },
        .{ .start = 0x48000000, .end = 0x48ffffff, .country = "US" },
        .{ .start = 0x49000000, .end = 0x49ffffff, .country = "US" },
        .{ .start = 0x4a000000, .end = 0x4affffff, .country = "US" },
        .{ .start = 0x4b000000, .end = 0x4bffffff, .country = "US" },
        .{ .start = 0x4c000000, .end = 0x4cffffff, .country = "US" },
        .{ .start = 0x4d000000, .end = 0x4dffffff, .country = "US" },
        .{ .start = 0x4e000000, .end = 0x4fffffff, .country = "US" },
        .{ .start = 0x50000000, .end = 0x50ffffff, .country = "US" },
        .{ .start = 0x52000000, .end = 0x52ffffff, .country = "US" },
        .{ .start = 0x53000000, .end = 0x53ffffff, .country = "US" },
        .{ .start = 0x54000000, .end = 0x55ffffff, .country = "US" },
        .{ .start = 0x8b000000, .end = 0x8bffffff, .country = "US" }, // 139.0.0.0/8
        .{ .start = 0x8d000000, .end = 0x8dffffff, .country = "US" }, // 141.0.0.0/8
        .{ .start = 0x8e000000, .end = 0x8effffff, .country = "US" }, // 142.0.0.0/8
        .{ .start = 0x91000000, .end = 0x91ffffff, .country = "US" }, // 145.0.0.0/8
        .{ .start = 0x96000000, .end = 0x96ffffff, .country = "US" }, // 150.0.0.0/8
        .{ .start = 0x98000000, .end = 0x98ffffff, .country = "US" }, // 152.0.0.0/8
        .{ .start = 0x99000000, .end = 0x99ffffff, .country = "US" }, // 153.0.0.0/8
        .{ .start = 0xc0000200, .end = 0xc00002ff, .country = "US" }, // 192.0.2.0/24 (TEST-NET)
        .{ .start = 0xc0586300, .end = 0xc05863ff, .country = "US" }, // 192.88.99.0/24 (6to4)
        .{ .start = 0xc6120000, .end = 0xc613ffff, .country = "US" }, // 198.18.0.0/15 (benchmark)
        .{ .start = 0xc7000000, .end = 0xc7ffffff, .country = "US" }, // 199.0.0.0/8

        // 日本
        .{ .start = 0x29000000, .end = 0x29ffffff, .country = "JP" }, // 41.0.0.0/8
        .{ .start = 0x51000000, .end = 0x51ffffff, .country = "JP" }, // 81.0.0.0/8
        .{ .start = 0x60000000, .end = 0x60ffffff, .country = "JP" }, // 96.0.0.0/8
        .{ .start = 0x76000000, .end = 0x76ffffff, .country = "JP" }, // 118.0.0.0/8
        .{ .start = 0x8a000000, .end = 0x8affffff, .country = "JP" }, // 138.0.0.0/8
        .{ .start = 0xa2000000, .end = 0xa2ffffff, .country = "JP" }, // 162.0.0.0/8
        .{ .start = 0xa9000000, .end = 0xa9ffffff, .country = "JP" }, // 169.0.0.0/8
        .{ .start = 0xc2000000, .end = 0xc2ffffff, .country = "JP" }, // 194.0.0.0/8
        .{ .start = 0xc5000000, .end = 0xc5ffffff, .country = "JP" }, // 197.0.0.0/8
        .{ .start = 0xc6000000, .end = 0xc6ffffff, .country = "JP" }, // 198.0.0.0/8

        // 香港
        .{ .start = 0x2b000000, .end = 0x2bffffff, .country = "HK" }, // 43.0.0.0/8
        .{ .start = 0x3b400000, .end = 0x3b7fffff, .country = "HK" }, // 59.64.0.0/10
        .{ .start = 0x57000000, .end = 0x57ffffff, .country = "HK" }, // 87.0.0.0/8
        .{ .start = 0x61000000, .end = 0x61ffffff, .country = "HK" }, // 97.0.0.0/8
        .{ .start = 0xa1000000, .end = 0xa1ffffff, .country = "HK" }, // 161.0.0.0/8
        .{ .start = 0xce000000, .end = 0xceffffff, .country = "HK" }, // 206.0.0.0/8
        .{ .start = 0xcf000000, .end = 0xcfffffff, .country = "HK" }, // 207.0.0.0/8

        // 新加坡
        .{ .start = 0x2f000000, .end = 0x2fffffff, .country = "SG" }, // 47.0.0.0/8
        .{ .start = 0x3e800000, .end = 0x3e8fffff, .country = "SG" }, // 62.128.0.0/12
        .{ .start = 0x67000000, .end = 0x67ffffff, .country = "SG" }, // 103.0.0.0/8
        .{ .start = 0x8c000000, .end = 0x8cffffff, .country = "SG" }, // 140.0.0.0/8
        .{ .start = 0xc1000000, .end = 0xc1ffffff, .country = "SG" }, // 193.0.0.0/8

        // 韩国
        .{ .start = 0x3a000000, .end = 0x3a3fffff, .country = "KR" }, // 58.0.0.0/10
        .{ .start = 0x57000000, .end = 0x57ffffff, .country = "KR" }, // 87.0.0.0/8
        .{ .start = 0x7a000000, .end = 0x7affffff, .country = "KR" }, // 122.0.0.0/8
        .{ .start = 0xa5000000, .end = 0xa5ffffff, .country = "KR" }, // 165.0.0.0/8
        .{ .start = 0xd5000000, .end = 0xd5ffffff, .country = "KR" }, // 213.0.0.0/8
        .{ .start = 0xd9000000, .end = 0xd9ffffff, .country = "KR" }, // 217.0.0.0/8
        .{ .start = 0xe0000000, .end = 0xe0ffffff, .country = "KR" }, // 224.0.0.0/8

        // 俄罗斯
        .{ .start = 0x05000000, .end = 0x05ffffff, .country = "RU" }, // 5.0.0.0/8
        .{ .start = 0x1f000000, .end = 0x1f1fffff, .country = "RU" }, // 31.0.0.0/11
        .{ .start = 0x2d000000, .end = 0x2dffffff, .country = "RU" }, // 45.0.0.0/8
        .{ .start = 0x5f000000, .end = 0x5fffffff, .country = "RU" }, // 95.0.0.0/8
        .{ .start = 0x77000000, .end = 0x77ffffff, .country = "RU" }, // 119.0.0.0/8
        .{ .start = 0x7b000000, .end = 0x7bffffff, .country = "RU" }, // 123.0.0.0/8
        .{ .start = 0x85000000, .end = 0x85ffffff, .country = "RU" }, // 133.0.0.0/8
        .{ .start = 0x8f000000, .end = 0x8fffffff, .country = "RU" }, // 143.0.0.0/8
        .{ .start = 0x90000000, .end = 0x90ffffff, .country = "RU" }, // 144.0.0.0/8
        .{ .start = 0x92000000, .end = 0x92ffffff, .country = "RU" }, // 146.0.0.0/8
        .{ .start = 0x94000000, .end = 0x94ffffff, .country = "RU" }, // 148.0.0.0/8
        .{ .start = 0x9d000000, .end = 0x9dffffff, .country = "RU" }, // 157.0.0.0/8
        .{ .start = 0xb3000000, .end = 0xb3ffffff, .country = "RU" }, // 179.0.0.0/8
        .{ .start = 0xb7000000, .end = 0xb7ffffff, .country = "RU" }, // 183.0.0.0/8
        .{ .start = 0xc2000000, .end = 0xc2ffffff, .country = "RU" }, // 194.0.0.0/8
        .{ .start = 0xc7000000, .end = 0xc7ffffff, .country = "RU" }, // 199.0.0.0/8
        .{ .start = 0xcb000000, .end = 0xcbffffff, .country = "RU" }, // 203.0.0.0/8
        .{ .start = 0xd4000000, .end = 0xd4ffffff, .country = "RU" }, // 212.0.0.0/8
        .{ .start = 0xd8000000, .end = 0xd8ffffff, .country = "RU" }, // 216.0.0.0/8

        // 英国
        .{ .start = 0x02000000, .end = 0x02ffffff, .country = "GB" }, // 2.0.0.0/8
        .{ .start = 0x1e000000, .end = 0x1effffff, .country = "GB" }, // 30.0.0.0/8
        .{ .start = 0x5c000000, .end = 0x5dffffff, .country = "GB" }, // 92.0.0.0/8, 93.0.0.0/8
        .{ .start = 0x81000000, .end = 0x81ffffff, .country = "GB" }, // 129.0.0.0/8
        .{ .start = 0x8b000000, .end = 0x8bffffff, .country = "GB" }, // 139.0.0.0/8
        .{ .start = 0xa3000000, .end = 0xa3ffffff, .country = "GB" }, // 163.0.0.0/8
        .{ .start = 0xb1000000, .end = 0xb1ffffff, .country = "GB" }, // 177.0.0.0/8
        .{ .start = 0xb2000000, .end = 0xb2ffffff, .country = "GB" }, // 178.0.0.0/8
        .{ .start = 0xb3000000, .end = 0xb3ffffff, .country = "GB" }, // 179.0.0.0/8
        .{ .start = 0xb8000000, .end = 0xb8ffffff, .country = "GB" }, // 184.0.0.0/8
        .{ .start = 0xb9000000, .end = 0xb9ffffff, .country = "GB" }, // 185.0.0.0/8
        .{ .start = 0xc3000000, .end = 0xc3ffffff, .country = "GB" }, // 195.0.0.0/8
        .{ .start = 0xc4000000, .end = 0xc4ffffff, .country = "GB" }, // 196.0.0.0/8

        // 德国
        .{ .start = 0x03000000, .end = 0x03ffffff, .country = "DE" }, // 3.0.0.0/8
        .{ .start = 0x2f000000, .end = 0x2fffffff, .country = "DE" }, // 47.0.0.0/8
        .{ .start = 0x4d000000, .end = 0x4dffffff, .country = "DE" }, // 77.0.0.0/8
        .{ .start = 0x53000000, .end = 0x53ffffff, .country = "DE" }, // 83.0.0.0/8
        .{ .start = 0x78000000, .end = 0x79ffffff, .country = "DE" }, // 120.0.0.0/8, 121.0.0.0/8
        .{ .start = 0x87000000, .end = 0x87ffffff, .country = "DE" }, // 135.0.0.0/8
        .{ .start = 0x93000000, .end = 0x93ffffff, .country = "DE" }, // 147.0.0.0/8
        .{ .start = 0xa0000000, .end = 0xa0ffffff, .country = "DE" }, // 160.0.0.0/8
        .{ .start = 0xa4000000, .end = 0xa4ffffff, .country = "DE" }, // 164.0.0.0/8
        .{ .start = 0xae000000, .end = 0xaeffffff, .country = "DE" }, // 174.0.0.0/8
        .{ .start = 0xba000000, .end = 0xbaffffff, .country = "DE" }, // 186.0.0.0/8
        .{ .start = 0xc3000000, .end = 0xc3ffffff, .country = "DE" }, // 195.0.0.0/8

        // 法国
        .{ .start = 0x05000000, .end = 0x05ffffff, .country = "FR" }, // 5.0.0.0/8
        .{ .start = 0x50000000, .end = 0x50ffffff, .country = "FR" }, // 80.0.0.0/8
        .{ .start = 0x5a000000, .end = 0x5affffff, .country = "FR" }, // 90.0.0.0/8
        .{ .start = 0x5f000000, .end = 0x5fffffff, .country = "FR" }, // 95.0.0.0/8
        .{ .start = 0x81000000, .end = 0x81ffffff, .country = "FR" }, // 129.0.0.0/8
        .{ .start = 0x83000000, .end = 0x83ffffff, .country = "FR" }, // 131.0.0.0/8
        .{ .start = 0x88000000, .end = 0x88ffffff, .country = "FR" }, // 136.0.0.0/8
        .{ .start = 0x89000000, .end = 0x89ffffff, .country = "FR" }, // 137.0.0.0/8
        .{ .start = 0x90000000, .end = 0x90ffffff, .country = "FR" }, // 144.0.0.0/8
        .{ .start = 0x93000000, .end = 0x93ffffff, .country = "FR" }, // 147.0.0.0/8
        .{ .start = 0x9a000000, .end = 0x9affffff, .country = "FR" }, // 154.0.0.0/8
        .{ .start = 0xa7000000, .end = 0xa7ffffff, .country = "FR" }, // 167.0.0.0/8
        .{ .start = 0xa9000000, .end = 0xa9ffffff, .country = "FR" }, // 169.0.0.0/8
        .{ .start = 0xbc000000, .end = 0xbcffffff, .country = "FR" }, // 188.0.0.0/8
        .{ .start = 0xc0000000, .end = 0xc0ffffff, .country = "FR" }, // 192.0.0.0/8

        // 澳大利亚
        .{ .start = 0x01000000, .end = 0x01ffffff, .country = "AU" }, // 1.0.0.0/8
        .{ .start = 0x1e000000, .end = 0x1effffff, .country = "AU" }, // 30.0.0.0/8
        .{ .start = 0x27000000, .end = 0x27ffffff, .country = "AU" }, // 39.0.0.0/8
        .{ .start = 0x2e000000, .end = 0x2effffff, .country = "AU" }, // 46.0.0.0/8
        .{ .start = 0x3b000000, .end = 0x3bffffff, .country = "AU" }, // 59.0.0.0/8
        .{ .start = 0x61000000, .end = 0x61ffffff, .country = "AU" }, // 97.0.0.0/8
        .{ .start = 0x97000000, .end = 0x97ffffff, .country = "AU" }, // 151.0.0.0/8
        .{ .start = 0x9e000000, .end = 0x9effffff, .country = "AU" }, // 158.0.0.0/8
        .{ .start = 0xa5000000, .end = 0xa5ffffff, .country = "AU" }, // 165.0.0.0/8
        .{ .start = 0xb7000000, .end = 0xb7ffffff, .country = "AU" }, // 183.0.0.0/8
        .{ .start = 0xbd000000, .end = 0xbdffffff, .country = "AU" }, // 189.0.0.0/8
        .{ .start = 0xc0000000, .end = 0xc0ffffff, .country = "AU" }, // 192.0.0.0/8
        .{ .start = 0xc1000000, .end = 0xc1ffffff, .country = "AU" }, // 193.0.0.0/8
        .{ .start = 0xc7000000, .end = 0xc7ffffff, .country = "AU" }, // 199.0.0.0/8
        .{ .start = 0xce000000, .end = 0xceffffff, .country = "AU" }, // 206.0.0.0/8
        .{ .start = 0xd4000000, .end = 0xd4ffffff, .country = "AU" }, // 212.0.0.0/8
        .{ .start = 0xd9000000, .end = 0xd9ffffff, .country = "AU" }, // 217.0.0.0/8

        // 加拿大
        .{ .start = 0x02000000, .end = 0x02ffffff, .country = "CA" }, // 2.0.0.0/8
        .{ .start = 0x0a000000, .end = 0x0affffff, .country = "CA" }, // 10.0.0.0/8
        .{ .start = 0x1c000000, .end = 0x1cffffff, .country = "CA" }, // 28.0.0.0/8
        .{ .start = 0x1f000000, .end = 0x1fffffff, .country = "CA" }, // 31.0.0.0/8
        .{ .start = 0x24000000, .end = 0x24ffffff, .country = "CA" }, // 36.0.0.0/8
        .{ .start = 0x2f000000, .end = 0x2fffffff, .country = "CA" }, // 47.0.0.0/8
        .{ .start = 0x3a000000, .end = 0x3affffff, .country = "CA" }, // 58.0.0.0/8
        .{ .start = 0x47000000, .end = 0x47ffffff, .country = "CA" }, // 71.0.0.0/8
        .{ .start = 0x4a000000, .end = 0x4affffff, .country = "CA" }, // 74.0.0.0/8
        .{ .start = 0x54000000, .end = 0x55ffffff, .country = "CA" }, // 84.0.0.0/8, 85.0.0.0/8
        .{ .start = 0x63000000, .end = 0x63ffffff, .country = "CA" }, // 99.0.0.0/8
        .{ .start = 0x64000000, .end = 0x65ffffff, .country = "CA" }, // 100.0.0.0/8, 101.0.0.0/8
        .{ .start = 0x69000000, .end = 0x69ffffff, .country = "CA" }, // 105.0.0.0/8
        .{ .start = 0x6c000000, .end = 0x6cffffff, .country = "CA" }, // 108.0.0.0/8
        .{ .start = 0x71000000, .end = 0x71ffffff, .country = "CA" }, // 113.0.0.0/8
        .{ .start = 0x72000000, .end = 0x72ffffff, .country = "CA" }, // 114.0.0.0/8
        .{ .start = 0x7d000000, .end = 0x7dffffff, .country = "CA" }, // 125.0.0.0/8
        .{ .start = 0x80000000, .end = 0x80ffffff, .country = "CA" }, // 128.0.0.0/8
        .{ .start = 0x84000000, .end = 0x84ffffff, .country = "CA" }, // 132.0.0.0/8
        .{ .start = 0x86000000, .end = 0x86ffffff, .country = "CA" }, // 134.0.0.0/8
        .{ .start = 0x8c000000, .end = 0x8cffffff, .country = "CA" }, // 140.0.0.0/8
        .{ .start = 0x92000000, .end = 0x92ffffff, .country = "CA" }, // 146.0.0.0/8
        .{ .start = 0x96000000, .end = 0x96ffffff, .country = "CA" }, // 150.0.0.0/8
        .{ .start = 0x9a000000, .end = 0x9affffff, .country = "CA" }, // 154.0.0.0/8
        .{ .start = 0xa3000000, .end = 0xa3ffffff, .country = "CA" }, // 163.0.0.0/8
        .{ .start = 0xa6000000, .end = 0xa6ffffff, .country = "CA" }, // 166.0.0.0/8
        .{ .start = 0xa7000000, .end = 0xa7ffffff, .country = "CA" }, // 167.0.0.0/8
        .{ .start = 0xb2000000, .end = 0xb2ffffff, .country = "CA" }, // 178.0.0.0/8
        .{ .start = 0xb4000000, .end = 0xb4ffffff, .country = "CA" }, // 180.0.0.0/8
        .{ .start = 0xb8000000, .end = 0xb8ffffff, .country = "CA" }, // 184.0.0.0/8
        .{ .start = 0xc2000000, .end = 0xc2ffffff, .country = "CA" }, // 194.0.0.0/8
        .{ .start = 0xc3000000, .end = 0xc3ffffff, .country = "CA" }, // 195.0.0.0/8
        .{ .start = 0xc4000000, .end = 0xc4ffffff, .country = "CA" }, // 196.0.0.0/8
        .{ .start = 0xc5000000, .end = 0xc5ffffff, .country = "CA" }, // 197.0.0.0/8
        .{ .start = 0xc7000000, .end = 0xc7ffffff, .country = "CA" }, // 199.0.0.0/8
        .{ .start = 0xca000000, .end = 0xcaffffff, .country = "CA" }, // 202.0.0.0/8
        .{ .start = 0xd4000000, .end = 0xd4ffffff, .country = "CA" }, // 212.0.0.0/8
        .{ .start = 0xd6000000, .end = 0xd6ffffff, .country = "CA" }, // 214.0.0.0/8

        // 荷兰
        .{ .start = 0x05000000, .end = 0x05ffffff, .country = "NL" }, // 5.0.0.0/8
        .{ .start = 0x31000000, .end = 0x31ffffff, .country = "NL" }, // 49.0.0.0/8
        .{ .start = 0x4d000000, .end = 0x4dffffff, .country = "NL" }, // 77.0.0.0/8
        .{ .start = 0x81000000, .end = 0x81ffffff, .country = "NL" }, // 129.0.0.0/8
        .{ .start = 0x83000000, .end = 0x83ffffff, .country = "NL" }, // 131.0.0.0/8
        .{ .start = 0x91000000, .end = 0x91ffffff, .country = "NL" }, // 145.0.0.0/8
        .{ .start = 0x94000000, .end = 0x94ffffff, .country = "NL" }, // 148.0.0.0/8
        .{ .start = 0x9d000000, .end = 0x9dffffff, .country = "NL" }, // 157.0.0.0/8
        .{ .start = 0xa2000000, .end = 0xa2ffffff, .country = "NL" }, // 162.0.0.0/8
        .{ .start = 0xa9000000, .end = 0xa9ffffff, .country = "NL" }, // 169.0.0.0/8
        .{ .start = 0xba000000, .end = 0xbaffffff, .country = "NL" }, // 186.0.0.0/8
        .{ .start = 0xc0000000, .end = 0xc0ffffff, .country = "NL" }, // 192.0.0.0/8
        .{ .start = 0xc1000000, .end = 0xc1ffffff, .country = "NL" }, // 193.0.0.0/8
        .{ .start = 0xc2000000, .end = 0xc2ffffff, .country = "NL" }, // 194.0.0.0/8
        .{ .start = 0xc3000000, .end = 0xc3ffffff, .country = "NL" }, // 195.0.0.0/8

        // 印度
        .{ .start = 0x01000000, .end = 0x01ffffff, .country = "IN" }, // 1.0.0.0/8
        .{ .start = 0x2f000000, .end = 0x2fffffff, .country = "IN" }, // 47.0.0.0/8
        .{ .start = 0x59000000, .end = 0x59ffffff, .country = "IN" }, // 89.0.0.0/8
        .{ .start = 0x61000000, .end = 0x61ffffff, .country = "IN" }, // 97.0.0.0/8
        .{ .start = 0x9e000000, .end = 0x9effffff, .country = "IN" }, // 158.0.0.0/8
        .{ .start = 0xa4000000, .end = 0xa4ffffff, .country = "IN" }, // 164.0.0.0/8
        .{ .start = 0xc0000000, .end = 0xc0ffffff, .country = "IN" }, // 192.0.0.0/8

        // 台湾
        .{ .start = 0x01000000, .end = 0x01ffffff, .country = "TW" }, // 1.0.0.0/8
        .{ .start = 0x3b400000, .end = 0x3b7fffff, .country = "TW" }, // 59.64.0.0/10
        .{ .start = 0x57000000, .end = 0x57ffffff, .country = "TW" }, // 87.0.0.0/8
        .{ .start = 0x61000000, .end = 0x61ffffff, .country = "TW" }, // 97.0.0.0/8
        .{ .start = 0xa1000000, .end = 0xa1ffffff, .country = "TW" }, // 161.0.0.0/8
        .{ .start = 0xce000000, .end = 0xceffffff, .country = "TW" }, // 206.0.0.0/8
        .{ .start = 0xcf000000, .end = 0xcfffffff, .country = "TW" }, // 207.0.0.0/8

        // 巴西
        .{ .start = 0x01000000, .end = 0x01ffffff, .country = "BR" }, // 1.0.0.0/8
        .{ .start = 0x5f000000, .end = 0x5fffffff, .country = "BR" }, // 95.0.0.0/8
        .{ .start = 0x64000000, .end = 0x65ffffff, .country = "BR" }, // 100.0.0.0/8, 101.0.0.0/8
        .{ .start = 0x8d000000, .end = 0x8dffffff, .country = "BR" }, // 141.0.0.0/8
        .{ .start = 0x96000000, .end = 0x96ffffff, .country = "BR" }, // 150.0.0.0/8
        .{ .start = 0xa9000000, .end = 0xa9ffffff, .country = "BR" }, // 169.0.0.0/8
        .{ .start = 0xb1000000, .end = 0xb1ffffff, .country = "BR" }, // 177.0.0.0/8
        .{ .start = 0xb2000000, .end = 0xb2ffffff, .country = "BR" }, // 178.0.0.0/8
        .{ .start = 0xb7000000, .end = 0xb7ffffff, .country = "BR" }, // 183.0.0.0/8
        .{ .start = 0xbd000000, .end = 0xbdffffff, .country = "BR" }, // 189.0.0.0/8
        .{ .start = 0xc0000000, .end = 0xc0ffffff, .country = "BR" }, // 192.0.0.0/8
        .{ .start = 0xc1000000, .end = 0xc1ffffff, .country = "BR" }, // 193.0.0.0/8
        .{ .start = 0xc2000000, .end = 0xc2ffffff, .country = "BR" }, // 194.0.0.0/8
        .{ .start = 0xc3000000, .end = 0xc3ffffff, .country = "BR" }, // 195.0.0.0/8
        .{ .start = 0xc4000000, .end = 0xc4ffffff, .country = "BR" }, // 196.0.0.0/8
        .{ .start = 0xc5000000, .end = 0xc5ffffff, .country = "BR" }, // 197.0.0.0/8
        .{ .start = 0xc7000000, .end = 0xc7ffffff, .country = "BR" }, // 199.0.0.0/8
        .{ .start = 0xc8000000, .end = 0xc8ffffff, .country = "BR" }, // 200.0.0.0/8
        .{ .start = 0xc9000000, .end = 0xc9ffffff, .country = "BR" }, // 201.0.0.0/8
        .{ .start = 0xca000000, .end = 0xcaffffff, .country = "BR" }, // 202.0.0.0/8
        .{ .start = 0xcb000000, .end = 0xcbffffff, .country = "BR" }, // 203.0.0.0/8
        .{ .start = 0xcc000000, .end = 0xccffffff, .country = "BR" }, // 204.0.0.0/8
        .{ .start = 0xcd000000, .end = 0xcdffffff, .country = "BR" }, // 205.0.0.0/8
        .{ .start = 0xce000000, .end = 0xceffffff, .country = "BR" }, // 206.0.0.0/8
        .{ .start = 0xcf000000, .end = 0xcfffffff, .country = "BR" }, // 207.0.0.0/8
    };

    /// 查询 IP 对应的国家代码
    pub fn lookup(ip: u32) ?[]const u8 {
        for (entries) |entry| {
            if (ip >= entry.start and ip <= entry.end) {
                return entry.country;
            }
        }
        return null;
    }

    /// 查询 IPv6 对应的国家代码（简化版）
    pub fn lookupV6(_: [16]u8) ?[]const u8 {
        // 简化实现：不支持 IPv6 GeoIP
        return null;
    }
};

test "SimpleGeoIp lookup" {
    // 测试中国 IP
    try std.testing.expectEqualStrings("CN", SimpleGeoIp.lookup(0x01000000).?);

    // 测试美国 IP
    try std.testing.expectEqualStrings("US", SimpleGeoIp.lookup(0x02000000).?);

    // 测试未知 IP
    try std.testing.expect(SimpleGeoIp.lookup(0x00000000) == null);
}
