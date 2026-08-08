<p align="center">
  <img src="docs/assets/zc-mark-transparent.png" width="176" alt="zc project mark">
</p>

<h1 align="center">zc</h1>

<p align="center">
  A Zig-powered, CLI-first proxy runtime inspired by the mihomo/clash ecosystem.
</p>

<p align="center">
  <a href="docs/README.md">Documentation</a>
  |
  <a href="docs/roadmap/v1.0.md">v1.0 roadmap</a>
  |
  <a href="docs/compat/mihomo-clash.md">Compatibility</a>
  |
  <a href="docs/api/README.md">Minimal API</a>
</p>

## What is zc?

zc is a lightweight proxy runtime and command-line tool built with Zig. It follows familiar mihomo/clash concepts such as profiles, proxies, proxy groups, rules, daemon status, runtime state, and health checks, while keeping the product surface intentionally CLI-first.

The goal is a small, observable runtime that can load mainstream proxy configurations, run a default mixed inbound listener, expose a minimal control API, and provide predictable commands for day-to-day operation.

zc does **not** include a TUI, and v1.0 is **not** positioned as a full mihomo/clash replacement.

## Project status

zc is in **v1.0 release-candidate cleanup**. It is under active development and is already usable for core local workflows:

- build and run the CLI with Zig 0.16.0+;
- start, stop, restart, inspect, and diagnose the daemon;
- load clash-style proxy, proxy-group, and rule configuration;
- run the default mixed inbound runtime;
- select proxies through the CLI or the minimal API;
- validate install, migration, reliability, and performance gates from repository scripts.

The remaining v1.0 work is tracked in [`docs/roadmap/v1.0.md`](docs/roadmap/v1.0.md). Do not treat the current release-candidate line as a final `v1.0.0` GA release until that roadmap gate is closed.

## Features

- **CLI-first operation**: `zc start`/`zc up`, `zc stop`/`zc down`, `zc restart`, `zc reload`, `zc status`, `zc log`, `zc doctor`, `zc test`, `zc config`, `zc proxy`, and `zc profile`, with generated help (`zc help <command>`).
- **Agent-friendly output contract**: every command supports `--json` (one `{"ok","command","data"|"error"}` envelope per run on stdout, `zc log --json` as JSON Lines), diagnostics go to stderr, exit codes are uniform (0 success / 1 failure / 2 usage error), and color respects `NO_COLOR` / `--no-color`.
- **Daemon lifecycle**: explicit process tracking, fork-and-exit start plus `zc start --foreground` for containers/systemd, hot reload via `zc reload`, JSON status output, log inspection, and diagnostics.
- **Default mixed inbound**: one local listener for HTTP and SOCKS5-style client traffic.
- **Config compatibility work**: parser and validator coverage for common clash-style fields, rule providers, proxy groups, and rule matching.
- **Proxy selection**: list and switch select groups through `zc proxy` or `PUT /proxies/<group>`.
- **Minimal API**: implemented endpoints for version, proxies, rules, and proxy-group selection when `external-controller` is configured.
- **Operational gates**: install regression, config migrator regression, smoke validation, reliability scenarios, and performance report scripts.

## Development requirements

- Zig `0.16.0+`
- Linux or another POSIX-like development environment for the current scripts
- `bash` for repository validation scripts
- `just` for the local install shortcut

CI and local development target Zig `0.16.0`.

## Install standalone (recommended)

