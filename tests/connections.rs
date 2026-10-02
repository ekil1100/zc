use serde_json::{Value, json};
use std::{net::SocketAddr, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    time::timeout,
};
use zc::{api::Server, config::Config, runtime::Runtime};

struct Fixture {
    mixed: SocketAddr,
    api: SocketAddr,
    client: reqwest::Client,
    stops: Vec<oneshot::Sender<()>>,
    tasks: Vec<tokio::task::JoinHandle<anyhow::Result<()>>>,
}
impl Fixture {
    async fn new(source: &str) -> Self {
        Self::configured(source, |config| config).await
    }
    async fn configured(source: &str, configure: impl FnOnce(Config) -> Config) -> Self {
        let reserve = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let api = reserve.local_addr().unwrap();
        drop(reserve);
        let config = Config::parse(&format!(
            "external-controller: {api}\nsecret: test-secret\n{source}"
        ))
        .unwrap();
        let runtime = Runtime::bind(configure(config), 0).await.unwrap();
        let mixed = runtime.local_addr().unwrap();
        let server = Server::bind(runtime.config(), None, runtime.connections())
            .await
            .unwrap()
            .unwrap();
        let (a, ar) = oneshot::channel();
        let (b, br) = oneshot::channel();
        Self {
            mixed,
            api,
            client: reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(2))
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
        }
    }
    async fn request(&self, method: reqwest::Method, path: &str) -> reqwest::Response {
        self.client
            .request(method, format!("http://{}{path}", self.api))
            .bearer_auth("test-secret")
            .send()
            .await
            .unwrap()
    }
    async fn list(&self) -> Vec<Value> {
        let response = self.request(reqwest::Method::GET, "/connections").await;
        assert_eq!(response.status(), 200);
        response.json::<Value>().await.unwrap()["connections"]
            .as_array()
            .unwrap()
            .clone()
    }
    async fn wait(&self, predicate: impl Fn(&[Value]) -> bool) -> Vec<Value> {
        timeout(Duration::from_secs(3), async {
            loop {
                let entries = self.list().await;
                if predicate(&entries) {
                    return entries;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap()
    }
    async fn close(&self, id: &str) -> reqwest::Response {
        self.request(reqwest::Method::DELETE, &format!("/connections/{id}"))
            .await
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
        let mut byte = [0];
        stream.read_exact(&mut byte).await.unwrap();
        bytes.push(byte[0]);
        assert!(bytes.len() < 16384);
    }
    String::from_utf8(bytes).unwrap()
}
async fn connect(f: &Fixture, origin: &TcpListener) -> (TcpStream, TcpStream) {
    let mut client = TcpStream::connect(f.mixed).await.unwrap();
    let target = origin.local_addr().unwrap();
    client
        .write_all(format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let (peer, _) = origin.accept().await.unwrap();
    assert!(header(&mut client).await.starts_with("HTTP/1.1 200"));
    (client, peer)
}
async fn eof(stream: &mut TcpStream) {
    assert!(matches!(stream.read(&mut [0]).await, Ok(0) | Err(_)));
}

#[tokio::test]
async fn two_real_tunnels_list_truthful_routes_and_close_only_one() {
    timeout(Duration::from_secs(8), async {
        let f = Fixture::new("proxy-groups: [{name: Pick, type: select, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,Pick']").await;
        let origin = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (mut a, mut pa) = connect(&f, &origin).await;
        let (mut b, mut pb) = connect(&f, &origin).await;
        let entries = f.list().await;
        assert_eq!(entries.len(), 2);
        let entry = entries.iter().find(|e| e["source"] == a.local_addr().unwrap().to_string()).unwrap();
        assert_eq!(entry["protocol"], "tcp");
        assert_eq!(entry["inbound"], "http_connect");
        assert_eq!(entry["phase"], "active");
        assert_eq!(entry["target"], json!({"host":"127.0.0.1", "port":origin.local_addr().unwrap().port()}));
        assert_eq!(entry["routed_target"], entry["target"]);
        assert_eq!(entry["rule"], json!({"index":0,"type":"MATCH","payload":"","target":"Pick"}));
        assert_eq!(entry["proxy"], json!({"name":"DIRECT","type":"Direct"}));
        let id = entry["id"].as_str().unwrap();
        let stale = format!("{}{}", if id.starts_with('0') { "1" } else { "0" }, &id[1..]);
        assert_eq!(f.close(&stale).await.status(), 409);
        assert_eq!(f.list().await.len(), 2);
        let response = f.close(id).await;
        assert_eq!(response.status(), 200);
        assert_eq!(response.json::<Value>().await.unwrap(), json!({"id":id,"close_requested":true,"phase":"closing"}));
        eof(&mut a).await; eof(&mut pa).await;
        f.wait(|v| v.len() == 1).await;
        assert_eq!(f.close(id).await.status(), 404);
        b.write_all(b"still alive").await.unwrap();
        let mut payload = [0;11]; pb.read_exact(&mut payload).await.unwrap(); assert_eq!(&payload,b"still alive");
        pb.write_all(b"reply").await.unwrap(); let mut reply = [0;5]; b.read_exact(&mut reply).await.unwrap(); assert_eq!(&reply,b"reply");
        drop(b); drop(pb); f.wait(|v| v.is_empty()).await;
        f.finish().await;
    }).await.unwrap();
}

#[tokio::test]
async fn udp_first_datagram_metadata_is_fixed_and_close_reclaims_association() {
    timeout(Duration::from_secs(8), async {
        let upstream = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let f = Fixture::new(&format!("proxies: [{{name: edge, type: ss, server: 127.0.0.1, port: {}, password: PRIVATE_PASSWORD, cipher: aes-128-gcm, udp: true}}]\nproxy-groups: [{{name: Pick, type: select, proxies: [edge, REJECT]}}]\nrules: ['DST-PORT,53,Pick', 'MATCH,REJECT']", upstream.local_addr().unwrap().port())).await;
        let mut control = TcpStream::connect(f.mixed).await.unwrap();
        control.write_all(b"\x05\x01\x00").await.unwrap();
        let mut greeting = [0;2]; control.read_exact(&mut greeting).await.unwrap();
        assert_eq!(greeting, [5,0]);
        control.write_all(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00").await.unwrap();
        let mut reply = [0;10]; control.read_exact(&mut reply).await.unwrap(); assert_eq!(&reply[..4], &[5,0,0,1]);
        let relay = SocketAddr::from(([reply[4],reply[5],reply[6],reply[7]], u16::from_be_bytes([reply[8],reply[9]])));
        let entries = f.list().await; assert_eq!(entries.len(),1);
        let entry = &entries[0]; assert_eq!(entry["protocol"], "udp"); assert_eq!(entry["phase"],"udp_wait");
        assert!(entry.get("target").is_none() && entry.get("rule").is_none() && entry.get("proxy").is_none());
        let id = entry["id"].as_str().unwrap();
        let datagram = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        datagram.send_to(b"\x00\x00\x00\x01\x7f\x00\x00\x01\x00\x35first",relay).await.unwrap();
        upstream.recv_from(&mut [0;1024]).await.unwrap();
        let first = f.list().await.remove(0);
        assert_eq!(first["id"],id); assert_eq!(first["target_scope"],"first_datagram");
        assert_eq!(first["datagram_source"], datagram.local_addr().unwrap().to_string());
        assert_eq!(first["target"],json!({"host":"127.0.0.1","port":53}));
        assert_eq!(first["rule"],json!({"index":0,"type":"DST-PORT","payload":"53","target":"Pick"}));
        assert_eq!(first["proxy"],json!({"name":"edge","type":"Shadowsocks"}));
        let selected = f.client.put(format!("http://{}/proxies/Pick",f.api)).bearer_auth("test-secret").json(&json!({"name":"REJECT"})).send().await.unwrap(); assert_eq!(selected.status(),200);
        datagram.send_to(b"\x00\x00\x00\x01\x7f\x00\x00\x02\x01\xbbsecond",relay).await.unwrap();
        upstream.recv_from(&mut [0;1024]).await.unwrap();
        assert_eq!(f.list().await[0],first);
        assert!(!first.to_string().contains("PRIVATE_PASSWORD"));
        assert_eq!(f.close(id).await.status(),200); eof(&mut control).await;
        f.wait(|entries| entries.is_empty()).await;
        f.finish().await;
    }).await.unwrap();
}

#[tokio::test]
async fn keepalive_idle_clears_metadata_and_next_request_uses_new_leaf() {
    timeout(Duration::from_secs(8), async {
        let f = Fixture::new("proxies: [{name: first, type: direct}, {name: second, type: direct}]\nproxy-groups: [{name: Pick, type: select, proxies: [first, second]}]\nrules: ['MATCH,Pick']").await;
        let origin = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (tunnel, _peer) = connect(&f, &origin).await;
        let mut http = TcpStream::connect(f.mixed).await.unwrap();
        let destination = origin.local_addr().unwrap();
        let request = format!("GET http://{destination}/PRIVATE_URL HTTP/1.1\r\nHost: {destination}\r\nAuthorization: Basic PRIVATE_HEADER\r\n\r\n");
        http.write_all(request.as_bytes()).await.unwrap();
        let (mut first, _) = origin.accept().await.unwrap();
        header(&mut first).await;
        let entries = f.list().await;
        let entry = entries.iter().find(|e| e["source"]==http.local_addr().unwrap().to_string()).unwrap();
        let id = entry["id"].as_str().unwrap().to_owned(); assert_eq!(entry["proxy"]["name"],"first");
        assert!(!entries.iter().any(|e| e.to_string().contains("PRIVATE_")));
        let selected = f.client.put(format!("http://{}/proxies/Pick",f.api)).bearer_auth("test-secret").json(&json!({"name":"second"})).send().await.unwrap(); assert_eq!(selected.status(),200);
        assert!(f.list().await.iter().all(|e|e["proxy"]["name"]=="first"));
        first.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n").await.unwrap();
        header(&mut http).await;
        let entries = f.wait(|v|v.iter().any(|e|e["id"]==id && e["phase"]=="idle")).await;
        let idle=entries.iter().find(|e|e["id"]==id).unwrap();
        for key in ["target","routed_target","rule","proxy"] { assert!(idle.get(key).is_none(),"{idle}"); }
        http.write_all(request.as_bytes()).await.unwrap();
        let (mut second, _) = origin.accept().await.unwrap(); header(&mut second).await;
        let entries=f.list().await;
        assert_eq!(entries.iter().find(|e|e["id"]==id).unwrap()["proxy"]["name"],"second");
        assert_eq!(entries.iter().find(|e|e["source"]==tunnel.local_addr().unwrap().to_string()).unwrap()["proxy"]["name"],"first");
        second.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n").await.unwrap(); header(&mut http).await;
        f.wait(|v|v.iter().any(|e|e["id"]==id && e["phase"]=="idle")).await;
        http.write_all(format!("CONNECT {destination} HTTP/1.1\r\nHost: {destination}\r\n\r\n").as_bytes()).await.unwrap();
        let (mut third,_)=origin.accept().await.unwrap(); assert!(header(&mut http).await.starts_with("HTTP/1.1 200"));
        let entries=f.list().await; let current=entries.iter().find(|e|e["id"]==id).unwrap();
        assert_eq!(current["inbound"],"http_connect"); assert_eq!(current["phase"],"active"); assert_eq!(current["proxy"]["name"],"second");
        assert_eq!(f.close(&id).await.status(),200); eof(&mut http).await; eof(&mut third).await;
        f.finish().await;
    }).await.unwrap();
}

#[tokio::test]
async fn management_cancels_pending_ingress_and_tls_at_wire_barriers() {
    timeout(Duration::from_secs(8), async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let f = Fixture::new(&format!("proxies: [{{name: edge, type: trojan, server: 127.0.0.1, port: {}, password: private, skip-cert-verify: true}}]\nrules: ['MATCH,edge']",upstream.local_addr().unwrap().port())).await;
        let mut handshake = TcpStream::connect(f.mixed).await.unwrap();
        handshake.write_all(b"\x05\x01").await.unwrap();
        let entries = f.wait(|e|e.len()==1).await; assert_eq!(entries[0]["phase"],"handshake");
        assert!(entries[0].get("proxy").is_none());
        assert_eq!(f.close(entries[0]["id"].as_str().unwrap()).await.status(),200); eof(&mut handshake).await;
        f.wait(|e|e.is_empty()).await;
        let mut client = TcpStream::connect(f.mixed).await.unwrap();
        client.write_all(b"CONNECT 127.0.0.1:12345 HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n").await.unwrap();
        let (mut tls, _) = upstream.accept().await.unwrap();
        let mut record=[0;5]; tls.read_exact(&mut record).await.unwrap(); assert_eq!(record[0],22);
        let mut hello=vec![0;u16::from_be_bytes([record[3],record[4]]) as usize]; tls.read_exact(&mut hello).await.unwrap();
        let entries=f.list().await; assert_eq!(entries[0]["phase"],"connecting"); assert_eq!(entries[0]["proxy"]["name"],"edge");
        assert_eq!(f.close(entries[0]["id"].as_str().unwrap()).await.status(),200);
        eof(&mut client).await; eof(&mut tls).await; f.wait(|e|e.is_empty()).await;
        f.finish().await;
    }).await.unwrap();
}

#[tokio::test]
async fn rejection_bad_ingress_and_upstream_errors_leave_no_history() {
    timeout(Duration::from_secs(8), async {
        let origin = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = origin.local_addr().unwrap().port();
        drop(origin);
        let f = Fixture::new(&format!("rules: ['DST-PORT,{port},DIRECT','MATCH,REJECT']")).await;
        for request in [
            b"BAD / HTTP/1.1\r\n\r\n".to_vec(),
            b"CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".to_vec(),
            format!("CONNECT 127.0.0.1:{port} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n")
                .into_bytes(),
        ] {
            let mut client = TcpStream::connect(f.mixed).await.unwrap();
            client.write_all(&request).await.unwrap();
            let mut response = String::new();
            client.read_to_string(&mut response).await.unwrap();
            assert!(response.starts_with("HTTP/1.1 400") || response.starts_with("HTTP/1.1 502"));
            f.wait(|e| e.is_empty()).await;
        }
        f.finish().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn connection_output_budget_counts_shared_configuration_and_json_escaping() {
    timeout(Duration::from_secs(20), async {
        // Each record borrows the large rule target and leaf name; never clone it per entry.
        for name in ["n".repeat(1024*1024), "\\".repeat(400_000)] {
            let source = json!({"proxies":[{"name":name,"type":"direct"}],"rules":[format!("MATCH,{name}")]});
            let source=format!("proxies: {}\nrules: {}",source["proxies"],source["rules"]);
            let f=Fixture::new(&source).await;
            let origin=TcpListener::bind("127.0.0.1:0").await.unwrap();
            let (a,pa)=connect(&f,&origin).await;
            assert_eq!(f.list().await.len(),1);
            let (b,pb)=connect(&f,&origin).await;
            let third=if name.starts_with('\\') { Some(connect(&f,&origin).await) } else { None };
            let response=f.request(reqwest::Method::GET,"/connections").await;
            assert_eq!(response.status(),500);
            assert_eq!(response.json::<Value>().await.unwrap(),json!({"error":"Response Too Large"}));
            drop((b,pb,third));
            f.wait(|e|e.len()==1).await;
            drop((a,pa)); f.finish().await;
        }
    }).await.unwrap();
}

#[tokio::test]
async fn closing_is_idempotent_until_reclaimed_and_listener_panic_removes_records() {
    timeout(Duration::from_secs(12), async {
        let reserve=TcpListener::bind("127.0.0.1:0").await.unwrap(); let api=reserve.local_addr().unwrap(); drop(reserve);
        let (ready, received)=std::sync::mpsc::sync_channel(1);
        let (pause, paused)=oneshot::channel();
        let (at_barrier, barrier)=std::sync::mpsc::sync_channel(1);
        let (release, released)=std::sync::mpsc::sync_channel(1);
        let (panic_now, panic_wait)=oneshot::channel();
        let worker=std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
                let runtime=Runtime::bind(Config::parse(&format!("external-controller: {api}\nsecret: test-secret\nrules: ['MATCH,DIRECT']")).unwrap(),0).await.unwrap();
                ready.send((runtime.local_addr().unwrap(), runtime.config(), runtime.connections())).unwrap();
                runtime.run(async {
                    paused.await.unwrap();
                    // Freeze only the fixture executor; the independent API can request cancellation.
                    at_barrier.send(()).unwrap(); released.recv_timeout(Duration::from_secs(5)).unwrap();
                    panic_wait.await.unwrap(); panic!("fixture listener panic");
                }).await
            })
        });
        let (mixed,config,connections)=received.recv_timeout(Duration::from_secs(3)).unwrap();
        let server=Server::bind(config,None,connections).await.unwrap().unwrap();
        let (stop,stopped)=oneshot::channel();
        let f=Fixture { mixed,api,client:reqwest::Client::builder().no_proxy().build().unwrap(),stops:vec![stop],tasks:vec![tokio::spawn(server.run(async { let _=stopped.await; }))] };
        let origin=TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (mut a,mut pa)=connect(&f,&origin).await;
        let entry=f.list().await.remove(0); let id=entry["id"].as_str().unwrap();
        pause.send(()).unwrap(); barrier.recv_timeout(Duration::from_secs(3)).unwrap();
        for _ in 0..3 {
            let response=f.close(id).await; assert_eq!(response.status(),200); assert_eq!(response.json::<Value>().await.unwrap()["phase"],"closing");
            let current=f.list().await.remove(0); assert_eq!(current["phase"],"closing"); assert_eq!(current["proxy"],entry["proxy"]);
        }
        release.send(()).unwrap(); eof(&mut a).await; eof(&mut pa).await;
        f.wait(|v|v.is_empty()).await; assert_eq!(f.close(id).await.status(),404);
        let (mut b,mut pb)=connect(&f,&origin).await; assert_eq!(f.list().await.len(),1);
        panic_now.send(()).unwrap(); assert!(worker.join().unwrap().is_err());
        assert!(f.list().await.is_empty()); eof(&mut b).await; eof(&mut pb).await;
        f.finish().await;
    }).await.unwrap();
}

fn tls_acceptor() -> tokio_rustls::TlsAcceptor {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
    let cert =
        CertificateDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-cert.pem")).unwrap();
    let key =
        PrivateKeyDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-key.pem")).unwrap();
    let config = rustls::ServerConfig::builder_with_provider(std::sync::Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![cert], key)
    .unwrap();
    tokio_rustls::TlsAcceptor::from(std::sync::Arc::new(config))
}
async fn association(f: &Fixture) -> (TcpStream, SocketAddr) {
    let mut client = TcpStream::connect(f.mixed).await.unwrap();
    client
        .write_all(b"\x05\x01\x00\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
        .await
        .unwrap();
    let mut reply = [0; 12];
    client.read_exact(&mut reply).await.unwrap();
    assert_eq!(&reply[..6], &[5, 0, 5, 0, 0, 1]);
    let relay = SocketAddr::from((
        [reply[6], reply[7], reply[8], reply[9]],
        u16::from_be_bytes([reply[10], reply[11]]),
    ));
    (client, relay)
}
#[tokio::test]
async fn trojan_udp_close_releases_tls_worker_and_all_64_slots() {
    timeout(Duration::from_secs(12), async {
        let upstream=TcpListener::bind("127.0.0.1:0").await.unwrap();
        let f=Fixture::new(&format!("proxies: [{{name: edge, type: trojan, server: 127.0.0.1, port: {}, password: password, skip-cert-verify: true, udp: true}}]\nrules: ['MATCH,edge']",upstream.local_addr().unwrap().port())).await;
        let (mut control,relay)=association(&f).await;
        let client=tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        client.send_to(b"\x00\x00\x00\x01\x7f\x00\x00\x01\x00\x35hello",relay).await.unwrap();
        let (socket,_)=upstream.accept().await.unwrap(); let mut tls=tls_acceptor().accept(socket).await.unwrap();
        let mut request=[0;66]; tls.read_exact(&mut request).await.unwrap();
        assert_eq!(&request[56..],b"\r\n\x03\x01\x00\x00\x00\x00\x00\x00");
        let mut frame=[0;18]; tls.read_exact(&mut frame).await.unwrap();
        assert_eq!(&frame,b"\r\n\x01\x7f\x00\x00\x01\x00\x35\x00\x05\r\nhello");
        let entry=f.list().await.remove(0); assert_eq!(entry["phase"],"active");
        // Leave the worker inside a partial real frame read.
        tls.write_all(b"\x01\x7f").await.unwrap(); tls.flush().await.unwrap();
        assert_eq!(f.close(entry["id"].as_str().unwrap()).await.status(),200);
        eof(&mut control).await;
        let mut byte=[0]; assert!(matches!(tls.read(&mut byte).await,Ok(0)|Err(_)));
        f.wait(|e|e.is_empty()).await;
        let mut controls=Vec::new(); for _ in 0..64 { controls.push(association(&f).await.0); }
        let mut excess=TcpStream::connect(f.mixed).await.unwrap(); excess.write_all(b"\x05\x01\x00\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00").await.unwrap();
        let mut reply=[0;12]; excess.read_exact(&mut reply).await.unwrap(); assert_eq!(&reply[..4],&[5,0,5,1]);
        eof(&mut excess).await;
        let entries=f.wait(|v|v.len()==64).await;
        for entry in entries { assert_eq!(f.close(entry["id"].as_str().unwrap()).await.status(),200); }
        for control in &mut controls { eof(control).await; }
        f.wait(|e|e.is_empty()).await;
        let (mut last,_)=association(&f).await;
        let entry=f.list().await.remove(0); assert_eq!(f.close(entry["id"].as_str().unwrap()).await.status(),200); eof(&mut last).await;
        f.finish().await;
    }).await.unwrap();
}

#[tokio::test]
async fn routing_and_outbound_dns_are_cancellable_and_targets_are_not_recomputed() {
    use hickory_resolver::{
        config::{NameServerConfig, ResolverConfig},
        proto::{
            op::{Message, MessageType},
            rr::{
                RData, Record, RecordType,
                rdata::{A, AAAA},
            },
        },
    };
    timeout(Duration::from_secs(10),async {
        for route_dns in [true,false] {
            let dns_socket=tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let mut server=NameServerConfig::udp(dns_socket.local_addr().unwrap().ip()); server.connections[0].port=dns_socket.local_addr().unwrap().port();
            let dns=zc::dns::Dns::from_config(ResolverConfig::from_name_servers(vec![server])).unwrap();
            let rules=if route_dns { "rules: ['IP-CIDR,127.0.0.0/8,DIRECT','MATCH,REJECT']" } else { "rules: ['MATCH,DIRECT']" };
            let f=Fixture::configured(rules,|c|c.with_dns(dns)).await;
            let origin=TcpListener::bind("127.0.0.1:0").await.unwrap(); let port=origin.local_addr().unwrap().port();
            let mut client=TcpStream::connect(f.mixed).await.unwrap();
            client.write_all(format!("CONNECT stalled.example.:{port} HTTP/1.1\r\nHost: stalled.example.:{port}\r\n\r\n").as_bytes()).await.unwrap();
            let mut packet=[0;4096]; for _ in 0..2 { dns_socket.recv_from(&mut packet).await.unwrap(); }
            let entry=f.list().await.remove(0);
            assert_eq!(entry["phase"],if route_dns {"routing"} else {"connecting"});
            assert_eq!(entry["target"]["host"],"stalled.example.");
            assert_eq!(entry.get("proxy").is_some(),!route_dns);
            assert_eq!(f.close(entry["id"].as_str().unwrap()).await.status(),200); eof(&mut client).await;
            f.wait(|e|e.is_empty()).await;
            if route_dns {
                let mut client=TcpStream::connect(f.mixed).await.unwrap();
                client.write_all(format!("CONNECT pinned.example.:{port} HTTP/1.1\r\nHost: pinned.example.:{port}\r\n\r\n").as_bytes()).await.unwrap();
                for _ in 0..2 {
                    let (count,peer)=dns_socket.recv_from(&mut packet).await.unwrap(); let mut message=Message::from_vec(&packet[..count]).unwrap();
                    let query=message.queries[0].clone(); assert_eq!(query.name().to_string(),"pinned.example.");
                    message.metadata.message_type=MessageType::Response; message.metadata.recursion_available=true;
                    let answer=match query.query_type() { RecordType::A=>RData::A(A(std::net::Ipv4Addr::LOCALHOST)),RecordType::AAAA=>RData::AAAA(AAAA(std::net::Ipv6Addr::LOCALHOST)),_=>panic!("unexpected query") };
                    message.answers.push(Record::from_rdata(query.name().clone(),0,answer));
                    dns_socket.send_to(&message.to_vec().unwrap(),peer).await.unwrap();
                }
                let (_peer,_)=origin.accept().await.unwrap(); assert!(header(&mut client).await.starts_with("HTTP/1.1 200"));
                let entry=f.list().await.remove(0); assert_eq!(entry["target"]["host"],"pinned.example."); assert_eq!(entry["routed_target"]["host"],"127.0.0.1"); assert_eq!(entry["rule"]["index"],0);
                // The DNS TTL is zero: inspecting a stored route cannot depend on another lookup.
                for _ in 0..3 { assert_eq!(f.list().await[0],entry); }
                assert!(dns_socket.try_recv_from(&mut packet).is_err());
            }
            f.finish().await;
        }
    }).await.unwrap();
}

#[tokio::test]
async fn registry_shares_the_1024_task_admission_bound_without_reusing_ids() {
    timeout(Duration::from_secs(12), async {
        let f = Fixture::new("rules: ['MATCH,DIRECT']").await;
        let mut clients = Vec::new();
        for _ in 0..1024 {
            clients.push(TcpStream::connect(f.mixed).await.unwrap());
        }
        let entries = f.wait(|v| v.len() == 1024).await;
        let ids: std::collections::BTreeSet<_> =
            entries.iter().map(|e| e["id"].as_str().unwrap()).collect();
        assert_eq!(ids.len(), 1024);
        let extra = TcpStream::connect(f.mixed).await.unwrap();
        assert_eq!(f.list().await.len(), 1024);
        let entry = entries
            .iter()
            .find(|e| e["source"] == clients[0].local_addr().unwrap().to_string())
            .unwrap();
        assert_eq!(f.close(entry["id"].as_str().unwrap()).await.status(), 200);
        eof(&mut clients[0]).await;
        let next = f
            .wait(|v| {
                v.len() == 1024
                    && v.iter()
                        .any(|e| e["source"] == extra.local_addr().unwrap().to_string())
            })
            .await;
        let admitted = next
            .iter()
            .find(|e| e["source"] == extra.local_addr().unwrap().to_string())
            .unwrap();
        assert!(!ids.contains(admitted["id"].as_str().unwrap()));
        assert!(admitted["id"].as_str().unwrap().ends_with("-1025"));
        f.finish().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn connection_json_budget_accepts_exactly_four_mib_and_rejects_the_next_name_byte() {
    timeout(Duration::from_secs(20), async {
        const CAP: usize = 4 * 1024 * 1024;
        let origin = TcpListener::bind("127.0.0.1:0").await.unwrap();
        assert_eq!(origin.local_addr().unwrap().port().to_string().len(), 5);
        let mut rule = "MATCH";
        let mut base_size = 0;
        for candidate in ["MATCH", "IP-CIDR,127.0.0.0/8"] {
            let f = Fixture::new(&format!(
                "proxies: [{{name: x, type: direct}}]\nrules: ['{candidate},x']"
            ))
            .await;
            let (client, peer) = connect(&f, &origin).await;
            assert_eq!(client.local_addr().unwrap().port().to_string().len(), 5);
            let response = f.request(reqwest::Method::GET, "/connections").await;
            assert_eq!(response.status(), 200);
            base_size = response.bytes().await.unwrap().len();
            f.finish().await;
            drop((client, peer));
            if (CAP - base_size).is_multiple_of(2) {
                rule = candidate;
                break;
            }
        }
        assert!((CAP - base_size).is_multiple_of(2));
        // The same name appears in rule.target and proxy.name; all socket ports have five digits.
        let exact_name_len = 1 + (CAP - base_size) / 2;
        for (name_len, expected_size) in [
            (exact_name_len - 1, CAP - 2),
            (exact_name_len, CAP),
            (exact_name_len + 1, CAP + 2),
        ] {
            let name = "n".repeat(name_len);
            let f = Fixture::new(&format!(
                "proxies: [{{name: {name}, type: direct}}]\nrules: ['{rule},{name}']"
            ))
            .await;
            let (client, peer) = connect(&f, &origin).await;
            assert_eq!(client.local_addr().unwrap().port().to_string().len(), 5);
            let response = f.request(reqwest::Method::GET, "/connections").await;
            if expected_size <= CAP {
                assert_eq!(response.status(), 200);
                let bytes = response.bytes().await.unwrap();
                assert_eq!(bytes.len(), expected_size);
                let value: Value = serde_json::from_slice(&bytes).unwrap();
                assert_eq!(value["connections"].as_array().unwrap().len(), 1);
            } else {
                assert_eq!(response.status(), 500);
                assert_eq!(
                    response.json::<Value>().await.unwrap(),
                    json!({"error":"Response Too Large"})
                );
            }
            f.finish().await;
            drop((client, peer));
        }
    })
    .await
    .unwrap();
}
