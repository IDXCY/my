#!/usr/bin/env bash

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$DIR"

source config.conf

HOST="$DOMAIN"

ZONE_ID=$(
curl -s \
-H "Authorization: Bearer ${CF_TOKEN}" \
"https://api.cloudflare.com/client/v4/zones?name=${ZONE}" \
| grep -o '"id":"[^"]*"' \
| head -1 \
| cut -d'"' -f4
)

if [ -z "$ZONE_ID" ]; then
    echo "获取 Zone ID 失败"
    exit 1
fi

TMP_IP=$(mktemp)
TMP_CSV=$(mktemp)

cleanup() {
    rm -f "$TMP_IP" "$TMP_CSV"
}

trap cleanup EXIT

extract_ip() {
    awk -F',' 'NR>1 {print $1}' "$1"
}

delete_records() {

    local TYPE="$1"

    curl -s \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=${TYPE}&name=${HOST}" \
    | grep -o '"id":"[^"]*"' \
    | cut -d'"' -f4 \
    | while read -r ID
    do
        curl -s \
        -X DELETE \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${ID}" \
        >/dev/null
    done
}

create_record() {

    local TYPE="$1"
    local IP="$2"

    curl -s \
    -X POST \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
      \"type\":\"${TYPE}\",
      \"name\":\"${HOST}\",
      \"content\":\"${IP}\",
      \"ttl\":120,
      \"proxied\":${PROXY}
    }" >/dev/null
}

echo
echo "========== IPv4 Stage 1 =========="

./cfst \
-n 500 \
-t 1 \
-tl 200 \
-tlr 0 \
-dd \
-url "${TEST_URL}" \
-f ipv4.txt \
-o "$TMP_CSV"

extract_ip "$TMP_CSV" | head -100 > "$TMP_IP"

echo
echo "========== IPv4 Stage 2 =========="

./cfst \
-n 200 \
-t 10 \
-tl 200 \
-tlr 0 \
-dd \
-url "${TEST_URL}" \
-f "$TMP_IP" \
-o "$TMP_CSV"

extract_ip "$TMP_CSV" | head -20 > "$TMP_IP"

echo
echo "========== IPv4 Stage 3 =========="

./cfst \
-n 100 \
-t 10 \
-dn "${KEEP_V4}" \
-dt 10 \
-tl 200 \
-tlr 0 \
-url "${TEST_URL}" \
-f "$TMP_IP" \
-o result-v4.csv

TOP_V4="$(extract_ip result-v4.csv | head -${KEEP_V4})"

echo
echo "========== IPv6 Stage 1 =========="

./cfst \
-n 500 \
-t 1 \
-tl 200 \
-tlr 0 \
-dd \
-url "${TEST_URL}" \
-f ipv6.txt \
-o "$TMP_CSV"

extract_ip "$TMP_CSV" | head -100 > "$TMP_IP"

echo
echo "========== IPv6 Stage 2 =========="

./cfst \
-n 200 \
-t 10 \
-tl 200 \
-tlr 0 \
-dd \
-url "${TEST_URL}" \
-f "$TMP_IP" \
-o "$TMP_CSV"

extract_ip "$TMP_CSV" | head -20 > "$TMP_IP"

echo
echo "========== IPv6 Stage 3 =========="

./cfst \
-n 100 \
-t 10 \
-dn "${KEEP_V6}" \
-dt 10 \
-tl 200 \
-tlr 0 \
-url "${TEST_URL}" \
-f "$TMP_IP" \
-o result-v6.csv

TOP_V6="$(extract_ip result-v6.csv | head -${KEEP_V6})"

echo
echo "======================================"
echo "IPv4 TOP${KEEP_V4}"
echo "======================================"
echo
echo "$TOP_V4"

echo
echo "======================================"
echo "IPv6 TOP${KEEP_V6}"
echo "======================================"
echo
echo "$TOP_V6"

echo
echo "======================================"
echo "10秒后自动更新 Cloudflare DNS"
echo "输入 n 取消"
echo "======================================"

read -r -t 10 CONFIRM || true

case "$CONFIRM" in
    n|N)
        echo
        echo "操作已取消"
        exit 0
        ;;
esac

echo
echo "删除旧 A 记录..."

delete_records A

for ip in $TOP_V4
do
    echo "A -> $ip"
    create_record A "$ip"
done

echo
echo "删除旧 AAAA 记录..."

delete_records AAAA

for ip in $TOP_V6
do
    echo "AAAA -> $ip"
    create_record AAAA "$ip"
done

echo
echo "DNS 更新完成"
echo
