#!/usr/bin/env bash
set -euo pipefail

for required_command in cmp curl file tar unzip; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Missing E2E fixture command: $required_command" >&2
        exit 1
    fi
done

cache_root="${1:-.zig-cache/e2e-fixtures}"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/zc-e2e-fixtures.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

ss_version="v1.24.0"
trojan_version="v0.10.6"

case "$(uname -s):$(uname -m)" in
    Linux:x86_64 | Linux:amd64)
        ss_target="x86_64-unknown-linux-musl"
        ss_sha256="0d84f5f350ec99396867d718f146fc3810975b2a7cd06192f158d96bdef460e7"
        trojan_asset="trojan-go-linux-amd64.zip"
        trojan_sha256="764480722783a6d76ed8401f6d2f1d87d8df7e60bf261f69c67eb94b77e732af"
        require_static=1
        ;;
    Linux:arm64 | Linux:aarch64)
        ss_target="aarch64-unknown-linux-musl"
        ss_sha256="e00b6551f40bb2d61adb2503909e0df6550c022372c812f3f34350510797ef2f"
        trojan_asset="trojan-go-linux-armv8.zip"
        trojan_sha256="42e98b97bd0715ee4c5771a953e96c829cfbf81792547ce1d67cc40eb9f35618"
        require_static=1
        ;;
    Darwin:x86_64 | Darwin:amd64)
        ss_target="x86_64-apple-darwin"
        ss_sha256="930ce3301d7408f13a08ea955bdec7afe74993a24ea6c08dcd8a6f4bc74137cb"
        trojan_asset="trojan-go-darwin-amd64.zip"
        trojan_sha256="b51a368e662090bfb23ef5daaf38ad062a51b9761e1badf9760c743a108aa425"
        require_static=0
        ;;
    Darwin:arm64 | Darwin:aarch64)
        ss_target="aarch64-apple-darwin"
        ss_sha256="bbbceeb2d452b19205e23863484bf7c126108c17b678783674e60bfb3d9a7359"
        trojan_asset="trojan-go-darwin-arm64.zip"
        trojan_sha256="908f834db1b24c61a37a1d0937288b0fe24341b7e73e7de00ce4a756e5a50391"
        require_static=0
        ;;
    *)
        echo "Unsupported E2E fixture platform: $(uname -s)/$(uname -m)" >&2
        exit 1
        ;;
esac

ss_asset="shadowsocks-${ss_version}.${ss_target}.tar.xz"
ss_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ss_version}/${ss_asset}"
trojan_url="https://github.com/p4gefau1t/trojan-go/releases/download/${trojan_version}/${trojan_asset}"

sha256_file() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    else
        shasum -a 256 "$path" | awk '{print $1}'
    fi
}

download_fixture() {
    local url="$1"
    local output="$2"
    curl --proto '=https' --tlsv1.2 \
        --retry 3 --retry-all-errors --max-filesize 33554432 \
        --connect-timeout 10 --max-time 180 \
        -fsSL "$url" -o "$output"
    local size_bytes
    size_bytes="$(wc -c <"$output" | tr -d ' ')"
    if [ "$size_bytes" -gt 33554432 ]; then
        echo "Fixture exceeds 32 MiB: $url" >&2
        exit 1
    fi
}

ss_archive="$work_root/$ss_asset"
trojan_archive="$work_root/$trojan_asset"
download_fixture "$ss_url" "$ss_archive"
download_fixture "$trojan_url" "$trojan_archive"

if [ "$(sha256_file "$ss_archive")" != "$ss_sha256" ]; then
    echo "Shadowsocks fixture checksum mismatch" >&2
    exit 1
fi
if [ "$(sha256_file "$trojan_archive")" != "$trojan_sha256" ]; then
    echo "Trojan fixture checksum mismatch" >&2
    exit 1
fi

tar -xJf "$ss_archive" -C "$work_root" ssserver
unzip -p "$trojan_archive" trojan-go >"$work_root/trojan-go"
chmod 755 "$work_root/ssserver" "$work_root/trojan-go"

"$work_root/ssserver" --version >/dev/null
"$work_root/trojan-go" -version >/dev/null

assert_static_fixture() {
    local path="$1"
    local description
    description="$(file "$path")"
    case "$description" in
        *'static-pie linked'* | *'statically linked'*) ;;
        *)
            echo "E2E fixture is not statically linked: $description" >&2
            exit 1
            ;;
    esac
}

if [ "$require_static" -eq 1 ]; then
    assert_static_fixture "$work_root/ssserver"
    assert_static_fixture "$work_root/trojan-go"
fi

mkdir -p "$cache_root"
ss_stage="$(mktemp "$cache_root/.ssserver.XXXXXX")"
trojan_stage="$(mktemp "$cache_root/.trojan-go.XXXXXX")"
cp "$work_root/ssserver" "$ss_stage"
cp "$work_root/trojan-go" "$trojan_stage"
chmod 755 "$ss_stage" "$trojan_stage"

# Compare each staged executable before its atomic publication. The archive
# digests remain the source of trust.
cmp "$work_root/ssserver" "$ss_stage"
cmp "$work_root/trojan-go" "$trojan_stage"
mv -f "$ss_stage" "$cache_root/ssserver"
mv -f "$trojan_stage" "$cache_root/trojan-go"
"$cache_root/ssserver" --version >/dev/null
"$cache_root/trojan-go" -version >/dev/null

echo "E2E_FIXTURES_RESULT=PASS"
echo "E2E_SHADOWSOCKS=$cache_root/ssserver"
echo "E2E_TROJAN=$cache_root/trojan-go"
