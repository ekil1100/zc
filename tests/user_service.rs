use std::process::Command;

#[test]
fn public_service_help_and_arguments_are_strict_and_side_effect_free() {
    let home = tempfile::tempdir().unwrap();
    for args in [
        vec!["service"],
        vec!["help", "service"],
        vec!["service", "start", "--help"],
    ] {
        let out = Command::new(env!("CARGO_BIN_EXE_zc"))
            .args(args)
            .env("HOME", home.path())
            .env_remove("XDG_RUNTIME_DIR")
            .output()
            .unwrap();
        assert!(out.status.success(), "{out:?}");
        assert!(String::from_utf8_lossy(&out.stdout).contains("service start"));
    }
    for args in [
        vec!["service", "stop", "--port", "17890"],
        vec!["service", "start", "--port", "0"],
        vec!["service", "disable", "-c", "x"],
        vec!["service", "restart", "--foreground"],
    ] {
        let out = Command::new(env!("CARGO_BIN_EXE_zc"))
            .args(args)
            .arg("--json")
            .env("HOME", home.path())
            .env_remove("XDG_RUNTIME_DIR")
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(2), "{out:?}");
    }
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
}

#[test]
fn login_preference_is_independent_of_loading_and_running() {
    if std::env::var_os("ZC_SERVICE_TEST_CHILD").is_none() {
        let home = tempfile::tempdir().unwrap();
        let out = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "login_preference_is_independent_of_loading_and_running",
                "--nocapture",
            ])
            .env("ZC_SERVICE_TEST_CHILD", "1")
            .env("HOME", home.path().canonicalize().unwrap())
            .env_remove("XDG_RUNTIME_DIR")
            .output()
            .unwrap();
        assert!(out.status.success(), "{out:?}");
        return;
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let config =
            std::path::PathBuf::from(std::env::var_os("HOME").unwrap()).join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(zc::user_service::Platform::Launchd);
        let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
        let data = zc::user_service::execute(
            "enable",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(17893),
                ..Default::default()
            },
            binary,
            &runner,
        )
        .await
        .unwrap();
        assert_eq!(data["registered"], true);
        assert_eq!(data["enabled"], true);
        assert_eq!(data["loaded"], false);
        assert_eq!(data["running"], false);
        let data = zc::user_service::execute("disable", Default::default(), binary, &runner)
            .await
            .unwrap();
        assert_eq!(data["enabled"], false);
        assert_eq!(data["running"], false);
    });
}

#[path = "support/service_runner.rs"]
mod support;

#[test]
fn real_service_lifecycle_preserves_login_preference_and_frozen_config() {
    if std::env::var_os("ZC_SERVICE_TEST_CHILD").is_none() {
        for platform in ["launchd", "systemd"] {
            let home = tempfile::tempdir().unwrap();
            let out = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "real_service_lifecycle_preserves_login_preference_and_frozen_config",
                    "--nocapture",
                ])
                .env("ZC_SERVICE_TEST_CHILD", platform)
                .env("HOME", home.path().canonicalize().unwrap())
                .env_remove("XDG_RUNTIME_DIR")
                .output()
                .unwrap();
            assert!(out.status.success(), "{platform}: {out:?}");
        }
        return;
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        use zc::user_service::{Platform, execute};
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin_dir = home.join(if platform() == zc::user_service::Platform::Launchd {
            "bin}valid with 'quotes' \"double\" \\ & $dollars %percent"
        } else {
            "bin with spaces & $dollars %percent"
        });
        std::fs::create_dir(&bin_dir).unwrap();
        let binary = bin_dir.join("zc");
        std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        assert_ne!(port, 7899);
        let runner = support::FakeManager::new(
            if std::env::var("ZC_SERVICE_TEST_CHILD").unwrap() == "launchd" {
                Platform::Launchd
            } else {
                Platform::Systemd
            },
        );
        let options = zc::service::PrepareOptions {
            config: Some(config.to_str().unwrap().into()),
            port: Some(port),
            ..Default::default()
        };
        let first = execute("start", options, &binary, &runner).await.unwrap();
        let private = home.join(".local/state/zc/service");
        if cfg!(target_os = "macos") && platform() == Platform::Launchd {
            let out = Command::new("/usr/bin/plutil").arg("-lint").arg(private.join("org.zc.user.plist")).output().unwrap();
            assert!(out.status.success(), "native plist parse: {out:?}");
        }
        if cfg!(target_os = "linux") && platform() == Platform::Systemd {
            if std::path::Path::new("/usr/bin/systemd-analyze").exists() {
                let unit = private.join("zc-user.service");
                let out = Command::new("/usr/bin/systemd-analyze").args(["verify", "--man=no", "--generators=no"]).arg(&unit).output().unwrap();
                assert!(out.status.success(), "native unit parse: {out:?}");
                println!("native systemd-analyze verified spaces/$/% without manager registration");
            } else {
                eprintln!("Native systemd parser unavailable; adapter tests are not native parsing evidence");
            }
        }
        assert_eq!(first["running"], true);
        assert_eq!(first["enabled"], false);
        std::fs::remove_file(config).unwrap();
        let enabled = execute("enable", Default::default(), &binary, &runner)
            .await
            .unwrap();
        assert_eq!(enabled["pid"], first["pid"]);
        let disabled = execute("disable", Default::default(), &binary, &runner)
            .await
            .unwrap();
        assert_eq!(disabled["pid"], first["pid"]);
        assert_eq!(disabled["enabled"], false);
        execute("enable", Default::default(), &binary, &runner)
            .await
            .unwrap();
        let restarted = execute("restart", Default::default(), &binary, &runner)
            .await
            .unwrap();
        assert_eq!(restarted["running"], true);
        assert_ne!(restarted["pid"], first["pid"]);
        assert_eq!(restarted["mixed_port"], port);
        assert_eq!(restarted["enabled"], true);
        let stopped = execute("stop", Default::default(), &binary, &runner)
            .await
            .unwrap();
        assert_eq!(stopped["running"], false);
        assert_eq!(stopped["enabled"], true);
        // Simulate a later login through the independent manager, without a CLI start.
        use zc::user_service::CommandRunner;
        let (program, args) = if runner.platform() == Platform::Launchd {
            (
                "/bin/launchctl",
                vec![
                    "bootstrap".into(),
                    format!("gui/{}", rustix::process::geteuid().as_raw()),
                    home.join(".local/state/zc/service/org.zc.user.plist")
                        .to_str()
                        .unwrap()
                        .into(),
                ],
            )
        } else {
            (
                "/usr/bin/systemctl",
                vec![
                    "--user".into(),
                    "--no-pager".into(),
                    "start".into(),
                    "zc-user.service".into(),
                ],
            )
        };
        assert_eq!(runner.run(program, &args).await.unwrap().code, 0);
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
        let started = loop {
            if let Ok(data) = execute("status", Default::default(), &binary, &runner).await
                && data["running"] == true
            {
                break data;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "enabled service failed to start at later login"
            );
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        };
        assert_eq!(started["mixed_port"], port);
        execute("stop", Default::default(), &binary, &runner)
            .await
            .unwrap();
    });
}

#[test]
fn manual_stop_cannot_bypass_service_owner() {
    if std::env::var_os("ZC_SERVICE_TEST_CHILD").is_none() {
        let home = tempfile::tempdir().unwrap();
        let out = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "manual_stop_cannot_bypass_service_owner",
                "--nocapture",
            ])
            .env("ZC_SERVICE_TEST_CHILD", "1")
            .env("HOME", home.path().canonicalize().unwrap())
            .env_remove("XDG_RUNTIME_DIR")
            .output()
            .unwrap();
        assert!(out.status.success(), "{out:?}");
        return;
    }
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(async {
            let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
            let config = home.join("source.yaml");
            std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
            let runner = support::FakeManager::new(zc::user_service::Platform::Launchd);
            let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
            zc::user_service::execute(
                "enable",
                zc::service::PrepareOptions {
                    config: Some(config.to_str().unwrap().into()),
                    port: Some(17894),
                    ..Default::default()
                },
                binary,
                &runner,
            )
            .await
            .unwrap();
            let out = Command::new(binary)
                .args(["stop", "--json"])
                .output()
                .unwrap();
            assert!(!out.status.success(), "{out:?}");
            assert!(String::from_utf8_lossy(&out.stdout).contains("SERVICE_OWNED"));
        });
}

