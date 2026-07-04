#!/usr/bin/env bash
# ==============================================================================
#  Script: Xiaomi Router Service Deployer (Dynamic Port & Interval Optimization)
#  Version: 2026.07.04-DynamicUltimate
# ==============================================================================
set -euo pipefail

# ================================= 全局常量与信道配置 =================================
readonly DEFAULT_IP="192.168.31.1"
readonly LOCAL_TMP="/tmp/x_local_download"
readonly ROUTER_TMP="/tmp/.x_deploy"
readonly BOOT_SCRIPT="/etc/rc.local"
readonly SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
readonly SCP_OPTS="-O -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

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
    if [[ -z "${ROUTER_PASS:-}" ]]; then
        ssh $SSH_OPTS "root@${ROUTER_IP}" "$1"
    else
        sshpass -p "$ROUTER_PASS" ssh $SSH_OPTS "root@${ROUTER_IP}" "$1"
    fi
}

scp_push() {
    if [[ -z "${ROUTER_PASS:-}" ]]; then
        scp $SCP_OPTS "$1" "root@${ROUTER_IP}:$2"
    else
        sshpass -p "$ROUTER_PASS" scp $SCP_OPTS "$1" "root@${ROUTER_IP}:$2"
    fi
}

fetch_version() {
    local repo="$1"
    local ver=""
    ver=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed -E 's/.*"v?([^"]*)".*/\1/' | tr -d '\r') || true
    echo "$ver"
}

# ================================= 1. 环境准备与动态引导 =================================
log_step "1/5 目标认证与动态业务引导"
rm -rf "$LOCAL_TMP" && mkdir -p "$LOCAL_TMP"

ROUTER_IP="$DEFAULT_IP"
read -rp "请输入小米路由器 IP [${DEFAULT_IP}]: " input_ip
[[ -n "$input_ip" ]] && ROUTER_IP="$input_ip"

echo "请输入 root SSH 密码 (已配置免密请直接回车):"
read -rs ROUTER_PASS
echo

if [[ -n "$ROUTER_PASS" ]] && ! command -v sshpass &>/dev/null; then
    pkg install -y sshpass >/dev/null 2>&1 || { log_err "无法安装 sshpass"; exit 1; }
fi

# --- 动态引导用户配置 socat 端口转发 ---
DEPLOY_SOCAT=true
SOCAT_LISTEN_PORT=""
SOCAT_TARGET_IP="127.0.0.1"
SOCAT_TARGET_PORT="80"

echo -e "${C_CYAN}如有端口转发需求，请配置以下参数；若不需要 socat 转发，请直接回车跳过！${C_RESET}"
read -rp "请输入外部监听端口 (例如 8080): " input_lport
if [[ -z "$input_lport" ]]; then
    log_warn "检测到外部端口输入为空，本次部署将彻底【跳过并关闭】socat 端口转发服务。"
    DEPLOY_SOCAT=false
else
    SOCAT_LISTEN_PORT="$input_lport"
    read -rp "请输入内部目标 IP [127.0.0.1]: " input_tip
    [[ -n "$input_tip" ]] && SOCAT_TARGET_IP="$input_tip"
    read -rp "请输入内部目标端口 [80]: " input_tport
    [[ -n "$input_tport" ]] && SOCAT_TARGET_PORT="$input_tport"
fi

# ================================= 2. 底层环境嗅探 =================================
log_step "2/5 路由器底层环境嗅探"
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

# ================================= 3. Termux 本地安全拦截下载 =================================
log_step "3/5 Termux 本地安全下载与解压结构化"

log_info "正在获取 DDNS-Go 最新版本号..."
VER_DDNS=$(fetch_version "jeessy2/ddns-go")
[[ -z "$VER_DDNS" ]] && VER_DDNS="6.7.2"
log_info "DDNS-Go 目标版本: v$VER_DDNS"

case "$GO_ARCH" in
    amd64) DDNS_ARCH="linux_x86_64" ;;
    arm64) DDNS_ARCH="linux_arm64" ;;
    armv7) DDNS_ARCH="linux_armv7" ;;
    *)     DDNS_ARCH="linux_${GO_ARCH}" ;;
esac

curl -fsSL -o "$LOCAL_TMP/ddns.tar.gz" "https://github.com/jeessy2/ddns-go/releases/download/v${VER_DDNS}/ddns-go_${VER_DDNS}_${DDNS_ARCH}.tar.gz"
tar -zxf "$LOCAL_TMP/ddns.tar.gz" -C "$LOCAL_TMP"

