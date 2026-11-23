#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/bci"
GH_PROXY="https://gh-proxy.org/https://"
RUN_URL="${GH_PROXY}raw.githubusercontent.com/IDXCY/my/main/Termux/bci/run.sh"

# 封装通用报错退出与下载校验函数
die() { echo "❌ $*" >&2; exit 1; }
fetch() {
    curl -fsSL "$1" -o "$2" || die "下载失败: $2"
    [ -s "$2" ] || die "文件为空: $2"
}

# 1. 记录脚本路径（以便安装完成后自删）并检查依赖
SELF_PATH=$([ -f "$0" ] && echo "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" || true)
for cmd in curl tar awk grep; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少必要命令: $cmd"
done

echo "[1/6] 创建目录..."
mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"

echo -e "\n[2/6] 下载 run.sh ..."
fetch "$RUN_URL" "run.sh"
head -n 1 run.sh | grep -q "bash" || die "run.sh 校验失败"
chmod +x run.sh
echo "run.sh 校验通过"

echo -e "\n[3/6] 下载 CloudflareSpeedTest ..."
case "$(uname -m)" in
    aarch64|arm64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="amd64" ;;
    *)             die "不支持架构: $(uname -m)" ;;
esac

CFST_URL="${GH_PROXY}github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_linux_${ARCH}.tar.gz"
curl -fL "$CFST_URL" | tar -zxO > cfst || die "CFST 下载或解压失败"
[ -s cfst ] || die "CFST 解压后为空"
chmod +x cfst

echo -e "\n[4/6] 下载 Cloudflare IP 段..."
fetch "https://www.cloudflare.com/ips-v4" "ipv4.txt"
fetch "https://www.cloudflare.com/ips-v6" "ipv6.txt"

echo -e "\n[5/6] 配置"
read -rsp $'\nCloudflare API Token: ' CF_TOKEN
echo -e "\n"
read -rp "Zone (例如 example.qzz.io): " ZONE
read -rp "完整域名 (例如 bci.example.qzz.io): " DOMAIN
read -rp "测速URL: " TEST_URL

echo -e "\n[6/6] 生成配置..."
cat > config.conf <<EOF
CF_TOKEN='${CF_TOKEN}'
ZONE='${ZONE}'
DOMAIN='${DOMAIN}'
TEST_URL='${TEST_URL}'
PROXY=false
KEEP_V4=3
KEEP_V6=3
EOF
chmod 600 config.conf

cat <<EOF

=====================================
 安装完成
=====================================

安装目录:
$INSTALL_DIR

运行:
cd $INSTALL_DIR
./run.sh

EOF

[ -n "$SELF_PATH" ] && [ -f "$SELF_PATH" ] && (sleep 1; rm -f "$SELF_PATH") >/dev/null 2>&1 &
exit 0
