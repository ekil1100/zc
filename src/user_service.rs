//! User-service ownership, platform adapters and cold installation transactions.
//! Manager execution is the only injected seam; daemon evidence is always real.
use crate::{
    daemon,
    fsutil::{self, FileLock, SecureDir},
    service::PrepareOptions,
};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    time::Duration,
};
use tokio::{io::AsyncReadExt, process::Command};

const LABEL: &str = "org.zc.user";
const UNIT: &str = "zc-user.service";
const RECORD: &str = "registration.json";
const LIMIT: usize = 64 * 1024;
const WAIT: Duration = Duration::from_secs(15);
pub type CommandFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T>> + 'a>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Platform {
    Launchd,
    Systemd,
}
#[derive(Debug)]
pub struct CommandOutput {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}
/// Implementations must bound execution/output, join command cleanup before
/// returning errors, and never echo manager output. Privilege-changing or
/// detached command helpers are unsupported (manager-owned daemons are separate).
pub trait CommandRunner {
    fn platform(&self) -> Platform;
    fn authorize<'a>(&'a self, home: &'a Path) -> CommandFuture<'a, ()>;
    fn run<'a>(&'a self, program: &'a str, args: &'a [String]) -> CommandFuture<'a, CommandOutput>;
}
pub struct Native;
impl CommandRunner for Native {
    fn platform(&self) -> Platform {
        if cfg!(target_os = "macos") {
            Platform::Launchd
        } else {
            Platform::Systemd
        }
    }
    fn authorize<'a>(&'a self, home: &'a Path) -> CommandFuture<'a, ()> {
        Box::pin(async move {
            ensure!(
                rustix::process::geteuid().as_raw() != 0,
                "SERVICE_USER_REQUIRED: run as an unprivileged login user"
            );
            let actual = if self.platform() == Platform::Launchd {
                let name = checked(self, "/usr/bin/id", &["-un".into()]).await?.stdout;
                let name = name.trim();
                ensure!(
                    !name.is_empty() && !name.contains(['/', '\n', '\r']),
                    "SERVICE_MANAGER_UNAVAILABLE: account lookup failed"
                );
                let out = checked(
                    self,
                    "/usr/bin/dscl",
                    &[
                        "/Search".into(),
                        "-read".into(),
                        format!("/Users/{name}"),
                        "NFSHomeDirectory".into(),
                    ],
                )
                .await?;
                out.stdout
                    .strip_prefix("NFSHomeDirectory: ")
                    .context("SERVICE_MANAGER_UNAVAILABLE: account home unavailable")?
                    .trim()
                    .to_owned()
            } else {
                let out = checked(
                    self,
                    "/usr/bin/getent",
                    &[
                        "passwd".into(),
                        rustix::process::geteuid().as_raw().to_string(),
                    ],
                )
                .await?;
                out.stdout
                    .trim()
                    .split(':')
                    .nth(5)
                    .context("SERVICE_MANAGER_UNAVAILABLE: account home unavailable")?
                    .to_owned()
            };
            ensure!(
                Path::new(&actual).canonicalize()? == home,
                "SERVICE_HOME_MISMATCH: HOME must match the operating-system login account; isolated tests require an injected runner"
            );
            Ok(())
        })
    }
    fn run<'a>(&'a self, program: &'a str, args: &'a [String]) -> CommandFuture<'a, CommandOutput> {
        Box::pin(run_bounded(program, args))
    }
}
tokio::task_local! {
    // Scoped to the installer only. Recovery deliberately uses an uncancelled
    // scope and is awaited to completion, even after repeated OS signals.
    static INSTALL_CANCEL: tokio::sync::watch::Receiver<bool>;
}
fn check_install_interruption() -> Result<()> {
    ensure!(
        !INSTALL_CANCEL.try_with(|rx| *rx.borrow()).unwrap_or(false),
        "SERVICE_INSTALL_INTERRUPTED: installation interrupted"
    );
    Ok(())
}
async fn install_interrupted() {
    let Ok(mut rx) = INSTALL_CANCEL.try_with(Clone::clone) else {
        return std::future::pending().await;
    };
    loop {
        if *rx.borrow_and_update() {
            return;
        }
        if rx.changed().await.is_err() {
            return std::future::pending().await;
        }
    }
}
/// Private binary installation entry shared by local and release installers.
/// The publisher is compiled into the candidate, never fetched or caller-supplied.
pub async fn install_embedded(
    source: &Path,
    target_dir: &Path,
    runner: &dyn CommandRunner,
) -> Result<()> {
    const PUBLISHER: &[u8] = include_bytes!("../scripts/install/local-dev-install.sh");
    ensure!(
        PUBLISHER.len() <= LIMIT,
        "embedded publisher exceeds 64 KiB"
    );
    std::fs::create_dir_all(target_dir)?;
    let target_dir = target_dir.canonicalize()?;
    let dir = SecureDir::open_owned_absolute(&target_dir, false)?;
    let name = format!(".zc.publisher.{}", fsutil::nonce()?);
    let _publisher = CandidateFile {
        dir: &dir,
        name: name.clone(),
    };
    dir.write_new(&name, PUBLISHER)?;
    install_with_signals(source, &target_dir, &target_dir.join(name), runner).await
}

/// Only the local-install entry opts into SIGINT/SIGTERM handling. Never drop
/// the transaction on interruption: command cleanup and recovery must join first.
pub async fn install_with_signals(
    source: &Path,
    target_dir: &Path,
    publisher: &Path,
    runner: &dyn CommandRunner,
) -> Result<()> {
    use tokio::signal::unix::{SignalKind, signal};
    let mut interrupt = signal(SignalKind::interrupt())?;
    let mut terminate = signal(SignalKind::terminate())?;
    let (cancel, receiver) = tokio::sync::watch::channel(false);
    INSTALL_CANCEL.scope(receiver, async {
        let transaction = install(source, target_dir, publisher, runner);
        tokio::pin!(transaction);
        tokio::select! {
            biased;
            _ = async { tokio::select! { _ = interrupt.recv() => {}, _ = terminate.recv() => {} } } => {
                cancel.send_replace(true);
                transaction.await
            }
            result = &mut transaction => result,
        }
    }).await
}

