#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "usage: run-core.sh <zc> <origin> <obfs-oracle> <fixture-dir> <testdata-dir>" >&2
    exit 2
fi

zc_bin="$1"
origin_bin="$2"
obfs_oracle_bin="$3"
fixture_dir="$4"
testdata_dir="$5"
ssserver_bin="$fixture_dir/ssserver"
trojan_bin="$fixture_dir/trojan-go"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/zc-core-e2e.XXXXXX")"
home_dir="$work_root/home"
runtime_dir="$work_root/run"
config_dir="$work_root/source"
origin_ready="$work_root/origin.ready"
origin_log="$work_root/origin.log"
fallback_ready="$work_root/fallback.ready"
fallback_log="$work_root/fallback.log"
obfs_oracle_obfs_log="$work_root/obfs-oracle-obfs.log"
obfs_oracle_obfs_error_log="$work_root/obfs-oracle-obfs.error.log"
obfs_oracle_local_log="$work_root/obfs-oracle-obfs-local.log"
obfs_oracle_local_error_log="$work_root/obfs-oracle-obfs-local.error.log"
managed_config="$config_dir/core.yaml"
unmanaged_config="$config_dir/unmanaged.yaml"
process_ids=()
current_daemon_pid=""
reserved_port_file="$work_root/reserved-ports"

mkdir -p "$home_dir/.config" "$runtime_dir" "$config_dir"
chmod 700 "$home_dir" "$runtime_dir"
home_dir="$(cd "$home_dir" && pwd -P)"
runtime_dir="$(cd "$runtime_dir" && pwd -P)"

export HOME="$home_dir"
export XDG_CONFIG_HOME="$home_dir/.config"
export XDG_RUNTIME_DIR="$runtime_dir"
export NO_PROXY=''
export no_proxy=''
target_host="127-0-0-1.sslip.io"

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    "$zc_bin" stop --json >/dev/null 2>&1 &
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
    if [ -n "$current_daemon_pid" ]; then
        if kill -0 "$current_daemon_pid" >/dev/null 2>&1; then
            kill -9 "$current_daemon_pid" >/dev/null 2>&1 || true
        fi
    fi

    local process_id
    for process_id in "${process_ids[@]:-}"; do
        kill "$process_id" >/dev/null 2>&1 || true
    done
    attempt=0
    while [ "$attempt" -lt 100 ]; do
        local live_process_found=0
        for process_id in "${process_ids[@]:-}"; do
            if kill -0 "$process_id" >/dev/null 2>&1; then
                live_process_found=1
            fi
        done
        if [ "$live_process_found" -eq 0 ]; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    for process_id in "${process_ids[@]:-}"; do
        if kill -0 "$process_id" >/dev/null 2>&1; then
            kill -9 "$process_id" >/dev/null 2>&1 || true
        fi
        wait "$process_id" >/dev/null 2>&1 || true
    done
    if [ "$exit_code" -ne 0 ]; then
        echo "E2E work directory: $work_root" >&2
        find "$work_root" -maxdepth 2 -type f -print >&2 || true
        local diagnostic_path
        for diagnostic_path in \
            "$work_root"/*.log \
            "$work_root"/*-start.json \
            "$work_root"/*-stop.json \
            "$work_root"/api-*.json \
            "$work_root"/reload-*.json \
            "$work_root"/status.error \
            "$runtime_dir/zc.log"; do
            if [ -f "$diagnostic_path" ]; then
                echo "--- $diagnostic_path" >&2
                tail -n 80 "$diagnostic_path" >&2 || true
            fi
        done
    else
        rm -rf "$work_root"
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

reserve_port() {
    local attempt=0
    local candidate=""
    while [ "$attempt" -lt 20 ]; do
        candidate="$($origin_bin reserve-port)"
        if ! grep -qx "$candidate" "$reserved_port_file" 2>/dev/null; then
            printf '%s\n' "$candidate" >>"$reserved_port_file"
            printf '%s\n' "$candidate"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    echo "Unable to reserve a unique E2E port" >&2
    return 1
}

wait_for_file() {
    local path="$1"
    local attempt=0
    while [ "$attempt" -lt 100 ]; do
        if [ -s "$path" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    echo "Timed out waiting for file: $path" >&2
    return 1
}

wait_for_tcp() {
    local port="$1"
    local process_id="$2"
    local attempt=0
    while [ "$attempt" -lt 100 ]; do
        if ! kill -0 "$process_id" >/dev/null 2>&1; then
            echo "Process $process_id exited before port $port was ready" >&2
            return 1
        fi
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    echo "Timed out waiting for 127.0.0.1:$port" >&2
    return 1
}

wait_for_tcp_closed() {
    local port="$1"
    local attempt=0
    while [ "$attempt" -lt 100 ]; do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    echo "Port remained open after daemon stop: $port" >&2
    return 1
}

wait_for_daemon() {
    local attempt=0
    local status_json=""
    local status_error="$work_root/status.error"
    while [ "$attempt" -lt 100 ]; do
        status_json="$($zc_bin status --json 2>"$status_error" || true)"
        if grep -q '"state":"running"' <<<"$status_json"; then
            current_daemon_pid="$(sed -n \
                's/.*"pid":\([0-9][0-9]*\).*/\1/p' <<<"$status_json")"
            if [ -n "$current_daemon_pid" ]; then
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    echo "Timed out waiting for zc daemon: $status_json" >&2
    cat "$status_error" >&2
    return 1
}

