fn main() -> std::process::ExitCode {
    let raw: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    let args: Vec<String> = match raw.iter().map(|arg| arg.clone().into_string()).collect() {
        Ok(args) => args,
        Err(_) => {
            let json = raw.iter().any(|arg| arg == "--json");
            let command = raw
                .iter()
                .take(2)
                .filter_map(|arg| arg.to_str())
                .collect::<Vec<_>>()
                .join(" ");
            let code = if matches!(command.as_str(), "config load" | "config download") {
                "CONFIG_NAME_INVALID"
            } else {
                "COMMAND_UNKNOWN"
            };
            if json {
                println!(
                    "{}",
                    zc::cli::ascii_json(
                        &serde_json::json!({"ok":false,"command":command,"error":{"code":code,"message":"command arguments must be valid UTF-8","hint":"use a UTF-8 config name and path"}})
                    )
                );
            } else {
                eprintln!(
                    "error: command arguments must be valid UTF-8\nhint: use a UTF-8 config name and path\ncode: {code}"
                );
            }
            return std::process::ExitCode::FAILURE;
        }
    };
    // Internal worker modes must bypass ordinary CLI parsing and output envelopes.
    if args
        .first()
        .is_some_and(|arg| arg == zc::override_script::WORKER_ARGUMENT)
    {
        return match zc::override_script::worker_main() {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("error: {error}");
                std::process::ExitCode::FAILURE
            }
        };
    }
    // Short CLI commands need async IO, not a pool of runtime worker threads.
    // Keep daemon/foreground scheduling unchanged; override workers above stay synchronous.
    let service = args.first().is_some_and(|arg| arg == "--service-run");
    let daemon = args.first().is_some_and(|arg| arg == "--daemon-run");
    let foreground = args
        .first()
        .is_some_and(|arg| matches!(arg.as_str(), "start" | "up"))
        && args.iter().any(|arg| arg == "--foreground");
    let mut builder = if daemon || foreground || service {
        tokio::runtime::Builder::new_multi_thread()
    } else {
        tokio::runtime::Builder::new_current_thread()
    };
    let runtime = match builder.enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("error: cannot initialize async runtime: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    runtime.block_on(async {
        if args.first().is_some_and(|arg| arg == "--install-check") {
            if args.len() != 1 {
                return std::process::ExitCode::from(2);
            }
            println!("zc-release-install-v1");
            return std::process::ExitCode::SUCCESS;
        }
        if args.first().is_some_and(|arg| arg == "--local-install") {
            if args.len() != 3 {
                return std::process::ExitCode::from(2);
            }
            return match zc::user_service::install_embedded(
                std::path::Path::new(&args[1]),
                std::path::Path::new(&args[2]),
                &zc::user_service::Native,
            )
            .await
            {
                Ok(()) => std::process::ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("error: {error:#}");
                    std::process::ExitCode::FAILURE
                }
            };
        }
        if args.first().is_some_and(|arg| arg == "--service-check") {
            return match zc::user_service::check_candidate() {
                Ok(()) => {
                    println!("zc-service-install-v1");
                    std::process::ExitCode::SUCCESS
                }
                Err(_) => {
                    eprintln!("Candidate rejected service state; original installation retained");
                    std::process::ExitCode::FAILURE
                }
            };
        }
        if service {
            if args.len() != 2 {
                return std::process::ExitCode::from(2);
            }
            return match zc::user_service::run_owned(&args[1]).await {
                Ok(()) => std::process::ExitCode::SUCCESS,
                Err(_) => {
                    eprintln!(
                        "Service startup or runtime failed; inspect service state and daemon log"
                    );
                    std::process::ExitCode::FAILURE
                }
            };
        }
        if daemon {
            if args.len() != 3 {
                eprintln!("error: invalid daemon invocation");
                return std::process::ExitCode::from(2);
            }
            return match zc::daemon::run_child(&args[1], &args[2]).await {
                Ok(()) => std::process::ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("error: {error}");
                    std::process::ExitCode::FAILURE
                }
            };
        }
        std::process::ExitCode::from(zc::cli::run(args).await)
    })
}
