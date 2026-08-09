# zc documentation

This directory is the public documentation entry for zc.

首次阅读请从根目录 [`README.md`](../README.md) 开始，其中只列出 zc 相对 mihomo 已实现与未实现的能力；安装、CLI、API 与运行细节由本目录中的专题文档分别维护。

## Current status

v1.0 实现路线图已经完成，`v1.0.0` 是当前正式发布基线。已完成的范围和常规发布验证入口见 [`roadmap/v1.0.md`](roadmap/v1.0.md)；该文件是完成记录，不再作为进行中的任务清单。

可靠持久选择与本地 `zc config load <path>` 已接入用户路径：选择先持久化再按 exact revision 尝试应用，本地配置及其依赖导入 immutable revision。托管下载只自动激活首个 runtime-ready revision；可恢复的 malformed simple-obfs raw revision 保持 inactive，capability 与资源上界错误使用文档化的 `CONFIG_CAPABILITY_UNSUPPORTED` / `CONFIG_*_LIMIT_EXCEEDED`。运行时 outbound manager 是 owned opaque handle，借用的配置及嵌套存储在 handle 销毁前必须保持 immutable/address-stable；准入使用预建 borrowed-key 索引，因此成本按 group 解析深度固定，不随配置节点总数线性增长。当前完整命令契约见 [`cli/spec.md`](cli/spec.md)，错误码见 [`api/error-codes.md`](api/error-codes.md)。

## v1.0 documentation map

| Area | Document | Purpose |
| --- | --- | --- |
| Release | [`roadmap/v1.0.md`](roadmap/v1.0.md) | Completed v1.0 scope and validation record. |
| CLI | [`cli/spec.md`](cli/spec.md) | Current command surface and JSON contract status. |
| Config | [`config/override.md`](config/override.md) | Runtime override behavior. |
| Compatibility | [`compat/mihomo-clash.md`](compat/mihomo-clash.md) | mihomo/clash compatibility boundaries and unsupported features. |
| Migrator | [`compat/migrator-rules-quickref.md`](compat/migrator-rules-quickref.md) | Config migrator rule reference. |
| Install | [`install/README.md`](install/README.md) | Standalone one-line installer、static release、Homebrew 与本地验证流程。 |
| API | [`api/README.md`](api/README.md) | Minimal API endpoints currently implemented. |
| E2E | [`reliability/e2e.md`](reliability/e2e.md) | PR/tag-only real binary, network and protocol interoperability gate. |
| Research | [`research/shadowsocks-simple-obfs-udp.md`](research/shadowsocks-simple-obfs-udp.md) | Primary-source wire and acceptance basis for simple-obfs HTTP and Shadowsocks UDP. |
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
- fixed `7899` mixed inbound runtime, with an explicit CLI override for non-production runs;
- DIRECT、REJECT、四种 Shadowsocks AEAD cipher 的 TCP，以及 `udp:true` 节点经 mixed SOCKS5 UDP ASSOCIATE 的 classic AEAD UDP；
- non-production explicit port override via `zc start --port <port>`;
- core rule matching and rule-provider expansion;
- minimal REST API for version/proxies/rules/proxy selection;
- checksum-verified standalone installer、static Linux artifacts、PR/main real E2E and release validation gates.

Not included in v1.0:

- TUI;
- TUN/redir/tproxy transparent proxying;
- complete mihomo DNS behavior;
- complete REST API v1/WebSocket event stream;
- HTTP/SOCKS5/VMess/VLESS/AnyTLS outbound；这些协议只有在独立 wire、互操作、资源和生命周期门禁通过后才会逐个启用。
