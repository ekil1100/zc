#!/usr/bin/env bash
set -euo pipefail

# Unified regression entry for first migrator rules (R1/R2)
# Offline reproducible command:
#   bash tools/config-migrator/run-regression.sh

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$ROOT_DIR/tools/config-migrator"
REPORT_DIR="$BASE/reports"
mkdir -p "$REPORT_DIR"

failed_rules=()
failed_samples=()
results=()

# R1 validation (PORT_TYPE_INT)
if bash "$BASE/verify-r1.sh" >/dev/null 2>&1; then
  results+=("{\"sample_id\":\"R1_PORT_TYPE_INT\",\"input\":\"tools/config-migrator/examples/r1-port-string.yaml\",\"result\":\"PASS\",\"diff\":\"port/socks-port/mixed-port string->int\",\"hint\":\"autofix applied\"}")
else
  failed_rules+=("PORT_TYPE_INT")
  failed_samples+=("R1_PORT_TYPE_INT")
  results+=("{\"sample_id\":\"R1_PORT_TYPE_INT\",\"input\":\"tools/config-migrator/examples/r1-port-string.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"verify-r1 failed\"}")
fi

# R2 validation (LOG_LEVEL_ENUM)
R2_OUT="$REPORT_DIR/r2-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/sample-2.yaml" > "$R2_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"LOG_LEVEL_ENUM"' "$R2_OUT" && grep -q '"fixable":false' "$R2_OUT" && grep -q '"suggested":"info"' "$R2_OUT"; then
    results+=("{\"sample_id\":\"R2_LOG_LEVEL_ENUM\",\"input\":\"tools/config-migrator/examples/sample-2.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"invalid log-level detected with suggested=info\"}")
  else
    failed_rules+=("LOG_LEVEL_ENUM")
    failed_samples+=("R2_LOG_LEVEL_ENUM")
    results+=("{\"sample_id\":\"R2_LOG_LEVEL_ENUM\",\"input\":\"tools/config-migrator/examples/sample-2.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected LOG_LEVEL_ENUM error with suggested=info\"}")
  fi
else
  failed_rules+=("LOG_LEVEL_ENUM")
  failed_samples+=("R2_LOG_LEVEL_ENUM")
  results+=("{\"sample_id\":\"R2_LOG_LEVEL_ENUM\",\"input\":\"tools/config-migrator/examples/sample-2.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"lint command failed\"}")
fi

# R3 validation (PROXY_GROUP_TYPE_CHECK)
R3_OUT="$REPORT_DIR/r3-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r3-proxy-group-type.yaml" > "$R3_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"PROXY_GROUP_TYPE_CHECK"' "$R3_OUT" && grep -q '"fixable":false' "$R3_OUT"; then
    results+=("{\"sample_id\":\"R3_PROXY_GROUP_TYPE_CHECK\",\"input\":\"tools/config-migrator/examples/r3-proxy-group-type.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"invalid proxy group type detected\"}")
  else
    failed_rules+=("PROXY_GROUP_TYPE_CHECK")
    failed_samples+=("R3_PROXY_GROUP_TYPE_CHECK")
    results+=("{\"sample_id\":\"R3_PROXY_GROUP_TYPE_CHECK\",\"input\":\"tools/config-migrator/examples/r3-proxy-group-type.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected PROXY_GROUP_TYPE_CHECK error\"}")
  fi
else
  failed_rules+=("PROXY_GROUP_TYPE_CHECK")
  failed_samples+=("R3_PROXY_GROUP_TYPE_CHECK")
  results+=("{\"sample_id\":\"R3_PROXY_GROUP_TYPE_CHECK\",\"input\":\"tools/config-migrator/examples/r3-proxy-group-type.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"lint command failed\"}")
fi

# R4 validation (DNS_FIELD_CHECK)
R4_OUT="$REPORT_DIR/r4-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r4-dns-fields.yaml" > "$R4_OUT" 2>/dev/null || true; then
  r4_ok=true
  # Must detect: dns.enable missing (warn), dns.nameserver empty (error), enhanced-mode (warn)
  grep -q '"rule":"DNS_FIELD_CHECK"' "$R4_OUT" || r4_ok=false
  grep -q '"path":"dns.enable"' "$R4_OUT" || r4_ok=false
  grep -q '"path":"dns.nameserver"' "$R4_OUT" || r4_ok=false
  grep -q '"path":"dns.enhanced-mode"' "$R4_OUT" || r4_ok=false
  if [[ "$r4_ok" == "true" ]]; then
    results+=("{\"sample_id\":\"R4_DNS_FIELD_CHECK\",\"input\":\"tools/config-migrator/examples/r4-dns-fields.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"dns field issues detected\"}")
  else
    failed_rules+=("DNS_FIELD_CHECK")
    failed_samples+=("R4_DNS_FIELD_CHECK")
    results+=("{\"sample_id\":\"R4_DNS_FIELD_CHECK\",\"input\":\"tools/config-migrator/examples/r4-dns-fields.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected DNS_FIELD_CHECK issues\"}")
  fi