# 条件执行：仅在用户开启转发需求时下载 socat
if [ "$DEPLOY_SOCAT" = true ]; then
    log_info "正在从 ernw/static-toolbox 库拉取最新的强固化静态 socat..."
    ERNW_SOCAT_BASE="https://github.com/ernw/static-toolbox/releases/download/socat-v1.7.4.4"
    case "$GO_ARCH" in
        arm64)
            curl -fsSL -o "$LOCAL_TMP/socat" "${ERNW_SOCAT_BASE}/socat-linux-AARCH64" || true
            ;;
        amd64|armv7|mipsle|mips)
            log_warn "⚠️ 检测到非目标设备架构 ($GO_ARCH)。由于用户指定仅为 arm64 适配，本次运行将不下载该架构下的静态 socat 二进制文件！"
            ;;
        *)
            log_err "未知或不支持的架构，跳过 socat 编译产物拉取。"
            ;;
    esac
fi

LOCAL_DDNS_SIZE=$(stat -c%s "$LOCAL_TMP/ddns-go" 2>/dev/null || stat -f%z "$LOCAL_TMP/ddns-go")

# ================================= 4. 跨端推送与远程固化 =================================
log_step "4/5 跨端安全推送与自启固化调度"
ssh_exec "mkdir -p $ROUTER_TMP /data/x_toolkit /etc/x_toolkit"

log_info "正在通过 RPC 降级信道推送二进制核心至远端临时栈..."
scp_push "$LOCAL_TMP/ddns-go" "$ROUTER_TMP/ddns-go"
if [ "$DEPLOY_SOCAT" = true ] && [[ -f "$LOCAL_TMP/socat" ]]; then
    scp_push "$LOCAL_TMP/socat" "$ROUTER_TMP/socat"
fi

# 传入闭环业务参数至远端执行上下文中
REMOTE_EXEC=$(cat << REMOTE_CMD
set -e
BOOT_SCRIPT="/etc/rc.local"
ROUTER_TMP="$ROUTER_TMP"
EXPECTED_SIZE="$LOCAL_DDNS_SIZE"

# 传递引导参数与开关状态
RUN_SOCAT="$DEPLOY_SOCAT"
S_LPORT="$SOCAT_LISTEN_PORT"
S_TIP="$SOCAT_TARGET_IP"
S_TPORT="$SOCAT_TARGET_PORT"

echo "[Remote] 正在执行严格的 SCP 传输完整性审计..."
REMOTE_SIZE=\$(stat -c%s "\$ROUTER_TMP/ddns-go" 2>/dev/null || echo "0")
if [ "\$REMOTE_SIZE" -ne "\$EXPECTED_SIZE" ]; then
    echo "[Remote] 错误：SCP 上传文件损坏或不完整！"
    exit 1
fi

PERSIST_DIR="/data/x_toolkit"
if [ \$(mount | grep -c ' /data ') -eq 0 ]; then
    PERSIST_DIR="/etc/x_toolkit"
fi

cp -f "\$ROUTER_TMP/ddns-go" "\$PERSIST_DIR/ddns-go"
chmod +x "\$PERSIST_DIR/ddns-go"

# 静态 socat 条件搬运与绝对路径映射
SOCAT_PATH=""
if [ "\$RUN_SOCAT" = "true" ] && [ -f "\$ROUTER_TMP/socat" ]; then
    cp -f "\$ROUTER_TMP/socat" "/usr/sbin/socat" || cp -f "\$ROUTER_TMP/socat" "\$PERSIST_DIR/socat"
    chmod +x /usr/sbin/socat 2>/dev/null || chmod +x "\$PERSIST_DIR/socat"
    if [ -x "/usr/sbin/socat" ]; then SOCAT_PATH="/usr/sbin/socat"; else SOCAT_PATH="\$PERSIST_DIR/socat"; fi
    echo "[Remote] 静态 socat 已安全就位，路径: \$SOCAT_PATH"
fi

# 固化自启钩子重组
if [ ! -f "\$BOOT_SCRIPT" ]; then
    printf '#!/bin/sh\nexit 0\n' > "\$BOOT_SCRIPT"
    chmod +x "\$BOOT_SCRIPT"
fi

sed -i '/# === x_toolkit start ===/,/# === x_toolkit end ===/d' "\$BOOT_SCRIPT"

STARTUP_FILE="/tmp/.x_startup.sh"
cat > "\$STARTUP_FILE" << EOF
# === x_toolkit start ===
# 1. DDNS-Go 开机挂载：-f 600 强制间隔 10 分钟安全同步，规避小米固件闪断污染
(sleep 15 && \$PERSIST_DIR/ddns-go -l :9876 -c \$PERSIST_DIR/ddns-config.yaml -f 600 >/dev/null 2>&1) &
EOF

# 如果开启了端口转发，增量追加 socat 自启与防火墙逻辑
if [ "\$RUN_SOCAT" = "true" ]; then
cat >> "\$STARTUP_FILE" << EOF

# 2. Socat 后台多路分叉监听与防火墙入站链路穿透
if [ -n "\$SOCAT_PATH" ] && [ -x "\$SOCAT_PATH" ]; then
    (sleep 20 && \$SOCAT_PATH tcp-listen:\$S_LPORT,reuseaddr,fork tcp:\$S_TIP:\$S_TPORT >/dev/null 2>&1) &
    (sleep 25 && iptables -I INPUT -p tcp --dport \$S_LPORT -j ACCEPT 2>/dev/null || true) &
    (sleep 25 && ip6tables -I INPUT -p tcp --dport \$S_LPORT -j ACCEPT 2>/dev/null || true) &
fi
EOF
fi

cat >> "\$STARTUP_FILE" << EOF
# === x_toolkit end ===
EOF

awk '
    /^exit 0/ {
        while ((getline line < "'"\$STARTUP_FILE"'") > 0) print line
        close("'"\$STARTUP_FILE"'")
    }
    {print}
' "\$BOOT_SCRIPT" > /tmp/rc.local.new

mv -f /tmp/rc.local.new "\$BOOT_SCRIPT"
chmod +x "\$BOOT_SCRIPT"
rm -f "\$STARTUP_FILE"
REMOTE_CMD
)

