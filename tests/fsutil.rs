use std::{fs, time::Duration};
use zc::fsutil::SecureDir;

#[test]
fn atomic_private_bounded_files_and_lock() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("private");
    let dir = SecureDir::create(&root).unwrap();
    assert!(
        dir.atomic_write("state", b"old")
            .unwrap()
            .durability_error
            .is_none()
    );
    assert_eq!(dir.read("state", 3).unwrap(), b"old");
    assert!(dir.read("state", 2).is_err());
    dir.atomic_write("state", b"new").unwrap();
    assert_eq!(dir.read("state", 3).unwrap(), b"new");
    let lock = dir.lock("lock", Duration::from_millis(50)).unwrap();
    assert!(dir.lock("lock", Duration::from_millis(20)).is_err());
    drop(lock);
    dir.lock("lock", Duration::from_millis(20)).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::{PermissionsExt, symlink};
        assert_eq!(
            fs::metadata(root.join("state"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        symlink("state", root.join("alias")).unwrap();
        assert!(dir.read("alias", 3).is_err());
        assert!(dir.atomic_write("alias", b"bad").is_err());
        fs::hard_link(root.join("state"), root.join("hard")).unwrap();
        assert!(dir.read("hard", 3).is_err());
    }
}

#[test]
fn lock_child_process() {
    let Some(root) = std::env::var_os("ZC_FSUTIL_LOCK_ROOT") else {
        return;
    };
    let dir = SecureDir::open(root).unwrap();
    let result = dir.lock("daemon.lock", Duration::from_millis(100));
    if std::env::var_os("ZC_FSUTIL_EXPECT_BUSY").is_some() {
        assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::TimedOut);
    } else {
        result.unwrap();
    }
}

#[test]
fn lock_excludes_an_actual_other_process_and_releases_on_drop() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("private");
    let dir = SecureDir::create(&root).unwrap();
    let guard = dir.lock("daemon.lock", Duration::from_millis(100)).unwrap();
    let run = |busy: bool| {
        let mut child = std::process::Command::new(std::env::current_exe().unwrap());
        child
            .args(["--exact", "lock_child_process", "--nocapture"])
            .env("ZC_FSUTIL_LOCK_ROOT", &root);
        if busy {
            child.env("ZC_FSUTIL_EXPECT_BUSY", "1");
        }
        assert!(child.status().unwrap().success());
    };
    run(true);
    drop(guard);
    run(false);
}

#[cfg(unix)]
#[test]
fn fifo_directory_symlink_and_insecure_permissions_fail_without_blocking() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("private");
    let dir = SecureDir::create(&root).unwrap();
    #[cfg(target_os = "linux")]
    {
        use rustix::fs::{CWD, Mode, mkfifoat};
        mkfifoat(CWD, root.join("fifo"), Mode::from_raw_mode(0o600)).unwrap();
        let start = std::time::Instant::now();
        assert!(dir.read("fifo", 8).is_err());
        assert!(dir.lock("fifo", Duration::from_millis(30)).is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
    }
    let _socket = std::os::unix::net::UnixListener::bind(root.join("socket")).unwrap();
    assert!(dir.read("socket", 8).is_err());
    dir.child("directory", true).unwrap();
    assert!(dir.read("directory", 8).is_err());
    symlink("missing", root.join("dangling")).unwrap();
    assert!(dir.atomic_write("dangling", b"no").is_err());
    dir.write_new("public", b"secret").unwrap();
    fs::set_permissions(root.join("public"), fs::Permissions::from_mode(0o644)).unwrap();
    assert!(dir.read("public", 8).is_err());
    assert!(dir.atomic_write("public", b"no").is_err());
    assert!(dir.read("../public", 8).is_err());
}

#[cfg(unix)]
#[test]
fn dirfd_writes_do_not_follow_replaced_paths_and_lock_identity_is_checked() {
    use std::os::unix::fs::symlink;
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("private");
    let dir = SecureDir::create(&root).unwrap();
    let guard = dir.lock("lock", Duration::from_millis(30)).unwrap();
    fs::rename(root.join("lock"), root.join("old-lock")).unwrap();
    dir.write_new("lock", b"").unwrap();
    assert!(guard.validate(&dir, "lock").is_err());
    let moved = temp.path().join("moved");
    fs::rename(&root, &moved).unwrap();
    let target = temp.path().join("target");
    fs::create_dir(&target).unwrap();
    symlink(&target, &root).unwrap();
    dir.atomic_write("record", b"private").unwrap();
    assert_eq!(fs::read(moved.join("record")).unwrap(), b"private");
    assert!(!target.join("record").exists());
}

