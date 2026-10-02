use std::{cell::RefCell, future::Future, path::Path, pin::Pin};
use zc::user_service::{CommandOutput, CommandRunner, Platform};
pub struct FakeManager {
    platform: Platform,
    pub calls: RefCell<Vec<Vec<String>>>,
}
impl FakeManager {
    pub fn new(platform: Platform) -> Self {
        Self {
            platform,
            calls: RefCell::new(vec![]),
        }
    }
}
impl Drop for FakeManager {
    fn drop(&mut self) {
        if std::env::var_os("ZC_SERVICE_TEST_CHILD").is_some() {
            let _ = std::process::Command::new("/usr/bin/python3")
                .args([
                    format!(
                        "{}/tests/support/service_manager.py",
                        env!("CARGO_MANIFEST_DIR")
                    ),
                    std::env::var("HOME").unwrap(),
                    "launchd".into(),
                    "test-cleanup".into(),
                ])
                .output();
        }
    }
}
impl CommandRunner for FakeManager {
    fn platform(&self) -> Platform {
        self.platform
    }
    fn authorize<'a>(
        &'a self,
        _home: &'a Path,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + 'a>> {
        Box::pin(async { Ok(()) })
    }
    fn run<'a>(
        &'a self,
        program: &'a str,
        args: &'a [String],
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<CommandOutput>> + 'a>> {
        self.calls.borrow_mut().push(
            std::iter::once(program.to_owned())
                .chain(args.iter().cloned())
                .collect(),
        );
        Box::pin(async move {
            let uncertain = std::path::PathBuf::from(std::env::var("HOME").unwrap())
                .join("cleanup-failed-once");
            if args
                .iter()
                .any(|arg| matches!(arg.as_str(), "stop" | "bootout"))
                && uncertain.exists()
            {
                std::fs::remove_file(uncertain)?;
                anyhow::bail!("SERVICE_COMMAND_CLEANUP_FAILED: injected uncertain command cleanup");
            }
            let mut command = vec![
                format!(
                    "{}/tests/support/service_manager.py",
                    env!("CARGO_MANIFEST_DIR")
                ),
                std::env::var("HOME").unwrap(),
                match self.platform {
                    Platform::Launchd => "launchd",
                    Platform::Systemd => "systemd",
                }
                .into(),
                program.into(),
            ];
            command.extend_from_slice(args);
            let output = zc::user_service::run_bounded("/usr/bin/python3", &command).await?;
            if output.code != 0 && output.stderr.contains("Traceback (most recent call last)") {
                // Preserve unexpected fixture exceptions for the isolated parent;
                // production errors must continue to hide manager output.
                let path = std::path::PathBuf::from(std::env::var("HOME").unwrap())
                    .join("manager-traceback.txt");
                let _ = std::fs::write(path, &output.stderr);
            }
            Ok(output)
        })
    }
}
