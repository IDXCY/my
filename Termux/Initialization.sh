# ==================== 1. 环境修复、换源与触发式自动清理 ====================
# 切换清华镜像源
sed -i 's|packages.termux.org|mirrors.tuna.tsinghua.edu.cn/termux/termux-main|' $PREFIX/etc/apt/sources.list
apt update && apt upgrade -y

# 修复存储软链接
if [ ! -d "$HOME/storage" ]; then
    termux-setup-storage
fi

# 挂载退出钩子与历史记录限制 (针对 Bash 和 Zsh 均生效)
for rfile in ".bashrc" ".zshrc"; do
    if [ -f "$HOME/$rfile" ] || [ "$rfile" = ".bashrc" ]; then
        sed -i '/HISTSIZE=/d' "$HOME/$rfile" 2>/dev/null
        echo "export HISTSIZE=1000" >> "$HOME/$rfile"
        echo "export HISTFILESIZE=2000" >> "$HOME/$rfile"
        # 退出会话时静默清理缓存
        if ! grep -q "apt clean" "$HOME/$rfile"; then
            echo "alias exit='apt clean && apt autoclean && exit'" >> "$HOME/$rfile"
        fi
    fi
done

# ==================== 2. 极简 Zsh 环境配置 ====================
apt install zsh curl git -y
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -- --unattended
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
    sed -i 's/plugins=(git)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions)/' ~/.zshrc
    if ! grep -q "exec zsh" ~/.bashrc; then
        echo "exec zsh" >> ~/.bashrc
    fi
fi

# ==================== 3. 字体与显示美化 ====================
mkdir -p ~/.termux
# 下载等宽高对比度字体
curl -fsSL https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/patched-fonts/DejaVuSansMono/Regular/complete/DejaVu%20Sans%20Mono%20Nerd%20Font%20Complete%20Mono.ttf -o ~/.termux/font.ttf

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

# ==================== 4. 必备高效工具箱 (含 tsu, tmux, tree) ====================
# 集成了你询问的 tsu、tmux 和 tree
apt install tsu tmux tree lf htop tldr ncdu vim wget -y