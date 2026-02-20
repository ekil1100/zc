#!/usr/bin/env bash
# P20-1B 复杂配置样本回归测试
# 测试包含所有代理类型的配置解析

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZC_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${ZC_ROOT}/testdata/config/all-proxy-types.yaml"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 测试结果
PASSED=0
FAILED=0

info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED++))
}

# 检查 zc 是否可构建
info "检查 zc 可构建性..."
cd "${ZC_ROOT}"
if zig build 2>/dev/null; then
    pass "zc 构建成功"
else
    fail "zc 构建失败"
    exit 1
fi

# 检查复杂配置文件存在
info "检查复杂配置文件..."
if [[ -f "${CONFIG_FILE}" ]]; then
    pass "复杂配置文件存在: ${CONFIG_FILE}"
else
    fail "复杂配置文件不存在: ${CONFIG_FILE}"
    exit 1
fi

# 检查配置文件 YAML 语法
info "检查 YAML 语法..."
if command -v yq >/dev/null 2>&1; then
    if yq '.' "${CONFIG_FILE}" > /dev/null 2>&1; then
        pass "YAML 语法检查通过"
    else
        fail "YAML 语法错误"
    fi
else
    info "yq 未安装，跳过 YAML 语法检查"
fi

# 检查配置中的代理类型
info "验证配置中的代理类型..."

EXPECTED_PROXY_TYPES=(
    "direct"
    "reject"
    "http"
    "socks5"
    "ss"
    "vmess"
    "trojan"
    "vless"
)

for proxy_type in "${EXPECTED_PROXY_TYPES[@]}"; do
    if grep -q "type: ${proxy_type}" "${CONFIG_FILE}"; then
        pass "包含代理类型: ${proxy_type}"
    else
        fail "缺少代理类型: ${proxy_type}"
    fi
done

# 检查代理组类型
info "验证代理组类型..."

EXPECTED_GROUP_TYPES=(
    "select"
    "url-test"
    "fallback"
    "load_balance"
    "relay"
)

for group_type in "${EXPECTED_GROUP_TYPES[@]}"; do
    if grep -q "type: ${group_type}" "${CONFIG_FILE}"; then
        pass "包含代理组类型: ${group_type}"
    else
        fail "缺少代理组类型: ${group_type}"
    fi
done

# 检查规则类型
info "验证规则类型..."

EXPECTED_RULE_TYPES=(
    "DOMAIN-SUFFIX"
    "DOMAIN-KEYWORD"
    "IP-CIDR"
    "GEOIP"
    "DST-PORT"
    "MATCH"
)

for rule_type in "${EXPECTED_RULE_TYPES[@]}"; do
    if grep -q "^  - ${rule_type}" "${CONFIG_FILE}"; then
        pass "包含规则类型: ${rule_type}"
    else
        fail "缺少规则类型: ${rule_type}"
    fi
done

# 检查特殊配置项
info "验证特殊配置项..."

# 检查 WebSocket 配置
if grep -q "ws-opts:" "${CONFIG_FILE}"; then
    pass "包含 ws-opts 配置"
else
    fail "缺少 ws-opts 配置"
fi

# 检查 TLS 配置
if grep -q "tls: true" "${CONFIG_FILE}"; then
    pass "包含 TLS 配置"
else
    fail "缺少 TLS 配置"
fi

# 检查 skip-cert-verify
if grep -q "skip-cert-verify:" "${CONFIG_FILE}"; then
    pass "包含 skip-cert-verify 配置"
else
    fail "缺少 skip-cert-verify 配置"
fi

# 检查 SNI 配置
if grep -q "sni:" "${CONFIG_FILE}"; then
    pass "包含 SNI 配置"
else
    fail "缺少 SNI 配置"
fi

# 检查外部控制器
if grep -q "external-controller:" "${CONFIG_FILE}"; then
    pass "包含 external-controller 配置"
else
    fail "缺少 external-controller 配置"
fi

# 输出汇总
echo ""
echo "========================================"
echo "复杂配置样本回归测试汇总"
echo "========================================"
echo -e "通过: ${GREEN}${PASSED}${NC}"
echo -e "失败: ${RED}${FAILED}${NC}"
echo "========================================"

if [[ ${FAILED} -eq 0 ]]; then
    echo -e "${GREEN}所有测试通过!${NC}"
    exit 0
else
    echo -e "${RED}存在失败的测试${NC}"
    exit 1
fi
