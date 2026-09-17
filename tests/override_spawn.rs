//! Public API regressions with real children and scoped native spawn fault injection.
//! The injection tests retry policy, not the cause of native Linux ETXTBSY.
#![cfg(any(target_os = "macos", target_os = "linux"))]

use std::{
    fs,
    future::{Future, poll_fn},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    task::Poll,
    time::{Duration, Instant},
};
use zc::override_script::{Invocation, OverrideArg, Script, execute_bytes};

const PATCH: &[u8] = b"mode: global\n";

fn script(slow: bool) -> Script {
    Script {
        name: "frozen.sh".into(),
        bytes: format!(
            "#!/bin/sh\nprintf 'frozen %s\\n' \"$$\" >> \"$ZC_OVERRIDE_ARG_MARKER\"\n{}printf 'mode: global\\n'\n",
            if slow { "/bin/sleep 0.75\n" } else { "" },
        )
        .into_bytes(),
    }
}

fn records(root: &Path) -> Vec<(String, PathBuf)> {
    let text = fs::read_to_string(root.join("calls")).expect("spawn hook did not fire");
    eprint!("{text}");
    let rows: Vec<_> = text
        .lines()
        .enumerate()
        .map(|(index, line)| {
            let fields: Vec<_> = line.splitn(3, ' ').collect();
            assert_eq!(fields.len(), 3, "invalid spawn marker: {line}");
            assert_eq!(fields[0].parse::<usize>().unwrap(), index + 1);
            (fields[1].to_owned(), PathBuf::from(fields[2]))
        })
        .collect();
    assert!(!rows.is_empty(), "spawn hook did not fire");
    for (_, path) in &rows {
        assert_eq!(path.parent().unwrap(), root.join("tmp"));
        assert_eq!(path, &rows[0].1, "retries must use the same frozen file");
    }
    rows
}

fn assert_removed(root: &Path, rows: &[(String, PathBuf)]) {
    for (_, path) in rows {
        assert!(
            !path.exists(),
            "temporary script leaked: {}",
            path.display()
        );
    }
    assert_eq!(fs::read_dir(root.join("tmp")).unwrap().count(), 0);
}

fn assert_launched_once(marker: &Path) {
    let text = fs::read_to_string(marker).expect("real child did not run");
    let lines: Vec<_> = text.lines().collect();
    assert_eq!(lines.len(), 1, "more than one real child: {text}");
    let pid = lines[0].strip_prefix("frozen ").unwrap();
    assert!(pid.parse::<u32>().unwrap() > 0);
}

