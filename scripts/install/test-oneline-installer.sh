#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v cc >/dev/null 2>&1 || {
    echo "TEST_RESULT=FAIL missing cc" >&2
    exit 1
}
real_zc_bin="${1:-}"
port_helper_bin="${2:-}"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/zc-installer-e2e.XXXXXX")"
real_home=""
real_runtime=""
real_daemon_pid=""
signal_installer_pid=""
orphan_target_pid=""

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    if [ -n "$real_home" ] && [ -n "$real_runtime" ] && [ -x "$install_dir/zc" ]; then
        HOME="$real_home" XDG_RUNTIME_DIR="$real_runtime" \
            "$install_dir/zc" stop --json >/dev/null 2>&1 &
        local stop_process_id=$!
        local attempt=0
        while [ "$attempt" -lt 140 ]; do
            if ! kill -0 "$stop_process_id" >/dev/null 2>&1; then
                break
            fi
            attempt=$((attempt + 1))
            sleep 0.05
        done
        if kill -0 "$stop_process_id" >/dev/null 2>&1; then
            kill -9 "$stop_process_id" >/dev/null 2>&1 || true
        fi
        wait "$stop_process_id" >/dev/null 2>&1 || true
    fi
    if [ -n "$orphan_target_pid" ]; then
        kill -9 "$orphan_target_pid" >/dev/null 2>&1 || true
        wait "$orphan_target_pid" >/dev/null 2>&1 || true
    fi
    if [ -n "$signal_installer_pid" ]; then
        kill -9 "$signal_installer_pid" >/dev/null 2>&1 || true
        wait "$signal_installer_pid" >/dev/null 2>&1 || true
    fi
    if [ -n "$real_daemon_pid" ]; then
        if kill -0 "$real_daemon_pid" >/dev/null 2>&1; then
            kill -9 "$real_daemon_pid" >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$work_root"
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

version="v9.8.7"
release_root="$work_root/releases"
release_dir="$release_root/$version"
install_dir="$work_root/install"
package_name=""

case "$(uname -s)" in
    Linux) package_os="linux" ;;
    Darwin) package_os="macos" ;;
    *)
        echo "TEST_RESULT=FAIL unsupported host OS" >&2
        exit 1
        ;;
esac

case "$(uname -m)" in
    x86_64 | amd64) package_arch="amd64" ;;
    arm64 | aarch64) package_arch="arm64" ;;
    *)
        echo "TEST_RESULT=FAIL unsupported host architecture" >&2
        exit 1
        ;;
esac

package_name="zc-${version}-${package_os}-${package_arch}"
archive_name="${package_name}.tar.gz"
mkdir -p "$release_dir" "$work_root/package/$package_name" "$install_dir"

write_fixture_binary() {
    local reported_version="$1"
    local reported_state="${2:-stopped}"
    cat >"$work_root/package/$package_name/zc" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then
    echo "zc $reported_version"
    exit 0
fi
if [ "\${1:-}" = "status" ]; then
    echo '{"ok":true,"data":{"state":"$reported_state"}}'
    exit 0
fi
echo "fixture zc"
EOF
    chmod 755 "$work_root/package/$package_name/zc"
}

write_checksum() {
    local archive_path="$release_dir/$archive_name"
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$release_dir" && sha256sum "$archive_name" >"$archive_name.sha256")
    else
        (cd "$release_dir" && shasum -a 256 "$archive_name" >"$archive_name.sha256")
    fi
    test -s "$archive_path.sha256"
}

package_fixture() {
    rm -f "$release_dir/$archive_name" "$release_dir/$archive_name.sha256"
    tar -czf "$release_dir/$archive_name" -C "$work_root/package" "$package_name"
    write_checksum
}

run_installer() {
    ZC_VERSION="$version" \
        ZC_INSTALL_DIR="$install_dir" \
        ZC_RELEASE_BASE_URL="file://$release_root" \
        /bin/sh "$repo_root/install.sh"
}

run_latest_installer_from_stdin() {
    ZC_VERSION=latest \
        ZC_INSTALL_DIR="$install_dir" \
        ZC_RELEASE_BASE_URL="file://$release_root" \
        ZC_RELEASE_FEED_URL="file://$work_root/releases.atom" \
        /bin/sh <"$repo_root/install.sh"
}

write_fixture_binary "${version#v}"
package_fixture

default_home="$work_root/default-home"
default_output="$work_root/default-install.out"
mkdir -p "$default_home"
HOME="$default_home" \
    XDG_BIN_HOME= \
    ZC_INSTALL_DIR= \
    ZC_VERSION="$version" \
    ZC_RELEASE_BASE_URL="file://$release_root" \
    /bin/sh "$repo_root/install.sh" >"$default_output"