log_match_count() {
    local log_path="$1"
    local pattern="$2"
    local count
    count="$(grep -Ec "$pattern" "$log_path" 2>/dev/null || true)"
    printf '%s\n' "${count:-0}"
}

wait_for_log_growth() {
    local log_path="$1"
    local pattern="$2"
    local previous_count="$3"
    local label="$4"
    local attempt=0
    while [ "$attempt" -lt 100 ]; do
        if [ "$(log_match_count "$log_path" "$pattern")" -gt "$previous_count" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    echo "No fixture attestation for $label" >&2
    return 1
}

obfs_oracle_event_count() {
    local log_path="$1"
    local event_name="$2"
    local endpoint_id="$3"
    local count
    count="$(grep -Ec "^E2E_OBFS_ORACLE_${event_name}=${endpoint_id}:" \
        "$log_path" 2>/dev/null || true)"
    printf '%s\n' "${count:-0}"
}

obfs_oracle_raw_count() {
    obfs_oracle_event_count "$1" RAW_ACCEPTED "$2"
}

obfs_oracle_verified_count() {
    obfs_oracle_event_count "$1" VERIFIED "$2"
}

assert_tcp_closed_now() {
    local port="$1"
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
        exec 3>&- 3<&-
        echo "Unexpected listener on 127.0.0.1:$port" >&2
        return 1
    fi
}

assert_obfs_preflight_rejected() {
    local label="$1"
    local config_path="$2"
    local mixed_port="$3"
    local obfs_raw_before obfs_verified_before local_raw_before local_verified_before
    obfs_raw_before="$(obfs_oracle_raw_count \
        "$obfs_oracle_obfs_log" obfs)"
    obfs_verified_before="$(obfs_oracle_verified_count \
        "$obfs_oracle_obfs_log" obfs)"
    local_raw_before="$(obfs_oracle_raw_count \
        "$obfs_oracle_local_log" obfs-local)"
    local_verified_before="$(obfs_oracle_verified_count \
        "$obfs_oracle_local_log" obfs-local)"
    local output_path="$work_root/obfs-negative-$label.json"
    if "$zc_bin" start -c "$config_path" --port "$mixed_port" --json \
        >"$output_path" 2>&1; then
        echo "Unsupported obfs config unexpectedly started: $label" >&2
        return 1
    fi
    if [ "$label" = "crlf" ]; then
        grep -q '"code":"START_PREFLIGHT_FAILED"' "$output_path"
    else
        grep -q '"code":"CONFIG_CAPABILITY_UNSUPPORTED"' "$output_path"
    fi
    assert_tcp_closed_now "$mixed_port"
    test "$(obfs_oracle_raw_count \
        "$obfs_oracle_obfs_log" obfs)" = "$obfs_raw_before"
    test "$(obfs_oracle_verified_count \
        "$obfs_oracle_obfs_log" obfs)" = "$obfs_verified_before"
    test "$(obfs_oracle_raw_count \
        "$obfs_oracle_local_log" obfs-local)" = "$local_raw_before"
    test "$(obfs_oracle_verified_count \
        "$obfs_oracle_local_log" obfs-local)" = "$local_verified_before"
}

send_obfs_content_length_negative() {
    local endpoint_id="$1"
    local log_path="$2"
    local port="$3"
    local host="$4"
    local declared_length="$5"
    local raw_before verified_before rejected_before
    raw_before="$(obfs_oracle_raw_count "$log_path" "$endpoint_id")"
    verified_before="$(obfs_oracle_verified_count "$log_path" "$endpoint_id")"
    rejected_before="$(log_match_count "$log_path" \
        "^E2E_OBFS_ORACLE_REJECTED=${endpoint_id}:")"
    exec 3<>"/dev/tcp/127.0.0.1/$port"
    printf 'GET / HTTP/1.1\r\nHost: %s:%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\nContent-Length: %s\r\n\r\n' \
        "$host" "$port" "$declared_length" >&3
    exec 3>&- 3<&-
    wait_for_log_growth "$log_path" \
        "^E2E_OBFS_ORACLE_RAW_ACCEPTED=${endpoint_id}:" \
        "$raw_before" "$endpoint_id raw-negative"
    wait_for_log_growth "$log_path" \
        "^E2E_OBFS_ORACLE_REJECTED=${endpoint_id}:" \
        "$rejected_before" "$endpoint_id rejected-negative"
    test "$(obfs_oracle_verified_count \
        "$log_path" "$endpoint_id")" = "$verified_before"
    grep -q "^E2E_OBFS_ORACLE_REJECTED=${endpoint_id}:.*error=ContentLengthMismatch$" \
        "$log_path"
}

origin_request_count() {
    local nonce="$1"
    local count
    count="$(grep -Ec "^E2E_ORIGIN_REQUEST=/${nonce}$" \
        "$origin_ready" 2>/dev/null || true)"
    printf '%s\n' "${count:-0}"
}

assert_origin_absent() {
    local nonce="$1"
    if [ "$(origin_request_count "$nonce")" -ne 0 ]; then
        echo "Forbidden request reached origin: $nonce" >&2
        return 1
    fi
}

wait_for_origin_request() {
    local nonce="$1"
    local previous_count="$2"
    local attempt=0
    while [ "$attempt" -lt 100 ]; do
        if [ "$(origin_request_count "$nonce")" -gt "$previous_count" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    echo "Origin did not attest request nonce: $nonce" >&2
    return 1
}

select_proxy() {
    local proxy_name="$1"
    local selection_json
    selection_json="$($zc_bin proxy select -g Proxy -p "$proxy_name" --json)"
    grep -q '"applied":true' <<<"$selection_json"
}

probe_http_success() {
    local mixed_port="$1"
    local origin_port="$2"
    local nonce="$3"
    local origin_count
    origin_count="$(origin_request_count "$nonce")"
    local response
    response="$(curl --noproxy '' --proxy "http://127.0.0.1:$mixed_port" \
        --connect-timeout 2 --max-time 5 -fsS \
        "http://$target_host:$origin_port/$nonce")"
    test "$response" = "zc-e2e-origin:$nonce"
    wait_for_origin_request "$nonce" "$origin_count"
}

probe_socks_success() {
    local mixed_port="$1"
    local origin_port="$2"
    local nonce="$3"
    local origin_count
    origin_count="$(origin_request_count "$nonce")"
    local response
    response="$(curl --noproxy '' --socks5-hostname "127.0.0.1:$mixed_port" \
        --connect-timeout 2 --max-time 5 -fsS \
        "http://$target_host:$origin_port/$nonce")"
    test "$response" = "zc-e2e-origin:$nonce"
    wait_for_origin_request "$nonce" "$origin_count"
}

probe_connect_success() {
    local mixed_port="$1"
    local origin_port="$2"
    local nonce="$3"
    local origin_count
    origin_count="$(origin_request_count "$nonce")"
    local response
    response="$(curl --noproxy '' --proxytunnel \
        --proxy "http://127.0.0.1:$mixed_port" \
        --connect-timeout 2 --max-time 5 -fsS \
        "http://$target_host:$origin_port/$nonce")"
    test "$response" = "zc-e2e-origin:$nonce"
    wait_for_origin_request "$nonce" "$origin_count"
}