// Keep the group leader unreaped until the group has been killed, so its PGID
// cannot be reused while cleanup is armed. Daemons launched by a manager are
// independent sessions; command helpers/publisher children stay in this group.
struct CommandGroup(rustix::process::Pid);
impl CommandGroup {
    fn kill(&self) -> Result<()> {
        match rustix::process::kill_process_group(self.0, rustix::process::Signal::KILL) {
            Ok(()) | Err(rustix::io::Errno::SRCH) => Ok(()),
            // XNU killpg1 excludes zombies and returns EPERM for a zombie-only
            // group. Our unreaped leader pins this group; same-user live helpers
            // would have made killpg succeed. Privilege-changing/detaching helpers
            // are outside the command-runner contract.
            #[cfg(target_os = "macos")]
            Err(rustix::io::Errno::PERM) if self.exited_now()? => Ok(()),
            Err(e) => Err(e)
                .context("SERVICE_COMMAND_CLEANUP_FAILED: command group could not be terminated"),
        }
    }
    fn exited_now(&self) -> Result<bool> {
        use rustix::process::{WaitId, WaitIdOptions, waitid};
        Ok(waitid(
            WaitId::Pid(self.0),
            WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
        )?
        .is_some())
    }
    async fn exited(&self) -> Result<()> {
        loop {
            if self.exited_now()? {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}
impl Drop for CommandGroup {
    fn drop(&mut self) {
        let _ = self.kill();
    }
}
/// Shared bounded execution for managers and installation checks, without a shell.
pub async fn run_bounded(program: &str, args: &[String]) -> Result<CommandOutput> {
    use std::process::Stdio;
    check_install_interruption()?;
    let mut command = Command::new(program);
    if program == "/usr/bin/systemctl" {
        let runtime = format!("/run/user/{}", rustix::process::geteuid().as_raw());
        command
            .env("XDG_RUNTIME_DIR", &runtime)
            .env(
                "DBUS_SESSION_BUS_ADDRESS",
                format!("unix:path={runtime}/bus"),
            )
            .env_remove("SYSTEMD_UNIT_PATH")
            .env_remove("SYSTEMD_BUS_ADDRESS")
            .env_remove("SYSTEMD_HOST")
            .env_remove("SYSTEMD_MACHINE");
    }
    let mut child = command
        .process_group(0)
        .args(args)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("SERVICE_MANAGER_UNAVAILABLE: command could not be started")?;
    let group = CommandGroup(
        rustix::process::Pid::from_raw(child.id().context("missing child pid")? as i32)
            .context("invalid child pid")?,
    );
    let stdout = child.stdout.take().context("missing stdout")?;
    let stderr = child.stderr.take().context("missing stderr")?;
    async fn read(stream: impl tokio::io::AsyncRead + Unpin) -> Result<String> {
        let mut bytes = Vec::new();
        stream
            .take(LIMIT as u64 + 1)
            .read_to_end(&mut bytes)
            .await?;
        ensure!(
            bytes.len() <= LIMIT,
            "SERVICE_MANAGER_OUTPUT_LIMIT: command output exceeded limit"
        );
        String::from_utf8(bytes).context("SERVICE_MANAGER_FAILED: invalid command output")
    }
    let result = tokio::select! {
        biased;
        _ = install_interrupted() => Err(anyhow::anyhow!("SERVICE_INSTALL_INTERRUPTED: installation interrupted")),
        result = tokio::time::timeout(WAIT, async {
            let ((), stdout, stderr) = tokio::try_join!(group.exited(), read(stdout), read(stderr))?;
            Ok::<_, anyhow::Error>((stdout, stderr))
        }) => result.unwrap_or_else(|_| Err(anyhow::anyhow!("SERVICE_MANAGER_TIMEOUT: command deadline exceeded"))),
    };
    // This also kills descendants left behind by a successfully exited shell.
    // Reap the direct child before the caller can release publication locks.
    group.kill()?;
    // Disarm before reaping (Drop has no asynchronous work or reused PID risk).
    std::mem::forget(group);
    let status = tokio::time::timeout(Duration::from_secs(1), child.wait())
        .await
        .context("SERVICE_COMMAND_CLEANUP_FAILED: command did not reap; retain recovery state")??;
    match result {
        Ok((stdout, stderr)) => Ok(CommandOutput {
            code: status.code().unwrap_or(-1),
            stdout,
            stderr,
        }),
        Err(e) => Err(e),
    }
}
async fn checked(
    runner: &dyn CommandRunner,
    program: &str,
    args: &[String],
) -> Result<CommandOutput> {
    let out = runner.run(program, args).await?;
    ensure!(
        out.code == 0,
        "SERVICE_MANAGER_FAILED: manager rejected operation (exit {}); check the login session and permissions",
        out.code
    );
    Ok(out)
}
fn home() -> Result<PathBuf> {
    let home =
        PathBuf::from(std::env::var_os("HOME").context("SERVICE_STATE_INVALID: HOME missing")?);
    SecureDir::open_owned_absolute(&home, false)?;
    Ok(home)
}
fn parent(create: bool) -> Result<(PathBuf, SecureDir)> {
    let home = home()?;
    let mut path = home.clone();
    let mut dir = SecureDir::open_owned_absolute(&home, false)?;
    for part in [".local", "state", "zc"] {
        dir = dir.owned_child(part, create, false)?;
        path.push(part);
    }
    Ok((path, dir))
}
/// Stable operation lock shared with the manual lifecycle and installer.
pub(crate) fn operation_lock() -> Result<FileLock> {
    Ok(parent(true)?
        .1
        .lock("zc.service.lock", Duration::from_secs(1))?)
}
fn state(create: bool) -> Result<(PathBuf, SecureDir)> {
    let (path, dir) = parent(create)?;
    Ok((
        path.join("service"),
        dir.owned_child("service", create, true)?,
    ))
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Registration {
    schema: u32,
    id: String,
    platform: Platform,
    binary: PathBuf,
    home: PathBuf,
    runtime: PathBuf,
    snapshot: String,
    allowed: bool,
}
fn read_record(dir: &SecureDir) -> Result<Option<Registration>> {
    dir.validate_path(&home()?.join(".local/state/zc/service"))?;
    if !dir.exists(RECORD)? {
        return Ok(None);
    }
    let bytes = dir.read(RECORD, LIMIT)?;
    let record: Registration = serde_json::from_slice(&bytes)
        .map_err(|_| anyhow::anyhow!("SERVICE_STATE_INVALID: registration is corrupt"))?;
    ensure!(
        record.schema == 1
            && record.id.len() == 32
            && record
                .id
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            && serde_json::to_vec(&record)? == bytes,
        "SERVICE_STATE_INVALID: registration is not canonical"
    );
    for path in [&record.binary, &record.home, &record.runtime] {
        path_text(path)?;
        ensure!(
            path.is_absolute(),
            "SERVICE_STATE_INVALID: absolute path required"
        );
    }
    let prepared = daemon::load_snapshot(dir, &record.snapshot, &record.id)?;
    daemon::validate_service_prepared(&prepared)?;
    if let Some(store) = crate::service::existing_store()? {
        store.load_existing().context("SERVICE_STATE_INVALID: established catalog is missing or invalid; retain state instead of recovering from mirrors")?;
    }
    if let Some(identity) = &prepared.identity {
        let store = crate::service::existing_store()?
            .context("SERVICE_STATE_INVALID: managed catalog is missing")?;
        store.read_bundle(&identity.key, &identity.revision)?;
    }
    Ok(Some(record))
}
fn write_record(dir: &SecureDir, record: &Registration) -> Result<()> {
    dir.validate_path(&home()?.join(".local/state/zc/service"))?;
    let receipt = dir.atomic_write(RECORD, &serde_json::to_vec(record)?)?;
    ensure!(
        receipt.durability_error.is_none(),
        "SERVICE_STATE_INVALID: registration durability uncertain; retain state and retry inspection"
    );
    Ok(())
}
// Only retire authenticated snapshots that this successful transaction replaced.
// Failed transactions retain recovery inputs; unrelated files are never swept.
fn retire_snapshots(dir: &SecureDir, committed: &Registration, replaced: &[&str]) -> Result<()> {
    let current = read_record(dir)?.context("SERVICE_STATE_INVALID: registration disappeared")?;
    ensure!(
        serde_json::to_vec(&current)? == serde_json::to_vec(committed)?,
        "SERVICE_CONTENDED: registration changed before snapshot retirement"
    );
    for name in replaced {
        if *name != committed.snapshot && dir.exists(name)? {
            daemon::load_snapshot(dir, name, &committed.id)?;
            dir.remove_file(name)?;
        }
    }
    dir.sync()?;
    Ok(())
}
fn path_text(path: &Path) -> Result<&str> {
    let text = path
        .to_str()
        .context("SERVICE_STATE_INVALID: UTF-8 path required")?;
    ensure!(
        !text.is_empty() && text.len() <= 4096 && !text.chars().any(char::is_control),
        "SERVICE_STATE_INVALID: invalid path"
    );
    Ok(text)
}
fn validate_executable(platform: Platform, path: &Path) -> Result<()> {
    let text = path_text(path)?;
    ensure!(
        platform != Platform::Systemd || !text.contains(['\'', '"', '\\']),
        "SERVICE_EXECUTABLE_PATH_UNSUPPORTED: systemd rejects quotes and backslashes in executable paths even when escaped; install zc in a path without these characters (spaces, $ and % are supported)"
    );
    Ok(())
}
fn definition_name(platform: Platform) -> &'static str {
    match platform {
        Platform::Launchd => "org.zc.user.plist",
        Platform::Systemd => UNIT,
    }
}
fn login_dir(platform: Platform, create: bool) -> Result<(PathBuf, SecureDir)> {
    let home = home()?;
    let mut dir = SecureDir::open_owned_absolute(&home, false)?;
    let parts: &[&str] = match platform {
        Platform::Launchd => &["Library", "LaunchAgents"],
        Platform::Systemd => &[".config", "systemd", "user"],
    };
    let mut path = home;
    for part in parts {
        dir = dir.owned_child(part, create, false)?;
        path.push(part);
    }
    Ok((path, dir))
}
fn xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
fn unit_quote(s: &str) -> String {
    format!(
        "\"{}\"",
        s.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('%', "%%")
    )
}
fn definition(record: &Registration) -> Result<String> {
    validate_executable(record.platform, &record.binary)?;
    let binary = path_text(&record.binary)?;
    let home = path_text(&record.home)?;
    let runtime = path_text(&record.runtime)?;
    let args = [binary.to_owned(), "--service-run".into(), record.id.clone()];
    Ok(match record.platform {
        Platform::Launchd => format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>\n<key>Label</key><string>{LABEL}</string>\n<key>ProgramArguments</key><array>{}</array>\n<key>EnvironmentVariables</key><dict><key>HOME</key><string>{}</string><key>XDG_RUNTIME_DIR</key><string>{}</string></dict>\n<key>RunAtLoad</key><true/><key>KeepAlive</key><false/>\n<key>ExitTimeOut</key><integer>10</integer>\n<key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string>\n</dict></plist>\n",
            args.iter()
                .map(|s| format!("<string>{}</string>", xml(s)))
                .collect::<String>(),
            xml(home),
            xml(runtime)
        ),
        Platform::Systemd => format!(
            "# Owned by zc; validated against its private registration.\n[Unit]\nDescription=zc user proxy\n[Service]\nType=exec\nExecStart=:{}\nEnvironment={} {}\nRestart=no\nKillMode=control-group\nTimeoutStopSec=10\nStandardOutput=null\nStandardError=null\n[Install]\nWantedBy=default.target\n",
            args.iter()
                .map(|s| unit_quote(s))
                .collect::<Vec<_>>()
                .join(" "),
            unit_quote(&format!("HOME={home}")),
            unit_quote(&format!("XDG_RUNTIME_DIR={runtime}"))
        ),
    })
}
fn verify_definitions(dir: &SecureDir, record: &Registration) -> Result<bool> {
    dir.validate_path(&home()?.join(".local/state/zc/service"))?;
    let expected = definition(record)?;
    ensure!(
        dir.read(definition_name(record.platform), LIMIT)? == expected.as_bytes(),
        "SERVICE_FOREIGN: private service definition differs; retain and inspect it"
    );
    let (_, login) = login_dir(record.platform, false)?;
    let exists = login.exists(definition_name(record.platform))?;
    if exists {
        ensure!(
            login.read(definition_name(record.platform), LIMIT)? == expected.as_bytes(),
            "SERVICE_FOREIGN: login service definition differs; retain and inspect it"
        );
    }
    ensure!(
        exists || record.platform == Platform::Launchd,
        "SERVICE_STATE_INVALID: registered unit is missing"
    );
    Ok(exists)
}
#[derive(Default)]
struct ManagerState {
    loaded: bool,
    pid: Option<u32>,
    enabled: bool,
}
struct Manager<'a> {
    runner: &'a dyn CommandRunner,
}
impl Manager<'_> {
    fn domain(&self) -> String {
        format!("gui/{}", rustix::process::geteuid().as_raw())
    }
    fn target(&self) -> String {
        format!("{}/{LABEL}", self.domain())
    }
    async fn launch(&self, args: &[String]) -> Result<CommandOutput> {
        checked(self.runner, "/bin/launchctl", args).await
    }
    async fn system(&self, args: &[String]) -> Result<CommandOutput> {
        let mut all = vec!["--user".into(), "--no-pager".into()];
        all.extend_from_slice(args);
        checked(self.runner, "/usr/bin/systemctl", &all).await
    }
    async fn inspect(
        &self,
        record: Option<&Registration>,
        login_exists: bool,
    ) -> Result<ManagerState> {
        match self.runner.platform() {
            Platform::Launchd => {
                // A missing service is meaningful only in an accessible login domain.
                let disabled = self
                    .launch(&["print-disabled".into(), self.domain()])
                    .await?;
                let out = self
                    .runner
                    .run("/bin/launchctl", &["print".into(), self.target()])
                    .await?;
                if out.code != 0 {
                    ensure!(
                        matches!(out.code, 113 | 3)
                            && out.stderr.contains("Could not find service"),
                        "SERVICE_MANAGER_FAILED: cannot inspect launch agent; check the login session and permissions"
                    );
                    return Ok(ManagerState {
                        enabled: login_exists
                            && !disabled.stdout.contains(&format!("\"{LABEL}\" => true")),
                        ..Default::default()
                    });
                }
                let record = record
                    .context("SERVICE_FOREIGN: an unregistered launch agent already exists")?;
                let (private, _) = state(false)?;
                let (login, _) = login_dir(Platform::Launchd, false)?;
                let paths = [
                    private.join(definition_name(record.platform)),
                    login.join(definition_name(record.platform)),
                ];
                let path = out
                    .stdout
                    .lines()
                    .find_map(|l| l.trim().strip_prefix("path = "))
                    .context("SERVICE_FOREIGN: launch agent path unavailable")?;
                ensure!(
                    paths.iter().any(|p| p.as_os_str() == path),
                    "SERVICE_FOREIGN: loaded launch agent path differs"
                );
                let program = out
                    .stdout
                    .lines()
                    .find_map(|l| l.trim().strip_prefix("program = "));
                let mut lines = out.stdout.lines().map(str::trim);
                let arguments = lines.find(|line| *line == "arguments = {").and_then(|_| {
                    let mut args = Vec::new();
                    for line in lines {
                        if line == "}" {
                            return Some(args);
                        }
                        if !line.is_empty() {
                            args.push(line);
                        }
                    }
                    None
                });
                ensure!(
                    program == Some(path_text(&record.binary)?)
                        && arguments.as_deref()
                            == Some(&[path_text(&record.binary)?, "--service-run", &record.id]),
                    "SERVICE_FOREIGN: loaded launch invocation differs from registration"
                );
                let pid = out
                    .stdout
                    .lines()
                    .find_map(|l| l.trim().strip_prefix("pid = "))
                    .map(str::parse)
                    .transpose()?;
                Ok(ManagerState {
                    loaded: true,
                    pid,
                    enabled: login_exists
                        && !disabled.stdout.contains(&format!("\"{LABEL}\" => true")),
                })
            }
            Platform::Systemd => {
                let out = self.system(&["show".into(),UNIT.into(),"--property=LoadState,ActiveState,MainPID,FragmentPath,DropInPaths,UnitFileState,ExecStart".into()]).await?;
                let properties: std::collections::BTreeMap<_, _> = out
                    .stdout
                    .lines()
                    .filter_map(|l| l.split_once('='))
                    .collect();
                let load = properties
                    .get("LoadState")
                    .context("SERVICE_MANAGER_FAILED: missing unit state")?;
                if *load == "not-found" {
                    return Ok(ManagerState::default());
                }
                ensure!(
                    *load == "loaded",
                    "SERVICE_MANAGER_FAILED: unit is masked or invalid"
                );
                let record = record.context("SERVICE_FOREIGN: unregistered unit already exists")?;
                let (login, _) = login_dir(record.platform, false)?;
                ensure!(
                    properties.get("FragmentPath").copied() == Some(path_text(&login.join(UNIT))?)
                        && properties.get("DropInPaths").copied() == Some(""),
                    "SERVICE_FOREIGN: unit path or drop-ins differ"
                );
                let expected = format!(
                    "{{ path={} ; argv[]={} --service-run {} ; ignore_errors=no ;",
                    path_text(&record.binary)?,
                    path_text(&record.binary)?,
                    record.id
                );
                let exec = properties
                    .get("ExecStart")
                    .context("SERVICE_FOREIGN: loaded invocation unavailable")?;
                ensure!(
                    exec.starts_with(&expected) && !exec.contains("} ;"),
                    "SERVICE_FOREIGN: loaded invocation differs from registration"
                );
                let pid: u32 = properties
                    .get("MainPID")
                    .context("SERVICE_MANAGER_FAILED: missing main PID")?
                    .parse()?;
                let enabled = match properties.get("UnitFileState").copied() {
                    Some("enabled") => true,
                    Some("disabled") => false,
                    _ => bail!("SERVICE_MANAGER_FAILED: unexpected unit enablement state"),
                };
                Ok(ManagerState {
                    loaded: true,
                    pid: (pid != 0).then_some(pid),
                    enabled,
                })
            }
        }
    }
    async fn enable(&self, record: &Registration, enabled: bool) -> Result<()> {
        match record.platform {
            Platform::Launchd => {
                let (_, login) = login_dir(record.platform, false)?;
                let name = definition_name(record.platform);
                if enabled {
                    self.launch(&["enable".into(), self.target()]).await?;
                    if !login.exists(name)? {
                        login.write_new(name, definition(record)?.as_bytes())?;
                        login.sync()?;
                    }
                } else if login.exists(name)? {
                    ensure!(
                        login.read(name, LIMIT)? == definition(record)?.as_bytes(),
                        "SERVICE_FOREIGN: login definition changed before removal"
                    );
                    login.remove_file(name)?;
                    login.sync()?;
                }
            }
            Platform::Systemd => {
                self.system(&[
                    if enabled { "enable" } else { "disable" }.into(),
                    UNIT.into(),
                ])
                .await?;
            }
        }
        Ok(())
    }
}

