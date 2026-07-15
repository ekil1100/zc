#!/usr/bin/env bash
set -euo pipefail

# Git's -C does not override repository-changing GIT_* variables. Remove them
# before resolving either provenance or the isolated build worktree.
while IFS='=' read -r name _; do
  [[ "$name" == GIT_* ]] && unset "$name"
done < <(env)

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SAMPLES=9
ITERATIONS=200
FIXTURE_BYTES=$((64 * 1024))
SUBJECT_COMMIT=""
HARNESS_COMMIT=""
MACHINE="$(hostname)"
OUTPUT=""

usage() {
  cat <<'EOF'
Usage: bash scripts/perf/run-control-plane-baseline.sh [options]

Options:
  --samples <n>          Raw sample count, minimum 5 (default: 9)
  --iterations <n>       Operations per sample (default: 200)
  --fixture-bytes <n>    Fixture size, 1..16777216 (default: 65536)
  --subject-commit <sha> Commit being measured (default: HEAD)
  --harness-commit <sha> Harness revision (default: HEAD)
  --output <path>        JSON output (default: .zig-cache/perf/...json)
  -h, --help             Show help

This command records measurements. It does not claim performance PASS/FAIL and
never writes docs/perf/reports/latest.json or history automatically.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --samples|--iterations|--fixture-bytes|--subject-commit|--harness-commit|--output)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }
      case "$1" in
        --samples) SAMPLES="$2" ;;
        --iterations) ITERATIONS="$2" ;;
        --fixture-bytes) FIXTURE_BYTES="$2" ;;
        --subject-commit) SUBJECT_COMMIT="$2" ;;
        --harness-commit) HARNESS_COMMIT="$2" ;;
        --output) OUTPUT="$2" ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$SAMPLES" =~ ^[0-9]+$ ]] && (( SAMPLES >= 5 )) || { echo "samples must be an integer >= 5" >&2; exit 2; }
[[ "$ITERATIONS" =~ ^[0-9]+$ ]] && (( ITERATIONS > 0 )) || { echo "iterations must be a positive integer" >&2; exit 2; }
[[ "$FIXTURE_BYTES" =~ ^[0-9]+$ ]] && (( FIXTURE_BYTES > 0 && FIXTURE_BYTES <= 16777216 )) || { echo "fixture-bytes must be in 1..16777216" >&2; exit 2; }

provenance_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zc-perf-provenance.XXXXXX")"
trap 'rm -rf "$provenance_tmp"' EXIT
if ! git -C "$ROOT_DIR" rev-parse --show-toplevel >"$provenance_tmp/toplevel"; then
  echo "unable to resolve repository root" >&2
  exit 2
fi
REPORTED_ROOT="$(cd "$(cat "$provenance_tmp/toplevel")" && pwd -P)"
if [[ "$REPORTED_ROOT" != "$ROOT_DIR" ]]; then
  echo "resolved git repository does not match the benchmark source" >&2
  exit 2
fi
if ! git -C "$ROOT_DIR" status --porcelain --untracked-files=all >"$provenance_tmp/status"; then
  echo "unable to verify worktree provenance" >&2
  exit 2
fi
if [[ -s "$provenance_tmp/status" ]]; then
  echo "refusing to record provenance from a dirty worktree; commit or clean the measurement source first" >&2
  exit 2
fi
if ! git -C "$ROOT_DIR" ls-files -v >"$provenance_tmp/index-flags"; then
  echo "unable to verify git index flags" >&2
  exit 2
fi
if grep -Eq '^[a-zS]' "$provenance_tmp/index-flags"; then
  echo "refusing provenance with assume-unchanged or skip-worktree entries" >&2
  exit 2
fi
if ! git -C "$ROOT_DIR" replace -l >"$provenance_tmp/replacements"; then
  echo "unable to verify git replacement refs" >&2
  exit 2
fi
if [[ -s "$provenance_tmp/replacements" ]]; then
  echo "refusing provenance with git replacement refs" >&2
  exit 2
fi
GRAFTS_PATH="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-path info/grafts)" || {
  echo "unable to locate git grafts" >&2
  exit 2
}
if [[ -s "$GRAFTS_PATH" ]]; then
  echo "refusing provenance with git grafts" >&2
  exit 2
fi

ACTUAL_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD)" || {
  echo "unable to resolve HEAD" >&2
  exit 2
}
[[ -n "$SUBJECT_COMMIT" ]] || SUBJECT_COMMIT="$ACTUAL_HEAD"
[[ -n "$HARNESS_COMMIT" ]] || HARNESS_COMMIT="$ACTUAL_HEAD"
SUBJECT_COMMIT="$(git -C "$ROOT_DIR" rev-parse "${SUBJECT_COMMIT}^{commit}" 2>/dev/null)" || {
  echo "subject-commit is not a commit" >&2
  exit 2
}
HARNESS_COMMIT="$(git -C "$ROOT_DIR" rev-parse "${HARNESS_COMMIT}^{commit}" 2>/dev/null)" || {
  echo "harness-commit is not a commit" >&2
  exit 2
}
[[ "$HARNESS_COMMIT" == "$ACTUAL_HEAD" ]] || {
  echo "harness-commit must match the clean worktree HEAD" >&2
  exit 2
}

