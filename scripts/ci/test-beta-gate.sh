#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zc-beta-gate-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/repo/scripts"
cp "$ROOT_DIR/scripts/run-beta-gate.sh" "$WORK_DIR/repo/scripts/run-beta-gate.sh"

cat >"$WORK_DIR/bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GATE_TRACE"
if [[ "${GATE_FAIL:-1}" == 1 && ( "$*" == release || "$*" == test ) ]]; then
  echo "Injected gate failure" >&2
  exit 42
fi
EOF
chmod +x "$WORK_DIR/bin/just"
export GATE_TRACE="$WORK_DIR/trace"
expected=$'release\ncheck\ntest\ndelivery-test\ne2e\ninstall-test'

for fail in 1 0; do
  : >"$GATE_TRACE"
  set +e
  output=$(PATH="$WORK_DIR/bin:$PATH" GATE_FAIL="$fail" bash "$WORK_DIR/repo/scripts/run-beta-gate.sh" 2>&1)
  exit_code=$?
  set -e
  if [[ "$fail" == 1 ]]; then
    [[ $exit_code -ne 0 ]] || { echo "BETA_GATE_CONTRACT=FAIL detail=failing gates returned success" >&2; exit 1; }
    grep -Fq 'BETA_GATE_RESULT=FAIL' <<<"$output"
    grep -Fq 'BETA_GATE_PASS=4/6' <<<"$output"
    grep -Fq 'BETA_GATE_FAILED=release test' <<<"$output"
  else
    [[ $exit_code -eq 0 ]] || { printf '%s\n' "$output" >&2; exit 1; }
    grep -Fq 'BETA_GATE_RESULT=PASS' <<<"$output"
    grep -Fq 'BETA_GATE_PASS=6/6' <<<"$output"
    grep -Fq 'BETA_GATE_FAILED=none' <<<"$output"
  fi
  [[ "$(<"$GATE_TRACE")" == "$expected" ]] || { echo "BETA_GATE_CONTRACT=FAIL detail=gate order or continuation changed" >&2; exit 1; }
done
printf 'BETA_GATE_CONTRACT=PASS\n'
