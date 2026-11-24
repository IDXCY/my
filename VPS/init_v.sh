#!/usr/bin/env bash
set -euo pipefail

# ==================== 基础工具与全局状态 ====================
log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" -ne 0 ] && err "请使用 root 权限运行 (sudo bash $0)" && exit 1

IS_WSL=0
grep -qiE "microsoft|wsl" /proc/version 2>/dev/null && IS_WSL=1
PROXY_USED=0

# 自动识别真实操作用户（兼容 sudo 运行与直接 root 登录）
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(eval echo "~$TARGET_USER")

# 通用写入函数：自动创建目录并写入标准输入
write_file() {
    mkdir -p "$(dirname "$1")"
    cat > "$1"
}

cleanup() {
    if [ "$PROXY_USED" -eq 1 ]; then
        git config --global --unset http.proxy 2>/dev/null || true
        git config --global --unset https.proxy 2>/dev/null || true
        rm -f /etc/apt/apt.conf.d/80proxy
        log "已自动清理临时代理通道。"
    fi
}
trap cleanup EXIT

# ==================== 1. DNS 与双栈优先级 ====================
setup_dns_and_dualstack() {
    if [ "$IS_WSL" -eq 0 ]; then
        log "配置 VPS DNS..."
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            write_file /etc/systemd/resolved.conf.d/99-dns.conf <<'EOF'
[Resolve]
DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
FallbackDNS=8.8.8.8 8.8.4.4
EOF
            systemctl restart systemd-resolved
        else
            chattr -i /etc/resolv.conf 2>/dev/null || true
            printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > /etc/resolv.conf
        fi
    fi

    log "测速对比 IPv4 与 IPv6 响应速度..."
    local t_v4 t_v6
    t_v4=$(curl -4 -o /dev/null -s -w '%{time_connect}' --connect-timeout 3 http://1.1.1 2>/dev/null || echo "999")
    t_v6=$(curl -6 -o /dev/null -s -w '%{time_connect}' --connect-timeout 3 http://[2606:4700:4700::1111] 2>/dev/null || echo "999")
    log "测速结果 -> IPv4: ${t_v4}s | IPv6: ${t_v6}s"

    touch /etc/gai.conf
    sed -i '/^precedence ::ffff:0:0\/96/d' /etc/gai.conf
    if awk -v v4="$t_v4" -v v6="$t_v6" 'BEGIN {exit !(v4 <= v6)}'; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
        log "已设定: IPv4 优先"
    else
        echo "precedence ::ffff:0:0/96  10" >> /etc/gai.conf
        log "已设定: IPv6 优先"
    fi
}

# ==================== 2. 智能代理探测 ====================
setup_network_proxy() {
    log "检测外网直连连通性..."
    curl -fsIL --connect-timeout 3 https://google.com >/dev/null 2>&1 && return 0

    warn "外网直连超时！"
    local def_proxy="127.0.0.1:10808" proxy_input
    read -rp "请输入本地代理地址 [默认 ${def_proxy}，回车使用，输入 skip 跳过]: " proxy_input
    [[ "$proxy_input" == "skip" ]] && warn "已跳过代理，将启用镜像加速。" && return 0

    local proxy_url="${proxy_input:-$def_proxy}"
    [[ "$proxy_url" != *"://"* ]] && proxy_url="http://${proxy_url}"

    export http_proxy="$proxy_url" https_proxy="$proxy_url" all_proxy="$proxy_url"
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$proxy_url" "$proxy_url" > /etc/apt/apt.conf.d/80proxy
    PROXY_USED=1
    log "已临时挂载代理: ${proxy_url}"
}

# ==================== 3. 基础软件包安装 ====================
setup_base_packages() {
    log "更新系统并安装基础工具..."
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    write_file /etc/needrestart/conf.d/99-automation.conf <<< '$nrconf{restart} = "a";'

    apt-get update -y && apt-get upgrade -y
    apt-get install -y curl wget git zsh tmux tree htop ncdu vim dnsutils mtr-tiny cron

    if [ "$PROXY_USED" -eq 1 ]; then
        git config --global http.proxy "$http_proxy"
        git config --global https.proxy "$https_proxy"
    fi
}

# ==================== 4. Zsh + Oh My Zsh 环境 ====================
clone_github() {
    rm -rf ~/.oh-my-zsh
    local repo="$1" target_dir="$2"
    [ -d "$target_dir" ] && return 0

    local url="https://github.com/${repo}.git"
    if ! git clone --depth=1 "$url" "$target_dir" 2>/dev/null; then
        warn "GitHub 克隆 ${repo} 失败，尝试镜像加速..."
        git clone --depth=1 "https://gh-proxy.com/${url}" "$target_dir" || warn "${repo} 克隆失败，已跳过"
    fi
}

setup_zsh_env() {
    log "部署 Zsh 与 Oh My Zsh (目标用户: ${TARGET_USER})..."
    local zsh_dir="${TARGET_HOME}/.oh-my-zsh"

    clone_github "ohmyzsh/ohmyzsh" "$zsh_dir"
    clone_github "zsh-users/zsh-autosuggestions" "$zsh_dir/custom/plugins/zsh-autosuggestions"
    clone_github "zsh-users/zsh-syntax-highlighting" "$zsh_dir/custom/plugins/zsh-syntax-highlighting"

    write_file "${TARGET_HOME}/.zshrc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"

export HISTFILE="$HOME/.zsh_history" HISTSIZE=5000 SAVEHIST=5000
setopt BANG_HIST EXTENDED_HISTORY INC_APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE
alias ll='ls -alF --color=auto' grep='grep --color=auto'
EOF

    chown -R "${TARGET_USER}:${TARGET_USER}" "$zsh_dir" "${TARGET_HOME}/.zshrc"
    chsh -s "$(command -v zsh)" "$TARGET_USER"
}

# ==================== 5. VPS 专属调优 ====================
setup_vps_tuning() {
    log "配置 zRAM、earlyoom 与内核参数..."
    if [ -f /swapfile ]; then
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        sed -i '/\/swapfile/d' /etc/fstab
    fi

    apt-get install -y zram-tools earlyoom unattended-upgrades
    write_file /etc/default/zramswap <<< $'ALGO=zstd\nPERCENT=100'
    write_file /etc/default/earlyoom <<< 'EARLYOOM_ARGS="-r 60 -m 10 -s 10 --prefer ^(sshd?)$ --avoid ^(systemd|dbus|cron|earlyoom)$"'
    systemctl enable --now zramswap earlyoom

    write_file /etc/sysctl.d/99-vps-tuning.conf <<'EOF'
vm.swappiness = 100
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 25165824
net.core.wmem_max = 25165824
net.ipv4.tcp_rmem = 4096 131072 25165824
net.ipv4.tcp_wmem = 4096 65536 25165824
net.ipv4.tcp_mem = 8192 32768 51200
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
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
    sysctl --system >/dev/null

    log "限制日志体积并配置自动安全更新..."
    write_file /etc/systemd/journald.conf.d/size.conf <<< $'[Journal]\nSystemMaxUse=100M'
    systemctl restart systemd-journald

    local cron_job="0 4 * * 0 apt-get autoremove -y && apt-get autoclean -y && journalctl --vacuum-time=7d"
    (crontab -l 2>/dev/null | grep -vF "$cron_job" || true; echo "$cron_job") | crontab -

    write_file /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    write_file /etc/apt/apt.conf.d/20auto-upgrades <<< $'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";'
}

# ==================== 6. VPS 专属: SSH 双端口平滑加固与防火墙 ====================
setup_vps_security() {
    log "配置 SSH 双端口平滑加固与 UFW 防火墙..."
    local def_ssh=22000 ssh_new_port
    read -rp "请输入新 SSH 端口 [默认 ${def_ssh}]: " ssh_new_port
    ssh_new_port=${ssh_new_port:-$def_ssh}

    while ! [[ "$ssh_new_port" =~ ^[0-9]+$ ]] || [ "$ssh_new_port" -lt 1 ] || [ "$ssh_new_port" -gt 65535 ]; do
        warn "端口无效 (1-65535)"
        read -rp "请输入新 SSH 端口 [默认 ${def_ssh}]: " ssh_new_port
        ssh_new_port=${ssh_new_port:-$def_ssh}
    done

    # 部署公钥到当前实际操作用户（避免 sudo 时写错到 /root）
    local ssh_dir="${TARGET_HOME}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"
    mkdir -p "$ssh_dir" && chmod 700 "$ssh_dir"
    touch "$auth_keys" && chmod 600 "$auth_keys"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$ssh_dir"

    local skip_key=0
    if [ ! -s "$auth_keys" ]; then
        read -rp "未检测到公钥，请粘贴 SSH 公钥后回车 (直接回车跳过): " pubkey
        if [[ "$pubkey" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2|sk-ssh-ed25519) ]]; then
            echo "$pubkey" >> "$auth_keys"
            log "公钥已写入 ${auth_keys}"
        else
            warn "未识别到有效公钥，保留密码登录以防锁死"
            skip_key=1
        fi
    fi

    # sshd OOM 保护
    for name in ssh sshd; do
        write_file "/etc/systemd/system/${name}.service.d/99-oom-protect.conf" <<< $'[Service]\nOOMScoreAdjust=-1000'
    done

    # 解决 Ubuntu 22.04/24.04 ssh.socket 接管端口导致改端口失效的问题
    systemctl disable --now ssh.socket 2>/dev/null || true
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    systemctl daemon-reload

    # 配置 UFW 防火墙（同时放行 22 与新端口以便平滑过渡）
    apt-get install -y ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw limit 22/tcp comment 'old-ssh-temp'
    ufw limit "${ssh_new_port}/tcp" comment 'new-ssh'
    ufw --force enable

    # 确保主配置包含 Include 指令
    grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config

    # 写入 00- 前缀子文件，确保优先级高于云厂商的 50-cloud-init.conf
    write_file /etc/ssh/sshd_config.d/00-custom-hardening.conf <<EOF
Port 22
Port ${ssh_new_port}
PubkeyAuthentication yes
PasswordAuthentication $([ "$skip_key" -eq 0 ] && echo "no" || echo "yes")
PermitRootLogin prohibit-password
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

    # 校验配置语法无误后再重启 SSH 服务
    if sshd -t; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
log "SSH 加固完成！当前同时监听 22 与 ${ssh_new_port} 端口。"
warn "请新开终端测试使用 ${ssh_new_port} 端口登录成功后，再手动移除 22 端口！"
else
err "sshd 配置校验失败，已跳过重启以防失联，请检查 /etc/ssh/sshd_config.d/00-custom-hardening.conf"
fi
}

# ==================== 主执行流程 ====================

main() {
log "运行环境: $([ "$IS_WSL" -eq 1 ] && echo 'Windows WSL' || echo '独立 Linux VPS')"
setup_dns_and_dualstack
setup_network_proxy
setup_base_packages
setup_zsh_env
if [ "$IS_WSL" -eq 0 ]; then
setup_vps_tuning
setup_vps_security
fi
log "初始化全部完成！"
}
main "$@"
