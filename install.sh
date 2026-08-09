#!/bin/sh
set -eu

zc_repo="${ZC_REPOSITORY:-ekil1100/zc}"
zc_version="${ZC_VERSION:-latest}"
zc_release_base_url="${ZC_RELEASE_BASE_URL:-https://github.com/$zc_repo/releases/download}"
zc_release_feed_url="${ZC_RELEASE_FEED_URL:-https://github.com/$zc_repo/releases.atom}"
zc_tmp_dir=""
zc_stage_path=""
zc_backup_path=""
zc_lock_dir=""
zc_target=""
zc_publish_in_progress=0
zc_restore_in_progress=0
zc_restore_path=""

zc_fail() {
    printf 'zc install: %s\n' "$1" >&2
    exit 1
}

zc_cleanup() {
    trap - 1 2 15
    if [ "$zc_restore_in_progress" -eq 1 ] && [ -n "$zc_target" ]; then
        if [ -f "$zc_restore_path" ]; then
            mv -f "$zc_restore_path" "$zc_target" || true
        fi
        zc_restore_in_progress=0
        zc_publish_in_progress=0
        zc_backup_path=""
    fi
    if [ "$zc_publish_in_progress" -eq 1 ] && [ -n "$zc_target" ]; then
        if [ -n "$zc_backup_path" ] && [ -f "$zc_backup_path" ]; then
            mv -f "$zc_backup_path" "$zc_target" || true
            zc_backup_path=""
        else
            rm -f "$zc_target"
        fi
    fi
    if [ -n "$zc_stage_path" ]; then
        rm -f "$zc_stage_path"
    fi
    if [ -n "$zc_backup_path" ]; then
        rm -f "$zc_backup_path"
    fi
    if [ -n "$zc_tmp_dir" ]; then
        rm -rf "$zc_tmp_dir"
    fi
    if [ -n "$zc_lock_dir" ]; then
        rm -f "$zc_lock_dir/owner"
        rmdir "$zc_lock_dir" >/dev/null 2>&1 || true
    fi
}
trap zc_cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

zc_download() {
    zc_download_url="$1"
    zc_download_path="$2"
    curl --proto '=https,file' --tlsv1.2 \
        --retry 3 --max-filesize 67108864 \
        --connect-timeout 10 --max-time 120 \
        -fsSL "$zc_download_url" -o "$zc_download_path"
}

zc_sha256() {
    zc_sha_path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$zc_sha_path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$zc_sha_path" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$zc_sha_path" | awk '{print $NF}'
    else
        zc_fail "sha256sum, shasum, or openssl is required"
    fi
}

zc_validate_tag() {
    zc_tag_candidate="$1"
    if ! printf '%s\n' "$zc_tag_candidate" | grep -Eq \
        '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'; then
        zc_fail "invalid release version: $zc_tag_candidate"
    fi
}

command -v curl >/dev/null 2>&1 || zc_fail "curl is required"
command -v tar >/dev/null 2>&1 || zc_fail "tar is required"
command -v awk >/dev/null 2>&1 || zc_fail "awk is required"
command -v mktemp >/dev/null 2>&1 || zc_fail "mktemp is required"

zc_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zc-install.XXXXXX")"

if [ "$zc_version" = "latest" ]; then
    zc_release_feed="$zc_tmp_dir/releases.atom"
    zc_download "$zc_release_feed_url" "$zc_release_feed" \
        || zc_fail "failed to resolve the latest release"
    zc_release_size="$(wc -c <"$zc_release_feed" | tr -d ' ')"
    if [ "$zc_release_size" -gt 1048576 ]; then
        zc_fail "release metadata exceeds 1 MiB"
    fi
    zc_tag="$(sed -n \
        's:.*href="[^"]*/releases/tag/\(v[0-9][0-9A-Za-z.-]*\)".*:\1:p' \
        "$zc_release_feed" | head -n 1)"
    [ -n "$zc_tag" ] || zc_fail "latest release metadata has no tag link"
else
    case "$zc_version" in
        v*) zc_tag="$zc_version" ;;
        *) zc_tag="v$zc_version" ;;
    esac
