#!/bin/bash
set -e

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" -ne 0 ] && err "请使用 root 运行。" && exit 1

DEF_SSH=22000
read -rp "新 SSH 端口 [${DEF_SSH}]: " SSH_NEW_PORT
SSH_NEW_PORT=${SSH_NEW_PORT:-$DEF_SSH}
while ! [[ "$SSH_NEW_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_NEW_PORT" -lt 1 ] || [ "$SSH_NEW_PORT" -gt 65535 ]; do
    warn "端口无效 (1-65535)"
    read -rp "新 SSH 端口 [${DEF_SSH}]: " SSH_NEW_PORT
    SSH_NEW_PORT=${SSH_NEW_PORT:-$DEF_SSH}
done

log "=== VPS 初始化(1核/1.2G/17G/纯zram/双栈) ==="

# ==================== 1. 系统更新 ====================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
mkdir -p /etc/needrestart/conf.d/
echo '$nrconf{restart} = "a";' > /etc/needrestart/conf.d/99-automation.conf

apt update -y
apt upgrade -y
apt install -y curl wget tmux mtr-tiny dnsutils htop ufw cron

# ==================== 2. 内存: 纯物理内存 + zram + earlyoom(不用磁盘swap) ====================
# 抹除可能残留的磁盘 Swap 挂载，确保纯 zRAM 高速运行
if [ -f /swapfile ]; then
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab
fi
log "配置 zram..."
apt install -y zram-tools
cat > /etc/default/zramswap <<EOF
ALGO=zstd
PERCENT=100
EOF
systemctl enable --now zramswap

if grep -q "^vm.swappiness" /etc/sysctl.conf; then
    sed -i 's/^vm.swappiness=.*/vm.swappiness=100/' /etc/sysctl.conf
else
    echo "vm.swappiness=100" >> /etc/sysctl.conf
fi
# 只有1核, zram压缩要吃CPU。如果之后 htop 里发现 CPU 经常被压缩占满,
# 把这个数字调低(比如60), 让系统没那么积极地换页

log "配置 earlyoom(内存<10%时优先保护sshd, 抢在内核OOM killer之前)..."
apt install -y earlyoom
cat > /etc/default/earlyoom <<'EOF'
EARLYOOM_ARGS="-r 60 -m 10 -s 10 --prefer ^(sshd?)$ --avoid ^(systemd|dbus|cron|earlyoom)$"
EOF
systemctl enable --now earlyoom

# ==================== 3. 网络参数(精简版, 只留个人轻量使用真正用得上的) ====================
log "配置 BBR 与网络参数..."
cat > /etc/sysctl.d/99-network-tuning.conf <<'EOF'
# 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# PLPMTUD: 常规ICMP路径MTU探测被中间设备屏蔽时, 让内核自己摸出实际可通过的包大小
net.ipv4.tcp_mtu_probing = 1

# 缓冲区上限(按700-800Mbps x 230ms估算BDP≈21.6MB, 取24MB留余量)
# 这只是上限不是预分配, 某条链路实际跑不满, 这个值放着也没有副作用
net.core.rmem_max = 25165824
net.core.wmem_max = 25165824
net.ipv4.tcp_rmem = 4096 131072 25165824
net.ipv4.tcp_wmem = 4096 65536 25165824
net.ipv4.tcp_mem = 8192 32768 51200

# 连接质量不稳时更快发现死连接, 不用等默认2小时
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5

# 基础安全加固
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
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
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
EOF
sysctl --system
# 没加 accept_ra=0: 你的v6是服务商分配的/64段, 手动配置了多个地址在用,
# 路由到底靠不靠RA不确定, 贸然关掉有直接断v6的风险

# ==================== 4. 磁盘、日志、定时清理 ====================
log "限制日志体积、定时清理..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf <<EOF
[Journal]
SystemMaxUse=100M
EOF
systemctl restart systemd-journald

CRON="0 4 * * 0 apt-get autoremove -y && apt-get autoclean -y && journalctl --vacuum-time=7d"
EXISTING_CRON=$(crontab -l 2>/dev/null | grep -vF "$CRON" || true)
{ [ -n "$EXISTING_CRON" ] && echo "$EXISTING_CRON"; echo "$CRON"; } | crontab -

# ==================== 5. 自动安全更新 ====================
log "配置自动安全更新..."
apt install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ==================== 6. 终端美化与高级 Shell 部署 (Zsh + Oh My Zsh) ====================
log "安装并配置 Zsh 软件生态..."

# 1. 安装 Zsh 核心及基础依赖，并强行将 root 的默认 Shell 修改为 Zsh
apt install -y zsh git curl
chsh -s $(which zsh)

# 2. 自动化拉取 Oh My Zsh 框架
# 增加 --unattended 参数防止脚本在此处弹出交互式终端打断你的自动化流程
log "正在拉取 Oh My Zsh 官方框架..."
if ! sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; then
    warn "官方 Oh My Zsh 下载超时，尝试切换国内 Gitee 镜像加速源..."
    sh -c "$(curl -fsSL https://gitee.com/mirrors/ohmyzsh/raw/master/tools/install.sh)" "" --unattended || true
fi

# 3. 异步拉取高级自愈插件（灰色阴影自动补全 + 实时代码高亮）
log "正在注入高级补全与高亮软件..."
ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins"
mkdir -p "$ZSH_CUSTOM_DIR"

# 针对 RackNerd 跨国网络长途抖动，采用或门逻辑防止下载失败中断整个脚本
git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM_DIR/zsh-autosuggestions" 2>/dev/null || true
git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_CUSTOM_DIR/zsh-syntax-highlighting" 2>/dev/null || true

# 4. 强行固化配置到新生成的 ~/.zshrc 配置文件中
if [ -f ~/.zshrc ]; then
    # 动态将默认的 plugins=(git) 替换为挂载了高级补全和高亮的完整软件列表
    sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc

    # 注入标准高亮彩色别名（Alias）
    grep -qxF "alias ll='ls -alF --color=auto'" ~/.zshrc || cat >> ~/.zshrc <<'EOF'
alias ll='ls -alF --color=auto'
alias grep='grep --color=auto'
EOF
else
    warn "未检测到 ~/.zshrc，可能框架未能成功写入"
fi

# ==================== 7. SSH 安全加固(密钥+改端口+防火墙, 不装fail2ban) ====================
log "配置 SSH(端口: ${SSH_NEW_PORT})..."
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

SKIP_KEY_HARDENING=0
if [ ! -s ~/.ssh/authorized_keys ]; then
    echo "未检测到公钥,请粘贴你的 SSH 公钥后回车:"
    read -r pubkey
    if [[ "$pubkey" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2|sk-ssh-ed25519) ]]; then
        echo "$pubkey" >> ~/.ssh/authorized_keys
        log "公钥已写入"
    else
        warn "未识别到有效公钥,跳过密码登录关闭步骤,避免锁死"
        SKIP_KEY_HARDENING=1
    fi