probe_http_failure() {
    local mixed_port="$1"
    local origin_port="$2"
    local nonce="$3"
    local origin_count
    origin_count="$(origin_request_count "$nonce")"
    if curl --noproxy '' --proxy "http://127.0.0.1:$mixed_port" \
        --connect-timeout 2 --max-time 3 -fsS \
        "http://$target_host:$origin_port/$nonce" >/dev/null 2>&1; then
        echo "Proxy request unexpectedly succeeded" >&2
        return 1
    fi
    test "$(origin_request_count "$nonce")" = "$origin_count"
}

probe_reject_response() {
    local mixed_port="$1"
    local origin_port="$2"
    local nonce="$3"
    local origin_count
    origin_count="$(origin_request_count "$nonce")"
    local status_code
    status_code="$(curl --noproxy '' --proxy "http://127.0.0.1:$mixed_port" \
        --connect-timeout 2 --max-time 3 -sS -o /dev/null -w '%{http_code}' \
        "http://$target_host:$origin_port/$nonce")"
    test "$status_code" = "502"
    test "$(origin_request_count "$nonce")" = "$origin_count"
}

origin_bin="$origin_bin"
"$origin_bin" >"$origin_ready" 2>"$origin_log" &
origin_pid=$!
process_ids+=("$origin_pid")
wait_for_file "$origin_ready"
origin_port="$(awk -F= '/^E2E_ORIGIN_PORT=/ { print $2 }' "$origin_ready")"
test -n "$origin_port"
origin_response="$(curl --noproxy '*' --connect-timeout 2 --max-time 3 -fsS \
    "http://$target_host:$origin_port/origin-preflight")"
test "$origin_response" = "zc-e2e-origin:origin-preflight"
test "$(origin_request_count origin-preflight)" = "1"
"$origin_bin" reject >"$fallback_ready" 2>"$fallback_log" &
fallback_pid=$!
process_ids+=("$fallback_pid")
wait_for_file "$fallback_ready"
trojan_fallback_port="$(awk -F= '/^E2E_ORIGIN_PORT=/ { print $2 }' "$fallback_ready")"
test -n "$trojan_fallback_port"
printf '%s\n%s\n' "$origin_port" "$trojan_fallback_port" >"$reserved_port_file"

mixed_port="$(reserve_port)"
controller_port="$(reserve_port)"
ss_aes128_port="$(reserve_port)"
ss_aes256_port="$(reserve_port)"
ss_chacha_port="$(reserve_port)"
trojan_port="$(reserve_port)"
negative_obfs_mixed_port="$(reserve_port)"

"$ssserver_bin" -s "127.0.0.1:$ss_aes128_port" -k e2e-password \
    -m aes-128-gcm -v --log-without-time >"$work_root/ss-aes128.log" 2>&1 &
