use std::sync::Arc;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};
use zc::{api::Server, config::Config};

async fn server() -> (
    std::net::SocketAddr,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    let reservation = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = reservation.local_addr().unwrap();
    drop(reservation);
    let config = Config::parse(&format!("mixed-port: 17891\nexternal-controller: {address}\nsecret: test-secret\nproxy-groups:\n  - name: pick\n    type: select\n    proxies: [DIRECT, REJECT]\nrules: [MATCH,pick]\n").replace("rules: [MATCH,pick]", "rules: ['MATCH,pick']")).unwrap();
    let server = Server::bind(
        Arc::new(config),
        None,
        zc::connection::ConnectionRegistry::new().unwrap(),
    )
    .await
    .unwrap()
    .unwrap();
    (address, tokio::spawn(server.run(std::future::pending())))
}
async fn request(address: std::net::SocketAddr, bytes: &[u8]) -> String {
    let mut stream = TcpStream::connect(address).await.unwrap();
    stream.write_all(bytes).await.unwrap();
    let mut response = Vec::new();
    if let Err(error) = stream.read_to_end(&mut response).await {
        assert!(
            error.kind() == std::io::ErrorKind::ConnectionReset && !response.is_empty(),
            "{error}"
        );
    }
    String::from_utf8(response).unwrap()
}

