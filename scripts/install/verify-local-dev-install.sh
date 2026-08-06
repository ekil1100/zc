#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$ROOT_DIR/scripts/install/local-dev-install.sh"
command -v cc >/dev/null 2>&1 || {
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=missing_cc"
  exit 1
}
TMP_DIR="/tmp/zc-local-dev-install"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR/src" "$TMP_DIR/bin"

TARGET="$TMP_DIR/bin/zc"
SOURCE="$TMP_DIR/src/zc"
HOOK="$TMP_DIR/check-before-promote.sh"
running_target_pid=""

cleanup() {
  if [[ -n "$running_target_pid" ]]; then
    kill "$running_target_pid" >/dev/null 2>&1 || true
    wait "$running_target_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cat >"$TARGET" <<'EOF'
#!/usr/bin/env bash
printf 'old\n'
EOF
chmod +x "$TARGET"

cat >"$SOURCE" <<'EOF'
#!/usr/bin/env bash
printf 'new\n'
EOF
chmod +x "$SOURCE"

cat >"$HOOK" <<'EOF'
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

cat >"$TMP_DIR/src/running-target.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *ready = fopen(argv[1], "w");
    if (ready == NULL) return 3;
    fclose(ready);
    sleep(30);
    return 0;
}
EOF
cc "$TMP_DIR/src/running-target.c" -o "$TMP_DIR/src/running-target"
cp "$TMP_DIR/src/running-target" "$TARGET"
chmod 755 "$TARGET"
running_ready="$TMP_DIR/running-target.ready"
"$TARGET" "$running_ready" &
running_target_pid=$!
running_attempt=0
while [[ "$running_attempt" -lt 100 ]]; do
  if [[ -f "$running_ready" ]]; then
    break
  fi
  running_attempt=$((running_attempt + 1))
  sleep 0.01
done
[[ -f "$running_ready" ]]
if bash "$INSTALLER" --source "$SOURCE" --target-dir "$TMP_DIR/bin" \
  >"$TMP_DIR/running-target.out" 2>&1; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=running_target_should_fail"
  exit 1
fi
if ! kill -0 "$running_target_pid" >/dev/null 2>&1; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=running_target_was_terminated"
  exit 1
fi
if ! cmp -s "$TMP_DIR/src/running-target" "$TARGET"; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=running_target_was_replaced"
  exit 1
fi
kill "$running_target_pid" >/dev/null 2>&1 || true
wait "$running_target_pid" >/dev/null 2>&1 || true
running_target_pid=""

echo "LOCAL_DEV_INSTALL_RUNNING_TARGET=PASS"

race_ready="$TMP_DIR/race-target.ready"
race_pid_file="$TMP_DIR/race-target.pid"
race_hook="$TMP_DIR/start-target-before-promote.sh"
cat >"$race_hook" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"\$1" "$race_ready" &
echo \$! >"$race_pid_file"
attempt=0
while [[ \$attempt -lt 100 ]]; do
  [[ ! -f "$race_ready" ]] || exit 0
  attempt=\$((attempt + 1))
  sleep 0.01
done
exit 1
EOF
chmod 755 "$race_hook"
if ZC_INSTALL_BEFORE_PROMOTE_HOOK="$race_hook" \
  bash "$INSTALLER" --source "$SOURCE" --target-dir "$TMP_DIR/bin" \
  >"$TMP_DIR/running-race.out" 2>&1; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=running_race_should_fail"
  exit 1
fi
running_target_pid="$(cat "$race_pid_file")"
if ! kill -0 "$running_target_pid" >/dev/null 2>&1; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=running_race_target_was_terminated"
  exit 1
fi
if ! cmp -s "$TMP_DIR/src/running-target" "$TARGET"; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=running_race_target_was_replaced"
  exit 1
fi
kill "$running_target_pid" >/dev/null 2>&1 || true
wait "$running_target_pid" >/dev/null 2>&1 || true
running_target_pid=""
echo "LOCAL_DEV_INSTALL_RUNNING_RACE=PASS"

rm -f "$TARGET"
ln -s "$SOURCE" "$TARGET"
if bash "$INSTALLER" --source "$SOURCE" --target-dir "$TMP_DIR/bin" \
  >"$TMP_DIR/symlink-target.out" 2>&1; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=symlink_target_should_fail"
  exit 1
fi
if [[ ! -L "$TARGET" ]]; then
  echo "LOCAL_DEV_INSTALL_REGRESSION=FAIL"
  echo "LOCAL_DEV_INSTALL_REASON=symlink_target_was_replaced"
  exit 1
fi
rm "$TARGET"
echo "LOCAL_DEV_INSTALL_SYMLINK_TARGET=PASS"

cat >"$TARGET" <<'EOF'
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
