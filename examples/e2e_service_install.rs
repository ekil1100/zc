//! Test-only candidate/manager route. Never built into or installed as production zc.
#[path = "../tests/support/service_runner.rs"]
mod support;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    rt.block_on(async {
        match args.first().map(String::as_str) {
            Some("--version") => println!("zc {}", env!("CARGO_PKG_VERSION")),
            Some("--install-check") => println!("zc-release-install-v1"),
            Some("--service-check") => {
                zc::user_service::check_candidate()?;
                println!("zc-service-install-v1");
            }
            Some("--service-run") if args.len() == 2 => {
                zc::user_service::run_owned(&args[1]).await?
            }
            Some("--local-install" | "--fixture-service") => {
                let platform = match std::env::var("ZC_SERVICE_TEST_CHILD")?.as_str() {
                    "launchd" => zc::user_service::Platform::Launchd,
                    "systemd" => zc::user_service::Platform::Systemd,
                    _ => anyhow::bail!("test platform required"),
                };
                // Parent harness owns cleanup; a completed installer must leave
                // the recovered/running daemon available for status assertions.
                let runner = std::mem::ManuallyDrop::new(support::FakeManager::new(platform));
                if args[0] == "--local-install" {
                    anyhow::ensure!(args.len() == 3, "source and target required");
                    zc::user_service::install_embedded(
                        std::path::Path::new(&args[1]),
                        std::path::Path::new(&args[2]),
                        &*runner,
                    )
                    .await?;
                } else {
                    let options = if args.len() == 4 {
                        zc::service::PrepareOptions {
                            config: Some(args[2].clone()),
                            port: Some(args[3].parse()?),
                            ..Default::default()
                        }
                    } else {
                        Default::default()
                    };
                    let state = zc::user_service::execute(
                        &args[1],
                        options,
                        &std::env::current_exe()?,
                        &*runner,
                    )
                    .await?;
                    println!("{state}");
                }
            }
            _ => anyhow::bail!("unsupported test helper invocation"),
        }
        Ok(())
    })
}
