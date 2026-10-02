//! Request-bound runtime evidence, never route prediction or connection-list matching.
use super::{diagnostic_request_probe, diagnostic_target_probe};
use crate::{connection::PROBE_HEADER, daemon::ConnectionControl, target::Target};
use anyhow::{Result, ensure};
use reqwest::Method;
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Clone, Copy)]
struct Unknown(&'static str, &'static str);
impl Unknown {
    fn from_error(error: &anyhow::Error) -> Self {
        let text = error.to_string();
        if text.starts_with("CONNECTION_NOT_RUNNING:") {
            Self(
                "not_running",
                "start the intended zc instance with an explicit controller and retry",
            )
        } else if text.starts_with("CONNECTION_CONTROLLER_REQUIRED:") {
            Self(
                "controller_required",
                "configure external-controller and explicitly reprepare with `zc restart -c <profile>`; no listener is opened automatically",
            )
        } else if text.starts_with("CONNECTION_SECRET_REQUIRED:") {
            Self(
                "secret_required",
                "explicitly reprepare the managed profile to enable its controller secret; unmanaged configs need a nonempty secret",
            )
        } else if text.starts_with("CONNECTION_UNAUTHORIZED:") {
            Self(
                "unauthorized",
                "verify the running controller authentication; no tracking ticket was trusted",
            )
        } else if text.starts_with("CONNECTION_INSTANCE_CHANGED:") {
            Self(
                "instance_changed",
                "retry against a stable running instance",
            )
        } else {
            Self(
                "evidence_unavailable",
                "check the controller version and reachability, then retry; route evidence requires request-ticket support",
            )
        }
    }
    fn apply(self, target: &mut Value) {
        target["actual_path"] = json!("unknown");
        target["path_reason"] = json!(self.0);
        target["path_hint"] = json!(self.1);
    }
}
#[derive(Clone)]
pub(super) struct Tracking {
    control: Option<Arc<ConnectionControl>>,
    unknown: Unknown,
}
impl Tracking {
    pub(super) async fn capture(port: u16) -> Self {
        let control = ConnectionControl::capture().await;
        let (control, unknown) = match control {
            Ok(control) if control.port() == port => (
                Some(Arc::new(control)),
                Unknown(
                    "route_not_observed",
                    "the request ended before a runtime route was recorded; inspect runtime diagnostics",
                ),
            ),
            Ok(_) => (
                None,
                Unknown(
                    "port_mismatch",
                    "use the running zc mixed port; external --port proxies do not provide authenticated zc request evidence",
                ),
            ),
            Err(error) => (None, Unknown::from_error(&error)),
        };
        Self { control, unknown }
    }
    pub(super) async fn probe(&self, client: &reqwest::Client, name: &str, url: &str) -> Value {
        let Some(control) = &self.control else {
            let mut result = diagnostic_target_probe(client, name, url).await;
            self.unknown.apply(&mut result);
            return result;
        };
        // A regular HTTPS request header would travel inside the tunnel to the
        // remote origin. Only absolute-form HTTP can carry this hop-local ticket.
        let target = reqwest::Url::parse(url)
            .ok()
            .filter(|u| u.scheme() == "http")
            .and_then(|url| {
                Target::new(
                    url.host_str()?
                        .trim_start_matches('[')
                        .trim_end_matches(']'),
                    url.port_or_known_default()?,
                )
                .ok()
            });
        let Some(target) = target else {
            let mut result = diagnostic_target_probe(client, name, url).await;
            Unknown(
                "unsupported_scheme",
                "request-bound route evidence currently supports HTTP forward probes only",
            )
            .apply(&mut result);
            return result;
        };
        let reserved = control
            .request(
                Method::PUT,
                "/connections/probes",
                Some(&json!({"host":target.host(),"port":target.port()})),
            )
            .await;
        let token = reserved.and_then(|value| {
            ensure!(
                value.as_object().is_some_and(|o| o.len() == 1),
                "invalid ticket response"
            );
            let token = value["token"]
                .as_str()
                .filter(|t| valid_token(t, control.nonce()))
                .ok_or_else(|| anyhow::anyhow!("invalid ticket response"))?;
            Ok(token.to_owned())
        });
        let token = match token {
            Ok(token) => token,
            Err(error) => {
                let mut result = diagnostic_target_probe(client, name, url).await;
                Unknown::from_error(&error).apply(&mut result);
                return result;
            }
        };
        // Nominate the ticket as hop-by-hop as well as stripping it in zc.
        // If an older zc or conforming proxy takes over the port between the
        // reservation and dispatch, it must also remove this field upstream.
        let mut result = diagnostic_request_probe(
            client
                .get(url)
                .header(reqwest::header::CONNECTION, PROBE_HEADER)
                .header(PROBE_HEADER, &token),
            name,
        )
        .await;
        let path = format!("/connections/probes/{token}");
        let observed = control
            .request(Method::GET, &path, None)
            .await
            .and_then(|value| evidence(value, &token, &target, control.nonce()));
        // Tickets are bounded and expire even when cleanup is unavailable. Do
        // not overwrite a successfully validated snapshot with a cleanup error.
        let _ = control.request(Method::DELETE, &path, None).await;
        match observed {
            Ok(Some(evidence)) => {
                let proxy = evidence.proxy.expect("routed evidence has a proxy");
                result["actual_path"] = json!(match proxy.kind.as_str() {
                    "Direct" => "direct",
                    "Reject" => "reject",
                    _ => "proxy",
                });
                result["proxy"] = json!({"name":proxy.name,"type":proxy.kind});
                result["route_evidence"] = json!({"connection_id":evidence.connection_id,"request_index":evidence.request_index});
            }
            Ok(None) => self.unknown.apply(&mut result),
            Err(error) => Unknown::from_error(&error).apply(&mut result),
        }
        result
    }
}
fn valid_token(token: &str, nonce: &str) -> bool {
    token.split_once('.').is_some_and(|(n, random)| {
        n == nonce
            && random.len() == 32
            && random
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Evidence {
    token: String,
    state: String,
    target: ProbeTarget,
    connection_id: Option<String>,
    request_index: Option<u32>,
    proxy: Option<Leaf>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProbeTarget {
    host: String,
    port: u16,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Leaf {
    name: String,
    #[serde(rename = "type")]
    kind: String,
}
fn evidence(value: Value, token: &str, target: &Target, nonce: &str) -> Result<Option<Evidence>> {
    let parsed: Evidence = serde_json::from_value(value)?;
    ensure!(
        parsed.token == token
            && parsed.target.host == target.host()
            && parsed.target.port == target.port(),
        "mismatched probe evidence"
    );
    if parsed.state == "reserved" {
        ensure!(
            parsed.connection_id.is_none()
                && parsed.request_index.is_none()
                && parsed.proxy.is_none(),
            "invalid unclaimed evidence"
        );
        return Ok(None);
    }
    ensure!(
        parsed
            .connection_id
            .as_deref()
            .and_then(crate::connection::split_id)
            .is_some_and(|(n, _)| n == nonce)
            && parsed.request_index.is_some_and(|i| i < 1024),
        "invalid request identity"
    );
    if parsed.state == "claimed" {
        ensure!(parsed.proxy.is_none(), "invalid pending evidence");
        return Ok(None);
    }
    ensure!(
        parsed.state == "routed"
            && parsed.proxy.as_ref().is_some_and(|p| !p.name.is_empty()
                && matches!(
                    p.kind.as_str(),
                    "Direct" | "Reject" | "Shadowsocks" | "Trojan" | "AnyTLS"
                )),
        "invalid route evidence"
    );
    Ok(Some(parsed))
}

pub(super) fn path_summary(targets: &[Value]) -> Value {
    let mut summary = json!({});
    for path in ["direct", "proxy", "reject", "unknown"] {
        let total = targets.iter().filter(|t| t["actual_path"] == path).count();
        let succeeded = targets
            .iter()
            .filter(|t| t["actual_path"] == path && t["ok"] == true)
            .count();
        summary[path] = json!({"total":total,"succeeded":succeeded,"failed":total-succeeded});
    }
    summary
}
