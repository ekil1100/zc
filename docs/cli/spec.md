# zc CLI spec — v1.0 current contract

This document describes the command surface implemented by `src/main.zig` for the v1.0 cleanup line.

## Global commands

| Command | Status | Notes |
| --- | --- | --- |
| `zc help` / `zc --help` | implemented | Prints help. |
| `zc start [-c <config>] [--port <port>] [--json]` | implemented | Starts daemon; `--port` overrides mixed-port for this run. |
| `zc stop [--json]` | implemented | Stops tracked daemon. |
| `zc restart [-c <config>] [--json]` | implemented | Restarts daemon after preflight. |
| `zc status [--json]` | implemented | Prints runtime state and paths. |
| `zc log [-n <lines>] [-f|--no-follow]` | implemented | Tails daemon log. |
| `zc test [-c <config>]` | implemented | Text output only today; `--json` is a v1.0 blocker. |
| `zc doctor [-c <config>] [--json]` | implemented | Config/service/port diagnostics. |
| `zc diag doctor [-c <config>] [--json]` | implemented | Alias for doctor. |

The TUI command is intentionally excluded from v1.0 and is not present in help/dispatch.

## Config commands

| Command | Status |
| --- | --- |
| `zc config list` / `zc config ls` | implemented |
| `zc config download <url> [-n <name>]` | implemented |
| `zc config update [<name>] [--apply <auto|hot|restart>]` | implemented |
| `zc config use <name>` | implemented |
| `zc config dump [-c <config>] [--no-override] [--json]` | implemented |
| `zc config override [<script>|--clear]` | implemented |

## Proxy/profile commands

| Command | Status |
| --- | --- |
| `zc proxy list` / `zc proxy ls` | implemented; supports `--json` |
| `zc proxy select [-g <group>] [-p <proxy>]` | implemented |
| `zc proxy test` | implemented |
| `zc profile list` / `zc profile ls` | implemented |
| `zc profile select` | implemented |
| `zc profile test` | implemented |

## JSON contract

Implemented and smoke-tested:

- `status --json`
- `start --json`
- `stop --json`
- `doctor --json`
- `proxy list --json`

Known v1.0 blocker:

- `test --json` currently prints the text report path. It must be fixed or removed from the advertised JSON contract.

## Error output direction

v1.0 should use actionable errors with:

- stable `code`;
- human-readable `message`;
- next-step `hint`.

Some API and older CLI paths still need alignment; do not advertise full consistency until tested.
