use std::{
    process::{Command, Output},
    time::{Duration, Instant},
};

fn command() -> Command {
    Command::new(env!("CARGO_BIN_EXE_zc"))
}

fn output(args: &[&str]) -> Output {
    let mut cmd = command();
    cmd.args(args);
    output_command(cmd)
}

fn output_command(mut command: Command) -> Output {
    let mut child = command
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if child.try_wait().unwrap().is_some() {
            return child.wait_with_output().unwrap();
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            let _ = child.wait();
            panic!("CLI did not exit within five seconds");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn help_version_and_required_explicit_start_arguments() {
    let help = output(&["--help"]);
    assert!(help.status.success());
    let help = String::from_utf8(help.stdout).unwrap();
    assert!(help.contains("experimental TCP"));
    let version = output(&["--version"]);
    assert!(version.status.success());
    assert_eq!(version.stdout, b"zc 1.0.1-rust.1\n");
    for args in [
        vec!["start"],
        vec!["start", "--port", "12345", "--foreground"],
        vec!["start", "-c", "missing.yaml", "--foreground"],
        vec!["start", "-c", "missing.yaml", "--port", "12345"],
        vec!["start", "-c", "missing.yaml", "--port", "0", "--foreground"],
        vec!["status"],
        vec!["--unknown"],
    ] {
        let result = output(&args);
        assert_eq!(
            result.status.code(),
            Some(2),
            "{args:?}: {:?}",
            result.stderr
        );
    }
}

#[test]
fn configuration_files_are_bounded_regular_and_errors_do_not_echo_source() {
    let dir = tempfile::tempdir().unwrap();
    let invalid = dir.path().join("invalid.yaml");
    std::fs::write(&invalid, "password: TOP_SECRET_SOURCE_MARKER\ninvalid: [\n").unwrap();
    let oversized = dir.path().join("large.yaml");
    std::fs::File::create(&oversized)
        .unwrap()
        .set_len(16 * 1024 * 1024 + 1)
        .unwrap();
    let invalid_utf8 = dir.path().join("utf8.yaml");
    std::fs::write(&invalid_utf8, [255]).unwrap();
    let missing = dir.path().join("missing.yaml");
    for (path, message) in [
        (dir.path(), "regular file"),
        (oversized.as_path(), "16 MiB"),
        (invalid.as_path(), "configuration"),
        (invalid_utf8.as_path(), "UTF-8"),
        (missing.as_path(), "configuration"),
    ] {
        let result = output(&[
            "start",
            "-c",
            path.to_str().unwrap(),
            "--port",
            "12345",
            "--foreground",
        ]);
        assert_eq!(result.status.code(), Some(1));
        let error = String::from_utf8(result.stderr).unwrap();
        assert!(error.contains(message), "{error}");
        assert!(!error.contains("TOP_SECRET_SOURCE_MARKER"));
        assert!(result.stdout.is_empty());
    }
    #[cfg(unix)]
    {
        let fifo = dir.path().join("config.fifo");
        assert!(
            Command::new("mkfifo")
                .arg(&fifo)
                .status()
                .unwrap()
                .success()
        );
        let result = output(&[
            "start",
            "-c",
            fifo.to_str().unwrap(),
            "--port",
            "12345",
            "--foreground",
        ]);
        assert_eq!(result.status.code(), Some(1));
        assert!(String::from_utf8_lossy(&result.stderr).contains("regular file"));
    }
}

#[test]
fn capability_errors_identify_the_action_without_exposing_credentials() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("config.yaml");
    std::fs::write(&config, "proxies:\n  - name: ss\n    type: ss\n    server: localhost\n    port: 443\n    password: TOP_SECRET_SOURCE_MARKER\n    cipher: aes-128-gcm\n    udp: true\nrules: ['MATCH,ss']\n").unwrap();
    let result = output(&[
        "start",
        "-c",
        config.to_str().unwrap(),
        "--port",
        "12345",
        "--foreground",
    ]);
    assert_eq!(result.status.code(), Some(1));
    let error = String::from_utf8_lossy(&result.stderr);
    assert!(error.contains("disable UDP"), "{error}");
    assert!(!error.contains("TOP_SECRET_SOURCE_MARKER"));
}

#[cfg(unix)]
#[test]
fn concurrently_replaced_config_never_blocks_opening_a_fifo() {
    use std::{
        os::unix::fs::symlink,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
    };
    struct Swapper {
        stopped: Arc<AtomicBool>,
        worker: Option<std::thread::JoinHandle<()>>,
    }
    impl Drop for Swapper {
        fn drop(&mut self) {
            self.stopped.store(true, Ordering::Release);
            self.worker.take().unwrap().join().unwrap();
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let regular = dir.path().join("regular.yaml");
    let fifo = dir.path().join("fifo");
    let active = dir.path().join("config.yaml");
    std::fs::write(&regular, "invalid: [\n").unwrap();
    assert!(
        Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success()
    );
    symlink(&regular, &active).unwrap();
    let stopped = Arc::new(AtomicBool::new(false));
    let stop = stopped.clone();
    let active_worker = active.clone();
    let replacement = dir.path().join("next");
    let worker = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(20);
        while !stop.load(Ordering::Acquire) && Instant::now() < deadline {
            for target in [&fifo, &regular] {
                symlink(target, &replacement).unwrap();
                std::fs::rename(&replacement, &active_worker).unwrap();
                std::thread::yield_now();
            }
        }
    });
    let _swapper = Swapper {
        stopped,
        worker: Some(worker),
    };
    for _ in 0..60 {
        let result = output(&[
            "start",
            "-c",
            active.to_str().unwrap(),
            "--port",
            "12345",
            "--foreground",
        ]);
        assert_eq!(result.status.code(), Some(1));
    }
}

#[test]
fn bind_collision_is_actionable_and_configuration_is_validated_first() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("config.yaml");
    std::fs::write(&config, "rules:\n  - MATCH,DIRECT\n").unwrap();
    let occupied = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = occupied.local_addr().unwrap().port().to_string();
    let args = [
        "start",
        "-c",
        config.to_str().unwrap(),
        "--port",
        &port,
        "--foreground",
    ];
    let result = output(&args);
    assert_eq!(result.status.code(), Some(1));
    let error = String::from_utf8_lossy(&result.stderr);
    assert!(error.contains("cannot bind"), "{error}");
    assert!(error.contains(&port));
    assert!(!error.contains("listening"));
    std::fs::write(&config, "proxies: [SECRET_SOURCE\n").unwrap();
    let result = output(&args);
    assert_eq!(result.status.code(), Some(1));
    let error = String::from_utf8_lossy(&result.stderr);
    assert!(error.contains("invalid configuration"));
    assert!(!error.contains("cannot bind"));
    assert!(!error.contains("SECRET_SOURCE"));
}