#[tokio::test(flavor = "current_thread")]
async fn spawn_fault_child() {
    let Some(root) = std::env::var_os("ZC_SPAWN_ROOT") else {
        return;
    };
    let root = Path::new(&root);
    let case = std::env::var("ZC_SPAWN_CASE").unwrap();
    let marker = root.join("real child ' marker");
    let script = script(case == "shared-budget");
    let timeout_ms = match case.as_str() {
        "persistent" | "cancel" => 200,
        "shared-budget" => 1000,
        _ => 2000,
    };
    let invocation = Invocation {
        timeout_ms,
        // This path deliberately does not exist: only the frozen bytes may execute.
        script_path: root.join("missing-original.sh").to_str().unwrap().into(),
        args: vec![OverrideArg {
            key: "marker".into(),
            value: marker.to_str().unwrap().into(),
        }],
        ..Invocation::default()
    };
    let started = Instant::now();
    let mut execution = Box::pin(execute_bytes(&script, &invocation));
    if case == "cancel" {
        // Stop at the first pending retry wait. Timer coalescing/preemption may
        // affect how many attempts fit in one poll; cancellation must stop them.
        let first_poll = poll_fn(|cx| Poll::Ready(execution.as_mut().poll(cx))).await;
        drop(execution);
        let before = records(root);
        assert_removed(root, &before);
        assert!(!marker.exists(), "child launched before cancellation");
        let log = fs::read(root.join("calls")).unwrap();
        // Keep the runtime alive beyond the original deadline, detecting detached
        // retries as well as immediate retries after the future was dropped.
        tokio::time::sleep(Duration::from_millis(u64::from(timeout_ms) + 100)).await;
        assert_eq!(
            fs::read(root.join("calls")).unwrap(),
            log,
            "late spawn attempt"
        );
        assert!(!marker.exists(), "child launched after cancellation");
        assert_removed(root, &before);
        assert!(
            before.iter().all(|(action, _)| action == "INJECT_ETXTBSY"),
            "retry wait launched a child"
        );
        assert!(
            first_poll.is_pending(),
            "retry wait must be cancellable; got {first_poll:?}"
        );
        return;
    }

    // Independent harness watchdog, not a larger product timeout.
    let result = tokio::time::timeout(Duration::from_secs(4), execution)
        .await
        .expect("execute_bytes exceeded the harness watchdog");
    let elapsed = started.elapsed();
    let rows = records(root);
    assert_removed(root, &rows);
    eprintln!("case={case} elapsed={elapsed:?} result={result:?}");
    match case.as_str() {
        "success" => {
            let result = result.expect("transient ETXTBSY must eventually execute frozen bytes");
            let failures: usize = std::env::var("ZC_SPAWN_FAILURES").unwrap().parse().unwrap();
            assert_eq!(rows.len(), failures + 1);
            assert!(
                rows[..failures]
                    .iter()
                    .all(|(action, _)| action == "INJECT_ETXTBSY")
            );
            assert_eq!(rows[failures].0, "FORWARD");
            assert_launched_once(&marker);
            assert_eq!(result.patch_bytes, PATCH);
            assert_eq!(result.script, script);
        }
        "persistent" | "shared-budget" => {
            let error = result.expect_err("retries and child must share the original deadline");
            assert!(
                error.to_string().starts_with("OVERRIDE_SCRIPT_TIMEOUT:"),
                "{error:#}"
            );
            let budget = Duration::from_millis(timeout_ms.into());
            assert!(elapsed >= budget, "deadline expired early: {elapsed:?}");
            // Allow normal scheduler/cleanup latency without changing Invocation.
            assert!(
                elapsed < budget + Duration::from_millis(500),
                "deadline reset: {elapsed:?}"
            );
            if case == "persistent" {
                assert!(rows.len() >= 2, "no retry occurred");
                assert!(rows.len() <= timeout_ms as usize / 5 + 2, "busy retry loop");
                assert!(rows.iter().all(|(action, _)| action == "INJECT_ETXTBSY"));
                assert!(!marker.exists(), "persistent ETXTBSY launched a child");
            } else {
                assert!(rows.len() >= 3, "no sustained retry wait occurred");
                assert!(
                    rows[..rows.len() - 1]
                        .iter()
                        .all(|(action, _)| action == "INJECT_ETXTBSY")
                );
                assert_eq!(rows.last().unwrap().0, "FORWARD");
                assert_launched_once(&marker);
            }
            let log = fs::read(root.join("calls")).unwrap();
            tokio::time::sleep(Duration::from_millis(50)).await;
            assert_eq!(
                fs::read(root.join("calls")).unwrap(),
                log,
                "retry after deadline"
            );
            assert_removed(root, &rows);
            if case == "persistent" {
                assert!(!marker.exists(), "late child after deadline");
            }
        }
        "permission" => {
            let error = result.expect_err("EACCES must not be retried or bypassed");
            assert!(
                error
                    .to_string()
                    .starts_with("OVERRIDE_SCRIPT_EXEC_FAILED:"),
                "{error:#}"
            );
            assert_eq!(
                error
                    .downcast_ref::<std::io::Error>()
                    .unwrap()
                    .raw_os_error(),
                Some(libc::EACCES)
            );
            assert_eq!(rows.len(), 1);
            assert_eq!(rows[0].0, "INJECT_EACCES");
            assert!(
                !marker.exists(),
                "permission failure used an alternate interpreter"
            );
            assert!(
                elapsed < Duration::from_millis(500),
                "permission failure waited: {elapsed:?}"
            );
        }
        _ => panic!("unknown spawn scenario: {case}"),
    }
}

struct Helper {
    child: Child,
}

