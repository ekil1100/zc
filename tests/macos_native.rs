#![cfg(target_os = "macos")]
#![forbid(unsafe_code)]

// Run only through scripts/ci/test-macos-native.py on a disposable CI runner.
// A fake HOME does not isolate macOS trust settings or SystemConfiguration.
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Barrier},
    time::Duration,
};

use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};
use zc::{
    config::{Config, Proxy, ProxyKind},
    dns::Dns,
    outbound::Connector,
    target::Target,
};

const CASES: &[&str] = &[
    "baseline-untrusted",
    "security-first",
    "dns-first",
    "wrong-sni",
    "user-deny",
    "admin-trust",
    "user-deny-admin-trust",
    "concurrent-independent",
    "concurrent-shared",
];

struct Fixture {
    directory: PathBuf,
    case: String,
    nonce: String,
}

impl Fixture {
    fn require() -> Self {
        use std::os::unix::fs::PermissionsExt;

        // These checks precede runtime construction, native trust and DNS reads.
        for (key, expected) in [
            ("GITHUB_ACTIONS", "true"),
            ("RUNNER_OS", "macOS"),
            ("ZC_MACOS_NATIVE_EPHEMERAL", "confirmed"),
        ] {
            assert!(
                std::env::var(key).as_deref() == Ok(expected),
                "native tests require the explicit disposable CI fixture runner"
            );
        }
        assert!(std::env::var_os("SSL_CERT_FILE").is_none());
        assert!(std::env::var_os("SSL_CERT_DIR").is_none());
        let directory = PathBuf::from(
            std::env::var_os("ZC_MACOS_NATIVE_FIXTURE")
                .expect("explicit native fixture is required"),
        );
        assert!(directory.is_absolute());
        let metadata = std::fs::symlink_metadata(&directory).unwrap();
        assert!(
            metadata.is_dir() && metadata.permissions().mode() & 0o077 == 0,
            "native fixture directory must be private"
        );
        for name in ["fixture.json", "cert.pem", "key.pem"] {
            let metadata = std::fs::symlink_metadata(directory.join(name)).unwrap();
            assert!(
                metadata.is_file() && metadata.permissions().mode() & 0o077 == 0,
                "native fixture files must be private regular files"
            );
        }
        let manifest: serde_json::Value =
            serde_json::from_slice(&std::fs::read(directory.join("fixture.json")).unwrap())
                .unwrap();
        assert_eq!(manifest["version"], 1);
        let case = manifest["case"].as_str().unwrap().to_owned();
        assert!(CASES.contains(&case.as_str()), "unknown native scenario");
        let nonce = manifest["nonce"].as_str().unwrap().to_owned();
        assert!(nonce.len() == 64 && nonce.bytes().all(|b| b.is_ascii_hexdigit()));
        assert!(
            std::env::var("ZC_MACOS_NATIVE_NONCE").as_deref() == Ok(&nonce),
            "fixture must belong to this runner invocation"
        );
        Self {
            directory,
            case,
            nonce,
        }
    }
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
}

async fn resolve_localhost(dns: &Dns) {
    // Dns::system is lazy; this non-literal lookup reads SC before hosts.
    let addresses = dns
        .resolve(&Target::new("localhost", 80).unwrap())
        .await
        .unwrap();
    assert!(addresses.contains(&"127.0.0.1".parse().unwrap()));
    assert!(addresses.contains(&"::1".parse().unwrap()));
    assert!(addresses.iter().all(std::net::IpAddr::is_loopback));
}

fn acceptor(directory: &Path) -> tokio_rustls::TlsAcceptor {
    let cert = CertificateDer::from_pem_slice(&std::fs::read(directory.join("cert.pem")).unwrap())
        .unwrap();
    let key =
        PrivateKeyDer::from_pem_slice(&std::fs::read(directory.join("key.pem")).unwrap()).unwrap();
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![cert], key)
    .unwrap();
    tokio_rustls::TlsAcceptor::from(Arc::new(config))
}

fn selected_proxy(config: &Config) -> &Proxy {
    let proxy = config
        .proxies()
        .iter()
        .find(|proxy| proxy.name == "native")
        .expect("native Trojan fixture is missing");
    assert!(
        matches!(
            proxy.kind,
            ProxyKind::Trojan {
                skip_cert_verify: false,
                ..
            }
        ),
        "fixture must exercise verified Trojan, not a built-in proxy"
    );
    proxy
}

#[test]
fn fixture_selects_named_verified_trojan() {
    let config = Config::parse(
        "proxies: [{name: native, type: trojan, server: 127.0.0.1, port: 18443, password: password, sni: front.example}]\nrules: ['MATCH,native']",
    ).unwrap();
    let proxy = selected_proxy(&config);
    assert_eq!(proxy.name, "native");
    assert!(matches!(
        proxy.kind,
        ProxyKind::Trojan {
            skip_cert_verify: false,
            ..
        }
    ));
}

