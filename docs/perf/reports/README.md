# Performance reports

## Active measurement entry

The only active performance measurement entry is the control-plane recorder:

```bash
# Requires a clean git worktree (untracked files count as dirty).
bash scripts/perf/run-control-plane-baseline.sh \
  --samples 9 \
  --output .zig-cache/perf/control-plane.json
```

Or via the eval framework (also requires a clean worktree):

```bash
bash scripts/eval/run.sh --suite perf
# artifact: .zig-cache/eval/<run_id>/artifacts/control-plane.json
```

### Contract

- **Record only.** A successful run means facts were written (raw samples, median,
  nearest-rank p95, subject/harness commits, Zig version, machine/OS/arch).
- **Not a threshold gate.** Compare / threshold PASS-FAIL judgment is deferred.
  Do not treat a zero exit as “performance is fine for merge.”
- **Clean worktree required.** Dirty trees exit nonzero and write nothing
  authoritative.
- **Output location.** Default and eval outputs stay under `.zig-cache/`
  (untracked). Nothing in this directory is auto-promoted to git.
- **Omitted metrics.** Unmeasured paths (for example data-plane rule_eval /
  dns / handshake gates) must appear as omitted, never as fabricated `0`.

Help:

```bash
bash scripts/perf/run-control-plane-baseline.sh --help
```

## Historical artifacts in this directory

| Path | Status |
| --- | --- |
| `history/*.json` | Non-authoritative historical blobs kept for archaeology only |
| `baseline-v1.0.0.md` | Historical notes only |

Former placeholder regression entrypoints and the tracked latest report file
were **removed**. They emitted fake PASS without raw samples and must not be
restored as gates. History under `history/` remains only as non-authoritative
archaeology.

Optional history pruning (history only, never invents a latest gate file):

```bash
bash scripts/perf/prune-history.sh 30
```

## Deferred work

1. Machine-local baseline compare with an explicit thresholds policy file.
2. Data-plane hot-path sampling (rule eval / DNS / handshake) in `perf_runner.zig`.
3. Any CI job that records or gates on performance numbers.
