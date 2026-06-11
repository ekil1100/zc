default:
    @just --list

install:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build -Doptimize=ReleaseFast
    # 安装前先记录 daemon 是否在运行，用于“按需重启”。
    # `zc status --json` 把 envelope 输出到 STDOUT（运行/停止都退出 0），直接用 jq 解析。
    # 该判断处于 if 条件中：即使 zc/jq 失败（非零退出、无 JSON），
    # 也只会判为 false（was_running=0），既不会中断安装，也不会误启 daemon。
    was_running=0
    if [ "$(zc status --json | jq -r .data.state 2>/dev/null)" = "running" ]; then
        was_running=1
    fi
    # 原子替换二进制（staged temp + mv -f）；正在运行的旧 daemon 仍持有旧 inode，安全。
    bash scripts/install/local-dev-install.sh
    # 按需重启：仅当安装前在运行时才重启。`zc restart` 会停掉旧进程并用新二进制重新 fork。
    # 不能无条件调用 restart——它总会以 start 结尾，会把本来停止的 daemon 启动起来。
    if [ "$was_running" -eq 1 ]; then
        echo "zc 之前在运行 —— 使用新二进制重启..."
        zc restart
    fi
