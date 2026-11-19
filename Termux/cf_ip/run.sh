#!/usr/bin/env bash

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# 1. 基础环境与配置校验
[ -f "config.conf" ] || { echo "❌ 错误：找不到 config.conf 配置文件"; exit 1; }
[ -x "./cfst" ]      || { echo "❌ 错误：找不到可执行文件 ./cfst"; exit 1; }
source config.conf

HOST="$DOMAIN"

TMP_IP=$(mktemp)
TMP_CSV=$(mktemp)
trap 'rm -f "$TMP_IP" "$TMP_CSV"' EXIT

# 2. 封装 Cloudflare API 通用请求函数
cf_api() {
    local METHOD="$1"
    local ENDPOINT="$2"
    local DATA="${3:-}"
    if [ -n "$DATA" ]; then
        curl -fsS -X "$METHOD" "https://cloudflare.com{ENDPOINT}" \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "$DATA"
    else
        curl -fsS -X "$METHOD" "https://cloudflare.com{ENDPOINT}" \
            -H "Authorization: Bearer ${CF_TOKEN}"
    fi
}

# 获取并校验 Zone ID
ZONE_RESP=$(cf_api GET "zones?name=${ZONE}") || { echo "❌ 错误：连接 Cloudflare API 失败，请检查网络"; exit 1; }
ZONE_ID=$(echo "$ZONE_RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$ZONE_ID" ] || { echo "❌ 错误：获取 Zone ID 失败，请检查 CF_TOKEN 或 ZONE 配置"; exit 1; }

# 3. 封装单阶段测速与结果校验函数
run_stage() {
    local LABEL="$1"
    local INPUT_FILE="$2"
    local OUTPUT_FILE="$3"
    shift 3

    echo -e "\n========== ${LABEL} =========="
    if ! ./cfst "$@" -url "${TEST_URL}" -f "$INPUT_FILE" -o "$OUTPUT_FILE"; then
        echo "❌ 测速失败 [${LABEL}]：cfst 程序运行异常（请检查网络连通性或 TEST_URL 是否有效）"
        exit 1
    fi

    if [ ! -s "$OUTPUT_FILE" ] || [ "$(wc -l < "$OUTPUT_FILE")" -le 1 ]; then
        echo "❌ 测速失败 [${LABEL}]：未筛选出符合条件（延迟<=200ms 且 0丢包）的可用 IP，脚本终止"
        exit 1
    fi
}

# 4. 封装 3 阶段漏斗测速流程
speedtest_funnel() {
    local PROTO="$1"       # IPv4 或 IPv6
    local SRC_FILE="$2"    # ipv4.txt 或 ipv6.txt
    local KEEP_NUM="$3"    # KEEP_V4 或 KEEP_V6
    local FINAL_CSV="$4"   # result-v4.csv 或 result-v6.csv

    [ -s "$SRC_FILE" ] || { echo "❌ 错误：IP 段文件 ${SRC_FILE} 不存在或为空"; exit 1; }

    # Stage 1: 粗筛前 100
    run_stage "${PROTO} Stage 1" "$SRC_FILE" "$TMP_CSV" -n 200 -t 10 -tl 200 -tlr 0 -dd
    awk -F',' 'NR>1 {print $1}' "$TMP_CSV" | head -n 100 > "$TMP_IP"

    # Stage 2: 复筛前 20
    run_stage "${PROTO} Stage 2" "$TMP_IP" "$TMP_CSV" -n 200 -t 10 -tl 200 -tlr 0 -dd
    awk -F',' 'NR>1 {print $1}' "$TMP_CSV" | head -n 20 > "$TMP_IP"

    # Stage 3: 测下载速度并输出最终结果
    run_stage "${PROTO} Stage 3" "$TMP_IP" "$FINAL_CSV" -n 100 -t 10 -dn "${KEEP_NUM}" -dt 10 -tl 200 -tlr 0
}

# 执行 IPv4 与 IPv6 测速
speedtest_funnel "IPv4" "ipv4.txt" "$KEEP_V4" "result-v4.csv"
TOP_V4=$(awk -F',' 'NR>1 {print $1}' result-v4.csv | head -n "${KEEP_V4}")

speedtest_funnel "IPv6" "ipv6.txt" "$KEEP_V6" "result-v6.csv"
TOP_V6=$(awk -F',' 'NR>1 {print $1}' result-v6.csv | head -n "${KEEP_V6}")

# 5. 展示结果并倒计时确认
for ITEM in "IPv4 TOP${KEEP_V4}:$TOP_V4" "IPv6 TOP${KEEP_V6}:$TOP_V6"; do
    echo -e "\n======================================"
    echo "${ITEM%%:*}"
    echo -e "======================================\n"
    echo "${ITEM#*:}"
done

echo -e "\n======================================"
echo "10秒后自动更新 Cloudflare DNS（输入 n 取消）"
echo "======================================"

read -r -t 10 CONFIRM || true
if [[ "${CONFIRM:-}" =~ ^[nN]$ ]]; then
    echo -e "\n操作已取消"
    exit 0
fi

# 6. 封装 DNS 记录更新函数（先删后建）
update_dns() {
    local TYPE="$1"
    local IP_LIST="$2"

    echo -e "\n删除旧 ${TYPE} 记录..."
    local RECORDS
    RECORDS=$(cf_api GET "zones/${ZONE_ID}/dns_records?type=${TYPE}&name=${HOST}" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 || true)
    for ID in $RECORDS; do
        cf_api DELETE "zones/${ZONE_ID}/dns_records/${ID}" >/dev/null
    done

    for IP in $IP_LIST; do
        echo "${TYPE} -> ${IP}"
        local RES
        RES=$(cf_api POST "zones/${ZONE_ID}/dns_records" \
            "{\"type\":\"${TYPE}\",\"name\":\"${HOST}\",\"content\":\"${IP}\",\"ttl\":120,\"proxied\":${PROXY}}")
        if ! echo "$RES" | grep -q '"success":true'; then
            echo "❌ 添加 ${TYPE} 记录 (${IP}) 失败，API 响应：$RES"
            exit 1
        fi
    done
}

update_dns "A" "$TOP_V4"
update_dns "AAAA" "$TOP_V6"

echo -e "\n✅ DNS 更新完成\n"
