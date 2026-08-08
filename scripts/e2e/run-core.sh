#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "usage: run-core.sh <zc> <origin> <obfs-oracle> <ss-udp-oracle> <fixture-dir> <testdata-dir>" >&2
    exit 2
fi

zc_bin="$1"
origin_bin="$2"
obfs_oracle_bin="$3"
ss_udp_oracle_bin="$4"
fixture_dir="$5"
testdata_dir="$6"
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
ss_udp_oracle_logs=()
ss_udp_oracle_ids=()
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
        if [ "$candidate" != "7899" ] && \
            ! grep -qx "$candidate" "$reserved_port_file" 2>/dev/null; then
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

wait_for_process_log() {
    local log_path="$1"
    local pattern="$2"
    local process_id="$3"
    local attempt=0
    while [ "$attempt" -lt 100 ]; do
        if ! kill -0 "$process_id" >/dev/null 2>&1; then
            return 1
        fi
        if grep -Eq "$pattern" "$log_path" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    return 1
}

terminate_fixture_attempt() {
    local process_id="$1"
    local attempt=0
    kill "$process_id" >/dev/null 2>&1 || true
    while [ "$attempt" -lt 100 ]; do
        if ! kill -0 "$process_id" >/dev/null 2>&1; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    if kill -0 "$process_id" >/dev/null 2>&1; then
        kill -9 "$process_id" >/dev/null 2>&1 || true
    fi
    wait "$process_id" >/dev/null 2>&1 || true
}

