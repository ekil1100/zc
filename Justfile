default:
    @just --list

install:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build -Doptimize=ReleaseFast
    # Stop the daemon with the previously installed binary before replacing it.
    # Different versions may use different runtime paths; replacing first can leave a second instance.
    installed_zc="$HOME/.local/bin/zc"
    was_running=0
    rollback_needed=0
    backup_path=""
    old_pid=""
    file_identity() {
        local path="$1"
        if stat -f '%d:%i' "$path" >/dev/null 2>&1; then
            stat -f '%d:%i' "$path"
        else
            stat -Lc '%d:%i' "$path"
        fi
    }
    process_executable_identity() {
        local pid="$1"
        local record device inode
        if [ -e "/proc/$pid/exe" ]; then
            stat -Lc '%d:%i' "/proc/$pid/exe"
            return
        fi
        record="$(lsof -a -p "$pid" -d txt -FDi 2>/dev/null | awk '
            /^D/ { device=substr($0, 2) }
            /^i/ { inode=substr($0, 2) }
            device != "" && inode != "" { print device ":" inode; exit }
        ')"
        [ -n "$record" ] || return 1
        device="${record%%:*}"
        inode="${record#*:}"
        printf '%d:%s\n' "$((device))" "$inode"
    }
    rollback_install() {
        rc=$?
        trap - EXIT
        if [ "$rc" -ne 0 ] && [ "$rollback_needed" -eq 1 ] && [ -n "$backup_path" ]; then
            echo "install failed — restoring previous binary and attempting restart..." >&2
            "$installed_zc" stop >/dev/null 2>&1 || true
            rollback_stage="$(mktemp "$installed_zc.rollback.XXXXXX")"
            cp "$backup_path" "$rollback_stage"
            chmod 755 "$rollback_stage"
            mv -f "$rollback_stage" "$installed_zc"
            "$installed_zc" start >/dev/null 2>&1 || true
        fi
        [ -z "$backup_path" ] || rm -f "$backup_path"
        exit "$rc"
    }
    trap rollback_install EXIT
    if [ -x "$installed_zc" ]; then
        old_status="$("$installed_zc" status --json)" || {
            echo "unable to confirm daemon status with the installed binary; refusing replace" >&2
            exit 1
        }
        old_state="$(jq -er '.data.state' <<<"$old_status")"
        if [ "$old_state" = "running" ]; then
            old_pid="$(jq -er '.data.pid' <<<"$old_status")"
            old_command="$(ps -ww -o command= -p "$old_pid")"
            old_executable="${old_command%% *}"
            if [ "$old_executable" != "$installed_zc" ]; then
                echo "running instance was not started from the install target; refusing takeover: $old_executable" >&2
                exit 1
            fi
            pid_file="$(jq -er '.data.paths.pid_file' <<<"$old_status")"
            descriptor_file="$(dirname "$pid_file")/zc.daemon.json"
            prepared_default=0
            if [ -f "$descriptor_file" ] && jq -e \
              --argjson pid "$old_pid" \
              '.pid == $pid and .ready == true and
               .invocation.prepared == true and
               .invocation.foreground == false and
               .invocation.source_path == null and
               .invocation.port_override == null and
               .identity != null' \
              "$descriptor_file" >/dev/null 2>&1; then
                prepared_default=1
            fi
            if [ "$prepared_default" -ne 1 ] && [[ "$old_command" == *" --foreground"* \
              || "$old_command" == *" -c "* \
              || "$old_command" == *" --port "* \
              || "$old_command" == *" --port="* \
              || "$old_command" == *" --override-"* ]]; then
                echo "old daemon uses foreground or custom flags; stop/install/start manually to preserve them" >&2
                exit 1
            fi
            was_running=1
            backup_path="$(mktemp "${TMPDIR:-/tmp}/zc-old.XXXXXX")"
            cp "$installed_zc" "$backup_path"
            chmod 755 "$backup_path"
            echo "zc is running — stopping with the installed binary before replace..."
            "$installed_zc" stop
            rollback_needed=1
            stopped_status="$("$installed_zc" status --json)" || exit 1
            if [ "$(jq -er '.data.state' <<<"$stopped_status")" != "stopped" ]; then
                echo "old daemon did not confirm stopped; refusing binary replace" >&2
                exit 1
            fi
        elif [ "$old_state" != "stopped" ]; then
            echo "old daemon state is indeterminate; refusing binary replace" >&2
            exit 1
        fi
    fi
    bash scripts/install/local-dev-install.sh
    if [ "$was_running" -eq 1 ]; then
        expected_identity="$(file_identity "$installed_zc")"
        echo "starting zc with the newly installed binary..."
        new_start="$("$installed_zc" start --json)"
        [ "$(jq -er '.data.state' <<<"$new_start")" = "running" ]
        new_status="$("$installed_zc" status --json)"
        [ "$(jq -er '.data.state' <<<"$new_status")" = "running" ]
        new_pid="$(jq -er '.data.pid' <<<"$new_status")"
        if [ "$new_pid" = "$old_pid" ]; then
            echo "new daemon did not change PID; refusing to confirm install success" >&2
            exit 1
        fi
        actual_identity="$(process_executable_identity "$new_pid")" || {
            echo "unable to confirm the new daemon executable identity" >&2
            exit 1
        }
        if [ "$actual_identity" != "$expected_identity" ]; then
            echo "new daemon still runs the replaced inode; refusing to confirm install success" >&2
            exit 1
        fi
        rollback_needed=0
    fi

