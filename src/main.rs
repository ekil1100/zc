use std::{
    fs::OpenOptions,
    io::Read,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use zc::{config::Config, runtime::Runtime};

#[derive(Parser)]
#[command(
    name = "zc",
    version,
    about = "An experimental TCP proxy runtime; foreground only, no daemon or managed state"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the experimental TCP mixed HTTP/SOCKS5 listener
    Start {
        /// Read an explicit configuration file (no managed profiles)
        #[arg(short, long, value_name = "PATH")]
        config: PathBuf,
        /// Bind exactly this port; no default or fallback port
        #[arg(long, value_parser = clap::value_parser!(u16).range(1..))]
        port: u16,
        /// Run in the foreground (required)
        #[arg(long, required = true)]
        foreground: bool,
    },
}

#[tokio::main]
async fn main() -> std::process::ExitCode {
    let cli = Cli::parse();
    match run(cli).await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error:#}");
            std::process::ExitCode::FAILURE
        }
    }
}

fn read_config(path: &Path) -> Result<Config> {
    const LIMIT: u64 = 16 * 1024 * 1024;
    let metadata = std::fs::metadata(path)
        .context("cannot inspect configuration file; check the path and permissions")?;
    // Reject special files before opening: opening a FIFO could block indefinitely.
    if !metadata.is_file() {
        bail!("configuration must be a regular file");
    }
    if metadata.len() > LIMIT {
        bail!("configuration exceeds the 16 MiB limit");
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // A path may become a FIFO after metadata(). Never block before fstat.
        options.custom_flags(libc::O_NONBLOCK | libc::O_NOCTTY);
    }
    let file = options
        .open(path)
        .context("cannot open configuration file; check read permissions")?;
    if !file
        .metadata()
        .context("cannot inspect opened configuration file")?
        .is_file()
    {
        bail!("configuration must be a regular file");
    }
    let mut bytes = Vec::new();
    file.take(LIMIT + 1)
        .read_to_end(&mut bytes)
        .context("cannot read configuration file")?;
    if bytes.len() as u64 > LIMIT {
        bail!("configuration exceeds the 16 MiB limit");
    }
    let source = std::str::from_utf8(&bytes).context("configuration must be UTF-8")?;
    // Config discards parser source snippets and returns credential-free diagnostics.
    Config::parse(source).context("invalid configuration")
}

async fn run(cli: Cli) -> Result<()> {
    let Commands::Start {
        config,
        port,
        foreground: _,
    } = cli.command;
    let config = read_config(&config)?;
    let runtime = Runtime::bind(config, port).await?;
    #[cfg(unix)]
    let shutdown = {
        use tokio::signal::unix::{SignalKind, signal};
        let mut interrupt =
            signal(SignalKind::interrupt()).context("cannot install Ctrl-C handler")?;
        let mut terminate =
            signal(SignalKind::terminate()).context("cannot install SIGTERM handler")?;
        async move {
            tokio::select! {
                _ = interrupt.recv() => {},
                _ = terminate.recv() => {},
            }
        }
    };
    #[cfg(windows)]
    let shutdown = {
        let mut interrupt =
            tokio::signal::windows::ctrl_c().context("cannot install Ctrl-C handler")?;
        async move {
            interrupt.recv().await;
        }
    };
    eprintln!(
        "Experimental TCP runtime listening on {} (foreground)",
        runtime.local_addr()?
    );
    runtime.run(shutdown).await
}