start_ssserver() {
    local cipher="$1"
    local log_path="$2"
    local port_variable="$3"
    local pid_variable="$4"
    local attempt=0
    while [ "$attempt" -lt 20 ]; do
        local port process_id process_index
        port="$(reserve_port)"
        # shadowsocks-rust v1.24.0: -U is TCP_AND_UDP; -u is UDP_ONLY.
        "$ssserver_bin" -U -s "127.0.0.1:$port" -k e2e-password \
            -m "$cipher" -v --log-without-time >"$log_path" 2>&1 &
        process_id=$!
        process_index="${#process_ids[@]}"
        process_ids+=("$process_id")
        if wait_for_process_log \
            "$log_path" 'shadowsocks udp server listening on' \
            "$process_id" && wait_for_tcp "$port" "$process_id"; then
            printf -v "$port_variable" '%s' "$port"
            printf -v "$pid_variable" '%s' "$process_id"
            return 0
        fi
        terminate_fixture_attempt "$process_id"
        unset "process_ids[$process_index]"
        attempt=$((attempt + 1))
    done
    echo "Unable to start dual TCP/UDP shadowsocks-rust fixture" >&2
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

ss_udp_oracle_event_count() {
    local log_path="$1"
    local event_name="$2"
    local endpoint_id="$3"
    local count
    count="$(grep -Ec "^E2E_SS_UDP_ORACLE_${event_name}=${endpoint_id}:" \
        "$log_path" 2>/dev/null || true)"
    printf '%s\n' "${count:-0}"
}

ss_udp_oracle_raw_count() {
    ss_udp_oracle_event_count "$1" RAW "$2"
}

ss_udp_oracle_verified_count() {
    ss_udp_oracle_event_count "$1" VERIFIED "$2"
}

ss_udp_oracle_response_count() {
    ss_udp_oracle_event_count "$1" RESPONSE "$2"
}

ss_udp_oracle_total_raw_count() {
    local total=0
    local index=0
    while [ "$index" -lt "${#ss_udp_oracle_logs[@]}" ]; do
        total=$((total + $(ss_udp_oracle_raw_count \
            "${ss_udp_oracle_logs[$index]}" \
            "${ss_udp_oracle_ids[$index]}")))
        index=$((index + 1))
    done
    printf '%s\n' "$total"
}

echo_packet_count() {
    local log_path="$1"
    local family="$2"
    log_match_count "$log_path" "^E2E_UDP_ECHO_PACKET=${family}:"
}

echo_packet_total_count() {
    printf '%s\n' "$(( \
        $(echo_packet_count "$udp_echo_ipv4_log" ipv4) + \
        $(echo_packet_count "$udp_echo_ipv6_log" ipv6) \
    ))"
}

wait_for_ss_udp_response_count() {
    local log_path="$1"
    local endpoint_id="$2"
    local expected_count="$3"
    local attempt=0
    local current=0
    while [ "$attempt" -lt 100 ]; do
        current="$(ss_udp_oracle_response_count "$log_path" "$endpoint_id")"
        if [ "$current" -eq "$expected_count" ]; then
            return 0
        fi
        if [ "$current" -gt "$expected_count" ]; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    echo "Unexpected Shadowsocks UDP oracle response count: ${endpoint_id} expected=${expected_count} actual=${current}" >&2
    return 1
}

wait_for_echo_total() {
    local expected_count="$1"
    local attempt=0
    local current=0
    while [ "$attempt" -lt 100 ]; do
        current="$(echo_packet_total_count)"
        if [ "$current" -eq "$expected_count" ]; then
            return 0
        fi
        if [ "$current" -gt "$expected_count" ]; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.05
    done
    echo "Unexpected UDP echo count: expected=${expected_count} actual=${current}" >&2
    return 1
}

assert_udp_packet_counts_stable() {
    local expected_oracle_count="$1"
    local expected_echo_count="$2"
    local attempt=0
    local oracle_count echo_count
    while [ "$attempt" -lt 10 ]; do
        sleep 0.05
        oracle_count="$(ss_udp_oracle_total_raw_count)"
        echo_count="$(echo_packet_total_count)"
        if [ "$oracle_count" -ne "$expected_oracle_count" ] || \
            [ "$echo_count" -ne "$expected_echo_count" ]; then
            printf '%s\n' \
                "UDP packet counts changed during quiet period:" \
                "  oracle expected=${expected_oracle_count} actual=${oracle_count}" \
                "  echo expected=${expected_echo_count} actual=${echo_count}" >&2
            return 1
        fi
        attempt=$((attempt + 1))
    done
}

start_ss_udp_oracle() {
    local cipher="$1"
    local mode="$2"
    local endpoint_id="$3"
    local requested_port="$4"
    local log_path="$work_root/ss-udp-oracle-${endpoint_id}.log"
    local error_path="$work_root/ss-udp-oracle-${endpoint_id}.error.log"

    "$ss_udp_oracle_bin" serve "$cipher" e2e-password "$mode" \
        "$endpoint_id" "$requested_port" >"$log_path" 2>"$error_path" &
    last_ss_udp_pid=$!
    process_ids+=("$last_ss_udp_pid")
    wait_for_file "$log_path"
    last_ss_udp_port="$(awk -F: \
        -v id="$endpoint_id" \
        '$1 == "E2E_SS_UDP_ORACLE_READY=" id { print $2 }' \
        "$log_path")"
    test -n "$last_ss_udp_port"
    test "$last_ss_udp_port" != "7899"
    if [ "$requested_port" -ne 0 ]; then
        test "$last_ss_udp_port" = "$requested_port"
    fi
    kill -0 "$last_ss_udp_pid"
    test "$(ss_udp_oracle_raw_count "$log_path" "$endpoint_id")" = "0"
    test "$(ss_udp_oracle_verified_count "$log_path" "$endpoint_id")" = "0"
    test "$(ss_udp_oracle_response_count "$log_path" "$endpoint_id")" = "0"
    ss_udp_oracle_logs+=("$log_path")
    ss_udp_oracle_ids+=("$endpoint_id")
    last_ss_udp_log="$log_path"
}

assert_ss_udp_response_sequence() {
    local log_path="$1"
    local endpoint_id="$2"
    local first_marker="$3"
    local first_line normal_line
    first_line="$(grep -n \
        "^E2E_SS_UDP_ORACLE_RESPONSE=${endpoint_id}:1:${first_marker}$" \
        "$log_path" | cut -d: -f1)"
    normal_line="$(grep -n \
        "^E2E_SS_UDP_ORACLE_RESPONSE=${endpoint_id}:2:NORMAL$" \
        "$log_path" | cut -d: -f1)"
    test -n "$first_line"
    test -n "$normal_line"
    test "$first_line" -lt "$normal_line"
}

probe_ss_udp_oracle() {
    local expected_delta="$1"
    local log_path="$2"
    local endpoint_id="$3"
    shift 3
    local raw_before verified_before response_before output
    raw_before="$(ss_udp_oracle_raw_count "$log_path" "$endpoint_id")"
    verified_before="$(ss_udp_oracle_verified_count "$log_path" "$endpoint_id")"
    response_before="$(ss_udp_oracle_response_count "$log_path" "$endpoint_id")"
    expected_ss_udp_oracle_raw_total=$((
        expected_ss_udp_oracle_raw_total + expected_delta
    ))
    output="$("$ss_udp_oracle_bin" probe "$@")"
    grep -q '^E2E_SS_UDP_PROBE_PASS=' <<<"$output"
    wait_for_ss_udp_response_count \
        "$log_path" "$endpoint_id" "$((response_before + expected_delta))"
    test "$(ss_udp_oracle_raw_count "$log_path" "$endpoint_id")" = \
        "$((raw_before + expected_delta))"
    test "$(ss_udp_oracle_verified_count "$log_path" "$endpoint_id")" = \
        "$((verified_before + expected_delta))"
    test "$(ss_udp_oracle_response_count "$log_path" "$endpoint_id")" = \
        "$((response_before + expected_delta))"
    assert_udp_packet_counts_stable \
        "$expected_ss_udp_oracle_raw_total" \
        "$expected_udp_echo_packet_total"
}

probe_ss_udp_no_oracle_or_echo() {
    local output
    output="$("$ss_udp_oracle_bin" probe "$@")"
    grep -q '^E2E_SS_UDP_PROBE_PASS=' <<<"$output"
    assert_udp_packet_counts_stable \
        "$expected_ss_udp_oracle_raw_total" \
        "$expected_udp_echo_packet_total"
}

probe_ss_udp_rust() {
    local family="$1"
    local fixture_log="$2"
    shift 2
    local ipv4_before ipv6_before fixture_before output
    ipv4_before="$(echo_packet_count "$udp_echo_ipv4_log" ipv4)"
    ipv6_before="$(echo_packet_count "$udp_echo_ipv6_log" ipv6)"
    fixture_before="$(log_match_count \
        "$fixture_log" 'created udp association for')"
    expected_udp_echo_packet_total=$((expected_udp_echo_packet_total + 1))
    output="$("$ss_udp_oracle_bin" probe "$@")"
    grep -q '^E2E_SS_UDP_PROBE_PASS=' <<<"$output"
    wait_for_echo_total "$expected_udp_echo_packet_total"
    wait_for_log_growth "$fixture_log" 'created udp association for' \
        "$fixture_before" "shadowsocks-rust UDP association"
    test "$(log_match_count \
        "$fixture_log" 'created udp association for')" = \
        "$((fixture_before + 1))"
    assert_udp_packet_counts_stable \
        "$expected_ss_udp_oracle_raw_total" \
        "$expected_udp_echo_packet_total"
    case "$family" in
        ipv4)
            test "$(echo_packet_count "$udp_echo_ipv4_log" ipv4)" = \
                "$((ipv4_before + 1))"
            test "$(echo_packet_count "$udp_echo_ipv6_log" ipv6)" = \
                "$ipv6_before"
            ;;
        ipv6)
            test "$(echo_packet_count "$udp_echo_ipv4_log" ipv4)" = \
                "$ipv4_before"
            test "$(echo_packet_count "$udp_echo_ipv6_log" ipv6)" = \
                "$((ipv6_before + 1))"
            ;;
        either) ;;
        *) return 2 ;;
    esac
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
test "$origin_port" != "7899"
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
test "$trojan_fallback_port" != "7899"
printf '%s\n%s\n' "$origin_port" "$trojan_fallback_port" >"$reserved_port_file"

