#!/data/data/com.termux/files/usr/bin/bash

echo "=== Termux 初始化优化脚本 (断言自愈版) ==="

# ==================== 0. 代理自动化注入 (用户自定义) ====================
echo "[-] 为了确保 GitHub 官方域名与官方官方源 100% 畅通，必须配置代理。"
read -p "请输入你的本地代理IP (直接回车默认 127.0.0.1): " PROXY_IP
PROXY_IP=${PROXY_IP:-"127.0.0.1"}

read -p "请输入你的代理共享端口 (直接回车默认 10808): " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-"10808"}

export http_proxy="http://${PROXY_IP}:${PROXY_PORT}"
export https_proxy="http://${PROXY_IP}:${PROXY_PORT}"
git config --global http.proxy "http://${PROXY_IP}:${PROXY_PORT}"
git config --global https.proxy "http://${PROXY_IP}:${PROXY_PORT}"

echo "[√] 终端局部代理已配置: ${http_proxy}"
echo "--------------------------------------------------------"


# ==================== 1. 环境修复与源检查循环 (核心重构) ====================
# 定义强制物理解锁函数
force_unlock_and_clean() {
    echo "[!] 正在执行包管理器物理强制解锁与缓存重置..."
    rm -f $PREFIX/var/lib/dpkg/lock
    rm -f $PREFIX/var/lib/dpkg/lock-frontend
    rm -f $PREFIX/var/cache/apt/archives/lock
    rm -rf $PREFIX/var/lib/apt/lists/*
}

# 强制重置官方原生源
cat << 'EOF' > $PREFIX/etc/apt/sources.list
deb https://packages-cf.termux.org/apt/termux-main stable main
EOF

# 第一轮尝试
echo "[*] [第一轮] 正在尝试拉取官方最新软件包索引..."
apt update -y && apt upgrade -y

# 断言检查机制
if [ $? -ne 0 ]; then
    echo "[⚠️ 检查提示] 第一轮依赖更新遇到阻断（可能是残留进程锁或代理握手时滞）。"
    echo "[*] 正在启动全自动自愈机制，尝试修复环境..."

    # 执行修复
    force_unlock_and_clean
    sleep 2

    # 第二轮再次检查
    echo "[*] [第二轮] 正在重新尝试同步索引并升级..."
    apt update -y && apt upgrade -y

    # 终极断言
    if [ $? -ne 0 ]; then
        echo "【信息熔断】"
        echo "缺失项：不可逆的 Apt 包管理器异常或网络代理隧道彻底握手失败。"
        echo "当前状态：经过二级自愈重试后依然无法通过断言检查。脚本强行终止退出。"
        exit 1
    fi
fi

echo "[√] 断言检查通过！软件包源与底层依赖已100%准备就绪。"


# ==================== 2. 极简 Zsh 与必备工具箱全量配置 ====================
echo "[*] 正在一次性安装 Zsh, Git 及所有必备工具箱..."
apt install zsh curl git tmux tree lf htop ncdu vim wget termux-tools -y

if [ ! -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]; then
    echo "[*] 正在重新克隆 Oh My Zsh 官方完整存储库..."
    rm -rf "$HOME/.oh-my-zsh"
    git clone https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
fi

ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
    echo "[*] 正在克隆语法高亮插件..."
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
    echo "[*] 正在克隆自动补全插件..."
    git clone https://github.com/zsh-users/zsh-autosuggestions.git "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

echo "[*] 正在生成标准 .zshrc 配置文件..."
cat << 'EOF' > "$HOME/.zshrc"
# ==================== 1. Oh My Zsh 核心框架初始化 ====================
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git zsh-syntax-highlighting zsh-autosuggestions)

if [ -f "$ZSH/oh-my-zsh.sh" ]; then
    source $ZSH/oh-my-zsh.sh
fi

# ==================== 2. 历史记录最高优先级硬核配置 ====================
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=5000
export SAVEHIST=5000

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

if [ -f "$HOME/.bashrc" ]; then
    sed -i '/HISTSIZE=/d; /HISTFILESIZE=/d; /exec/d; /zsh/d' "$HOME/.bashrc" 2>/dev/null
fi
echo "export HISTSIZE=1000" >> "$HOME/.bashrc"
echo "export HISTFILESIZE=2000" >> "$HOME/.bashrc"

chsh -s zsh 2>/dev/null


# ==================== 3. 字体与显示美化 ====================
echo "[*] 正在配置字体与色彩美化..."
mkdir -p ~/.termux

FONT_URL="https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/patched-fonts/DejaVuSansMono/Regular/DejaVuSansMNerdFont-Regular.ttf"

if curl -fsSL "$FONT_URL" -o ~/.termux/font.ttf; then
    echo "[√] 字体下载成功"
else
    echo "[×] 远程字体下载失败。"
fi

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

git config --global --unset http.proxy
git config --global --unset https.proxy


# ==================== 4. 存储权限挂载 (绝对末尾) ====================
if [ ! -d "$HOME/storage" ]; then
    echo "[*] 核心流程已结束。最后一步：正在请求存储权限，请在随后的系统弹窗中允许..."
    termux-setup-storage
fi

echo "=== 初始化全部安全完成！你现在可以向上滑动查看完整日志 ==="
echo "=== 请手动输入 'zsh' 或重启应用进入全新终端 ==="