Linux/macOS amd64/arm64 可以直接安装，无需 Homebrew 或 `sudo`：

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/ekil1100/zc/main/install.sh | sh
export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
zc --version
```

默认目标是 `${XDG_BIN_HOME:-$HOME/.local/bin}/zc`。Linux 发布物是静态 musl ELF；
macOS 发布物只依赖系统库。installer 会验证版本化 Release SHA-256，并在下载、校验或
自检失败时保留旧二进制；安装目标仍有进程运行时，即使新版本无法追踪其旧 runtime 状态，也拒绝覆盖。固定版本和自定义目录使用 `ZC_VERSION`、`ZC_INSTALL_DIR`，
详见 [`docs/install/README.md`](docs/install/README.md)。

## Install with Homebrew (release candidate)

当前 release candidate 通过项目 Tap 发布：

```bash
brew install ekil1100/tap/zc
zc --version
```

升级到 Tap 中的最新版本时，先用旧二进制停止 daemon，避免跨版本 runtime 路径变化造成双实例：

```bash
zc stop
brew upgrade ekil1100/tap/zc
zc start  # only if it was running before the upgrade
```

该渠道目前发布的是 `v1.0.0-rc6`，不代表 `v1.0.0` GA gate 已关闭。

## Install from source

```bash
git clone https://github.com/ekil1100/zc.git
cd zc

just install

zc --help
```

Make sure `"$HOME/.local/bin"` is on your `PATH`.

## Quick start

Use an explicit non-production port during local development. Port `7899` is reserved for production use in this project.

```bash
zc up --port 7901 -c testdata/config/minimal.yaml --json
zc status --json | jq -r .data.state
zc proxy list --json | jq .data.groups
zc doctor --json | jq .data.proxy_reachable
zc reload --json
zc down --json
```

`zc up`/`zc down` are aliases of `zc start`/`zc stop`. JSON envelopes are
emitted on stdout, so they pipe directly into `jq`; human diagnostics stay on
stderr. Set `NO_COLOR=1` or pass `--no-color` to disable ANSI colors. In
containers or under systemd, run the daemon with `zc start --foreground`.
生命周期文件优先写入 owner-only (`0700`) 的规范化 `XDG_RUNTIME_DIR`；未设置时使用 `$HOME/.local/state/zc/runtime`。后台 `start` 先绑定代理与 controller listener，但在 exact desired 对账与 runtime descriptor 发布完成前保持 accept gate 关闭；开放接入后才报告成功。

The same binary can be run without installing:

```bash
zig build
./zig-out/bin/zc start --port 7901 -c testdata/config/minimal.yaml --json
```

## Configuration

zc reads clash-style YAML configuration. A minimal shape looks like this:

```yaml
mixed-port: 7901
allow-lan: false
mode: rule
log-level: info

proxies:
  - name: demo-ss
    type: ss
    server: 127.0.0.1
    port: 8388
    cipher: aes-128-gcm
    password: "password"

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - demo-ss
      - DIRECT

rules:
  - MATCH,PROXY
