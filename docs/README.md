# zc documentation

This directory is the public documentation entry for the current zc v1.0 release work.

For a first read, start with the root [`README.md`](../README.md). It contains the project overview, status, install-from-source flow, quick start, and the current zc project mark.

## Current status

zc 当前处于 **v1.0 release-candidate cleanup**，尚未进入最终 GA。当前发布计划以代码事实为准：

1. 修复工具链与 release workflow 漂移；
2. 让文档声明与已实现能力一致；
3. 从 v1.0 范围移除 TUI；
4. 清理过期文档；
5. 让代理选择具备持久、revision-aware 的一致语义；
6. 增加经过验证、仅 CLI 可用的本地 config import；
7. 通过最终 smoke gate 后再标记 `v1.0.0`。

公开 v1.0 roadmap 见 [`roadmap/v1.0.md`](roadmap/v1.0.md)。可靠持久选择与 `config import` 当前均为**计划能力，尚未实现**；当前命令契约仍以 [`cli/spec.md`](cli/spec.md) 为准。

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

The current project mark has three PNG variants:

- [`assets/zc-mark-transparent.png`](assets/zc-mark-transparent.png) for transparent background usage and the root README.
- [`assets/zc-mark-dark.png`](assets/zc-mark-dark.png) for dark framed usage.
- [`assets/zc-mark-light.png`](assets/zc-mark-light.png) for light background usage.

## Archived docs

Historical drafts and stale planning documents live under [`archive/`](archive/). They are kept only for traceability and **do not represent current v1.0 commitments**.

The TUI documentation has been archived because TUI is removed from the v1.0 release scope.

## v1.0 scope summary

Included:

- daemon lifecycle through CLI: `start` (`up`), `stop` (`down`), `restart`, `reload`, `status`, `log`, `doctor`, with a uniform `--json` envelope on stdout and uniform exit codes (see [`cli/spec.md`](cli/spec.md));
- default mixed inbound runtime;
- AnyTLS 出站(动态 padding、session 多路复用 + 空闲池、UoT v2 UDP 中继;[设计](anytls/session-multiplexing-design.md) / [兼容与已知限制](compat/mihomo-clash.md));
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
