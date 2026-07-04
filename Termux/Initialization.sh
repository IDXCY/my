#!/data/data/com.termux/files/usr/bin/bash

echo "=== Termux 初始化优化脚本 ==="

# ==================== 1. 环境修复与手动换源（严格按用户设计时序） ====================
echo "[*] 正在更新包管理器并升级换源工具..."
# 单独更新存储库索引并强制升级 termux-tools 以获取最新版 termux-change-repo
pkg update -f -y
pkg install termux-tools -y

echo "[*] 请在弹出的菜单中手动选择你需要的镜像源（建议选择 TUNA 清华源或 BFSU 北外源）..."
# 触发手动换源交互界面
termux-change-repo

echo "[*] 正在根据新镜像源执行全局软件升级..."
# 换源完成后，再执行全面的系统更新
pkg upgrade -y

# 修复存储软链接
if [ ! -d "$HOME/storage" ]; then
    echo "[*] 正在请求存储权限，请在系统弹窗中允许..."
    termux-setup-storage
fi

# ==================== 2. 极简 Zsh 环境配置 ====================
echo "[*] 正在安装并配置 Zsh 环境..."
apt install zsh curl git -y

if [ ! -d "$HOME/.oh-my-zsh" ]; then
    # 使用国内加速节点下载 Oh My Zsh 安装脚本
    sh -c "$(curl -fsSL https://github.moeyy.xyz/https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -- --unattended

    # 插件克隆同步使用加速通道，确保 100% 成功
    git clone https://github.moeyy.xyz/https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    git clone https://github.moeyy.xyz/https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

    sed -i 's/plugins=(git)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions)/' ~/.zshrc
fi

# 历史记录数量限制（保留本地持久化，仅作上限截断，不影响上下键翻阅）
for rfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rfile" ] || [ "$rfile" = "$HOME/.bashrc" ]; then
        # 仅删除旧的条数限制字串
        sed -i '/HISTSIZE=/d' "$rfile" 2>/dev/null
        sed -i '/HISTFILESIZE=/d' "$rfile" 2>/dev/null

        # 限制内存中缓存 1000 条，本地文件保存 2000 条，绝对不影响下次打开时的历史读取
        echo "export HISTSIZE=1000" >> "$rfile"
        echo "export HISTFILESIZE=2000" >> "$rfile"

        # 挂载退出时静默清理缓存的钩子别名
        if ! grep -q "apt clean" "$rfile" 2>/dev/null; then
            echo "alias exit='apt clean && apt autoclean && exit'" >> "$rfile"
        fi
    fi
done

# .bashrc 结尾自动切入 zsh
if ! grep -q "exec zsh" ~/.bashrc; then
    echo "exec zsh" >> ~/.bashrc
fi

# ==================== 3. 字体与显示美化 ====================
echo "[*] 正在配置字体与色彩美化..."
mkdir -p ~/.termux

FONT_URL="https://github.moeyy.xyz/https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/patched-fonts/DejaVuSansMono/Regular/DejaVuSansMonoNerdFont-Regular.ttf"

if curl -fsSL "$FONT_URL" -o ~/.termux/font.ttf; then
    echo "[√] 字体下载成功"
else
    echo "[×] 远程下载失败，启用本地降级提示..."
    echo "    请在手机浏览器中下载该文件："
    echo "    https://gitee.com/mirrors/nerd-fonts/raw/master/patched-fonts/DejaVuSansMono/Regular/DejaVuSansMonoNerdFont-Regular.ttf"
    echo "    下载后手动执行：cp /sdcard/Download/DejaVuSansMonoNerdFont-Regular.ttf ~/.termux/font.ttf"
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
apt install tmux tree lf htop tldr ncdu vim wget -y

echo "=== 初始化完成，重启 Termux 或运行 exec zsh 生效 ==="