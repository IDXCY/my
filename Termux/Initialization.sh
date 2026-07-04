#!/data/data/com.termux/files/usr/bin/bash

echo "=== Termux 初始化优化脚本 (纯净原生版) ==="
echo "[提示] 请确保当前环境已配置有效代理，否则 GitHub 官方域名可能会连接超时。"

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

if [ ! -d "$HOME/.oh-my-zsh" ]; then
    # 彻底回归 GitHub 官方原生安装路径
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -- --unattended

    # 彻底回归 GitHub 官方原生的插件仓库
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    git clone https://github.com/zsh-users/zsh-autosuggestions.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

    sed -i 's/plugins=(git)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions)/' ~/.zshrc
fi

# 历史记录数量限制（保留本地持久化，仅作上限截断）
for rfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rfile" ] || [ "$rfile" = "$HOME/.bashrc" ]; then
        sed -i '/HISTSIZE=/d' "$rfile" 2>/dev/null
        sed -i '/HISTFILESIZE=/d' "$rfile" 2>/dev/null

        echo "export HISTSIZE=1000" >> "$rfile"
        echo "export HISTFILESIZE=2000" >> "$rfile"

        if ! grep -q "apt clean" "$rfile" 2>/dev/null; then
            echo "alias exit='apt clean && apt autoclean && exit'" >> "$rfile"
        fi
    fi
done

if ! grep -q "exec zsh" ~/.bashrc; then
    echo "exec zsh" >> ~/.bashrc
fi

# ==================== 3. 字体与显示美化 ====================
echo "[*] 正在配置字体与色彩美化..."
mkdir -p ~/.termux

# 彻底回归 GitHub 官方原生的 Raw 真实文件流链接
FONT_URL="https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/patched-fonts/DejaVuSansMono/Regular/DejaVuSansMNerdFont-Regular.ttf"

if curl -fsSL "$FONT_URL" -o ~/.termux/font.ttf; then
    echo "[√] 字体下载成功"
else
    echo "[×] 远程下载失败。请检查你的终端代理配置（如 export https_proxy=...）后重试。"
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
echo "=== 初始化完成，重启 Termux 或运行 exec zsh 生效 ==="