mixed_port="$(reserve_port)"
controller_port="$(reserve_port)"
trojan_port="$(reserve_port)"
negative_obfs_mixed_port="$(reserve_port)"
udp_disabled_mixed_port="$(reserve_port)"

start_ssserver aes-128-gcm "$work_root/ss-aes128.log" \
    ss_aes128_port ss_aes128_pid
start_ssserver aes-256-gcm "$work_root/ss-aes256.log" \
    ss_aes256_port ss_aes256_pid
start_ssserver chacha20-ietf-poly1305 "$work_root/ss-chacha.log" \
    ss_chacha_port ss_chacha_pid

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
test "$obfs_oracle_port" != "7899"
test "$obfs_oracle_local_port" != "7899"
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
for negative_label in \
    tls \
    unknown-plugin \
    unknown-mode \
    missing-options \
    missing-host \
    crlf; do
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

start_ss_udp_oracle aes-128-gcm normal udp-aes128 0
udp_oracle_aes128_port="$last_ss_udp_port"
udp_oracle_aes128_pid="$last_ss_udp_pid"
udp_oracle_aes128_log="$last_ss_udp_log"
start_ss_udp_oracle aes-256-gcm normal udp-aes256 0
udp_oracle_aes256_port="$last_ss_udp_port"
udp_oracle_aes256_pid="$last_ss_udp_pid"
udp_oracle_aes256_log="$last_ss_udp_log"
start_ss_udp_oracle chacha20-ietf-poly1305 normal udp-chacha 0
udp_oracle_chacha_port="$last_ss_udp_port"
udp_oracle_chacha_pid="$last_ss_udp_pid"
udp_oracle_chacha_log="$last_ss_udp_log"
start_ss_udp_oracle aes-128-gcm bad-tag-once udp-bad-tag 0
udp_oracle_bad_tag_port="$last_ss_udp_port"
udp_oracle_bad_tag_pid="$last_ss_udp_pid"
udp_oracle_bad_tag_log="$last_ss_udp_log"
start_ss_udp_oracle aes-128-gcm truncated-salt-once udp-short-salt 0
udp_oracle_short_salt_port="$last_ss_udp_port"
udp_oracle_short_salt_pid="$last_ss_udp_pid"
udp_oracle_short_salt_log="$last_ss_udp_log"
start_ss_udp_oracle aes-128-gcm truncated-tag-once udp-short-tag 0
udp_oracle_short_tag_port="$last_ss_udp_port"
udp_oracle_short_tag_pid="$last_ss_udp_pid"
udp_oracle_short_tag_log="$last_ss_udp_log"
start_ss_udp_oracle aes-128-gcm normal udp-obfs \
    "$obfs_oracle_port"