pub async fn execute(
    action: &str,
    mut options: PrepareOptions,
    binary: &Path,
    runner: &dyn CommandRunner,
) -> Result<Value> {
    // systemd rejects these characters after unescaping ExecStart. Validate the
    // resolved executable before locks, registration or prepare side effects.
    let resolved_binary = binary.canonicalize()?;
    validate_executable(runner.platform(), &resolved_binary)?;
    options.command = "start".into();
    runner.authorize(&home()?).await?;
    let _operation = operation_lock()?;
    let manager = Manager { runner };
    let register = matches!(action, "start" | "enable");
    if register && let Some(store) = crate::service::existing_store()? {
        store.load_existing().context(
            "SERVICE_STATE_INVALID: service registration requires an intact schema-2 authority",
        )?;
    }
    let mut first_prepared = None;
    let (path, dir) = match state(false) {
        Ok(state) => state,
        Err(e) if missing(&e) => {
            ensure!(
                !login_definition_exists(runner.platform())?,
                "SERVICE_STATE_INVALID: definition exists without registration"
            );
            manager.inspect(None, false).await?;
            ensure!(
                action != "restart",
                "SERVICE_NOT_REGISTERED: register with `zc service start -c <config> --port <port>`"
            );
            if !register {
                return Ok(
                    json!({"registered":false,"loaded":false,"running":false,"enabled":false}),
                );
            }
            let _launch = daemon::service_launch_lock()?;
            ensure!(
                daemon::capture_restart().await?.prepared.is_none(),
                "SERVICE_MANUAL_INSTANCE: confirm and stop the manual instance, then run `zc service start -c <config> --port <port>`"
            );
            first_prepared = Some(crate::service::prepare(options.clone()).await?);
            state(true)?
        }
        Err(e) => return Err(e),
    };
    let mut record = read_record(&dir)?;
    let newly_registered = record.is_none();
    if record.is_none() {
        ensure!(
            std::fs::read_dir(&path)?.next().is_none(),
            "SERVICE_STATE_INVALID: registration is missing from existing service state"
        );
        let (_, login) = login_dir(runner.platform(), register)?;
        ensure!(
            !dir.exists(definition_name(runner.platform()))?
                && !login.exists(definition_name(runner.platform()))?,
            "SERVICE_STATE_INVALID: definition exists without registration; retain and inspect state"
        );
        manager.inspect(None, false).await?;
        if matches!(action, "start" | "enable") {
            ensure!(
                daemon::capture_restart().await?.prepared.is_none(),
                "SERVICE_MANUAL_INSTANCE: confirm and stop the manual instance, then run `zc service start -c <config> --port <port>`"
            );
            let _launch = daemon::service_launch_lock()?;
            let prepared = match first_prepared.take() {
                Some(prepared) => prepared,
                None => crate::service::prepare(options.clone()).await?,
            };
            let id = fsutil::nonce()?;
            let record_new = Registration {
                schema: 1,
                id: id.clone(),
                platform: runner.platform(),
                binary: binary.canonicalize()?,
                home: home()?,
                runtime: daemon::service_runtime_path()?,
                snapshot: daemon::save_snapshot(&dir, prepared, &id)?,
                allowed: true,
            };
            let definition = definition(&record_new)?;
            dir.write_new(definition_name(record_new.platform), definition.as_bytes())?;
            if record_new.platform == Platform::Systemd {
                login.write_new(UNIT, definition.as_bytes())?;
                login.sync()?;
            }
            write_record(&dir, &record_new)?;
            if record_new.platform == Platform::Systemd {
                manager.system(&["daemon-reload".into()]).await?;
            }
            record = Some(record_new);
        } else {
            return Ok(json!({"registered":false,"loaded":false,"running":false,"enabled":false}));
        }
    }
    let mut record = record.context("SERVICE_STATE_INVALID: missing registration")?;
    ensure!(
        record.binary == binary.canonicalize()?
            && record.home == home()?
            && record.runtime == daemon::service_runtime_path()?
            && record.platform == runner.platform(),
        "SERVICE_TARGET_MISMATCH: use the registered executable, HOME and runtime namespace"
    );
    let login_exists = verify_definitions(&dir, &record)?;
    let current = manager.inspect(Some(&record), login_exists).await?;
    let launch = daemon::service_launch_lock()?;
    let captured = daemon::capture_service(&record.id, action != "status").await?;
    ensure!(
        captured.pid() == current.pid,
        "SERVICE_INSTANCE_MISMATCH: manager and daemon ownership disagree; no process was stopped"
    );
    let explicit = options.config.is_some() || options.port.is_some();
    if explicit && !matches!(action, "start" | "restart" | "enable") {
        bail!("SERVICE_ARGUMENT_INVALID: configuration is not accepted here");
    }
    ensure!(
        !explicit || !captured.ready() || action == "restart",
        "SERVICE_RUNNING: change a running service with explicit `zc service restart -c <config> --port <port>`"
    );
    let original = record.clone();
    if action != "status"
        && let Some(prepared) = captured.prepared.clone()
    {
        record.snapshot = daemon::save_snapshot(&dir, prepared, &record.id)?;
    }
    let previous = record.clone();
    if explicit && !newly_registered {
        let mut prepared = daemon::load_snapshot(&dir, &record.snapshot, &record.id)?;
        if options.config.is_some() {
            let mut options = options.clone();
            options.port = options.port.or(prepared.invocation.port_override);
            prepared = crate::service::prepare(options).await?;
        } else if let Some(port) = options.port {
            prepared.port = port;
            prepared.invocation.port_override = Some(port);
        }
        record.snapshot = daemon::save_snapshot(&dir, prepared, &record.id)?;
    }
    captured.verify()?;
    match action {
        "enable" | "disable" => {
            write_record(&dir, &record)?;
            manager.enable(&record, action == "enable").await?;
            drop(launch);
        }
        "status" => {
            drop(launch);
        }
        "stop" => {
            stop_registered(&manager, &dir, &original, &current, &captured).await?;
            record.allowed = true;
            write_record(&dir, &record)?;
            drop(launch);
        }
        "start" if captured.ready() => {
            write_record(&dir, &record)?;
            drop(launch);
        }
        "start" | "restart" => {
            if action == "restart" {
                stop_registered(&manager, &dir, &original, &current, &captured).await?;
            }
            record.allowed = true;
            write_record(&dir, &record)?;
            drop(launch);
            let mut started_pid = None;
            if start_ready(&manager, &record, &dir, &mut started_pid)
                .await
                .is_err()
            {
                let recovery = async {
                    let launch = daemon::service_launch_lock()?;
                    record.allowed = false;
                    write_record(&dir, &record)?;
                    let current = manager
                        .inspect(Some(&record), verify_definitions(&dir, &record)?)
                        .await?;
                    verify_recovery_owner(&record, &current, started_pid, None).await?;
                    manager.stop(&record, &current).await?;
                    write_record(&dir, &previous)?;
                    drop(launch);
                    if captured.ready() {
                        start_ready(&manager, &previous, &dir, &mut None).await?;
                    }
                    Ok::<_, anyhow::Error>(())
                }
                .await;
                recovery.context(
                    "SERVICE_RECOVERY_FAILED: previous invocation could not be restored",
                )?;
                if captured.ready() {
                    bail!(
                        "SERVICE_START_FAILED_ROLLED_BACK: startup failed; previous frozen invocation restored"
                    );
                }
                bail!(
                    "SERVICE_START_FAILED: daemon did not become ready; registered configuration retained"
                );
            }
        }
        _ => bail!("SERVICE_ARGUMENT_INVALID: unknown service action"),
    }
    let after = manager
        .inspect(Some(&record), verify_definitions(&dir, &record)?)
        .await?;
    let observed = daemon::capture_service(&record.id, false).await?;
    ensure!(
        observed.pid() == after.pid,
        "SERVICE_INSTANCE_MISMATCH: manager and daemon ownership disagree"
    );
    if action != "status" {
        retire_snapshots(&dir, &record, &[&original.snapshot, &previous.snapshot])?;
    }
    let _ = path;
    Ok(
        json!({"registered":true,"loaded":after.loaded,"running":observed.ready(),"enabled":after.enabled,"pid":observed.pid(),"mixed_port":observed.prepared.as_ref().map(|p|p.port),"configured_port":daemon::load_snapshot(&dir,&record.snapshot,&record.id)?.port,"binary":record.binary,"runtime":record.runtime}),
    )
}

