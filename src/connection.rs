//! Instance-local connection authority; snapshots contain indices, never credentials.
use crate::{
    config::{Config, Route},
    target::Target,
};
use serde::Serialize;
use std::{
    collections::BTreeMap,
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use tokio::sync::watch;

mod probes;
pub(crate) use probes::{Probe, ProbeError};

pub const PROBE_HEADER: &str = "x-zc-probe-token";
pub const INSTANCE_HEADER: &str = "x-zc-instance-nonce";
pub const LIMIT: usize = 1024;

#[derive(Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Phase {
    Handshake,
    Routing,
    Connecting,
    Active,
    Idle,
    UdpWait,
    Rejected,
    Closing,
}
#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Protocol {
    Tcp,
    Udp,
}
#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Inbound {
    HttpConnect,
    HttpForward,
    Socks5Connect,
    Socks5Udp,
}

#[derive(Clone, Serialize)]
struct Metadata {
    id: String,
    source: SocketAddr,
    protocol: Protocol,
    phase: Phase,
    #[serde(skip_serializing_if = "Option::is_none")]
    inbound: Option<Inbound>,
    #[serde(skip_serializing_if = "Option::is_none")]
    target: Option<Target>,
    #[serde(skip_serializing_if = "Option::is_none")]
    routed_target: Option<Target>,
    #[serde(skip_serializing_if = "Option::is_none")]
    datagram_source: Option<SocketAddr>,
    #[serde(skip_serializing_if = "Option::is_none")]
    target_scope: Option<&'static str>,
}
struct Entry {
    metadata: Metadata,
    route: Option<(usize, usize)>,
    cancel: watch::Sender<bool>,
}
#[derive(Default)]
struct State {
    sequence: u64,
    entries: BTreeMap<u64, Entry>,
}
pub struct ConnectionRegistry {
    nonce: String,
    state: Mutex<State>,
    probes: Mutex<probes::Tickets>,
}
pub(crate) enum CloseError {
    Invalid,
    Instance,
    Missing,
}
impl ConnectionRegistry {
    pub fn new() -> std::io::Result<Arc<Self>> {
        Ok(Self::for_instance(crate::fsutil::nonce()?))
    }
    pub(crate) fn for_instance(nonce: String) -> Arc<Self> {
        Arc::new(Self {
            nonce,
            state: Mutex::new(State::default()),
            probes: Mutex::new(probes::Tickets::default()),
        })
    }
    pub(crate) fn nonce(&self) -> &str {
        &self.nonce
    }
    pub(crate) fn register(
        self: &Arc<Self>,
        source: SocketAddr,
    ) -> Option<(Guard, watch::Receiver<bool>)> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.entries.len() >= LIMIT {
            return None;
        }
        let sequence = state.sequence.checked_add(1)?;
        state.sequence = sequence;
        // Publish with a receiver already alive. wait_for also observes a preexisting true.
        let (cancel, cancelled) = watch::channel(false);
        state.entries.insert(
            sequence,
            Entry {
                metadata: Metadata {
                    id: format!("{}-{sequence}", self.nonce),
                    source,
                    protocol: Protocol::Tcp,
                    phase: Phase::Handshake,
                    inbound: None,
                    target: None,
                    routed_target: None,
                    datagram_source: None,
                    target_scope: None,
                },
                route: None,
                cancel,
            },
        );
        Some((
            Guard {
                registry: self.clone(),
                sequence,
            },
            cancelled,
        ))
    }
    pub(crate) fn close(&self, id: &str) -> Result<(), CloseError> {
        let (nonce, sequence) = split_id(id).ok_or(CloseError::Invalid)?;
        if nonce != self.nonce {
            return Err(CloseError::Instance);
        }
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let entry = state
            .entries
            .get_mut(&sequence)
            .ok_or(CloseError::Missing)?;
        entry.metadata.phase = Phase::Closing;
        entry.cancel.send_replace(true);
        Ok(())
    }
    pub(crate) fn write_list(
        &self,
        config: &Config,
        writer: impl std::io::Write,
    ) -> serde_json::Result<()> {
        // Release the lock before config access or serialization; target lengths and count are bounded.
        let snapshots: Vec<_> = self
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entries
            .values()
            .map(|e| (e.metadata.clone(), e.route))
            .collect();
        #[derive(Serialize)]
        struct View<'a> {
            #[serde(flatten)]
            metadata: &'a Metadata,
            #[serde(skip_serializing_if = "Option::is_none")]
            rule: Option<crate::config::RuleView<'a>>,
            #[serde(skip_serializing_if = "Option::is_none")]
            proxy: Option<crate::config::ProxyView<'a>>,
        }
        #[derive(Serialize)]
        struct List<'a> {
            connections: Vec<View<'a>>,
        }
        let connections = snapshots
            .iter()
            .map(|(metadata, route)| View {
                metadata,
                rule: route.map(|(rule, _)| config.rule_view(rule)),
                proxy: route.map(|(_, leaf)| config.proxy_view(leaf)),
            })
            .collect();
        serde_json::to_writer(writer, &List { connections })
    }
}
pub(crate) fn split_id(id: &str) -> Option<(&str, u64)> {
    let (nonce, sequence) = id.rsplit_once('-')?;
    if nonce.len() != 32
        || !nonce
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        || sequence.starts_with('0')
        || !sequence.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    Some((nonce, sequence.parse().ok()?))
}
pub(crate) struct Guard {
    registry: Arc<ConnectionRegistry>,
    sequence: u64,
}
impl Guard {
    fn update(&self, change: impl FnOnce(&mut Entry)) {
        let mut state = self
            .registry
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Some(entry) = state.entries.get_mut(&self.sequence)
            && entry.metadata.phase != Phase::Closing
        {
            change(entry);
        }
    }
    pub(crate) fn phase(&self, phase: Phase) {
        self.update(|e| e.metadata.phase = phase);
    }
    pub(crate) fn inbound(&self, inbound: Inbound) {
        self.update(|e| {
            e.metadata.inbound = Some(inbound);
            if matches!(inbound, Inbound::Socks5Udp) {
                e.metadata.protocol = Protocol::Udp;
                e.metadata.phase = Phase::UdpWait;
            }
        });
    }
    pub(crate) fn target(
        &self,
        target: &Target,
        datagram_source: Option<SocketAddr>,
        inbound: Inbound,
    ) {
        self.update(|e| {
            e.metadata.inbound = Some(inbound);
            e.metadata.target = Some(target.clone());
            e.metadata.routed_target = None;
            e.route = None;
            e.metadata.phase = Phase::Routing;
            e.metadata.datagram_source = datagram_source;
            e.metadata.target_scope = datagram_source.map(|_| "first_datagram");
        });
    }
    pub(crate) fn routed(&self, route: &Route<'_>) {
        self.update(|e| {
            e.metadata.routed_target = Some(route.target.clone());
            e.route = Some((route.rule_index, route.leaf_index));
            e.metadata.phase = Phase::Connecting;
        });
    }
    pub(crate) fn idle(&self) {
        self.update(|e| {
            e.metadata.phase = Phase::Idle;
            e.metadata.target = None;
            e.metadata.routed_target = None;
            e.route = None;
        });
    }
}
impl Drop for Guard {
    fn drop(&mut self) {
        self.registry
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entries
            .remove(&self.sequence);
    }
}