fi
zc_validate_tag "$zc_tag"

case "$(uname -s)" in
    Linux)
        zc_os="linux"
        command -v readlink >/dev/null 2>&1 || zc_fail "readlink is required on Linux"
        ;;
    Darwin)
        zc_os="macos"
        command -v lsof >/dev/null 2>&1 || zc_fail "lsof is required on macOS"
        ;;
    *) zc_fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
    x86_64 | amd64) zc_arch="amd64" ;;
    arm64 | aarch64) zc_arch="arm64" ;;
    *) zc_fail "unsupported architecture: $(uname -m)" ;;
esac

zc_default_path_hint=0
if [ -n "${ZC_INSTALL_DIR:-}" ]; then
    zc_install_dir="$ZC_INSTALL_DIR"
elif [ -n "${XDG_BIN_HOME:-}" ]; then
    zc_install_dir="$XDG_BIN_HOME"
    zc_default_path_hint=1
elif [ -n "${HOME:-}" ]; then
    zc_install_dir="$HOME/.local/bin"
    zc_default_path_hint=1
else
    zc_fail "HOME or ZC_INSTALL_DIR is required"
fi

zc_package="zc-$zc_tag-$zc_os-$zc_arch"
zc_archive="$zc_package.tar.gz"
zc_download_root="$zc_release_base_url/$zc_tag"
zc_archive_path="$zc_tmp_dir/$zc_archive"
zc_checksum_path="$zc_tmp_dir/$zc_archive.sha256"

printf 'Installing zc %s for %s/%s\n' "$zc_tag" "$zc_os" "$zc_arch"
zc_download "$zc_download_root/$zc_archive" "$zc_archive_path" \
    || zc_fail "failed to download $zc_archive"
zc_download "$zc_download_root/$zc_archive.sha256" "$zc_checksum_path" \
    || zc_fail "failed to download $zc_archive.sha256"
zc_archive_size="$(wc -c <"$zc_archive_path" | tr -d ' ')"
zc_checksum_size="$(wc -c <"$zc_checksum_path" | tr -d ' ')"
if [ "$zc_archive_size" -gt 67108864 ]; then
    zc_fail "release archive exceeds 64 MiB"
fi
if [ "$zc_checksum_size" -gt 4096 ]; then
    zc_fail "checksum file exceeds 4 KiB"
fi

zc_expected_sha="$(awk -v name="$zc_archive" '
    ($2 == name || $2 == "*" name) { print $1 }
' "$zc_checksum_path")"
case "$zc_expected_sha" in
    *' '*) zc_fail "checksum file contains duplicate entries for $zc_archive" ;;
esac
[ "${#zc_expected_sha}" -eq 64 ] || zc_fail "checksum is not a SHA-256 digest"
case "$zc_expected_sha" in
    *[!0-9A-Fa-f]*) zc_fail "checksum is not hexadecimal" ;;
esac

zc_actual_sha="$(zc_sha256 "$zc_archive_path")"
zc_expected_sha="$(printf '%s' "$zc_expected_sha" | tr 'A-F' 'a-f')"
zc_actual_sha="$(printf '%s' "$zc_actual_sha" | tr 'A-F' 'a-f')"
[ "$zc_actual_sha" = "$zc_expected_sha" ] || zc_fail "checksum verification failed"

mkdir -p "$zc_tmp_dir/extract"
tar -xzf "$zc_archive_path" -C "$zc_tmp_dir/extract" "$zc_package/zc" \
    || zc_fail "release archive does not contain $zc_package/zc"
zc_binary="$zc_tmp_dir/extract/$zc_package/zc"
[ -f "$zc_binary" ] || zc_fail "release binary is not a regular file"
[ ! -L "$zc_binary" ] || zc_fail "release binary must not be a symbolic link"
zc_binary_size="$(wc -c <"$zc_binary" | tr -d ' ')"
if [ "$zc_binary_size" -gt 134217728 ]; then
    zc_fail "release binary exceeds 128 MiB"
