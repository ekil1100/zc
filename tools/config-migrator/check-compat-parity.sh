#!/usr/bin/env bash
set -euo pipefail

# Compare declared compatibility rules vs implemented migrator rules.

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
COMPAT_DOC="$ROOT_DIR/docs/compat/mihomo-clash.md"
MIGRATOR_RUN="$ROOT_DIR/tools/config-migrator/run.sh"

if [[ ! -f "$COMPAT_DOC" || ! -f "$MIGRATOR_RUN" ]]; then
  echo "MIGRATOR_COMPAT_PARITY=FAIL"
  echo "MIGRATOR_COMPAT_PARITY_ERROR=missing_input_files"
  exit 1
fi

declared_rules=$(awk '
  /^## Migrator rules$/ { in_section = 1; next }
  in_section && /^## / { in_section = 0 }
  in_section && /^- `[^`]+`$/ {
    line = $0
    sub(/^- `/, "", line)
    sub(/`$/, "", line)
    print line
  }
' "$COMPAT_DOC" | sort -u)
implemented_rules=$( (grep -Eo 'PORT_TYPE_INT|LOG_LEVEL_ENUM|PROXY_GROUP_TYPE_CHECK|DNS_FIELD_CHECK|DNS_NAMESERVER_FORMAT|PROXY_GROUP_EMPTY_PROXIES|TUN_ENABLE_CHECK|EXTERNAL_CONTROLLER_FORMAT|ALLOW_LAN_BIND_CONFLICT|RULE_PROVIDER_REF_CHECK|PROXY_NODE_FIELDS_CHECK|SS_CIPHER_ENUM_CHECK|VMESS_UUID_FORMAT_CHECK|MIXED_PORT_CONFLICT_CHECK|MODE_ENUM_CHECK|PROXY_NAME_UNIQUENESS_CHECK|PORT_RANGE_CHECK|SS_PROTOCOL_CHECK|VMESS_ALTERID_RANGE_CHECK|TROJAN_FIELDS_CHECK|RULES_FORMAT_CHECK|VLESS_FIELDS_CHECK|PROXY_GROUP_REF_CHECK|YAML_SYNTAX_CHECK|SUBSCRIPTION_URL_CHECK|WS_OPTS_FORMAT_CHECK|TLS_SNI_CHECK|UNSUPPORTED_PROXY_TYPE_CHECK|PORT_CONFLICT_CHECK' "$MIGRATOR_RUN" || true) | sort -u )

missing_in_impl=$(comm -23 <(printf '%s
' "$declared_rules") <(printf '%s
' "$implemented_rules") | sed '/^$/d')
undeclared_in_doc=$(comm -13 <(printf '%s
' "$declared_rules") <(printf '%s
' "$implemented_rules") | sed '/^$/d')

if [[ -n "$missing_in_impl" || -n "$undeclared_in_doc" ]]; then
  echo "MIGRATOR_COMPAT_PARITY=FAIL"
  echo "MIGRATOR_COMPAT_MISSING_IN_IMPL=$(echo "$missing_in_impl" | paste -sd, -)"
  echo "MIGRATOR_COMPAT_UNDECLARED_IN_DOC=$(echo "$undeclared_in_doc" | paste -sd, -)"
  exit 1
fi

echo "MIGRATOR_COMPAT_PARITY=PASS"
