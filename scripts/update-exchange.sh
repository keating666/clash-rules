#!/usr/bin/env bash
set -euo pipefail

# 通用交易所/服务域名自动发现脚本
# 用法: ./update-exchange.sh configs/Bybit.json
# 数据源: crt.sh (Certificate Transparency logs)

CONFIG_FILE="${1:?用法: $0 <config.json>}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "错误: 配置文件不存在: $CONFIG_FILE" >&2
  exit 1
fi

# 读取配置
NAME=$(jq -r '.name' "$CONFIG_FILE")
SEEDS=()
while IFS= read -r line; do SEEDS+=("$line"); done < <(jq -r '.seeds[]' "$CONFIG_FILE")
ORGS=()
while IFS= read -r line; do ORGS+=("$line"); done < <(jq -r '.orgs[]' "$CONFIG_FILE")
EXCLUDES=()
while IFS= read -r line; do EXCLUDES+=("$line"); done < <(jq -r '.exclude[]' "$CONFIG_FILE")

RULE_FILE="rules/${NAME}.yaml"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 需要排除的 TLD
EXCLUDE_TLDS=("com.tr" "com.au" "com.br" "com.cn" "co.uk" "co.jp" "com.hk" "com.sg")

echo "=== ${NAME} 域名自动更新 ===" >&2
echo "时间: $(date -u '+%Y-%m-%d %H:%M UTC')" >&2

# 从 crt.sh 获取域名
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
  sleep 3
}

# 提取根域名
extract_root_domain() {
  local domain="$1"
  local two_level_tlds="co.uk co.jp com.au com.br com.cn com.tr com.hk com.sg org.uk co.kr"
  local last_two
  last_two=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
  if echo "$two_level_tlds" | grep -qw "$last_two"; then
    echo "$domain" | awk -F. '{if(NF>=3) print $(NF-2)"."$(NF-1)"."$NF}'
  else
    echo "$domain" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF}'
  fi
}

# 第一步: 收集
echo "" >&2
echo "--- 第一步: 从 crt.sh 收集域名 ---" >&2
ALL_DOMAINS="$TEMP_DIR/all_domains.txt"
touch "$ALL_DOMAINS"

for seed in "${SEEDS[@]}"; do
  fetch_ct_domains "https://crt.sh/?q=%25.${seed}&output=json" "%.${seed}" >> "$ALL_DOMAINS"
done

for org in "${ORGS[@]}"; do
  local_org_encoded=$(echo "$org" | sed 's/ /+/g')
  fetch_ct_domains "https://crt.sh/?O=${local_org_encoded}&output=json" "组织: ${org}" >> "$ALL_DOMAINS"
done

# 清洗：去空行、去含空格的行
grep -v ' ' "$ALL_DOMAINS" | grep -v '^$' | sort -u > "$TEMP_DIR/clean.txt" 2>/dev/null || true
mv "$TEMP_DIR/clean.txt" "$ALL_DOMAINS"

echo "  原始域名条目: $(wc -l < "$ALL_DOMAINS" | tr -d ' ')" >&2

# 第二步: 提取根域名
echo "" >&2
echo "--- 第二步: 提取并清洗根域名 ---" >&2
ROOT_DOMAINS="$TEMP_DIR/root_domains.txt"
touch "$ROOT_DOMAINS"
while IFS= read -r domain; do
  [ -z "$domain" ] && continue
  extract_root_domain "$domain"
done < "$ALL_DOMAINS" | tr '[:upper:]' '[:lower:]' | sort -u > "$ROOT_DOMAINS"

# 添加种子域名
for seed in "${SEEDS[@]}"; do
  echo "$seed"
done >> "$ROOT_DOMAINS"

# 合并已有规则（只增不减）
if [ -f "$RULE_FILE" ]; then
  echo "  合并已有规则中的域名..." >&2
  grep 'DOMAIN-SUFFIX,' "$RULE_FILE" 2>/dev/null \
    | sed 's/.*DOMAIN-SUFFIX,//' \
    | tr '[:upper:]' '[:lower:]' \
    >> "$ROOT_DOMAINS"
fi

sort -u "$ROOT_DOMAINS" -o "$ROOT_DOMAINS"

# 过滤排除项
for pattern in "${EXCLUDES[@]}"; do
  grep -v "$pattern" "$ROOT_DOMAINS" > "$TEMP_DIR/tmp.txt" 2>/dev/null || true
  mv "$TEMP_DIR/tmp.txt" "$ROOT_DOMAINS"
done

# 过滤纯 TLD
FILTERED="$TEMP_DIR/filtered.txt"
touch "$FILTERED"
while IFS= read -r domain; do
  [ -z "$domain" ] && continue
  local_dots=$(echo "$domain" | tr -cd '.' | wc -c | tr -d ' ')
  [ "$local_dots" -lt 1 ] && continue
  skip=false
  for tld in "${EXCLUDE_TLDS[@]}"; do
    [ "$domain" = "$tld" ] && skip=true && break
  done
  $skip && continue
  echo "$domain" >> "$FILTERED"
done < "$ROOT_DOMAINS"

echo "  清洗后域名数: $(wc -l < "$FILTERED" | tr -d ' ')" >&2

# 第三步: 验证 DNS
echo "" >&2
echo "--- 第三步: 验证域名可解析 ---" >&2
VALID="$TEMP_DIR/valid.txt"
touch "$VALID"
while IFS= read -r domain; do
  [ -z "$domain" ] && continue
  if dig +short +time=5 +tries=2 "$domain" 2>/dev/null | grep -q '.'; then
    echo "  ✓ $domain" >&2
    echo "$domain" >> "$VALID"
  else
    echo "  ✗ $domain (跳过)" >&2
  fi
done < "$FILTERED"

DOMAIN_COUNT=$(wc -l < "$VALID" | tr -d ' ')

# 第四步: 生成规则文件
echo "" >&2
echo "--- 第四步: 生成规则文件 ---" >&2
{
  echo "# ${NAME} 完整域名规则集"
  echo "# 自动生成于: $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "# 数据源: Certificate Transparency (crt.sh)"
  echo "# 域名数量: ${DOMAIN_COUNT}"
  echo "payload:"
  sort "$VALID" | while IFS= read -r domain; do
    echo "  - DOMAIN-SUFFIX,$domain"
  done
} > "$RULE_FILE"

echo "" >&2
echo "=== ${NAME} 完成 — 域名总数: ${DOMAIN_COUNT} ===" >&2
cat "$RULE_FILE"
