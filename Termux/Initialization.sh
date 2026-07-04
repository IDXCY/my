#!/data/data/com.termux/files/usr/bin/bash

echo "=== Termux 初始化优化脚本 (纯净原生健壮版) ==="

# ==================== 0. 代理自动化注入 (用户自定义) ====================
echo "[-] 为了确保 GitHub 官方域名（框架、插件、字体）100% 下载成功，必须配置代理。"
read -p "请输入你的本地代理IP (直接回车默认 127.0.0.1): " PROXY_IP
PROXY_IP=${PROXY_IP:-"127.0.0.1"}

read -p "请输入你的代理共享端口 (直接回车默认 10808): " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-"10808"}

# 组装代理全局变量
export http_proxy="http://${PROXY_IP}:${PROXY_PORT}"
export https_proxy="http://${PROXY_IP}:${PROXY_PORT}"

# 强行将代理注入全局 Git 配置，确保后续克隆畅通无阻
git config --global http.proxy "http://${PROXY_IP}:${PROXY_PORT}"
git config --global https.proxy "http://${PROXY_IP}:${PROXY_PORT}"

echo "[√] 终端局部代理已配置: ${http_proxy}"
echo "--------------------------------------------------------"

# ==================== 1. 环境修复与手动换源 ====================
echo "[*] 正在更新包管理器并升级换源工具..."
pkg update -f -y
pkg install termux-tools -y

echo "[*] 请在弹出的菜单中手动选择你需要的镜像源..."
termux-change-repo

echo "[*] 正在根据新镜像源执行全局软件升级..."
pkg upgrade -y

if [ ! -d "$HOME/storage" ]; then
    echo "[*] 正在请求存储权限，请在系统弹窗中允许..."
    termux-setup-storage
fi

# ==================== 2. 极简 Zsh 环境配置 ====================
echo "[*] 正在安装并配置 Zsh 环境..."
apt install zsh curl git -y

# 稳妥健壮的 Oh My Zsh 安装逻辑
if [ ! -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]; then
    echo "[*] 核心框架不存在或破损，正在重新克隆 Oh My Zsh 官方完整存储库..."
    rm -rf "$HOME/.oh-my-zsh"
    git clone https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
fi

# 确保核心插件目录完整
ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
    echo "[*] 正在克隆语法高亮插件..."
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
    echo "[*] 正在克隆自动补全插件..."
    git clone https://github.com/zsh-users/zsh-autosuggestions.git "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

# 规范化一键全量写入 .zshrc，彻底告别动态替换失效、配置挤在同一行的隐患
echo "[*] 正在生成标准 .zshrc 配置文件..."
cat << 'EOF' > "$HOME/.zshrc"
# ==================== 1. Oh My Zsh 核心框架初始化 ====================
export ZSH="$HOME/.oh-my-zsh"

# 选用经典极简主题
ZSH_THEME="robbyrussell"

# 启用核心功能插件（必须放在 source 之前）
plugins=(git zsh-syntax-highlighting zsh-autosuggestions)

# 唤醒 Oh My Zsh 核心管理器
if [ -f "$ZSH/oh-my-zsh.sh" ]; then
    source $ZSH/oh-my-zsh.sh
fi

# ==================== 2. 历史记录最高优先级硬核配置 ====================
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=5000
export SAVEHIST=5000

# 核心同步写入机制
setopt BANG_HIST
setopt EXTENDED_HISTORY
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

# ==================== 3. 环境变量与退出钩子 ====================
export LANG=zh_CN.UTF-8
alias exit='apt clean && apt autoclean && exit'
EOF

# 保持 .bashrc 干净，且幂等安全追加自动切 Zsh 逻辑
if [ -f "$HOME/.bashrc" ]; then
    sed -i '/HISTSIZE=/d; /HISTFILESIZE=/d; /exec zsh/d' "$HOME/.bashrc" 2>/dev/null
fi
echo "export HISTSIZE=1000" >> "$HOME/.bashrc"
echo "export HISTFILESIZE=2000" >> "$HOME/.bashrc"
if ! grep -q "exec zsh" "$HOME/.bashrc"; then
    echo "exec zsh" >> ~/.bashrc
fi

# ==================== 3. 字体与显示美化 ====================
echo "[*] 正在配置字体与色彩美化..."
mkdir -p ~/.termux

FONT_URL="https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/patched-fonts/DejaVuSansMono/Regular/DejaVuSansMNerdFont-Regular.ttf"

# 此时 curl 将完美继承脚本顶部的 proxy 变量
if curl -fsSL "$FONT_URL" -o ~/.termux/font.ttf; then
    echo "[√] 字体下载成功"
else
    echo "[×] 远程字体下载失败。请检查你输入的代理端口是否被手机防火墙拦截。"
fi

# 写入暗黑高对比度配色
cat << 'EOF' > ~/.termux/colors.properties
background: #1e1e1e
foreground: #c5c8c6
cursor: #aeafad
color0: #1d1f21
color1: #cc6666
color2: #b5bd68
color3: #f0c674
color4: #81a2be
color5: #b294bb
color6: #8abeb7
color7: #c5c8c6
color8: #666666
color9: #d54e53
color10: #b9ca4a
color11: #e7c547
color12: #7aa6da
color13: #c397d8
color14: #70c0b1
color15: #eaeaea
EOF

termux-reload-settings

# ==================== 4. 必备高效工具箱 ====================
echo "[*] 正在安装常用工具箱..."
apt install tmux tree lf htop ncdu vim wget -y

# 清理全局 Git 代理配置，避免影响用户后续的日常本地国内 Git 推送
git config --global --unset http.proxy
git config --global --unset https.proxy

echo "=== 初始化完成，重启 Termux 或运行 exec zsh 生效 ==="