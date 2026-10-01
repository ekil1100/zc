use serde_json::{Value, json};
use std::{net::SocketAddr, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    time::timeout,
};
use zc::{
    api::Server,
    config::Config,
    connection::{INSTANCE_HEADER, PROBE_HEADER},
    runtime::Runtime,
};

struct Fixture {
    mixed: SocketAddr,
    api: SocketAddr,
    nonce: String,
    config: std::sync::Arc<Config>,
    client: reqwest::Client,
    stops: Vec<oneshot::Sender<()>>,
    tasks: Vec<tokio::task::JoinHandle<anyhow::Result<()>>>,
}
impl Fixture {
    async fn new(rules: &str) -> Self {
        let reserved = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let api = reserved.local_addr().unwrap();
        drop(reserved);
        let runtime = Runtime::bind(
            Config::parse(&format!(
                "external-controller: {api}\nsecret: test-secret\n{rules}"
            ))
            .unwrap(),
            0,
        )
        .await
        .unwrap();
        let mixed = runtime.local_addr().unwrap();
        assert_ne!(mixed.port(), 7899);
        let config = runtime.config();
        let server = Server::bind(config.clone(), None, runtime.connections())
            .await
            .unwrap()
            .unwrap();
        let (a, ar) = oneshot::channel();
        let (b, br) = oneshot::channel();
        let mut f = Self {
            mixed,
            api,
            config,
            nonce: String::new(),
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(3))
                .build()
                .unwrap(),
            stops: vec![a, b],
            tasks: vec![
                tokio::spawn(runtime.run(async {
                    let _ = ar.await;
                })),
                tokio::spawn(server.run(async {
                    let _ = br.await;
                })),
            ],
        };
        f.nonce = f
            .client
            .get(format!("http://{api}/connections"))
            .bearer_auth("test-secret")
            .send()
            .await
            .unwrap()
            .headers()[INSTANCE_HEADER]
            .to_str()
            .unwrap()
            .to_owned();
        f
    }
    async fn reserve(&self, target: SocketAddr) -> String {
        let response = self
            .client
            .put(format!("http://{}/connections/probes", self.api))
            .bearer_auth("test-secret")
            .header(INSTANCE_HEADER, &self.nonce)
            .json(&json!({"host":target.ip().to_string(),"port":target.port()}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        response.json::<Value>().await.unwrap()["token"]
            .as_str()
            .unwrap()
            .to_owned()
    }
    async fn evidence(&self, token: &str) -> Value {
        let response = self
            .client
            .get(format!("http://{}/connections/probes/{token}", self.api))
            .bearer_auth("test-secret")
            .header(INSTANCE_HEADER, &self.nonce)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        response.json().await.unwrap()
    }
    async fn wait_closed(&self) {
        timeout(Duration::from_secs(3), async {
            loop {
                let value: Value = self
                    .client
                    .get(format!("http://{}/connections", self.api))
                    .bearer_auth("test-secret")
                    .header(INSTANCE_HEADER, &self.nonce)
                    .send()
                    .await
                    .unwrap()
                    .json()
                    .await
                    .unwrap();
                if value["connections"].as_array().unwrap().is_empty() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }
    async fn finish(mut self) {
        for stop in self.stops.drain(..) {
            let _ = stop.send(());
        }
        for task in self.tasks.drain(..) {
            task.await.unwrap().unwrap();
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        for stop in self.stops.drain(..) {
            let _ = stop.send(());
        }
    }
}
async fn header(stream: &mut TcpStream) -> String {
    let mut bytes = Vec::new();
    while !bytes.ends_with(b"\r\n\r\n") {
        bytes.push(stream.read_u8().await.unwrap());
        assert!(bytes.len() < 16384);
    }
    String::from_utf8(bytes).unwrap()
}
async fn send(stream: &mut TcpStream, target: SocketAddr, token: &str) -> String {
    stream
        .write_all(
            format!(
                "GET http://{target}/ HTTP/1.1\r\nHost: {target}\r\n{PROBE_HEADER}: {token}\r\n\r\n"
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    header(stream).await
}
async fn origin(listener: TcpListener, count: usize) {
    for _ in 0..count {
        let (mut peer, _) = listener.accept().await.unwrap();
        let request = header(&mut peer).await;
        assert!(
            !request.to_lowercase().contains(PROBE_HEADER),
            "tracking header reached origin"
        );
        assert!(!request.contains("test-secret"));
        peer.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn duplicate_connect_and_trailer_probe_fields_never_reach_an_origin() {
    timeout(Duration::from_secs(10), async {
        let f = Fixture::new("rules: ['MATCH,DIRECT']").await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let token = f.reserve(target).await;
        for request in [
            format!("GET http://{target}/ HTTP/1.1\r\nHost: {target}\r\n{PROBE_HEADER}: {token}\r\nX-Zc-Probe-Token: {token}\r\n\r\n"),
            format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n{PROBE_HEADER}: {token}\r\n\r\n"),
            format!("POST http://{target}/ HTTP/1.1\r\nHost: {target}\r\nTransfer-Encoding: chunked\r\nTrailer: X-Zc-Probe-Token\r\n\r\n0\r\nX-Zc-Probe-Token: {token}\r\n\r\n"),
        ] {
            let mut stream = TcpStream::connect(f.mixed).await.unwrap();
            stream.write_all(request.as_bytes()).await.unwrap();
            assert!(header(&mut stream).await.starts_with("HTTP/1.1 400"));
        }
        assert_eq!(f.evidence(&token).await["state"], "reserved");
        // An undeclared trailer is validated before the final chunk is relayed.
        let mut stream = TcpStream::connect(f.mixed).await.unwrap();
        stream.write_all(format!("POST http://{target}/ HTTP/1.1\r\nHost: {target}\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\nX-Zc-Probe-Token: {token}\r\n\r\n").as_bytes()).await.unwrap();
        let (mut peer, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        peer.read_to_end(&mut bytes).await.unwrap();
        let request = String::from_utf8(bytes).unwrap();
        assert!(!request.to_lowercase().contains(PROBE_HEADER));
        assert!(!request.contains(&token));
        f.finish().await;
    }).await.unwrap();
}

#[tokio::test]
#[ignore = "real 120-second ticket retention boundary"]
async fn tickets_expire_and_expired_dispatch_fails_without_dialing() {
    let f = Fixture::new("rules: ['MATCH,DIRECT']").await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = listener.local_addr().unwrap();
    let token = f.reserve(target).await;
    tokio::time::sleep(Duration::from_secs(121)).await;
    let response = f
        .client
        .get(format!("http://{}/connections/probes/{token}", f.api))
        .bearer_auth("test-secret")
        .header(INSTANCE_HEADER, &f.nonce)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 404);
    let mut stream = TcpStream::connect(f.mixed).await.unwrap();
    assert!(
        send(&mut stream, target, &token)
            .await
            .starts_with("HTTP/1.1 502")
    );
    assert!(
        timeout(Duration::from_millis(20), listener.accept())
            .await
            .is_err()
    );
    assert_ne!(f.reserve(target).await, token);
    f.finish().await;
}

#[tokio::test]
async fn short_requests_keep_evidence_and_keep_alive_captures_each_actual_selection() {
    timeout(Duration::from_secs(10), async {
        let f = Fixture::new("proxies: [{name: other-direct, type: direct}]\nproxy-groups: [{name: Pick, type: select, proxies: [DIRECT, other-direct]}]\nrules: ['MATCH,Pick']").await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let peer = tokio::spawn(origin(listener, 2));
        let first = f.reserve(target).await;
        let second = f.reserve(target).await;
        let mut stream = TcpStream::connect(f.mixed).await.unwrap();
        assert!(send(&mut stream, target, &first).await.starts_with("HTTP/1.1 200"));
        f.config.select("Pick", "other-direct").unwrap();
        assert!(send(&mut stream, target, &second).await.starts_with("HTTP/1.1 200"));
        drop(stream);
        peer.await.unwrap();
        f.wait_closed().await;
        let a = f.evidence(&first).await;
        let b = f.evidence(&second).await;
        assert_eq!(a["state"], "routed", "{a}");
        assert_eq!(a["proxy"], json!({"name":"DIRECT","type":"Direct"}));
        assert_eq!(b["proxy"], json!({"name":"other-direct","type":"Direct"}));
        assert_eq!(a["connection_id"], b["connection_id"]);
        assert_eq!(a["request_index"], 0);
        assert_eq!(b["request_index"], 1);
        let mut replay = TcpStream::connect(f.mixed).await.unwrap();
        assert!(send(&mut replay, target, &first).await.starts_with("HTTP/1.1 502"));
        assert_eq!(f.evidence(&first).await, a);
        f.finish().await;
    }).await.unwrap();
}

#[tokio::test]
async fn concurrent_same_target_requests_have_distinct_connection_evidence() {
    timeout(Duration::from_secs(10), async {
        let f = Fixture::new("rules: ['MATCH,DIRECT']").await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = listener.local_addr().unwrap();
        let peer = tokio::spawn(origin(listener, 12));
        let mut tasks = tokio::task::JoinSet::new();
        let mut tokens = Vec::new();
        for _ in 0..12 {
            let token = f.reserve(target).await;
            tokens.push(token.clone());
            let mixed = f.mixed;
            tasks.spawn(async move {
                let mut stream = TcpStream::connect(mixed).await.unwrap();
                assert!(
                    send(&mut stream, target, &token)
                        .await
                        .starts_with("HTTP/1.1 200")
                );
            });
        }
        while let Some(result) = tasks.join_next().await {
            result.unwrap();
        }
        peer.await.unwrap();
        f.wait_closed().await;
        let mut ids = std::collections::BTreeSet::new();
        for token in tokens {
            let value = f.evidence(&token).await;
            assert_eq!(value["token"], token);
            assert_eq!(value["proxy"]["type"], "Direct");
            assert!(ids.insert(value["connection_id"].as_str().unwrap().to_owned()));
        }
        assert_eq!(ids.len(), 12);
        f.finish().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn failed_proxy_dial_retains_leaf_and_wrong_target_or_instance_cannot_claim() {
    timeout(Duration::from_secs(10), async {
        let closed = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = closed.local_addr().unwrap(); drop(closed);
        let f = Fixture::new(&format!("proxies: [{{name: edge, type: ss, server: 127.0.0.1, port: {}, password: test-only, cipher: aes-128-gcm}}]\nrules: ['MATCH,edge']", address.port())).await;
        let target: SocketAddr = "127.0.0.1:23456".parse().unwrap();
        let token = f.reserve(target).await;
        let mut wrong = TcpStream::connect(f.mixed).await.unwrap();
        assert!(send(&mut wrong, "127.0.0.1:23457".parse().unwrap(), &token).await.starts_with("HTTP/1.1 502"));
        assert_eq!(f.evidence(&token).await["state"], "reserved");
        let stale = format!("{}.{}", "0".repeat(32), token.split_once('.').unwrap().1);
        let mut old = TcpStream::connect(f.mixed).await.unwrap();
        assert!(send(&mut old, target, &stale).await.starts_with("HTTP/1.1 502"));
        let mut stream = TcpStream::connect(f.mixed).await.unwrap();
        assert!(send(&mut stream, target, &token).await.starts_with("HTTP/1.1 502"));
        drop(stream);
        let value = f.evidence(&token).await;
        assert_eq!(value["proxy"], json!({"name":"edge","type":"Shadowsocks"}));
        assert!(!value.to_string().contains("test-only"));
        f.finish().await;
    }).await.unwrap();
}