ss_aes128_pid=$!
process_ids+=("$ss_aes128_pid")
"$ssserver_bin" -s "127.0.0.1:$ss_aes256_port" -k e2e-password \
    -m aes-256-gcm -v --log-without-time >"$work_root/ss-aes256.log" 2>&1 &
ss_aes256_pid=$!
process_ids+=("$ss_aes256_pid")
"$ssserver_bin" -s "127.0.0.1:$ss_chacha_port" -k e2e-password \
    -m chacha20-ietf-poly1305 -v --log-without-time >"$work_root/ss-chacha.log" 2>&1 &
ss_chacha_pid=$!
process_ids+=("$ss_chacha_pid")

cat >"$work_root/trojan.json" <<EOF
{
  "run_type": "server",
  "local_addr": "127.0.0.1",
  "local_port": $trojan_port,
  "remote_addr": "127.0.0.1",
  "remote_port": $trojan_fallback_port,
  "password": ["e2e-password"],
  "ssl": {
    "cert": "$testdata_dir/trojan-cert.pem",
    "key": "$testdata_dir/trojan-key.pem",
    "sni": "localhost.localdomain"
  },
  "router": {"enabled": false}
}
EOF
"$trojan_bin" -config "$work_root/trojan.json" \
    >"$work_root/trojan.log" 2>&1 &
trojan_pid=$!
process_ids+=("$trojan_pid")

wait_for_tcp "$ss_aes128_port" "$ss_aes128_pid"
wait_for_tcp "$ss_aes256_port" "$ss_aes256_pid"
wait_for_tcp "$ss_chacha_port" "$ss_chacha_pid"
wait_for_tcp "$trojan_port" "$trojan_pid"

