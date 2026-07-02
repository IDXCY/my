#!/usr/bin/env bash
# ==============================================================================
#  Script: Xiaomi Router Service Deployer (Ultimate Edition)
#  Desc:   一键部署并固化 DDNS-Go, AdGuard, frpc, mihomo, MosDNS, socat, WireGuard
#  Env:    适用于 macOS / Linux / Termux (Android)
# ==============================================================================
set -euo pipefail

# ================================= 全局常量 =================================
readonly DEFAULT_IP="192.168.31.1"
readonly WORK_DIR="/tmp/.x_deploy"
readonly BOOT_SCRIPT="/etc/rc.local"
readonly GITHUB_BASE="https://github.com"

# ================================= 日志与工具函数 =================================
readonly C_RESET="\033[0m"
readonly C_GREEN="\033[1;32m"
readonly C_YELLOW="\033[1;33m"
readonly C_RED="\033[1;31m"
readonly C_CYAN="\033[1;36m"

log_info()  { echo -e "${C_GREEN}[INFO]${C_RESET}  $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
log_err()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_step()  { echo -e "\n${C_CYAN}==>${C_RESET} ${C_CYAN}$*${C_RESET}"; }

ssh_exec() {
    if [[ -z "$ROUTER_PASS" ]]; then
        ssh $SSH_OPTS "root@${ROUTER_IP}" "$1"
    else
        sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS "root@${ROUTER_IP}" "$1"
    fi
}

# 获取 GitHub 仓库最新 Release 版本号 (带 302 重定向 Fallback，防 API 限速)
fetch_version() {
    local repo="$1"
    local ver=""
    # 1. 尝试 GitHub REST API
    ver=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \

        | grep '"tag_name"' | head -1 | sed -E 's/.*"v?([^"]*)".*/\1/' | tr -d '\r') || true
    # 2. Fallback: 跟踪 releases/latest 的 302 重定向获取 tag
    if [[ -z "$ver" ]]; then
        ver=$(curl -fsSI "https://github.com/${repo}/releases/latest" 2>/dev/null \

            | grep -i '^location:' | sed -E 's|.*/tag/v?([^"]*).*|\1|' | tr -d '\r') || true
    fi
    echo "$ver"
}

# ================================= 阶段 1: 环境准备与认证 =================================
log_step "1/6 目标认证与环境准备"

ROUTER_IP="$DEFAULT_IP"
read -rp "路由器 IP [${DEFAULT_IP}]: " input_ip
[[ -n "$input_ip" ]] && ROUTER_IP="$input_ip"

log_info "目标地址: root@${ROUTER_IP}"
echo "请输入 root SSH 密码 (已配置免密请直接回车):"
read -rs ROUTER_PASS
echo

if [[ -n "$ROUTER_PASS" ]] && ! command -v sshpass &>/dev/null; then
    log_warn "未检测到 sshpass，正在尝试自动安装..."
    if command -v pkg &>/dev/null; then
        pkg install -y sshpass >/dev/null 2>&1
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y sshpass >/dev/null 2>&1
    else
        log_err "无法自动安装 sshpass，请手动安装后重试。"
        exit 1
    fi
fi

readonly SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# ================================= 阶段 2: 路由器环境嗅探 =================================
log_step "2/6 路由器底层环境嗅探"

ARCH=$(ssh_exec "uname -m") || { log_err "无法连接路由器，请检查网络或密码"; exit 1; }

case "$ARCH" in
    x86_64)          GO_ARCH="amd64" ;;
    aarch64|armv8*)  GO_ARCH="arm64" ;;
    armv7*)          GO_ARCH="armv7" ;;
    mipsel)          GO_ARCH="mipsle" ;;
    mips)
        IS_LE=$(ssh_exec "grep -c 'mipsel' /proc/cpuinfo 2>/dev/null || echo 0")
        [[ "$IS_LE" -gt 0 ]] && GO_ARCH="mipsle" || GO_ARCH="mips"
        ;;
    *) log_err "不支持的 CPU 架构: $ARCH"; exit 1 ;;
esac
log_info "CPU 架构: $ARCH -> 映射为: $GO_ARCH"

PKG_MGR=$(ssh_exec "command -v opkg || command -v apt-get || command -v yum || echo 'none'")
log_info "包管理器: $PKG_MGR"

PERSIST_DIR="/data/x_toolkit"
HAS_DATA=$(ssh_exec "mount | grep -c ' /data ' || echo 0")
if [[ "$HAS_DATA" -eq 0 ]]; then
    log_warn "未检测到 /data 分区，将降级使用 /etc/x_toolkit"
    PERSIST_DIR="/etc/x_toolkit"
fi
log_info "持久化目录: $PERSIST_DIR"