#[tokio::test]
async fn wildcard_controller_authenticates_every_route_before_disclosing_state() {
    let reservation = TcpListener::bind("0.0.0.0:0").await.unwrap();
    let port = reservation.local_addr().unwrap().port();
    drop(reservation);
    let config = Config::parse(&format!(
        "external-controller: 0.0.0.0:{port}\nsecret: test-secret\nproxy-groups: [{{name: pick, type: select, proxies: [DIRECT, REJECT]}}]\nrules: ['MATCH,pick']"
    )).unwrap();
    let server = Server::bind(
        Arc::new(config),
        None,
        zc::connection::ConnectionRegistry::new().unwrap(),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(server.local_addr().unwrap().ip().to_string(), "0.0.0.0");
    let address = ([127, 0, 0, 1], port).into();
    let task = tokio::spawn(server.run(std::future::pending()));
    for (method, path, body) in [
        ("GET", "/", ""),
        ("GET", "/version", ""),
        ("GET", "/status", ""),
        ("GET", "/proxies", ""),
        ("GET", "/rules", ""),
        ("GET", "/connections", ""),
        ("GET", "/unknown", ""),
        ("POST", "/status", ""),
        ("PUT", "/proxies/pick", r#"{"name":"REJECT"}"#),
        ("DELETE", "/connections/invalid", ""),
    ] {
        for auth in ["", "Authorization: Bearer wrong\r\n"] {
            let wire = format!(
                "{method} {path} HTTP/1.1\r\n{auth}Content-Length: {}\r\n\r\n{body}",
                body.len()
            );
            let response = request(address, wire.as_bytes()).await;
            assert!(
                response.starts_with("HTTP/1.1 401"),
                "{method} {path}: {response}"
            );
            assert!(!response.to_lowercase().contains("x-zc-instance-nonce:"));
            assert!(!response.contains("DIRECT") && !response.contains("test-secret"));
        }
    }
    for path in [
        "/",
        "/version",
        "/status",
        "/proxies",
        "/rules",
        "/connections",
    ] {
        let wire = format!("GET {path} HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n\r\n");
        let response = request(address, wire.as_bytes()).await;
        assert!(response.starts_with("HTTP/1.1 200"), "{path}: {response}");
    }
    let response = request(address, b"PUT /proxies/pick HTTP/1.1\r\nAuthorization: Bearer test-secret\r\nContent-Length: 17\r\n\r\n{\"name\":\"REJECT\"}").await;
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    let response = request(
        address,
        b"GET /status HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n\r\n",
    )
    .await;
    assert!(response.contains("REJECT"), "{response}");
    task.abort();
}

#[tokio::test]
async fn wildcard_controller_requires_secret_and_never_changes_an_occupied_port() {
    let reserved = TcpListener::bind("0.0.0.0:0").await.unwrap();
    let port = reserved.local_addr().unwrap().port();
    let config = Config::parse(&format!(
        "external-controller: 0.0.0.0:{port}\nrules: ['MATCH,DIRECT']"
    ))
    .unwrap();
    let result = Server::bind(
        Arc::new(config),
        None,
        zc::connection::ConnectionRegistry::new().unwrap(),
    )
    .await;
    let error = result
        .err()
        .expect("wildcard without secret must be rejected");
    assert!(
        format!("{error:#}").contains("START_CONTROLLER_SECRET_REQUIRED"),
        "{error:#}"
    );
    let config = Config::parse(&format!(
        "external-controller: 0.0.0.0:{port}\nsecret: test-secret\nrules: ['MATCH,DIRECT']"
    ))
    .unwrap();
    let result = Server::bind(
        Arc::new(config),
        None,
        zc::connection::ConnectionRegistry::new().unwrap(),
    )
    .await;
    let error = result
        .err()
        .expect("occupied wildcard port must be rejected");
    assert!(
        format!("{error:#}").contains("START_CONTROLLER_PORT_IN_USE"),
        "{error:#}"
    );
}
#[tokio::test]
async fn public_reads_and_authenticated_unmanaged_selection() {
    let (address, task) = server().await;
    let response = request(address, b"GET /status HTTP/1.1\r\nHost: localhost\r\n\r\n").await;
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert!(response.contains("DIRECT"));
    let body = r#"{"name":"REJECT"}"#;
    let unauthorized = format!(
        "PUT /proxies/pick HTTP/1.1\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    assert!(
        request(address, unauthorized.as_bytes())
            .await
            .starts_with("HTTP/1.1 401")
    );
    let authorized = unauthorized.replace(
        "Content-Length:",
        "Authorization: Bearer test-secret\r\nContent-Length:",
    );
    assert!(
        request(address, authorized.as_bytes())
            .await
            .starts_with("HTTP/1.1 200")
    );
    let response = request(address, b"GET /status HTTP/1.1\r\n\r\n").await;
    assert!(response.contains("REJECT"));
    assert!(response.contains("transient"));
    task.abort();
}

#[tokio::test]
async fn strict_framing_bounds_and_fragmented_body() {
    let (address, task) = server().await;
    for (wire, status) in [
        ("PUT /proxies/pick HTTP/1.1\r\n\r\n", 411),
        (
            "PUT /proxies/pick HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
            400,
        ),
        (
            "PUT /proxies/pick HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            501,
        ),
        (
            "PUT /proxies/pick HTTP/1.1\r\nContent-Length: 65537\r\n\r\n",
            413,
        ),
        ("GET / HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n", 400),
    ] {
        assert!(
            request(address, wire.as_bytes())
                .await
                .starts_with(&format!("HTTP/1.1 {status}"))
        );
    }
    let long = format!("GET / HTTP/1.1\r\nX-Large: {}\r\n\r\n", "a".repeat(16384));
    assert!(
        request(address, long.as_bytes())
            .await
            .starts_with("HTTP/1.1 413")
    );
    let mut stream = TcpStream::connect(address).await.unwrap();
    stream.write_all(b"PUT /proxies/pick HTTP/1.1\r\nAuthorization: Bearer test-secret\r\nContent-Length: 17\r\n\r\n").await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    stream.write_all(br#"{"name":"REJECT"}"#).await.unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).await.unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    task.abort();
}

#[tokio::test]
async fn request_deadline_and_connection_admission_are_bounded() {
    let (address, task) = server().await;
    let mut sockets = Vec::new();
    for _ in 0..16 {
        let mut socket = TcpStream::connect(address).await.unwrap();
        socket
            .write_all(b"GET / HTTP/1.1\r\nX-Pending: ")
            .await
            .unwrap();
        sockets.push(socket);
    }
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let mut excess = TcpStream::connect(address).await.unwrap();
    let mut byte = [0];
    let result = tokio::time::timeout(std::time::Duration::from_secs(1), excess.read(&mut byte))
        .await
        .unwrap();
    assert!(matches!(result, Ok(0) | Err(_)));
    let mut response = String::new();
    sockets[0].read_to_string(&mut response).await.unwrap();
    assert!(response.starts_with("HTTP/1.1 408"), "{response}");
    task.abort();
}

#[tokio::test]
async fn oversized_response_is_a_complete_500() {
    let reserve = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = reserve.local_addr().unwrap();
    drop(reserve);
    let mut source = format!("mixed-port: 17895\nexternal-controller: {address}\nproxies:\n");
    for index in 0..2100 {
        source.push_str(&format!("  - name: {index}{}\n    type: ss\n    server: localhost\n    port: 443\n    password: test\n    cipher: aes-128-gcm\n", "x".repeat(2048)));
    }
    source.push_str("rules: ['MATCH,DIRECT']\n");
    let config = Config::parse(&source).unwrap();
    let server = Server::bind(
        Arc::new(config),
        None,
        zc::connection::ConnectionRegistry::new().unwrap(),
    )
    .await
    .unwrap()
    .unwrap();
    let task = tokio::spawn(server.run(std::future::pending()));
    let response = request(address, b"GET /proxies HTTP/1.1\r\n\r\n").await;
    assert!(response.starts_with("HTTP/1.1 500 Response Too Large"));
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(response.split_once("\r\n\r\n").unwrap().1)
            .unwrap()["error"],
        "Response Too Large"
    );
    task.abort();
}

#[tokio::test]
async fn ambiguous_header_end_never_mutates_selection() {
    let (address, task) = server().await;
    for wire in [
        "PUT /proxies/pick HTTP/1.1\r\nAuthorization: Bearer test-secret\r\nContent-Length: 17\n\nContent-Length: 0\r\n\r\n{\"name\":\"REJECT\"}",
        "GET /status HTTP/1.1\nHost: localhost\r\n\r\n",
        "GET /status HTTP/1.1\r\nX: value\n\nignored\r\n\r\n",
        "GET /status HTTP/1.1\r\nX: value\rBroken: yes\r\n\r\n",
    ] {
        let response = request(address, wire.as_bytes()).await;
        assert!(response.starts_with("HTTP/1.1 400"), "{response}");
        let state = request(address, b"GET /status HTTP/1.1\r\n\r\n").await;
        assert!(
            state.contains("DIRECT") && !state.contains("REJECT"),
            "{state}"
        );
    }
    task.abort();
}

#[tokio::test]
async fn bearer_scheme_is_ascii_case_insensitive_but_secret_is_exact() {
    let (address, task) = server().await;
    for (auth, status) in [
        ("bearer test-secret", 200),
        ("BEARER test-secret", 200),
        ("bEaReR test-secret", 200),
        ("Bearer TEST-secret", 401),
        ("Bearer  test-secret", 401),
    ] {
        let wire = format!(
            "PUT /proxies/pick HTTP/1.1\r\nAuthorization: {auth}\r\nContent-Length: 17\r\n\r\n{{\"name\":\"REJECT\"}}"
        );
        let response = request(address, wire.as_bytes()).await;
        assert!(
            response.starts_with(&format!("HTTP/1.1 {status}")),
            "{response}"
        );
    }
    task.abort();
}

#[tokio::test]
async fn connections_require_bearer_and_bind_requests_to_the_instance() {
    let (address, task) = server().await;
    for path in [
        "/connections",
        "/connections/00000000000000000000000000000000-1",
    ] {
        let method = if path == "/connections" {
            "GET"
        } else {
            "DELETE"
        };
        for authorization in ["", "Authorization: Bearer wrong\r\n"] {
            let wire = format!("{method} {path} HTTP/1.1\r\n{authorization}\r\n");
            let response = request(address, wire.as_bytes()).await;
            assert!(response.starts_with("HTTP/1.1 401"), "{response}");
            assert!(
                !response.to_lowercase().contains("x-zc-instance-nonce:"),
                "{response}"
            );
        }
    }
    let response = request(
        address,
        b"GET /connections HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n\r\n",
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert!(response.to_lowercase().contains("x-zc-instance-nonce:"));
    let body: serde_json::Value =
        serde_json::from_str(response.split_once("\r\n\r\n").unwrap().1).unwrap();
    assert_eq!(body["connections"], serde_json::json!([]));
    let response = request(address, b"GET /connections HTTP/1.1\r\nAuthorization: Bearer test-secret\r\nX-Zc-Instance-Nonce: wrong\r\n\r\n").await;
    assert!(response.starts_with("HTTP/1.1 409"), "{response}");
    let response = request(address, b"DELETE /connections/00000000000000000000000000000000-1 HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n\r\n").await;
    assert!(response.starts_with("HTTP/1.1 409"), "{response}");
    task.abort();
}

#[tokio::test]
async fn connections_without_secret_are_forbidden_but_legacy_reads_and_put_stay_open() {
    let reserve = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = reserve.local_addr().unwrap();
    drop(reserve);
    let config=Config::parse(&format!("external-controller: {address}\nproxy-groups: [{{name: pick, type: select, proxies: [DIRECT,REJECT]}}]\nrules: ['MATCH,pick']")).unwrap();
    let server = Server::bind(
        Arc::new(config),
        None,
        zc::connection::ConnectionRegistry::new().unwrap(),
    )
    .await
    .unwrap()
    .unwrap();
    let task = tokio::spawn(server.run(std::future::pending()));
    for method in ["GET", "DELETE"] {
        for auth in ["", "Authorization: Bearer anything\r\n"] {
            let path = if method == "GET" {
                "/connections"
            } else {
                "/connections/00000000000000000000000000000000-1"
            };
            let response = request(
                address,
                format!("{method} {path} HTTP/1.1\r\n{auth}\r\n").as_bytes(),
            )
            .await;
            assert!(response.starts_with("HTTP/1.1 403"), "{response}");
            assert!(
                !response.to_lowercase().contains("x-zc-instance-nonce:"),
                "{response}"
            );
        }
    }
    assert!(
        request(address, b"GET /status HTTP/1.1\r\n\r\n")
            .await
            .starts_with("HTTP/1.1 200")
    );
    assert!(
        request(
            address,
            b"PUT /proxies/pick HTTP/1.1\r\nContent-Length: 17\r\n\r\n{\"name\":\"REJECT\"}"
        )
        .await
        .starts_with("HTTP/1.1 200")
    );
    task.abort();
}

#[tokio::test]
async fn instance_header_is_private_to_authenticated_connection_requests() {
    let (address, task) = server().await;
    for (wire, status, visible) in [
        ("GET /version HTTP/1.1\r\n\r\n", 200, false),
        (
            "GET /status HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n\r\n",
            200,
            false,
        ),
        (
            "GET /other HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n\r\n",
            404,
            false,
        ),
        (
            "PUT /proxies/pick HTTP/1.1\r\nAuthorization: Bearer test-secret\r\nContent-Length: 17\r\n\r\n{\"name\":\"REJECT\"}",
            200,
            false,
        ),
        (
            "DELETE /connections/bad HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n\r\n",
            400,
            true,
        ),
        (
            "GET /connections/missing HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n\r\n",
            404,
            true,
        ),
        (
            "GET /connections HTTP/1.1\r\nAuthorization: Bearer test-secret\r\nX-Zc-Instance-Nonce: wrong\r\n\r\n",
            409,
            true,
        ),
        (
            "GET /connections HTTP/1.1\r\nAuthorization: Bearer test-secret\r\nX-Zc-Instance-Nonce: a\r\nX-Zc-Instance-Nonce: a\r\n\r\n",
            400,
            false,
        ),
        (
            "GET /connections HTTP/1.1\r\nAuthorization: Bearer test-secret\r\nContent-Length: 1\r\n\r\n",
            408,
            false,
        ),
    ] {
        let response = request(address, wire.as_bytes()).await;
        assert!(
            response.starts_with(&format!("HTTP/1.1 {status}")),
            "{response}"
        );
        assert_eq!(
            response.to_lowercase().contains("x-zc-instance-nonce:"),
            visible,
            "{response}"
        );
    }
    task.abort();
}

#[tokio::test]
async fn authenticated_connection_response_limit_retains_instance_header() {
    let reserve = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = reserve.local_addr().unwrap();
    drop(reserve);
    let name = "n".repeat(2 * 1024 * 1024);
    let config = Config::parse(&format!(
        "external-controller: {address}\nsecret: test-secret\nproxies: [{{name: {name}, type: direct}}]\nrules: ['MATCH,{name}']"
    )).unwrap();
    let runtime = zc::runtime::Runtime::bind(config, 0).await.unwrap();
    let mixed = runtime.local_addr().unwrap();
    let server = Server::bind(runtime.config(), None, runtime.connections())
        .await
        .unwrap()
        .unwrap();
    let runtime_task = tokio::spawn(runtime.run(std::future::pending()));
    let api_task = tokio::spawn(server.run(std::future::pending()));
    let origin = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = origin.local_addr().unwrap();
    let mut tunnel = TcpStream::connect(mixed).await.unwrap();
    tunnel
        .write_all(format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let (_peer, _) = origin.accept().await.unwrap();
    let mut established = Vec::new();
    while !established.ends_with(b"\r\n\r\n") {
        established.push(tunnel.read_u8().await.unwrap());
    }
    assert!(established.starts_with(b"HTTP/1.1 200"));
    let response = request(
        address,
        b"GET /connections HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n\r\n",
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 500"), "{response}");
    assert!(response.to_lowercase().contains("x-zc-instance-nonce:"));
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(response.split_once("\r\n\r\n").unwrap().1)
            .unwrap()["error"],
        "Response Too Large"
    );
    api_task.abort();
    runtime_task.abort();
}
