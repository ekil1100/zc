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
STAGED_PATH="$(mktemp "$TARGET_PATH.tmp.XXXXXX")"

cleanup() {
  if [[ -n "${STAGED_PATH:-}" && -e "$STAGED_PATH" ]]; then
    rm -f "$STAGED_PATH"
  fi
}

trap cleanup EXIT

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

mv -f "$STAGED_PATH" "$TARGET_PATH"
trap - EXIT
