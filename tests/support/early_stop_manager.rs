use crate::support::FakeManager;
use std::{
    cell::{Cell, RefCell},
    future::Future,
    path::Path,
    pin::Pin,
};
use zc::user_service::{CommandOutput, CommandRunner, Platform};

/// An independent manager request whose completion belongs to the test, not
/// the command client. Cleanup retains the original PID if an assertion fails.
pub struct EarlyStopManager {
    inner: FakeManager,
    stop: RefCell<Option<tokio::sync::oneshot::Sender<u32>>>,
    lose_ack: Cell<bool>,
}
impl EarlyStopManager {
    pub fn new(platform: Platform) -> Self {
        Self {
            inner: FakeManager::new(platform),
            stop: RefCell::new(None),
            lose_ack: Cell::new(false),
        }
    }
    pub fn defer_stop(&self) -> tokio::sync::oneshot::Receiver<u32> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        assert!(self.stop.borrow_mut().replace(tx).is_none());
        rx
    }
    pub fn lose_stop_acknowledgement(&self) -> tokio::sync::oneshot::Receiver<u32> {
        self.lose_ack.set(true);
        self.defer_stop()
    }
}
impl CommandRunner for EarlyStopManager {
    fn platform(&self) -> Platform {
        self.inner.platform()
    }
    fn authorize<'a>(
        &'a self,
        home: &'a Path,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + 'a>> {
        self.inner.authorize(home)
    }
    fn run<'a>(
        &'a self,
        program: &'a str,
        args: &'a [String],
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<CommandOutput>> + 'a>> {
        Box::pin(async move {
            if args
                .iter()
                .any(|arg| matches!(arg.as_str(), "stop" | "bootout"))
            {
                let tx = self.stop.borrow_mut().take();
                if let Some(tx) = tx {
                    let path = std::path::PathBuf::from(std::env::var_os("HOME").unwrap())
                        .join("fake-manager.json");
                    let mut state: serde_json::Value =
                        serde_json::from_slice(&std::fs::read(&path)?)?;
                    let pid = state["pid"].as_u64().unwrap() as u32;
                    if self.platform() == Platform::Launchd {
                        state["loaded"] = false.into();
                    }
                    std::fs::write(path, serde_json::to_vec(&state)?)?;
                    tx.send(pid).unwrap();
                    if self.lose_ack.replace(false) {
                        anyhow::bail!(
                            "SERVICE_MANAGER_TIMEOUT: accepted stop acknowledgement was lost"
                        );
                    }
                    return Ok(CommandOutput {
                        code: 0,
                        stdout: String::new(),
                        stderr: String::new(),
                    });
                }
            }
            self.inner.run(program, args).await
        })
    }
}