obfs_host="obfs-alias.example.test"
obfs_local_host="obfs-local-alias.example.test"
# AES-128-GCM initial body: 16-byte salt + encrypted length (2+16) +
# encrypted domain address (ATYP+LEN+HOST+PORT+16-byte tag).
expected_initial_body_bytes=$((16 + 18 + 1 + 1 + ${#target_host} + 2 + 16))
test "$expected_initial_body_bytes" = "72"

"$obfs_oracle_bin" "$ss_aes128_port" "$obfs_host" \
    "$expected_initial_body_bytes" fragmented_header obfs \
    >"$obfs_oracle_obfs_log" 2>"$obfs_oracle_obfs_error_log" &
obfs_oracle_obfs_pid=$!
process_ids+=("$obfs_oracle_obfs_pid")
"$obfs_oracle_bin" "$ss_aes128_port" "$obfs_local_host" \
    "$expected_initial_body_bytes" same_write_tail obfs-local \
    >"$obfs_oracle_local_log" 2>"$obfs_oracle_local_error_log" &
obfs_oracle_local_pid=$!
process_ids+=("$obfs_oracle_local_pid")
wait_for_file "$obfs_oracle_obfs_log"
wait_for_file "$obfs_oracle_local_log"
obfs_oracle_port="$(awk -F: \
    '/^E2E_OBFS_ORACLE_READY=obfs:/ { print $2 }' \
    "$obfs_oracle_obfs_log")"
obfs_oracle_local_port="$(awk -F: \
    '/^E2E_OBFS_ORACLE_READY=obfs-local:/ { print $2 }' \
    "$obfs_oracle_local_log")"
test -n "$obfs_oracle_port"
test -n "$obfs_oracle_local_port"
test "$obfs_oracle_port" != "$obfs_oracle_local_port"
kill -0 "$obfs_oracle_obfs_pid"
kill -0 "$obfs_oracle_local_pid"
test "$(obfs_oracle_raw_count "$obfs_oracle_obfs_log" obfs)" = "0"
test "$(obfs_oracle_verified_count "$obfs_oracle_obfs_log" obfs)" = "0"
test "$(obfs_oracle_raw_count \
    "$obfs_oracle_local_log" obfs-local)" = "0"
test "$(obfs_oracle_verified_count \
    "$obfs_oracle_local_log" obfs-local)" = "0"

# Exact off-by-one negatives prove that a range-only Content-Length check could
# not satisfy either independently-bound alias oracle.
send_obfs_content_length_negative \
    obfs "$obfs_oracle_obfs_log" "$obfs_oracle_port" "$obfs_host" 71
send_obfs_content_length_negative \
    obfs-local "$obfs_oracle_local_log" "$obfs_oracle_local_port" \
    "$obfs_local_host" 73

cat >"$config_dir/obfs-negative-tls.yaml" <<EOF
mixed-port: $negative_obfs_mixed_port
proxies:
  - name: bad-obfs
    type: ss
    server: 127.0.0.1
    port: $obfs_oracle_port
    cipher: aes-128-gcm
    password: e2e-password
    plugin: obfs
    plugin-opts: { mode: tls, host: $obfs_host }
rules:
  - MATCH,bad-obfs
EOF
cat >"$config_dir/obfs-negative-unknown-plugin.yaml" <<EOF
mixed-port: $negative_obfs_mixed_port
proxies:
  - name: bad-obfs
    type: ss
    server: 127.0.0.1
    port: $obfs_oracle_port
    cipher: aes-128-gcm
    password: e2e-password
    plugin: unknown-plugin
rules:
  - MATCH,bad-obfs
EOF
cat >"$config_dir/obfs-negative-unknown-mode.yaml" <<EOF
mixed-port: $negative_obfs_mixed_port
proxies:
  - name: bad-obfs
    type: ss
    server: 127.0.0.1
    port: $obfs_oracle_port
    cipher: aes-128-gcm
    password: e2e-password
    plugin: obfs-local
    plugin-opts: { mode: quic, host: $obfs_host }
rules:
  - MATCH,bad-obfs
EOF
cat >"$config_dir/obfs-negative-missing-options.yaml" <<EOF
mixed-port: $negative_obfs_mixed_port
proxies:
  - name: bad-obfs
    type: ss
    server: 127.0.0.1
    port: $obfs_oracle_port
    cipher: aes-128-gcm
    password: e2e-password
    plugin: obfs
rules:
  - MATCH,bad-obfs
EOF
cat >"$config_dir/obfs-negative-missing-host.yaml" <<EOF
mixed-port: $negative_obfs_mixed_port
proxies:
  - name: bad-obfs
    type: ss
    server: 127.0.0.1
    port: $obfs_oracle_port
    cipher: aes-128-gcm
    password: e2e-password
    plugin: obfs
    plugin-opts: { mode: http }
rules:
  - MATCH,bad-obfs
EOF
{
    cat <<EOF
mixed-port: $negative_obfs_mixed_port
proxies:
  - name: bad-obfs
    type: ss
    server: 127.0.0.1
    port: $obfs_oracle_port
    cipher: aes-128-gcm
    password: e2e-password
    plugin: obfs
    plugin-opts:
      mode: http
EOF
    printf '      host: "safe\r\nInjected"\n'
    cat <<EOF
rules:
  - MATCH,bad-obfs
EOF
} >"$config_dir/obfs-negative-crlf.yaml"
cat >"$config_dir/obfs-negative-udp.yaml" <<EOF
mixed-port: $negative_obfs_mixed_port
proxies:
  - name: bad-obfs
    type: ss
    server: 127.0.0.1
    port: $obfs_oracle_port
    cipher: aes-128-gcm
    password: e2e-password
    udp: true
rules:
  - MATCH,bad-obfs
EOF

for negative_label in \
    tls \
    unknown-plugin \
    unknown-mode \
    missing-options \
    missing-host \
    crlf \
    udp; do
    assert_obfs_preflight_rejected \
        "$negative_label" \
        "$config_dir/obfs-negative-$negative_label.yaml" \
        "$negative_obfs_mixed_port"
done
test "$(obfs_oracle_raw_count "$obfs_oracle_obfs_log" obfs)" = "1"
test "$(obfs_oracle_verified_count "$obfs_oracle_obfs_log" obfs)" = "0"
test "$(obfs_oracle_raw_count \
    "$obfs_oracle_local_log" obfs-local)" = "1"
test "$(obfs_oracle_verified_count \
    "$obfs_oracle_local_log" obfs-local)" = "0"
test "$(log_match_count "$obfs_oracle_obfs_log" \
    '^E2E_OBFS_ORACLE_REJECTED=obfs:')" = "1"
test "$(log_match_count "$obfs_oracle_local_log" \
    '^E2E_OBFS_ORACLE_REJECTED=obfs-local:')" = "1"
grep -q '"state":"stopped"' <<<"$($zc_bin status --json)"
echo "E2E_OBFS_NEGATIVE_PREFLIGHT=PASS"

cat >"$managed_config" <<EOF
mixed-port: $mixed_port
external-controller: 127.0.0.1:$controller_port
secret: e2e-secret
proxies:
  - name: ss-aes128
    type: ss
    server: 127.0.0.1
    port: $ss_aes128_port
    cipher: aes-128-gcm
    password: e2e-password
  - name: ss-obfs-http
    type: ss
    server: 127.0.0.1
    port: $obfs_oracle_port
    cipher: aes-128-gcm
    password: e2e-password
    plugin: obfs
    plugin-opts:
      mode: http
      host: $obfs_host
  - name: ss-obfs-local-http
    type: ss
    server: 127.0.0.1
    port: $obfs_oracle_local_port
    cipher: aes-128-gcm
    password: e2e-password
    plugin: obfs-local
    plugin_opts:
      mode: http
      host: $obfs_local_host
  - name: ss-aes256
    type: ss
    server: 127.0.0.1
    port: $ss_aes256_port
    cipher: aes-256-gcm
    password: e2e-password
  - name: ss-chacha
    type: ss
    server: 127.0.0.1
    port: $ss_chacha_port
    cipher: chacha20-poly1305
    password: e2e-password
  - name: ss-chacha-ietf
    type: ss
    server: 127.0.0.1
    port: $ss_chacha_port
    cipher: chacha20-ietf-poly1305
    password: e2e-password
  - name: ss-wrong-password
    type: ss
    server: 127.0.0.1
    port: $ss_aes128_port
    cipher: aes-128-gcm
    password: wrong-password
  - name: trojan
    type: trojan
    server: 127.0.0.1
    port: $trojan_port
    password: e2e-password
    sni: localhost.localdomain
    skip-cert-verify: true
  - name: trojan-wrong-password
    type: trojan
    server: 127.0.0.1
    port: $trojan_port
    password: wrong-password
    sni: localhost.localdomain
    skip-cert-verify: true
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - DIRECT
      - REJECT
      - ss-aes128
      - ss-obfs-http
      - ss-obfs-local-http
      - ss-aes256
      - ss-chacha
      - ss-chacha-ietf
      - ss-wrong-password
      - trojan
      - trojan-wrong-password
rules:
  - MATCH,Proxy
EOF

load_json="$($zc_bin config load "$managed_config" --json)"
list_json="$($zc_bin config list --json)"
grep -q '"active":true' <<<"$load_json"
grep -q '"name":"core"' <<<"$list_json"
"$zc_bin" start --port "$mixed_port" --json >"$work_root/managed-start.json"
wait_for_daemon
managed_status="$($zc_bin status --json)"
grep -q '"active_config":"core"' <<<"$managed_status"

select_proxy DIRECT
probe_http_success "$mixed_port" "$origin_port" direct-http
probe_socks_success "$mixed_port" "$origin_port" direct-socks
echo "E2E_DIRECT_AND_MIXED=PASS"

for proxy_name in ss-aes128 ss-aes256 ss-chacha ss-chacha-ietf trojan; do
    case "$proxy_name" in
        ss-aes128) fixture_log="$work_root/ss-aes128.log" ;;
        ss-aes256) fixture_log="$work_root/ss-aes256.log" ;;
        ss-chacha | ss-chacha-ietf) fixture_log="$work_root/ss-chacha.log" ;;
        trojan) fixture_log="$work_root/trojan.log" ;;
    esac
    if [ "$proxy_name" = "trojan" ]; then
        fixture_pattern=" tunneling to ${target_host}:${origin_port} closed"
    else
        fixture_pattern="established tcp tunnel .*${target_host}:${origin_port}"
    fi
    fixture_count="$(log_match_count "$fixture_log" "$fixture_pattern")"
    select_proxy "$proxy_name"
    probe_http_success "$mixed_port" "$origin_port" "http-$proxy_name"
    wait_for_log_growth "$fixture_log" "$fixture_pattern" \
        "$fixture_count" "$proxy_name"
    if [ "$proxy_name" = "ss-aes128" ]; then
        fixture_count="$(log_match_count "$fixture_log" "$fixture_pattern")"
        probe_socks_success "$mixed_port" "$origin_port" socks-ss-aes128
        wait_for_log_growth "$fixture_log" "$fixture_pattern" \
            "$fixture_count" socks-ss-aes128
    fi
    if [ "$proxy_name" = "trojan" ]; then
        fixture_count="$(log_match_count "$fixture_log" "$fixture_pattern")"
        probe_connect_success "$mixed_port" "$origin_port" connect-trojan
        wait_for_log_growth "$fixture_log" "$fixture_pattern" \
            "$fixture_count" connect-trojan
    fi
    echo "E2E_PROXY_${proxy_name}=PASS"
