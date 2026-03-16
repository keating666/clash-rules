#!/usr/bin/env bash
set -euo pipefail

# Wise 域名自动发现脚本
# 数据源: crt.sh (Certificate Transparency logs)
# 原理: 通过 SSL 证书签发记录发现 Wise 使用的所有域名

RULE_FILE="rules/Wise.yaml"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 已知的 Wise 种子域名（确保始终存在）
SEED_DOMAINS=(
  "wise.com"
  "transferwise.com"
  "wise.tech"
  "transferwise.tech"
  "wiseconnect.io"
)

# 需要排除的域名或模式
EXCLUDE_PATTERNS=(
  "wise.jobs"
  "cpanel"
  "autodiscover"
  "webmail"
  "webdisk"
  "cpcalendars"
  "cpcontacts"
  "_dmarc"
  "_domainkey"
  "plesk.page"
)

# 需要排除的 TLD（防止误匹配整个国家顶级域名）
EXCLUDE_TLDS=(
  "com.tr"
  "com.au"
  "com.br"
  "com.cn"
  "co.uk"
  "co.jp"
)

echo "=== Wise 域名自动更新 ==="
echo "时间: $(date -u '+%Y-%m-%d %H:%M UTC')"

# 从 crt.sh 获取证书透明度日志中的域名
fetch_ct_domains() {
  local query="$1"
  local label="$2"
  echo "  查询 crt.sh: ${label}" >&2
  local result
  result=$(curl -sf --max-time 30 "$query" 2>/dev/null || echo "")
  if [ -n "$result" ] && [ "$result" != "[]" ]; then
    echo "$result" \
      | jq -r '.[].name_value // empty' 2>/dev/null \
      | tr ',' '\n' \
      | sed 's/\*\.//g' \
      | tr '[:upper:]' '[:lower:]' \
      | sort -u
  fi
  sleep 3  # 避免请求过快被限流
}

# 提取根域名 (e.g., api.sandbox.wise.com → wise.com)
extract_root_domain() {
  local domain="$1"
  # 处理常见的二级 TLD
  local two_level_tlds="co.uk co.jp com.au com.br com.cn com.tr org.uk"
  local last_two
  last_two=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')

  if echo "$two_level_tlds" | grep -qw "$last_two"; then
    # 二级 TLD: 取最后三段
    echo "$domain" | awk -F. '{if(NF>=3) print $(NF-2)"."$(NF-1)"."$NF}'
  else
    # 普通 TLD: 取最后两段
    echo "$domain" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF}'
  fi
}

# 收集所有域名
echo ""
echo "--- 第一步: 从 crt.sh 收集域名 ---"
ALL_DOMAINS="$TEMP_DIR/all_domains.txt"
touch "$ALL_DOMAINS"

# 查询种子域名的子域名证书
for seed in "${SEED_DOMAINS[@]}"; do
  fetch_ct_domains "https://crt.sh/?q=%25.${seed}&output=json" "%.${seed}" >> "$ALL_DOMAINS"
done

# 查询组织名
fetch_ct_domains "https://crt.sh/?O=Wise+Payments&output=json" "组织: Wise Payments" >> "$ALL_DOMAINS"
fetch_ct_domains "https://crt.sh/?O=TransferWise&output=json" "组织: TransferWise" >> "$ALL_DOMAINS"

# 过滤掉包含空格的无效行（如组织名被误收录）
grep -v ' ' "$ALL_DOMAINS" | grep -v '^$' | sort -u > "$TEMP_DIR/clean.txt"
mv "$TEMP_DIR/clean.txt" "$ALL_DOMAINS"

echo "  原始域名条目: $(wc -l < "$ALL_DOMAINS" | tr -d ' ')"

# 提取唯一根域名
echo ""
echo "--- 第二步: 提取并清洗根域名 ---"
ROOT_DOMAINS="$TEMP_DIR/root_domains.txt"
touch "$ROOT_DOMAINS"
while IFS= read -r domain; do
  [ -z "$domain" ] && continue
  extract_root_domain "$domain"
done < "$ALL_DOMAINS" | tr '[:upper:]' '[:lower:]' | sort -u > "$ROOT_DOMAINS"

# 添加种子域名（确保始终存在）
for seed in "${SEED_DOMAINS[@]}"; do
  echo "$seed"
done >> "$ROOT_DOMAINS"

# 合并已有规则文件中的域名（只增不减）
if [ -f "$RULE_FILE" ]; then
  echo "  合并已有规则中的域名..."
  grep 'DOMAIN-SUFFIX,' "$RULE_FILE" 2>/dev/null \
    | sed 's/.*DOMAIN-SUFFIX,//' \
    | tr '[:upper:]' '[:lower:]' \
    >> "$ROOT_DOMAINS"
fi

sort -u "$ROOT_DOMAINS" -o "$ROOT_DOMAINS"

# 过滤排除项
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
  grep -v "$pattern" "$ROOT_DOMAINS" > "$TEMP_DIR/tmp.txt" 2>/dev/null || true
  mv "$TEMP_DIR/tmp.txt" "$ROOT_DOMAINS"
done

# 过滤纯 TLD（少于 2 段的、或是排除的 TLD）
FILTERED="$TEMP_DIR/filtered.txt"
touch "$FILTERED"
while IFS= read -r domain; do
  [ -z "$domain" ] && continue
  # 跳过少于 2 个点分段的
  local_dots=$(echo "$domain" | tr -cd '.' | wc -c | tr -d ' ')
  [ "$local_dots" -lt 1 ] && continue
  # 跳过排除的 TLD
  skip=false
  for tld in "${EXCLUDE_TLDS[@]}"; do
    [ "$domain" = "$tld" ] && skip=true && break
  done
  $skip && continue
  echo "$domain" >> "$FILTERED"
done < "$ROOT_DOMAINS"

echo "  清洗后域名数: $(wc -l < "$FILTERED" | tr -d ' ')"

# 验证域名可解析
echo ""
echo "--- 第三步: 验证域名可解析 ---"
VALID="$TEMP_DIR/valid.txt"
touch "$VALID"
while IFS= read -r domain; do
  [ -z "$domain" ] && continue
  if dig +short +time=5 +tries=2 "$domain" 2>/dev/null | grep -q '.'; then
    echo "  ✓ $domain"
    echo "$domain" >> "$VALID"
  else
    echo "  ✗ $domain (无法解析，跳过)"
  fi
done < "$FILTERED"

DOMAIN_COUNT=$(wc -l < "$VALID" | tr -d ' ')

# 生成规则文件
echo ""
echo "--- 第四步: 生成规则文件 ---"
{
  echo "# Wise 完整域名规则集"
  echo "# 自动生成于: $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "# 数据源: Certificate Transparency (crt.sh) + 手动种子"
  echo "# 域名数量: ${DOMAIN_COUNT}"
  echo "payload:"
  sort "$VALID" | while IFS= read -r domain; do
    echo "  - DOMAIN-SUFFIX,$domain"
  done
} > "$RULE_FILE"

echo ""
echo "=== 完成 ==="
echo "规则文件: $RULE_FILE"
echo "域名总数: ${DOMAIN_COUNT}"
echo ""
cat "$RULE_FILE"