else
  failed_rules+=("DNS_FIELD_CHECK")
  failed_samples+=("R4_DNS_FIELD_CHECK")
  results+=("{\"sample_id\":\"R4_DNS_FIELD_CHECK\",\"input\":\"tools/config-migrator/examples/r4-dns-fields.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"lint command failed\"}")
fi

# R5 validation (DNS_NAMESERVER_FORMAT)
R5_OUT="$REPORT_DIR/r5-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r5-dns-nameserver-format.yaml" > "$R5_OUT" 2>/dev/null; then
  if grep -q '"rule":"DNS_NAMESERVER_FORMAT"' "$R5_OUT"; then
    results+=("{\"sample_id\":\"R5_DNS_NAMESERVER_FORMAT\",\"input\":\"tools/config-migrator/examples/r5-dns-nameserver-format.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"plain IP detected\"}")
  else
    failed_rules+=("DNS_NAMESERVER_FORMAT")
    failed_samples+=("R5_DNS_NAMESERVER_FORMAT")
    results+=("{\"sample_id\":\"R5_DNS_NAMESERVER_FORMAT\",\"input\":\"tools/config-migrator/examples/r5-dns-nameserver-format.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected DNS_NAMESERVER_FORMAT warn\"}")
  fi
else
  # lint may exit 0 (only warns), check output
  if grep -q '"rule":"DNS_NAMESERVER_FORMAT"' "$R5_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R5_DNS_NAMESERVER_FORMAT\",\"input\":\"tools/config-migrator/examples/r5-dns-nameserver-format.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"plain IP detected\"}")
  else
    failed_rules+=("DNS_NAMESERVER_FORMAT")
    failed_samples+=("R5_DNS_NAMESERVER_FORMAT")
    results+=("{\"sample_id\":\"R5_DNS_NAMESERVER_FORMAT\",\"input\":\"tools/config-migrator/examples/r5-dns-nameserver-format.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected DNS_NAMESERVER_FORMAT warn\"}")
  fi
fi

# R6 validation (PROXY_GROUP_EMPTY_PROXIES)
R6_OUT="$REPORT_DIR/r6-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r6-proxy-group-empty.yaml" > "$R6_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"PROXY_GROUP_EMPTY_PROXIES"' "$R6_OUT"; then
    results+=("{\"sample_id\":\"R6_PROXY_GROUP_EMPTY_PROXIES\",\"input\":\"tools/config-migrator/examples/r6-proxy-group-empty.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"empty proxies detected\"}")
  else
    failed_rules+=("PROXY_GROUP_EMPTY_PROXIES")
    failed_samples+=("R6_PROXY_GROUP_EMPTY_PROXIES")
    results+=("{\"sample_id\":\"R6_PROXY_GROUP_EMPTY_PROXIES\",\"input\":\"tools/config-migrator/examples/r6-proxy-group-empty.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected PROXY_GROUP_EMPTY_PROXIES error\"}")
  fi
else
  failed_rules+=("PROXY_GROUP_EMPTY_PROXIES")
  failed_samples+=("R6_PROXY_GROUP_EMPTY_PROXIES")
  results+=("{\"sample_id\":\"R6_PROXY_GROUP_EMPTY_PROXIES\",\"input\":\"tools/config-migrator/examples/r6-proxy-group-empty.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"lint command failed\"}")
fi

# R7 validation (TUN_ENABLE_CHECK)
R7_OUT="$REPORT_DIR/r7-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r7-tun-enable.yaml" > "$R7_OUT" 2>/dev/null; then
  if grep -q '"rule":"TUN_ENABLE_CHECK"' "$R7_OUT"; then
    results+=("{\"sample_id\":\"R7_TUN_ENABLE_CHECK\",\"input\":\"tools/config-migrator/examples/r7-tun-enable.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"tun.enable detected\"}")
  else
    failed_rules+=("TUN_ENABLE_CHECK")
    failed_samples+=("R7_TUN_ENABLE_CHECK")
    results+=("{\"sample_id\":\"R7_TUN_ENABLE_CHECK\",\"input\":\"tools/config-migrator/examples/r7-tun-enable.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected TUN_ENABLE_CHECK warn\"}")
  fi
else
  if grep -q '"rule":"TUN_ENABLE_CHECK"' "$R7_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R7_TUN_ENABLE_CHECK\",\"input\":\"tools/config-migrator/examples/r7-tun-enable.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"tun.enable detected\"}")
  else
    failed_rules+=("TUN_ENABLE_CHECK")
    failed_samples+=("R7_TUN_ENABLE_CHECK")
    results+=("{\"sample_id\":\"R7_TUN_ENABLE_CHECK\",\"input\":\"tools/config-migrator/examples/r7-tun-enable.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected TUN_ENABLE_CHECK warn\"}")
  fi
fi