#[test]
fn install_restores_only_previously_running_service_and_rolls_back_failed_activation() {
    if std::env::var_os("ZC_SERVICE_TEST_CHILD").is_none() {
        let home = tempfile::tempdir().unwrap();
        let out = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "install_restores_only_previously_running_service_and_rolls_back_failed_activation",
                "--nocapture",
            ])
            .env("ZC_SERVICE_TEST_CHILD", "1")
            .env("HOME", home.path().canonicalize().unwrap())
            .env_remove("XDG_RUNTIME_DIR")
            .output()
            .unwrap();
        assert!(out.status.success(), "{out:?}");
        return;
    }
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(async {
            use zc::user_service::{Platform, execute, install};
            let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
            let bin_dir = home.join("install quoted ' & $ %");
            let binary = bin_dir.join("zc");
            let source = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
            let publisher = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("scripts/install/local-dev-install.sh");
            let runner = support::FakeManager::new(Platform::Launchd);
            install(source, &bin_dir, &publisher, &runner)
                .await
                .unwrap();
            assert_eq!(
                std::fs::read(&binary).unwrap(),
                std::fs::read(source).unwrap()
            );
            assert!(!home.join("fake-manager.json").exists());
            let config = home.join("source.yaml");
            std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
            let port = std::net::TcpListener::bind("127.0.0.1:0")
                .unwrap()
                .local_addr()
                .unwrap()
                .port();
            execute(
                "enable",
                zc::service::PrepareOptions {
                    config: Some(config.to_str().unwrap().into()),
                    port: Some(port),
                    ..Default::default()
                },
                &binary,
                &runner,
            )
            .await
            .unwrap();
            install(source, &bin_dir, &publisher, &runner)
                .await
                .unwrap();
            assert_eq!(
                execute("status", Default::default(), &binary, &runner)
                    .await
                    .unwrap()["running"],
                false
            );
            let old = execute("start", Default::default(), &binary, &runner)
                .await
                .unwrap();
            std::fs::remove_file(config).unwrap();
            install(source, &bin_dir, &publisher, &runner)
                .await
                .unwrap();
            let next = execute("status", Default::default(), &binary, &runner)
                .await
                .unwrap();
            assert_eq!(next["running"], true);
            assert_eq!(next["enabled"], true);
            assert_eq!(next["mixed_port"], port);
            assert_ne!(next["pid"], old["pid"]);
            std::fs::write(home.join("fail-start-once"), "").unwrap();
            let error = install(source, &bin_dir, &publisher, &runner)
                .await
                .unwrap_err();
            assert!(error.to_string().contains("ROLLED_BACK"), "{error:#}");
            let recovered = execute("status", Default::default(), &binary, &runner)
                .await
                .unwrap();
            assert_eq!(recovered["running"], true);
            assert_eq!(recovered["enabled"], true);
            assert_eq!(recovered["mixed_port"], port);
            assert_eq!(
                std::fs::read(&binary).unwrap(),
                std::fs::read(source).unwrap()
            );
            execute("stop", Default::default(), &binary, &runner)
                .await
                .unwrap();
        });
}

fn isolated(name: &str) -> bool {
    if std::env::var_os("ZC_SERVICE_TEST_CHILD").is_some() {
        return true;
    }
    for platform in ["launchd", "systemd"] {
        let home = tempfile::tempdir().unwrap();
        let runtime = home.path().join("custom runtime");
        std::fs::create_dir(&runtime).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&runtime, std::fs::Permissions::from_mode(0o700)).unwrap();
        let out = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", name, "--nocapture"])
            .env("ZC_SERVICE_TEST_CHILD", platform)
            .env("HOME", home.path().canonicalize().unwrap())
            .env("XDG_RUNTIME_DIR", runtime.canonicalize().unwrap())
            .output()
            .unwrap();
        assert!(out.status.success(), "{platform}: {out:?}");
        print!("{}", String::from_utf8_lossy(&out.stdout));
    }
    false
}
fn platform() -> zc::user_service::Platform {
    if std::env::var("ZC_SERVICE_TEST_CHILD").unwrap() == "systemd" {
        zc::user_service::Platform::Systemd
    } else {
        zc::user_service::Platform::Launchd
    }
}
fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
}
fn port() -> u16 {
    let p = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    assert_ne!(p, 7899);
    p
}
fn cli(binary: &std::path::Path, args: &[&str]) -> serde_json::Value {
    let out = Command::new(binary)
        .args(args)
        .arg("--json")
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    serde_json::from_slice(&out.stdout).unwrap()
}

#[test]
fn native_service_commands_reject_temporary_home_before_any_mutation() {
    let home = tempfile::tempdir().unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_zc"))
        .args(["service", "start", "--port", "17891", "--json"])
        .env("HOME", home.path().canonicalize().unwrap())
        .env_remove("XDG_RUNTIME_DIR")
        .output()
        .unwrap();
    assert!(!out.status.success(), "{out:?}");
    let message = String::from_utf8_lossy(&out.stdout);
    assert!(
        message.contains("SERVICE_HOME_MISMATCH") || message.contains("SERVICE_USER_REQUIRED"),
        "{message}"
    );
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
}

#[test]
fn missing_foreign_and_corrupt_state_is_retained_and_manager_errors_are_not_absence() {
    if !isolated("missing_foreign_and_corrupt_state_is_retained_and_manager_errors_are_not_absence")
    {
        return;
    }
    runtime().block_on(async {
        use std::os::unix::fs::PermissionsExt;
        use zc::user_service::execute;
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let runner = support::FakeManager::new(platform());
        let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
        let status = execute("status", Default::default(), binary, &runner)
            .await
            .unwrap();
        assert_eq!(status["registered"], false);
        assert!(!home.join(".local/state/zc/service").exists());
        std::fs::write(home.join("manager-denied"), "").unwrap();
        let err = execute("status", Default::default(), binary, &runner)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("SERVICE_MANAGER_FAILED"));
        std::fs::remove_file(home.join("manager-denied")).unwrap();
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        execute(
            "enable",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(port()),
                ..Default::default()
            },
            binary,
            &runner,
        )
        .await
        .unwrap();
        let root = home.join(".local/state/zc/service");
        let record = root.join("registration.json");
        let original = std::fs::read(&record).unwrap();
        let calls = runner.calls.borrow().len();
        for bytes in [b"{broken".as_slice(), b"{}".as_slice()] {
            std::fs::write(&record, bytes).unwrap();
            assert!(
                execute("start", Default::default(), binary, &runner)
                    .await
                    .is_err()
            );
            assert_eq!(std::fs::read(&record).unwrap(), bytes);
        }
        std::fs::remove_file(&record).unwrap();
        assert!(
            execute("start", Default::default(), binary, &runner)
                .await
                .is_err()
        );
        assert!(!record.exists());
        std::fs::write(&record, &original).unwrap();
        std::fs::set_permissions(&record, std::fs::Permissions::from_mode(0o600)).unwrap();
        let doc: serde_json::Value = serde_json::from_slice(&original).unwrap();
        let frozen = root.join(doc["snapshot"].as_str().unwrap());
        let bytes = std::fs::read(&frozen).unwrap();
        std::fs::write(&frozen, b"corrupt snapshot").unwrap();
        assert!(
            execute("start", Default::default(), binary, &runner)
                .await
                .is_err()
        );
        assert_eq!(std::fs::read(&frozen).unwrap(), b"corrupt snapshot");
        std::fs::write(&frozen, bytes).unwrap();
        let definition = root.join(if platform() == zc::user_service::Platform::Launchd {
            "org.zc.user.plist"
        } else {
            "zc-user.service"
        });
        std::fs::write(&definition, b"foreign unit content").unwrap();
        assert!(
            execute("disable", Default::default(), binary, &runner)
                .await
                .is_err()
        );
        assert_eq!(std::fs::read(&definition).unwrap(), b"foreign unit content");
        assert_eq!(
            runner.calls.borrow().len(),
            calls,
            "bad state reached manager mutation"
        );
    });
}

#[test]
fn managed_namespace_frozen_identity_secret_and_selected_node_survive_upgrade() {
    if !isolated("managed_namespace_frozen_identity_secret_and_selected_node_survive_upgrade") {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::{execute,install};
        let home=std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin_dir=home.join("bin");std::fs::create_dir(&bin_dir).unwrap();let binary=bin_dir.join("zc");
        std::fs::copy(env!("CARGO_BIN_EXE_zc"),&binary).unwrap();
        let source=home.join("source.yaml");
        let controller=port();let mixed=port();
        std::fs::write(&source,format!("external-controller: 127.0.0.1:{controller}\nproxy-groups:\n  - name: pick\n    type: select\n    proxies: [DIRECT, REJECT]\nrules: ['MATCH,pick']\n")).unwrap();
        let imported=cli(&binary,&["config","load",source.to_str().unwrap()]);
        let key=imported["data"]["name"].as_str().or_else(||imported["data"]["key"].as_str()).map(str::to_owned);
        let runner=support::FakeManager::new(platform());
        let first=execute("start",zc::service::PrepareOptions{port:Some(mixed),..Default::default()},&binary,&runner).await.unwrap();
        cli(&binary,&["proxy","select","-g","pick","-p","REJECT"]);
        let before=cli(&binary,&["status"]);
        assert_eq!(before["data"]["selected_proxies"][0]["proxy"],"REJECT");
        let catalog_path=home.join(".config/zc/state-v2.json");
        let catalog:serde_json::Value=serde_json::from_slice(&std::fs::read(&catalog_path).unwrap()).unwrap();
        let secret=catalog.to_string();
        assert!(secret.contains("auto_controller_secret"));
        let other=home.join("other.yaml");std::fs::write(&other,"rules: ['MATCH,REJECT']\n").unwrap();cli(&binary,&["config","load",other.to_str().unwrap()]);
        std::fs::remove_file(&source).unwrap();
        let publisher=std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("scripts/install/local-dev-install.sh");
        install(std::path::Path::new(env!("CARGO_BIN_EXE_zc")),&bin_dir,&publisher,&runner).await.unwrap();
        let after=cli(&binary,&["status"]);
        assert_eq!(after["data"]["active_config"],before["data"]["active_config"],"{key:?}");
        assert_eq!(after["data"]["mixed_port"],mixed);
        assert_eq!(after["data"]["selected_proxies"][0]["proxy"],"REJECT");
        let status=execute("status",Default::default(),&binary,&runner).await.unwrap();
        assert_eq!(status["runtime"],std::env::var("XDG_RUNTIME_DIR").unwrap());
        assert_ne!(status["pid"],first["pid"]);
        assert_eq!(status["enabled"],false);
        let calls=std::fs::read_to_string(home.join("manager-calls.jsonl")).unwrap();
        // Unit files and manager commands contain only executable/namespace/identity.
        assert!(!calls.contains("REJECT") && !calls.contains("secret"));
        execute("stop",Default::default(),&binary,&runner).await.unwrap();
    });
}

