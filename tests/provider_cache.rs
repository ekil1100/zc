use std::{
    collections::BTreeMap,
    path::Path,
    time::{Duration, SystemTime},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};
use zc::{
    config::{self, ProviderSyncPolicy},
    fsutil::SecureDir,
};

fn root(dir: &tempfile::TempDir) -> SecureDir {
    SecureDir::open_owned_absolute(&dir.path().canonicalize().unwrap(), false).unwrap()
}
fn source(url: &str, path: &str) -> String {
    format!(
        "rule-providers: {{list: {{type: http, behavior: domain, path: '{path}', url: '{url}', interval: 1}}}}\nrules: ['RULE-SET,list,DIRECT', 'MATCH,REJECT']\n"
    )
}
fn stale(path: &Path) {
    std::fs::File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(10))
        .unwrap();
}
async fn server(status: u16, body: Vec<u8>) -> (String, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/rules", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            request.push(stream.read_u8().await.unwrap());
            assert!(request.len() <= 16 * 1024);
        }
        let header = format!(
            "HTTP/1.1 {status} Response\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        if stream.write_all(header.as_bytes()).await.is_ok() {
            let _ = stream.write_all(&body).await;
        }
    });
    (url, task)
}

#[tokio::test]
async fn fresh_cache_is_offline_and_stale_cache_refreshes_atomically() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("rules");
    std::fs::write(&path, b"old.example\n").unwrap();
    let (url, peer) = server(200, b"new.example\n".to_vec()).await;
    let source = source(&url, "rules");
    let assets = config::sync_http_assets(
        &source,
        &root(&dir),
        ProviderSyncPolicy::Eager,
        &BTreeMap::new(),
        None,
    )
    .await
    .unwrap();
    assert_eq!(assets["rules"], b"old.example\n");
    assert!(!peer.is_finished());
    stale(&path);
    let frozen = assets;
    let assets = config::sync_http_assets(
        &source,
        &root(&dir),
        ProviderSyncPolicy::Eager,
        &BTreeMap::new(),
        None,
    )
    .await
    .unwrap();
    peer.await.unwrap();
    assert_eq!(assets["rules"], b"new.example\n");
    assert_eq!(std::fs::read(&path).unwrap(), b"new.example\n");
    assert_eq!(frozen["rules"], b"old.example\n");
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(source, self::source(&url, "rules"));
}

#[tokio::test]
async fn missing_cache_downloads_and_creates_private_parents() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let (url, peer) = server(200, b"download.example\n".to_vec()).await;
    let source = source(&url, "nested/rules");
    let assets = config::sync_http_assets(
        &source,
        &root(&dir),
        ProviderSyncPolicy::MissingOnly,
        &BTreeMap::new(),
        None,
    )
    .await
    .unwrap();
    peer.await.unwrap();
    assert_eq!(assets["nested/rules"], b"download.example\n");
    assert_eq!(
        std::fs::metadata(dir.path().join("nested"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        std::fs::read(dir.path().join("nested/rules")).unwrap(),
        assets["nested/rules"]
    );
    assert_eq!(
        std::fs::read_dir(dir.path().join("nested"))
            .unwrap()
            .count(),
        2
    );
}

#[tokio::test]
async fn ordinary_http_failure_uses_only_existing_valid_cache() {
    for (cache, succeeds) in [
        (Some(b"cached.example\n".as_slice()), true),
        (Some(b"payload: [unterminated".as_slice()), false),
        (None, false),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rules");
        if let Some(bytes) = cache {
            std::fs::write(&path, bytes).unwrap();
            stale(&path);
        }
        let (url, peer) = server(503, b"service unavailable".to_vec()).await;
        let result = config::sync_http_assets(
            &source(&url, "rules"),
            &root(&dir),
            ProviderSyncPolicy::Eager,
            &BTreeMap::new(),
            None,
        )
        .await;
        peer.await.unwrap();
        assert_eq!(result.is_ok(), succeeds);
        if succeeds {
            assert_eq!(result.unwrap()["rules"], cache.unwrap());
        }
        assert_eq!(std::fs::read(&path).ok().as_deref(), cache);
    }
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("rules");
    std::fs::write(&path, b"cached.example\n").unwrap();
    stale(&path);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    drop(listener);
    let assets = config::sync_http_assets(
        &source(&url, "rules"),
        &root(&dir),
        ProviderSyncPolicy::Eager,
        &BTreeMap::new(),
        None,
    )
    .await
    .unwrap();
    assert_eq!(assets["rules"], b"cached.example\n");
}

#[tokio::test]
async fn malformed_or_oversized_download_never_replaces_or_falls_back_to_cache() {
    for body in [
        b"payload: [unterminated".to_vec(),
        vec![b'x'; 16 * 1024 * 1024 + 1],
        vec![0xff],
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rules");
        std::fs::write(&path, b"valid.example\n").unwrap();
        stale(&path);
        let (url, peer) = server(200, body).await;
        assert!(
            config::sync_http_assets(
                &source(&url, "rules"),
                &root(&dir),
                ProviderSyncPolicy::Eager,
                &BTreeMap::new(),
                None
            )
            .await
            .is_err()
        );
        peer.await.unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"valid.example\n");
    }
}