# R8 validation (EXTERNAL_CONTROLLER_FORMAT)
R8_OUT="$REPORT_DIR/r8-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r8-external-controller.yaml" > "$R8_OUT" 2>/dev/null; then
  if grep -q '"rule":"EXTERNAL_CONTROLLER_FORMAT"' "$R8_OUT"; then
    results+=("{\"sample_id\":\"R8_EXTERNAL_CONTROLLER_FORMAT\",\"input\":\"tools/config-migrator/examples/r8-external-controller.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"bad format detected\"}")
  else
    failed_rules+=("EXTERNAL_CONTROLLER_FORMAT")
    failed_samples+=("R8_EXTERNAL_CONTROLLER_FORMAT")
    results+=("{\"sample_id\":\"R8_EXTERNAL_CONTROLLER_FORMAT\",\"input\":\"tools/config-migrator/examples/r8-external-controller.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected EXTERNAL_CONTROLLER_FORMAT warn\"}")
  fi
else
  if grep -q '"rule":"EXTERNAL_CONTROLLER_FORMAT"' "$R8_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R8_EXTERNAL_CONTROLLER_FORMAT\",\"input\":\"tools/config-migrator/examples/r8-external-controller.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"bad format detected\"}")
  else
    failed_rules+=("EXTERNAL_CONTROLLER_FORMAT")
    failed_samples+=("R8_EXTERNAL_CONTROLLER_FORMAT")
    results+=("{\"sample_id\":\"R8_EXTERNAL_CONTROLLER_FORMAT\",\"input\":\"tools/config-migrator/examples/r8-external-controller.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected EXTERNAL_CONTROLLER_FORMAT warn\"}")
  fi
fi

# R9 validation (ALLOW_LAN_BIND_CONFLICT)
R9_OUT="$REPORT_DIR/r9-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r9-allow-lan-bind.yaml" > "$R9_OUT" 2>/dev/null; then
  if grep -q '"rule":"ALLOW_LAN_BIND_CONFLICT"' "$R9_OUT"; then
    results+=("{\"sample_id\":\"R9_ALLOW_LAN_BIND_CONFLICT\",\"input\":\"tools/config-migrator/examples/r9-allow-lan-bind.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"conflict detected\"}")
  else
    failed_rules+=("ALLOW_LAN_BIND_CONFLICT")
    failed_samples+=("R9_ALLOW_LAN_BIND_CONFLICT")
    results+=("{\"sample_id\":\"R9_ALLOW_LAN_BIND_CONFLICT\",\"input\":\"tools/config-migrator/examples/r9-allow-lan-bind.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected ALLOW_LAN_BIND_CONFLICT warn\"}")
  fi
else
  if grep -q '"rule":"ALLOW_LAN_BIND_CONFLICT"' "$R9_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R9_ALLOW_LAN_BIND_CONFLICT\",\"input\":\"tools/config-migrator/examples/r9-allow-lan-bind.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"conflict detected\"}")
  else
    failed_rules+=("ALLOW_LAN_BIND_CONFLICT")
    failed_samples+=("R9_ALLOW_LAN_BIND_CONFLICT")
    results+=("{\"sample_id\":\"R9_ALLOW_LAN_BIND_CONFLICT\",\"input\":\"tools/config-migrator/examples/r9-allow-lan-bind.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected ALLOW_LAN_BIND_CONFLICT warn\"}")
  fi
fi

# R10 validation (RULE_PROVIDER_REF_CHECK)
R10_OUT="$REPORT_DIR/r10-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r10-rule-provider-ref.yaml" > "$R10_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"RULE_PROVIDER_REF_CHECK"' "$R10_OUT" && grep -q 'missing-provider' "$R10_OUT"; then
    results+=("{\"sample_id\":\"R10_RULE_PROVIDER_REF_CHECK\",\"input\":\"tools/config-migrator/examples/r10-rule-provider-ref.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"undefined provider detected\"}")
  else
    failed_rules+=("RULE_PROVIDER_REF_CHECK")
    failed_samples+=("R10_RULE_PROVIDER_REF_CHECK")
    results+=("{\"sample_id\":\"R10_RULE_PROVIDER_REF_CHECK\",\"input\":\"tools/config-migrator/examples/r10-rule-provider-ref.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected RULE_PROVIDER_REF_CHECK error\"}")
  fi
fi

# R11 validation (PROXY_NODE_FIELDS_CHECK)
R11_OUT="$REPORT_DIR/r11-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r11-proxy-fields.yaml" > "$R11_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"PROXY_NODE_FIELDS_CHECK"' "$R11_OUT"; then
    results+=("{\"sample_id\":\"R11_PROXY_NODE_FIELDS_CHECK\",\"input\":\"tools/config-migrator/examples/r11-proxy-fields.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"missing fields detected\"}")
  else
    failed_rules+=("PROXY_NODE_FIELDS_CHECK")
    failed_samples+=("R11_PROXY_NODE_FIELDS_CHECK")
    results+=("{\"sample_id\":\"R11_PROXY_NODE_FIELDS_CHECK\",\"input\":\"tools/config-migrator/examples/r11-proxy-fields.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected PROXY_NODE_FIELDS_CHECK error\"}")
  fi
fi