#[test]
fn manager_success_without_ready_daemon_is_failure_and_keeps_registration() {
    if !isolated("manager_success_without_ready_daemon_is_failure_and_keeps_registration") {
        return;
    }
    runtime().block_on(async {
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(platform());
        let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
        std::fs::write(home.join("success-without-daemon"), "").unwrap();
        let error = zc::user_service::execute(
            "start",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(port()),
                ..Default::default()
            },
            binary,
            &runner,
        )
        .await
        .unwrap_err();
        assert!(
            error.to_string().contains("SERVICE_START_FAILED"),
            "{error:#}"
        );
        let status = zc::user_service::execute("status", Default::default(), binary, &runner)
            .await
            .unwrap();
        assert_eq!(status["registered"], true);
        assert_eq!(status["running"], false);
    });
}

#[test]
fn manual_migration_and_target_mismatch_refuse_without_stopping_instances() {
    if !isolated("manual_migration_and_target_mismatch_refuse_without_stopping_instances") {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::{execute, install};
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin_dir = home.join("bin");
        std::fs::create_dir(&bin_dir).unwrap();
        let binary = bin_dir.join("zc");
        std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let mixed = port().to_string();
        cli(
            &binary,
            &["start", "-c", config.to_str().unwrap(), "--port", &mixed],
        );
        let before = cli(&binary, &["status"]);
        let runner = support::FakeManager::new(platform());
        let options = zc::service::PrepareOptions {
            config: Some(config.to_str().unwrap().into()),
            port: Some(mixed.parse().unwrap()),
            ..Default::default()
        };
        let err = execute("start", options.clone(), &binary, &runner)
            .await
            .unwrap_err();
        assert!(
            err.to_string().contains("SERVICE_MANUAL_INSTANCE"),
            "{err:#}"
        );
        let publisher = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("scripts/install/local-dev-install.sh");
        assert!(
            install(
                std::path::Path::new(env!("CARGO_BIN_EXE_zc")),
                &bin_dir,
                &publisher,
                &runner
            )
            .await
            .unwrap_err()
            .to_string()
            .contains("SERVICE_MANUAL_INSTANCE")
        );
        assert_eq!(
            cli(&binary, &["status"])["data"]["pid"],
            before["data"]["pid"]
        );
        cli(&binary, &["stop"]);
        // The failed registration must leave no partial authority behind.
        let first = execute("start", options, &binary, &runner).await.unwrap();
        let other = home.join("other");
        std::fs::create_dir(&other).unwrap();
        let other_binary = other.join("zc");
        std::fs::copy(&binary, &other_binary).unwrap();
        let err = execute("stop", Default::default(), &other_binary, &runner)
            .await
            .unwrap_err();
        assert!(
            err.to_string().contains("SERVICE_TARGET_MISMATCH"),
            "{err:#}"
        );
        assert!(
            install(
                std::path::Path::new(env!("CARGO_BIN_EXE_zc")),
                &other,
                &publisher,
                &runner
            )
            .await
            .unwrap_err()
            .to_string()
            .contains("SERVICE_TARGET_MISMATCH")
        );
        let bad = home.join("bad-candidate");
        std::fs::write(&bad, "#!/bin/sh\nexit 7\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&bad, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(install(&bad, &bin_dir, &publisher, &runner).await.is_err());
        let status = execute("status", Default::default(), &binary, &runner)
            .await
            .unwrap();
        assert_eq!(status["pid"], first["pid"]);
        execute("stop", Default::default(), &binary, &runner)
            .await
            .unwrap();
    });
}

#[test]
fn failed_new_binary_and_publication_restore_real_old_binary_and_invocation() {
    if !isolated("failed_new_binary_and_publication_restore_real_old_binary_and_invocation") {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::{execute,install};use std::os::unix::fs::PermissionsExt;
        let home=std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin_dir=home.join("bin");std::fs::create_dir(&bin_dir).unwrap();let binary=bin_dir.join("zc");std::fs::copy(env!("CARGO_BIN_EXE_zc"),&binary).unwrap();
        let config=home.join("source.yaml");std::fs::write(&config,"rules: ['MATCH,DIRECT']\n").unwrap();let mixed=port();
        let runner=support::FakeManager::new(platform());
        execute("start",zc::service::PrepareOptions{config:Some(config.to_str().unwrap().into()),port:Some(mixed),..Default::default()},&binary,&runner).await.unwrap();
        std::fs::remove_file(config).unwrap();
        let source=std::path::Path::new(env!("CARGO_BIN_EXE_zc"));let original=std::fs::read(&binary).unwrap();
        let publisher=std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("scripts/install/local-dev-install.sh");
        let failure=home.join("bad-runtime");
        std::fs::write(&failure,"#!/bin/sh\ncase \"$1\" in\n--version) echo 'zc broken-test-candidate';;\n--service-check) echo zc-service-install-v1;;\n*) exit 9;;\nesac\n").unwrap();std::fs::set_permissions(&failure,std::fs::Permissions::from_mode(0o700)).unwrap();
        let error=install(&failure,&bin_dir,&publisher,&runner).await.unwrap_err();assert!(error.to_string().contains("ROLLED_BACK"),"{error:#}");
        assert_eq!(std::fs::read(&binary).unwrap(),original);
        let restored=execute("status",Default::default(),&binary,&runner).await.unwrap();assert_eq!(restored["running"],true);assert_eq!(restored["mixed_port"],mixed);assert_eq!(restored["enabled"],false);
        let broken_publisher=home.join("publisher.sh");std::fs::write(&broken_publisher,"#!/bin/sh\nexit 8\n").unwrap();
        let error=install(source,&bin_dir,&broken_publisher,&runner).await.unwrap_err();assert!(error.to_string().contains("ROLLED_BACK"),"{error:#}");
        assert_eq!(execute("status",Default::default(),&binary,&runner).await.unwrap()["running"],true);
        execute("stop",Default::default(),&binary,&runner).await.unwrap();
    });
}

#[test]
fn concurrent_command_and_other_namespace_cannot_be_stopped_or_replaced() {
    if !isolated("concurrent_command_and_other_namespace_cannot_be_stopped_or_replaced") {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::{execute, install};
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin_dir = home.join("bin");
        std::fs::create_dir(&bin_dir).unwrap();
        let binary = bin_dir.join("zc");
        std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(platform());
        execute(
            "start",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(port()),
                ..Default::default()
            },
            &binary,
            &runner,
        )
        .await
        .unwrap();
        let op = zc::fsutil::SecureDir::open(home.join(".local/state/zc"))
            .unwrap()
            .lock("zc.service.lock", std::time::Duration::from_secs(1))
            .unwrap();
        let calls = runner.calls.borrow().len();
        assert!(
            execute("restart", Default::default(), &binary, &runner)
                .await
                .is_err()
        );
        assert_eq!(runner.calls.borrow().len(), calls);
        drop(op);
        let other = tempfile::tempdir().unwrap();
        let other_home = other.path().canonicalize().unwrap();
        let mixed = port().to_string();
        let other_command = |args: &[&str]| {
            Command::new(&binary)
                .args(args)
                .arg("--json")
                .env("HOME", &other_home)
                .env_remove("XDG_RUNTIME_DIR")
                .output()
                .unwrap()
        };
        let started = other_command(&["start", "-c", config.to_str().unwrap(), "--port", &mixed]);
        assert!(started.status.success(), "{started:?}");
        let before: serde_json::Value =
            serde_json::from_slice(&other_command(&["status"]).stdout).unwrap();
        let publisher = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("scripts/install/local-dev-install.sh");
        let error = install(
            std::path::Path::new(env!("CARGO_BIN_EXE_zc")),
            &bin_dir,
            &publisher,
            &runner,
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("ROLLED_BACK"), "{error:#}");
        let after: serde_json::Value =
            serde_json::from_slice(&other_command(&["status"]).stdout).unwrap();
        assert_eq!(after["data"]["pid"], before["data"]["pid"]);
        assert_eq!(after["data"]["state"], "running");
        assert_eq!(
            execute("status", Default::default(), &binary, &runner)
                .await
                .unwrap()["running"],
            true
        );
        assert!(other_command(&["stop"]).status.success());
        execute("stop", Default::default(), &binary, &runner)
            .await
            .unwrap();
    });
}

#[test]
fn command_execution_is_bounded_and_never_echoes_untrusted_output() {
    runtime().block_on(async {
        let error = zc::user_service::run_bounded(
            "/usr/bin/python3",
            &["-c".into(), "print('SENSITIVE_MARKER' * 10000)".into()],
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("OUTPUT_LIMIT"));
        assert!(!error.to_string().contains("SENSITIVE_MARKER"));
        let error = zc::user_service::run_bounded(
            "/usr/bin/python3",
            &["-c".into(), "import time; time.sleep(60)".into()],
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("TIMEOUT"));
        let error = zc::user_service::run_bounded("/absent-zc-test-manager", &[])
            .await
            .unwrap_err();
        assert!(error.to_string().contains("UNAVAILABLE"));
    });
}

