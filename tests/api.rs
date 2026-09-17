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
    let server = Server::bind(Arc::new(config), None).await.unwrap().unwrap();
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
    let server = Server::bind(Arc::new(config), None).await.unwrap().unwrap();
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