# --- Build / test -----------------------------------------------------------

# Build with baseline CPU (matches CI)
build:
    zig build -Dcpu=baseline

# Unit + process + oracle unit tests (matches CI)
test:
    zig build test -Dcpu=baseline

# Local real-binary e2e (not the CI e2e-release flavor)
e2e:
    zig build e2e --summary all

# CI-style static e2e-release (Linux musl target; may not suit every host)
e2e-release:
    zig build e2e-release -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe -Dcpu=baseline --summary all

# --- Eval framework ---------------------------------------------------------

# Fast eval contract checks (CI-safe; no full zig test / e2e / perf)
eval-selfcheck *args:
    bash scripts/eval/selfcheck.sh {{args}}

# Full selfcheck including correctness + contract
eval-selfcheck-full:
    bash scripts/eval/selfcheck.sh --full

# Show eval orchestrator help
eval-help:
    bash scripts/eval/run.sh --help

# Eval suite: just eval <correctness|contract|interop|perf|reliability|all> [-- --with-interop|--run-id ID]
eval suite *args:
    bash scripts/eval/run.sh --suite {{suite}} {{args}}

# Alias: correctness suite
eval-correctness:
    just eval correctness

eval-contract:
    just eval contract

eval-interop:
    just eval interop

eval-perf:
    just eval perf

eval-all:
    just eval all

# correctness + contract + interop + perf (clean tree required for perf)
eval-all-interop:
    just eval all -- --with-interop

# S1 startup scenario (default binary: zig-out/bin/zc)
eval-s1 zc="zig-out/bin/zc":
    bash scripts/eval/scenarios/s1_startup.sh --zc {{zc}}

# S2 rule-matrix scenario (production rule engine)
eval-s2:
    bash scripts/eval/scenarios/s2_rule_matrix.sh

# --- Gates / perf / reliability ---------------------------------------------

# Beta gate: build + test + migrator + install regression
beta-gate:
    bash scripts/run-beta-gate.sh

# Full validation: install regression + migrator + beta gate
validate:
    bash scripts/run-full-validation.sh

# Install regression only
install-regression:
    bash scripts/install/run-all-regression.sh

# Migrator regression only
migrator-regression:
    bash tools/config-migrator/run-all.sh

# Record control-plane perf facts (clean worktree); e.g. just perf-record -- --samples 9
perf-record *args:
    bash scripts/perf/run-control-plane-baseline.sh {{args}}

# Reliability soak harness (see scripts/reliability)
soak *args:
    bash scripts/reliability/run-soak.sh {{args}}

soak-real *args:
    bash scripts/reliability/run-soak-real.sh {{args}}

chaos-round *args:
    bash scripts/reliability/run-chaos-round.sh {{args}}