#[test]
fn recovery_failure_is_explicit_and_retains_old_binary_backup() {
    if !isolated("recovery_failure_is_explicit_and_retains_old_binary_backup") {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::{execute, install};
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin_dir = home.join("bin");
        std::fs::create_dir(&bin_dir).unwrap();
        let binary = bin_dir.join("zc");
        std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(platform());
        execute(
            "start",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(port()),
                ..Default::default()
            },
            &binary,
            &runner,
        )
        .await
        .unwrap();
        let marker = home.join("fail-all-starts");
        std::fs::write(&marker, "").unwrap();
        let publisher = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("scripts/install/local-dev-install.sh");
        let error = install(
            std::path::Path::new(env!("CARGO_BIN_EXE_zc")),
            &bin_dir,
            &publisher,
            &runner,
        )
        .await
        .unwrap_err();
        assert!(
            error.to_string().contains("SERVICE_RECOVERY_FAILED"),
            "{error:#}"
        );
        let backups: Vec<_> = std::fs::read_dir(&bin_dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| {
                p.file_name()
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .starts_with(".zc.recovery.")
            })
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(
            std::fs::read(&backups[0]).unwrap(),
            std::fs::read(env!("CARGO_BIN_EXE_zc")).unwrap()
        );
        std::fs::remove_file(marker).unwrap();
        execute("start", Default::default(), &binary, &runner)
            .await
            .unwrap();
        execute("stop", Default::default(), &binary, &runner)
            .await
            .unwrap();
    });
}

#[test]
fn public_cli_dispatches_service_commands_through_explicit_runner() {
    if !isolated("public_cli_dispatches_service_commands_through_explicit_runner") {
        return;
    }
    runtime().block_on(async {
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(platform());
        let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
        let args = vec![
            "service".into(),
            "enable".into(),
            "-c".into(),
            config.to_str().unwrap().into(),
            "--port".into(),
            port().to_string(),
            "--json".into(),
        ];
        assert_eq!(zc::cli::run_with_services(args, &runner, binary).await, 0);
        for action in ["start", "status", "restart", "disable", "stop"] {
            assert_eq!(
                zc::cli::run_with_services(
                    vec!["service".into(), action.into(), "--json".into()],
                    &runner,
                    binary
                )
                .await,
                0
            );
        }
    });
}

#[test]
fn launchd_persistent_disable_does_not_turn_start_into_enable() {
    if !isolated("launchd_persistent_disable_does_not_turn_start_into_enable") {
        return;
    }
    if platform() != zc::user_service::Platform::Launchd {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::{CommandRunner, Platform, execute};
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(Platform::Launchd);
        let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
        execute(
            "enable",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(port()),
                ..Default::default()
            },
            binary,
            &runner,
        )
        .await
        .unwrap();
        runner
            .run(
                "/bin/launchctl",
                &[
                    "disable".into(),
                    format!("gui/{}/org.zc.user", rustix::process::geteuid().as_raw()),
                ],
            )
            .await
            .unwrap();
        assert_eq!(
            execute("status", Default::default(), binary, &runner)
                .await
                .unwrap()["enabled"],
            false
        );
        let started = execute("start", Default::default(), binary, &runner)
            .await
            .unwrap();
        assert_eq!(started["running"], true);
        assert_eq!(started["enabled"], false);
        execute("stop", Default::default(), binary, &runner)
            .await
            .unwrap();
    });
}

#[test]
fn missing_managed_authority_is_not_regenerated_from_legacy_mirrors() {
    if !isolated("missing_managed_authority_is_not_regenerated_from_legacy_mirrors") {
        return;
    }
    runtime().block_on(async {
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
        cli(binary, &["config", "load", config.to_str().unwrap()]);
        let runner = support::FakeManager::new(platform());
        zc::user_service::execute(
            "enable",
            zc::service::PrepareOptions {
                port: Some(port()),
                ..Default::default()
            },
            binary,
            &runner,
        )
        .await
        .unwrap();
        let authority = home.join(".config/zc/state-v2.json");
        assert!(home.join(".config/zc/meta.json").exists());
        std::fs::remove_file(&authority).unwrap();
        assert!(
            zc::user_service::execute("status", Default::default(), binary, &runner)
                .await
                .is_err()
        );
        assert!(!authority.exists(), "missing authority was regenerated");
        let output = Command::new(binary)
            .arg("--service-check")
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(
            !authority.exists(),
            "candidate check regenerated missing authority"
        );
    });
}

#[test]
fn failed_stop_restores_exact_registration_and_reports_partial_stop() {
    if !isolated("failed_stop_restores_exact_registration_and_reports_partial_stop") {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::execute;
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(platform());
        let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
        let mixed = port();
        execute(
            "enable",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(mixed),
                ..Default::default()
            },
            binary,
            &runner,
        )
        .await
        .unwrap();
        let record = home.join(".local/state/zc/service/registration.json");
        for failure in ["fail-stop-once", "fail-after-stop-once"] {
            for action in ["stop", "restart"] {
                let old = execute("start", Default::default(), binary, &runner)
                    .await
                    .unwrap();
                let before = std::fs::read(&record).unwrap();
                std::fs::write(home.join(failure), "").unwrap();
                let options = zc::service::PrepareOptions {
                    port: (action == "restart").then(port),
                    ..Default::default()
                };
                let error = execute(action, options, binary, &runner).await.unwrap_err();
                assert_eq!(
                    std::fs::read(&record).unwrap(),
                    before,
                    "failed stop changed registration: {error:#}"
                );
                let after = execute("status", Default::default(), binary, &runner)
                    .await
                    .unwrap();
                assert_eq!(after["enabled"], true);
                assert_eq!(after["configured_port"], mixed);
                if failure == "fail-stop-once" {
                    assert_eq!(after["pid"], old["pid"]);
                    assert_eq!(after["running"], true);
                } else {
                    assert_eq!(after["running"], false);
                    assert!(error.to_string().contains("stopped"), "{error:#}");
                }
                execute("stop", Default::default(), binary, &runner)
                    .await
                    .unwrap();
                let next = execute("start", Default::default(), binary, &runner)
                    .await
                    .unwrap();
                assert_eq!(next["running"], true);
                assert_eq!(next["mixed_port"], mixed);
            }
        }
        execute("stop", Default::default(), binary, &runner)
            .await
            .unwrap();
    });
}

#[test]
fn systemd_unsafe_executable_paths_are_rejected_before_preparation_or_state() {
    if !isolated("systemd_unsafe_executable_paths_are_rejected_before_preparation_or_state") {
        return;
    }
    if platform() != zc::user_service::Platform::Systemd {
        return;
    }
    runtime().block_on(async {
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let runner = support::FakeManager::new(platform());
        for part in ["single'quote", "double\"quote", "back\\slash"] {
            let bin_dir = home.join(part);
            std::fs::create_dir(&bin_dir).unwrap();
            let binary = bin_dir.join("zc");
            std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
            for action in ["enable", "start"] {
                let error = zc::user_service::execute(
                    action,
                    zc::service::PrepareOptions {
                        config: Some(home.join("missing.yaml").to_str().unwrap().into()),
                        port: Some(port()),
                        ..Default::default()
                    },
                    &binary,
                    &runner,
                )
                .await
                .unwrap_err();
                assert!(
                    error
                        .to_string()
                        .contains("SERVICE_EXECUTABLE_PATH_UNSUPPORTED"),
                    "{error:#}"
                );
                assert!(error.to_string().contains("install"), "{error:#}");
                assert!(!home.join(".local").exists());
                assert!(!home.join(".config").exists());
                assert!(runner.calls.borrow().is_empty());
            }
        }
    });
}

fn snapshots(path: &std::path::Path) -> Vec<std::path::PathBuf> {
    std::fs::read_dir(path)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|s| s == "snapshot"))
        .collect()
}

#[test]
fn early_service_start_failures_cleanup_only_owned_runtime_snapshot() {
    if !isolated("early_service_start_failures_cleanup_only_owned_runtime_snapshot") {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::execute;
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin = home.join("bin");
        std::fs::create_dir(&bin).unwrap();
        let binary = bin.join("zc");
        std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(platform());
        execute(
            "enable",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(port()),
                ..Default::default()
            },
            &binary,
            &runner,
        )
        .await
        .unwrap();
        let service = home.join(".local/state/zc/service");
        let frozen = snapshots(&service);
        let record: serde_json::Value =
            serde_json::from_slice(&std::fs::read(service.join("registration.json")).unwrap())
                .unwrap();
        let runtime_dir = std::path::PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
        let foreign = runtime_dir.join(format!(
            "zc.prepared.{}.{}.snapshot",
            "a".repeat(64),
            "b".repeat(32)
        ));
        std::fs::write(&foreign, b"corrupt unrelated snapshot").unwrap();
        let dir = zc::fsutil::SecureDir::open_owned_absolute(&bin, false).unwrap();
        let lease = dir
            .lock(".zc.binary.lock", std::time::Duration::from_secs(1))
            .unwrap();
        let out = Command::new(&binary)
            .args(["--service-run", record["id"].as_str().unwrap()])
            .output()
            .unwrap();
        assert!(!out.status.success());
        drop(lease);
        assert_eq!(
            snapshots(&runtime_dir),
            vec![foreign.clone()],
            "lease failure orphaned snapshot"
        );
        // Evidence::start fails before entering the normal instance cleanup scope.
        let log = runtime_dir.join("zc.log");
        std::fs::create_dir(&log).unwrap();
        let out = Command::new(&binary)
            .args(["--service-run", record["id"].as_str().unwrap()])
            .output()
            .unwrap();
        assert!(!out.status.success());
        assert_eq!(
            snapshots(&runtime_dir),
            vec![foreign.clone()],
            "evidence failure orphaned snapshot"
        );
        std::fs::remove_dir(log).unwrap();
        assert!(frozen.iter().all(|p| p.exists()));
        execute("start", Default::default(), &binary, &runner)
            .await
            .unwrap();
        execute("stop", Default::default(), &binary, &runner)
            .await
            .unwrap();
        assert_eq!(snapshots(&runtime_dir), vec![foreign.clone()]);
        assert_eq!(
            std::fs::read(foreign).unwrap(),
            b"corrupt unrelated snapshot"
        );
        assert_eq!(snapshots(&service).len(), 1);
    });
}