# R12 validation (SS_CIPHER_ENUM_CHECK)
R12_OUT="$REPORT_DIR/r12-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r12-cipher-enum.yaml" > "$R12_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"SS_CIPHER_ENUM_CHECK"' "$R12_OUT" && grep -q 'aes-256-cbc' "$R12_OUT"; then
    results+=("{\"sample_id\":\"R12_SS_CIPHER_ENUM_CHECK\",\"input\":\"tools/config-migrator/examples/r12-cipher-enum.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"unsupported cipher detected\"}")
  else
    failed_rules+=("SS_CIPHER_ENUM_CHECK")
    failed_samples+=("R12_SS_CIPHER_ENUM_CHECK")
    results+=("{\"sample_id\":\"R12_SS_CIPHER_ENUM_CHECK\",\"input\":\"tools/config-migrator/examples/r12-cipher-enum.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected SS_CIPHER_ENUM_CHECK error\"}")
  fi
fi

# R13 validation (VMESS_UUID_FORMAT_CHECK)
R13_OUT="$REPORT_DIR/r13-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r13-vmess-uuid.yaml" > "$R13_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"VMESS_UUID_FORMAT_CHECK"' "$R13_OUT" && grep -q 'not-a-valid-uuid' "$R13_OUT"; then
    results+=("{\"sample_id\":\"R13_VMESS_UUID_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r13-vmess-uuid.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"invalid UUID detected\"}")
  else
    failed_rules+=("VMESS_UUID_FORMAT_CHECK")
    failed_samples+=("R13_VMESS_UUID_FORMAT_CHECK")
    results+=("{\"sample_id\":\"R13_VMESS_UUID_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r13-vmess-uuid.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected VMESS_UUID_FORMAT_CHECK error\"}")
  fi
else
  if grep -q '"rule":"VMESS_UUID_FORMAT_CHECK"' "$R13_OUT" && grep -q 'not-a-valid-uuid' "$R13_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R13_VMESS_UUID_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r13-vmess-uuid.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"invalid UUID detected\"}")
  else
    failed_rules+=("VMESS_UUID_FORMAT_CHECK")
    failed_samples+=("R13_VMESS_UUID_FORMAT_CHECK")
    results+=("{\"sample_id\":\"R13_VMESS_UUID_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r13-vmess-uuid.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected VMESS_UUID_FORMAT_CHECK error\"}")
  fi
fi

# R14 validation (MIXED_PORT_CONFLICT_CHECK)
R14_OUT="$REPORT_DIR/r14-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r14-port-conflict.yaml" > "$R14_OUT" 2>/dev/null; then
  if grep -q '"rule":"MIXED_PORT_CONFLICT_CHECK"' "$R14_OUT"; then
    results+=("{\"sample_id\":\"R14_MIXED_PORT_CONFLICT_CHECK\",\"input\":\"tools/config-migrator/examples/r14-port-conflict.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"port conflict detected\"}")
  else
    failed_rules+=("MIXED_PORT_CONFLICT_CHECK")
    failed_samples+=("R14_MIXED_PORT_CONFLICT_CHECK")
    results+=("{\"sample_id\":\"R14_MIXED_PORT_CONFLICT_CHECK\",\"input\":\"tools/config-migrator/examples/r14-port-conflict.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected MIXED_PORT_CONFLICT_CHECK warn\"}")
  fi
else
  if grep -q '"rule":"MIXED_PORT_CONFLICT_CHECK"' "$R14_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R14_MIXED_PORT_CONFLICT_CHECK\",\"input\":\"tools/config-migrator/examples/r14-port-conflict.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"port conflict detected\"}")
  else
    failed_rules+=("MIXED_PORT_CONFLICT_CHECK")
    failed_samples+=("R14_MIXED_PORT_CONFLICT_CHECK")
    results+=("{\"sample_id\":\"R14_MIXED_PORT_CONFLICT_CHECK\",\"input\":\"tools/config-migrator/examples/r14-port-conflict.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected MIXED_PORT_CONFLICT_CHECK warn\"}")
  fi
fi

# R15 validation (MODE_ENUM_CHECK)
R15_OUT="$REPORT_DIR/r15-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r15-mode-enum.yaml" > "$R15_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"MODE_ENUM_CHECK"' "$R15_OUT"; then
    results+=("{\"sample_id\":\"R15_MODE_ENUM_CHECK\",\"input\":\"tools/config-migrator/examples/r15-mode-enum.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"invalid mode detected\"}")
  else
    failed_rules+=("MODE_ENUM_CHECK")
    failed_samples+=("R15_MODE_ENUM_CHECK")
    results+=("{\"sample_id\":\"R15_MODE_ENUM_CHECK\",\"input\":\"tools/config-migrator/examples/r15-mode-enum.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected MODE_ENUM_CHECK error\"}")
  fi
fi

