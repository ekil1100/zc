#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_PATH="$ROOT_DIR/zig-out/bin/zc"
TARGET_DIR="${HOME}/.local/bin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_PATH="${2:-}"
      shift 2
      ;;
    --target-dir)
      TARGET_DIR="${2:-}"
      shift 2
      ;;
    *)
      echo "usage: $0 [--source <path>] [--target-dir <dir>]" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SOURCE_PATH" || -z "$TARGET_DIR" ]]; then
  echo "source path and target dir are required" >&2
  exit 2
fi

mkdir -p "$TARGET_DIR"

TARGET_PATH="$TARGET_DIR/zc"
TARGET_DIR_PHYSICAL="$(cd -P "$TARGET_DIR" && pwd -P)"
TARGET_PATH_PHYSICAL="$TARGET_DIR_PHYSICAL/zc"
running_target_pids() {
  local executable exe_link lsof_output pid
  if [[ -r /proc/self/exe ]]; then
    command -v readlink >/dev/null 2>&1 || return 1
    for exe_link in /proc/[0-9]*/exe; do
      if ! executable="$(readlink "$exe_link" 2>/dev/null)"; then
        local proc_dir comm
        proc_dir="${exe_link%/exe}"
        comm="$(cat "$proc_dir/comm" 2>/dev/null)" || continue
        [[ "$comm" != "zc" ]] || return 1
        continue
      fi
      executable="${executable% (deleted)}"
      if [[ "$executable" == "$TARGET_PATH" ||
        "$executable" == "$TARGET_PATH_PHYSICAL" ]]; then
        pid="${exe_link#/proc/}"
        printf '%s\n' "${pid%%/*}"
      fi
    done
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  lsof_output="$(lsof -n -d txt -Fpn 2>/dev/null)" || return 1
  local ps_output
  ps_output="$(ps -ww -axo pid=,comm= 2>/dev/null)" || return 1
  {
    awk -v logical="$TARGET_PATH" -v physical="$TARGET_PATH_PHYSICAL" '
          {
              pid = $1
              sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
              if ($0 == logical || $0 == physical) print pid
          }
      ' <<<"$ps_output"
    awk -v logical="$TARGET_PATH" -v physical="$TARGET_PATH_PHYSICAL" '
          /^p/ { pid = substr($0, 2) }
          /^n/ {
              path = substr($0, 2)
              sub(/ \(deleted\)$/, "", path)
              if (path == logical || path == physical) print pid
          }
      ' <<<"$lsof_output"
  } | awk '!seen[$0]++'
}

require_stopped_target() {
  local target_pids
  if [[ -L "$TARGET_PATH" ]]; then
    echo "Installation target must not be a symbolic link: $TARGET_PATH" >&2
    exit 1
  fi
  if ! target_pids="$(running_target_pids)"; then
    echo "Unable to inspect running processes; refusing to replace $TARGET_PATH" >&2
    exit 1
  fi
  if [[ -n "$target_pids" ]]; then
    echo "Installation target is still running (pid: ${target_pids//$'\n'/, }); refusing replacement" >&2
    echo "Stop the exact process and retry the install" >&2
    exit 1
  fi
}

require_stopped_target

STAGED_PATH=""
BACKUP_PATH=""
HAD_TARGET=0
PUBLISHING=0

cleanup() {
  if [[ "$PUBLISHING" -eq 1 ]]; then
    if [[ "$HAD_TARGET" -eq 1 && -f "$BACKUP_PATH" ]]; then
      mv -f "$BACKUP_PATH" "$TARGET_PATH" || true
      BACKUP_PATH=""
    else
      rm -f "$TARGET_PATH"
    fi
  fi
  if [[ -n "$STAGED_PATH" && -e "$STAGED_PATH" ]]; then
    rm -f "$STAGED_PATH"
  fi
  if [[ -n "$BACKUP_PATH" && -e "$BACKUP_PATH" ]]; then
    rm -f "$BACKUP_PATH"
  fi
}

trap cleanup EXIT

if [[ -e "$TARGET_PATH" ]]; then
  HAD_TARGET=1
  BACKUP_PATH="$(mktemp "$TARGET_PATH.backup.XXXXXX")"
  cp -p "$TARGET_PATH" "$BACKUP_PATH"
fi
STAGED_PATH="$(mktemp "$TARGET_PATH.tmp.XXXXXX")"
cp "$SOURCE_PATH" "$STAGED_PATH"
chmod 755 "$STAGED_PATH"

if [[ "$(uname -s)" == "Darwin" ]] && command -v codesign >/dev/null 2>&1 && command -v file >/dev/null 2>&1; then
  if file -b "$STAGED_PATH" | grep -q "Mach-O"; then
    codesign --verify --strict "$STAGED_PATH" >/dev/null
  fi
fi

if [[ -n "${ZC_INSTALL_BEFORE_PROMOTE_HOOK:-}" ]]; then
  "$ZC_INSTALL_BEFORE_PROMOTE_HOOK" "$TARGET_PATH" "$STAGED_PATH"
fi

require_stopped_target
PUBLISHING=1
mv -f "$STAGED_PATH" "$TARGET_PATH"
STAGED_PATH=""
require_stopped_target
PUBLISHING=0
if [[ -n "$BACKUP_PATH" ]]; then
  rm -f "$BACKUP_PATH"
  BACKUP_PATH=""
fi
trap - EXIT
