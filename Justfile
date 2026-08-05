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
        expected_identity="$(file_identity "$installed_zc")"
        echo "使用安装目标中的新二进制启动 zc..."
        new_start="$("$installed_zc" start --json)"
        [ "$(jq -er '.data.state' <<<"$new_start")" = "running" ]
        new_status="$("$installed_zc" status --json)"
        [ "$(jq -er '.data.state' <<<"$new_status")" = "running" ]
        new_pid="$(jq -er '.data.pid' <<<"$new_status")"
        if [ "$new_pid" = "$old_pid" ]; then
            echo "新 daemon 未发生 PID 转换，拒绝确认安装成功" >&2
            exit 1
        fi
        actual_identity="$(process_executable_identity "$new_pid")" || {
            echo "无法确认新 daemon 的可执行文件身份" >&2
            exit 1
        }
        if [ "$actual_identity" != "$expected_identity" ]; then
            echo "新 daemon 仍在运行被替换的旧 inode，拒绝确认安装成功" >&2
            exit 1
        fi
        rollback_needed=0
    fi
