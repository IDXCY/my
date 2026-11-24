#!/usr/bin/env bash
set -euo pipefail

cd "$(cd "$(dirname "$0")" && pwd)"

# 兼容 Termux 的 HTTPS 根证书路径
TERMUX_CERT="/data/data/com.termux/files/usr/etc/tls/cert.pem"
[ -f "$TERMUX_CERT" ] && export SSL_CERT_FILE="$TERMUX_CERT"

# 通用报错退出与 CSV 第一列提取函数
die() { echo -e "❌ $*" >&2; exit 1; }
extract_ips() { awk -F',' -v n="$2" 'NR>1 && NR<=(n+1) {print $1}' "$1"; }

# 1. 基础环境与配置校验
[ -f "config.conf" ] || die "错误：找不到 config.conf 配置文件"
[ -x "./cfst" ]      || die "错误：找不到可执行文件 ./cfst"
# shellcheck source=/dev/null
source config.conf

TMP_IP=$(mktemp)
TMP_CSV=$(mktemp)
trap 'rm -f "$TMP_IP" "$TMP_CSV"' EXIT

# 2. 封装 Cloudflare API 通用请求函数
cf_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-fsS -X "$method" "https://api.cloudflare.com/client/v4/${endpoint}" -H "Authorization: Bearer ${CF_TOKEN}")
    [ -n "$data" ] && args+=(-H "Content-Type: application/json" --data "$data")
    curl "${args[@]}"
}

# 获取并校验 Zone ID
ZONE_RESP=$(cf_api GET "zones?name=${ZONE}") || die "错误：连接 Cloudflare API 失败，请检查网络"
ZONE_ID=$(echo "$ZONE_RESP" | grep -o '"result":\[{"id":"[^"]*"' | cut -d'"' -f6)
[ -n "$ZONE_ID" ] || die "错误：获取 Zone ID 失败，请检查 CF_TOKEN 或 ZONE 配置"

# 3. 封装单阶段测速与结果校验函数
run_stage() {
    local label="$1" input_file="$2" output_file="$3"
    shift 3

    echo -e "\n========== ${label} ==========" >&2
    ./cfst "$@" -url "${TEST_URL}" -f "$input_file" -o "$output_file" >&2 \
        || die "测速失败 [${label}]：cfst 运行异常（请检查网络连通性或 TEST_URL）"

    [ -s "$output_file" ] && [ "$(wc -l < "$output_file")" -gt 1 ] \
        || die "测速失败 [${label}]：未筛选出符合条件的可用 IP，脚本终止"
}

# 4. 封装 3 阶段漏斗测速流程
speedtest_funnel() {
    local proto="$1" src_file="$2" keep_num="$3" final_csv="$4"

    (( keep_num <= 0 )) && return 0
    [ -s "$src_file" ] || die "错误：IP 段文件 ${src_file} 不存在或为空"

    # Stage 1: 粗筛前 300 -> Stage 2: 复筛前 100 -> Stage 3: 测下载速度
    run_stage "${proto} Stage 1" "$src_file" "$TMP_CSV" -dd -n 400 -t 2 -tll 60 -tl 600 -tlr 1 -debug
    extract_ips "$TMP_CSV" 300 > "$TMP_IP"

    run_stage "${proto} Stage 2" "$TMP_IP" "$TMP_CSV" -dd -httping -n 50 -t 10 -tll 60 -tl 600 -tlr 0.3 -debug
    extract_ips "$TMP_CSV" 100 > "$TMP_IP"

    run_stage "${proto} Stage 3" "$TMP_IP" "$final_csv" -n 30 -t 2 -dn 10 -dt 10 -tll 60 -tl 600 -tlr 1 -sl 2 -debug
    extract_ips "$final_csv" "$keep_num"
}

# 执行 IPv4 与 IPv6 测速
TOP_V4=$(speedtest_funnel "IPv4" "ipv4.txt" "$KEEP_V4" "result-v4.csv")
TOP_V6=$(speedtest_funnel "IPv6" "ipv6.txt" "$KEEP_V6" "result-v6.csv")

# 5. 展示结果并交互确认（仅在交互终端下倒计时）
for item in "IPv4 TOP${KEEP_V4}:$TOP_V4" "IPv6 TOP${KEEP_V6}:$TOP_V6"; do
    echo -e "\n======================================\n${item%%:*}\n======================================\n${item#*:}"
done

if [ -t 0 ]; then
    echo -e "\n======================================\n10秒后自动更新 Cloudflare DNS（输入 n 取消）\n======================================"
    read -r -t 10 CONFIRM || true
    [[ "${CONFIRM:-}" =~ ^[nN]$ ]] && { echo -e "\n操作已取消"; exit 0; }
fi

# 6. 封装 DNS 记录更新函数（先删后建）
update_dns() {
    local type="$1" ip_list="$2"
    [ -n "$ip_list" ] || { echo "⚠️ ${type} 列表为空，跳过更新"; return 0; }

    echo -e "\n删除旧 ${type} 记录..."
    local records res
    records=$(cf_api GET "zones/${ZONE_ID}/dns_records?type=${type}&name=${DOMAIN}" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 || true)
    for id in $records; do
        cf_api DELETE "zones/${ZONE_ID}/dns_records/${id}" >/dev/null || true
    done

    for ip in $ip_list; do
        echo "${type} -> ${ip}"
        res=$(cf_api POST "zones/${ZONE_ID}/dns_records" \
            "{\"type\":\"${type}\",\"name\":\"${DOMAIN}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":${PROXY}}")
        echo "$res" | grep -q '"success":true' || die "添加 ${type} 记录 (${ip}) 失败，API 响应：$res"
    done
}

update_dns "A" "$TOP_V4"
update_dns "AAAA" "$TOP_V6"

echo -e "\n✅ DNS 更新完成\n"