impl Drop for Helper {
    fn drop(&mut self) {
        // Fixture scripts are finite. Never signal a PID read from a marker.
        if !matches!(self.child.try_wait(), Ok(Some(_))) {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

fn run(case: &str, failures: i32) {
    use std::os::unix::{fs::DirBuilderExt, process::CommandExt};
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let library = root.join(if cfg!(target_os = "macos") {
        "fault.dylib"
    } else {
        "fault.so"
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
        "/tests/support/override_spawn_fault.c"
    ));
    if cfg!(target_os = "linux") {
        cc.arg("-ldl");
    }
    let compiled = cc
        .output()
        .expect("cc is required for spawn fault injection");
    assert!(
        compiled.status.success(),
        "{}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    for dir in ["home", "config", "data", "cache", "state", "runtime", "tmp"] {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join(dir))
            .unwrap();
    }
    fs::write(root.join("expected"), script(case == "shared-budget").bytes).unwrap();
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            "spawn_fault_child",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_clear()
        .current_dir(&root)
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", root.join("home"))
        .env("XDG_CONFIG_HOME", root.join("config"))
        .env("XDG_CONFIG_DIRS", root.join("config"))
        .env("XDG_DATA_HOME", root.join("data"))
        .env("XDG_DATA_DIRS", root.join("data"))
        .env("XDG_CACHE_HOME", root.join("cache"))
        .env("XDG_STATE_HOME", root.join("state"))
        .env("XDG_RUNTIME_DIR", root.join("runtime"))
        .env("TMPDIR", root.join("tmp"))
        .env("TMP", root.join("tmp"))
        .env("TEMP", root.join("tmp"))
        .env("ZC_SPAWN_ROOT", &root)
        .env("ZC_SPAWN_CASE", case)
        .env("ZC_SPAWN_FAILURES", failures.to_string())
        // Consume real time, not an assumed number of scheduler ticks.
        .env(
            "ZC_SPAWN_BUSY_MS",
            if case == "shared-budget" { "400" } else { "0" },
        )
        .env(
            "ZC_SPAWN_ERROR",
            if case == "permission" {
                "EACCES"
            } else {
                "ETXTBSY"
            },
        )
        .env("ZC_SPAWN_EXPECTED", root.join("expected"))
        .env("ZC_SPAWN_LOG", root.join("calls"))
        .env(
            if cfg!(target_os = "macos") {
                "DYLD_INSERT_LIBRARIES"
            } else {
                "LD_PRELOAD"
            },
            &library,
        )
        .stdin(Stdio::null())
        .stdout(fs::File::create(root.join("stdout")).unwrap())
        .stderr(fs::File::create(root.join("stderr")).unwrap())
        .process_group(0);
    let mut helper = Helper {
        child: command.spawn().unwrap(),
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = helper.child.try_wait().unwrap() {
            break status;
        }
        assert!(
            Instant::now() < deadline,
            "spawn helper watchdog expired: {}",
            fs::read_to_string(root.join("stderr")).unwrap()
        );
        std::thread::sleep(Duration::from_millis(10));
    };
    let stdout = fs::read_to_string(root.join("stdout")).unwrap();
    let stderr = fs::read_to_string(root.join("stderr")).unwrap();
    let calls = fs::read_to_string(root.join("calls")).unwrap_or_default();
    assert!(
        !calls.is_empty(),
        "spawn hook missed: {status}\n{stdout}\n{stderr}"
    );
    assert!(
        status.success(),
        "{case}/{failures}: {status}\n{stdout}\n{stderr}"
    );
}

#[test]
fn real_spawn_control() {
    run("success", 0);
}

#[test]
fn one_text_busy_then_executes_frozen_bytes() {
    run("success", 1);
}

#[test]
fn two_text_busy_then_executes_frozen_bytes() {
    run("success", 2);
}

#[test]
fn persistent_text_busy_expires_original_deadline_without_a_child() {
    run("persistent", -1);
}

#[test]
fn cancelling_retry_wait_removes_script_and_prevents_later_attempts() {
    run("cancel", -1);
}

#[test]
fn permission_failure_is_immediate_preserves_errno_and_never_retries() {
    run("permission", -1);
}

#[test]
fn retry_wait_and_real_child_share_one_execution_budget() {
    run("shared-budget", 0);
}