done

obfs_fixture_pattern="established tcp tunnel .*${target_host}:${origin_port}"
for obfs_proxy_name in ss-obfs-http ss-obfs-local-http; do
    if [ "$obfs_proxy_name" = "ss-obfs-http" ]; then
        endpoint_id=obfs
        endpoint_log="$obfs_oracle_obfs_log"
        other_id=obfs-local
        other_log="$obfs_oracle_local_log"
        nonce=socks-ss-obfs-http
    else
        endpoint_id=obfs-local
        endpoint_log="$obfs_oracle_local_log"
        other_id=obfs
        other_log="$obfs_oracle_obfs_log"
        nonce=socks-ss-obfs-local-http
    fi
    raw_before="$(obfs_oracle_raw_count "$endpoint_log" "$endpoint_id")"
    verified_before="$(obfs_oracle_verified_count \
        "$endpoint_log" "$endpoint_id")"
    other_raw_before="$(obfs_oracle_raw_count "$other_log" "$other_id")"
    other_verified_before="$(obfs_oracle_verified_count \
        "$other_log" "$other_id")"
    fixture_count="$(log_match_count "$work_root/ss-aes128.log" \
        "$obfs_fixture_pattern")"

    select_proxy "$obfs_proxy_name"
    probe_socks_success "$mixed_port" "$origin_port" "$nonce"
    wait_for_log_growth "$endpoint_log" \
        "^E2E_OBFS_ORACLE_RAW_ACCEPTED=${endpoint_id}:" \
        "$raw_before" "$obfs_proxy_name raw"
    wait_for_log_growth "$endpoint_log" \
        "^E2E_OBFS_ORACLE_VERIFIED=${endpoint_id}:" \
        "$verified_before" "$obfs_proxy_name verified"
    test "$(obfs_oracle_raw_count \
        "$endpoint_log" "$endpoint_id")" = "$((raw_before + 1))"
    test "$(obfs_oracle_verified_count \
        "$endpoint_log" "$endpoint_id")" = "$((verified_before + 1))"
    test "$(obfs_oracle_raw_count \
        "$other_log" "$other_id")" = "$other_raw_before"
    test "$(obfs_oracle_verified_count \
        "$other_log" "$other_id")" = "$other_verified_before"
    wait_for_log_growth "$work_root/ss-aes128.log" \
        "$obfs_fixture_pattern" "$fixture_count" "$obfs_proxy_name"
