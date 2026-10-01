// Included only by observability's unit tests; injection never enters production.
use super::*;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt, symlink};

const TEST: &str =
    "observability::initialization_tests::cold_log_initialization_preserves_lock_contract";

#[tokio::test]
async fn cold_log_initialization_preserves_lock_contract() {
    if let Some(case) = std::env::var_os("ZC_LOG_INIT_CASE") {
        let case = case.to_str().unwrap();
        let path = PathBuf::from(std::env::var_os("ZC_LOG_INIT_ROOT").unwrap());
        let dir = SecureDir::open(&path).unwrap();
        let lock = Arc::new(dir.lock("zc.lock", Duration::from_secs(1)).unwrap());
        let held = (case == "startup-contention")
            .then(|| dir.lock("zc.log.lock", Duration::from_secs(1)).unwrap());
        let started = Instant::now();
        let result = Evidence::start(&path, "0123456789abcdef0123456789abcdef", lock);
        match case {
            "expired" | "file-eio" | "directory-eio" | "startup-contention" => {
                let error = result
                    .err()
                    .expect("startup must reject unavailable log lock");
                let error = error.downcast_ref::<io::Error>().unwrap();
                if case.ends_with("eio") {
                    assert_eq!(error.raw_os_error(), Some(5));
                } else {
                    assert_eq!(error.kind(), io::ErrorKind::TimedOut);
                    assert!(started.elapsed() >= Duration::from_secs(1));
                    assert!(started.elapsed() < Duration::from_secs(2));
                }
                assert!(!path.join("zc.log").exists());
                assert!(!path.join(EXIT_MARKER).exists());
            }
            "symlink" | "hardlink" | "permissions" => {
                assert!(result.is_err(), "unsafe log lock accepted");
                assert!(!path.join("zc.log").exists());
                assert_eq!(std::fs::read(path.join("sentinel")).unwrap(), b"preserve");
                assert!(std::fs::symlink_metadata(path.join("zc.log.lock")).is_ok());
            }
            _ => {
                let evidence = result.expect("cold log initialization must tolerate a 75ms sync");
                if case == "hot-contention" {
                    let guard = dir.lock("zc.log.lock", Duration::from_secs(1)).unwrap();
                    let started = Instant::now();
                    let error = evidence.ready().unwrap_err();
                    assert_eq!(
                        error.downcast_ref::<io::Error>().unwrap().kind(),
                        io::ErrorKind::TimedOut
                    );
                    assert!(started.elapsed() >= Duration::from_millis(50));
                    assert!(started.elapsed() < Duration::from_millis(500));
                    drop(guard);
                }
                if case == "hot-invalid" {
                    let lock_path = path.join("zc.log.lock");
                    std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o666))
                        .unwrap();
                    assert!(evidence.ready().is_err(), "unsafe hot log lock accepted");
                    assert_eq!(
                        std::fs::metadata(&lock_path).unwrap().permissions().mode() & 0o777,
                        0o666
                    );
                    std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o600))
                        .unwrap();
                }
                evidence.ready().unwrap();
                evidence.finish("stop_request", None).await;
                let events: Vec<Value> = std::fs::read_to_string(path.join("zc.log"))
                    .unwrap()
                    .lines()
                    .map(|line| serde_json::from_str(line).unwrap())
                    .collect();
                assert_eq!(events.first().unwrap()["event"], "daemon_starting");
                assert!(events.iter().any(|event| event["event"] == "daemon_ready"));
                assert_eq!(events.last().unwrap()["event"], "daemon_stopped");
                assert!(!path.join(EXIT_MARKER).exists());
            }
        }
        drop(held);
        std::fs::write(path.join("completed"), case).unwrap();
        return;
    }

    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().canonicalize().unwrap();
    let library = home.join(if cfg!(target_os = "macos") {
        "sync.dylib"
    } else {
        "sync.so"
    });
    let mut cc = Command::new("cc");
    cc.args(["-std=c11", "-Wall", "-Wextra", "-Werror"]);
    if cfg!(target_os = "macos") {
        cc.arg("-dynamiclib");
    } else {
        cc.args(["-shared", "-fPIC"]);
    }
    cc.arg(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/support/observability_init_sync.c"
    ))
    .arg("-o")
    .arg(&library);
    if cfg!(target_os = "linux") {
        cc.arg("-ldl");
    }
    let output = cc
        .output()
        .expect("cc is required for log initialization injection");
    assert!(output.status.success(), "{output:?}");
    for case in [
        "precreated",
        "slow",
        "expired",
        "file-eio",
        "directory-eio",
        "hot-contention",
        "hot-invalid",
        "startup-contention",
        "symlink",
        "hardlink",
        "permissions",
    ] {
        let root = home.join(case);
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
        let dir = SecureDir::open(&root).unwrap();
        if matches!(
            case,
            "precreated" | "hot-contention" | "hot-invalid" | "startup-contention"
        ) {
            drop(dir.lock("zc.log.lock", Duration::from_secs(1)).unwrap());
        }
        if matches!(case, "symlink" | "hardlink" | "permissions") {
            dir.atomic_write("sentinel", b"preserve").unwrap();
            match case {
                "symlink" => symlink(root.join("sentinel"), root.join("zc.log.lock")).unwrap(),
                "hardlink" => {
                    std::fs::hard_link(root.join("sentinel"), root.join("zc.log.lock")).unwrap()
                }
                _ => {
                    dir.atomic_write("zc.log.lock", b"preserve").unwrap();
                    std::fs::set_permissions(
                        root.join("zc.log.lock"),
                        std::fs::Permissions::from_mode(0o666),
                    )
                    .unwrap();
                }
            }
        }
        let log_path = root.join("child-output");
        let log = std::fs::File::create(&log_path).unwrap();
        let mut child = Reap(
            Command::new(std::env::current_exe().unwrap())
                .args(["--exact", TEST, "--nocapture", "--test-threads=1"])
                .env("HOME", &root)
                .env("XDG_RUNTIME_DIR", &root)
                .env("ZC_LOG_INIT_ROOT", &root)
                .env("ZC_LOG_INIT_CASE", case)
                .env(
                    if cfg!(target_os = "macos") {
                        "DYLD_INSERT_LIBRARIES"
                    } else {
                        "LD_PRELOAD"
                    },
                    &library,
                )
                .stdout(Stdio::from(log.try_clone().unwrap()))
                .stderr(Stdio::from(log))
                .spawn()
                .unwrap(),
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        let status = loop {
            if let Some(status) = child.0.try_wait().unwrap() {
                break status;
            }
            assert!(
                Instant::now() < deadline,
                "log initialization fixture timed out: {case}"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        let output = std::fs::read_to_string(log_path).unwrap();
        assert!(status.success(), "{case}: {status}\n{output}");
        assert_eq!(
            std::fs::read_to_string(root.join("completed")).unwrap(),
            case
        );
        let markers = std::fs::read_to_string(root.join("sync-markers")).unwrap_or_default();
        let expected = match case {
            "slow" | "expired" | "directory-eio" => "FD",
            "file-eio" => "F",
            _ => "",
        };
        assert_eq!(
            markers, expected,
            "injection scope or durability changed: {case}"
        );
        eprintln!("Log initialization fixture {case}: verified");
    }
}
