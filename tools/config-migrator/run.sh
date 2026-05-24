#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
INPUT="${2:-}"
OUT="${3:-}"

if [[ "$MODE" != "lint" && "$MODE" != "autofix" ]]; then
  echo '{"ok":false,"error":{"code":"MIGRATOR_MODE_INVALID","message":"mode must be lint|autofix","hint":"use: run.sh lint <file>"}}'
  exit 2
fi

if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
  echo '{"ok":false,"error":{"code":"MIGRATOR_INPUT_MISSING","message":"input file not found","hint":"pass an existing yaml file path"}}'
  exit 2
fi

json_escape() {
  echo "$1" | sed 's/"/\\"/g'
}

_proxy_issues=()

_check_proxy_fields() {
  local block="$1"
  local pname ptype
  pname=$(echo "$block" | grep -oE 'name:[[:space:]]*"?[^"]*"?' | head -1 | sed -E 's/name:[[:space:]]*"?([^"]*)"?/\1/')
  ptype=$(echo "$block" | grep -oE 'type:[[:space:]]*[a-z]+' | head -1 | sed -E 's/type:[[:space:]]*//')

  # Skip direct/reject - no server/port needed
  [[ "$ptype" == "direct" || "$ptype" == "reject" ]] && return

  if [[ -z "$pname" ]]; then
    _proxy_issues+=("{\"rule\":\"PROXY_NODE_FIELDS_CHECK\",\"level\":\"error\",\"path\":\"proxies[?]\",\"message\":\"proxy node missing 'name' field\",\"fixable\":false}")
  fi
  if [[ -n "$ptype" ]] && ! echo "$block" | grep -Eq 'server:'; then
    _proxy_issues+=("{\"rule\":\"PROXY_NODE_FIELDS_CHECK\",\"level\":\"error\",\"path\":\"proxies[$pname].server\",\"message\":\"proxy '$pname' missing 'server' field\",\"fixable\":false}")
  fi
  if [[ -n "$ptype" ]] && ! echo "$block" | grep -Eq 'port:'; then
    _proxy_issues+=("{\"rule\":\"PROXY_NODE_FIELDS_CHECK\",\"level\":\"error\",\"path\":\"proxies[$pname].port\",\"message\":\"proxy '$pname' missing 'port' field\",\"fixable\":false}")
  fi
}