// A stop failure may mean either no effect or a completed stop. Restore only
// our registration; never repeat the stop or adopt a process to infer success.
async fn stop_registered(
    manager: &Manager<'_>,
    dir: &SecureDir,
    original: &Registration,
    current: &ManagerState,
    captured: &daemon::ServiceCapture,
) -> Result<()> {
    let mut gated = original.clone();
    gated.allowed = false;
    let result = async {
        write_record(dir, &gated)?;
        manager.stop(original, current).await?;
        let after = manager
            .inspect(Some(original), verify_definitions(dir, original)?)
            .await?;
        ensure!(
            after.pid.is_none()
                && daemon::capture_service(&original.id, false)
                    .await?
                    .pid()
                    .is_none(),
            "SERVICE_STOP_FAILED: daemon is still present"
        );
        Ok::<_, anyhow::Error>(())
    }
    .await;
    if let Err(error) = result {
        write_record(dir, original).context(
            "SERVICE_RECOVERY_FAILED: stop failed and prior registration could not be restored; retain service state"
        )?;
        let outcome = async {
            let after = manager.inspect(Some(original), verify_definitions(dir, original)?).await?;
            let observed = daemon::capture_service(&original.id, false).await?;
            ensure!(after.pid == observed.pid(), "ownership differs");
            if observed.pid().is_some() {
                captured.verify()?;
                Ok::<_, anyhow::Error>("original instance remains running")
            } else {
                Ok("service is stopped; use `zc service start` to resume the prior frozen invocation")
            }
        }.await;
        bail!("SERVICE_STOP_FAILED: {}; prior registration and start permission restored; stop command failed: {error:#}",
            outcome.unwrap_or("stop outcome is uncertain; inspect `zc service status` and the manager before retrying"));
    }
    Ok(())
}

