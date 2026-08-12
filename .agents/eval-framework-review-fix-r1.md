# Eval framework review-fix round 1

Sources: `.agents/review-standards.md`, `.agents/review-spec.md` (gpt-5.6-sol + ultracode).

## Fixed
- Report publish order: validate staged JSON before rename (`lib.sh`)
- Suite adapters fail closed if report write/validation fails
- fail vs error: executed nonzero => fail; missing dep => error
- S1 no longer clears XDG_* before trap; requires `state=stopped` after stop
- Contract requires S1/S2 steps; migrator reports restored from backup copies
- Perf metrics use `median_ns_per_op` / `p95_ns_per_op`
- Rule matrix runner snake_case + production-engine prefix matched_rule check
- Selfcheck always enforces placeholder absence; rg fallback to grep
- Broken docs links after latest.json removal
- Avoid global `set -e` flip inside suite helpers

## Verified
- `bash scripts/eval/selfcheck.sh` PASS
- `zig build eval-rule-matrix ...` 6/6 PASS
- `bash scripts/eval/scenarios/s1_startup.sh --zc zig-out/bin/zc` PASS

## Deferred / accepted
- GEOIP fixture uses `183.1.2.3` (SimpleGeoIp CN); not reverting to 114.*
- Full `--suite all` / interop not re-run in this round (selfcheck + S1/S2 covered)

## Follow-up: just entrypoints

User-facing script commands are managed via Justfile recipes (`just --list`):
eval / eval-selfcheck / build / test / e2e / beta-gate / validate / perf-record / …
CI build-test job uses `just` for build, test, migrator, install-regression, eval-selfcheck.
