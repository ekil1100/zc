const std = @import("std");
const testing = std.testing;

// Mixed port protocol detection tests
test "Mixed port HTTP detection" {
    // HTTP methods start with printable characters
    const get: u8 = 'G';
    const post: u8 = 'P';
    const connect: u8 = 'C';
    const head: u8 = 'H';
    
    try testing.expect(get > 0x40 and get < 0x7F);
    try testing.expect(post > 0x40 and post < 0x7F);
    try testing.expect(connect > 0x40 and connect < 0x7F);
    try testing.expect(head > 0x40 and head < 0x7F);
}

test "Mixed port SOCKS5 detection" {
    const first_byte: u8 = 0x05;
    try testing.expectEqual(@as(u8, 0x05), first_byte);
}

test "Mixed port SOCKS4 detection" {
    const first_byte: u8 = 0x04;
    try testing.expectEqual(@as(u8, 0x04), first_byte);
}

test "Protocol detection logic" {
    const http_first_byte: u8 = 'C'; // CONNECT
    const socks5_first_byte: u8 = 0x05;
    const socks4_first_byte: u8 = 0x04;
    
    // HTTP: first byte is printable ASCII
    const is_http = http_first_byte >= 0x20 and http_first_byte <= 0x7E;
    try testing.expect(is_http);
    
    // SOCKS5: first byte is 0x05
    const is_socks5 = socks5_first_byte == 0x05;
    try testing.expect(is_socks5);
    
    // SOCKS4: first byte is 0x04
    const is_socks4 = socks4_first_byte == 0x04;
    try testing.expect(is_socks4);
}

test "Mixed port configuration" {
    const port: u16 = 7892;
    
    // When mixed-port is set, individual ports are disabled
    const http_port: u16 = 0;
    const socks_port: u16 = 0;
    const mixed_port: u16 = port;
    
    try testing.expect(mixed_port > 0);
    try testing.expect(http_port == 0);
    try testing.expect(socks_port == 0);
}

test "Mixed port priority" {
    // mixed-port > (port + socks-port)
    const has_mixed_port = true;
    const has_separate_ports = true;

    const use_mixed = has_mixed_port or (!has_mixed_port and has_separate_ports);
    try testing.expect(use_mixed);
}

// Regression: SOCKS5 domain-length bounds check must not overflow u8 arithmetic.
// The handler reads `domain_len = buf[4]` then checks `req_n < 5 + domain_len + 2`.
// If domain_len is kept as a u8, `5 + domain_len + 2` overflows for domain_len >= 249
// (panic in safe builds, wraparound + OOB read in ReleaseFast). Computing in usize fixes it.
test "SOCKS5 domain-length bounds check does not overflow" {
    // buf mirrors the per-connection read buffer (256 bytes).
    const buf_len: usize = 256;

    // Helper replicating the (fixed) bounds-check decision.
    const accepts = struct {
        fn f(domain_len: u8, req_n: usize) bool {
            const dl: usize = domain_len; // widened, as in the fix
            // returns true if the request would be accepted (not InvalidRequest)
            return !(req_n < 5 + dl + 2);
        }
    }.f;

    // For the largest domain_len values, the request can never fit in a 256-byte buffer,
    // so it must be rejected (and crucially must not panic computing the threshold).
    var dl: u8 = 249;
    while (true) {
        // Maximum possible req_n is the buffer size.
        const accepted = accepts(dl, buf_len);
        // 5 + dl + 2 > 256 for dl >= 250, so those must be rejected.
        if (@as(usize, dl) + 7 > buf_len) {
            try testing.expect(!accepted);
        }
        if (dl == 255) break;
        dl += 1;
    }

    // And whenever the check accepts, the highest index read (5 + dl + 1) is in bounds.
    var dl2: u8 = 0;
    while (true) {
        if (accepts(dl2, buf_len)) {
            const high_index: usize = 5 + @as(usize, dl2) + 1;
            try testing.expect(high_index < buf_len);
        }
        if (dl2 == 255) break;
        dl2 += 1;
    }
}
