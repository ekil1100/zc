//! Bounded request tickets, retained independently of active connection guards.
use super::{ConnectionRegistry, Guard};
use crate::{
    config::{Config, Route},
    target::Target,
};
use serde::Serialize;
use std::{
    collections::BTreeMap,
    sync::Arc,
    time::{Duration, Instant},
};

const LIMIT: usize = 256;
const RETENTION: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ProbeError {
    Invalid,
    Instance,
    Missing,
    Consumed,
    Target,
    Quota,
    Unavailable,
    ResponseTooLarge,
}
impl std::fmt::Display for ProbeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Invalid => "Invalid probe request",
            Self::Instance => "Probe instance changed",
            Self::Missing => "Probe not found",
            Self::Consumed => "Probe already claimed",
            Self::Target => "Probe target mismatch",
            Self::Quota => "Probe quota exceeded",
            Self::Unavailable => "Probe unavailable",
            Self::ResponseTooLarge => "Response Too Large",
        })
    }
}
impl std::error::Error for ProbeError {}

#[derive(Clone)]
struct Claim {
    connection_id: String,
    request_index: u32,
    // Actual route indices only; never retain the credential-bearing proxy.
    route: Option<(usize, usize)>,
}
#[derive(Clone)]
struct Ticket {
    reserved: Instant,
    target: Target,
    claim: Option<Claim>,
}
#[derive(Default)]
pub(super) struct Tickets {
    sequence: u32,
    entries: BTreeMap<String, Ticket>,
}
impl Tickets {
    fn expire(&mut self) {
        let now = Instant::now();
        self.entries
            .retain(|_, t| now.duration_since(t.reserved) < RETENTION);
    }
}

fn normalized(target: &Target) -> Result<Target, ProbeError> {
    // Revalidate even a Target constructed by the permissive SOCKS path.
    let host = target
        .host()
        .parse::<std::net::IpAddr>()
        .map(|ip| ip.to_string())
        .unwrap_or_else(|_| target.host().to_ascii_lowercase());
    // Keep the trailing DNS dot: an absolute name and a search-relative name
    // need not resolve to the same destination.
    Target::new(host, target.port()).map_err(|_| ProbeError::Invalid)
}
impl ConnectionRegistry {
    fn validate_probe_token(&self, token: &str) -> Result<(), ProbeError> {
        let (nonce, random) = token.split_once('.').ok_or(ProbeError::Invalid)?;
        let hex = |s: &str| {
            s.len() == 32
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        };
        if !hex(nonce) || !hex(random) {
            return Err(ProbeError::Invalid);
        }
        if nonce != self.nonce {
            return Err(ProbeError::Instance);
        }
        Ok(())
    }

    pub(crate) fn reserve_probe(&self, target: &Target) -> Result<String, ProbeError> {
        let mut tickets = self.probes.lock().unwrap_or_else(|e| e.into_inner());
        tickets.expire();
        let target = normalized(target)?;
        if tickets.entries.len() >= LIMIT {
            return Err(ProbeError::Quota);
        }
        let sequence = tickets.sequence.checked_add(1).ok_or(ProbeError::Quota)?;
        // 96 fresh random bits plus a checked 32-bit issuance counter: bounded
        // memory and no reuse even after expiry/delete or an RNG collision.
        // Exhaustion rejects instead of wrapping. Bearer auth is still required.
        let mut random = [0; 12];
        getrandom::fill(&mut random).map_err(|_| ProbeError::Unavailable)?;
        let random: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let token = format!("{}.{random}{sequence:08x}", self.nonce);
        tickets.sequence = sequence;
        tickets.entries.insert(
            token.clone(),
            Ticket {
                reserved: Instant::now(),
                target,
                claim: None,
            },
        );
        Ok(token)
    }

    pub(crate) fn release_probe(&self, token: &str) -> Result<(), ProbeError> {
        let mut tickets = self.probes.lock().unwrap_or_else(|e| e.into_inner());
        tickets.expire();
        self.validate_probe_token(token)?;
        tickets.entries.remove(token).ok_or(ProbeError::Missing)?;
        Ok(())
    }

    pub(crate) fn write_probe(
        &self,
        token: &str,
        config: &Config,
        writer: impl std::io::Write,
    ) -> Result<(), ProbeError> {
        let ticket = {
            let mut tickets = self.probes.lock().unwrap_or_else(|e| e.into_inner());
            tickets.expire();
            self.validate_probe_token(token)?;
            tickets
                .entries
                .get(token)
                .ok_or(ProbeError::Missing)?
                .clone()
        };
        #[derive(Serialize)]
        struct View<'a> {
            token: &'a str,
            state: &'static str,
            target: &'a Target,
            #[serde(skip_serializing_if = "Option::is_none")]
            connection_id: Option<&'a str>,
            #[serde(skip_serializing_if = "Option::is_none")]
            request_index: Option<u32>,
            #[serde(skip_serializing_if = "Option::is_none")]
            proxy: Option<crate::config::ProxyView<'a>>,
        }
        let claim = ticket.claim.as_ref();
        let route = claim.and_then(|c| c.route);
        // Borrow configuration names before writing to the API's bounded writer.
        // Only the small, bounded ticket is cloned outside the registry lock.
        serde_json::to_writer(
            writer,
            &View {
                token,
                state: if route.is_some() {
                    "routed"
                } else if claim.is_some() {
                    "claimed"
                } else {
                    "reserved"
                },
                target: &ticket.target,
                connection_id: claim.map(|c| c.connection_id.as_str()),
                request_index: claim.map(|c| c.request_index),
                proxy: route.map(|(_, leaf)| config.proxy_view(leaf)),
            },
        )
        .map_err(|_| ProbeError::ResponseTooLarge)
    }
}

pub(crate) struct Probe {
    registry: Arc<ConnectionRegistry>,
    token: String,
}
impl Guard {
    /// Claim once, after parsing the HTTP target and before any dial.
    pub(crate) fn claim_probe(
        &self,
        token: &str,
        target: &Target,
        request_index: u32,
    ) -> Result<Probe, ProbeError> {
        let mut tickets = self
            .registry
            .probes
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        tickets.expire();
        self.registry.validate_probe_token(token)?;
        let target = normalized(target)?;
        let ticket = tickets.entries.get_mut(token).ok_or(ProbeError::Missing)?;
        if ticket.claim.is_some() {
            return Err(ProbeError::Consumed);
        }
        if ticket.target != target {
            return Err(ProbeError::Target);
        }
        ticket.claim = Some(Claim {
            connection_id: format!("{}-{}", self.registry.nonce, self.sequence),
            request_index,
            route: None,
        });
        Ok(Probe {
            registry: self.registry.clone(),
            token: token.to_owned(),
        })
    }
}
impl Probe {
    /// Capture the first actual route. Repeated calls cannot rewrite history;
    /// release/expiry cannot be undone by a late route calculation.
    pub(crate) fn routed(&self, route: &Route<'_>) {
        let mut tickets = self
            .registry
            .probes
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        tickets.expire();
        if let Some(ticket) = tickets.entries.get_mut(&self.token)
            && let Some(claim) = &mut ticket.claim
            && claim.route.is_none()
        {
            claim.route = Some((route.rule_index, route.leaf_index));
        }
    }
}
