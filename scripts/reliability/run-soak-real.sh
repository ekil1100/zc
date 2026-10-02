#!/usr/bin/env bash
set -euo pipefail
# Real Rust foreground runner; all runtime state is temporary and private.
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
exec python3 "$ROOT_DIR/scripts/reliability/soak.py" "$@"