#[test]
fn successful_reconfiguration_retains_only_current_frozen_snapshot() {
    if !isolated("successful_reconfiguration_retains_only_current_frozen_snapshot") {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::{execute, install};
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin = home.join("bin"); std::fs::create_dir(&bin).unwrap();
        let binary = bin.join("zc"); std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
        let config = home.join("source.yaml");
        std::fs::write(&config, format!("external-controller: 127.0.0.1:{}\nproxy-groups:\n  - name: pick\n    type: select\n    proxies: [DIRECT, REJECT]\nrules: ['MATCH,pick']\n", port())).unwrap();
        cli(&binary, &["config", "load", config.to_str().unwrap()]);
        let runner = support::FakeManager::new(platform());
        execute("start", zc::service::PrepareOptions { port: Some(port()), ..Default::default() }, &binary, &runner).await.unwrap();
        let service = home.join(".local/state/zc/service");
        // Unknown state is never swept, even if it resembles a snapshot.
        let unrelated = service.join("unknown.snapshot");
        std::fs::write(&unrelated, b"retain unknown state").unwrap();
        for selected in ["REJECT", "DIRECT", "REJECT"] {
            cli(&binary, &["proxy", "select", "-g", "pick", "-p", selected]);
            let mixed = port();
            let next = execute("restart", zc::service::PrepareOptions { port: Some(mixed), ..Default::default() }, &binary, &runner).await.unwrap();
            assert_eq!(next["mixed_port"], mixed);
            assert_eq!(cli(&binary, &["status"])["data"]["selected_proxies"][0]["proxy"], selected);
            assert_eq!(snapshots(&service).len(), 2, "successful restart leaked frozen snapshots");
            let publisher = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("scripts/install/local-dev-install.sh");
            install(std::path::Path::new(env!("CARGO_BIN_EXE_zc")), &bin, &publisher, &runner).await.unwrap();
            assert_eq!(snapshots(&service).len(), 2, "successful install leaked captured snapshots");
        }
        execute("stop", Default::default(), &binary, &runner).await.unwrap();
        assert_eq!(snapshots(&service).len(), 2);
        assert_eq!(std::fs::read(unrelated).unwrap(), b"retain unknown state");
    });
}

#[test]
fn bounded_command_timeout_and_cancellation_kill_publisher_descendants() {
    runtime().block_on(async {
        for cancel in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().to_str().unwrap();
            let script = r#"import os, pathlib, time, sys
root = pathlib.Path(sys.argv[1])
if os.fork() == 0:
    (root / 'child').write_text(str(os.getpid()))
    while not (root / 'release').exists(): time.sleep(.01)
    (root / 'late-publication').write_text('unsafe')
    os._exit(0)
time.sleep(60)
"#;
            let args = vec!["-c".into(), script.into(), root.into()];
            let mut command = Box::pin(zc::user_service::run_bounded("/usr/bin/python3", &args));
            if cancel {
                tokio::select! {
                    result = &mut command => panic!("command returned early: {result:?}"),
                    _ = async { while !dir.path().join("child").exists() { tokio::time::sleep(std::time::Duration::from_millis(10)).await; } } => {}
                }
                // Dropping the actual future must terminate the whole command group.
            } else {
                assert!(command.as_mut().await.unwrap_err().to_string().contains("TIMEOUT"));
            }
            drop(command);
            std::fs::write(dir.path().join("release"), "").unwrap();
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            let late = dir.path().join("late-publication").exists();
            let pid: i32 = std::fs::read_to_string(dir.path().join("child")).unwrap().parse().unwrap();
            let _ = rustix::process::kill_process(rustix::process::Pid::from_raw(pid).unwrap(), rustix::process::Signal::KILL);
            assert!(!late, "descendant published after command returned/dropped (cancel={cancel})");
        }
    });
}

