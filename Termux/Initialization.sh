#!/data/data/com.termux/files/usr/bin/bash

echo "=== Termux 初始化优化脚本 ==="

# ==================== 1. 环境修复与换源 ====================
pkg update -y && pkg upgrade -y

# 更换更快的镜像源（国内用户，交互式选择）
termux-change-repo

# 修复存储软链接
if [ ! -d "$HOME/storage" ]; then
    termux-setup-storage
fi

# ==================== 2. 极简 Zsh 环境配置 ====================
apt install zsh curl git -y

if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -- --unattended
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
    sed -i 's/plugins=(git)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions)/' ~/.zshrc
fi

# 历史记录限制配置（放在 oh-my-zsh 安装之后，确保 .zshrc 已存在）
for rfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rfile" ]; then
        sed -i '/HISTSIZE=/d' "$rfile"
        sed -i '/HISTFILESIZE=/d' "$rfile"
        echo "export HISTSIZE=1000" >> "$rfile"
        echo "export HISTFILESIZE=2000" >> "$rfile"
    fi
done

# .bashrc 结尾自动切入 zsh
if ! grep -q "exec zsh" ~/.bashrc; then
    echo "exec zsh" >> ~/.bashrc
fi

# ==================== 3. 字体与显示美化 ====================
mkdir -p ~/.termux

FONT_URL="https://fastly.jsdelivr.net/gh/ryanoasis/nerd-fonts@master/patched-fonts/DejaVuSansMono/Regular/complete/DejaVu%20Sans%20Mono%20Nerd%20Font%20Complete%20Mono.ttf"
if curl -fsSL "$FONT_URL" -o ~/.termux/font.ttf; then
    echo "[√] 字体下载成功"
else
    echo "[×] 字体下载失败，请检查网络后手动重试："
    echo "    curl -fsSL \"$FONT_URL\" -o ~/.termux/font.ttf"
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
apt install tmux tree lf htop tldr ncdu vim wget -y

echo "=== 初始化完成，重启 Termux 或运行 exec zsh 生效 ==="