fi

mkdir -p "$zc_install_dir"
zc_target="$zc_install_dir/zc"
zc_install_dir_physical="$(CDPATH= cd -P "$zc_install_dir" && pwd -P)" \
    || zc_fail "cannot resolve installation directory: $zc_install_dir"
zc_target_physical="$zc_install_dir_physical/zc"
if [ -L "$zc_target" ]; then
    zc_fail "installation target must not be a symbolic link: $zc_target"
fi
if [ -d "$zc_target" ]; then
    zc_fail "installation target is a directory: $zc_target"
fi
zc_lock_candidate="$zc_install_dir/.zc.install.lock"
if ! mkdir "$zc_lock_candidate" 2>/dev/null; then
    zc_lock_owner="$(cat "$zc_lock_candidate/owner" 2>/dev/null || true)"
    zc_fail "another installer holds $zc_lock_candidate (owner: ${zc_lock_owner:-unknown})"
fi
zc_lock_dir="$zc_lock_candidate"
printf '%s\n' "$$" >"$zc_lock_dir/owner" || zc_fail "failed to record installer lock owner"

zc_running_target_pids() {
    if [ -r /proc/self/exe ]; then
        command -v readlink >/dev/null 2>&1 || return 1
        for zc_exe_link in /proc/[0-9]*/exe; do
            if ! zc_executable="$(readlink "$zc_exe_link" 2>/dev/null)"; then
                zc_proc_dir="${zc_exe_link%/exe}"
                zc_comm="$(cat "$zc_proc_dir/comm" 2>/dev/null)" || continue
                [ "$zc_comm" != "zc" ] || return 1
                continue
            fi
            zc_executable="${zc_executable% (deleted)}"
            if [ "$zc_executable" = "$zc_target" ] \
                || [ "$zc_executable" = "$zc_target_physical" ]; then
                zc_pid="${zc_exe_link#/proc/}"
                printf '%s\n' "${zc_pid%%/*}"
            fi
        done
        return 0
    fi

    command -v lsof >/dev/null 2>&1 || return 1
    if ! zc_lsof_output="$(lsof -n -d txt -Fpn 2>/dev/null)"; then
        return 1
    fi
    if ! zc_ps_output="$(ps -ww -axo pid=,comm= 2>/dev/null)"; then
        return 1
    fi
    {
        printf '%s\n' "$zc_ps_output" | awk \
            -v logical="$zc_target" \
            -v physical="$zc_target_physical" '
                {
                    pid = $1
                    sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                    if ($0 == logical || $0 == physical) print pid
                }
            '
        printf '%s\n' "$zc_lsof_output" | awk \
            -v logical="$zc_target" \
            -v physical="$zc_target_physical" '
                /^p/ { pid = substr($0, 2) }
                /^n/ {
                    path = substr($0, 2)
                    sub(/ \(deleted\)$/, "", path)
                    if (path == logical || path == physical) print pid
                }
            '
    } | awk '!seen[$0]++'
}

zc_require_stopped_target() {
    if [ -L "$zc_target" ]; then
        zc_fail "installation target must not be a symbolic link: $zc_target"
    fi
    if [ ! -e "$zc_target" ]; then
        return 0
    fi
    if [ ! -x "$zc_target" ]; then
        zc_fail "existing target is not executable: $zc_target"
    fi
    if ! zc_status="$("$zc_target" status --json 2>/dev/null)"; then
        zc_fail "cannot verify daemon state with existing $zc_target"
    fi
    zc_status_compact="$(printf '%s' "$zc_status" | tr -d '[:space:]')"
    case "$zc_status_compact" in
        *'"state":"stopped"'*) ;;
        *'"state":"running"'*)
            zc_fail "zc is running; stop it before replacing $zc_target"
            ;;
        *) zc_fail "existing zc returned an unknown status contract" ;;
    esac
    if ! zc_target_pids="$(zc_running_target_pids)"; then
        zc_fail "cannot inspect running processes before replacing $zc_target"
    fi
    if [ -n "$zc_target_pids" ]; then
        zc_target_pids_one_line="$(printf '%s' "$zc_target_pids" | tr '\n' ' ')"
        zc_fail "installation target is still running (pid: $zc_target_pids_one_line)"
    fi
}