#[test]
fn local_install_signals_join_commands_before_returning_recovery_result() {
    use std::{os::unix::fs::PermissionsExt, time::Duration};
    for signal in [
        rustix::process::Signal::INT,
        rustix::process::Signal::TERM,
        rustix::process::Signal::KILL,
    ] {
        let home = tempfile::tempdir().unwrap();
        let target = home.path().join("bin");
        std::fs::create_dir(&target).unwrap();
        let binary = target.join("zc");
        std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
        let publisher = home.path().join("publisher.sh");
        std::fs::write(
            &publisher,
            r#"#!/bin/bash
set -eu
ps -o pgid= -p "$$" | tr -d ' ' > "$HOME/publisher-group"
# The recovery publisher completes without repeating the interruption barrier.
if [ -e "$HOME/entered" ]; then exit 0; fi
(
  echo "started" > "$HOME/descendant"
  touch "$HOME/entered"
  while [ ! -e "$HOME/release" ]; do sleep .01; done
  touch "$HOME/late-publication"
) &
wait
"#,
        )
        .unwrap();
        std::fs::set_permissions(&publisher, std::fs::Permissions::from_mode(0o700)).unwrap();
        let error_path = home.path().join("stderr");
        let mut child = Command::new(env!("CARGO_BIN_EXE_zc"))
            .env("ZC_INSTALL_BEFORE_PROMOTE_HOOK", &publisher)
            .args([
                "--local-install",
                env!("CARGO_BIN_EXE_zc"),
                target.to_str().unwrap(),
            ])
            .env("HOME", home.path().canonicalize().unwrap())
            .env_remove("XDG_RUNTIME_DIR")
            .stdout(std::process::Stdio::null())
            .stderr(std::fs::File::create(&error_path).unwrap())
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while !home.path().join("entered").exists() {
            let status = child.try_wait().unwrap();
            assert!(
                status.is_none(),
                "installer exited early {status:?}: {}",
                std::fs::read_to_string(&error_path).unwrap()
            );
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        rustix::process::kill_process(
            rustix::process::Pid::from_raw(child.id() as i32).unwrap(),
            signal,
        )
        .unwrap();
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "interrupted install failed to join"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        if signal == rustix::process::Signal::KILL {
            assert!(status.code().is_none(), "SIGKILL cannot run recovery");
            let backups: Vec<_> = std::fs::read_dir(&target)
                .unwrap()
                .map(|e| e.unwrap().path())
                .filter(|p| {
                    p.file_name()
                        .unwrap()
                        .to_str()
                        .unwrap()
                        .starts_with(".zc.recovery.")
                })
                .collect();
            assert_eq!(backups.len(), 1);
            assert_eq!(
                std::fs::read(&backups[0]).unwrap(),
                std::fs::read(&binary).unwrap()
            );
            // Model the documented operator step: identify and terminate the
            // retained publisher group before inspecting/restoring the target.
            let pgid: i32 = std::fs::read_to_string(home.path().join("publisher-group"))
                .unwrap()
                .trim()
                .parse()
                .unwrap();
            rustix::process::kill_process_group(
                rustix::process::Pid::from_raw(pgid).unwrap(),
                rustix::process::Signal::KILL,
            )
            .unwrap();
        }
        // Observe after all installation locks are available again.
        let dir =
            zc::fsutil::SecureDir::open_owned_absolute(&target.canonicalize().unwrap(), false)
                .unwrap();
        let _lock = dir.lock(".zc.binary.lock", Duration::from_secs(1)).unwrap();
        std::fs::write(home.path().join("release"), "").unwrap();
        std::thread::sleep(Duration::from_millis(200));
        let late = home.path().join("late-publication").exists();
        let error = std::fs::read_to_string(error_path).unwrap();
        if signal == rustix::process::Signal::KILL {
            assert!(!late, "manual publisher cleanup failed");
            continue;
        }
        assert_eq!(
            status.code(),
            Some(1),
            "signal bypassed install recovery: {error}"
        );
        assert!(
            error.contains("INTERRUPTED") && error.contains("ROLLED_BACK"),
            "{error}"
        );
        assert!(
            !late,
            "descendant published after install locks were released"
        );
    }
}

#[test]
fn install_interruption_and_timeout_boundaries_preserve_truthful_recovery() {
    if !isolated("install_interruption_and_timeout_boundaries_preserve_truthful_recovery") {
        return;
    }
    runtime().block_on(async {
        use std::time::Duration;
        use zc::user_service::{execute, install_with_signals};
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin = home.join("bin");
        std::fs::create_dir(&bin).unwrap();
        let binary = bin.join("zc");
        std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
        // Make the old executable observably different while retaining a real
        // daemon and valid native signature. No user installation is touched.
        if cfg!(target_os = "macos") {
            assert!(
                Command::new("/usr/bin/codesign")
                    .args(["--force", "--sign", "-", "--identifier", "org.zc.test.old"])
                    .arg(&binary)
                    .output()
                    .unwrap()
                    .status
                    .success()
            );
        } else {
            use std::io::Write;
            std::fs::OpenOptions::new()
                .append(true)
                .open(&binary)
                .unwrap()
                .write_all(b"zc-old-test-build")
                .unwrap();
        }
        let old_bytes = std::fs::read(&binary).unwrap();
        assert_ne!(old_bytes, std::fs::read(env!("CARGO_BIN_EXE_zc")).unwrap());
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(platform());
        let mixed = port();
        execute(
            "enable",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(mixed),
                ..Default::default()
            },
            &binary,
            &runner,
        )
        .await
        .unwrap();
        let publisher = home.join("publisher.sh");
        let real_publisher = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("scripts/install/local-dev-install.sh");
        // All variable paths are passed as argv, not interpolated shell text.
        std::fs::write(
            &publisher,
            r#"#!/bin/bash
set -eu
phase="$(cat "$HOME/phase")"
pause() {
  if [ -e "$HOME/pause-$phase" ]; then
    rm "$HOME/pause-$phase"
    (
      touch "$HOME/entered"
      while [ ! -e "$HOME/release" ]; do sleep .01; done
      touch "$HOME/late-publication"
    ) &
    wait
  fi
}
if [ "$phase" = pre-publish ]; then pause; fi
/bin/bash "$(cat "$HOME/real-publisher")" "$@"
if [ "$phase" = post-publish ]; then pause; fi
"#,
        )
        .unwrap();
        std::fs::write(
            home.join("real-publisher"),
            real_publisher.to_str().unwrap(),
        )
        .unwrap();
        for phase in [
            "pre-stop",
            "post-stop",
            "pre-publish",
            "post-publish",
            "readiness-pending",
            "readiness-ready",
        ] {
            for signal in [
                Some(rustix::process::Signal::INT),
                Some(rustix::process::Signal::TERM),
                None,
            ] {
                let old = execute("start", Default::default(), &binary, &runner)
                    .await
                    .unwrap();
                let record_path = home.join(".local/state/zc/service/registration.json");
                let old_record = std::fs::read(&record_path).unwrap();
                std::fs::write(home.join("phase"), phase).unwrap();
                std::fs::write(home.join(format!("pause-{phase}")), "").unwrap();
                for name in ["entered", "release", "late-publication"] {
                    let _ = std::fs::remove_file(home.join(name));
                }
                let transaction = install_with_signals(
                    std::path::Path::new(env!("CARGO_BIN_EXE_zc")),
                    &bin,
                    &publisher,
                    &runner,
                );
                let interrupt = async {
                    let deadline = tokio::time::Instant::now() + Duration::from_secs(12);
                    while !home.join("entered").exists() {
                        assert!(
                            tokio::time::Instant::now() < deadline,
                            "missing barrier: {phase}"
                        );
                        tokio::time::sleep(Duration::from_millis(10)).await;
                    }
                    if phase == "readiness-ready" {
                        loop {
                            if let Ok(status) = zc::daemon::status().await
                                && status["state"] == "running"
                                && status["pid"] != old["pid"]
                            {
                                break;
                            }
                            assert!(
                                tokio::time::Instant::now() < deadline,
                                "new daemon failed to reach readiness"
                            );
                            tokio::time::sleep(Duration::from_millis(10)).await;
                        }
                    }
                    if let Some(signal) = signal {
                        rustix::process::kill_process(rustix::process::getpid(), signal).unwrap();
                    }
                };
                let (result, ()) = tokio::join!(transaction, interrupt);
                let error = result.unwrap_err();
                let message = format!("{error:#}");
                assert!(
                    message.contains(if signal.is_some() {
                        "INTERRUPTED"
                    } else {
                        "TIMEOUT"
                    }),
                    "{phase}: {message}"
                );
                let state = execute("status", Default::default(), &binary, &runner)
                    .await
                    .unwrap();
                assert_eq!(state["enabled"], true, "{phase}: {message}");
                assert_eq!(state["running"], true, "{phase}: {message}");
                assert_eq!(state["mixed_port"], mixed);
                if phase == "readiness-ready" {
                    // The manager command's result was lost: the new process is
                    // not a captured startup PID, so recovery must not stop it.
                    assert!(message.contains("RECOVERY_FAILED"), "{message}");
                    assert_ne!(state["pid"], old["pid"]);
                    assert!(std::fs::read_dir(&bin).unwrap().any(|e| {
                        e.unwrap()
                            .file_name()
                            .to_str()
                            .unwrap()
                            .starts_with(".zc.recovery.")
                    }));
                } else {
                    assert!(message.contains("ROLLED_BACK"), "{phase}: {message}");
                    if phase == "pre-stop" {
                        assert_eq!(state["pid"], old["pid"]);
                        assert_eq!(std::fs::read(&record_path).unwrap(), old_record);
                    }
                }
                if phase != "readiness-ready" {
                    assert_eq!(
                        std::fs::read(&binary).unwrap(),
                        old_bytes,
                        "{phase}: old binary not restored"
                    );
                }
                // The daemon holds a shared binary lease. An additional shared
                // lease proves the exclusive publisher lease has been released.
                let dir = zc::fsutil::SecureDir::open_owned_absolute(&bin, false).unwrap();
                let _lease = dir
                    .shared_lock(".zc.binary.lock", Duration::from_secs(1))
                    .unwrap();
                let _install = dir
                    .lock(".zc.install.guard", Duration::from_secs(1))
                    .unwrap();
                std::fs::write(home.join("release"), "").unwrap();
                tokio::time::sleep(Duration::from_millis(150)).await;
                assert!(
                    !home.join("late-publication").exists(),
                    "late write at {phase}"
                );
                println!(
                    "boundary={phase} signal={signal:?} recovery={} late_publication=false",
                    if phase == "readiness-ready" {
                        "uncertain-retained"
                    } else {
                        "restored"
                    }
                );
                execute("stop", Default::default(), &binary, &runner)
                    .await
                    .unwrap();
                if phase == "readiness-ready" {
                    std::fs::write(&binary, &old_bytes).unwrap();
                }
            }
        }
    });
}

#[test]
fn foreground_cancellation_cleans_authenticated_snapshot_and_preserves_corruption() {
    if !isolated("foreground_cancellation_cleans_authenticated_snapshot_and_preserves_corruption") {
        return;
    }
    runtime().block_on(async {
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let dir = std::path::PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        for corrupt in [false, true] {
            let mixed = port();
            let mut foreground = Box::pin(zc::daemon::run_foreground(zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()), port: Some(mixed), ..Default::default()
            }));
            let ready = async {
                let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
                loop {
                    if let Ok(bytes) = std::fs::read(dir.join("zc.daemon.json"))
                        && let Ok(record) = serde_json::from_slice::<serde_json::Value>(&bytes)
                        && record["ready"] == true { break; }
                    assert!(tokio::time::Instant::now() < deadline);
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                }
            };
            tokio::select! {
                result = &mut foreground => panic!("foreground exited before cancellation: {result:?}"),
                () = ready => {}
            }
            let owned = snapshots(&dir);
            assert_eq!(owned.len(), 1);
            if corrupt { std::fs::write(&owned[0], b"retain corrupted state").unwrap(); }
            drop(foreground);
            assert!(!dir.join("zc.daemon.json").exists());
            if corrupt {
                assert_eq!(std::fs::read(&owned[0]).unwrap(), b"retain corrupted state");
            } else { assert!(snapshots(&dir).is_empty()); }
            // Cancellation releases listeners/tasks and instance ownership too.
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            let listener = std::net::TcpListener::bind(("127.0.0.1", mixed)).unwrap();
            drop(listener);
        }
    });
}

#[test]
fn failed_stop_with_changed_manager_instance_restores_permission_without_stopping_either() {
    if !isolated(
        "failed_stop_with_changed_manager_instance_restores_permission_without_stopping_either",
    ) {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::execute;
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(platform());
        let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
        let old = execute(
            "start",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(port()),
                ..Default::default()
            },
            binary,
            &runner,
        )
        .await
        .unwrap();
        let record = home.join(".local/state/zc/service/registration.json");
        let before = std::fs::read(&record).unwrap();
        let manager_path = home.join("fake-manager.json");
        let manager_before = std::fs::read(&manager_path).unwrap();
        let mut other = Command::new("/bin/sleep").arg("60").spawn().unwrap();
        std::fs::write(home.join("replace-stop-pid"), other.id().to_string()).unwrap();
        let result = execute(
            "restart",
            zc::service::PrepareOptions {
                port: Some(port()),
                ..Default::default()
            },
            binary,
            &runner,
        )
        .await;
        let other_alive = other.try_wait().unwrap().is_none();
        let unchanged = before == std::fs::read(&record).unwrap();
        let actual = cli(binary, &["status"]);
        let status = execute("status", Default::default(), binary, &runner).await;
        // Restore only the test manager fixture before assertions/teardown.
        std::fs::write(manager_path, manager_before).unwrap();
        other.kill().unwrap();
        other.wait().unwrap();
        execute("stop", Default::default(), binary, &runner)
            .await
            .unwrap();
        let error = result.unwrap_err();
        assert!(error.to_string().contains("uncertain"), "{error:#}");
        assert!(unchanged && other_alive);
        assert_eq!(actual["data"]["pid"], old["pid"]);
        assert_eq!(actual["data"]["state"], "running");
        assert!(
            status.is_err(),
            "mismatched manager must not report success"
        );
    });
}

