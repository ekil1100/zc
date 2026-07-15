#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SAMPLES=9
ITERATIONS=200
FIXTURE_BYTES=$((64 * 1024))
SUBJECT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
HARNESS_COMMIT="$SUBJECT_COMMIT"
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

status_file="$(mktemp "${TMPDIR:-/tmp}/zc-perf-status.XXXXXX")"
trap 'rm -f "$status_file"' EXIT
if ! git -C "$ROOT_DIR" status --porcelain --untracked-files=all >"$status_file"; then
  echo "unable to verify worktree provenance" >&2
  exit 2
fi
if [[ -s "$status_file" ]]; then
  echo "refusing to record provenance from a dirty worktree; commit or clean the measurement source first" >&2
  exit 2
fi
rm -f "$status_file"
trap - EXIT

SUBJECT_COMMIT="$(git -C "$ROOT_DIR" rev-parse "${SUBJECT_COMMIT}^{commit}" 2>/dev/null)" || {
  echo "subject-commit is not a commit" >&2
  exit 2
}
HARNESS_COMMIT="$(git -C "$ROOT_DIR" rev-parse "${HARNESS_COMMIT}^{commit}" 2>/dev/null)" || {
  echo "harness-commit is not a commit" >&2
  exit 2
}
ACTUAL_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD)"
[[ "$HARNESS_COMMIT" == "$ACTUAL_HEAD" ]] || {
  echo "harness-commit must match the clean worktree HEAD" >&2
  exit 2
}

if [[ "$SUBJECT_COMMIT" != "$ACTUAL_HEAD" ]]; then
  PARENT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD^)"
  [[ "$SUBJECT_COMMIT" == "$PARENT_COMMIT" ]] || {
    echo "subject-commit must be HEAD or the direct parent of a harness-only commit" >&2
    exit 2
  }
  while IFS= read -r changed_path; do
    case "$changed_path" in
      build.zig|docs/perf/reports/README.md|scripts/perf/run-control-plane-baseline.sh|src/perf_runner.zig|src/perf_stats.zig|src/test_runner.zig)
        ;;
      *)
        echo "subject differs from harness by non-harness source: $changed_path" >&2
        exit 2
        ;;
    esac
  done < <(git -C "$ROOT_DIR" diff --name-only "$SUBJECT_COMMIT..$ACTUAL_HEAD")
fi

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
trap 'rm -f "$tmp_output"' EXIT

(
  cd "$ROOT_DIR"
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

mv "$tmp_output" "$OUTPUT"
trap - EXIT

echo "CONTROL_PLANE_MEASUREMENT=RECORDED"
echo "CONTROL_PLANE_MEASUREMENT_REPORT=$OUTPUT"
