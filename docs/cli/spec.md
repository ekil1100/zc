# zc CLI spec — v1.0 current contract

This document describes the command surface implemented by `src/main.zig` for the v1.0 cleanup line.

## Global commands

| Command | Status | Notes |
| --- | --- | --- |
| `zc help` / `zc --help` | implemented | Prints global help. |
| `zc help <topic>` | implemented | Prints group help for `config`, `proxy`, `profile`, `diag`, or `doctor`. |
| `zc start [-c <config>] [--port <port>] [--json]` | implemented | Starts daemon; `--port` overrides mixed-port for this run. |
| `zc stop [--json]` | implemented | Stops tracked daemon. |
| `zc restart [-c <config>] [--json]` | implemented | Restarts daemon after preflight. |
| `zc status [--json]` | implemented | 输出运行状态、运行时路径，以及 select 代理组当前节点；无持久化选择时显示该组默认首个节点。 |
| `zc log [-n <lines>] [-f|--no-follow]` | implemented | Tails daemon log. |
| `zc test [-c <config>] [--json]` | implemented | 文本和 JSON 输出都会包含 select 代理组当前节点；JSON 模式只做本地监听探测，不执行外部连通性探测。 |
| `zc doctor [-c <config>] [--json]` | implemented | 配置/服务诊断；端口输出展示有效运行时 mixed 端口，运行中的 daemon 可发现 `start --port` 时优先展示该覆盖端口。 |
| `zc diag doctor [-c <config>] [--json]` | implemented | `doctor` 别名，端口输出语义一致。 |

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

## Error output direction

v1.0 should use actionable errors with:

- stable `code`;
- human-readable `message`;
- next-step `hint`.

Some API and older CLI paths still need alignment; do not advertise full consistency until tested.
