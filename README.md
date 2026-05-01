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

`zc` runtime management now validates the tracked PID against the actual `zc --daemon-run` process, so a reused stale PID will not cause `zc stop` or `zc restart` to terminate an unrelated process.

`zc` mixed proxy now keeps long-lived Shadowsocks-backed `CONNECT` and WebSocket tunnels draining correctly even when upstream data is already buffered in memory, which improves Discord Gateway and similar traffic stability.

`zc` mixed proxy uses a bounded worker stack and reaps relay tunnels after 15 minutes without traffic. Active long-lived tunnels continue to stay open, while stale sockets no longer accumulate threads, ports, and macOS Activity Monitor memory footprint.

`zc start` no longer crashes during startup when rule-provider downloads return compressed HTTP bodies; provider fetches now explicitly request `identity` encoding so daemon startup stays stable while refreshing rule-providers.

## License

MIT
