# zc CLI Migration Baseline

## 1. Command contract matrix

All mappers agree on one global fact: except for `zc proxy/profile test --json` (the single stdout writer, `src/compat.zig:55-61` via `src/test_cli.zig:114`), **every byte the CLI emits — help, human output, JSON envelopes, errors — goes to stderr** via `std.debug.print` or raw writes to `STDERR_FILENO`.

| Command | `--json` today | Success stream | Error style | Exit codes | Source refs |
|---|---|---|---|---|---|
| `zc` (no args) | no | stderr (full help) | n/a | 0 | main.zig:82-86, 1747-1839 |
| `zc help [topic]` / `-h` / `--help` | no | stderr | ad-hoc "Unknown help topic" + full help | always 0 (even unknown topic) | main.zig:109-116, 1718-1745 |
| `zc --version` | **not implemented** — falls into unknown-command path ("Unknown command: --version" + help) | stderr | COMMAND_UNKNOWN path | 1 | main.zig:873-881 (verified: no `--version` handling anywhere in src/); yet required by Containerfile:23 and e2e-test-podman.sh:76 |
| `zc start` | yes — `{"ok":true,"data":{"action":"start","state":"running","pid":N}}`; no `command` field | stderr | printCliError envelope (START_* codes); **double-print bug** on failure (daemon.zig:750-758 then main.zig:140 → two JSON lines) | 0 success/already-running; 1 via raw Zig error trace | main.zig:118-144, 1306-1406; daemon.zig:711-860, 393-404, 411-464 |
| `zc stop` | yes — `{"action":"stop","state":"stopped",...}` | stderr | printCliError STOP_FAILED; **double-print** (daemon.zig:867/881 + main.zig:149) | 0 success/already-stopped; 1 via Zig trace | main.zig:146-153; daemon.zig:863-905 |
| `zc restart` | yes — but emits **2–3 separate JSON lines** per run (stop + start + restart envelopes) | stderr | printCliError RESTART_* codes; partial double-print suppression (main.zig:167-175) | 0 success; 1 via Zig trace | main.zig:155-179, 1408-1433; daemon.zig:863-923 |
| `zc status` | yes — richest payload; strings escaped via appendJsonStringEscaped (partial: misses ctrl chars <0x20) | stderr (even `--json`, daemon.zig:639) | printCliError STATUS_FAILED | always 0 running or stopped; 1 via Zig trace | main.zig:181-188; daemon.zig:480-667, 585-596 |
| `zc log` | **no** — `--json` silently ignored | stderr | mostly silent/ad-hoc; only lifecycle cmd with **no envelope at all** (bare `try` main.zig:211) | 0 / never exits (default follows forever) / 130 on Ctrl-C / 1 Zig trace | main.zig:190-213; daemon.zig:967-1088 |
| `zc --daemon-run` (hidden) | parsed, errors only | stderr (redirected to log file by parent) | ad-hoc banner + printCliError for arg errors | runs forever; 1 on startup error | main.zig:97-106, 1239-1298; daemon.zig:826-835 |
| `zc config` (bare) | no (ignored) | stderr | ad-hoc text | 0; 1 Zig trace on NoConfigDir | main.zig:216-220; config.zig:1612-1659 |
| `zc config list` / `ls` | no | stderr | ad-hoc text, no envelope | 0; 1 Zig trace | main.zig:229-236; config.zig:1612-1659 |
| `zc config download <url>` | no | stderr | ad-hoc text | 0 success **and** missing-url usage error; 1 Zig trace on download failure | main.zig:238-264; config.zig:1123-1291 |
| `zc config update` | no (own messages always text; only nested daemon reload honors `--json` → mixed-format output) | stderr | mixed ad-hoc + nested envelopes | **0 on several failures** (invalid `--apply`, no subscription URL); 1 Zig trace on download error | main.zig:266-328; config.zig:1566-1609; daemon.zig:929-951 |
| `zc config use <name>` | no | stderr | ad-hoc text | 0; 1 Zig trace on ConfigNotFound; 0 on missing arg (help) | main.zig:330-342; config.zig:1662-1711 |
| `zc config dump` | yes — but **bare config object, no `{ok,data}` envelope**; secrets masked | stderr (payload via std.debug.print, main.zig:388 — unpipeable) | printCliError OVERRIDE_*/CONFIG_DUMP_FAILED; config-load failure bypasses envelope (bare `try` main.zig:351-354) | 0; 1 | main.zig:344-390; override.zig:646-888 |
| `zc config override` | yes — set/clear/show envelopes | stderr | printCliError CONFIG_OVERRIDE_* codes; **invalid args exit 0 and diverge by mode** (JSON envelope vs help text, main.zig:399-403) | 0 success and invalid-args; 1 on real failures | main.zig:392-495, 1141-1166, 1206-1230; config.zig:1354-1460 |
| `zc config <unknown>` | no — ad-hoc text even with `--json` | stderr | "Unknown config subcommand", no envelope, no help | **always 0** | main.zig:497-498 |
| `zc proxy` (bare/help) | no — help even with `--json` (inconsistent with `zc profile`) | stderr | help only | 0 | main.zig:502-513, 1870-1889 |
| `zc proxy list` / `ls` | yes — **unescaped** hand-built JSON (proxy_cli.zig:95-131); type-fallback bug substitutes proxy *name* as `type` (proxy_cli.zig:122) | stderr (even `--json`, proxy_cli.zig:137) | printCliError PROXY_CONFIG_LOAD_FAILED | 0; 1 Zig trace | main.zig:515-546; proxy_cli.zig:43-138 |
| `zc proxy select` | yes — but **JSON mode never calls notifyDaemon** (no-op reporting `state:"selected"`); `-g` matches any group in JSON, only select-groups in text | stderr (interactive TUI on stderr) | JSON: envelope (PROXY_GROUP_NOT_FOUND etc.); text: ad-hoc + Zig trace | **inconsistent: text errors → 1; JSON errors → 0** (main.zig:593); non-TTY stdin silently auto-picks first proxy | main.zig:548-599; proxy_cli.zig:141-486 |
| `zc proxy test` | yes — **only stdout JSON in the CLI** (test_cli.zig:114); JSON skips all external probes and **never reports failure** | mixed: JSON→stdout, text→stderr | printCliError PROXY_CONFIG_LOAD_FAILED | 0; 1 on config failure; text-mode probe failure → 1, JSON always 0 | main.zig:601-630; test_cli.zig:79-200 |
| `zc proxy <unknown>` | yes — PROXY_SUBCOMMAND_UNKNOWN envelope | stderr | envelope / ad-hoc + help | **always 0** | main.zig:632-639 |
| `zc profile` (bare) | yes — PROFILE_SUBCOMMAND_MISSING (inconsistent with proxy's help-only) | stderr | envelope or help | 0 | main.zig:643-658 |
| `zc profile list/select/test/<unknown>` | as proxy equivalents | as proxy | same, but error messages/hints leak "proxy" wording (main.zig:680, 733-734) | same as proxy (incl. JSON-error-exit-0 flaw) | main.zig:660-784 — byte-for-byte copy-paste of 515-639. Note: `printProfileListJson` (main.zig:988-1047) is dead code |
| `zc test` | yes — same payload as proxy test, stdout; config-load failure in `--json` is **completely silent** before exit 1 | mixed (JSON→stdout, text→stderr) | text: ad-hoc hints + Zig trace; no envelope on config failure | 0; 1 text failures; JSON always 0 once config loads | main.zig:788-805; test_cli.zig:13-360, 498-564. **No `--help` handling** (unlike `zc proxy test` — mapper-confirmed inconsistency between the two spellings) |
| `zc doctor` | yes — **unescaped** config_path/errors/warnings/hints (doctor_cli.zig:82-128) | stderr (even `--json`, doctor_cli.zig:136) | JSON: DIAG_DOCTOR_FAILED; **text-mode config failure prints nothing** (json-only guard main.zig:810-816) | 0 even when all checks FAIL; 1 on load/emit error | main.zig:807-828; doctor_cli.zig:56-181. **No `--help`**; external probe to 1.1.1.1:443 runs in both modes (doctor_cli.zig:170, 219-281) — testDoctor mapper verified this contradicts spec.md's "JSON skips probes" claim |
| `zc diag` (bare/help/unknown) | yes — DIAG_SUBCOMMAND_UNKNOWN (misused for missing arg too) | stderr | envelope in both modes (inconsistent with proxy/profile prose+help) | **always 0** | main.zig:830-847, 2011-2023 |
| `zc diag doctor` | yes — identical to `zc doctor`, but **does** support `--help` (main.zig:848-851) | stderr | DIAG_DOCTOR_FAILED | 0; 1 | main.zig:848-871; doctor_cli.zig:56-137 |
| `zc <unknown>` | yes — COMMAND_UNKNOWN envelope | stderr | envelope / ad-hoc + full help | **1** via explicit exit(1) — the only nonzero unknown-path | main.zig:873-881 |

Mapper disagreements: none material — lifecycle, config, proxyHelp, and testDoctor inventories overlap on `proxy test`, `doctor`, and `diag doctor` and agree on streams, shapes, and exit codes. The only nuance worth recording: proxyHelp lists `zc doctor` error style as "DIAG_DOCTOR_FAILED" generally, while testDoctor clarifies the envelope is emitted **only in `--json` mode** (main.zig:810-816); text mode gets just the Zig trace. The testDoctor reading is correct per the json-only guard.

## 2. Gaps vs target

Ordered by user impact:

1. **JSON (and everything else) goes to stderr, not stdout.** Every command except `zc test --json`/`zc proxy test --json` prints via `std.debug.print`. `zc status --json | jq` reads nothing; `scripts/reliability/run-soak-real.sh:112` is *currently broken* because of this. Affected: all commands. Refs: daemon.zig:639, doctor_cli.zig:136, proxy_cli.zig:137, main.zig:388, main.zig:1049-1061; sole stdout path test_cli.zig:114/compat.zig:55-61.
2. **JSON is hand-formatted with no (or partial) escaping — target requires std.json.** Unescaped: proxy list (proxy_cli.zig:95-131), proxy select choices + PUT body (proxy_cli.zig:162-178, 421-423), doctor config_path/errors/warnings/hints (doctor_cli.zig:82-128), config override profile/script paths (main.zig:437-485). Partial escaping (misses ctrl chars <0x20): status (daemon.zig:585-596), config dump (override.zig:875-888), selected_proxies (runtime_selection.zig:127-137). printCliError itself never escapes (main.zig:1051-1054).
3. **Envelope shape mismatches the target.** No `"command":"<path>"` field anywhere; `config dump --json` emits a bare config object with no envelope (override.zig:769-873); `zc restart --json` emits 2–3 independent JSON lines per invocation (main.zig:1424,1432 + daemon envelopes) instead of one document. Affected: all `--json` commands.
4. **Exit codes are wildly non-uniform.** JSON-mode errors exit 0 (proxy/profile select, main.zig:593/738); unknown subcommands exit 0 (config main.zig:497-498, proxy main.zig:639, profile main.zig:784, diag main.zig:845-846) while top-level unknown exits 1 (main.zig:880); usage errors exit 0 (config download missing url main.zig:243-246, config update invalid `--apply` main.zig:281-285, config override invalid args main.zig:403); propagated errors exit 1 but with a raw Zig `error:` + stack trace *after* any envelope (double error output, main.zig:63). `test --json`/`doctor --json` exit 0 even when checks fail (test_cli.zig:79-115; doctor_cli findings).
5. **Many commands have no `--json` at all.** `zc log` (target: JSON Lines), `zc config` bare/list/download/update/use, `zc help`. Refs: main.zig:190-213 (`--json` ignored), main.zig:216-342. `config update` can interleave plain text with nested JSON daemon output (main.zig:314-323).
6. **Help is broken vs target (help on stdout, exit 0; per-command `--help`).** No per-command help for start/stop/restart/status/log (`--help` silently ignored and the command *runs* — `zc start --help` actually starts the daemon, `zc log --help` tails), nor for `zc test`/`zc doctor` (main.zig:788, 808). All help prints to stderr. `zc help start|stop|...|test` → "Unknown help topic" + full help, exit 0 (main.zig:1732-1745). `containsHelpArg` matches help/-h/--help at *any* position, so values literally named "help" are unusable (main.zig:1724-1730). Cosmetic: duplicated `proxy select` line (main.zig:1798-1799, 1878-1880, 1999-2001), documented-but-unparsed `-d` for download (main.zig:1785/1850 vs 251-259).
7. **Double-print bugs on lifecycle failures** — two envelopes (two JSON lines in `--json` mode): start (daemon.zig:750-758 + main.zig:140), stop (daemon.zig:867/881 + main.zig:149); restart only partially suppressed (main.zig:167-175).
8. **JSON/text behavior divergence (not just formatting).** `proxy select --json -g G -p P` reports success without notifying the daemon (proxy_cli.zig:141-179 never calls notifyDaemon); `-g` group matching differs by mode (proxy_cli.zig:143-147 vs 203-215); `test --json` runs no probes and can't fail; doctor exposes network_ok/version/errors/warnings/hints/uptime only in JSON (doctor_cli.zig:382-399 vs 78-137).
9. **No TTY detection, NO_COLOR, or `--no-color`.** ANSI colors/raw-mode TUI written unconditionally to stderr (proxy_cli.zig:255-360, 445-486); emoji markers in test output (test_cli.zig:475-479). Non-TTY stdin silently auto-selects proxy index 0 (proxy_cli.zig:256-266) — dangerous under pipes.
10. **No `zc --version`** despite Containerfile:23 (`RUN zc --version` gates the image build) and e2e-test-podman.sh:76; currently resolves to COMMAND_UNKNOWN, exit 1 (verified by grep — no `--version` in src/).
11. **`--json` and flags parsed positionally-blind**: `hasFlag` matches `--json` anywhere in argv (main.zig:89, 1189-1194) so a positional value `--json` flips modes; unknown/misspelled flags silently ignored everywhere; `-c`/`-n` with missing values silently dropped (main.zig:1199, 253-258).
12. **No `src/cli/output.zig`, no command table.** Dispatch is a hand-rolled if-chain with profile being a byte-for-byte copy of proxy (main.zig:660-784 vs 515-639); printCliOk/printCliError duplicated in main.zig:1049-1102 and daemon.zig:411-464; dead code `printProfileListJson` (main.zig:988-1047) and parallel `daemon.restartDaemon` (daemon.zig:908-923).
13. **`zc log` semantics**: default follows forever; timestamps are view-time not event-time (daemon.zig:1085-1088); rename-rotation goes silently stale (daemon.zig:1013-1022); output on stderr defeats `| grep`.

## 3. Consumer breakage checklist

| Consumer | Expects today | Must become |
|---|---|---|
| `Justfile:14` | `zc status --json 2>&1 \| grep -q '"state":"running"'` — JSON on stderr (deliberate `2>&1`), exit 0 in both states, compact `"state":"running"` substring | Survives stdout move (2>&1 merges); update to `zc status --json \| jq -r .data.state` once stdout/std.json lands; keep `state`/`running` tokens and exit-0-when-stopped, or rewrite the check |
| `Justfile:23` | `zc restart` exits 0 under `set -euo pipefail` | Keep exit 0 on success — no change if codes stay uniform |
| `scripts/reliability/run-soak-real.sh:112` | `doctor --json 2>/dev/null \| grep -q '"proxy_reachable":true'` — **currently never matches** (JSON on stderr) | Fixed for free by stdout move; keep `proxy_reachable` key and compact `:true`, or switch script to jq |
| `scripts/reliability/run-soak-real.sh:67,73,100-104` | backgrounded `zc start` process stays alive (kill -0 liveness, crash-restart) | Breaks if start's fork model changes; align with process-model decision (Open question 1) and update to pid-file-based liveness if start becomes fork-and-exit officially |
| `scripts/e2e-test-podman.sh:76-81` | `zc --version 2>&1` contains "zc" — currently exits 1 (unknown command) which aborts the `set -e` script at the command substitution | Implement real `--version` on stdout, exit 0 |
| `scripts/e2e-test-podman.sh:85-90` | `zc --help 2>&1 \| grep -q "Usage"` — **latently failing** (help says `USAGE:`) | New generated help must contain literal "Usage" (or update grep) and stay exit 0; stdout move tolerated by 2>&1 |
| `scripts/e2e-test-podman.sh:94-114` | doctor text contains `OK\|valid`; doctor exits 0 on valid config (both non-blocking) | Keep "OK"/"valid" token in text labels and exit 0 for healthy configs |
| `scripts/e2e-test-podman.sh:118-137` | `zc start` as container PID 1 stays foreground ≥5s (fatal check) | Conflicts with current daemonize model — resolve per Open question 1 (e.g. `zc start --foreground` and update script) |
| `scripts/e2e-test-podman.sh:179-184` | `zc reload` exits 0 — command **does not exist** in dispatch (verified) | Either add `reload` to the command table or delete the test (non-blocking warn today) |
| `scripts/test-release-install.sh:131,136` | `zc --help` exit 0; `--help \| head -3` SIGPIPE-safe | After help moves to stdout, ensure EPIPE doesn't produce nonzero exit |
| `scripts/test-release-install.sh:182-201` | `zc start -c …` returns promptly (non-blocking) then `status`/`stop` | Opposite of podman/systemd expectation — keep fork-and-exit for default `start` or update script per process-model decision |
| `scripts/test-release-install.sh:141-208` | various commands `… 2>&1 \|\| true` — must not hang or prompt | `zc test` must keep self-timeout; interactive select must never trigger non-interactively (replace auto-pick-index-0 with an error) |
| `scripts/install-curl.sh:83-85` | `zc --help \| head -3` exit 0 under pipefail | Same as above: exit 0 + EPIPE-safe |
| `Containerfile:23,29` | `RUN zc --version` exit 0; `CMD ["zc","--help"]` exit 0 | Implement `--version`; keep `--help` exit 0 |
| `.github/workflows/release.yml` generated Homebrew formula | `zc --help` exit 0 | Keep |
| `scripts/zclash.service:6-12`, `scripts/build-deb.sh:44-59` | systemd `Type=simple`, `ExecStart=… start` long-running foreground; stop/restart exit 0 | Either change units to `Type=forking` + PIDFile, or add a foreground mode — per Open question 1 |
| `src/integration_error_test.zig:13-68` | merged stdout+stderr contains compact `"ok":false`, `"error":{`, codes PROFILE_NOT_FOUND / PROXY_SUBCOMMAND_UNKNOWN / DIAG_SUBCOMMAND_UNKNOWN, `"message":`, `"hint":` | Update assertions for new envelope (add `"command":` key; std.json output formatting); keep code strings; tolerant of stdout move (already merged) |
| `src/daemon.zig:1316-1334` | exact compact substrings of status JSON incl. `paths` object order | Rewrite test against std.json-emitted envelope; preserve field names `action/state/pid/uptime_seconds/active_config/selected_proxies/paths` |
| `src/daemon.zig:1159,1199-1201,1291-1292` | state tokens `running`/`stopped`, details `stale_pid_file`/`lock_held_pid_untracked` | Keep token values verbatim |
| `src/doctor_cli.zig:413-434` | text labels `Config: OK`, `Daemon: stopped`, `PID: -`, `Port: 7890`, `Connection: FAILED` | Keep labels (also feeds e2e grep) or update test+spec.md:17 together |
| `src/test_cli.zig:638-641` | exact stopped-daemon hint strings | Update if hint wording changes |
| `src/test_cli.zig:82-90` | literal `{"ok":true,"data":{"action":"proxy_test","daemon_state":"…"` | Re-emit via output.zig; keep `daemon_state` key (documented in compat doc) |
| `src/runtime_selection.zig:250-263` | exact `[{"group":"Proxy","proxy":"B","source":"persisted"}]` | Keep keys/order or update test |
| `src/main.zig:2279-2283` | `RESTART_PORT_IN_USE` code, exact message, hint contains "zc restart" | Keep code string; update message assertion if reworded |
| `docs/cli/spec.md:53-66, 11, 16-17` | seven `--json` commands; "JSON on stdout"; doctor labels; `already_running` | Update spec to the new global contract (it already *requires* stdout) |
| `docs/api/error-codes.md:96-102` | documented code strings + hints | Keep codes; regenerate hints alongside help |
| `docs/compat/mihomo-clash.md:68,105-110` | `selected_proxies`, `daemon_state` field names; three `--json` commands | Keep field names |
| `README.md:79-93,171-177`; `docs/roadmap/v1.0.md:71-73,106-110` | copy-paste `--json` sequences exit 0; "test --json emits valid JSON on stdout" | Re-verify sequences after each batch |
| `.github/workflows/ci.yml:24,33`; `scripts/run-beta-gate.sh:33` | `zig build test` + run-full-validation.sh enforce all string assertions | Every batch must land with its test updates in the same commit |

## 4. Suggested migration batches

**Batch 1 — Output infrastructure + global surface (no command payload changes).**
- Commands: `zc` (bare), `zc help`, `zc --version` (new), `zc <unknown>`, command-table skeleton.
- Files: new `src/cli/output.zig` (Output context: std.json envelope writer with `command` field, stdout/stderr routing, TTY/NO_COLOR/`--no-color`, JSONL writer); new declarative command table + generated help in `src/main.zig` (dispatch shell only — existing handlers called through it); delete dead `printProfileListJson`.
- Consumers: e2e-test-podman.sh:76-90 ("Usage" grep + version), Containerfile:23/29, test-release-install.sh:131-136 (EPIPE), install-curl.sh:83-85, homebrew zc.rb.
- Acceptance: `zig build test`; `zc --help >out 2>err` → help in out, err empty, exit 0; `zc --version` exit 0; `zc nope` → usage on stderr, exit ≠0; `zc nope --json | jq .ok` works from stdout.

**Batch 2 — Lifecycle: start/stop/restart/status/log.**
- Commands: start, stop, restart (single final envelope; intermediate steps to stderr text or suppressed), status, log (`--json` = JSON Lines; `--help`; event timestamps decision), `--daemon-run` untouched.
- Files: `src/main.zig` (lifecycle dispatch), `src/daemon.zig` (remove duplicated printCliOk/printCliError, fix double-prints, route JSON through output.zig), `src/runtime_selection.zig` (escaping via std.json).
- Consumers: Justfile:14 (jq rewrite), daemon.zig:1159-1334 tests, runtime_selection.zig:250-263 test, main.zig:2279-2283 test, README smoke sequence, run-soak-real.sh:67, zclash.service/build-deb.sh (per process-model decision).
- Acceptance: `zig build test`; `zc status --json | jq -e '.ok and .command=="status"'`; failure paths emit exactly one JSON line, exit ≠0, no Zig stack trace; `just install` round-trips.

**Batch 3 — config tree.**
- Commands: config list/download/update/use/dump/override + bare/unknown; uniform `--help`; nonzero usage errors; `--json` for list/download/update/use; decide dump envelope (Open question 3); fix `-d` flag; std.json everywhere.
- Files: `src/main.zig` (config dispatch), `src/config.zig`, `src/override.zig`.
- Consumers: test-release-install.sh:154-168 (tolerant), docs/cli/spec.md config section.
- Acceptance: `zig build test`; `zc config dump --json | jq .` and `zc config dump > f` capture the payload; `zc config nope` exits ≠0; `zc config list --json | jq` works.

**Batch 4 — proxy/profile: list/select/test (de-duplicate via table).**
- Commands: proxy+profile list/select/test/unknown; single shared handler with command-path-aware messages; JSON-mode select calls notifyDaemon (parity fix); unify `-g` matching; non-TTY select without `-g -p` → error instead of auto-pick; nonzero exits for JSON errors and unknown subcommands; escape all names; fix type-fallback bug.
- Files: `src/main.zig`, `src/proxy_cli.zig`, `src/test_cli.zig` (envelope via output.zig — already stdout).
- Consumers: src/integration_error_test.zig (PROXY/PROFILE codes), test_cli.zig:82-90/638-641 tests, docs/api/error-codes.md:96-97, docs/compat/mihomo-clash.md:68/105-110.
- Acceptance: `zig build test`; `zc proxy list --json | jq`; `zc proxy select -g X --json` with bad group exits ≠0 with one envelope; piped stdin no longer mutates daemon selection.

**Batch 5 — test/doctor/diag + docs/spec/CI sweep.**
- Commands: `zc test`, `zc doctor`, `zc diag doctor` (+ diag bare): per-command `--help` (incl. bare `zc test`/`zc doctor`), envelope on config-load failure in *both* modes, escape doctor strings, decide JSON-mode probe semantics & `ok:false` on failed probes (Open question 5), distinguish DIAG missing vs unknown subcommand codes.
- Files: `src/main.zig`, `src/doctor_cli.zig`, `src/test_cli.zig`; docs: `docs/cli/spec.md`, `docs/api/error-codes.md`, `docs/compat/mihomo-clash.md`, `README.md`, `docs/roadmap/v1.0.md`; scripts: run-soak-real.sh:112 (drop 2>/dev/null workaround note), e2e-test-podman.sh:94-114/179-184 (`zc reload` decision).
- Consumers: doctor_cli.zig:413-434 test, integration_error_test.zig:67 (DIAG code), e2e doctor greps.
- Acceptance: `zig build test`; `bash scripts/run-full-validation.sh`; `zc doctor --json | jq -e .data.proxy_reachable` from stdout; full README/roadmap smoke sequence; e2e-podman script passes end-to-end.

(Each batch keeps `main.zig` edits sequential; output.zig is created once in Batch 1 and only consumed thereafter.)

## 5. Open questions

1. **Process model for `zc start`** — consumers are contradictory: systemd `Type=simple` units (zclash.service, build-deb.sh) and the podman PID-1 test need *foreground*; test-release-install.sh and the current fork-and-exit code need *prompt return*. Recommend: keep fork-and-exit default, add `--foreground` (alias of `--daemon-run` semantics), and update units + podman script — needs maintainer sign-off.
2. **Should `zc status` exit nonzero when stopped?** Justfile:14 relies on exit 0 in both states; a `--exit-code` opt-in vs changing the default needs a call.
3. **`config dump --json` envelope** — wrapping the config in `{ok,data}` matches the global contract but makes `zc config dump --json | yq` round-trips awkward (and changes today's bare-object shape). Wrap, or document dump as an explicit exception?
4. **`zc restart --json` intermediate events** — collapse to one final envelope (recommended), or keep step events as JSON Lines like `zc log`?
5. **`test`/`doctor` failure semantics in JSON mode** — should failed probes/checks produce `ok:false` + nonzero exit (target says failure ⇒ non-zero), or stay `ok:true` with failing fields as data? Also: should `test --json` run the real curl probes for text/JSON parity (cost: up to 90s), and should doctor's unconditional 1.1.1.1:443 probe be kept in JSON mode (spec.md currently claims it isn't)?
6. **`zc reload`** — referenced by e2e-test-podman.sh:179 but not implemented; add as alias of restart/hot-reload, or delete the test?
7. **Stable-token guarantees** — confirm the frozen vocabulary before refactoring: error code strings (docs/api/error-codes.md + integration tests), `state`/`detail` tokens, `selected_proxies`/`daemon_state` keys, doctor text labels (`Config: OK` etc.). Everything else (messages, hints, whitespace) gets re-asserted; key *order* guarantees (daemon.zig:1316-1334 paths object) should be dropped in favor of parsed-JSON assertions.
8. **Curated short aliases** — `ls` exists for list; does the maintainer want more (e.g. `zc st`, `zc up/down`), and should `profile` remain a full alias group of `proxy` (its `list` lists proxy groups, not profiles — arguably misnamed) or be repurposed/deprecated?
9. **`zc config use` auto-apply** — today it does not touch a running daemon while `config update`/`override` auto-apply; unify during Batch 3 or keep as-is?
10. **`already_running`/`already_stopped`** stay `ok:true` successes (current behavior, spec.md:11) — confirm, since uniform exit codes might tempt someone to make them errors and break Justfile/README flows.