if [[ "$SUBJECT_COMMIT" != "$ACTUAL_HEAD" ]]; then
  PARENT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD^)" || {
    echo "unable to resolve harness parent" >&2
    exit 2
  }
  [[ "$SUBJECT_COMMIT" == "$PARENT_COMMIT" ]] || {
    echo "subject-commit must be HEAD or the direct parent of a harness-only commit" >&2
    exit 2
  }
  if ! git -C "$ROOT_DIR" diff --name-only -z "$SUBJECT_COMMIT..$ACTUAL_HEAD" >"$provenance_tmp/changed"; then
    echo "unable to verify harness-only changes" >&2
    exit 2
  fi
  while IFS= read -r -d '' changed_path; do
    case "$changed_path" in
      build.zig|docs/perf/reports/README.md|scripts/perf/run-control-plane-baseline.sh|src/perf_runner.zig|src/perf_stats.zig|src/test_runner.zig)
        ;;
      *)
        echo "subject differs from harness by non-harness source: $changed_path" >&2
        exit 2
        ;;
    esac
  done <"$provenance_tmp/changed"
fi
rm -rf "$provenance_tmp"
trap - EXIT

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$ROOT_DIR/.zig-cache/perf/control-plane-$(date -u +%Y%m%dT%H%M%SZ).json"
elif [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$ROOT_DIR/$OUTPUT"
fi

case "$OUTPUT" in
  "$ROOT_DIR/docs/perf/reports/"*)
    echo "refusing to overwrite tracked perf reports; use .zig-cache or /tmp" >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "$OUTPUT")"
tmp_output="${OUTPUT}.tmp.$$"
build_parent="$(mktemp -d "${TMPDIR:-/tmp}/zc-perf-build.XXXXXX")"
build_root="$build_parent/source"
build_registered=false
cleanup_measurement() {
  rm -f "$tmp_output"
  if [[ "$build_registered" == true ]]; then
    git -C "$ROOT_DIR" worktree remove --force "$build_root" >/dev/null 2>&1 || true
  fi
  rm -rf "$build_parent"
}
trap cleanup_measurement EXIT

verify_checkout() {
  local checkout_root="$1"
  local expected_commit="$2"
  local checkout_head
  checkout_head="$(git -C "$checkout_root" rev-parse HEAD)" || return 1
  [[ "$checkout_head" == "$expected_commit" ]] || return 1

  if ! git -C "$checkout_root" status --porcelain --untracked-files=all >"$build_parent/checkout-status"; then
    return 1
  fi
  [[ ! -s "$build_parent/checkout-status" ]] || return 1
  if ! git -C "$checkout_root" ls-files -v >"$build_parent/checkout-index-flags"; then
    return 1
  fi
  if grep -Eq '^[a-zS]' "$build_parent/checkout-index-flags"; then
    return 1
  fi
  if ! git -C "$ROOT_DIR" ls-tree -r -z "$expected_commit" >"$build_parent/expected-tree"; then
    return 1
  fi

  while IFS= read -r -d '' entry; do
    local metadata="${entry%%$'\t'*}"
    local path="${entry#*$'\t'}"
    local mode type expected_hash actual_hash
    read -r mode type expected_hash <<<"$metadata"
    [[ "$type" == "blob" ]] || return 1
    [[ -e "$checkout_root/$path" || -L "$checkout_root/$path" ]] || return 1
    if [[ "$mode" == "120000" ]]; then
      local link_target
      link_target="$(readlink "$checkout_root/$path")" || return 1
      actual_hash="$(printf '%s' "$link_target" | git -C "$ROOT_DIR" hash-object --stdin)" || return 1
    else
      actual_hash="$(git -C "$ROOT_DIR" hash-object --no-filters -- "$checkout_root/$path")" || return 1
      if [[ "$mode" == "100755" ]]; then
        [[ -x "$checkout_root/$path" ]] || return 1
      fi
    fi
    [[ "$actual_hash" == "$expected_hash" ]] || return 1
  done <"$build_parent/expected-tree"
}

# Build from the verified commit, not from the caller's mutable worktree.
git -c core.hooksPath=/dev/null -C "$ROOT_DIR" worktree add --detach --quiet "$build_root" "$HARNESS_COMMIT"
build_registered=true
verify_checkout "$build_root" "$HARNESS_COMMIT" || {
  echo "isolated benchmark checkout does not match harness-commit" >&2
  exit 2
}
(
  cd "$build_root"
  env ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/zig-cache}" \
    zig build perf -- \
      --samples "$SAMPLES" \
      --iterations "$ITERATIONS" \
      --fixture-bytes "$FIXTURE_BYTES" \
      --subject-commit "$SUBJECT_COMMIT" \
      --harness-commit "$HARNESS_COMMIT" \
      --machine "$MACHINE"
) > "$tmp_output"

jq -e \
  --arg subject "$SUBJECT_COMMIT" \
  --arg harness "$HARNESS_COMMIT" \
  --argjson samples "$SAMPLES" \
  '.schema_version == 1 and
   .kind == "measurement" and
   .status == "measured" and
   .provenance.subject_commit == $subject and
   .provenance.harness_commit == $harness and
   .provenance.optimize == "ReleaseFast" and
   (.provenance.zig_version | length) > 0 and
   (.provenance.cpu_model | length) > 0 and
   (.provenance.machine | length) > 0 and
   .method.sample_count == $samples and
   ([.benchmarks[].samples | length] | all(. == $samples)) and
   ([.benchmarks[] | has("pass")] | all(. == false))' \
  "$tmp_output" >/dev/null

git -C "$ROOT_DIR" worktree remove --force "$build_root" >/dev/null
build_registered=false
rm -rf "$build_parent"
mv "$tmp_output" "$OUTPUT"
trap - EXIT

echo "CONTROL_PLANE_MEASUREMENT=RECORDED"
echo "CONTROL_PLANE_MEASUREMENT_REPORT=$OUTPUT"