zc_restore_previous() {
    zc_restore_reason="$1"
    zc_restore_path="$zc_backup_path"
    zc_restore_in_progress=1
    if ! mv -f "$zc_restore_path" "$zc_target"; then
        zc_publish_in_progress=0
        zc_backup_path=""
        zc_restore_in_progress=0
        zc_fail "rollback failed; previous zc remains at $zc_restore_path"
    fi
    zc_publish_in_progress=0
    zc_backup_path=""
    zc_restore_in_progress=0
    zc_fail "$zc_restore_reason"
}

zc_verify_post_publish_processes() {
    if ! zc_target_pids="$(zc_running_target_pids)"; then
        if [ "$zc_had_target" -eq 1 ]; then
            zc_restore_previous \
                "could not inspect processes after publication; restored previous zc"
        fi
        zc_fail "could not inspect processes after publication"
    fi
    if [ -n "$zc_target_pids" ]; then
        zc_target_pids_one_line="$(printf '%s' "$zc_target_pids" | tr '\n' ' ')"
        if [ "$zc_had_target" -eq 1 ]; then
            zc_restore_previous \
                "zc started during installation (pid: $zc_target_pids_one_line); restored previous zc"
        fi
        zc_fail "zc started during installation (pid: $zc_target_pids_one_line)"
    fi
}

zc_require_stopped_target
zc_had_target=0
if [ -e "$zc_target" ]; then
    zc_had_target=1
    zc_backup_path="$(mktemp "$zc_install_dir/.zc.backup.XXXXXX")"
    cp -p "$zc_target" "$zc_backup_path"
fi
zc_stage_path="$(mktemp "$zc_install_dir/.zc.tmp.XXXXXX")"
cp "$zc_binary" "$zc_stage_path"
chmod 755 "$zc_stage_path"
zc_expected_version="zc ${zc_tag#v}"
zc_actual_version="$("$zc_stage_path" --version 2>/dev/null || true)"
[ "$zc_actual_version" = "$zc_expected_version" ] \
    || zc_fail "binary self-check failed: expected '$zc_expected_version'"
zc_require_stopped_target
if [ -L "$zc_target" ]; then
    zc_fail "installation target became a symbolic link: $zc_target"
fi
if [ -d "$zc_target" ]; then
    zc_fail "installation target became a directory: $zc_target"
fi
zc_publish_in_progress=1
mv -f "$zc_stage_path" "$zc_target"
zc_stage_path=""

zc_verify_post_publish_processes

if [ "$zc_had_target" -eq 1 ]; then
    if ! zc_status="$("$zc_target" status --json 2>/dev/null)"; then
        zc_restore_previous \
            "new binary could not verify daemon state; restored previous zc"
    fi
    zc_status_compact="$(printf '%s' "$zc_status" | tr -d '[:space:]')"
    case "$zc_status_compact" in
        *'"state":"stopped"'*) ;;
        *)
            zc_restore_previous \
                "daemon started during installation; restored previous zc"
            ;;
    esac
    zc_verify_post_publish_processes
    zc_publish_in_progress=0
    rm -f "$zc_backup_path"
    zc_backup_path=""
else
    zc_verify_post_publish_processes
    zc_publish_in_progress=0
fi

printf 'Installed %s to %s\n' "$zc_expected_version" "$zc_target"
case ":${PATH:-}:" in
    *":$zc_install_dir:"*) ;;
    *)
        if [ "$zc_default_path_hint" -eq 1 ]; then
            printf '%s\n' 'export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"'
        else
            printf 'Add %s to PATH to run zc directly.\n' "$zc_install_dir"
        fi
        ;;
esac
