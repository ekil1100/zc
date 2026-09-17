#!/usr/bin/env bash
set -euo pipefail
# Exercise only the implemented process-exit recovery scenario, not a full chaos gate.
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
printf 'CHAOS_SCOPE=process-exit-only\n'
printf 'CHAOS_OMITTED=dns-timeout,proxy-failover\n'
exec python3 "$ROOT_DIR/scripts/reliability/soak.py" "$@" --scenario process-exit