test -x "$default_home/.local/bin/zc"
test "$(tail -n 1 "$default_output")" = \
    'export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"'
echo "INSTALLER_DEFAULT_PATH_HINT=PASS"

run_installer

test -x "$install_dir/zc"
test "$("$install_dir/zc" --version)" = "zc ${version#v}"
echo "INSTALLER_EXPLICIT_VERSION=PASS"

spaced_install_dir="$work_root/install with spaces"
ZC_VERSION="$version" \
    ZC_INSTALL_DIR="$spaced_install_dir" \
    ZC_RELEASE_BASE_URL="file://$release_root" \
    /bin/sh "$repo_root/install.sh" >/dev/null
test "$("$spaced_install_dir/zc" --version)" = "zc ${version#v}"
echo "INSTALLER_SPACED_PATH=PASS"

cat >"$work_root/releases.atom" <<EOF
<feed>
  <title>Release notes from zc</title>
  <entry>
    <title>Newest standalone build</title>
    <link rel="alternate" href="https://example.invalid/releases/tag/$version"/>
  </entry>
  <entry>
    <title>v1.2.3</title>
    <link rel="alternate" href="https://example.invalid/releases/tag/v1.2.3"/>
  </entry>
</feed>
EOF
rm -f "$install_dir/zc"
run_latest_installer_from_stdin
test "$("$install_dir/zc" --version)" = "zc ${version#v}"
echo "INSTALLER_LATEST_STDIN=PASS"

real_uname="$(command -v uname)"
mkdir -p "$work_root/fake-bin"
cat >"$work_root/fake-bin/uname" <<EOF
#!/bin/sh
case "\${1:-}" in
    -s) echo "\$FAKE_UNAME_S" ;;
    -m) echo "\$FAKE_UNAME_M" ;;
    *) exec "$real_uname" "\$@" ;;
esac
EOF
chmod 755 "$work_root/fake-bin/uname"
for platform in Linux:x86_64 Linux:aarch64 Darwin:x86_64 Darwin:arm64; do
    platform_os="${platform%%:*}"
    platform_arch="${platform#*:}"
    case "$platform_os" in
        Linux) asset_os="linux" ;;
        Darwin) asset_os="macos" ;;
    esac
    case "$platform_arch" in
        x86_64) asset_arch="amd64" ;;
        aarch64 | arm64) asset_arch="arm64" ;;
    esac
    matrix_package="zc-${version}-${asset_os}-${asset_arch}"
    matrix_archive="${matrix_package}.tar.gz"
    rm -rf "$work_root/matrix-package"
    mkdir -p "$work_root/matrix-package/$matrix_package"
    cp "$work_root/package/$package_name/zc" \
        "$work_root/matrix-package/$matrix_package/zc"
    tar -czf "$release_dir/$matrix_archive" \
        -C "$work_root/matrix-package" "$matrix_package"
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$release_dir" && sha256sum "$matrix_archive" >"$matrix_archive.sha256")
    else
        (cd "$release_dir" && shasum -a 256 "$matrix_archive" >"$matrix_archive.sha256")
    fi
    rm -f "$install_dir/zc"
    PATH="$work_root/fake-bin:$PATH" \
        FAKE_UNAME_S="$platform_os" \
        FAKE_UNAME_M="$platform_arch" \
        ZC_VERSION="$version" \
        ZC_INSTALL_DIR="$install_dir" \
        ZC_RELEASE_BASE_URL="file://$release_root" \
        /bin/sh "$repo_root/install.sh" >/dev/null
    test "$("$install_dir/zc" --version)" = "zc ${version#v}"
done
echo "INSTALLER_PLATFORM_MATRIX=PASS"

if ZC_VERSION=v1.2.3.rc1 \
    ZC_INSTALL_DIR="$install_dir" \
    ZC_RELEASE_BASE_URL="file://$release_root" \
    /bin/sh "$repo_root/install.sh" >/dev/null 2>&1; then
    echo "invalid dot-prerelease version was unexpectedly accepted" >&2
    exit 1
fi
echo "INSTALLER_VERSION_VALIDATION=PASS"

cat >"$install_dir/zc" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "status" ]; then
    echo '{ "ok": true, "data": { "state": "stopped" } }'
    exit 0
fi
echo "zc preserved"
EOF
chmod 755 "$install_dir/zc"
printf 'tampered\n' >>"$release_dir/$archive_name"
if run_installer >/dev/null 2>&1; then
    echo "checksum mismatch unexpectedly installed" >&2
    exit 1