done

test "$(obfs_oracle_raw_count "$obfs_oracle_obfs_log" obfs)" = "2"
test "$(obfs_oracle_verified_count "$obfs_oracle_obfs_log" obfs)" = "1"
test "$(obfs_oracle_raw_count \
    "$obfs_oracle_local_log" obfs-local)" = "2"
test "$(obfs_oracle_verified_count \
    "$obfs_oracle_local_log" obfs-local)" = "1"
grep -q "^E2E_OBFS_ORACLE_EXPECTED=obfs:host=${obfs_host}:body=${expected_initial_body_bytes}:mode=fragmented_header$" \
    "$obfs_oracle_obfs_log"
grep -q "^E2E_OBFS_ORACLE_EXPECTED=obfs-local:host=${obfs_local_host}:body=${expected_initial_body_bytes}:mode=same_write_tail$" \
    "$obfs_oracle_local_log"
grep -q "^E2E_OBFS_ORACLE_REQUEST=obfs:GET_HOST_UPGRADE_CONNECTION_KEY_CONTENT_LENGTH_EXACT:${expected_initial_body_bytes}$" \
    "$obfs_oracle_obfs_log"
grep -q "^E2E_OBFS_ORACLE_REQUEST=obfs-local:GET_HOST_UPGRADE_CONNECTION_KEY_CONTENT_LENGTH_EXACT:${expected_initial_body_bytes}$" \
    "$obfs_oracle_local_log"
grep -q '^E2E_OBFS_ORACLE_RESPONSE=obfs:fragmented_header$' \
    "$obfs_oracle_obfs_log"
grep -q '^E2E_OBFS_ORACLE_RESPONSE=obfs-local:same_write_tail$' \
    "$obfs_oracle_local_log"
grep -q '^E2E_OBFS_ORACLE_FORWARD=obfs:RAW_TCP_HALF_CLOSE_PASS$' \
    "$obfs_oracle_obfs_log"
grep -q '^E2E_OBFS_ORACLE_FORWARD=obfs-local:RAW_TCP_HALF_CLOSE_PASS$' \
    "$obfs_oracle_local_log"
test "$(log_match_count "$obfs_oracle_obfs_log" \
    '^E2E_OBFS_ORACLE_REJECTED=obfs:')" = "1"
test "$(log_match_count "$obfs_oracle_local_log" \
    '^E2E_OBFS_ORACLE_REJECTED=obfs-local:')" = "1"
kill -0 "$obfs_oracle_obfs_pid"
kill -0 "$obfs_oracle_local_pid"
echo "E2E_OBFS_ALIASES=INDEPENDENT_ENDPOINT_HOST_RAW_VERIFIED_PASS"
echo "E2E_OBFS_THREE_PARTY_ATTESTATION=ORACLE_SSSERVER_ORIGIN_PASS"

ss_failure_pattern='tcp handshake failed'
ss_failure_count="$(log_match_count "$work_root/ss-aes128.log" "$ss_failure_pattern")"
select_proxy ss-wrong-password
probe_http_failure "$mixed_port" "$origin_port" wrong-ss-password
wait_for_log_growth "$work_root/ss-aes128.log" "$ss_failure_pattern" \
    "$ss_failure_count" ss-wrong-password
assert_origin_absent wrong-ss-password

trojan_failure_pattern='invalid trojan header'
trojan_failure_count="$(log_match_count "$work_root/trojan.log" "$trojan_failure_pattern")"
select_proxy trojan-wrong-password
probe_http_failure "$mixed_port" "$origin_port" wrong-trojan-password
wait_for_log_growth "$work_root/trojan.log" "$trojan_failure_pattern" \
    "$trojan_failure_count" trojan-wrong-password
assert_origin_absent wrong-trojan-password

select_proxy REJECT
probe_reject_response "$mixed_port" "$origin_port" managed-reject
echo "E2E_PROXY_NEGATIVE_PATHS=PASS"

api_version="$(curl --noproxy '*' --max-time 3 -fsS \
    "http://127.0.0.1:$controller_port/version")"
api_proxies="$(curl --noproxy '*' --max-time 3 -fsS \
    "http://127.0.0.1:$controller_port/proxies")"
api_rules="$(curl --noproxy '*' --max-time 3 -fsS \
    "http://127.0.0.1:$controller_port/rules")"
printf '%s\n' "$api_version" >"$work_root/api-version.json"
printf '%s\n' "$api_proxies" >"$work_root/api-proxies.json"
printf '%s\n' "$api_rules" >"$work_root/api-rules.json"
grep -q '"version"' <<<"$api_version"
grep -q '"ss-aes128"' <<<"$api_proxies"
grep -q 'MATCH' <<<"$api_rules"
if grep -Fq 'e2e-password' \
    "$work_root/api-proxies.json" "$work_root/api-rules.json" "$runtime_dir/zc.log"; then
    echo "Credential leaked through API or daemon log" >&2
    exit 1