impl Manager<'_> {
    async fn start(&self, record: &Registration, loaded: bool) -> Result<()> {
        match record.platform {
            Platform::Launchd => {
                self.launch(&["enable".into(), self.target()]).await?;
                if !loaded {
                    let (path, _) = state(false)?;
                    self.launch(&[
                        "bootstrap".into(),
                        self.domain(),
                        path_text(&path.join(definition_name(record.platform)))?.into(),
                    ])
                    .await?;
                } else {
                    self.launch(&["kickstart".into(), self.target()]).await?;
                }
            }
            Platform::Systemd => {
                self.system(&["start".into(), UNIT.into()]).await?;
            }
        }
        Ok(())
    }
    async fn stop(&self, record: &Registration, current: &ManagerState) -> Result<()> {
        match record.platform {
            Platform::Launchd if current.loaded => {
                self.launch(&["bootout".into(), self.target()]).await?;
            }
            Platform::Systemd if current.loaded => {
                self.system(&["stop".into(), UNIT.into()]).await?;
            }
            _ => (),
        }
        Ok(())
    }
}
async fn start_ready(
    manager: &Manager<'_>,
    record: &Registration,
    dir: &SecureDir,
    started_pid: &mut Option<u32>,
) -> Result<()> {
    let current = manager
        .inspect(Some(record), verify_definitions(dir, record)?)
        .await?;
    ensure!(
        current.pid.is_none(),
        "SERVICE_CONTENDED: a manager process appeared before this startup attempt; it was not adopted or stopped"
    );
    // A persistent external launchctl disable blocks bootstrap. Clearing it is
    // necessary to start now, but must not silently enable next-login startup.
    if record.platform == Platform::Launchd && !current.enabled && verify_definitions(dir, record)?
    {
        manager.enable(record, false).await?;
    }
    manager.start(record, current.loaded).await?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let current = manager
            .inspect(Some(record), verify_definitions(dir, record)?)
            .await?;
        if let Some(pid) = current.pid {
            ensure!(
                started_pid.is_none_or(|expected| expected == pid),
                "SERVICE_CONTENDED: manager process changed during startup"
            );
            *started_pid = Some(pid);
        }
        if let Ok(observed) = daemon::capture_service(&record.id, false).await {
            ensure!(
                observed.pid().is_none() || observed.pid() == current.pid,
                "SERVICE_INSTANCE_MISMATCH: readiness belongs to another process"
            );
            if observed.ready() {
                return Ok(());
            }
        }
        ensure!(
            tokio::time::Instant::now() < deadline,
            "SERVICE_START_FAILED: manager success did not produce a ready daemon"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
/// Foreground manager entry. The registration and random identity, never an
/// environment flag, authorize this invocation; launch ownership closes races.
pub async fn run_owned(id: &str) -> Result<()> {
    daemon::run_service(id, || {
        let (_, dir) = state(false)?;
        let record = read_record(&dir)?.context("SERVICE_STATE_INVALID: registration missing")?;
        ensure!(
            record.id == id
                && record.allowed
                && record.binary == std::env::current_exe()?.canonicalize()?
                && record.home == home()?
                && record.runtime == daemon::service_runtime_path()?,
            "SERVICE_INSTANCE_MISMATCH: service invocation is not authorized"
        );
        verify_definitions(&dir, &record)?;
        daemon::load_snapshot(&dir, &record.snapshot, &record.id)
    })
    .await
}

pub(crate) fn manual_guard() -> Result<FileLock> {
    let lock = operation_lock()?;
    check_manual_ownership()?;
    Ok(lock)
}

// Manual restart/reload check before preparation, separately from running-state capture.
// The execution guard rechecks this under the lock before changing the runtime.
pub(crate) fn check_manual_ownership() -> Result<()> {
    match state(false) {
        Ok((_, dir)) => {
            if let Some(record) = read_record(&dir)? {
                ensure!(
                    record.runtime != daemon::service_runtime_path()?,
                    "SERVICE_OWNED: use `zc service start/stop/restart` for this registered runtime"
                );
            } else {
                ensure!(
                    !dir.exists("org.zc.user.plist")? && !dir.exists(UNIT)?,
                    "SERVICE_STATE_INVALID: service registration is missing; retain and inspect state"
                );
            }
        }
        Err(e)
            if e.downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) => {}
        Err(e) => return Err(e),
    }
    Ok(())
}

/// Read-only candidate compatibility check, including authenticated frozen input.
pub fn check_candidate() -> Result<()> {
    if let Some(store) = crate::service::existing_store()? {
        store.load_existing().context("SERVICE_STATE_INVALID: established catalog is missing or invalid; retain state instead of recovering from mirrors")?;
    }
    match state(false) {
        Ok((_, dir)) => {
            let record =
                read_record(&dir)?.context("SERVICE_STATE_INVALID: registration missing")?;
            verify_definitions(&dir, &record)?;
            daemon::validate_service_prepared(&daemon::load_snapshot(
                &dir,
                &record.snapshot,
                &record.id,
            )?)?;
        }
        Err(e) if missing(&e) => (),
        Err(e) => return Err(e),
    }
    Ok(())
}
fn missing(e: &anyhow::Error) -> bool {
    e.downcast_ref::<std::io::Error>()
        .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound)
}