fi
test "$("$install_dir/zc")" = "zc preserved"
echo "INSTALLER_CHECKSUM_FAIL_CLOSED=PASS"

write_fixture_binary "0.0.0-wrong"
package_fixture
if run_installer >/dev/null 2>&1; then
    echo "version mismatch unexpectedly installed" >&2
    exit 1
fi
test "$("$install_dir/zc")" = "zc preserved"
echo "INSTALLER_SELF_CHECK_FAIL_CLOSED=PASS"

write_fixture_binary "${version#v}"
package_fixture
mkdir "$install_dir/.zc.install.lock"
if run_installer >/dev/null 2>&1; then
    echo "concurrent installer lock was unexpectedly ignored" >&2
    exit 1
fi
test -d "$install_dir/.zc.install.lock"
rmdir "$install_dir/.zc.install.lock"
test "$("$install_dir/zc")" = "zc preserved"
echo "INSTALLER_CONCURRENT_LOCK=PASS"

rm -f "$install_dir/zc"
mkdir "$install_dir/zc"
if run_installer >/dev/null 2>&1; then
    echo "directory installation target was unexpectedly accepted" >&2
    exit 1
fi
test -d "$install_dir/zc"
rmdir "$install_dir/zc"
echo "INSTALLER_DIRECTORY_TARGET_FAIL_CLOSED=PASS"

cat >"$work_root/symlink-target" <<'EOF'
#!/bin/sh
echo "zc symlink sentinel"
EOF
chmod 755 "$work_root/symlink-target"
ln -s "$work_root/symlink-target" "$install_dir/zc"
if run_installer >/dev/null 2>&1; then
    echo "symbolic-link installation target was unexpectedly accepted" >&2
    exit 1
fi
test -L "$install_dir/zc"
test "$("$install_dir/zc")" = "zc symlink sentinel"
rm "$install_dir/zc"
echo "INSTALLER_SYMLINK_TARGET_FAIL_CLOSED=PASS"

write_fixture_binary "${version#v}" running
package_fixture
cat >"$install_dir/zc" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    echo "zc previous-race"
    exit 0
fi
if [ "${1:-}" = "status" ]; then
    echo '{"ok":true,"data":{"state":"stopped"}}'
    exit 0
fi
EOF
chmod 755 "$install_dir/zc"
if run_installer >/dev/null 2>&1; then
    echo "daemon start race was unexpectedly accepted" >&2
    exit 1
fi
test "$("$install_dir/zc" --version)" = "zc previous-race"
echo "INSTALLER_START_RACE_ROLLBACK=PASS"

status_marker="$work_root/status-marker"
cat >"$work_root/package/$package_name/zc" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then
    echo "zc ${version#v}"
    exit 0
fi
if [ "\${1:-}" = "status" ]; then
    : >"\$ZC_TEST_STATUS_MARKER"
    sleep 2
    echo '{"ok":true,"data":{"state":"stopped"}}'
    exit 0
fi
EOF
chmod 755 "$work_root/package/$package_name/zc"
package_fixture
cat >"$install_dir/zc" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    echo "zc previous-signal"
    exit 0
fi
if [ "${1:-}" = "status" ]; then
    echo '{"ok":true,"data":{"state":"stopped"}}'
    exit 0
fi
EOF
chmod 755 "$install_dir/zc"
ZC_TEST_STATUS_MARKER="$status_marker" \
    ZC_VERSION="$version" \
    ZC_INSTALL_DIR="$install_dir" \
    ZC_RELEASE_BASE_URL="file://$release_root" \
    /bin/sh "$repo_root/install.sh" >/dev/null 2>&1 &
signal_installer_pid=$!
status_attempt=0
while [ "$status_attempt" -lt 100 ]; do
    if [ -f "$status_marker" ]; then
        break
    fi
    status_attempt=$((status_attempt + 1))
    sleep 0.05
done
test -f "$status_marker"
kill -TERM "$signal_installer_pid"
if wait "$signal_installer_pid"; then
    echo "interrupted installer unexpectedly succeeded" >&2
    exit 1
fi
signal_installer_pid=""
test "$("$install_dir/zc" --version)" = "zc previous-signal"
for transaction_path in \
    "$install_dir"/.zc.tmp.* \
    "$install_dir"/.zc.backup.* \
    "$install_dir"/.zc.install.lock; do
    if [ -e "$transaction_path" ]; then
        echo "interrupted installer leaked transaction artifact: $transaction_path" >&2
        exit 1
    fi