#[tokio::test]
async fn stale_invalid_cache_can_be_repaired_but_fresh_invalid_cache_is_authoritative() {
    for oversized in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rules");
        let bytes = if oversized {
            vec![b'x'; 16 * 1024 * 1024 + 1]
        } else {
            b"payload: [unterminated".to_vec()
        };
        std::fs::write(&path, &bytes).unwrap();
        let (url, peer) = server(200, b"repaired.example\n".to_vec()).await;
        let input = source(&url, "rules");
        assert!(
            config::sync_http_assets(
                &input,
                &root(&dir),
                ProviderSyncPolicy::MissingOnly,
                &BTreeMap::new(),
                None
            )
            .await
            .is_err()
        );
        assert!(!peer.is_finished());
        stale(&path);
        let assets = config::sync_http_assets(
            &input,
            &root(&dir),
            ProviderSyncPolicy::Eager,
            &BTreeMap::new(),
            None,
        )
        .await
        .unwrap();
        peer.await.unwrap();
        assert_eq!(assets["rules"], b"repaired.example\n");
    }
}

#[tokio::test]
async fn unsafe_caches_and_source_symlink_escapes_fail_without_io_outside_root() {
    use std::os::unix::fs::symlink;
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let external = outside.path().join("rules");
    std::fs::write(&external, b"outside.example\n").unwrap();
    symlink(&external, dir.path().join("link")).unwrap();
    symlink(outside.path(), dir.path().join("escape")).unwrap();
    std::fs::create_dir(dir.path().join("directory")).unwrap();
    assert!(
        std::process::Command::new("mkfifo")
            .arg(dir.path().join("fifo"))
            .status()
            .unwrap()
            .success()
    );
    std::fs::hard_link(&external, dir.path().join("hardlink")).unwrap();
    for path in [
        "link",
        "escape/rules",
        "escape/new",
        "directory",
        "fifo",
        "hardlink",
        "../rules",
        "/absolute/rules",
    ] {
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            config::sync_http_assets(
                &source("http://127.0.0.1:1/", path),
                &root(&dir),
                ProviderSyncPolicy::Eager,
                &BTreeMap::new(),
                None,
            ),
        )
        .await
        .unwrap();
        assert!(result.is_err(), "accepted {path}");
    }
    assert_eq!(std::fs::read(external).unwrap(), b"outside.example\n");
    assert!(!outside.path().join("new").exists());
}

