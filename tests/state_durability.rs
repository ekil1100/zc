//! Real directory fsync failures, isolated in a child process (no Zig dependency).
#[cfg(target_os = "macos")]
mod macos {
    use std::{fs, process::Command};
    use zc::store::{Bundle, Metadata, Store, storage_id};

    #[test]
    fn state_fault_child() {
        let Ok(root) = std::env::var("STATE_FAULT_ROOT") else {
            return;
        };
        let root = std::path::Path::new(&root);
        let store = Store::open(root).unwrap();
        let snapshot = store.load().unwrap();
        let bundle = Bundle::from_memory(b"mixed-port: 9000\n", None, Default::default()).unwrap();
        for pass in 1..=3 {
            if pass < 3 {
                fs::write(std::env::var("TEST_FAIL_SYNC_ARMED").unwrap(), b"armed").unwrap();
            }
            let result = store.publish(
                &snapshot.token,
                "home",
                None,
                &bundle,
                Metadata::default(),
                true,
            );
            if pass < 3 {
                assert!(
                    result.is_err(),
                    "retry must resync the visible orphan before authority commit"
                );
                assert!(!root.join("state-v2.json").exists());
            } else {
                assert!(result.unwrap().durability_error.is_none());
                assert_eq!(store.load().unwrap().catalog.sequence, 1);
            }
        }
    }

    #[test]
    fn state_takeover_child() {
        let Ok(root) = std::env::var("STATE_TAKEOVER_ROOT") else {
            return;
        };
        let store = Store::open(&root).unwrap();
        let snapshot = store.load().unwrap();
        assert_eq!(snapshot.catalog.sequence, 1);
        assert!(snapshot.catalog.active.is_some());
        assert!(
            snapshot.durability_uncertain,
            "visible takeover must report failed authority fsync"
        );
        assert!(store.durability_uncertain());
        assert!(
            store.load().unwrap().durability_uncertain,
            "same reader must retain the warning"
        );
        assert_eq!(store.load().unwrap().token, snapshot.token);
        assert!(std::path::Path::new(&root).join("state-v2.json").exists());
    }

    #[test]
    fn takeover_reports_uncertain_durability_without_rollback() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("state");
        fs::create_dir_all(root.join("configs")).unwrap();
        fs::write(root.join("configs/home.yaml"), b"mixed-port: 9000\n").unwrap();
        fs::write(
            root.join("meta.json"),
            br#"{"active":"home","configs":{"home":{}}}"#,
        )
        .unwrap();
        let root = root.canonicalize().unwrap();
        let dylib = temp.path().join("state_io_fault.dylib");
        assert!(
            Command::new("cc")
                .args(["-dynamiclib", "-o"])
                .arg(&dylib)
                .arg(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/tests/support/state_io_fault.c"
                ))
                .status()
                .unwrap()
                .success()
        );
        let armed = temp.path().join("armed");
        fs::write(&armed, b"armed").unwrap();
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "macos::state_takeover_child", "--nocapture"])
            .env("HOME", temp.path())
            .env("STATE_TAKEOVER_ROOT", &root)
            .env("DYLD_INSERT_LIBRARIES", &dylib)
            .env("TEST_FAIL_SYNC_DIR", &root)
            .env("TEST_FAIL_SYNC_READY", root.join("state-v2.json"))
            .env("TEST_FAIL_SYNC_ARMED", armed)
            .output()
            .unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("INJECT_EIO"),
            "fault not injected: {stderr}"
        );
        assert!(
            output.status.success(),
            "{}\n{stderr}",
            String::from_utf8_lossy(&output.stdout)
        );
    }

    #[test]
    fn cli_reports_takeover_durability_uncertainty() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().canonicalize().unwrap();
        let root = home.join(".config/zc");
        fs::create_dir_all(root.join("configs")).unwrap();
        fs::write(root.join("configs/home.yaml"), b"mixed-port: 9000\n").unwrap();
        fs::write(
            root.join("meta.json"),
            br#"{"active":"home","configs":{"home":{}}}"#,
        )
        .unwrap();
        let dylib = home.join("state_io_fault.dylib");
        assert!(
            Command::new("cc")
                .args(["-dynamiclib", "-o"])
                .arg(&dylib)
                .arg(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/tests/support/state_io_fault.c"
                ))
                .status()
                .unwrap()
                .success()
        );
        let armed = home.join("armed");
        fs::write(&armed, b"armed").unwrap();
        let output = Command::new(env!("CARGO_BIN_EXE_zc"))
            .args(["config", "list", "--json"])
            .env("HOME", &home)
            .env_remove("XDG_RUNTIME_DIR")
            .env("DYLD_INSERT_LIBRARIES", &dylib)
            .env("TEST_FAIL_SYNC_DIR", &root)
            .env("TEST_FAIL_SYNC_READY", root.join("state-v2.json"))
            .env("TEST_FAIL_SYNC_ARMED", armed)
            .output()
            .unwrap();
        assert!(String::from_utf8_lossy(&output.stderr).contains("INJECT_EIO"));
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let result: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(result["data"]["durability_uncertain"], true, "{result}");
        assert!(root.join("state-v2.json").is_file());
    }

    #[test]
    fn retry_resyncs_existing_revision_before_authority_commit() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("state");
        fs::create_dir(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let dylib = temp.path().join("state_io_fault.dylib");
        assert!(
            Command::new("cc")
                .args(["-dynamiclib", "-o"])
                .arg(&dylib)
                .arg(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/tests/support/state_io_fault.c"
                ))
                .status()
                .unwrap()
                .success()
        );
        let revisions = root.join(format!("profiles/{}/revisions", storage_id("home")));
        let ready = revisions.join("85eae890e91da1c27aa2081ace7302b2/manifest.json");
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "macos::state_fault_child", "--nocapture"])
            .env("HOME", temp.path())
            .env("STATE_FAULT_ROOT", &root)
            .env("DYLD_INSERT_LIBRARIES", &dylib)
            .env("TEST_FAIL_SYNC_DIR", &revisions)
            .env("TEST_FAIL_SYNC_READY", ready)
            .env("TEST_FAIL_SYNC_ARMED", temp.path().join("armed"))
            .output()
            .unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("INJECT_EIO"),
            "fault not injected: {stderr}"
        );
        assert!(
            output.status.success(),
            "{}\n{stderr}",
            String::from_utf8_lossy(&output.stdout)
        );
    }
}