# ================================= 阶段 3: 服务选择 =================================
log_step "3/6 选择要部署的服务"
echo -e "  ${C_CYAN}1${C_RESET} - DDNS-Go (动态域名解析)"
echo -e "  ${C_CYAN}2${C_RESET} - AdGuard Home (DNS 广告拦截)"
echo -e "  ${C_CYAN}3${C_RESET} - frpc (内网穿透客户端)"
echo -e "  ${C_CYAN}4${C_RESET} - mihomo / clash-meta (代理内核)"
echo -e "  ${C_CYAN}5${C_RESET} - MosDNS (DNS 分流与缓存)"
echo -e "  ${C_CYAN}6${C_RESET} - socat (端口转发工具)"
echo -e "  ${C_CYAN}7${C_RESET} - WireGuard (VPN 隧道)"
echo -e "  ${C_CYAN}8${C_RESET} - 全部安装"
echo -e "  ${C_CYAN}0${C_RESET} - 退出"
read -rp "请输入选项 [0-8]: " CHOICE

NEED_DDNS="no" NEED_AGH="no" NEED_FRPC="no" NEED_MIHOMO="no" NEED_MOSDNS="no" NEED_SOCAT="no" NEED_WG="no"

case "$CHOICE" in
    1) NEED_DDNS="yes" ;;
    2) NEED_AGH="yes" ;;
    3) NEED_FRPC="yes" ;;
    4) NEED_MIHOMO="yes" ;;
    5) NEED_MOSDNS="yes" ;;
    6) NEED_SOCAT="yes" ;;
    7) NEED_WG="yes" ;;
    8) NEED_DDNS="yes"; NEED_AGH="yes"; NEED_FRPC="yes"; NEED_MIHOMO="yes"; NEED_MOSDNS="yes"; NEED_SOCAT="yes"; NEED_WG="yes" ;;
    *) echo "已取消。"; exit 0 ;;
esac

# ================================= 阶段 4: 本地获取版本号 (防 API 限速与远程 BusyBox 兼容性问题) =================================
log_step "4/6 获取上游组件版本号"

VER_DDNS="" VER_FRPC="" VER_MOSDNS=""

if [[ "$NEED_DDNS" == "yes" ]]; then
    VER_DDNS=$(fetch_version "jeessy2/ddns-go")
    [[ -z "$VER_DDNS" ]] && { log_err "无法获取 DDNS-Go 版本号"; exit 1; }
    log_info "  DDNS-Go  -> v$VER_DDNS"
fi
if [[ "$NEED_FRPC" == "yes" ]]; then
    VER_FRPC=$(fetch_version "fatedier/frp")
    [[ -z "$VER_FRPC" ]] && { log_err "无法获取 frp 版本号"; exit 1; }
    log_info "  frpc     -> v$VER_FRPC"
fi
if [[ "$NEED_MOSDNS" == "yes" ]]; then
    VER_MOSDNS=$(fetch_version "IrineSistiana/mosdns")
    [[ -z "$VER_MOSDNS" ]] && { log_err "无法获取 MosDNS 版本号"; exit 1; }
    log_info "  MosDNS   -> v$VER_MOSDNS"
fi

# ================================= 阶段 5: 远程构建与部署 =================================
log_step "5/6 推送并执行远程部署脚本"
ssh_exec "mkdir -p $WORK_DIR $PERSIST_DIR"

# 注意：HEREDOC 无引号，本地变量(如 $GO_ARCH, $VER_DDNS)会被直接展开传递给远程
DEPLOY_CMD=$(cat <<REMOTE_SCRIPT
set -e
cd $WORK_DIR

# 通用下载函数 (Release Assets 必须直连 GitHub 或官方源，jsDelivr 不支持)
dl() {
    wget -q --no-check-certificate -O "\$1" "\$2" 2>/dev/null || \
    curl -fsSL -o "\$1" "\$2"
}

echo "[Remote] 开始下载与安装..."

# --- 1. DDNS-Go ---
if [ "$NEED_DDNS" = "yes" ]; then
    echo "  -> DDNS-Go (v${VER_DDNS})"
    case "$GO_ARCH" in
        amd64) DDNS_ARCH="linux_x86_64" ;;
        arm64) DDNS_ARCH="linux_arm64" ;;
        armv7) DDNS_ARCH="linux_armv7" ;;
        *)     DDNS_ARCH="linux_${GO_ARCH}" ;;
    esac
    dl "ddns.tar.gz" "${GITHUB_BASE}/jeessy2/ddns-go/releases/download/v${VER_DDNS}/ddns-go_${VER_DDNS}_\${DDNS_ARCH}.tar.gz"
    tar -zxf ddns.tar.gz
    mv -f ddns-go $PERSIST_DIR/ddns-go
    chmod +x $PERSIST_DIR/ddns-go
    rm -f ddns.tar.gz
fi

