# Changelog

## [Unreleased]

### Added (AnyTLS protocol completion)
- **Dynamic padding scheme**: parse the AnyTLS padding-scheme grammar (ranges + CheckMarks + `stop`), emit randomized multi-record framing per the scheme (replacing the old fixed shaping), and adopt server-pushed `update-padding-scheme` (cmd 6). The advertised `padding-md5` always matches the active scheme. Closes a static traffic-fingerprint gap.
- **Session multiplexing + idle pool**: one authenticated TLS session is reused across connections (single-active-stream-per-session, anytls-go parity) instead of a full TLS+auth handshake per connection. A per-session background recv-loop demultiplexes frames; an idle-session pool with a reaper honors `idle-session-check-interval` / `idle-session-timeout` / `min-idle-session` (config keys, seconds; sub-5s values clamp to 30). SYN-DONE bounded wait on reused streams.
- **UoT v2 UDP relay**: SOCKS5 UDP ASSOCIATE inbound bridged to sing UDP-over-TCP v2 over an AnyTLS stream. Per-proxy `udp: true` flag; routing picks the proxy by matching the first datagram's real target against the rule engine.
- **Anti-fingerprint / correctness fixes**: omit SNI for IP-literal servers (an IP in ClientHello is an abnormal handshake); surface the server `alert` (cmd 5) reason instead of discarding it; bounded TCP keepalive on the upstream proxy socket; honor half-close (per-stream FIN) on the relay path.
- Known TLS-stack limitations (uTLS fingerprint, ALPN, TLS-version control, mTLS, Reality) are documented in [`docs/compat/mihomo-clash.md`](docs/compat/mihomo-clash.md) and [`docs/anytls/session-multiplexing-design.md`](docs/anytls/session-multiplexing-design.md).

### Added
- `zc reload` for hot-reloading the current config into the running daemon (falls back to restart when hot reload is unavailable).
- `zc start --foreground` for containers/systemd (no fork; `zclash.service`, `build-deb.sh`, and the podman e2e use it).
- `zc version` / `zc --version` (plain version on stdout; supports `--json`).
- Command aliases `zc up` (start) and `zc down` (stop).
- Per-command help generated from a declarative command table (`zc <command> --help`, `zc help <command>`); `zc start --help` no longer starts a daemon.
- `--no-color` global flag; ANSI colors are TTY-only and honor `NO_COLOR`.
- `zc log --json` emits JSON Lines (one `{"line":"..."}` event per line; implies `--no-follow` unless `-f`).

### Changed (CLI output-contract alignment — breaking)
- **Output streams**: payloads (human output and JSON) now go to **stdout**; diagnostics/progress go to stderr. Scripts that read JSON from stderr (`2>&1` workarounds) must read stdout instead.
- **JSON envelope**: every command emits exactly one `{"ok":true|false,"command":"<path>","data"|...,"error":{code,message,hint}}` document per run, serialized via `std.json` (names properly escaped). The `command` field is new. Exceptions: `zc config dump --json` prints a bare JSON document (text mode bare YAML) and `zc log --json` streams JSON Lines.
- **Exit codes**: uniform across modes — 0 success (including `already_running`/`already_stopped` and stopped `zc status`), 1 runtime failure, 2 usage error. JSON-mode errors, unknown subcommands, and usage errors no longer exit 0; failure paths no longer print Zig stack traces.
- **Bare `zc`** prints a short usage line to stderr and exits 2 (it previously printed full help and exited 0).
- `zc test`/`zc doctor`/`zc proxy test` run the same probes in text and JSON modes; failed checks now report `error.code=CHECKS_FAILED` with per-check `data` and exit 1.
- `zc restart --json` emits a single final envelope instead of multiple JSON lines.
- `zc proxy select --json -g <group> -p <proxy>` actually applies the selection and notifies the running daemon (`data.applied`); non-TTY `proxy select` without `-p` errors out instead of silently picking the first node.
- `zc config use` never auto-applies to a running daemon; it prints the `zc reload` next step (JSON: `data.applied:false`).
- `zc config download` no longer switches the active config on every download: the documented `-d` flag is now actually parsed, and the active config changes only with `-d` or on the very first download. Scripts that relied on download auto-switching the active config must pass `-d` (or run `zc config use <name>`).
- **Lifecycle argument parsing (D11)**: `zc start`/`zc restart`/`zc stop`/`zc status`/`zc reload`/`zc log`/`zc doctor`/`zc diag doctor` now reject unknown flags and extra arguments as usage errors (exit 2) instead of silently ignoring them, and `start`/`restart` argument errors (`START_CONFIG_PATH_REQUIRED`, `START_PORT_REQUIRED`, `START_PORT_INVALID`, `START_ARGS_INVALID`) exit 2 instead of 1. `zc log -n` now requires an integer value (previously fell back to 50). New codes: `STOP_ARGUMENT_INVALID`, `STATUS_ARGUMENT_INVALID`, `RELOAD_ARGUMENT_INVALID`, `LOG_ARGUMENT_INVALID`, `DIAG_DOCTOR_ARGUMENT_INVALID`.

### Removed (breaking)
- Global daemon discovery via ps/pgrep (decision D12): `zc status`/`zc stop` only trust the pid/lock files of the current HOME/XDG environment and never adopt or kill daemons from other environments. Untracked daemons are reported as `lock_held_pid_untracked` instead of being taken over.
- Error code `PROFILE_SUBCOMMAND_MISSING` (bare `zc profile` now prints group help, exit 0).

### Changed
- Align v1.0 release planning with code-first validation.
- Require Zig 0.16.0+ across project policy, CI, release workflow, and package metadata.
- Remove TUI from the v1.0 scope and from CLI help/dispatch.
- Replace stale root `ROADMAP.md` / `TASKS.md` planning entry points with `docs/README.md` and `docs/roadmap/v1.0.md`.
- Reframe public documentation around the currently implemented CLI, daemon runtime, minimal API, install validation, and compatibility boundaries.
- Run unit tests through an isolated test root and emit `zc test --json` success payloads on stdout.

### Archived
- Move stale install, benchmark, roadmap, API versioning, TUI, and historical agent planning drafts under `docs/archive/`.
- Archive the old full API v1 OpenAPI draft because it described endpoints and WebSocket events that are not implemented in v1.0.

### Known Blockers Before v1.0.0
- Decide and enforce the HTTP/SOCKS5 outbound policy: implement them or reject them early in validation/docs/migrator.
- Pass the final smoke gate before tagging `v1.0.0`.

## [0.1.0] - 2025-12

### Added
- Initial project structure.
- Zig build system.
- Basic proxy forwarding.
- YAML config parsing.