/// Installed daemons hold a shared lease for their entire lifetime. Publication
/// takes the exclusive side, closing the scan/rename race across HOME namespaces.
pub(crate) fn binary_lease() -> Result<Option<FileLock>> {
    use std::os::unix::fs::MetadataExt;
    let binary = std::env::current_exe()?;
    let parent = binary.parent().context("executable parent missing")?;
    // Root-owned distribution installs remain usable; this user cannot publish there.
    if parent.metadata()?.uid() != rustix::process::geteuid().as_raw() {
        return Ok(None);
    }
    let dir = SecureDir::open_owned_absolute(parent, false)?;
    Ok(Some(
        dir.shared_lock(".zc.binary.lock", Duration::from_secs(1))?,
    ))
}

async fn publish(source: &Path, target_dir: &Path, publisher: &Path) -> Result<()> {
    let out = run_bounded(
        "/bin/bash",
        &[
            path_text(publisher)?.into(),
            "--publish-only".into(),
            "--source".into(),
            path_text(source)?.into(),
            "--target-dir".into(),
            path_text(target_dir)?.into(),
        ],
    )
    .await?;
    ensure!(
        out.code == 0,
        "SERVICE_PUBLISH_FAILED: staging publisher refused replacement; check target ownership and running processes; for a manual instance, stop it explicitly and migrate with `zc service start -c <config> --port <port>`"
    );
    Ok(())
}
/// Cold activation transaction. No manager calls are made for a first install.
/// The caller must await completion; the CLI uses `install_with_signals` rather
/// than dropping this future, so command cleanup and rollback retain their locks.
pub async fn install(
    source: &Path,
    target_dir: &Path,
    publisher: &Path,
    runner: &dyn CommandRunner,
) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let source = source
        .canonicalize()
        .context("SERVICE_CANDIDATE_INVALID: candidate is missing")?;
    let publisher = publisher.canonicalize()?;
    std::fs::create_dir_all(target_dir)?;
    let target_dir = target_dir.canonicalize()?;
    let target = target_dir.join("zc");
    ensure!(
        target != source,
        "SERVICE_CANDIDATE_INVALID: source and target must differ"
    );
    let target_fd = SecureDir::open_owned_absolute(&target_dir, false)?;
    let _install = target_fd.lock(".zc.install.guard", Duration::from_secs(1))?;
    let candidate_name = format!(".zc.candidate.{}", fsutil::nonce()?);
    target_fd.write_new(
        &candidate_name,
        &fsutil::read_installation_source(&source, 256 * 1024 * 1024)?,
    )?;
    let _candidate = CandidateFile {
        dir: &target_fd,
        name: candidate_name.clone(),
    };
    let source = target_dir.join(candidate_name);
    std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o700))?;
    let version = run_bounded(path_text(&source)?, &["--version".into()]).await?;
    ensure!(
        version.code == 0 && version.stdout.starts_with("zc "),
        "SERVICE_CANDIDATE_INVALID: candidate version check failed"
    );
    let compatible = run_bounded(path_text(&source)?, &["--service-check".into()]).await?;
    ensure!(
        compatible.code == 0 && compatible.stdout.trim() == "zc-service-install-v1",
        "SERVICE_CANDIDATE_INVALID: candidate does not accept the frozen service state"
    );
    if cfg!(target_os = "macos") {
        let file = run_bounded("/usr/bin/file", &["-b".into(), path_text(&source)?.into()]).await?;
        if file.stdout.contains("Mach-O") {
            let signed = run_bounded(
                "/usr/bin/codesign",
                &[
                    "--verify".into(),
                    "--strict".into(),
                    path_text(&source)?.into(),
                ],
            )
            .await?;
            ensure!(
                signed.code == 0,
                "SERVICE_CANDIDATE_INVALID: candidate signature check failed"
            );
        }
    }
    let _operation = operation_lock()?;
    let launch = daemon::service_launch_lock()?;
    let state = match state(false) {
        Ok(state) => Some(state),
        Err(e) if missing(&e) => None,
        Err(e) => return Err(e),
    };
    if state.is_none() {
        ensure!(
            !login_definition_exists(runner.platform())?,
            "SERVICE_STATE_INVALID: definition exists without registration"
        );
    }
    let mut record = match &state {
        Some((_, dir)) => {
            Some(read_record(dir)?.context("SERVICE_STATE_INVALID: registration missing")?)
        }
        None => None,
    };
    let original_registration = record.clone();
    let manager = Manager { runner };
    let mut was_running = false;
    let mut original_capture = None;
    if let Some(record) = &mut record {
        runner.authorize(&home()?).await?;
        ensure!(
            record.binary == target
                && record.home == home()?
                && record.runtime == daemon::service_runtime_path()?
                && record.platform == runner.platform(),
            "SERVICE_TARGET_MISMATCH: installer target or runtime differs from the registered service"
        );
        let dir = &state.as_ref().expect("registered state").1;
        let current = manager
            .inspect(Some(record), verify_definitions(dir, record)?)
            .await?;
        let capture = daemon::capture_service(&record.id, true).await?;
        ensure!(
            capture.pid() == current.pid,
            "SERVICE_INSTANCE_MISMATCH: installer cannot prove service ownership"
        );
        was_running = capture.ready();
        if let Some(prepared) = capture.prepared.clone() {
            record.snapshot = daemon::save_snapshot(dir, prepared, &record.id)?;
        }
        capture.verify()?;
        original_capture = Some(capture);
    } else {
        ensure!(
            daemon::capture_restart().await?.prepared.is_none(),
            "SERVICE_MANUAL_INSTANCE: confirm and stop the manual instance in its original runtime, then migrate explicitly with `zc service start -c <config> --port <port>`"
        );
    }
    let backup = if target_fd.exists("zc")? {
        let meta = target.symlink_metadata()?;
        ensure!(
            !meta.file_type().is_symlink(),
            "SERVICE_TARGET_INVALID: installation target must not be a symbolic link"
        );
        ensure!(
            meta.is_file()
                && meta.uid() == rustix::process::geteuid().as_raw()
                && meta.nlink() == 1
                && meta.mode() & 0o022 == 0,
            "SERVICE_TARGET_INVALID: target must be an owned, non-writable-by-others regular file"
        );
        let name = format!(".zc.recovery.{}", fsutil::nonce()?);
        target_fd.write_new(&name, &fsutil::read_regular(&target, 256 * 1024 * 1024)?)?;
        let path = target_dir.join(name);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))?;
        Some(path)
    } else {
        ensure!(
            record.is_none(),
            "SERVICE_STATE_INVALID: registered installation is missing"
        );
        None
    };
    let mut publication_attempted = false;
    let result = async {
        check_install_interruption()?;
    if record.is_some() {
        let out = run_bounded(path_text(&source)?, &["--service-check".into()]).await?;
        ensure!(
            out.code == 0 && out.stdout.trim() == "zc-service-install-v1",
            "SERVICE_CANDIDATE_INVALID: candidate rejected captured running state"
        );
    }
        if let Some(record) = &mut record {
            let dir = &state.as_ref().expect("registered state").1;
            let current = manager
                .inspect(Some(record), verify_definitions(dir, record)?)
                .await?;
            original_capture
                .as_ref()
                .context("SERVICE_STATE_INVALID: original capture missing")?
                .verify()?;
            // Recheck the exact runtime immediately before asking the manager to stop.
            let capture = daemon::capture_service(&record.id, false).await?;
            ensure!(
                capture.pid() == current.pid && capture.ready() == was_running,
                "SERVICE_CONTENDED: service changed before stop"
            );
            record.allowed = false;
            write_record(dir, record)?;
            manager.stop(record, &current).await?;
            ensure!(
                daemon::capture_service(&record.id, false)
                    .await?
                    .pid()
                    .is_none(),
                "SERVICE_STOP_FAILED: service is still running"
            );
        }
        let lease = target_fd
            .lock(".zc.binary.lock", Duration::from_secs(1))
            .context("SERVICE_CONTENDED: a target instance is running; publication was refused; confirm and stop it with its original HOME/XDG_RUNTIME_DIR, then migrate explicitly with `zc service start -c <config> --port <port>`")?;
        target_fd.validate_owned_path(&target_dir, false)?;
        _install.validate(&target_fd, ".zc.install.guard")?;
        check_install_interruption()?;
        publication_attempted = true;
        publish(&source, &target_dir, &publisher).await?;
        target_fd.validate_owned_path(&target_dir, false)?;
        drop(lease);
        Ok::<_, anyhow::Error>(())
    }
    .await;
    drop(launch);
    let mut started_pid = None;
    let result = match result {
        Ok(()) if was_running => {
            let record = record.as_mut().expect("running service");
            record.allowed = true;
            let dir = &state.as_ref().expect("registered state").1;
            match write_record(dir, record) {
                Ok(()) => start_ready(&manager, record, dir, &mut started_pid).await,
                Err(e) => Err(e),
            }
        }
        Ok(()) => {
            if let Some(record) = &mut record {
                record.allowed = true;
                write_record(&state.as_ref().expect("registered state").1, record)
            } else {
                Ok(())
            }
        }
        result => result,
    };
    let result = result.and_then(|()| check_install_interruption());
    if let Err(error) = result {
        if error.chain().any(|cause| {
            cause
                .to_string()
                .starts_with("SERVICE_COMMAND_CLEANUP_FAILED:")
        }) {
            bail!(
                "SERVICE_RECOVERY_FAILED: command cleanup is uncertain; no further publication or automatic recovery attempted; inspect and terminate retained command processes before using .zc.recovery.* and service state; cause: {error:#}"
            );
        }
        let (_recovery_tx, recovery_rx) = tokio::sync::watch::channel(false);
        let recovery = INSTALL_CANCEL
            .scope(recovery_rx, async {
                let launch = daemon::service_launch_lock()?;
                if let Some(record) = &mut record {
                    let dir = &state.as_ref().expect("registered state").1;
                    record.allowed = false;
                    write_record(dir, record)?;
                    let current = manager
                        .inspect(Some(record), verify_definitions(dir, record)?)
                        .await?;
                    verify_recovery_owner(record, &current, started_pid, original_capture.as_ref())
                        .await?;
                    if !publication_attempted && current.pid.is_some() {
                        // Stop failed or was interrupted before taking effect. The
                        // exact original instance is still alive: leave it untouched.
                        let original = original_registration
                            .as_ref()
                            .context("original registration missing")?;
                        write_record(dir, original)?;
                        return Ok(());
                    }
                    manager.stop(record, &current).await?;
                }
                if let Some(backup) = &backup {
                    let original = fsutil::read_regular(backup, 256 * 1024 * 1024)?;
                    // If publication never happened (or the publisher restored it),
                    // preserve the old inode and allow its exact invocation to resume.
                    if fsutil::read_regular(&target, 256 * 1024 * 1024)
                        .ok()
                        .as_ref()
                        != Some(&original)
                    {
                        let _lease = target_fd.lock(".zc.binary.lock", Duration::from_secs(1))?;
                        target_fd.validate_owned_path(&target_dir, false)?;
                        publish(backup, &target_dir, &publisher).await?;
                    }
                } else if target_fd.exists("zc")? {
                    bail!("SERVICE_RECOVERY_FAILED: first-install target requires inspection");
                }
                drop(launch);
                if let Some(record) = &mut record {
                    record.allowed = true;
                    let dir = &state.as_ref().expect("registered state").1;
                    write_record(dir, record)?;
                    if was_running {
                        start_ready(&manager, record, dir, &mut None).await?;
                    }
                }
                Ok::<_, anyhow::Error>(())
            })
            .await;
        if let Err(recovery) = recovery {
            bail!(
                "SERVICE_RECOVERY_FAILED: installation/activation failed and exact recovery failed; retain .zc.recovery.* and service state for inspection; original: {error:#}; recovery: {recovery:#}"
            );
        }
        if let Some(backup) = &backup {
            target_fd.remove_file(
                backup
                    .file_name()
                    .and_then(|n| n.to_str())
                    .context("backup name")?,
            )?;
        }
        bail!(
            "SERVICE_INSTALL_ROLLED_BACK: installation/activation failed; old binary and prior running/stopped invocation restored; cause: {error:#}"
        );
    }
    if let Some(backup) = &backup {
        target_fd.remove_file(
            backup
                .file_name()
                .and_then(|n| n.to_str())
                .context("backup name")?,
        )?;
    }
    if let (Some(original), Some(committed), Some((_, dir))) =
        (&original_registration, &record, &state)
    {
        retire_snapshots(dir, committed, &[&original.snapshot])?;
    }
    Ok(())
}