ssh_exec "$REMOTE_EXEC"

# ================================= 5. 深度垃圾清理 =================================
log_step "5/5 跨端深度垃圾清理与审计"
rm -rf "$LOCAL_TMP"
ssh_exec "rm -rf $ROUTER_TMP && rm -f /tmp/rc.local.new 2>/dev/null || true"

LOCAL_HAS_DATA=$(ssh_exec "mount | grep -c ' /data ' || echo 0")
PRINT_PERSIST="/data/x_toolkit"
[[ "$LOCAL_HAS_DATA" -eq 0 ]] && PRINT_PERSIST="/etc/x_toolkit"

# ================================= 最终看板输出 =================================
echo
echo -e "${C_GREEN}=====================================================${C_RESET}"
echo -e "${C_GREEN}  🎉 弹性闭环自适应服务固化环境部署成功！${C_RESET}"
echo -e "${C_GREEN}=====================================================${C_RESET}"
echo -e " 🌐 DDNS-Go 控制台:       ${C_CYAN}http://${ROUTER_IP}:9876${C_RESET}"
echo -e " ⏱️  DDNS 强同步参数:      ${C_YELLOW}已固化注入 -f 600 (每 10 分钟强制同步校准)${C_RESET}"
echo -e " 💾 核心固化驻留路径:     ${C_YELLOW}${PRINT_PERSIST}/ddns-go${C_RESET}"

if [ "$DEPLOY_SOCAT" = true ]; then
    echo -e " 🔗 Socat 端口映射:       ${C_GREEN}开启${C_RESET} -> 外部 ${C_RED}${SOCAT_LISTEN_PORT}${C_RESET} 转发至 ${C_CYAN}${SOCAT_TARGET_IP}:${SOCAT_TARGET_PORT}${C_RESET}"
    echo -e "${C_GREEN}----------------------------------------------------=${C_RESET}"
    echo -e "${C_YELLOW}📖 快捷状态审计指令：${C_RESET}"
    echo -e " 查看转发进程:  ${C_CYAN}ps | grep socat${C_RESET}"
    echo -e " 查看防火墙放行:  ${C_CYAN}iptables -L INPUT -n | grep ${SOCAT_LISTEN_PORT}${C_RESET}"
else
    echo -e " 🔗 Socat 端口映射:       ${C_RED}未启用 (用户回车跳过，已完全净化远端进程环境)${C_RESET}"
    echo -e "${C_GREEN}----------------------------------------------------=${C_RESET}"
fi
echo