#[tokio::test]
async fn publication_failure_is_not_reported_as_cache_fallback() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("rules");
    std::fs::write(&path, b"old.example\n").unwrap();
    stale(&path);
    // The safe atomic writer's lock is an unusable directory, not a mock error.
    std::fs::create_dir(dir.path().join(".provider-cache.lock")).unwrap();
    let (url, peer) = server(200, b"new.example\n".to_vec()).await;
    let result = config::sync_http_assets(
        &source(&url, "rules"),
        &root(&dir),
        ProviderSyncPolicy::Eager,
        &BTreeMap::new(),
        None,
    )
    .await;
    peer.await.unwrap();
    assert!(result.is_err());
    assert_eq!(std::fs::read(path).unwrap(), b"old.example\n");
}

#[tokio::test]
async fn delayed_headers_allow_cancellation_without_publishing_or_mutating_inputs() {
    let dir = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let source = source(
        &format!("http://{}/", listener.local_addr().unwrap()),
        "rules",
    );
    let original = source.clone();
    let assets = BTreeMap::new();
    let root = root(&dir);
    let sync = config::sync_http_assets(&source, &root, ProviderSyncPolicy::Eager, &assets, None);
    tokio::pin!(sync);
    let accepted = tokio::select! {
        result = &mut sync => panic!("completed before headers: {result:?}"),
        accepted = listener.accept() => accepted.unwrap(),
    };
    assert!(
        tokio::time::timeout(Duration::from_millis(50), &mut sync)
            .await
            .is_err()
    );
    drop(accepted);
    assert!(!dir.path().join("rules").exists());
    assert_eq!(source, original);
    assert!(assets.is_empty());
}

#[tokio::test]
async fn held_source_root_cannot_be_redirected_by_a_symlink_swap() {
    use std::os::unix::fs::symlink;
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let original = dir.path().join("source");
    std::fs::create_dir(&original).unwrap();
    let held = SecureDir::open_owned_absolute(&original.canonicalize().unwrap(), false).unwrap();
    let moved = dir.path().join("held");
    std::fs::rename(&original, &moved).unwrap();
    symlink(outside.path(), &original).unwrap();
    let (url, peer) = server(200, b"held.example\n".to_vec()).await;
    let assets = config::sync_http_assets(
        &source(&url, "nested/rules"),
        &held,
        ProviderSyncPolicy::Eager,
        &BTreeMap::new(),
        None,
    )
    .await
    .unwrap();
    peer.await.unwrap();
    assert_eq!(assets["nested/rules"], b"held.example\n");
    assert_eq!(
        std::fs::read(moved.join("nested/rules")).unwrap(),
        b"held.example\n"
    );
    assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 0);
}

#[tokio::test]
async fn provider_sync_enforces_count_aggregate_wire_and_candidate_entry_budgets() {
    let dir = tempfile::tempdir().unwrap();
    let source = format!(
        "rule-providers:\n{}",
        (0..4097)
            .map(|i| format!(
                "  p{i}: {{type: http, behavior: domain, path: p{i}, url: 'http://127.0.0.1:1/'}}\n"
            ))
            .collect::<String>()
    );
    assert!(
        config::sync_http_assets(
            &source,
            &root(&dir),
            ProviderSyncPolicy::Eager,
            &BTreeMap::new(),
            None
        )
        .await
        .unwrap_err()
        .to_string()
        .contains("count limit")
    );
    let (url, peer) = server(200, "example.com\n".repeat(262145).into_bytes()).await;
    assert!(
        config::sync_http_assets(
            &self::source(&url, "rules"),
            &root(&dir),
            ProviderSyncPolicy::Eager,
            &BTreeMap::new(),
            None
        )
        .await
        .unwrap_err()
        .to_string()
        .contains("count limit")
    );
    peer.await.unwrap();
    assert!(!dir.path().join("rules").exists());
    // Four bounded local sources reserve the entire aggregate window, even if
    // their content is only comments. No fifth remote body may be downloaded.
    let mut assets = BTreeMap::new();
    let mut declarations = String::from("rule-providers:\n");
    for i in 0..4 {
        assets.insert(
            format!("p{i}"),
            format!("#{}", "x".repeat(16 * 1024 * 1024 - 1)).into_bytes(),
        );
        declarations.push_str(&format!(
            "  p{i}: {{type: file, behavior: domain, path: p{i}}}\n"
        ));
    }
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    declarations.push_str(&format!(
        "  remote: {{type: http, behavior: domain, path: remote, url: 'http://{}/'}}\n",
        listener.local_addr().unwrap()
    ));
    let error = config::sync_http_assets(
        &declarations,
        &root(&dir),
        ProviderSyncPolicy::Eager,
        &assets,
        None,
    )
    .await
    .unwrap_err();
    assert!(
        error.to_string().contains("aggregate source bytes limit"),
        "{error}"
    );
    assert!(!dir.path().join("remote").exists());
    assert!(
        tokio::time::timeout(Duration::from_millis(30), listener.accept())
            .await
            .is_err()
    );
    assert_eq!(assets.len(), 4);
}