collect_issues() {
  local file="$1"
  local issues=()

  # R1: PORT_TYPE_INT - numeric string should be int
  for key in port socks-port mixed-port; do
    if grep -Eq "^[[:space:]]*$key:[[:space:]]*\"[0-9]+\"[[:space:]]*$" "$file"; then
      issues+=("{\"rule\":\"PORT_TYPE_INT\",\"level\":\"warn\",\"path\":\"$key\",\"message\":\"numeric string can be autofixed to int\",\"fixable\":true}")
    fi
  done

  # R31: DNS_INVALID_CHECK
  local invalid_dns="localhost|127\.0\.0\.1|0\.0\.0\.0"
  if grep -Eq 'nameserver:' "$file"; then
    while IFS= read -r line; do
      if echo "$line" | grep -Eq '^[[:space:]]*-'; then
        local ns=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' | tr -d ' ')
        if [[ -n "$ns" ]] && [[ "$ns" == "localhost" || "$ns" == "127.0.0.1" || "$ns" == "0.0.0.0" ]]; then
          issues+=("{\"rule\":\"DNS_INVALID_CHECK\",\"level\":\"error\",\"path\":\"dns.nameserver\",\"message\":\"invalid DNS server (will cause resolution failure): $ns\",\"fixable\":false,\"suggested\":\"8.8.8.8 or 1.1.1.1\"}")
        fi
      fi
    done < <(grep -A20 'nameserver:' "$file" | grep '^[[:space:]]*-')
  fi

  # R30: DUPLICATE_KEY_CHECK
  local top_level_keys="port|socks-port|mixed-port|log-level|mode|allow-lan|bind-address|external-controller"
  for key in $(echo "$top_level_keys" | tr '|' ' '); do
    local count=$(grep -E "^[[:space:]]*$key:" "$file" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -gt 1 ]]; then
      issues+=("{\"rule\":\"DUPLICATE_KEY_CHECK\",\"level\":\"warn\",\"path\":\"$key\",\"message\":\"$key is defined $count times (last value will be used)\",\"fixable\":false}")
    fi
  done

  # R29: PORT_CONFLICT_CHECK
  if grep -Eq '^[[:space:]]*proxies:' "$file"; then
    local -A port_map
    local current_name=""
    local current_port=""
    
    while IFS= read -r line; do
      if echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*name:'; then
        current_name=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
      elif echo "$line" | grep -Eq '^[[:space:]]*port:'; then
        current_port=$(echo "$line" | sed -E 's/^[[:space:]]*port:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
        if [[ -n "$current_name" && -n "$current_port" && "$current_port" =~ ^[0-9]+$ ]]; then
          if [[ -n "${port_map[$current_port]:-}" ]]; then
            issues+=("{\"rule\":\"PORT_CONFLICT_CHECK\",\"level\":\"warn\",\"path\":\"proxies[$current_name].port\",\"message\":\"port $current_port is also used by '${port_map[$current_port]}'\",\"fixable\":false}")
          else
            port_map[$current_port]="$current_name"
          fi
        fi
      fi
    done < <(grep -E '^[[:space:]]*(-[[:space:]]*name:|port:)' "$file")
  fi

  # R28: UNSUPPORTED_PROXY_TYPE_CHECK
  local supported_types="direct|reject|ss|ss-plugin|vmess|trojan|vless|anytls|http|socks5|socks"
  while IFS= read -r line; do
    local t=$(echo "$line" | sed -E 's/^[[:space:]]*type:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
    if [[ -n "$t" ]] && ! echo "$t" | grep -Eq "^($supported_types)$"; then
      local name=$(grep -B5 "type:[[:space:]]*$t" "$file" | grep "name:" | tail -1 | sed -E 's/.*name:[[:space:]]*"?([^"]*)"?.*/\1/')
      issues+=("{\"rule\":\"UNSUPPORTED_PROXY_TYPE_CHECK\",\"level\":\"error\",\"path\":\"proxies[$name].type\",\"message\":\"proxy type '$t' is not supported by zclash\",\"fixable\":false}")
    fi
  done < <(grep -E '^[[:space:]]*type:' "$file")

  # R27: TLS_SNI_CHECK
  if grep -Eq '^[[:space:]]*tls:[[:space:]]*true' "$file"; then
    # Get all proxy names and their tls/sni status
    local proxy_names=()
    local has_tls=()
    local has_sni=()
    local current_name=""
    local in_tls_node=false
    
    while IFS= read -r line; do
      if echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*name:'; then
        current_name=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
      elif echo "$line" | grep -Eq '^[[:space:]]*tls:[[:space:]]*true'; then
        in_tls_node=true
        proxy_names+=("$current_name")
        has_tls+=("$current_name")
      elif [[ "$in_tls_node" == "true" ]] && echo "$line" | grep -Eq '^[[:space:]]*sni:'; then
        has_sni+=("$current_name")
      elif [[ "$in_tls_node" == "true" ]] && echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*name:'; then
        in_tls_node=false
      fi
    done < <(grep -E '^[[:space:]]*(-[[:space:]]*name:|tls:|sni:)' "$file")
    
    # Check which tls nodes lack sni
    for pn in "${has_tls[@]:-}"; do
      local found_sni=false
      for sn in "${has_sni[@]:-}"; do
        if [[ "$sn" == "$pn" ]]; then
          found_sni=true
          break
        fi
      done
      if [[ "$found_sni" == "false" ]]; then
        issues+=("{\"rule\":\"TLS_SNI_CHECK\",\"level\":\"warn\",\"path\":\"proxies[$pn].sni\",\"message\":\"tls=true but sni not set for '$pn' (may cause TLS handshake failure)\",\"fixable\":false}")
      fi
    done
  fi

  # R26: WS_OPTS_FORMAT_CHECK
  if grep -Eq '^[[:space:]]*ws-opts:' "$file"; then
    # Check path format (should start with /)
    while IFS= read -r line; do
      if echo "$line" | grep -Eq 'path:[[:space:]]*[^/]'; then
        local p=$(echo "$line" | sed -E 's/.*path:[[:space:]]*"?([^"]*)"?.*/\1/')
        if [[ -n "$p" ]] && [[ "$p" != /* ]]; then
          issues+=("{\"rule\":\"WS_OPTS_FORMAT_CHECK\",\"level\":\"warn\",\"path\":\"ws-opts.path\",\"message\":\"ws-opts path should start with /: $p\",\"fixable\":false,\"suggested\":\"/\${p}\"}")
        fi
      fi
    done < <(grep -E '^[[:space:]]+path:' "$file")
  fi

  # R25: SUBSCRIPTION_URL_CHECK
  if grep -Eq '^[[:space:]]*subscription-url:' "$file"; then
    local sub_url=$(grep -E '^[[:space:]]*subscription-url:' "$file" | head -n1 | sed -E 's/^[[:space:]]*subscription-url:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
    if [[ -n "$sub_url" ]] && ! echo "$sub_url" | grep -Eq '^(https?|file)://'; then
      issues+=("{\"rule\":\"SUBSCRIPTION_URL_CHECK\",\"level\":\"warn\",\"path\":\"subscription-url\",\"message\":\"subscription-url should use http/https/file protocol: $sub_url\",\"fixable\":false}")
    fi
  fi

  # R24: YAML_SYNTAX_CHECK
  # Try to detect obvious YAML syntax errors
  local yaml_errors=()
  
  # Check for lines without colon that should have them (in proxy/group definitions)
  while IFS= read -r line; do
    if echo "$line" | grep -Eq '^[[:space:]]+[a-zA-Z-]+[[:space:]]+[^:[:space:]]'; then
      if echo "$line" | grep -Eqv '^[[:space:]]*-'; then
        local key=$(echo "$line" | sed -E 's/^[[:space:]]+([a-zA-Z-]+).*/\1/')
        if [[ "$key" =~ ^(name|type|server|port|cipher|password|uuid|sni|mode|log-level)$ ]]; then
          yaml_errors+=("line missing colon after '$key': $(echo "$line" | cut -c1-40)")
        fi
      fi
    fi
  done < <(grep -E '^[[:space:]]+[a-zA-Z-]+[[:space:]]+[^:]' "$file" 2>/dev/null || true)
  
  # Check for inconsistent indentation (mixing tabs and spaces)
  if grep -Pq '^\t' "$file" 2>/dev/null && grep -Pq '^ ' "$file" 2>/dev/null; then
    yaml_errors+=("mixed tabs and spaces for indentation")
  fi
  
  for err in "${yaml_errors[@]:-}"; do
    issues+=("{\"rule\":\"YAML_SYNTAX_CHECK\",\"level\":\"error\",\"path\":\"yaml\",\"message\":\"YAML syntax issue: $err\",\"fixable\":false}")
  done

  # R23: PROXY_GROUP_REF_CHECK
  if grep -Eq '^[[:space:]]*proxy-groups:' "$file" && grep -Eq '^[[:space:]]*proxies:' "$file"; then
    # Collect all proxy names
    local proxy_names=()
    while IFS= read -r line; do
      local n=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
      [[ -n "$n" ]] && proxy_names+=("$n")
    done < <(grep -E '^[[:space:]]*-[[:space:]]*name:' "$file" | head -100)
    
    # Check proxy-groups references
    local in_group=false
    local group_name=""
    while IFS= read -r line; do
      if echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*name:'; then
        group_name=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
        in_group=true
      elif [[ "$in_group" == "true" ]] && echo "$line" | grep -Eq '^[[:space:]]*proxies:'; then
        : # start of proxies list
      elif [[ "$in_group" == "true" ]] && echo "$line" | grep -Eq '^[[:space:]]+-'; then
        local ref=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
        if [[ -n "$ref" ]]; then
          local found=false
          for pn in "${proxy_names[@]:-}"; do
            if [[ "$pn" == "$ref" ]]; then
              found=true
              break
            fi
          done
          if [[ "$found" == "false" ]]; then
            issues+=("{\"rule\":\"PROXY_GROUP_REF_CHECK\",\"level\":\"error\",\"path\":\"proxy-groups[$group_name].proxies\",\"message\":\"proxy group '$group_name' references undefined proxy: $ref\",\"fixable\":false}")
          fi
        fi
      elif [[ "$in_group" == "true" ]] && ! echo "$line" | grep -Eq '^[[:space:]]'; then
        in_group=false
      fi
    done < <(grep -E '^[[:space:]]*(proxy-groups:|proxies:|proxy-providers:|rule-providers:|rules:)' -A 1000 "$file" | grep -E '^[[:space:]]*(proxy-groups:|proxies:|[[:space:]]+-[[:space:]]*name:|[[:space:]]+-)' | head -200)
  fi

  # R22: VLESS_FIELDS_CHECK
  if grep -Eq '^[[:space:]]*type:[[:space:]]*vless' "$file"; then
    local proxy_types=()
    local proxy_names=()
    local current_name=""
    
    while IFS= read -r line; do
      if echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*name:'; then
        current_name=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
      elif echo "$line" | grep -Eq '^[[:space:]]*type:'; then
        local t=$(echo "$line" | sed -E 's/^[[:space:]]*type:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
        if [[ -n "$current_name" ]]; then
          proxy_types+=("$current_name:$t")
        fi
      fi
    done < <(grep -E '^[[:space:]]*(-[[:space:]]*name:|type:)' "$file")
    
    for pt in "${proxy_types[@]:-}"; do
      local pname=${pt%%:*}
      local ptype=${pt#*:}
      if [[ "$ptype" == "vless" ]]; then
        local block_start=false
        local in_block=false
        local has_uuid=false
        local has_sni=false
        
        while IFS= read -r line; do
          if echo "$line" | grep -Eq "^[[:space:]]*-[[:space:]]*name:[[:space:]]*\"?$pname\"?"; then
            block_start=true
            in_block=true
          elif [[ "$in_block" == "true" ]] && echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*name:'; then
            break
          elif [[ "$in_block" == "true" ]]; then
            if echo "$line" | grep -Eq '^[[:space:]]*uuid:'; then
              has_uuid=true
            fi
            if echo "$line" | grep -Eq '^[[:space:]]*sni:'; then
              has_sni=true
            fi
          fi
        done < <(grep -E '^[[:space:]]*(-[[:space:]]*name:|uuid:|sni:)' "$file")
        
        if [[ "$has_uuid" != "true" ]]; then
          issues+=("{\"rule\":\"VLESS_FIELDS_CHECK\",\"level\":\"error\",\"path\":\"proxies[$pname].uuid\",\"message\":\"vless node '$pname' missing required field: uuid\",\"fixable\":false}")
        fi
        if [[ "$has_sni" != "true" ]]; then
          issues+=("{\"rule\":\"VLESS_FIELDS_CHECK\",\"level\":\"warn\",\"path\":\"proxies[$pname].sni\",\"message\":\"vless node '$pname' missing recommended field: sni\",\"fixable\":false}")
        fi
      fi
    done
  fi

  # R21: RULES_FORMAT_CHECK
  if grep -Eq '^[[:space:]]*rules:' "$file"; then
    while IFS= read -r line; do
      # Check if rule line starts with - and has comma-separated parts
      if echo "$line" | grep -Eq '^[[:space:]]*-'; then
        local content=$(echo "$line" | sed -E 's/^[[:space:]]*-//' | tr -d ' ')
        # Skip MATCH rule (only needs two parts)
        if echo "$content" | grep -Eq '^MATCH,'; then
          continue
        fi
        # Check for at least 3 comma-separated parts
        local parts=$(echo "$content" | awk -F',' '{print NF}')
        if [[ "$parts" -lt 3 ]]; then
          local rule_preview=$(echo "$content" | cut -c1-30)
          issues+=("{\"rule\":\"RULES_FORMAT_CHECK\",\"level\":\"error\",\"path\":\"rules[]\",\"message\":\"rule malformed (expected TYPE,VALUE,ACTION): $rule_preview\",\"fixable\":false}")
        fi
      fi
    done < <(grep -E '^[[:space:]]*-|^rules:' "$file" | tail -n +2)
  fi

  # R20: TROJAN_FIELDS_CHECK
  if grep -Eq '^[[:space:]]*type:[[:space:]]*trojan' "$file"; then
    # Get all proxy names and their types
    local proxy_types=()
    local proxy_names=()
    local current_name=""
    
    while IFS= read -r line; do
      if echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*name:'; then
        current_name=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
      elif echo "$line" | grep -Eq '^[[:space:]]*type:'; then
        local t=$(echo "$line" | sed -E 's/^[[:space:]]*type:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
        if [[ -n "$current_name" ]]; then
          proxy_types+=("$current_name:$t")
        fi
      fi
    done < <(grep -E '^[[:space:]]*(-[[:space:]]*name:|type:)' "$file")
    
    # For each trojan proxy, check password and sni
    for pt in "${proxy_types[@]:-}"; do
      local pname=${pt%%:*}
      local ptype=${pt#*:}
      if [[ "$ptype" == "trojan" ]]; then
        # Check if password exists in block
        local block_start=false
        local in_block=false
        local has_password=false
        local has_sni=false
        
        while IFS= read -r line; do
          if echo "$line" | grep -Eq "^[[:space:]]*-[[:space:]]*name:[[:space:]]*\"?$pname\"?"; then
            block_start=true
            in_block=true
          elif [[ "$in_block" == "true" ]] && echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*name:'; then
            break
          elif [[ "$in_block" == "true" ]]; then
            if echo "$line" | grep -Eq '^[[:space:]]*password:'; then
              has_password=true
            fi
            if echo "$line" | grep -Eq '^[[:space:]]*sni:'; then
              has_sni=true
            fi
          fi
        done < <(grep -E '^[[:space:]]*(-[[:space:]]*name:|password:|sni:)' "$file")
        
        if [[ "$has_password" != "true" ]]; then
          issues+=("{\"rule\":\"TROJAN_FIELDS_CHECK\",\"level\":\"error\",\"path\":\"proxies[$pname].password\",\"message\":\"trojan node '$pname' missing required field: password\",\"fixable\":false}")
        fi
        if [[ "$has_sni" != "true" ]]; then
          issues+=("{\"rule\":\"TROJAN_FIELDS_CHECK\",\"level\":\"warn\",\"path\":\"proxies[$pname].sni\",\"message\":\"trojan node '$pname' missing recommended field: sni\",\"fixable\":false}")
        fi
      fi
    done
  fi

  # R19: VMESS_ALTERID_RANGE_CHECK
  while IFS= read -r line; do
    if echo "$line" | grep -Eq 'alterId:'; then
      aid=$(echo "$line" | sed -E 's/.*alterId:[[:space:]]*"?([^"]*)"?.*/\1/')
      if [[ "$aid" =~ ^[0-9]+$ ]]; then
        if [[ "$aid" -lt 0 || "$aid" -gt 65535 ]]; then
          issues+=("{\"rule\":\"VMESS_ALTERID_RANGE_CHECK\",\"level\":\"error\",\"path\":\"proxies[].alterId\",\"message\":\"alterId out of range: $aid (must be 0-65535)\",\"fixable\":false}")
        fi
      fi
    fi
  done < <(grep -E '^[[:space:]]*alterId:' "$file")

  # R18: SS_PROTOCOL_CHECK
  while IFS= read -r line; do
    type_val=$(echo "$line" | sed -E 's/.*type:[[:space:]]*"?([^"]*)"?.*/\1/')
    if [[ -n "$type_val" ]] && [[ "$type_val" == ss* ]]; then
      if [[ "$type_val" != "ss" && "$type_val" != "ss-plugin" ]]; then
        issues+=("{\"rule\":\"SS_PROTOCOL_CHECK\",\"level\":\"warn\",\"path\":\"proxies[].type\",\"message\":\"unrecognized ss variant: $type_val (treating as ss)\",\"fixable\":false,\"suggested\":\"ss\"}")
      fi
    fi
  done < <(grep -E '^[[:space:]]*type:[[:space:]]*ss' "$file")

  # R17: PORT_RANGE_CHECK
  for port_key in port socks-port mixed-port; do
    if grep -Eq "^[[:space:]]*$port_key:" "$file"; then
      port_val=$(grep -E "^[[:space:]]*$port_key:" "$file" | head -n1 | sed -E "s/^[[:space:]]*$port_key:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/")
      if [[ "$port_val" =~ ^[0-9]+$ ]]; then
        if [[ "$port_val" -lt 1 || "$port_val" -gt 65535 ]]; then
          issues+=("{\"rule\":\"PORT_RANGE_CHECK\",\"level\":\"error\",\"path\":\"$port_key\",\"message\":\"port out of range: $port_val (must be 1-65535)\",\"fixable\":false}")
        fi
      fi
    fi
  done

  # R16: PROXY_NAME_UNIQUENESS_CHECK
  if grep -Eq '^[[:space:]]*proxies:' "$file"; then
    local -a names=()
    while IFS= read -r line; do
      n=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
      if [[ -n "$n" ]]; then
        for existing in "${names[@]:-}"; do
          if [[ "$existing" == "$n" ]]; then
            issues+=("{\"rule\":\"PROXY_NAME_UNIQUENESS_CHECK\",\"level\":\"error\",\"path\":\"proxies[$n]\",\"message\":\"duplicate proxy name: $n\",\"fixable\":false}")
            break
          fi
        done
        names+=("$n")
      fi
    done < <(grep -E '^[[:space:]]*-[[:space:]]*name:' "$file")
  fi

  # R15: MODE_ENUM_CHECK
  if grep -Eq '^[[:space:]]*mode:' "$file"; then
    mode_val=$(grep -E '^[[:space:]]*mode:' "$file" | head -n1 | sed -E 's/^[[:space:]]*mode:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
    case "$mode_val" in
      rule|global|direct) ;;
      *)
        issues+=("{\"rule\":\"MODE_ENUM_CHECK\",\"level\":\"error\",\"path\":\"mode\",\"message\":\"invalid mode: $mode_val (must be rule/global/direct)\",\"fixable\":false,\"suggested\":\"rule\"}")
        ;;
    esac
  fi

  # R14: MIXED_PORT_CONFLICT_CHECK
  local has_mixed=false has_port=false has_socks=false
  grep -Eq '^[[:space:]]*mixed-port:' "$file" && has_mixed=true
  grep -Eq '^[[:space:]]*port:' "$file" && has_port=true
  grep -Eq '^[[:space:]]*socks-port:' "$file" && has_socks=true
  if [[ "$has_mixed" == "true" ]] && [[ "$has_port" == "true" || "$has_socks" == "true" ]]; then
    issues+=("{\"rule\":\"MIXED_PORT_CONFLICT_CHECK\",\"level\":\"warn\",\"path\":\"port/socks-port\",\"message\":\"mixed-port is set, port/socks-port will be ignored\",\"fixable\":false,\"suggested\":\"remove port/socks-port when using mixed-port\"}")
  fi

  # R13: VMESS_UUID_FORMAT_CHECK
  local in_vmess=false vmess_name=""
  while IFS= read -r line; do
    if echo "$line" | grep -Eq 'type:[[:space:]]*vmess'; then
      in_vmess=true
      vmess_name=""
    elif [[ "$in_vmess" == "true" ]] && echo "$line" | grep -Eq 'name:'; then
      vmess_name=$(echo "$line" | sed -E 's/.*name:[[:space:]]*"?([^"]*)"?.*/\1/')
    elif [[ "$in_vmess" == "true" ]] && echo "$line" | grep -Eq 'uuid:'; then
      uuid_val=$(echo "$line" | sed -E 's/.*uuid:[[:space:]]*"?([^"]*)"?.*/\1/')
      # UUID v4 pattern: 8-4-4-4-12 hex digits
      if ! echo "$uuid_val" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
        issues+=("{\"rule\":\"VMESS_UUID_FORMAT_CHECK\",\"level\":\"error\",\"path\":\"proxies[$vmess_name].uuid\",\"message\":\"invalid UUID format: $uuid_val\",\"fixable\":false}")
      fi
      in_vmess=false
    elif [[ "$in_vmess" == "true" ]] && echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*(name|type|server|port):'; then
      # Next proxy or end of vmess block
      in_vmess=false
    fi
  done < <(grep -E '^[[:space:]]*(name:|type:|uuid:|server:|port:|-[[:space:]]*name:)' "$file")

  # R12: SS_CIPHER_ENUM_CHECK
  local valid_ciphers="aes-128-gcm|aes-192-gcm|aes-256-gcm|aes-128-cfb|aes-192-cfb|aes-256-cfb|chacha20-ietf-poly1305|chacha20-poly1305|rc4-md5|none"
  while IFS= read -r line; do
    cipher_val=$(echo "$line" | sed -E 's/^[[:space:]]*cipher:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
    if [[ -n "$cipher_val" ]] && ! echo "$cipher_val" | grep -Eq "^($valid_ciphers)$"; then
      issues+=("{\"rule\":\"SS_CIPHER_ENUM_CHECK\",\"level\":\"error\",\"path\":\"proxies[].cipher\",\"message\":\"unsupported cipher: $cipher_val\",\"fixable\":false,\"suggested\":\"aes-256-gcm\"}")
    fi
  done < <(grep -E '^[[:space:]]*cipher:' "$file")

  # R11: PROXY_NODE_FIELDS_CHECK
  if grep -Eq '^[[:space:]]*proxies:' "$file"; then
    local proxy_block=""
    local in_proxy=false
    while IFS= read -r line; do
      if echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*name:|^[[:space:]]*-[[:space:]]*type:'; then
        # Process previous block
        if [[ -n "$proxy_block" ]]; then
          _check_proxy_fields "$proxy_block"
        fi
        proxy_block="$line"
      elif [[ -n "$proxy_block" ]]; then
        proxy_block="$proxy_block
$line"
      fi
    done < <(awk '/^[[:space:]]*proxies:/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' "$file")
    # Last block
    if [[ -n "$proxy_block" ]]; then
      _check_proxy_fields "$proxy_block"
    fi
  fi

  # Merge proxy field issues
  for pi in "${_proxy_issues[@]:-}"; do
    [[ -n "$pi" ]] && issues+=("$pi")
  done
  _proxy_issues=()

  # R10: RULE_PROVIDER_REF_CHECK
  if grep -Eq '^[[:space:]]*rule-providers:' "$file" && grep -Eq 'RULE-SET,' "$file"; then
    # Collect declared provider names
    local providers=()
    while IFS= read -r line; do
      pname=$(echo "$line" | sed -E 's/^[[:space:]]+([^:]+):[[:space:]]*$/\1/')
      [[ -n "$pname" ]] && providers+=("$pname")
    done < <(awk '/^[[:space:]]*rule-providers:/{found=1; next} found && /^[[:space:]]{2,4}[a-zA-Z]/{print; next} found && /^[^[:space:]]/{exit}' "$file")
    # Check RULE-SET references
    while IFS= read -r line; do
      ref=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*RULE-SET,([^,]+),.*/\1/')
      if [[ -n "$ref" ]]; then
        local found_ref=false
        for p in "${providers[@]:-}"; do
          [[ "$p" == "$ref" ]] && found_ref=true && break
        done
        if [[ "$found_ref" == "false" ]]; then
          issues+=("{\"rule\":\"RULE_PROVIDER_REF_CHECK\",\"level\":\"error\",\"path\":\"rules[RULE-SET,$ref]\",\"message\":\"RULE-SET references undefined provider: $ref\",\"fixable\":false}")
        fi
      fi
    done < <(grep -E '^[[:space:]]*-[[:space:]]*RULE-SET,' "$file")
  fi

  # R9: ALLOW_LAN_BIND_CONFLICT
  if grep -Eq '^[[:space:]]*allow-lan:[[:space:]]*false' "$file"; then
    if grep -Eq '^[[:space:]]*bind-address:' "$file"; then
      bind_val=$(grep -E '^[[:space:]]*bind-address:' "$file" | head -n1 | sed -E 's/^[[:space:]]*bind-address:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
      if [[ "$bind_val" != "127.0.0.1" && "$bind_val" != "localhost" ]]; then
        issues+=("{\"rule\":\"ALLOW_LAN_BIND_CONFLICT\",\"level\":\"warn\",\"path\":\"bind-address\",\"message\":\"allow-lan=false but bind-address=$bind_val (will be overridden to 127.0.0.1)\",\"fixable\":false,\"suggested\":\"127.0.0.1\"}")
      fi
    fi
  fi

  # R8: EXTERNAL_CONTROLLER_FORMAT
  if grep -Eq '^[[:space:]]*external-controller:' "$file"; then
    ec_val=$(grep -E '^[[:space:]]*external-controller:' "$file" | head -n1 | sed -E 's/^[[:space:]]*external-controller:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
    if [[ -n "$ec_val" ]] && ! echo "$ec_val" | grep -Eq '^[^:]+:[0-9]+$'; then
      issues+=("{\"rule\":\"EXTERNAL_CONTROLLER_FORMAT\",\"level\":\"warn\",\"path\":\"external-controller\",\"message\":\"expected host:port format, got: $ec_val\",\"fixable\":false,\"suggested\":\"127.0.0.1:$ec_val\"}")
    fi
  fi

  # R7: TUN_ENABLE_CHECK
  if grep -Eq '^[[:space:]]*tun:' "$file"; then
    if grep -Eq '^[[:space:]]+enable:[[:space:]]*true' "$file"; then
      issues+=("{\"rule\":\"TUN_ENABLE_CHECK\",\"level\":\"warn\",\"path\":\"tun.enable\",\"message\":\"tun mode is not supported by zclash, will be ignored\",\"fixable\":false}")
    elif ! grep -Eq '^[[:space:]]+enable:' "$file"; then
      issues+=("{\"rule\":\"TUN_ENABLE_CHECK\",\"level\":\"info\",\"path\":\"tun.enable\",\"message\":\"tun section present but enable not set, will be ignored\",\"fixable\":false}")
    fi
  fi

  # R6: PROXY_GROUP_EMPTY_PROXIES
  if grep -Eq '^[[:space:]]*-[[:space:]]*name:' "$file" && grep -Eq '^[[:space:]]*proxy-groups:' "$file"; then
    # Detect groups with empty proxies array or missing proxies key
    local in_group=false group_name="" has_proxies=false
    while IFS= read -r line; do
      if echo "$line" | grep -Eq '^[[:space:]]*-[[:space:]]*name:[[:space:]]*'; then
        # Close previous group check
        if [[ "$in_group" == "true" && "$has_proxies" == "false" ]]; then
          issues+=("{\"rule\":\"PROXY_GROUP_EMPTY_PROXIES\",\"level\":\"error\",\"path\":\"proxy-groups[$group_name].proxies\",\"message\":\"proxy group '$group_name' has no proxies\",\"fixable\":false}")
        fi
        in_group=true
        group_name=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
        has_proxies=false
      elif echo "$line" | grep -Eq '^[[:space:]]*proxies:[[:space:]]*\[' && echo "$line" | grep -Eq '\[\s*\]'; then
        # proxies: [] on same line
        has_proxies=false
      elif echo "$line" | grep -Eq '^[[:space:]]*proxies:'; then
        has_proxies=true
      fi
    done < <(awk '/^[[:space:]]*proxy-groups:/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' "$file")
    # Check last group
    if [[ "$in_group" == "true" && "$has_proxies" == "false" ]]; then
      issues+=("{\"rule\":\"PROXY_GROUP_EMPTY_PROXIES\",\"level\":\"error\",\"path\":\"proxy-groups[$group_name].proxies\",\"message\":\"proxy group '$group_name' has no proxies\",\"fixable\":false}")
    fi
  fi

  # R3: PROXY_GROUP_TYPE_CHECK
  local valid_types="select|url-test|fallback|load-balance|relay"
  if grep -Eq '^[[:space:]]*-[[:space:]]*name:' "$file" && grep -Eq '^[[:space:]]*type:' "$file"; then
    while IFS= read -r line; do
      raw_type=$(echo "$line" | sed -E 's/^[[:space:]]*type:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/')
      if [[ -n "$raw_type" ]] && ! echo "$raw_type" | grep -Eq "^($valid_types)$"; then
        issues+=("{\"rule\":\"PROXY_GROUP_TYPE_CHECK\",\"level\":\"error\",\"path\":\"proxy-groups[].type\",\"message\":\"unknown proxy group type: $raw_type\",\"fixable\":false,\"suggested\":\"select\"}")
      fi
    done < <(grep -E '^[[:space:]]*type:[[:space:]]*"?[A-Za-z-]+"?' "$file")
  fi

  # R4: DNS_FIELD_CHECK
  if grep -Eq '^[[:space:]]*dns:' "$file"; then
    # Check dns.enable missing
    if ! grep -Eq '^[[:space:]]+enable:' "$file"; then
      issues+=("{\"rule\":\"DNS_FIELD_CHECK\",\"level\":\"warn\",\"path\":\"dns.enable\",\"message\":\"dns.enable missing, defaults to true\",\"fixable\":false,\"suggested\":\"true\"}")
    fi
    # Check dns.nameserver empty or missing
    if ! grep -Eq '^[[:space:]]+nameserver:' "$file"; then
      issues+=("{\"rule\":\"DNS_FIELD_CHECK\",\"level\":\"error\",\"path\":\"dns.nameserver\",\"message\":\"dns.nameserver missing\",\"fixable\":false}")
    elif grep -A1 'nameserver:' "$file" | grep -Eq '^\s*nameserver:\s*\[\s*\]\s*$'; then
      issues+=("{\"rule\":\"DNS_FIELD_CHECK\",\"level\":\"error\",\"path\":\"dns.nameserver\",\"message\":\"dns.nameserver is empty\",\"fixable\":false}")
    fi
    # Check dns.enhanced-mode (unsupported)
    if grep -Eq '^[[:space:]]+enhanced-mode:' "$file"; then
      issues+=("{\"rule\":\"DNS_FIELD_CHECK\",\"level\":\"warn\",\"path\":\"dns.enhanced-mode\",\"message\":\"zclash ignores enhanced-mode\",\"fixable\":false}")
    fi
  fi

  # R5: DNS_NAMESERVER_FORMAT
  if grep -Eq '^[[:space:]]+nameserver:' "$file"; then
    while IFS= read -r line; do
      ns=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//')
      if [[ -n "$ns" ]] && ! echo "$ns" | grep -Eq '^(https?://|tls://|quic://|tcp://|udp://)'; then
        # Plain IP without protocol prefix
        if echo "$ns" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^\[?[0-9a-fA-F:]+\]?$'; then
          issues+=("{\"rule\":\"DNS_NAMESERVER_FORMAT\",\"level\":\"warn\",\"path\":\"dns.nameserver\",\"message\":\"plain IP without protocol: $ns (defaults to udp)\",\"fixable\":false,\"suggested\":\"udp://$ns\"}")
        fi
      fi
    done < <(awk '/^[[:space:]]*nameserver:/{found=1; next} found && /^[[:space:]]*-/{print; next} found && /^[[:space:]]*[^-[:space:]]/{found=0}' "$file")
  fi

  # R2: LOG_LEVEL_ENUM
  if grep -Eq '^[[:space:]]*log-level:[[:space:]]*"?[A-Za-z-]+"?[[:space:]]*$' "$file"; then
    raw=$(grep -E '^[[:space:]]*log-level:[[:space:]]*"?[A-Za-z-]+"?[[:space:]]*$' "$file" | head -n1 | sed -E 's/^[[:space:]]*log-level:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/')
    case "$raw" in
      debug|info|warning|error|silent) ;;
      *)
        issues+=("{\"rule\":\"LOG_LEVEL_ENUM\",\"level\":\"error\",\"path\":\"log-level\",\"message\":\"value out of enum\",\"fixable\":false,\"suggested\":\"info\"}")
        ;;
    esac
  fi

  if [[ ${#issues[@]} -eq 0 ]]; then
    echo "[]"
  else
    local joined
    joined=$(IFS=,; echo "${issues[*]}")
    echo "[$joined]"
  fi
}

if [[ "$MODE" == "lint" ]]; then
  issues_json=$(collect_issues "$INPUT")

  if echo "$issues_json" | grep -q '"level":"error"'; then
    ok=false
    hint="fix error-level issues first; for LOG_LEVEL_ENUM use suggested value: info"
  else
    ok=true
    hint="run autofix for fixable issues"
  fi

  echo "{\"ok\":$ok,\"mode\":\"lint\",\"issues\":$issues_json,\"fixed\":0,\"hint\":\"$(json_escape "$hint")\"}"
  if [[ "$ok" == "true" ]]; then
    exit 0
  else
    exit 1
  fi
fi

# autofix mode: apply R1 only (PORT_TYPE_INT)
out_path="${OUT:-$INPUT.bak}"
cp "$INPUT" "$out_path"

fixed=0
for key in port socks-port mixed-port; do
  count=$(grep -Ec "^[[:space:]]*$key:[[:space:]]*\"[0-9]+\"[[:space:]]*$" "$out_path" || true)
  if [[ "$count" -gt 0 ]]; then
    fixed=$((fixed + count))
    sed -E -i.bak "s|^([[:space:]]*$key:[[:space:]]*)\"([0-9]+)\"([[:space:]]*)$|\1\2\3|" "$out_path"
    rm -f "$out_path.bak"
  fi
done

issues_json=$(collect_issues "$out_path")
if echo "$issues_json" | grep -q '"level":"error"'; then
  ok=false
  hint="autofix done for fixable issues; unresolved error-level issues remain"
else
  ok=true
  hint="autofix applied"
fi

echo "{\"ok\":$ok,\"mode\":\"autofix\",\"issues\":$issues_json,\"fixed\":$fixed,\"hint\":\"$(json_escape "$hint")\"}"
if [[ "$ok" == "true" ]]; then
  exit 0
else
  exit 1
fi