udp_oracle_obfs_pid="$last_ss_udp_pid"
udp_oracle_obfs_log="$last_ss_udp_log"
start_ss_udp_oracle aes-128-gcm normal udp-obfs-local \
    "$obfs_oracle_local_port"
udp_oracle_obfs_local_pid="$last_ss_udp_pid"
udp_oracle_obfs_local_log="$last_ss_udp_log"

test "$(ss_udp_oracle_total_raw_count)" = "0"

udp_echo_ipv4_log="$work_root/udp-echo-ipv4.log"
udp_echo_ipv4_error_log="$work_root/udp-echo-ipv4.error.log"
"$ss_udp_oracle_bin" echo ipv4 0 \
    >"$udp_echo_ipv4_log" 2>"$udp_echo_ipv4_error_log" &
udp_echo_ipv4_pid=$!
process_ids+=("$udp_echo_ipv4_pid")
wait_for_file "$udp_echo_ipv4_log"
udp_echo_port="$(awk -F: \
    '/^E2E_UDP_ECHO_READY=ipv4:/ { print $2 }' \
    "$udp_echo_ipv4_log")"
test -n "$udp_echo_port"
test "$udp_echo_port" != "0"
test "$udp_echo_port" != "7899"
kill -0 "$udp_echo_ipv4_pid"

udp_echo_ipv6_log="$work_root/udp-echo-ipv6.log"
udp_echo_ipv6_error_log="$work_root/udp-echo-ipv6.error.log"
"$ss_udp_oracle_bin" echo ipv6 "$udp_echo_port" \
    >"$udp_echo_ipv6_log" 2>"$udp_echo_ipv6_error_log" &
udp_echo_ipv6_pid=$!
process_ids+=("$udp_echo_ipv6_pid")
wait_for_file "$udp_echo_ipv6_log"
grep -q "^E2E_UDP_ECHO_READY=ipv6:${udp_echo_port}$" \
    "$udp_echo_ipv6_log"
kill -0 "$udp_echo_ipv6_pid"
test "$(echo_packet_total_count)" = "0"
expected_ss_udp_oracle_raw_total=0
expected_udp_echo_packet_total=0

