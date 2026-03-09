# zc

A lightweight network tool built with Zig.

## Installation

Requires [Zig](https://ziglang.org/) 0.15.0+ and [just](https://github.com/casey/just):

```bash
git clone https://github.com/ekil1100/zc
cd zc
just install
```

`just install` builds `zig-out/bin/zc` and atomically replaces `~/.local/bin/zc`, so an existing local daemon can keep running while the new CLI binary is staged.

## Quick Start

```bash
# Build and install
just install

# Start service
zc start

# Start service on an explicit local-dev port
zc start --port 7901

# Check status
zc status
```

`zc restart` now does the same mixed-port preflight as `zc start`, so a port conflict is reported in the foreground instead of only appearing in `zc log`.

`zc` mixed proxy now keeps long-lived Shadowsocks-backed `CONNECT` and WebSocket tunnels draining correctly even when upstream data is already buffered in memory, which improves Discord Gateway and similar traffic stability.

## License

MIT
