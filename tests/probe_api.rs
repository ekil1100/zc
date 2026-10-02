use reqwest::{Method, Response};
use serde_json::{Value, json};
use std::{net::SocketAddr, sync::Arc, time::Duration};
use tokio::{net::TcpListener, sync::oneshot};
use zc::{
    api::Server,
    config::Config,
    connection::{ConnectionRegistry, INSTANCE_HEADER},
};

const SECRET: &str = "probe-test-secret";
const ROOT: &str = "/connections/probes";
struct Fixture {
    address: SocketAddr,
    nonce: String,
    client: reqwest::Client,
    stop: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<anyhow::Result<()>>>,
}
impl Fixture {
    async fn new(secret: &str) -> Self {
        let reserved = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = reserved.local_addr().unwrap();
        drop(reserved);
        let config = Arc::new(
            Config::parse(&format!(
                "external-controller: {address}\nsecret: {secret:?}\nrules: ['MATCH,DIRECT']"
            ))
            .unwrap(),
        );
        let server = Server::bind(config, None, ConnectionRegistry::new().unwrap())
            .await
            .unwrap()
            .unwrap();
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(server.run(async {
            let _ = stopped.await;
        }));
        let mut f = Self {
            address,
            nonce: String::new(),
            client: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(3))
                .build()
                .unwrap(),
            stop: Some(stop),
            task: Some(task),
        };
        if !secret.is_empty() {
            let response = f
                .request(Method::GET, "/connections", Some(secret), None, None)
                .await;
            assert_eq!(response.status(), 200);
            f.nonce = response.headers()[INSTANCE_HEADER]
                .to_str()
                .unwrap()
                .to_owned();
        }
        f
    }
    async fn request(
        &self,
        method: Method,
        path: &str,
        secret: Option<&str>,
        instance: Option<&str>,
        body: Option<Value>,
    ) -> Response {
        let mut request = self
            .client
            .request(method, format!("http://{}{path}", self.address));
        if let Some(secret) = secret {
            request = request.bearer_auth(secret);
        }
        if let Some(instance) = instance {
            request = request.header(INSTANCE_HEADER, instance);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        request.send().await.unwrap()
    }
    async fn probe(&self, method: Method, path: &str, body: Option<Value>) -> Response {
        self.request(method, path, Some(SECRET), Some(&self.nonce), body)
            .await
    }
    async fn reserve(&self, host: &str, port: u16) -> String {
        let response = self
            .probe(Method::PUT, ROOT, Some(json!({"host":host,"port":port})))
            .await;
        assert_eq!(response.status(), 200);
        let value = response.json::<Value>().await.unwrap();
        assert_eq!(value.as_object().unwrap().len(), 1);
        value["token"].as_str().unwrap().to_owned()
    }
    async fn finish(mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.task.take().unwrap().await.unwrap().unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}

#[tokio::test]
async fn reservation_roundtrip_is_normalized_and_delete_releases_only_that_ticket() {
    let f = Fixture::new(SECRET).await;
    let token = f.reserve("EXAMPLE.test", 443).await;
    let (nonce, random) = token.split_once('.').unwrap();
    assert_eq!(nonce, f.nonce);
    assert_eq!(random.len(), 32);
    assert!(
        random
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    );
    let path = format!("{ROOT}/{token}");
    let response = f.probe(Method::GET, &path, None).await;
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.json::<Value>().await.unwrap(),
        json!({"token":token,"state":"reserved","target":{"host":"example.test","port":443}})
    );
    let other = f.reserve("2001:0db8:0:0:0:0:0:1", 80).await;
    let other_path = format!("{ROOT}/{other}");
    let value = f
        .probe(Method::GET, &other_path, None)
        .await
        .json::<Value>()
        .await
        .unwrap();
    assert_eq!(value["target"], json!({"host":"2001:db8::1","port":80}));
    let response = f.probe(Method::DELETE, &path, None).await;
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.json::<Value>().await.unwrap(),
        json!({"released":true})
    );
    for method in [Method::GET, Method::DELETE] {
        assert_eq!(f.probe(method, &path, None).await.status(), 404);
    }
    assert_eq!(f.probe(Method::GET, &other_path, None).await.status(), 200);
    assert_ne!(f.reserve("example.test", 443).await, token);
    f.finish().await;
}

#[tokio::test]
async fn every_probe_endpoint_requires_secret_bearer_and_matching_instance() {
    let f = Fixture::new(SECRET).await;
    let token = format!("{}.{}", f.nonce, "1".repeat(32));
    let path = format!("{ROOT}/{token}");
    for (method, path, body) in [
        (
            Method::PUT,
            ROOT,
            Some(json!({"host":"example.test","port":443})),
        ),
        (Method::GET, path.as_str(), None),
        (Method::DELETE, path.as_str(), None),
    ] {
        for auth in [None, Some("wrong-secret")] {
            let response = f
                .request(
                    method.clone(),
                    path,
                    auth,
                    Some("wrong-instance"),
                    body.clone(),
                )
                .await;
            assert_eq!(response.status(), 401);
            assert!(response.headers().get(INSTANCE_HEADER).is_none());
            assert_eq!(
                response.json::<Value>().await.unwrap(),
                json!({"error":"Unauthorized"})
            );
        }
        let response = f
            .request(method.clone(), path, Some(SECRET), None, body.clone())
            .await;
        assert_eq!(response.status(), 400);
        let response = f
            .request(
                method.clone(),
                path,
                Some(SECRET),
                Some(&"0".repeat(32)),
                body,
            )
            .await;
        assert_eq!(response.status(), 409);
    }
    f.finish().await;
    let f = Fixture::new("").await;
    for method in [Method::PUT, Method::GET, Method::DELETE] {
        let path = if method == Method::PUT {
            ROOT.to_owned()
        } else {
            format!("{ROOT}/{}.{}", "0".repeat(32), "1".repeat(32))
        };
        let body = (method == Method::PUT).then(|| json!({"host":"example.test","port":443}));
        let response = f
            .request(method, &path, Some(SECRET), Some(&"0".repeat(32)), body)
            .await;
        assert_eq!(response.status(), 403);
        assert!(response.headers().get(INSTANCE_HEADER).is_none());
        assert_eq!(
            response.json::<Value>().await.unwrap(),
            json!({"error":"Connection secret required"})
        );
    }
    f.finish().await;
}