async fn exercise(fixture: &Fixture, dns: &Dns, dns_first: bool) {
    if dns_first {
        resolve_localhost(dns).await;
    }
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let destination = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let destination_port = destination.local_addr().unwrap().port();
    let sni = if fixture.case == "wrong-sni" {
        "wrong.example"
    } else {
        "front.example"
    };
    let reject = matches!(
        fixture.case.as_str(),
        "baseline-untrusted" | "wrong-sni" | "user-deny" | "user-deny-admin-trust"
    );
    let config = Config::parse(&format!(
        "proxies: [{{name: native, type: trojan, server: 127.0.0.1, port: {}, password: password, sni: {sni}}}]\nrules: ['MATCH,native']",
        address.port(),
    )).unwrap();
    // This must be the first Security consumer, not a pre-warmed test TLS client.
    let connector = Connector::new(&config).expect("native trust initialization failed");
    let acceptor = acceptor(&fixture.directory);
    let peer = tokio::spawn(async move {
        let (socket, remote) = listener.accept().await.unwrap();
        assert!(remote.ip().is_loopback());
        assert_eq!(socket.local_addr().unwrap(), address);
        let handshake = acceptor.accept(socket).await;
        if reject {
            assert!(
                handshake.is_err(),
                "TLS must reject before any Trojan authentication"
            );
            return;
        }
        let mut stream = handshake.unwrap();
        assert_eq!(stream.get_ref().1.server_name(), Some("front.example"));
        // Independently fixed SHA224(password), CONNECT and loopback IPv4 wire address.
        let mut expected =
            b"d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01\r\n\x01\x01\x7f\x00\x00\x01"
                .to_vec();
        expected.extend_from_slice(&destination_port.to_be_bytes());
        expected.extend_from_slice(b"\r\n");
        let mut request = vec![0; expected.len()];
        stream.read_exact(&mut request).await.unwrap();
        assert!(request == expected, "Trojan wire request mismatch");
        stream.write_all(b"native peer").await.unwrap();
        stream.flush().await.unwrap();
        let mut payload = Vec::new();
        stream.read_to_end(&mut payload).await.unwrap();
        assert!(
            payload == b"local payload",
            "unexpected application payload"
        );
        stream.shutdown().await.unwrap();
    });
    let target = Target::new("127.0.0.1", destination_port).unwrap();
    let result = connector.connect(selected_proxy(&config), &target).await;
    if reject {
        let error = match result {
            Ok(_) => panic!("native certificate policy unexpectedly accepted the peer"),
            Err(error) => format!("{error:#}"),
        };
        let reason = if fixture.case == "wrong-sni" {
            "NotValidForName"
        } else {
            "UnknownIssuer"
        };
        assert!(
            error.contains(reason),
            "expected certificate rejection, not timeout or dial failure"
        );
        assert!(
            !error.contains("password"),
            "diagnostic leaked authentication data"
        );
    } else {
        let mut stream = result.expect("trusted native TLS must succeed");
        let mut response = [0; 11];
        stream.read_exact(&mut response).await.unwrap();
        assert_eq!(&response, b"native peer");
        stream.write_all(b"local payload").await.unwrap();
        stream.shutdown().await.unwrap();
        let mut tail = Vec::new();
        stream.read_to_end(&mut tail).await.unwrap();
        assert!(tail.is_empty());
    }
    peer.await.unwrap();
    assert!(
        tokio::time::timeout(Duration::from_millis(100), destination.accept())
            .await
            .is_err(),
        "Trojan must not fall back to a direct connection"
    );
    if !dns_first {
        resolve_localhost(dns).await;
    }
}

#[test]
#[ignore = "requires disposable macOS CI trust fixture and parent watchdog"]
fn native_first_use() {
    let fixture = Fixture::require();
    println!("ZC_MACOS_NATIVE_BEGIN {} {}", fixture.case, fixture.nonce);
    match fixture.case.as_str() {
        "concurrent-independent" | "concurrent-shared" => {
            const THREADS: usize = 8;
            let barrier = Arc::new(Barrier::new(THREADS));
            // Construction is deliberately lazy; the barrier gates its first resolve.
            let shared = (fixture.case == "concurrent-shared").then(|| Arc::new(Dns::system()));
            std::thread::scope(|scope| {
                let handles: Vec<_> = (0..THREADS)
                    .map(|index| {
                        let barrier = barrier.clone();
                        let shared = shared.clone();
                        let fixture = &fixture;
                        scope.spawn(move || {
                            let runtime = runtime();
                            barrier.wait();
                            let dns = shared.unwrap_or_else(|| Arc::new(Dns::system()));
                            runtime.block_on(exercise(fixture, &dns, index % 2 == 1));
                        })
                    })
                    .collect();
                for handle in handles {
                    handle.join().expect("native first-use worker failed");
                }
            });
        }
        _ => runtime().block_on(exercise(
            &fixture,
            &Dns::system(),
            fixture.case == "dns-first",
        )),
    }
    // Emitted only after all assertions and every OS thread have completed.
    println!("ZC_MACOS_NATIVE_PASS {} {}", fixture.case, fixture.nonce);
}