fi
if grep -Fq 'e2e-secret' \
    "$work_root/api-proxies.json" "$work_root/api-rules.json" "$runtime_dir/zc.log"; then
    echo "Controller secret leaked through API or daemon log" >&2
    exit 1
fi
api_code="$(curl --noproxy '*' --max-time 3 -sS -o /dev/null -w '%{http_code}' \
    -X PUT -H 'Content-Type: application/json' \
    --data '{"name":"DIRECT"}' \
    "http://127.0.0.1:$controller_port/proxies/Proxy")"
test "$api_code" = "401"
echo "E2E_MANAGED_API_AUTH=PASS"

"$zc_bin" stop --json >"$work_root/managed-stop.json"
wait_for_tcp_closed "$mixed_port"
current_daemon_pid=""

cat >"$unmanaged_config" <<EOF
mixed-port: $mixed_port
external-controller: 127.0.0.1:$controller_port
secret: e2e-secret
proxies: []
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - DIRECT
      - REJECT
rules:
  - MATCH,Proxy
EOF
"$zc_bin" start -c "$unmanaged_config" --port "$mixed_port" --json \
    >"$work_root/unmanaged-start.json"
wait_for_daemon

api_code="$(curl --noproxy '*' --max-time 3 -sS -o /dev/null -w '%{http_code}' \
    -X PUT -H 'Authorization: Bearer wrong-secret' \
    -H 'Content-Type: application/json' --data '{"name":"REJECT"}' \
    "http://127.0.0.1:$controller_port/proxies/Proxy")"
test "$api_code" = "401"
probe_http_success "$mixed_port" "$origin_port" wrong-token-still-direct

api_code="$(curl --noproxy '*' --max-time 3 -sS -o /dev/null -w '%{http_code}' \
    -X PUT -H 'Authorization: Bearer e2e-secret' \
    -H 'Content-Type: application/json' --data '{"name":"REJECT"}' \
    "http://127.0.0.1:$controller_port/proxies/Proxy")"
test "$api_code" = "200"
probe_reject_response "$mixed_port" "$origin_port" api-reject
api_code="$(curl --noproxy '*' --max-time 3 -sS -o /dev/null -w '%{http_code}' \
    -X PUT -H 'Authorization: Bearer e2e-secret' \
    -H 'Content-Type: application/json' --data '{"name":"DIRECT"}' \
    "http://127.0.0.1:$controller_port/proxies/Proxy")"
test "$api_code" = "200"
probe_http_success "$mixed_port" "$origin_port" api-direct
echo "E2E_UNMANAGED_API_SELECTION=PASS"

before_reload_status="$($zc_bin status --json)"
before_reload_pid="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' \
    <<<"$before_reload_status")"
test -n "$before_reload_pid"
cat >"$unmanaged_config" <<EOF
mixed-port: $mixed_port
rule-providers:
  unavailable:
    type: http
    behavior: domain
    url: http://127.0.0.1:1/rules.yaml
    path: unavailable.yaml
rules:
  - RULE-SET,unavailable,DIRECT
  - MATCH,REJECT
EOF
if "$zc_bin" reload --json >"$work_root/reload-failure.json" 2>&1; then
    echo "Invalid reload unexpectedly succeeded" >&2
    exit 1
fi
grep -q '"code":"RELOAD_FAILED"' "$work_root/reload-failure.json"
after_reload_status="$($zc_bin status --json)"
after_reload_pid="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' \
    <<<"$after_reload_status")"
test "$after_reload_pid" = "$before_reload_pid"
probe_http_success "$mixed_port" "$origin_port" rollback-still-direct
cat >"$unmanaged_config" <<EOF
mixed-port: $mixed_port
external-controller: 127.0.0.1:$controller_port
secret: e2e-secret
rules:
  - MATCH,REJECT
EOF
"$zc_bin" reload --json >"$work_root/reload-success.json"
wait_for_daemon
probe_reject_response "$mixed_port" "$origin_port" reload-applied-reject
echo "E2E_RELOAD_ROLLBACK=PASS"

final_daemon_pid="$current_daemon_pid"
"$zc_bin" stop --json >"$work_root/unmanaged-stop.json"
wait_for_tcp_closed "$mixed_port"
if kill -0 "$final_daemon_pid" >/dev/null 2>&1; then
    echo "Daemon PID remained alive after stop: $final_daemon_pid" >&2
    exit 1
fi
current_daemon_pid=""
for forbidden_nonce in \
    wrong-ss-password \
    wrong-trojan-password \
    managed-reject \
    api-reject \
    reload-applied-reject; do
    assert_origin_absent "$forbidden_nonce"
done
status_json="$($zc_bin status --json)"
grep -q '"state":"stopped"' <<<"$status_json"
for prepared_path in "$runtime_dir"/zc.prepared.*.yaml; do
    if [ -e "$prepared_path" ]; then
        echo "Prepared snapshot leaked after stop: $prepared_path" >&2
        exit 1
    fi
done
if [ -e "$runtime_dir/zc.daemon.json" ]; then
    echo "Runtime descriptor leaked after stop" >&2
    exit 1
fi
echo "E2E_STOP_CLEANUP=PASS"
echo "CORE_E2E_RESULT=PASS"
