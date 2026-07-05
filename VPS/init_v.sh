#!/bin/bash
set -e

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" -ne 0 ] && err "请使用 root 运行。" && exit 1

# ── 交互: SSH 端口 ─────────────────────────────────────
DEF_SSH=22000
read -rp "新 SSH 端口 [${DEF_SSH}]: " SSH_NEW_PORT
SSH_NEW_PORT=${SSH_NEW_PORT:-$DEF_SSH}
while ! [[ "$SSH_NEW_PORT" =~ ^[0-9]+$ ]] || \
      [ "$SSH_NEW_PORT" -lt 1 ] || [ "$SSH_NEW_PORT" -gt 65535 ]; do
    warn "端口无效 (1-65535)"
    read -rp "新 SSH 端口 [${DEF_SSH}]: " SSH_NEW_PORT
    SSH_NEW_PORT=${SSH_NEW_PORT:-$DEF_SSH}
done

log "=== VPS 初始化 (1核/1.2G/17G/双栈/230ms跨国) ==="

# ═════════════  1. 系统更新  ══════════════════════
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # 禁用 needrestart 弹窗 (会话级)

# 持久化 needrestart 静默 (重启后也生效)
mkdir -p /etc/needrestart/conf.d/
echo '$nrconf{restart} = "a";' > /etc/needrestart/conf.d/99-automation.conf 2>/dev/null || true

apt update -y && apt upgrade -y
apt install -y curl tar wget tmux iperf3 mtr-tiny net-tools dnsutils lsof git sudo cron

# ════  2. 内存: zram + swap + earlyoom  ═══════════════
log "配置内存策略: zram(压缩优先) + swap(磁盘兜底) + earlyoom(防卡死)"

# zram: 用 CPU 压缩换内存空间，1 核机器避免过度压缩
apt install -y zram-tools
cat > /etc/default/zramswap <<EOF
ALGO=zstd
PERCENT=100
PRIORITY=100
EOF
systemctl restart zramswap

# swap: 磁盘兜底，优先级低于 zram
if [ ! -f /swapfile ]; then
    dd if=/dev/zero of=/swapfile bs=1M count=512
    chmod 600 /swapfile && mkswap /swapfile
    swapon -p 10 /swapfile
    echo '/swapfile none swap sw,pri=10 0 0' >> /etc/fstab
fi

# swappiness=60: 平衡压缩与换页，避免 1 核 CPU 争抢
{
    grep -q "^vm.swappiness" /etc/sysctl.conf \
        && sed -i 's/^vm.swappiness=.*/vm.swappiness=60/' /etc/sysctl.conf \

        || echo "vm.swappiness=60" >> /etc/sysctl.conf
}

# earlyoom: 内存<10% 时秒级杀进程，保护 sshd 免杀
apt install -y earlyoom
cat > /etc/default/earlyoom <<'EOF'
EARLYOOM_ARGS="-r 60 -m 10 -s 10 --prefer '^(sshd?)$' --avoid '^(systemd|dbus|cron|earlyoom)$'"
EOF
systemctl enable --now earlyoom

# ═══  3. 网络: BBR + 缓冲区(BDP≈21.6MB,取24MB) + 安全加固  ════
log "配置网络: BBR + 24MB 缓冲区 + TCP 加固"

modprobe tcp_bbr 2>/dev/null || true
grep -qxF 'tcp_bbr' /etc/modules-load.d/modules.conf 2>/dev/null \

    || echo 'tcp_bbr' >> /etc/modules-load.d/modules.conf

cat > /etc/sysctl.d/99-network-tuning.conf <<'EOF'
# 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1

# 缓冲区 (BDP=750Mbps×230ms≈21.6MB, 取 24MB)
net.core.rmem_max = 25165824
net.core.wmem_max = 25165824
net.ipv4.tcp_rmem = 4096 131072 25165824
net.ipv4.tcp_wmem = 4096 65536 25165824
net.ipv4.tcp_mem = 8192 32768 51200

# 连接管理
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Keepalive (600s/10s/5次: 快速清理死连接)
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5

# 文件描述符
fs.file-max = 1048576

# 安全加固
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_max_orphans = 16384
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
EOF
sysctl --system 2>&1 | grep -v "No such file or directory" || true

# 进程级文件描述符限制
cat > /etc/security/limits.d/99-fd.conf <<EOF
*    soft    nofile    524288
*    hard    nofile    1048576
root soft    nofile    524288
root hard    nofile    1048576
EOF
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-fd.conf <<EOF
[Manager]
DefaultLimitNOFILE=524288:1048576
EOF

# ═════════  4. IPv4/IPv6 出站优先级  ════════════════════════
log "测试 v4/v6 出站质量..."
host="www.cloudflare.com"
v4=$(curl -4 -o /dev/null -s --connect-timeout 3 -w '%{time_connect}' "https://${host}" 2>/dev/null) || v4=""
v6=$(curl -6 -o /dev/null -s --connect-timeout 3 -w '%{time_connect}' "https://${host}" 2>/dev/null) || v6=""
[ -z "$v4" ] && v4="999"
[ -z "$v6" ] && v6="999"
echo "  IPv4: ${v4}s | IPv6: ${v6}s"

sed -i '/^precedence ::ffff:0:0\/96/d' /etc/gai.conf
if awk "BEGIN{exit !($v4 < $v6)}"; then
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    log "IPv4 优先"
else
    log "IPv6 优先 (或 v4 不可用)"
fi