#[test]
fn uncertain_command_cleanup_retains_backup_without_attempting_publication_or_recovery() {
    if !isolated(
        "uncertain_command_cleanup_retains_backup_without_attempting_publication_or_recovery",
    ) {
        return;
    }
    runtime().block_on(async {
        use zc::user_service::{execute, install};
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin = home.join("bin");
        std::fs::create_dir(&bin).unwrap();
        let binary = bin.join("zc");
        std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(platform());
        let old = execute(
            "start",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(port()),
                ..Default::default()
            },
            &binary,
            &runner,
        )
        .await
        .unwrap();
        std::fs::write(home.join("cleanup-failed-once"), "").unwrap();
        let publisher = home.join("publisher.sh");
        std::fs::write(&publisher, "touch \"$HOME/publisher-ran\"\nexit 1\n").unwrap();
        let error = install(
            std::path::Path::new(env!("CARGO_BIN_EXE_zc")),
            &bin,
            &publisher,
            &runner,
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("RECOVERY_FAILED"), "{error:#}");
        assert!(!home.join("publisher-ran").exists());
        assert!(std::fs::read_dir(&bin).unwrap().any(|e| {
            e.unwrap()
                .file_name()
                .to_str()
                .unwrap()
                .starts_with(".zc.recovery.")
        }));
        let current = execute("status", Default::default(), &binary, &runner)
            .await
            .unwrap();
        assert_eq!(current["pid"], old["pid"]);
        execute("stop", Default::default(), &binary, &runner)
            .await
            .unwrap();
    });
}

fn install_source_link_count(links: u64) {
    use std::{fs, os::unix::fs::MetadataExt};
    let home = tempfile::tempdir().unwrap();
    let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
    // Do not depend on Cargo's platform-specific artifact link count.
    let source = home.path().join("source-zc");
    fs::copy(binary, &source).unwrap();
    let alias = home.path().join("source-alias");
    if links == 2 {
        fs::hard_link(&source, &alias).unwrap();
    }
    let before = fs::metadata(&source).unwrap();
    assert_eq!(before.nlink(), links);
    let bytes = fs::read(&source).unwrap();
    let target = home.path().join("bin with spaces");
    let out = Command::new(binary)
        .arg("--local-install")
        .arg(&source)
        .arg(&target)
        .current_dir(home.path())
        .env("HOME", home.path().canonicalize().unwrap())
        .env_remove("XDG_RUNTIME_DIR")
        .output()
        .unwrap();
    assert!(out.status.success(), "source nlink={links}: {out:?}");
    let installed = fs::metadata(target.join("zc")).unwrap();
    assert_ne!(
        (installed.dev(), installed.ino()),
        (before.dev(), before.ino())
    );
    assert_eq!(installed.nlink(), 1);
    assert_eq!(fs::read(target.join("zc")).unwrap(), bytes);
    for path in std::iter::once(&source).chain((links == 2).then_some(&alias)) {
        let after = fs::metadata(path).unwrap();
        assert_eq!((after.dev(), after.ino()), (before.dev(), before.ino()));
        assert_eq!(after.nlink(), links);
        assert_eq!(after.mode(), before.mode());
        assert_eq!(fs::read(path).unwrap(), bytes);
    }
    assert!(!home.path().join(".local/state/zc/service").exists());
    assert!(
        !home
            .path()
            .join(".local/state/zc/runtime/zc.daemon.json")
            .exists()
    );
}

#[test]
fn install_source_single_link_control() {
    install_source_link_count(1);
}

#[test]
fn install_source_stable_hardlinks_are_captured_into_independent_target() {
    install_source_link_count(2);
}

#[test]
fn install_source_hardlinks_do_not_allow_hardlinked_installed_target() {
    use std::{fs, os::unix::fs::MetadataExt};
    let home = tempfile::tempdir().unwrap();
    let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
    let source = home.path().join("source-zc");
    fs::copy(binary, &source).unwrap();
    fs::hard_link(&source, home.path().join("source-alias")).unwrap();
    let target_dir = home.path().join("bin");
    fs::create_dir(&target_dir).unwrap();
    let target = target_dir.join("zc");
    fs::copy(binary, &target).unwrap();
    let alias = home.path().join("target-alias");
    fs::hard_link(&target, &alias).unwrap();
    let before = fs::metadata(&target).unwrap();
    let bytes = fs::read(&target).unwrap();
    let out = Command::new(binary)
        .arg("--local-install")
        .arg(&source)
        .arg(&target_dir)
        .current_dir(home.path())
        .env("HOME", home.path().canonicalize().unwrap())
        .env_remove("XDG_RUNTIME_DIR")
        .output()
        .unwrap();
    assert!(!out.status.success(), "{out:?}");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("SERVICE_TARGET_INVALID"),
        "{out:?}"
    );
    for path in [&target, &alias, &source, &home.path().join("source-alias")] {
        assert_eq!(fs::metadata(path).unwrap().nlink(), 2);
        assert_eq!(fs::read(path).unwrap(), bytes);
    }
    let after = fs::metadata(&target).unwrap();
    assert_eq!((after.dev(), after.ino()), (before.dev(), before.ino()));
    assert!(!fs::read_dir(target_dir).unwrap().any(|entry| {
        let name = entry.unwrap().file_name();
        let name = name.to_string_lossy();
        name.starts_with(".zc.candidate.") || name.starts_with(".zc.recovery.")
    }));
}

#[test]
fn private_install_entry_embeds_publisher_and_requires_only_source_and_target() {
    let home = tempfile::tempdir().unwrap();
    let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
    let probe = Command::new(binary)
        .arg("--install-check")
        .env("HOME", home.path())
        .output()
        .unwrap();
    assert!(probe.status.success(), "{probe:?}");
    assert_eq!(probe.stdout, b"zc-release-install-v1\n");
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
    for args in [
        vec!["--local-install"],
        vec!["--local-install", "source"],
        vec!["--local-install", "source", "target", "untrusted-publisher"],
        vec!["--install-check", "extra"],
    ] {
        let out = Command::new(binary)
            .args(args)
            .env("HOME", home.path())
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(2), "{out:?}");
    }
    let target = home.path().join("bin with spaces");
    let out = Command::new(binary)
        .arg("--local-install")
        .arg(binary)
        .arg(&target)
        .current_dir(home.path())
        .env("HOME", home.path().canonicalize().unwrap())
        .env_remove("XDG_RUNTIME_DIR")
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    assert_eq!(
        std::fs::read(target.join("zc")).unwrap(),
        std::fs::read(binary).unwrap()
    );
    assert!(!std::fs::read_dir(target).unwrap().any(|e| {
        e.unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".zc.publisher.")
    }));
}