```

See [`testdata/config/`](testdata/config/) for runnable examples and [`docs/compat/mihomo-clash.md`](docs/compat/mihomo-clash.md) for current compatibility boundaries.

Managed downloads auto-activate only the first **runtime-ready** config. A strict-YAML revision whose only recoverable defect is malformed Shadowsocks simple-obfs metadata can be retained for repair, but remains inactive; `config download -d`, an active `config update`, and `config use` reject it with `CONFIG_CAPABILITY_UNSUPPORTED` until plugin/TLS/cipher/group issues are fixed. `config load/download/update` report their own `*_LIMIT_EXCEEDED` code for fixed YAML/proxy bounds plus 4096 rule providers (and at most 4096 captured local-provider assets), 262144 aggregate provider entries / 64 MiB normalized bytes, **64 MiB aggregate raw provider source bytes per sync/load pass**, and 262144 expanded rules / 64 MiB owned payload+target bytes; each local or remote provider source is limited to 16 MiB and uses the typed provider-file limit error, while only the complete config's separate 16 MiB source limit uses `*_TOO_LARGE`. Proxy-compatible std HTTP→curl fallback shares the same remaining provider-source window rather than granting each transport a full cap. The separate 1024 persisted-selection limit is enforced by catalog/selection mutations, not by YAML fields; an existing on-disk excess is corrupt state and fails closed. See [`docs/cli/spec.md`](docs/cli/spec.md) and [`docs/api/error-codes.md`](docs/api/error-codes.md).

## Minimal API

The API starts when `external-controller` is set to an explicit IPv4 loopback endpoint. zc uses the exact configured port and fails startup on conflicts:

```yaml
external-controller: 127.0.0.1:9090
```

Implemented endpoints include:

- `GET /`
- `GET /version`
- `GET /proxies`
- `GET /rules`
- `PUT /proxies/<group_name>`

This is a minimal control API, not a full mihomo/clash dashboard-compatible API. See [`docs/api/README.md`](docs/api/README.md).

## Compatibility

zc is compatibility-oriented, but intentionally conservative about what it claims.

Current v1.0 documentation tracks implemented behavior for:

- mixed inbound runtime;
- core rule matching and rule-provider expansion;
- select proxy groups;
- DIRECT、REJECT、`aes-128-gcm` / `aes-256-gcm` / `chacha20-poly1305` / `chacha20-ietf-poly1305` Shadowsocks classic AEAD TCP 与 mixed SOCKS5 UDP ASSOCIATE，以及 Trojan TCP/TLS 出站；
- minimal REST control endpoints.

Shadowsocks 现在精确支持 classic 2017 AEAD TCP，以及 `udp: true` 节点经 mixed 端口提供的 SOCKS5 UDP ASSOCIATE。TCP 可使用 plain transport，或 `plugin: obfs|obfs-local` + `plugin-opts: {mode: http, host: <1..255 bytes>}`；`plugin_opts` map 会在输出时规范化为 `plugin-opts`。simple-obfs 始终只包装 TCP，UDP 直接使用同一 Shadowsocks server host/port。UDP association 全局最多 64 个，300 秒 awake-clock idle，单个 SOCKS/SS wire datagram 最多 65507 bytes；坏认证、非零 RSV/FRAG 与畸形地址静默丢弃，DIRECT 或不支持 UDP 的选中节点会终止 association，绝不 fallback。simple-obfs `tls`、未知 mode、通用外部插件、缺失/不安全 host、AEAD-2022、standalone `socks-port` UDP、fragmentation 及 Trojan UDP 仍保持关闭。HTTP、SOCKS5、VMess、VLESS、AnyTLS outbound 仍未支持。其他已知缺口包括完整 mihomo DNS、TUN/redir/tproxy、完整 REST API v1、WebSocket 事件流和第三方 dashboard 兼容。

## Development

Run the focused local gates before sending changes:

```bash
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast --summary all
zig build e2e --summary all  # PR/tag gate; downloads checksum-pinned static fixtures
bash tools/config-migrator/run-all.sh
bash scripts/install/run-all-regression.sh
bash scripts/run-full-validation.sh
```

Daemon smoke test:

```bash
./zig-out/bin/zc start --port 29001 -c testdata/config/minimal.yaml --json
./zig-out/bin/zc status --json
./zig-out/bin/zc stop --json
```

## Documentation

- [`docs/README.md`](docs/README.md): documentation index
- [`docs/roadmap/v1.0.md`](docs/roadmap/v1.0.md): public v1.0 release plan
- [`docs/cli/spec.md`](docs/cli/spec.md): CLI command surface and JSON contracts
- [`docs/compat/mihomo-clash.md`](docs/compat/mihomo-clash.md): compatibility boundaries
- [`docs/install/README.md`](docs/install/README.md): install and validation scripts
- [`docs/api/README.md`](docs/api/README.md): implemented minimal API
- [`docs/reliability/e2e.md`](docs/reliability/e2e.md): PR/tag-only real network E2E gate
- [`docs/reliability/soak-guide.md`](docs/reliability/soak-guide.md): soak validation

Historical drafts live under [`docs/archive/`](docs/archive/) and are not current commitments.

## License

MIT