fi

# sshd OOM保护: 内存告急时不会因为sshd被kill导致彻底失联
for name in ssh sshd; do
    dir="/etc/systemd/system/${name}.service.d"
    mkdir -p "$dir"
    cat > "${dir}/99-oom-protect.conf" <<EOF
[Service]
OOMScoreAdjust=-1000
EOF
done
systemctl daemon-reload

# limit而不是allow: 对同一来源短时间内的连接尝试做频次限制, 零额外进程,
# 算是不装fail2ban情况下的轻量替代
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'old-ssh-temp'
ufw limit "${SSH_NEW_PORT}/tcp" comment 'new-ssh'
ufw --force enable

if [ "$SKIP_KEY_HARDENING" -eq 0 ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    sed -i '/^Port /d; /^MaxAuthTries /d; /^LoginGraceTime /d; /^PasswordAuthentication /d; /^MaxStartups /d' /etc/ssh/sshd_config
    cat >> /etc/ssh/sshd_config <<EOF
Port 22
Port ${SSH_NEW_PORT}
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 3:50:10
PasswordAuthentication no
EOF
    if sshd -t; then
        systemctl restart sshd
        log "sshd 配置检查通过,已重启,新旧端口同时监听"
    else
        err "sshd 配置语法有误,已跳过重启,备份在 sshd_config.bak"
    fi
fi

# ==================== 收尾 ====================
apt-get autoremove -y
apt-get autoclean -y

echo ""
log "=== 初始化完成 ==="
if [ "$SKIP_KEY_HARDENING" -eq 0 ]; then
    echo "[重要] 请【新开一个终端】测试: ssh -p ${SSH_NEW_PORT} 用户名@服务器IP"
    echo "用 ss -tlnp | grep sshd 确认22和${SSH_NEW_PORT}是否都在监听"
    echo "确认能登录后手动执行收尾:"
    echo "    ufw delete limit 22/tcp"
    echo "    sed -i '/^Port 22\$/d' /etc/ssh/sshd_config"
    echo "    systemctl restart sshd"
fi
echo "执行 source ~/.zshrc 让终端美化生效"
echo ""
echo "[网络] v4/v6具体走哪个、线路质量如何, 脚本不自动判断了, 在你自己电脑上手动测(不是在VPS上跑):"
echo "    bash <(curl -Ls IP.Check.Place)      # IP质量体检, 默认双栈"
echo "    bash <(curl -Ls Net.Check.Place)     # 更全: BGP/回程路由/分地区测速, 耗时8-10分钟"
echo "两个都是 github.com/xykt 的开源脚本, 测完自己决定SSH以后主要用哪个地址连"
echo "还要修改优化dns配置，比如v4还是v6优先"
