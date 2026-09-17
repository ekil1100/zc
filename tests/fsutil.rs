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
