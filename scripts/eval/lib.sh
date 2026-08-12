#!/usr/bin/env bash
# Shared helpers for the zc eval framework.
# shellcheck shell=bash

if [[ -n "${ZC_EVAL_LIB_SH:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ZC_EVAL_LIB_SH=1

eval_require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'eval: missing required command: %s\n' "$cmd" >&2
    if [[ -n "$hint" ]]; then
      printf 'eval: %s\n' "$hint" >&2
    fi
    return 2
  fi
}

eval_repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
  printf '%s\n' "$here"
}

eval_cache_root() {
  local root
  root="$(eval_repo_root)"
  printf '%s\n' "$root/.zig-cache/eval"
}

eval_schema_path() {
  local root
  root="$(eval_repo_root)"
  printf '%s\n' "$root/scripts/eval/schema/report.jq"
}

# Validate run_id: [A-Za-z0-9][A-Za-z0-9._-]{0,63}
eval_validate_run_id() {
  local run_id="$1"
  if [[ ! "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    printf 'eval: invalid run id %q (expected [A-Za-z0-9][A-Za-z0-9._-]{0,63})\n' "$run_id" >&2
    return 2
  fi
  # Reject path-like values even if they somehow matched (defense in depth).
  case "$run_id" in
    */*|*..*|*\\*)
      printf 'eval: invalid run id %q (path-like values are rejected)\n' "$run_id" >&2
      return 2
      ;;
  esac
}

eval_default_run_id() {
  # Compact UTC stamp + pid keeps collisions rare without external deps.
  printf 'run-%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

# Atomically create .zig-cache/eval/<run_id>/. Existing directory is an error.
eval_new_run_dir() {
  local run_id="${1:-}"
  local cache_root parent run_dir
  if [[ -z "$run_id" ]]; then
    run_id="$(eval_default_run_id)"
  fi
  eval_validate_run_id "$run_id" || return 2

  cache_root="$(eval_cache_root)"
  parent="$(dirname "$cache_root")"
  mkdir -p "$parent" || return 2
  mkdir -p "$cache_root" || return 2

  run_dir="$cache_root/$run_id"
  if ! mkdir "$run_dir" 2>/dev/null; then
    printf 'eval: run directory already exists: %s\n' "$run_dir" >&2
    return 2
  fi
  mkdir -p "$run_dir/suites" "$run_dir/artifacts" || return 2
  printf '%s\n' "$run_dir"
}

eval_iso_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

eval_git_head() {
  local root
  root="$(eval_repo_root)"
  if ! git -C "$root" rev-parse HEAD 2>/dev/null; then
    printf 'unknown\n'
  fi
}

# Prints "true" or "false".
eval_worktree_dirty() {
  local root
  root="$(eval_repo_root)"
  if [[ -n "$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null || true)" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# Prints a JSON object: {"os":"...","arch":"...","zig_version":"..."}
eval_capture_env_json() {
  local os arch zig_version
  os="$(uname -s 2>/dev/null || printf 'unknown')"
  arch="$(uname -m 2>/dev/null || printf 'unknown')"
  if command -v zig >/dev/null 2>&1; then
    zig_version="$(zig version 2>/dev/null || printf 'unknown')"
  else
    zig_version="missing"
  fi
  jq -nc \
    --arg os "$os" \
    --arg arch "$arch" \
    --arg zig_version "$zig_version" \
    '{os:$os, arch:$arch, zig_version:$zig_version}'
}

eval_validate_report() {
  local path="$1"
  local schema
  eval_require_cmd jq "install jq to validate eval reports" || return 2
  schema="$(eval_schema_path)"
  if [[ ! -f "$schema" ]]; then
    printf 'eval: missing report contract: %s\n' "$schema" >&2
    return 2
  fi
  if [[ ! -f "$path" ]]; then
    printf 'eval: report not found: %s\n' "$path" >&2
    return 2
  fi
  if ! jq -e -f "$schema" "$path" >/dev/null; then
    printf 'eval: report failed contract validation: %s\n' "$path" >&2
    return 2
  fi
}

# Write JSON text or file contents to a temp path in dest's directory.
# Does not publish to dest. Caller must validate then rename.
eval_stage_json() {
  local dest="$1"
  local src="$2"
  local dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || return 2
  tmp="$(mktemp "$dir/.tmp.XXXXXX")" || return 2
  if [[ -f "$src" ]]; then
    cp "$src" "$tmp" || { rm -f "$tmp"; return 2; }
  else
    printf '%s\n' "$src" >"$tmp" || { rm -f "$tmp"; return 2; }
  fi
  if ! jq -e . "$tmp" >"${tmp}.fmt" 2>/dev/null; then
    printf 'eval: refusing invalid JSON staged for %s\n' "$dest" >&2
    rm -f "$tmp" "${tmp}.fmt"
    return 2
  fi
  mv -f "${tmp}.fmt" "$tmp" || { rm -f "$tmp" "${tmp}.fmt"; return 2; }
  printf '%s\n' "$tmp"
}

# Atomic JSON write without report-contract validation (generic helper).
eval_write_json_atomic() {
  local dest="$1"
  local src="$2"
  local tmp
  tmp="$(eval_stage_json "$dest" "$src")" || return 2
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 2; }
}

# Stage JSON, validate against report.jq, only then publish to dest.
# On validation failure the final path is left untouched (or absent).
eval_write_report() {
  local dest="$1"
  local json="$2"
  local tmp
  tmp="$(eval_stage_json "$dest" "$json")" || return 2
  if ! eval_validate_report "$tmp"; then
    rm -f "$tmp"
    return 2
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 2; }
}

# Merge result priority: error > fail > pass
eval_merge_result() {
  local current="$1"
  local next="$2"
  case "$current:$next" in
    error:*|*:error) printf 'error\n' ;;
    fail:*|*:fail) printf 'fail\n' ;;
    *) printf 'pass\n' ;;
  esac
}