pub(crate) fn valid_response(value: &serde_json::Value, nonce: &str, id: Option<&str>) -> bool {
    use serde_json::Value;
    fn keys(value: &Value, required: &[&str], optional: &[&str]) -> bool {
        value.as_object().is_some_and(|map| {
            required.iter().all(|k| map.contains_key(*k))
                && map
                    .keys()
                    .all(|k| required.contains(&k.as_str()) || optional.contains(&k.as_str()))
        })
    }
    fn target(value: &Value) -> bool {
        keys(value, &["host", "port"], &[])
            && value["host"]
                .as_str()
                .is_some_and(|s| !s.is_empty() && s.len() <= 255)
            && value["port"]
                .as_u64()
                .is_some_and(|p| (1..=65535).contains(&p))
    }
    if let Some(id) = id {
        return keys(value, &["id", "phase", "close_requested"], &[])
            && value["id"] == id
            && value["phase"] == "closing"
            && value["close_requested"] == true;
    }
    if !keys(value, &["connections"], &[]) {
        return false;
    }
    let Some(entries) = value["connections"].as_array().filter(|v| v.len() <= LIMIT) else {
        return false;
    };
    let mut ids = std::collections::BTreeSet::new();
    entries.iter().all(|e| {
        if !keys(
            e,
            &["id", "source", "protocol", "phase"],
            &[
                "inbound",
                "target",
                "routed_target",
                "rule",
                "proxy",
                "datagram_source",
                "target_scope",
            ],
        ) {
            return false;
        }
        let Some(id) = e["id"].as_str() else {
            return false;
        };
        if !split_id(id).is_some_and(|(n, _)| n == nonce) || !ids.insert(id) {
            return false;
        }
        if e["source"]
            .as_str()
            .and_then(|v| v.parse::<SocketAddr>().ok())
            .is_none()
            || !matches!(e["protocol"].as_str(), Some("tcp" | "udp"))
            || !matches!(
                e["phase"].as_str(),
                Some(
                    "handshake"
                        | "routing"
                        | "connecting"
                        | "active"
                        | "idle"
                        | "udp_wait"
                        | "rejected"
                        | "closing"
                )
            )
        {
            return false;
        }
        if let Some(v) = e.get("inbound")
            && !matches!(
                v.as_str(),
                Some("http_connect" | "http_forward" | "socks5_connect" | "socks5_udp")
            )
        {
            return false;
        }
        for key in ["target", "routed_target"] {
            if let Some(v) = e.get(key)
                && !target(v)
            {
                return false;
            }
        }
        if let Some(v) = e.get("datagram_source")
            && v.as_str()
                .and_then(|v| v.parse::<SocketAddr>().ok())
                .is_none()
        {
            return false;
        }
        if let Some(v) = e.get("target_scope")
            && (v != "first_datagram"
                || e["protocol"] != "udp"
                || e.get("datagram_source").is_none())
        {
            return false;
        }
        if e.get("rule").is_some() != e.get("proxy").is_some()
            || e.get("rule").is_some() != e.get("routed_target").is_some()
        {
            return false;
        }
        if let Some(v) = e.get("rule")
            && (!keys(v, &["index", "type", "payload", "target"], &[])
                || !v["index"].as_u64().is_some_and(|i| i < 262144)
                || v["type"].as_str().is_none()
                || v["payload"].as_str().is_none()
                || v["target"].as_str().is_none())
        {
            return false;
        }
        if let Some(v) = e.get("proxy")
            && (!keys(v, &["name", "type"], &[])
                || v["name"].as_str().is_none()
                || !matches!(
                    v["type"].as_str(),
                    Some("Direct" | "Reject" | "Shadowsocks" | "Trojan" | "AnyTLS")
                ))
        {
            return false;
        }
        if matches!(e["phase"].as_str(), Some("idle" | "handshake" | "udp_wait"))
            && (e.get("target").is_some() || e.get("rule").is_some())
        {
            return false;
        }
        if matches!(
            e["phase"].as_str(),
            Some("active" | "connecting" | "rejected")
        ) && (e.get("target").is_none() || e.get("rule").is_none() || e.get("inbound").is_none())
        {
            return false;
        }
        if e["phase"] == "routing" && (e.get("target").is_none() || e.get("rule").is_some()) {
            return false;
        }
        let udp = e["protocol"] == "udp";
        if udp != (e["inbound"] == "socks5_udp")
            || (e["phase"] == "udp_wait" && !udp)
            || (e["phase"] == "handshake" && udp)
        {
            return false;
        }
        // UDP targets describe the first valid datagram as one atomic snapshot.
        // TCP entries and associations still waiting for it have no datagram metadata.
        let datagram = udp && e.get("target").is_some();
        if e.get("datagram_source").is_some() != datagram
            || e.get("target_scope").is_some() != datagram
        {
            return false;
        }
        if e["phase"] == "idle" && e["inbound"] != "http_forward" {
            return false;
        }
        e.get("routed_target").is_none() || e.get("target").is_some()
    })
}