udp_disabled_config="$config_dir/udp-disabled.yaml"
cat >"$udp_disabled_config" <<EOF
mixed-port: $udp_disabled_mixed_port
proxies:
  - name: ss-no-udp
    type: ss
    server: 127.0.0.1
    port: $ss_aes128_port
    cipher: aes-128-gcm
    password: e2e-password
rules:
  - MATCH,ss-no-udp
EOF
"$zc_bin" start -c "$udp_disabled_config" \
    --port "$udp_disabled_mixed_port" --json \
    >"$work_root/udp-disabled-start.json"
wait_for_daemon
probe_ss_udp_no_oracle_or_echo \
    associate-rejected "$udp_disabled_mixed_port" 7
"$zc_bin" stop --json >"$work_root/udp-disabled-stop.json"
wait_for_tcp_closed "$udp_disabled_mixed_port"
current_daemon_pid=""
test "$(ss_udp_oracle_total_raw_count)" = "0"
echo "E2E_SS_UDP_DISABLED_REP07_NO_ASSOCIATION=PASS"

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
    udp: true
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
    udp: true
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
    udp: true
  - name: ss-aes256
    type: ss
    server: 127.0.0.1
    port: $ss_aes256_port
    cipher: aes-256-gcm
    password: e2e-password
    udp: true
  - name: ss-chacha
    type: ss
    server: 127.0.0.1
    port: $ss_chacha_port
    cipher: chacha20-poly1305
    password: e2e-password
    udp: true
  - name: ss-chacha-ietf
    type: ss
    server: 127.0.0.1
    port: $ss_chacha_port
    cipher: chacha20-ietf-poly1305
    password: e2e-password
    udp: true
  - name: udp-oracle-aes128
    type: ss
    server: 127.0.0.1
    port: $udp_oracle_aes128_port
    cipher: aes-128-gcm
    password: e2e-password
    udp: true
  - name: udp-oracle-aes256
    type: ss
    server: 127.0.0.1
    port: $udp_oracle_aes256_port
    cipher: aes-256-gcm
    password: e2e-password
    udp: true
  - name: udp-oracle-chacha
    type: ss
    server: 127.0.0.1
    port: $udp_oracle_chacha_port
    cipher: chacha20-ietf-poly1305
    password: e2e-password
    udp: true
  - name: udp-oracle-bad-tag
    type: ss
    server: 127.0.0.1
    port: $udp_oracle_bad_tag_port
    cipher: aes-128-gcm
    password: e2e-password
    udp: true
  - name: udp-oracle-short-salt
    type: ss
    server: 127.0.0.1
    port: $udp_oracle_short_salt_port
    cipher: aes-128-gcm
    password: e2e-password
    udp: true
  - name: udp-oracle-short-tag
    type: ss
    server: 127.0.0.1
    port: $udp_oracle_short_tag_port
    cipher: aes-128-gcm
    password: e2e-password
    udp: true
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
      - udp-oracle-aes128
      - udp-oracle-aes256
      - udp-oracle-chacha
      - udp-oracle-bad-tag
      - udp-oracle-short-salt
      - udp-oracle-short-tag
      - ss-wrong-password
      - trojan
      - trojan-wrong-password
rules:
  - DST-PORT,9,DIRECT
  - MATCH,Proxy
EOF

if ! load_json="$($zc_bin config load "$managed_config" --json)"; then
    printf '%s\n' "$load_json" >&2
    exit 1
fi
list_json="$($zc_bin config list --json)"
grep -q '"active":true' <<<"$load_json"
grep -q '"name":"core"' <<<"$list_json"
"$zc_bin" start --port "$mixed_port" --json >"$work_root/managed-start.json"
wait_for_daemon
managed_status="$($zc_bin status --json)"
grep -q '"active_config":"core"' <<<"$managed_status"

select_proxy udp-oracle-bad-tag
probe_ss_udp_oracle 2 "$udp_oracle_bad_tag_log" udp-bad-tag \
    response-drop-recovery "$mixed_port" "$udp_echo_port" bad-tag
assert_ss_udp_response_sequence \
    "$udp_oracle_bad_tag_log" udp-bad-tag BAD_TAG