#[cfg(unix)]
#[test]
fn contained_capture_resolves_internal_links_but_rejects_all_escape_forms() {
    use std::os::unix::fs::symlink;
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("input");
    fs::create_dir(&root).unwrap();
    fs::create_dir(root.join("nested")).unwrap();
    fs::write(root.join("rules"), b"payload: []\n").unwrap();
    symlink("../rules", root.join("nested/link")).unwrap();
    let (target, bytes) = zc::fsutil::read_contained(&root, "nested/link", 100).unwrap();
    assert_eq!(target, "rules");
    assert_eq!(bytes, b"payload: []\n");
    symlink("../input/rules", root.join("leave-and-return")).unwrap();
    assert!(zc::fsutil::read_contained(&root, "leave-and-return", 100).is_err());
    symlink("loop", root.join("loop")).unwrap();
    assert!(zc::fsutil::read_contained(&root, "loop", 100).is_err());
    assert!(zc::fsutil::read_contained(&root, "../input/rules", 100).is_err());
    fs::hard_link(root.join("rules"), root.join("hard")).unwrap();
    assert!(zc::fsutil::read_contained(&root, "hard", 100).is_err());
}

#[test]
fn immutable_file_install_never_overwrites_and_has_one_link() {
    let temp = tempfile::tempdir().unwrap();
    let dir = SecureDir::create(temp.path().join("private")).unwrap();
    dir.install_new("identity", b"original").unwrap();
    assert_eq!(
        dir.install_new("identity", b"replacement")
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::AlreadyExists
    );
    assert_eq!(dir.read("identity", 100).unwrap(), b"original");
}

#[test]
fn cache_permissions_allow_public_read_but_reject_group_or_other_write() {
    use std::os::unix::fs::PermissionsExt;
    let temp = tempfile::tempdir().unwrap();
    fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o755)).unwrap();
    let dir = SecureDir::open_owned_absolute(&temp.path().canonicalize().unwrap(), false).unwrap();
    for mode in [0o644, 0o666, 0o620] {
        let path = temp.path().join("cache");
        fs::write(&path, b"old").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        let allowed = mode == 0o644;
        assert_eq!(
            dir.cache_metadata("cache").is_ok(),
            allowed,
            "metadata mode {mode:o}"
        );
        assert_eq!(
            dir.read_cache("cache", 3).is_ok(),
            allowed,
            "read mode {mode:o}"
        );
        let lock = dir
            .lock(".provider-cache.lock", Duration::from_secs(1))
            .unwrap();
        assert_eq!(
            dir.write_cache("cache", b"new").is_ok(),
            allowed,
            "write mode {mode:o}"
        );
        drop(lock);
        assert_eq!(
            fs::read(&path).unwrap(),
            if allowed { b"new" } else { b"old" }
        );
    }
}

// Native interposition is confined to an explicitly scoped child process.
#[cfg(any(target_os = "macos", target_os = "linux"))]
mod read_capture {
    use std::{
        fs, io,
        os::unix::fs::{MetadataExt, PermissionsExt},
        path::Path,
        process::Command,
    };
    use zc::fsutil::{SecureDir, read_contained, read_regular};

    const BYTES: &[u8] = b"capture payload\n";
    const SEAMS: &[&str] = &[
        "read",
        "read_with_metadata",
        "read_cache",
        "read_regular",
        "read_contained",
    ];

    fn capture(root: &Path, seam: &str, name: &str) -> io::Result<Vec<u8>> {
        match seam {
            "read" => SecureDir::open(root)?.read(name, BYTES.len()),
            "read_with_metadata" => SecureDir::open(root)?
                .read_with_metadata(name, BYTES.len())
                .map(|(bytes, _)| bytes),
            "read_cache" => SecureDir::open(root)?.read_cache(name, BYTES.len()),
            "read_regular" => read_regular(root.join(name), BYTES.len()),
            "read_contained" => read_contained(root, name, BYTES.len()).map(|(_, bytes)| bytes),
            _ => panic!("unknown public read seam: {seam}"),
        }
    }

