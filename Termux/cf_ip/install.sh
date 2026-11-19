#!/usr/bin/env bash

set -e

INSTALL_DIR="$HOME/cf-ip"

RUN_URL="https://cdn.jsdelivr.net/gh/IDXCY/my@main/Termux/cf_ip/run.sh"

# 1. 在切换目录前记录安装脚本的绝对路径
SELF_PATH=""
if [ -f "$0" ]; then
    SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
fi

# 检查必要依赖
for cmd in curl tar awk grep; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "缺少必要命令: $cmd"
        exit 1
    }
done

echo "[1/6] 创建目录..."

mkdir -p "$INSTALL_DIR"

cd "$INSTALL_DIR"

echo
echo "[2/6] 下载 run.sh ..."

curl -fsSL "$RUN_URL" -o run.sh

chmod +x run.sh

if [ ! -s run.sh ]; then
    echo "run.sh 下载失败"
    exit 1
fi

if ! head -n 1 run.sh | grep -q "bash"; then
    echo "run.sh 校验失败"
    exit 1
fi

echo "run.sh 校验通过"

echo
echo "[3/6] 下载 CloudflareSpeedTest ..."

ARCH=$(uname -m)

case "$ARCH" in
    aarch64|arm64)
        CFST_URL="https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_linux_arm64.tar.gz"
        ;;
    x86_64|amd64)
        CFST_URL="https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_linux_amd64.tar.gz"
        ;;
    *)
        echo "不支持架构: $ARCH"
        exit 1
        ;;
esac

curl -fL "$CFST_URL" -o cfst.tar.gz
tar -zxf cfst.tar.gz -O > cfst
rm -f cfst.tar.gz

chmod +x cfst

if [ ! -s cfst ]; then
    echo "CFST 下载或解压失败"
    exit 1
fi

echo
echo "[4/6] 下载 Cloudflare IP 段..."

curl -fsSL https://www.cloudflare.com/ips-v4 -o ipv4.txt

curl -fsSL https://www.cloudflare.com/ips-v6 -o ipv6.txt

echo
echo "[5/6] 配置"

echo
read -rsp "Cloudflare API Token: " CF_TOKEN
echo
echo

read -rp "Zone (例如 example.qzz.io): " ZONE

read -rp "完整域名 (例如 bci.example.qzz.io): " DOMAIN

read -rp "测速URL: " TEST_URL

echo
echo "[6/6] 生成配置..."

cat > config.conf <<EOF
CF_TOKEN='${CF_TOKEN}'

ZONE='${ZONE}'

DOMAIN='${DOMAIN}'

TEST_URL='${TEST_URL}'

PROXY=true

KEEP_V4=3

KEEP_V6=3
EOF

chmod 600 config.conf

echo
echo "====================================="
echo " 安装完成"
echo "====================================="
echo
echo "安装目录:"
echo "$INSTALL_DIR"
echo
echo "运行:"
echo
echo "cd $INSTALL_DIR"
echo "./run.sh"
echo

if [ -n "$SELF_PATH" ] && [ -f "$SELF_PATH" ]; then
    (sleep 1; rm -f "$SELF_PATH") >/dev/null 2>&1 &
fi

exit 0