select_proxy udp-oracle-short-salt
probe_ss_udp_oracle 2 "$udp_oracle_short_salt_log" udp-short-salt \
    response-drop-recovery "$mixed_port" "$udp_echo_port" short-salt
assert_ss_udp_response_sequence \
    "$udp_oracle_short_salt_log" udp-short-salt TRUNCATED_SALT

select_proxy udp-oracle-short-tag
probe_ss_udp_oracle 2 "$udp_oracle_short_tag_log" udp-short-tag \
    response-drop-recovery "$mixed_port" "$udp_echo_port" short-tag
assert_ss_udp_response_sequence \
    "$udp_oracle_short_tag_log" udp-short-tag TRUNCATED_TAG
echo "E2E_SS_UDP_RESPONSE_DROP_RECOVERY=PASS"

for cipher_case in aes128 aes256 chacha; do
    case "$cipher_case" in
        aes128)
            proxy_name=udp-oracle-aes128
            endpoint_id=udp-aes128
            endpoint_log="$udp_oracle_aes128_log"
            cipher_name=aes-128-gcm
            ;;
        aes256)
            proxy_name=udp-oracle-aes256
            endpoint_id=udp-aes256
            endpoint_log="$udp_oracle_aes256_log"
            cipher_name=aes-256-gcm
            ;;
        chacha)
            proxy_name=udp-oracle-chacha
            endpoint_id=udp-chacha
            endpoint_log="$udp_oracle_chacha_log"
            cipher_name=chacha20-ietf-poly1305
            ;;
    esac
    select_proxy "$proxy_name"
    probe_ss_udp_oracle 1 "$endpoint_log" "$endpoint_id" \
        roundtrip "$mixed_port" "$udp_echo_port" "oracle-${cipher_case}-v4"
    probe_ss_udp_oracle 1 "$endpoint_log" "$endpoint_id" \
        roundtrip-domain "$mixed_port" "$udp_echo_port" \
        "oracle-${cipher_case}-domain"
    probe_ss_udp_oracle 1 "$endpoint_log" "$endpoint_id" \
        roundtrip-ipv6 "$mixed_port" "$udp_echo_port" \
        "oracle-${cipher_case}-v6"
    probe_ss_udp_oracle 2 "$endpoint_log" "$endpoint_id" \
        max "$cipher_name" "$mixed_port" "$udp_echo_port" \
        "oracle-${cipher_case}-max"
done
echo "E2E_SS_UDP_INDEPENDENT_THREE_CIPHER_ADDRESS_MAX=PASS"

select_proxy udp-oracle-aes128
for invalid_kind in rsv1 rsv2 frag atyp truncated; do
    probe_ss_udp_oracle 1 "$udp_oracle_aes128_log" udp-aes128 \
        invalid-then-valid "$invalid_kind" "$mixed_port" \
        "$udp_echo_port" "invalid-${invalid_kind}"
done
probe_ss_udp_oracle 2 "$udp_oracle_aes128_log" udp-aes128 \
    source-pin "$mixed_port" "$udp_echo_port" source-pin
probe_ss_udp_oracle 1 "$udp_oracle_aes128_log" udp-aes128 \
    client-ip "$mixed_port" "$udp_echo_port" client-ip
probe_ss_udp_oracle 2 "$udp_oracle_aes128_log" udp-aes128 \
    control-close "$mixed_port" "$udp_echo_port" control-close
echo "E2E_SS_UDP_MALFORMED_PIN_AND_CONTROL_LIFECYCLE=PASS"

select_proxy udp-oracle-aes128
probe_ss_udp_no_oracle_or_echo \
    selection-teardown "$mixed_port" 9 literal-direct
select_proxy DIRECT
probe_ss_udp_no_oracle_or_echo \
    selection-teardown "$mixed_port" "$udp_echo_port" group-direct
select_proxy ss-wrong-password
probe_ss_udp_no_oracle_or_echo \
    selection-teardown "$mixed_port" "$udp_echo_port" non-udp-leaf
select_proxy udp-oracle-aes128
probe_ss_udp_oracle 1 "$udp_oracle_aes128_log" udp-aes128 \
    roundtrip "$mixed_port" "$udp_echo_port" teardown-recovery
