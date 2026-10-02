#!/bin/sh
set -eu

zc_repo="${ZC_REPOSITORY:-ekil1100/zc}"
zc_version="${ZC_VERSION:-latest}"
zc_release_base_url="${ZC_RELEASE_BASE_URL:-https://github.com/$zc_repo/releases/download}"
zc_release_feed_url="${ZC_RELEASE_FEED_URL:-https://github.com/$zc_repo/releases.atom}"
zc_tmp_dir=""
zc_lock_dir=""
zc_child=""
zc_signal=0
zc_checking=0

zc_fail() {
    printf 'zc install: %s\n' "$1" >&2
    exit 1
}

# Keep extracted code and the shell lock alive until Rust has joined command
# cleanup/recovery. Repeated signals request cancellation once, never kill recovery.
zc_interrupt() {
    if [ "$zc_signal" -eq 0 ]; then
        zc_signal="$1"
        zc_forward_signal="$2"
        # Background shells may inherit ignored INT; the preflight supervisor
        # uses TERM for cancellation and has no transaction to recover.
        if [ "$zc_checking" -eq 1 ]; then zc_forward_signal=TERM; fi
        if [ -n "$zc_child" ]; then
            kill -"$zc_forward_signal" "$zc_child" 2>/dev/null || true
        fi
    fi
}
zc_wait() {
    zc_child_status=0
    while :; do
        if wait "$zc_child"; then
            zc_child_status=0
            break
        else
            zc_child_status=$?
        fi
        # wait can return early when the shell's trap runs. Keep joining the
        # same child; a signal handler must not remove files under recovery.
        kill -0 "$zc_child" 2>/dev/null || break
    done
    zc_child=""
}
zc_cleanup() {
    trap '' 1 2 15
    if [ -n "$zc_child" ]; then
        kill -TERM "$zc_child" 2>/dev/null || true
        zc_wait
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
trap 'zc_interrupt 129 TERM' 1
trap 'zc_interrupt 130 INT' 2
trap 'zc_interrupt 143 TERM' 15

# Bash is already required by the embedded publisher. Its job control creates
# private process groups on both Linux and macOS, without GNU timeout/setsid.
# Keep this call in the parent shell: command substitution defers its traps.
zc_check() {
    [ "$zc_signal" -eq 0 ] || exit "$zc_signal"
    zc_checking=1
    /bin/bash -c '
        set -m
        cancelled=0
        worker=""
        timer=""
        trap "cancelled=1" TERM HUP
        cleanup() {
            trap "" TERM HUP INT
            if [ -n "$worker" ]; then kill -KILL -- "-$worker" 2>/dev/null || :; fi
            if [ -n "$timer" ]; then kill -KILL -- "-$timer" 2>/dev/null || :; fi
            if [ -n "$worker" ]; then wait "$worker" 2>/dev/null || :; fi
            if [ -n "$timer" ]; then wait "$timer" 2>/dev/null || :; fi
        }
        trap cleanup EXIT
        "$1" "$2" > "$3" 2>/dev/null &
        worker=$!
        (
            sleep 15
            : > "$4"
            kill -TERM "$$"
        ) &
        timer=$!
        trap "exit 124" TERM HUP
        [ "$cancelled" -eq 0 ] || exit 124
        wait "$worker"
        exit $?
    ' zc-check "$zc_binary" "$1" "$zc_tmp_dir/check-output" "$zc_tmp_dir/check-timeout" 2>/dev/null &
    zc_child=$!
    if [ "$zc_signal" -ne 0 ]; then kill -TERM "$zc_child" 2>/dev/null || true; fi
    zc_wait
    zc_checking=0
    [ "$zc_signal" -eq 0 ] || exit "$zc_signal"
    [ ! -f "$zc_tmp_dir/check-timeout" ] || zc_fail "candidate $1 check timed out after 15 seconds; original installation retained"
    [ "$zc_child_status" -eq 0 ]
}

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
[ -x /bin/bash ] || zc_fail "/bin/bash is required for the embedded publisher"

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
        ;;
    Darwin)
        zc_os="macos"
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

# Inspect the selected member before extraction (including hard links and
# duplicate entries); no helper or other archive member is executed/extracted.
tar -tvzf "$zc_archive_path" "$zc_package/zc" >"$zc_tmp_dir/member" \
    || zc_fail "release archive does not contain $zc_package/zc"
awk 'substr($0, 1, 1) != "-" { bad=1 } END { exit (bad || NR != 1) }' \
    "$zc_tmp_dir/member" || zc_fail "release binary member must be one regular file"

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

chmod 700 "$zc_binary"
zc_expected_version="zc ${zc_tag#v}"
if ! zc_check --version \
    || [ "$(cat "$zc_tmp_dir/check-output")" != "$zc_expected_version" ]; then
    zc_fail "binary self-check failed: expected '$zc_expected_version'"
fi
if ! zc_check --install-check \
    || [ "$(cat "$zc_tmp_dir/check-output")" != "zc-release-install-v1" ]; then
    zc_fail "release lacks the required install contract; original installation retained. Choose ZC_VERSION=<tag> with zc-release-install-v1 support. For an older-version rollback, explicitly stop the owned service/manual instance with its original HOME/runtime, back up complete state, and restore a verified old binary with matching state; see docs/install/README.md (State compatibility and rollback)."
fi
[ "$zc_signal" -eq 0 ] || exit "$zc_signal"
mkdir -p "$zc_install_dir"
zc_target="$zc_install_dir/zc"
zc_lock_candidate="$zc_install_dir/.zc.install.lock"
if ! mkdir "$zc_lock_candidate" 2>/dev/null; then
    zc_lock_owner="$(cat "$zc_lock_candidate/owner" 2>/dev/null || true)"
    zc_fail "another installer holds $zc_lock_candidate (owner: ${zc_lock_owner:-unknown})"
fi
zc_lock_dir="$zc_lock_candidate"
printf '%s\n' "$$" >"$zc_lock_dir/owner" || zc_fail "failed to record installer lock owner"
[ "$zc_signal" -eq 0 ] || exit "$zc_signal"
# Start asynchronously so a signal interrupts wait, rather than deferring the
# shell trap until the transaction finishes. Rust owns all service/publication state.
"$zc_binary" --local-install "$zc_binary" "$zc_install_dir" &
zc_child=$!
# Close the trap/child-assignment race before waiting.
if [ "$zc_signal" -ne 0 ]; then kill -"$zc_forward_signal" "$zc_child" 2>/dev/null || true; fi
zc_wait
[ "$zc_signal" -eq 0 ] || exit "$zc_signal"
[ "$zc_child_status" -eq 0 ] || zc_fail "candidate installation failed; inspect the recovery result above before retrying"

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
