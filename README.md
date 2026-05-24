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

- **CLI-first operation**: `zc start`, `zc stop`, `zc restart`, `zc status`, `zc log`, `zc doctor`, `zc test`, `zc config`, `zc proxy`, and `zc profile`.
- **Daemon lifecycle**: explicit process tracking, JSON status output, log inspection, and diagnostics.
- **Default mixed inbound**: one local listener for HTTP and SOCKS5-style client traffic.
- **Config compatibility work**: parser and validator coverage for common clash-style fields, rule providers, proxy groups, and rule matching.
- **Proxy selection**: list and switch select groups through `zc proxy` or `PUT /proxies/<group>`.
- **Minimal API**: implemented endpoints for version, proxies, rules, and proxy-group selection when `external-controller` is configured.
- **Operational gates**: install regression, config migrator regression, smoke validation, reliability scenarios, and performance report scripts.

## Requirements

- Zig `0.16.0+`
- Linux or another POSIX-like development environment for the current scripts
- `bash` for repository validation scripts
- `just` for the local install shortcut

CI and local development target Zig `0.16.0`.

## Install from source

Public release artifacts are intentionally not documented until the release workflow is aligned and `v1.0.0` is tagged. For now, install from source:

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
zc start --port 7901 -c testdata/config/minimal.yaml --json
zc status --json
zc proxy list --json
zc doctor --json
zc stop --json
```

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

## Minimal API

The API starts when `external-controller` is set in the active config:

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
- select, url-test, fallback, load-balance, and relay proxy groups;
- direct、reject、Shadowsocks、VMess、Trojan、VLESS 和 AnyTLS 出站运行路径;
- minimal REST control endpoints.

Known gaps include full mihomo DNS behavior, transparent proxying through TUN/redir/tproxy, full REST API v1, WebSocket event streams, complete VMess/VLESS transport matrices, and third-party dashboard compatibility.

## Development

Run the focused local gates before sending changes:

```bash
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast --summary all
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
- [`docs/reliability/soak-guide.md`](docs/reliability/soak-guide.md): soak validation

Historical drafts live under [`docs/archive/`](docs/archive/) and are not current commitments.

## License

MIT