#[tokio::test]
async fn cache_publication_rejects_a_destination_replaced_during_download() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("rules");
    std::fs::write(&path, b"old.example\n").unwrap();
    stale(&path);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    let input = source(&url, "rules");
    let root = root(&dir);
    let empty = BTreeMap::new();
    let sync = config::sync_http_assets(&input, &root, ProviderSyncPolicy::Eager, &empty, None);
    tokio::pin!(sync);
    let (mut peer, _) = tokio::select! {
        result = &mut sync => panic!("completed before response: {result:?}"),
        accepted = listener.accept() => accepted.unwrap(),
    };
    std::fs::remove_file(&path).unwrap();
    std::fs::create_dir(&path).unwrap();
    peer.write_all(
        b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnew.example\n",
    )
    .await
    .unwrap();
    assert!(sync.await.is_err());
    assert!(path.is_dir());
    assert!(!std::fs::read_dir(dir.path()).unwrap().any(|entry| {
        entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".write-")
    }));
}

#[tokio::test]
async fn delayed_headers_obey_real_total_deadline_before_valid_cache_fallback() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("rules");
    std::fs::write(&path, b"old.example\n").unwrap();
    stale(&path);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let input = source(
        &format!("http://{}/", listener.local_addr().unwrap()),
        "rules",
    );
    let root = root(&dir);
    let empty = BTreeMap::new();
    let sync = config::sync_http_assets(&input, &root, ProviderSyncPolicy::Eager, &empty, None);
    tokio::pin!(sync);
    let accepted = tokio::select! {
        result = &mut sync => panic!("completed before response: {result:?}"),
        accepted = listener.accept() => accepted.unwrap(),
    };
    let start = std::time::Instant::now();
    let result = tokio::time::timeout(Duration::from_secs(35), &mut sync)
        .await
        .unwrap()
        .unwrap();
    assert!(start.elapsed() >= Duration::from_secs(29));
    assert_eq!(result["rules"], b"old.example\n");
    assert_eq!(std::fs::read(path).unwrap(), b"old.example\n");
    drop(accepted);
}

#[tokio::test]
async fn existing_provider_filesystem_aliases_are_rejected_before_publication() {
    use std::os::unix::fs::MetadataExt;
    for (name, alias) in [("rules", "RULES"), ("café", "cafe\u{301}")] {
        for local in [true, false] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join(name);
            std::fs::write(&path, b"old.example\n").unwrap();
            let Ok(metadata) = std::fs::metadata(dir.path().join(alias)) else {
                continue;
            };
            if metadata.ino() != std::fs::metadata(&path).unwrap().ino() {
                continue;
            }
            stale(&path);
            let (url, peer) = server(200, b"new.example\n".to_vec()).await;
            let (url2, peer2) = server(200, b"other.example\n".to_vec()).await;
            let first = if local {
                format!("type: file, behavior: domain, path: '{name}'")
            } else {
                format!("type: http, behavior: domain, path: '{name}', url: '{url}', interval: 1")
            };
            let input = format!(
                "rule-providers: {{a: {{{first}}}, b: {{type: http, behavior: domain, path: '{alias}', url: '{url2}', interval: 1}}}}\nrules: ['RULE-SET,a,DIRECT', 'RULE-SET,b,REJECT']\n"
            );
            let assets = if local {
                BTreeMap::from([(name.into(), b"old.example\n".to_vec())])
            } else {
                BTreeMap::new()
            };
            let result = config::sync_http_assets(
                &input,
                &root(&dir),
                ProviderSyncPolicy::Eager,
                &assets,
                None,
            )
            .await;
            peer.abort();
            peer2.abort();
            assert_eq!(
                std::fs::read(&path).unwrap(),
                b"old.example\n",
                "overwritten provider alias {alias}, local={local}"
            );
            assert!(
                result.is_err(),
                "accepted provider alias {alias}, local={local}"
            );
        }
    }
}

