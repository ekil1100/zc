#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zc-beta-gate-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p \
  "$WORK_DIR/bin" \
  "$WORK_DIR/repo/scripts/install" \
  "$WORK_DIR/repo/tools/config-migrator"
cp "$ROOT_DIR/scripts/run-beta-gate.sh" "$WORK_DIR/repo/scripts/run-beta-gate.sh"

cat >"$WORK_DIR/bin/zig" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
cat >"$WORK_DIR/repo/tools/config-migrator/run-all.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$WORK_DIR/repo/scripts/install/run-all-regression.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x \
  "$WORK_DIR/bin/zig" \
  "$WORK_DIR/repo/tools/config-migrator/run-all.sh" \
  "$WORK_DIR/repo/scripts/install/run-all-regression.sh"

set +e
output=$(PATH="$WORK_DIR/bin:$PATH" bash "$WORK_DIR/repo/scripts/run-beta-gate.sh" 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 0 ]]; then
  printf 'BETA_GATE_CONTRACT=FAIL detail=failing command returned success\n' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
if ! grep -Fq 'BETA_GATE_RESULT=FAIL' <<<"$output"; then
  printf 'BETA_GATE_CONTRACT=FAIL detail=missing failure result\n' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
if ! grep -Fq 'BETA_GATE_PASS=2/4' <<<"$output"; then
  printf 'BETA_GATE_CONTRACT=FAIL detail=unexpected pass count\n' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
if ! grep -Fq 'BETA_GATE_FAILED=build test' <<<"$output"; then
  printf 'BETA_GATE_CONTRACT=FAIL detail=unexpected failed gates\n' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

printf 'BETA_GATE_CONTRACT=PASS\n'
