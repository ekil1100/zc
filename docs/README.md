# zc documentation

This directory is the public documentation entry for the current zc v1.0 release work.

For a first read, start with the root [`README.md`](../README.md). It contains the project overview, status, install-from-source flow, quick start, and the current zc project mark.

## Current status

zc is in **v1.0 release-candidate cleanup**, not final GA. The current release plan is code-first:

1. fix toolchain/release workflow drift,
2. align documented capabilities with implemented code,
3. remove the TUI from the v1.0 scope,
4. clean stale documentation,
5. pass the final smoke gate before tagging `v1.0.0`.

See [`roadmap/v1.0.md`](roadmap/v1.0.md) for the public v1.0 roadmap.

## v1.0 documentation map

| Area | Document | Purpose |
| --- | --- | --- |
| CLI | [`cli/spec.md`](cli/spec.md) | Current command surface and JSON contract status. |
| Config | [`config/override.md`](config/override.md) | Runtime override behavior. |
| Compatibility | [`compat/mihomo-clash.md`](compat/mihomo-clash.md) | mihomo/clash compatibility boundaries and unsupported features. |
| Migrator | [`compat/migrator-rules-quickref.md`](compat/migrator-rules-quickref.md) | Config migrator rule reference. |
| Install | [`install/README.md`](install/README.md) | Local install/verify/upgrade/rollback scripts. |
| API | [`api/README.md`](api/README.md) | Minimal API endpoints currently implemented. |
| Reliability | [`reliability/soak-guide.md`](reliability/soak-guide.md) | Soak runner usage and release-gate evidence. |
| Perf reports | [`perf/reports/README.md`](perf/reports/README.md) | Perf report storage used by scripts. |

## Project assets

The current project mark lives at [`assets/zc-mark.svg`](assets/zc-mark.svg). It is an original cat-inspired routing mark for zc and is used by the root README.

## Archived docs

Historical drafts and stale planning documents live under [`archive/`](archive/). They are kept only for traceability and **do not represent current v1.0 commitments**.

The TUI documentation has been archived because TUI is removed from the v1.0 release scope.

## v1.0 scope summary

Included:

- daemon lifecycle through CLI: `start`, `stop`, `restart`, `status`, `log`, `doctor`;
- default mixed inbound runtime;
- non-production explicit port override via `zc start --port <port>`;
- core rule matching and rule-provider expansion;
- minimal REST API for version/proxies/rules/proxy selection;
- install regression scripts and release validation gate.

Not included in v1.0:

- TUI;
- TUN/redir/tproxy transparent proxying;
- complete mihomo DNS behavior;
- complete REST API v1/WebSocket event stream;
- full VMess/VLESS transport matrix;
- HTTP/SOCKS5 outbound unless explicitly implemented before GA.
