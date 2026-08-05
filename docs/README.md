# zc documentation

This directory is the public documentation entry for the current zc v1.0 release work.

首次阅读请从根目录 [`README.md`](../README.md) 开始，其中包含项目概览、状态、Homebrew Tap 与源码安装入口、quick start 和当前项目标识。

## Current status

zc 当前处于 **v1.0 release-candidate cleanup**，尚未进入最终 GA。当前发布计划以代码事实为准：

1. 修复工具链与 release workflow 漂移；
2. 让文档声明与已实现能力一致；
3. 从 v1.0 范围移除 TUI；
4. 清理过期文档；
5. 用统一 capability gate 在 bind/dial 前拒绝未经验证的协议；
6. 让代理选择具备持久、revision-aware 的一致语义；
7. 增加经过验证、仅 CLI 可用的本地 config import；
8. 修复安全审计阻断项并通过最终 smoke gate 后再标记 `v1.0.0`。

公开 v1.0 roadmap 见 [`roadmap/v1.0.md`](roadmap/v1.0.md)。可靠持久选择与本地 `zc config load <path>` 已接入用户路径：选择先持久化再按 exact revision 尝试应用，本地配置及其依赖导入 immutable revision。当前完整命令契约见 [`cli/spec.md`](cli/spec.md)。

## v1.0 documentation map

| Area | Document | Purpose |
| --- | --- | --- |
| CLI | [`cli/spec.md`](cli/spec.md) | Current command surface and JSON contract status. |
| Config | [`config/override.md`](config/override.md) | Runtime override behavior. |
| Compatibility | [`compat/mihomo-clash.md`](compat/mihomo-clash.md) | mihomo/clash compatibility boundaries and unsupported features. |
| Migrator | [`compat/migrator-rules-quickref.md`](compat/migrator-rules-quickref.md) | Config migrator rule reference. |
| Install | [`install/README.md`](install/README.md) | Standalone one-line installer、static release、Homebrew 与本地验证流程。 |
| API | [`api/README.md`](api/README.md) | Minimal API endpoints currently implemented. |
| E2E | [`reliability/e2e.md`](reliability/e2e.md) | PR/tag-only real binary, network and protocol interoperability gate. |
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
- DIRECT、REJECT、四种 Shadowsocks AEAD cipher 与 Trojan TCP/TLS 出站；
- non-production explicit port override via `zc start --port <port>`;
- core rule matching and rule-provider expansion;
- minimal REST API for version/proxies/rules/proxy selection;
- checksum-verified standalone installer、static Linux artifacts、PR/tag-only real E2E and release validation gates.

Not included in v1.0:

- TUI;
- TUN/redir/tproxy transparent proxying;
- complete mihomo DNS behavior;
- complete REST API v1/WebSocket event stream;
- HTTP/SOCKS5/VMess/VLESS/AnyTLS outbound；这些协议只有在独立 wire、互操作、资源和生命周期门禁通过后才会逐个启用。