#[tokio::test]
async fn later_malformed_provider_preserves_every_old_cache() {
    let dir = tempfile::tempdir().unwrap();
    for path in ["a", "b"] {
        std::fs::write(dir.path().join(path), b"old.example\n").unwrap();
        stale(&dir.path().join(path));
    }
    let (url, peer) = server(200, b"new.example\n".to_vec()).await;
    let (bad_url, bad_peer) = server(200, b"payload: [unterminated".to_vec()).await;
    let input = format!(
        "rule-providers: {{a: {{type: http, behavior: domain, path: a, url: '{url}', interval: 1}}, b: {{type: http, behavior: domain, path: b, url: '{bad_url}', interval: 1}}}}\nrules: ['RULE-SET,a,DIRECT', 'RULE-SET,b,REJECT']\n"
    );
    let original = input.clone();
    let assets = BTreeMap::new();
    let result = config::sync_http_assets(
        &input,
        &root(&dir),
        ProviderSyncPolicy::Eager,
        &assets,
        None,
    )
    .await;
    peer.await.unwrap();
    bad_peer.await.unwrap();
    assert!(result.is_err());
    for path in ["a", "b"] {
        assert_eq!(
            std::fs::read(dir.path().join(path)).unwrap(),
            b"old.example\n"
        );
    }
    assert_eq!(input, original);
    assert!(assets.is_empty());
}