# ═════════  5. 日志与定时清理  ═══════════════════════════════
log "限制日志体积 + 定时清理"

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf <<EOF
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
EOF
systemctl restart systemd-journald

CRON="0 4 * * 0 apt-get autoremove -y && apt-get autoclean -y && journalctl --vacuum-time=7d"
(crontab -l 2>/dev/null | grep -vF "$CRON"; echo "$CRON") | crontab -

# ═══════════  6. 自动安全更新  ═══════════════════════════
log "启用自动安全更新"

apt install -y unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOAPT'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOAPT
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ════════════  7. 终端美化  ═══════════════════════════
log "安装 starship + 常用 alias"

if curl -fsSL https://starship.rs/install.sh -o /tmp/starship.sh; then
    sh /tmp/starship.sh -y
    grep -qxF 'eval "$(starship init bash)"' ~/.bashrc \

        || echo 'eval "$(starship init bash)"' >> ~/.bashrc
else
    warn "starship 下载失败，稍后手动安装"
fi
rm -f /tmp/starship.sh

grep -qxF "alias ll='ls -alF --color=auto'" ~/.bashrc || cat >> ~/.bashrc <<'EOF'
alias ll='ls -alF --color=auto'
alias grep='grep --color=auto'
EOF
apt install -y htop

# ══════════  8. 时区与精简服务  ══════════════════════════
log "设置时区 + 禁用无用服务"

timedatectl set-timezone Asia/Shanghai 2>/dev/null \

    || ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# VPS 无需这些服务，mask 防止被依赖拉起
for svc in ModemManager pollinate motd-news.timer; do
    systemctl disable --mask "$svc" 2>/dev/null || true
done

# ═════════  9. SSH 加固  ════════════════════════════════
log "配置 SSH (端口: ${SSH_NEW_PORT})"

mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

SKIP_KEY=0
if [ ! -s ~/.ssh/authorized_keys ]; then
    echo "未检测到公钥，请粘贴 SSH 公钥后回车:"
    read -r pubkey
    if [[ "$pubkey" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2|sk-ssh-ed25519) ]]; then
        echo "$pubkey" >> ~/.ssh/authorized_keys
        log "公钥已写入"
    else
        warn "未识别有效公钥，跳过关闭密码登录 (防锁死)"
        SKIP_KEY=1
    fi
fi

# 防火墙: limit = 30s/6次连接限制，零成本防爆破
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'old-ssh-temp'
ufw limit "${SSH_NEW_PORT}/tcp" comment 'new-ssh'
ufw --force enable

# sshd OOM 免死金牌 (兼容两种服务名)
for name in ssh sshd; do
    dir="/etc/systemd/system/${name}.service.d"
    mkdir -p "$dir"
    cat > "${dir}/99-oom-protect.conf" <<EOF
[Service]
OOMScoreAdjust=-1000
EOF
done
systemctl daemon-reload

if [ "$SKIP_KEY" -eq 0 ]; then
    # 清理主配置中的冲突项，保留 Port 22 兜底
    sed -i '/^Port /d; /^MaxAuthTries /d; /^LoginGraceTime /d; /^PasswordAuthentication /d; /^PubkeyAuthentication/d; /^MaxStartups /d' \
        /etc/ssh/sshd_config
    grep -q '^Port 22' /etc/ssh/sshd_config || echo "Port 22" >> /etc/ssh/sshd_config

    # 确保 drop-in 目录被加载
    grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config \

        || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config

    # 定制配置 (Port 22 在主配置兜底，此处只放新端口)
    cat > /etc/ssh/sshd_config.d/99-custom-security.conf <<EOF
Port ${SSH_NEW_PORT}
MaxAuthTries 3
MaxStartups 3:50:10
LoginGraceTime 30
PubkeyAuthentication yes
PasswordAuthentication no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    sshd -t && systemctl restart sshd && log "sshd 配置通过，已重启 (双端口监听)" \

        || err "sshd 配置语法错误，已跳过重启"
fi

# ═══════  10. 收尾  ═════════════════════════════════
apt-get autoremove -y >/dev/null 2>&1
apt-get autoclean -y >/dev/null 2>&1
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

cat <<'SUMMARY'

  ┌─────────────────────────────────────┐
  │         ✅ 初始化完成               │
  └─────────────────────────────────────┘
  ├─ BBR + 24MB 缓冲区
  ├─ zram(zstd) + swap(512MB)
  ├─ earlyoom 防卡死
  ├─ TCP Keepalive 600s / FD 524288
  ├─ UFW + limit 防爆破
  ├─ sshd OOM 保护
  ├─ 自动安全更新
  └─ 日志 100M + 每周清理

SUMMARY

if [ "$SKIP_KEY" -eq 0 ]; then
    cat <<EOF
  ⚠️  请【新开终端】验证登录:
     ssh -p ${SSH_NEW_PORT} 用户名@服务器IP

  确认无误后执行收尾:
     ufw delete limit 22/tcp
     sed -i '/^Port 22\$/d' /etc/ssh/sshd_config
     systemctl restart sshd

EOF
fi

echo "  执行 source ~/.bashrc 让终端美化生效"
echo ""

# ══════ 11. 自毁 ══════════════════════════
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
[ -f "$SELF" ] && [ "$SELF" != "bash" ] && [ "$SELF" != "-bash" ] && [ "$SELF" != "/dev/stdin" ] && {
    log "删除脚本: ${SELF}"
    rm -f "$SELF"
}
