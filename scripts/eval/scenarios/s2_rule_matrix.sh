#!/usr/bin/env bash
# S2: frozen rule-matrix against the production rule engine.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd -P)"
MATRIX="$ROOT_DIR/testdata/rules/rule-matrix.yaml"

usage() {
  cat <<'HELP'
Usage: bash scripts/eval/scenarios/s2_rule_matrix.sh [--matrix <path>]

Runs: zig build eval-rule-matrix -Dcpu=baseline -- <matrix>
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --matrix)
      [[ $# -ge 2 ]] || { printf 's2: missing --matrix value\n' >&2; exit 2; }
      MATRIX="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 's2: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$MATRIX" ]]; then
  printf 's2: matrix not found: %s\n' "$MATRIX" >&2
  exit 2
fi
if ! command -v zig >/dev/null 2>&1; then
  printf 's2: zig not found on PATH\n' >&2
  exit 2
fi

cd "$ROOT_DIR"
set +e
zig build eval-rule-matrix -Dcpu=baseline -- "$MATRIX"
rc=$?
set -e
exit "$rc"