# --- 2. AdGuard Home ---
if [ "$NEED_AGH" = "yes" ]; then
    echo "  -> AdGuard Home"
    # 修复：使用 AdGuard 官方静态分发链接，避免 GitHub Release 404 或 jsDelivr 404
    dl "agh.tar.gz" "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${GO_ARCH}.tar.gz"
    tar -zxf agh.tar.gz
    mv -f AdGuardHome $PERSIST_DIR/AdGuardHome
    chmod +x $PERSIST_DIR/AdGuardHome/AdGuardHome
    rm -f agh.tar.gz
fi

# --- 3. frpc ---
if [ "$NEED_FRPC" = "yes" ]; then
    echo "  -> frpc (v${VER_FRPC})"
    dl "frp.tar.gz" "${GITHUB_BASE}/fatedier/frp/releases/download/v${VER_FRPC}/frp_${VER_FRPC}_linux_${GO_ARCH}.tar.gz"
    tar -zxf frp.tar.gz
    find . -name 'frpc' -type f -exec mv -f {} $PERSIST_DIR/frpc \;
    chmod +x $PERSIST_DIR/frpc
    rm -rf frp_* frp.tar.gz
fi

# --- 4. mihomo (clash-meta) ---
if [ "$NEED_MIHOMO" = "yes" ]; then
    echo "  -> mihomo"
    dl "mihomo.gz" "${GITHUB_BASE}/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${GO_ARCH}-compatible.gz"
    gunzip -f "mihomo.gz"
+    mv -f mihomo-linux-${GO_ARCH}-compatible $PERSIST_DIR/mihomo
    chmod +x $PERSIST_DIR/mihomo
fi

# --- 5. MosDNS ---
if [ "$NEED_MOSDNS" = "yes" ]; then
    echo "  -> MosDNS (v${VER_MOSDNS})"
    dl "mosdns.zip" "${GITHUB_BASE}/IrineSistiana/mosdns/releases/download/v${VER_MOSDNS}/mosdns-linux-${GO_ARCH}.zip"
    if command -v unzip >/dev/null 2>&1; then
        unzip -o mosdns.zip -d $PERSIST_DIR/ >/dev/null
    else
        python3 -c "import zipfile; zipfile.ZipFile('mosdns.zip').extractall('$PERSIST_DIR/')" 2>/dev/null || \
        busybox unzip -o mosdns.zip -d $PERSIST_DIR/ 2>/dev/null
    fi
    chmod +x $PERSIST_DIR/mosdns
    rm -f mosdns.zip
fi

# --- 6. socat ---
if [ "$NEED_SOCAT" = "yes" ]; then
    echo "  -> socat"
    if [ "$PKG_MGR" != "none" ]; then
        $PKG_MGR update -qq >/dev/null 2>&1 && $PKG_MGR install -y socat >/dev/null 2>&1 || echo "    安装失败"
    fi
fi

# --- 7. WireGuard ---
if [ "$NEED_WG" = "yes" ]; then
    echo "  -> WireGuard"
    if [ "$PKG_MGR" != "none" ]; then
        $PKG_MGR install -y wireguard-tools kmod-wireguard >/dev/null 2>&1 || echo "    安装失败"
    fi
fi

# ================================= 开机自启固化 =================================
echo "[Remote] 配置开机自启..."

if [ ! -f $BOOT_SCRIPT ]; then
    printf '#!/bin/sh\nexit 0\n' > $BOOT_SCRIPT
    chmod +x $BOOT_SCRIPT
fi

sed -i '/# === x_toolkit start ===/,/# === x_toolkit end ===/d' $BOOT_SCRIPT

STARTUP_FILE="/tmp/.x_startup.sh"
cat > \$STARTUP_FILE << 'STARTUP'
# === x_toolkit start ===
STARTUP

# 注意：此处的 $PERSIST_DIR 会被本地 bash 展开为实际路径（如 /data/x_toolkit），这是正确的行为
[ "$NEED_DDNS" = "yes" ]   && echo "(sleep 15 && $PERSIST_DIR/ddns-go -l :9876 -c $PERSIST_DIR/ddns-config.yaml >/dev/null 2>&1) &" >> \$STARTUP_FILE
[ "$NEED_AGH" = "yes" ]    && echo "(sleep 15 && $PERSIST_DIR/AdGuardHome/AdGuardHome -w $PERSIST_DIR/AdGuardHome -c $PERSIST_DIR/AdGuardHome/AdGuardHome.yaml >/dev/null 2>&1) &" >> \$STARTUP_FILE
[ "$NEED_FRPC" = "yes" ]   && echo "(sleep 15 && $PERSIST_DIR/frpc -c $PERSIST_DIR/frpc.toml >/dev/null 2>&1) &" >> \$STARTUP_FILE
[ "$NEED_MIHOMO" = "yes" ] && echo "(sleep 15 && $PERSIST_DIR/mihomo -d $PERSIST_DIR >/dev/null 2>&1) &" >> \$STARTUP_FILE
[ "$NEED_MOSDNS" = "yes" ] && echo "(sleep 15 && $PERSIST_DIR/mosdns start -c $PERSIST_DIR/mosdns-config.yaml >/dev/null 2>&1) &" >> \$STARTUP_FILE
echo "# === x_toolkit end ===" >> \$STARTUP_FILE

