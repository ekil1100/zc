#!/usr/bin/env bash
set -euo pipefail

zc_bin=${1:?zc executable is required}
root=$(mktemp -d)
source_root=$(mktemp -d)
trap 'rm -rf "$root" "$source_root"' EXIT
mkdir -p "$root/run"

cat >"$source_root/local.yaml" <<'YAML'
mixed-port: 28888
proxies:
  - name: A
    type: direct
  - name: B
    type: direct
proxy-groups:
  - name: Proxy
    type: select
    proxies: [A, B]
rules:
  - MATCH,Proxy
YAML

env HOME="$root" XDG_RUNTIME_DIR="$root/run" \
  "$zc_bin" config load "$source_root/local.yaml" --json >"$root/load.json"
grep -q '"ok":true' "$root/load.json"
grep -q '"action":"config_load"' "$root/load.json"
grep -q '"active":true' "$root/load.json"

env HOME="$root" XDG_RUNTIME_DIR="$root/run" \
  "$zc_bin" proxy select -g Proxy -p B --json >"$root/select.json"
grep -q '"ok":true' "$root/select.json"
grep -q '"proxy":"B"' "$root/select.json"
grep -q '"applied":false' "$root/select.json"

grep -q '"generation":1' "$root/.config/zc/state-v2.json"
grep -q '"group":"Proxy"' "$root/.config/zc/state-v2.json"
grep -q '"proxy":"B"' "$root/.config/zc/state-v2.json"

if env HOME="$root" XDG_RUNTIME_DIR="$root/run" \
  "$zc_bin" config load "$source_root/local.yaml" --json >/dev/null 2>&1; then
  echo "duplicate config load unexpectedly succeeded" >&2
  exit 1
fi

echo "CONFIG_LOAD_SELECTION_TEST=PASS"
