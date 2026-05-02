# zc

A lightweight proxy runtime and CLI built with Zig.

## Status

zc is in **v1.0 release-candidate cleanup**. Do not tag `v1.0.0` until the release blockers in [`docs/roadmap/v1.0.md`](docs/roadmap/v1.0.md) are closed.

Current local facts:

- Zig 0.16.0 is the supported development toolchain.
- `zig build test` passes locally.
- `scripts/run-full-validation.sh` passes locally.
- TUI is removed from the v1.0 scope and must not be documented as a user feature.

## Requirements

- [Zig](https://ziglang.org/) 0.16.0+
- `just` for the local install shortcut

## Quick start

```bash
git clone https://github.com/ekil1100/zc
cd zc
just install

# Start daemon with the default mixed port
zc start

# Prefer explicit non-production ports during development
zc start --port 7901

zc status
zc doctor
```

`just install` builds `zig-out/bin/zc` and atomically replaces `~/.local/bin/zc`, so an existing local daemon can keep running while the new CLI binary is staged.

## Core v1.0 scope

Included:

- daemon lifecycle: `start`, `stop`, `restart`, `status`, `log`;
- CLI diagnostics: `doctor`, `diag doctor`;
- config management and override flow;
- proxy group listing/selection;
- default mixed inbound runtime;
- explicit local-dev port override via `zc start --port <port>`;
- core rule matching and rule-provider expansion;
- minimal REST API when `external-controller` is configured;
- install/verify/upgrade/rollback validation scripts.

Not included in v1.0:

- TUI;
- TUN/redir/tproxy transparent proxying;
- full mihomo/clash DNS behavior;
- full REST API v1/WebSocket event stream;
- full third-party dashboard compatibility;
- complete VMess/VLESS transport matrix;
- HTTP/SOCKS5 outbound unless implemented or explicitly rejected before GA.

## Documentation

Start at [`docs/README.md`](docs/README.md).

Key documents:

- [`docs/roadmap/v1.0.md`](docs/roadmap/v1.0.md) — current v1.0 release blockers and gate.
- [`docs/cli/spec.md`](docs/cli/spec.md) — implemented CLI surface and JSON contract gaps.
- [`docs/compat/mihomo-clash.md`](docs/compat/mihomo-clash.md) — compatibility boundaries.
- [`docs/install/README.md`](docs/install/README.md) — local install validation scripts.
- [`docs/api/README.md`](docs/api/README.md) — minimal API endpoints actually implemented.

Historical drafts live under `docs/archive/` and are not current commitments.

## Validation

```bash
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast --summary all
bash scripts/run-full-validation.sh
```

Daemon smoke test on a non-production port:

```bash
./zig-out/bin/zc start --port 29001 -c testdata/config/minimal.yaml --json
./zig-out/bin/zc status --json
./zig-out/bin/zc stop --json
```

## License

MIT