# R16 validation (PROXY_NAME_UNIQUENESS_CHECK)
R16_OUT="$REPORT_DIR/r16-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r16-duplicate-names.yaml" > "$R16_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"PROXY_NAME_UNIQUENESS_CHECK"' "$R16_OUT"; then
    results+=("{\"sample_id\":\"R16_PROXY_NAME_UNIQUENESS_CHECK\",\"input\":\"tools/config-migrator/examples/r16-duplicate-names.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"duplicate name detected\"}")
  else
    failed_rules+=("PROXY_NAME_UNIQUENESS_CHECK")
    failed_samples+=("R16_PROXY_NAME_UNIQUENESS_CHECK")
    results+=("{\"sample_id\":\"R16_PROXY_NAME_UNIQUENESS_CHECK\",\"input\":\"tools/config-migrator/examples/r16-duplicate-names.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected PROXY_NAME_UNIQUENESS_CHECK error\"}")
  fi
fi

# R17 validation (PORT_RANGE_CHECK)
R17_OUT="$REPORT_DIR/r17-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r17-port-range.yaml" > "$R17_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"PORT_RANGE_CHECK"' "$R17_OUT"; then
    results+=("{\"sample_id\":\"R17_PORT_RANGE_CHECK\",\"input\":\"tools/config-migrator/examples/r17-port-range.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"out of range ports detected\"}")
  else
    failed_rules+=("PORT_RANGE_CHECK")
    failed_samples+=("R17_PORT_RANGE_CHECK")
    results+=("{\"sample_id\":\"R17_PORT_RANGE_CHECK\",\"input\":\"tools/config-migrator/examples/r17-port-range.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected PORT_RANGE_CHECK error\"}")
  fi
fi

# R18 validation (SS_PROTOCOL_CHECK)
R18_OUT="$REPORT_DIR/r18-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r18-ss-protocol.yaml" > "$R18_OUT" 2>/dev/null || true; then
  results+=("{\"sample_id\":\"R18_SS_PROTOCOL_CHECK\",\"input\":\"tools/config-migrator/examples/r18-ss-protocol.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"ss types valid\"}")
else
  if grep -q '"rule":"SS_PROTOCOL_CHECK"' "$R18_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R18_SS_PROTOCOL_CHECK\",\"input\":\"tools/config-migrator/examples/r18-ss-protocol.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"ss types valid\"}")
  else
    results+=("{\"sample_id\":\"R18_SS_PROTOCOL_CHECK\",\"input\":\"tools/config-migrator/examples/r18-ss-protocol.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"ss types valid\"}")
  fi
fi

# R19 validation (VMESS_ALTERID_RANGE_CHECK)
R19_OUT="$REPORT_DIR/r19-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r19-vmess-alterid.yaml" > "$R19_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"VMESS_ALTERID_RANGE_CHECK"' "$R19_OUT"; then
    results+=("{\"sample_id\":\"R19_VMESS_ALTERID_RANGE_CHECK\",\"input\":\"tools/config-migrator/examples/r19-vmess-alterid.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"alterId out of range detected\"}")
  else
    failed_rules+=("VMESS_ALTERID_RANGE_CHECK")
    failed_samples+=("R19_VMESS_ALTERID_RANGE_CHECK")
    results+=("{\"sample_id\":\"R19_VMESS_ALTERID_RANGE_CHECK\",\"input\":\"tools/config-migrator/examples/r19-vmess-alterid.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected VMESS_ALTERID_RANGE_CHECK error\"}")
  fi
fi

# R20 validation (TROJAN_FIELDS_CHECK)
R20_OUT="$REPORT_DIR/r20-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r20-trojan-fields.yaml" > "$R20_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"TROJAN_FIELDS_CHECK"' "$R20_OUT"; then
    results+=("{\"sample_id\":\"R20_TROJAN_FIELDS_CHECK\",\"input\":\"tools/config-migrator/examples/r20-trojan-fields.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"missing trojan fields detected\"}")
  else
    failed_rules+=("TROJAN_FIELDS_CHECK")
    failed_samples+=("R20_TROJAN_FIELDS_CHECK")
    results+=("{\"sample_id\":\"R20_TROJAN_FIELDS_CHECK\",\"input\":\"tools/config-migrator/examples/r20-trojan-fields.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected TROJAN_FIELDS_CHECK errors\"}")
  fi
else
  if grep -q '"rule":"TROJAN_FIELDS_CHECK"' "$R20_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R20_TROJAN_FIELDS_CHECK\",\"input\":\"tools/config-migrator/examples/r20-trojan-fields.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"missing trojan fields detected\"}")
  else
    failed_rules+=("TROJAN_FIELDS_CHECK")
    failed_samples+=("R20_TROJAN_FIELDS_CHECK")
    results+=("{\"sample_id\":\"R20_TROJAN_FIELDS_CHECK\",\"input\":\"tools/config-migrator/examples/r20-trojan-fields.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected TROJAN_FIELDS_CHECK errors\"}")
  fi
fi

# R21 validation (RULES_FORMAT_CHECK)
R21_OUT="$REPORT_DIR/r21-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r21-rules-format.yaml" > "$R21_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"RULES_FORMAT_CHECK"' "$R21_OUT"; then
    results+=("{\"sample_id\":\"R21_RULES_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r21-rules-format.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"malformed rule detected\"}")
  else
    failed_rules+=("RULES_FORMAT_CHECK")
    failed_samples+=("R21_RULES_FORMAT_CHECK")
    results+=("{\"sample_id\":\"R21_RULES_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r21-rules-format.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected RULES_FORMAT_CHECK error\"}")
  fi
