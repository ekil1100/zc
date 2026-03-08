#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$ROOT_DIR/scripts/install/local-dev-install.sh"
TMP_DIR="/tmp/zc-local-dev-install"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR/src" "$TMP_DIR/bin"

TARGET="$TMP_DIR/bin/zc"
SOURCE="$TMP_DIR/src/zc"
HOOK="$TMP_DIR/check-before-promote.sh"

cat > "$TARGET" <<'EOF'
#!/usr/bin/env bash
printf 'old\n'
EOF
chmod +x "$TARGET"

cat > "$SOURCE" <<'EOF'
#!/usr/bin/env bash
printf 'new\n'
EOF
chmod +x "$SOURCE"

cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="$1"
staged="$2"

[[ -x "$target" ]]
[[ "$("$target")" == "old" ]]
[[ -f "$staged" ]]
[[ "$("$staged")" == "new" ]]
EOF
chmod +x "$HOOK"

ZC_INSTALL_BEFORE_PROMOTE_HOOK="$HOOK" bash "$INSTALLER" --source "$SOURCE" --target-dir "$TMP_DIR/bin"

if [[ "$("$TARGET")" != "new" ]]; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=target_not_replaced"
  exit 1
fi

if find "$TMP_DIR/bin" -maxdepth 1 -name 'zc.tmp.*' | grep -q .; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=staged_file_leaked"
  exit 1
fi

cat > "$TARGET" <<'EOF'
#!/usr/bin/env bash
printf 'old-again\n'
EOF
chmod +x "$TARGET"

if bash "$INSTALLER" --source "$TMP_DIR/src/missing-zc" --target-dir "$TMP_DIR/bin" >/tmp/zc-local-dev-install.fail.out 2>&1; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=missing_source_should_fail"
  exit 1
fi

if [[ "$("$TARGET")" != "old-again" ]]; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=failed_install_mutated_existing_target"
  exit 1
fi

echo "LOCAL_DEV_INSTALL_REGRESSION=PASS"
echo "LOCAL_DEV_INSTALL_REPORT=$TMP_DIR"