done
echo "INSTALLER_SIGNAL_ROLLBACK=PASS"

write_fixture_binary "${version#v}"
package_fixture
cat >"$install_dir/zc" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "status" ]; then
    echo '{ "ok": true, "data": { "state": "running" } }'
    exit 0
fi
echo "zc running sentinel"
EOF
chmod 755 "$install_dir/zc"
if run_installer >/dev/null 2>&1; then
    echo "running installation target was unexpectedly replaced" >&2
    exit 1
fi
test "$("$install_dir/zc")" = "zc running sentinel"
echo "INSTALLER_RUNNING_TARGET_FAIL_CLOSED=PASS"

cat >"$work_root/orphan-target.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "status") == 0) {
        puts("{\"ok\":true,\"data\":{\"state\":\"stopped\"}}");
        return 0;
    }
    if (argc > 2 && strcmp(argv[1], "run") == 0) {
        FILE *ready = fopen(argv[2], "w");
        if (ready == NULL) return 2;
        fclose(ready);
        sleep(30);
        return 0;
    }
    puts("zc orphan sentinel");
    return 0;
}
EOF
cc "$work_root/orphan-target.c" -o "$work_root/orphan-target"
cp "$work_root/orphan-target" "$install_dir/zc"
chmod 755 "$install_dir/zc"
orphan_ready="$work_root/orphan-ready"
"$install_dir/zc" run "$orphan_ready" &
orphan_target_pid=$!
orphan_attempt=0
while [ "$orphan_attempt" -lt 100 ]; do
    if [ -f "$orphan_ready" ]; then
        break
    fi
    orphan_attempt=$((orphan_attempt + 1))
    sleep 0.01
done
test -f "$orphan_ready"
if run_installer >/dev/null 2>&1; then
    echo "orphaned installation target was unexpectedly replaced" >&2
    exit 1
fi
if ! kill -0 "$orphan_target_pid" >/dev/null 2>&1; then
    echo "orphaned installation target was terminated" >&2
    exit 1
fi
cmp "$work_root/orphan-target" "$install_dir/zc"
kill "$orphan_target_pid" >/dev/null 2>&1 || true
wait "$orphan_target_pid" >/dev/null 2>&1 || true
orphan_target_pid=""
echo "INSTALLER_ORPHAN_TARGET_FAIL_CLOSED=PASS"

if [ -n "$real_zc_bin" ] && [ -n "$port_helper_bin" ]; then
    real_home="$work_root/real-home"
    real_runtime="$work_root/real-run"
    mkdir -p "$real_home/.config" "$real_runtime"
    chmod 700 "$real_home" "$real_runtime"
    real_home="$(cd "$real_home" && pwd -P)"
    real_runtime="$(cd "$real_runtime" && pwd -P)"
    cp "$real_zc_bin" "$install_dir/zc"
    chmod 755 "$install_dir/zc"
    real_version="$("$install_dir/zc" --version)"
    real_port="$($port_helper_bin reserve-port)"
    cat >"$work_root/real.yaml" <<EOF
mixed-port: $real_port
rules:
  - MATCH,DIRECT
EOF
    HOME="$real_home" XDG_RUNTIME_DIR="$real_runtime" \
        "$install_dir/zc" start -c "$work_root/real.yaml" --json >/dev/null
    real_status="$(HOME="$real_home" XDG_RUNTIME_DIR="$real_runtime" \
        "$install_dir/zc" status --json)"
    real_daemon_pid="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' \
        <<<"$real_status")"
    test -n "$real_daemon_pid"
    if HOME="$real_home" XDG_RUNTIME_DIR="$real_runtime" \
        ZC_VERSION="$version" \
        ZC_INSTALL_DIR="$install_dir" \
        ZC_RELEASE_BASE_URL="file://$release_root" \
        /bin/sh "$repo_root/install.sh" >/dev/null 2>&1; then
        echo "live daemon installation target was unexpectedly replaced" >&2
        exit 1
    fi
    test "$("$install_dir/zc" --version)" = "$real_version"
    HOME="$real_home" XDG_RUNTIME_DIR="$real_runtime" \
        "$install_dir/zc" stop --json >/dev/null
    if kill -0 "$real_daemon_pid" >/dev/null 2>&1; then
        echo "real daemon remained alive after installer refusal test" >&2
        exit 1
    fi
    real_daemon_pid=""
    echo "INSTALLER_REAL_DAEMON_FAIL_CLOSED=PASS"
fi

echo "INSTALLER_E2E_RESULT=PASS"