awk '
    /^exit 0/ {
        while ((getline line < "'\$STARTUP_FILE'") > 0) print line
        close("'\$STARTUP_FILE'")
    }
    {print}
' $BOOT_SCRIPT > /tmp/rc.local.new
mv -f /tmp/rc.local.new $BOOT_SCRIPT
chmod +x $BOOT_SCRIPT
rm -f \$STARTUP_FILE

echo "[Remote] 部署完成。"
REMOTE_SCRIPT
)

ssh_exec "$DEPLOY_CMD"

# ================================= 阶段 6: 校验与深度清理 =================================
log_step "6/6 部署校验与深度清理"

VERIFY_CMD=""
[[ "$NEED_DDNS" == "yes" ]]   && VERIFY_CMD+=" [ -x $PERSIST_DIR/ddns-go ] && echo '✅ ddns-go' || echo '❌ ddns-go';"
[[ "$NEED_AGH" == "yes" ]]    && VERIFY_CMD+=" [ -x $PERSIST_DIR/AdGuardHome/AdGuardHome ] && echo '✅ AdGuard Home' || echo '❌ AdGuard Home';"
[[ "$NEED_FRPC" == "yes" ]]   && VERIFY_CMD+=" [ -x $PERSIST_DIR/frpc ] && echo '✅ frpc' || echo '❌ frpc';"
[[ "$NEED_MIHOMO" == "yes" ]] && VERIFY_CMD+=" [ -x $PERSIST_DIR/mihomo ] && echo '✅ mihomo' || echo '❌ mihomo';"
[[ "$NEED_MOSDNS" == "yes" ]] && VERIFY_CMD+=" [ -x $PERSIST_DIR/mosdns ] && echo '✅ MosDNS' || echo '❌ MosDNS';"
[[ "$NEED_SOCAT" == "yes" ]]  && VERIFY_CMD+=" command -v socat >/dev/null && echo '✅ socat' || echo '❌ socat';"
[[ "$NEED_WG" == "yes" ]]     && VERIFY_CMD+=" command -v wg >/dev/null && echo '✅ WireGuard' || echo '❌ WireGuard';"

ssh_exec "$VERIFY_CMD"

log_info "清理路由器临时文件与缓存..."
ssh_exec "
    rm -rf $WORK_DIR
    rm -f /tmp/*.tar.gz /tmp/*.zip /tmp/*.gz
    command -v opkg >/dev/null && opkg clean 2>/dev/null || true
    find /var/log -type f -name '*.log' -exec truncate -s 0 {} \; 2>/dev/null || true
"

# ================================= 总结 =================================
echo
echo -e "${C_GREEN}=========================================${C_RESET}"
echo -e "${C_GREEN} 🎉 部署流程执行完毕！${C_RESET}"
echo -e "${C_GREEN}=========================================${C_RESET}"

[[ "$NEED_DDNS" == "yes" ]]   && echo -e " 🌐 DDNS-Go 控制台:  ${C_CYAN}http://${ROUTER_IP}:9876${C_RESET}"
[[ "$NEED_AGH" == "yes" ]]    && echo -e " 🛡️  AdGuard Home:    ${C_CYAN}http://${ROUTER_IP}:3000${C_RESET}"
[[ "$NEED_FRPC" == "yes" ]]   && echo -e " 🚇 frpc 配置文件:    ${C_YELLOW}$PERSIST_DIR/frpc.toml${C_RESET}"
[[ "$NEED_MIHOMO" == "yes" ]] && echo -e " 🚀 mihomo 配置目录:  ${C_YELLOW}$PERSIST_DIR/mihomo-config/${C_RESET}"
[[ "$NEED_MOSDNS" == "yes" ]] && echo -e " 🧩 MosDNS 配置文件:  ${C_YELLOW}$PERSIST_DIR/mosdns-config.yaml${C_RESET}"
[[ "$NEED_SOCAT" == "yes" ]]  && echo -e " 🔗 socat:            系统命令，使用 \`socat -h\` 查看帮助"
[[ "$NEED_WG" == "yes" ]]     && echo -e " 🔒 WireGuard:        系统命令，使用 \`wg -h\` 查看帮助"

echo
log_info "开机自启已写入: $BOOT_SCRIPT (延迟 15s 启动)"
log_warn "请先通过 SSH 创建对应的配置文件，再手动运行二进制文件测试！"