#[tokio::test]
async fn http_await_replacements_do_not_escape_held_root_or_overwrite_providers() {
    use std::os::unix::fs::symlink;
    for kind in [
        "symlink", "hardlink", "fifo", "ancestor", "root", "local", "writable",
    ] {
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let original = dir.path().join("root");
        std::fs::create_dir(&original).unwrap();
        std::fs::create_dir(original.join("nested")).unwrap();
        let cache = original.join("nested/rules");
        std::fs::write(&cache, b"old.example\n").unwrap();
        stale(&cache);
        let external = outside.path().join("rules");
        std::fs::write(&external, b"outside.example\n").unwrap();
        std::fs::write(original.join("local"), b"local.example\n").unwrap();
        let root =
            SecureDir::open_owned_absolute(&original.canonicalize().unwrap(), false).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let input = format!(
            "rule-providers: {{p: {{type: http, behavior: domain, path: nested/rules, url: 'http://{}/', interval: 1}}, local: {{type: file, behavior: domain, path: local}}}}\nrules: ['RULE-SET,p,DIRECT']\n",
            listener.local_addr().unwrap()
        );
        let assets = BTreeMap::from([("local".into(), b"local.example\n".to_vec())]);
        let sync =
            config::sync_http_assets(&input, &root, ProviderSyncPolicy::Eager, &assets, None);
        tokio::pin!(sync);
        let (mut peer, _) = tokio::select! {
            result = &mut sync => panic!("completed before response: {result:?}"),
            accepted = listener.accept() => accepted.unwrap(),
        };
        let mut request = Vec::new();
        tokio::select! {
            result = &mut sync => panic!("completed before request: {result:?}"),
            _ = async {
                while !request.ends_with(b"\r\n\r\n") {
                    request.push(peer.read_u8().await.unwrap());
                    assert!(request.len() <= 16 * 1024);
                }
            } => (),
        }
        match kind {
            "ancestor" => {
                std::fs::rename(original.join("nested"), original.join("moved")).unwrap();
                symlink(outside.path(), original.join("nested")).unwrap();
            }
            "root" => {
                std::fs::rename(&original, dir.path().join("held")).unwrap();
                symlink(outside.path(), &original).unwrap();
            }
            "writable" => {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&cache, std::fs::Permissions::from_mode(0o666)).unwrap();
            }
            _ => {
                std::fs::remove_file(&cache).unwrap();
                match kind {
                    "symlink" => symlink(&external, &cache).unwrap(),
                    "hardlink" => std::fs::hard_link(&external, &cache).unwrap(),
                    "fifo" => assert!(
                        std::process::Command::new("mkfifo")
                            .arg(&cache)
                            .status()
                            .unwrap()
                            .success()
                    ),
                    "local" => std::fs::rename(original.join("local"), &cache).unwrap(),
                    _ => unreachable!(),
                }
            }
        }
        peer.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnew.example\n",
        )
        .await
        .unwrap();
        let result = tokio::time::timeout(Duration::from_secs(2), sync)
            .await
            .unwrap();
        assert_eq!(
            result.is_ok(),
            kind == "root",
            "replacement {kind}: {result:?}"
        );
        assert_eq!(std::fs::read(&external).unwrap(), b"outside.example\n");
        if kind == "local" {
            assert_eq!(std::fs::read(&cache).unwrap(), b"local.example\n");
        }
        if kind == "root" {
            assert_eq!(
                std::fs::read(dir.path().join("held/nested/rules")).unwrap(),
                b"new.example\n"
            );
        }
    }
}

#[tokio::test]
async fn newly_published_cache_alias_is_not_overwritten() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("probe"), b"probe").unwrap();
    if !dir.path().join("PROBE").exists() {
        return;
    }
    let (url, peer) = server(200, b"first.example\n".to_vec()).await;
    let (url2, peer2) = server(200, b"second.example\n".to_vec()).await;
    let input = format!(
        "rule-providers: {{a: {{type: http, behavior: domain, path: rules, url: '{url}'}}, b: {{type: http, behavior: domain, path: RULES, url: '{url2}'}}}}\nrules: ['RULE-SET,a,DIRECT', 'RULE-SET,b,REJECT']\n"
    );
    let result = config::sync_http_assets(
        &input,
        &root(&dir),
        ProviderSyncPolicy::Eager,
        &BTreeMap::new(),
        None,
    )
    .await;
    peer.abort();
    peer2.abort();
    assert!(result.is_err(), "accepted newly published cache alias");
    assert_eq!(
        std::fs::read(dir.path().join("rules")).unwrap(),
        b"first.example\n"
    );
}

#[tokio::test]
async fn cache_cannot_replace_filesystem_alias_of_publication_lock() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("probe"), b"probe").unwrap();
    if !dir.path().join("PROBE").exists() {
        return;
    }
    let (url, peer) = server(200, b"new.example\n".to_vec()).await;
    let result = config::sync_http_assets(
        &source(&url, ".PROVIDER-CACHE.LOCK"),
        &root(&dir),
        ProviderSyncPolicy::Eager,
        &BTreeMap::new(),
        None,
    )
    .await;
    peer.abort();
    assert!(result.is_err(), "accepted publication lock alias");
    assert_eq!(
        std::fs::read(dir.path().join(".provider-cache.lock")).unwrap(),
        b""
    );
    assert!(
        config::sync_http_assets(
            &source("http://127.0.0.1:1/", ".PROVIDER-CACHE.LOCK"),
            &root(&dir),
            ProviderSyncPolicy::MissingOnly,
            &BTreeMap::new(),
            None
        )
        .await
        .is_err()
    );
}