echo "E2E_SS_UDP_NO_DIRECT_OR_LEAF_FALLBACK=PASS"

obfs_raw_before="$(obfs_oracle_raw_count \
    "$obfs_oracle_obfs_log" obfs)"
obfs_verified_before="$(obfs_oracle_verified_count \
    "$obfs_oracle_obfs_log" obfs)"
obfs_local_raw_before="$(obfs_oracle_raw_count \
    "$obfs_oracle_local_log" obfs-local)"
obfs_local_verified_before="$(obfs_oracle_verified_count \
    "$obfs_oracle_local_log" obfs-local)"
select_proxy ss-obfs-http
probe_ss_udp_oracle 1 "$udp_oracle_obfs_log" udp-obfs \
    roundtrip "$mixed_port" "$udp_echo_port" udp-obfs
select_proxy ss-obfs-local-http
probe_ss_udp_oracle 1 "$udp_oracle_obfs_local_log" udp-obfs-local \
    roundtrip "$mixed_port" "$udp_echo_port" udp-obfs-local
test "$(obfs_oracle_raw_count "$obfs_oracle_obfs_log" obfs)" = \
    "$obfs_raw_before"
test "$(obfs_oracle_verified_count "$obfs_oracle_obfs_log" obfs)" = \
    "$obfs_verified_before"
test "$(obfs_oracle_raw_count \
    "$obfs_oracle_local_log" obfs-local)" = "$obfs_local_raw_before"
test "$(obfs_oracle_verified_count \
    "$obfs_oracle_local_log" obfs-local)" = "$obfs_local_verified_before"
echo "E2E_SS_UDP_SIMPLE_OBFS_TCP_BYPASS=PASS"

for rust_case in aes128 aes256 chacha; do
    case "$rust_case" in
        aes128)
            proxy_name=ss-aes128
            fixture_log="$work_root/ss-aes128.log"
            ;;
        aes256)
            proxy_name=ss-aes256
            fixture_log="$work_root/ss-aes256.log"
            ;;
        chacha)
            proxy_name=ss-chacha-ietf
            fixture_log="$work_root/ss-chacha.log"
            ;;
    esac
    select_proxy "$proxy_name"
    probe_ss_udp_rust ipv4 "$fixture_log" \
        roundtrip "$mixed_port" "$udp_echo_port" \
        "rust-${rust_case}-v4"
    probe_ss_udp_rust either "$fixture_log" \
        roundtrip-domain "$mixed_port" \
        "$udp_echo_port" "rust-${rust_case}-domain"
    probe_ss_udp_rust ipv6 "$fixture_log" \
        roundtrip-ipv6 "$mixed_port" \
        "$udp_echo_port" "rust-${rust_case}-v6"
done
select_proxy ss-chacha
probe_ss_udp_rust ipv4 "$work_root/ss-chacha.log" \
    roundtrip "$mixed_port" "$udp_echo_port" rust-chacha-alias-v4
echo "E2E_SS_UDP_SHADOWSOCKS_RUST_V1_24_0_THREE_CIPHER=PASS"

select_proxy udp-oracle-aes128
probe_ss_udp_no_oracle_or_echo capacity "$mixed_port"
select_proxy DIRECT
echo "E2E_SS_UDP_CAPACITY_64_PLUS_1_RELEASE=PASS"

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
assert_udp_packet_counts_stable \
    "$expected_ss_udp_oracle_raw_total" \
    "$expected_udp_echo_packet_total"
for service_pid in \
    "$udp_oracle_aes128_pid" \
    "$udp_oracle_aes256_pid" \
    "$udp_oracle_chacha_pid" \
    "$udp_oracle_bad_tag_pid" \
    "$udp_oracle_short_salt_pid" \
    "$udp_oracle_short_tag_pid" \
    "$udp_oracle_obfs_pid" \
    "$udp_oracle_obfs_local_pid" \
    "$udp_echo_ipv4_pid" \
    "$udp_echo_ipv6_pid"; do
    kill -0 "$service_pid"
done
echo "E2E_SS_UDP_TEST_SERVICES_ALIVE=PASS"
echo "E2E_STOP_CLEANUP=PASS"
echo "CORE_E2E_RESULT=PASS"