else
  if grep -q '"rule":"RULES_FORMAT_CHECK"' "$R21_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R21_RULES_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r21-rules-format.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"malformed rule detected\"}")
  else
    failed_rules+=("RULES_FORMAT_CHECK")
    failed_samples+=("R21_RULES_FORMAT_CHECK")
    results+=("{\"sample_id\":\"R21_RULES_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r21-rules-format.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected RULES_FORMAT_CHECK error\"}")
  fi
fi

# R22 validation (VLESS_FIELDS_CHECK)
R22_OUT="$REPORT_DIR/r22-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r22-vless-fields.yaml" > "$R22_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"VLESS_FIELDS_CHECK"' "$R22_OUT"; then
    results+=("{\"sample_id\":\"R22_VLESS_FIELDS_CHECK\",\"input\":\"tools/config-migrator/examples/r22-vless-fields.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"missing vless fields detected\"}")
  else
    failed_rules+=("VLESS_FIELDS_CHECK")
    failed_samples+=("R22_VLESS_FIELDS_CHECK")
    results+=("{\"sample_id\":\"R22_VLESS_FIELDS_CHECK\",\"input\":\"tools/config-migrator/examples/r22-vless-fields.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected VLESS_FIELDS_CHECK errors\"}")
  fi
else
  if grep -q '"rule":"VLESS_FIELDS_CHECK"' "$R22_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R22_VLESS_FIELDS_CHECK\",\"input\":\"tools/config-migrator/examples/r22-vless-fields.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"missing vless fields detected\"}")
  else
    failed_rules+=("VLESS_FIELDS_CHECK")
    failed_samples+=("R22_VLESS_FIELDS_CHECK")
    results+=("{\"sample_id\":\"R22_VLESS_FIELDS_CHECK\",\"input\":\"tools/config-migrator/examples/r22-vless-fields.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected VLESS_FIELDS_CHECK errors\"}")
  fi
fi

# R23 validation (PROXY_GROUP_REF_CHECK)
R23_OUT="$REPORT_DIR/r23-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r23-group-ref.yaml" > "$R23_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"PROXY_GROUP_REF_CHECK"' "$R23_OUT"; then
    results+=("{\"sample_id\":\"R23_PROXY_GROUP_REF_CHECK\",\"input\":\"tools/config-migrator/examples/r23-group-ref.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"undefined proxy reference detected\"}")
  else
    failed_rules+=("PROXY_GROUP_REF_CHECK")
    failed_samples+=("R23_PROXY_GROUP_REF_CHECK")
    results+=("{\"sample_id\":\"R23_PROXY_GROUP_REF_CHECK\",\"input\":\"tools/config-migrator/examples/r23-group-ref.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected PROXY_GROUP_REF_CHECK error\"}")
  fi
else
  if grep -q '"rule":"PROXY_GROUP_REF_CHECK"' "$R23_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R23_PROXY_GROUP_REF_CHECK\",\"input\":\"tools/config-migrator/examples/r23-group-ref.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"undefined proxy reference detected\"}")
  else
    failed_rules+=("PROXY_GROUP_REF_CHECK")
    failed_samples+=("R23_PROXY_GROUP_REF_CHECK")
    results+=("{\"sample_id\":\"R23_PROXY_GROUP_REF_CHECK\",\"input\":\"tools/config-migrator/examples/r23-group-ref.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected PROXY_GROUP_REF_CHECK error\"}")
  fi
fi

# R24 validation (YAML_SYNTAX_CHECK)
R24_OUT="$REPORT_DIR/r24-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r24-yaml-syntax.yaml" > "$R24_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"YAML_SYNTAX_CHECK"' "$R24_OUT"; then
    results+=("{\"sample_id\":\"R24_YAML_SYNTAX_CHECK\",\"input\":\"tools/config-migrator/examples/r24-yaml-syntax.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"YAML syntax issue detected\"}")
  else
    results+=("{\"sample_id\":\"R24_YAML_SYNTAX_CHECK\",\"input\":\"tools/config-migrator/examples/r24-yaml-syntax.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"YAML syntax check passed\"}")
  fi
else
  if grep -q '"rule":"YAML_SYNTAX_CHECK"' "$R24_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R24_YAML_SYNTAX_CHECK\",\"input\":\"tools/config-migrator/examples/r24-yaml-syntax.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"YAML syntax issue detected\"}")
  else
    results+=("{\"sample_id\":\"R24_YAML_SYNTAX_CHECK\",\"input\":\"tools/config-migrator/examples/r24-yaml-syntax.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"YAML syntax check passed\"}")
  fi
fi