fn stopped_registration_rejects_manual_preparation(action: &str) {
    runtime().block_on(async {
        use zc::user_service::execute;
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
        let config = home.join("service.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(platform());
        let registered = execute(
            "enable",
            zc::service::PrepareOptions {
                config: Some(config.to_str().unwrap().into()),
                port: Some(port()),
                ..Default::default()
            },
            binary,
            &runner,
        )
        .await
        .unwrap();
        assert_eq!(registered["registered"], true);
        assert_eq!(registered["running"], false);
        let managed = home.join("managed.yaml");
        std::fs::write(
            &managed,
            format!(
                "external-controller: 127.0.0.1:{}\nrules: ['MATCH,DIRECT']\n",
                port()
            ),
        )
        .unwrap();
        cli(binary, &["config", "load", managed.to_str().unwrap()]);
        let catalog = home.join(".config/zc/state-v2.json");
        let before = std::fs::read(&catalog).unwrap();
        assert!(!String::from_utf8_lossy(&before).contains("auto_controller_secret"));
        let mut command = Command::new(binary);
        command.arg(action).arg("--json");
        if action == "restart" {
            command.args(["--port", &port().to_string()]);
        }
        let out = command.output().unwrap();
        assert!(!out.status.success(), "{out:?}");
        let response: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(response["error"]["code"], "SERVICE_OWNED", "{response}");
        assert_eq!(
            std::fs::read(&catalog).unwrap(),
            before,
            "rejected command changed catalog"
        );
        if action == "restart" {
            use std::os::unix::fs::PermissionsExt;
            let script = home.join("override.sh");
            let marker = home.join("override-executed");
            std::fs::write(
                &script,
                format!(
                    "#!/bin/sh\n: > '{}'\nprintf 'mode: rule\\n'\n",
                    marker.display()
                ),
            )
            .unwrap();
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
            let out = Command::new(binary)
                .args([
                    "restart",
                    "-c",
                    "managed",
                    "--port",
                    &port().to_string(),
                    "--override-script",
                    script.to_str().unwrap(),
                    "--json",
                ])
                .output()
                .unwrap();
            assert!(!out.status.success(), "{out:?}");
            let response: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(response["error"]["code"], "SERVICE_OWNED", "{response}");
            assert!(!marker.exists(), "rejected restart executed override");
            assert_eq!(std::fs::read(&catalog).unwrap(), before);
        }
        assert_eq!(
            execute("status", Default::default(), binary, &runner)
                .await
                .unwrap()["running"],
            false
        );
    });
}

fn registered_config_changes(running: bool) {
    runtime().block_on(async {
        use std::io::{Read, Write};
        use std::time::{Duration, Instant};
        use zc::store::{Bundle, Metadata, Store};
        use zc::user_service::execute;

        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let binary = std::path::Path::new(env!("CARGO_BIN_EXE_zc"));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}/subscription", listener.local_addr().unwrap());
        let store = Store::open(home.join(".config/zc")).unwrap();
        let bundle = Bundle::from_memory(
            b"mode: rule\nrules: ['MATCH,DIRECT']\n",
            None,
            Default::default(),
        )
        .unwrap();
        store
            .publish(
                &store.load().unwrap().token,
                "subscription",
                None,
                &bundle,
                Metadata {
                    url: Some(url),
                    ..Default::default()
                },
                true,
            )
            .unwrap();
        let runner = support::FakeManager::new(platform());
        let initial = execute(
            if running { "start" } else { "enable" },
            zc::service::PrepareOptions {
                config: Some("subscription".into()),
                port: Some(port()),
                ..Default::default()
            },
            binary,
            &runner,
        )
        .await
        .unwrap();
        assert_eq!(initial["registered"], true);
        assert_eq!(initial["running"], running);
        if running {
            let error = zc::daemon::capture_restart().await.err().unwrap();
            assert!(error.to_string().starts_with("SERVICE_OWNED:"), "{error:#}");
            for action in ["restart", "reload"] {
                let output = Command::new(binary)
                    .args([action, "--json"])
                    .output()
                    .unwrap();
                assert!(!output.status.success(), "{output:?}");
                let response: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
                assert_eq!(response["error"]["code"], "SERVICE_OWNED", "{response}");
            }
        } else {
            let captured = zc::daemon::capture_restart().await.unwrap();
            assert!(captured.prepared.is_none());
            let prepared = zc::service::prepare(zc::service::PrepareOptions {
                config: Some("subscription".into()),
                port: Some(port()),
                ..Default::default()
            })
            .await
            .unwrap();
            let error = zc::daemon::restart_checked(captured, prepared)
                .await
                .unwrap_err();
            assert!(error.to_string().starts_with("SERVICE_OWNED:"), "{error:#}");
        }
        let registration = home.join(".local/state/zc/service/registration.json");
        let registered = std::fs::read(&registration).unwrap();
        let server = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(10);
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(
                            Instant::now() < deadline,
                            "subscription request did not arrive"
                        );
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(e) => panic!("accept failed: {e}"),
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut header = Vec::new();
            let mut byte = [0];
            while !header.ends_with(b"\r\n\r\n") && header.len() < 16384 {
                stream.read_exact(&mut byte).unwrap();
                header.push(byte[0]);
            }
            assert!(header.ends_with(b"\r\n\r\n"));
            let body = "mode: global\nrules: ['MATCH,REJECT']\n";
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let script = home.join("override.lua");
        std::fs::write(&script, "return {mode = 'direct'}").unwrap();
        let mut results = Vec::new();
        for (args, mode, error_code) in [
            (
                vec!["config", "update"],
                "global",
                "CONFIG_UPDATE_APPLY_FAILED",
            ),
            (
                vec!["config", "override", script.to_str().unwrap()],
                "direct",
                "CONFIG_OVERRIDE_APPLY_FAILED",
            ),
            (
                vec!["config", "override", "--clear"],
                "global",
                "CONFIG_OVERRIDE_APPLY_FAILED",
            ),
        ] {
            let before = store.load().unwrap();
            let output = Command::new(binary)
                .args(&args)
                .arg("--json")
                .output()
                .unwrap();
            let response: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
            let after = store.load().unwrap();
            assert_ne!(before.token, after.token);
            assert_ne!(before.catalog.active, after.catalog.active);
            assert_eq!(
                after.catalog.active.as_ref().unwrap().revision,
                store.get("subscription").unwrap().head
            );
            let dump = cli(binary, &["config", "dump"]);
            assert_eq!(dump["mode"], mode);
            assert_eq!(dump["rules"], serde_json::json!(["MATCH,REJECT"]));
            let status = execute("status", Default::default(), binary, &runner)
                .await
                .unwrap();
            assert_eq!(status["running"], running);
            assert_eq!(status["pid"], initial["pid"]);
            assert_eq!(status["enabled"], initial["enabled"]);
            assert_eq!(std::fs::read(&registration).unwrap(), registered);
            results.push((output.status.success(), response, error_code));
        }
        server.join().unwrap();
        for (success, response, error_code) in results {
            if running {
                assert!(!success, "{response}");
                assert_eq!(response["error"]["code"], error_code, "{response}");
            } else {
                assert!(success, "{response}");
                assert_eq!(response["data"]["applied"], false, "{response}");
            }
        }
    });
}

#[test]
fn stopped_registered_config_changes_persist_without_apply() {
    if isolated("stopped_registered_config_changes_persist_without_apply") {
        registered_config_changes(false);
    }
}

#[test]
fn running_service_config_changes_reject_manual_apply() {
    if isolated("running_service_config_changes_reject_manual_apply") {
        registered_config_changes(true);
    }
}

#[test]
fn stopped_registered_restart_rejects_before_preparation() {
    if isolated("stopped_registered_restart_rejects_before_preparation") {
        stopped_registration_rejects_manual_preparation("restart");
    }
}

#[test]
fn stopped_registered_reload_reports_service_ownership() {
    if isolated("stopped_registered_reload_reports_service_ownership") {
        stopped_registration_rejects_manual_preparation("reload");
    }
}

#[test]
fn launchd_arguments_require_complete_exact_registered_invocation() {
    if !isolated("launchd_arguments_require_complete_exact_registered_invocation")
        || platform() != zc::user_service::Platform::Launchd
    {
        return;
    }
    runtime().block_on(async {
        use std::{future::Future, path::Path, pin::Pin};
        use zc::user_service::{CommandOutput, CommandRunner, Platform, execute};
        struct PrintReply<'a> {
            inner: &'a support::FakeManager,
            stdout: String,
        }
        impl CommandRunner for PrintReply<'_> {
            fn platform(&self) -> Platform {
                Platform::Launchd
            }
            fn authorize<'a>(&'a self, home: &'a Path) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + 'a>> {
                self.inner.authorize(home)
            }
            fn run<'a>(&'a self, program: &'a str, args: &'a [String]) -> Pin<Box<dyn Future<Output = anyhow::Result<CommandOutput>> + 'a>> {
                Box::pin(async move {
                    if args.first().is_some_and(|arg| arg == "print") {
                        Ok(CommandOutput { code: 0, stdout: self.stdout.clone(), stderr: String::new() })
                    } else {
                        self.inner.run(program, args).await
                    }
                })
            }
        }
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let bin = home.join("bin}valid");
        std::fs::create_dir(&bin).unwrap();
        let binary = bin.join("zc");
        std::fs::copy(env!("CARGO_BIN_EXE_zc"), &binary).unwrap();
        let config = home.join("source.yaml");
        std::fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let runner = support::FakeManager::new(Platform::Launchd);
        let started = execute("start", zc::service::PrepareOptions {
            config: Some(config.to_str().unwrap().into()),
            port: Some(port()),
            ..Default::default()
        }, &binary, &runner).await.unwrap();
        let private = home.join(".local/state/zc/service");
        let record: serde_json::Value = serde_json::from_slice(&std::fs::read(private.join("registration.json")).unwrap()).unwrap();
        let id = record["id"].as_str().unwrap();
        let arguments = format!("\targuments = {{\n\t\t{}\n\t\t--service-run\n\t\t{id}\n\t}}", binary.display());
        // Match launchctl's indented block shape, with more fields after arguments.
        let stdout = format!("gui/501/org.zc.user = {{\n\tpath = {}\n\tprogram = {}\n{arguments}\n\tpid = {}\n\tenvironment = {{\n\t\tHOME => {}\n\t}}\n}}\n",
            private.join("org.zc.user.plist").display(), binary.display(), started["pid"], home.display());
        let reply = PrintReply { inner: &runner, stdout: stdout.clone() };
        assert_eq!(execute("status", Default::default(), &binary, &reply).await.unwrap()["pid"], started["pid"]);
        for bad in [
            stdout.replace(&format!("program = {}", binary.display()), "program = /foreign/zc"),
            stdout.replace(&arguments, &arguments.replace(&binary.display().to_string(), "/foreign/zc")),
            stdout.replace("--service-run", "--daemon-run"),
            stdout.replace(id, "foreign-service-id"),
            stdout.replace(&arguments, &arguments.replace("\n\t}", "\n\t\textra\n\t}")),
            stdout.replace("arguments = {", "other-arguments = {"),
            stdout.split_once("\n\t}").unwrap().0.to_owned(),
        ] {
            let reply = PrintReply { inner: &runner, stdout: bad };
            let error = execute("status", Default::default(), &binary, &reply).await.unwrap_err();
            assert!(error.to_string().contains("SERVICE_FOREIGN"), "{error:#}");
        }
        assert_eq!(execute("status", Default::default(), &binary, &runner).await.unwrap()["pid"], started["pid"]);
        execute("stop", Default::default(), &binary, &runner).await.unwrap();
    });
}
