#!/usr/bin/env bash
set -euo pipefail
# The historical scaffold is replaced by the real isolated runner.
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
exec bash "$ROOT_DIR/scripts/reliability/run-soak-real.sh" "$@"