#[tokio::test]
async fn invalid_schema_and_token_syntax_fail_with_sanitized_errors() {
    let f = Fixture::new(SECRET).await;
    for body in [
        json!(null),
        json!([]),
        json!({}),
        json!({"host":"example.test"}),
        json!({"host":"example.test","port":0}),
        json!({"host":"example.test","port":65536}),
        json!({"host":"example.test","port":-1}),
        json!({"host":"example.test","port":"443"}),
        json!({"host":"example.test","port":1.5}),
        json!({"host":null,"port":443}),
        json!({"host":"","port":443}),
        json!({"host":"user:PRIVATE_PASSWORD@example.test","port":443}),
        json!({"host":"https://example.test/path","port":443}),
        json!({"host":"example.test\r\n","port":443}),
        json!({"host":"a".repeat(256),"port":443}),
        json!({"host":"example.test","port":443,"extra":"PRIVATE_PASSWORD"}),
    ] {
        let response = f.probe(Method::PUT, ROOT, Some(body)).await;
        assert_eq!(response.status(), 400);
        assert_eq!(
            response.json::<Value>().await.unwrap(),
            json!({"error":"Bad Request"})
        );
    }
    for body in [
        r#"{"host":"example.test","host":"other.test","port":443}"#,
        "{",
    ] {
        let response = f
            .client
            .put(format!("http://{}{ROOT}", f.address))
            .bearer_auth(SECRET)
            .header(INSTANCE_HEADER, &f.nonce)
            .body(body)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 400);
    }
    for token in [
        "bad".to_owned(),
        format!("{}.{}", f.nonce, "a".repeat(31)),
        format!("{}.{}", f.nonce, "G".repeat(32)),
        format!("{}.{}", f.nonce, "a".repeat(33)),
        format!("{}.{}", f.nonce, "a".repeat(32)) + "/extra",
        String::new(),
    ] {
        for method in [Method::GET, Method::DELETE] {
            let response = f.probe(method, &format!("{ROOT}/{token}"), None).await;
            assert_eq!(response.status(), 400);
            assert_eq!(
                response.json::<Value>().await.unwrap(),
                json!({"error":"Bad Request"})
            );
        }
    }
    for method in [Method::GET, Method::DELETE] {
        assert_eq!(
            f.probe(
                method.clone(),
                &format!("{ROOT}/{}.{}", f.nonce, "f".repeat(32)),
                None
            )
            .await
            .status(),
            404
        );
        assert_eq!(
            f.probe(
                method,
                &format!("{ROOT}/{}.{}", "0".repeat(32), "f".repeat(32)),
                None
            )
            .await
            .status(),
            409
        );
    }
    f.finish().await;
}

#[tokio::test]
async fn capacity_rejects_without_eviction_and_is_instance_local() {
    let f = Fixture::new(SECRET).await;
    let mut tokens = std::collections::BTreeSet::new();
    for _ in 0..256 {
        assert!(tokens.insert(f.reserve("127.0.0.1", 443).await));
    }
    let response = f
        .probe(
            Method::PUT,
            ROOT,
            Some(json!({"host":"127.0.0.1","port":443})),
        )
        .await;
    assert_eq!(response.status(), 429);
    assert_eq!(
        response.json::<Value>().await.unwrap(),
        json!({"error":"Probe quota exceeded"})
    );
    for token in &tokens {
        assert_eq!(
            f.probe(Method::GET, &format!("{ROOT}/{token}"), None)
                .await
                .status(),
            200
        );
    }
    let other = Fixture::new(SECRET).await;
    let other_token = other.reserve("127.0.0.1", 443).await;
    assert_eq!(
        f.probe(Method::GET, &format!("{ROOT}/{other_token}"), None)
            .await
            .status(),
        409
    );
    assert_eq!(
        other
            .probe(
                Method::GET,
                &format!("{ROOT}/{}", tokens.first().unwrap()),
                None
            )
            .await
            .status(),
        409
    );
    other.finish().await;
    let released = tokens.first().unwrap();
    assert_eq!(
        f.probe(Method::DELETE, &format!("{ROOT}/{released}"), None)
            .await
            .status(),
        200
    );
    let fresh = f.reserve("127.0.0.1", 443).await;
    assert!(!tokens.contains(&fresh));
    assert_eq!(
        f.probe(Method::GET, &format!("{ROOT}/{released}"), None)
            .await
            .status(),
        404
    );
    assert_eq!(
        f.probe(
            Method::PUT,
            ROOT,
            Some(json!({"host":"127.0.0.1","port":443}))
        )
        .await
        .status(),
        429
    );
    f.finish().await;
}