    #[test]
    fn child() {
        let Some(root) = std::env::var_os("ZC_READ_RACE_ROOT") else {
            return;
        };
        let root = Path::new(&root);
        let seam = std::env::var("ZC_READ_RACE_SEAM").unwrap();
        let marker = std::env::var_os("ZC_READ_RACE_MARKER").unwrap();
        // Same API and permissions, different inode: the shim must not affect it.
        assert_eq!(capture(root, &seam, "control").unwrap(), BYTES);
        assert!(
            !Path::new(&marker).exists(),
            "injected on the control inode"
        );
        let result = capture(root, &seam, "target");
        let injection = fs::read_to_string(marker).expect("metadata hook did not fire");
        eprint!("{injection}");
        assert!(
            result.is_err(),
            "{seam} accepted an invalid capture: {result:?}"
        );
    }

    fn reject_race(action: &str, seams: &[&str]) {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().canonicalize().unwrap();
        let library = home.join(if cfg!(target_os = "macos") {
            "read_capture_race.dylib"
        } else {
            "read_capture_race.so"
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
        let compiled = cc
            .output()
            .expect("cc is required for the metadata race shim");
        assert!(
            compiled.status.success(),
            "{}",
            String::from_utf8_lossy(&compiled.stderr)
        );
        let mut failures = Vec::new();
        for seam in seams {
            let root = home.join(seam);
            SecureDir::create(&root).unwrap();
            let mode = if matches!(*seam, "read" | "read_with_metadata") {
                0o600
            } else {
                0o644
            };
            for name in ["target", "control"] {
                fs::write(root.join(name), BYTES).unwrap();
                fs::set_permissions(root.join(name), fs::Permissions::from_mode(mode)).unwrap();
            }
            let target = root.join("target");
            let original = fs::metadata(&target).unwrap();
            let marker = root.join("injected");
            // Cache has a separate permission-check snapshot after checked-open.
            // Widen only after that genuine snapshot, before capture's fresh stat.
            let snapshot = if action == "cache-chmod" { "2" } else { "1" };
            let output = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "read_capture::child",
                    "--nocapture",
                    "--test-threads=1",
                ])
                .env("HOME", &home)
                .env_remove("XDG_RUNTIME_DIR")
                .env(
                    if cfg!(target_os = "macos") {
                        "DYLD_INSERT_LIBRARIES"
                    } else {
                        "LD_PRELOAD"
                    },
                    &library,
                )
                .env("ZC_READ_RACE_ROOT", &root)
                .env("ZC_READ_RACE_SEAM", seam)
                .env("ZC_READ_RACE_TARGET", &target)
                .env("ZC_READ_RACE_DEV", original.dev().to_string())
                .env("ZC_READ_RACE_INO", original.ino().to_string())
                .env("ZC_READ_RACE_ACTION", action)
                .env("ZC_READ_RACE_SNAPSHOT", snapshot)
                .env("ZC_READ_RACE_MARKER", &marker)
                .env("ZC_READ_RACE_ALIAS", root.join("alias"))
                .output()
                .unwrap();
            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);
            assert_eq!(
                fs::read_to_string(&marker).unwrap_or_default(),
                format!("INJECT_READ_CAPTURE {action} snapshot={snapshot}\n"),
                "{seam}/{action}: hook missed or mutation failed ({})\n{stdout}\n{stderr}",
                output.status
            );
            if !output.status.success() {
                failures.push(format!("{seam}/{action}:\n{stdout}\n{stderr}"));
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }

    #[test]
    fn rejects_unlinked_inode_after_checked_open() {
        reject_race("unlink", SEAMS);
    }

    #[test]
    fn rejects_hardlinked_inode_after_checked_open() {
        reject_race("hardlink", SEAMS);
    }

    #[test]
    fn rejects_private_permission_widening_after_checked_open() {
        reject_race("private-chmod", &["read", "read_with_metadata"]);
    }

    #[test]
    fn rejects_cache_group_write_after_permission_check() {
        reject_race("cache-chmod", &["read_cache"]);
    }

    #[test]
    fn public_source_mode_0644_remains_legal() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        fs::write(root.join("source"), BYTES).unwrap();
        fs::set_permissions(root.join("source"), fs::Permissions::from_mode(0o644)).unwrap();
        for seam in ["read_regular", "read_contained"] {
            assert_eq!(capture(&root, seam, "source").unwrap(), BYTES);
        }
    }
}