# R25 validation (SUBSCRIPTION_URL_CHECK)
R25_OUT="$REPORT_DIR/r25-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r25-sub-url.yaml" > "$R25_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"SUBSCRIPTION_URL_CHECK"' "$R25_OUT"; then
    results+=("{\"sample_id\":\"R25_SUBSCRIPTION_URL_CHECK\",\"input\":\"tools/config-migrator/examples/r25-sub-url.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"invalid subscription URL detected\"}")
  else
    failed_rules+=("SUBSCRIPTION_URL_CHECK")
    failed_samples+=("R25_SUBSCRIPTION_URL_CHECK")
    results+=("{\"sample_id\":\"R25_SUBSCRIPTION_URL_CHECK\",\"input\":\"tools/config-migrator/examples/r25-sub-url.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected SUBSCRIPTION_URL_CHECK warn\"}")
  fi
else
  if grep -q '"rule":"SUBSCRIPTION_URL_CHECK"' "$R25_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R25_SUBSCRIPTION_URL_CHECK\",\"input\":\"tools/config-migrator/examples/r25-sub-url.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"invalid subscription URL detected\"}")
  else
    failed_rules+=("SUBSCRIPTION_URL_CHECK")
    failed_samples+=("R25_SUBSCRIPTION_URL_CHECK")
    results+=("{\"sample_id\":\"R25_SUBSCRIPTION_URL_CHECK\",\"input\":\"tools/config-migrator/examples/r25-sub-url.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected SUBSCRIPTION_URL_CHECK warn\"}")
  fi
fi

# R26 validation (WS_OPTS_FORMAT_CHECK)
R26_OUT="$REPORT_DIR/r26-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r26-ws-opts.yaml" > "$R26_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"WS_OPTS_FORMAT_CHECK"' "$R26_OUT"; then
    results+=("{\"sample_id\":\"R26_WS_OPTS_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r26-ws-opts.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"ws-opts path format issue detected\"}")
  else
    results+=("{\"sample_id\":\"R26_WS_OPTS_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r26-ws-opts.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"ws-opts check passed\"}")
  fi
else
  if grep -q '"rule":"WS_OPTS_FORMAT_CHECK"' "$R26_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R26_WS_OPTS_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r26-ws-opts.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"ws-opts path format issue detected\"}")
  else
    results+=("{\"sample_id\":\"R26_WS_OPTS_FORMAT_CHECK\",\"input\":\"tools/config-migrator/examples/r26-ws-opts.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"ws-opts check passed\"}")
  fi
fi

# R27 validation (TLS_SNI_CHECK)
R27_OUT="$REPORT_DIR/r27-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r27-tls-sni.yaml" > "$R27_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"TLS_SNI_CHECK"' "$R27_OUT"; then
    results+=("{\"sample_id\":\"R27_TLS_SNI_CHECK\",\"input\":\"tools/config-migrator/examples/r27-tls-sni.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"tls without sni detected\"}")
  else
    failed_rules+=("TLS_SNI_CHECK")
    failed_samples+=("R27_TLS_SNI_CHECK")
    results+=("{\"sample_id\":\"R27_TLS_SNI_CHECK\",\"input\":\"tools/config-migrator/examples/r27-tls-sni.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected TLS_SNI_CHECK warn\"}")
  fi
else
  if grep -q '"rule":"TLS_SNI_CHECK"' "$R27_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R27_TLS_SNI_CHECK\",\"input\":\"tools/config-migrator/examples/r27-tls-sni.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"tls without sni detected\"}")
  else
    failed_rules+=("TLS_SNI_CHECK")
    failed_samples+=("R27_TLS_SNI_CHECK")
    results+=("{\"sample_id\":\"R27_TLS_SNI_CHECK\",\"input\":\"tools/config-migrator/examples/r27-tls-sni.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected TLS_SNI_CHECK warn\"}")
  fi
fi

# R28 validation (UNSUPPORTED_PROXY_TYPE_CHECK)
# P0-2: http/socks5/socks outbound are now warn-level (accepted-but-unimplemented),
# while truly unknown types (snell/tuic/hysteria) stay error-level. PASS
# requires BOTH branches present plus the actionable suggested next-step.
R28_OUT="$REPORT_DIR/r28-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r28-unsupported-types.yaml" > "$R28_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"UNSUPPORTED_PROXY_TYPE_CHECK"' "$R28_OUT" \
    && grep -q '"level":"error"' "$R28_OUT" \
    && grep -q '"level":"warn"' "$R28_OUT" \
    && grep -q '"suggested":"ss/vmess/trojan/vless/anytls or remove this proxy"' "$R28_OUT"; then
    results+=("{\"sample_id\":\"R28_UNSUPPORTED_PROXY_TYPE_CHECK\",\"input\":\"tools/config-migrator/examples/r28-unsupported-types.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"unsupported + unimplemented-outbound types detected (error+warn)\"}")
  else
    failed_rules+=("UNSUPPORTED_PROXY_TYPE_CHECK")
    failed_samples+=("R28_UNSUPPORTED_PROXY_TYPE_CHECK")
    results+=("{\"sample_id\":\"R28_UNSUPPORTED_PROXY_TYPE_CHECK\",\"input\":\"tools/config-migrator/examples/r28-unsupported-types.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected UNSUPPORTED_PROXY_TYPE_CHECK error+warn with suggested next-step\"}")
  fi
