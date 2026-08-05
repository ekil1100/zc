default:
    @just --list

install:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build -Doptimize=ReleaseFast
    # 必须在替换二进制前使用旧版本停止 daemon。不同版本可能使用不同
    # runtime 路径；替换后再执行 restart 可能发现不了旧实例并形成双实例。
    installed_zc="$HOME/.local/bin/zc"
    was_running=0
    rollback_needed=0
    backup_path=""
    rollback_install() {
        rc=$?
        trap - EXIT
        if [ "$rc" -ne 0 ] && [ "$rollback_needed" -eq 1 ] && [ -n "$backup_path" ]; then
            echo "安装失败 —— 恢复旧二进制并尝试重启..." >&2
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
            echo "无法用安装目标中的旧二进制确认 daemon 状态，拒绝替换" >&2
            exit 1
        }
        old_state="$(jq -er '.data.state' <<<"$old_status")"
        if [ "$old_state" = "running" ]; then
            old_pid="$(jq -er '.data.pid' <<<"$old_status")"
            old_command="$(ps -ww -o command= -p "$old_pid")"
            old_executable="${old_command%% *}"
            if [ "$old_executable" != "$installed_zc" ]; then
                echo "运行实例并非由安装目标启动，拒绝自动接管：$old_executable" >&2
                exit 1
            fi
            if [[ "$old_command" == *" --foreground"* \
              || "$old_command" == *" -c "* \
              || "$old_command" == *" --port "* \
              || "$old_command" == *" --port="* \
              || "$old_command" == *" --override-"* ]]; then
                echo "旧 daemon 使用 foreground 或自定义启动参数；请通过 supervisor 或手动 stop/install/start 保留参数" >&2
                exit 1
            fi
            was_running=1
            backup_path="$(mktemp "${TMPDIR:-/tmp}/zc-old.XXXXXX")"
            cp "$installed_zc" "$backup_path"
            chmod 755 "$backup_path"
            echo "zc 之前在运行 —— 替换前先用安装目标中的旧二进制停止..."
            "$installed_zc" stop
            rollback_needed=1
            stopped_status="$("$installed_zc" status --json)" || exit 1
            if [ "$(jq -er '.data.state' <<<"$stopped_status")" != "stopped" ]; then
                echo "旧 daemon 未确认停止，拒绝替换二进制" >&2
                exit 1
            fi
        elif [ "$old_state" != "stopped" ]; then
            echo "旧 daemon 状态不可判定，拒绝替换二进制" >&2
            exit 1
        fi
    fi
    bash scripts/install/local-dev-install.sh
    if [ "$was_running" -eq 1 ]; then
        echo "使用安装目标中的新二进制启动 zc..."
        "$installed_zc" start
        new_status="$("$installed_zc" status --json)"
        [ "$(jq -er '.data.state' <<<"$new_status")" = "running" ]
        rollback_needed=0
    fi
