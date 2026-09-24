use std::{net::IpAddr, sync::OnceLock, time::Duration};

use anyhow::{Context, Result, anyhow, bail};
use hickory_resolver::{
    Resolver, TokioResolver,
    config::{LookupIpStrategy, ResolveHosts, ResolverConfig, ResolverOpts},
    net::runtime::TokioRuntimeProvider,
};
use tokio::{sync::Semaphore, time::timeout};

use crate::{observability::FailureStage, target::Target};

const LIMIT: usize = 64;
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(2);

pub struct Dns {
    config: Option<ResolverConfig>,
    resolver: OnceLock<Result<TokioResolver, String>>,
    slots: Semaphore,
}

impl Dns {
    pub fn system() -> Self {
        Self {
            config: None,
            resolver: OnceLock::new(),
            slots: Semaphore::new(LIMIT),
        }
    }

    // Accept real Hickory nameserver configuration, not a mock lookup implementation.
    // The same bounds apply to system DNS and explicitly supplied nameservers.
    pub fn from_config(config: ResolverConfig) -> Result<Self> {
        validate_config(&config)?;
        Ok(Self {
            config: Some(config),
            ..Self::system()
        })
    }

    fn resolver(&self) -> Result<&TokioResolver> {
        self.resolver
            .get_or_init(|| self.build_resolver().map_err(|error| format!("{error:#}")))
            .as_ref()
            .map_err(|error| anyhow!("{error}"))
    }

    fn build_resolver(&self) -> Result<TokioResolver> {
        // Only local configuration/hosts reads are synchronous. Network resolution never
        // uses getaddrinfo, spawn_blocking, or a process-global runtime-bound resolver.
        let (config, mut options) = match &self.config {
            Some(config) => (config.clone(), ResolverOpts::default()),
            None => hickory_resolver::system_conf::read_system_conf().context(
                "cannot read system DNS configuration; configure system nameservers (no public DNS fallback)",
            )?,
        };
        validate_config(&config)?;
        options.timeout = LOOKUP_TIMEOUT;
        options.attempts = 0;
        options.num_concurrent_reqs = 1;
        options.max_active_requests = LIMIT;
        options.cache_size = LIMIT as u64;
        options.ip_strategy = LookupIpStrategy::Ipv4AndIpv6;
        options.use_hosts_file = ResolveHosts::Always;
        options.preserve_intermediates = false;
        Resolver::builder_with_config(config, TokioRuntimeProvider::default())
            .with_options(options)
            .build()
            .context("cannot initialize async DNS resolver")
    }

    pub async fn resolve(&self, target: &Target) -> Result<Vec<IpAddr>> {
        self.resolve_inner(target).await.map_err(|error| {
            // Preserve the public resolver diagnostic while carrying a typed stage.
            let message = error.to_string();
            error.context(FailureStage::Dns).context(message)
        })
    }

    async fn resolve_inner(&self, target: &Target) -> Result<Vec<IpAddr>> {
        if let Ok(ip) = target.host().parse::<IpAddr>() {
            return Ok(vec![ip]);
        }
        // Fail fast rather than retaining an unbounded queue of waiting queries.
        // Dropping this future releases the slot even if the DNS peer is silent.
        // Reserve both A and AAAA requests: at most 64 concurrent wire queries.
        let _slot = self
            .slots
            .try_acquire_many(2)
            .map_err(|_| anyhow!("DNS concurrency limit of 64 reached; retry later"))?;
        timeout(LOOKUP_TIMEOUT, async {
            let lookup = self
                .resolver()?
                .lookup_ip(target.host())
                .await
                .context("DNS lookup failed; check system DNS and destination name")?;
            let addresses: Vec<_> = lookup.iter().take(LIMIT + 1).collect();
            if addresses.is_empty() || addresses.len() > LIMIT {
                bail!("DNS lookup must return between 1 and 64 addresses; connection denied");
            }
            Ok(addresses)
        })
        .await
        .context("DNS lookup timed out after 2 seconds; connection denied")?
    }
}

fn validate_config(config: &ResolverConfig) -> Result<()> {
    if config.name_servers().is_empty() {
        bail!("no DNS nameservers configured; configure system DNS (no public DNS fallback)");
    }
    if config.name_servers().len() > LIMIT
        || config.search().len() > LIMIT
        || config
            .name_servers()
            .iter()
            .map(|server| server.connections.len())
            .sum::<usize>()
            > LIMIT
    {
        bail!("DNS configuration exceeds the 64-entry resource limit");
    }
    Ok(())
}
