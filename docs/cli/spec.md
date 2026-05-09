# zc CLI spec — v1.0 current contract

This document describes the command surface implemented by `src/main.zig` for the v1.0 cleanup line.

## Global commands

| Command | Status | Notes |
| --- | --- | --- |
| `zc help` / `zc --help` | implemented | Prints global help. |
| `zc help <topic>` | implemented | Prints group help for `config`, `proxy`, `profile`, `diag`, or `doctor`. |
| `zc start [-c <config>] [--port <port>] [--json]` | implemented | Starts daemon; if a tracked daemon is already running, reports `already_running` instead of treating its port as a conflict. `--port` overrides mixed-port for this run. |
| `zc stop [--json]` | implemented | Stops tracked daemon. |
| `zc restart [-c <config>] [--json]` | implemented | Restarts daemon after preflight. |
| `zc status [--json]` | implemented | 输出运行状态、运行时路径，以及 select 代理组当前节点；无持久化选择时显示该组默认首个节点。 |
| `zc log [-n <lines>] [-f|--no-follow]` | implemented | Tails daemon log. |
| `zc test [-c <config>] [--json]` | implemented | 文本和 JSON 输出都会包含 select 代理组当前节点；端口未监听时文本输出会报告 daemon 状态；JSON 输出包含 `daemon_state`。JSON 模式只做本地监听探测，不执行外部连通性探测。 |
| `zc doctor [-c <config>] [--json]` | implemented | 轻量配置/服务诊断；文本输出固定为 `Config`、`Daemon`、`PID`、`Port`、`Connection`；普通模式不刷新或展开远程 rule-provider。 |
| `zc diag doctor [-c <config>] [--json]` | implemented | `doctor` 别名，端口输出和轻量诊断语义一致。 |

The TUI command is intentionally excluded from v1.0 and is not present in help/dispatch.

## Config commands

All config subcommands accept `help`, `--help`, or `-h` after the subcommand, for example `zc config download --help`.

| Command | Status |
| --- | --- |
| `zc config help` / `zc config --help` / `zc config -h` | implemented |
| `zc config list` / `zc config ls` | implemented |
| `zc config download <url> [-n <name>]` | implemented |
| `zc config update [<name>] [--apply <auto|hot|restart>]` | implemented |
| `zc config use <name>` | implemented |
| `zc config dump [-c <config>] [--no-override] [--json]` | implemented |
| `zc config override [<script>|--clear]` | implemented |

## Proxy/profile commands

All proxy/profile subcommands accept `help`, `--help`, or `-h` after the subcommand, for example `zc proxy select --help`.

| Command | Status |
| --- | --- |
| `zc proxy help` / `zc proxy --help` / `zc proxy -h` | implemented |
| `zc proxy list` / `zc proxy ls` | implemented; supports `--json` |
| `zc proxy select [-g <group>] [-p <proxy>]` | implemented |
| `zc proxy test` | implemented；输出当前节点信息 |
| `zc profile help` / `zc profile --help` / `zc profile -h` | implemented |
| `zc profile list` / `zc profile ls` | implemented |
| `zc profile select` | implemented |
| `zc profile test` | implemented |
| `zc diag help` / `zc diag --help` / `zc diag -h` | implemented |
| `zc diag doctor --help` | implemented |

## JSON contract

已实现并经过 smoke 验证：

- `status --json`
- `start --json`
- `stop --json`
- `doctor --json`
- `proxy list --json`
- `test --json`
- `proxy test --json`

JSON success payloads are emitted on stdout so they can be piped directly into JSON tooling.
Diagnostics and human-readable progress may use stderr on legacy paths until each command is fully aligned.

## Error output direction

v1.0 should use actionable errors with:

- stable `code`;
- human-readable `message`;
- next-step `hint`.

Some API and older CLI paths still need alignment; do not advertise full consistency until tested.