fn login_definition_exists(platform: Platform) -> Result<bool> {
    match login_dir(platform, false) {
        Ok((_, dir)) => Ok(dir.exists(definition_name(platform))?),
        Err(e) if missing(&e) => Ok(false),
        Err(e) => Err(e),
    }
}

struct CandidateFile<'a> {
    dir: &'a SecureDir,
    name: String,
}
impl Drop for CandidateFile<'_> {
    fn drop(&mut self) {
        let _ = self.dir.remove_file(&self.name);
    }
}

async fn verify_recovery_owner(
    record: &Registration,
    manager: &ManagerState,
    started_pid: Option<u32>,
    original: Option<&daemon::ServiceCapture>,
) -> Result<()> {
    if let Some(pid) = manager.pid
        && started_pid != Some(pid)
    {
        let original =
            original.context("SERVICE_CONTENDED: manager process is not this startup attempt")?;
        ensure!(
            original.pid() == Some(pid),
            "SERVICE_CONTENDED: manager process changed during recovery"
        );
        original.verify()?;
    }
    match daemon::capture_service(&record.id, false).await {
        Ok(capture) => ensure!(
            capture.pid().is_none() || capture.pid() == manager.pid,
            "SERVICE_INSTANCE_MISMATCH: runtime changed during recovery"
        ),
        Err(e)
            if started_pid.is_some()
                && manager.pid == started_pid
                && e.to_string()
                    .starts_with("SERVICE_CONTENDED: instance startup") => {}
        Err(e) => return Err(e),
    }
    Ok(())
}