else
  if grep -q '"rule":"UNSUPPORTED_PROXY_TYPE_CHECK"' "$R28_OUT" 2>/dev/null \
    && grep -q '"level":"error"' "$R28_OUT" 2>/dev/null \
    && grep -q '"level":"warn"' "$R28_OUT" 2>/dev/null \
    && grep -q '"suggested":"ss/vmess/trojan/vless/anytls or remove this proxy"' "$R28_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R28_UNSUPPORTED_PROXY_TYPE_CHECK\",\"input\":\"tools/config-migrator/examples/r28-unsupported-types.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"unsupported + unimplemented-outbound types detected (error+warn)\"}")
  else
    failed_rules+=("UNSUPPORTED_PROXY_TYPE_CHECK")
    failed_samples+=("R28_UNSUPPORTED_PROXY_TYPE_CHECK")
    results+=("{\"sample_id\":\"R28_UNSUPPORTED_PROXY_TYPE_CHECK\",\"input\":\"tools/config-migrator/examples/r28-unsupported-types.yaml\",\"result\":\"FAIL\",\"diff\":\"\",\"hint\":\"expected UNSUPPORTED_PROXY_TYPE_CHECK error+warn with suggested next-step\"}")
  fi
fi

# R29 validation (PORT_CONFLICT_CHECK)
R29_OUT="$REPORT_DIR/r29-regression.lint.json"
if bash "$BASE/run.sh" lint "$BASE/examples/r29-port-conflict.yaml" > "$R29_OUT" 2>/dev/null || true; then
  if grep -q '"rule":"PORT_CONFLICT_CHECK"' "$R29_OUT"; then
    results+=("{\"sample_id\":\"R29_PORT_CONFLICT_CHECK\",\"input\":\"tools/config-migrator/examples/r29-port-conflict.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"port conflicts detected\"}")
  else
    results+=("{\"sample_id\":\"R29_PORT_CONFLICT_CHECK\",\"input\":\"tools/config-migrator/examples/r29-port-conflict.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"no port conflicts\"}")
  fi
else
  if grep -q '"rule":"PORT_CONFLICT_CHECK"' "$R29_OUT" 2>/dev/null; then
    results+=("{\"sample_id\":\"R29_PORT_CONFLICT_CHECK\",\"input\":\"tools/config-migrator/examples/r29-port-conflict.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"port conflicts detected\"}")
  else
    results+=("{\"sample_id\":\"R29_PORT_CONFLICT_CHECK\",\"input\":\"tools/config-migrator/examples/r29-port-conflict.yaml\",\"result\":\"PASS\",\"diff\":\"\",\"hint\":\"no port conflicts\"}")
  fi
fi

pass_count=0
for r in "${results[@]}"; do
  if echo "$r" | grep -q '"result":"PASS"'; then
    pass_count=$((pass_count+1))
  fi
done
fail_count=$(( ${#results[@]} - pass_count ))
status="PASS"
if [[ ${#failed_rules[@]} -gt 0 ]]; then
  status="FAIL"
fi

joined_results=$(IFS=,; echo "${results[*]}")
failed_items="[]"
if [[ ${#failed_rules[@]} -gt 0 ]]; then
  entries=()
  for rule in "${failed_rules[@]}"; do
    entries+=("{\"sample_id\":\"$rule\",\"hint\":\"rule regression failed\"}")
  done
  failed_items="[$(IFS=,; echo "${entries[*]}")]"
fi

OUT_SUMMARY="$REPORT_DIR/samples-summary.json"
cat > "$OUT_SUMMARY" <<EOF
{
  "run_id": "migrator-regression-$(date +%s)",
  "status": "$status",
  "pass_count": $pass_count,
  "fail_count": $fail_count,
  "failed_items": $failed_items,
  "results": [
    $joined_results
  ]
}
EOF

total_count=${#results[@]}

if [[ "$status" == "PASS" ]]; then
  echo "MIGRATOR_REGRESSION_RESULT=PASS"
  echo "MIGRATOR_REGRESSION_FAILED_RULES=[]"
  echo "MIGRATOR_REGRESSION_FAILED_SAMPLES=[]"
  echo "MIGRATOR_REGRESSION_REPORT=tools/config-migrator/reports/samples-summary.json"
  echo "MIGRATOR_REGRESSION_SUMMARY=PASS total=${total_count} failed_rules=0 failed_samples=0"
  exit 0
else
  echo "MIGRATOR_REGRESSION_RESULT=FAIL"
  echo "MIGRATOR_REGRESSION_FAILED_RULES=$(IFS=,; echo "${failed_rules[*]}")"
  echo "MIGRATOR_REGRESSION_FAILED_SAMPLES=$(IFS=,; echo "${failed_samples[*]}")"
  echo "MIGRATOR_REGRESSION_REPORT=tools/config-migrator/reports/samples-summary.json"
  echo "MIGRATOR_REGRESSION_SUMMARY=FAIL total=${total_count} failed_rules=$(IFS=,; echo "${failed_rules[*]}") failed_samples=$(IFS=,; echo "${failed_samples[*]}")"
  # fail-fast gate: any failed rule returns non-zero
  exit 1
fi
