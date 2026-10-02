// Included only in daemon's unit-test module; no production hook or unsafe Rust.
use std::{
    fs,
    path::Path,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

pub const ROOT_ENV: &str = "ZC_DESCRIPTOR_RACE_ROOT";
pub const NEGATIVE_ENV: &str = "ZC_DESCRIPTOR_RACE_NEGATIVE";
const TEST: &str = "daemon::lifecycle_tests::atomic_descriptor_publication_never_accepts_unlinked_or_partial_state";

struct OwnedChild(Child);

impl Drop for OwnedChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

pub fn read_markers(root: &Path) -> String {
    match fs::read_to_string(root.join("markers")) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => panic!("cannot read descriptor overlap markers: {error}"),
    }
}

pub fn run_scoped() {
    // Darwin's sockaddr_un is short. Never inherit its long default TMPDIR.
    let temp = tempfile::Builder::new()
        .prefix("zc-desc-")
        .tempdir_in("/tmp")
        .unwrap();
    let home = temp.path().canonicalize().unwrap();
    let library = home.join(if cfg!(target_os = "macos") {
        "capture.dylib"
    } else {
        "capture.so"
    });
    let mut cc = Command::new("cc");
    cc.args(["-std=c11", "-Wall", "-Wextra", "-Werror"]);
    if cfg!(target_os = "macos") {
        cc.arg("-dynamiclib");
    } else {
        cc.args(["-shared", "-fPIC"]);
    }
    cc.arg("-o").arg(&library).arg(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/support/read_capture_race.c"
    ));
    if cfg!(target_os = "linux") {
        cc.arg("-ldl");
    }
    let output = cc.output().expect("cc is required for the descriptor shim");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    for case in ["overlap", "malformed", "miss"] {
        run_case(&home, &library, case);
    }
}

fn run_case(home: &Path, library: &Path, case: &str) {
    let root = home.join(case);
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    for name in ["runtime", "config", "cache", "data", "state"] {
        fs::DirBuilder::new().mode(0o700).create(root.join(name)).unwrap();
    }
    let log_path = root.join("child.log");
    let log = fs::File::create(&log_path).unwrap();
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args(["--exact", TEST, "--nocapture", "--test-threads=1"])
        .env("HOME", &root)
        .env("TMPDIR", &root)
        .env("XDG_RUNTIME_DIR", root.join("runtime"))
        .env("XDG_CONFIG_HOME", root.join("config"))
        .env("XDG_CACHE_HOME", root.join("cache"))
        .env("XDG_DATA_HOME", root.join("data"))
        .env("XDG_STATE_HOME", root.join("state"))
        .env("XDG_CONFIG_DIRS", root.join("config"))
        .env("XDG_DATA_DIRS", root.join("data"))
        .env(ROOT_ENV, &root)
        .env("ZC_DESCRIPTOR_RACE_CONTROL", root.join("control"))
        .env("ZC_DESCRIPTOR_RACE_SOCKET", root.join("writer.sock"))
        .env("ZC_DESCRIPTOR_RACE_MARKER", root.join("markers"))
        .env(NEGATIVE_ENV, case)
        .env_remove("ZC_READ_RACE_TARGET")
        .env(
            if cfg!(target_os = "macos") {
                "DYLD_INSERT_LIBRARIES"
            } else {
                "LD_PRELOAD"
            },
            library,
        )
        .stdout(Stdio::from(log.try_clone().unwrap()))
        .stderr(Stdio::from(log));
    let mut child = OwnedChild(command.spawn().unwrap());
    let start = Instant::now();
    let status = loop {
        if let Some(status) = child.0.try_wait().unwrap() {
            break status;
        }
        assert!(
            start.elapsed() < Duration::from_secs(120),
            "descriptor fixture watchdog expired ({case}):\n{}",
            fs::read_to_string(&log_path).unwrap()
        );
        std::thread::sleep(Duration::from_millis(10));
    };
    let log = fs::read_to_string(log_path).unwrap();
    match case {
        "overlap" => {
            assert!(status.success(), "{status}\n{log}");
            // A misspelled --exact filter must not turn zero child tests green.
            assert_eq!(
                fs::read_to_string(root.join("markers"))
                    .expect("descriptor child did not record overlaps")
                    .lines()
                    .count(),
                500
            );
        }
        "malformed" => {
            assert_eq!(status.code(), Some(90), "{status}\n{log}");
            assert!(log.contains("malformed descriptor control"), "{log}");
        }
        "miss" => {
            assert!(!status.success(), "missing hook passed:\n{log}");
            assert!(log.contains("descriptor hook missed"), "{log}");
        }
        _ => unreachable!(),
    }
    eprintln!("Descriptor fixture {case}: verified ({status})\n{log}");
}