#[cfg(unix)]
#[test]
fn foreground_reports_real_address_handles_signals_and_never_mutates_managed_state() {
    use std::io::{BufRead, Read, Write};
    use std::process::Stdio;
    use std::sync::mpsc;

    struct Child(std::process::Child);
    impl Drop for Child {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    fn snapshot(
        root: &std::path::Path,
    ) -> std::collections::BTreeMap<std::path::PathBuf, Option<Vec<u8>>> {
        let mut result = std::collections::BTreeMap::new();
        for entry in std::fs::read_dir(root).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                result.insert(path.clone(), None);
                result.extend(snapshot(&path));
            } else {
                result.insert(path.clone(), Some(std::fs::read(path).unwrap()));
            }
        }
        result
    }

    for signal in ["-TERM", "-INT"] {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let state = home.join(".local/state/zc/runtime");
        let configs = home.join(".config/zc");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::create_dir_all(&configs).unwrap();
        std::fs::write(state.join("zc.pid"), "managed-state-marker").unwrap();
        std::fs::write(configs.join("config.yaml"), "do-not-read-or-replace").unwrap();
        let config = dir.path().join("explicit.yaml");
        std::fs::write(
            &config,
            "bind-address: 127.0.0.1\nrules:\n  - MATCH,DIRECT\n",
        )
        .unwrap();
        let before = snapshot(dir.path());
        let reserved = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = reserved.local_addr().unwrap();
        drop(reserved);
        let mut child = Child(
            command()
                .args([
                    "start",
                    "-c",
                    config.to_str().unwrap(),
                    "--port",
                    &address.port().to_string(),
                    "--foreground",
                ])
                .env("HOME", &home)
                .env("XDG_CONFIG_HOME", home.join(".config"))
                .env("XDG_STATE_HOME", home.join(".local/state"))
                .env("XDG_RUNTIME_DIR", &state)
                .current_dir(dir.path())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap(),
        );
        let stderr = child.0.stderr.take().unwrap();
        let (tx, rx) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            let mut reader = std::io::BufReader::new(stderr);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            tx.send(line.clone()).unwrap();
            reader.read_to_string(&mut line).unwrap();
            line
        });
        let readiness = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(readiness.contains(&address.to_string()), "{readiness}");
        assert!(readiness.contains("listening"));
        let mut client = std::net::TcpStream::connect(address).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        client.write_all(b"C").unwrap();
        assert!(
            Command::new("kill")
                .args([signal, &child.0.id().to_string()])
                .status()
                .unwrap()
                .success()
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        let status = loop {
            if let Some(status) = child.0.try_wait().unwrap() {
                break status;
            }
            assert!(
                Instant::now() < deadline,
                "runtime failed to stop on {signal}"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        assert!(status.success(), "{signal}: {status}");
        assert!(matches!(client.read(&mut [0]), Ok(0) | Err(_)));
        assert!(std::net::TcpStream::connect(address).is_err());
        let log = reader.join().unwrap();
        assert!(!log.contains("MATCH"));
        let mut stdout = Vec::new();
        child
            .0
            .stdout
            .take()
            .unwrap()
            .read_to_end(&mut stdout)
            .unwrap();
        assert!(stdout.is_empty());
        assert_eq!(snapshot(dir.path()), before);
    }
}
