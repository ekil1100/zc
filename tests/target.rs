use zc::target::Target;

#[test]
fn targets_preserve_valid_dns_and_ip_addresses() {
    for host in [
        "example.com",
        "localhost",
        "127.0.0.1",
        "::1",
        "2001:db8::1",
    ] {
        let target = Target::new(host, 443).unwrap();
        assert_eq!(target.host(), host);
        assert_eq!(target.port(), 443);
    }
}

#[test]
fn socks_wire_names_preserve_the_full_one_byte_length_range() {
    let host = "a".repeat(255);
    assert!(Target::new(&host, 443).is_err());
    let target = Target::from_socks(&host, 443).unwrap();
    assert_eq!(target.host(), host);
    assert_eq!(target.port(), 443);
    assert!(Target::from_socks("a".repeat(256), 443).is_err());
    assert!(Target::from_socks("", 443).is_err());
    assert!(Target::from_socks("example.com", 0).is_err());
}

#[test]
fn targets_reject_ambiguous_or_unsafe_wire_addresses() {
    for host in [
        "",
        "example.com\r\nInjected: yes",
        "a b",
        "user@host",
        "host/path",
        "[::1]",
        "bad:host",
        "host\0",
        "bad\\host",
        "é.com",
    ] {
        assert!(Target::new(host, 443).is_err(), "accepted {host:?}");
    }
    assert!(Target::new("example.com", 0).is_err());
    assert!(Target::new("x".repeat(256), 443).is_err());
}
