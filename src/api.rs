//! Bounded, single-request loopback control API.
use crate::config::Config;
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    future::Future,
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::Duration,
};
use subtle::ConstantTimeEq;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    task::JoinSet,
    time::timeout,
};

const HEADER_LIMIT: usize = 16 * 1024;
const BODY_LIMIT: usize = 64 * 1024;
const RESPONSE_LIMIT: usize = 4 * 1024 * 1024;
const IO_TIMEOUT: Duration = Duration::from_secs(2);

pub trait Managed: Send + Sync {
    fn status(&self) -> Result<Value>;
    fn select(&self, group: &str, proxy: &str, metadata: &Value) -> Result<bool>;
}

pub struct Server {
    listener: TcpListener,
    state: Arc<State>,
}
struct State {
    config: Arc<Config>,
    managed: Option<Arc<dyn Managed>>,
    transient: Mutex<BTreeSet<String>>,
}
impl Server {
    pub async fn bind(
        config: Arc<Config>,
        managed: Option<Arc<dyn Managed>>,
    ) -> Result<Option<Self>> {
        let Some(address) = config.controller_endpoint() else {
            return Ok(None);
        };
        ensure!(
            address.ip() == std::net::Ipv4Addr::LOCALHOST && address.port() != 0,
            "START_CONTROLLER_INVALID: controller must be explicit 127.0.0.1:<port>"
        );
        let listener = TcpListener::bind(address).await.map_err(|error| {
            anyhow::anyhow!("START_CONTROLLER_PORT_IN_USE: cannot bind {address}: {error}")
        })?;
        Ok(Some(Self {
            listener,
            state: Arc::new(State {
                config,
                managed,
                transient: Mutex::new(BTreeSet::new()),
            }),
        }))
    }
    pub fn local_addr(&self) -> Result<SocketAddr> {
        Ok(self.listener.local_addr()?)
    }
    pub async fn run(self, shutdown: impl Future<Output = ()>) -> Result<()> {
        let mut tasks = JoinSet::new();
        tokio::pin!(shutdown);
        let result = loop {
            tokio::select! {
                biased;
                _ = &mut shutdown => break Ok(()),
                _ = tasks.join_next(), if !tasks.is_empty() => {},
                accepted = self.listener.accept() => {
                    let (stream, _) = match accepted { Ok(v) => v, Err(e) => break Err(e.into()) };
                    if tasks.len() >= 16 { drop(stream); continue; }
                    let state = self.state.clone();
                    tasks.spawn(async move { let _ = serve(stream, state).await; });
                }
            }
        };
        tasks.shutdown().await;
        result
    }
}
struct Request {
    method: String,
    path: String,
    authorization: Option<Vec<u8>>,
    body: Vec<u8>,
}
#[derive(Clone, Copy)]
struct HttpError(u16, &'static str);
const BAD: HttpError = HttpError(400, "Bad Request");
async fn read_request(stream: &mut TcpStream) -> std::result::Result<Request, HttpError> {
    let mut bytes = Vec::with_capacity(4096);
    let header_end = loop {
        if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
            if end + 4 > HEADER_LIMIT {
                return Err(HttpError(413, "Payload Too Large"));
            }
            break end + 4;
        }
        if bytes.len() >= HEADER_LIMIT {
            return Err(HttpError(413, "Payload Too Large"));
        }
        let mut chunk = [0; 4096];
        let n = stream.read(&mut chunk).await.map_err(|_| BAD)?;
        if n == 0 {
            return Err(BAD);
        }
        bytes.extend_from_slice(&chunk[..n]);
    };
    let mut headers = vec![httparse::EMPTY_HEADER; HEADER_LIMIT / 4];
    let mut parsed = httparse::Request::new(&mut headers);
    for (index, byte) in bytes[..header_end].iter().enumerate() {
        if (*byte == b'\r' && bytes.get(index + 1) != Some(&b'\n'))
            || (*byte == b'\n' && (index == 0 || bytes[index - 1] != b'\r'))
        {
            return Err(BAD);
        }
    }
    if parsed.parse(&bytes[..header_end]).map_err(|_| BAD)?
        != httparse::Status::Complete(header_end)
    {
        return Err(BAD);
    }
    let method = parsed.method.ok_or(BAD)?.to_owned();
    let path = parsed.path.ok_or(BAD)?.to_owned();
    if !path.starts_with('/') || !matches!(parsed.version, Some(0 | 1)) {
        return Err(BAD);
    }
    let mut length = None;
    let mut authorization = None;
    for header in parsed.headers.iter() {
        if header.name.eq_ignore_ascii_case("transfer-encoding") {
            return Err(HttpError(501, "Transfer Encoding Unsupported"));
        }
        if header.name.eq_ignore_ascii_case("content-length") {
            if length.is_some()
                || header.value.is_empty()
                || !header.value.iter().all(u8::is_ascii_digit)
            {
                return Err(BAD);
            }
            let count: usize = std::str::from_utf8(header.value)
                .map_err(|_| BAD)?
                .parse()
                .map_err(|_| BAD)?;
            if count > BODY_LIMIT {
                return Err(HttpError(413, "Payload Too Large"));
            }
            length = Some(count);
        }
        if header.name.eq_ignore_ascii_case("authorization") {
            if authorization.is_some() {
                return Err(BAD);
            }
            authorization = Some(header.value.to_vec());
        }
    }
    if method == "PUT" && length.is_none() {
        return Err(HttpError(411, "Length Required"));
    }
    let total = header_end + length.unwrap_or(0);
    if bytes.len() > total {
        return Err(BAD);
    }
    let received = bytes.len();
    bytes.resize(total, 0);
    stream
        .read_exact(&mut bytes[received..])
        .await
        .map_err(|_| BAD)?;
    Ok(Request {
        method,
        path,
        authorization,
        body: bytes[header_end..].to_vec(),
    })
}
fn selected(config: &Config, source: impl Fn(&str) -> &'static str) -> Value {
    Value::Array(
        config
            .selected()
            .into_iter()
            .map(|(group, proxy)| {
                let origin = source(&group);
                json!({"group": group, "proxy": proxy, "source": origin})
            })
            .collect(),
    )
}
pub(crate) fn selected_json(config: &Config, persisted: &BTreeSet<String>) -> Value {
    selected(config, |group| {
        if persisted.contains(group) {
            "persisted"
        } else {
            "default"
        }
    })
}
fn decode_group(path: &str) -> Option<String> {
    let mut result = Vec::new();
    let mut input = path.as_bytes().iter().copied();
    while let Some(byte) = input.next() {
        if byte == b'%' {
            let a = (input.next()? as char).to_digit(16)?;
            let b = (input.next()? as char).to_digit(16)?;
            result.push((a * 16 + b) as u8);
        } else {
            result.push(byte);
        }
    }
    String::from_utf8(result).ok()
}
impl State {
    fn route(&self, request: Request) -> std::result::Result<Value, HttpError> {
        if request.method == "PUT" && !self.config.secret().is_empty() {
            let authorization = request.authorization.as_deref().unwrap_or_default();
            if authorization.len() < 7
                || !authorization[..7].eq_ignore_ascii_case(b"Bearer ")
                || !bool::from(authorization[7..].ct_eq(self.config.secret().as_bytes()))
            {
                return Err(HttpError(401, "Unauthorized"));
            }
        }
        match (request.method.as_str(), request.path.as_str()) {
            ("GET", "/") => Ok(json!({"version": env!("CARGO_PKG_VERSION"), "hello": "zc"})),
            ("GET", "/version") => Ok(json!({"version": env!("CARGO_PKG_VERSION")})),
            ("GET", "/proxies") => Ok(self.config.proxies_json()),
            ("GET", "/rules") => Ok(self.config.rules_json()),
            ("GET", "/status") => {
                if let Some(managed) = &self.managed {
                    return managed
                        .status()
                        .map_err(|_| HttpError(409, "Runtime changed"));
                }
                let transient = self
                    .transient
                    .lock()
                    .map_err(|_| HttpError(500, "Internal Server Error"))?;
                Ok(
                    json!({"config_key": null, "selected_proxies": selected(&self.config, |group| if transient.contains(group) { "transient" } else { "default" })}),
                )
            }
            ("PUT", path) if path.starts_with("/proxies/") => {
                let group = decode_group(&path[9..]).ok_or(BAD)?;
                let body: Value = serde_json::from_slice(&request.body).map_err(|_| BAD)?;
                let proxy = body
                    .get("name")
                    .and_then(Value::as_str)
                    .ok_or(HttpError(400, "Missing name in body"))?;
                let group_definition = ["proxy-groups", "proxies"]
                    .into_iter()
                    .filter_map(|key| self.config.document().get(key).and_then(Value::as_array))
                    .flatten()
                    .find(|entry| entry["name"] == group && entry.get("proxies").is_some())
                    .ok_or(HttpError(404, "Group not found"))?;
                if !group_definition["proxies"]
                    .as_array()
                    .is_some_and(|members| {
                        members.iter().any(|member| member.as_str() == Some(proxy))
                    })
                {
                    return Err(HttpError(404, "Proxy not found in group"));
                }
                let fields = [
                    "instance_nonce",
                    "identity_key",
                    "identity_revision",
                    "generation",
                ];
                let count = fields
                    .iter()
                    .filter(|key| body.get(**key).is_some())
                    .count();
                if count != 0
                    && (count != 4
                        || fields[..3].iter().any(|key| body[*key].as_str().is_none())
                        || body["generation"].as_u64().unwrap_or(0) == 0)
                {
                    return Err(HttpError(400, "Invalid managed selection metadata"));
                }
                if count == 4 {
                    let valid_hex = |value: &Value| {
                        value.as_str().is_some_and(|text| {
                            text.len() == 32
                                && text.bytes().all(|byte| {
                                    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
                                })
                        })
                    };
                    if !valid_hex(&body["instance_nonce"])
                        || !valid_hex(&body["identity_revision"])
                        || !body["identity_key"]
                            .as_str()
                            .is_some_and(crate::store::valid_key)
                    {
                        return Err(HttpError(400, "Invalid managed selection metadata"));
                    }
                }
                if let Some(managed) = &self.managed {
                    if count == 0 {
                        return Err(HttpError(409, "Managed selection metadata required"));
                    }
                    if !managed
                        .select(&group, proxy, &body)
                        .map_err(|_| HttpError(409, "Selection changed during apply"))?
                    {
                        return Err(HttpError(409, "Selection changed during apply"));
                    }
                } else {
                    if count != 0 {
                        return Err(HttpError(409, "Selection changed during apply"));
                    }
                    let mut transient = self
                        .transient
                        .lock()
                        .map_err(|_| HttpError(500, "Internal Server Error"))?;
                    self.config
                        .select(&group, proxy)
                        .map_err(|_| HttpError(404, "Proxy or group not found"))?;
                    transient.insert(group.clone());
                }
                Ok(json!({"ok": true, "group": group, "proxy": proxy}))
            }
            ("GET" | "PUT", _) => Err(HttpError(404, "Not Found")),
            _ => Err(HttpError(405, "Method Not Allowed")),
        }
    }
}
struct BoundedResponse(Vec<u8>);
impl std::io::Write for BoundedResponse {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > RESPONSE_LIMIT.saturating_sub(self.0.len()) {
            return Err(std::io::Error::other("response size limit exceeded"));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
async fn serve(mut stream: TcpStream, state: Arc<State>) -> Result<()> {
    let result = match timeout(IO_TIMEOUT, read_request(&mut stream)).await {
        Ok(Ok(request)) => state.route(request),
        Ok(Err(error)) => Err(error),
        Err(_) => Err(HttpError(408, "Request Timeout")),
    };
    let (code, reason, body) = match result {
        Ok(value) => {
            let mut bounded = BoundedResponse(Vec::new());
            if serde_json::to_writer(&mut bounded, &value).is_err() {
                (
                    500,
                    "Response Too Large",
                    serde_json::to_vec(&json!({"error": "Response Too Large"}))?,
                )
            } else {
                (200, "OK", bounded.0)
            }
        }
        Err(HttpError(code, reason)) => {
            (code, reason, serde_json::to_vec(&json!({"error": reason}))?)
        }
    };
    let header = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
        body.len()
    );
    timeout(IO_TIMEOUT, async {
        stream.write_all(header.as_bytes()).await?;
        stream.write_all(&body).await?;
        stream.shutdown().await
    })
    .await??;
    Ok(())
}
