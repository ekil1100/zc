# zc

A lightweight network tool built with Zig.

## Installation

Requires [Zig](https://ziglang.org/) 0.15.0+ and [just](https://github.com/casey/just):

```bash
git clone https://github.com/ekil1100/zc
cd zc
just install
```

## Quick Start

```bash
# Start TUI
zc tui

# Start service
zc start

# Check status
zc status
```

## Runtime Override

Use runtime override flags on config-loading commands (`start/tui/test/doctor/proxy ...`) to patch config without modifying source YAML:

```bash
# dump merged config (YAML)
zc config dump -c testdata/config/minimal.yaml

# run lua override script (returns lua table)
zc config dump -c testdata/config/minimal.yaml \
  --override-script /tmp/override.lua \
  --override-arg region=sg

# JSON output
zc config dump -c testdata/config/minimal.yaml --json

# ignore override scripts
zc config dump -c testdata/config/minimal.yaml --no-override
```

For `*.lua` scripts, ensure `luajit` or `lua` is available in PATH.
See `docs/config/override.md` for the full script contract and error codes.

## License

MIT
